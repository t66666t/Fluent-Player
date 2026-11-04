import 'package:video_player_app/services/network/network_http.dart';
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/subtitle_model.dart';
import '../models/subtitle_punctuation.dart';
import 'subtitle_output_preparer.dart';
import 'subtitle_translation_languages.dart';
export 'subtitle_translation_languages.dart';
import 'subtitle_translation_policy.dart';
export 'subtitle_translation_policy.dart';
import 'smart_subtitle_translator.dart';
import '../utils/subtitle_parser.dart';
import 'ai_subtitle_api_settings.dart';
import 'ai_subtitle_translator.dart';
import 'bing_subtitle_translator.dart';
import '../features/model_center/model_catalog.dart';
import '../features/model_center/model_center_service.dart';
import '../features/model_center/local_subtitle_translator.dart';
import '../features/model_center/inference_scheduler.dart';

enum SubtitleTranslateProvider { bing, ai, local }

class SubtitleTranslationResult {
  final String outputPath;
  final int totalCount;

  const SubtitleTranslationResult({
    required this.outputPath,
    required this.totalCount,
  });
}

/// 翻译完成事件（成功或失败）。
class SubtitleTranslationCompletion {
  final String videoPath;
  final SubtitleTranslationResult? result;
  final Object? error;

  const SubtitleTranslationCompletion({
    required this.videoPath,
    this.result,
    this.error,
  });

  bool get isSuccess => result != null && error == null;
}

/// 翻译任务完成回调签名。
typedef SubtitleTranslationCompletionCallback =
    void Function(SubtitleTranslationCompletion completion);

class SubtitleTranslationService extends ChangeNotifier {
  static const popularLanguages = subtitlePopularLanguages;
  static const supportedLanguages = subtitleTranslationLanguages;

  static const Map<String, String> _bingLangMap = {
    'auto': '',
    'zh-CN': 'zh-Hans',
    'zh-TW': 'zh-Hant',
    'en': 'en',
    'ja': 'ja',
    'ko': 'ko',
    'fr': 'fr',
    'de': 'de',
    'es': 'es',
    'ru': 'ru',
    'it': 'it',
    'pt': 'pt',
  };

  final Dio _dio;
  final Future<void> Function(Duration) _delay;
  final AiSubtitleTranslator? _aiTranslator;
  final SubtitleOutputPreparer _outputPreparer;
  BingSubtitleTranslator? _bingTranslator;
  BingSubtitleTranslator get _bing =>
      _bingTranslator ??= BingSubtitleTranslator(dio: _dio, delay: _delay);

  SubtitleTranslationService._internal({Dio? dio})
    : _dio =
          dio ??
          NetworkHttp.instance.createDio(scope: NetworkScope.translation),
      _delay = Future<void>.delayed,
      _outputPreparer = const SubtitleOutputPreparer(),
      _aiTranslator = null;

  /// 全局单例。翻译任务的生命周期跨越 UI 重建，必须使用单例持有状态。
  static final SubtitleTranslationService instance =
      SubtitleTranslationService._internal();

  /// 仅供测试注入使用；UI 层应使用 [instance]。
  SubtitleTranslationService({
    Dio? dio,
    @visibleForTesting Future<void> Function(Duration)? delay,
    @visibleForTesting AiSubtitleTranslator? aiTranslator,
    @visibleForTesting SubtitleOutputPreparer? outputPreparer,
    @visibleForTesting BingSubtitleTranslator? bingTranslator,
  }) : _dio =
           dio ??
           NetworkHttp.instance.createDio(scope: NetworkScope.translation),
       _delay = delay ?? Future<void>.delayed,
       _outputPreparer = outputPreparer ?? const SubtitleOutputPreparer(),
       _aiTranslator = aiTranslator,
       _bingTranslator = bingTranslator;

