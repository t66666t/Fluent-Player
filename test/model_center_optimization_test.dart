import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_screen.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/features/model_center/model_center_widgets.dart';
import 'package:video_player_app/features/model_center/model_device_info.dart';
import 'package:video_player_app/services/ai_subtitle_api_settings.dart';
import 'package:video_player_app/services/subtitle_optimization.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/widgets/subtitle_optimization_control.dart';
import 'package:video_player_app/widgets/ai_subtitle_api_dialog.dart';

class _Center extends ModelCenterService {
  _Center() {
    loaded = true;
    profiles['test-asr'] = const ModelServiceProfile(
      id: 'test-asr',
      name: '测试转录接口',
      kind: TranscriptionServiceKind.openai,
      model: 'recognizer',
    );
    asrProfileId = 'test-asr';
  }
  @override
  Future<void> initialize() async {}
  @override
  Future<void> save() async {}
  @override
  void rememberView() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const inherited = AiSubtitleApiSettings(
    baseUrl: 'https://translation.example/v1',
    model: 'translation-model',
  );
  const proofreader = AiSubtitleApiSettings(
    baseUrl: 'http://localhost:11434/v1',
    model: 'correction-model',
  );
  final preview =
      Platform.environment['MODEL_CENTER_OPTIMIZATION_PREVIEW'] == '1';
  setUpAll(() async {
    if (!preview) return;
    await (FontLoader('ModelPreview')
          ..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf')))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({
      AiSubtitleApiSettings.preferencesKey: jsonEncode(inherited.toJson()),
      SubtitleAiConnectionStore.preferencesKey: jsonEncode([
        SubtitleAiConnection('proofreader', '独立校对接口', proofreader).toJson(),
        SubtitleAiConnection('translator', '翻译接口', inherited).toJson(),
      ]),
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (_) async => null,
        );
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        ),
  );

