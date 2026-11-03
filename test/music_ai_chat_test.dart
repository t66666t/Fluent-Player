import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_controller.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_models.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_panel.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_session.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';
import 'package:video_player_app/features/ai_chat/ai_conversation_store.dart';
import 'package:video_player_app/features/ai_chat/ai_message_navigation.dart';
import 'package:video_player_app/features/ai_chat/ai_video_context.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/podcast_source_ref.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/screens/music_player_screen.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/music_lyric_view.dart';

class _Store extends AiConversationStore {
  final records = <AiConversation>[];

  @override
  Future<List<AiConversation>> load(String videoId) async =>
      records.where((record) => record.videoId == videoId).toList();

  @override
  Future<void> save(AiConversation conversation) async {
    records.removeWhere((record) => record.id == conversation.id);
    records.add(conversation);
  }
}

class _Loader extends AiVideoContextLoader {
  @override
  Future<AiVideoContext> load({
    required VideoItem video,
    List<SubtitleItem> primarySubtitles = const [],
    List<SubtitleItem> secondarySubtitles = const [],
    Duration position = Duration.zero,
    String? primaryPath,
    String? secondaryPath,
  }) async => AiVideoContext(
    videoId: video.id,
    title: video.title,
    position: position,
    tracks: [
      if (primarySubtitles.isNotEmpty)
        AiSubtitleTrack(id: 'primary', label: '文字稿', cues: primarySubtitles),
    ],
  );
}

class _Transport extends AiChatTransport {
  final updates = StreamController<AiChatDelta>();
  final started = Completer<void>();

  @override
  Stream<AiChatDelta> stream({
    required AiChatSettings settings,
    required List<Map<String, String>> messages,
    required AiChatCancellation cancellation,
  }) {
    if (!started.isCompleted) started.complete();
    return updates.stream;
  }
}

