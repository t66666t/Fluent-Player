import 'dart:async';
import 'package:flutter/material.dart';

/// 实验性功能入口：双击检测器
///
/// 使用方式：包裹原有的媒体标题 Widget
///
/// Example:
/// ```dart
/// ExperimentalTapGateway(
///   child: Text('媒体标题'),  // 原有标题 widget 不做任何修改
///   onTrigger: () {
///     Navigator.push(context, MaterialPageRoute(
///       builder: (_) => MusicPlayerScreen(...),
///     ));
///   },
/// )
/// ```
class ExperimentalTapGateway extends StatefulWidget {
  final Widget child;
  final VoidCallback onTrigger;

  /// 需要连续点击的次数
  static const int requiredTapCount = 2;

  /// 超时重置间隔（2秒内无后续点击则归零）
  static const Duration resetTimeout = Duration(seconds: 2);

  const ExperimentalTapGateway({
    super.key,
    required this.child,
    required this.onTrigger,
  });

  @override
  State<ExperimentalTapGateway> createState() =>
      _ExperimentalTapGatewayState();
}

class _ExperimentalTapGatewayState extends State<ExperimentalTapGateway> {
  int _tapCount = 0;
  Timer? _resetTimer;

  void _handleTap() {
    setState(() => _tapCount++);

    // 重置超时计时器
    _resetTimer?.cancel();
    _resetTimer = Timer(ExperimentalTapGateway.resetTimeout, () {
      if (mounted) setState(() => _tapCount = 0);
    });

    // 达到触发条件
    if (_tapCount >= ExperimentalTapGateway.requiredTapCount) {
      _resetTimer?.cancel();
      _tapCount = 0;
      widget.onTrigger();
    }
  }

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _handleTap,
      child: widget.child,
    );
  }
}
