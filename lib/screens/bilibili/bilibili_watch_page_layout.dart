import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../services/bilibili/bilibili_player_panel_memory.dart';
import '../../services/bilibili/bilibili_player_panel_policy.dart';
import '../../services/playback_navigation_service.dart';
import '../../services/settings_service.dart';
import '../../widgets/landscape_sidebar_layout.dart';

/// Where the playback page puts the video, worked out before it exists, so
/// the Bilibili loading page can show the cover exactly there and the switch
/// to the playback page does not move anything.
///
/// The numbers mirror the playback pages: the landscape page's subtitle
/// sidebar sizes and the portrait page's width cap. Tests read the pages'
/// source to keep them equal.

/// Width of the landscape page's subtitle sidebar resize handle.
const double kPlayerSubtitleSidebarResizerWidth = 12.0;

/// Narrowest landscape subtitle sidebar.
const double kPlayerSubtitleSidebarMinWidth = 100.0;

/// Player width a landscape subtitle sidebar always leaves.
const double kPlayerSubtitleSidebarMinRemainingWidth = 24.0;

/// Widest portrait playback page; wider windows center it.
const double kPortraitPlayerMaxWidth = 500.0;

/// The settings and platform facts the playback page's layout depends on.
@immutable
class BilibiliWatchPageShape {
  const BilibiliWatchPageShape({
    required this.landscape,
    this.leftHanded = false,
    this.bilibiliPanelRemembered = false,
    this.subtitleSidebarRemembered = false,
    this.subtitleSidebarWidth = 262.4,
    this.isMobilePlatform = false,
    this.isDesktop = false,
  });

  /// As the playback page opened now would be laid out.
  factory BilibiliWatchPageShape.current() {
    final settings = SettingsService();
    final mobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    return BilibiliWatchPageShape(
      landscape: PlaybackNavigationService.entrySkipsPortraitPlayer,
      leftHanded: settings.isLeftHandedMode,
      bilibiliPanelRemembered: BilibiliPlayerPanelMemory.of(
        settings,
      ).remembered,
      subtitleSidebarRemembered: settings.isLandscapeSubtitleSidebarVisible,
      subtitleSidebarWidth: settings.userSubtitleSidebarWidth,
      isMobilePlatform: mobile,
      isDesktop:
          !kIsWeb &&
          (Platform.isWindows || Platform.isMacOS || Platform.isLinux),
    );
  }

  /// The landscape playback page (else the portrait one).
  final bool landscape;
  final bool leftHanded;
  final bool bilibiliPanelRemembered;
  final bool subtitleSidebarRemembered;
  final double subtitleSidebarWidth;
  final bool isMobilePlatform;

  /// Desktop pages close with a cross, others go back with an arrow.
  final bool isDesktop;

  BilibiliWatchLandscapeLayout landscapeLayout({
    required Size window,
    required EdgeInsets padding,
  }) {
    return bilibiliWatchLandscapeLayout(
      window: window,
      padding: padding,
      leftHanded: leftHanded,
      slot: bilibiliWatchSidebarSlot(
        window: window,
        isMobilePlatform: isMobilePlatform,
        bilibiliPanelRemembered: bilibiliPanelRemembered,
        subtitleSidebarRemembered: subtitleSidebarRemembered,
      ),
      subtitleSidebarWidth: subtitleSidebarWidth,
    );
  }
}

/// The landscape side panel the playback page opens with.
enum BilibiliWatchSidebarSlot { none, bilibili, subtitles }

/// Desktops and tablets share the resizable subtitle slot for both tabs.
/// Phones retain the separate, manually opened Bilibili overlay.
BilibiliWatchSidebarSlot bilibiliWatchSidebarSlot({
  required Size window,
  required bool isMobilePlatform,
  required bool bilibiliPanelRemembered,
  required bool subtitleSidebarRemembered,
}) {
  if (!bilibiliPanelOverlaysVideo(
    isMobilePlatform: isMobilePlatform,
    shortestSide: window.shortestSide,
  )) {
    return subtitleSidebarRemembered
        ? BilibiliWatchSidebarSlot.subtitles
        : BilibiliWatchSidebarSlot.none;
  }
  final target = landscapeDefaultSidebar(
    subtitleSidebarRemembered: subtitleSidebarRemembered,
    isBilibiliVideo: true,
    bilibiliPanelRemembered: bilibiliPanelRemembered,
    allowAutoOpen: bilibiliPanelMayAutoOpen(
      windowWidth: window.width,
      panelWidth: LandscapeSidebarLayout.functionalWidthFor(window),
      isMobilePlatform: isMobilePlatform,
      shortestSide: window.shortestSide,
    ),
  );
  return switch (target) {
    LandscapeSidebarTarget.bilibili => BilibiliWatchSidebarSlot.bilibili,
    LandscapeSidebarTarget.subtitles => BilibiliWatchSidebarSlot.subtitles,
    _ => BilibiliWatchSidebarSlot.none,
  };
}

