import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_controller.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_models.dart';
import 'package:video_player_app/features/podcasts/podcast_pages.dart';
import 'package:video_player_app/features/podcasts/podcast_runtime.dart';
import 'package:video_player_app/features/podcasts/podcast_scrollbar.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';
import 'package:video_player_app/widgets/media_library_scroll_viewport.dart';
import 'package:video_player_app/widgets/mini_playback_card.dart';

/// Find the actually painted thumb, so fading or a disconnected scrollbar
/// fails the test even when its widget still exists in the tree.
Offset thumbCenter(WidgetTester tester, Finder scrollbar) {
  final thumb = find.descendant(
    of: scrollbar,
    matching: find.byKey(MediaLibraryScrollViewport.thumbKey),
  );
  expect(thumb.hitTestable(), findsOneWidget);
  final opacity = find.descendant(of: thumb, matching: find.byType(Opacity));
  expect(tester.widget<Opacity>(opacity).opacity, 1);
  final rect = tester.getRect(thumb);
  expect(tester.getSize(thumb).height, inInclusiveRange(56, 88));
  expect(rect.right, lessThan(tester.getRect(scrollbar).center.dx));
  return rect.center;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final viewport in [
    (TargetPlatform.android, const Size(390, 844)),
    (TargetPlatform.android, const Size(844, 390)),
    (TargetPlatform.android, const Size(900, 1200)),
    (TargetPlatform.iOS, const Size(390, 844)),
    (TargetPlatform.windows, const Size(1440, 900)),
    (TargetPlatform.macOS, const Size(1280, 800)),
    (TargetPlatform.linux, const Size(1280, 800)),
    (TargetPlatform.fuchsia, const Size(768, 1024)),
  ]) {
    testWidgets(
      '${viewport.$1.name} ${viewport.$2}: persistent dragging and stable mini player',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final settings = SettingsService()..resetForTest();
        await settings.init();
        final playback = MediaPlaybackService();
        await playback.stop();
        final directory = Directory.systemTemp.createTempSync(
          'podcast-scroll-',
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
        final channel = PodcastChannel(
          id: 'scroll-channel',
          feedUrl: 'https://example.com/feed',
          title: '滚动测试频道',
        );
        store.write('channel', channel.id, channel.toJson());
        store.setSetting(channel.id, 'autoRefresh', false);
        for (var i = 0; i < 150; i++) {
          final episode = PodcastEpisode(
            id: 'scroll-$i',
            channelId: channel.id,
            title: '单集 $i',
            publishedMs: 1000 - i,
            media: [PodcastMedia(url: 'https://example.com/$i.mp3')],
          );
          store.write(
            'episode',
            episode.id,
            episode.toJson(),
            channel: channel.id,
          );
        }
        final runtime = PodcastRuntime.forTesting(controller);
        PodcastRuntime.debugOverride = runtime;
        playback.publishRestoredSessionPreview(
          VideoItem(
            id: 'current',
            path: 'current.mp3',
            title: '正在播放',
            durationMs: 120000,
            lastUpdated: 0,
            type: MediaType.audio,
          ),
          const Duration(seconds: 30),
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('window_manager'),
              (call) async => null,
            );
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = viewport.$2;
        tester.view.padding = const FakeViewPadding(bottom: 32);
        tester.view.viewPadding = const FakeViewPadding(bottom: 32);
        addTearDown(() async {
          tester.view.reset();
          PodcastRuntime.debugOverride = null;
          runtime.dispose();
          await playback.stop();
          settings.resetForTest();
          await controller.close();
          store.close();
          directory.deleteSync(recursive: true);
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('window_manager'),
                null,
              );
        });

        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<MediaPlaybackService>.value(
                value: playback,
              ),
              ChangeNotifierProvider<SettingsService>.value(value: settings),
            ],
            child: MaterialApp(
              theme: ThemeData.dark(),
              home: MediaLibraryShell(
                home: PodcastChannelPage(channelId: channel.id),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final scroll = find.byType(CustomScrollView);
        final scrollbar = find.byKey(
          const ValueKey('podcast-channel-episodes-scrollbar'),
        );
        final scrollController = tester
            .widget<PodcastScrollbar>(scrollbar)
            .controller;
        final player = find.byType(MiniPlaybackCard);
        final playerState = tester.state(player);
        final playerRect = tester.getRect(player);
        void expectStablePlayer() {
          expect(playback.shouldShowMiniPlaybackCard, isTrue);
          expect(tester.state(player), same(playerState));
          expect(tester.getRect(player), playerRect);
          expect(
            tester.getBottomRight(scroll).dy,
            lessThanOrEqualTo(playerRect.top),
          );
          expect(find.byTooltip('播放列表').hitTestable(), findsOneWidget);
          expect(
            mediaLibraryRouteIsCurrent(tester.element(scroll)),
            isTrue,
            reason: 'Scrolling must not accidentally open a playback page',
          );
          expect(tester.takeException(), isNull);
        }

        // The thumb is visible before the first scroll and after a long idle.
        await tester.pump(const Duration(seconds: 3));
        var thumb = thumbCenter(tester, scrollbar);
        final scrollRect = tester.getRect(scroll);
        // Touch slightly beside the visual thumb: the padded target must
        // work without a preceding long press, on Android and iOS as well.
        final touch = await tester.startGesture(thumb + const Offset(3, 0));
        await touch.moveBy(const Offset(0, 2));
        await tester.pump();
        await touch.moveBy(Offset(0, scrollRect.height * .25));
        await tester.pump();
        await touch.up();
        await tester.pumpAndSettle();
        expect(scrollController.offset, greaterThan(scrollRect.height));
        expectStablePlayer();

        await tester.pump(const Duration(seconds: 3));
        thumb = thumbCenter(tester, scrollbar);
        final beforeMouse = scrollController.offset;
        final mouse = await tester.startGesture(
          thumb,
          kind: PointerDeviceKind.mouse,
        );
        await mouse.moveBy(Offset(0, -scrollRect.height * .15));
        await tester.pump();
        await mouse.up();
        await tester.pumpAndSettle();
        expect(scrollController.offset, lessThan(beforeMouse));
        expectStablePlayer();

        // A brief flick that stays inside InkWell's tap tolerance must not
        // navigate away and cover the mini player when the pointer is released.
        final shortSwipe = await tester.startGesture(scrollRect.center);
        await shortSwipe.moveBy(const Offset(0, -14));
        await tester.pump(const Duration(milliseconds: 10));
        await shortSwipe.up();
        await tester.pumpAndSettle();
        expectStablePlayer();

        // Repeated fast flicks start near the bottom edge of the episode area.
        for (var i = 0; i < 3; i++) {
          await tester.flingFrom(
            Offset(scrollRect.center.dx, scrollRect.bottom - 16),
            Offset(0, -scrollRect.height * .7),
            5000,
          );
          for (var frame = 0; frame < 6; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            expectStablePlayer();
          }
          await tester.pumpAndSettle();
          expectStablePlayer();
        }

        // At the end, the last episode clears the player as well as the viewport.
        for (var i = 0; i < 4; i++) {
          scrollController.jumpTo(scrollController.position.maxScrollExtent);
          await tester.pump();
        }
        expect(
          tester
              .getBottomRight(
                find.byKey(
                  const ValueKey('podcast-episode-surface-scroll-149'),
                ),
              )
              .dy,
          lessThanOrEqualTo(playerRect.top),
        );
        thumbCenter(tester, scrollbar);
        expectStablePlayer();
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant.only(viewport.$1),
    );
  }
}