  // ===== 活跃任务状态（跨 UI 重建保留） =====
  CancelToken? _activeCancelToken;
  void _checkCancelled() {
    final token = _activeCancelToken;
    if (token?.isCancelled == true) throw token!.cancelError!;
  }

  bool _isTranslating = false;
  double _progress = 0;
  String? _activity;
  String? _activeInputPath;
  String? _activeVideoPath;
  SubtitleTranslateProvider? _activeProvider;
  String? _activeSourceLanguage;
  String? _activeTargetLanguage;

  bool get isTranslating => _isTranslating;
  double get progress => _progress;

  /// Short status for the current AI batch, such as "AI 翻译 12/80".
  String? get activity => _activity;
  String? get activeInputPath => _activeInputPath;
  String? get activeVideoPath => _activeVideoPath;
  SubtitleTranslateProvider? get activeProvider => _activeProvider;
  String? get activeSourceLanguage => _activeSourceLanguage;
  String? get activeTargetLanguage => _activeTargetLanguage;

  /// Whether the current task belongs to [videoPath].
  ///
  /// UI pages can be rebuilt while a translation is running.  Paths obtained
  /// from a fresh directory scan may differ only in normalization (and on
  /// Windows, letter case), so raw string equality would lose the task state.
  bool isTranslatingForVideo(String videoPath) {
    return _isTranslating &&
        _activeVideoPath != null &&
        _samePath(_activeVideoPath!, videoPath);
  }

  /// Whether the current task translates [inputPath] for [videoPath].
  bool isTranslatingPathForVideo({
    required String videoPath,
    required String inputPath,
  }) {
    return isTranslatingForVideo(videoPath) &&
        _activeInputPath != null &&
        _samePath(_activeInputPath!, inputPath);
  }

  bool _samePath(String first, String second) {
    final left = p.normalize(first);
    final right = p.normalize(second);
    return Platform.isWindows
        ? left.toLowerCase() == right.toLowerCase()
        : left == right;
  }

  /// 翻译完成回调列表。UI 在 initState 注册、dispose 移除。
  /// 即便发起翻译的 UI 已销毁，只要重开后重新注册即可接收后续完成事件。
  final List<SubtitleTranslationCompletionCallback> _completionCallbacks = [];

  void addCompletionCallback(SubtitleTranslationCompletionCallback cb) {
    _completionCallbacks.add(cb);
  }

  void removeCompletionCallback(SubtitleTranslationCompletionCallback cb) {
    _completionCallbacks.remove(cb);
  }

  void _notifyCompletion(SubtitleTranslationCompletion completion) {
    for (final cb in List.of(_completionCallbacks)) {
      try {
        cb(completion);
      } catch (_) {}
    }
  }

  Future<void> _translationTail = Future<void>.value();
  int _cancellationEpoch = 0;
  void cancel() {
    _cancellationEpoch++;
    _activeCancelToken?.cancel('用户停止了字幕翻译');
  }

