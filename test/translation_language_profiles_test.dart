import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/services/ai_subtitle_api_settings.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';

class _Models extends ModelCenterService {
  void select(String id) {
    translationModelId = id;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'common languages lead the complete catalog and source defaults to detection',
    () async {
      final settings = SubtitleTranslateSettings();
      addTearDown(settings.dispose);
      await settings.ensureLoaded();
      expect(settings.sourceLanguage, 'auto');
      expect(settings.targetLanguage, 'zh-CN');
      expect(settings.mode, SubtitleTranslationMode.smart);
      expect(settings.availableLanguages.take(4).map((l) => l.code), [
        'zh-CN',
        'en',
        'ja',
        'ko',
      ]);
      expect(
        settings.availableLanguages.map((l) => l.code).toSet(),
        hasLength(179),
      );
      final captured = await TranscriptTranslateChoice.capture(
        settings,
        enabled: true,
      );
      expect(captured.sourceLanguage, 'auto');
      expect(captured.targetLanguage, 'mul');
      expect(captured.smartPolicy, isNotNull);
    },
  );

  test(
    'web service and each API endpoint/model restore independent pairs after restart',
    () async {
      var api = const AiSubtitleApiSettings(
        providerId: 'custom',
        baseUrl: 'https://one.example/v1',
        model: 'model-a',
        apiKey: 'secret',
      );
      SubtitleTranslateSettings open() =>
          SubtitleTranslateSettings(readApiSettings: () async => api);
      var settings = open();
      try {
        await settings.ensureLoaded();
        await settings.setLanguages(source: 'ja', target: 'en');
        await settings.setProviderEnZh(SubtitleTranslateProvider.ai);
        final keyA = settings.binding.key;
        expect(settings.sourceLanguage, 'auto');
        await settings.setLanguages(source: 'ko', target: 'fr');
        api = api.copyWith(model: 'model-b');
        await settings.refreshBinding();
        expect(settings.targetLanguage, 'zh-CN');
        await settings.setLanguages(source: 'auto', target: 'ja');
        api = api.copyWith(model: 'model-a');
        await settings.refreshBinding();
        expect(settings.binding.key, keyA);
        expect(
          (settings.sourceLanguage, settings.targetLanguage),
          ('ko', 'fr'),
        );
        api = api.copyWith(baseUrl: 'https://two.example/v1');
        await settings.refreshBinding();
        expect(settings.binding.key, isNot(keyA));
        expect(settings.targetLanguage, 'zh-CN');
        await settings.setLanguages(target: 'de');
        await settings.setProviderEnZh(SubtitleTranslateProvider.bing);
        expect(
          (settings.sourceLanguage, settings.targetLanguage),
          ('ja', 'en'),
        );
        settings.dispose();
        settings = open();
        await settings.ensureLoaded();
        expect(
          (settings.sourceLanguage, settings.targetLanguage),
          ('ja', 'en'),
        );
        api = api.copyWith(baseUrl: 'https://one.example/v1');
        await settings.setProviderEnZh(SubtitleTranslateProvider.ai);
        expect(
          (settings.sourceLanguage, settings.targetLanguage),
          ('ko', 'fr'),
        );
        api = api.copyWith(model: 'model-b');
        await settings.refreshBinding();
        expect(
          (settings.sourceLanguage, settings.targetLanguage),
          ('auto', 'ja'),
        );
        final raw = (await SharedPreferences.getInstance()).getString(
          SubtitleTranslateSettings.languageProfilesKey,
        )!;
        expect(raw, isNot(contains('secret')));
        expect(raw, isNot(contains('one.example')));
      } finally {
        settings.dispose();
      }
    },
  );

