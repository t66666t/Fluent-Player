import 'package:flutter/material.dart';
import '../services/subtitle_debug_session.dart';
import '../utils/app_toast.dart';

/// Speed control that keeps the hidden subtitle-preset gesture off the tap path.
///
/// A tap must open the speed picker immediately. The preset entry used to be a
/// triple-tap on this same button, and detecting that sequence held every tap
/// for 350ms. Long-press does not compete with the tap, so the picker no
/// longer waits to see whether another tap is coming.
class SubtitleDebugSpeedGateway extends StatelessWidget {
  const SubtitleDebugSpeedGateway({super.key, required this.builder});

  /// [onLongPress] toggles the subtitle-preset entry when that entry is available.
  final Widget Function(BuildContext context, VoidCallback onLongPress) builder;

  static void _togglePresetEntry() {
    if (!SubtitleDebugSession.available) return;
    SubtitleDebugSession.instance.toggle();
    AppToast.show(
      SubtitleDebugSession.instance.enabled
          ? '字幕预设入口已开启 · 状态会自动保存'
          : '已切回原字幕模式 · 状态已保存',
    );
  }

  @override
  Widget build(BuildContext context) => builder(context, _togglePresetEntry);
}
