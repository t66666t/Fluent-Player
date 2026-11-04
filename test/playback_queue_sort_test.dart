import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/playback_mode.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playback_queue_actions.dart';
import 'package:video_player_app/services/playback_queue_policy.dart';
import 'package:video_player_app/services/playback_state_store.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/widgets/episode_picker_panel.dart';
import 'package:video_player_app/widgets/playback_queue_sort_controls.dart';
import 'package:video_player_app/widgets/playlist_bottom_sheet.dart';

import 'test_artifacts.dart';

class _Store extends PlaybackStateStore {
  Map<String, dynamic>? value;
  Completer<Map<String, dynamic>?>? gate;
  @override
  Future<Map<String, dynamic>?> read() async =>
      gate == null ? value : gate!.future;
  @override
  Future<void> write(Map<String, dynamic> snapshot) async {
    value = snapshot;
  }
}

VideoItem _item(int i, {String? id, MediaSourceRef? source}) => VideoItem(
  id: id ?? 'item-$i',
  path: '/$i.mp3',
  title: '节目 $i · 这里是一段较长的媒体标题',
  durationMs: 125000,
  lastUpdated: 0,
  type: MediaType.audio,
  sourceRef: source,
);

PlaylistManager _queue({int count = 3, int start = 0, _Store? store}) =>
    PlaylistManager(
      queuePolicy: PlaybackQueuePolicy(sourceExists: (_) => true),
      modeStore: store ?? _Store(),
    )..setPlaylist(List.generate(count, _item), startIndex: start);

List<String> _ids(PlaylistManager queue) =>
    queue.playbackQueue.map((item) => item.id).toList();

void _expectQueueNumbers(WidgetTester tester, PlaylistManager queue) {
  final ids = _ids(queue);
  for (var index = 0; index < ids.length; index++) {
    final row = find.byKey(ValueKey('queue-drag-${ids[index]}'));
    if (row.evaluate().isEmpty) continue; // Unmounted rows are virtualized.
    final number = find.descendant(
      of: row,
      matching: find.byKey(const ValueKey('queue-position')),
    );
    expect(
      tester.widget<Text>(number).data,
      '${index + 1}',
      reason: 'position of ${ids[index]}',
    );
  }
}

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
  PlaybackMode get playbackMode => queue.playbackMode;
  @override
  VideoItem? get nextPlayableItem => queue.getNext();
  @override
  VideoItem? get previousPlayableItem => queue.getPrevious();
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

