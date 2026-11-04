import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// 把系统栏安全区稳定成可以长期使用的"预留值"。
///
/// Android 从沉浸式横屏播放页退回竖屏播放页时，状态栏和底部手势条/导航栏会带动画
/// 重新出现，[MediaQueryData.padding] 会在若干帧里从 0 变到最终值。如果直接把这个
/// 实时值交给 [SafeArea]，底部字幕面板的可用高度会被逐帧压缩——视觉上就是"被触控条
/// 挤了一下"。
///
/// 用法：State 里持有本控制器，在 `build` 中调用 [observe] 取得稳定安全区，交给
/// `SafeArea.minimum`（`SafeArea` 会取实时值与 minimum 的较大者，因此预留只会变多、
/// 不会被动画中的小值覆盖）。策略：
///
///  * 安全区变大时立即采用（例如手势条更高、切到三键导航），不会等到超时；
///  * 安全区变小时先保持原值，只有实时值稳定 [shrinkSettleDelay] 之后才收窄，
///    因为系统栏进/出场与键盘收起产生的都是短时瞬态值。
///
/// 效果等同于提前把状态栏与触控条的位置预留好：系统栏出现/消失不再改变页面几何，
/// 同时预留量来自设备真实上报的安全区，不会比设备实际需要的更大。
class StableSystemUiInsetController {
  StableSystemUiInsetController({
    this.onChanged,
    this.includeSystemGestureInsets = false,
  });

  final bool includeSystemGestureInsets;

  /// 预留值因实时安全区稳定下来而收窄时回调，用于触发页面重建。
  final VoidCallback? onChanged;

  /// 实时安全区变小后需要稳定多久才收窄的等待时长，需要覆盖系统栏动画与
  /// 键盘收起动画的时长。
  static const Duration shrinkSettleDelay = Duration(milliseconds: 700);

  double _reservedTop = 0;
  double _reservedBottom = 0;
  double _observedTop = 0;
  double _observedBottom = 0;
  bool _initialized = false;
  Size? _viewportSize;
  double? _devicePixelRatio;
  Timer? _shrinkTimer;

  /// 当前用于布局的稳定竖直安全区（top/bottom）。
  double get reservedTop => _reservedTop;
  double get reservedBottom => _reservedBottom;

  /// 记录实时安全区并返回当前应当用于布局的稳定安全区。
  ///
  /// 返回值可直接传给 `SafeArea.minimum`。
  EdgeInsets observe(MediaQueryData mediaQuery, {bool active = true}) {
    if (!active) {
      pause();
      return EdgeInsets.only(top: _reservedTop, bottom: _reservedBottom);
    }
    // Rotation, split view and display changes create a new coordinate system.
    // A reservation from the previous window must not survive in this one.
    if (_viewportSize != mediaQuery.size ||
        _devicePixelRatio != mediaQuery.devicePixelRatio) {
      pause();
      _initialized = false;
      _viewportSize = mediaQuery.size;
      _devicePixelRatio = mediaQuery.devicePixelRatio;
    }
    final EdgeInsets padding = mediaQuery.padding;
    final EdgeInsets viewPadding = mediaQuery.viewPadding;
    // viewPadding 不会因为键盘弹出而清零，用它作为"系统栏真实占位"的更稳来源。
    _apply(
      math.max(padding.top, viewPadding.top),
      math.max(
        math.max(padding.bottom, viewPadding.bottom),
        includeSystemGestureInsets ? mediaQuery.systemGestureInsets.bottom : 0,
      ),
    );
    return EdgeInsets.only(top: _reservedTop, bottom: _reservedBottom);
  }

  void _apply(double top, double bottom) {
    if (!_initialized) {
      // 首帧直接采用实时值：页面刚创建时不应该凭空多出一块留白。
      _reservedTop = top;
      _reservedBottom = bottom;
      _observedTop = top;
      _observedBottom = bottom;
      _initialized = true;
      return;
    }

    if (top > _reservedTop || bottom > _reservedBottom) {
      // 变大立即采用：设备上报的真实安全区不会在动画中途"变大到错误值"，
      // 即便中途变大也只是把预留调大，不会产生反复抖动。
      _reservedTop = math.max(_reservedTop, top);
      _reservedBottom = math.max(_reservedBottom, bottom);
    }

    if (top == _observedTop &&
        bottom == _observedBottom &&
        (_shrinkTimer != null ||
            (top >= _reservedTop && bottom >= _reservedBottom))) {
      // 实时值没有变化，已安排的收窄回调继续等待即可。
      return;
    }
    _observedTop = top;
    _observedBottom = bottom;
    _shrinkTimer?.cancel();
    _shrinkTimer = null;

    if (top >= _reservedTop && bottom >= _reservedBottom) {
      // 实时值已经不小于预留值，无需收窄。
      return;
    }
    _shrinkTimer = Timer(shrinkSettleDelay, _adoptObserved);
  }

  void _adoptObserved() {
    _shrinkTimer = null;
    if (_observedTop == _reservedTop && _observedBottom == _reservedBottom) {
      return;
    }
    _reservedTop = _observedTop;
    _reservedBottom = _observedBottom;
    onChanged?.call();
  }

  void dispose() {
    pause();
  }

  /// Covered routes do not learn the immersive player's insets, nor finish a
  /// pending shrink while their own system bars are not on screen.
  void pause() {
    _shrinkTimer?.cancel();
    _shrinkTimer = null;
  }
}
