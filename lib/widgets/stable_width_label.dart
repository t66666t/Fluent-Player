import 'package:flutter/material.dart';

/// 状态会切换文案的按钮标签。
///
/// 把 [variants] 里所有可能出现的文案叠在同一个 [Stack] 里，由最宽的一条
/// 撑出尺寸，只显示当前的 [text]。所以按钮在「默认 / 进行中 / 已完成 /
/// 失败」之间切换时宽度保持不变，旁边的元素也不会跟着挪位置。
///
/// - 隐藏的文案只参与排版：不绘制、不进无障碍树，也不会被 `find.text` 找到。
/// - 跟随 [DefaultTextStyle] 和系统字体缩放（`MediaQuery.textScalerOf`）。
/// - 外层宽度不够时（窄屏、大字体）单行省略，不会溢出报错。
class StableWidthLabel extends StatelessWidget {
  const StableWidthLabel(
    this.text, {
    super.key,
    required this.variants,
    this.style,
    this.alignment = AlignmentDirectional.center,
  });

  /// 当前要显示的文案。
  final String text;

  /// 这个按钮所有可能出现的文案（可以包含 [text]，重复的会自动去掉）。
  final List<String> variants;

  final TextStyle? style;

  /// 当前文案比最宽文案短时的对齐方式。
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    final defaultStyle = DefaultTextStyle.of(context);
    final effectiveStyle = defaultStyle.style.merge(style);
    final textScaler = MediaQuery.textScalerOf(context);
    final hidden = <String>{...variants}..remove(text);
    return Stack(
      alignment: alignment,
      children: [
        for (final variant in hidden)
          Visibility(
            visible: false,
            maintainSize: true,
            maintainAnimation: true,
            maintainState: true,
            child: RichText(
              text: TextSpan(text: variant, style: effectiveStyle),
              textScaler: textScaler,
              textHeightBehavior: defaultStyle.textHeightBehavior,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.clip,
            ),
          ),
        Text(
          text,
          style: style,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// 按钮图标位：进行中时用转圈替换图标，占位尺寸固定为 [size]，
/// 所以切换时不会改变按钮宽度。
class StableIconSlot extends StatelessWidget {
  const StableIconSlot({
    super.key,
    required this.icon,
    required this.size,
    this.busy = false,
    this.spinnerSize,
    this.spinnerColor,
    this.strokeWidth = 2,
  });

  final IconData icon;
  final double size;
  final bool busy;

  /// 转圈的直径，默认比图标略小。
  final double? spinnerSize;
  final Color? spinnerColor;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    final spinner = spinnerSize ?? size * 0.82;
    return SizedBox.square(
      dimension: size,
      child: Center(
        child: busy
            ? SizedBox.square(
                dimension: spinner,
                child: CircularProgressIndicator(
                  strokeWidth: strokeWidth,
                  color: spinnerColor,
                ),
              )
            : Icon(icon, size: size),
      ),
    );
  }
}
