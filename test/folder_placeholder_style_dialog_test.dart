import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/folder_placeholder_style.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/adaptive_settings_dialog.dart';
import 'package:video_player_app/widgets/folder_placeholder_cover.dart';
import 'package:video_player_app/widgets/folder_placeholder_style_dialog.dart';
import 'package:video_player_app/widgets/media_library_layout_profile.dart';
import 'package:video_player_app/widgets/media_library_grid_card.dart';
import 'package:video_player_app/widgets/media_library_style_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SettingsService> readySettings() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();
    return settings;
  }

  testWidgets('设置窗口展示 3×2 真实卡片预览，拖滑条后面上的剪影尺寸跟着变', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final settings = await readySettings();
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsService>.value(
        value: settings,
        child: MaterialApp(
          theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
          home: const Scaffold(
            body: FolderPlaceholderStyleDialogBody(
              scope: MediaLibraryCardStyleScope.home,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(FolderPlaceholderStyleDialog.previewGridKey), findsOneWidget);
    expect(find.text('日剧'), findsWidgets);
    expect(find.text('Movies'), findsOneWidget);
    expect(find.text('音乐'), findsWidgets);
    expect(find.text('数学'), findsWidgets);
    expect(find.text('《三国演义》'), findsOneWidget);
    expect(find.text('2024'), findsWidgets);

    final sampleId = kFolderPlaceholderPreviewSamples.first.id;
    final before = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(FolderPlaceholderStyleDialog.previewGridKey),
        matching: find.byKey(
          FolderPlaceholderCover.silhouetteKeyFor(sampleId),
        ),
      ),
    );

    await tester.drag(
      find.byKey(const ValueKey<String>('folder-placeholder-slider-silhouetteScale')),
      const Offset(240, 0),
    );
    await tester.pumpAndSettle();

    final after = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(FolderPlaceholderStyleDialog.previewGridKey),
        matching: find.byKey(
          FolderPlaceholderCover.silhouetteKeyFor(sampleId),
        ),
      ),
    );
    expect(after.size!, greaterThan(before.size!));
    expect(
      settings.folderPlaceholderSettings.silhouetteScale,
      greaterThan(FolderPlaceholderSettings.defaults.silhouetteScale),
    );
  });

  Future<void> pumpDialog(WidgetTester tester, SettingsService settings) {
    return tester.pumpWidget(
      ChangeNotifierProvider<SettingsService>.value(
        value: settings,
        child: MaterialApp(
          theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
          home: const Scaffold(
            body: FolderPlaceholderStyleDialogBody(
              scope: MediaLibraryCardStyleScope.home,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('平板横屏预览不会占满高度，滑条保持在窗口内', (tester) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await pumpDialog(tester, await readySettings());
    await tester.pumpAndSettle();

    final previewSize = tester.getSize(
      find.byKey(FolderPlaceholderStyleDialog.previewGridKey),
    );
    expect(previewSize.height, lessThan(768 * 0.55));
    expect(find.text('日剧'), findsWidgets);
    expect(find.text('2024'), findsWidgets);

    final slider = find.byKey(
      const ValueKey<String>('folder-placeholder-slider-silhouetteScale'),
    );
    expect(slider, findsOneWidget);
    final sliderRect = tester.getRect(slider);
    expect(sliderRect.top, greaterThanOrEqualTo(0));
    expect(sliderRect.bottom, lessThanOrEqualTo(768));
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机竖屏预览限高后仍是 3×2，滑条无需滚过整屏预览', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final settings = await readySettings();
    await pumpDialog(tester, settings);
    await tester.pumpAndSettle();

    final previewSize = tester.getSize(
      find.byKey(FolderPlaceholderStyleDialog.previewGridKey),
    );
    expect(previewSize.height, lessThan(240));
    expect(find.text('日剧'), findsWidgets);
    expect(find.text('Movies'), findsOneWidget);
    expect(find.text('音乐'), findsWidgets);
    expect(find.text('数学'), findsWidgets);
    expect(find.text('《三国演义》'), findsOneWidget);
    expect(find.text('2024'), findsWidgets);

    final slider = find.byKey(
      const ValueKey<String>('folder-placeholder-slider-silhouetteScale'),
    );
    expect(slider, findsOneWidget);
    expect(tester.getRect(slider).bottom, lessThan(844));
    expect(tester.takeException(), isNull);

    final cardSize = tester.getSize(
      find.descendant(
        of: find.byKey(FolderPlaceholderStyleDialog.previewGridKey),
        matching: find.byType(MediaLibraryGridCard),
      ).first,
    );
    final expected = MediaLibraryLayoutDefaults.cardGrid(
      screenSize: const Size(390, 844),
      style: settings.homeCardStyleFor(const Size(390, 844)),
    );
    expect(cardSize.width / cardSize.height, closeTo(expected.aspectRatio, 0.02));
    final sampleId = kFolderPlaceholderPreviewSamples.first.id;
    final coverSize = tester.getSize(
      find.descendant(
        of: find.byKey(FolderPlaceholderStyleDialog.previewGridKey),
        matching: find.byKey(FolderPlaceholderCover.coverKeyFor(sampleId)),
      ),
    );
    expect(coverSize.width / coverSize.height, closeTo(16 / 9, 0.03));
  });

  testWidgets('桌面宽屏用左右分栏，预览与滑条同时可见', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await pumpDialog(tester, await readySettings());
    await tester.pumpAndSettle();

    final previewRect = tester.getRect(
      find.byKey(FolderPlaceholderStyleDialog.previewGridKey),
    );
    final sliderRect = tester.getRect(
      find.byKey(
        const ValueKey<String>('folder-placeholder-slider-silhouetteScale'),
      ),
    );
    expect(previewRect.height, lessThan(360));
    expect(sliderRect.left, greaterThan(previewRect.right - 8));
    expect(sliderRect.bottom, lessThanOrEqualTo(900));
    expect(tester.takeException(), isNull);
  });

  testWidgets('卡片样式表有共用的文件夹占位入口', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final settings = await readySettings();
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsService>.value(
        value: settings,
        child: MaterialApp(
          theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
          home: Builder(
            builder: (context) {
              return Scaffold(
                body: TextButton(
                  onPressed: () {
                    MediaLibraryStyleSheet.show(
                      context: context,
                      scope: MediaLibraryCardStyleScope.home,
                    );
                  },
                  child: const Text('open-sheet'),
                ),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('open-sheet'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('folder-placeholder-style-entry')),
      findsOneWidget,
    );
    expect(find.text('文件夹占位'), findsOneWidget);
    expect(find.text('渐变剪影'), findsOneWidget);
  });

  testWidgets('默认不显示封面文字，打开后预览才绘制字形', (tester) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final settings = await readySettings();
    await pumpDialog(tester, settings);
    await tester.pumpAndSettle();

    final sampleId = kFolderPlaceholderPreviewSamples.first.id;
    expect(settings.folderPlaceholderSettings.showCoverText, isFalse);
    expect(
      find.byKey(FolderPlaceholderCover.glyphKeyFor(sampleId)),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('folder-placeholder-show-cover-text')),
    );
    await tester.pumpAndSettle();

    expect(settings.folderPlaceholderSettings.showCoverText, isTrue);
    expect(
      find.byKey(FolderPlaceholderCover.glyphKeyFor(sampleId)),
      findsWidgets,
    );
    expect(find.text('显示封面文字'), findsOneWidget);
  });

  testWidgets('滑条是 0 到 100 且没有刻度点，上限芯片能改封面字数', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final settings = await readySettings();
    await pumpDialog(tester, settings);
    await tester.pumpAndSettle();

    final slider = tester.widget<Slider>(
      find.byKey(
        const ValueKey<String>('folder-placeholder-slider-silhouetteScale'),
      ),
    );
    expect(slider.min, 0);
    expect(slider.max, 100);
    expect(slider.divisions, isNull);
    expect(slider.value, closeTo(58, 0.2));

    await tester.tap(
      find.byKey(const ValueKey<String>('folder-placeholder-show-cover-text')),
    );
    await tester.pumpAndSettle();

    expect(find.text('2 字'), findsOneWidget);
    expect(find.text('三国'), findsWidgets);

    await tester.tap(
      find.byKey(const ValueKey<String>('folder-placeholder-max-text-4')),
    );
    await tester.pumpAndSettle();

    expect(settings.folderPlaceholderSettings.maxCoverTextLength, 4);
    expect(find.text('三国演义'), findsOneWidget);
  });

  test('六种屏幕选用对应排版', () {
    FolderPlaceholderDialogLayout layoutFor(Size screen) {
      final metrics = AdaptiveSettingsDialogMetrics.fromSize(
        screen,
        preferredWidth: 840,
      );
      return FolderPlaceholderDialogLayout.from(
        screen: screen,
        metrics: metrics,
      );
    }

    expect(
      layoutFor(const Size(390, 844)).pane,
      FolderPlaceholderPane.stacked,
    );
    expect(
      layoutFor(const Size(844, 390)).pane,
      FolderPlaceholderPane.landscapeStrip,
    );
    expect(
      layoutFor(const Size(800, 1200)).pane,
      FolderPlaceholderPane.splitTop,
    );
    expect(
      layoutFor(const Size(1024, 768)).pane,
      FolderPlaceholderPane.splitStart,
    );
    expect(
      layoutFor(const Size(1200, 1800)).pane,
      FolderPlaceholderPane.splitTop,
    );
    expect(
      layoutFor(const Size(1600, 900)).pane,
      FolderPlaceholderPane.splitStart,
    );
  });

  testWidgets('画法色板和实时预览用不同底板，避免看起来像同一排卡片', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await pumpDialog(tester, await readySettings());
    await tester.pumpAndSettle();

    final picker = tester.widget<DecoratedBox>(
      find.byKey(FolderPlaceholderStyleDialog.pickerPanelKey),
    );
    final preview = tester.widget<DecoratedBox>(
      find.byKey(FolderPlaceholderStyleDialog.previewPanelKey),
    );
    expect(
      (picker.decoration as BoxDecoration).color,
      FolderPlaceholderStyleDialog.pickerPanelColor,
    );
    expect(
      (preview.decoration as BoxDecoration).color,
      FolderPlaceholderStyleDialog.previewPanelColor,
    );
    expect(
      (picker.decoration as BoxDecoration).color,
      isNot((preview.decoration as BoxDecoration).color),
    );
    expect(find.text('画法'), findsOneWidget);
    expect(find.text('实时预览'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机横屏预览在左侧，滑条仍在窗口内', (tester) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await pumpDialog(tester, await readySettings());
    await tester.pumpAndSettle();

    final previewRect = tester.getRect(
      find.byKey(FolderPlaceholderStyleDialog.previewGridKey),
    );
    final slider = find.byKey(
      const ValueKey<String>('folder-placeholder-slider-silhouetteScale'),
    );
    expect(slider, findsOneWidget);
    expect(previewRect.center.dx, lessThan(844 / 2));
    expect(previewRect.bottom, lessThanOrEqualTo(390));
    expect(tester.takeException(), isNull);
  });

  testWidgets('平板竖屏画法在上，预览与滑条左右并列', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await pumpDialog(tester, await readySettings());
    await tester.pumpAndSettle();

    final pickerRect = tester.getRect(
      find.byKey(FolderPlaceholderStyleDialog.pickerPanelKey),
    );
    final previewRect = tester.getRect(
      find.byKey(FolderPlaceholderStyleDialog.previewGridKey),
    );
    final sliderRect = tester.getRect(
      find.byKey(
        const ValueKey<String>('folder-placeholder-slider-silhouetteScale'),
      ),
    );
    expect(pickerRect.bottom, lessThanOrEqualTo(previewRect.top + 12));
    expect(sliderRect.left, greaterThan(previewRect.right - 8));
    expect(sliderRect.bottom, lessThanOrEqualTo(1200));
    expect(tester.takeException(), isNull);
  });

  testWidgets('染色图标把封面文字开关改成字母徽章，并能单独调徽章内文字', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final settings = await readySettings();
    await pumpDialog(tester, settings);
    await tester.pumpAndSettle();

    expect(find.text('显示封面文字'), findsOneWidget);
    await tester.tap(
      find.byKey(
        const ValueKey<String>('folder-placeholder-paint-tile-tintedIcon'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('显示字母徽章'), findsOneWidget);
    expect(find.text('显示封面文字'), findsNothing);
    expect(
      find.byKey(
        const ValueKey<String>('folder-placeholder-slider-letterBadgeGlyphScale'),
      ),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('folder-placeholder-show-cover-text')),
    );
    await tester.pumpAndSettle();

    expect(find.text('徽章文字上限'), findsOneWidget);
    expect(find.text('徽章文字大小'), findsOneWidget);
    expect(find.text('字母徽章大小'), findsOneWidget);
    final glyphSlider = tester.widget<Slider>(
      find.byKey(
        const ValueKey<String>('folder-placeholder-slider-letterBadgeGlyphScale'),
      ),
    );
    expect(glyphSlider.min, 0);
    expect(glyphSlider.max, 100);
    expect(glyphSlider.value, closeTo(50, 0.2));
  });
}
