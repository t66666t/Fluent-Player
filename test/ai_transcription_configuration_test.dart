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
      textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'MiSans'),
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

  testWidgets(
    'transcription and translation share the group under model settings',
    (tester) async {
      await tester.pumpWidget(shell(SizedBox(width: 420, child: config())));
      await tester.pumpAndSettle();
      final group = find.byKey(const ValueKey('ai-subtitle-methods'));
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
          matching: find.byKey(const ValueKey('translation-direction-summary')),
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
                find.byKey(const ValueKey('translation-direction-summary')),
              )
              .dy,
        ),
      );
      expect(find.byKey(const ValueKey('video-hotwords-input')), findsNothing);
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
            'MiSans': 'assets/fonts/MiSans-Regular.otf',
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
            textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'MiSans'),
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
          await File(
            '.artifacts/ai-transcription-settings-20261029/${entry.$1.width.toInt()}-$suffix.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }

      await preview('panel');
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
          await File(
            '.artifacts/ai-transcription-settings-20261029/${entry.$1.width.toInt()}-editor.png',
          ).writeAsBytes(data!.buffer.asUint8List());
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
