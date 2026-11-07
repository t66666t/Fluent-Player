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
import 'package:video_player_app/features/podcasts/podcast_runtime.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/features/podcasts/podcast_pages.dart';
import 'package:video_player_app/models/media_library_root_entry.dart';
import 'package:video_player_app/screens/home_screen.dart';
import 'package:video_player_app/services/batch_import_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_entry_switcher.dart';
import 'package:video_player_app/widgets/media_library_keyboard_navigation.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';

void main() {
  testWidgets('podcast subscriptions keep card focus when entering selection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'onboarding.handled.v1': true});
    final settings = SettingsService()..resetForTest();
    await settings.init();
    final library = LibraryService()..resetLibraryForTesting();
    library.writeLibrarySnapshotOverrideForTesting = () async {};
    final store = PodcastStore(sqlite3.openInMemory());
    for (var i = 0; i < 3; i++) {
      final channel = PodcastChannel(
        id: 'channel$i',
        feedUrl: 'https://example.test/$i.xml',
        title: 'Channel $i',
        description: List.generate(9, (line) => '频道简介第 $line 行').join('\n'),
      );
      store.mergeFeed(
        PodcastFeed(channel, [
          for (var e = 0; e < 2; e++)
            PodcastEpisode(
              id: 'channel$i-episode$e',
              channelId: channel.id,
              title: 'Episode $i-$e',
              media: [PodcastMedia(url: 'https://example.test/$i/$e.mp3')],
            ),
        ]),
        initial: true,
      );
      store.setSetting(channel.id, 'autoRefresh', false);
    }
    final http = PodcastHttp();
    final runtime = PodcastRuntime.forTesting(
      PodcastController(
        store: store,
        client: PodcastClient(http: http),
        mediaStore: PodcastMediaStore(
          root: Directory.systemTemp,
          store: store,
          http: http,
        ),
      ),
      library: library,
    );
    PodcastRuntime.debugOverride = runtime;
    final playback = MediaPlaybackService();
    await playback.stop();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      PodcastRuntime.debugOverride = null;
      await runtime.shutdown();
      library.resetLibraryForTesting();
      await playback.stop();
      settings.resetForTest();
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider.value(value: library),
          ChangeNotifierProvider.value(value: playback),
          ChangeNotifierProvider.value(value: BatchImportService()),
        ],
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: const MediaLibraryShell(home: HomeScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    tester
        .widget<MediaLibraryEntrySwitcher>(
          find.byType(MediaLibraryEntrySwitcher),
        )
        .onSelected(MediaLibraryRootEntry.podcasts);
    await tester.pumpAndSettle();
    final refreshIcon = find.descendant(
      of: find.byTooltip('检查更新'),
      matching: find.byIcon(Icons.refresh_rounded),
    );
    final queueLabel = find.text('队列');
    for (final size in [const Size(1200, 800), const Size(800, 1200)]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      Focus.of(tester.element(refreshIcon)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(
        Focus.of(tester.element(queueLabel)).hasPrimaryFocus,
        isTrue,
        reason: 'the queue tab is the refresh button’s left neighbour',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(Focus.of(tester.element(refreshIcon)).hasPrimaryFocus, isTrue);
    }
    tester.view.physicalSize = const Size(1200, 800);
    await tester.pumpAndSettle();
    expect(
      MediaLibraryKeyboardRegion.focusInitialOf(
        tester.element(find.byType(MediaLibraryKeyboardItem).first),
      ),
      isTrue,
    );
    await tester.pumpAndSettle();
    expect(MediaLibraryKeyboardItem.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.pumpAndSettle();
    expect(MediaLibraryKeyboardItem.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<MediaLibraryKeyboardItem>(
            find.byType(MediaLibraryKeyboardItem),
          )
          .where((card) => card.selected),
      hasLength(1),
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<MediaLibraryKeyboardItem>(
            find.byType(MediaLibraryKeyboardItem),
          )
          .where((card) => card.selected),
      hasLength(2),
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<MediaLibraryKeyboardItem>(
            find.byType(MediaLibraryKeyboardItem),
          )
          .where((card) => card.selected),
      hasLength(3),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(MediaLibraryKeyboardItem.hasPrimaryFocus, isTrue);
    final channelId = FocusManager.instance.primaryFocus!.context!
        .findAncestorWidgetOfExactType<MediaLibraryKeyboardItem>()!
        .itemId;
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(PodcastChannelPage), findsOneWidget);
    final episode = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<MediaLibraryKeyboardItem>();
    expect(episode?.itemId, startsWith('$channelId-episode'));
    final sidebar = find.byKey(const ValueKey('podcast-channel-sidebar'));
    final description = find.byKey(
      const ValueKey('podcast-channel-description'),
    );
    expect(tester.getSize(sidebar).width, greaterThan(216));
    expect(
      find.descendant(of: description, matching: find.text('展开')),
      findsNothing,
    );
    final initialChannel = store.channel(channelId)!;
    final originalDescription = initialChannel.description;
    initialChannel.description = List.generate(
      80,
      (line) => '较长的频道说明第 $line 行',
    ).join('\n');
    store.write('channel', channelId, initialChannel.toJson());
    runtime.controller.publish();
    await tester.pumpAndSettle();
    final longText = find.descendant(
      of: description,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Text && (widget.data?.contains('较长的频道说明第 0 行') ?? false),
      ),
    );
    final expand = find.descendant(of: description, matching: find.text('展开'));
    expect(expand, findsOneWidget);
    final linesAt800 = tester.widget<Text>(longText).maxLines;
    expect(linesAt800, greaterThan(3));
    expect(
      tester.getRect(longText).width,
      closeTo(tester.getRect(description).width, .5),
    );
    expect(
      tester.getTopLeft(expand).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(longText).dy),
    );
    expect(
      tester.getBottomLeft(description).dy,
      lessThanOrEqualTo(tester.getBottomLeft(sidebar).dy + 1),
    );
    tester.view.physicalSize = const Size(1200, 950);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(longText).maxLines, greaterThan(linesAt800!));
    await tester.ensureVisible(expand);
    await tester.tap(expand);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(longText).maxLines, isNull);
    final collapse = find.descendant(
      of: description,
      matching: find.text('收起'),
    );
    await tester.ensureVisible(collapse);
    await tester.tap(collapse);
    await tester.pumpAndSettle();
    initialChannel.description = originalDescription;
    store.write('channel', channelId, initialChannel.toJson());
    runtime.controller.publish();
    tester.view.physicalSize = const Size(1200, 800);
    await tester.pumpAndSettle();
    FocusNode buttonFocus(String tooltip) => Focus.of(
      tester.element(
        find
            .descendant(
              of: find.byTooltip(tooltip),
              matching: find.byType(Icon),
            )
            .first,
      ),
    );
    for (final size in [
      const Size(1200, 800),
      const Size(800, 1200),
      const Size(390, 844),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      final back = buttonFocus('返回');
      final refresh = buttonFocus('刷新频道');
      final more = buttonFocus('更多频道操作');
      back.requestFocus();
      await tester.pump();
      for (final target in [refresh, more]) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(
          target.hasPrimaryFocus,
          isTrue,
          reason:
              'channel header controls share the same horizontal row at $size',
        );
      }
      for (final target in [refresh, back]) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pumpAndSettle();
        expect(target.hasPrimaryFocus, isTrue);
      }
    }
    tester.view.physicalSize = const Size(1200, 800);
    await tester.pumpAndSettle();
    runtime.controller.refreshing.add(channelId);
    runtime.controller.publish();
    await tester.pumpAndSettle();
    buttonFocus('返回').requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      buttonFocus('更多频道操作').hasPrimaryFocus,
      isTrue,
      reason: 'disabled refresh controls are skipped',
    );
    runtime.controller.refreshing.remove(channelId);
    runtime.controller.publish();
    await tester.pumpAndSettle();
    final lastFilter = find.byKey(const ValueKey('podcast-filter-hidden'));
    await tester.ensureVisible(lastFilter);
    await tester.pumpAndSettle();
    Focus.of(
      tester.element(
        find.descendant(of: lastFilter, matching: find.byType(Text)).first,
      ),
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(buttonFocus('搜索频道节目').hasPrimaryFocus, isTrue);
    expect(
      MediaLibraryKeyboardRegion.focusInitialOf(
        tester.element(find.byType(MediaLibraryKeyboardItem).first),
      ),
      isTrue,
    );
    await tester.pumpAndSettle();
    final episodeRow = find.byWidgetPredicate(
      (widget) =>
          widget is MediaLibraryKeyboardItem &&
          widget.itemId == episode!.itemId,
    );
    FocusNode episodeButtonFocus(String tooltip) => Focus.of(
      tester.element(
        find
            .descendant(
              of: find.descendant(
                of: episodeRow,
                matching: find.byTooltip(tooltip),
              ),
              matching: find.byType(Icon),
            )
            .first,
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(episodeButtonFocus('播放节目').hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(episodeButtonFocus('节目操作').hasPrimaryFocus, isTrue);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(MediaLibraryKeyboardItem.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(episodeButtonFocus('播放节目').hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(episodeButtonFocus('节目操作').hasPrimaryFocus, isTrue);
    expect(
      find.ancestor(
        of: find.descendant(of: episodeRow, matching: find.byTooltip('节目操作')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).border?.top.color ==
                  Colors.lightBlueAccent,
        ),
      ),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('podcast-compact-menu')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(episodeButtonFocus('节目操作').hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('podcast-compact-menu')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(episodeButtonFocus('节目操作').hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(MediaLibraryKeyboardItem.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    final nextEpisode = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<MediaLibraryKeyboardItem>();
    expect(nextEpisode?.itemId, isNot(episode!.itemId));
    expect(MediaLibraryKeyboardItem.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<MediaLibraryKeyboardItem>()
          ?.itemId,
      episode.itemId,
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f10);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.text('节目操作'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
