import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_controller.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_pages.dart';
import 'package:video_player_app/features/podcasts/podcast_runtime.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playback_queue_policy.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/widgets/playback_queue_sort_controls.dart';

import 'podcast_core_test.dart' show podcastFixture;
import 'test_artifacts.dart';

void main() {
  for (final spec in [
    (size: const Size(320, 700), scale: 1.0),
    (size: const Size(768, 1024), scale: 1.0),
    (size: const Size(1440, 900), scale: 1.0),
    (size: const Size(320, 700), scale: 2.0),
  ]) {
    testWidgets('podcast queue drag/menu ${spec.size.width} x${spec.scale}', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = spec.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory.systemTemp.createTempSync('podcast-queue-sort-');
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
      final queue = PlaylistManager(
        queuePolicy: PlaybackQueuePolicy(sourceExists: (_) => true),
      );
      final local = VideoItem(
        id: 'local',
        path: '/local.mp3',
        title: 'Local',
        durationMs: 1000,
        lastUpdated: 0,
        type: MediaType.audio,
      );
      queue.setPlaylist([local]);
      final feed = client.parser.parse(
        utf8.encode(podcastFixture(second: true)),
        'https://example.com/rss',
      );
      store.mergeFeed(feed, initial: true);
      final runtime = PodcastRuntime.forTesting(
        controller,
        playlist: queue,
        playback: MediaPlaybackService.forTesting(),
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
      final original = queue.playbackQueue.map((item) => item.id).toList();
      final boundary = GlobalKey();
      await tester.runAsync(() async {
        await (FontLoader(
          'MiSans',
        )..addFont(rootBundle.load('assets/fonts/MiSans-Regular.otf'))).load();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark().copyWith(
            textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'MiSans'),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(spec.scale)),
            child: child!,
          ),
          home: RepaintBoundary(
            key: boundary,
            child: const Scaffold(body: PodcastOverviewPage()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('队列'));
      await tester.tap(find.text('队列'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(PlaybackQueueDragHandle), findsNWidgets(2));
      expect(find.byIcon(Icons.drag_indicator_rounded), findsNothing);
      expect(find.byType(PlaybackQueueSortControls), findsOneWidget);
      expect(
        find.byKey(const ValueKey('queue-sort-reverse')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('queue-sort-reset')).hitTestable(),
        findsOneWidget,
      );
      final visibleQueueTab = tester.getRect(find.text('队列'));
      final visibleActions = tester.getRect(
        find.byType(PlaybackQueueSortControls),
      );
      expect(visibleQueueTab.right, lessThanOrEqualTo(visibleActions.left));
      void checkNumbers() {
        final episodes = runtime.queueEpisodes();
        for (var i = 0; i < episodes.length; i++) {
          final number = find.descendant(
            of: find.byKey(ValueKey('podcast-queue-drag-${episodes[i].id}')),
            matching: find.byKey(const ValueKey('queue-position')),
          );
          expect(tester.widget<Text>(number).data, '${i + 1}');
        }
      }

      checkNumbers();
      final first = find.byKey(
        ValueKey('podcast-queue-drag-${feed.episodes.first.id}'),
      );
      expect(tester.getSize(first), const Size(48, 48));
      if (spec.size.width == 320 && spec.scale == 1) {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1.5);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await testArtifact(
            'podcast-queue-sort-phone.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      final origin = tester.getCenter(first);
      final end =
          tester.getRect(find.byType(PlaybackQueueListView)).bottomCenter -
          const Offset(0, 16);
      final gesture = await tester.startGesture(origin);
      for (var i = 1; i <= 10; i++) {
        await gesture.moveTo(
          Offset(origin.dx, origin.dy + (end.dy - origin.dy) * i / 10),
        );
        await tester.pump(const Duration(milliseconds: 60));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(queue.playbackQueue.map((item) => item.id), [
        original[0],
        original[2],
        original[1],
      ]);
      checkNumbers();
      expect(
        (store.read('queue', 'current')!['entries'] as List).map(
          (entry) => (entry as Map)['mediaId'],
        ),
        [original[0], original[2], original[1]],
      );
      await tester.tap(find.byKey(const ValueKey('queue-sort-reverse')));
      await tester.pumpAndSettle();
      expect(queue.playbackQueue.map((item) => item.id), original);
      checkNumbers();
      await tester.tap(find.byKey(const ValueKey('queue-sort-reset')));
      await tester.pumpAndSettle();
      expect(queue.hasCustomOrder, isFalse);
      checkNumbers();
      expect(queue.playbackQueue.first, same(local));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
