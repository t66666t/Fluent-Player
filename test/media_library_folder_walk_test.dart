import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_library_folder_walk.dart';
import 'package:video_player_app/widgets/media_library_folder_breadcrumb.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LibraryService library;

  setUp(() {
    library = LibraryService();
    library.resetLibraryForTesting();
    MediaLibraryFolderBrowseMemory.resetForTest();
  });

  tearDown(() {
    library.resetLibraryForTesting();
    MediaLibraryFolderBrowseMemory.resetForTest();
  });

  test('DFS include-subfolders follows children order and skips recycled', () {
    library.seedCollectionForTesting(
      _folder('a', children: ['ch1', 'ch2', 'gone']),
    );
    library.seedCollectionForTesting(
      _folder('ch1', parentId: 'a', children: ['v1']),
    );
    library.seedCollectionForTesting(
      _folder('ch2', parentId: 'a', children: ['b']),
    );
    library.seedCollectionForTesting(
      _folder('b', parentId: 'ch2', children: ['v2', 'dup']),
    );
    library.seedCollectionForTesting(
      _folder('gone', parentId: 'a', recycled: true, children: ['hidden']),
    );
    library.seedVideoForTesting(_clip('v1', parentId: 'ch1'));
    library.seedVideoForTesting(_clip('v2', parentId: 'b'));
    library.seedVideoForTesting(_clip('dup', parentId: 'b'));
    library.seedVideoForTesting(_clip('hidden', parentId: 'gone'));

    final snapshot = List<String>.from(
      library.getCollection('a')!.childrenIds,
    );
    final media = library.mediaInFolderTree('a');
    expect(media.map((item) => item.id), ['v1', 'v2', 'dup']);
    expect(library.getCollection('a')!.childrenIds, snapshot);
    expect(library.relativeFolderPath('a', 'b'), 'ch2 / b');
    expect(library.relativeFolderPath('a', 'a'), '');
  });

  test('cycles and duplicate ids terminate without repeating media', () {
    library.seedCollectionForTesting(_folder('loop', children: ['loop', 'v']));
    library.seedVideoForTesting(_clip('v', parentId: 'loop'));
    library.seedCollectionForTesting(
      _folder('x', children: ['y']),
    );
    library.seedCollectionForTesting(
      _folder('y', parentId: 'x', children: ['x', 'w']),
    );
    library.seedVideoForTesting(_clip('w', parentId: 'y'));

    expect(library.mediaInFolderTree('loop').map((item) => item.id), ['v']);
    expect(library.mediaInFolderTree('x').map((item) => item.id), ['w']);
  });

  test('same-named folders stay distinct in relative paths', () {
    library.seedCollectionForTesting(_folder('root', children: ['c1', 'c2']));
    library.seedCollectionForTesting(
      _folder('c1', name: '第一课', parentId: 'root', children: ['a']),
    );
    library.seedCollectionForTesting(
      _folder('c2', name: '第一课', parentId: 'root', children: ['b']),
    );
    library.seedVideoForTesting(_clip('a', parentId: 'c1'));
    library.seedVideoForTesting(_clip('b', parentId: 'c2'));

    expect(library.relativeFolderPath('root', 'c1'), '第一课');
    expect(library.relativeFolderPath('root', 'c2'), '第一课');
    expect(
      library.mediaInFolderTree('root').map((item) => item.id),
      ['a', 'b'],
    );
  });

  test('session include memory defaults off except last persisted folder', () {
    expect(
      MediaLibraryFolderBrowseMemory.includeFor(
        folderId: 'a',
        lastFolderId: 'b',
        persistedLast: true,
      ),
      isFalse,
    );
    expect(
      MediaLibraryFolderBrowseMemory.includeFor(
        folderId: 'b',
        lastFolderId: 'b',
        persistedLast: true,
      ),
      isTrue,
    );
    MediaLibraryFolderBrowseMemory.remember('a', true);
    expect(
      MediaLibraryFolderBrowseMemory.includeFor(
        folderId: 'a',
        lastFolderId: 'b',
        persistedLast: false,
      ),
      isTrue,
    );
  });

  testWidgets('breadcrumb keeps the full trail and scrolls instead of collapsing', (
    tester,
  ) async {
    String? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 120,
            child: MediaLibraryFolderBreadcrumb(
              compact: true,
              onSelected: (id) => opened = id,
              crumbs: const [
                MediaLibraryBreadcrumbCrumb(folderId: null, label: '媒体库'),
                MediaLibraryBreadcrumbCrumb(folderId: 'a', label: 'A'),
                MediaLibraryBreadcrumbCrumb(folderId: 'b', label: 'B'),
                MediaLibraryBreadcrumbCrumb(folderId: 'c', label: 'C'),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('…'), findsNothing);
    expect(find.text('C'), findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsOneWidget);

    final scroller = tester.widget<SingleChildScrollView>(
      find.byType(SingleChildScrollView),
    );
    scroller.controller!.jumpTo(0);
    await tester.pump();
    await tester.tap(find.text('A'));
    await tester.pump();
    expect(opened, 'a');
  });
}

VideoCollection _folder(
  String id, {
  String? parentId,
  List<String>? children,
  bool recycled = false,
  String? name,
}) {
  return VideoCollection(
    id: id,
    name: name ?? id,
    createTime: 1,
    parentId: parentId,
    childrenIds: children ?? <String>[],
    isRecycled: recycled,
  );
}

VideoItem _clip(String id, {String? parentId}) {
  return VideoItem(
    id: id,
    path: '/tmp/$id.mp4',
    title: id,
    durationMs: 1,
    lastUpdated: 1,
    parentId: parentId,
    hasProbedChapters: true,
  );
}
