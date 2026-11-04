import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Stable identities for the overlays hosted by a media-library [Stack].
///
/// Box selection inserts and removes an overlay before the mini player while a
/// desktop pointer is down. Without keys, Flutter can reuse the adjacent
/// [Positioned] elements by index, disposing and recreating the mini player's
/// state in the process.
class MediaLibraryOverlayKeys {
  static const emptySpaceHitTarget = ValueKey<String>(
    'media-library-empty-space-hit-target',
  );
  static const boxSelection = ValueKey<String>(
    'media-library-box-selection-overlay',
  );
  static const playbackBottomFill = ValueKey<String>(
    'media-library-playback-bottom-fill',
  );
  static const miniPlaybackCard = ValueKey<String>(
    'media-library-mini-playback-card',
  );
  static const fileDrop = ValueKey<String>('media-library-file-drop-overlay');

  const MediaLibraryOverlayKeys._();
}

/// 播放卡片尺寸数据类
class PlaybackCardDimensions {
  /// 卡片高度
  final double height;

  /// 缩略图尺寸
  final double thumbnailSize;

  /// 标题字体大小
  final double titleFontSize;

  /// 字幕字体大小
  final double subtitleFontSize;

  /// 图标尺寸
  final double iconSize;

  /// 内边距
  final double padding;

  const PlaybackCardDimensions({
    required this.height,
    required this.thumbnailSize,
    required this.titleFontSize,
    required this.subtitleFontSize,
    required this.iconSize,
    required this.padding,
  });
}

/// 响应式布局计算器
class PlaybackCardLayout {
  /// 根据屏幕宽度计算播放卡片的响应式尺寸
  ///
  /// 设备类型判断：
  /// - 手机: 屏幕宽度 < 600dp
  /// - 平板: 600dp <= 屏幕宽度 < 1200dp
  /// - 桌面: 屏幕宽度 >= 1200dp
  static PlaybackCardDimensions calculate(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;

    // 判断设备类型
    final isPhone = screenWidth < 600;
    final isTablet = screenWidth >= 600 && screenWidth < 1200;

    final PlaybackCardDimensions base;
    if (isPhone) {
      // 手机设备
      base = const PlaybackCardDimensions(
        height: 124.0,
        thumbnailSize: 40.0,
        titleFontSize: 14.0,
        subtitleFontSize: 13.0,
        iconSize: 22.0,
        padding: 6.0,
      );
    } else if (isTablet) {
      // 平板设备
      base = const PlaybackCardDimensions(
        height: 146.0,
        thumbnailSize: 48.0,
        titleFontSize: 15.0,
        subtitleFontSize: 14.0,
        iconSize: 26.0,
        padding: 8.0,
      );
    } else {
      // 桌面设备
      base = const PlaybackCardDimensions(
        height: 124.0,
        thumbnailSize: 40.0,
        titleFontSize: 14.0,
        subtitleFontSize: 13.0,
        iconSize: 22.0,
        padding: 6.0,
      );
    }
    // Use exactly the same row metrics as the rendered card. Accessibility
    // text must grow the reservation as well as the card itself.
    final requiredHeight =
        base.padding * 2 +
        titleRowHeight(context, base) +
        subtitleRowHeight(context, base) +
        transportRowHeight(context, base) +
        base.padding * 2 / 3;
    return PlaybackCardDimensions(
      height: math.max(base.height, requiredHeight),
      thumbnailSize: base.thumbnailSize,
      titleFontSize: base.titleFontSize,
      subtitleFontSize: base.subtitleFontSize,
      iconSize: base.iconSize,
      padding: base.padding,
    );
  }

  static double titleRowHeight(
    BuildContext context,
    PlaybackCardDimensions dimensions,
  ) => math.max(
    dimensions.thumbnailSize,
    MediaQuery.textScalerOf(context).scale(dimensions.titleFontSize) * 1.3,
  );

