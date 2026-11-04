import 'dart:async';
import 'dart:convert';
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
import 'package:video_player_app/features/podcasts/podcast_settings_page.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/features/podcasts/podcast_widgets.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';
import 'package:video_player_app/widgets/mini_playback_card.dart';

import 'podcast_core_test.dart' show podcastFixture;

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), (
          call,
        ) async {
          if (call.method == 'getBounds') {
            return {'x': 0.0, 'y': 0.0, 'width': 1280.0, 'height': 800.0};
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  });
  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(768, 1024),
    const Size(1280, 800),
  ]) {
    testWidgets('podcast routes clear player and Android navigation at $size', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService()..resetForTest();
      await settings.init();
      settings.isFullScreen = false;
      Future<void> checkFullscreenShortcut() async {
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.pump();
        expect(settings.isFullScreen, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.pump();
        expect(settings.isFullScreen, isFalse);
      }

      final playback = MediaPlaybackService();
      await playback.stop();
      final directory = Directory.systemTemp.createTempSync('podcast-insets-');
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
      feed.channel.imageUrl = '';
      final template = feed.episodes.single.toJson();
      feed.episodes
        ..clear()
        ..addAll([
          for (var i = 0; i < 20; i++)
            PodcastEpisode.fromJson({
              ...template,
              'id': 'insets-$i',
              'title': 'Episode $i',
              'publishedMs': 1000 - i,
              'imageUrl': '',
            }),
        ]);
      store.mergeFeed(feed, initial: true);
      store.setSetting(feed.channel.id, 'autoRefresh', false);
      PodcastRuntime.debugOverride = PodcastRuntime.forTesting(controller);
      playback.publishRestoredSessionPreview(
        VideoItem(
          id: 'clip',
          path: 'clip.mp4',
          title: 'clip',
          durationMs: 120000,
          lastUpdated: 0,
        ),
        Duration.zero,
      );
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      tester.view.padding = const FakeViewPadding(bottom: 32);
      tester.view.viewPadding = const FakeViewPadding(bottom: 32);
      tester.view.systemGestureInsets = const FakeViewPadding(bottom: 24);
      addTearDown(() async {
        tester.view.reset();
        PodcastRuntime.debugOverride = null;
        await playback.stop();
        settings.resetForTest();
        await controller.close();
        store.close();
        directory.deleteSync(recursive: true);
      });

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
            ChangeNotifierProvider<SettingsService>.value(value: settings),
          ],
          child: MaterialApp(
            theme: ThemeData.dark(),
            home: MediaLibraryShell(
              home: PodcastChannelPage(channelId: feed.channel.id),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final rootNavigator = Navigator.of(
        tester.element(find.byType(PodcastChannelPage)),
        rootNavigator: true,
      );
      Finder currentMenu() => find.byWidgetPredicate(
        (widget) =>
            widget.key == const ValueKey('podcast-compact-menu') ||
            widget.key == const ValueKey('capsule-choice-menu') ||
            widget is BottomSheet,
      );
      Future<void> checkMenuCoversPlayer(
        Finder trigger,
        String lastOptionLabel,
      ) async {
        await tester.ensureVisible(trigger);
        await tester.pumpAndSettle();
        await tester.tap(trigger);
        await tester.pumpAndSettle();
        final option = find.descendant(
          of: currentMenu(),
          matching: find.text(lastOptionLabel),
        );
        expect(
          ModalRoute.of(tester.element(option))!.navigator,
          same(rootNavigator),
        );
        await tester.ensureVisible(option);
        await tester.pumpAndSettle();
        expect(option.hitTestable(), findsOneWidget);
        await tester.tapAt(const Offset(4, 4));
        await tester.pumpAndSettle();
        expect(currentMenu(), findsNothing);
        expect(rootNavigator.canPop(), isFalse);
      }

      await checkMenuCoversPlayer(find.byTooltip('更多频道操作'), '取消订阅');
      await checkMenuCoversPlayer(find.byTooltip('节目排序'), '最早优先');
      final scroll = find.byType(CustomScrollView);
      await checkFullscreenShortcut();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.pump();
      expect(find.byTooltip('退出多选'), findsOneWidget);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(find.text('已选 20 集'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byTooltip('退出多选'), findsNothing);
      final state = tester.state<ScrollableState>(
        find
            .descendant(
              of: scroll,
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Scrollable &&
                    widget.axisDirection == AxisDirection.down,
              ),
            )
            .first,
      );
      state.position.jumpTo(state.position.maxScrollExtent);
      await tester.pump();
      final playerTop = tester.getTopLeft(find.byType(MiniPlaybackCard)).dy;
      expect(tester.getBottomRight(scroll).dy, lessThanOrEqualTo(playerTop));
      expect(
        tester
            .getBottomRight(
              find.byKey(const ValueKey('podcast-episode-surface-insets-19')),
            )
            .dy,
        lessThanOrEqualTo(playerTop),
      );
      await checkMenuCoversPlayer(find.byTooltip('节目操作').last, '始终保留文件');

      unawaited(settings.updateSetting('showMiniPlaybackCard', false));
      await tester.pumpAndSettle();
      expect(tester.getBottomRight(scroll).dy, size.height - 32);
      expect(tester.getSize(find.byType(MiniPlaybackCard)).height, 0);

      // Some Android devices expose the gesture exclusion before view padding.
      tester.view.padding = FakeViewPadding.zero;
      tester.view.viewPadding = FakeViewPadding.zero;
      await tester.pumpAndSettle();
      expect(tester.getBottomRight(scroll).dy, size.height - 32);

      unawaited(settings.updateSetting('showMiniPlaybackCard', true));
      await tester.pumpAndSettle();
      expect(
        tester.getBottomRight(scroll).dy,
        lessThanOrEqualTo(tester.getTopLeft(find.byType(MiniPlaybackCard)).dy),
      );

      // A root route covers the mini player; only system navigation remains.
      tester.view.padding = const FakeViewPadding(bottom: 32);
      tester.view.viewPadding = const FakeViewPadding(bottom: 32);
      unawaited(
        pushAboveMediaLibrary<void>(
          tester.element(find.byType(PodcastChannelPage)),
          MaterialPageRoute<void>(
            builder: (_) => PodcastChannelPage(channelId: feed.channel.id),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.getBottomRight(scroll).dy, size.height - 32);

      Navigator.of(
        tester.element(find.byType(PodcastChannelPage)),
        rootNavigator: true,
      ).pop();
      await tester.pumpAndSettle();
      final libraryNavigator = Navigator.of(
        tester.element(find.byType(PodcastChannelPage)),
      );
      unawaited(
        libraryNavigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) =>
                PodcastDiscoverPage(initialPreview: PodcastResolution(feed)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final previewList = find.byKey(
        const ValueKey('podcast-discover-episodes'),
      );
      await checkFullscreenShortcut();
      expect(
        tester.getBottomRight(previewList).dy,
        lessThanOrEqualTo(tester.getTopLeft(find.byType(MiniPlaybackCard)).dy),
      );
      final firstPreviewEpisode = find.byKey(
        const ValueKey('podcast-discover-episode-insets-0'),
      );
      await tester.scrollUntilVisible(
        firstPreviewEpisode,
        100,
        scrollable: find.descendant(
          of: previewList,
          matching: find.byType(Scrollable),
        ),
      );
      await tester.ensureVisible(firstPreviewEpisode);
      await tester.pumpAndSettle();
      // Short landscape viewports can show only part of an episode row.
      await tester.tapAt(
        tester
            .getRect(firstPreviewEpisode)
            .intersect(tester.getRect(previewList))
            .center,
      );
      await tester.pumpAndSettle();
      final trialButton = find.byKey(
        const ValueKey('podcast-discover-preview-play'),
      );
      final notes = find.byKey(
        const ValueKey('podcast-discover-episode-notes'),
      );
      final visibleButtonBottom = tester.getBottomRight(trialButton).dy;
      await checkFullscreenShortcut();
      expect(
        visibleButtonBottom,
        lessThanOrEqualTo(tester.getTopLeft(find.byType(MiniPlaybackCard)).dy),
      );
      expect(trialButton.hitTestable(), findsOneWidget);
      expect(
        tester.getBottomRight(notes).dy,
        lessThanOrEqualTo(tester.getTopLeft(trialButton).dy),
      );

      unawaited(settings.updateSetting('showMiniPlaybackCard', false));
      await tester.pumpAndSettle();
      expect(
        tester.getBottomRight(trialButton).dy,
        greaterThan(visibleButtonBottom),
      );
      expect(
        tester.getBottomRight(trialButton).dy,
        lessThanOrEqualTo(size.height - 32),
      );
      expect(trialButton.hitTestable(), findsOneWidget);
      unawaited(settings.updateSetting('showMiniPlaybackCard', true));
      await tester.pumpAndSettle();
      expect(tester.getBottomRight(trialButton).dy, visibleButtonBottom);
      expect(trialButton.hitTestable(), findsOneWidget);

      libraryNavigator.pop();
      await tester.pumpAndSettle();
      libraryNavigator.pop();
      await tester.pumpAndSettle();
      for (final channelId in [null, feed.channel.id]) {
        unawaited(
          libraryNavigator.push<void>(
            MaterialPageRoute<void>(
              builder: (_) => PodcastSettingsPage(channelId: channelId),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final settingsList = find.byType(ListView);
        expect(
          tester.getBottomRight(settingsList).dy,
          lessThanOrEqualTo(
            tester.getTopLeft(find.byType(MiniPlaybackCard)).dy,
          ),
        );
        await checkFullscreenShortcut();

        // Settings menus must cover the shell, including its mini player.
        final interval = find.byTooltip('检查间隔');
        await tester.scrollUntilVisible(
          interval,
          160,
          scrollable: find.descendant(
            of: settingsList,
            matching: find.byType(Scrollable),
          ),
        );
        await tester.ensureVisible(interval);
        await tester.pumpAndSettle();
        await tester.tap(interval);
        await tester.pumpAndSettle();
        final lastOption = find.descendant(
          of: currentMenu(),
          matching: find.text('每天'),
        );
        final menuRoute = ModalRoute.of(tester.element(lastOption));
        expect(menuRoute!.navigator, same(rootNavigator));
        await tester.ensureVisible(lastOption);
        await tester.pumpAndSettle();
        expect(lastOption.hitTestable(), findsOneWidget);
        await tester.tap(lastOption);
        await tester.pumpAndSettle();
        expect(store.effective(channelId).number('refreshMinutes'), 1440);
        if (channelId != null) {
          expect(store.overrides(channelId)['refreshMinutes'], 1440);
        }
        expect(find.byType(PodcastSettingsPage), findsOneWidget);
        expect(rootNavigator.canPop(), isFalse);

        libraryNavigator.pop();
        await tester.pumpAndSettle();
      }
      unawaited(
        libraryNavigator.push<void>(
          MaterialPageRoute<void>(builder: (_) => const PodcastDiscoverPage()),
        ),
      );
      await tester.pumpAndSettle();
      await checkFullscreenShortcut();
      expect(
        tester.getBottomRight(find.byType(PodcastGate)).dy,
        lessThanOrEqualTo(tester.getTopLeft(find.byType(MiniPlaybackCard)).dy),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      expect(settings.isFullScreen, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await tester.pumpAndSettle();
      final importField = tester.widget<TextField>(find.byType(TextField));
      expect(importField.decoration!.hintText, contains('RSS'));
      expect(importField.focusNode!.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      // Landscape keyboards leave enough room for the page's navigation.
      final keyboardInset = size.height < 500 ? 200.0 : 320.0;
      tester.view.viewInsets = FakeViewPadding(bottom: keyboardInset);
      tester.view.padding = FakeViewPadding.zero;
      await tester.pumpAndSettle();
      expect(
        tester.getBottomRight(find.byType(PodcastGate)).dy,
        size.height - keyboardInset,
      );
      tester.view.viewInsets = FakeViewPadding.zero;
      tester.view.padding = const FakeViewPadding(bottom: 32);
      libraryNavigator.pop();
      await tester.pumpAndSettle();
      unawaited(
        libraryNavigator.push<void>(
          MaterialPageRoute<void>(builder: (_) => const PodcastOverviewPage()),
        ),
      );
      await tester.pumpAndSettle();
      await checkFullscreenShortcut();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pumpAndSettle();
      expect(find.byType(PodcastDiscoverPage), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(PodcastOverviewPage), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.pumpAndSettle();
      expect(find.byType(PodcastSettingsPage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
