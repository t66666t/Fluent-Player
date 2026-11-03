import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/podcasts/podcast_models.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/features/podcasts/podcast_subscription_layout.dart';

void main() {
  late PodcastStore store;
  late PodcastSubscriptionLayout layout;

  void channel(String id, {int subscribed = 1, bool active = true}) {
    store.write(
      'channel',
      id,
      PodcastChannel(
        id: id,
        feedUrl: 'https://example.test/$id.xml',
        title: id,
        subscribedMs: subscribed,
        active: active,
      ).toJson(),
    );
  }

  List<String> entries([String? parent]) =>
      layout.entries(parent, store.channels);

  setUp(() {
    store = PodcastStore(sqlite3.openInMemory());
    for (final id in ['a', 'b', 'c', 'd', 'e']) {
      channel(id);
    }
    layout = PodcastSubscriptionLayout(store);
  });
  tearDown(() => store.close());

  test('legacy order survives organizing subscriptions and feed refresh', () {
    store.setOverviewOrder(['c', 'a', 'b', 'd', 'e']);
    layout = PodcastSubscriptionLayout(store);
    expect(entries(), ['c', 'a', 'b', 'd', 'e']);
    final folder = layout.createFolder('通勤');
    expect(layout.move(['a', 'b'], folder), isTrue);
    channel('new', subscribed: 100);
    layout = PodcastSubscriptionLayout(store);
    expect(entries(), ['c', 'd', 'e', folder, 'new']);
    expect(entries(folder), ['a', 'b']);
    layout.renameFolder(folder, '  每天听  ');
    expect(PodcastSubscriptionLayout(store).folder(folder)!.name, '每天听');
    expect(store.overviewOrder(), ['c', 'a', 'b', 'd', 'e']);
  });

  test('nested moves reject self and descendant targets as one operation', () {
    final parent = layout.createFolder('父文件夹');
    final child = layout.createFolder('子文件夹', parentId: parent);
    expect(layout.move(['a', 'b'], child), isTrue);
    expect(layout.canMove([parent], child), isFalse);
    expect(layout.move([parent, 'c'], child), isFalse);
    expect(layout.parentOf('c'), isNull);
    expect(layout.move([parent], parent), isFalse);
    expect(layout.move(['a'], 'missing'), isFalse);
    expect(layout.move(['missing'], child), isFalse);
    expect(layout.move(['a'], parent), isTrue);
    expect(entries(child), ['b']);
    expect(entries(parent), [child, 'a']);
    expect(layout.move(['a'], null), isTrue);
    expect(entries().last, 'a');
  });

  test('reorders selected blocks in display order in either direction', () {
    expect(
      layout.reorder(null, ['b', 'd'], draggedId: 'b', targetId: 'e'),
      isTrue,
    );
    expect(entries(), ['a', 'c', 'e', 'b', 'd']);
    expect(
      layout.reorder(null, ['b', 'd'], draggedId: 'd', targetId: 'a'),
      isTrue,
    );
    expect(entries(), ['b', 'd', 'a', 'c', 'e']);
    expect(
      layout.reorder(null, ['b', 'd'], draggedId: 'b', targetId: 'd'),
      isFalse,
    );
    final folder = layout.createFolder('组');
    layout.move(['a', 'c', 'e'], folder);
    layout.reorder(folder, ['a'], draggedId: 'a', targetId: 'e');
    expect(entries(folder), ['c', 'e', 'a']);
    expect(entries(), ['b', 'd', folder]);
  });

  test(
    'dissolving folders preserves their children at the original position',
    () {
      final parent = layout.createFolder('上级');
      final child = layout.createFolder('下级', parentId: parent);
      layout.move(['b', 'c'], child);
      layout.move(['d'], parent);
      layout.reorder(null, [parent], draggedId: parent, targetId: 'a');
      channel('b', active: false);
      layout.dissolveFolders([parent, child, child]);
      expect(entries(), ['c', 'd', 'a', 'e']);
      expect(layout.folders, isEmpty);
      channel('b');
      expect(entries(), contains('b'));
      expect(layout.parentOf('b'), isNull);
      expect(store.channels.length, 5);
    },
  );

  test(
    'organizing does not change playback, episode state, or download records',
    () {
      final protected = <String, Map<String, dynamic>>{
        'state': {'positionMs': 42000, 'favorite': true},
        'download': {
          'episodeId': 'episode-a',
          'status': 'completed',
          'path': 'audio.mp3',
        },
        'episodeOrder': {
          'ids': ['episode-b', 'episode-a'],
          'revision': 5,
        },
      };
      for (final entry in protected.entries) {
        store.write(entry.key, 'a', entry.value);
      }
      final folder = layout.createFolder('收听');
      layout.move(['a', 'c'], folder);
      layout.reorder(folder, ['a'], draggedId: 'a', targetId: 'c');
      layout.dissolveFolders([folder]);
      for (final entry in protected.entries) {
        expect(store.read(entry.key, 'a'), entry.value);
      }
    },
  );

  test('folders and order survive closing and reopening the database', () {
    final directory = Directory.systemTemp.createTempSync('podcast-folders-');
    final diskStore = PodcastStore.open('${directory.path}/podcasts.sqlite');
    for (final item in store.channels) {
      diskStore.write('channel', item.id, item.toJson());
    }
    final diskLayout = PodcastSubscriptionLayout(diskStore);
    final parent = diskLayout.createFolder('外层');
    final child = diskLayout.createFolder('内层', parentId: parent);
    diskLayout.move(['a', 'c'], child);
    diskLayout.reorder(child, ['a'], draggedId: 'a', targetId: 'c');
    diskStore.close();
    final reopened = PodcastStore.open('${directory.path}/podcasts.sqlite');
    try {
      final restored = PodcastSubscriptionLayout(reopened);
      expect(restored.ancestors(child).map((folder) => folder.name), [
        '外层',
        '内层',
      ]);
      expect(restored.entries(child, reopened.channels), ['c', 'a']);
      reopened.setOverviewOrder(['d', 'e', 'b']);
      expect(PodcastSubscriptionLayout(reopened).folder(child), isNotNull);
    } finally {
      reopened.close();
      directory.deleteSync(recursive: true);
    }
  });

  test('orphaned and cyclic folders remain reachable from the root', () {
    store.write('viewState', 'podcast-overview', {
      'folders': [
        {'id': 'podcast-folder:a', 'name': 'A', 'parentId': 'podcast-folder:b'},
        {'id': 'podcast-folder:b', 'name': 'B', 'parentId': 'podcast-folder:a'},
        {'id': 'podcast-folder:c', 'name': 'C', 'parentId': 'missing'},
      ],
      'channelFolders': {'a': 'podcast-folder:b', 'b': 'missing'},
    });
    layout = PodcastSubscriptionLayout(store);
    expect(layout.ancestors('podcast-folder:b').length, lessThanOrEqualTo(2));
    expect(
      entries(),
      containsAll(['podcast-folder:a', 'podcast-folder:c', 'b']),
    );
    expect(entries('podcast-folder:b'), contains('a'));
  });
}