  Future<SubtitleTranslationResult> translateSubtitleFile({
    required String inputPath,
    String? sourceText,
    SubtitlePunctuation outputPunctuation = SubtitlePunctuation.preserve,
    required String sourceLanguage,
    required String targetLanguage,
    required SubtitleTranslateProvider provider,
    required void Function(double progress) onProgress,
    void Function(String? activity)? onActivity,
    String? outputDirectory,
    String? outputFilePrefix,
    String? videoPath,
    AiSubtitleTranslationSettings? aiOptions,
    AiSubtitleApiSettings? aiEndpoint,
    Future<void>? cancelSignal,
    ModelJobSpec? localSpecification,
    String checkpointScope = '',
    SmartTranslationPolicy? smartPolicy,
  }) async {
    final previous = _translationTail;
    final epoch = _cancellationEpoch;
    final released = Completer<void>();
    _translationTail = released.future;
    var cancelled = false;
    var finished = false;
    cancelSignal?.then((_) {
      if (!finished) cancelled = true;
    });
    try {
      final frozenLocal = provider == SubtitleTranslateProvider.local
          ? localSpecification ??
                await captureLocalTranslation(ModelCenterService.instance)
          : null;
      if (_isTranslating) onActivity?.call('等待前一个字幕翻译任务');
      await previous;
      if (cancelled || epoch != _cancellationEpoch) throw StateError('字幕翻译已取消');
      return await _translateSubtitleFileNow(
        inputPath: inputPath,
        sourceText: sourceText,
        outputPunctuation: outputPunctuation,
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
        provider: provider,
        onProgress: onProgress,
        onActivity: onActivity,
        outputDirectory: outputDirectory,
        outputFilePrefix: outputFilePrefix,
        videoPath: videoPath,
        aiOptions: aiOptions,
        aiEndpoint: aiEndpoint,
        cancelSignal: cancelSignal,
        localSpecification: frozenLocal,
        checkpointScope: checkpointScope,
        smartPolicy: smartPolicy,
      );
    } finally {
      finished = true;
      await previous;
      released.complete();
    }
  }

  Future<SubtitleTranslationResult> _translateSubtitleFileNow({
    required String inputPath,
    String? sourceText,
    SubtitlePunctuation outputPunctuation = SubtitlePunctuation.preserve,
    required String sourceLanguage,
    required String targetLanguage,
    required SubtitleTranslateProvider provider,
    required void Function(double progress) onProgress,
    void Function(String? activity)? onActivity,
    String? outputDirectory,
    String? outputFilePrefix,
    String? videoPath,
    AiSubtitleTranslationSettings? aiOptions,
    AiSubtitleApiSettings? aiEndpoint,
    Future<void>? cancelSignal,
    ModelJobSpec? localSpecification,
    String checkpointScope = '',
    SmartTranslationPolicy? smartPolicy,
  }) async {
    if (_isTranslating) {
      throw StateError('已有字幕翻译任务正在进行，请等待当前任务完成');
    }
    final token = CancelToken();
    _activeCancelToken = token;
    var finished = false;
    cancelSignal?.then((_) {
      if (!finished) token.cancel('用户停止了转录翻译');
    });
    // 设置活跃任务状态，通知 UI（含重开后的新 UI）能恢复进度显示
    _isTranslating = true;
    _progress = 0;
    _activity = null;
    _activeInputPath = inputPath;
    _activeVideoPath = videoPath;
    _activeProvider = provider;
    _activeSourceLanguage = sourceLanguage;
    _activeTargetLanguage = smartPolicy == null ? targetLanguage : 'mul';
    notifyListeners();

    try {
      _checkCancelled();
      final file = File(inputPath);
      if (!await file.exists()) {
        throw Exception('字幕文件不存在');
      }

      final content =
          sourceText ?? SubtitleParser.decodeBytes(await file.readAsBytes());
      final items = await (smartPolicy == null
          ? _outputPreparer.parse(content)
          : _outputPreparer.parseTranslation(content));
      _checkCancelled();

      if (items.isEmpty) {
        throw Exception('字幕内容为空或格式不支持');
      }

      var done = 0;
      String? providerActivity;
      void publishActivity(String message) {
        _checkCancelled();
        _activity = message;
        notifyListeners();
        try {
          onActivity?.call(message);
        } catch (_) {}
      }

      void combinedActivity(String? message) {
        providerActivity = message;
        publishActivity(
          '已处理 $done/${items.length} 条'
          '${message == null || message.isEmpty ? '' : ' · $message'}',
        );
      }

      // Keep the caller's percentage and item count in the same notification.
      void combinedProgress(double p) {
        _checkCancelled();
        _progress = p.clamp(0.0, 1.0);
        done = (_progress * items.length).round();
        try {
          onProgress(_progress);
        } catch (_) {}
        combinedActivity(providerActivity);
      }

      combinedProgress(0);

      final translatedTexts = await _translateItems(
        items: items,
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
        provider: provider,
        onProgress: combinedProgress,
        onActivity: combinedActivity,
        aiOptions: aiOptions,
        aiEndpoint: aiEndpoint,
        localSpecification: localSpecification,
        checkpointScope: checkpointScope,
        smartPolicy: smartPolicy,
      );

      _checkCancelled();
      publishActivity('已处理 $done/${items.length} 条 · 正在保存翻译字幕');
      final srtContent = await _outputPreparer.translation(
        items,
        translatedTexts,
        outputPunctuation,
        lineEnding: Platform.isWindows ? '\r\n' : '\n',
      );
      _checkCancelled();
      final outputPath = _buildOutputPath(
        inputPath: inputPath,
        targetLanguage: smartPolicy == null ? targetLanguage : 'mul',
        outputDirectory: outputDirectory,
        outputFilePrefix: outputFilePrefix,
      );
      final outputDir = Directory(p.dirname(outputPath));
      if (!await outputDir.exists()) {
        await outputDir.create(recursive: true);
      }
      await File(outputPath).writeAsString(srtContent, flush: true);
      _checkCancelled();

      final result = SubtitleTranslationResult(
        outputPath: outputPath,
        totalCount: items.length,
      );
      _notifyCompletion(
        SubtitleTranslationCompletion(
          videoPath: videoPath ?? '',
          result: result,
        ),
      );
      return result;
    } catch (e) {
      _notifyCompletion(
        SubtitleTranslationCompletion(videoPath: videoPath ?? '', error: e),
      );
      rethrow;
    } finally {
      finished = true;
      _activeCancelToken = null;
      _isTranslating = false;
      _progress = 0;
      _activity = null;
      _activeInputPath = null;
      _activeVideoPath = null;
      _activeProvider = null;
      _activeSourceLanguage = null;
      _activeTargetLanguage = null;
      notifyListeners();
    }
  }

