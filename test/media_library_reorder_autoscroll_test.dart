import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/media_library_range_selection.dart';
import 'package:video_player_app/widgets/media_library_item_interaction_wrapper.dart';

/// 用和首页 / 文件夹页相同的滚动器，把卡片拖拽位置接到边缘自动滚动上。
class _ReorderScrollHarness extends StatefulWidget {
  const _ReorderScrollHarness({required this.onDrop});

  final void Function(int oldIndex, int newIndex) onDrop;

  @override
  State<_ReorderScrollHarness> createState() => _ReorderScrollHarnessState();
}

class _ReorderScrollHarnessState extends State<_ReorderScrollHarness> {
  final scrollController = ScrollController();
  final session = MediaLibraryReorderDragSession();
  final listKey = GlobalKey();
  MediaLibrarySelectionAutoScroller? _scroller;

  @override
  void dispose() {
    session.end();
    _scroller?.dispose();
    scrollController.dispose();
    super.dispose();
  }

  MediaLibrarySelectionAutoScroller _ensureScroller() {
    return _scroller ??= MediaLibrarySelectionAutoScroller(
      scrollController: scrollController,
      onScrolled: () {
        if (session.isActive) session.scheduleHitRefresh();
      },
    );
  }

  void _updateDrag(
    Offset globalPosition,
    int pointer,
    int viewId,
    PointerDeviceKind kind,
  ) {
    session.update(
      globalPosition: globalPosition,
      pointer: pointer,
      viewId: viewId,
      kind: kind,
    );
    final box = listKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) {
      _ensureScroller().stop();
      return;
    }
    final top = box.localToGlobal(Offset.zero).dy;
    _ensureScroller().update(
      pointerY: globalPosition.dy,
      viewportTop: top,
      viewportBottom: top + box.size.height,
    );
  }

  void _endDrag() {
    if (!session.isActive) return;
    session.end();
    _scroller?.stop();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          key: listKey,
          height: 240,
          child: ListView.builder(
            controller: scrollController,
            // 手指拖卡片时滚动权在自动滚动，不让列表自己把这次拖拽吃掉。
            physics: const NeverScrollableScrollPhysics(),
            itemExtent: 80,
            itemCount: 24,
            itemBuilder: (context, index) {
              return MediaLibraryItemInteractionWrapper(
                key: ValueKey('card-$index'),
                index: index,
                dragDelay: const Duration(milliseconds: 80),
                isSelected: index == 0,
                selectedCount: 1,
                onDragStarted: () {},
                onDragPosition: _updateDrag,
                onDragEnd: _endDrag,
                onReorder: widget.onDrop,
                child: ColoredBox(
                  color: index.isEven
                      ? const Color(0xFF222222)
                      : const Color(0xFF444444),
                  child: Text('card-$index'),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

void main() {
  testWidgets('原地长按卡片不会滚动列表', (tester) async {
    await tester.pumpWidget(_ReorderScrollHarness(onDrop: (_, _) {}));
    final state = tester.state<_ReorderScrollHarnessState>(
      find.byType(_ReorderScrollHarness),
    );
    final listBox = tester.renderObject<RenderBox>(find.byKey(state.listKey));
    final holdPoint = listBox.localToGlobal(const Offset(40, 16));

    final gesture = await tester.startGesture(holdPoint);
    await tester.pump(const Duration(milliseconds: 500));
    expect(state.scrollController.offset, 0);
    await gesture.up();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖卡片到列表边缘会自动滚动，松手落在滚出来的卡片上', (tester) async {
    int? droppedOn;
    await tester.pumpWidget(
      _ReorderScrollHarness(onDrop: (_, newIndex) => droppedOn = newIndex),
    );
    final state = tester.state<_ReorderScrollHarnessState>(
      find.byType(_ReorderScrollHarness),
    );
    final listBox = tester.renderObject<RenderBox>(find.byKey(state.listKey));
    final start = tester.getCenter(find.byKey(const ValueKey('card-0')));
    final edge = listBox.localToGlobal(
      Offset(listBox.size.width / 2, listBox.size.height - 8),
    );

    final gesture = await tester.startGesture(start);
    await gesture.moveTo(edge);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));

    expect(state.scrollController.offset, greaterThan(40));

    await gesture.up();
    await tester.pump();

    expect(droppedOn, isNotNull);
    // 视口大约只能看到前 3 张。滚起来之后，松手应该落在更靠后的卡片上。
    expect(droppedOn!, greaterThan(2));
    expect(tester.takeException(), isNull);
  });
}
