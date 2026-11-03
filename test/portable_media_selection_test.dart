import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/portable_transfer/portable_media_selection.dart';

void main() {
  PortableTreeIndex courseTree() {
    PortableTreeNode folder({
      required String id,
      required String name,
      required String? parentId,
      required List<String> childIds,
    }) {
      return PortableTreeNode(
        id: id,
        name: name,
        isFolder: true,
        parentId: parentId,
        childIds: childIds,
      );
    }

    PortableTreeNode file({
      required String id,
      required String name,
      required String parentId,
    }) {
      return PortableTreeNode(
        id: id,
        name: name,
        isFolder: false,
        parentId: parentId,
        childIds: const <String>[],
        fileName: '$name.mp4',
      );
    }

    return PortableTreeIndex(
      rootIds: const <String>['course', 'rootVideo'],
      nodes: <String, PortableTreeNode>{
        'course': folder(
          id: 'course',
          name: '课程',
          parentId: null,
          childIds: const <String>['lesson1', 'lesson2'],
        ),
        'lesson1': folder(
          id: 'lesson1',
          name: '第一课',
          parentId: 'course',
          childIds: const <String>['a', 'b'],
        ),
        'lesson2': folder(
          id: 'lesson2',
          name: '第二课',
          parentId: 'course',
          childIds: const <String>['c'],
        ),
        'a': file(id: 'a', name: '片段A', parentId: 'lesson1'),
        'b': file(id: 'b', name: '片段B', parentId: 'lesson1'),
        'c': file(id: 'c', name: '片段C', parentId: 'lesson2'),
        'rootVideo': const PortableTreeNode(
          id: 'rootVideo',
          name: '根目录视频',
          isFolder: false,
          parentId: null,
          childIds: <String>[],
          fileName: 'root.mp4',
        ),
      },
    );
  }

  test('checking a folder selects every descendant without listing them', () {
    final tree = courseTree();
    final selection = PortableMediaSelection();
    selection.setChecked(tree, 'course', true);

    expect(selection.selectedRoots, {'course'});
    expect(selection.checkState(tree, 'a'), PortableCheckState.checked);
    expect(selection.checkState(tree, 'lesson2'), PortableCheckState.checked);
    expect(selection.selectedMediaCount(tree), 3);
    expect(selection.resolve(tree).videoIds, {'a', 'b', 'c'});
    expect(selection.resolve(tree).collectionIds, {
      'course',
      'lesson1',
      'lesson2',
    });
  });

  test('unchecking one nested file keeps siblings and ancestor folders', () {
    final tree = courseTree();
    final selection = PortableMediaSelection();
    selection.setChecked(tree, 'course', true);
    selection.setChecked(tree, 'a', false);

    expect(selection.checkState(tree, 'a'), PortableCheckState.unchecked);
    expect(selection.checkState(tree, 'b'), PortableCheckState.checked);
    expect(selection.checkState(tree, 'lesson1'), PortableCheckState.partial);
    expect(selection.checkState(tree, 'course'), PortableCheckState.partial);
    expect(selection.checkState(tree, 'c'), PortableCheckState.checked);
    expect(selection.selectedRoots, {'b', 'lesson2'});

    final inclusion = selection.resolve(tree);
    expect(inclusion.videoIds, {'b', 'c'});
    expect(inclusion.collectionIds, {'course', 'lesson1', 'lesson2'});
  });

  test('selecting every sibling compacts back to the parent folder', () {
    final tree = courseTree();
    final selection = PortableMediaSelection();
    selection.setChecked(tree, 'a', true);
    selection.setChecked(tree, 'b', true);

    expect(selection.selectedRoots, {'lesson1'});
    expect(selection.checkState(tree, 'lesson1'), PortableCheckState.checked);
    expect(selection.checkState(tree, 'course'), PortableCheckState.partial);

    selection.setChecked(tree, 'c', true);
    expect(selection.selectedRoots, {'course'});
  });

  test('picks from different depths stay selected together', () {
    final tree = courseTree();
    final selection = PortableMediaSelection();
    selection.setChecked(tree, 'a', true);
    selection.setChecked(tree, 'c', true);
    selection.setChecked(tree, 'rootVideo', true);

    expect(selection.selectedRoots, {'a', 'lesson2', 'rootVideo'});
    expect(selection.checkState(tree, 'lesson1'), PortableCheckState.partial);
    expect(selection.checkState(tree, 'lesson2'), PortableCheckState.checked);

    final inclusion = selection.resolve(tree);
    expect(inclusion.videoIds, {'a', 'c', 'rootVideo'});
    expect(inclusion.collectionIds, {'course', 'lesson1', 'lesson2'});
    expect(inclusion.videoIds.contains('b'), isFalse);
  });

  test('exporting only a nested folder omits unused outer shells', () {
    final tree = courseTree();
    final selection = PortableMediaSelection();
    selection.setChecked(tree, 'lesson2', true);

    expect(selection.selectedRoots, {'lesson2'});
    expect(tree.lowestCommonAncestor(selection.selectedRoots), 'lesson2');

    final inclusion = selection.resolve(tree);
    expect(inclusion.videoIds, {'c'});
    expect(inclusion.collectionIds, {'lesson2'});
  });

  test('a lone nested file is exported without parent folders', () {
    final tree = courseTree();
    final selection = PortableMediaSelection();
    selection.setChecked(tree, 'a', true);

    expect(selection.selectedRoots, {'a'});
    final inclusion = selection.resolve(tree);
    expect(inclusion.videoIds, {'a'});
    expect(inclusion.collectionIds, isEmpty);
  });

  test('mixed-depth picks keep the lowest common folder as the wrapper', () {
    final tree = courseTree();
    final selection = PortableMediaSelection();
    selection.setChecked(tree, 'a', true);
    selection.setChecked(tree, 'c', true);

    expect(selection.selectedRoots, {'a', 'lesson2'});
    expect(tree.lowestCommonAncestor(selection.selectedRoots), 'course');

    final inclusion = selection.resolve(tree);
    expect(inclusion.videoIds, {'a', 'c'});
    expect(inclusion.collectionIds, {'course', 'lesson1', 'lesson2'});
  });

  test('lowest common ancestor is null when picks only share the library root', () {
    final tree = courseTree();
    expect(tree.lowestCommonAncestor(['a', 'rootVideo']), isNull);
    expect(tree.lowestCommonAncestor(['course']), 'course');
    expect(tree.lowestCommonAncestor(['a', 'b']), 'lesson1');
  });

  test('unchecking a partial folder clears only that subtree', () {
    final tree = courseTree();
    final selection = PortableMediaSelection();
    selection.setChecked(tree, 'a', true);
    selection.setChecked(tree, 'c', true);
    selection.setChecked(tree, 'lesson1', false);

    expect(selection.checkState(tree, 'a'), PortableCheckState.unchecked);
    expect(selection.checkState(tree, 'c'), PortableCheckState.checked);
    expect(selection.selectedRoots, {'lesson2'});
  });

  test('breadcrumb lists folders from the library root', () {
    final tree = courseTree();
    expect(tree.breadcrumb(tree.node('lesson1')!.parentId), ['课程']);
    expect(tree.breadcrumb(tree.node('a')!.parentId), ['课程', '第一课']);
    expect(tree.breadcrumb(null), isEmpty);
    expect(tree.descendantMediaCount('course'), 3);
    expect(tree.descendantMediaCount('lesson2'), 1);
  });
}
