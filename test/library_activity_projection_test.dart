import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/library_activity.dart';
import 'package:video_player_app/models/media_library_continue_policy.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_activity_projection.dart';

void main() {
  test('recycled ancestor walks terminate on parent cycles', () {
    final collections = <String, VideoCollection>{
      'a': _folder('a', parentId: 'b', recycled: true),
      'b': _folder('b', parentId: 'a'),
    };
    final videos = <String, VideoItem>{'clip': _item('clip', parentId: 'b')};
    final projection = _projection(
      collections: collections,
      videos: videos,
      store: LibraryActivityStore(
        media: <String, MediaActivityRecord>{
          'clip': MediaActivityRecord(mediaId: 'clip', addedAtMs: 3),
        },
        pinnedIds: <String>['clip'],
      ),
    );

    expect(projection.hasRecycledAncestor('b'), isTrue);
    expect(projection.isVisibleMedia('clip'), isFalse);
    expect(projection.visiblePinnedIds(), isEmpty);
  });

  test('recent added keeps unknown times out of the dated list', () {
    final videos = <String, VideoItem>{
      'new': _item('new'),
      'old': _item('old', lastUpdated: 9999),
      'gone': _item('gone', recycled: true),
    };
    final projection = _projection(
      videos: videos,
      store: LibraryActivityStore(
        media: <String, MediaActivityRecord>{
          'new': MediaActivityRecord(mediaId: 'new', addedAtMs: 20),
          'old': MediaActivityRecord(mediaId: 'old'),
        },
      ),
    );

    final recent = projection.recentAddedMediaIds();
    expect(recent.datedIds, ['new']);
    expect(recent.unknownAddedIds, ['old']);
  });

  test('continue-learning groups folders to the latest item', () {
    final collections = <String, VideoCollection>{'course': _folder('course')};
    final videos = <String, VideoItem>{
      'ep1': _item('ep1', parentId: 'course'),
      'ep2': _item('ep2', parentId: 'course'),
      'loose': _item('loose'),
    };
    final projection = _projection(
      collections: collections,
      videos: videos,
      store: LibraryActivityStore(
        media: <String, MediaActivityRecord>{
          'ep1': MediaActivityRecord(
            mediaId: 'ep1',
            lastPlayedAtMs: 10,
            accumulatedWatchMs: 40000,
          ),
          'ep2': MediaActivityRecord(
            mediaId: 'ep2',
            lastPlayedAtMs: 30,
            accumulatedWatchMs: 40000,
          ),
          'loose': MediaActivityRecord(
            mediaId: 'loose',
            lastPlayedAtMs: 20,
            accumulatedWatchMs: 40000,
          ),
        },
      ),
    );

    final groups = projection.continueLearningGroups();
    expect(groups.singleWhere((group) => group.parentId == 'course').mediaIds, [
      'ep2',
      'ep1',
    ]);
    expect(
      groups
          .where((group) => group.parentId == null)
          .map((g) => g.mediaIds.single),
      ['loose'],
    );
  });

  test('recent rows order batches by startedAt then id, not lastUpdated', () {
    final videos = <String, VideoItem>{
      'a1': _item('a1', lastUpdated: 999),
      'a2': _item('a2', lastUpdated: 999),
      'b1': _item('b1', lastUpdated: 1),
      'b2': _item('b2', lastUpdated: 1),
      'orphan': _item('orphan', lastUpdated: 5000),
      'old': _item('old', lastUpdated: 8000),
    };
    final projection = _projection(
      videos: videos,
      store: LibraryActivityStore(
        media: <String, MediaActivityRecord>{
          'a1': MediaActivityRecord(mediaId: 'a1', addedAtMs: 10),
          'a2': MediaActivityRecord(mediaId: 'a2', addedAtMs: 11),
          'b1': MediaActivityRecord(mediaId: 'b1', addedAtMs: 20),
          'b2': MediaActivityRecord(mediaId: 'b2', addedAtMs: 21),
          'orphan': MediaActivityRecord(mediaId: 'orphan', addedAtMs: 15),
          'old': MediaActivityRecord(mediaId: 'old'),
        },
        batches: [
          ImportBatchRecord(
            id: 'batch-a',
            startedAtMs: 100,
            title: 'A',
            sourceKind: LibraryImportSourceKind.folder,
            createdMediaIds: ['a1', 'a2'],
          ),
          ImportBatchRecord(
            id: 'batch-b',
            startedAtMs: 100,
            title: 'B',
            sourceKind: LibraryImportSourceKind.folder,
            createdMediaIds: ['b1', 'b2'],
          ),
        ],
      ),
    );

    final rows = projection.recentAddedEntries();
    expect(rows.map((row) => row.rowId).toList(), [
      'batch:batch-b',
      'batch:batch-a',
      'media:orphan',
      'unknown',
    ]);
    expect(rows[0].groupHeaderLabel(), 'B·当前2项');
    expect(rows.last.visibleMediaIds, ['old']);
  });

  test('single-member batches render as media and skip duplicate singles', () {
    final videos = <String, VideoItem>{'only': _item('only')};
    final projection = _projection(
      videos: videos,
      store: LibraryActivityStore(
        media: <String, MediaActivityRecord>{
          'only': MediaActivityRecord(mediaId: 'only', addedAtMs: 3),
        },
        batches: [
          ImportBatchRecord(
            id: 'one',
            startedAtMs: 3,
            title: 'Solo',
            sourceKind: LibraryImportSourceKind.localFile,
            createdMediaIds: ['only'],
          ),
        ],
      ),
    );
    final rows = projection.recentAddedEntries();
    expect(rows, hasLength(1));
    expect(rows.single.kind, RecentAddedKind.single);
    expect(rows.single.mediaId, 'only');
    expect(rows.single.sourceBatchId, 'one');
  });

  test('recycled members drop out and empty batches disappear', () {
    final videos = <String, VideoItem>{
      'keep': _item('keep'),
      'gone': _item('gone', recycled: true),
    };
    final projection = _projection(
      videos: videos,
      store: LibraryActivityStore(
        media: <String, MediaActivityRecord>{
          'keep': MediaActivityRecord(mediaId: 'keep', addedAtMs: 1),
          'gone': MediaActivityRecord(mediaId: 'gone', addedAtMs: 1),
        },
        batches: [
          ImportBatchRecord(
            id: 'mixed',
            startedAtMs: 1,
            title: 'Mix',
            sourceKind: LibraryImportSourceKind.archive,
            createdMediaIds: ['keep', 'gone'],
          ),
          ImportBatchRecord(
            id: 'dead',
            startedAtMs: 2,
            title: 'Dead',
            sourceKind: LibraryImportSourceKind.archive,
            createdMediaIds: ['gone'],
          ),
        ],
      ),
    );
    final rows = projection.recentAddedEntries();
    expect(rows.single.kind, RecentAddedKind.single);
    expect(rows.single.mediaId, 'keep');
  });

  test('empty library has no recent rows', () {
    final projection = _projection(store: LibraryActivityStore.empty());
    expect(projection.recentAddedEntries(), isEmpty);
  });

  test('continue-learning skips preview ticks and pinned media', () {
    final collections = <String, VideoCollection>{
      'alpha': _folder('alpha', name: '课程'),
      'beta': _folder('beta', name: '课程'),
    };
    final videos = <String, VideoItem>{
      'preview': _item('preview', lastPositionMs: 4000),
      'legacy': _item('legacy', lastPositionMs: 8000),
      'pinned': _item('pinned', parentId: 'alpha'),
      'a1': _item('a1', parentId: 'alpha'),
      'b1': _item('b1', parentId: 'beta'),
      'done': _item('done'),
    };
    final projection = _projection(
      collections: collections,
      videos: videos,
      store: LibraryActivityStore(
        pinnedIds: <String>['pinned'],
        media: <String, MediaActivityRecord>{
          'preview': MediaActivityRecord(
            mediaId: 'preview',
            accumulatedWatchMs: 4000,
          ),
          'legacy': MediaActivityRecord(mediaId: 'legacy'),
          'pinned': MediaActivityRecord(
            mediaId: 'pinned',
            lastPlayedAtMs: 90,
            accumulatedWatchMs: 40000,
          ),
          'a1': MediaActivityRecord(
            mediaId: 'a1',
            lastPlayedAtMs: 50,
            accumulatedWatchMs: 40000,
          ),
          'b1': MediaActivityRecord(
            mediaId: 'b1',
            lastPlayedAtMs: 80,
            accumulatedWatchMs: 40000,
          ),
          'done': MediaActivityRecord(
            mediaId: 'done',
            lastPlayedAtMs: 70,
            completed: true,
            accumulatedWatchMs: 40000,
          ),
        },
      ),
    );

    final sections = projection.continueLearningSections();
    expect(sections.recent.map((group) => group.featuredMediaId), ['b1', 'a1']);
    expect(sections.unknown.single.mediaIds, ['legacy']);
    expect(projection.visiblePinnedIds(), ['pinned']);
  });

  test('hidden media leave continue-learning until unhidden', () {
    final videos = <String, VideoItem>{
      'clip': _item('clip', lastPositionMs: 1000),
    };
    final store = LibraryActivityStore(
      media: <String, MediaActivityRecord>{
        'clip': MediaActivityRecord(
          mediaId: 'clip',
          lastPlayedAtMs: 9,
          accumulatedWatchMs: 40000,
          hidden: true,
        ),
      },
    );
    final projection = _projection(videos: videos, store: store);
    expect(projection.continueLearningSections().isEmpty, isTrue);
    store.media['clip']!.hidden = false;
    expect(
      projection.continueLearningSections().recent.single.featuredMediaId,
      'clip',
    );
  });

  test('playback history keeps short plays and completed, not hidden', () {
    final videos = <String, VideoItem>{
      'peek': _item('peek'),
      'done': _item('done'),
      'hidden': _item('hidden'),
      'fresh': _item('fresh'),
    };
    final projection = _projection(
      videos: videos,
      store: LibraryActivityStore(
        media: <String, MediaActivityRecord>{
          'peek': MediaActivityRecord(
            mediaId: 'peek',
            lastPlayedAtMs: 30,
            accumulatedWatchMs: 800,
            continueEnrolled: false,
          ),
          'done': MediaActivityRecord(
            mediaId: 'done',
            lastPlayedAtMs: 20,
            accumulatedWatchMs: 40000,
            completed: true,
          ),
          'hidden': MediaActivityRecord(
            mediaId: 'hidden',
            lastPlayedAtMs: 40,
            accumulatedWatchMs: 800,
            hidden: true,
            continueEnrolled: false,
          ),
          'fresh': MediaActivityRecord(mediaId: 'fresh'),
        },
      ),
    );
    expect(projection.playbackHistoryMediaIds(), ['peek', 'done']);
    expect(projection.isContinueEligible(videos['peek']!), isFalse);
    expect(projection.isContinueEligible(videos['done']!), isFalse);

    final now = DateTime(2026, 9, 20, 12);
    final todayMs = DateTime(2026, 9, 20, 10).millisecondsSinceEpoch;
    final yesterdayMs = DateTime(2026, 9, 19, 18).millisecondsSinceEpoch;
    final dayGroups = LibraryActivityProjection(
      store: LibraryActivityStore(
        media: <String, MediaActivityRecord>{
          'peek': MediaActivityRecord(
            mediaId: 'peek',
            lastPlayedAtMs: todayMs,
            accumulatedWatchMs: 800,
            continueEnrolled: false,
          ),
          'done': MediaActivityRecord(
            mediaId: 'done',
            lastPlayedAtMs: yesterdayMs,
            accumulatedWatchMs: 40000,
            completed: true,
          ),
        },
      ),
      videoOf: (id) => videos[id],
      collectionOf: (_) => null,
      allVideos: () => videos.values,
    ).playbackHistoryDayGroups(now: now);
    expect(dayGroups.map((group) => group.label).toList(), ['今天', '昨天']);
    expect(dayGroups.first.mediaIds, ['peek']);
  });

  test('custom continue policy refilters without rewatching', () {
    final videos = <String, VideoItem>{
      'clip': VideoItem(
        id: 'clip',
        path: '/tmp/clip.mp4',
        title: 'clip',
        durationMs: 120000,
        lastUpdated: 1,
        lastPositionMs: 40000,
      ),
    };
    final projection = _projection(
      videos: videos,
      store: LibraryActivityStore(
        media: <String, MediaActivityRecord>{
          'clip': MediaActivityRecord(
            mediaId: 'clip',
            lastPlayedAtMs: 9,
            accumulatedWatchMs: 40000,
          ),
        },
      ),
    );
    expect(projection.isContinueEligible(videos['clip']!), isTrue);
    final strict = ContinueWatchPolicy.defaults.copyWith(
      combineMode: ContinueWatchCombineMode.both,
      minWatchMs: 60000,
    );
    expect(
      projection.isContinueEligible(videos['clip']!, policy: strict),
      isFalse,
    );
  });

  test('folder import shows the root first layer, not nested files', () {
    final videos = <String, VideoItem>{
      'loose': _item('loose', parentId: 'root'),
      'deep': _item('deep', parentId: 'chapter'),
      'deeper': _item('deeper', parentId: 'section'),
    };
    final collections = <String, VideoCollection>{
      'root': _folder(
        'root',
        name: '课程',
        childrenIds: ['loose', 'chapter', 'other'],
      ),
      'chapter': _folder(
        'chapter',
        name: '第一章',
        parentId: 'root',
        childrenIds: ['deep', 'section'],
      ),
      'section': _folder(
        'section',
        name: '小节',
        parentId: 'chapter',
        childrenIds: ['deeper'],
      ),
      'other': _folder(
        'other',
        name: '第二章',
        parentId: 'root',
        childrenIds: <String>[],
      ),
    };
    final projection = _projection(
      videos: videos,
      collections: collections,
      store: LibraryActivityStore(
        media: <String, MediaActivityRecord>{
          for (final id in videos.keys)
            id: MediaActivityRecord(mediaId: id, addedAtMs: 5),
        },
        batches: [
          ImportBatchRecord(
            id: 'folder-batch',
            startedAtMs: 5,
            title: '课程',
            sourceKind: LibraryImportSourceKind.folder,
            createdMediaIds: videos.keys.toList(),
            createdCollectionIds: ['root', 'chapter', 'section', 'other'],
          ),
        ],
      ),
    );

    final rows = projection.recentAddedEntries();
    expect(rows, hasLength(1));
    expect(rows.single.groupHeaderLabel(), '课程·当前2项');
    expect(rows.single.children.map((child) => child.id).toList(), [
      'loose',
      'chapter',
    ]);
    expect(rows.single.children[1].kind, RecentAddedChildKind.folder);
  });

  test('bilibili import splits a collection and a lone video', () {
    final videos = <String, VideoItem>{
      'p1': _item('p1', parentId: 'parts'),
      'p2': _item('p2', parentId: 'parts'),
      'single': _item('single'),
    };
    final collections = <String, VideoCollection>{
      'season': _folder(
        'season',
        name: '合集',
        childrenIds: ['parts', 'episode-file'],
      ),
      'parts': _folder(
        'parts',
        name: '分P视频',
        parentId: 'season',
        childrenIds: ['p1', 'p2'],
      ),
      'episode': _folder(
        'episode',
        name: '单集成片',
        parentId: 'season',
        childrenIds: <String>[],
      ),
    };
    videos['episode-file'] = _item('episode-file', parentId: 'season');
    final projection = _projection(
      videos: videos,
      collections: collections,
      store: LibraryActivityStore(
        media: <String, MediaActivityRecord>{
          for (final id in ['p1', 'p2', 'single', 'episode-file'])
            id: MediaActivityRecord(mediaId: id, addedAtMs: 8),
        },
        batches: [
          ImportBatchRecord(
            id: 'bili',
            startedAtMs: 8,
            title: 'B站下载 4 项',
            sourceKind: LibraryImportSourceKind.bilibili,
            createdMediaIds: ['p1', 'p2', 'episode-file', 'single'],
            createdCollectionIds: ['season', 'parts'],
          ),
        ],
      ),
    );

    final rows = projection.recentAddedEntries();
    expect(rows.map((row) => row.rowId).toList(), [
      'batch:bili:season',
      'media:single',
    ]);
    expect(rows.first.groupHeaderLabel(), '合集·当前2项');
    expect(rows.first.children.map((child) => child.id).toList(), [
      'parts',
      'episode-file',
    ]);
  });

  test('dismissed recent cards leave the page and keep the import clock', () {
    final videos = <String, VideoItem>{
      'loose': _item('loose'),
      'old': _item('old'),
      'stay': _item('stay'),
    };
    final projection = _projection(
      videos: videos,
      store: LibraryActivityStore(
        media: <String, MediaActivityRecord>{
          'loose': MediaActivityRecord(
            mediaId: 'loose',
            addedAtMs: 30,
            lastPlayedAtMs: 30,
            accumulatedWatchMs: 40000,
          ),
          'old': MediaActivityRecord(mediaId: 'old'),
          'stay': MediaActivityRecord(mediaId: 'stay', addedAtMs: 10),
        },
        recentDismissedIds: <String>['loose', 'old'],
      ),
    );

    expect(projection.recentAddedEntries().map((row) => row.mediaId).toList(), [
      'stay',
    ]);
    expect(
      projection.recentAddedMediaIds().datedIds,
      containsAll(<String>['loose', 'stay']),
    );
    expect(projection.recentAddedMediaIds().unknownAddedIds, ['old']);
    expect(projection.isContinueEligible(videos['loose']!), isTrue);
    expect(projection.isMediaHidden('loose'), isFalse);
  });

  test('continue-learning hide keeps the recent card', () {
    final clip = _item('clip');
    final projection = _projection(
      videos: <String, VideoItem>{'clip': clip},
      store: LibraryActivityStore(
        media: <String, MediaActivityRecord>{
          'clip': MediaActivityRecord(
            mediaId: 'clip',
            addedAtMs: 4,
            hidden: true,
            lastPlayedAtMs: 4,
            accumulatedWatchMs: 40000,
          ),
        },
      ),
    );

    expect(projection.recentAddedEntries().single.mediaId, 'clip');
    expect(projection.isContinueEligible(clip), isFalse);
  });

  test('hiding a recent folder card does not spill nested files', () {
    final videos = <String, VideoItem>{
      'loose': _item('loose', parentId: 'root'),
      'deep': _item('deep', parentId: 'chapter'),
      'deeper': _item('deeper', parentId: 'section'),
    };
    final collections = <String, VideoCollection>{
      'root': _folder('root', name: '课程', childrenIds: ['loose', 'chapter']),
      'chapter': _folder(
        'chapter',
        name: '第一章',
        parentId: 'root',
        childrenIds: ['deep', 'section'],
      ),
      'section': _folder(
        'section',
        name: '小节',
        parentId: 'chapter',
        childrenIds: ['deeper'],
      ),
    };
    final store = LibraryActivityStore(
      media: <String, MediaActivityRecord>{
        for (final id in videos.keys)
          id: MediaActivityRecord(mediaId: id, addedAtMs: 5),
      },
      batches: [
        ImportBatchRecord(
          id: 'folder-batch',
          startedAtMs: 5,
          title: '课程',
          sourceKind: LibraryImportSourceKind.folder,
          createdMediaIds: videos.keys.toList(),
          createdCollectionIds: ['root', 'chapter', 'section'],
        ),
      ],
    );
    final projection = _projection(
      videos: videos,
      collections: collections,
      store: store,
    );

    expect(
      projection.recentAddedEntries().single.children.map((child) => child.id),
      ['loose', 'chapter'],
    );

    store.recentDismissedIds.add('chapter');
    final afterFolder = projection.recentAddedEntries();
    expect(afterFolder, hasLength(1));
    expect(afterFolder.single.kind, RecentAddedKind.single);
    expect(afterFolder.single.mediaId, 'loose');

    store.recentDismissedIds.add('loose');
    expect(projection.recentAddedEntries(), isEmpty);
    expect(projection.recentAddedMediaIds().datedIds, contains('deep'));
  });
}

LibraryActivityProjection _projection({
  required LibraryActivityStore store,
  Map<String, VideoItem> videos = const <String, VideoItem>{},
  Map<String, VideoCollection> collections = const <String, VideoCollection>{},
}) {
  return LibraryActivityProjection(
    store: store,
    videoOf: (id) => videos[id],
    collectionOf: (id) => collections[id],
    allVideos: () => videos.values,
  );
}

VideoItem _item(
  String id, {
  String? parentId,
  int lastUpdated = 1,
  bool recycled = false,
  int lastPositionMs = 0,
}) {
  return VideoItem(
    id: id,
    path: '/tmp/$id.mp4',
    title: id,
    durationMs: 1,
    lastUpdated: lastUpdated,
    parentId: parentId,
    isRecycled: recycled,
    lastPositionMs: lastPositionMs,
  );
}

VideoCollection _folder(
  String id, {
  String? parentId,
  bool recycled = false,
  String? name,
  List<String>? childrenIds,
}) {
  return VideoCollection(
    id: id,
    name: name ?? id,
    createTime: 1,
    parentId: parentId,
    isRecycled: recycled,
    childrenIds: childrenIds,
  );
}
