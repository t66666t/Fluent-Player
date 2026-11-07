import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/features/model_center/model_transcription.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/transcription_progress.dart';
import 'package:video_player_app/services/ai_subtitle_api_settings.dart';
import 'package:video_player_app/services/ai_subtitle_translator.dart';
import 'package:video_player_app/services/local_transcription_stream.dart';
import 'package:video_player_app/services/streaming_subtitle_store.dart';
import 'package:video_player_app/services/subtitle_optimization.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';

const endpoint = AiSubtitleApiSettings(
  baseUrl: 'http://localhost:11434/v1',
  model: 'test-model',
);
const optimization = SubtitleOptimizationChoice(endpoint: endpoint);
SubtitleItem cue(int index) => SubtitleItem(
  index: index,
  startTime: Duration(seconds: index),
  endTime: Duration(seconds: index + 1),
  text: '这是第 $index 条，打开设制页面。',
);
SubtitleOptimizer optimizer(void Function() called) => SubtitleOptimizer(
  client: AiSubtitleTranslator(
    complete: (_, messages) async {
      called();
      final source =
          (jsonDecode(
                    messages.firstWhere((m) => m['role'] == 'user')['content']!,
                  )
                  as Map)['字幕']
              as Map;
      return jsonEncode({
        for (final e in source.entries)
          e.key: (e.value as String).replaceAll('设制', '设置'),
      });
    },
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'completed optimization is visible before a blocked translation publishes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'optimization-progress-',
      );
      final store = await StreamingSubtitleStore.create(
        File('${directory.path}/journal.jsonl'),
        {
          'generationId': 'progress',
          'primaryPath': '${directory.path}/primary.srt',
          'secondaryPath': '${directory.path}/translated.srt',
        },
      );
      final translationEntered = Completer<void>(), release = Completer<void>();
      final progress = <SubtitleOptimizationProgress>[];
      final center = ModelCenterService();
      var calls = 0;
      final translator = SubtitleTranslationService(
        aiTranslator: AiSubtitleTranslator(
          complete: (_, messages) async {
            if (!translationEntered.isCompleted) translationEntered.complete();
            await release.future;
            final source =
                jsonDecode(
                      messages.firstWhere(
                        (m) => m['role'] == 'user',
                      )['content']!,
                    )
                    as Map;
            return jsonEncode({
              for (final key in source.keys) key: 'Translation $key',
            });
          },
        ),
      );
      final stream = LocalTranscriptionStream(
        openStore: () async => store,
        choice: const TranscriptTranslateChoice(
          enabled: true,
          direction: TranscriptTranslateDirection.auto,
          provider: SubtitleTranslateProvider.ai,
          aiOptions: AiSubtitleTranslationSettings(threadNum: 1),
          targetLanguage: 'en',
        ),
        endpoint: endpoint,
        center: center,
        translator: translator,
        optimization: optimization,
        optimizationEndpoint: endpoint,
        optimizer: optimizer(() => calls++),
        sourceTotal: 40,
        onOptimizationProgress: progress.add,
        cancelSignal: Completer<void>().future,
        checkCancelled: () {},
        onCommitted: (_, _, _) async {},
        onActivity: (_, _) {},
        onFailure: () {},
      );
      try {
        await stream.accept(
          StableAsrBatch(
            [for (var i = 1; i <= 20; i++) cue(i)],
            const Duration(seconds: 21),
            null,
          ),
        );
        await translationEntered.future;
        expect(store.primary.snapshot, isEmpty);
        expect(store.pendingOptimizations, hasLength(20));
        expect(progress.last.label, '优化 20/40 条');
        expect(progress.last.fraction, .5);
        release.complete();
        await stream.drain();
        expect(store.primary.snapshot, hasLength(20));
        expect(progress.last.processed, 20);
        expect(calls, 1);
      } finally {
        if (!release.isCompleted) release.complete();
        await stream.close();
        translator.dispose();
        center.dispose();
        await directory.delete(recursive: true);
      }
    },
  );

  for (final knownTotal in [false, true]) {
    test(
      'resume counts saved corrections once; total known=$knownTotal',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'optimization-resume-progress-',
        );
        var store = await StreamingSubtitleStore.create(
          File('${directory.path}/journal.jsonl'),
          {
            'generationId': 'resume',
            'primaryPath': '${directory.path}/primary.srt',
          },
        );
        await store.rememberOptimizations({
          1: cue(1).text.replaceAll('设制', '设置'),
        });
        store = await StreamingSubtitleStore.open(store.journal);
        final center = ModelCenterService(),
            translator = SubtitleTranslationService();
        final progress = <SubtitleOptimizationProgress>[];
        var calls = 0;
        final stream = LocalTranscriptionStream(
          openStore: () async => store,
          choice: const TranscriptTranslateChoice.off(),
          center: center,
          translator: translator,
          optimization: optimization,
          optimizationEndpoint: endpoint,
          optimizer: optimizer(() => calls++),
          sourceTotal: knownTotal ? 2 : null,
          onOptimizationProgress: progress.add,
          cancelSignal: Completer<void>().future,
          checkCancelled: () {},
          onCommitted: (_, _, _) async {},
          onActivity: (_, _) {},
          onFailure: () {},
        );
        try {
          final batch = StableAsrBatch(
            [cue(1), cue(2)],
            const Duration(seconds: 3),
            null,
          );
          await stream.accept(batch);
          await stream.drain();
          expect(progress.first.processed, 1);
          expect(progress.first.totalIsFinal, knownTotal);
          expect(
            progress.first.label,
            knownTotal ? '优化 1/2 条' : '优化 1/2 条（已识别）',
          );
          expect(progress.last.label, '优化 2/2 条');
          expect(progress.every((p) => p.processed <= p.total), isTrue);
          await stream.accept(batch);
          await stream.drain();
          expect(calls, 1);
          expect(progress.last.processed, 2);
        } finally {
          await stream.close();
          translator.dispose();
          center.dispose();
          await directory.delete(recursive: true);
        }
      },
    );
  }

  test(
    'manual file service retains optimization counts while translation waits',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'optimization-file-progress-',
      );
      final source = File('${directory.path}/source.srt');
      await source.writeAsString('1\n00:00:01,000 --> 00:00:02,000\n打开设制页面。\n');
      final entered = Completer<void>(), release = Completer<void>();
      final service = SubtitleTranslationService(
        aiTranslator: AiSubtitleTranslator(
          complete: (_, _) async {
            entered.complete();
            await release.future;
            return '{"0":"Open settings."}';
          },
        ),
      );
      final values = <double>[];
      final work = service.processSubtitleFile(
        inputPath: source.path,
        sourceLanguage: 'zh-CN',
        targetLanguage: 'en',
        provider: SubtitleTranslateProvider.ai,
        aiEndpoint: endpoint,
        optimization: optimization,
        optimizationEndpoint: endpoint,
        optimizer: optimizer(() {}),
        onProgress: values.add,
      );
      try {
        await entered.future;
        expect(service.optimizationProgress!.label, '优化 1/1 条');
        expect(service.progress, .5);
        release.complete();
        await work;
        expect(values.last, 1);
        expect(service.optimizationProgress, isNull);
      } finally {
        if (!release.isCompleted) release.complete();
        await work;
        service.dispose();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'overall allocation leaves room for optimization with or without translation',
    () {
      for (final translate in [false, true]) {
        final plan = TranscriptionProgressPlan(
          translate: translate,
          optimize: true,
        );
        expect(plan.recognition(1), .55);
        expect(plan.optimization(0), .55);
        expect(plan.optimization(.5), greaterThan(plan.recognition(1)));
        expect(plan.optimization(1), translate ? .72 : .9);
        if (translate) expect(plan.translation(0), plan.optimization(1));
      }
    },
  );
}
