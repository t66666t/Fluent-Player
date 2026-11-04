import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/asr_enhancement_options.dart';
import 'package:video_player_app/features/model_center/inference_scheduler.dart';
import 'package:video_player_app/features/model_center/inference_resource_governor.dart';
import 'package:video_player_app/features/model_center/local_subtitle_translator.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/features/model_center/model_transcription.dart';
import 'package:video_player_app/features/model_center/subtitle_segmentation.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_stream.dart';
import 'package:video_player_app/models/subtitle_punctuation.dart';
import 'package:video_player_app/models/subtitle_output_path_strategy.dart';
import 'package:video_player_app/models/transcription_status.dart';
import 'package:video_player_app/services/ai_subtitle_api_settings.dart';
import 'package:video_player_app/services/ai_subtitle_translator.dart';
import 'package:video_player_app/services/bing_subtitle_translator.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/utils/ffmpeg_utils.dart';
import 'package:video_player_app/utils/subtitle_parser.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

ModelJobSpec _spec(String model, {String language = 'auto', int threads = 2}) =>
    ModelJobSpec(
      profile: ModelServiceProfile(
        id: 'local:$model',
        name: model,
        kind: TranscriptionServiceKind.local,
        model: model,
        language: language,
      ),
      artifactIdentity: '$model@1',
      threads: threads,
      subtitleSegmentation: SubtitleSegmentationOptions.natural,
      asrEnhancements: AsrEnhancementOptions.disabled,
    );

class _Center extends ModelCenterService {
  ModelJobSpec current = _spec('first');
  Object? captureError;
  int captures = 0;
  @override
  ModelJobSpec get transcriptionConfiguration => current;
  @override
  bool get started => true;
  @override
  Future<void> initialize() async {}
  @override
  bool installed(String id) => true;
  @override
  Future<ModelJobSpec> captureTranscription() async {
    captures++;
    if (captureError case final error?) throw error;
    return current;
  }
}

class _Runner extends ModelTranscriptionRunner {
  final specs = <ModelJobSpec>[];
  final scopes = <String>[];
  final assemblyVersions = <int>[];
  String speech = 'Hello, world.';
  String ending = '.';
  bool hold = true;
  bool holdAfterBatch = false;
  bool prepareCloudInput = false, forceCloudTranscode = false;
  final cloudAudio = <CloudAsrAudio>[];
  Future<void> Function(CloudAsrAudio)? checkCloudAudio;
  Object? failureAfterBatch;
  final List<Object> transientFailures = [];
  Object cancellationFailure = StateError('cancelled');
  Completer<void>? cancellationRelease;
  bool cancellationObserved = false;
  @override
  Future<List<SubtitleItem>> run({
    required ModelJobSpec spec,
    required String sourceIdentity,
    String checkpointScope = '',
    required Duration duration,
    required PrepareModelAudio prepareAudio,
    PrepareCloudAsrAudio? prepareCloudAudio,
    Future<String> Function(
      Duration,
      Duration,
      AsrAudioChannel,
      void Function(double),
    )?
    prepareAudioChannel,
    required void Function(ModelProcessingProgress) onProgress,
    Future<void>? cancelSignal,
    Future<void> Function(StableAsrBatch)? onStableBatch,
    bool serializeConsumer = false,
    int consumerModelBytes = 0,
    int? consumerWorkingSetBytes,
    int consumerBatchSize = 8,
    int streamAssemblyVersion = 3,
    Future<void> Function()? onSessionClose,
    Future<void> Function()? onConsumerIdle,
    bool Function()? consumerHasResidentModel,
    InferenceResourceSession? resourceSession,
  }) async {
    specs.add(spec);
    scopes.add(checkpointScope);
    assemblyVersions.add(streamAssemblyVersion);
    if (prepareCloudInput) {
      final audio = await prepareCloudAudio!(Duration.zero, duration, forceCloudTranscode, (_) {});
      cloudAudio.add(audio);
      try { await checkCloudAudio?.call(audio); }
      finally { await audio.dispose(); }
    }
    if (hold) {
      await cancelSignal!;
      cancellationObserved = true;
      await cancellationRelease?.future;
      throw cancellationFailure;
    }
    final cues = [
      SubtitleItem(
        index: 1,
        startTime: Duration.zero,
        endTime: const Duration(seconds: 1),
        text: '$speech from ${spec.profile.model}$ending',
      ),
    ];
    if (onStableBatch != null) {
      await onStableBatch(StableAsrBatch(cues, duration, null));
    }
    if (failureAfterBatch case final error?) throw error;
    if (transientFailures.isNotEmpty) throw transientFailures.removeAt(0);
    if (holdAfterBatch) {
      await cancelSignal!;
      cancellationObserved = true;
      await cancellationRelease?.future;
      throw cancellationFailure;
    }
    return cues;
  }
}

class _Translation extends SubtitleTranslationService {
  final specs = <ModelJobSpec?>[];
  final scopes = <String>[];
  final providers = <SubtitleTranslateProvider>[];
  final targets = <String>[];
  final sources = <String>[];
  final smartPolicies = <SmartTranslationPolicy?>[];
  final sourceTexts = <List<String>>[];
  bool hold = true;
  Object? failure;
  @override
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
    specs.add(localSpecification);
    scopes.add(checkpointScope);
    providers.add(provider);
    targets.add(targetLanguage);
    sources.add(sourceLanguage);
    smartPolicies.add(smartPolicy);
    sourceTexts.add(items.map((cue) => cue.text).toList());
    if (hold) {
      await cancelSignal!;
      throw StateError('cancelled');
    }
    if (failure case final error?) throw error;
    final values = [for (final item in items) '译文 ${item.index}。'];
    for (var i = 0; i < values.length; i++) {
      onTranslated?.call(i, values[i]);
    }
    return values;
  }

  @override
  Future<SubtitleTranslationResult> translateSubtitleFile({
    required String inputPath,
    String? sourceText,
    SubtitlePunctuation outputPunctuation = SubtitlePunctuation.preserve,
    required String sourceLanguage,
    required String targetLanguage,
    required SubtitleTranslateProvider provider,
    required void Function(double) onProgress,
    void Function(String?)? onActivity,
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
    specs.add(localSpecification);
    scopes.add(checkpointScope);
    providers.add(provider);
    targets.add(targetLanguage);
    sources.add(sourceLanguage);
    smartPolicies.add(smartPolicy);
    if (hold) {
      await cancelSignal!;
      throw StateError('cancelled');
    }
    final output = File(
      p.join(outputDirectory!, '$outputFilePrefix.translated.srt'),
    );
    await output.writeAsString('1\n00:00:00,000 --> 00:00:01,000\n你好\n');
    return SubtitleTranslationResult(outputPath: output.path, totalCount: 1);
  }
}