/// Room the landscape page gives [slot], resize handle included.
double bilibiliWatchSidebarExtent({
  required BilibiliWatchSidebarSlot slot,
  required Size window,
  required double subtitleSidebarWidth,
}) {
  switch (slot) {
    case BilibiliWatchSidebarSlot.none:
      return 0;
    case BilibiliWatchSidebarSlot.bilibili:
      return LandscapeSidebarLayout.functionalWidthFor(window);
    case BilibiliWatchSidebarSlot.subtitles:
      final maxWidth =
          (window.width -
                  kPlayerSubtitleSidebarResizerWidth -
                  kPlayerSubtitleSidebarMinRemainingWidth)
              .clamp(kPlayerSubtitleSidebarMinWidth, window.width);
      return subtitleSidebarWidth.clamp(
            kPlayerSubtitleSidebarMinWidth,
            maxWidth,
          ) +
          kPlayerSubtitleSidebarResizerWidth;
  }
}

/// The landscape playback page's areas, in window coordinates.
@immutable
class BilibiliWatchLandscapeLayout {
  const BilibiliWatchLandscapeLayout({
    required this.surface,
    required this.slot,
    required this.sidebar,
  });

  /// Everything beside the side panel. The playback page centers the video
  /// in it; the loading cover uses that same video rectangle.
  final Rect surface;
  final BilibiliWatchSidebarSlot slot;

  /// The side panel; empty when [slot] is none.
  final Rect sidebar;

  /// The video itself at [aspectRatio], fitted inside [surface].
  Rect videoIn(double aspectRatio) => containedVideoRect(surface, aspectRatio);
}

/// The landscape page: below the top inset (its only safe area), the side
/// panel on the right, or on the left in left-handed mode.
BilibiliWatchLandscapeLayout bilibiliWatchLandscapeLayout({
  required Size window,
  required EdgeInsets padding,
  required bool leftHanded,
  required BilibiliWatchSidebarSlot slot,
  required double subtitleSidebarWidth,
}) {
  final top = padding.top;
  final height = math.max(0.0, window.height - top);
  final extent = math.min(
    window.width,
    bilibiliWatchSidebarExtent(
      slot: slot,
      window: window,
      subtitleSidebarWidth: subtitleSidebarWidth,
    ),
  );
  final surfaceWidth = window.width - extent;
  return BilibiliWatchLandscapeLayout(
    slot: slot,
    surface: Rect.fromLTWH(leftHanded ? extent : 0, top, surfaceWidth, height),
    sidebar: Rect.fromLTWH(leftHanded ? 0 : surfaceWidth, top, extent, height),
  );
}

/// The portrait playback page's video area: at most [kPortraitPlayerMaxWidth]
/// wide and centered, inside the safe area, [aspectRatio] tall.
Rect bilibiliWatchPortraitVideoArea({
  required Size window,
  required EdgeInsets padding,
  required double aspectRatio,
}) {
  final boxWidth = math.min(window.width, kPortraitPlayerMaxWidth);
  final boxLeft = (window.width - boxWidth) / 2;
  final width = math.max(0.0, boxWidth - padding.left - padding.right);
  final ratio = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 16 / 9;
  return Rect.fromLTWH(
    boxLeft + padding.left,
    padding.top,
    width,
    width / ratio,
  );
}

/// [aspectRatio] fitted inside [viewport], centered (how the landscape page
/// sizes the video).
Rect containedVideoRect(Rect viewport, double aspectRatio) {
  final ratio = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 16 / 9;
  if (viewport.width <= 0 || viewport.height <= 0) {
    return Rect.fromCenter(center: viewport.center, width: 0, height: 0);
  }
  var width = viewport.width;
  var height = viewport.height;
  if (ratio > width / height) {
    height = width / ratio;
  } else {
    width = height * ratio;
  }
  return Rect.fromCenter(center: viewport.center, width: width, height: height);
}
