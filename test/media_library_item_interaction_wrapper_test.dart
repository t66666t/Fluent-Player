import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/media_library_item_interaction_wrapper.dart';

void main() {
  testWidgets('桌面端原地长按超过阈值时间后触发选中而不是点击', (tester) async {
    var taps = 0;
    var dragStarts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 180,
            height: 48,
            child: MediaLibraryItemInteractionWrapper(
              key: const ValueKey('stationary-source'),
              index: 0,
              dragDelay: const Duration(milliseconds: 100),
              isSelected: false,
              selectedCount: 0,
              onDragStarted: () => dragStarts++,
              onReorder: (_, _) {},
              onTap: () => taps++,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('stationary-source'))),
    );
    // 按住不动超过长按阈值（100ms），应触发选中而不是点击。
    await tester.pump(const Duration(milliseconds: 800));
    await gesture.up();
    await tester.pump();

    expect(taps, 0);
    expect(dragStarts, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面端原地长按不会触发卡片 InkWell 点击从而取消选中', (tester) async {
    var selectionMode = false;
    final selected = <int>{};
    var dragStarts = 0;

    Widget buildCard() {
      return MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            return Center(
              child: SizedBox(
                width: 180,
                height: 80,
                child: MediaLibraryItemInteractionWrapper(
                  key: const ValueKey('inkwell-long-press'),
                  index: 0,
                  dragDelay: const Duration(milliseconds: 100),
                  isSelected: selected.contains(0),
                  selectedCount: selected.length,
                  onDragStarted: () {
                    dragStarts++;
                    setState(() {
                      selectionMode = true;
                      selected.add(0);
                    });
                  },
                  onTap: () {
                    if (!selectionMode) return;
                    setState(() {
                      if (selected.contains(0)) {
                        selected.remove(0);
                      } else {
                        selected.add(0);
                      }
                    });
                  },
                  onReorder: (_, _) {},
                  child: Material(
                    child: InkWell(
                      onTap: () {
                        if (!selectionMode) return;
                        setState(() {
                          if (selected.contains(0)) {
                            selected.remove(0);
                          } else {
                            selected.add(0);
                          }
                        });
                      },
                      child: Text(selected.contains(0) ? 'selected' : 'idle'),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );
    }

    await tester.pumpWidget(buildCard());
    final center = tester.getCenter(
      find.byKey(const ValueKey('inkwell-long-press')),
    );
    final gesture = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 800));
    await gesture.up();
    await tester.pump();

    expect(dragStarts, 1);
    expect(selectionMode, isTrue);
    expect(selected, {0});
    expect(find.text('selected'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 下一次短按仍应能切换选中，说明抑制只作用于这次长按。
    final second = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 40));
    await second.up();
    await tester.pump();

    expect(dragStarts, 1);
    expect(selectionMode, isTrue);
    expect(selected, isEmpty);
    expect(find.text('idle'), findsOneWidget);
  });

  testWidgets('桌面端快速点击不进入拖拽', (tester) async {
    var taps = 0;
    var dragStarts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 180,
            height: 48,
            child: MediaLibraryItemInteractionWrapper(
              key: const ValueKey('quick-tap-source'),
              index: 0,
              dragDelay: const Duration(milliseconds: 100),
              isSelected: false,
              selectedCount: 0,
              onDragStarted: () => dragStarts++,
              onReorder: (_, _) {},
              onTap: () => taps++,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => taps++,
                child: const ColoredBox(color: Colors.black),
              ),
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('quick-tap-source'))),
    );
    // 快速点击（< 长按阈值 100ms）不移动，应正常触发点击而不进入拖拽。
    await tester.pump(const Duration(milliseconds: 40));
    await gesture.up();
    await tester.pump();

    expect(taps, 1);
    expect(dragStarts, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面端移动超过系统阈值才启动拖拽入口', (tester) async {
    var dragStarts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 180,
            height: 48,
            child: MediaLibraryItemInteractionWrapper(
              key: const ValueKey('source'),
              index: 0,
              dragDelay: const Duration(milliseconds: 100),
              isSelected: false,
              selectedCount: 0,
              onDragStarted: () => dragStarts++,
              onReorder: (_, _) {},
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('source'))),
    );
    // 长按阈值之前移动（50ms < 100ms），验证位移门控本身生效。
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();

    expect(dragStarts, 1);
    await gesture.up();
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖到普通列表项会按原索引和目标索引排序', (tester) async {
    int? oldIndex;
    int? newIndex;
    await tester.pumpWidget(
      MaterialApp(
        home: Row(
          children: [
            SizedBox(
              width: 120,
              height: 48,
              child: MediaLibraryItemInteractionWrapper(
                key: const ValueKey('reorder-source'),
                index: 0,
                dragDelay: const Duration(milliseconds: 50),
                isSelected: false,
                selectedCount: 0,
                onDragStarted: () {},
                onReorder: (_, _) {},
                child: const ColoredBox(color: Colors.black),
              ),
            ),
            SizedBox(
              width: 120,
              height: 48,
              child: MediaLibraryItemInteractionWrapper(
                key: const ValueKey('reorder-target'),
                index: 1,
                dragDelay: const Duration(milliseconds: 50),
                isSelected: false,
                selectedCount: 0,
                onDragStarted: () {},
                onReorder: (oldValue, newValue) {
                  oldIndex = oldValue;
                  newIndex = newValue;
                },
                child: const ColoredBox(color: Colors.black),
              ),
            ),
          ],
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('reorder-source'))),
    );
    await tester.pump(const Duration(milliseconds: 70));
    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey('reorder-target'))),
    );
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(oldIndex, 0);
    expect(newIndex, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('在文件夹上持续悬停后会触发移入而不是排序', (tester) async {
    int? movedIndex;
    String? targetFolder;
    await tester.pumpWidget(
      MaterialApp(
        home: Row(
          children: [
            SizedBox(
              width: 120,
              height: 48,
              child: MediaLibraryItemInteractionWrapper(
                key: const ValueKey('folder-source'),
                index: 0,
                dragDelay: const Duration(milliseconds: 50),
                isSelected: true,
                selectedCount: 2,
                onDragStarted: () {},
                onReorder: (_, _) {},
                child: const ColoredBox(color: Colors.black),
              ),
            ),
            SizedBox(
              width: 120,
              height: 48,
              child: MediaLibraryItemInteractionWrapper(
                key: const ValueKey('folder-target'),
                index: 1,
                dragDelay: const Duration(milliseconds: 50),
                isSelected: false,
                selectedCount: 2,
                onDragStarted: () {},
                onReorder: (_, _) {},
                folderId: 'folder-1',
                onMoveToFolder: (oldValue, folderId) {
                  movedIndex = oldValue;
                  targetFolder = folderId;
                },
                child: const ColoredBox(color: Colors.black),
              ),
            ),
          ],
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('folder-source'))),
    );
    await tester.pump(const Duration(milliseconds: 70));
    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey('folder-target'))),
    );
    await tester.pump(const Duration(milliseconds: 350));
    await gesture.up();
    await tester.pump();

    expect(movedIndex, 0);
    expect(targetFolder, 'folder-1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('搜索结果禁用排序时拖到文件夹会立即触发移入', (tester) async {
    var reorderCount = 0;
    int? movedIndex;
    String? targetFolder;
    await tester.pumpWidget(
      MaterialApp(
        home: Row(
          children: [
            SizedBox(
              width: 120,
              height: 48,
              child: MediaLibraryItemInteractionWrapper(
                key: const ValueKey('search-source'),
                index: 0,
                dragDelay: const Duration(milliseconds: 50),
                isSelected: false,
                selectedCount: 0,
                onDragStarted: () {},
                onReorder: (_, _) => reorderCount++,
                allowReorder: false,
                child: const ColoredBox(color: Colors.black),
              ),
            ),
            SizedBox(
              width: 120,
              height: 48,
              child: MediaLibraryItemInteractionWrapper(
                key: const ValueKey('search-folder-target'),
                index: 1,
                dragDelay: const Duration(milliseconds: 50),
                isSelected: false,
                selectedCount: 0,
                onDragStarted: () {},
                onReorder: (_, _) => reorderCount++,
                allowReorder: false,
                folderId: 'folder-2',
                onMoveToFolder: (oldValue, folderId) {
                  movedIndex = oldValue;
                  targetFolder = folderId;
                },
                child: const ColoredBox(color: Colors.black),
              ),
            ),
          ],
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('search-source'))),
    );
    await tester.pump(const Duration(milliseconds: 70));
    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey('search-folder-target'))),
    );
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(movedIndex, 0);
    expect(targetFolder, 'folder-2');
    expect(reorderCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面端轻微移动但未达阈值时不进入拖拽并补偿点击', (tester) async {
    var taps = 0;
    var dragStarts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 180,
            height: 48,
            child: MediaLibraryItemInteractionWrapper(
              key: const ValueKey('slight-move-source'),
              index: 0,
              dragDelay: const Duration(milliseconds: 100),
              isSelected: false,
              selectedCount: 0,
              onDragStarted: () => dragStarts++,
              onReorder: (_, _) {},
              onTap: () => taps++,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('slight-move-source'))),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 60));
    // 鼠标位移 5px：已超过点击容差（1px），未达到拖拽阈值（10px）。
    await gesture.moveBy(const Offset(5, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(taps, 1);
    expect(dragStarts, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面端鼠标微移仍只打开一次，不会和卡片点击叠成两次', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 180,
            height: 48,
            child: MediaLibraryItemInteractionWrapper(
              key: const ValueKey('sub-slop-source'),
              index: 0,
              dragDelay: const Duration(milliseconds: 100),
              isSelected: false,
              selectedCount: 0,
              onDragStarted: () {},
              onReorder: (_, _) {},
              onTap: () => taps++,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => taps++,
                child: const ColoredBox(color: Colors.black),
              ),
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('sub-slop-source'))),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 40));
    // 0.5px 仍在鼠标点击容差内，只能由内层点击处理。
    await gesture.moveBy(const Offset(0.5, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面端鼠标超过点击容差但未达拖拽阈值时只补偿一次', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 180,
            height: 48,
            child: MediaLibraryItemInteractionWrapper(
              key: const ValueKey('past-slop-source'),
              index: 0,
              dragDelay: const Duration(milliseconds: 100),
              isSelected: false,
              selectedCount: 0,
              onDragStarted: () {},
              onReorder: (_, _) {},
              onTap: () => taps++,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => taps++,
                child: const ColoredBox(color: Colors.black),
              ),
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('past-slop-source'))),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 40));
    await gesture.moveBy(const Offset(5, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面端触控未达点击容差时不和卡片点击重复触发', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 180,
            height: 48,
            child: MediaLibraryItemInteractionWrapper(
              key: const ValueKey('touch-slop-source'),
              index: 0,
              dragDelay: const Duration(milliseconds: 100),
              isSelected: false,
              selectedCount: 0,
              onDragStarted: () {},
              onReorder: (_, _) {},
              onTap: () => taps++,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => taps++,
                child: const ColoredBox(color: Colors.black),
              ),
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('touch-slop-source'))),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(const Duration(milliseconds: 40));
    // 5px 小于触控点击容差，仍是一次内层点击。
    await gesture.moveBy(const Offset(5, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面端位移超过阈值后即使回到原位仍保持拖拽不触发点击', (tester) async {
    var taps = 0;
    var dragStarts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 180,
            height: 48,
            child: MediaLibraryItemInteractionWrapper(
              key: const ValueKey('return-move-source'),
              index: 0,
              dragDelay: const Duration(milliseconds: 100),
              isSelected: false,
              selectedCount: 0,
              onDragStarted: () => dragStarts++,
              onReorder: (_, _) {},
              onTap: () => taps++,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('return-move-source'))),
    );
    await tester.pump(const Duration(milliseconds: 60));
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    // 超过阈值后移回原位再松开，仍然是一次拖拽。
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(taps, 0);
    expect(dragStarts, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面端右击轻微移动不会补偿成左键点击', (tester) async {
    var taps = 0;
    var dragStarts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 180,
            height: 48,
            child: MediaLibraryItemInteractionWrapper(
              key: const ValueKey('secondary-source'),
              index: 0,
              dragDelay: const Duration(milliseconds: 100),
              isSelected: false,
              selectedCount: 0,
              onDragStarted: () => dragStarts++,
              onReorder: (_, _) {},
              onTap: () => taps++,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('secondary-source'))),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pump(const Duration(milliseconds: 60));
    await gesture.moveBy(const Offset(5, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(taps, 0);
    expect(dragStarts, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('置顶拖拽使用独立数据类型并按可见索引排序', (tester) async {
    int? fromIndex;
    int? toIndex;
    await tester.pumpWidget(
      MaterialApp(
        home: Row(
          children: [
            SizedBox(
              width: 120,
              height: 48,
              child: MediaLibraryPinnedReorderWrapper(
                key: const ValueKey('pin-source'),
                visibleIndex: 0,
                dragDelay: const Duration(milliseconds: 50),
                onReorder: (_, _) {},
                child: const ColoredBox(color: Colors.black),
              ),
            ),
            SizedBox(
              width: 120,
              height: 48,
              child: MediaLibraryPinnedReorderWrapper(
                key: const ValueKey('pin-target'),
                visibleIndex: 1,
                dragDelay: const Duration(milliseconds: 50),
                onReorder: (from, to) {
                  fromIndex = from;
                  toIndex = to;
                },
                child: const ColoredBox(color: Colors.black),
              ),
            ),
          ],
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('pin-source'))),
    );
    await tester.pump(const Duration(milliseconds: 70));
    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey('pin-target'))),
    );
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(fromIndex, 0);
    expect(toIndex, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('文件夹卡片不会接收置顶拖拽', (tester) async {
    var folderReorder = 0;
    var pinReorder = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Row(
          children: [
            SizedBox(
              width: 120,
              height: 48,
              child: MediaLibraryPinnedReorderWrapper(
                key: const ValueKey('pin-only-source'),
                visibleIndex: 0,
                dragDelay: const Duration(milliseconds: 50),
                onReorder: (_, _) => pinReorder++,
                child: const ColoredBox(color: Colors.black),
              ),
            ),
            SizedBox(
              width: 120,
              height: 48,
              child: MediaLibraryItemInteractionWrapper(
                key: const ValueKey('folder-int-target'),
                index: 1,
                dragDelay: const Duration(milliseconds: 50),
                isSelected: false,
                selectedCount: 0,
                onDragStarted: () {},
                onReorder: (_, _) => folderReorder++,
                child: const ColoredBox(color: Colors.black),
              ),
            ),
          ],
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('pin-only-source'))),
    );
    await tester.pump(const Duration(milliseconds: 70));
    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey('folder-int-target'))),
    );
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(pinReorder, 0);
    expect(folderReorder, 0);
    expect(tester.takeException(), isNull);
  });
}
