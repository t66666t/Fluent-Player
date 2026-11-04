import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/player_top_bar.dart';
import 'package:video_player_app/widgets/video_controls_overlay.dart';

const String _longTitle = '一个很长很长的哔哩哔哩视频标题，用来占满顶栏';

const Map<String, IconData> _icons = <String, IconData>{
  'close': Icons.close,
  'settings': Icons.settings,
  'subtitles': Icons.subtitles,
  'edit': Icons.edit_note,
  'compose': Icons.movie_creation_outlined,
  'ocr': Icons.document_scanner_outlined,
  'bilibili': Icons.smart_display_outlined,
  'style': Icons.style,
  'move': Icons.open_with,
  'fullscreen': Icons.fullscreen,
  'sidebar': Icons.menu,
  'aspect': Icons.aspect_ratio,
};

const Map<PlayerTopAction, IconData> _actionIcons = <PlayerTopAction, IconData>{
  PlayerTopAction.settings: Icons.settings,
  PlayerTopAction.subtitleLibrary: Icons.subtitles,
  PlayerTopAction.subtitleEditor: Icons.edit_note,
  PlayerTopAction.videoCompose: Icons.movie_creation_outlined,
  PlayerTopAction.ocrSubtitle: Icons.document_scanner_outlined,
  PlayerTopAction.bilibiliPanel: Icons.smart_display_outlined,
  PlayerTopAction.subtitleStyle: Icons.style,
  PlayerTopAction.moveSubtitles: Icons.open_with,
  PlayerTopAction.fullScreen: Icons.fullscreen,
  PlayerTopAction.subtitleSidebar: Icons.menu,
  PlayerTopAction.aspectRatio: Icons.aspect_ratio,
};

class _WideCase {
  const _WideCase(
    this.size, {
    required this.leftHanded,
    required this.title,
    required this.rects,
  });

  final Size size;
  final bool leftHanded;
  final bool title;
  final Map<String, List<double>> rects;
}

/// Measured on the bar before「更多」existed: wide windows must not change.
///
/// Compared within [_rectTolerance]: text metrics of the aspect chip differ
/// by a few hundredths of a pixel between Flutter versions (the old bar
/// measures the same on each), while any real move is a pixel or more.
const double _rectTolerance = 0.5;