Widget _host(
  PlaylistManager queue,
  _Playback playback, {
  required bool panel,
  required double width,
  double scale = 1,
  bool portrait = false,
  GlobalKey? boundary,
  ScrollController? scrollController,
}) => MultiProvider(
  providers: [
    ChangeNotifierProvider<PlaylistManager>.value(value: queue),
    ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
  ],
  child: MaterialApp(
    theme: ThemeData.dark().copyWith(
      textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'MiSans'),
    ),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(
      body: Center(
        child: RepaintBoundary(
          key: boundary,
          child: SizedBox(
            width: width,
            height: 560,
            child: panel
                ? EpisodePickerPanel(
                    panelWidth: width,
                    panelHeight: 560,
                    isPortrait: portrait,
                    onClose: () {},
                  )
                : ListenableBuilder(
                    listenable: queue,
                    builder: (context, _) => PlaylistBottomSheet(
                      playlist: queue.playbackQueue,
                      currentItemId: playback.currentItem.id,
                      scrollController: scrollController,
                      itemStatuses: {
                        for (final item in queue.playbackQueue)
                          if (playback.queueItemStatus(item.id) != null)
                            item.id: playback.queueItemStatus(item.id)!,
                      },
                      onItemTap: (_) => playback.itemTaps++,
                      onItemRemove: (item) =>
                          removePlaybackQueueItem(queue, item),
                      onOrderChanged: (ids) => reorderPlaybackQueue(queue, ids),
                      onReverse: () => reversePlaybackQueue(queue),
                      onResetOrder: () => resetPlaybackQueueOrder(queue),
                      hasCustomOrder: queue.hasCustomOrder,
                      isShuffle: queue.playbackMode == PlaybackMode.shuffle,
                    ),
                  ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  setUpAll(() async {
    await (FontLoader(
      'MiSans',
    )..addFont(rootBundle.load('assets/fonts/MiSans-Regular.otf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  test(
    'reorder, reverse and reset keep the anchor and change actual navigation',
    () {
      final queue = _queue(count: 4, start: 1);
      expect(
        queue.reorderQueue(['item-3', 'item-1', 'item-0', 'item-2']),
        isTrue,
      );
      expect(queue.currentItem?.id, 'item-1');
      expect(queue.currentIndex, 1);
      expect(queue.getPrevious()?.id, 'item-3');
      expect(queue.getNext()?.id, 'item-0');
      expect(queue.reverseQueue(), isTrue);
      expect(_ids(queue), ['item-2', 'item-0', 'item-1', 'item-3']);
      expect(queue.currentItem?.id, 'item-1');
      expect(queue.resetQueueOrder(), isTrue);
      expect(_ids(queue), ['item-0', 'item-1', 'item-2', 'item-3']);
      expect(queue.hasCustomOrder, isFalse);
      queue.removeFromQueue('item-1');
      queue.reverseQueue();
      expect(queue.anchoredItemId, 'item-1');
      expect(queue.isCurrentItemDetached, isTrue);
    },
  );

  test('random mode yields to a deliberate order; repeat-one is preserved', () {
    final queue = _queue(count: 6);
    queue.setPlaybackMode(PlaybackMode.shuffle);
    final desired = _ids(queue).reversed.toList();
    queue.reorderQueue(desired);
    expect(_ids(queue), desired);
    expect(queue.playbackMode, PlaybackMode.sequential);
    expect(queue.currentItem?.id, 'item-0');
    queue.setPlaybackMode(PlaybackMode.repeatOne);
    queue.reverseQueue();
    expect(queue.playbackMode, PlaybackMode.repeatOne);
  });

  test('stale or duplicate drag snapshots are ignored without publishing', () {
    final queue = _queue();
    final revision = queue.revision;
    for (final invalid in [
      ['item-0', 'item-0', 'item-2'],
      ['item-1', 'item-0'],
      ['item-1', 'item-0', 'gone'],
    ]) {
      expect(queue.reorderQueue(invalid), isFalse);
    }
    expect(queue.revision, revision);
    expect(queue.hasCustomOrder, isFalse);
    queue.removeFromQueue('item-2');
    expect(queue.reorderQueue(['item-2', 'item-0', 'item-1']), isFalse);
  });

  test('custom order survives owned source refresh and new media append', () {
    final queue = _queue();
    final source = [...queue.playlist];
    final owner = Object();
    queue.setPlaylist(source, owner: owner);
    queue.reverseQueue();
    queue.setPlaylist(
      [...source, _item(3)],
      currentItemId: 'item-0',
      owner: owner,
    );
    queue.appendPlaylistItems([_item(4)]);
    queue.revalidatePlaylist();
    final revision = queue.revision;
    queue.refreshQueueEligibility();
    expect(
      queue.revision,
      revision,
      reason: 'eligibility refresh must not loop on custom order',
    );
    expect(_ids(queue), ['item-2', 'item-1', 'item-0', 'item-3', 'item-4']);
    queue.removeFromQueue('item-1');
    queue.resetQueueOrder();
    expect(_ids(queue), ['item-0', 'item-2', 'item-3', 'item-4']);
  });

  test('custom order persists even with the default sequential mode', () async {
    final store = _Store();
    final queue = _queue(store: store);
    await queue.initializePlaybackModes();
    queue.reverseQueue();
    await queue.flushPlaybackModes();
    final restored = _queue(store: store);
    await restored.initializePlaybackModes();
    expect(_ids(restored), ['item-2', 'item-1', 'item-0']);
    expect(restored.hasCustomOrder, isTrue);
    restored.resetQueueOrder();
    expect(_ids(restored), ['item-0', 'item-1', 'item-2']);
  });

  test(
    'a delayed restore cannot override a drag performed while loading',
    () async {
      final previousStore = _Store();
      final previous = _queue(store: previousStore);
      await previous.initializePlaybackModes();
      previous.reverseQueue();
      await previous.flushPlaybackModes();
      final store = _Store()..gate = Completer();
      final queue = _queue(store: store);
      final loading = queue.initializePlaybackModes();
      queue.reorderQueue(['item-1', 'item-0', 'item-2']);
      store.gate!.complete(previousStore.value);
      await loading;
      expect(_ids(queue), ['item-1', 'item-0', 'item-2']);
    },
  );

  test('sorting a folder survives reload without changing library order', () {
    final library = LibraryService()..resetLibraryForTesting();
    addTearDown(library.resetLibraryForTesting);
    final source = List.generate(3, _item);
    for (final item in source) {
      item.parentId = 'folder';
      library.seedVideoForTesting(item);
    }
    library.seedCollectionForTesting(
      VideoCollection(
        id: 'folder',
        name: 'Folder',
        createTime: 0,
        childrenIds: source.map((item) => item.id).toList(),
      ),
    );
    final queue = PlaylistManager(
      queuePolicy: PlaybackQueuePolicy(sourceExists: (_) => true),
      modeStore: _Store(),
    )..initialize(libraryService: library);
    queue.loadFolderPlaylist('folder', source.first.id);
    queue.reverseQueue();
    queue.reloadPlaylist();
    expect(_ids(queue), ['item-2', 'item-1', 'item-0']);
    expect(library.getVideosInFolder('folder'), source);
    queue.resetQueueOrder();
    expect(_ids(queue), ['item-0', 'item-1', 'item-2']);
  });

  test('rebuilt Bilibili placeholders retain their custom position', () {
    const source = MediaSourceRef(
      value: 'bilibili://BVtest/1',
      kind: MediaSourceKind.bilibiliStream,
      bvid: 'BVtest',
      cid: 1,
      page: 1,
    );
    final queue = _queue();
    final owner = Object();
    queue.setPlaylist([
      _item(0),
      _item(1, id: 'old', source: source),
      _item(2),
    ], owner: owner);
    queue.reorderQueue(['item-2', 'old', 'item-0']);
    queue.setPlaylist(
      [_item(0), _item(1, id: 'rebuilt', source: source), _item(2)],
      currentItemId: 'item-0',
      owner: owner,
    );
    expect(_ids(queue), ['item-2', 'rebuilt', 'item-0']);
  });

  for (final panel in [false, true]) {
    for (final spec in [
      (screen: const Size(320, 700), width: 320.0, scale: 1.0),
      (screen: const Size(390, 844), width: 390.0, scale: 1.0),
      (screen: const Size(768, 1024), width: 560.0, scale: 1.0),
      (screen: const Size(1440, 900), width: 320.0, scale: 1.0),
      (screen: const Size(1440, 900), width: 560.0, scale: 1.0),
      (screen: const Size(320, 700), width: 320.0, scale: 2.0),
    ]) {
      testWidgets(
        '${panel ? 'panel' : 'sheet'} drag/reverse/reset ${spec.screen.width}/${spec.width} x${spec.scale}',
        (tester) async {
          tester.view.physicalSize = spec.screen;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final queue = _queue();
          final playback = _Playback(queue);
          final boundary = GlobalKey();
          await tester.pumpWidget(
            _host(
              queue,
              playback,
              panel: panel,
              width: spec.width,
              scale: spec.scale,
              portrait: spec.screen.width < 600,
              boundary: boundary,
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          _expectQueueNumbers(tester, queue);
          expect(find.byIcon(Icons.drag_indicator_rounded), findsNothing);
          expect(
            find.byKey(const ValueKey('queue-sort-reverse')).hitTestable(),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('queue-sort-reset')).hitTestable(),
            findsOneWidget,
          );
          expect(
            find.byWidgetPredicate((widget) => widget is PopupMenuButton),
            findsNothing,
          );
          final orderRect = tester.getRect(
            find.byType(PlaybackQueueSortControls),
          );
          final headingRect = tester.getRect(find.text('播放列表 (3)'));
          expect(orderRect.left - headingRect.right, greaterThanOrEqualTo(7.9));
          expect(orderRect.center.dy, closeTo(headingRect.center.dy, 0.01));
          for (final grip in find.byType(PlaybackQueueDragHandle).evaluate()) {
            expect(
              tester.getSize(find.byWidget(grip.widget)),
              const Size(48, 48),
            );
          }
          final title = tester.getRect(find.text(_item(1).title));
          final remove = tester.getRect(
            find.byKey(const ValueKey('queue-remove-item-1')),
          );
          expect(remove.left - title.right, greaterThanOrEqualTo(8));
          expect(remove.width, 48);
          if (spec.scale == 1 &&
              (spec.screen.width == 390 ||
                  spec.screen.width == 768 ||
                  spec.screen.width == 1440 && spec.width == 320)) {
            await tester.runAsync(() async {
              final image =
                  await (boundary.currentContext!.findRenderObject()!
                          as RenderRepaintBoundary)
                      .toImage(pixelRatio: 1.5);
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await testArtifact(
                'queue-sort-${panel ? 'panel' : 'sheet'}-${spec.screen.width.toInt()}.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
          final first = find.byKey(const ValueKey('queue-drag-item-0'));
          await tester.tap(first);
          expect(playback.itemTaps, 0);
          final origin = tester.getCenter(first);
          final listRect = tester.getRect(find.byType(PlaybackQueueListView));
          final target = Offset(origin.dx, listRect.bottom - 8);
          final gesture = await tester.startGesture(
            origin,
            kind: spec.screen.width >= 1000
                ? ui.PointerDeviceKind.mouse
                : ui.PointerDeviceKind.touch,
          );
          await gesture.moveBy(const Offset(0, 12));
          await tester.pump(const Duration(milliseconds: 50));
          for (var i = 1; i <= 10; i++) {
            await gesture.moveTo(
              Offset.lerp(origin + const Offset(0, 12), target, i / 10)!,
            );
            await tester.pump(const Duration(milliseconds: 60));
          }
          await gesture.moveBy(const Offset(0, 1));
          await tester.pump(const Duration(milliseconds: 200));
          await gesture.up();
          await tester.pumpAndSettle();
          expect(_ids(queue), ['item-1', 'item-2', 'item-0']);
          _expectQueueNumbers(tester, queue);
          expect(playback.currentItem.id, 'item-0');
          expect(playback.itemTaps, 0);
          await tester.tap(find.byKey(const ValueKey('queue-sort-reverse')));
          await tester.pumpAndSettle();
          expect(_ids(queue), ['item-0', 'item-2', 'item-1']);
          _expectQueueNumbers(tester, queue);
          await tester.tap(find.byKey(const ValueKey('queue-sort-reset')));
          await tester.pumpAndSettle();
          expect(_ids(queue), ['item-0', 'item-1', 'item-2']);
          _expectQueueNumbers(tester, queue);
          removePlaybackQueueItem(queue, queue.playbackQueue[1]);
          await tester.pumpAndSettle();
          _expectQueueNumbers(tester, queue);
          queue.addToPlaybackQueue([_item(3)]);
          await tester.pumpAndSettle();
          _expectQueueNumbers(tester, queue);
          expect(
            find.byKey(const ValueKey('queue-undo-addition')).hitTestable(),
            findsOneWidget,
          );
          await tester.tap(find.byKey(const ValueKey('queue-undo-addition')));
          await tester.pumpAndSettle();
          expect(_ids(queue), ['item-0', 'item-2']);
          _expectQueueNumbers(tester, queue);
          expect(playback.currentItem.id, 'item-0');
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets('focused grips support keyboard order changes without playback', (
    tester,
  ) async {
    final queue = _queue();
    final playback = _Playback(queue);
    await tester.pumpWidget(_host(queue, playback, panel: true, width: 560));
    await tester.pumpAndSettle();
    final handle = find.byKey(const ValueKey('queue-drag-item-0'));
    final number = find.descendant(
      of: handle,
      matching: find.byKey(const ValueKey('queue-position')),
    );
    Focus.of(tester.element(number)).requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();
    expect(_ids(queue), ['item-1', 'item-0', 'item-2']);
    _expectQueueNumbers(tester, queue);
    expect(playback.itemTaps, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'read-only rows use visible positions, including the playing row',
    (tester) async {
      final items = [_item(2), _item(0), _item(1)];
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: SizedBox(
              width: 390,
              height: 560,
              child: PlaylistBottomSheet(
                playlist: items,
                currentItemId: 'item-0',
                onItemTap: (_) {},
                originalPositions: const {
                  'item-2': 98,
                  'item-0': 41,
                  'item-1': 17,
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (var i = 0; i < items.length; i++) {
        final number = find.descendant(
          of: find.byKey(ValueKey(items[i].id)),
          matching: find.byKey(const ValueKey('queue-position')),
        );
        expect(tester.widget<Text>(number).data, '${i + 1}');
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('dragging near a long queue edge scrolls to offscreen entries', (
    tester,
  ) async {
    final queue = _queue(count: 50);
    final playback = _Playback(queue);
    final scroll = ScrollController();
    await tester.pumpWidget(
      _host(
        queue,
        playback,
        panel: false,
        width: 390,
        scrollController: scroll,
      ),
    );
    await tester.pumpAndSettle();
    final origin = tester.getCenter(
      find.byKey(const ValueKey('queue-drag-item-0')),
    );
    final rect = tester.getRect(find.byType(PlaybackQueueListView));
    final gesture = await tester.startGesture(origin);
    await gesture.moveBy(const Offset(0, 12));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveTo(Offset(origin.dx, rect.bottom - 8));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(scroll.offset, greaterThan(100));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_ids(queue).indexOf('item-0'), greaterThan(2));
    _expectQueueNumbers(tester, queue);
    scroll.jumpTo(scroll.position.maxScrollExtent / 2);
    await tester.pumpAndSettle();
    _expectQueueNumbers(tester, queue);
    expect(playback.itemTaps, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    scroll.dispose();
  });

  testWidgets(
    'the draggable mini-player sheet shares its scroll controller during reordering',
    (tester) async {
      final queue = _queue(count: 20);
      var itemTaps = 0;
      ScrollController? sheetScroll;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: DraggableScrollableSheet(
                initialChildSize: 0.8,
                minChildSize: 0.3,
                maxChildSize: 0.95,
                expand: false,
                builder: (context, controller) {
                  sheetScroll = controller;
                  return ListenableBuilder(
                    listenable: queue,
                    builder: (context, _) => PlaylistBottomSheet(
                      playlist: queue.playbackQueue,
                      currentItemId: 'item-0',
                      scrollController: controller,
                      onItemTap: (_) => itemTaps++,
                      onOrderChanged: (ids) => queue.reorderQueue(ids),
                      onReverse: queue.reverseQueue,
                      onResetOrder: queue.resetQueueOrder,
                      hasCustomOrder: queue.hasCustomOrder,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final origin = tester.getCenter(
        find.byKey(const ValueKey('queue-drag-item-0')),
      );
      final bottom =
          tester.getRect(find.byType(PlaybackQueueListView)).bottom - 8;
      final gesture = await tester.startGesture(origin);
      for (var i = 1; i <= 8; i++) {
        await gesture.moveTo(
          Offset(origin.dx, origin.dy + (bottom - origin.dy) * i / 8),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(sheetScroll!.offset, greaterThan(0));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(_ids(queue).indexOf('item-0'), greaterThan(2));
      expect(itemTaps, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
