import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;

import '../../services/app_storage_service.dart';
import 'inference_scheduler.dart';
import 'inference_resource_governor.dart';
import 'inference_tuning.dart';
import 'local_translation_batch.dart';
import 'model_catalog.dart';
import 'model_adapters.dart';
import 'model_center_service.dart';
import 'translation_inference.dart';
import 'translation_android_inference.dart';
import 'translation_compute_policy.dart';
import 'translation_performance.dart';
import 'translation_memory.dart';

/// Ownership moves to translate() during each call, so normal error recovery
/// can dispose a failed backend while successful batches keep their weights.
class LocalTranslationSession {
  TranslationInference? _engine;
  String? _key;
  void Function()? _release, _unregisterIdle;
  bool get hasModel => _engine != null || _key != null;
  TranslationInference? take(String key) {
    if (_key != key) return null;
    final value = _engine;
    _engine = null;
    return value;
  }

  Future<void> select(String key) async {
    if (_key != key && _engine != null) await release();
  }

  Future<void> retain(
    String key,
    TranslationInference engine,
    ModelCenterService center,
    String modelId,
  ) async {
    await _engine?.dispose();
    _engine = engine;
    _key = key;
    _release ??= center.retainModel(modelId);
    _unregisterIdle?.call();
    _unregisterIdle = InferenceResourceSession.current?.registerIdleModel(
      () async {
        if (_engine != null) await release();
      },
    );
  }

  Future<void> release() async {
    _unregisterIdle?.call();
    _unregisterIdle = null;
    final engine = _engine;
    _engine = null;
    try {
      await engine?.dispose();
    } finally {
      _release?.call();
      _release = null;
      _key = null;
    }
  }
}

typedef LocalTranslationCompletion =
    Future<String> Function(
      String text,
      String context,
      String target,
      String glossary,
      Future<void>? cancelSignal,
    );
typedef LocalTranslationBatchCompletion =
    Future<String> Function(
      Map<int, String> texts,
      String context,
      String target,
      String glossary,
      Future<void>? cancelSignal,
    );

final _protectedTranslationText = RegExp(
  r'</?(?:i|b|u|font)(?:\s[^>]*)?>|\{\\[^}]+\}|\{\{[^}]+\}\}|%[sd]',
  caseSensitive: false,
);

typedef LocalTranslationInferenceFactory =
    Future<TranslationInference> Function(
      String modelPath,
      ModelParams params,
      bool gpu,
      Future<void>? cancelSignal,
    );
final _translationHtmlTags = RegExp(
  r'</?(?:i|b|u|font)(?:\s[^>]*)?>',
  caseSensitive: false,
);

/// Remove format tokens copied from a neighbouring record without changing
/// words. Missing source tags/placeholders still fail validation and retry.
String normalizeLocalTranslation(String source, String translated) {
  var result = translated.trim();
  if (!source.contains(']') && result.endsWith(']') && !result.contains('[')) {
    result = result.substring(0, result.length - 1).trimRight();
  }
  final allowed = <String, int>{};
  for (final match in _translationHtmlTags.allMatches(source)) {
    allowed.update(match[0]!, (n) => n + 1, ifAbsent: () => 1);
  }
  final matches = _translationHtmlTags.allMatches(result).toList();
  final extras = <String, int>{};
  for (final match in matches) {
    extras.update(match[0]!, (n) => n + 1, ifAbsent: () => 1);
  }
  for (final tag in extras.keys.toList()) {
    extras[tag] = extras[tag]! - (allowed[tag] ?? 0);
  }
  for (final match in matches.reversed) {
    final tag = match[0]!;
    if ((extras[tag] ?? 0) > 0) {
      result = result.replaceRange(match.start, match.end, '');
      extras[tag] = extras[tag]! - 1;
    }
  }
  return result.trim();
}

List<String> splitLocalTranslationText(String text, {int maxRunes = 400}) {
  if (maxRunes < 1) throw ArgumentError.value(maxRunes, 'maxRunes');
  final runes = text.runes.toList();
  final protected = _protectedTranslationText
      .allMatches(text)
      .map(
        (match) => (
          start: text.substring(0, match.start).runes.length,
          end: text.substring(0, match.end).runes.length,
        ),
      )
      .toList();
  final result = <String>[];
  for (var at = 0; at < runes.length;) {
    var end = (at + maxRunes).clamp(0, runes.length);
    if (end < runes.length) {
      for (var i = end - 1; i > at + maxRunes ~/ 2; i--) {
        if ('.!?。！？\n'.runes.contains(runes[i])) {
          end = i + 1;
          break;
        }
      }
      for (final span in protected) {
        if (span.start < end && end < span.end) {
          end = span.start > at ? span.start : span.end;
          break;
        }
      }
    }
    result.add(String.fromCharCodes(runes.sublist(at, end)));
    at = end;
  }
  return result;
}

void validateLocalTranslation(
  String source,
  String translated, {
  String targetLanguage = '',
}) {
  if (translated.trim().isEmpty ||
      translated.contains('<|im_') ||
      translated.contains('<think>') ||
      translated.contains('</think>')) {
    throw const FormatException('模型未返回有效译文');
  }
  final leakedRow = RegExp(r'\[\s*(?:\d+|编号)\s*[,，]');
  if (leakedRow.hasMatch(translated) && !leakedRow.hasMatch(source)) {
    throw const FormatException('模型将批次编号混入译文，需要重新翻译该条字幕');
  }
  final leakedPrompt = RegExp(
    r'(?:Background|Context)\s*\(\s*(?:no translation|do not translate)\s*\)|Text to be translated\s*[:：]|背景(?:信息)?[（(]不要翻译|待翻译文本\s*[:：]',
    caseSensitive: false,
  );
  if (leakedPrompt.hasMatch(translated) && !leakedPrompt.hasMatch(source)) {
    throw const FormatException('模型将提示词混入译文，需要重新翻译该条字幕');
  }
  if (!source.contains(']') &&
      translated.trimRight().endsWith(']') &&
      !translated.contains('[')) {
    throw const FormatException('译文含有多余的批次括号');
  }
  final before =
      _protectedTranslationText.allMatches(source).map((m) => m[0]!).toList()
        ..sort();
  final after =
      _protectedTranslationText
          .allMatches(translated)
          .map((m) => m[0]!)
          .toList()
        ..sort();
  if (jsonEncode(before) != jsonEncode(after)) {
    throw const FormatException('译文未保留字幕标签或占位符，请重试');
  }
  final plainSource = source.replaceAll(_protectedTranslationText, '').trim();
  final plainTarget = translated
      .replaceAll(_protectedTranslationText, '')
      .trim();
  final chinese = RegExp(r'[\u3400-\u9fff]');
  // Names and codes may stay unchanged; an untranslated sentence in a clearly
  // different writing system must not be accepted as a successful response.
  final properName = RegExp(r"^[A-Z][a-zA-Z'-]*(?: [A-Z][a-zA-Z'-]*){0,3}$");
  if (targetLanguage.startsWith('zh') &&
      RegExp(r'[\uac00-\ud7af]').allMatches(plainSource).length >= 8 &&
      !chinese.hasMatch(plainTarget)) {
    throw const FormatException('模型未将韩语字幕翻译为中文');
  }
  if (targetLanguage.startsWith('zh') &&
      !chinese.hasMatch(plainSource) &&
      RegExp(r'[a-zA-Z]+').allMatches(plainSource).length >= 2 &&
      !properName.hasMatch(plainSource) &&
      !chinese.hasMatch(plainTarget)) {
    throw const FormatException('模型未将字幕翻译为中文');
  }
  if (targetLanguage == 'en' &&
      chinese.allMatches(plainSource).length >= 8 &&
      !RegExp(r'[a-zA-Z]').hasMatch(plainTarget)) {
    throw const FormatException('模型未将字幕翻译为英语');
  }
}

