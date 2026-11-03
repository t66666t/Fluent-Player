import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/desktop_player_sidebar.dart';
import 'package:video_player_app/widgets/stable_video_surface.dart';
import 'package:video_player_app/widgets/subtitle_chat_sidebar.dart';

void main() {
  for (final left in [false, true]) {
    testWidgets(
      'independent widths, fades and stable video at 120Hz, left=$left',
      (tester) async {
        final key = GlobalKey<_HarnessState>();
        await tester.pumpWidget(_Harness(key: key, left: left));
        final host = key.currentState!;
        expect(host.extent(tester), 0);
        host.open('subtitles');
        await tester.pump();
        expect(host.extent(tester), 0);
        await tester.pump(const Duration(milliseconds: 60));
        expect(host.extent(tester), inExclusiveRange(0, 212));
        final subtitleState = host.subtitles.currentState;
        final subtitleLayouts = host.subtitleLayouts;
        final textureLayouts = host.textureLayouts;
        final textureBuilds = host.textureBuilds;
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(microseconds: 8333));
          final video = tester.renderObject<RenderBox>(
            find.byKey(const ValueKey('video-plane')),
          );
          final picture = Rect.fromPoints(
            video.localToGlobal(Offset.zero),
            video.localToGlobal(video.size.bottomRight(Offset.zero)),
          );
          final playerWidth = 800 - host.extent(tester);
          expect(picture.width, closeTo(playerWidth, .001));
          expect(picture.size.aspectRatio, closeTo(16 / 9, .000001));
          expect(
            picture.center,
            Offset((left ? host.extent(tester) : 0) + playerWidth / 2, 300),
          );
        }
        expect(host.extent(tester), 212);
        expect(host.subtitleLayouts, subtitleLayouts);
        expect(host.textureLayouts, textureLayouts);
        expect(host.textureBuilds, textureBuilds);
        host.open('chat');
        await tester.pump();
        final fade = find
            .ancestor(
              of: find.byKey(const ValueKey('chat-body')),
              matching: find.byType(FadeTransition),
            )
            .first;
        expect(tester.widget<FadeTransition>(fade).opacity.value, 0);
        await tester.pump(const Duration(milliseconds: 60));
        expect(host.extent(tester), inExclusiveRange(212, 332));
        expect(
          tester.widget<FadeTransition>(fade).opacity.value,
          inExclusiveRange(0, 1),
        );
        expect(host.subtitleWidth, 200);
        expect(host.chatWidth, 320);
        final beforeReverse = host.extent(tester);
        host.open('subtitles');
        await tester.pump();
        expect(host.extent(tester), closeTo(beforeReverse, .001));
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 17));
          final before = host.extent(tester);
          host.open(i.isEven ? 'chat' : 'subtitles');
          await tester.pump();
          expect(host.extent(tester), closeTo(before, .001));
        }
        await tester.pumpAndSettle();
        expect(host.subtitles.currentState, same(subtitleState));
        expect(host.textureLayouts, textureLayouts);
        expect(host.textureBuilds, textureBuilds);
        host.open(null);
        await tester.pumpAndSettle();
        expect(host.extent(tester), 0);
        expect(
          TickerMode.valuesOf(host.subtitles.currentContext!).enabled,
          isFalse,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'multi-hop history retains reading and releases tools, left=$left',
      (tester) async {
        final key = GlobalKey<_HarnessState>();
        await tester.pumpWidget(_Harness(key: key, left: left));
        final host = key.currentState!;
        Future<void> visit(String? panel) async {
          host.open(panel);
          await tester.pumpAndSettle();
        }

        await visit('subtitles');
        final originalSubtitles = host.subtitles.currentState!;
        originalSubtitles.scroll.jumpTo(710);
        await tester.pumpAndSettle();
        await visit('chat');
        final originalChat = host.chat.currentState!;
        originalChat.scroll.jumpTo(1230);
        originalChat.draft.text = '跨多个边栏也保留草稿';
        await tester.pumpAndSettle();
        await visit('settings');
        host.settings.currentState!.scroll.jumpTo(950);
        await tester.pumpAndSettle();
        await visit('position');
        expect(host.settings.currentState, isNull);
        host.position.currentState!.scroll.jumpTo(410);
        await tester.pumpAndSettle();
        await visit(null);
        expect(host.position.currentState, isNull);
        await visit('compose');
        await visit('settings');
        expect(host.settings.currentState!.scroll.offset, 950);
        await visit('position');
        expect(host.position.currentState!.scroll.offset, 410);
        await visit('subtitles');
        expect(host.subtitles.currentState, same(originalSubtitles));
        expect(originalSubtitles.scroll.offset, 710);
        await visit('chat');
        expect(host.chat.currentState, same(originalChat));
        expect(originalChat.scroll.offset, 1230);
        expect(originalChat.draft.text, '跨多个边栏也保留草稿');
        expect(find.byKey(const ValueKey('subtitle-body')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'resize target and hit region follow the animated divider, left=$left',
      (tester) async {
        final key = GlobalKey<_HarnessState>();
        await tester.pumpWidget(_Harness(key: key, left: left));
        final host = key.currentState!;
        host.open('subtitles');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 75));
        final width = host.extent(tester);
        final x = left ? width - 6 : 800 - width + 6;
        await tester.tapAt(Offset(x, 100));
        expect(host.handleTaps, 1);
        await tester.pumpAndSettle();
        final endX = left ? 206.0 : 594.0;
        // Both sides of the 12px divider retain the enlarged 28px hit area.
        await tester.tapAt(Offset(endX + (left ? 10 : -10), 100));
        expect(host.handleTaps, 2);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'reduced motion completes opacity and disposes tools immediately',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: key, disableAnimations: true));
      final host = key.currentState!;
      host.open('settings');
      await tester.pumpAndSettle();
      expect(host.extent(tester), 280);
      host.open(null);
      await tester.pumpAndSettle();
      expect(host.extent(tester), 0);
      expect(host.settings.currentState, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a new media session starts with independent tool scroll history',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: key));
      final host = key.currentState!;
      host.open('settings');
      await tester.pumpAndSettle();
      host.settings.currentState!.scroll.jumpTo(950);
      await tester.pumpAndSettle();
      host.open(null);
      await tester.pumpAndSettle();
      host.nextMedia();
      await tester.pumpAndSettle();
      host.open('settings');
      await tester.pumpAndSettle();
      expect(host.settings.currentState!.scroll.offset, 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'return-path tools keep drafts and release after leaving history',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: key));
      final host = key.currentState!;
      host.open('settings');
      await tester.pumpAndSettle();
      final settings = host.settings.currentState!;
      settings.draft.text = '保留设置输入';
      settings.scroll.jumpTo(950);
      host.returnPanels.add('settings');
      host.open('position');
      await tester.pumpAndSettle();
      expect(host.settings.currentState, same(settings));
      expect(
        TickerMode.valuesOf(host.settings.currentContext!).enabled,
        isFalse,
      );
      host.returnPanels.add('position');
      host.open('compose');
      await tester.pumpAndSettle();
      host.open('settings');
      await tester.pumpAndSettle();
      expect(host.settings.currentState, same(settings));
      expect(settings.scroll.offset, 950);
      expect(settings.draft.text, '保留设置输入');
      host.returnPanels.clear();
      host.open(null);
      await tester.pumpAndSettle();
      expect(host.settings.currentState, isNull);
      expect(host.position.currentState, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}

class _Harness extends StatefulWidget {
  const _Harness({
    super.key,
    this.left = false,
    this.disableAnimations = false,
  });
  final bool left;
  final bool disableAnimations;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final subtitles = GlobalKey<_ScrollPanelState>();
  final chat = GlobalKey<_ScrollPanelState>();
  final settings = GlobalKey<_ScrollPanelState>();
  final position = GlobalKey<_ScrollPanelState>();
  final link = LayerLink();
  final returnPanels = <Object>{};
  String? panel;
  String media = 'first-video';
  int textureBuilds = 0;
  int textureLayouts = 0;
  int subtitleLayouts = 0;
  int handleTaps = 0;
  double subtitleWidth = 0;
  double chatWidth = 0;
  late final texture = Builder(
    builder: (_) {
      textureBuilds++;
      return LayoutBuilder(
        key: const ValueKey('video-plane'),
        builder: (_, _) {
          textureLayouts++;
          return const ColoredBox(color: Colors.blue);
        },
      );
    },
  );

  void open(String? id) => setState(() => panel = id);
  void nextMedia() => setState(() => media = 'next-video');
  double extent(WidgetTester tester) =>
      tester.getSize(find.byType(DesktopPlayerSidebar)).width;

  @override
  Widget build(BuildContext context) {
    final reading = panel == 'subtitles' || panel == 'chat';
    final divider = reading ? 12.0 : 0.0;
    final width = panel == 'chat'
        ? 320.0
        : reading
        ? 200.0
        : 280.0;
    final sidebar = DesktopPlayerSidebar(
      key: ValueKey(media),
      panelId: reading ? 'reading' : panel,
      panel: panel == 'settings'
          ? _ScrollPanel(key: settings, name: 'settings')
          : panel == 'position'
          ? _ScrollPanel(key: position, name: 'position')
          : const _ScrollPanel(name: 'compose'),
      width: width,
      retainedId: 'reading',
      returnPanelIds: returnPanels.toSet(),
      retainedWidth: 200,
      retainedPanel: SubtitleChatSidebar(
        showChat: panel == 'chat',
        isVisible: reading,
        subtitleWidth: 200,
        chatWidth: 320,
        onLeft: widget.left,
        subtitles: LayoutBuilder(
          builder: (_, constraints) {
            subtitleLayouts++;
            subtitleWidth = constraints.maxWidth;
            return _ScrollPanel(key: subtitles, name: 'subtitle');
          },
        ),
        chat: LayoutBuilder(
          builder: (_, constraints) {
            chatWidth = constraints.maxWidth;
            return _ScrollPanel(key: chat, name: 'chat');
          },
        ),
      ),
      viewportSize: const Size(800, 600),
      divider: reading ? const ColoredBox(color: Colors.grey) : null,
      dividerWidth: divider,
      dividerLink: link,
      onLeft: widget.left,
    );
    return MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(800, 600),
          disableAnimations: widget.disableAnimations,
        ),
        child: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              Row(
                children: [
                  if (widget.left) sidebar,
                  Expanded(
                    child: StableVideoSurface(
                      referenceSize: const Size(800, 450),
                      child: texture,
                    ),
                  ),
                  if (!widget.left) sidebar,
                ],
              ),
              if (reading)
                Positioned.fill(
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: CompositedTransformFollower(
                      link: link,
                      targetAnchor: Alignment.topCenter,
                      followerAnchor: Alignment.topCenter,
                      showWhenUnlinked: false,
                      child: SizedBox(
                        width: 28,
                        height: double.infinity,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => handleTaps++,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScrollPanel extends StatefulWidget {
  const _ScrollPanel({super.key, required this.name});
  final String name;

  @override
  State<_ScrollPanel> createState() => _ScrollPanelState();
}

class _ScrollPanelState extends State<_ScrollPanel> {
  final scroll = ScrollController();
  final draft = TextEditingController();

  @override
  void dispose() {
    scroll.dispose();
    draft.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    key: ValueKey('${widget.name}-body'),
    children: [
      if (widget.name == 'chat') TextField(controller: draft),
      Expanded(
        child: ListView.builder(
          key: const PageStorageKey('items'),
          controller: scroll,
          itemExtent: 50,
          itemCount: 100,
          itemBuilder: (_, i) => Text('${widget.name} $i'),
        ),
      ),
    ],
  );
}
