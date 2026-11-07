import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_controller.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_pages.dart';
import 'package:video_player_app/features/podcasts/podcast_runtime.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/models/playback_mode.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playback_queue_actions.dart';
import 'package:video_player_app/services/playback_queue_policy.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/widgets/episode_picker_panel.dart';
import 'package:video_player_app/widgets/playback_queue_remove_button.dart';
import 'package:video_player_app/widgets/playlist_bottom_sheet.dart';

import 'podcast_core_test.dart' show podcastFixture;
import 'test_artifacts.dart';

VideoItem _item(int index, {String? path}) => VideoItem(
  id: 'item-$index',
  path: path ?? '/$index.mp3',
  title: '测试媒体 $index · 很长的节目名称也应该保留足够的标题空间',
  durationMs: 125000,
  lastUpdated: 0,
  type: MediaType.audio,
);

PlaylistManager _queue() =>
    PlaylistManager(queuePolicy: PlaybackQueuePolicy(sourceExists: (_) => true))
      ..setPlaylist(List.generate(3, _item));

class _Playback extends MediaPlaybackService {
  _Playback(this.queue) : selected = queue.currentItem!, super.forTesting();
  final PlaylistManager queue;
  final VideoItem selected;
  int itemTaps = 0;
  @override
  VideoItem get currentItem => selected;
  @override
  bool get isPlaying => true;
  @override
  PlaybackState get state => PlaybackState.playing;
  @override
  VideoItem? get nextPlayableItem => queue.getNext();
  @override
  VideoItem? get previousPlayableItem => queue.getPrevious();
  @override
  PlaybackMode get playbackMode => queue.playbackMode;
  @override
  String? queueItemStatus(String id) => id == selected.id
      ? '播放中'
      : id == nextPlayableItem?.id
      ? '自动连播已开启'
      : null;
  @override
  Future<void> playPlaylistItem(
    VideoItem item, {
    bool? autoPlay,
    Duration? startPosition,
    bool forceFromStart = false,
  }) async {
    itemTaps++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  setUpAll(() async {
    await (FontLoader(
      'Noto Sans SC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC-Variable.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  test(
    'removal preserves mode, queue owner and anchor; refresh does not reinsert',
    () {
      final queue = _queue();
      final owner = Object();
      queue.queueOwner = owner;
      queue.setPlaybackMode(PlaybackMode.shuffle);
      final next = queue.relativeItem(next: true)!;
      final planned = queue.planNavigation([1])!;
      queue.prepareNavigation(planned);
      expect(queue.removeFromQueue(next.id), isTrue);
      expect(queue.playlist, hasLength(2));
      expect(queue.playbackMode, PlaybackMode.shuffle);
      expect(queue.queueOwner, same(owner));
      expect(queue.currentItem?.id, 'item-0');
      queue.revalidatePlaylist();
      queue.refreshQueueEligibility();
      expect(queue.playbackQueue.any((item) => item.id == next.id), isFalse);
      expect(queue.relativeItem(next: true)?.id, isNot(next.id));
      final revision = queue.revision;
      expect(queue.removeFromQueue(next.id), isFalse);
      expect(queue.revision, revision);
      expect(queue.removeFromQueue('item-0'), isTrue);
      expect(queue.anchoredItemId, 'item-0');
      expect(queue.currentIndex, -1);
      expect(queue.isCurrentItemDetached, isTrue);
      expect(queue.hasNext, isFalse);
      expect(queue.hasPrevious, isFalse);
      for (final item in [...queue.playlist]) {
        queue.removeFromQueue(item.id);
      }
      expect(queue.playbackQueue, isEmpty);
    },
  );

  test(
    'editing a folder queue survives reload and leaves library files intact',
    () async {
      final root = Directory.systemTemp.createTempSync('queue-remove-folder-');
      final library = LibraryService()..resetLibraryForTesting();
      addTearDown(() async {
        library.resetLibraryForTesting();
        await root.delete(recursive: true);
      });
      final items = [
        for (var i = 0; i < 3; i++) _item(i, path: '${root.path}/$i.mp3'),
      ];
      for (final item in items) {
        File(item.path).writeAsBytesSync([0]);
        item.parentId = 'folder';
        library.seedVideoForTesting(item);
      }
      library.seedCollectionForTesting(
        VideoCollection(
          id: 'folder',
          name: 'Folder',
          createTime: 0,
          childrenIds: items.map((item) => item.id).toList(),
        ),
      );
      final queue = PlaylistManager()..initialize(libraryService: library);
      queue.loadFolderPlaylist('folder', items.first.id);
      expect(queue.playlist.map((item) => item.id), contains(items[1].id));
      queue.removeFromQueue(items[1].id);
      queue.reloadPlaylist();
      queue.revalidatePlaylist();
      queue.refreshQueueEligibility();
      expect(
        queue.playlist.map((item) => item.id),
        isNot(contains(items[1].id)),
      );
      expect(library.getVideo(items[1].id), isNotNull);
      expect(File(items[1].path).existsSync(), isTrue);
      queue.loadFolderPlaylist('folder', items.first.id);
      expect(queue.playlist.map((item) => item.id), contains(items[1].id));
    },
  );

  test('delayed cloud projections and pages cannot reinsert removed media', () {
    final queue = _queue();
    final owner = Object();
    final original = [...queue.playlist];
    queue.setPlaylist(original, owner: owner);
    queue.removeFromQueue(original[1].id);
    queue.setPlaylist(original, owner: owner, currentItemId: original.first.id);
    queue.appendPlaylistItems([original[1]]);
    expect(queue.playlist.map((item) => item.id), ['item-0', 'item-2']);
    for (final item in [...queue.playlist]) {
      queue.removeFromQueue(item.id);
    }
    queue.anchorCurrentItem(original.first);
    expect(queue.playlist, isEmpty);
    expect(queue.isCurrentItemDetached, isTrue);
    queue.setPlaylist(original, owner: Object());
    expect(queue.playlist, hasLength(3));
  });

  for (final panel in [false, true]) {
    for (final spec in [
      (screen: const Size(320, 700), width: 320.0, scale: 1.0),
      (screen: const Size(390, 844), width: 390.0, scale: 1.0),
      (screen: const Size(390, 844), width: 390.0, scale: 2.0),
      (screen: const Size(1440, 900), width: 320.0, scale: 1.0),
      (screen: const Size(1440, 900), width: 560.0, scale: 1.0),
    ]) {
      testWidgets(
        '${panel ? 'panel' : 'sheet'} remove at ${spec.screen.width}/${spec.width} scale ${spec.scale}',
        (tester) async {
          tester.view.physicalSize = spec.screen;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final queue = _queue();
          final playback = _Playback(queue);
          final boundary = GlobalKey();
          await tester.pumpWidget(
            MultiProvider(
              providers: [
                ChangeNotifierProvider<PlaylistManager>.value(value: queue),
                ChangeNotifierProvider<MediaPlaybackService>.value(
                  value: playback,
                ),
              ],
              child: MaterialApp(
                theme: ThemeData.dark().copyWith(
                  visualDensity: VisualDensity.compact,
                  textTheme: ThemeData.dark().textTheme.apply(
                    fontFamily: 'Noto Sans SC',
                  ),
                ),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(spec.scale)),
                  child: child!,
                ),
                home: Scaffold(
                  body: Center(
                    child: RepaintBoundary(
                      key: boundary,
                      child: SizedBox(
                        width: spec.width,
                        height: 560,
                        child: panel
                            ? EpisodePickerPanel(
                                panelWidth: spec.width,
                                panelHeight: 560,
                                isPortrait: spec.screen.width < 600,
                                onClose: () {},
                              )
                            : ListenableBuilder(
                                listenable: queue,
                                builder: (context, _) => PlaylistBottomSheet(
                                  playlist: queue.playbackQueue,
                                  currentItemId: playback.currentItem.id,
                                  itemStatuses: {
                                    'item-0': '播放中',
                                    'item-1': '自动连播已开启',
                                  },
                                  onItemTap: (_) => playback.itemTaps++,
                                  onItemRemove: (item) =>
                                      removePlaybackQueueItem(queue, item),
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final buttons = find.byType(PlaybackQueueRemoveButton);
          expect(buttons, findsNWidgets(3));
          final rects = buttons
              .evaluate()
              .map((element) => tester.getRect(find.byWidget(element.widget)))
              .toList();
          for (final rect in rects) {
            expect(rect.width, closeTo(48, 0.001));
            expect(rect.height, closeTo(48, 0.001));
            expect(
              rect.right,
              lessThanOrEqualTo((spec.screen.width + spec.width) / 2 - 12),
            );
          }
          expect(rects[1].top - rects[0].bottom, greaterThanOrEqualTo(12));
          final titleRect = tester.getRect(find.text(_item(1).title));
          expect(rects[1].left - titleRect.right, greaterThanOrEqualTo(8));
          if (spec.scale == 1 &&
              (spec.screen.width == 390 || spec.width == 560)) {
            await tester.runAsync(() async {
              final image =
                  await (boundary.currentContext!.findRenderObject()!
                          as RenderRepaintBoundary)
                      .toImage(pixelRatio: 1.5);
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = testArtifact(
                'queue-${panel ? 'panel' : 'sheet'}-${spec.width.toInt()}.png',
              );
              await file.writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
          // Tap the edge of the touch area, away from the small visible icon.
          await tester.tapAt(rects[1].topLeft + const Offset(3, 24));
          await tester.pumpAndSettle();
          expect(queue.playlist.map((item) => item.id), ['item-0', 'item-2']);
          expect(playback.itemTaps, 0);
          expect(
            find.byKey(const ValueKey('queue-remove-item-1')),
            findsNothing,
          );
          expect(find.text('播放列表 (2)'), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('queue-remove-item-0')));
          await tester.pumpAndSettle();
          expect(playback.currentItem.id, 'item-0');
          expect(playback.isPlaying, isTrue);
          expect(queue.isCurrentItemDetached, isTrue);
          await tester.tap(find.byKey(const ValueKey('queue-remove-item-2')));
          await tester.pumpAndSettle();
          expect(find.text('播放列表为空'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets(
    'podcast queue has direct remove actions and saves mixed queues',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory.systemTemp.createTempSync('podcast-queue-remove-');
      final store = PodcastStore(sqlite3.openInMemory());
      final client = PodcastClient();
      final controller = PodcastController(
        store: store,
        client: client,
        mediaStore: PodcastMediaStore(
          root: root,
          store: store,
          http: client.http,
        ),
      );
      final feed = client.parser.parse(
        utf8.encode(podcastFixture(second: true)),
        'https://example.com/rss',
      );
      store.mergeFeed(feed, initial: true);
      final queue = _queue();
      final playback = _Playback(queue);
      final runtime = PodcastRuntime.forTesting(
        controller,
        playlist: queue,
        playback: playback,
      );
      PodcastRuntime.debugOverride = runtime;
      addTearDown(() async {
        PodcastRuntime.debugOverride = null;
        await controller.close();
        store.close();
        await root.delete(recursive: true);
      });
      for (final episode in feed.episodes) {
        await runtime.addToQueue(episode);
      }
      final podcastItem = queue.playlist.firstWhere(
        (item) => item.sourceRef?.podcast != null,
      );
      removePlaybackQueueItem(queue, _item(2));
      expect((store.read('queue', 'current')!['entries'] as List).length, 4);
      removePlaybackQueueItem(queue, podcastItem);
      expect(runtime.queueEpisodes(), hasLength(1));
      expect(store.read('queue', 'current')!['custom'], isTrue);
      expect((store.read('queue', 'current')!['entries'] as List).length, 3);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: const Scaffold(body: PodcastOverviewPage()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('队列'));
      await tester.tap(find.text('队列'));
      await tester.pumpAndSettle();
      expect(find.byType(PlaybackQueueRemoveButton), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is ReorderableDragStartListener,
        ),
        findsOneWidget,
      );
      final remove = find.byType(PlaybackQueueRemoveButton);
      expect(tester.getSize(remove), const Size(48, 48));
      await tester.tap(remove);
      await tester.pumpAndSettle();
      expect(find.text('队列是空的'), findsOneWidget);
      expect(queue.playlist.map((item) => item.id), ['item-0', 'item-1']);
      expect((store.read('queue', 'current')!['entries'] as List).length, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