class LocalTranslationMetrics {
  String backend = 'CPU';
  int threads = 0, gpuLayers = 0, loadMs = 0, elapsedMs = 0;
  int promptThreads = 0, batchLimit = 8;
  String schedulingReason = '';

  int modelLoads = 0, modelReuses = 0;
  int requests = 0, batchRequests = 0, fallbackRequests = 0;
  int promptTokens = 0, generatedTokens = 0, restoredCues = 0;
  int calibrationMs = 0, reusedPieces = 0;
  int deferredPieces = 0, recoveredPieces = 0, cpuRestarts = 0;
  double promptMs = 0, decodeMs = 0, sampleMs = 0;
  Map<String, Object> toJson() => {
    'backend': backend,
    'threads': threads,
    'promptThreads': promptThreads,
    'batchLimit': batchLimit,
    'schedulingReason': schedulingReason,
    'gpuLayers': gpuLayers,
    'loadMs': loadMs,
    'modelLoads': modelLoads,
    'modelReuses': modelReuses,
    'elapsedMs': elapsedMs,
    'requests': requests,
    'batchRequests': batchRequests,
    'fallbackRequests': fallbackRequests,
    'promptTokens': promptTokens,
    'generatedTokens': generatedTokens,
    'promptMs': promptMs,
    'decodeMs': decodeMs,
    'sampleMs': sampleMs,
    'restoredCues': restoredCues,
    'calibrationMs': calibrationMs,
    'reusedPieces': reusedPieces,
    'deferredPieces': deferredPieces,
    'recoveredPieces': recoveredPieces,
    'cpuRestarts': cpuRestarts,
  };
}

String _failureCode(Object error) => switch (error) {
  InferenceMemoryPressure() => 'memory',
  TranslationWorkerFailure() => error.code,
  FormatException() => 'invalid_translation',
  FileSystemException() => 'storage',
  TimeoutException() => 'timeout',
  _ => 'runtime',
};

class LocalTranslationIncomplete extends FormatException {
  const LocalTranslationIncomplete(super.message);
}

/// Safe for the task UI: arbitrary native errors can contain input text/paths.
String localTranslationFailureSummary(Object error) => switch (error) {
  InferenceMemoryPressure() => error.message,
  LocalTranslationIncomplete() => error.message,
  FormatException() => '译文未通过格式或完整性检查，已保留有效断点',
  FileSystemException() => '无法读写翻译文件，请检查磁盘空间和目录权限',
  TimeoutException() => '本地推理长时间未响应，已保留有效断点',
  StateError() when isTransientInferencePressure(error) =>
    '当前内存余量不足，已保留有效断点；释放资源后可继续',
  _ => '本地推理异常，已保留有效断点，可重试或切换模型',
};

class _TranslationPiece {
  _TranslationPiece(this.id, this.cue, this.source);
  final int id, cue;
  final String source;
  String? result;
}

class LocalSubtitleTranslator {
  LocalSubtitleTranslator({
    ModelCenterService? center,
    LocalTranslationCompletion? complete,
    LocalTranslationBatchCompletion? completeBatch,
    LocalTranslationInferenceFactory? loadInference,
    String? gpuWorkerExecutable,
    InferenceScheduler? scheduler,
  }) : center = center ?? ModelCenterService.instance,
       _complete = complete,
       _completeBatch = completeBatch,
       _loadInference = loadInference,
       _gpuWorkerExecutable = gpuWorkerExecutable,
       _scheduler = scheduler ?? InferenceScheduler.instance;
  final ModelCenterService center;
  final LocalTranslationCompletion? _complete;
  final LocalTranslationBatchCompletion? _completeBatch;
  final LocalTranslationInferenceFactory? _loadInference;
  final String? _gpuWorkerExecutable;
  final InferenceScheduler _scheduler;

