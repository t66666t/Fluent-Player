import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_screen.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/screens/batch_subtitle_screen.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/widgets/batch_subtitle_configuration_bar.dart';

class _Routes extends NavigatorObserver {
  Route<dynamic>? last;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    last = route;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final preview = Platform.environment['BATCH_CONFIGURATION_PREVIEW'] == '1';
  setUpAll(() async {
    if (!preview) return;
    await (FontLoader('Noto Sans SC')
          ..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'))
          ..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Medium.otf'))
          ..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Bold.otf')))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  for (final (width, height, scale) in <(double, double, double)>[
    (320, 568, 1),
    (390, 844, 1),
    (768, 1024, 1),
    (1024, 768, 1),
    (1280, 800, 1),
    (1920, 1080, 1),
    (320, 740, 1.6),
    (568, 320, 1),
    (800, 360, 1),
    (320, 568, 2),
  ]) {
    testWidgets('batch configuration at $width x $height text $scale', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService()..resetForTest();
      await settings.init();
      await settings.updateBatchSubtitleTranslateEnabled(false);
      final translate = SubtitleTranslateSettings();
      await translate.ensureLoaded();
      final manager = TranscriptionManager(settings: settings);
      addTearDown(manager.dispose);
      addTearDown(translate.dispose);
      tester.view.physicalSize = Size(width, height);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const boundary = ValueKey('batch-preview');
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: settings),
            ChangeNotifierProvider.value(value: translate),
            ChangeNotifierProvider<TranscriptionManager>.value(value: manager),
            ChangeNotifierProvider<LibraryService>.value(
              value: LibraryService(),
            ),
          ],
          child: RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                useMaterial3: true,
                brightness: Brightness.dark,
                scaffoldBackgroundColor: const Color(0xFF121212),
                colorScheme: const ColorScheme.dark(
                  primary: Color(0xFF2196F3),
                  surface: Color(0xFF191919),
                ),
                fontFamily: 'Noto Sans SC',
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: const BatchSubtitleScreen(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final keepAwake = find.byKey(const ValueKey('batch-keep-screen-awake'));
      expect(keepAwake.hitTestable(), findsOneWidget);
      if (width < 600 || height < 600) {
        expect(
          tester.getRect(keepAwake).center.dy,
          closeTo(tester.getRect(find.byTooltip('更多操作')).center.dy, .1),
        );
      }
      await tester.tap(keepAwake);
      await tester.pumpAndSettle();
      expect(settings.batchSubtitleKeepScreenAwake, isTrue);
      await tester.tap(keepAwake);
      await tester.pumpAndSettle();
      expect(settings.batchSubtitleKeepScreenAwake, isFalse);
      if (find.byTooltip('展开配置详情').evaluate().isNotEmpty) {
        await tester.tap(find.byTooltip('展开配置详情'));
        await tester.pumpAndSettle();
      }
      expect(find.textContaining('公益接口', findRichText: true), findsOneWidget);
      expect(find.text('仅转录'), findsOneWidget);
      expect(find.byType(Switch), findsOneWidget);
      expect(find.text('翻译设置'), findsOneWidget);
      expect(find.text('转录设置'), findsOneWidget);
      expect(
        tester
            .widget<Switch>(
              find.byKey(const ValueKey('batch-translation-enabled')),
            )
            .value,
        isFalse,
      );
      final action = find.byKey(const ValueKey('batch-translation-settings'));
      final transcriptionAction = find.byKey(
        const ValueKey('batch-transcription-settings'),
      );
      expect(action.hitTestable(), findsOneWidget);
      expect(transcriptionAction.hitTestable(), findsOneWidget);
      expect(
        tester.getRect(transcriptionAction).right,
        lessThanOrEqualTo(width),
      );
      if (width < 600 || height < 600) {
        expect(
          tester.getRect(transcriptionAction).top,
          tester.getRect(action).top,
        );
        expect(
          tester.getRect(transcriptionAction).right,
          lessThanOrEqualTo(tester.getRect(action).left),
        );
      } else if (width < 1100 * scale) {
        expect(
          tester.getRect(transcriptionAction).bottom,
          lessThan(tester.getRect(action).top),
        );
      }
      final bar = find.byKey(const ValueKey('batch-configuration-bar'));
      expect(tester.getRect(action).right, lessThanOrEqualTo(width));
      expect(tester.getSize(bar).height, lessThan(height / 2));
      if (width == 320 && scale == 1) {
        final autoDelete = settings.batchSubtitleAutoDelete;
        for (final expected in [!autoDelete, autoDelete]) {
          await tester.tap(find.byTooltip('更多操作'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('完成后自动移除'));
          await tester.pumpAndSettle();
          expect(settings.batchSubtitleAutoDelete, expected);
          expect(tester.takeException(), isNull);
        }
      }

      Future<void> capture(String suffix) async {
        if (!preview || scale != 1) return;
        await tester.runAsync(() async {
          final image = await tester
              .renderObject<RenderRepaintBoundary>(find.byKey(boundary))
              .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            '.artifacts/batch-subtitle/config-v2-${width.toInt()}-$suffix.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
          final renderBoundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(boundary),
          );
          final rect = tester.getRect(bar);
          final header = await (renderBoundary.debugLayer! as OffsetLayer)
              .toImage(Rect.fromLTWH(0, 0, width, rect.bottom + 14));
          final headerBytes = await header.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await File(
            '.artifacts/batch-subtitle/config-v2-${width.toInt()}-$suffix-header.png',
          ).writeAsBytes(headerBytes!.buffer.asUint8List());
          header.dispose();
        });
      }

      if (preview && find.byTooltip('收起配置详情').evaluate().isNotEmpty) {
        await tester.tap(find.byTooltip('收起配置详情'));
        await tester.pumpAndSettle();
        await capture('compact');
        await tester.tap(find.byTooltip('展开配置详情'));
        await tester.pumpAndSettle();
      }
      await capture('off');
      final toggle = find.byKey(const ValueKey('batch-translation-enabled'));
      expect(toggle.hitTestable(), findsOneWidget);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(settings.batchSubtitleTranslateEnabled, isTrue);
      expect(tester.widget<Switch>(toggle).value, isTrue);
      expect(find.text('仅转录'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('batch-current-mode')),
          matching: find.text('转录并翻译'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await capture('on');
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(find.text('翻译服务'), findsOneWidget);
      // Opening settings must not toggle the batch mode.
      expect(settings.batchSubtitleTranslateEnabled, isTrue);
      await capture('settings');
      final sheetTitle = find.text('翻译设置').last;
      Navigator.of(tester.element(sheetTitle)).pop();
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(settings.batchSubtitleTranslateEnabled, isFalse);
      expect(find.text('仅转录'), findsOneWidget);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(find.text('翻译服务'), findsOneWidget);
      expect(settings.batchSubtitleTranslateEnabled, isFalse);
      Navigator.of(tester.element(find.text('翻译设置').last)).pop();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'transcription settings keeps the batch mode and shared defaults',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService()..resetForTest();
      await settings.init();
      final center = ModelCenterService();
      final translate = SubtitleTranslateSettings(modelCenter: center);
      await translate.ensureLoaded();
      final routes = _Routes();
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [routes],
          home: Scaffold(
            body: BatchSubtitleConfigurationBar(
              settings: settings,
              translateSettings: translate,
              modelCenter: center,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final enabled in [false, true]) {
        await settings.updateBatchSubtitleTranslateEnabled(enabled);
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('batch-transcription-settings')),
        );
        final route = routes.last! as MaterialPageRoute<void>;
        final screen =
            route.builder(
                  tester.element(find.byType(BatchSubtitleConfigurationBar)),
                )
                as ModelCenterScreen;
        expect(screen.transcriptionOnly, isTrue);
        expect(screen.service, same(center));
        expect(screen.translateSettings, same(translate));
        route.navigator!.removeRoute(route);
        await tester.pumpAndSettle();
        expect(settings.batchSubtitleTranslateEnabled, enabled);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      translate.dispose();
      center.dispose();
    },
  );

  testWidgets('long ASR names wrap and react to model changes', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService()..resetForTest();
    await settings.init();
    final center = ModelCenterService();
    final translate = SubtitleTranslateSettings(modelCenter: center);
    await translate.ensureLoaded();
    addTearDown(translate.dispose);
    addTearDown(center.dispose);
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BatchSubtitleConfigurationBar(
            settings: settings,
            translateSettings: translate,
            modelCenter: center,
          ),
        ),
      ),
    );
    center.profiles['test'] = const ModelServiceProfile(
      id: 'test',
      name: '测试接口的超长名称用于检查手机竖屏换行',
      kind: TranscriptionServiceKind.openai,
      model: 'whisper-large-v3-turbo-long-model-name',
    );
    center.asrProfileId = 'test';
    center.selectedLanguage = 'yue';
    center.notifyListeners();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('展开配置详情'));
    await tester.pumpAndSettle();
    expect(find.textContaining('粤语', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
    await translate.setMode(SubtitleTranslationMode.fixed);
    await translate.setLanguages(target: 'ja');
    await tester.pumpAndSettle();
    expect(find.textContaining('日语', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
