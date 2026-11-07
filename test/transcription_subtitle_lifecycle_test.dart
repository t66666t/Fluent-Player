import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_transcription.dart';
import 'package:video_player_app/models/managed_subtitle_asset.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_punctuation.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/ai_subtitle_translator.dart';
import 'package:video_player_app/services/ai_subtitle_api_settings.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';
import 'package:video_player_app/services/subtitle_output_preparer.dart';
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

// These tests target the completed-file lifecycle used by user-configured
// services. They must not depend on the disabled public ASR transport.
class _Center extends ModelCenterService {
  @override
  bool get started => true;
  @override
  Future<void> initialize() async {}
  @override
  ModelJobSpec get transcriptionConfiguration => const ModelJobSpec(
    profile: ModelServiceProfile(
      id: 'test-authorized',
      name: 'Configured test service',
      kind: TranscriptionServiceKind.openai,
      endpoint: 'https://example.test/v1',
      model: 'test',
    ),
  );
  @override
  Future<ModelJobSpec> captureTranscription() async =>
      transcriptionConfiguration;
}

class _Asr extends ModelTranscriptionRunner {
  _Asr({this.speech = 'Hello world'});
  final String speech;
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
  }) async => [
    SubtitleItem(
      index: 1,
      startTime: Duration.zero,
      endTime: const Duration(seconds: 1),
      text: speech,
    ),
  ];
}

class _GatePreparer extends SubtitleOutputPreparer {
  _GatePreparer(this.phase);
  final String phase;
  final entered = Completer<void>(), release = Completer<void>();
  bool blocked = false;
  Future<void> waitAt(String current) async {
    if (current != phase || blocked) return;
    blocked = true;
    entered.complete();
    await release.future;
  }

  @override
  Future<PreparedTranscriptOutput> transcript(
    List<SubtitleItem> cues,
    SubtitlePunctuation punctuation, {
    bool keepTranslationInput = false,
  }) async {
    final result = await super.transcript(
      cues,
      punctuation,
      keepTranslationInput: keepTranslationInput,
    );
    await waitAt('transcript');
    return result;
  }

  @override
  Future<String> translation(
    List<SubtitleItem> cues,
    List<String> translations,
    SubtitlePunctuation punctuation, {
    String lineEnding = '\n',
  }) async {
    final result = await super.translation(
      cues,
      translations,
      punctuation,
      lineEnding: lineEnding,
    );
    await waitAt('translation');
    return result;
  }

  @override
  Future<List<SubtitleItem>> parse(String content) async {
    final result = await super.parse(content);
    await waitAt('parse');
    return result;
  }
}

