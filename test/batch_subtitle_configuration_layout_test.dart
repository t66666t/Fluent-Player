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
          ..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf')))
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
    (1152, 720, 1),
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
      if ((width < 600 || height < 600) && scale == 1) {
        expect(
          tester
              .getSize(find.byKey(const ValueKey('batch-configuration-bar')))
              .height,
          lessThanOrEqualTo(45),
          reason:
              'The collapsed phone/short-window strip must keep its original compact height.',
        );
      }
      if (find.byTooltip('展开配置详情').evaluate().isNotEmpty) {
        await tester.tap(find.byTooltip('展开配置详情'));
        await tester.pumpAndSettle();
      }
      expect(
        find.textContaining(
          manager.modelCenter.asrProfile.local
              ? manager.modelCenter
                        .artifact(manager.modelCenter.asrProfile.model)
                        ?.name ??
                    manager.modelCenter.asrProfile.name
              : manager.modelCenter.asrProfile.name,
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(find.text('仅转录'), findsOneWidget);
      expect(find.byType(Switch), findsOneWidget);
      expect(
        find.byKey(const ValueKey('batch-translation-settings')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('batch-transcription-settings')),
        findsOneWidget,
      );
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
      } else if (find
          .byKey(const ValueKey('batch-configuration-stacked'))
          .evaluate()
          .isNotEmpty) {
        expect(
          tester.getRect(transcriptionAction).bottom,
          lessThan(tester.getRect(action).top),
        );
        expect(
          tester.getRect(action).left,
          tester.getRect(transcriptionAction).left,
        );
        expect(
          tester.getRect(action).right,
          tester.getRect(transcriptionAction).right,
        );
        expect(
          tester.getRect(action).height,
          tester.getRect(transcriptionAction).height,
        );
        final language = tester.getRect(
          find.byKey(const ValueKey('batch-transcription-language')),
        );
        final mode = tester.getRect(
          find.byKey(const ValueKey('batch-current-mode')),
        );
        expect(
          language.center.dy,
          closeTo(tester.getRect(transcriptionAction).center.dy, .1),
        );
        expect(mode.center.dy, closeTo(tester.getRect(action).center.dy, .1));
        expect(language.right, closeTo(mode.right, .1));
      }
      if (width >= 1152 && scale == 1) {
        expect(
          find.byKey(const ValueKey('batch-configuration-inline')),
          findsOneWidget,
        );
        final language = tester.getRect(
          find.byKey(const ValueKey('batch-transcription-language')),
        );
        final mode = tester.getRect(
          find.byKey(const ValueKey('batch-current-mode')),
        );
        for (final rect in [tester.getRect(action), language, mode]) {
          expect(
            rect.center.dy,
            closeTo(tester.getRect(transcriptionAction).center.dy, .1),
          );
          expect(
            rect.height,
            closeTo(tester.getRect(transcriptionAction).height, .1),
          );
        }
        for (final key in [
          'batch-transcription-summary',
          'batch-translation-summary',
        ]) {
          final summary = find.byKey(ValueKey(key));
          final paragraph = tester.renderObject<RenderParagraph>(summary);
          expect(
            paragraph.didExceedMaxLines,
            isFalse,
            reason: '$key should fit without clipping at $width',
          );
          expect(tester.widget<Text>(summary).maxLines, 1);
          expect(tester.widget<Text>(summary).softWrap, isFalse);
        }
      }
      final bar = find.byKey(const ValueKey('batch-configuration-bar'));
      expect(tester.getRect(action).right, lessThanOrEqualTo(width));
      expect(tester.getSize(bar).height, lessThan(height / 2));
      if (width >= 1152 && scale == 1) {
        expect(tester.getSize(bar).height, lessThanOrEqualTo(54));
      }
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
            '.artifacts/batch-subtitle/config-v3-${width.toInt()}-$suffix.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
          final renderBoundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(boundary),
          );
          final rect = tester.getRect(bar);
          final strip = await (renderBoundary.debugLayer! as OffsetLayer)
              .toImage(
                Rect.fromLTWH(0, rect.top, width, rect.height),
                pixelRatio: 1.5,
              );
          final stripBytes = await strip.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await File(
            '.artifacts/batch-subtitle/config-v3-${width.toInt()}-$suffix-bar.png',
          ).writeAsBytes(stripBytes!.buffer.asUint8List());
          strip.dispose();
          final header = await (renderBoundary.debugLayer! as OffsetLayer)
              .toImage(Rect.fromLTWH(0, 0, width, rect.bottom + 14));
          final headerBytes = await header.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await File(
            '.artifacts/batch-subtitle/config-v3-${width.toInt()}-$suffix-header.png',
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
    'rotation and a constrained tablet pane keep aligned controls and the current mode',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService()..resetForTest();
      await settings.init();
      await settings.updateBatchSubtitleTranslateEnabled(true);
      final center = ModelCenterService()..loaded = true;
      center.profiles['layout'] = const ModelServiceProfile(
        id: 'layout',
        name: '示例本地模型',
        kind: TranscriptionServiceKind.local,
        model: 'layout-model',
      );
      center.asrProfileId = 'layout';
      final translation = SubtitleTranslateSettings(modelCenter: center);
      await translation.ensureLoaded();
      final paneWidth = ValueNotifier<double>(double.infinity);
      addTearDown(paneWidth.dispose);
      addTearDown(translation.dispose);
      addTearDown(center.dispose);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1152, 720);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: ValueListenableBuilder<double>(
                valueListenable: paneWidth,
                builder: (context, width, _) => SizedBox(
                  width: width,
                  child: BatchSubtitleConfigurationBar(
                    settings: settings,
                    modelCenter: center,
                    translateSettings: translation,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final state = tester.state(find.byType(BatchSubtitleConfigurationBar));
      expect(
        find.byKey(const ValueKey('batch-configuration-inline')),
        findsOneWidget,
      );
      paneWidth.value = 680;
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('batch-configuration-stacked')),
        findsOneWidget,
      );
      for (final size in [
        const Size(768, 1024),
        const Size(390, 844),
        const Size(1152, 720),
      ]) {
        paneWidth.value = double.infinity;
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        final asr = tester.getRect(
          find.byKey(const ValueKey('batch-transcription-settings')),
        );
        final translator = tester.getRect(
          find.byKey(const ValueKey('batch-translation-settings')),
        );
        expect(asr.height, translator.height);
        expect(
          tester
              .widget<Switch>(
                find.byKey(const ValueKey('batch-translation-enabled')),
              )
              .value,
          isTrue,
        );
        expect(settings.batchSubtitleTranslateEnabled, isTrue);
        expect(center.asrProfileId, 'layout');
        expect(
          tester.state(find.byType(BatchSubtitleConfigurationBar)),
          same(state),
        );
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

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

  testWidgets('long ASR names stay on one line and react to model changes', (
    tester,
  ) async {
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
    final summary = tester.widget<Text>(
      find.byKey(const ValueKey('batch-transcription-summary')),
    );
    expect(summary.maxLines, 1);
    expect(summary.softWrap, isFalse);
    expect(summary.data, contains('测试接口的超长名称'));
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
