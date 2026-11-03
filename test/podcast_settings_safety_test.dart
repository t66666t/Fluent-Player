import 'package:video_player_app/widgets/operation_status.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_controller.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_models.dart';
import 'package:video_player_app/features/podcasts/podcast_runtime.dart';
import 'package:video_player_app/features/podcasts/podcast_settings_page.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'podcast_core_test.dart' show podcastFixture;

void main() {
  testWidgets(
    'channel reset and partial cleanup require an explicit confirmation',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync('podcast-safety-');
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
      final feed = client.parser.parse(
        utf8.encode(podcastFixture()),
        'https://example.com/rss',
      );
      store.mergeFeed(feed, initial: true);
      store.setSetting(feed.channel.id, 'autoRefresh', false);
      final episode = feed.episodes.first;
      store.write(
        'download',
        episode.id,
        PodcastDownload(
          episodeId: episode.id,
          mediaUrl: episode.media.first.url,
          status: PodcastDownloadStatus.paused,
        ).toJson(),
        channel: feed.channel.id,
      );
      PodcastRuntime.debugOverride = PodcastRuntime.forTesting(controller);
      addTearDown(() {
        PodcastRuntime.debugOverride = null;
        controller.dispose();
        store.close();
        directory.deleteSync(recursive: true);
      });
      await tester.pumpWidget(
        MaterialApp(home: PodcastSettingsPage(channelId: feed.channel.id)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('全部恢复继承'));
      await tester.pumpAndSettle();
      expect(find.textContaining('1 项独立设置'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(store.overrides(feed.channel.id), isNotEmpty);
      await tester.tap(find.byTooltip('全部恢复继承'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '恢复继承'));
      await tester.pumpAndSettle();
      expect(store.overrides(feed.channel.id), isEmpty);
      final storage = find.byKey(
        const ValueKey('podcast-setting-group-storage'),
      );
      await tester.ensureVisible(storage);
      await tester.tap(storage);
      await tester.pumpAndSettle();
      final cleanup = find.text('清理未完成下载');
      await tester.ensureVisible(cleanup);
      await tester.tap(cleanup);
      await tester.pumpAndSettle();
      expect(find.textContaining('取消 1 项并删除'), findsOneWidget);
      expect(find.textContaining('下次将从头下载'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(store.read('download', episode.id), isNotNull);
      final beforeCleanup = tester.getTopLeft(cleanup).dy;
      await tester.tap(cleanup);
      await tester.pumpAndSettle();
      // A queued/running task may complete while its cleanup confirmation is open.
      final completed = store.read('download', episode.id)!;
      completed['status'] = PodcastDownloadStatus.completed.name;
      store.write('download', episode.id, completed, channel: feed.channel.id);
      await tester.tap(find.widgetWithText(FilledButton, '放弃并清理'));
      await tester.pumpAndSettle();
      expect(
        store.read('download', episode.id)!['status'],
        PodcastDownloadStatus.completed.name,
      );
      expect(find.byType(OperationStatus), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.getTopLeft(cleanup).dy, closeTo(beforeCleanup, 1));
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
