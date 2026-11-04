import 'package:flutter/gestures.dart';
import 'dart:io';

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
import 'package:video_player_app/widgets/mini_playback_card.dart';
import 'package:video_player_app/widgets/media_library_selection_bottom_bar.dart';
import 'package:video_player_app/features/podcasts/podcast_episode_summary.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('channel summary folds to one line and expands', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            child: PodcastEpisodeSummary(
              collapsedLines: 1,
              text: List.filled(20, '频道介绍内容').join(),
            ),
          ),
        ),
      ),
    );
    final content = find.byWidgetPredicate(
      (w) => w is Text && (w.data?.contains('频道介绍内容') ?? false),
    );
    expect(tester.widget<Text>(content).maxLines, 1);
    await tester.tap(find.text('展开'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(content).maxLines, isNull);
    await tester.tap(find.text('收起'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(content).maxLines, 1);
  });
  for (final viewport in [
    (TargetPlatform.android, const Size(320, 640), 1.7),
    (TargetPlatform.android, const Size(320, 640), 2.0),
    (TargetPlatform.android, const Size(390, 844), 2.0),
    (TargetPlatform.android, const Size(320, 640), 1.0),
    (TargetPlatform.android, const Size(360, 740), 1.0),
    (TargetPlatform.android, const Size(430, 900), 1.0),
    (TargetPlatform.android, const Size(390, 844), 1.0),
    (TargetPlatform.android, const Size(844, 390), 1.0),
    (TargetPlatform.android, const Size(900, 1200), 1.0),
    (TargetPlatform.iOS, const Size(390, 844), 1.0),
    (TargetPlatform.windows, const Size(1440, 900), 1.0),
    (TargetPlatform.macOS, const Size(1280, 800), 1.0),
    (TargetPlatform.linux, const Size(1280, 800), 1.0),
    (TargetPlatform.fuchsia, const Size(768, 1024), 1.0),
  ]) {
    testWidgets(
      '${viewport.$1.name} ${viewport.$2} scale ${viewport.$3}: selection preserves list position and clears mini player',
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
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(viewport.$3)),
                child: child!,
              ),
              home: MediaLibraryShell(
                home: Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              PodcastChannelPage(channelId: channel.id),
                        ),
                      ),
                      child: const Text('打开测试频道'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('打开测试频道'));
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

        final first = find.byKey(
          const ValueKey('podcast-episode-surface-scroll-0'),
        );
        if (viewport.$1 == TargetPlatform.windows) {
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: Offset.zero);
          await mouse.moveTo(tester.getCenter(find.text('滚动测试频道')));
          await tester.pump(const Duration(milliseconds: 650));
          expect(find.text('滚动测试频道'), findsNWidgets(2));
          await mouse.moveTo(Offset.zero);
          await tester.pumpAndSettle();
          await mouse.moveTo(
            tester.getCenter(
              find.byKey(const ValueKey('podcast-episode-title-scroll-0')),
            ),
          );
          await tester.pump(const Duration(milliseconds: 650));
          expect(find.text('单集 0'), findsNWidgets(2));
          await mouse.removePointer();
          await tester.pumpAndSettle();
        }
        await tester.ensureVisible(first);
        await tester.pumpAndSettle();
        // Back requests and Escape each leave selection before leaving this route.
        await tester.longPress(first);
        await tester.pumpAndSettle();
        await Navigator.of(tester.element(first)).maybePop();
        await tester.pumpAndSettle();
        expect(find.byType(PodcastChannelPage), findsOneWidget);
        expect(find.byType(MediaLibrarySelectionBottomBar), findsNothing);
        if (viewport.$1 == TargetPlatform.windows ||
            viewport.$1 == TargetPlatform.android) {
          await tester.longPress(first);
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(find.byType(PodcastChannelPage), findsOneWidget);
          expect(find.byType(MediaLibrarySelectionBottomBar), findsNothing);
        }
        if (viewport.$1 == TargetPlatform.windows) {
          await tester.tap(find.byTooltip('搜索频道节目'));
          await tester.pumpAndSettle();
          await tester.tap(find.byType(TextField));
          await tester.ensureVisible(first);
          await tester.longPress(first);
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(find.byType(MediaLibrarySelectionBottomBar), findsNothing);
          expect(find.byType(PodcastChannelPage), findsOneWidget);
          await tester.tap(find.byTooltip('搜索频道节目'));
          await tester.pumpAndSettle();
          await tester.ensureVisible(first);
          await tester.pumpAndSettle();
        }
        final firstTop = tester.getTopLeft(first).dy;
        final offset = scrollController.offset;
        await tester.longPress(first);
        await tester.pumpAndSettle();
        expect(find.byType(MediaLibrarySelectionBottomBar), findsOneWidget);
        expect(tester.getTopLeft(first).dy, firstTop);
        expect(scrollController.offset, offset);
        final bar = tester.getRect(find.byType(MediaLibrarySelectionBottomBar));
        expect(tester.getBottomRight(player).dy, lessThanOrEqualTo(bar.top));
        expect(tester.state(player), same(playerState));
        await tester.tap(find.text('已听').last);
        await tester.pumpAndSettle();
        expect(runtime.controller.state('scroll-0').played, isTrue);
        expect(find.byType(MediaLibrarySelectionBottomBar), findsNothing);
        await tester.ensureVisible(first);
        await tester.pumpAndSettle();
        await tester.longPress(first);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('全选当前列表'));
        await tester.pumpAndSettle();
        expect(find.text('已选 150 集'), findsOneWidget);
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
          lessThanOrEqualTo(tester.getTopLeft(player).dy),
        );

        await tester.tap(find.byTooltip('退出多选'));
        await tester.pumpAndSettle();
        expect(find.byType(MediaLibrarySelectionBottomBar), findsNothing);
        expectStablePlayer();
        await Navigator.of(tester.element(scroll)).maybePop();
        await tester.pumpAndSettle();
        expect(find.text('打开测试频道'), findsOneWidget);
        expect(find.byType(PodcastChannelPage), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant.only(viewport.$1),
    );
  }
}
