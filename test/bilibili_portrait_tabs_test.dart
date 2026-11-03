import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_controller.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_models.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_panel.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_session.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_conversation_store.dart';
import 'package:video_player_app/features/ai_chat/ai_video_context.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/bilibili_browse_models.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/screens/portrait_video_screen.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_video_detail_cache.dart';
import 'package:video_player_app/services/bilibili/bilibili_watch_launch.dart';
import 'package:video_player_app/services/bilibili/bilibili_player_panel_memory.dart';
import 'package:video_player_app/services/bilibili/bilibili_player_panel_policy.dart';
import 'package:video_player_app/services/bilibili/bilibili_streaming_service.dart';
import 'package:video_player_app/services/embedded_subtitle_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/ocr_subtitle_manager.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/progress_tracker.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/widgets/bilibili_player_panel.dart';
import 'package:video_player_app/widgets/bilibili_portrait_tabs.dart';
import 'package:video_player_app/widgets/bilibili_parts_picker.dart';
import 'package:video_player_app/widgets/episode_picker_panel.dart';
import 'package:video_player_app/widgets/portrait_playback_layout.dart';
import 'package:video_player_app/widgets/subtitle_management_sheet.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';

import 'test_dir_cleanup.dart';

void main() {
  group('BilibiliPortraitTabMemory', () {
    test('details at first; only userPicked writes', () async {
      var stored = false;
      final writes = <bool>[];
      final memory = BilibiliPortraitTabMemory(
        readSubtitles: () => stored,
        writeSubtitles: (value) async {
          writes.add(value);
          stored = value;
        },
      );
      expect(memory.remembered, PortraitBilibiliTab.details);
      memory.userPicked(PortraitBilibiliTab.subtitles);
      await Future<void>.delayed(Duration.zero);
      expect(memory.remembered, PortraitBilibiliTab.subtitles);
      expect(writes, [true]);
    });

    test('a hand-off is for its card only, and taken once', () {
      BilibiliPortraitTabMemory.handOff('a', PortraitBilibiliTab.subtitles);
      expect(BilibiliPortraitTabMemory.takeHandOff('b'), isNull);
      expect(
        BilibiliPortraitTabMemory.takeHandOff('a'),
        PortraitBilibiliTab.subtitles,
      );
      expect(BilibiliPortraitTabMemory.takeHandOff('a'), isNull);
    });
  });

  group('portrait player, 「详情 | 字幕」 below the video', () {
    late Directory root;
    late PathProviderPlatform originalPaths;
    late LibraryService library;
    late MediaPlaybackService playback;
    final settings = SettingsService();

    setUp(() async {
      Provider.debugCheckInvalidValueType = null;
      SharedPreferences.setMockInitialValues(<String, Object>{});
      settings.resetForTest();
      await settings.init();
      root = await Directory.systemTemp.createTemp('bilibili_portrait_tabs_');
      originalPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(root.path);
      library = LibraryService()..resetLibraryForTesting();
      playback = MediaPlaybackService();
      await playback.initialize(
        playlistManager: PlaylistManager(),
        progressTracker: ProgressTracker(),
        bilibiliStreamingService: _NeverReadyStreaming(),
      );
    });

    tearDown(() async {
      BilibiliWatchSources.overrideForTesting = null;
      BilibiliPortraitTabMemory.takeHandOff(_bilibiliItem().id);
      settings.resetForTest();
      library.resetLibraryForTesting();
      PathProviderPlatform.instance = originalPaths;
      Provider.debugCheckInvalidValueType = _defaultValueTypeCheck;
      await deleteTestTempDir(root);
    });

    Future<void> open(WidgetTester tester, VideoItem item) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsService>.value(value: settings),
            ChangeNotifierProvider<LibraryService>.value(value: library),
            ChangeNotifierProvider<TranscriptionManager>.value(
              value: TranscriptionManager(),
            ),
            ChangeNotifierProvider<EmbeddedSubtitleService>.value(
              value: EmbeddedSubtitleService(),
            ),
            ChangeNotifierProvider<OcrSubtitleManager>.value(
              value: OcrSubtitleManager(library: library),
            ),
            ChangeNotifierProvider<PlaylistManager>.value(
              value: PlaylistManager(),
            ),
            Provider<MediaPlaybackService>.value(value: playback),
          ],
          child: MaterialApp(
            home: PortraitVideoScreen(videoItem: item, autoPlayOnEntry: false),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    Future<void> close(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 30));
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    final tabBar = find.byKey(const ValueKey('bilibili-portrait-tab-bar'));
    final details = find.byType(BilibiliPlayerPanel);
    final subtitles = find.byType(SubtitleSidebar);

    PortraitBilibiliTab shownTab(WidgetTester tester) => tester
        .widget<BilibiliPortraitTabs>(find.byType(BilibiliPortraitTabs))
        .tab;

    testWidgets('a Bilibili video shows the details at first, the '
        'subtitle list a tap away; the tap is remembered', (tester) async {
      await open(tester, _bilibiliItem());
      expect(tabBar, findsOneWidget);
      expect(shownTab(tester), PortraitBilibiliTab.details);
      expect(details, findsOneWidget);
      // The subtitle list stays built behind the details, not visible.
      expect(find.byType(SubtitleSidebar, skipOffstage: false), findsOneWidget);
      expect(subtitles, findsNothing);
      expect(
        tester
            .widget<SubtitleSidebar>(
              find.byType(SubtitleSidebar, skipOffstage: false),
            )
            .isVisible,
        isFalse,
      );

      await tester.tap(
        find.byKey(const ValueKey('bilibili-portrait-tab-subtitles')),
      );
      await settle(tester);
      expect(shownTab(tester), PortraitBilibiliTab.subtitles);
      expect(subtitles, findsOneWidget);
      expect(tester.widget<SubtitleSidebar>(subtitles).isVisible, isTrue);
      expect(settings.bilibiliPortraitShowsSubtitles, isTrue);
      await close(tester);

      // The next Bilibili video opens on the remembered tab.
      await open(tester, _bilibiliItem());
      expect(shownTab(tester), PortraitBilibiliTab.subtitles);
      await tester.tap(
        find.byKey(const ValueKey('bilibili-portrait-tab-details')),
      );
      await settle(tester);
      expect(shownTab(tester), PortraitBilibiliTab.details);
      expect(settings.bilibiliPortraitShowsSubtitles, isFalse);
      await close(tester);
    });

    testWidgets('swiping switches and remembers the portrait tab', (
      tester,
    ) async {
      await open(tester, _bilibiliItem());
      final bounds = tester.getRect(find.byType(BilibiliPortraitTabs));
      final start = Offset(bounds.right - 60, bounds.bottom - 80);
      await tester.timedDragFrom(
        start,
        Offset(-bounds.width * .6, 0),
        const Duration(milliseconds: 300),
      );
      await settle(tester);
      expect(shownTab(tester), PortraitBilibiliTab.subtitles);
      expect(settings.bilibiliPortraitShowsSubtitles, isTrue);
      expect(tester.widget<SubtitleSidebar>(subtitles).isVisible, isTrue);
      await close(tester);
      await open(tester, _bilibiliItem());
      expect(shownTab(tester), PortraitBilibiliTab.subtitles);
      final returned = tester.getRect(find.byType(BilibiliPortraitTabs));
      await tester.timedDragFrom(
        Offset(returned.left + 60, returned.bottom - 80),
        Offset(returned.width * .6, 0),
        const Duration(milliseconds: 300),
      );
      await settle(tester);
      expect(shownTab(tester), PortraitBilibiliTab.details);
      expect(settings.bilibiliPortraitShowsSubtitles, isFalse);
      await close(tester);
    });

    testWidgets('the part picker opens over details; '
        'closing it brings the details back, nothing remembered', (
      tester,
    ) async {
      BilibiliWatchSources.overrideForTesting = BilibiliWatchSources(
        details: BilibiliVideoDetailCache(
          fetch: (_) async => const BilibiliVideoDetail(
            bvid: _bvid,
            title: '分P视频',
            parts: [
              BilibiliVideoPart(cid: 101, page: 1, title: '第一P'),
              BilibiliVideoPart(cid: 102, page: 2, title: '第二P'),
            ],
          ),
        ),
      );
      await open(tester, _bilibiliItem());
      await tester.tap(find.byKey(const ValueKey('bilibili-panel-episodes')));
      await settle(tester);
      expect(find.byType(BilibiliPartsPicker), findsOneWidget);
      expect(tabBar, findsOneWidget);

      await tester.tap(find.byTooltip('关闭').last);
      await settle(tester);
      expect(find.byType(BilibiliPartsPicker), findsNothing);
      expect(shownTab(tester), PortraitBilibiliTab.details);
      expect(details, findsOneWidget);
      expect(settings.bilibiliPortraitShowsSubtitles, isFalse);
      await close(tester);
    });

    testWidgets('the subtitle manager takes the place of the subtitle tab; '
        'closing it goes back to that tab', (tester) async {
      settings.bilibiliPortraitShowsSubtitles = true;
      await open(tester, _bilibiliItem());
      expect(shownTab(tester), PortraitBilibiliTab.subtitles);
      tester.widget<SubtitleSidebar>(subtitles).onOpenSubtitleManager!();
      await settle(tester);
      expect(find.byType(SubtitleManagementSheet), findsOneWidget);
      expect(tabBar.hitTestable(), findsNothing);

      tester
          .widget<SubtitleManagementSheet>(find.byType(SubtitleManagementSheet))
          .onClose!();
      await settle(tester);
      expect(shownTab(tester), PortraitBilibiliTab.subtitles);
      expect(subtitles, findsOneWidget);
      expect(settings.bilibiliPortraitShowsSubtitles, isTrue);
      await close(tester);
    });

    testWidgets('the tab picked on the loading page is where the page '
        'starts, and where it comes back to; the memory stays', (tester) async {
      BilibiliPortraitTabMemory.handOff(
        _bilibiliItem().id,
        PortraitBilibiliTab.subtitles,
      );
      await open(tester, _bilibiliItem());
      expect(shownTab(tester), PortraitBilibiliTab.subtitles);
      tester.widget<SubtitleSidebar>(subtitles).onOpenEpisodePicker!();
      await settle(tester);
      tester
          .widget<EpisodePickerPanel>(find.byType(EpisodePickerPanel))
          .onClose();
      await settle(tester);
      expect(shownTab(tester), PortraitBilibiliTab.subtitles);
      expect(settings.bilibiliPortraitShowsSubtitles, isFalse);
      await close(tester);
    });

    testWidgets('other videos keep the plain subtitle list', (tester) async {
      settings.bilibiliPortraitShowsSubtitles = false;
      await open(tester, _localItem(root.path));
      expect(tabBar, findsNothing);
      expect(details, findsNothing);
      expect(subtitles, findsOneWidget);
      expect(tester.widget<SubtitleSidebar>(subtitles).isVisible, isTrue);
      await close(tester);
    });

    testWidgets(
      'portrait chat keyboard frames retain the real page and playing surface',
      (tester) async {
        final item = _localItem(root.path);
        final controller = AiChatController(
          video: item,
          initialSettings: const AiChatSettings(),
          conversationStore: _KeyboardConversationStore(),
          contextLoader: _KeyboardContextLoader(),
        );
        await tester.runAsync(controller.initialize);
        AiChatSessions.instance.holdForTesting(controller);
        addTearDown(AiChatSessions.instance.shutdown);
        await open(tester, item);
        tester.widget<SubtitleSidebar>(subtitles).onOpenAiChat!();
        await settle(tester);
        final inputFinder = find.byKey(const ValueKey('ai-chat-input'));
        expect(tester.widget<TextField>(inputFinder).enabled, isTrue);
        await tester.enterText(inputFinder, '键盘动画中的草稿\n继续编辑');
        await tester.pump();
        final input = tester.widget<TextField>(inputFinder);
        final draft = input.controller!.value;
        final layoutFinder = find.byType(PortraitPlaybackLayout);
        final layout = tester.widget<PortraitPlaybackLayout>(layoutFinder);
        final chat = tester.element(find.byType(AiChatPanel));
        final page = tester.element(find.byType(PortraitVideoScreen));
        Rect paintedRect(Finder finder) {
          final box = tester.renderObject<RenderBox>(finder);
          return Rect.fromPoints(
            box.localToGlobal(Offset.zero),
            box.localToGlobal(box.size.bottomRight(Offset.zero)),
          );
        }
        final transport = find.byKey(const ValueKey('portrait-external-controls'));
        final progress = find.byKey(const ValueKey('portrait-bottom-control-bar'));
        final originalControlsHeight = paintedRect(transport).height;
        final originalProgressHeight = paintedRect(progress).height;
        for (final inset in [160.0, 320.0, 400.0, 260.0, 360.0, 0.0]) {
          tester.view.viewInsets = FakeViewPadding(bottom: inset);
          await tester.pump(const Duration(milliseconds: 8));
          expect(
            tester.widget<PortraitPlaybackLayout>(layoutFinder),
            same(layout),
          );
          expect(tester.element(find.byType(AiChatPanel)), same(chat));
          expect(tester.element(find.byType(PortraitVideoScreen)), same(page));
          expect(input.focusNode!.hasFocus, isTrue, reason: 'inset=$inset');
          expect(input.controller!.value, draft);
          final composer = tester.getRect(
            find.byKey(const ValueKey('ai-chat-composer')),
          );
          expect(composer.bottom, lessThanOrEqualTo(915 - inset));
          final transportRect = paintedRect(transport);
          final progressRect = paintedRect(progress);
          expect(transportRect.bottom, closeTo(progressRect.top, .1));
          expect(
            progressRect.bottom,
            lessThanOrEqualTo(paintedRect(find.byType(AiChatPanel)).top + .1),
          );
          if (inset > 0) {
            expect(transportRect.height, lessThan(originalControlsHeight));
            expect(progressRect.height, lessThan(originalProgressHeight));
          } else {
            expect(transportRect.height, closeTo(originalControlsHeight, .1));
            expect(progressRect.height, closeTo(originalProgressHeight, .1));
          }
          expect(tester.takeException(), isNull);
        }
        // A normal state change still rebuilds the live page and returns to
        // subtitles while the same video remains mounted.
        tester
            .widget<AiChatPanel>(find.byType(AiChatPanel))
            .onBackToSubtitles!();
        await settle(tester);
        expect(subtitles, findsOneWidget);
        expect(tester.element(find.byType(PortraitVideoScreen)), same(page));
        await close(tester);
        AiChatSessions.instance.shutdown();
      },
    );
  });
}

