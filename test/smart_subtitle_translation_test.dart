import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/inference_scheduler.dart';
import 'package:video_player_app/features/model_center/local_subtitle_translator.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/ai_subtitle_api_settings.dart';
import 'package:video_player_app/services/ai_subtitle_translator.dart';
import 'package:video_player_app/services/smart_subtitle_translator.dart';
import 'package:video_player_app/services/subtitle_language_identifier.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';
import 'package:video_player_app/utils/subtitle_parser.dart';

import 'test_artifacts.dart';

SubtitleItem cue(int i, String text) => SubtitleItem(
  index: i,
  startTime: Duration(seconds: i),
  endTime: Duration(seconds: i + 1),
  text: text,
);

class _RoutingSpy extends SubtitleTranslationService {
  final calls =
      <
        ({
          String source,
          String target,
          List<SubtitleItem> items,
          String scope,
          SubtitleTranslateProvider provider,
        })
      >[];
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
    if (smartPolicy != null) {
      return super.translateCueBatch(
        items: items,
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
        provider: provider,
        onProgress: onProgress,
        onActivity: onActivity,
        onTranslated: onTranslated,
        aiOptions: aiOptions,
        aiEndpoint: aiEndpoint,
        localSpecification: localSpecification,
        modelCenter: modelCenter,
        localSession: localSession,
        reservation: reservation,
        precedingContext: precedingContext,
        checkpointScope: checkpointScope,
        cancelSignal: cancelSignal,
        smartPolicy: smartPolicy,
      );
    }
    calls.add((
      source: sourceLanguage,
      target: targetLanguage,
      items: items,
      scope: checkpointScope,
      provider: provider,
    ));
    final result = [for (final item in items) '[$targetLanguage:${item.text}]'];
    for (var i = 0; i < result.length; i++) {
      onTranslated?.call(i, result[i]);
    }
    onProgress(1);
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  const policy = SmartTranslationPolicy();
  final identifier = SubtitleLanguageIdentifier();

  test(
    'bundled identifier handles common scripts and Latin phrases locally',
    () async {
      await identifier.load();
      for (final entry in {
        'zh-CN': '大家好，今天天气很好。',
        'ja': '皆さん、こんにちは。今日はいい天気ですね。',
        'ko': '안녕하세요. 오늘 날씨가 좋아요.',
        'en': 'Please sit down and take your bags.',
        'fr': 'Bonjour tout le monde, merci pour votre aide.',
        'de': 'Guten Morgen, danke für Ihre Hilfe.',
        'es': 'Hola, buenos días, gracias por todo.',
      }.entries) {
        final guess = identifier.identify(entry.value);
        expect(guess.language, entry.key, reason: entry.value);
        expect(guess.confident, isTrue, reason: entry.value);
      }
      expect(identifier.identify('12345 !?').confident, isFalse);
    },
  );

  for (final provider in SubtitleTranslateProvider.values) {
    test(
      'smart mixed cues reach $provider with ordinary supported target languages',
      () async {
        final service = _RoutingSpy();
        final center = ModelCenterService();
        center.catalog =
            ((jsonDecode(File('assets/models/catalog.json').readAsStringSync())
                        as Map)['models']
                    as List)
                .map(
                  (value) => ModelArtifact.fromJson(
                    Map<String, dynamic>.from(value as Map),
                  ),
                )
                .toList();
        addTearDown(service.dispose);
        addTearDown(center.dispose);
        final spec = ModelJobSpec(
          profile: ModelServiceProfile(
            id: 'test',
            name: 'test',
            kind: TranscriptionServiceKind.local,
            model: center.translationModelId,
          ),
        );
        final published = <int, String>{};
        final output = await service.translateCueBatch(
          items: [cue(1, '大家好。Please sit down.ありがとう。'), cue(2, '안녕하세요.')],
          sourceLanguage: 'auto',
          targetLanguage: 'mul',
          provider: provider,
          localSpecification: spec,
          modelCenter: center,
          smartPolicy: policy,
          onProgress: (_) {},
          onTranslated: (index, value) => published[index] = value,
        );
        expect(service.calls.map((call) => call.target), ['en', 'zh-CN']);
        expect(
          service.calls.every((call) => call.provider == provider),
          isTrue,
        );
        expect(service.calls.every((call) => call.target != 'mul'), isTrue);
        expect(
          service.calls.last.source,
          'auto',
        ); // English, Japanese and Korean share a target.
        expect(output.first, '[en:大家好。][zh-CN:Please sit down.][zh-CN:ありがとう。]');
        expect(output.last, '[zh-CN:안녕하세요.]');
        expect(published, {0: output.first, 1: output.last});
        expect(service.calls.first.scope, contains(policy.fingerprint));
      },
    );
  }

