import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/asr_execution_plan.dart';
import 'package:video_player_app/features/model_center/bounded_model_pipeline.dart';
import 'package:video_player_app/features/model_center/device_resource_snapshot.dart';
import 'package:video_player_app/features/model_center/inference_resource_governor.dart';
import 'package:video_player_app/features/model_center/local_subtitle_translator.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/features/model_center/model_device_info.dart';
import 'package:video_player_app/features/model_center/translation_memory.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/ai_subtitle_api_settings.dart';
import 'package:video_player_app/services/smart_subtitle_translator.dart';
import 'package:video_player_app/services/subtitle_language_identifier.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';
import 'package:video_player_app/services/transcription_reliability.dart';

class _UnexpectedLanguage extends SubtitleLanguageIdentifier {
  @override
  SubtitleLanguageGuess identify(String text, {String context = ''}) =>
      text.startsWith('Unexpected')
      ? const SubtitleLanguageGuess('af', true)
      : super.identify(text, context: context);
}

class _ReadyModels extends ModelCenterService {
  @override
  Future<void> initialize() async {}
  @override
  bool installed(String id) => true;
}

SubtitleItem _cue(int index, String text) => SubtitleItem(
  index: index,
  startTime: Duration(seconds: index),
  endTime: Duration(seconds: index + 1),
  text: text,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const gib = 1073741824;

  test(
    'new providers and models default to smart; explicit fixed mode survives restart',
    () async {
      SharedPreferences.setMockInitialValues({});
      final center = _ReadyModels()..catalog = await loadModelCatalog();
      final settings = SubtitleTranslateSettings(
        modelCenter: center,
        readApiSettings: () async => const AiSubtitleApiSettings(
          baseUrl: 'https://translate.example/v1',
          model: 'test',
        ),
      );
      addTearDown(center.dispose);
      addTearDown(settings.dispose);
      for (final provider in SubtitleTranslateProvider.values) {
        await settings.setProviderEnZh(provider);
        expect(settings.mode, SubtitleTranslationMode.smart);
        final choice = await TranscriptTranslateChoice.capture(
          settings,
          enabled: true,
        );
        expect(choice.smartPolicy, isNotNull);
      }
      center.translationModelId = 'qwen3-4b-q4';
      await settings.refreshBinding();
      expect(settings.mode, SubtitleTranslationMode.smart);
      await settings.setMode(SubtitleTranslationMode.fixed);
      await settings.setLanguages(target: 'ja');
      final restored = SubtitleTranslateSettings(modelCenter: center);
      addTearDown(restored.dispose);
      await restored.ensureLoaded();
      expect(restored.mode, SubtitleTranslationMode.fixed);
      expect(restored.targetLanguage, 'ja');
      expect(
        SubtitleTranslationPair.fromJson({}).mode,
        SubtitleTranslationMode.smart,
      );
      expect(
        SubtitleTranslationPair.fromJson({'mode': 'fixed'}).mode,
        SubtitleTranslationMode.fixed,
      );
    },
  );

  for (final keepUncertain in [true, false]) {
    test(
      'unsupported detection keeps only that fragment and completes later cues: $keepUncertain',
      () async {
        final calls = <String>[];
        final accepted = <int, String>{};
        final activity = <String?>[];
        final progress = <double>[];
        final result =
            await SmartSubtitleTranslator(
              identifier: _UnexpectedLanguage(),
            ).translate(
              items: [
                _cue(1, 'Unexpected fragment. Hello everyone.'),
                _cue(2, '大家好。'),
              ],
              policy: SmartTranslationPolicy(keepUncertain: keepUncertain),
              supportedSourceLanguages: const [
                SubtitleTranslationLanguage(code: 'en', label: '英语'),
                SubtitleTranslationLanguage(code: 'zh-CN', label: '简体中文'),
              ],
              onProgress: progress.add,
              onActivity: activity.add,
              onTranslated: (index, text) => accepted[index] = text,
              translateBatch:
                  (items, source, target, scope, progress, translated) async =>
                      [
                        for (final item in items)
                          () {
                            calls.add(item.text);
                            return '[$target:${item.text}]';
                          }(),
                      ],
            );
        expect(calls, isNot(contains('Unexpected fragment.')));
        expect(result, [
          'Unexpected fragment. [zh-CN:Hello everyone.]',
          '[en:大家好。]',
        ]);
        expect(accepted, {0: result[0], 1: result[1]});
        expect(activity.last, contains('南非荷兰语'));
        expect(activity.last, contains('已保留原文'));
        expect(progress.last, 1);
      },
    );
  }

  test(
    'same-direction sentences use one model row per cue while mixed directions stay separate',
    () async {
      final batches = <List<String>>[];
      final result = await SmartSubtitleTranslator().translate(
        items: [
          _cue(1, 'Hello everyone. Please save the file. Thanks!'),
          _cue(2, '你好。Hello everyone.'),
        ],
        policy: const SmartTranslationPolicy(),
        onProgress: (_) {},
        translateBatch:
            (items, source, target, scope, progress, translated) async {
              batches.add(items.map((item) => item.text).toList());
              return [for (final item in items) '[$target:${item.text}]'];
            },
      );
      expect(batches, [
        ['Hello everyone. Please save the file. Thanks!', 'Hello everyone.'],
        ['你好。'],
      ]);
      expect(result[1], '[en:你好。][zh-CN:Hello everyone.]');
    },
  );

  test('slow translation has a bounded queue and drains in order', () async {
    final entered = Completer<void>(), release = Completer<void>();
    final events = <int>[];
    final queue = BoundedModelConsumer(
      onFailure: () => fail('unexpected failure'),
    );
    await queue.submit(() async {
      events.add(1);
      entered.complete();
      await release.future;
    });
    await entered.future;
    await queue.submit(() async => events.add(2));
    var thirdAccepted = false;
    final third = queue
        .submit(() async => events.add(3))
        .then((_) => thirdAccepted = true);
    await Future<void>.delayed(Duration.zero);
    expect(thirdAccepted, isFalse);
    expect(events, [1]);
    release.complete();
    await third;
    await queue.drain();
    expect(events, [1, 2, 3]);
  });

  test(
    'consumer failure cancels peers once and preserves the original error',
    () async {
      var aborted = 0, secondRan = false;
      final release = Completer<void>();
      final error = StateError('translation allocation failed');
      final queue = BoundedModelConsumer(onFailure: () => aborted++);
      await queue.submit(() async {
        await release.future;
        throw error;
      });
      await queue.submit(() async => secondRan = true);
      release.complete();
      await expectLater(queue.drain(), throwsA(same(error)));
      expect(aborted, 1);
      expect(secondRan, isFalse);
    },
  );

  test(
    '12 GB tablet admits SenseVoice and CPU Qwen from actual free memory',
    () async {
      final models = await loadModelCatalog();
      final asr = models.singleWhere(
        (model) => model.id == 'sensevoice-small-int8',
      );
      final qwen = models.singleWhere((model) => model.id == 'qwen3-4b-q4');
      final estimated = translationAllocationBytes(qwen.bytes);
      expect(estimated, lessThan(qwen.bytes * 2));
      final plan =
          const AsrExecutionPlan(
            pipeline: true,
            reuseModels: true,
            asrThreads: 4,
            enhancementThreads: 1,
            reason: 'test',
          ).withLocalTranslation(
            device: const ModelDeviceInfo(
              processors: 8,
              memoryBytes: 12 * gib,
              availableMemoryBytes: 5 * gib,
            ),
            platform: 'android',
            modelBytes: asr.bytes,
            translationBytes: qwen.bytes,
            alignmentBytes: 0,
            lightweightBytes: 0,
            mode: AsrExecutionMode.auto,
          );
      expect(plan.retainTranslation, isTrue);
      final resources = InferenceResourceSession(
        InferenceResourceGovernor(
          DeviceResourceSnapshot(
            platform: 'android',
            processors: 8,
            memoryBytes: 12 * gib,
            availableMemoryBytes: 4 * gib,
            capturedAt: DateTime.now(),
          ),
        ),
      );
      await resources.checkAllocation(estimated, modelLabel: 'Qwen3 4B');
      await expectLater(
        resources.checkAllocation(qwen.bytes * 2),
        throwsA(isA<InferenceMemoryPressure>()),
      );
      await resources.close();
    },
  );

  test(
    'memory admission reclaims idle models and explains model, free memory and recovery',
    () async {
      var available = 2 * gib, reclaims = 0;
      DeviceResourceSnapshot snapshot() => DeviceResourceSnapshot(
        platform: 'android',
        processors: 8,
        memoryBytes: 12 * gib,
        availableMemoryBytes: available,
        capturedAt: DateTime.now(),
      );
      final governor = InferenceResourceGovernor(snapshot());
      final resources = InferenceResourceSession(
        governor,
        refreshSnapshot: () async => governor.update(snapshot()),
      );
      final unregister = resources.registerIdleModel(() async {
        reclaims++;
        available = 4 * gib;
      });
      await resources.checkAllocation(3 * gib);
      expect(reclaims, 1);
      unregister();
      available = gib;
      try {
        await resources.checkAllocation(
          3 * gib,
          modelLabel: '本地翻译模型「Qwen3 4B」',
        );
        fail('allocation must be rejected');
      } on InferenceMemoryPressure catch (error) {
        final message = TranscriptionUserMessage.describe(error);
        expect(message, contains('Qwen3 4B'));
        expect(message, contains('3.00 GB'));
        expect(message, contains('1.00 GB'));
        expect(message, contains('12.00 GB'));
        expect(message, contains('释放内存'));
        expect(message, contains('更小模型'));
        expect(message, isNot(contains('转录失败')));
        expect(localTranslationFailureSummary(error), error.message);
      }
      await resources.close();
    },
  );
}