/// A video-file podcast. The chat must say「播客」, not the file type「视频」.
VideoItem _episode(String id) => VideoItem(
  id: id,
  path: '$id.mp3',
  title: '一段值得细听的播客',
  durationMs: 120000,
  lastUpdated: 1,
  sourceRef: MediaSourceRef(
    value: 'podcast:$id',
    kind: MediaSourceKind.podcastEpisode,
    podcast: PodcastEpisodeRef(
      channelId: 'channel',
      episodeId: id,
      feedUrl: 'https://example.com/feed.xml',
      mediaUrl: 'https://example.com/$id.mp3',
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MediaPlaybackService playback;
  late SettingsService settings;
  late VideoItem item;
  late AiChatController controller;
  late _Transport transport;
  late GlobalKey previewKey;
  Duration? sought;

  setUpAll(() async {
    if (const bool.fromEnvironment('MUSIC_AI_CHAT_PREVIEW')) {
      final fonts = FontLoader('Noto Sans SC')
        ..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'));
      await fonts.load();
      await (FontLoader(
        'Inter',
      )..addFont(rootBundle.load('assets/fonts/Inter-Regular.otf'))).load();
      await (FontLoader('Roboto')..addFont(
            rootBundle.load('assets/fonts/Roboto_Condensed-Regular.ttf'),
          ))
          .load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
            rootBundle.load(
              'packages/cupertino_icons/assets/CupertinoIcons.ttf',
            ),
          ))
          .load();
    }
  });

  setUp(() async {
    debugAiChatDesktopAutofocus = false;
    AiChatSessions.instance.shutdown();
    item = _episode('podcast-ai');
    playback = MediaPlaybackService.forTesting()..debugSeedCurrentItem(item);
    settings = SettingsService()..resetForTest();
    transport = _Transport();
    final store = _Store();
    store.records.add(
      AiConversation(
        id: 'podcast-history',
        videoId: item.id,
        title: '一起理解这期播客',
        messages: [
          for (var i = 0; i < 16; i++) ...[
            AiChatMessage(id: 'q$i', role: 'user', content: '问题 $i'),
            AiChatMessage(
              id: 'a$i',
              role: 'assistant',
              content: List.generate(
                35,
                (line) => '第 $i 轮，第 $line 段：把这期播客的观点讲清楚。',
              ).join('\n\n'),
            ),
          ],
        ],
      ),
    );
    controller = AiChatController(
      video: item,
      contextLoader: _Loader(),
      conversationStore: store,
      transport: transport,
      initialSettings: const AiChatSettings(
        backend: AiBackend.codex,
        titlePrompt: '',
      ),
    );
    await controller.initialize();
    AiChatSessions.instance.holdForTesting(controller);
    previewKey = GlobalKey();
    sought = null;
  });

  tearDown(() {
    AiChatSessions.instance.shutdown();
    unawaited(transport.updates.close());
    playback.dispose();
    settings.resetForTest();
    debugAiChatDesktopAutofocus = true;
  });

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    bool followSession = true,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
        ],
        child: RepaintBoundary(
          key: previewKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              brightness: Brightness.dark,
              useMaterial3: true,
              fontFamily: const bool.fromEnvironment('MUSIC_AI_CHAT_PREVIEW')
                  ? 'Noto Sans SC'
                  : null,
            ),
            home: MusicPlayerScreen(
              followCurrentSession: followSession,
              title: item.title,
              artist: '慢慢听 · 播客',
              onSeek: (value) => sought = value,
              headerAction: IconButton(
                key: const ValueKey('podcast-more'),
                tooltip: '更多',
                onPressed: () {},
                icon: const Icon(Icons.more_horiz),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  final entry = find.byKey(const ValueKey('music-toolbar-ai-chat'));

  Future<void> open(WidgetTester tester) async {
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.byType(AiChatPanel), findsOneWidget);
  }

  Future<void> preview(WidgetTester tester, String name) async {
    if (!const bool.fromEnvironment('MUSIC_AI_CHAT_PREVIEW')) return;
    await tester.runAsync(() async {
      final boundary =
          previewKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final directory = Directory('.artifacts/music-ai-chat');
      await directory.create(recursive: true);
      await File(
        '${directory.path}/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final size in [
    const Size(320, 640),
    const Size(390, 844),
    const Size(568, 320),
    const Size(844, 390),
    const Size(1366, 900),
  ]) {
    testWidgets('fixed AI entry and fullscreen return at $size', (
      tester,
    ) async {
      await mount(tester, size: size);
      final buttonRect = tester.getRect(entry);
      final timer = tester.getRect(find.byIcon(Icons.schedule_rounded));
      final more = tester.getRect(find.byKey(const ValueKey('podcast-more')));
      expect(
        buttonRect.center.dx,
        inExclusiveRange(
          timer.center.dx < more.center.dx ? timer.center.dx : more.center.dx,
          timer.center.dx > more.center.dx ? timer.center.dx : more.center.dx,
        ),
      );
      expect(buttonRect.size, const Size(44, 44));
      final playerState = tester.state(find.byType(MusicPlayerScreen));
      await tester.pumpAndSettle();
      await preview(tester, 'player-${size.width.toInt()}');
      await open(tester);
      expect(find.text('询问这个播客…'), findsOneWidget);
      expect(find.text('询问这个视频…'), findsNothing);
      final panel = tester.widget<AiChatPanel>(find.byType(AiChatPanel));
      expect(panel.videoItem.id, item.id);
      expect(panel.isFullscreen, isTrue);
      expect(tester.getSize(find.byType(AiChatFullscreenSurface)), size);
      panel.onSeek!(const Duration(seconds: 23));
      expect(sought, const Duration(seconds: 23));
      await preview(tester, 'chat-${size.width.toInt()}');
      await tester.tap(find.byTooltip('返回播放页').first);
      await tester.pumpAndSettle();
      expect(find.byType(AiChatPanel), findsNothing);
      expect(tester.state(find.byType(MusicPlayerScreen)), same(playerState));
      expect(entry.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('reading anchor and draft survive close, reopen and rotation', (
    tester,
  ) async {
    await mount(tester);
    await open(tester);
    final viewport = tester.widget<AiMessageViewport>(
      find.byType(AiMessageViewport),
    );
    viewport.onNavigate();
    viewport.controller.restore(const AiMessageBookmark('a7', 0, .4));
    await tester.pumpAndSettle();
    final draft = AiChatSessions.instance.retain(
      video: item,
      createLoader: _Loader.new,
    );
    expect(draft.controller, same(controller));
    draft.input.text = '先留着，接着问';
    await tester.pump();
    await tester.tap(find.byTooltip('返回播放页').first);
    await tester.pumpAndSettle();
    await open(tester);
    var restored = tester.widget<AiMessageViewport>(
      find.byType(AiMessageViewport),
    );
    expect(restored.controller.bookmark!.messageId, 'a7');
    expect(restored.controller.bookmark!.fraction, closeTo(.4, .02));
    expect(draft.input.text, '先留着，接着问');
    tester.view.physicalSize = const Size(844, 390);
    await tester.binding.setSurfaceSize(const Size(844, 390));
    await tester.pumpAndSettle();
    restored = tester.widget<AiMessageViewport>(find.byType(AiMessageViewport));
    expect(restored.controller.bookmark!.messageId, 'a7');
    // System back only dismisses the conversation route.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(entry.hitTestable(), findsOneWidget);
    expect(find.byType(AiChatPanel), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('live transcript updates, clock and episode changes reach chat', (
    tester,
  ) async {
    await mount(tester);
    await open(tester);
    final cues = [
      SubtitleItem(
        index: 0,
        startTime: Duration.zero,
        endTime: const Duration(seconds: 12),
        text: '刚完成的播客文字稿',
      ),
    ];
    playback.setSubtitleState(
      paths: ['podcast.srt'],
      primary: cues,
      secondary: [],
    );
    playback.positionNotifier.value = const Duration(seconds: 9);
    await tester.pumpAndSettle();
    var panel = tester.widget<AiChatPanel>(find.byType(AiChatPanel));
    expect(panel.primaryPath, 'podcast.srt');
    expect(panel.primarySubtitles.single.text, cues.single.text);
    expect(panel.positionListenable!.value, const Duration(seconds: 9));
    expect(
      controller.videoContext!.tracks.single.cues.single.text,
      cues.single.text,
    );
    final next = _episode('next-podcast');
    final nextController = AiChatController(
      video: next,
      contextLoader: _Loader(),
      conversationStore: _Store(),
      initialSettings: const AiChatSettings(titlePrompt: ''),
    );
    await nextController.initialize();
    AiChatSessions.instance.holdForTesting(nextController);
    playback.debugSeedCurrentItem(next);
    playback.setSubtitleState(paths: [], primary: [], secondary: []);
    await tester.pumpAndSettle();
    panel = tester.widget<AiChatPanel>(find.byType(AiChatPanel));
    expect(panel.videoItem.id, next.id);
    expect(panel.primarySubtitles, isEmpty);
    expect(nextController.video.id, next.id);
    expect(controller.video.id, item.id);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('generation continues with the fullscreen route closed', (
    tester,
  ) async {
    await mount(tester);
    await open(tester);
    final reply = controller.send('继续解释');
    await tester.pump();
    expect(transport.started.isCompleted, isTrue);
    transport.updates.add(const AiChatDelta(content: '开始回答。'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回播放页').first);
    await tester.pumpAndSettle();
    expect(controller.generating, isTrue);
    transport.updates.add(
      const AiChatDelta(content: '在播放页继续完成。', finishReason: 'stop'),
    );
    await tester.runAsync(() => transport.updates.close());
    await reply;
    await open(tester);
    expect(controller.active!.messages.last.content, contains('在播放页继续完成。'));
    expect(controller.generating, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('entry stays fixed while scrolling hides playback controls', (
    tester,
  ) async {
    settings.musicPortraitControlsAutoHide = true;
    await mount(tester);
    playback.setSubtitles([
      for (var i = 0; i < 50; i++)
        SubtitleItem(
          index: i,
          startTime: Duration(seconds: i * 2),
          endTime: Duration(seconds: i * 2 + 2),
          text: '播客文字稿第 $i 段',
        ),
    ]);
    await tester.pumpAndSettle();
    final before = tester.getRect(entry);
    final lyric = tester.widget<MusicLyricView>(find.byType(MusicLyricView));
    lyric.onScrollDirectionChanged!(-1);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(const Duration(milliseconds: 400));
    final controls = find.byKey(
      const ValueKey('music-portrait-controls-overlay'),
    );
    expect(
      tester
          .widget<IgnorePointer>(
            find
                .descendant(of: controls, matching: find.byType(IgnorePointer))
                .first,
          )
          .ignoring,
      isTrue,
    );
    expect(tester.getRect(entry), before);
    expect(entry.hitTestable(), findsOneWidget);
    await open(tester);
    // Playback shortcuts must not intercept typing or Escape in AI mode.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AiChatPanel), findsNothing);
    expect(entry.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('pending episode cannot open the previous media chat', (
    tester,
  ) async {
    await mount(tester, followSession: false);
    expect(tester.widget<IconButton>(entry).onPressed, isNull);
    await tester.tap(entry);
    await tester.pump();
    expect(find.byType(AiChatPanel), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
