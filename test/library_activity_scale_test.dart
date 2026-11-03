import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/library_activity.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_activity_projection.dart';
import 'package:video_player_app/services/media_library_folder_walk.dart';

void main() {
  test('thousand-item metadata queries stay in memory and keep counts', () {
    final collections = <String, VideoCollection>{};
    final videos = <String, VideoItem>{};
    final media = <String, MediaActivityRecord>{};
    final batchMembers = <String>[];

    collections['root'] = VideoCollection(
      id: 'root',
      name: 'Root',
      createTime: 1,
      childrenIds: List<String>.generate(20, (index) => 'f$index'),
    );
    for (var folder = 0; folder < 20; folder++) {
      final childIds = <String>[];
      for (var slot = 0; slot < 50; slot++) {
        final id = 'm${folder * 50 + slot}';
        childIds.add(id);
        videos[id] = VideoItem(
          id: id,
          path: '/meta/$id.mp4',
          title: 'Title $id with a fairly long course name',
          durationMs: 120000,
          lastUpdated: 1,
          parentId: 'f$folder',
          lastPositionMs: slot == 0 ? 40000 : 0,
        );
        media[id] = MediaActivityRecord(
          mediaId: id,
          addedAtMs: 1 + folder * 50 + slot,
          lastPlayedAtMs: slot == 0 ? 1000 + folder : null,
          accumulatedWatchMs: slot == 0 ? 40000 : 0,
        );
        if (folder == 0) batchMembers.add(id);
      }
      collections['f$folder'] = VideoCollection(
        id: 'f$folder',
        name: 'Folder $folder',
        createTime: 1,
        parentId: 'root',
        childrenIds: childIds,
      );
    }

    final store = LibraryActivityStore(
      media: media,
      batches: [
        ImportBatchRecord(
          id: 'batch-0',
          startedAtMs: 1,
          title: 'Course',
          sourceKind: LibraryImportSourceKind.localFile,
          createdMediaIds: batchMembers,
        ),
      ],
      pinnedIds: <String>['f0'],
    );
    final projection = LibraryActivityProjection(
      store: store,
      videoOf: (id) => videos[id],
      collectionOf: (id) => collections[id],
      allVideos: () => videos.values,
    );

    final started = DateTime.now();
    final recent = projection.recentAddedEntries();
    final sections = projection.continueLearningSections();
    final walked = MediaLibraryFolderWalk.collectMedia(
      rootId: 'root',
      folderOf: (id) => collections[id],
      videoOf: (id) => videos[id],
    );
    final elapsed = DateTime.now().difference(started);

    expect(videos.length, 1000);
    expect(
      recent
          .where((row) => row.kind == RecentAddedKind.batch)
          .single
          .visibleMediaIds,
      hasLength(50),
    );
    expect(
      recent.where((row) => row.kind == RecentAddedKind.single),
      hasLength(950),
    );
    expect(sections.recent, hasLength(20));
    expect(walked, hasLength(1000));
    expect(projection.visiblePinnedIds(), <String>['f0']);
    expect(elapsed.inMilliseconds, lessThan(2000));
  });
}