  /// In-memory batches used by local ASR streaming. The file translator keeps
  /// its own UI/cancellation state; batches never write a temporary full SRT.
  Future<List<String>> translateCueBatch({
    required List<SubtitleItem> items,
    required String sourceLanguage,
    required String targetLanguage,
    required SubtitleTranslateProvider provider,
    required void Function(double) onProgress,
    void Function(String?)? onActivity,
    void Function(int, String)? onTranslated,
    AiSubtitleTranslationSettings? aiOptions,
    AiSubtitleApiSettings? aiEndpoint,
    ModelJobSpec? localSpecification,
    ModelCenterService? modelCenter,
    LocalTranslationSession? localSession,
    InferenceReservation? reservation,
    String precedingContext = '',
    String checkpointScope = '',
    Future<void>? cancelSignal,
    SmartTranslationPolicy? smartPolicy,
  }) async {
    if (smartPolicy != null) {
      final center = modelCenter ?? ModelCenterService.instance;
      final local = provider == SubtitleTranslateProvider.local;
      final specification = local
          ? localSpecification ?? await captureLocalTranslation(center)
          : null;
      final languages = local
          ? subtitleLanguagesForModel(
              center.artifact(specification!.profile.model)?.languages ??
                  const [],
            )
          : supportedLanguages;
      smartPolicy.validate(languages);
      final ownedSession = local && localSession == null
          ? LocalTranslationSession()
          : null;
      try {
        return await SmartSubtitleTranslator().translate(
          items: items,
          policy: smartPolicy,
          precedingContext: precedingContext,
          supportedSourceLanguages: local ? languages : null,
          cancelSignal: cancelSignal,
          onProgress: onProgress,
          onActivity: onActivity,
          onTranslated: onTranslated,
          translateBatch:
              (pieces, source, target, scope, progress, translated) =>
                  translateCueBatch(
                    items: pieces,
                    sourceLanguage: source,
                    targetLanguage: target,
                    provider: provider,
                    onProgress: progress,
                    onActivity: onActivity,
                    onTranslated: translated,
                    aiOptions: aiOptions,
                    aiEndpoint: aiEndpoint,
                    localSpecification: specification,
                    modelCenter: center,
                    localSession: localSession ?? ownedSession,
                    reservation: reservation,
                    precedingContext: precedingContext,
                    checkpointScope: '$checkpointScope:smart:$scope',
                    cancelSignal: cancelSignal,
                  ),
        );
      } finally {
        await ownedSession?.release();
      }
    }
    if (provider == SubtitleTranslateProvider.local) {
      return LocalSubtitleTranslator(center: modelCenter).translate(
        texts: items.map((cue) => cue.text).toList(),
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
        targetLabel: _languageLabel(targetLanguage),
        glossary:
            (aiOptions ?? AiSubtitleTranslationSettings.defaults).customPrompt,
        onProgress: onProgress,
        onActivity: onActivity,
        onTranslated: onTranslated,
        specification: localSpecification,
        checkpointScope: checkpointScope,
        precedingContext: precedingContext,
        cancelSignal: cancelSignal,
        reservation: reservation,
        session: localSession,
      );
    }
    if (provider == SubtitleTranslateProvider.ai) {
      return (_aiTranslator ?? AiSubtitleTranslator.shared).translate(
        texts: items.map((cue) => cue.text).toList(),
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
        targetLabel: _languageLabel(targetLanguage),
        sourceLabel: _languageLabel(sourceLanguage),
        options: aiOptions ?? AiSubtitleTranslationSettings.defaults,
        endpoint: aiEndpoint?.toChatSettings(),
        onProgress: onProgress,
        onActivity: onActivity,
        onTranslated: onTranslated,
        requireAll: true,
        precedingContext: precedingContext,
        cancelSignal: cancelSignal,
      );
    }
    final batch = SubtitleTranslationService(
      dio: _dio,
      delay: _delay,
      bingTranslator: provider == SubtitleTranslateProvider.bing
          ? _bing
          : _bingTranslator,
    );
    final token = batch._activeCancelToken = CancelToken();
    var finished = false;
    cancelSignal?.then((_) {
      if (!finished) token.cancel('字幕翻译已停止');
    });
    try {
      final output = await batch._translateItems(
        items: items,
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
        provider: provider,
        onProgress: onProgress,
        onActivity: (value) => onActivity?.call(value),
        onTranslated: onTranslated,
      );
      if (output.length != items.length ||
          output.any((text) => text.trim().isEmpty)) {
        throw StateError('部分字幕尚未翻译成功，请继续生成');
      }
      return output;
    } finally {
      finished = true;
      batch._activeCancelToken = null;
    }
  }