  test(
    'embedded brand stays in a Chinese sentence, while real foreign phrases split',
    () async {
      final service = _RoutingSpy();
      addTearDown(service.dispose);
      final output = await service.translateCueBatch(
        items: [cue(1, '我在 YouTube 上学习日语。'), cue(2, '大家好 Hello everyone')],
        sourceLanguage: 'auto',
        targetLanguage: 'mul',
        provider: SubtitleTranslateProvider.bing,
        smartPolicy: policy,
        onProgress: (_) {},
      );
      expect(output.first, '[en:我在 YouTube 上学习日语。]');
      expect(output.last, '[en:大家好] [zh-CN:Hello everyone]');
    },
  );

  test(
    'a Japanese neighbor does not change the direction of a Chinese greeting',
    () async {
      final service = _RoutingSpy();
      addTearDown(service.dispose);
      final result = await service.translateCueBatch(
        items: [cue(1, '大家好。'), cue(2, 'ありがとうございます。')],
        sourceLanguage: 'auto',
        targetLanguage: 'mul',
        smartPolicy: policy,
        provider: SubtitleTranslateProvider.bing,
        onProgress: (_) {},
      );
      expect(result, ['[en:大家好。]', '[zh-CN:ありがとうございます。]']);
    },
  );

  test(
    'clear English and French phrases can split within a single Latin-script clause',
    () async {
      final service = _RoutingSpy();
      addTearDown(service.dispose);
      const smart = SmartTranslationPolicy(
        rules: [
          SmartTranslationRule(source: 'en', target: 'ja'),
          SmartTranslationRule(source: 'fr', target: 'ko'),
        ],
      );
      final output = await service.translateCueBatch(
        items: [cue(1, 'Hello everyone bonjour tout le monde')],
        sourceLanguage: 'auto',
        targetLanguage: 'mul',
        provider: SubtitleTranslateProvider.bing,
        smartPolicy: smart,
        onProgress: (_) {},
      );
      expect(output.single, '[ja:Hello everyone] [ko:bonjour tout le monde]');
    },
  );

  test(
    'ambiguous all-Han text in Japanese context follows the uncertainty setting',
    () async {
      final service = _RoutingSpy();
      addTearDown(service.dispose);
      final output = await service.translateCueBatch(
        items: [cue(1, '世界。ありがとう。')],
        sourceLanguage: 'auto',
        targetLanguage: 'mul',
        provider: SubtitleTranslateProvider.bing,
        smartPolicy: policy,
        onProgress: (_) {},
      );
      expect(output.single, '世界。[zh-CN:ありがとう。]');
    },
  );

  test(
    'timestamps, markup, URLs, line breaks and whitespace survive file translation',
    () async {
      final root = await Directory.systemTemp.createTemp('smart-translation-');
      addTearDown(() => root.delete(recursive: true));
      final input = File('${root.path}/input.srt');
      await input.writeAsString(
        '1\n00:00:01,000 --> 00:00:02,500\n<i>大家好。</i>\nWelcome! https://example.com/a\n',
      );
      final service = _RoutingSpy();
      addTearDown(service.dispose);
      final result = await service.translateSubtitleFile(
        inputPath: input.path,
        sourceLanguage: 'auto',
        targetLanguage: 'mul',
        provider: SubtitleTranslateProvider.bing,
        smartPolicy: policy,
        onProgress: (_) {},
      );
      final raw = await File(result.outputPath).readAsString();
      expect(raw, contains('<i>[en:大家好。]</i>'));
      final parsed = SubtitleParser.parse(raw);
      expect(parsed.single.startTime, const Duration(seconds: 1));
      expect(parsed.single.endTime, const Duration(milliseconds: 2500));
      expect(
        parsed.single.text,
        '[en:大家好。]\n[zh-CN:Welcome!] https://example.com/a',
      );
      expect(result.outputPath, contains('mul'));
    },
  );

