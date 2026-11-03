import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/bilibili/bilibili_player_panel_memory.dart';
import 'package:video_player_app/services/bilibili/bilibili_player_panel_policy.dart';
import 'package:video_player_app/widgets/landscape_sidebar_layout.dart';

/// A landscape page reduced to its panels: what it shows, what it goes back
/// to, and the remembered choices it reads.
class _Page {
  _Page({
    required this.width,
    this.bilibiliRemembered = true,
    this.subtitlesRemembered = false,
    this.isBilibiliVideo = true,
    this.mobile = false,
    this.height = 720,
  }) {
    memory = BilibiliPlayerPanelMemory(
      read: () => bilibiliRemembered,
      write: (open) async {
        writes++;
        bilibiliRemembered = open;
      },
    );
    room = LandscapeSidebarRoom<LandscapeSidebarTarget>(fits: fits);
    shown = landscapeDefaultSidebar(
      subtitleSidebarRemembered: subtitlesRemembered,
      isBilibiliVideo: isBilibiliVideo,
      bilibiliPanelRemembered: bilibiliRemembered,
      allowAutoOpen: fits,
    );
  }

  double width;
  final double height;
  bool bilibiliRemembered;
  bool subtitlesRemembered;
  final bool isBilibiliVideo;
  final bool mobile;
  int writes = 0;
  late final BilibiliPlayerPanelMemory memory;
  late final LandscapeSidebarRoom<LandscapeSidebarTarget> room;
  late LandscapeSidebarTarget shown;
  LandscapeSidebarTarget previous = LandscapeSidebarTarget.none;

  bool get fits {
    final size = Size(width, height);
    return bilibiliPanelMayAutoOpen(
      windowWidth: width,
      panelWidth: LandscapeSidebarLayout.functionalWidthFor(size),
      isMobilePlatform: mobile,
      shortestSide: size.shortestSide,
    );
  }

  LandscapeSidebarTarget defaultFor(bool fits) => landscapeDefaultSidebar(
    subtitleSidebarRemembered: subtitlesRemembered,
    isBilibiliVideo: isBilibiliVideo,
    bilibiliPanelRemembered: bilibiliRemembered,
    allowAutoOpen: fits,
  );

  /// The window is dragged to [to] wide.
  void resize(double to) {
    width = to;
    final next = room.follow(
      fits: fits,
      shown: shown,
      previous: previous,
      bilibili: LandscapeSidebarTarget.bilibili,
      none: LandscapeSidebarTarget.none,
      defaultFor: defaultFor,
    );
    if (next == null) return;
    shown = next.shown;
    previous = next.previous;
  }

  /// The panel button: open or closed by hand, remembered.
  void toggle() {
    final open = memory.userToggled(
      showing: shown == LandscapeSidebarTarget.bilibili,
    );
    previous = LandscapeSidebarTarget.none;
    shown = open
        ? LandscapeSidebarTarget.bilibili
        : landscapeSidebarAfterBilibiliClosed(
            subtitleSidebarRemembered: subtitlesRemembered,
          );
  }

  /// A panel shown over the current one for a while (subtitle manager...).
  void openTool() {
    previous = shown;
    shown = LandscapeSidebarTarget.videoCompose;
  }

  void closeTool() {
    final target = landscapeSidebarAfterClose(
      closing: LandscapeSidebarClosing.toolPanel,
      hasPrevious: previous != LandscapeSidebarTarget.none,
      subtitleSidebarRemembered: subtitlesRemembered,
      isBilibiliVideo: isBilibiliVideo,
      bilibiliPanelRemembered: bilibiliRemembered,
      allowAutoOpen: fits,
    );
    shown = target == LandscapeSidebarTarget.previous ? previous : target;
    previous = LandscapeSidebarTarget.none;
  }
}

const double _wide = 1280;
const double _narrow = 900;

