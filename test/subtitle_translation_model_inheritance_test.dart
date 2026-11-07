import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/services/ai_subtitle_api_settings.dart';
import 'package:video_player_app/services/subtitle_optimization.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';
import 'package:video_player_app/widgets/subtitle_translation_model_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final secrets = <String, String>{};

  setUp(() {
    secrets.clear();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = call.arguments is Map
              ? Map<String, dynamic>.from(call.arguments as Map)
              : <String, dynamic>{};
          final key = args['key'] as String?;
          switch (call.method) {
            case 'read':
              return key == null ? null : secrets[key];
            case 'write':
              secrets[key!] = args['value'] as String;
              return null;
            case 'delete':
              if (key != null) secrets.remove(key);
              return null;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> saveConnection(String id, String model) {
    final endpoint = AiSubtitleApiSettings(
      connectionId: id,
      providerId: 'deepseek',
      baseUrl: 'https://api.deepseek.com',
      apiKey: 'secret-$id',
      model: model,
    );
    return SubtitleAiConnectionStore().save(
      SubtitleAiConnection(id, 'DeepSeek · $model', endpoint),
    );
  }

  test('AI translation adopts the optimization model until replaced', () async {
    await saveConnection('opt-deepseek', 'deepseek-chat');
    await const SubtitleOptimizationSettings(
      connectionId: 'opt-deepseek',
    ).save();
    final settings = SubtitleTranslateSettings();
    addTearDown(settings.dispose);
    await settings.setProviderEnZh(SubtitleTranslateProvider.ai);

    expect(settings.binding.api?.model, 'deepseek-chat');
    expect(settings.binding.api?.connectionId, 'opt-deepseek');
    expect(settings.providerEnZh, SubtitleTranslateProvider.ai);

    await saveConnection('opt-other', 'other-model');
    await const SubtitleOptimizationSettings(connectionId: 'opt-other').save();
    await settings.refreshBinding();
    expect(settings.binding.api?.model, 'deepseek-chat');

    await AiSubtitleApiSettingsStore().save(
      const AiSubtitleApiSettings(
        connectionId: 'opt-other',
        providerId: 'deepseek',
        baseUrl: 'https://api.deepseek.com',
        model: 'other-model',
      ),
    );
    await settings.refreshBinding();
    expect(settings.binding.api?.model, 'other-model');
    expect(settings.binding.api?.connectionId, 'opt-other');
  });

  test('an already chosen translation endpoint is left alone', () async {
    await saveConnection('opt-deepseek', 'deepseek-chat');
    await const SubtitleOptimizationSettings(
      connectionId: 'opt-deepseek',
    ).save();
    await AiSubtitleApiSettingsStore().save(
      const AiSubtitleApiSettings(
        providerId: 'openai',
        baseUrl: 'https://api.openai.com/v1',
        apiKey: 'openai-key',
        model: 'gpt-4o-mini',
      ),
    );
    final settings = SubtitleTranslateSettings();
    addTearDown(settings.dispose);
    await settings.setProviderEnZh(SubtitleTranslateProvider.ai);
    expect(settings.binding.api?.model, 'gpt-4o-mini');
    expect(settings.binding.api?.connectionId, isEmpty);
  });

  test('Bing does not copy the optimization connection', () async {
    await saveConnection('opt-deepseek', 'deepseek-chat');
    await const SubtitleOptimizationSettings(
      connectionId: 'opt-deepseek',
    ).save();
    final settings = SubtitleTranslateSettings();
    addTearDown(settings.dispose);
    await settings.ensureLoaded();
    expect(settings.providerEnZh, SubtitleTranslateProvider.bing);
    expect(
      (await AiSubtitleApiSettingsStore().loadMetadata()).connectionId,
      isEmpty,
    );
  });

  testWidgets('translation model sheet lists Bing, local models and AI', (
    tester,
  ) async {
    // testWidgets resets the messenger after the suite setUp.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = call.arguments is Map
              ? Map<String, dynamic>.from(call.arguments as Map)
              : <String, dynamic>{};
          final key = args['key'] as String?;
          switch (call.method) {
            case 'read':
              return key == null ? null : secrets[key];
            case 'write':
              secrets[key!] = args['value'] as String;
              return null;
            case 'delete':
              if (key != null) secrets.remove(key);
              return null;
          }
          return null;
        });
    await tester.runAsync(
      () => saveConnection('opt-deepseek', 'deepseek-chat'),
    );
    final center = ModelCenterService()
      ..loaded = true
      ..catalog = [
        const ModelArtifact(
          id: 'hy-mt',
          name: '本地译员',
          engine: 'marian',
          revision: '1',
          parameters: '1',
          quantization: 'q4',
          languages: ['zh', 'en'],
          description: '',
          license: '',
          homepage: '',
          purpose: ModelPurpose.translation,
          files: [],
          suggestedRamGb: 1,
          memoryNote: '',
        ),
      ];
    final settings = SubtitleTranslateSettings(modelCenter: center);
    addTearDown(settings.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSubtitleTranslationModelSettings(
                context,
                settings: settings,
                center: center,
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('翻译模型'), findsOneWidget);
    expect(find.text('必应翻译'), findsOneWidget);
    await tester.tap(find.text('必应翻译'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('本地 · 本地译员'), findsWidgets);
    expect(find.textContaining('deepseek-chat'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