  Future<List<String>> _translateItems({
    required List<SubtitleItem> items,
    required String sourceLanguage,
    required String targetLanguage,
    required SubtitleTranslateProvider provider,
    required void Function(double progress) onProgress,
    required void Function(String? activity) onActivity,
    AiSubtitleTranslationSettings? aiOptions,
    AiSubtitleApiSettings? aiEndpoint,
    ModelJobSpec? localSpecification,
    String checkpointScope = '',
    void Function(int, String)? onTranslated,
    SmartTranslationPolicy? smartPolicy,
  }) async {
    if (smartPolicy != null) {
      return translateCueBatch(
        items: items,
        sourceLanguage: 'auto',
        targetLanguage: 'mul',
        smartPolicy: smartPolicy,
        provider: provider,
        onProgress: onProgress,
        onActivity: onActivity,
        onTranslated: onTranslated,
        aiOptions: aiOptions ?? await AiSubtitleTranslationSettings.load(),
        aiEndpoint: aiEndpoint,
        localSpecification: localSpecification,
        checkpointScope: checkpointScope,
        cancelSignal: _activeCancelToken?.whenCancel.then<void>((_) {}),
      );
    }
    if (provider == SubtitleTranslateProvider.local) {
      onActivity('正在准备本地翻译');
      return LocalSubtitleTranslator().translate(
        texts: items.map((item) => item.text).toList(),
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
        targetLabel: _languageLabel(targetLanguage),
        glossary: (aiOptions ?? await AiSubtitleTranslationSettings.load())
            .customPrompt,
        onProgress: onProgress,
        onActivity: onActivity,
        specification: localSpecification,
        checkpointScope: checkpointScope,
        cancelSignal: _activeCancelToken?.whenCancel.then<void>((_) {}),
      );
    }

    if (provider == SubtitleTranslateProvider.ai) {
      // Batch size, concurrency and reflective mode are panel settings.
      // The endpoint itself is the translation interface, not the chat one.
      final configured =
          aiOptions ?? await AiSubtitleTranslationSettings.load();
      final translator = _aiTranslator ?? AiSubtitleTranslator.shared;
      onActivity('正在准备 AI 翻译');
      return translator.translate(
        texts: items.map((item) => item.text).toList(),
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
        targetLabel: _languageLabel(targetLanguage),
        sourceLabel: _languageLabel(sourceLanguage),
        options: configured,
        onProgress: onProgress,
        onActivity: onActivity,
        endpoint: aiEndpoint?.toChatSettings(),
        cancelSignal: _activeCancelToken?.whenCancel.then<void>((_) {}),
      );
    }

    return _bing.translate(
      texts: items.map((item) => item.text).toList(),
      sourceLanguage: _bingLangMap[sourceLanguage] ?? sourceLanguage,
      targetLanguage: _bingLangMap[targetLanguage] ?? targetLanguage,
      cancelToken: _activeCancelToken,
      onProgress: onProgress,
      onTranslated: onTranslated,
    );
  }

