import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/media_library_compact_app_bar.dart';
import 'package:video_player_app/widgets/media_library_selection_drop_targets.dart';

class _DropItem {
  const _DropItem(this.id);
  final String id;
}

void main() {
  group('resolveMediaLibrarySelectionDropIds', () {
    const items = [_DropItem('a'), _DropItem('b'), _DropItem('c')];

    test('拖拽已选项时移动整个选区', () {
      expect(
        resolveMediaLibrarySelectionDropIds(
          contents: items,
          selectedIds: {'a', 'c'},
          draggedIndex: 0,
        ),
        ['a', 'c'],
      );
    });

    test('拖拽未选项时只移动该项', () {
      expect(
        resolveMediaLibrarySelectionDropIds(
          contents: items,
          selectedIds: {'a'},
          draggedIndex: 1,
        ),
        ['b'],
      );
    });

    test('点击时使用当前选区', () {
      expect(
        resolveMediaLibrarySelectionDropIds(
          contents: items,
          selectedIds: {'a', 'c'},
        ),
        ['a', 'c'],
      );
    });

    test('越界拖拽索引不产生动作', () {
      expect(
        resolveMediaLibrarySelectionDropIds(
          contents: items,
          selectedIds: {'a'},
          draggedIndex: 9,
        ),
        isEmpty,
      );
    });
  });

  testWidgets('手机文件夹顶栏左右拆分且短标签不溢出', (tester) async {
    await _pumpAppBar(
      tester,
      size: const Size(320, 568),
      showMoveToParent: true,
    );

    expect(find.text('上一级'), findsOneWidget);
    expect(find.text('回收站'), findsOneWidget);
    expect(find.text('移动到上一级'), findsNothing);
    expect(find.text('移入回收站'), findsNothing);

    final parentRect = tester.getRect(
      find.byKey(mediaLibraryMoveToParentDropKey),
    );
    final recycleRect = tester.getRect(
      find.byKey(mediaLibraryMoveToRecycleDropKey),
    );
    expect(parentRect.right, lessThanOrEqualTo(recycleRect.left));
    expect(parentRect.width, closeTo(recycleRect.width, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机最外层顶栏整块显示移入回收站且不溢出', (tester) async {
    await _pumpAppBar(
      tester,
      size: const Size(320, 568),
      showMoveToParent: false,
    );

    expect(find.byKey(mediaLibraryMoveToParentDropKey), findsNothing);
    expect(find.text('移入回收站'), findsOneWidget);
    expect(find.text('上一级'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面文件夹顶栏使用完整文案并均分两半', (tester) async {
    await _pumpAppBar(
      tester,
      size: const Size(1280, 800),
      showMoveToParent: true,
    );

    expect(find.text('移动到上一级'), findsOneWidget);
    expect(find.text('移入回收站'), findsOneWidget);
    expect(find.text('上一级'), findsNothing);

    final parentRect = tester.getRect(
      find.byKey(mediaLibraryMoveToParentDropKey),
    );
    final recycleRect = tester.getRect(
      find.byKey(mediaLibraryMoveToRecycleDropKey),
    );
    expect(parentRect.right, lessThanOrEqualTo(recycleRect.left));
    expect(parentRect.width, closeTo(recycleRect.width, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面最外层顶栏整块显示移入回收站', (tester) async {
    await _pumpAppBar(
      tester,
      size: const Size(1280, 800),
      showMoveToParent: false,
    );

    expect(find.byKey(mediaLibraryMoveToParentDropKey), findsNothing);
    expect(find.text('移入回收站'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('大号字体下拆分投放区仍不溢出', (tester) async {
    await _pumpAppBar(
      tester,
      size: const Size(320, 568),
      showMoveToParent: true,
      textScaler: const TextScaler.linear(1.6),
    );

    expect(find.byKey(mediaLibraryMoveToParentDropKey), findsOneWidget);
    expect(find.byKey(mediaLibraryMoveToRecycleDropKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击两半分别触发上一级和回收站', (tester) async {
    final parentTaps = <int?>[];
    final recycleTaps = <int?>[];
    await _pumpAppBar(
      tester,
      size: const Size(390, 844),
      showMoveToParent: true,
      onParent: parentTaps.add,
      onRecycle: recycleTaps.add,
    );

    await tester.tap(find.byKey(mediaLibraryMoveToParentDropKey));
    await tester.tap(find.byKey(mediaLibraryMoveToRecycleDropKey));
    await tester.pump();

    expect(parentTaps, [null]);
    expect(recycleTaps, [null]);
  });

  testWidgets('未选中时点击投放区不触发动作', (tester) async {
    var recycleTaps = 0;
    await _pumpAppBar(
      tester,
      size: const Size(390, 844),
      showMoveToParent: false,
      hasSelectedItems: false,
      onRecycle: (_) => recycleTaps++,
    );

    await tester.tap(find.byKey(mediaLibraryMoveToRecycleDropKey));
    await tester.pump();

    expect(recycleTaps, 0);
  });

  testWidgets('拖拽到回收站投放区会带上卡片索引', (tester) async {
    final recycled = <int?>[];
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          appBar: AppBar(
            title: MediaLibrarySelectionDropTargets(
              hasSelectedItems: true,
              onMoveToRecycleBin: recycled.add,
            ),
          ),
          body: Center(
            child: Draggable<int>(
              key: const ValueKey('drag-source'),
              data: 2,
              feedback: const SizedBox(
                width: 24,
                height: 24,
                child: ColoredBox(color: Colors.white),
              ),
              child: const SizedBox(
                width: 48,
                height: 48,
                child: ColoredBox(color: Colors.blue),
              ),
            ),
          ),
        ),
      ),
    );

    final source = tester.getCenter(find.byKey(const ValueKey('drag-source')));
    final target = tester.getCenter(
      find.byKey(mediaLibraryMoveToRecycleDropKey),
    );
    await tester.timedDragFrom(
      source,
      target - source,
      const Duration(milliseconds: 300),
    );
    await tester.pumpAndSettle();

    expect(recycled, [2]);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpAppBar(
  WidgetTester tester, {
  required Size size,
  required bool showMoveToParent,
  bool hasSelectedItems = true,
  TextScaler textScaler = TextScaler.noScaling,
  ValueChanged<int?>? onParent,
  ValueChanged<int?>? onRecycle,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final compact = size.width < mediaLibraryCompactTopBarBreakpoint;
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: child!,
        );
      },
      home: Scaffold(
        appBar: AppBar(
          toolbarHeight: compact ? 50 : kToolbarHeight,
          leadingWidth: compact ? 40 : null,
          titleSpacing: compact ? 3 : NavigationToolbar.kMiddleSpacing,
          leading: IconButton(icon: const Icon(Icons.close), onPressed: () {}),
          title: MediaLibrarySelectionDropTargets(
            showMoveToParent: showMoveToParent,
            hasSelectedItems: hasSelectedItems,
            onMoveToParent: onParent ?? (_) {},
            onMoveToRecycleBin: onRecycle ?? (_) {},
          ),
          actions: [
            IconButton(icon: const Icon(Icons.select_all), onPressed: () {}),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
}
