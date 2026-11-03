import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/widgets/media_list_layout_metrics.dart';
import 'package:video_player_app/widgets/media_library_layout_profile.dart';
import 'package:video_player_app/widgets/media_library_list_tile.dart';

void main() {
  testWidgets('极窄紧凑列表项同时保留标题、缩略图和元信息', (tester) async {
    final collection = VideoCollection(
      id: 'collection-1',
      name: '需要优先显示的媒体标题',
      createTime: 0,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 80,
              height: 24,
              child: MediaLibraryListTile.collection(
                collection: collection,
                index: 0,
                showIndex: true,
                showThumbnail: true,
                isSelected: false,
                isSelectionMode: false,
                titleScale: 0.001,
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('需要优先显示的媒体标题'), findsOneWidget);
    expect(find.byKey(const ValueKey('media-list-thumbnail')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('media-list-thumbnail-index')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('media-list-metadata')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('media-list-thumbnail'))).width,
      lessThanOrEqualTo(80 * 0.14),
    );
    final titleRect = tester.getRect(
      find.byKey(const ValueKey('media-list-title')),
    );
    final cardRect = tester.getRect(
      find.byKey(const ValueKey('media-list-card')),
    );
    final thumbnailRect = tester.getRect(
      find.byKey(const ValueKey('media-list-thumbnail')),
    );
    final metadataRect = tester.getRect(
      find.byKey(const ValueKey('media-list-metadata')),
    );
    expect(
      thumbnailRect.left - cardRect.left,
      closeTo(titleRect.left - thumbnailRect.right, 0.001),
    );
    expect(metadataRect.top - titleRect.bottom, lessThanOrEqualTo(24 * 0.08));
    expect(metadataRect.bottom, lessThan(24));
    expect(tester.takeException(), isNull);
  });

  testWidgets('视频和音频在紧凑选择状态下仍保留完整信息结构', (tester) async {
    for (final type in MediaType.values) {
      final item = VideoItem(
        id: type.name,
        path: '${type.name}.media',
        title: '很长的${type == MediaType.audio ? '音频' : '视频'}标题',
        durationMs: 100000,
        lastPositionMs: 50000,
        lastUpdated: 0,
        type: type,
      );

      await tester.pumpWidget(
        ChangeNotifierProvider<MediaPlaybackService>.value(
          value: MediaPlaybackService(),
          child: MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 100,
                  height: 24,
                  child: MediaLibraryListTile.video(
                    item: item,
                    index: 8,
                    showIndex: true,
                    showThumbnail: true,
                    isSelected: true,
                    isSelectionMode: true,
                    titleScale: 0.065,
                    onTap: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('media-list-title')), findsOneWidget);
      expect(find.byKey(const ValueKey('media-list-metadata')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('media-list-thumbnail')),
        findsOneWidget,
      );
      expect(
        find.textContaining(type == MediaType.audio ? '音频' : '视频'),
        findsWidgets,
      );
      expect(find.textContaining('已播放 50%'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('列表选择圆圈支持点击和拖动选择回调', (tester) async {
    var taps = 0;
    var starts = 0;
    var updates = 0;
    var ends = 0;
    final collection = VideoCollection(
      id: 'selection-target',
      name: '选择目标',
      createTime: 0,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 240,
              height: 56,
              child: MediaLibraryListTile.collection(
                collection: collection,
                index: 0,
                showIndex: false,
                showThumbnail: false,
                isSelected: false,
                isSelectionMode: true,
                titleScale: 0.042,
                onTap: () {},
                onSelectionTap: () => taps++,
                onSelectionPanStart: (_) => starts++,
                onSelectionPanUpdate: (_) => updates++,
                onSelectionPanEnd: (_) => ends++,
              ),
            ),
          ),
        ),
      ),
    );

    final handle = find.byKey(const ValueKey('media-list-selection-handle'));
    await tester.tap(handle);
    await tester.drag(handle, const Offset(-30, 0));

    expect(taps, 1);
    expect(starts, 1);
    expect(updates, greaterThan(0));
    expect(ends, 1);
    expect(tester.takeException(), isNull);
  });

  test('字号决定母版基础高度，卡片高度设置提供额外倍率', () {
    expect(MediaListLayoutMetrics.referenceTitleSize(0.001), 4);
    expect(MediaListLayoutMetrics.referenceTitleSize(0.065), 18);
    expect(MediaListLayoutMetrics.heightAdjustment(0.001), 0.45);
    expect(MediaListLayoutMetrics.heightAdjustment(0.10), 1);
    expect(MediaListLayoutMetrics.heightAdjustment(0.15), 1.6);
    expect(
      MediaListLayoutMetrics.referenceRowHeight(0.042, 0.10),
      closeTo(56.39, 0.01),
    );
  });

  test('字号缩小时卡片默认高度同步缩小', () {
    final small = MediaListLayoutMetrics.referenceRowHeight(0.001, 0.10);
    final normal = MediaListLayoutMetrics.referenceRowHeight(0.042, 0.10);
    final large = MediaListLayoutMetrics.referenceRowHeight(0.065, 0.10);

    expect(small, lessThan(normal));
    expect(normal, lessThan(large));
  });

  test('手机、平板和桌面按屏幕短边同比缩放', () {
    final phone = MediaListLayoutMetrics.forGrid(
      screenShortestSide: 390,
      availableWidth: 1200,
      crossAxisCount: 1,
      heightSetting: 0.15,
      titleSetting: 0.042,
      mainSpacingSetting: 0.04,
      crossSpacingSetting: 0.05,
    );
    final tablet = MediaListLayoutMetrics.forGrid(
      screenShortestSide: 780,
      availableWidth: 2400,
      crossAxisCount: 1,
      heightSetting: 0.15,
      titleSetting: 0.042,
      mainSpacingSetting: 0.04,
      crossSpacingSetting: 0.05,
    );
    final desktop = MediaListLayoutMetrics.forGrid(
      screenShortestSide: 1170,
      availableWidth: 3600,
      crossAxisCount: 1,
      heightSetting: 0.15,
      titleSetting: 0.042,
      mainSpacingSetting: 0.04,
      crossSpacingSetting: 0.05,
    );

    expect(tablet.rowHeight, closeTo(phone.rowHeight * 2, 0.001));
    expect(desktop.rowHeight, closeTo(phone.rowHeight * 3, 0.001));
    expect(tablet.outerPadding, closeTo(phone.outerPadding * 2, 0.001));
    expect(tablet.mainSpacing, closeTo(phone.mainSpacing * 2, 0.001));
  });

  test('1、4、15 列都以单元宽度限制行高', () {
    for (final columns in [1, 4, 15]) {
      final metrics = MediaListLayoutMetrics.forGrid(
        screenShortestSide: 390,
        availableWidth: 390,
        crossAxisCount: columns,
        heightSetting: 0.15,
        titleSetting: 0.042,
        mainSpacingSetting: 0,
        crossSpacingSetting: 0,
      );

      expect(metrics.rowHeight, lessThanOrEqualTo(metrics.cellWidth));
      expect(metrics.rowHeight, greaterThan(0));
    }
  });

  test('首行顶部留白始终等于行间距', () {
    for (final spacing in [0.0, 0.02, 0.04]) {
      final metrics = MediaListLayoutMetrics.forGrid(
        screenShortestSide: 390,
        availableWidth: 390,
        crossAxisCount: 2,
        heightSetting: 0.10,
        titleSetting: 0.042,
        mainSpacingSetting: spacing,
        crossSpacingSetting: 0.02,
      );

      expect(metrics.topPadding, metrics.mainSpacing);
    }
  });

  test('极窄容器会连续压缩外边距和列间距并保留有效单元宽度', () {
    final metrics = MediaListLayoutMetrics.forGrid(
      screenShortestSide: 390,
      availableWidth: 100,
      crossAxisCount: 15,
      heightSetting: 0.15,
      titleSetting: 0.042,
      mainSpacingSetting: 0.04,
      crossSpacingSetting: 0.05,
    );

    final occupiedWidth =
        metrics.outerPadding * 2 +
        metrics.crossSpacing * 14 +
        metrics.cellWidth * 15;
    expect(occupiedWidth, closeTo(100, 0.001));
    expect(metrics.cellWidth, greaterThan(0));
    expect(metrics.rowHeight, lessThanOrEqualTo(metrics.cellWidth));
  });

  test('卡片内部的内边距、图标和文字保持统一比例', () {
    final phone = MediaListLayoutMetrics.forTile(
      screenShortestSide: 390,
      cellWidth: 300,
      rowHeight: 120,
      titleSetting: 0.001,
    );
    final tablet = MediaListLayoutMetrics.forTile(
      screenShortestSide: 780,
      cellWidth: 600,
      rowHeight: 240,
      titleSetting: 0.001,
    );

    expect(tablet.titleSize, closeTo(phone.titleSize * 2, 0.001));
    expect(
      tablet.horizontalPadding,
      closeTo(phone.horizontalPadding * 2, 0.001),
    );
    expect(tablet.trailingSize, closeTo(phone.trailingSize * 2, 0.001));
    expect(tablet.radius, closeTo(phone.radius * 2, 0.001));
  });

  test('卡片视图选择圆圈和点击留白随卡片宽度等比例变化', () {
    expect(
      MediaListLayoutMetrics.gridSelectionIconSize(200),
      closeTo(MediaListLayoutMetrics.gridSelectionIconSize(100) * 2, 0.001),
    );
    expect(
      MediaListLayoutMetrics.gridSelectionHitPadding(200),
      closeTo(MediaListLayoutMetrics.gridSelectionHitPadding(100) * 2, 0.001),
    );
  });

  test('列表几何能正确识别卡片、间距和多行索引', () {
    const geometry = MediaLibraryGridGeometry(
      crossAxisCount: 2,
      itemWidth: 100,
      itemHeight: 40,
      horizontalSpacing: 10,
      verticalSpacing: 8,
      horizontalPadding: 16,
      topPadding: 6,
    );

    expect(geometry.indexAt(const Offset(20, 10), 4), 0);
    expect(geometry.indexAt(const Offset(120, 10), 4), isNull);
    expect(geometry.indexAt(const Offset(130, 10), 4), 1);
    expect(geometry.indexAt(const Offset(20, 50), 4), isNull);
    expect(geometry.indexAt(const Offset(20, 60), 4), 2);
    expect(geometry.rectForIndex(3), const Rect.fromLTWH(126, 54, 100, 40));
    expect(geometry.indexForDragSelection(const Offset(120, 10), 4), 0);
    expect(geometry.indexForDragSelection(const Offset(20, 50), 4), 0);
    expect(
      geometry.indicesOverlapping(const Rect.fromLTWH(16, 6, 210, 40), 4),
      [0, 1],
    );
  });

  test('56 高视觉母版保持紧凑且协调的文字层级和留白', () {
    final rowHeight = MediaListLayoutMetrics.referenceRowHeight(0.042, 0.10);
    final metrics = MediaListLayoutMetrics.forTile(
      screenShortestSide: 390,
      cellWidth: 200,
      rowHeight: rowHeight,
      titleSetting: 0.042,
    );

    expect(metrics.titleSize, closeTo(12.97, 0.01));
    expect(metrics.metadataSize, closeTo(9.34, 0.01));
    expect(metrics.informationGap, closeTo(2.99, 0.01));
    expect(metrics.horizontalPadding, closeTo(7.89, 0.01));
    expect(metrics.verticalPadding, closeTo(4.51, 0.01));
    expect(metrics.radius, closeTo(10.15, 0.01));
  });

  test('平板默认横屏 10 列、竖屏 6 列，间距随卡片宽度等比例变化', () {
    const portrait = Size(800, 1280);
    const landscape = Size(1280, 800);

    expect(
      MediaLibraryLayoutDefaults.defaultCardCrossAxisCount(landscape),
      10,
    );
    expect(
      MediaLibraryLayoutDefaults.defaultCardCrossAxisCount(portrait),
      6,
    );

    const style = MediaCardStyleSettings(
      crossAxisCount: 10,
      titleScale: 0.104,
      heightScale: 1.39,
      crossSpacingScale: 0.12,
      mainSpacingScale: 0.12,
    );
    final landscapeGrid = MediaLibraryLayoutDefaults.cardGrid(
      screenSize: landscape,
      style: style,
    );
    final portraitGrid = MediaLibraryLayoutDefaults.cardGrid(
      screenSize: portrait,
      style: MediaCardStyleSettings(
        crossAxisCount: 6,
        titleScale: style.titleScale,
        heightScale: style.heightScale,
        crossSpacingScale: style.crossSpacingScale,
        mainSpacingScale: style.mainSpacingScale,
      ),
    );

    expect(
      landscapeGrid.crossSpacing / landscapeGrid.cellWidth,
      closeTo(0.12, 1e-9),
    );
    expect(
      portraitGrid.crossSpacing / portraitGrid.cellWidth,
      closeTo(0.12, 1e-9),
    );
    expect(landscapeGrid.cellWidth, closeTo(portraitGrid.cellWidth, 8));
  });

  test('卡片内边距随宽度等比例缩小', () {
    final wide = MediaListLayoutMetrics.cardGridContentPadding(170);
    final narrow = MediaListLayoutMetrics.cardGridContentPadding(60);
    expect(wide.horizontal, closeTo(20, 0.2));
    expect(narrow.horizontal, lessThan(wide.horizontal));
    expect(
      MediaListLayoutMetrics.cardGridThumbnailIconSize(34),
      lessThan(50),
    );
  });
}
