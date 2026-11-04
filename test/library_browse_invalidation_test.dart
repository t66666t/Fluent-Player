import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/widgets/library_card_rebuild.dart';

void main() {
  final library = LibraryService();
  setUp(() {
    library.resetLibraryForTesting();
  });
  tearDown(() {
    library.resetLibraryForTesting();
  });

  for (final count in [1000, 10000]) {
    testWidgets(
      '$count items keep bounded cells and stable membership on cache/activity updates',
      (tester) async {
        final folder = VideoCollection(
          id: 'large',
          name: 'Large',
          createTime: 0,
        );
        for (var i = 0; i < count; i++) {
          final id = 'v$i';
          folder.childrenIds.add(id);
          library.seedVideoForTesting(
            VideoItem(
              id: id,
              parentId: folder.id,
              path: '/missing/$id.mp4',
              title: id,
              durationMs: 1000,
              lastUpdated: 0,
            ),
          );
        }
        library.seedCollectionForTesting(folder);
        final initial = library.browseContents(folder.id);
        var pageBuilds = 0, cellBuilds = 0;
        await tester.pumpWidget(
          ChangeNotifierProvider.value(
            value: library,
            child: MaterialApp(
              home: Selector<LibraryService, int>(
                selector: (_, service) => service.browseRevision,
                builder: (_, _, _) {
                  pageBuilds++;
                  final items = library.browseContents(folder.id);
                  return GridView.builder(
                    itemCount: items.length,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisExtent: 160,
                        ),
                    itemBuilder: (_, index) => LibraryCardRebuild(
                      itemId: items[index].id,
                      builder: (_) {
                        cellBuilds++;
                        return Text(items[index].title);
                      },
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(cellBuilds, lessThan(40));
        final built = cellBuilds;
        library.notifyOnlineCacheChanged('v999');
        await tester.pump();
        expect(pageBuilds, 1);
        expect(cellBuilds, built);
        expect(identical(initial, library.browseContents(folder.id)), true);
        folder.childrenIds.removeLast();
        library.notifyListeners();
        await tester.pump();
        expect(pageBuilds, 2);
        expect(library.browseContents(folder.id).length, count - 1);
        expect(initial.length, count);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
