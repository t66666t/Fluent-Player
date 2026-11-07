import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/inference_scheduler.dart';
import 'package:video_player_app/features/model_center/local_subtitle_translator.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/features/model_center/model_transcription.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_punctuation.dart';
import 'package:video_player_app/models/subtitle_stream.dart';
import 'package:video_player_app/models/transcription_status.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/ai_subtitle_api_settings.dart';
import 'package:video_player_app/services/ai_subtitle_translator.dart';
import 'package:video_player_app/services/cloud_translation_batches.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/streaming_subtitle_store.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/subtitle_optimization.dart';
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

List<SubtitleItem> _cues(int count) => List.generate(
  count,
  (i) => SubtitleItem(
    index: i + 1,
    startTime: Duration(seconds: i * 3),
    endTime: Duration(seconds: i * 3 + 2),
    text: 'Hello, sentence ${i + 1}.',
  ),
);

class _Asr extends ModelTranscriptionRunner {
  int calls = 0, count = 17;
  Completer<void>? gate;
  @override
  Future<List<SubtitleItem>> run({
    required ModelJobSpec spec,
    required String sourceIdentity,
    String checkpointScope = '',
    required Duration duration,
    required PrepareModelAudio prepareAudio,
    PrepareCloudAsrAudio? prepareCloudAudio,
    dynamic prepareAudioChannel,
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
    dynamic resourceSession,
  }) async {
    calls++;
    if (gate != null) {
      await Future.any([
        gate!.future,
        if (cancelSignal != null)
          cancelSignal.then((_) => throw StateError('cancelled')),
      ]);
    }
    final cues = _cues(count);
    if (count > 17) {
      for (var i = 0; i < cues.length; i++) {
        cues[i] = cues[i].copyWith(
          startTime: Duration(seconds: i),
          endTime: Duration(seconds: i + 1),
          timedSpans: const [],
        );
      }
    }
    cues[0] = cues[0].copyWith(
      timedSpans: const [
        SubtitleTimedSpan(
          textStart: 0,
          textEnd: 5,
          startTime: Duration.zero,
          endTime: Duration(seconds: 1),
        ),
      ],
    );
    return cues;
  }
}

class _Center extends ModelCenterService {
  @override
  bool get started => true;
  @override
  Future<void> initialize() async {}
  @override
  bool installed(String id) => true;
  @override
  Future<ModelJobSpec> captureTranscription() async => const ModelJobSpec(
    profile: ModelServiceProfile(
      id: 'test-authorized',
      name: 'Configured test service',
      kind: TranscriptionServiceKind.openai,
      endpoint: 'https://example.test/v1',
      model: 'test',
    ),
  );
}

class _Translation extends SubtitleTranslationService {
  bool hold = true, fail = false, partial = false;
  final calls = <List<int>>[];
  final contexts = <String>[];
  final sourceTexts = <List<String>>[];
  final sessions = <LocalTranslationSession?>[];
  final gates = <Completer<void>>[];
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
    expect(provider, SubtitleTranslateProvider.local);
    calls.add(items.map((cue) => cue.index).toList());
    contexts.add(precedingContext);
    sourceTexts.add(items.map((cue) => cue.text).toList());
    sessions.add(localSession);
    final gate = Completer<void>();
    gates.add(gate);
    if (partial) onTranslated?.call(0, '你好，第 ${items.first.index} 句。');
    if (hold) {
      await Future.any([
        gate.future,
        if (cancelSignal != null)
          cancelSignal.then((_) => throw StateError('cancelled')),
      ]);
    }
    if (fail) throw StateError('local translation failed');
    return [for (final cue in items) '你好，第 ${cue.index} 句。'];
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