  Future<List<String>> translate({
    required List<String> texts,
    required String sourceLanguage,
    required String targetLanguage,
    required String targetLabel,
    String glossary = '',
    required void Function(double) onProgress,
    void Function(String?)? onActivity,
    void Function(LocalTranslationMetrics)? onMetrics,
    // Optional local benchmark tracing. Application callers never log content.
    void Function(String)? onBatchResponse,
    Future<void>? cancelSignal,
    ModelJobSpec? specification,
    bool resume = true,
    bool calibrate = false,
    String checkpointScope = '',
    InferenceReservation? reservation,
    LocalTranslationSession? session,
    String precedingContext = '',
    void Function(int, String)? onTranslated,
  }) async {
    await center.initialize();
    final spec = specification ?? await captureLocalTranslation(center);
    final options = spec.translation;
    final metrics = LocalTranslationMetrics();
    final watch = Stopwatch()..start();
    var cancelled = false, finished = false;
    File? diagnostic;
    var stage = 'queue', completedCues = 0;
    var currentCues = <int>[];
    final recoveryEvents = <Map<String, Object?>>[];
    Object? terminalError;
    void recordRecovery(Object error) {
      if (recoveryEvents.length == 16) recoveryEvents.removeAt(0);
      recoveryEvents.add({
        'code': _failureCode(error),
        'stage': stage,
        'cueNumbers': List<int>.of(currentCues),
        'elapsedMs': watch.elapsedMilliseconds,
        if (error is TranslationWorkerFailure) 'exitCode': error.exitCode,
      });
    }

    TranslationInference? engine;
    cancelSignal?.then((_) {
      if (!finished) {
        cancelled = true;
        engine?.cancel();
      }
    });
    void check() {
      if (cancelled) throw StateError('字幕翻译已取消');
    }

    try {
      await center.prepareModel(
        spec,
        cancelSignal: cancelSignal,
        onProgress: (message) => onActivity?.call(message),
      );
      check();
      onActivity?.call('等待本地推理资源');
      return await _scheduler.run(
        () => center.usingModel(spec.profile.model, (model, directory) async {
          if (spec.artifactIdentity != model.identity) {
            throw StateError('任务所需的模型版本已变更，请重新创建任务');
          }
          check();
          String digest(Map<String, Object?> value) =>
              sha256.convert(utf8.encode(jsonEncode(value))).toString();
          // Performance settings do not change the identity of saved work.
          final key = digest({
            'version': 2,
            'texts': texts,
            'source': sourceLanguage,
            'target': targetLanguage,
            'identity': model.identity,
            'prompt': glossary,
            if (checkpointScope.isNotEmpty) 'run': checkpointScope,
          });
          final root = await center.storage.featureDirectory('model_jobs');
          final checkpoint = File(p.join(root.path, 'translation-$key.json'));
          diagnostic = File(
            p.join(root.path, 'translation-$key.diagnostic.json'),
          );
          stage = 'restore';
          Object? raw = resume ? await readStorageJson(checkpoint) : null;
          if (resume && raw == null && checkpointScope.isEmpty) {
            // Read the original per-cue checkpoint after upgrading the app.
            // The old key included the shared ASR/translation CPU budget.
            // Preserve it even when that preference changed before upgrading.
            for (final threads in {spec.threads, 1, 2, 3, 4}) {
              final legacySpec = spec.toJson()..remove('translation');
              legacySpec['threads'] = threads;
              final legacyKey = digest({
                'version': 1,
                'texts': texts,
                'source': sourceLanguage,
                'target': targetLanguage,
                'spec': legacySpec,
                'prompt': glossary,
              });
              raw = await readStorageJson(
                File(p.join(root.path, 'translation-$legacyKey.json')),
              );
              if (raw != null) break;
            }
          }
          final translations = <String, String>{};
          final saved = raw is Map ? raw['translations'] : null;
          final output = List<String>.filled(texts.length, '');
          var done = 0, dirty = false;
          for (var i = 0; i < texts.length; i++) {
            if (texts[i].trim().isEmpty) {
              done++;
            } else if (saved is Map && saved['$i'] is String) {
              try {
                final value = saved['$i'] as String;
                validateLocalTranslation(
                  texts[i],
                  value,
                  targetLanguage: targetLanguage,
                );
                translations['$i'] = output[i] = value;
                done++;
                metrics.restoredCues++;
              } on FormatException {
                // Repair the invalid entry without discarding other saved cues.
              }
            }
          }
          onProgress(texts.isEmpty ? 1 : done / texts.length);
          completedCues = done;
          if (done == texts.length) return output;
          final pieces = <_TranslationPiece>[];
          final cuePieces = <int, List<_TranslationPiece>>{};
          for (var i = 0; i < texts.length; i++) {
            if (texts[i].trim().isEmpty || output[i].isNotEmpty) continue;
            final group = <_TranslationPiece>[];
            for (final part in splitLocalTranslationText(texts[i])) {
              final piece = _TranslationPiece(pieces.length, i, part);
              pieces.add(piece);
              group.add(piece);
            }
            cuePieces[i] = group;
          }
          var lastFlushMs = 0;
          Future<void> flush({bool force = false}) async {
            if (!dirty ||
                (!force && watch.elapsedMilliseconds - lastFlushMs < 1000)) {
              return;
            }
            await writeStorageJson(checkpoint, {
              'version': 2,
              'identity': model.identity,
              'translations': Map<String, String>.of(translations),
              'done': translations.length,
              'total': texts.length,
            });
            dirty = false;
            lastFlushMs = watch.elapsedMilliseconds;
          }

          void acceptOne(_TranslationPiece piece, String translated) {
            if (piece.result != null) return;
            translated = normalizeLocalTranslation(piece.source, translated);
            try {
              validateLocalTranslation(
                piece.source,
                translated,
                targetLanguage: targetLanguage,
              );
            } on FormatException {
              return;
            }
            piece.result = translated.trim();
            final group = cuePieces[piece.cue]!;
            if (group.any((p) => p.result == null)) return;
            final value = group
                .map((p) => p.result!)
                .join(
                  targetLanguage.startsWith('zh') || targetLanguage == 'ja'
                      ? ''
                      : ' ',
                );
            validateLocalTranslation(
              texts[piece.cue],
              value,
              targetLanguage: targetLanguage,
            );
            output[piece.cue] = translations['${piece.cue}'] = value;
            dirty = true;
            done++;
            completedCues = done;
            onTranslated?.call(piece.cue, value);
            onProgress(done / texts.length);
          }

          String contextFor(int cue) {
            final previous = [
              precedingContext,
              ...texts.skip((cue - 2).clamp(0, cue)).take(cue.clamp(0, 2)),
            ].join('\n');
            final runes = previous.runes.toList();
            return String.fromCharCodes(
              runes.skip((runes.length - 160).clamp(0, runes.length)),
            );
          }

          // Repeated cues share work only with identical context. A recurring
          // word with a different preceding sentence can have a different meaning.
          final uniquePieces = <_TranslationPiece>[];
          final aliases = <int, List<_TranslationPiece>>{};
          final byContent = <String, _TranslationPiece>{};
          for (final piece in pieces) {
            final key = jsonEncode([piece.source, contextFor(piece.cue)]);
            final previous = byContent[key];
            if (previous == null) {
              byContent[key] = piece;
              uniquePieces.add(piece);
            } else {
              aliases.putIfAbsent(previous.id, () => []).add(piece);
            }
          }
          void accept(_TranslationPiece piece, String translated) {
            acceptOne(piece, translated);
            if (piece.result == null) return;
            for (final alias in aliases[piece.id] ?? <_TranslationPiece>[]) {
              if (alias.result != null) continue;
              acceptOne(alias, piece.result!);
              metrics.reusedPieces++;
            }
          }

          final resources = InferenceResourceSession.current!;
          resources.translationMaximum = options.threads;
          final tuningIdentity = inferenceTuningSignature(
            resources,
            model.identity,
            'llamadart-pinned',
            configuration:
                '$sourceLanguage:$targetLanguage:${jsonEncode(options.toJson())}',
          );
          final generationTuner = InferenceTuner(
            session: resources,
            records: center.inferenceTuning,
            modelId: model.id,
            signature: '$tuningIdentity:tg',
            save: center.save,
          );
          final promptTuner = InferenceTuner(
            session: resources,
            records: center.inferenceTuning,
            modelId: model.id,
            signature: '$tuningIdentity:pp',
            save: center.save,
          );
          if (options.threads == 0) {
            resources.preferredTranslationThreads =
                generationTuner.preferredThreads;
            resources.preferredPromptThreads = promptTuner.preferredThreads;
          }
          final initialParams = localTranslationModelParams(
            options,
            platform: Platform.operatingSystem,
            processors: Platform.numberOfProcessors,
            threads: resources.decision.translationThreads,
            promptThreads: resources.decision.promptThreads,
          );
          metrics.threads = initialParams.numberOfThreads;
          final apple = Platform.isMacOS || Platform.isIOS;
          final desktopWorker =
              _gpuWorkerExecutable ??
              ProcessTranslationInference.bundledExecutable();
          final canCompareGpu =
              apple ||
              Platform.isAndroid ||
              desktopWorker != null ||
              _loadInference != null;
          final signature =
              tuningIdentity +
              translationPerformanceSignature(
                modelIdentity: model.identity,
                threads: metrics.threads,
                batchSize: options.batchSize,
                gpuLayers: options.gpuLayers,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                backend: options.backend,
              );
          final cacheKey =
              '${model.id}:${sha256.convert(utf8.encode(signature))}';
          final previousLastProfile = center.translationPerformance[model.id];
          final previousCachedProfile = center.translationPerformance[cacheKey];
          final previousProfile = previousCachedProfile ?? previousLastProfile;
          final profile =
              previousProfile?.matches(signature, DateTime.now()) == true
              ? previousProfile
              : null;
          final rowBatches =
              (uniquePieces.length / options.batchSize.clamp(1, 12)).ceil();
          final textBatches =
              (uniquePieces.fold<int>(
                        0,
                        (n, piece) => n + piece.source.runes.length,
                      ) /
                      800)
                  .ceil();
          final estimatedBatches = rowBatches > textBatches
              ? rowBatches
              : textBatches;
          var compare =
              options.acceleration == TranslationAcceleration.auto &&
              profile == null &&
              canCompareGpu &&
              calibrate &&
              resources.decision.allowTuning;
          var cpuFallback =
              options.acceleration == TranslationAcceleration.cpu ||
              (options.acceleration == TranslationAcceleration.auto &&
                  profile?.useGpuFor(estimatedBatches) != true) ||
              ((Platform.isWindows || Platform.isLinux || Platform.isMacOS) &&
                  desktopWorker == null &&
                  _loadInference == null);

          Future<void> remember(TranslationPerformanceProfile value) async {
            center.translationPerformance[model.id] = value;
            center.translationPerformance[cacheKey] = value;
            final variants =
                center.translationPerformance.entries
                    .where((entry) => entry.key.startsWith('${model.id}:'))
                    .toList()
                  ..sort(
                    (a, b) => b.value.testedAt.compareTo(a.value.testedAt),
                  );
            for (final entry in variants.skip(16)) {
              center.translationPerformance.remove(entry.key);
            }
            await center.settingsChanged();
          }

          var currentLoadMs = 0;
          var activeThreads = initialParams.numberOfThreads;
          var activePromptThreads = initialParams.numberOfThreadsBatch;
          DateTime? configuredAt;
          InferenceComputePermit? heldPermit;
          Future<T> compute<T>(
            Future<T> Function(InferenceComputePermit) action,
          ) async {
            if (heldPermit != null) return action(heldPermit!);
            return resources.run(InferenceLane.translation, (permit) async {
              heldPermit = permit;
              try {
                check();
                return await action(permit);
              } finally {
                heldPermit = null;
              }
            }, cancelSignal: cancelSignal);
          }

          String engineKey() =>
              '${model.identity}:${jsonEncode(options.toJson())}:$cpuFallback:$activeThreads:$activePromptThreads';
          Future<TranslationInference> loadGpu(String path) async {
            final routes = translationGpuRoutes(
              Platform.operatingSystem,
              backend: options.backend,
            );
            Object? lastError;
            Object? pressureError;
            for (final route in routes) {
              check();
              try {
                if (Platform.isAndroid) {
                  return await AndroidTranslationInference.load(
                    modelPath: path,
                    backend: route.name,
                    threads: activeThreads,
                    promptThreads: activePromptThreads,
                    gpuLayers: options.gpuLayers,
                    cancelSignal: cancelSignal,
                  );
                }
                if (desktopWorker != null) {
                  return await ProcessTranslationInference.load(
                    executable: desktopWorker,
                    modelPath: path,
                    backend: route.name,
                    threads: activeThreads,
                    promptThreads: activePromptThreads,
                    gpuLayers: options.gpuLayers,
                    cancelSignal: cancelSignal,
                  );
                }
                // iOS keeps the runtime's simulator-safe automatic Metal
                // choice. It cannot create a desktop-style child process.
                if (Platform.isIOS) {
                  return await NativeTranslationInference.load(
                    path,
                    localTranslationModelParams(
                      options,
                      platform: Platform.operatingSystem,
                      processors: Platform.numberOfProcessors,
                      threads: activeThreads,
                      promptThreads: activePromptThreads,
                    ),
                  );
                }
              } catch (error) {
                check();
                lastError = error;
                if (isTransientInferencePressure(error)) pressureError = error;
              }
            }
            throw pressureError ?? lastError ?? StateError('当前安装没有可用的翻译硬件加速组件');
          }

          Future<void> loadEngine() => compute((permit) async {
            check();
            activeThreads =
                (resources.preferredTranslationThreads ??
                        permit.decision.translationThreads)
                    .clamp(1, permit.threads);
            activePromptThreads =
                (resources.preferredPromptThreads ??
                        permit.decision.promptThreads)
                    .clamp(1, permit.threads);
            metrics.threads = activeThreads;
            metrics.promptThreads = activePromptThreads;
            metrics.batchLimit = resources.decision.translationBatchLimit;
            metrics.schedulingReason = resources.decision.reason;
            configuredAt = DateTime.now();
            stage = 'load';
            final loadWatch = Stopwatch()..start();
            final path = p.join(directory.path, model.files.first.name);
            await session?.select(engineKey());
            engine = session?.take(engineKey());
            if (engine == null) {
              await resources.checkAllocation(
                translationAllocationBytes(model.bytes, gpu: !cpuFallback),
                permit: heldPermit,
                modelLabel: '本地翻译模型「${model.name}」',
              );
              check();
              metrics.modelLoads++;
              onActivity?.call(
                '正在加载 ${model.name}${cpuFallback ? ' · CPU' : ''}',
              );
            } else {
              metrics.modelReuses++;
              onActivity?.call('复用已加载的 ${model.name}');
            }
            engine ??= _loadInference != null
                ? await _loadInference(
                    path,
                    localTranslationModelParams(
                      options,
                      platform: Platform.operatingSystem,
                      processors: Platform.numberOfProcessors,
                      forceCpu: cpuFallback,
                      threads: activeThreads,
                      promptThreads: activePromptThreads,
                    ),
                    !cpuFallback,
                    cancelSignal,
                  )
                : !cpuFallback
                ? await loadGpu(path)
                : await NativeTranslationInference.load(
                    path,
                    localTranslationModelParams(
                      options,
                      platform: Platform.operatingSystem,
                      processors: Platform.numberOfProcessors,
                      forceCpu: cpuFallback,
                      threads: activeThreads,
                      promptThreads: activePromptThreads,
                    ),
                  );
            currentLoadMs = loadWatch.elapsedMilliseconds;
            metrics.loadMs += currentLoadMs;
            check();
            metrics.gpuLayers = engine!.gpuLayers;
            metrics.backend = engine!.backend;
            stage = 'translate';
          });

          Future<void> fallBackToCpu([Object? cause]) async {
            check();
            if (cause != null) recordRecovery(cause);
            cpuFallback = true;
            await engine?.dispose();
            engine = null;
            onActivity?.call('GPU 无法完成推理，正在改用 CPU，已完成的字幕会保留');
            compare = false;
            if (cause == null || !isTransientInferencePressure(cause)) {
              await remember(
                TranslationPerformanceProfile(
                  signature: signature,
                  testedAt: DateTime.now(),
                  cpuMs: center.translationPerformance[model.id]?.cpuMs,
                  cpuStartupMs:
                      center.translationPerformance[model.id]?.cpuStartupMs ??
                      0,
                  gpuFailed: true,
                ),
              );
            }
            await loadEngine();
          }

          var lastGenerationTruncated = false;
          String? tuningPrompt, tuningGrammar;
          var tuningStructured = false, lastRequestMs = 0;
          bool Function(String)? tuningValidator;
          Future<TranslationGeneration> invoke(
            String prompt, {
            String? grammar,
            bool structured = false,
            bool reusePromptPrefix = true,
            void Function(String)? onDelta,
          }) async {
            check();
            metrics.requests++;
            tuningPrompt = prompt;
            tuningGrammar = grammar;
            tuningStructured = structured;
            final requestWatch = Stopwatch()..start();
            final value = await compute((permit) async {
              final next =
                  (resources.preferredTranslationThreads ??
                          permit.decision.translationThreads)
                      .clamp(1, permit.threads);
              final nextPrompt =
                  (resources.preferredPromptThreads ??
                          permit.decision.promptThreads)
                      .clamp(1, permit.threads);
              final changed =
                  next != activeThreads || nextPrompt != activePromptThreads;
              final mustReduce =
                  activeThreads > next || activePromptThreads > nextPrompt;
              if (engine != null &&
                  changed &&
                  (mustReduce ||
                      DateTime.now().difference(configuredAt!) >=
                          const Duration(seconds: 30))) {
                await engine!.dispose();
                engine = null;
                onActivity?.call('${permit.decision.reason} · 正在调整计算资源');
                await loadEngine();
              }
              return engine!.generate(
                prompt,
                grammar: grammar,
                structured: structured,
                reusePromptPrefix: reusePromptPrefix,
                onDelta: onDelta,
              );
            });
            check();
            lastRequestMs = requestWatch.elapsedMilliseconds;
            metrics.promptTokens += value.promptTokens;
            metrics.generatedTokens += value.generatedTokens;
            metrics.promptMs += value.promptMs;
            metrics.decodeMs += value.decodeMs;
            metrics.sampleMs += value.sampleMs;
            return value;
          }

          Future<String> generate(
            String instruction, {
            String? grammar,
            void Function(String)? onRow,
            bool Function(String)? valid,
          }) async {
            check();
            tuningValidator = valid;
            if (compare && grammar == null && valid != null) {
              compare = false;
              final tuning = Stopwatch()..start();
              onActivity?.call('${model.name} · 正在比较本机 CPU / GPU 速度 · CPU');
              final cpuLoadMs = currentLoadMs;
              final cpuWarm = Stopwatch()..start();
              // Warm both backends before timing; shader compilation can dwarf
              // actual decoding. Disable KV reuse so repeating the sample does
              // not turn the comparison into a prompt-cache benchmark.
              final warmCpuReply = await invoke(
                instruction,
                structured: onRow != null,
                reusePromptPrefix: false,
              );
              if (warmCpuReply.truncated || !valid(warmCpuReply.text)) {
                throw const FormatException('CPU 测速译文未通过校验');
              }
              final cpuWarmMs = cpuWarm.elapsedMilliseconds;
              final cpuWatch = Stopwatch()..start();
              final cpuReply = await invoke(
                instruction,
                structured: onRow != null,
                reusePromptPrefix: false,
              );
              final cpuMs = cpuWatch.elapsedMilliseconds.clamp(1, 1 << 31);
              final cpuStartupMs = (cpuLoadMs + cpuWarmMs - cpuMs).clamp(
                0,
                1 << 31,
              );
              var chosen = cpuReply;
              if (!cpuReply.truncated && valid(cpuReply.text)) {
                await engine?.dispose();
                engine = null;
                // A persisted fuse also covers an OS-level termination during
                // the Metal probe. Interrupted probes start safely next time.
                await remember(
                  TranslationPerformanceProfile(
                    signature: signature,
                    testedAt: DateTime.now(),
                    cpuMs: cpuMs,
                    gpuFailed: true,
                    cpuStartupMs: cpuStartupMs,
                  ),
                );
                cpuFallback = false;
                try {
                  onActivity?.call('${model.name} · 正在比较本机 CPU / GPU 速度 · GPU');
                  await loadEngine();
                  if (metrics.gpuLayers <= 0) throw StateError('GPU 不可用');
                  final gpuLoadMs = currentLoadMs;
                  final gpuWarm = Stopwatch()..start();
                  final warmGpuReply = await invoke(
                    instruction,
                    structured: onRow != null,
                    reusePromptPrefix: false,
                  );
                  if (warmGpuReply.truncated || !valid(warmGpuReply.text)) {
                    throw const FormatException('GPU 测速译文未通过校验');
                  }
                  final gpuWarmMs = gpuWarm.elapsedMilliseconds;
                  final gpuWatch = Stopwatch()..start();
                  final gpuReply = await invoke(
                    instruction,
                    structured: onRow != null,
                    reusePromptPrefix: false,
                  );
                  if (gpuReply.truncated || !valid(gpuReply.text)) {
                    throw const FormatException('GPU 译文未通过校验');
                  }
                  final gpuMs = gpuWatch.elapsedMilliseconds.clamp(1, 1 << 31);
                  final measured = TranslationPerformanceProfile(
                    signature: signature,
                    testedAt: DateTime.now(),
                    cpuMs: cpuMs,
                    gpuMs: gpuMs,
                    cpuStartupMs: cpuStartupMs,
                    gpuStartupMs: (gpuLoadMs + gpuWarmMs - gpuMs).clamp(
                      0,
                      1 << 31,
                    ),
                  );
                  await remember(measured);
                  if (measured.useGpuFor(estimatedBatches)) {
                    chosen = gpuReply;
                  } else {
                    cpuFallback = true;
                    await engine?.dispose();
                    engine = null;
                    await loadEngine();
                  }
                  onActivity?.call(measured.summary);
                } catch (error) {
                  if (cancelled || isTransientInferencePressure(error)) {
                    // A deliberate cancellation is not evidence of a bad GPU.
                    if (previousLastProfile == null) {
                      center.translationPerformance.remove(model.id);
                    } else {
                      center.translationPerformance[model.id] =
                          previousLastProfile;
                    }
                    if (previousCachedProfile == null) {
                      center.translationPerformance.remove(cacheKey);
                    } else {
                      center.translationPerformance[cacheKey] =
                          previousCachedProfile;
                    }
                    await center.settingsChanged();
                    check();
                  }
                  await fallBackToCpu(error);
                }
              }
              metrics.calibrationMs += tuning.elapsedMilliseconds;
              lastGenerationTruncated = chosen.truncated;
              if (onRow != null) {
                for (final row in const LineSplitter().convert(chosen.text)) {
                  onRow(row);
                }
              }
              if (chosen.truncated && onRow == null) {
                throw const FormatException('译文超过输出长度，已保留有效断点，请缩短字幕后重试');
              }
              return chosen.text;
            }
            var tail = '', lastActivity = 0, received = 0;
            lastGenerationTruncated = false;
            final generating = Stopwatch()..start();
            final result = await invoke(
              instruction,
              grammar: grammar,
              structured: onRow != null,
              onDelta: (delta) {
                check();
                received += delta.runes.length;
                if (onRow != null) {
                  tail += delta;
                  var newline = tail.indexOf('\n');
                  while (newline >= 0) {
                    onRow(tail.substring(0, newline));
                    tail = tail.substring(newline + 1);
                    newline = tail.indexOf('\n');
                  }
                }
                if (generating.elapsedMilliseconds - lastActivity >= 500) {
                  lastActivity = generating.elapsedMilliseconds;
                  onActivity?.call(
                    '${model.name} · ${metrics.backend} · 已完成 $done/${texts.length} 条 · 正在生成 $received 字',
                  );
                }
                // Only completed cues are dirty; avoid an asynchronous disk call
                // on every generated token. Batch/cancellation paths flush below.
              },
            );
            check();
            lastGenerationTruncated = result.truncated;
            if (onRow != null && tail.isNotEmpty) onRow(tail);
            if (result.truncated && onRow == null) {
              throw const FormatException('译文超过输出长度，已保留有效断点，请缩短字幕后重试');
            }
            return result.text;
          }

          var promptTurn = false;
          Future<void> tuneCpu() async {
            final prompt = tuningPrompt, valid = tuningValidator;
            if (options.threads != 0 ||
                !cpuFallback ||
                engine == null ||
                prompt == null ||
                valid == null ||
                !resources.decision.allowTuning) {
              return;
            }
            final tuner = promptTurn ? promptTuner : generationTuner;
            final prefill = promptTurn;
            final base = prefill ? activePromptThreads : activeThreads;
            final formalThreads = activeThreads,
                formalPrompt = activePromptThreads;
            final maximum = resources.decision.totalThreads;
            try {
              final selected = await tuner.explore(
                baseline: base,
                maximum: maximum,
                estimatedCostMs: ((lastRequestMs + currentLoadMs) * 3).clamp(
                  1000,
                  1 << 31,
                ),
                remainingProductiveMs:
                    (resources.productiveTime.inMilliseconds *
                            (texts.length - done) /
                            math.max(1, done))
                        .round(),
                probe: (candidate) => resources.run(
                  InferenceLane.tuning,
                  (permit) async {
                    final cost = Stopwatch()..start();
                    onActivity?.call('本机调优 · 校准当前设备的速度');
                    heldPermit = permit;
                    try {
                      await engine?.dispose();
                      engine = null;
                      Future<({TranslationGeneration reply, int time})> sample(
                        int threads,
                      ) async {
                        check();
                        if (!resources.decision.allowTuning) {
                          throw StateError('资源压力下停止测速');
                        }
                        await resources.checkAllocation(
                          translationAllocationBytes(model.bytes),
                          modelLabel: '本地翻译模型「${model.name}」',
                        );
                        final timing = Stopwatch()..start();
                        final params = localTranslationModelParams(
                          options,
                          platform: Platform.operatingSystem,
                          processors: Platform.numberOfProcessors,
                          forceCpu: true,
                          threads: (prefill ? formalThreads : threads).clamp(
                            1,
                            permit.threads,
                          ),
                          promptThreads: (prefill ? threads : formalPrompt)
                              .clamp(1, permit.threads),
                        );
                        final path = p.join(
                          directory.path,
                          model.files.first.name,
                        );
                        metrics.modelLoads++;
                        final temporary = _loadInference != null
                            ? await _loadInference(
                                path,
                                params,
                                false,
                                cancelSignal,
                              )
                            : await NativeTranslationInference.load(
                                path,
                                params,
                              );
                        var closed = false;
                        final unlisten = resources.governor.listen(() {
                          if (!closed && !resources.decision.allowTuning) {
                            temporary.cancel();
                          }
                        });
                        cancelSignal?.then((_) {
                          if (!closed) temporary.cancel();
                        });
                        try {
                          final value = await temporary.generate(
                            prompt,
                            grammar: tuningGrammar,
                            structured: tuningStructured,
                            reusePromptPrefix: false,
                          );
                          check();
                          return (
                            reply: value,
                            time: timing.elapsedMilliseconds.clamp(1, 1 << 31),
                          );
                        } finally {
                          closed = true;
                          unlisten();
                          await temporary.dispose();
                        }
                      }

                      final baseline = await sample(base);
                      final next = await sample(candidate);
                      // Restore before returning; no caller can observe a half-configured context.
                      await loadEngine();
                      return InferenceProbeResult(
                        baselineMs: baseline.time,
                        candidateMs: next.time,
                        costMs: cost.elapsedMilliseconds,
                        startupMs: currentLoadMs,
                        valid:
                            !baseline.reply.truncated &&
                            !next.reply.truncated &&
                            valid(baseline.reply.text) &&
                            valid(next.reply.text),
                      );
                    } finally {
                      metrics.calibrationMs += cost.elapsedMilliseconds;
                      heldPermit = null;
                    }
                  },
                  requested: math.max(
                    math.max(formalThreads, formalPrompt),
                    candidate,
                  ),
                  cancelSignal: cancelSignal,
                ),
              );
              if (selected != null) {
                if (prefill) {
                  resources.preferredPromptThreads = selected;
                } else {
                  resources.preferredTranslationThreads = selected;
                }
              }
              if (tuner.automaticCreditMs >= 1000) promptTurn = !promptTurn;
            } catch (_) {
              check();
              if (engine == null) await loadEngine();
            }
          }

          Future<String> generateSafely(
            String prompt, {
            String? grammar,
            void Function(String)? onRow,
            bool Function(String)? valid,
          }) async {
            while (true) {
              try {
                return await generate(
                  prompt,
                  grammar: grammar,
                  onRow: onRow,
                  valid: valid,
                );
              } catch (error) {
                check();
                if (error is FormatException || error is FileSystemException) {
                  rethrow;
                }
                if (!cpuFallback && metrics.gpuLayers > 0) {
                  await fallBackToCpu(error);
                } else {
                  // Restart an unusable context only once per job. Repeated
                  // runtime errors retain the checkpoint and stop explicitly.
                  if (metrics.cpuRestarts >= 1 || engine == null) rethrow;
                  recordRecovery(error);
                  metrics.cpuRestarts++;
                  compare = false;
                  cpuFallback = true;
                  onActivity?.call('本地推理发生异常，正在重新加载 CPU 模型，已完成的字幕会保留');
                  await engine!.dispose();
                  engine = null;
                  await loadEngine();
                }
              }
            }
          }

          Future<void> single(_TranslationPiece piece) async {
            currentCues = [piece.cue + 1];
            final context = contextFor(piece.cue);
            final prompt = localTranslationSinglePrompt(
              engine: model.engine,
              source: piece.source,
              targetLanguage: targetLanguage,
              targetLabel: targetLabel,
              glossary: glossary,
              hasProtectedText: _protectedTranslationText.hasMatch(
                piece.source,
              ),
            );
            for (var attempt = 0; attempt < 2; attempt++) {
              check();
              metrics.fallbackRequests++;
              try {
                final value = _complete != null
                    ? await _complete(
                        piece.source,
                        context,
                        targetLabel,
                        glossary,
                        cancelSignal,
                      )
                    : _completeBatch != null
                    ? parseLocalTranslationBatch(
                            await _completeBatch(
                              {piece.id: piece.source},
                              context,
                              targetLabel,
                              glossary,
                              cancelSignal,
                            ),
                            {piece.id},
                          )[piece.id] ??
                          ''
                    : await generateSafely(
                        attempt == 0
                            ? prompt
                            : localTranslationSingleRetryPrompt(
                                initialPrompt: prompt,
                                engine: model.engine,
                                source: piece.source,
                                targetLanguage: targetLanguage,
                                targetLabel: targetLabel,
                                glossary: glossary,
                              ),
                        valid: (value) {
                          try {
                            validateLocalTranslation(
                              piece.source,
                              normalizeLocalTranslation(piece.source, value),
                              targetLanguage: targetLanguage,
                            );
                            return true;
                          } on FormatException {
                            return false;
                          }
                        },
                      );
                check();
                accept(piece, value);
                await flush();
                if (piece.result != null) return;
              } on FormatException {
                check();
                // An invalid/truncated response must not abort later cues.
              }
            }
          }

          Future<void> batch(
            List<_TranslationPiece> group, {
            int repairLevel = 0,
          }) async {
            check();
            currentCues = group.map((p) => p.cue + 1).toSet().toList();
            stage = 'translate';
            final constrained = repairLevel >= 2;
            // Upstream documents Android Vulkan driver crashes with grammar
            // sampling. Repair on CPU instead of sending that workload to it.
            if (constrained && Platform.isAndroid && metrics.gpuLayers > 0) {
              await fallBackToCpu();
            }
            if (_complete != null || group.length == 1) {
              for (final piece in group) {
                await single(piece);
              }
              return;
            }
            metrics.batchRequests++;
            onActivity?.call(
              '${model.name} · ${metrics.backend} · 批量翻译 ${group.length} 条 · 已完成 $done/${texts.length} 条',
            );
            final inputs = {for (final piece in group) piece.id: piece.source};
            final byId = {for (final piece in group) piece.id: piece};
            void receive(String value, {bool finished = false}) {
              for (final entry in parseLocalTranslationBatch(
                value,
                inputs.keys.toSet(),
                allowMissingClosingQuote: finished && !lastGenerationTruncated,
                allowMissingClosingBracket:
                    finished && !lastGenerationTruncated,
              ).entries) {
                accept(byId[entry.key]!, entry.value);
              }
            }

            final previewIds = <int>{};
            void preview(String value) {
              final rows = parseLocalTranslationBatch(
                value,
                inputs.keys.toSet(),
              );
              for (final entry in rows.entries) {
                try {
                  validateLocalTranslation(
                    byId[entry.key]!.source,
                    normalizeLocalTranslation(
                      byId[entry.key]!.source,
                      entry.value,
                    ),
                    targetLanguage: targetLanguage,
                  );
                  previewIds.add(entry.key);
                } on FormatException {
                  continue;
                }
              }
              onActivity?.call(
                '${model.name} · ${metrics.backend} · 已完成 $done/${texts.length} 条 · 本批已生成 ${previewIds.length}/${group.length} 条',
              );
            }

            try {
              final context = contextFor(group.first.cue);
              final englishPrompt = localTranslationUsesEnglishPrompt(
                model.engine,
                targetLanguage,
              );
              final value = _completeBatch != null
                  ? await _completeBatch(
                      inputs,
                      context,
                      targetLabel,
                      glossary,
                      cancelSignal,
                    )
                  : await generateSafely(
                      localTranslationBatchPrompt(
                        texts: inputs,
                        target: englishPrompt
                            ? localTranslationEnglishTarget(
                                targetLanguage,
                                targetLabel,
                              )
                            : targetLabel,
                        english: englishPrompt,
                        context: context,
                        glossary: glossary,
                      ),
                      // Grammar sampling itself is expensive on large vocabularies.
                      // The normal path uses the model's structured-translation
                      // ability and validates all IDs before committing. Only
                      // malformed groups pay for constrained decoding on repair.
                      grammar: constrained
                          ? localTranslationBatchGrammar(inputs.keys)
                          : null,
                      onRow: constrained ? receive : preview,
                      valid: (value) {
                        final rows = parseLocalTranslationBatch(
                          value,
                          inputs.keys.toSet(),
                          allowMissingClosingBracket: true,
                        );
                        if (rows.length != inputs.length) return false;
                        try {
                          for (final entry in rows.entries) {
                            validateLocalTranslation(
                              byId[entry.key]!.source,
                              normalizeLocalTranslation(
                                byId[entry.key]!.source,
                                entry.value,
                              ),
                              targetLanguage: targetLanguage,
                            );
                          }
                          return true;
                        } on FormatException {
                          return false;
                        }
                      },
                    );
              check();
              onBatchResponse?.call(value);
              receive(value, finished: true);
            } on FormatException {
              check();
              // Context/format failures are repaired in smaller groups below.
            }
            await flush(force: true);
            final missing = group.where((p) => p.result == null).toList();
            if (missing.isEmpty) return;
            if (missing.length == 1) {
              await single(missing.single);
            } else {
              final half = (missing.length / 2).ceil();
              await batch(
                missing.take(half).toList(),
                repairLevel: repairLevel + 1,
              );
              await batch(
                missing.skip(half).toList(),
                repairLevel: repairLevel + 1,
              );
            }
          }

          try {
            if (_complete == null && _completeBatch == null) {
              try {
                await loadEngine();
              } catch (error) {
                check();
                if (cpuFallback) rethrow;
                await fallBackToCpu(error);
              }
            }
            check();
            var emptyGroups = 0;
            for (var at = 0; at < uniquePieces.length;) {
              final group = <_TranslationPiece>[];
              var runes = 0;
              while (at < uniquePieces.length &&
                  group.length <
                      options.batchSize.clamp(
                        1,
                        resources.decision.translationBatchLimit,
                      )) {
                final next = uniquePieces[at];
                final length = next.source.runes.length;
                if (group.isNotEmpty && runes + length > 800) break;
                group.add(next);
                runes += length;
                at++;
              }
              await batch(group);
              if (at < uniquePieces.length &&
                  group.every((p) => p.result != null)) {
                await tuneCpu();
              }
              // Continue the main pass even if a cue failed format validation.
              // Valid later subtitles are saved before isolated repairs run.
              final deferred = group.where((p) => p.result == null).toList();
              if (deferred.isNotEmpty) {
                metrics.deferredPieces += deferred.length;
                onActivity?.call(
                  '已完成 $done/${texts.length} 条 · ${metrics.deferredPieces} 个片段稍后补译，继续处理后续字幕',
                );
              }
              emptyGroups = deferred.length == group.length
                  ? emptyGroups + 1
                  : 0;
              if (emptyGroups >= 3) {
                throw LocalTranslationIncomplete(
                  '连续 3 批字幕均未得到有效译文，已停止以避免无效等待。'
                  '已完成 $done/${texts.length} 条，有效译文已保存；请检查模型或切换模型后重试。',
                );
              }
            }
            check();
            final deferred = uniquePieces
                .where((p) => p.result == null)
                .toList();
            for (final piece in deferred) {
              check();
              stage = 'repair';
              onActivity?.call(
                '已完成 $done/${texts.length} 条 · 正在补译第 ${piece.cue + 1} 条',
              );
              await single(piece);
              if (piece.result != null) metrics.recoveredPieces++;
            }
            final missing = cuePieces.keys
                .where((cue) => output[cue].isEmpty)
                .toList();
            if (missing.isNotEmpty) {
              currentCues = missing.take(16).map((cue) => cue + 1).toList();
              throw LocalTranslationIncomplete(
                '已完成 $done/${texts.length} 条，仍有 ${missing.length} 条字幕未通过翻译校验'
                '（第 ${currentCues.join('、')}${missing.length > 16 ? '…' : ''} 条）。'
                '有效译文已保存，重试会仅处理未完成部分。',
              );
            }
            stage = 'complete';
            return output;
          } finally {
            // Flush validated, complete cues even when cancelled in mid-batch.
            // A partial JSON row or an unfinished long cue is never checkpointed.
            try {
              await flush(force: true);
            } finally {
              final retained = engine;
              if (session != null &&
                  retained != null &&
                  !cancelled &&
                  resources.decision.retainModels) {
                await session.retain(engineKey(), retained, center, model.id);
              } else {
                await retained?.dispose();
              }
              engine = null;
            }
          }
        }),
        cancelSignal: cancelSignal,
        reservation: reservation,
      );
    } catch (error) {
      terminalError = error;
      rethrow;
    } finally {
      finished = true;
      metrics.elapsedMs = watch.elapsedMilliseconds;
      // A diagnosis failure must not replace the original translation error.
      // Record metadata only: never prompts, source text or generated replies.
      if (diagnostic != null) {
        try {
          await writeStorageJson(diagnostic!, {
            'version': 1,
            'finishedAt': DateTime.now().toUtc().toIso8601String(),
            'model': spec.profile.model,
            'platform': Platform.operatingSystem,
            'status': cancelled
                ? 'cancelled'
                : terminalError == null
                ? 'complete'
                : 'failed',
            'stage': stage,
            'completedCues': completedCues,
            'totalCues': texts.length,
            'cueNumbers': currentCues,
            if (terminalError != null && !cancelled)
              'failureCode': _failureCode(terminalError),
            if (terminalError != null && !cancelled)
              'errorType': terminalError.runtimeType.toString(),
            'recoveries': recoveryEvents,
            'metrics': metrics.toJson(),
          });
        } catch (_) {
          // The main checkpoint/error remains authoritative on a full disk.
        }
      }
      onMetrics?.call(metrics);
    }
  }
}

