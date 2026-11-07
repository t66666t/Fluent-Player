import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/transcription_hotword_store.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/widgets/ai_transcription_configuration.dart';
import 'package:video_player_app/widgets/ai_transcription_panel.dart';
import 'package:video_player_app/widgets/subtitle_processing_stage.dart';
import 'package:video_player_app/widgets/transcript_translate_settings_sheet.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';
import 'package:video_player_app/services/subtitle_optimization.dart';
import 'package:video_player_app/services/ai_subtitle_translator.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';

class _Center extends ModelCenterService {
  _Center() {
    loaded = true;
  }
  @override
  Future<void> initialize() async {}
  @override
  bool installed(String id) => true;
  @override
  Future<void> settingsChanged() async => notifyListeners();
  @override
  Future<void> save() async {}
  void select(String id) {
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
  late TranscriptionHotwordStore words;
  late SubtitleTranslateSettings translation;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    center = _Center()..catalog = await loadModelCatalog();
    center.select('qwen3-asr-0.6b-f16');
    words = TranscriptionHotwordStore();
    await words.load();
    translation = SubtitleTranslateSettings(modelCenter: center);
    await translation.ensureLoaded();
  });
  tearDown(() {
    translation.dispose();
    words.dispose();
  });

  Widget config({String key = 'id:a', TranscriptionHotwordStore? store}) =>
      AiTranscriptionConfiguration(
        center: center,
        hotwords: store ?? words,
        mediaKey: key,
        mediaTitle: key == 'id:a' ? '视频 A · 技术访谈' : '视频 B',
        translation: translation,
      );
  Widget shell(Widget child) => MaterialApp(
    theme: ThemeData.dark(useMaterial3: true).copyWith(
      textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Noto Sans SC'),
    ),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
  Future<void> openWords(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('video-hotwords-button')),
      80,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('video-hotwords-button')));
    await tester.pumpAndSettle();
  }

  TextField editor(WidgetTester tester) => tester.widget<TextField>(
    find.byKey(const ValueKey('video-hotwords-input')),
  );

  testWidgets('public preset can be selected from transcription settings', (
    tester,
  ) async {
    await tester.pumpWidget(shell(config()));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('transcription-method-summary')),
    );
    await tester.pumpAndSettle();
    final choice = find.byKey(const ValueKey('model-center-choice-gongyi'));
    expect(choice, findsOneWidget);
    await tester.ensureVisible(choice);
    await tester.tap(choice);
    await tester.pumpAndSettle();
    expect(center.asrProfileId, ModelCenterService.legacyProfile.id);
    expect(center.asrProfile.kind, TranscriptionServiceKind.gongyi);
    expect(find.textContaining('公益接口'), findsWidgets);
    expect(find.byKey(const ValueKey('video-hotwords-button')), findsNothing);
  });

  testWidgets(
    'transcription and translation share the group under model settings',
    (tester) async {
      await tester.pumpWidget(shell(SizedBox(width: 420, child: config())));
      await tester.pumpAndSettle();
      final group = find.byKey(const ValueKey('ai-subtitle-methods'));
      expect(
        find.byKey(const ValueKey('transcription-model-settings')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: group,
          matching: find.byKey(const ValueKey('transcription-method-summary')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: group,
          matching: find.byKey(
            const ValueKey('ai-transcription-translation-settings'),
          ),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('本地模型 · Qwen3-ASR 0.6B'), findsOneWidget);
      expect(find.text('识别语言：自动识别'), findsOneWidget);
      expect(
        tester
            .getTopLeft(
              find.byKey(const ValueKey('transcription-method-summary')),
            )
            .dy,
        lessThan(
          tester
              .getTopLeft(
                find.byKey(
                  const ValueKey('ai-transcription-translation-settings'),
                ),
              )
              .dy,
        ),
      );
      expect(find.byKey(const ValueKey('video-hotwords-input')), findsNothing);
    },
  );

  testWidgets('processing stages share aligned switches and explicit actions', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final width in [320.0, 390.0, 768.0]) {
      for (final scale in [1.0, 1.6]) {
        tester.view.physicalSize = Size(width, 900);
        await tester.pumpWidget(
          shell(
            MediaQuery(
              data: MediaQueryData(
                size: Size(width, 900),
                textScaler: TextScaler.linear(scale),
              ),
              child: SizedBox(width: width, child: config()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(SubtitleProcessingStage), findsNWidgets(2));
        final optimize = tester.getRect(
          find.byKey(const ValueKey('subtitle-optimization-toggle')),
        );
        final translate = tester.getRect(
          find.byKey(const ValueKey('ai-transcription-translation-toggle')),
        );
        expect(optimize.center.dx, closeTo(translate.center.dx, .1));
        expect(optimize.size, translate.size);
        expect(find.text('模型'), findsNWidgets(2));
        expect(find.text('提示词'), findsOneWidget);
        expect(find.text('翻译选项'), findsOneWidget);
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const ValueKey('subtitle-optimization-settings')),
              )
              .onPressed,
          isNotNull,
        );
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(
                  const ValueKey('subtitle-optimization-prompt-button'),
                ),
              )
              .onPressed,
          isNotNull,
        );
        expect(find.byType(TranscriptTranslateSettingsSheet), findsNothing);
        expect(tester.takeException(), isNull, reason: '$width / $scale');
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });

  testWidgets(
    'model and prompt actions open their editors without enabling a stage',
    (tester) async {
      await tester.pumpWidget(shell(config()));
      await tester.pumpAndSettle();
      Future<void> tap(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      await tap(find.byKey(const ValueKey('subtitle-optimization-settings')));
      expect(find.text('优化模型'), findsOneWidget);
      await tap(find.byTooltip('关闭优化设置'));
      await tap(
        find.byKey(const ValueKey('subtitle-optimization-prompt-button')),
      );
      final prompt = find.byKey(const ValueKey('subtitle-optimization-prompt'));
      await tester.ensureVisible(prompt);
      await tester.enterText(prompt, '保留口语和时间轴');
      await tap(find.text('保存'));
      final saved = await SubtitleOptimizationSettings.load();
      expect(saved.prompt, '保留口语和时间轴');
      expect(saved.enabled, isFalse);
      expect(
        tester
            .widget<Switch>(
              find.byKey(const ValueKey('ai-transcription-translation-toggle')),
            )
            .value,
        isFalse,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'translation options expand inline and preserve edits and switch choices',
    (tester) async {
      var translate = false;
      await tester.pumpWidget(
        shell(
          StatefulBuilder(
            builder: (context, change) => AiTranscriptionConfiguration(
              center: center,
              hotwords: words,
              mediaKey: 'id:a',
              mediaTitle: '视频 A',
              translation: translation,
              translationEnabled: translate,
              onTranslationChanged: (value) => change(() => translate = value),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> tap(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      final options = find.byKey(
        const ValueKey('ai-transcription-translation-settings'),
      );
      await tap(options);
      expect(translate, isFalse);
      expect(find.byType(BottomSheet), findsNothing);
      expect(
        tester
            .widget<TranscriptTranslateSettingsSheet>(
              find.byType(TranscriptTranslateSettingsSheet),
            )
            .embedded,
        isTrue,
      );
      final providers = find.byType(
        CapsuleDropdownButtonFormField<SubtitleTranslateProvider>,
      );
      tester
          .widget<CapsuleDropdownButtonFormField<SubtitleTranslateProvider>>(
            providers,
          )
          .onChanged!(SubtitleTranslateProvider.local);
      await tester.pumpAndSettle();
      expect(find.text('模型中心'), findsOneWidget);
      tester
          .widget<CapsuleDropdownButtonFormField<SubtitleTranslateProvider>>(
            providers,
          )
          .onChanged!(SubtitleTranslateProvider.ai);
      await tester.pumpAndSettle();
      final prompt = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == '提示词',
      );
      await tester.ensureVisible(prompt);
      await tester.enterText(prompt, '专有名词保持原文');
      expect(
        TranscriptTranslateChoice.current(translation).aiOptions.customPrompt,
        '专有名词保持原文',
      );
      // Collapse before the debounce finishes; disposal must flush the prompt.
      await tap(options);
      expect(find.byType(TranscriptTranslateSettingsSheet), findsNothing);
      expect(translation.aiOptions.customPrompt, '专有名词保持原文');
      expect(
        (await AiSubtitleTranslationSettings.load()).customPrompt,
        '专有名词保持原文',
      );
      expect(translate, isFalse);
      expect((await SubtitleOptimizationSettings.load()).enabled, isFalse);
      await tap(
        find.byKey(const ValueKey('ai-transcription-translation-toggle')),
      );
      expect(translate, isTrue);
      await tap(options);
      expect(tester.widget<TextField>(prompt).controller!.text, '专有名词保持原文');
      await tap(options);
      expect(translate, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'language can be selected directly and model switching hides unsupported hotwords',
    (tester) async {
      await tester.pumpWidget(shell(SizedBox(width: 420, child: config())));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('transcription-language-summary')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('英语'));
      await tester.pumpAndSettle();
      expect(center.selectedLanguage, 'en');
      expect(find.text('识别语言：英语'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('transcription-method-summary')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('SenseVoice Small'));
      await tester.pumpAndSettle();
      expect(center.asrProfile.model, 'sensevoice-small-int8');
      expect(find.byKey(const ValueKey('video-hotwords-button')), findsNothing);
      expect(find.textContaining('本地模型 · SenseVoice Small'), findsOneWidget);
    },
  );

  testWidgets('custom service displays both interface name and actual model', (
    tester,
  ) async {
    const profile = ModelServiceProfile(
      id: 'my-api',
      name: '我的语音接口',
      kind: TranscriptionServiceKind.openai,
      endpoint: 'http://localhost:1234',
      model: 'custom-speech-model',
    );
    center.profiles[profile.id] = profile;
    center.asrProfileId = profile.id;
    await tester.pumpWidget(shell(config()));
    await tester.pumpAndSettle();
    expect(find.textContaining('我的语音接口 · custom-speech-model'), findsOneWidget);
    expect(find.byKey(const ValueKey('video-hotwords-button')), findsNothing);
  });

  testWidgets('open editor remains bound to its video when playback changes', (
    tester,
  ) async {
    var mediaKey = 'id:a';
    late StateSetter change;
    await tester.pumpWidget(
      shell(
        StatefulBuilder(
          builder: (_, setState) {
            change = setState;
            return config(key: mediaKey);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await openWords(tester);
    await tester.enterText(
      find.byKey(const ValueKey('video-hotwords-input')),
      '张三\nOpenAI',
    );
    change(() => mediaKey = 'id:b');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('apply-video-hotwords')));
    await tester.pumpAndSettle();
    expect(words.wordsFor('id:a'), '张三\nOpenAI');
    expect(words.wordsFor('id:b'), isEmpty);
    await openWords(tester);
    expect(editor(tester).controller!.text, isEmpty);
    await tester.tap(find.byTooltip('关闭热词编辑器'));
    await tester.pumpAndSettle();
    change(() => mediaKey = 'id:a');
    await tester.pump();
    expect(find.text('热词 · 2 条'), findsOneWidget);
  });

  testWidgets(
    'named presets save separately and apply with one click to another video',
    (tester) async {
      await tester.pumpWidget(shell(config()));
      await tester.pumpAndSettle();
      await openWords(tester);
      await tester.enterText(
        find.byKey(const ValueKey('video-hotwords-input')),
        'Transformer\n张三',
      );
      await tester.tap(find.byKey(const ValueKey('save-hotword-preset')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('hotword-preset-name')),
        '人工智能访谈',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      final preset = words.presets.single;
      expect(preset.name, '人工智能访谈');
      expect(words.wordsFor('id:a'), isEmpty);
      await tester.tap(find.byKey(const ValueKey('apply-video-hotwords')));
      await tester.pumpAndSettle();
      await tester.pumpWidget(shell(config(key: 'id:b')));
      await tester.pumpAndSettle();
      await openWords(tester);
      expect(editor(tester).controller!.text, isEmpty);
      await tester.tap(
        find.byKey(ValueKey('apply-hotword-preset-${preset.id}')),
      );
      await tester.pump();
      expect(editor(tester).controller!.text, 'Transformer\n张三');
      expect(words.wordsFor('id:b'), isEmpty);
      await tester.tap(find.byKey(const ValueKey('apply-video-hotwords')));
      await tester.pumpAndSettle();
      expect(words.wordsFor('id:b'), 'Transformer\n张三');
    },
  );

  testWidgets(
    'preset menu renames updates and deletes without rewriting video words',
    (tester) async {
      await words.savePreset(name: '项目术语', words: '旧术语');
      await tester.pumpWidget(shell(config()));
      await tester.pumpAndSettle();
      await openWords(tester);
      await tester.tap(find.byTooltip('管理预设 项目术语'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('hotword-preset-name')),
        '团队成员',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(words.presets.single.name, '团队成员');
      await tester.enterText(
        find.byKey(const ValueKey('video-hotwords-input')),
        '张三\n李四',
      );
      await tester.tap(find.byTooltip('管理预设 团队成员'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('用当前热词更新'));
      await tester.pumpAndSettle();
      expect(words.presets.single.words, '张三\n李四');
      expect(words.wordsFor('id:a'), isEmpty);
      await tester.tap(find.byTooltip('管理预设 团队成员'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除预设'));
      await tester.pumpAndSettle();
      expect(words.presets, isEmpty);
      expect(editor(tester).controller!.text, '张三\n李四');
      await tester.tap(find.byTooltip('关闭热词编辑器'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('failed storage keeps the edited words available for retry', (
    tester,
  ) async {
    var fail = false;
    final prefs = await SharedPreferences.getInstance();
    final unstable = TranscriptionHotwordStore(
      preferences: () async {
        if (fail) throw StateError('模拟保存失败');
        return prefs;
      },
    );
    await unstable.load();
    await tester.pumpWidget(shell(config(store: unstable)));
    await tester.pumpAndSettle();
    await openWords(tester);
    await tester.enterText(
      find.byKey(const ValueKey('video-hotwords-input')),
      '尚未保存的术语',
    );
    fail = true;
    await tester.tap(find.byKey(const ValueKey('apply-video-hotwords')));
    await tester.pumpAndSettle();
    expect(editor(tester).controller!.text, '尚未保存的术语');
    expect(find.byKey(const ValueKey('hotword-editor-error')), findsOneWidget);
    expect(unstable.wordsFor('id:a'), isEmpty);
    fail = false;
    await tester.tap(find.byKey(const ValueKey('apply-video-hotwords')));
    await tester.pumpAndSettle();
    expect(unstable.wordsFor('id:a'), '尚未保存的术语');
    await tester.pumpWidget(const SizedBox());
    unstable.dispose();
  });

  for (final entry in [
    (const Size(390, 844), 390.0, 1.0, 0.0),
    (const Size(320, 568), 320.0, 1.6, 240.0),
    (const Size(844, 390), 310.0, 1.6, 200.0),
    (const Size(1440, 900), 420.0, 1.0, 0.0),
  ]) {
    testWidgets('panel and hotword editor fit ${entry.$1}, keyboard ${entry.$4}', (
      tester,
    ) async {
      tester.view.physicalSize = entry.$1;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      if (const bool.fromEnvironment('AI_CONFIGURATION_PREVIEWS')) {
        await tester.runAsync(() async {
          for (final font in {
            'Noto Sans SC': 'assets/fonts/NotoSansSC-Variable.ttf',
            'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
          }.entries) {
            await (FontLoader(
              font.key,
            )..addFont(rootBundle.load(font.value))).load();
          }
        });
      }
      final manager = TranscriptionManager(
        modelCenter: center,
        hotwordStore: words,
      );
      final capture = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true).copyWith(
            textTheme: ThemeData.dark().textTheme.apply(
              fontFamily: 'Noto Sans SC',
            ),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(entry.$3)),
            child: child!,
          ),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: entry.$2,
                child: RepaintBoundary(
                  key: capture,
                  child: MultiProvider(
                    providers: [
                      ChangeNotifierProvider<TranscriptionManager>.value(
                        value: manager,
                      ),
                      ChangeNotifierProvider<SubtitleTranslateSettings>.value(
                        value: translation,
                      ),
                    ],
                    child: AiTranscriptionPanel(
                      videoPath: 'lecture.mp4',
                      videoId: 'a',
                      onCompleted: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      Future<void> preview(String suffix) async {
        if (!const bool.fromEnvironment('AI_CONFIGURATION_PREVIEWS')) return;
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(capture),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1.5);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            'artifacts/transcription_stage_redesign/transcription-${entry.$1.width.toInt()}-${entry.$3}-$suffix.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }

      await preview('panel');
      if (const bool.fromEnvironment('AI_CONFIGURATION_PREVIEWS') &&
          entry.$3 == 1) {
        final options = find.byKey(
          const ValueKey('ai-transcription-translation-settings'),
        );
        await tester.ensureVisible(options);
        await tester.tap(options);
        await tester.pumpAndSettle();
        await preview('translation-options');
        await tester.tap(options);
        await tester.pumpAndSettle();
      }
      await openWords(tester);
      await tester.enterText(
        find.byKey(const ValueKey('video-hotwords-input')),
        '张三\nTransformer\nOpenAI',
      );
      await words.savePreset(name: '技术访谈', words: 'OpenAI\nTransformer');
      await tester.pumpAndSettle();
      tester.view.viewInsets = FakeViewPadding(bottom: entry.$4);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('apply-video-hotwords')).hitTestable(),
        findsOneWidget,
      );
      if (const bool.fromEnvironment('AI_CONFIGURATION_PREVIEWS')) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find
              .ancestor(
                of: find.byType(Dialog).first,
                matching: find.byType(RepaintBoundary),
              )
              .first,
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            'artifacts/transcription_stage_redesign/transcription-${entry.$1.width.toInt()}-${entry.$3}-hotwords.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.byKey(const ValueKey('apply-video-hotwords')));
      await tester.pumpAndSettle();
      expect(words.wordsFor('id:a'), '张三\nTransformer\nOpenAI');
      await tester.pumpWidget(const SizedBox());
      manager.dispose();
    });
  }
}