  Future<GlobalKey> mount(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
    double scale = 1,
    bool transcriptionOnly = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final center = _Center();
    final translation = SubtitleTranslateSettings(modelCenter: center);
    await translation.ensureLoaded();
    addTearDown(translation.dispose);
    addTearDown(center.dispose);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark(useMaterial3: true).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Colors.blue,
              surface: Color(0xFF121212),
            ),
            textTheme: ThemeData.dark().textTheme.apply(
              fontFamily: preview ? 'ModelPreview' : null,
            ),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: ModelCenterScreen(
            service: center,
            translateSettings: translation,
            transcriptionOnly: transcriptionOnly,
            deviceInfo: const ModelDeviceInfo(
              memoryBytes: 16 * 1073741824,
              availableMemoryBytes: 12 * 1073741824,
              processors: 8,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return boundary;
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
    if (!preview) return;
    await tester.runAsync(() async {
      final image = await tester
          .renderObject<RenderRepaintBoundary>(find.byKey(key))
          .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File(
        '.artifacts/model-center-optimization/previews/$name.png',
      );
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final (size, scale) in [
    (const Size(320, 568), 1.0),
    (const Size(390, 844), 1.0),
    (const Size(1000, 900), 1.0),
    (const Size(1440, 900), 1.0),
    (const Size(1920, 1080), 1.0),
    (const Size(568, 320), 1.0),
    (const Size(320, 740), 1.6),
    (const Size(320, 740), 2.0),
  ]) {
    testWidgets(
      'optimization matches model center panels at $size scale $scale',
      (tester) async {
        final boundary = await mount(tester, size: size, scale: scale);
        final optimization = find.byKey(
          const ValueKey('model-center-optimization'),
        );
        expect(
          find.descendant(
            of: optimization,
            matching: find.byType(ModelCenterPanel),
          ),
          findsOneWidget,
        );
        expect(find.text('字幕优化'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('model-center-optimization-toggle')),
          findsOneWidget,
        );
        expect((await SubtitleOptimizationSettings.load()).enabled, isFalse);
        final asrRect = tester.getRect(
          find.byKey(const ValueKey('model-center-asr')),
        );
        final optRect = tester.getRect(optimization);
        final translateRect = tester.getRect(
          find.byKey(const ValueKey('model-center-translation')),
        );
        if (size.width >= 1280) {
          expect(optRect.top, closeTo(asrRect.top, .1));
          expect(translateRect.top, closeTo(asrRect.top, .1));
          expect(optRect.left, greaterThan(asrRect.right));
          expect(translateRect.left, greaterThan(optRect.right));
        } else if (size.width < 1000) {
          expect(optRect.top - asrRect.bottom, closeTo(12, .1));
          expect(translateRect.top - optRect.bottom, closeTo(12, .1));
        }
        await capture(tester, boundary, 'center-${size.width.toInt()}-$scale');
        for (final key in [
          'model-center-optimization-model',
          'model-center-optimization-prompt',
          'model-center-optimization-connections',
        ]) {
          final entry = find.byKey(ValueKey(key));
          await tester.ensureVisible(entry);
          await tester.pumpAndSettle();
          expect(entry.hitTestable(), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'optimization selection saves independently and follows translation only when requested',
    (tester) async {
      await const SubtitleOptimizationSettings(prompt: '保留口语。').save();
      final boundary = await mount(tester, size: const Size(390, 844));
      final prefs = await SharedPreferences.getInstance();
      final before = prefs.getString(AiSubtitleApiSettings.preferencesKey);
      await tap(
        tester,
        find.byKey(const ValueKey('model-center-optimization-toggle')),
      );
      expect((await SubtitleOptimizationSettings.load()).enabled, isTrue);
      await tap(
        tester,
        find.byKey(const ValueKey('model-center-optimization-model')),
      );
      expect(find.byType(AiSubtitleApiEditor), findsOneWidget);
      expect(
        find.byKey(const ValueKey('subtitle-optimization-prompt')),
        findsNothing,
      );
      await capture(tester, boundary, 'optimization-model');
      await tap(tester, find.byKey(const ValueKey('optimization-model-')));
      await tap(tester, find.text('独立校对接口').last);
      await tap(tester, find.text('保存并使用'));
      final saved = await SubtitleOptimizationSettings.load();
      expect(saved.connectionId, 'proofreader');
      expect(saved.prompt, '保留口语。');
      expect(prefs.getString(AiSubtitleApiSettings.preferencesKey), before);
      expect(find.text('correction-model'), findsOneWidget);
      final captured = await saved.capture();
      await AiSubtitleApiSettingsStore().save(
        inherited.copyWith(model: 'new-translation-model'),
      );
      await tester.pumpAndSettle();
      expect(find.text('correction-model'), findsOneWidget);
      expect(captured.endpoint!.model, 'correction-model');
      await tap(
        tester,
        find.byKey(const ValueKey('model-center-optimization-model')),
      );
      await tap(
        tester,
        find.byKey(const ValueKey('optimization-model-proofreader')),
      );
      await tap(tester, find.textContaining('跟随翻译的 AI 接口').last);
      await tap(tester, find.text('保存并使用'));
      expect((await SubtitleOptimizationSettings.load()).connectionId, isEmpty);
      expect(find.text('new-translation-model'), findsOneWidget);
      await const SubtitleOptimizationSettings().save();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Switch>(
              find.byKey(const ValueKey('model-center-optimization-toggle')),
            )
            .value,
        isFalse,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'prompt entry opens the existing expanded editor and saves shared defaults',
    (tester) async {
      final boundary = await mount(tester, size: const Size(390, 844));
      await tap(
        tester,
        find.byKey(const ValueKey('model-center-optimization-prompt')),
      );
      final prompt = find.byKey(const ValueKey('subtitle-optimization-prompt'));
      expect(
        tester.widget<TextField>(prompt).controller!.text,
        defaultSubtitleOptimizationPrompt,
      );
      expect(tester.widget<TextField>(prompt).maxLines, isNull);
      expect(find.text('保存').hitTestable(), findsOneWidget);
      await capture(tester, boundary, 'center-prompt');
      await tester.enterText(prompt, '只纠正有把握的错字，保留口语。');
      await tap(tester, find.text('保存'));
      expect(
        (await SubtitleOptimizationSettings.load()).prompt,
        '只纠正有把握的错字，保留口语。',
      );
      expect(find.text('字幕优化'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SubtitleOptimizationControl())),
      );
      await tester.pumpAndSettle();
      await tap(
        tester,
        find.byKey(const ValueKey('subtitle-optimization-prompt-button')),
      );
      expect(
        tester.widget<TextField>(prompt).controller!.text,
        '只纠正有把握的错字，保留口语。',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'manage connections uses the shared registry without replacing translation',
    (tester) async {
      await mount(tester);
      await tap(
        tester,
        find.byKey(const ValueKey('model-center-optimization-connections')),
      );
      expect(find.text('优化/翻译接口'), findsOneWidget);
      expect(find.text('新增接口'), findsOneWidget);
      await tap(tester, find.text('独立校对接口'));
      expect(
        (await SubtitleOptimizationSettings.load()).connectionId,
        'proofreader',
      );
      expect(
        (await AiSubtitleApiSettingsStore().loadMetadata()).model,
        inherited.model,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'transcription-only shortcut stays focused on transcription settings',
    (tester) async {
      await mount(tester, size: const Size(390, 844), transcriptionOnly: true);
      expect(find.byKey(const ValueKey('model-center-asr')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('model-center-optimization')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('model-center-translation')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