void main() {
  test('the 640 px rule decides: 1280 fits, 900 does not', () {
    expect(_Page(width: _wide).fits, isTrue);
    expect(_Page(width: _narrow).fits, isFalse);
  });

  test('the threshold is window width minus panel width against 640', () {
    // Window widths around the edge, panel width from the page's own rule.
    for (var w = 900.0; w <= 1100; w += 0.5) {
      final page = _Page(width: w);
      final panel = LandscapeSidebarLayout.functionalWidthFor(Size(w, 720));
      expect(page.fits, w - panel >= 640, reason: '$w');
    }
  });

  group('narrow: the panel gives way for now; wide: back as remembered; the '
      'remembered state never changes', () {
    for (final subtitles in <bool>[false, true]) {
      test('subtitle list ${subtitles ? 'left open' : 'closed'}', () {
        final page = _Page(width: _wide, subtitlesRemembered: subtitles);
        expect(page.shown, LandscapeSidebarTarget.bilibili);

        page.resize(_narrow);
        expect(
          page.shown,
          subtitles
              ? LandscapeSidebarTarget.subtitles
              : LandscapeSidebarTarget.none,
        );
        expect(page.bilibiliRemembered, isTrue);

        // Still narrow: nothing moves.
        page.resize(_narrow - 100);
        page.resize(_narrow + 50);
        expect(
          page.shown,
          subtitles
              ? LandscapeSidebarTarget.subtitles
              : LandscapeSidebarTarget.none,
        );

        page.resize(_wide);
        expect(page.shown, LandscapeSidebarTarget.bilibili);

        // Back and forth a few times.
        for (var i = 0; i < 3; i++) {
          page.resize(_narrow);
          expect(page.shown, isNot(LandscapeSidebarTarget.bilibili));
          page.resize(1600);
          expect(page.shown, LandscapeSidebarTarget.bilibili);
        }
        expect(page.writes, 0);
        expect(page.bilibiliRemembered, isTrue);
      });
    }
  });

  test('remembered closed: resizing never opens it', () {
    final page = _Page(width: _wide, bilibiliRemembered: false);
    expect(page.shown, LandscapeSidebarTarget.none);
    page.resize(_narrow);
    expect(page.shown, LandscapeSidebarTarget.none);
    page.resize(_wide);
    expect(page.shown, LandscapeSidebarTarget.none);
    expect(page.writes, 0);
    expect(page.bilibiliRemembered, isFalse);
  });

  test('a window opened narrow shows the panel once it is made wide', () {
    final page = _Page(width: _narrow);
    expect(page.shown, LandscapeSidebarTarget.none);
    page.resize(_wide);
    expect(page.shown, LandscapeSidebarTarget.bilibili);
    expect(page.writes, 0);
  });

  test('opened by hand while narrow: stays when widened, gives way when '
      'narrowed again', () {
    final page = _Page(width: _narrow, bilibiliRemembered: false);
    page.toggle();
    expect(page.shown, LandscapeSidebarTarget.bilibili);
    expect(page.writes, 1);
    expect(page.bilibiliRemembered, isTrue);

    page.resize(_wide);
    expect(page.shown, LandscapeSidebarTarget.bilibili);
    page.resize(_narrow);
    expect(page.shown, LandscapeSidebarTarget.none);
    page.resize(_wide);
    expect(page.shown, LandscapeSidebarTarget.bilibili);
    // Only the button wrote.
    expect(page.writes, 1);
  });

  test('closed by hand while wide: resizing keeps it closed', () {
    final page = _Page(width: _wide);
    page.toggle();
    expect(page.shown, LandscapeSidebarTarget.none);
    page.resize(_narrow);
    page.resize(_wide);
    expect(page.shown, LandscapeSidebarTarget.none);
    expect(page.writes, 1);
    expect(page.bilibiliRemembered, isFalse);
  });

  group('a panel shown over it goes back to what fits when it closes', () {
    for (final subtitles in <bool>[false, true]) {
      final narrowDefault = subtitles
          ? LandscapeSidebarTarget.subtitles
          : LandscapeSidebarTarget.none;
      test('narrowed while it is open '
          '(subtitle list ${subtitles ? 'left open' : 'closed'})', () {
        final page = _Page(width: _wide, subtitlesRemembered: subtitles);
        page.openTool();
        page.resize(_narrow);
        // The tool panel itself stays.
        expect(page.shown, LandscapeSidebarTarget.videoCompose);
        page.closeTool();
        expect(page.shown, narrowDefault);
        page.resize(_wide);
        expect(page.shown, LandscapeSidebarTarget.bilibili);
        expect(page.writes, 0);
      });

      test('opened while narrow, closed after widening '
          '(subtitle list ${subtitles ? 'left open' : 'closed'})', () {
        final page = _Page(width: _wide, subtitlesRemembered: subtitles);
        page.resize(_narrow);
        page.openTool();
        page.resize(_wide);
        expect(page.shown, LandscapeSidebarTarget.videoCompose);
        page.closeTool();
        expect(page.shown, LandscapeSidebarTarget.bilibili);
        expect(page.writes, 0);
      });

      test('narrowed and widened while it is open '
          '(subtitle list ${subtitles ? 'left open' : 'closed'})', () {
        final page = _Page(width: _wide, subtitlesRemembered: subtitles);
        page.openTool();
        page.resize(_narrow);
        page.resize(_wide);
        page.closeTool();
        expect(page.shown, LandscapeSidebarTarget.bilibili);
        expect(page.writes, 0);
      });
    }
  });

  test('other videos: resizing changes nothing', () {
    for (final subtitles in <bool>[false, true]) {
      final page = _Page(
        width: _wide,
        isBilibiliVideo: false,
        subtitlesRemembered: subtitles,
      );
      final before = page.shown;
      page.resize(_narrow);
      expect(page.shown, before);
      page.resize(_wide);
      expect(page.shown, before);
      expect(page.writes, 0);
    }
  });

  test('tablets use the same 640 px rule; phones (panel over the video) are '
      'left alone', () {
    final tablet = _Page(width: 1280, height: 800, mobile: true);
    expect(tablet.shown, LandscapeSidebarTarget.bilibili);
    tablet.resize(900);
    expect(tablet.shown, LandscapeSidebarTarget.none);
    tablet.resize(1280);
    expect(tablet.shown, LandscapeSidebarTarget.bilibili);
    expect(tablet.writes, 0);

    final phone = _Page(width: 844, height: 390, mobile: true);
    phone.toggle(); // Opened by hand over the video.
    expect(phone.shown, LandscapeSidebarTarget.bilibili);
    phone.resize(780);
    phone.resize(844);
    expect(phone.shown, LandscapeSidebarTarget.bilibili);
    expect(phone.writes, 1);
  });

  test('no change asked for when the room did not change', () {
    final room = LandscapeSidebarRoom<LandscapeSidebarTarget>(fits: true);
    LandscapeSidebarTarget defaultFor(bool fits) =>
        fits ? LandscapeSidebarTarget.bilibili : LandscapeSidebarTarget.none;
    final same = room.follow(
      fits: true,
      shown: LandscapeSidebarTarget.bilibili,
      previous: LandscapeSidebarTarget.none,
      bilibili: LandscapeSidebarTarget.bilibili,
      none: LandscapeSidebarTarget.none,
      defaultFor: defaultFor,
    );
    expect(same, isNull);
    expect(room.fits, isTrue);
    final narrowed = room.follow(
      fits: false,
      shown: LandscapeSidebarTarget.subtitles,
      previous: LandscapeSidebarTarget.none,
      bilibili: LandscapeSidebarTarget.bilibili,
      none: LandscapeSidebarTarget.none,
      defaultFor: defaultFor,
    );
    expect(narrowed, isNull);
    expect(room.fits, isFalse);
  });
}