  test('cloud windows bound rows, text and span without losing a long cue', () {
    final source = _cues(100);
    final batches = cloudTranslationBatches(source).toList();
    expect(batches.expand((b) => b.cues), orderedEquals(source));
    for (final batch in batches) {
      expect(batch.cues.length, inInclusiveRange(1, 8));
      expect(
        batch.processedThrough - batch.cues.first.startTime,
        lessThanOrEqualTo(const Duration(seconds: 30)),
      );
      expect(batch.retainConsumerModels, isTrue);
    }
    final long = source.first.copyWith(text: '中' * 1200);
    final bounded = cloudTranslationBatches([
      long,
      ...source.skip(1).take(10),
    ]).toList();
    expect(bounded.first.cues, [long]);
    expect(bounded.expand((b) => b.cues), hasLength(11));
    final dense = cloudTranslationBatches([
      for (final cue in source.take(10)) cue.copyWith(text: '中' * 200),
    ]).toList();
    expect(dense.first.cues, hasLength(4));
  });

  test(
    'translation journal repairs only its own suffix and restores pending validated cues',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'cloud-store-recovery-',
      );
      try {
        final cues = _cues(3);
        final primary = File(p.join(root.path, 'original.srt'));
        await primary.writeAsString(
          '\ufeff${encodeStreamingSrt(cues).replaceAll('\n', '\r\n')}',
        );
        final originalBytes = await primary.readAsBytes();
        final store = await StreamingSubtitleStore.create(
          File(p.join(root.path, 'stream.jsonl')),
          {
            'primaryPath': primary.path,
            'secondaryPath': p.join(root.path, 'translated.srt'),
            'primaryComplete': true,
          },
          completedPrimary: cues,
        );
        await store.rememberTranslations({1: '第一句', 2: '第二句'});
        await store.append([], [
          cues.first.copyWith(text: '第一句'),
        ], cues.first.endTime);
        final secondary = File(store.secondaryPath!);
        await secondary.writeAsString(
          'unfinished suffix',
          mode: FileMode.append,
        );
        var restored = await StreamingSubtitleStore.open(store.journal);
        expect(restored.primary.snapshot, hasLength(3));
        expect(restored.secondary.snapshot, hasLength(1));
        expect(restored.pendingTranslations, {2: '第二句'});
        expect(await secondary.readAsString(), isNot(contains('unfinished')));
        await secondary.delete();
        restored = await StreamingSubtitleStore.open(store.journal);
        expect(
          SubtitleParser.parse(await secondary.readAsString()),
          hasLength(1),
        );
        expect(await primary.readAsBytes(), originalBytes);
        expect(restored.through, cues.first.endTime);
      } finally {
        if (root.absolute.parent.path == Directory.systemTemp.absolute.path &&
            root.path.contains('cloud-store-recovery-')) {
          await root.delete(recursive: true);
        }
      }
    },
  );

  group(
    'cloud transcript with local translation',
    () {
      late Directory root;
      late PathProviderPlatform oldPaths;
      late _Center center;
      late _Asr asr;
      late _Translation translation;
      late TranscriptionManager manager;
      late MediaPlaybackService playback;
      late VideoItem item;
      var optimizeCalls = 0;
      final library = LibraryService();
      final settings = SettingsService();

      setUp(() async {
        SharedPreferences.setMockInitialValues({
          'batchSubtitleAutoDelete': false,
        });
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel(
                'plugins.it_nomads.com/flutter_secure_storage',
              ),
              (call) async => call.method == 'read' ? 'test' : null,
            );
        root = await Directory.systemTemp.createTemp('cloud-local-stream-');
        oldPaths = PathProviderPlatform.instance;
        PathProviderPlatform.instance = _Paths(root.path);
        settings.resetForTest();
        settings.largeDataRootPath = root.path;
        library.resetLibraryForTesting();
        await library.init();
        final audio = p.join(root.path, 'audio.m4a');
        final generated = await Process.run(await FFmpegUtils.ffmpegPath, [
          '-v',
          'error',
          '-f',
          'lavfi',
          '-i',
          'anullsrc=r=16000:cl=mono',
          '-t',
          '60',
          '-c:a',
          'aac',
          audio,
        ]);
        expect(generated.exitCode, 0);
        item = VideoItem(
          id: 'cloud',
          path: audio,
          title: 'Cloud',
          durationMs: 60000,
          lastUpdated: 1,
        );
        library.seedVideoForTesting(item);
        center = _Center()..catalog = await loadModelCatalog();
        center.subtitlePunctuation =
            SubtitlePunctuation.removeTrailingFullStopsAndCommas;
        asr = _Asr();
        translation = _Translation();
        optimizeCalls = 0;
        manager = TranscriptionManager(
          subtitleOptimizer: SubtitleOptimizer(
            client: AiSubtitleTranslator(
              complete: (_, messages) async {
                optimizeCalls++;
                final source =
                    (jsonDecode(
                              messages.firstWhere(
                                (m) => m['role'] == 'user',
                              )['content']!,
                            )
                            as Map)['字幕']
                        as Map;
                return jsonEncode({
                  for (final entry in source.entries)
                    '${entry.key}': (entry.value as String).replaceAll(
                      'Hello',
                      'Hello!',
                    ),
                });
              },
            ),
          ),
          resolveOptimizationEndpoint: (snapshot) async => snapshot,
          settings: settings,
          modelRunner: asr,
          modelCenter: center,
          translationService: translation,
        );
        await manager.initialize();
        playback = MediaPlaybackService.forTesting()
          ..debugSeedCurrentItem(item)
          ..debugAttachLibrary(library);
        playback.bindSubtitleStreams(manager);
      });

      tearDown(() async {
        await manager.shutdown();
        await playback.subtitleSelectionSavedForTest;
        playback.dispose();
        manager.dispose();
        translation.dispose();
        center.dispose();
        library.resetLibraryForTesting();
        settings.resetForTest();
        PathProviderPlatform.instance = oldPaths;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel(
                'plugins.it_nomads.com/flutter_secure_storage',
              ),
              null,
            );
        if (root.absolute.parent.path == Directory.systemTemp.absolute.path &&
            root.path.contains('cloud-local-stream-')) {
          await root.delete(recursive: true);
        }
      });

      Future<void> start() => manager.startTranscription(
        item.path,
        videoId: item.id,
        libraryService: library,
        autoStart: true,
        translateChoice: const TranscriptTranslateChoice(
          enabled: true,
          provider: SubtitleTranslateProvider.local,
          direction: TranscriptTranslateDirection.toChinese,
          aiOptions: AiSubtitleTranslationSettings(),
        ),
      );

      test(
        'public ASR batches optimize before translation and resume without recognition or optimization replay',
        () async {
          asr.count = 45;
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(
            AiSubtitleApiSettings.preferencesKey,
            jsonEncode(
              const AiSubtitleApiSettings(
                baseUrl: 'https://example.test',
                model: 'corrector',
              ).toJson(),
            ),
          );
          await const SubtitleOptimizationSettings(enabled: true).save();
          translation.fail = true;
          translation.hold = false;
          await start();
          await _until(() => !manager.isQueueRunning);
          expect(
            manager.getQueueSnapshot().single.status,
            TranscriptionStatus.error,
          );
          expect(asr.calls, 1);
          final savedCalls = optimizeCalls;
          expect(savedCalls, greaterThan(0));
          expect(
            translation.sourceTexts
                .expand((batch) => batch)
                .every((text) => text.startsWith('Hello!')),
            isTrue,
          );
          final raw = library.getVideo(item.id)!.subtitlePath!;
          expect(await File(raw).readAsString(), contains('Hello,'));
          // Changing the global default cannot change the frozen generation.
          await const SubtitleOptimizationSettings().save();
          translation.fail = false;
          manager.retryTask(
            manager.mediaKeyForVideo(item.path, videoId: item.id),
          );
          await _until(() => !manager.isQueueRunning);
          expect(
            manager.getQueueSnapshot().single.status,
            TranscriptionStatus.completed,
          );
          expect(asr.calls, 1);
          expect(optimizeCalls, 3);
          final output = manager.getGeneratedSrtPathForVideo(
            item.path,
            videoId: item.id,
          )!;
          expect(await File(output).readAsString(), contains('Hello!'));
          expect(
            SubtitleParser.parse(await File(output).readAsString()),
            hasLength(45),
          );
          expect(await File(raw).readAsString(), contains('Hello,'));
          expect(
            manager.completionMessageForVideo(item.path, videoId: item.id),
            contains('优化'),
          );
        },
      );

      test(
        'existing secondary stays until first translation, and a later manual primary keeps the streaming secondary',
        () async {
          final previous = File(p.join(root.path, 'previous.srt'))
            ..writeAsStringSync('1\n00:00:00,000 --> 00:00:04,000\nPrevious\n');
          item.secondarySubtitlePath = previous.path;
          playback.setSubtitleState(
            paths: ['/previous-primary.srt', previous.path],
            primary: _cues(1),
            secondary: _cues(1),
          );
          await start();
          await _until(
            () =>
                translation.calls.length == 1 &&
                playback.subtitles.length == 17,
          );
          expect(playback.subtitlePaths[1], previous.path);
          translation.gates.first.complete();
          await _until(
            () =>
                translation.calls.length == 2 &&
                playback.secondarySubtitles.length == 8,
          );
          final generated = playback.subtitlePaths[1];
          expect(generated, isNot(previous.path));
          final manual = File(p.join(root.path, 'manual-primary.srt'))
            ..writeAsStringSync(
              '1\n00:00:00,000 --> 00:00:04,000\nManual primary\n',
            );
          await playback.loadSubtitlePathsForCurrentItem(
            itemId: item.id,
            paths: [manual.path, generated],
          );
          await library.updateVideoSubtitles(
            item.id,
            manual.path,
            false,
            secondarySubtitlePath: generated,
          );
          translation.hold = false;
          translation.gates[1].complete();
          await _until(() => !manager.isQueueRunning);
          expect(playback.subtitlePaths, [manual.path, generated]);
          expect(playback.subtitles.single.text, 'Manual primary');
          expect(playback.secondarySubtitles, hasLength(17));
          expect(item.subtitlePath, manual.path);
        },
      );

      test(
        'automatic layout restoration does not prevent first secondary attachment',
        () async {
          await start();
          await _until(
            () =>
                translation.calls.length == 1 &&
                playback.subtitles.length == 17,
          );
          final intent = playback.subtitleIntentGenerationForTest;
          await playback.loadSubtitlePathsForCurrentItem(
            itemId: item.id,
            paths: playback.subtitlePaths,
            userInitiated: false,
          );
          expect(manager.subtitleSelectionOverridden('id:cloud'), isFalse);
          expect(playback.subtitleIntentGenerationForTest, intent);
          translation.hold = false;
          translation.gates.first.complete();
          await _until(() => !manager.isQueueRunning);
          expect(playback.secondarySubtitles, hasLength(17));
        },
      );

      test(
        'manual choice made during cloud recognition is preserved throughout local translation',
        () async {
          asr.gate = Completer<void>();
          await start();
          await _until(() => asr.calls == 1);
          final manual = File(p.join(root.path, 'manual.srt'))
            ..writeAsStringSync('1\n00:00:00,000 --> 00:00:04,000\nManual\n');
          await playback.loadSubtitlePathsForCurrentItem(
            itemId: item.id,
            paths: [manual.path],
          );
          await library.updateVideoSubtitles(item.id, manual.path, false);
          translation.hold = false;
          asr.gate!.complete();
          await _until(() => !manager.isQueueRunning);
          expect(playback.subtitlePaths, [manual.path]);
          expect(item.subtitlePath, manual.path);
          expect(
            manager.streamForVideo(item.path, videoId: item.id)!.secondaryBytes,
            greaterThan(0),
          );
        },
      );
      test(
        'manual selection during optimized public ASR remains selected',
        () async {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(AiSubtitleApiSettings.preferencesKey,
            jsonEncode(const AiSubtitleApiSettings(baseUrl: 'https://example.test', model: 'corrector').toJson()));
          await const SubtitleOptimizationSettings(enabled: true).save();
          asr.gate = Completer<void>();
          await start();
          await _until(() => asr.calls == 1);
          final manual = File(p.join(root.path, 'manual.srt'))
            ..writeAsStringSync('1\n00:00:00,000 --> 00:00:04,000\nManual\n');
          await playback.loadSubtitlePathsForCurrentItem(
            itemId: item.id,
            paths: [manual.path],
          );
          await library.updateVideoSubtitles(item.id, manual.path, false);
          translation.hold = false;
          asr.gate!.complete();
          await _until(() => !manager.isQueueRunning);
          expect(playback.subtitlePaths, [manual.path]);
          expect(item.subtitlePath, manual.path);
          expect(
            manager.streamForVideo(item.path, videoId: item.id)!.secondaryBytes,
            greaterThan(0),
          );
        },
      );
      test(
        'first completed batch attaches secondary; remaining batches retain full primary and session',
        () async {
          await start();
          await _until(
            () =>
                translation.calls.length == 1 &&
                playback.subtitles.length == 17,
          );

          final primary = playback.subtitles;
          expect(primary.first.timedSpans, hasLength(1));
          final primaryPath = playback.subtitlePaths.first;
          final originalBytes = await File(primaryPath).readAsBytes();
          expect(playback.secondarySubtitles, isEmpty);
          expect(
            manager.hasUnconsumedResultForVideo(item.path, videoId: item.id),
            isFalse,
          );
          translation.gates.first.complete();
          await _until(
            () =>
                translation.calls.length == 2 &&
                playback.secondarySubtitles.length == 8,
          );
          expect(playback.subtitlePaths, hasLength(2));
          expect(playback.subtitles.length, 17);
          expect(identical(playback.subtitles.first, primary.first), isTrue);
          expect(playback.subtitleWasAppend, isTrue);
          expect(playback.secondarySubtitles.first.text, '你好，第 1 句');
          expect(translation.contexts[1], contains('sentence 8.'));
          translation.hold = false;
          translation.gates[1].complete();
          await _until(() => !manager.isQueueRunning);
          expect(playback.secondarySubtitles.length, 17);
          expect(translation.calls.map((c) => c.length), [8, 8, 1]);
          expect(
            translation.sessions.every(
              (s) => identical(s, translation.sessions.first),
            ),
            isTrue,
          );
          expect(translation.sessions.first, isNotNull);
          expect(await File(primaryPath).readAsBytes(), originalBytes);
          expect(item.subtitlePath, primaryPath);
          expect(item.secondarySubtitlePath, playback.subtitlePaths[1]);
          expect(
            manager.streamForVideo(item.path, videoId: item.id)!.phase,
            SubtitleStreamPhase.complete,
          );
          await manager.shutdown();
          manager.dispose();
          manager = TranscriptionManager(
            settings: settings,
            modelRunner: asr,
            modelCenter: center,
            translationService: translation,
          );
          await manager.initialize();
          playback.bindSubtitleStreams(manager);
          expect(manager.streamForVideo(item.path, videoId: item.id), isNull);
          expect(
            manager.hasSubtitleStreamForVideo(item.path, videoId: item.id),
            isTrue,
          );
        },
      );

      test(
        'stop and process restart preserve primary, committed batches, partial validated cues and manual secondary',
        () async {
          await start();
          await _until(() => translation.calls.length == 1);
          translation.partial = true;
          translation.gates.first.complete();
          await _until(
            () =>
                translation.calls.length == 2 &&
                playback.secondarySubtitles.length == 8,
          );
          final primaryPath = playback.subtitlePaths.first;
          final translatedPath = playback.subtitlePaths[1];
          final manual = File(p.join(root.path, 'manual.srt'))
            ..writeAsStringSync('1\n00:00:00,000 --> 00:00:05,000\nManual\n');
          await playback.loadSubtitlePathsForCurrentItem(
            itemId: item.id,
            paths: [primaryPath, manual.path],
          );
          await library.updateVideoSubtitles(
            item.id,
            primaryPath,
            false,
            secondarySubtitlePath: manual.path,
          );
          expect(manager.pauseVideo(item.path, videoId: item.id), isTrue);
          await _until(() => !manager.isQueueRunning);
          await manager.shutdown();
          expect(
            SubtitleParser.parse(await File(translatedPath).readAsString()),
            hasLength(8),
          );
          final saved = jsonDecode(
            await File(
              p.join(root.path, 'transcription_queue_cache.json'),
            ).readAsString(),
          );
          final journal = saved['queue'][0]['streamJournal'] as String;
          final store = await StreamingSubtitleStore.open(File(journal));
          expect(store.pendingTranslations.keys, contains(9));
          manager.dispose();
          translation.hold = false;
          translation.partial = false;
          manager = TranscriptionManager(
            settings: settings,
            modelRunner: asr,
            modelCenter: center,
            translationService: translation,
          );
          await manager.initialize();
          playback.bindSubtitleStreams(manager);
          expect(manager.subtitleSelectionOverridden('id:cloud'), isTrue);
          manager.startTask('id:cloud');
          await _until(() => !manager.isQueueRunning);
          expect(asr.calls, 1);
          expect(translation.calls[2], [10, 11, 12, 13, 14, 15, 16]);
          expect(
            SubtitleParser.parse(await File(translatedPath).readAsString()),
            hasLength(17),
          );
          expect(playback.subtitlePaths, [primaryPath, manual.path]);
          expect(item.secondarySubtitlePath, manual.path);
        },
      );

      for (final beforeFirst in [true, false]) {
        test(
          'manual clear wins before completion, beforeFirst=$beforeFirst',
          () async {
            await start();
            await _until(() => translation.calls.length == 1);
            if (!beforeFirst) {
              translation.gates.first.complete();
              await _until(
                () =>
                    translation.calls.length == 2 &&
                    playback.secondarySubtitles.length == 8,
              );
            }
            await playback.loadSubtitlePathsForCurrentItem(
              itemId: item.id,
              paths: [],
            );
            await library.updateVideoSubtitles(item.id, null, false);
            translation.hold = false;
            translation.gates.last.complete();
            await _until(() => !manager.isQueueRunning);
            expect(playback.subtitlePaths, isEmpty);
            expect(item.subtitlePath, isNull);
            expect(item.secondarySubtitlePath, isNull);
            expect(
              manager.getQueueSnapshot().single.status,
              TranscriptionStatus.completed,
            );
          },
        );
      }

      test(
        'failed batch retains partial translations and retries without cloud recognition',
        () async {
          translation.partial = true;
          await start();
          await _until(() => translation.calls.length == 1);
          translation.partial = true;
          translation.fail = true;
          translation.gates.first.complete();
          await _until(() => !manager.isQueueRunning);
          expect(
            manager.getQueueSnapshot().single.status,
            TranscriptionStatus.error,
          );
          expect(
            manager.streamForVideo(item.path, videoId: item.id)!.phase,
            SubtitleStreamPhase.failed,
          );
          translation.fail = false;
          translation.hold = false;
          translation.partial = false;
          expect(manager.retryTask('id:cloud'), isTrue);
          await _until(() => !manager.isQueueRunning);
          expect(asr.calls, 1);
          expect(translation.calls[1], [2, 3, 4, 5, 6, 7, 8]);
          expect(playback.secondarySubtitles, hasLength(17));
        },
      );
    },
    skip: !FFmpegUtils.preferSystemFfmpeg,
  );
}