const List<_WideCase> _wideCases = <_WideCase>[
  _WideCase(
    Size(1280.0, 720.0),
    leftHanded: false,
    title: false,
    rects: <String, List<double>>{
      'close': <double>[16.0, 8.0, 36.0, 36.0],
      'settings': <double>[843.5, 8.0, 36.0, 36.0],
      'subtitles': <double>[879.5, 8.0, 36.0, 36.0],
      'edit': <double>[915.5, 8.0, 36.0, 36.0],
      'compose': <double>[951.5, 8.0, 36.0, 36.0],
      'ocr': <double>[987.5, 8.0, 36.0, 36.0],
      'bilibili': <double>[1023.5, 8.0, 36.0, 36.0],
      'style': <double>[1059.5, 8.0, 36.0, 36.0],
      'move': <double>[1095.5, 8.0, 36.0, 36.0],
      'fullscreen': <double>[1131.5, 8.0, 36.0, 36.0],
      'sidebar': <double>[1167.5, 8.0, 36.0, 36.0],
      'aspect': <double>[1203.5, 12.5, 60.5, 27.0],
    },
  ),
  _WideCase(
    Size(1280.0, 720.0),
    leftHanded: false,
    title: true,
    rects: <String, List<double>>{
      'close': <double>[16.0, 8.0, 36.0, 36.0],
      'settings': <double>[843.5, 8.0, 36.0, 36.0],
      'subtitles': <double>[879.5, 8.0, 36.0, 36.0],
      'edit': <double>[915.5, 8.0, 36.0, 36.0],
      'compose': <double>[951.5, 8.0, 36.0, 36.0],
      'ocr': <double>[987.5, 8.0, 36.0, 36.0],
      'bilibili': <double>[1023.5, 8.0, 36.0, 36.0],
      'style': <double>[1059.5, 8.0, 36.0, 36.0],
      'move': <double>[1095.5, 8.0, 36.0, 36.0],
      'fullscreen': <double>[1131.5, 8.0, 36.0, 36.0],
      'sidebar': <double>[1167.5, 8.0, 36.0, 36.0],
      'aspect': <double>[1203.5, 12.5, 60.5, 27.0],
      'title': <double>[60.0, 14.5],
    },
  ),
  _WideCase(
    Size(1280.0, 720.0),
    leftHanded: true,
    title: false,
    rects: <String, List<double>>{
      'close': <double>[1228.0, 8.0, 36.0, 36.0],
      'settings': <double>[16.0, 8.0, 36.0, 36.0],
      'subtitles': <double>[52.0, 8.0, 36.0, 36.0],
      'edit': <double>[88.0, 8.0, 36.0, 36.0],
      'compose': <double>[124.0, 8.0, 36.0, 36.0],
      'ocr': <double>[160.0, 8.0, 36.0, 36.0],
      'bilibili': <double>[196.0, 8.0, 36.0, 36.0],
      'style': <double>[232.0, 8.0, 36.0, 36.0],
      'move': <double>[268.0, 8.0, 36.0, 36.0],
      'fullscreen': <double>[304.0, 8.0, 36.0, 36.0],
      'sidebar': <double>[340.0, 8.0, 36.0, 36.0],
      'aspect': <double>[376.0, 12.5, 60.5, 27.0],
    },
  ),
  _WideCase(
    Size(1280.0, 720.0),
    leftHanded: true,
    title: true,
    rects: <String, List<double>>{
      'close': <double>[1228.0, 8.0, 36.0, 36.0],
      'settings': <double>[16.0, 8.0, 36.0, 36.0],
      'subtitles': <double>[52.0, 8.0, 36.0, 36.0],
      'edit': <double>[88.0, 8.0, 36.0, 36.0],
      'compose': <double>[124.0, 8.0, 36.0, 36.0],
      'ocr': <double>[160.0, 8.0, 36.0, 36.0],
      'bilibili': <double>[196.0, 8.0, 36.0, 36.0],
      'style': <double>[232.0, 8.0, 36.0, 36.0],
      'move': <double>[268.0, 8.0, 36.0, 36.0],
      'fullscreen': <double>[304.0, 8.0, 36.0, 36.0],
      'sidebar': <double>[340.0, 8.0, 36.0, 36.0],
      'aspect': <double>[376.0, 12.5, 60.5, 27.0],
      'title': <double>[862.5, 14.5],
    },
  ),
  _WideCase(
    Size(1920.0, 1080.0),
    leftHanded: false,
    title: false,
    rects: <String, List<double>>{
      'close': <double>[16.0, 8.0, 36.0, 36.0],
      'settings': <double>[1483.5, 8.0, 36.0, 36.0],
      'subtitles': <double>[1519.5, 8.0, 36.0, 36.0],
      'edit': <double>[1555.5, 8.0, 36.0, 36.0],
      'compose': <double>[1591.5, 8.0, 36.0, 36.0],
      'ocr': <double>[1627.5, 8.0, 36.0, 36.0],
      'bilibili': <double>[1663.5, 8.0, 36.0, 36.0],
      'style': <double>[1699.5, 8.0, 36.0, 36.0],
      'move': <double>[1735.5, 8.0, 36.0, 36.0],
      'fullscreen': <double>[1771.5, 8.0, 36.0, 36.0],
      'sidebar': <double>[1807.5, 8.0, 36.0, 36.0],
      'aspect': <double>[1843.5, 12.5, 60.5, 27.0],
    },
  ),
  _WideCase(
    Size(1920.0, 1080.0),
    leftHanded: false,
    title: true,
    rects: <String, List<double>>{
      'close': <double>[16.0, 8.0, 36.0, 36.0],
      'settings': <double>[1483.5, 8.0, 36.0, 36.0],
      'subtitles': <double>[1519.5, 8.0, 36.0, 36.0],
      'edit': <double>[1555.5, 8.0, 36.0, 36.0],
      'compose': <double>[1591.5, 8.0, 36.0, 36.0],
      'ocr': <double>[1627.5, 8.0, 36.0, 36.0],
      'bilibili': <double>[1663.5, 8.0, 36.0, 36.0],
      'style': <double>[1699.5, 8.0, 36.0, 36.0],
      'move': <double>[1735.5, 8.0, 36.0, 36.0],
      'fullscreen': <double>[1771.5, 8.0, 36.0, 36.0],
      'sidebar': <double>[1807.5, 8.0, 36.0, 36.0],
      'aspect': <double>[1843.5, 12.5, 60.5, 27.0],
      'title': <double>[60.0, 14.5],
    },
  ),
  _WideCase(
    Size(1920.0, 1080.0),
    leftHanded: true,
    title: false,
    rects: <String, List<double>>{
      'close': <double>[1868.0, 8.0, 36.0, 36.0],
      'settings': <double>[16.0, 8.0, 36.0, 36.0],
      'subtitles': <double>[52.0, 8.0, 36.0, 36.0],
      'edit': <double>[88.0, 8.0, 36.0, 36.0],
      'compose': <double>[124.0, 8.0, 36.0, 36.0],
      'ocr': <double>[160.0, 8.0, 36.0, 36.0],
      'bilibili': <double>[196.0, 8.0, 36.0, 36.0],
      'style': <double>[232.0, 8.0, 36.0, 36.0],
      'move': <double>[268.0, 8.0, 36.0, 36.0],
      'fullscreen': <double>[304.0, 8.0, 36.0, 36.0],
      'sidebar': <double>[340.0, 8.0, 36.0, 36.0],
      'aspect': <double>[376.0, 12.5, 60.5, 27.0],
    },
  ),
  _WideCase(
    Size(1920.0, 1080.0),
    leftHanded: true,
    title: true,
    rects: <String, List<double>>{
      'close': <double>[1868.0, 8.0, 36.0, 36.0],
      'settings': <double>[16.0, 8.0, 36.0, 36.0],
      'subtitles': <double>[52.0, 8.0, 36.0, 36.0],
      'edit': <double>[88.0, 8.0, 36.0, 36.0],
      'compose': <double>[124.0, 8.0, 36.0, 36.0],
      'ocr': <double>[160.0, 8.0, 36.0, 36.0],
      'bilibili': <double>[196.0, 8.0, 36.0, 36.0],
      'style': <double>[232.0, 8.0, 36.0, 36.0],
      'move': <double>[268.0, 8.0, 36.0, 36.0],
      'fullscreen': <double>[304.0, 8.0, 36.0, 36.0],
      'sidebar': <double>[340.0, 8.0, 36.0, 36.0],
      'aspect': <double>[376.0, 12.5, 60.5, 27.0],
      'title': <double>[1502.5, 14.5],
    },
  ),
  _WideCase(
    Size(1024.0, 600.0),
    leftHanded: false,
    title: false,
    rects: <String, List<double>>{
      'close': <double>[16.0, 7.798, 35.093, 35.093],
      'settings': <double>[598.104, 7.798, 35.093, 35.093],
      'subtitles': <double>[633.197, 7.798, 35.093, 35.093],
      'edit': <double>[668.29, 7.798, 35.093, 35.093],
      'compose': <double>[703.383, 7.798, 35.093, 35.093],
      'ocr': <double>[738.475, 7.798, 35.093, 35.093],
      'bilibili': <double>[773.568, 7.798, 35.093, 35.093],
      'style': <double>[808.661, 7.798, 35.093, 35.093],
      'move': <double>[843.754, 7.798, 35.093, 35.093],
      'fullscreen': <double>[878.847, 7.798, 35.093, 35.093],
      'sidebar': <double>[913.939, 7.798, 35.093, 35.093],
      'aspect': <double>[949.032, 11.971, 58.968, 26.748],
    },
  ),
  _WideCase(
    Size(1024.0, 600.0),
    leftHanded: false,
    title: true,
    rects: <String, List<double>>{
      'close': <double>[16.0, 7.798, 35.093, 35.093],
      'settings': <double>[598.104, 7.798, 35.093, 35.093],
      'subtitles': <double>[633.197, 7.798, 35.093, 35.093],
      'edit': <double>[668.29, 7.798, 35.093, 35.093],
      'compose': <double>[703.383, 7.798, 35.093, 35.093],
      'ocr': <double>[738.475, 7.798, 35.093, 35.093],
      'bilibili': <double>[773.568, 7.798, 35.093, 35.093],
      'style': <double>[808.661, 7.798, 35.093, 35.093],
      'move': <double>[843.754, 7.798, 35.093, 35.093],
      'fullscreen': <double>[878.847, 7.798, 35.093, 35.093],
      'sidebar': <double>[913.939, 7.798, 35.093, 35.093],
      'aspect': <double>[949.032, 11.971, 58.968, 26.748],
      'title': <double>[58.891, 13.845],
    },
  ),
  _WideCase(
    Size(1024.0, 600.0),
    leftHanded: true,
    title: false,
    rects: <String, List<double>>{
      'close': <double>[972.907, 7.798, 35.093, 35.093],
      'settings': <double>[16.0, 7.798, 35.093, 35.093],
      'subtitles': <double>[51.093, 7.798, 35.093, 35.093],
      'edit': <double>[86.186, 7.798, 35.093, 35.093],
      'compose': <double>[121.278, 7.798, 35.093, 35.093],
      'ocr': <double>[156.371, 7.798, 35.093, 35.093],
      'bilibili': <double>[191.464, 7.798, 35.093, 35.093],
      'style': <double>[226.557, 7.798, 35.093, 35.093],
      'move': <double>[261.65, 7.798, 35.093, 35.093],
      'fullscreen': <double>[296.742, 7.798, 35.093, 35.093],
      'sidebar': <double>[331.835, 7.798, 35.093, 35.093],
      'aspect': <double>[366.928, 11.971, 58.968, 26.748],
    },
  ),
  _WideCase(
    Size(1024.0, 600.0),
    leftHanded: true,
    title: true,
    rects: <String, List<double>>{
      'close': <double>[972.907, 7.798, 35.093, 35.093],
      'settings': <double>[16.0, 7.798, 35.093, 35.093],
      'subtitles': <double>[51.093, 7.798, 35.093, 35.093],
      'edit': <double>[86.186, 7.798, 35.093, 35.093],
      'compose': <double>[121.278, 7.798, 35.093, 35.093],
      'ocr': <double>[156.371, 7.798, 35.093, 35.093],
      'bilibili': <double>[191.464, 7.798, 35.093, 35.093],
      'style': <double>[226.557, 7.798, 35.093, 35.093],
      'move': <double>[261.65, 7.798, 35.093, 35.093],
      'fullscreen': <double>[296.742, 7.798, 35.093, 35.093],
      'sidebar': <double>[331.835, 7.798, 35.093, 35.093],
      'aspect': <double>[366.928, 11.971, 58.968, 26.748],
      'title': <double>[607.609, 13.845],
    },
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, int> calls;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
    calls = <String, int>{};
  });

  tearDown(() => SettingsService().isLeftHandedMode = false);

  VoidCallback count(String name) =>
      () => calls[name] = (calls[name] ?? 0) + 1;

  Future<void> pumpBar(
    WidgetTester tester, {
    required Size size,
    String title = _longTitle,
    bool leftHanded = false,
    bool aiChat = false,
    bool showSubtitles = false,
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
              showSubtitles: showSubtitles,
              onToggleSubtitles: () {},
              onMoveSubtitles: count('move'),
              isLongPressing: false,
              longPressFeedbackText: '',
              onLongPressStart: () => false,
              onLongPressEnd: () {},
              subtitleEntries: const [],
              subtitleStyle: const SubtitleStyle(),
              subtitleAlignment: Alignment.bottomCenter,
              onEnterSubtitleDragMode: () {},
              allowPlayWhenUninitialized: true,
              onToggleBilibiliPanel: count('bilibili'),
              mediaTitle: title,
              onOpenSettings: count('settings'),
              onOpenSubtitleManager: count('subtitles'),
              onOpenSubtitleEditor: count('edit'),
              onOpenVideoCompose: count('compose'),
              onOpenOcrSubtitle: count('ocr'),
              onOpenAiChat: aiChat ? count('aiChat') : null,
              onToggleFloatingSubtitleSettings: count('style'),
              onToggleSidebar: count('sidebar'),
              onToggleFullScreen: count('fullscreen'),
              onOpenAspectRatio: count('aspect'),
              aspectRatioLabel: '原始',
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'hidden subtitles disable the original move action without a toast',
    (tester) async {
      await pumpBar(tester, size: const Size(1280, 720));
      final move = find.byKey(
        const ValueKey('video-controls-top-move-subtitles'),
      );
      expect(tester.widget<IconButton>(move).onPressed, isNull);
      expect(tester.widget<IconButton>(move).tooltip, contains('先显示字幕'));
      await tester.tap(move);
      await tester.pump();
      expect(calls['move'], isNull);
      await pumpBar(tester, size: const Size(1280, 720), showSubtitles: true);
      expect(tester.widget<IconButton>(move).onPressed, isNotNull);
      await tester.tap(move);
      await tester.pump();
      expect(calls['move'], 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
      expect(tester.takeException(), isNull);
    },
  );

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 40));
  }

  Rect rectOf(WidgetTester tester, IconData icon) {
    final finder = find.byIcon(icon);
    return icon == Icons.aspect_ratio
        ? tester.getRect(
            find.ancestor(of: finder, matching: find.byType(Material)).first,
          )
        : tester.getRect(
            find.ancestor(of: finder, matching: find.byType(IconButton)).first,
          );
  }

  void press(
    WidgetTester tester,
    LogicalKeyboardKey key,
    PhysicalKeyboardKey p,
  ) {
    final state = tester.state<VideoControlsOverlayState>(
      find.byType(VideoControlsOverlay),
    );
    final node = FocusNode();
    addTearDown(node.dispose);
    state.handleKeyEvent(
      node,
      KeyDownEvent(physicalKey: p, logicalKey: key, timeStamp: Duration.zero),
    );
    state.handleKeyEvent(
      node,
      KeyUpEvent(physicalKey: p, logicalKey: key, timeStamp: Duration.zero),
    );
  }

  /// The actions shown as buttons in the bar.
  Set<PlayerTopAction> shown() => <PlayerTopAction>{
    for (final entry in _actionIcons.entries)
      if (find.byIcon(entry.value).evaluate().isNotEmpty) entry.key,
  };

  group('wide windows: the bar stays exactly as it was', () {
    for (final wide in _wideCases) {
      testWidgets('${wide.size.width.toInt()}x${wide.size.height.toInt()}'
          '${wide.leftHanded ? ', left-handed' : ''}'
          '${wide.title ? ', with title' : ''}', (tester) async {
        await pumpBar(
          tester,
          size: wide.size,
          title: wide.title ? _longTitle : '',
          leftHanded: wide.leftHanded,
        );
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const ValueKey('video-controls-top-more')),
          findsNothing,
        );
        // Same buttons, same order, same place and size.
        for (final entry in wide.rects.entries) {
          final rect = entry.key == 'title'
              ? tester.getRect(find.text(_longTitle))
              : rectOf(tester, _icons[entry.key]!);
          final want = entry.value;
          expect(
            rect.left,
            closeTo(want[0], _rectTolerance),
            reason: entry.key,
          );
          expect(rect.top, closeTo(want[1], _rectTolerance), reason: entry.key);
          if (want.length > 2) {
            expect(
              rect.width,
              closeTo(want[2], _rectTolerance),
              reason: entry.key,
            );
            expect(
              rect.height,
              closeTo(want[3], _rectTolerance),
              reason: entry.key,
            );
          }
        }
        // The back button and ten buttons (the aspect chip is no IconButton).
        expect(
          find.descendant(
            of: find.byType(PlayerTopBar),
            matching: find.byType(IconButton),
          ),
          findsNWidgets(11),
        );
        await finish(tester);
      });
    }
  });

  group('640x360 with the subtitle list docked', () {
    // The video area beside a docked list (262.4 + its 12 handle); tests
    // run as a desktop, so the full-screen button's 32 is added on top as
    // on the phone bar without it.
    const docked = Size(640 - 274.4 + 32, 360);

    for (final leftHanded in const <bool>[false, true]) {
      testWidgets('the title stays visible, rare tools go into 更多 first'
          '${leftHanded ? ' (left-handed)' : ''}', (tester) async {
        await pumpBar(tester, size: docked, leftHanded: leftHanded);
        expect(tester.takeException(), isNull);
        // The visible slot, not the full string: the text itself is wider
        // and scrolls inside this rect.
        final title = tester.getRect(
          find.byKey(const ValueKey('video-controls-title')),
        );
        expect(
          title.width,
          greaterThanOrEqualTo(kPlayerTopTitleMinWidth - 0.5),
        );
        expect(title.left, greaterThanOrEqualTo(0));
        expect(title.right, lessThanOrEqualTo(docked.width));
        final text = tester.widget<Text>(find.text(_longTitle));
        expect(text.overflow, TextOverflow.visible);
        expect(text.maxLines, 1);
        final scrollable = find.descendant(
          of: find.byKey(const ValueKey('video-controls-title')),
          matching: find.byType(Scrollable),
        );
        final position = tester.state<ScrollableState>(scrollable).position;
        expect(position.maxScrollExtent, greaterThan(0));
        position.jumpTo(position.maxScrollExtent);
        await tester.pump();
        final scrolled = tester.getRect(find.text(_longTitle));
        expect(scrolled.right, closeTo(title.right, 1.5));

        final more = find.byKey(const ValueKey('video-controls-top-more'));
        expect(more, findsOneWidget);
        final visible = shown();
        final hidden = _actionIcons.keys.toSet().difference(visible);
        expect(
          hidden,
          containsAll(<PlayerTopAction>[
            PlayerTopAction.videoCompose,
            PlayerTopAction.ocrSubtitle,
          ]),
        );
        // Exactly the first ones of the priority list went.
        expect(
          hidden,
          kPlayerTopActionCollapseOrder
              .where(_actionIcons.containsKey)
              .take(hidden.length)
              .toSet(),
        );
        expect(visible, contains(PlayerTopAction.bilibiliPanel));
        expect(visible, contains(PlayerTopAction.subtitleSidebar));
        for (final action in visible) {
          final rect = rectOf(tester, _actionIcons[action]!);
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(docked.width + 0.01));
          expect(rect.overlaps(title), isFalse, reason: action.name);
        }

        // Every item of the menu has its icon and its text.
        await tester.tap(more);
        await tester.pumpAndSettle();
        for (final action in hidden) {
          final item = find.byKey(
            ValueKey('video-controls-more-${action.name}'),
          );
          expect(item, findsOneWidget);
          expect(
            find.descendant(
              of: item,
              matching: find.byIcon(_actionIcons[action]!),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(of: item, matching: find.byType(Text)),
            findsOneWidget,
          );
        }
        expect(find.textContaining('合成视频'), findsOneWidget);

        // A menu item does what its button did.
        await tester.tap(find.textContaining('合成视频'));
        await tester.pumpAndSettle();
        expect(calls['compose'], 1);
        await tester.tap(more);
        await tester.pumpAndSettle();
        await tester.tap(find.textContaining('识别画面字幕（OCR）'));
        await tester.pumpAndSettle();
        expect(calls['ocr'], 1);

        // Their shortcuts still work.
        press(tester, LogicalKeyboardKey.keyV, PhysicalKeyboardKey.keyV);
        press(tester, LogicalKeyboardKey.keyO, PhysicalKeyboardKey.keyO);
        expect(calls['compose'], 2);
        expect(calls['ocr'], 2);
        await finish(tester);
      });
    }

    testWidgets('a bar too narrow even for Bilibili: its menu item and the I '
        'key still open the panel', (tester) async {
      await pumpBar(tester, size: const Size(260, 360));
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.smart_display_outlined), findsNothing);
      expect(
        tester.getRect(find.text(_longTitle)).width,
        greaterThanOrEqualTo(kPlayerTopTitleMinWidth - 0.5),
      );
      press(tester, LogicalKeyboardKey.keyI, PhysicalKeyboardKey.keyI);
      expect(calls['bilibili'], 1);
      await tester.tap(find.byKey(const ValueKey('video-controls-top-more')));
      await tester.pumpAndSettle();
      final item = find.byKey(
        const ValueKey('video-controls-more-bilibiliPanel'),
      );
      expect(
        find.descendant(
          of: item,
          matching: find.byIcon(Icons.smart_display_outlined),
        ),
        findsOneWidget,
      );
      await tester.tap(item);
      await tester.pumpAndSettle();
      expect(calls['bilibili'], 2);
      await finish(tester);
    });
  });

  testWidgets('AI 对话 is a peer action in 更多 and opens once', (tester) async {
    await pumpBar(tester, size: const Size(397, 360), aiChat: true);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('video-controls-top-more')));
    await tester.pumpAndSettle();
    final action = find.byKey(const ValueKey('video-controls-more-aiChat'));
    expect(action, findsOneWidget);
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(calls['aiChat'], 1);
    await finish(tester);
  });

  group('which buttons move into 更多', () {
    PlayerTopBarAction entry(PlayerTopAction action) => PlayerTopBarAction(
      action: action,
      button: const SizedBox(width: 30),
      width: 30,
      icon: Icons.circle,
      label: action.name,
      onSelected: () {},
    );
    final all = <PlayerTopBarAction>[
      for (final action in PlayerTopAction.values) entry(action),
    ];

    test('nothing when everything fits', () {
      expect(
        playerTopActionsToCollapse(
          available: 30.0 * all.length + 100,
          fixedWidth: 100,
          actions: all,
          moreButtonWidth: 30,
        ),
        isEmpty,
      );
    });

    test('in the order of the priority table, room made for 更多', () {
      // Two buttons too many: three go (one more for the 更多 button).
      final collapsed = playerTopActionsToCollapse(
        available: 30.0 * (all.length - 2) + 100,
        fixedWidth: 100,
        actions: all,
        moreButtonWidth: 30,
      );
      expect(collapsed, kPlayerTopActionCollapseOrder.take(3).toSet());
      expect(
        collapsed,
        containsAll(<PlayerTopAction>[
          PlayerTopAction.videoCompose,
          PlayerTopAction.ocrSubtitle,
        ]),
      );
    });

    test('the table names every button once; playback, subtitle and '
        'Bilibili buttons are last', () {
      expect(
        kPlayerTopActionCollapseOrder.toSet(),
        PlayerTopAction.values.toSet(),
      );
      expect(
        kPlayerTopActionCollapseOrder.length,
        PlayerTopAction.values.length,
      );
      final last = kPlayerTopActionCollapseOrder.skip(
        kPlayerTopActionCollapseOrder.length - 4,
      );
      expect(last, <PlayerTopAction>[
        PlayerTopAction.subtitleLibrary,
        PlayerTopAction.bilibiliPanel,
        PlayerTopAction.subtitleSidebar,
        PlayerTopAction.fullScreen,
      ]);
    });
  });
}