final _defaultValueTypeCheck = Provider.debugCheckInvalidValueType;

const _bvid = 'BV1xx411c7mD';

VideoItem _bilibiliItem() => VideoItem(
  id: 'watch-1',
  path: 'bilibili://stream/$_bvid?cid=101',
  title: '测试视频',
  durationMs: 600000,
  lastUpdated: 0,
  isTransient: true,
  isBilibiliExported: true,
  sourceRef: const MediaSourceRef(
    value: _bvid,
    kind: MediaSourceKind.bilibiliStream,
    bvid: _bvid,
    cid: 101,
    page: 1,
  ),
);

VideoItem _localItem(String root) => VideoItem(
  id: 'local-1',
  path: '$root/local.mp4',
  title: '本地视频',
  durationMs: 600000,
  lastUpdated: 0,
);

class _NeverReadyStreaming extends BilibiliStreamingService {
  _NeverReadyStreaming() : super(BilibiliApiService());

  @override
  Future<BilibiliPreparedPlayback> prepare(
    VideoItem item, {
    int? qualityId,
    int? audioQualityId,
    bool allowWarmReuse = true,
    bool forceRefresh = false,
  }) => Completer<BilibiliPreparedPlayback>().future;
}

class _KeyboardConversationStore extends AiConversationStore {
  @override
  Future<List<AiConversation>> load(String videoId) async => [];

  @override
  Future<void> save(AiConversation conversation) async {}
}

class _KeyboardContextLoader extends AiVideoContextLoader {
  @override
  Future<AiVideoContext> load({
    required VideoItem video,
    List<SubtitleItem> primarySubtitles = const [],
    List<SubtitleItem> secondarySubtitles = const [],
    Duration position = Duration.zero,
    String? primaryPath,
    String? secondaryPath,
  }) async => AiVideoContext(videoId: video.id, title: video.title);
}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;
}