  test(
    'rules can change their source and both targets, add languages, or keep originals',
    () async {
      final service = _RoutingSpy();
      addTearDown(service.dispose);
      const changed = SmartTranslationPolicy(
        rules: [
          SmartTranslationRule(source: 'ja', target: 'ko'),
          SmartTranslationRule(source: 'en', target: keepOriginal),
        ],
        otherTarget: 'fr',
      );
      final output = await service.translateCueBatch(
        items: [cue(1, '大家好。Hello everyone.ありがとう。')],
        sourceLanguage: 'auto',
        targetLanguage: 'mul',
        provider: SubtitleTranslateProvider.bing,
        smartPolicy: changed,
        onProgress: (_) {},
      );
      expect(output.single, '[fr:大家好。]Hello everyone.[ko:ありがとう。]');
      expect(service.calls.map((call) => call.target), ['fr', 'ko']);
      expect(
        () => const SmartTranslationPolicy(
          rules: [
            SmartTranslationRule(source: 'zh-CN', target: 'en'),
            SmartTranslationRule(source: 'zh-TW', target: 'ja'),
          ],
        ).validate(subtitleTranslationLanguages),
        throwsArgumentError,
      );
    },
  );

  test(
    'uncertain direction can keep text or apply the other-language rule',
    () async {
      final router = SmartSubtitleTranslator();
      Future<List<String>> run(bool keep) => router.translate(
        items: [cue(1, 'qzxv')],
        policy: SmartTranslationPolicy(
          rules: const [SmartTranslationRule(source: 'en', target: 'fr')],
          keepUncertain: keep,
        ),
        onProgress: (_) {},
        translateBatch:
            (items, source, target, scope, progress, translated) async => [
              for (final item in items) '[$target:${item.text}]',
            ],
      );
      expect(await run(true), ['qzxv']);
      expect(await run(false), ['[zh-CN:qzxv]']);
    },
  );

  test(
    'partial mixed cues are never published when a later direction fails',
    () async {
      var requests = 0;
      final accepted = <int>[];
      await expectLater(
        SmartSubtitleTranslator().translate(
          items: [cue(1, '大家好。'), cue(2, '你好。Hello everyone.')],
          policy: policy,
          onProgress: (_) {},
          onTranslated: (index, _) => accepted.add(index),
          translateBatch:
              (items, source, target, scope, progress, translated) async {
                requests++;
                if (requests == 2) throw StateError('temporary failure');
                final values = [
                  for (final item in items) '[$target:${item.text}]',
                ];
                for (var i = 0; i < values.length; i++) {
                  translated(i, values[i]);
                }
                return values;
              },
        ),
        throwsStateError,
      );
      expect(accepted, [0]);
    },
  );

  test(
    'cancellation prevents later direction requests and late cue publication',
    () async {
      final signal = Completer<void>(), entered = Completer<void>();
      final release = Completer<void>();
      var requests = 0;
      final accepted = <int>[];
      final work = SmartSubtitleTranslator().translate(
        items: [cue(1, '大家好。Hello everyone.')],
        policy: policy,
        cancelSignal: signal.future,
        onProgress: (_) {},
        onTranslated: (index, _) => accepted.add(index),
        translateBatch:
            (items, source, target, scope, progress, translated) async {
              requests++;
              entered.complete();
              await release.future;
              return ['done'];
            },
      );
      await entered.future;
      signal.complete();
      await Future<void>.delayed(Duration.zero);
      release.complete();
      await expectLater(work, throwsStateError);
      expect(requests, 1);
      expect(accepted, isEmpty);
    },
  );