Future<void> _until(bool Function() condition) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 15)) {
      fail('state did not settle');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late String audio;
  late PathProviderPlatform oldPaths;
  late _Center center;
  late _Runner runner;
  late _Translation translation;
  late TranscriptionManager manager;
  final settings = SettingsService();
  final library = LibraryService();

  setUp(() async {
    SharedPreferences.setMockInitialValues({'batchSubtitleAutoDelete': false});
    settings.resetForTest();
    root = await Directory.systemTemp.createTemp('transcription-resume-');
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    await settings.init();
    settings.largeDataRootPath = root.path;
    library.resetLibraryForTesting();
    await library.init();
    audio = p.join(root.path, 'input.wav');
    final bytes = ByteData(32044);
    void tag(int at, String value) {
      for (var i = 0; i < value.length; i++) {
        bytes.setUint8(at + i, value.codeUnitAt(i));
      }
    }

    tag(0, 'RIFF');
    bytes.setUint32(4, 32036, Endian.little);
    tag(8, 'WAVEfmt ');
    bytes.setUint32(16, 16, Endian.little);
    bytes.setUint16(20, 1, Endian.little);
    bytes.setUint16(22, 1, Endian.little);
    bytes.setUint32(24, 16000, Endian.little);
    bytes.setUint32(28, 32000, Endian.little);
    bytes.setUint16(32, 2, Endian.little);
    bytes.setUint16(34, 16, Endian.little);
    tag(36, 'data');
    bytes.setUint32(40, 32000, Endian.little);
    await File(audio).writeAsBytes(bytes.buffer.asUint8List());
    center = _Center()..catalog = await loadModelCatalog();
    runner = _Runner();
    translation = _Translation();
    manager = TranscriptionManager(
      settings: settings,
      modelCenter: center,
      modelRunner: runner,
      translationService: translation,
    );
    await manager.initialize();
  });

  tearDown(() async {
    if (manager.isProcessing) {
      manager.pauseAllTasks();
      await _until(() => !manager.isQueueRunning);
    }
    await manager.shutdown();
    manager.dispose();
    translation.dispose();
    library.resetLibraryForTesting();
    settings.resetForTest();
    PathProviderPlatform.instance = oldPaths;
    await root.delete(recursive: true);
  });

  Future<void> start({TranscriptTranslateChoice? choice}) async {
    await manager.startTranscription(
      audio,
      videoId: 'media',
      autoStart: true,
      translateChoice: choice,
    );
    await _until(() => runner.specs.isNotEmpty);
  }

  Future<void> pause() async {
    expect(manager.pauseVideo(audio, videoId: 'media'), isTrue);
    await _until(() => !manager.isQueueRunning);
    expect(manager.isVideoPaused(audio, videoId: 'media'), isTrue);
  }

  const bingChoice = TranscriptTranslateChoice(
    enabled: true,
    direction: TranscriptTranslateDirection.toChinese,
    provider: SubtitleTranslateProvider.bing,
    aiOptions: AiSubtitleTranslationSettings.defaults,
  );

  void configureCloud() {
    center.current = ModelJobSpec(profile: ModelServiceProfile(id: 'cloud', name: 'ElevenLabs',
      kind: TranscriptionServiceKind.elevenlabs, model: 'scribe_v2',
      cloudOptions: const CloudAsrOptions(),
      cloudCapabilities: cloudAsrCapabilities(CloudAsrProvider.elevenlabs, 'scribe_v2')));
  }
  Future<void> replaceWithProbedManager(void Function() probed) async {
    await manager.shutdown(); manager.dispose();
    manager = TranscriptionManager(settings: settings, modelCenter: center, modelRunner: runner,
      translationService: translation, mediaProbe: (_) async {
        probed();
        return {'streams': [{'codec_type':'audio', 'codec_name':'pcm_s16le',
          'channels':1, 'sample_rate':'16000', 'bit_rate':'256000'}],
          'format': {'duration':'1.0'}};
      });
    await manager.initialize();
  }

  test('new cloud provider publishes incrementally, reuses original audio, and resumes frozen task', () async {
    configureCloud();
    var probes = 0;
    await replaceWithProbedManager(() => probes++);
    runner..hold = false..holdAfterBatch = true..prepareCloudInput = true;
    await start(choice: const TranscriptTranslateChoice.off());
    await _until(() => manager.streamForVideo(audio, videoId: 'media')?.primary.length == 1);
    expect(runner.cloudAudio.single.path, audio);
    expect(runner.cloudAudio.single.temporary, false);
    expect(probes, 1, reason: 'Only one source metadata probe; direct upload has no output scan');
    expect(manager.isProcessing, true);
    final originalPath = manager.streamForVideo(audio, videoId: 'media')!.primaryPath;
    await pause();
    runner..holdAfterBatch = false..prepareCloudInput = false;
    center.current = const ModelJobSpec(profile: ModelServiceProfile(id: 'new', name: 'Deepgram',
      kind: TranscriptionServiceKind.deepgram, model: 'future-model'));
    manager.resumeVideo(audio, videoId: 'media');
    await _until(() => !manager.isQueueRunning);
    expect(runner.specs.last.profile.model, 'scribe_v2');
    expect(center.captures, 1);
    final state = manager.streamForVideo(audio, videoId: 'media')!;
    expect(state.primaryPath, originalPath);
    expect(state.cueCount, 1);
    expect(state.phase, SubtitleStreamPhase.complete);
    expect(await File(audio).exists(), true);
    expect(manager.getQueueSnapshot().single.status, TranscriptionStatus.completed);
  });

  test('new cloud provider uses existing transcription-with-local-translation stream exactly once', () async {
    configureCloud();
    await replaceWithProbedManager(() {});
    center.translationModelId = center.catalog.firstWhere((m) => m.purpose == ModelPurpose.translation).id;
    runner.hold = false; translation.hold = false;
    await start(choice: const TranscriptTranslateChoice(enabled: true,
      direction: TranscriptTranslateDirection.toChinese, provider: SubtitleTranslateProvider.local,
      aiOptions: AiSubtitleTranslationSettings.defaults));
    await _until(() => !manager.isQueueRunning);
    final state = manager.streamForVideo(audio, videoId: 'media')!;
    expect(state.phase, SubtitleStreamPhase.complete);
    expect(state.cueCount, 1);
    expect(translation.providers, [SubtitleTranslateProvider.local]);
    expect(translation.sourceTexts, hasLength(1));
    expect(SubtitleParser.parse(await File(state.secondaryPath!).readAsString()), hasLength(1));
    expect(manager.getQueueSnapshot().single.status, TranscriptionStatus.completed);
  });

  test('cloud MP3 preparation produces real 16 kHz mono audio without a second production probe', () async {
    configureCloud();
    var probes = 0;
    await replaceWithProbedManager(() => probes++);
    runner..hold = false..prepareCloudInput = true..forceCloudTranscode = true;
    runner.checkCloudAudio = (input) async {
      expect(input.path, endsWith('.mp3')); expect(input.temporary, true);
      final result = await Process.run('ffprobe', ['-v','quiet','-print_format','json',
        '-show_streams','-show_format',input.path]);
      expect(result.exitCode, 0);
      final info = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      final stream = (info['streams'] as List).single as Map;
      expect(stream['codec_name'], 'mp3'); expect(stream['sample_rate'], '16000');
      expect(stream['channels'], 1); expect(stream['bit_rate'], '64000');
    };
    await start(choice: const TranscriptTranslateChoice.off());
    await _until(() => !manager.isQueueRunning);
    expect(probes, 1);
    expect(runner.cloudAudio, hasLength(1));
    expect(await File(runner.cloudAudio.single.path).exists(), false);
    expect(await File(audio).exists(), true);
    expect(manager.getQueueSnapshot().single.status, TranscriptionStatus.completed);
  }, skip: !FFmpegUtils.preferSystemFfmpeg);

  test('cloud preparation preserves two seconds of silence before a delayed video audio track', () async {
    configureCloud();
    final video = p.join(root.path, 'delayed-track.mp4');
    final generated = await Process.run('ffmpeg', ['-v','error','-y','-f','lavfi','-i',
      'color=black:s=32x32:r=10:d=3','-itsoffset','2','-f','lavfi','-i',
      'sine=frequency=600:duration=1','-c:v','mpeg4','-c:a','aac',video]);
    expect(generated.exitCode, 0);
    audio = video;
    await manager.shutdown(); manager.dispose();
    var probes = 0;
    manager = TranscriptionManager(settings: settings, modelCenter: center, modelRunner: runner,
      translationService: translation, mediaProbe: (path) async {
        probes++;
        final info = await Process.run('ffprobe', ['-v','quiet','-of','json','-show_streams','-show_format',path]);
        return jsonDecode(info.stdout as String) as Map<String, dynamic>;
      });
    await manager.initialize();
    runner..hold = false..prepareCloudInput = true;
    runner.checkCloudAudio = (input) async {
      expect(input.path, endsWith('.mp3'), reason: 'A copied delayed audio track would lose its video clock');
      final decoded = await Process.run('ffmpeg', ['-v','error','-i',input.path,
        '-f','s16le','-acodec','pcm_s16le','-ac','1','-ar','16000','pipe:1'], stdoutEncoding: null);
      expect(decoded.exitCode, 0);
      final bytes = Uint8List.fromList(decoded.stdout as List<int>);
      final samples = ByteData.sublistView(bytes);
      expect(bytes.length, greaterThanOrEqualTo(3 * 32000));
      var quietPeak = 0, speechPeak = 0;
      for (var i = 0; i < 1700 * 32; i += 2) {
        final value = samples.getInt16(i, Endian.little).abs();
        if (value > quietPeak) quietPeak = value;
      }
      for (var i = 2200 * 32; i < 2800 * 32; i += 2) {
        final value = samples.getInt16(i, Endian.little).abs();
        if (value > speechPeak) speechPeak = value;
      }
      expect(quietPeak, lessThan(50)); expect(speechPeak, greaterThan(1000));
    };
    await start(choice: const TranscriptTranslateChoice.off());
    await _until(() => !manager.isQueueRunning);
    expect(probes, 1);
    expect(manager.getQueueSnapshot().single.status, TranscriptionStatus.completed);
  }, skip: !FFmpegUtils.preferSystemFfmpeg);

  for (final interruption in ['转录已取消', '本地识别：Bad state: 任务已取消']) {
    test(
      'SenseVoice with Bing recovers an unrequested native cancellation once: $interruption',
      () async {
        center.current = _spec('sensevoice-small-int8');
        runner
          ..hold = false
          ..transientFailures.add(StateError(interruption));
        translation.hold = false;
        await start(choice: bingChoice);
        await _until(() => !manager.isQueueRunning);

        expect(runner.specs, hasLength(2));
        expect(runner.scopes[1], runner.scopes[0]);
        expect(center.captures, 1);
        final state = manager.streamForVideo(audio, videoId: 'media')!;
        expect(state.phase, SubtitleStreamPhase.complete);
        expect(
          manager.getQueueSnapshot().single.status,
          TranscriptionStatus.completed,
        );
        expect(
          SubtitleParser.parse(await File(state.primaryPath).readAsString()),
          hasLength(1),
        );
        expect(
          SubtitleParser.parse(await File(state.secondaryPath!).readAsString()),
          hasLength(1),
        );
        expect(translation.providers, [SubtitleTranslateProvider.bing]);
      },
    );
  }

  test(
    'persistent internal cancellation remains a resumable failure with a clear reason',
    () async {
      center.current = _spec('sensevoice-small-int8');
      runner
        ..hold = false
        ..failureAfterBatch = StateError('转录已取消');
      translation.hold = false;
      await start(choice: bingChoice);
      await _until(() => !manager.isQueueRunning);

      expect(runner.specs, hasLength(2));
      final task = manager.getQueueSnapshot().single;
      expect(task.status, TranscriptionStatus.error);
      expect(task.statusMessage, contains('意外中断'));
      expect(task.statusMessage, isNot(contains('已取消')));
      final state = manager.streamForVideo(audio, videoId: 'media')!;
      expect(state.phase, SubtitleStreamPhase.failed);
      final path = state.primaryPath;
      runner.failureAfterBatch = null;
      expect(manager.retryVideo(audio, videoId: 'media'), isTrue);
      await _until(() => !manager.isQueueRunning);
      expect(
        manager.getQueueSnapshot().single.status,
        TranscriptionStatus.completed,
      );
      expect(
        manager.streamForVideo(audio, videoId: 'media')!.primaryPath,
        path,
      );
      expect(translation.providers, [SubtitleTranslateProvider.bing]);
    },
  );

  test(
    'an explicit pause never restarts SenseVoice with Bing automatically',
    () async {
      center.current = _spec('sensevoice-small-int8');
      runner.cancellationFailure = StateError('转录已取消');
      await start(choice: bingChoice);
      await pause();
      expect(runner.specs, hasLength(1));
      expect(manager.isVideoPaused(audio, videoId: 'media'), isTrue);
      expect(translation.providers, isEmpty);
    },
  );

  test(
    'pausing at the recovery notification prevents a second native run',
    () async {
      center.current = _spec('sensevoice-small-int8');
      runner
        ..hold = false
        ..transientFailures.add(StateError('转录已取消'));
      translation.hold = false;
      var paused = false;
      void pauseAtRecovery() {
        if (!paused && manager.statusMessage.contains('正在从已保存断点恢复')) {
          paused = true;
          manager.pauseVideo(audio, videoId: 'media');
        }
      }

      manager.addListener(pauseAtRecovery);
      addTearDown(() => manager.removeListener(pauseAtRecovery));
      await start(choice: bingChoice);
      await _until(() => !manager.isQueueRunning);
      expect(paused, isTrue);
      expect(runner.specs, hasLength(1));
      expect(manager.isVideoPaused(audio, videoId: 'media'), isTrue);
    },
  );

  test(
    'a Bing failure keeps its cause and never becomes a native cancellation retry',
    () async {
      center.current = _spec('sensevoice-small-int8');
      runner.hold = false;
      translation
        ..hold = false
        ..failure = const BingTranslationException('必应暂时限制翻译请求，请稍后继续');
      await start(choice: bingChoice);
      await _until(() => !manager.isQueueRunning);

      expect(runner.specs, hasLength(1));
      final task = manager.getQueueSnapshot().single;
      expect(task.status, TranscriptionStatus.error);
      expect(task.statusMessage, contains('必应暂时限制翻译请求'));
      expect(task.statusMessage, isNot(contains('取消')));
      expect(
        manager.streamForVideo(audio, videoId: 'media')!.phase,
        SubtitleStreamPhase.failed,
      );
      translation.failure = null;
      expect(manager.retryVideo(audio, videoId: 'media'), isTrue);
      await _until(() => !manager.isQueueRunning);
      expect(
        manager.getQueueSnapshot().single.status,
        TranscriptionStatus.completed,
      );
      expect(runner.scopes[1], runner.scopes[0]);
    },
  );

  test(
    'video hotwords freeze for resume and refresh only for a new generation',
    () async {
      center.current = ModelJobSpec.fromJson({
        ..._spec('qwen3-asr-0.6b-f16').toJson(),
        'asrEnhancements': const AsrEnhancementOptions(
          denoise: false,
          alignment: false,
          punctuation: false,
          trimSilence: false,
          review: false,
          hotwords: '旧版全局词',
        ).toJson(),
      });
      final key = manager.mediaKeyForVideo(audio, videoId: 'media');
      await manager.hotwordStore.setWords(key, '第一段的人名');
      await start(choice: const TranscriptTranslateChoice.off());
      expect(runner.specs.single.asrEnhancements!.hotwords, '第一段的人名');
      await pause();
      await manager.hotwordStore.setWords(
        manager.mediaKeyForVideo(audio, videoId: 'another'),
        '另一个视频的术语',
      );
      expect(
        manager.configurationChangedForVideo(audio, videoId: 'media'),
        isFalse,
      );
      await manager.hotwordStore.setWords(key, '修改后的人名');
      expect(
        manager.configurationChangedForVideo(audio, videoId: 'media'),
        isTrue,
      );
      manager.resumeVideo(audio, videoId: 'media');
      await _until(() => runner.specs.length == 2);
      expect(runner.specs.last.asrEnhancements!.hotwords, '第一段的人名');
      await pause();
      expect(manager.restartVideo(audio, videoId: 'media'), isTrue);
      await _until(() => runner.specs.length == 3);
      expect(runner.specs.last.asrEnhancements!.hotwords, '修改后的人名');
    },
  );

  test(
    'a second video never inherits the first video or global hotwords',
    () async {
      center.current = ModelJobSpec.fromJson({
        ..._spec('qwen3-asr-0.6b-f16').toJson(),
        'asrEnhancements': const AsrEnhancementOptions(
          denoise: false,
          alignment: false,
          punctuation: false,
          review: false,
          hotwords: '旧版全局词',
        ).toJson(),
      });
      await manager.hotwordStore.setWords(
        manager.mediaKeyForVideo(audio, videoId: 'media'),
        '只属于第一个视频',
      );
      await start(choice: const TranscriptTranslateChoice.off());
      await pause();
      await manager.startTranscription(
        audio,
        videoId: 'second',
        autoStart: true,
        translateChoice: const TranscriptTranslateChoice.off(),
      );
      await _until(() => runner.specs.length == 2);
      expect(runner.specs.last.asrEnhancements!.hotwords, isEmpty);
    },
  );

  group('local streaming generations', () {
    for (final translate in [false, true]) {
      for (final phase in ['running', 'paused', 'failed']) {
        test(
          'cancel $phase generation keeps subtitles and cannot resume: $translate',
          () async {
            runner
              ..hold = false
              ..holdAfterBatch = true;
            translation.hold = false;
            if (phase == 'failed') {
              runner.failureAfterBatch = StateError('test failure');
            }
            await start(
              choice: translate
                  ? const TranscriptTranslateChoice.automatic()
                  : const TranscriptTranslateChoice.off(),
            );
            await _until(
              () =>
                  manager
                      .streamForVideo(audio, videoId: 'media')
                      ?.primary
                      .isNotEmpty ==
                  true,
            );
            if (phase == 'paused') await pause();
            if (phase == 'failed') {
              await _until(
                () => manager.isVideoFailed(audio, videoId: 'media'),
              );
            }
            final stream = manager.streamForVideo(audio, videoId: 'media')!;
            final primary = await File(stream.primaryPath).readAsString();
            final secondary = stream.secondaryPath == null
                ? null
                : await File(stream.secondaryPath!).readAsString();
            final oldScope = runner.scopes.single;
            await manager.startTranscription(audio, videoId: 'other');

            expect(await manager.cancelVideo(audio, videoId: 'media'), isTrue);
            expect(manager.isVideoCancelling(audio, videoId: 'media'), isFalse);
            expect(manager.getQueueSnapshot().map((task) => task.mediaKey), [
              'id:other',
            ]);
            expect(manager.streamForPath(stream.primaryPath), isNull);
            expect(await File(stream.primaryPath).readAsString(), primary);
            if (secondary != null) {
              expect(
                await File(stream.secondaryPath!).readAsString(),
                secondary,
              );
            }
            manager.resumeStreamForPath(stream.primaryPath);
            expect(runner.scopes, [oldScope]);
            expect(manager.getQueueSnapshot().map((task) => task.mediaKey), [
              'id:other',
            ]);

            await manager.shutdown();
            manager.dispose();
            manager = TranscriptionManager(
              settings: settings,
              modelCenter: center,
              modelRunner: runner,
              translationService: translation,
            );
            await manager.initialize();
            expect(manager.getQueueSnapshot().map((task) => task.mediaKey), [
              'id:other',
            ]);
            expect(manager.streamForPath(stream.primaryPath), isNull);
            runner
              ..hold = true
              ..failureAfterBatch = null;
            await manager.startTranscription(
              audio,
              videoId: 'media',
              autoStart: true,
            );
            await _until(() => runner.scopes.length == 2);
            expect(runner.scopes.last, isNot(oldScope));
            expect(await File(stream.primaryPath).readAsString(), primary);
          },
        );
      }
    }

    test(
      'cancel waits for the active worker before allowing another generation',
      () async {
        runner.cancellationRelease = Completer<void>();
        addTearDown(() {
          if (!runner.cancellationRelease!.isCompleted) {
            runner.cancellationRelease!.complete();
          }
        });
        await start();
        await manager.startTranscription(
          audio,
          videoId: 'other',
          autoStart: true,
        );
        final cancelling = manager.cancelVideo(audio, videoId: 'media');
        await _until(() => runner.cancellationObserved);
        expect(manager.isVideoCancelling(audio, videoId: 'media'), isTrue);
        expect(manager.isVideoStopping(audio, videoId: 'media'), isTrue);
        expect(manager.restartVideo(audio, videoId: 'media'), isFalse);
        await manager.startTranscription(
          audio,
          videoId: 'media',
          autoStart: true,
        );
        expect(runner.scopes.length, 1);
        runner.cancellationRelease!.complete();
        expect(await cancelling, isTrue);
        expect(manager.isVideoCancelling(audio, videoId: 'media'), isFalse);
        await _until(() => runner.scopes.length == 2);
        expect(manager.isVideoRunning(audio, videoId: 'other'), isTrue);
      },
    );

    test(
      'cancel a queued task keeps the other queue entries in order',
      () async {
        for (final id in ['first', 'media', 'last']) {
          await manager.startTranscription(audio, videoId: id);
        }
        expect(await manager.cancelVideo(audio, videoId: 'media'), isTrue);
        expect(manager.getQueueSnapshot().map((task) => task.mediaKey), [
          'id:first',
          'id:last',
        ]);
        expect(runner.specs, isEmpty);
        expect(await manager.cancelVideo(audio, videoId: 'media'), isFalse);
      },
    );

    test('overall audio time advances only after paired commit', () async {
      runner
        ..hold = false
        ..holdAfterBatch = true;
      await start(choice: const TranscriptTranslateChoice.automatic());
      await _until(() => translation.specs.length == 1);
      expect(manager.localAudioProgress!.label, '已完成 00:00 / 00:01');
      expect(
        manager.getQueueSnapshot().single.audioProgress!.completed,
        Duration.zero,
      );
      await pause();
      translation.hold = false;
      manager.resumeVideo(audio, videoId: 'media');
      await _until(
        () =>
            manager.localAudioProgress?.completed == const Duration(seconds: 1),
      );
      expect(manager.localAudioProgress!.label, '已完成 00:01 / 00:01');
      expect(manager.getQueueSnapshot().single.audioProgress!.fraction, 1);
      await pause();
      translation.hold = true;
      expect(manager.restartTask('id:media'), isTrue);
      await _until(() => translation.specs.length == 3);
      expect(manager.localAudioProgress!.completed, Duration.zero);
    });
    test(
      'new tasks default to removing final commas in the saved source',
      () async {
        runner
          ..hold = false
          ..ending = '，';
        await start();
        await _until(() => !manager.isQueueRunning);
        final state = manager.streamForVideo(audio, videoId: 'media')!;
        expect(
          SubtitleParser.parse(
            await File(state.primaryPath).readAsString(),
          ).single.text,
          'Hello, world. from first',
        );
        expect(
          await File(state.primaryPath).readAsString(),
          contains('Hello, world. from first\n'),
        );
      },
    );
    for (final mode in [
      SubtitlePunctuation.removeAll,
      SubtitlePunctuation.removeTrailingFullStops,
      SubtitlePunctuation.removeTrailingFullStopsAndCommas,
    ]) {
      test(
        'punctuation is frozen across pause and app restart, including translations: $mode',
        () async {
          center.subtitlePunctuation = mode;
          runner
            ..hold = false
            ..ending = ',';
          const rawText = 'Hello, world. from first,';
          final expectedSource = switch (mode) {
            SubtitlePunctuation.removeAll => 'Hello world from first',
            SubtitlePunctuation.removeTrailingFullStopsAndCommas =>
              'Hello, world. from first',
            _ => rawText,
          };
          await start(choice: const TranscriptTranslateChoice.automatic());
          await _until(() => translation.specs.length == 1);
          await pause();
          center.subtitlePunctuation = SubtitlePunctuation.preserve;
          await manager.shutdown();
          manager.dispose();
          manager = TranscriptionManager(
            settings: settings,
            modelCenter: center,
            modelRunner: runner,
            translationService: translation,
          );
          await manager.initialize();
          translation.hold = false;
          manager.resumeVideo(audio, videoId: 'media');
          await _until(() => !manager.isQueueRunning);
          final state = manager.streamForVideo(audio, videoId: 'media')!;
          expect(
            SubtitleParser.parse(
              await File(state.primaryPath).readAsString(),
            ).single.text,
            expectedSource,
          );
          expect(
            SubtitleParser.parse(
              await File(state.secondaryPath!).readAsString(),
            ).single.text,
            '译文 1',
          );
          expect(
            translation.sourceTexts.every((cues) => cues.single == rawText),
            isTrue,
          );
          final oldPath = state.primaryPath;
          expect(manager.restartTask('id:media'), isTrue);
          await _until(() => !manager.isQueueRunning);
          final next = manager.streamForVideo(audio, videoId: 'media')!;
          expect(
            SubtitleParser.parse(
              await File(next.primaryPath).readAsString(),
            ).single.text,
            rawText,
          );
          expect(next.primaryPath, isNot(oldPath));
          expect(
            await File(oldPath).readAsString(),
            contains('$expectedSource\n'),
          );
        },
      );
    }
    test('completion observers see one completed row before the worker exits', () async {
      runner.hold = false;
      List<TranscriptionStatus>? completionRows;
      Future<TranscriptionEnqueueResult>? duplicate;
      manager.addListener(() {
        if (manager.status != TranscriptionStatus.completed || completionRows != null) return;
        completionRows = manager.getQueueSnapshot().map((task) => task.status).toList();
        duplicate = manager.startTranscription(audio, videoId: 'media', autoStart: true);
      });
      await start();
      await _until(() => !manager.isQueueRunning);
      expect(completionRows, [TranscriptionStatus.completed]);
      expect(await duplicate, TranscriptionEnqueueResult.alreadyQueued);
      expect(runner.specs, hasLength(1));
      expect(manager.getQueueSnapshot().single.status, TranscriptionStatus.completed);
    });

    test('deleting on completion never resurrects the finished row or deletes subtitles', () async {
      runner.hold = false;
      bool? removed;
      String? published;
      manager.addListener(() {
        if (manager.status != TranscriptionStatus.completed || removed != null) return;
        published = manager.getGeneratedSrtPathForVideo(audio, videoId: 'media');
        removed = false;
        removed = manager.removeFromQueue('id:media');
      });
      await start();
      await _until(() => !manager.isQueueRunning);
      expect(removed, isTrue);
      expect(manager.getQueueSnapshot(), isEmpty);
      expect(await File(published!).exists(), isTrue);
    });

    test('completed runs create a new file when the model changes', () async {
      runner.hold = false;
      await start();
      await _until(() => !manager.isQueueRunning);
      final old = manager.streamForVideo(audio, videoId: 'media')!;
      final oldText = await File(old.primaryPath).readAsString();
      center.current = _spec('second');
      await manager.startTranscription(
        audio,
        videoId: 'media',
        autoStart: true,
      );
      await _until(() => !manager.isQueueRunning);
      final next = manager.streamForVideo(audio, videoId: 'media')!;
      expect(next.generationId, isNot(old.generationId));
      expect(next.primaryPath, isNot(old.primaryPath));
      expect(await File(next.primaryPath).readAsString(), contains('second'));
      expect(await File(old.primaryPath).readAsString(), oldText);
    });
    test('resume freezes model, language, threads and run', () async {
      await start();
      expect(
        manager.configurationChangedForVideo(audio, videoId: 'media'),
        isFalse,
      );
      center.current = _spec('second', language: 'en', threads: 4);
      expect(
        manager.configurationChangedForVideo(audio, videoId: 'media'),
        isTrue,
      );
      await pause();
      manager.resumeVideo(audio, videoId: 'media');
      await _until(() => runner.specs.length == 2);
      expect(runner.specs.last.profile.model, 'first');
      expect(runner.specs.last.profile.language, 'auto');
      expect(runner.specs.last.threads, 2);
      expect(runner.scopes.last, runner.scopes.first);
      expect(runner.assemblyVersions, [3, 3]);
      expect(center.captures, 1);
      expect(
        manager
            .configurationForVideo(audio, videoId: 'media')!
            .transcription!
            .profile
            .model,
        'first',
      );
    });
    test('restart waits for cancellation and preserves queue order', () async {
      await start();
      await manager.startTranscription(audio, videoId: 'other');
      expect(manager.restartTask('id:media'), isFalse);
      manager.pauseVideo(audio, videoId: 'media');
      expect(manager.restartTask('id:media'), isFalse);
      await _until(() => !manager.isQueueRunning);
      center.current = _spec('second');
      expect(manager.restartTask('id:media'), isTrue);
      await _until(() => runner.specs.length == 2);
      expect(runner.specs.last.profile.model, 'second');
      expect(runner.scopes.last, isNot(runner.scopes.first));
      expect(
        manager.configurationChangedForVideo(audio, videoId: 'media'),
        isFalse,
      );
      expect(manager.getQueueSnapshot().map((t) => t.mediaKey), [
        'id:media',
        'id:other',
      ]);
      expect(manager.isTaskStarted('id:other'), isFalse);
    });
    test(
      'saved online configurations survive continuing and persistence',
      () async {
        await manager.shutdown();
        manager.dispose();
        const savedSpec = ModelJobSpec(
          profile: ModelServiceProfile(
            id: 'original-online',
            name: '原转录接口',
            kind: TranscriptionServiceKind.openai,
            endpoint: 'https://original.invalid',
            model: 'original-model',
            language: 'ja',
          ),
        );
        await File(
          p.join(root.path, 'transcription_queue_cache.json'),
        ).writeAsString(
          jsonEncode({
            'queue': [
              {
                'videoPath': audio,
                'videoId': 'media',
                'mediaKey': 'id:media',
                'modelSpec': savedSpec.toJson(),
                'translateFrozen': true,
                'translateEnabled': false,
                'subtitlePunctuation': SubtitlePunctuation.defaultValue.name,
              },
            ],
            'taskOrder': ['id:media'],
          }),
        );
        manager = TranscriptionManager(
          settings: settings,
          modelCenter: center,
          modelRunner: runner,
          translationService: translation,
        );
        await manager.initialize();
        center.current = _spec('new-local');
        manager.resumeVideo(
          audio,
          videoId: 'media',
          translateChoice: const TranscriptTranslateChoice.automatic(),
        );
        manager.pauseVideo(audio, videoId: 'media');
        await _until(() => !manager.isQueueRunning);
        final saved = manager.configurationForVideo(audio, videoId: 'media')!;
        expect(saved.transcription!.fingerprint, savedSpec.fingerprint);
        expect(saved.translation.enabled, isFalse);
        expect(center.captures, 0);
        await manager.shutdown();
        manager.dispose();
        manager = TranscriptionManager(
          settings: settings,
          modelCenter: center,
          modelRunner: runner,
          translationService: translation,
        );
        await manager.initialize();
        expect(
          manager
              .configurationForVideo(audio, videoId: 'media')!
              .transcription!
              .fingerprint,
          savedSpec.fingerprint,
        );
      },
    );
    test(
      'a queued task without a captured model adopts settings on its first run',
      () async {
        await manager.startTranscription(
          audio,
          videoId: 'media',
          translateChoice: const TranscriptTranslateChoice.off(),
        );
        await manager.shutdown();
        manager.dispose();
        manager = TranscriptionManager(
          settings: settings,
          modelCenter: center,
          modelRunner: runner,
          translationService: translation,
        );
        await manager.initialize();
        expect(
          manager.configurationForVideo(audio, videoId: 'media')!.transcription,
          isNull,
        );
        center.current = _spec('first-start');
        manager.resumeVideo(audio, videoId: 'media');
        await _until(() => runner.specs.isNotEmpty);
        expect(runner.specs.single.profile.model, 'first-start');
        expect(center.captures, 1);
      },
    );
    test('missing model on a new run fails explicitly and can retry', () async {
      await start();
      await pause();
      center.captureError = StateError('请先下载新模型');
      expect(manager.restartTask('id:media'), isTrue);
      await _until(() => !manager.isQueueRunning);
      expect(runner.specs, hasLength(1));
      expect(
        manager.getQueueSnapshot().single.status,
        TranscriptionStatus.error,
      );
      center.captureError = null;
      center.current = _spec('second');
      expect(manager.retryVideo(audio, videoId: 'media'), isTrue);
      await _until(() => runner.specs.length == 2);
      expect(runner.specs.last.profile.model, 'second');
      expect(runner.scopes.last, isNot(runner.scopes.first));
    });
    test(
      'explicit translation languages survive pausing and app restart',
      () async {
        runner.hold = false;
        await start(
          choice: const TranscriptTranslateChoice(
            enabled: true,
            direction: TranscriptTranslateDirection.auto,
            provider: SubtitleTranslateProvider.bing,
            aiOptions: AiSubtitleTranslationSettings.defaults,
            sourceLanguage: 'ja',
            targetLanguage: 'en',
          ),
        );
        await _until(() => translation.sources.isNotEmpty);
        expect(translation.sources.single, 'ja');
        expect(translation.targets.single, 'en');
        await pause();
        await manager.shutdown();
        manager.dispose();
        final cache =
            jsonDecode(
                  await File(
                    p.join(root.path, 'transcription_queue_cache.json'),
                  ).readAsString(),
                )
                as Map;
        final saved = (cache['queue'] as List).single as Map;
        expect(saved['translateSourceLanguage'], 'ja');
        expect(saved['translateTargetLanguage'], 'en');
        manager = TranscriptionManager(
          settings: settings,
          modelCenter: center,
          modelRunner: runner,
          translationService: translation,
        );
        await manager.initialize();
        translation.hold = false;
        manager.resumeVideo(audio, videoId: 'media');
        await _until(() => !manager.isQueueRunning);
        expect(translation.sources, ['ja', 'ja']);
        expect(translation.targets, ['en', 'en']);
        final state = manager.streamForVideo(audio, videoId: 'media')!;
        expect(state.phase, SubtitleStreamPhase.complete);
      },
    );
    test(
      'smart rules stay frozen across pause, restart, and a different resume selection',
      () async {
        runner.hold = false;
        const smart = SmartTranslationPolicy(
          rules: [
            SmartTranslationRule(source: 'zh-CN', target: 'en'),
            SmartTranslationRule(source: 'ja', target: 'ko'),
          ],
          otherTarget: 'fr',
          keepUncertain: false,
        );
        await start(
          choice: const TranscriptTranslateChoice(
            enabled: true,
            direction: TranscriptTranslateDirection.auto,
            provider: SubtitleTranslateProvider.bing,
            aiOptions: AiSubtitleTranslationSettings.defaults,
            sourceLanguage: 'auto',
            targetLanguage: 'mul',
            smartPolicy: smart,
          ),
        );
        await _until(() => translation.smartPolicies.isNotEmpty);
        expect(translation.smartPolicies.single!.toJson(), smart.toJson());
        await pause();
        await manager.shutdown();
        manager.dispose();
        final saved =
            jsonDecode(
                  await File(
                    p.join(root.path, 'transcription_queue_cache.json'),
                  ).readAsString(),
                )
                as Map;
        expect(
          (saved['queue'] as List).single['translateSmartPolicy'],
          smart.toJson(),
        );
        manager = TranscriptionManager(
          settings: settings,
          modelCenter: center,
          modelRunner: runner,
          translationService: translation,
        );
        await manager.initialize();
        translation.hold = false;
        manager.resumeVideo(
          audio,
          videoId: 'media',
          translateChoice: const TranscriptTranslateChoice(
            enabled: true,
            direction: TranscriptTranslateDirection.auto,
            provider: SubtitleTranslateProvider.bing,
            aiOptions: AiSubtitleTranslationSettings.defaults,
            sourceLanguage: 'auto',
            targetLanguage: 'mul',
            smartPolicy: SmartTranslationPolicy(otherTarget: 'de'),
          ),
        );
        await _until(() => !manager.isQueueRunning);
        expect(translation.smartPolicies.map((policy) => policy!.toJson()), [
          smart.toJson(),
          smart.toJson(),
        ]);
        expect(translation.targets, ['mul', 'mul']);
        expect(
          manager.streamForVideo(audio, videoId: 'media')!.phase,
          SubtitleStreamPhase.complete,
        );
      },
    );
    test('restart of the app retains frozen local configuration', () async {
      await start();
      await pause();
      final scope = runner.scopes.single;
      await manager.shutdown();
      manager.dispose();
      center.current = _spec('second');
      manager = TranscriptionManager(
        settings: settings,
        modelCenter: center,
        modelRunner: runner,
        translationService: translation,
      );
      await manager.initialize();
      expect(manager.isQueueRunning, isFalse);
      manager.startAllTasks();
      await _until(() => runner.specs.length == 2);
      expect(runner.specs.last.profile.model, 'first');
      expect(runner.scopes.last, scope);
      expect(runner.assemblyVersions, [3, 3]);
    });
    test(
      'old streaming generations freeze assembly until regeneration',
      () async {
        await start();
        await pause();
        final originalScope = runner.scopes.single;
        await manager.shutdown();
        manager.dispose();
        final cache = File(p.join(root.path, 'transcription_queue_cache.json'));
        final data = jsonDecode(await cache.readAsString()) as Map;
        for (final job in data['queue'] as List) {
          (job as Map).remove('streamAssemblyVersion');
          job.remove('subtitlePunctuation');
        }
        await cache.writeAsString(jsonEncode(data));
        manager = TranscriptionManager(
          settings: settings,
          modelCenter: center,
          modelRunner: runner,
          translationService: translation,
        );
        await manager.initialize();
        center.subtitlePunctuation = SubtitlePunctuation.removeAll;
        manager.resumeVideo(audio, videoId: 'media');
        await _until(() => runner.specs.length == 2);
        expect(runner.assemblyVersions.last, 1);
        expect(runner.scopes.last, originalScope);
        await pause();
        await manager.shutdown();
        final saved = jsonDecode(await cache.readAsString()) as Map;
        expect(
          (saved['queue'] as List).single['subtitlePunctuation'],
          'preserve',
        );
        expect(manager.restartTask('id:media'), isTrue);
        await _until(() => runner.specs.length == 3);
        expect(runner.assemblyVersions.last, 3);
        expect(runner.scopes.last, isNot(originalScope));
      },
    );
    test('a fresh run preserves published subtitle files', () async {
      runner.hold = false;
      await start();
      await _until(() => !manager.isQueueRunning);
      final path = manager.getGeneratedSrtPathForVideo(
        audio,
        videoId: 'media',
      )!;
      final original = await File(path).readAsString();
      runner.hold = true;
      center.current = _spec('second');
      await manager.startTranscription(
        audio,
        videoId: 'media',
        autoStart: true,
      );
      await _until(() => runner.specs.length == 2);
      expect(runner.scopes.last, isNot(runner.scopes.first));
      expect(await File(path).readAsString(), original);
    });
    test('legacy persisted jobs adopt settings once and can restart', () async {
      await manager.shutdown();
      manager.dispose();
      await File(
        p.join(root.path, 'transcription_queue_cache.json'),
      ).writeAsString(
        jsonEncode({
          'queue': [
            {
              'videoPath': audio,
              'videoId': 'media',
              'mediaKey': 'id:media',
              'modelSpec': _spec('retired').toJson(),
            },
          ],
        }),
      );
      manager = TranscriptionManager(
        settings: settings,
        modelCenter: center,
        modelRunner: runner,
      );
      await manager.initialize();
      manager.resumeVideo(audio, videoId: 'media');
      await _until(() => runner.specs.length == 1);
      expect(runner.specs.single.profile.model, 'first');
      expect(runner.scopes.single, isEmpty);
      await pause();
      expect(manager.restartVideo(audio, videoId: 'media'), isTrue);
      await _until(() => runner.specs.length == 2);
      expect(runner.scopes.last, isNotEmpty);
    });
    test(
      'only paired results publish and translation intent stays frozen',
      () async {
        runner.hold = false;
        await start(choice: const TranscriptTranslateChoice.automatic());
        await _until(() => translation.specs.length == 1);
        final state = manager.streamForVideo(audio, videoId: 'media')!;
        expect(state.primary, isEmpty);
        expect(await File(state.primaryPath).length(), 0);
        expect(await File(state.secondaryPath!).length(), 0);
        await pause();
        translation.hold = false;
        center.current = _spec('second');
        manager.resumeVideo(
          audio,
          videoId: 'media',
          translateChoice: const TranscriptTranslateChoice.off(),
        );
        await _until(() => !manager.isQueueRunning);
        final done = manager.streamForVideo(audio, videoId: 'media')!;
        expect(done.complete, isTrue);
        expect(done.cueCount, 1);
        expect(await File(done.primaryPath).readAsString(), contains('Hello'));
        expect(await File(done.secondaryPath!).readAsString(), contains('译文'));
        expect(runner.specs.last.profile.model, 'first');
        expect(translation.scopes.last, translation.scopes.first);
        expect(translation.providers.last, SubtitleTranslateProvider.bing);
      },
    );
    test('changed source requires a new generation', () async {
      runner.hold = false;
      await start(choice: const TranscriptTranslateChoice.automatic());
      await _until(() => translation.specs.length == 1);
      await pause();
      await File(
        audio,
      ).setLastModified(DateTime.now().add(const Duration(seconds: 10)));
      manager.resumeVideo(audio, videoId: 'media');
      await _until(() => !manager.isQueueRunning);
      expect(manager.isVideoFailed(audio, videoId: 'media'), isTrue);
      expect(translation.specs, hasLength(1));
      translation.hold = false;
      expect(manager.restartTask('id:media'), isTrue);
      await _until(() => !manager.isQueueRunning);
      expect(manager.streamForVideo(audio, videoId: 'media')!.complete, isTrue);
    });
    test(
      'external resume keeps its allocated directory despite preference changes',
      () async {
        runner.hold = false;
        await manager.startExternalTranscription(
          audio,
          outputPathStrategy: SubtitleOutputPathStrategy.sameAsVideo,
        );
        final key = manager.getQueueSnapshot().single.mediaKey;
        manager.startTask(
          key,
          translateIfUnfrozen: const TranscriptTranslateChoice.automatic(),
        );
        await _until(() => translation.specs.length == 1);
        final path = manager.streamForVideo(audio)!.primaryPath;
        manager.pauseTask(key);
        await _until(() => !manager.isQueueRunning);
        final directory = Directory(p.join(root.path, 'new-output'));
        await settings.updateBatchSubtitleOutputLocation(
          SubtitleOutputPathStrategy.customDirectory,
          customOutputDir: directory.path,
        );
        translation.hold = false;
        manager.startTask(key);
        await _until(() => !manager.isQueueRunning);
        expect(manager.streamForVideo(audio)!.primaryPath, path);
        expect(await directory.exists(), isFalse);
        expect(manager.streamForVideo(audio)!.complete, isTrue);
      },
    );
  }, skip: !FFmpegUtils.preferSystemFfmpeg);
}
