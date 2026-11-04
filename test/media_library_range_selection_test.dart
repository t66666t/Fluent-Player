import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/media_library_range_selection.dart';
import 'package:video_player_app/widgets/media_list_layout_metrics.dart';

void main() {
  const geometry = MediaLibraryGridGeometry(
    crossAxisCount: 4,
    itemWidth: 80,
    itemHeight: 80,
    horizontalSpacing: 8,
    verticalSpacing: 8,
    horizontalPadding: 0,
    topPadding: 0,
  );

  test('从第2行第3张拖到第5行第2张时，中间两行整行选中', () {
    // 0-based: start (row 1, col 2) = 6, end (row 4, col 1) = 17
    final ids = List<String>.generate(20, (i) => 'id-$i');
    final selected = MediaLibraryRangeSelection.mergeSnapshotWithIndexRange(
      snapshot: {'id-6'},
      startIndex: 6,
      currentIndex: 17,
      itemCount: ids.length,
      idAt: (i) => ids[i],
    );

    expect(selected.contains('id-5'), isFalse);
    expect(selected.contains('id-6'), isTrue);
    expect(selected.contains('id-7'), isTrue);
    for (var i = 8; i <= 15; i++) {
      expect(selected.contains('id-$i'), isTrue);
    }
    expect(selected.contains('id-16'), isTrue);
    expect(selected.contains('id-17'), isTrue);
    expect(selected.contains('id-18'), isFalse);
  });

  test('往回拖会缩短范围，手势开始前已选中的项仍保留', () {
    final ids = List<String>.generate(20, (i) => 'id-$i');
    final snapshot = {'id-0', 'id-6'};
    final expanded = MediaLibraryRangeSelection.mergeSnapshotWithIndexRange(
      snapshot: snapshot,
      startIndex: 6,
      currentIndex: 17,
      itemCount: ids.length,
      idAt: (i) => ids[i],
    );
    expect(expanded.contains('id-12'), isTrue);

    final shrunk = MediaLibraryRangeSelection.mergeSnapshotWithIndexRange(
      snapshot: snapshot,
      startIndex: 6,
      currentIndex: 8,
      itemCount: ids.length,
      idAt: (i) => ids[i],
    );
    expect(shrunk.contains('id-0'), isTrue);
    expect(shrunk.contains('id-6'), isTrue);
    expect(shrunk.contains('id-8'), isTrue);
    expect(shrunk.contains('id-12'), isFalse);
  });

  test('指针超出可视区时命中夹在边缘，不会落到整表首尾', () {
    const viewportTop = 100.0;
    const viewportBottom = 700.0;
    final above = MediaLibraryRangeSelection.clampPointerToVerticalViewport(
      global: const Offset(40, -5000),
      viewportTop: viewportTop,
      viewportBottom: viewportBottom,
    );
    final below = MediaLibraryRangeSelection.clampPointerToVerticalViewport(
      global: const Offset(40, 9000),
      viewportTop: viewportTop,
      viewportBottom: viewportBottom,
    );
    final inside = MediaLibraryRangeSelection.clampPointerToVerticalViewport(
      global: const Offset(40, 240),
      viewportTop: viewportTop,
      viewportBottom: viewportBottom,
    );

    expect(above, const Offset(40, viewportTop));
    expect(below, const Offset(40, viewportBottom));
    expect(inside, const Offset(40, 240));

    // 列表已经滚到内容坐标 1000。夹取后的落点是视口边缘那一行，
    // 未夹取的屏幕外坐标则会把行号打到 0 或最后一项。
    const scrollOffset = 1000.0;
    final edgeContentY = (above.dy - viewportTop) + scrollOffset;
    final rawContentY = (-5000 - viewportTop) + scrollOffset;
    expect(
      geometry.indexForDragSelection(Offset(40, edgeContentY), 200),
      isNot(0),
    );
    expect(geometry.indexForDragSelection(Offset(40, rawContentY), 200), 0);
  });

  test('框选矩形伸到列表外时只检查真实存在的行', () {
    final indices = geometry.indicesOverlapping(
      const Rect.fromLTRB(-1000, -1000, 1000, 1000000),
      20,
    );
    expect(indices, List<int>.generate(20, (index) => index));
  });

  test('最后一根指针抬起或取消才结束拖选', () {
    final session = MediaLibrarySelectionPointerSession();
    session.down(1);
    session.down(2);
    expect(session.move(1), isTrue);
    expect(session.move(3), isFalse);
    expect(session.up(1), isFalse);
    expect(session.up(9), isFalse);
    expect(session.up(2), isTrue);
    session.down(4);
    expect(session.up(4), isTrue);
  });

  test('拖选命中把间距也算进相邻格子', () {
    expect(geometry.indexForDragSelection(const Offset(40, 40), 20), 0);
    expect(geometry.indexForDragSelection(const Offset(90, 40), 20), 1);
    expect(geometry.indexForDragSelection(const Offset(40, 180), 20), 8);
    expect(geometry.indexForDragSelection(const Offset(-10, -10), 20), 0);
    expect(geometry.indexForDragSelection(const Offset(400, 800), 20), 19);
  });

  test('靠近可视区上沿上滚、下沿下滚，有 mini 条时下界会上移', () {
    const top = 100.0;
    const fullBottom = 800.0;
    expect(
      MediaLibrarySelectionAutoScroll.velocityPxPerSecond(
        pointerY: 100,
        viewportTop: top,
        viewportBottom: fullBottom,
      ),
      lessThan(0),
    );
    expect(
      MediaLibrarySelectionAutoScroll.velocityPxPerSecond(
        pointerY: 450,
        viewportTop: top,
        viewportBottom: fullBottom,
      ),
      0,
    );
    expect(
      MediaLibrarySelectionAutoScroll.velocityPxPerSecond(
        pointerY: 790,
        viewportTop: top,
        viewportBottom: fullBottom,
      ),
      greaterThan(0),
    );

    expect(
      MediaLibraryRangeSelection.miniPlayerOverlayHeight(
        visible: false,
        cardHeight: 124,
        cardBottomInset: 30,
      ),
      0,
    );
    expect(
      MediaLibraryRangeSelection.miniPlayerOverlayHeight(
        visible: true,
        cardHeight: 124,
        cardBottomInset: 30,
      ),
      154,
    );
  });

  for (final height in [24.0, 80.0, 128.0]) {
    test('短视口 $height 的上下滚动热区互不重叠', () {
      double speed(double y) =>
          MediaLibrarySelectionAutoScroll.velocityPxPerSecond(
            pointerY: y,
            viewportTop: 100,
            viewportBottom: 100 + height,
          );
      expect(speed(101), lessThan(0));
      expect(speed(100 + height / 2), 0);
      expect(speed(99 + height), greaterThan(0));
      expect(
        speed(100 + height),
        MediaLibrarySelectionAutoScroll.maxSpeedPxPerSecond,
      );
    });
  }

  test('鼠标框选手势在任意平台都只认单键鼠标', () {
    expect(
      MediaLibraryRangeSelection.isMouseBoxGesture(
        pointerKind: PointerDeviceKind.mouse,
        pointerCount: 1,
      ),
      isTrue,
    );
    expect(
      MediaLibraryRangeSelection.isMouseBoxGesture(
        pointerKind: PointerDeviceKind.touch,
        pointerCount: 1,
      ),
      isFalse,
    );
    expect(
      MediaLibraryRangeSelection.isMouseBoxGesture(
        pointerKind: PointerDeviceKind.mouse,
        pointerCount: 2,
      ),
      isFalse,
    );
  });
}
