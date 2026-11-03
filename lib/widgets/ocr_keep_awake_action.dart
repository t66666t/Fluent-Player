import 'package:flutter/material.dart';

/// The header decides how much text fits using its actual available width.
class OcrKeepAwakeAction extends StatelessWidget {
  const OcrKeepAwakeAction({
    super.key,
    required this.checked,
    required this.active,
    required this.compact,
    required this.showLabel,
    required this.height,
    required this.onChanged,
  });

  final bool checked;
  final bool active;
  final bool compact;
  final bool showLabel;
  final double height;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final accent = active ? const Color(0xFF6CE0C7) : const Color(0xFF8FB8FF);
    final status = active
        ? 'OCR 处理中，正在保持亮屏'
        : checked
        ? '已勾选，等待 OCR 任务'
        : '未勾选';
    const hint = '仅在 OCR 任务运行期间保持亮屏，完成、取消或失败后自动恢复';
    final radius = BorderRadius.circular(height / 2);

    return Semantics(
      label: '处理时不息屏',
      checked: checked,
      value: status,
      hint: hint,
      onTap: () => onChanged(!checked),
      child: Tooltip(
        message: '处理时不息屏 · $status\n$hint',
        excludeFromSemantics: true,
        child: ExcludeSemantics(
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => onChanged(!checked),
              borderRadius: radius,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                height: height,
                padding: EdgeInsets.symmetric(horizontal: showLabel ? 9 : 7),
                decoration: BoxDecoration(
                  color: checked
                      ? accent.withValues(alpha: active ? 0.13 : 0.08)
                      : Colors.white.withValues(alpha: 0.03),
                  borderRadius: radius,
                  border: Border.all(
                    color: checked
                        ? accent.withValues(alpha: 0.5)
                        : Colors.white.withValues(alpha: 0.14),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      checked
                          ? Icons.check_box_rounded
                          : Icons.check_box_outline_blank_rounded,
                      size: 18,
                      color: checked ? accent : Colors.white60,
                    ),
                    if (showLabel) ...[
                      const SizedBox(width: 5),
                      Text(
                        compact ? '亮屏' : '处理时不息屏',
                        maxLines: 1,
                        softWrap: false,
                        style: TextStyle(
                          color: checked ? accent : Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
