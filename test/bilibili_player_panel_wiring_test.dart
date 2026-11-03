import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/desktop_player_shortcuts.dart';
import 'package:video_player_app/widgets/player_top_bar.dart';
import 'package:video_player_app/widgets/video_controls_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
  });

  tearDown(() => SettingsService().isLeftHandedMode = false);

  Future<void> pumpOverlay(
    WidgetTester tester, {
    VoidCallback? onToggleBilibiliPanel,
    bool open = false,
    Size size = const Size(1280, 720),
    bool allButtons = false,
    bool leftHanded = false,
    bool sharedTabs = false,
    bool sidebarOpen = false,
  }) async {
    SettingsService().isLeftHandedMode = leftHanded;
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(
            value: SettingsService(),
          ),
          ChangeNotifierProvider<MediaPlaybackService>.value(
            value: MediaPlaybackService(),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: VideoControlsOverlay(
              controller: null,
              isLocked: false,
              onTogglePlay: () {},
              onBackPressed: () {},
              onExitPressed: () {},
              onToggleLock: () {},
              onSpeedUpdate: (_) async {},
              showSubtitles: false,
              onToggleSubtitles: () {},
              onMoveSubtitles: () {},
              isLongPressing: false,
              longPressFeedbackText: '',
              onLongPressStart: () => false,
              onLongPressEnd: () {},
              subtitleEntries: const [],
              subtitleStyle: const SubtitleStyle(),
              subtitleAlignment: Alignment.bottomCenter,
              onEnterSubtitleDragMode: () {},
              allowPlayWhenUninitialized: true,
              onToggleBilibiliPanel: onToggleBilibiliPanel,
              bilibiliPanelOpen: open,
              usesBilibiliSidebarTabs: sharedTabs,
              isSubtitleSidebarVisible: sidebarOpen,
              mediaTitle: allButtons ? '一个很长很长的哔哩哔哩视频标题，用来占满顶栏' : '',
              onOpenSettings: allButtons ? () {} : null,
              onOpenSubtitleManager: allButtons ? () {} : null,
              onOpenVideoCompose: allButtons ? () {} : null,
              onOpenOcrSubtitle: allButtons ? () {} : null,
              onToggleFloatingSubtitleSettings: allButtons ? () {} : null,
              onToggleSidebar: allButtons ? () {} : null,
              onToggleFullScreen: allButtons ? () {} : null,
              onOpenAspectRatio: allButtons ? () {} : null,
              aspectRatioLabel: allButtons ? '原始' : null,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 40));
  }

  KeyEventResult pressI(WidgetTester tester, FocusNode node) {
    final state = tester.state<VideoControlsOverlayState>(
      find.byType(VideoControlsOverlay),
    );
    final down = state.handleKeyEvent(
      node,
      const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyI,
        logicalKey: LogicalKeyboardKey.keyI,
        timeStamp: Duration.zero,
      ),
    );
    state.handleKeyEvent(
      node,
      const KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.keyI,
        logicalKey: LogicalKeyboardKey.keyI,
        timeStamp: Duration.zero,
      ),
    );
    return down;
  }

  const buttonKey = ValueKey('video-controls-top-bilibili-panel');

  testWidgets('no Bilibili button for other videos', (tester) async {
    await pumpOverlay(tester);
    expect(find.byKey(buttonKey), findsNothing);
    await finish(tester);
  });

  testWidgets('a Bilibili video gets the button and the I key', (tester) async {
    var toggles = 0;
    await pumpOverlay(tester, onToggleBilibiliPanel: () => toggles++);
    expect(find.byKey(buttonKey), findsOneWidget);

    await tester.tap(find.byKey(buttonKey));
    await tester.pump();
    expect(toggles, 1);

    final node = FocusNode();
    addTearDown(node.dispose);
    pressI(tester, node);
    expect(toggles, 2);
    await finish(tester);
  });

  testWidgets(
    'shared-sidebar buttons describe tab switching and slot visibility',
    (tester) async {
      for (final open in [false, true]) {
        await pumpOverlay(
          tester,
          onToggleBilibiliPanel: () {},
          sharedTabs: true,
          sidebarOpen: open,
          open: open,
          allButtons: true,
        );
        expect(
          find.byTooltip(open ? '切换到字幕 (I)' : '切换到哔哩哔哩 (I)'),
          findsOneWidget,
        );
        expect(
          find.byTooltip(open ? '收起播放边栏 (B)' : '展开播放边栏 (B)'),
          findsOneWidget,
        );
        await finish(tester);
      }
    },
  );

  group('phone landscape: the title stays visible, buttons that do not fit '
      'go into 更多 by priority, nothing overflows', () {
    Rect buttonRect(WidgetTester tester, Finder icon) => tester.getRect(
      find.ancestor(of: icon, matching: find.byType(IconButton)).first,
    );
    const icons = <PlayerTopAction, IconData>{
      PlayerTopAction.settings: Icons.settings,
      PlayerTopAction.subtitleLibrary: Icons.subtitles,
      PlayerTopAction.videoCompose: Icons.movie_creation_outlined,
      PlayerTopAction.ocrSubtitle: Icons.document_scanner_outlined,
      PlayerTopAction.bilibiliPanel: Icons.smart_display_outlined,
      PlayerTopAction.subtitleStyle: Icons.style,
      PlayerTopAction.moveSubtitles: Icons.open_with,
      PlayerTopAction.fullScreen: Icons.fullscreen,
      PlayerTopAction.subtitleSidebar: Icons.menu,
      PlayerTopAction.aspectRatio: Icons.aspect_ratio,
    };

    // The page's video area: the whole window (the Bilibili panel goes over
    // the video), or what a docked subtitle list (262.4 + its 12 handle)
    // leaves while the panel is closed.
    for (final window in const <Size>[
      Size(640, 360),
      Size(740, 360),
      Size(800, 360),
    ]) {
      for (final surfaceWidth in <double>[window.width, window.width - 274.4]) {
        for (final leftHanded in const <bool>[false, true]) {
          testWidgets('${window.width.toInt()}x${window.height.toInt()}, '
              'video ${surfaceWidth.toStringAsFixed(1)} wide'
              '${leftHanded ? ', left-handed' : ''}', (tester) async {
            // Tests run as a desktop, whose bar also has the full-screen
            // button phones do not get: the bar is given its width on top.
            await pumpOverlay(
              tester,
              onToggleBilibiliPanel: () {},
              size: Size(surfaceWidth, window.height),
              allButtons: true,
              leftHanded: leftHanded,
            );
            tester.takeException();
            final desktopOnly = buttonRect(
              tester,
              find.byIcon(Icons.fullscreen),
            ).width;
            await finish(tester);

            final width = surfaceWidth + desktopOnly;
            await pumpOverlay(
              tester,
              onToggleBilibiliPanel: () {},
              size: Size(width, window.height),
              allButtons: true,
              leftHanded: leftHanded,
            );
            expect(tester.takeException(), isNull);
            final title = tester.getRect(find.text('一个很长很长的哔哩哔哩视频标题，用来占满顶栏'));
            expect(
              title.width,
              greaterThanOrEqualTo(kPlayerTopTitleMinWidth - 0.5),
            );
            final shown = <PlayerTopAction>{
              for (final entry in icons.entries)
                if (find.byIcon(entry.value).evaluate().isNotEmpty) entry.key,
            };
            final hidden = icons.keys.toSet().difference(shown);
            // Only the first ones of the priority table went into 更多.
            expect(
              hidden,
              kPlayerTopActionCollapseOrder
                  .where(icons.containsKey)
                  .where(icons.containsKey)
                  .take(hidden.length)
                  .toSet(),
            );
            expect(
              find.byKey(const ValueKey('video-controls-top-more')),
              hidden.isEmpty ? findsNothing : findsOneWidget,
            );
            expect(shown, contains(PlayerTopAction.bilibiliPanel));
            final bilibili = buttonRect(
              tester,
              find.byIcon(Icons.smart_display_outlined),
            );
            expect(bilibili.left, greaterThanOrEqualTo(0));
            expect(bilibili.right, lessThanOrEqualTo(width));
            if (shown.contains(PlayerTopAction.ocrSubtitle)) {
              // Still right after OCR when both are in the bar.
              final ocr = buttonRect(
                tester,
                find.byIcon(Icons.document_scanner_outlined),
              );
              expect(bilibili.left, closeTo(ocr.right, 0.5));
            }
            await finish(tester);
          });
        }
      }
    }
  });

  test('I is the panel shortcut', () {
    expect(
      DesktopPlayerShortcuts.matchAction(LogicalKeyboardKey.keyI),
      DesktopPlayerShortcutAction.toggleBilibiliPanel,
    );
    expect(
      DesktopPlayerShortcuts.shortcutLabel(
        DesktopPlayerShortcutAction.toggleBilibiliPanel,
      ),
      'I',
    );
  });

  group('the landscape page only wires the panel', () {
    final source = File(
      'lib/screens/video_player_screen.dart',
    ).readAsStringSync();
    int count(String pattern) => RegExp(pattern).allMatches(source).length;

    test('the button is passed for Bilibili videos only', () {
      expect(
        count(
          r'onToggleBilibiliPanel:\s*_isBilibiliVideo\s*\?\s*'
          r'_toggleBilibiliPanel\s*:\s*null',
        ),
        1,
      );
    });

    test('only the button / shortcut and the collapse button write the '
        'remembered state', () {
      expect(count(r'saveBilibiliPlayerPanelOpen'), 0);
      expect(count(r'_bilibiliPanelMemory\.userToggled\('), 1);
      expect(count(r'_bilibiliPanelMemory\.userCollapsed\('), 1);
      expect(count(r'onCollapse:\s*_collapseBilibiliPanel'), 1);
    });

    test('resizing the window follows the room beside the panel and '
        'writes nothing', () {
      final start = source.indexOf('void didChangeMetrics() {');
      expect(start, greaterThan(0));
      // The checkout may use CRLF line endings (Windows).
      final end = source.indexOf(RegExp(r'\r?\n  }\r?\n'), start);
      expect(end, greaterThan(start));
      final metrics = source.substring(start, end);
      expect(metrics, contains('_followRoomForBilibiliPanel();'));
      expect(count(r'_followRoomForBilibiliPanel\(\);'), 1);
      expect(count(r'_bilibiliPanelRoom\.follow\('), 1);
      // Seeded once with the room the page opens with.
      expect(
        count(
          r'_bilibiliPanelRoom = LandscapeSidebarRoom<SidebarType>\(\s*'
          r'fits: _bilibiliPanelMayAutoOpen,',
        ),
        1,
      );
      final follow = source.substring(
        source.indexOf('void _followRoomForBilibiliPanel('),
        source.indexOf(
          '/// Keeps the Bilibili panel in step after the video changed',
        ),
      );
      expect(follow, contains('_bilibiliPanelMemory.remembered'));
      expect(follow, isNot(contains('userToggled')));
      expect(follow, isNot(contains('userCollapsed')));
      expect(follow, isNot(contains('save')));
      // Moving an open phone overlay into a tablet dock changes the current
      // shared slot, while the legacy phone fallback retains its own state.
      expect(follow, contains('if (_usesBilibiliSidebarTabs) {'));
      final phoneFollow = follow.substring(
        follow.indexOf('final fittedBefore'),
      );
      expect(phoneFollow, isNot(contains('_isSubtitleSidebarVisible =')));
    });
  });
}
