import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_controller.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_models.dart';
import 'package:video_player_app/features/podcasts/podcast_pages.dart';
import 'package:video_player_app/features/podcasts/podcast_runtime.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('preview pages episodes and does not store a trial listen', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'podcast-discover-preview-',
    );
    final store = PodcastStore(sqlite3.openInMemory());
    final client = PodcastClient();
    final controller = PodcastController(
      store: store,
      client: client,
      mediaStore: PodcastMediaStore(
        root: directory,
        store: store,
        http: client.http,
      ),
    );
    final episodes = [
      for (var index = 1; index <= 25; index++)
        PodcastEpisode(
          id: 'ep-$index',
          channelId: 'channel-preview',
          title: '预览节目 ${index.toString().padLeft(2, '0')}',
          description: index == 21
              ? '第二十一集的完整节目简介，滑出来之后才能读到。\n00:01:02 试听节点'
              : '第 $index 集的短介绍',
          media: [
            PodcastMedia(
              url: 'https://example.com/ep-$index.mp3',
              mimeType: 'audio/mpeg',
            ),
          ],
          publishedMs: DateTime(2026, 10, 1).millisecondsSinceEpoch - index,
          durationMs: 60000,
        ),
    ];
    final resolution = PodcastResolution(
      PodcastFeed(
        PodcastChannel(
          id: 'channel-preview',
          feedUrl: 'https://example.com/feed.xml',
          title: '预览频道',
          author: '预览主播',
          nextPage: 'https://example.com/next.xml',
        ),
        episodes,
      ),
    );
    PodcastRuntime.debugOverride = PodcastRuntime.forTesting(controller);
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(home: PodcastDiscoverPage(initialPreview: resolution)),
    );
    await tester.pump();

    expect(find.text('预览节目 01'), findsOneWidget);
    expect(find.text('预览节目 21'), findsNothing);
    expect(store.channels, isEmpty);
    expect(store.episodes(), isEmpty);

    await tester.drag(
      find.byKey(const ValueKey('podcast-discover-episodes')),
      const Offset(0, -4000),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('预览节目 21'), findsOneWidget);

    await tester.ensureVisible(find.text('预览节目 21'));
    await tester.tap(find.text('预览节目 21'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('podcast-discover-episode-notes')),
        matching: find.text('第二十一集的完整节目简介，滑出来之后才能读到。'),
      ),
      findsOneWidget,
    );
    expect(find.text('试听这一集'), findsOneWidget);
    expect(find.text('00:01:02'), findsOneWidget);
    expect(find.text('试听节点'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('podcast-discover-preview-progress')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('podcast-discover-preview-duration')),
          )
          .data,
      '1:00',
    );
    final trialLabel = tester.widget<Text>(find.text('试听这一集'));
    expect(trialLabel.style?.fontWeight, FontWeight.w600);
    expect(trialLabel.style?.fontFamily, 'MiSans');

    await tester.tap(find.text('试听节点'));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('podcast-discover-preview-play')),
    );
    await tester.pump();
    expect(store.channels, isEmpty);
    expect(store.episodes(), isEmpty);

    await tester.pageBack();
    // Trial playback and a failed "older episodes" request both use timers.
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpWidget(const SizedBox());
    PodcastRuntime.debugOverride = null;
    await tester.runAsync(() async {
      await controller.close();
      store.close();
      directory.deleteSync(recursive: true);
    });
  });
}