  test(
    'local model selection restores its languages and its own remembered pair',
    () async {
      final center = _Models();
      center.catalog =
          ((jsonDecode(File('assets/models/catalog.json').readAsStringSync())
                      as Map)['models']
                  as List)
              .map(
                (raw) => ModelArtifact.fromJson(
                  Map<String, dynamic>.from(raw as Map),
                ),
              )
              .toList();
      final settings = SubtitleTranslateSettings(modelCenter: center);
      addTearDown(settings.dispose);
      addTearDown(center.dispose);
      await settings.ensureLoaded();
      await settings.setProviderEnZh(SubtitleTranslateProvider.local);
      expect(settings.binding.key, 'local:hy-mt2-1.8b-q4');
      expect(settings.binding.label, contains('Hy-MT'));
      await settings.setLanguages(source: 'ja', target: 'ko');
      center.select('qwen3-4b-q4');
      await settings.refreshBinding();
      expect(settings.targetLanguage, 'zh-CN');
      expect(settings.availableLanguages.any((l) => l.code == 'km'), isFalse);
      await settings.setLanguages(source: 'en', target: 'fr');
      center.select('hy-mt2-1.8b-q4');
      await settings.refreshBinding();
      expect((settings.sourceLanguage, settings.targetLanguage), ('ja', 'ko'));
      expect(settings.availableLanguages.any((l) => l.code == 'km'), isTrue);
    },
  );

  test(
    'an old async binding read cannot replace a newly selected service',
    () async {
      final gate = Completer<AiSubtitleApiSettings>();
      final settings = SubtitleTranslateSettings(
        readApiSettings: () => gate.future,
      );
      addTearDown(settings.dispose);
      await settings.ensureLoaded();
      await settings.setLanguages(target: 'ja');
      final ai = settings.setProviderEnZh(SubtitleTranslateProvider.ai);
      await Future<void>.delayed(Duration.zero);
      await settings.setProviderEnZh(SubtitleTranslateProvider.bing);
      gate.complete(
        const AiSubtitleApiSettings(
          baseUrl: 'https://stale.example',
          model: 'stale',
        ),
      );
      await ai;
      expect(settings.binding.key, 'bing');
      expect(settings.targetLanguage, 'ja');
    },
  );

  test('a picker opened for the old model saves only to that model', () async {
    var api = const AiSubtitleApiSettings(
      baseUrl: 'https://models.example/v1',
      model: 'first',
    );
    final settings = SubtitleTranslateSettings(
      readApiSettings: () async => api,
    );
    addTearDown(settings.dispose);
    await settings.setProviderEnZh(SubtitleTranslateProvider.ai);
    final old = settings.binding.key;
    api = api.copyWith(model: 'second');
    await settings.refreshBinding();
    await settings.setLanguages(bindingKey: old, target: 'ja');
    expect(settings.targetLanguage, 'zh-CN');
    api = api.copyWith(model: 'first');
    await settings.refreshBinding();
    expect(settings.targetLanguage, 'ja');
  });

  test(
    'captured AI job freezes both language direction and the selected model without credentials',
    () async {
      var api = const AiSubtitleApiSettings(
        providerId: 'custom',
        baseUrl: 'https://models.example/v1',
        model: 'first',
        apiKey: 'secret',
      );
      final settings = SubtitleTranslateSettings(
        readApiSettings: () async => api,
      );
      addTearDown(settings.dispose);
      await settings.setProviderEnZh(SubtitleTranslateProvider.ai);
      await settings.setMode(SubtitleTranslationMode.fixed);
      await settings.setLanguages(source: 'ja', target: 'en');
      final choice = await TranscriptTranslateChoice.capture(
        settings,
        enabled: true,
      );
      api = api.copyWith(model: 'second');
      await settings.refreshBinding();
      await settings.setLanguages(target: 'fr');
      expect(choice.apiEndpoint!.model, 'first');
      expect(choice.apiEndpoint!.apiKey, isEmpty);
      expect(choice.apiEndpoint!.profiles, isEmpty);
      expect((choice.sourceLanguage, choice.targetLanguage), ('ja', 'en'));
      final plan = resolveTranscriptTranslation(
        direction: choice.direction,
        subtitleText: '普通中文',
        sourceLanguage: choice.sourceLanguage,
        targetLanguage: choice.targetLanguage,
      );
      expect((plan.sourceLanguage, plan.targetLanguage), ('ja', 'en'));
    },
  );
}
