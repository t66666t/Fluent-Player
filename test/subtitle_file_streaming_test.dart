import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_stream.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/ai_subtitle_api_settings.dart';
import 'package:video_player_app/services/ai_subtitle_translator.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/streaming_subtitle_store.dart';
import 'package:video_player_app/services/subtitle_optimization.dart';
import 'package:video_player_app/services/subtitle_stream_source.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';
import 'package:video_player_app/utils/subtitle_parser.dart';

const endpoint = AiSubtitleApiSettings(
  baseUrl: 'https://example.test',
  model: 'test',
);
const optimization = SubtitleOptimizationChoice(endpoint: endpoint);

List<SubtitleItem> cues() => List.generate(
  41,
  (i) => SubtitleItem(
    index: i + 1,
    startTime: Duration(seconds: i),
    endTime: Duration(seconds: i + 1),
    text: '打开设制页面，第${i + 1}条。',
  ),
);

String correct(List<Map<String, String>> messages) {
  final source =
      (jsonDecode(messages.firstWhere((m) => m['role'] == 'user')['content']!)
              as Map)['字幕']
          as Map;
  return jsonEncode({
    '修改': {
      for (final e in source.entries)
        e.key: (e.value as String).replaceAll('设制', '设置'),
    },
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final translate in [false, true]) {
    test(
      'manual processing publishes and plays the first batch while later work waits; translate=$translate',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'subtitle-file-stream-',
        );
        final input = File('${directory.path}/课程.srt');
        final original = encodeStreamingSrt(cues());
        await input.writeAsString(original);
        final release = Completer<void>();
        var calls = 0;
        final optimizer = SubtitleOptimizer(
          client: AiSubtitleTranslator(
            complete: (_, messages) async {
              if (++calls > 1) await release.future;
              return correct(messages);
            },
          ),
        );
        final service = SubtitleTranslationService(
          aiTranslator: AiSubtitleTranslator(
            complete: (_, messages) async {
              final source =
                  jsonDecode(
                        messages.firstWhere(
                          (m) => m['role'] == 'user',
                        )['content']!,
                      )
                      as Map;
              return jsonEncode({
                for (final e in source.entries) e.key: '译文${e.key}',
              });
            },
          ),
        );
        final hub = SubtitleStreamHub([service.streamSource]);
        final playback = MediaPlaybackService.forTesting();
        final mediaPath = '${directory.path}/课程.mp4';
        playback.debugSeedCurrentItem(
          VideoItem(
            id: 'lesson',
            path: mediaPath,
            title: '课程',
            durationMs: 60000,
            lastUpdated: 0,
          ),
        );
        playback.bindSubtitleStreams(hub);
        final firstBatch = service.streamSource.subtitleUpdates.firstWhere(
          (s) => s.cueCount == 20,
        );
        final committed = <int>[];
        final work = service.processSubtitleFile(
          inputPath: input.path,
          videoPath: mediaPath,
          optimization: optimization,
          optimizationEndpoint: endpoint,
          optimizer: optimizer,
          translationEnabled: translate,
          sourceLanguage: 'zh-CN',
          targetLanguage: 'en',
          provider: SubtitleTranslateProvider.ai,
          aiEndpoint: endpoint,
          onProgress: (_) {},
          onBatchCommitted: (value) async {
            committed.add(value.totalCount);
          },
        );
        try {
          final update = await firstBatch.timeout(const Duration(seconds: 10));
          expect(update.complete, isFalse);
          expect(service.isTranslating, isTrue);
          expect(update.primaryPath, contains('.优化.srt'));
          expect(update.primaryPath, isNot(contains('optimized')));
          expect(
            SubtitleParser.parse(await File(update.primaryPath).readAsString()),
            hasLength(20),
          );
          expect(committed, [20]);
          await Future<void>.delayed(const Duration(milliseconds: 300));
          expect(playback.subtitles, hasLength(20));
          expect(playback.subtitles.first.text, contains('设置'));
          expect(playback.secondarySubtitles.length, translate ? 20 : 0);
          release.complete();
          final result = await work;
          expect(result.totalCount, 41);
          expect(committed, [20, 40, 41]);
          expect(playback.subtitles, hasLength(41));
          expect(playback.secondarySubtitles.length, translate ? 41 : 0);
          expect(await input.readAsString(), original);
          expect(
            service.streamSource.streamForPath(result.outputPath)!.complete,
            isTrue,
          );
        } finally {
          if (!release.isCompleted) release.complete();
          await work;
          playback.dispose();
          hub.dispose();
          service.dispose();
          await directory.delete(recursive: true);
        }
      },
    );
  }

  test(
    'cancelled manual optimization keeps its published batch, selection and resume checkpoint',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'subtitle-file-resume-',
      );
      final input = File('${directory.path}/课程.srt');
      await input.writeAsString(encodeStreamingSrt(cues()));
      final release = Completer<void>();
      var hold = true;
      final processed = <String>[];
      final optimizer = SubtitleOptimizer(
        client: AiSubtitleTranslator(
          complete: (_, messages) async {
            final source =
                (jsonDecode(messages[1]['content']!) as Map)['字幕'] as Map;
            processed.add(source.keys.first as String);
            if (hold && source.keys.first != '1') await release.future;
            return correct(messages);
          },
        ),
      );
      final service = SubtitleTranslationService();
      final mediaPath = '${directory.path}/课程.mp4';
      final playback = MediaPlaybackService.forTesting();
      playback.debugSeedCurrentItem(
        VideoItem(
          id: 'lesson',
          path: mediaPath,
          title: '课程',
          durationMs: 60000,
          lastUpdated: 0,
        ),
      );
      playback.bindSubtitleStreams(service.streamSource);
      final firstBatch = service.streamSource.subtitleUpdates.firstWhere(
        (s) => s.cueCount == 20,
      );
      Future<SubtitleTranslationResult> run() => service.processSubtitleFile(
        inputPath: input.path,
        videoPath: mediaPath,
        optimization: optimization,
        optimizationEndpoint: endpoint,
        optimizer: optimizer,
        translationEnabled: false,
        sourceLanguage: 'zh-CN',
        targetLanguage: 'en',
        provider: SubtitleTranslateProvider.ai,
        onProgress: (_) {},
      );
      final work = run();
      final cancelled = expectLater(
        work,
        throwsA(
          anyOf(isA<AiSubtitleTranslationCancelled>(), isA<DioException>()),
        ),
      );
      try {
        final first = await firstBatch.timeout(const Duration(seconds: 10));
        final manual = File('${directory.path}/手动字幕.srt');
        await manual.writeAsString('1\n00:00:00,000 --> 00:00:01,000\n我的选择\n');
        await playback.loadSubtitlePathsForCurrentItem(
          itemId: 'lesson',
          paths: [manual.path],
        );
        await service.streamSource.stopStreamForPath(first.primaryPath);
        await cancelled;
        final paused = service.streamSource.streamForPath(first.primaryPath)!;
        expect(paused.phase, SubtitleStreamPhase.paused);
        expect(paused.cueCount, 20);
        expect(paused.autoSelectSuppressed, isTrue);
        hold = false;
        release.complete();
        final result = await run();
        expect(result.outputPath, first.primaryPath);
        expect(processed.where((key) => key == '1'), hasLength(1));
        expect(
          SubtitleParser.parse(await File(result.outputPath).readAsString()),
          hasLength(41),
        );
        expect(
          service.streamSource
              .streamForPath(result.outputPath)!
              .autoSelectSuppressed,
          isTrue,
        );
        expect(playback.subtitlePaths, [manual.path]);
        expect(playback.subtitles.single.text, '我的选择');
      } finally {
        if (!release.isCompleted) release.complete();
        await cancelled;
        playback.dispose();
        service.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}
