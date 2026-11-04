import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final preview = Platform.environment['SUBTITLE_TOOLBAR_PREVIEW'] == '1';
  setUpAll(() async {
    if (!preview) return;
    await (FontLoader('Noto Sans SC')
          ..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf')))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'autoScrollSubtitles': false,
      'portraitSidebarShowTimestamps': false,
      'landscapeSidebarShowTimestamps': false,
    });
    SettingsService().resetForTest();
    await SettingsService().init();
  });

  testWidgets(
    'haptics: subtitle reading controls pulse only on user changes',
    (tester) async {
      final feedback = <Object?>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'HapticFeedback.vibrate') {
              feedback.add(call.arguments);
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await _pumpSidebar(tester, 600, true, []);
      expect(feedback, isEmpty);
      await tester.tap(find.byIcon(Icons.article));
      await tester.pumpAndSettle();
      expect(feedback, ['HapticFeedbackType.selectionClick']);
      feedback.clear();
      await tester.tap(find.byIcon(Icons.article));
      await tester.pumpAndSettle();
      expect(feedback, isEmpty);
      await tester.tap(find.byTooltip('仅显示第一行'));
      await tester.pumpAndSettle();
      expect(feedback, ['HapticFeedbackType.selectionClick']);
      feedback.clear();
      await tester.tap(find.byTooltip('定位到当前字幕'));
      await tester.pumpAndSettle();
      expect(feedback, ['HapticFeedbackType.lightImpact']);
      feedback.clear();
      await tester.pump(const Duration(seconds: 2));
      expect(feedback, isEmpty);
      await SettingsService().saveEnableHapticFeedback(false);
      await tester.tap(find.byIcon(Icons.list));
      await tester.tap(find.byTooltip('文稿显示设置'));
      await tester.pumpAndSettle();
      expect(feedback, isEmpty);
      expect(SettingsService().subtitleViewMode, 0);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  for (final portrait in [true, false]) {
    for (final width in [
      80.0,
      160.0,
      240.0,
      280.0,
      320.0,
      360.0,
      390.0,
      600.0,
      768.0,
      1200.0,
      1920.0,
    ]) {
      testWidgets('all actions fit width=$width portrait=$portrait', (
        tester,
      ) async {
        final calls = <String>[];
        tester.view.physicalSize = Size(width < 800 ? 800 : width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await _pumpSidebar(tester, width, portrait, calls);
        final toolbar = find.byKey(const ValueKey('subtitle-toolbar'));
        final bounds = tester.getRect(toolbar);
        final buttons = find.descendant(
          of: toolbar,
          matching: find.byType(InkWell),
        );
        final count = portrait ? 15 : 11;
        expect(buttons, findsNWidgets(count));
        expect(find.byType(PopupMenuButton), findsNothing);
        for (final tooltip in ['字幕样式设置', '字幕编辑', '合成视频', '识别画面字幕（OCR）']) {
          expect(
            find.byTooltip(tooltip),
            portrait ? findsOneWidget : findsNothing,
          );
        }
        expect(find.byTooltip('扫描内嵌字幕'), findsNothing);
        expect(
          find.descendant(of: toolbar, matching: find.byType(Scrollable)),
          findsNothing,
        );
        var previousRight = bounds.left;
        for (var index = 0; index < count; index++) {
          final rect = tester.getRect(buttons.at(index));
          expect(rect.left, greaterThanOrEqualTo(previousRight - 0.001));
          expect(rect.right, lessThanOrEqualTo(bounds.right + 0.001));
          expect(rect.top, bounds.top);
          expect(rect.height, 44);
          expect(rect.width, greaterThan(0));
          expect(rect.width, lessThanOrEqualTo(36.001));
          final glyph = tester.renderObject<RenderBox>(
            find.descendant(
              of: buttons.at(index),
              matching: find.byType(FittedBox),
            ),
          );
          final painted = MatrixUtils.transformRect(
            glyph.getTransformTo(null),
            glyph.paintBounds,
          );
          expect(painted.left, greaterThanOrEqualTo(rect.left - 0.001));
          expect(painted.right, lessThanOrEqualTo(rect.right + 0.001));
          expect(painted.height, lessThanOrEqualTo(20.001));
          previousRight = rect.right;
        }
        expect(previousRight, lessThanOrEqualTo(bounds.right + 0.001));
        final settingsRect = tester.getRect(buttons.last);
        final precedingRect = tester.getRect(buttons.at(count - 2));
        expect(settingsRect.left, closeTo(precedingRect.right, 0.001));
        expect(settingsRect.width, closeTo(precedingRect.width, 0.001));
        if (width >= 600) {
          expect(settingsRect.width, 36);
          expect(settingsRect.right, lessThan(bounds.right));
        }
        for (final (group, count) in [('view', 2), ('language', 3)]) {
          expect(
            find.descendant(
              of: find.byKey(ValueKey('subtitle-toolbar-$group-group')),
              matching: find.byType(InkWell),
            ),
            findsNWidgets(count),
          );
        }
        await tester.tap(find.byTooltip('自动跟随字幕'));
        await tester.pumpAndSettle();
        final icon = tester.renderObject<RenderBox>(
          find.byIcon(Icons.gps_fixed),
        );
        final badge = tester.renderObject<RenderBox>(find.text('A'));
        final iconTransform = icon.getTransformTo(null);
        final badgeTransform = badge.getTransformTo(null);
        final iconScale =
            MatrixUtils.transformRect(
              iconTransform,
              Offset.zero & icon.size,
            ).width /
            icon.size.width;
        final badgeScale =
            MatrixUtils.transformRect(
              badgeTransform,
              Offset.zero & badge.size,
            ).width /
            badge.size.width;
        // Check painted transforms, not nominal font sizes: the badge and icon
        // must shrink by the same factor, including with 2x system text.
        expect(badgeScale, closeTo(iconScale, 0.000001));
        expect(badgeScale, lessThanOrEqualTo(1.000001));
        if (width <= 160 || (portrait && width <= 280)) {
          expect(badgeScale, lessThan(1.0));
        }
        if (!portrait && width >= 240) expect(badgeScale, 1);
        final badgeBounds = MatrixUtils.transformRect(
          badgeTransform,
          Offset.zero & badge.size,
        );
        final followBounds = tester.getRect(find.byTooltip('自动跟随字幕'));
        expect(badgeBounds.left, greaterThanOrEqualTo(followBounds.left));
        expect(badgeBounds.right, lessThanOrEqualTo(followBounds.right));
        expect(badgeBounds.top, greaterThanOrEqualTo(followBounds.top));
        expect(badgeBounds.bottom, lessThanOrEqualTo(followBounds.bottom));
        if (preview && portrait && [240.0, 320.0, 600.0].contains(width)) {
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('toolbar-preview')),
            );
            final image = await (boundary.debugLayer! as OffsetLayer).toImage(
              Rect.fromLTWH(0, 0, width, 80),
              pixelRatio: 3,
            );
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              '.artifacts/subtitle-toolbar/toolbar-${width.toInt()}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        // The important trailing action is visible and hit-testable without
        // scrolling, even when every optional action is present.
        await tester.tap(find.byTooltip('设置'));
        expect(calls, ['settings']);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('compact actions retain callbacks, modes and selection state', (
    tester,
  ) async {
    final calls = <String>[];
    await _pumpSidebar(tester, 280, true, calls);
    for (final icon in [
      Icons.auto_awesome_outlined,
      Icons.subtitles_outlined,
      Icons.style_outlined,
      Icons.edit_note,
      Icons.movie_creation_outlined,
      Icons.document_scanner_outlined,
      Icons.settings,
    ]) {
      await tester.tap(find.byIcon(icon));
    }
    expect(calls, [
      'chat',
      'manager',
      'style',
      'editor',
      'compose',
      'ocr',
      'settings',
    ]);
    await tester.tap(find.byIcon(Icons.article));
    await tester.pumpAndSettle();
    expect(SettingsService().subtitleViewMode, 1);
    await tester.tap(find.byIcon(Icons.list));
    await tester.pumpAndSettle();
    expect(SettingsService().subtitleViewMode, 0);
    for (final tooltip in ['仅显示第一行', '仅显示第二行', '双语显示']) {
      await tester.tap(find.byTooltip(tooltip));
      await tester.pumpAndSettle();
      final semantics = tester.widget<Semantics>(
        find
            .ancestor(
              of: find.byTooltip(tooltip),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(semantics.properties.selected, isTrue);
    }
    await tester.tap(find.byTooltip('自动跟随字幕'));
    await tester.pumpAndSettle();
    expect(SettingsService().autoScrollSubtitles, isTrue);
    expect(
      tester.widget<Icon>(find.byIcon(Icons.gps_fixed)).color,
      Colors.blueAccent,
    );
    expect(find.text('A'), findsOneWidget);
    await tester.tap(find.byTooltip('自动跟随字幕'));
    await tester.pumpAndSettle();
    expect(SettingsService().autoScrollSubtitles, isFalse);
    expect(
      tester.widget<Icon>(find.byIcon(Icons.gps_not_fixed)).color,
      Colors.white70,
    );
    expect(find.text('A'), findsNothing);
    await tester.tap(find.byTooltip('定位到当前字幕'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings follows actions with optional actions absent', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 600, child: SubtitleSidebar(subtitles: [])),
        ),
      ),
    );
    final toolbar = tester.getRect(
      find.byKey(const ValueKey('subtitle-toolbar')),
    );
    final settings = tester.getRect(find.byTooltip('设置'));
    final preceding = tester.getRect(find.byTooltip('定位到当前字幕'));
    expect(settings.left, preceding.right);
    expect(settings.width, preceding.width);
    expect(settings.right, lessThan(toolbar.right));
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpSidebar(
  WidgetTester tester,
  double width,
  bool portrait,
  List<String> calls,
) => tester.pumpWidget(
  MaterialApp(
    theme: ThemeData(fontFamily: 'Noto Sans SC'),
    home: MediaQuery(
      // Deliberately wider than the panel, with large system text: sizing must
      // follow local constraints and cannot depend on the device orientation.
      data: const MediaQueryData(
        size: Size(1000, 800),
        textScaler: TextScaler.linear(2),
      ),
      child: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            height: 500,
            child: RepaintBoundary(
              key: const ValueKey('toolbar-preview'),
              child: SubtitleSidebar(
                subtitles: [
                  SubtitleItem(
                    index: 0,
                    startTime: Duration.zero,
                    endTime: const Duration(seconds: 2),
                    text: '文稿',
                  ),
                ],
                isPortrait: portrait,
                isCompact: true,
                onOpenAiChat: () => calls.add('chat'),
                onOpenSubtitleManager: () => calls.add('manager'),
                onOpenSubtitleStyle: () => calls.add('style'),
                onOpenSubtitleEditor: () => calls.add('editor'),
                onOpenVideoCompose: () => calls.add('compose'),
                onOpenOcrSubtitle: () => calls.add('ocr'),
                onOpenSettings: () => calls.add('settings'),
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);