  static double subtitleRowHeight(
    BuildContext context,
    PlaybackCardDimensions dimensions,
  ) => math.max(
    dimensions.iconSize >= 26 ? 28.0 : 24.0,
    MediaQuery.textScalerOf(context).scale(dimensions.subtitleFontSize) * 1.3,
  );

  static double transportRowHeight(
    BuildContext context,
    PlaybackCardDimensions dimensions,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: '00:00 / 00:00',
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(fontSize: 9, height: 1),
      ),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final progressHeight = 27 + painter.height.ceilToDouble();
    painter.dispose();
    return math.max(dimensions.iconSize >= 26 ? 46.0 : 42.0, progressHeight);
  }
}

/// Keeps the mini player and its action-button column in one coordinate system.
///
/// System bars can briefly report a zero bottom inset while a playback route is
/// leaving immersive mode. Stateful hosts stabilize those metrics with
/// StableSystemUiInsetController so settled smaller insets can shrink again.
class PlaybackCardOverlayLayout {
  static const double cardBottomGap = 6.0;
  static const double actionButtonsGap = 16.0;
  static const double actionButtonsEndInset = 16.0;

  static double resolveStableBottomInset(
    MediaQueryData mediaQuery,
    double previousInset,
  ) {
    var resolved = previousInset;
    final candidates = <double>[
      mediaQuery.viewPadding.bottom,
      mediaQuery.padding.bottom,
      mediaQuery.systemGestureInsets.bottom,
    ];
    for (final candidate in candidates) {
      if (candidate > resolved) resolved = candidate;
    }
    return resolved;
  }

  static double cardBottom(double stableBottomInset) {
    return stableBottomInset + cardBottomGap;
  }

  /// Where the mini player sits when a selection bar also occupies the bottom.
  ///
  /// The bar already covers the system inset, so the player only needs to clear
  /// the bar itself. A bar shorter than the resting inset (the inset never
  /// shrinks) must not pull the player back down over that inset.
  static double cardBottomAbove({
    required double stableBottomInset,
    required double selectionBarHeight,
  }) {
    final resting = cardBottom(stableBottomInset);
    if (selectionBarHeight <= 0) return resting;
    final aboveBar = selectionBarHeight + cardBottomGap;
    return aboveBar > resting ? aboveBar : resting;
  }

  /// Space that scrollable content must clear, including system navigation
  /// even when the mini player is closed.
  static double contentBottomPadding({
    required double stableBottomInset,
    required double cardHeight,
    required bool isCardVisible,
    double selectionBarHeight = 0,
  }) {
    if (!isCardVisible) {
      return selectionBarHeight > stableBottomInset
          ? selectionBarHeight
          : stableBottomInset;
    }
    return cardBottomAbove(
          stableBottomInset: stableBottomInset,
          selectionBarHeight: selectionBarHeight,
        ) +
        cardHeight;
  }

  static double actionButtonsBottom({
    required double stableBottomInset,
    required double cardHeight,
    required bool isCardVisible,
  }) {
    if (!isCardVisible) {
      return stableBottomInset + actionButtonsGap;
    }
    return cardBottom(stableBottomInset) + cardHeight + actionButtonsGap;
  }
}

/// Anchors the action-button overlay to the physical bottom-right corner.
/// All safe-area and mini-player offsets are supplied by the child's padding,
/// so Scaffold does not add a second, implicit system-bar displacement.
class PlaybackActionButtonsLocation extends FloatingActionButtonLocation {
  const PlaybackActionButtonsLocation();

  @override
  Offset getOffset(ScaffoldPrelayoutGeometry scaffoldGeometry) {
    return Offset(
      scaffoldGeometry.scaffoldSize.width -
          scaffoldGeometry.floatingActionButtonSize.width -
          PlaybackCardOverlayLayout.actionButtonsEndInset -
          math.max(
            scaffoldGeometry.minViewPadding.right,
            scaffoldGeometry.minInsets.right,
          ),
      scaffoldGeometry.scaffoldSize.height -
          scaffoldGeometry.floatingActionButtonSize.height,
    );
  }
}