Future<void> _until(bool Function() ready) async {
  final timer = Stopwatch()..start();
  while (!ready()) {
    if (timer.elapsed > const Duration(seconds: 15)) {
      fail('Timed out waiting for transcription state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform oldPaths;
  final library = LibraryService();
  final settings = SettingsService();

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'read' ? 'test' : null,
        );
    SharedPreferences.setMockInitialValues({
      // Queue tasks capture the dedicated subtitle endpoint before invoking
      // the injected translator; chat settings alone are no longer sufficient.
      AiSubtitleApiSettings.preferencesKey: jsonEncode({
        'providerId': 'custom',
        'baseUrl': 'https://example.test/v1',
        'model': 'test',
      }),
    });
    settings.resetForTest();
    library.resetLibraryForTesting();
    root = await Directory.systemTemp.createTemp('transcript_lifecycle_');
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    settings.largeDataRootPath = root.path;
    await library.init();
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
    library.resetLibraryForTesting();
    settings.resetForTest();
    PathProviderPlatform.instance = oldPaths;
    await root.delete(recursive: true);
  });

  for (final phase in ['transcript', 'translation', 'parse']) {
    for (final remove in [false, true]) {
      test(
        'stop during $phase preparation has no late output, remove=$remove',
        () async {
          final audio = p.join(root.path, 'stopping.m4a');
          final generated = await Process.run(await FFmpegUtils.ffmpegPath, [
            '-v',
            'error',
            '-f',
            'lavfi',
            '-i',
            'anullsrc=r=16000:cl=mono',
            '-t',
            '1',
            '-c:a',
            'aac',
            audio,
          ]);
          expect(generated.exitCode, 0);
          final preparer = _GatePreparer(phase);
          final center = _Center()
            ..subtitlePunctuation = SubtitlePunctuation.removeAll;
          final translation = SubtitleTranslationService(
            outputPreparer: preparer,
            aiTranslator: AiSubtitleTranslator(
              loadSettings: () async => const AiChatSettings(
                baseUrl: 'https://example.test/v1',
                apiKey: 'test',
                model: 'test',
              ),
              delay: (_) async {},
              complete: (_, messages) async {
                final input = jsonDecode(messages.last['content']!) as Map;
                return jsonEncode({
                  for (final key in input.keys) '$key': '你好，世界。',
                });
              },
            ),
          );
          final manager = TranscriptionManager(
            settings: settings,
            modelCenter: center,
            modelRunner: _Asr(speech: 'Hello, world.'),
            translationService: translation,
            outputPreparer: preparer,
          );
          final successes = <SubtitleTranslationCompletion>[];
          translation.addCompletionCallback((completion) {
            if (completion.isSuccess) successes.add(completion);
          });
          try {
            await manager.initialize();
            await manager.startTranscription(
              audio,
              videoId: 'stop',
              autoStart: true,
              translateChoice: TranscriptTranslateChoice(
                enabled: phase != 'transcript',
                direction: TranscriptTranslateDirection.toChinese,
                provider: SubtitleTranslateProvider.ai,
                aiOptions: const AiSubtitleTranslationSettings(),
              ),
            );
            await preparer.entered.future.timeout(const Duration(seconds: 15));
            expect(
              manager.getGeneratedTranslationPathForVideo(
                audio,
                videoId: 'stop',
              ),
              isNull,
            );
            final source = manager.getGeneratedSrtPathForVideo(
              audio,
              videoId: 'stop',
            );
            Future<bool>? cancellation;
            if (remove) {
              cancellation = manager.cancelVideo(audio, videoId: 'stop');
            } else {
              expect(manager.pauseVideo(audio, videoId: 'stop'), isTrue);
            }
            expect(manager.isQueueRunning, isTrue);
            preparer.release.complete();
            await _until(() => !manager.isQueueRunning);
            if (cancellation != null) {
              expect(await cancellation, isTrue);
              expect(manager.getQueueSnapshot(), isEmpty);
              expect(manager.streamForVideo(audio, videoId: 'stop'), isNull);
            }
            expect(successes, isEmpty);
            expect(
              manager.getGeneratedTranslationPathForVideo(
                audio,
                videoId: 'stop',
              ),
              isNull,
            );
            if (phase == 'transcript') {
              expect(
                manager.getGeneratedSrtPathForVideo(audio, videoId: 'stop'),
                isNull,
              );
            } else {
              expect(source, isNotNull);
              expect(
                await File(source!).readAsString(),
                contains('Hello world'),
              );
              final siblings = Directory(
                p.dirname(source),
              ).listSync().whereType<File>();
              expect(
                siblings.where(
                  (f) => p.basename(f.path).contains('.translated.'),
                ),
                isEmpty,
              );
            }
            if (!remove) {
              expect(manager.isVideoPaused(audio, videoId: 'stop'), isTrue);
              manager.resumeVideo(audio, videoId: 'stop');
              await _until(() => !manager.isQueueRunning);
              final finalSource = manager.getGeneratedSrtPathForVideo(
                audio,
                videoId: 'stop',
              );
              expect(finalSource, isNotNull);
              expect(
                await File(finalSource!).readAsString(),
                contains('Hello world'),
              );
              if (phase != 'transcript') {
                final result = manager.getGeneratedTranslationPathForVideo(
                  audio,
                  videoId: 'stop',
                );
                expect(result, isNotNull);
                expect(await File(result!).readAsString(), contains('你好世界'));
                expect(successes, hasLength(1));
              }
            }
          } finally {
            if (!preparer.release.isCompleted) preparer.release.complete();
            await manager.shutdown();
            manager.dispose();
            translation.dispose();
            center.dispose();
          }
        },
        skip: !FFmpegUtils.preferSystemFfmpeg,
      );
    }
  }

  for (final mode in SubtitlePunctuation.values) {
    test(
      'cloud transcript and translation obey ${mode.name} with original context',
      () async {
        final withComma =
            mode == SubtitlePunctuation.removeTrailingFullStopsAndCommas;
        final rawSource = withComma ? 'Hello, world,' : 'Hello, world.';
        final rawTranslation = withComma ? '你好，世界，' : '你好，世界。';
        final audio = p.join(root.path, 'punctuation.m4a');
        final generated = await Process.run(await FFmpegUtils.ffmpegPath, [
          '-v',
          'error',
          '-f',
          'lavfi',
          '-i',
          'anullsrc=r=16000:cl=mono',
          '-t',
          '1',
          '-c:a',
          'aac',
          audio,
        ]);
        expect(generated.exitCode, 0, reason: '${generated.stderr}');
        final center = _Center()..subtitlePunctuation = mode;
        final entered = Completer<void>(), release = Completer<void>();
        var requests = 0;
        final translation = SubtitleTranslationService(
          aiTranslator: AiSubtitleTranslator(
            loadSettings: () async => const AiChatSettings(
              baseUrl: 'https://example.test/v1',
              apiKey: 'test',
              model: 'test',
            ),
            delay: (_) async {},
            complete: (_, messages) async {
              final input = jsonDecode(messages.last['content']!) as Map;
              expect(input.values, [rawSource]);
              requests++;
              if (!entered.isCompleted) entered.complete();
              await release.future;
              return jsonEncode({
                for (final key in input.keys) '$key': rawTranslation,
              });
            },
          ),
        );
        final manager = TranscriptionManager(
          settings: settings,
          modelCenter: center,
          modelRunner: _Asr(speech: rawSource),
          translationService: translation,
        );
        try {
          await manager.initialize();
          await manager.startTranscription(
            audio,
            videoId: 'punctuation',
            autoStart: true,
            translateChoice: const TranscriptTranslateChoice(
              enabled: true,
              direction: TranscriptTranslateDirection.toChinese,
              provider: SubtitleTranslateProvider.ai,
              aiOptions: AiSubtitleTranslationSettings(),
            ),
          );
          await entered.future.timeout(const Duration(seconds: 15));
          final sourcePath = manager.getGeneratedSrtPathForVideo(
            audio,
            videoId: 'punctuation',
          )!;
          final expectedSource = switch (mode) {
            SubtitlePunctuation.preserve => 'Hello, world.',
            SubtitlePunctuation.removeAll => 'Hello world',
            _ => 'Hello, world',
          };
          expect(
            SubtitleParser.parse(
              await File(sourcePath).readAsString(),
            ).single.text,
            expectedSource,
          );
          expect(
            translation.isTranslatingPathForVideo(
              inputPath: sourcePath,
              videoPath: audio,
            ),
            isTrue,
          );
          center.subtitlePunctuation = SubtitlePunctuation.preserve;
          if (mode == SubtitlePunctuation.removeAll) {
            expect(manager.pauseVideo(audio, videoId: 'punctuation'), isTrue);
            await _until(() => !manager.isQueueRunning);
            manager.resumeVideo(audio, videoId: 'punctuation');
            await _until(() => requests == 2);
          }
          release.complete();
          await _until(() => !manager.isQueueRunning);
          final output = manager.getGeneratedTranslationPathForVideo(
            audio,
            videoId: 'punctuation',
          )!;
          final expectedTranslation = switch (mode) {
            SubtitlePunctuation.preserve => '你好，世界。',
            SubtitlePunctuation.removeAll => '你好世界',
            _ => '你好，世界',
          };
          expect(
            SubtitleParser.parse(await File(output).readAsString()).single.text,
            expectedTranslation,
          );
        } finally {
          if (!release.isCompleted) release.complete();
          await manager.shutdown();
          manager.dispose();
          translation.dispose();
          center.dispose();
        }
      },
      skip: !FFmpegUtils.preferSystemFfmpeg,
    );
  }

  for (final outcome in ['success', 'failure', 'stop', 'remove']) {
    test(
      'transcript is committed before translation ($outcome)',
      () async {
        final audio = p.join(root.path, 'audio.m4a');
        final generated = await Process.run(await FFmpegUtils.ffmpegPath, [
          '-v',
          'error',
          '-f',
          'lavfi',
          '-i',
          'anullsrc=r=16000:cl=mono',
          '-t',
          '1',
          '-c:a',
          'aac',
          audio,
        ]);
        expect(generated.exitCode, 0, reason: '${generated.stderr}');
        final oldSecondary = File(p.join(root.path, 'previous.srt'))
          ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nPrevious\n');
        final item = VideoItem(
          id: 'card',
          path: audio,
          title: 'Audio',
          durationMs: 1000,
          lastUpdated: 1,
          secondarySubtitlePath: oldSecondary.path,
        );
        library.seedVideoForTesting(item);
        final entered = Completer<void>();
        final release = Completer<void>();
        final translation = SubtitleTranslationService(
          aiTranslator: AiSubtitleTranslator(
            loadSettings: () async => const AiChatSettings(
              baseUrl: 'https://example.test/v1',
              apiKey: 'test',
              model: 'test',
            ),
            delay: (_) async {},
            complete: (_, messages) async {
              if (!entered.isCompleted) entered.complete();
              await release.future;
              if (outcome == 'failure') throw StateError('translation failed');
              final input = jsonDecode(messages.last['content']!) as Map;
              return jsonEncode({for (final key in input.keys) '$key': '你好世界'});
            },
          ),
        );
        final manager = TranscriptionManager(
          settings: settings,
          modelCenter: _Center(),
          modelRunner: _Asr(),
          translationService: translation,
        );
        try {
          await manager.initialize();
          await manager.startTranscription(
            audio,
            videoId: item.id,
            libraryService: library,
            autoStart: true,
            translateChoice: const TranscriptTranslateChoice(
              enabled: true,
              direction: TranscriptTranslateDirection.toChinese,
              provider: SubtitleTranslateProvider.ai,
              aiOptions: AiSubtitleTranslationSettings(),
            ),
          );
          await entered.future.timeout(const Duration(seconds: 15));
          final primary = manager.getGeneratedSrtPathForVideo(
            audio,
            videoId: 'card',
          );
          expect(primary, isNotNull);
          expect(manager.isVideoTranslating(audio, videoId: 'card'), isTrue);
          expect(item.subtitlePath, primary);
          expect(item.localSubtitles!.values, contains(primary));
          expect(item.secondarySubtitlePath, oldSecondary.path);
          expect(await File(primary!).readAsString(), contains('Hello world'));
          expect(
            manager.consumeResultNotificationForVideo(audio, videoId: 'card'),
            isTrue,
          );
          expect(
            manager.consumeResultNotificationForVideo(audio, videoId: 'card'),
            isFalse,
          );
          final saved = jsonDecode(
            await File(p.join(root.path, 'library.json')).readAsString(),
          );
          final restored = VideoItem.fromJson(
            Map<String, dynamic>.from(saved['videos'][0]),
          );
          expect(restored.subtitlePath, primary);
          expect(restored.localSubtitles!.values, contains(primary));

          if (outcome == 'stop') {
            expect(manager.pauseVideo(audio, videoId: 'card'), isTrue);
          } else if (outcome == 'remove') {
            expect(manager.removeFromQueue('id:card'), isTrue);
          } else {
            release.complete();
          }
          await _until(() => !manager.isQueueRunning);
          expect(await File(primary).exists(), isTrue);
          expect(item.subtitlePath, primary);
          expect(item.localSubtitles!.values, contains(primary));
          if (outcome == 'success') {
            final translated = manager.getGeneratedTranslationPathForVideo(
              audio,
              videoId: 'card',
            );
            expect(translated, isNotNull);
            expect(item.secondarySubtitlePath, translated);
            expect(await File(translated!).readAsString(), contains('你好世界'));
            expect(item.managedSubtitleAssets, hasLength(2));
            expect(
              manager.consumeResultNotificationForVideo(audio, videoId: 'card'),
              isTrue,
            );
          } else {
            expect(item.secondarySubtitlePath, oldSecondary.path);
            expect(item.managedSubtitleAssets, hasLength(1));
            if (outcome == 'failure') {
              expect(
                manager.completionMessageForVideo(audio, videoId: 'card'),
                contains('翻译未成功'),
              );
            }
          }
        } finally {
          if (!release.isCompleted) release.complete();
          await manager.shutdown();
          manager.dispose();
          translation.dispose();
        }
      },
      skip: !FFmpegUtils.preferSystemFfmpeg,
    );
  }

  for (final deleteSource in [true, false]) {
    test('subtitle deletion is independent (source=$deleteSource)', () async {
      final directory = Directory(
        p.join(root.path, 'subtitles', 'tasks', 'card'),
      )..createSync(recursive: true);
      final source = File(p.join(directory.path, 'ai.srt'))
        ..writeAsStringSync('source');
      final translated = File(p.join(directory.path, 'translated.srt'))
        ..writeAsStringSync('translation');
      final words = File('${source.path}.wordtiming.json')
        ..writeAsStringSync('{}');
      final translatedWords = File('${translated.path}.wordtiming.json')
        ..writeAsStringSync('{}');
      final item = VideoItem(
        id: 'card',
        path: p.join(root.path, 'video.mp4'),
        title: 'Video',
        durationMs: 1000,
        lastUpdated: 1,
      );
      library.seedVideoForTesting(item);
      final asset = await library.registerManagedLocalSubtitle(
        'card',
        path: source.path,
        kind: ManagedSubtitleAssetKind.ai,
        displayName: 'AI 字幕',
      );
      await library.registerManagedLocalSubtitle(
        'card',
        path: translated.path,
        kind: ManagedSubtitleAssetKind.translated,
        displayName: '翻译字幕',
        sourceAssetId: asset!.assetId,
      );
      await library.updateVideoSubtitles(
        'card',
        source.path,
        false,
        secondarySubtitlePath: translated.path,
      );
      final selected = deleteSource ? source : translated;
      final remaining = deleteSource ? translated : source;
      final companion = deleteSource ? words : translatedWords;
      final paths = library.managedSubtitleDeletionPaths('card', selected.path);
      expect(paths, unorderedEquals([selected.path, companion.path]));
      for (final path in paths) {
        await File(path).delete();
      }
      await library.forgetSubtitleFiles('card', paths);
      expect(await remaining.exists(), isTrue);
      expect(await File('${remaining.path}.wordtiming.json').exists(), isTrue);
      expect(item.localSubtitles!.values, [remaining.path]);
      expect(item.managedSubtitleAssets.single.path, remaining.path);
      expect(item.subtitlePath, deleteSource ? null : source.path);
      expect(item.secondarySubtitlePath, deleteSource ? translated.path : null);
      library.resetLibraryForTesting();
      await library.init();
      final restored = library.getVideo('card')!;
      expect(restored.localSubtitles!.values, [remaining.path]);
      expect(restored.managedSubtitleAssets.single.path, remaining.path);
    });
  }
}