Future<ModelJobSpec> captureLocalTranslation(ModelCenterService center) async {
  await center.initialize();
  final model = center.artifact(center.translationModelId);
  if (model == null ||
      model.purpose != ModelPurpose.translation ||
      model.retired) {
    throw StateError('翻译模型清单缺失或已下架，请重新选择翻译模型');
  }
  return localTranslationConfiguration(center)!;
}

/// Current translation settings for comparison, without preparing a model.
ModelJobSpec? localTranslationConfiguration(ModelCenterService center) {
  final model = center.artifact(center.translationModelId);
  if (model == null || model.purpose != ModelPurpose.translation) return null;
  return ModelJobSpec(
    profile: ModelServiceProfile(
      id: 'local:${model.id}',
      name: model.name,
      kind: TranscriptionServiceKind.local,
      model: model.id,
    ),
    artifactIdentity: model.identity,
    threads: center.threads,
    translation: center.translationOptions,
  );
}

ModelParams localTranslationModelParams(
  LocalTranslationOptions options, {
  required String platform,
  required int processors,
  bool forceCpu = false,
  int? threads,
  int? promptThreads,
}) {
  final apple = platform == 'macos' || platform == 'ios';
  // Desktop/Android GPUs run in private processes, outside the player.
  // Force the in-process device to CPU, including restored GPU jobs;
  // zero GPU layers alone is not enough to prevent native module discovery.
  final cpu =
      forceCpu ||
      platform == 'windows' ||
      platform == 'linux' ||
      platform == 'macos' ||
      platform == 'android' ||
      options.acceleration == TranslationAcceleration.cpu ||
      (!apple && options.acceleration == TranslationAcceleration.auto);
  final resolvedThreads =
      threads ??
      localTranslationThreadBudget(
        requested: options.threads,
        processors: processors,
        mobile: platform == 'android' || platform == 'ios',
      );
  return ModelParams(
    contextSize: 4096,
    gpuLayers: options.gpuLayers,
    device: cpu ? ComputeDevice.cpu : ComputeDevice.auto,
    // Apple retains upstream's Metal selection and CPU simulator fallback.
    // Android Vulkan remains an explicit experimental preference.
    preferredBackend: cpu
        ? GpuBackend.cpu
        : apple
        ? GpuBackend.auto
        : GpuBackend.vulkan,
    numberOfThreads: resolvedThreads,
    numberOfThreadsBatch: promptThreads ?? resolvedThreads,
    batchSize: 256,
    // Zero retains upstream's device-specific Vulkan subgroup guard. An
    // explicit large micro-batch can produce incorrect text on Mali devices.
    microBatchSize:
        platform == 'android' &&
            !cpu &&
            options.acceleration == TranslationAcceleration.gpu
        ? 0
        : 128,
  );
}