  test(
    'smart and fixed settings persist independently for each endpoint and model',
    () async {
      var api = const AiSubtitleApiSettings(
        baseUrl: 'https://models.example/v1',
        model: 'one',
      );
      SubtitleTranslateSettings create() =>
          SubtitleTranslateSettings(readApiSettings: () async => api);
      var settings = create();
      await settings.ensureLoaded();
      await settings.setLanguages(source: 'ja', target: 'en');
      await settings.setMode(SubtitleTranslationMode.smart);
      await settings.setSmartPolicy(
        const SmartTranslationPolicy(
          rules: [SmartTranslationRule(source: 'ko', target: 'ja')],
          otherTarget: 'en',
          keepUncertain: false,
        ),
      );
      final frozen = await TranscriptTranslateChoice.capture(
        settings,
        enabled: true,
      );
      await settings.setProviderEnZh(SubtitleTranslateProvider.ai);
      expect(settings.mode, SubtitleTranslationMode.smart);
      await settings.setMode(SubtitleTranslationMode.smart);
      await settings.setSmartPolicy(
        const SmartTranslationPolicy(otherTarget: 'fr'),
      );
      api = api.copyWith(model: 'two');
      await settings.refreshBinding();
      expect(settings.mode, SubtitleTranslationMode.smart);
      await settings.setProviderEnZh(SubtitleTranslateProvider.bing);
      expect(settings.smartPolicy.rules.single.source, 'ko');
      await settings.setMode(SubtitleTranslationMode.fixed);
      expect((settings.sourceLanguage, settings.targetLanguage), ('ja', 'en'));
      settings.dispose();
      settings = create();
      addTearDown(settings.dispose);
      await settings.ensureLoaded();
      expect(settings.smartPolicy.otherTarget, 'en');
      api = api.copyWith(model: 'one');
      await settings.setProviderEnZh(SubtitleTranslateProvider.ai);
      expect(settings.mode, SubtitleTranslationMode.smart);
      expect(settings.smartPolicy.otherTarget, 'fr');
      expect(frozen.smartPolicy!.rules.single.target, 'ja');
      expect((frozen.sourceLanguage, frozen.targetLanguage), ('auto', 'mul'));
    },
  );

  test(
    'local rule choices follow the selected model and each model remembers its own rules',
    () async {
      final center = ModelCenterService();
      center.catalog =
          ((jsonDecode(File('assets/models/catalog.json').readAsStringSync())
                      as Map)['models']
                  as List)
              .map(
                (value) => ModelArtifact.fromJson(
                  Map<String, dynamic>.from(value as Map),
                ),
              )
              .toList();
      final settings = SubtitleTranslateSettings(modelCenter: center);
      addTearDown(settings.dispose);
      addTearDown(center.dispose);
      await settings.setProviderEnZh(SubtitleTranslateProvider.local);
      await settings.setMode(SubtitleTranslationMode.smart);
      const khmer = SmartTranslationPolicy(
        rules: [SmartTranslationRule(source: 'ja', target: 'km')],
      );
      await settings.setSmartPolicy(khmer);
      center.translationModelId = 'qwen3-4b-q4';
      await settings.refreshBinding();
      expect(
        settings.availableLanguages.any((language) => language.code == 'km'),
        isFalse,
      );
      await expectLater(settings.setSmartPolicy(khmer), throwsArgumentError);
      expect(settings.mode, SubtitleTranslationMode.smart);
      center.translationModelId = 'hy-mt2-1.8b-q4';
      await settings.refreshBinding();
      expect(settings.mode, SubtitleTranslationMode.smart);
      expect(settings.smartPolicy.rules.single.target, 'km');
    },
  );

  test(
    'a thousand mixed cues are grouped by destination rather than issuing per-fragment calls',
    () async {
      final service = _RoutingSpy();
      addTearDown(service.dispose);
      final watch = Stopwatch()..start();
      final output = await service.translateCueBatch(
        items: [
          for (var i = 1; i <= 1000; i++)
            cue(i, '第$i条字幕。Please sit down.ありがとう。'),
        ],
        sourceLanguage: 'auto',
        targetLanguage: 'mul',
        smartPolicy: policy,
        provider: SubtitleTranslateProvider.bing,
        onProgress: (_) {},
      );
      watch.stop();
      expect(output, hasLength(1000));
      expect(service.calls, hasLength(2));
      expect(service.calls.first.items, hasLength(1000));
      expect(service.calls.last.items, hasLength(2000));
      await testArtifact(
        'smart-translation/routing-benchmark.json',
      ).writeAsString(
        jsonEncode({
          'cues': output.length,
          'routedFragments': 3000,
          'destinationGroups': service.calls.length,
          'routingAndFakeTranslationMs': watch.elapsedMilliseconds,
        }),
      );
    },
  );
}