  String _languageLabel(String code) => subtitleLanguageLabel(code);

  /// 是否为中英方向（源/目标中任意一方为中文、另一方为英文，
  /// 或包含 auto 自动检测）。用于读写两个方向各自保存的翻译选择。
  bool isEnZhDirection(String sourceLanguage, String targetLanguage) {
    final sourceIsZh =
        sourceLanguage == 'zh-CN' ||
        sourceLanguage == 'zh-TW' ||
        sourceLanguage == 'zh';
    final sourceIsEn = sourceLanguage == 'en';
    final targetIsZh =
        targetLanguage == 'zh-CN' ||
        targetLanguage == 'zh-TW' ||
        targetLanguage == 'zh';
    final targetIsEn = targetLanguage == 'en';
    if (sourceLanguage == 'auto' || targetLanguage == 'auto') {
      // auto 方向：若另一端是中文或英文，按中英方向处理
      return targetIsZh || targetIsEn || sourceIsZh || sourceIsEn;
    }
    return (sourceIsEn && targetIsZh) || (sourceIsZh && targetIsEn);
  }

  String _buildOutputPath({
    required String inputPath,
    required String targetLanguage,
    String? outputDirectory,
    String? outputFilePrefix,
  }) {
    final dir = outputDirectory?.trim().isNotEmpty == true
        ? p.normalize(outputDirectory!.trim())
        : p.dirname(inputPath);
    final base = (outputFilePrefix?.trim().isNotEmpty == true)
        ? outputFilePrefix!.trim()
        : p.basenameWithoutExtension(inputPath);
    final ext = '.srt';
    final normalizedLang = targetLanguage.replaceAll(
      RegExp(r'[^a-zA-Z0-9\-]'),
      '_',
    );

    var candidate = p.join(dir, '$base.translated.$normalizedLang$ext');
    if (!File(candidate).existsSync()) {
      return candidate;
    }

    candidate = p.join(
      dir,
      '$base.translated.$normalizedLang.${DateTime.now().millisecondsSinceEpoch}$ext',
    );
    return candidate;
  }
}
