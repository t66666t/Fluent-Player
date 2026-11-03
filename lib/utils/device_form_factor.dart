import 'dart:ui' show FlutterView;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

enum AppOrientationSurface { mediaLibrary, portraitPlayer, landscapePlayer }

/// 设备形态判定工具。
///
/// 平板判定口径与项目内既有逻辑保持完全一致：
/// - `VideoPlayerScreen._usesAndroidPhoneOrientationBridge` 使用
///   `display.size.shortestSide / devicePixelRatio < 600` 判定手机；
/// - `PortraitVideoScreen._updateOrientations` 使用
///   `size.shortestSide >= 600`（逻辑像素）判定平板。
///
/// 这里统一采用"逻辑最短边 >= 600dp 即平板"。任何无法可靠读取视口的场景
/// （测试环境、视口尚未挂载、pixelRatio 异常）一律按手机处理，宁可多进入
/// 一次竖屏播放页，也不把手机误判为平板。
class DeviceFormFactor {
  const DeviceFormFactor._();

  /// Android/iOS 上逻辑最短边 >= 600dp 判定为平板；其余平台返回 false。
  static bool isTabletLikeDevice() {
    final FlutterView? view = _firstView();
    if (view == null) return false;
    return isTabletLikeView(view);
  }

  static bool isTabletLikeView(FlutterView view) {
    final display = view.display;
    final double physicalShortestSide = display.size.shortestSide;
    final double pixelRatio = display.devicePixelRatio;
    if (physicalShortestSide <= 0 || pixelRatio <= 0) return false;
    return physicalShortestSide / pixelRatio >= 600;
  }

  /// Central orientation matrix for every app surface.
  ///
  /// Phones keep the library and portrait player portrait-only. Tablets let
  /// those surfaces follow the physical display, while the portrait player's
  /// layout remains narrow and centered. The landscape player always requests
  /// a landscape orientation on mobile devices.
  static List<DeviceOrientation> preferredOrientations({
    required AppOrientationSurface surface,
    required bool isMobile,
    required bool isTablet,
  }) {
    if (!isMobile) return const <DeviceOrientation>[];
    if (surface == AppOrientationSurface.landscapePlayer) {
      return const <DeviceOrientation>[
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ];
    }
    if (isTablet) {
      return const <DeviceOrientation>[
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ];
    }
    return const <DeviceOrientation>[
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ];
  }

  static List<DeviceOrientation> preferredOrientationsForSurface({
    required AppOrientationSurface surface,
    required bool isMobile,
  }) {
    return preferredOrientations(
      surface: surface,
      isMobile: isMobile,
      isTablet: isTabletLikeDevice(),
    );
  }

  /// 返回非播放页面（媒体库等）期望的首选方向集合。
  ///
  /// 手机锁定竖屏；平板允许全方向旋转（与竖屏页 `_updateOrientations`
  /// 的平板策略一致）。桌面平台调用方不应使用该返回值。
  static List<DeviceOrientation> homeScreenPreferredOrientations({
    required bool isMobile,
  }) {
    return preferredOrientationsForSurface(
      surface: AppOrientationSurface.mediaLibrary,
      isMobile: isMobile,
    );
  }

  static FlutterView? _firstView() {
    try {
      final Iterable<FlutterView> views =
          WidgetsBinding.instance.platformDispatcher.views;
      return views.isEmpty ? null : views.first;
    } catch (_) {
      return null;
    }
  }
}
