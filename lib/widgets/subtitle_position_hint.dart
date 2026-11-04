import 'package:flutter/material.dart';

/// Position-editing hint. When exit is offered, the entire pill is tappable.
class SubtitlePositionHint extends StatelessWidget {
  const SubtitlePositionHint({super.key, this.onExit, this.errorMessage});

  final VoidCallback? onExit;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.black54,
    borderRadius: BorderRadius.circular(20),
    child: InkWell(
      onTap: onExit,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text(
          errorMessage ?? (onExit == null ? '拖拽调整位置' : '拖拽调整位置 (点击退出)'),
          style: const TextStyle(color: Colors.white),
        ),
      ),
    ),
  );
}
