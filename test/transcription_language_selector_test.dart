import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/widgets/batch_subtitle_configuration_bar.dart';
import 'package:video_player_app/widgets/transcription_language_selector.dart';
import 'package:video_player_app/widgets/transcription_restart_dialog.dart';

class _Center extends ModelCenterService {
  _Center() {
    loaded = true;
  }
  int downloadsStarted = 0;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> settingsChanged() async => notifyListeners();
  @override
  Future<void> save() async {}
  @override
  Future<void> enqueue(String id) async {
    downloadsStarted++;
  }

  void bind(String id) {
    final model = artifact(id)!;
    final profile = ModelServiceProfile(
      id: 'local:$id',
      name: model.name,
      kind: TranscriptionServiceKind.local,
      model: id,
    );
    profiles[profile.id] = profile;
    asrProfileId = profile.id;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Center center;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    center = _Center()..catalog = await loadModelCatalog();
    center.bind('qwen3-asr-0.6b-f16');
  });
  tearDown(() => center.dispose());
  Widget shell(Widget child) => MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
  Finder getSelector() =>
      find.byKey(const ValueKey('transcription-language-summary'));
  Finder choice(String code) =>
      find.byKey(ValueKey('model-center-choice-$code'));

  testWidgets(
    'model changes filter unsupported languages and return to the remembered choice',
    (tester) async {
      await tester.pumpWidget(
        shell(TranscriptionLanguageSelector(center: center)),
      );
      await tester.pumpAndSettle();
      await tester.tap(getSelector());
      await tester.pumpAndSettle();
      await tester.tap(choice('ja'));
      await tester.pumpAndSettle();
      center.bind('parakeet-v3-int8');
      await tester.pumpAndSettle();
      expect(find.text('识别语言：自动识别'), findsOneWidget);
      await tester.tap(getSelector());
      await tester.pumpAndSettle();
      expect(choice('ja'), findsNothing);
      expect(choice('zh'), findsNothing);
      await tester.tap(choice('en'));
      await tester.pumpAndSettle();
      center.bind('qwen3-asr-0.6b-f16');
      await tester.pumpAndSettle();
      expect(find.text('识别语言：日语'), findsOneWidget);
      expect(center.downloadsStarted, 0);
    },
  );

  testWidgets(
    'single-language model has a clear fixed language and no misleading picker',
    (tester) async {
      center.bind('parakeet-ja-0.6b-q8');
      await tester.pumpWidget(
        shell(TranscriptionLanguageSelector(center: center)),
      );
      await tester.pumpAndSettle();
      expect(find.text('识别语言：日语'), findsOneWidget);
      expect(tester.widget<TextButton>(getSelector()).onPressed, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a language picker remains attached to its original model', (
    tester,
  ) async {
    await tester.pumpWidget(
      shell(TranscriptionLanguageSelector(center: center)),
    );
    await tester.pumpAndSettle();
    await tester.tap(getSelector());
    await tester.pumpAndSettle();
    center.bind('parakeet-v3-int8');
    await tester.pumpAndSettle();
    await tester.tap(choice('ja'));
    await tester.pumpAndSettle();
    expect(center.effectiveAsrLanguage, 'auto');
    center.bind('qwen3-asr-0.6b-f16');
    await tester.pumpAndSettle();
    expect(center.effectiveAsrLanguage, 'ja');
  });

  testWidgets(
    'long language lists are searchable by code without offering unsupported English',
    (tester) async {
      center.bind('dolphin-base-int8');
      await tester.pumpWidget(
        shell(TranscriptionLanguageSelector(center: center)),
      );
      await tester.pumpAndSettle();
      await tester.tap(getSelector());
      await tester.pumpAndSettle();
      expect(choice('en'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('model-center-picker-search')),
        'kab',
      );
      await tester.pumpAndSettle();
      expect(find.text('卡拜尔语'), findsOneWidget);
      await tester.tap(choice('kab'));
      await tester.pumpAndSettle();
      expect(center.effectiveAsrLanguage, 'kab');
    },
  );

  testWidgets(
    'batch page changes recognition language directly and preserves translation mode',
    (tester) async {
      final settings = SettingsService()..resetForTest();
      await settings.init();
      final translation = SubtitleTranslateSettings(modelCenter: center);
      await translation.ensureLoaded();
      addTearDown(translation.dispose);
      await tester.pumpWidget(
        shell(
          SizedBox(
            width: 320,
            child: BatchSubtitleConfigurationBar(
              settings: settings,
              modelCenter: center,
              translateSettings: translation,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('展开配置详情'));
      await tester.pumpAndSettle();
      final enabled = settings.batchSubtitleTranslateEnabled;
      await tester.tap(
        find.byKey(const ValueKey('batch-transcription-language')),
      );
      await tester.pumpAndSettle();
      await tester.tap(choice('ko'));
      await tester.pumpAndSettle();
      expect(center.transcriptionConfiguration.profile.language, 'ko');
      expect(settings.batchSubtitleTranslateEnabled, enabled);
      expect(center.downloadsStarted, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'restart confirmation offers the same remembered language before creating a new task',
    (tester) async {
      await tester.pumpWidget(
        shell(
          Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  confirmTranscriptionRestart(context, modelCenter: center),
              child: const Text('restart'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('restart'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('restart-transcription-language')),
      );
      await tester.pumpAndSettle();
      await tester.tap(choice('ja'));
      await tester.pumpAndSettle();
      expect(center.effectiveAsrLanguage, 'ja');
      expect(
        find.byKey(const ValueKey('transcription-restart-confirm')),
        findsOneWidget,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(center.effectiveAsrLanguage, 'ja');
      expect(tester.takeException(), isNull);
    },
  );

  for (final (size, scale, keyboard) in [
    (const Size(320, 568), 2.0, 250.0),
    (const Size(568, 320), 1.6, 140.0),
    (const Size(844, 390), 1.6, 160.0),
  ]) {
    testWidgets('language search fits $size at $scale with keyboard', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(body: TranscriptionLanguageSelector(center: center)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(getSelector());
      await tester.pumpAndSettle();
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
      await tester.pumpAndSettle();
      final search = find.byKey(const ValueKey('model-center-picker-search'));
      await tester.ensureVisible(search);
      await tester.enterText(search, 'ja');
      await tester.pumpAndSettle();
      await tester.ensureVisible(choice('ja'));
      expect(choice('ja').hitTestable(), findsOneWidget);
      await tester.tap(choice('ja'));
      await tester.pumpAndSettle();
      expect(center.effectiveAsrLanguage, 'ja');
      expect(tester.takeException(), isNull);
      expect(center.downloadsStarted, 0);
    });
  }
}
