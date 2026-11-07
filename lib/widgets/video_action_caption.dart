import 'package:flutter/widgets.dart';

import '../theme/app_tokens.dart';
import 'video_action_rail_layout.dart';

/// A snug caption that disappears into the library's plain background.
class VideoActionCaption extends StatelessWidget {
  const VideoActionCaption({
    super.key,
    required this.label,
    required this.fontSize,
  });

  final String label;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final inherited = DefaultTextStyle.of(context).style;
    final scaledFont = MediaQuery.textScalerOf(context).scale(fontSize);
    final lineHeight = scaledFont * VideoActionRailLayout.labelLineHeight;
    final text = Text(
      label,
      key: ValueKey('action-label-$label'),
      maxLines: 1,
      softWrap: false,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: fontSize,
        height: VideoActionRailLayout.labelLineHeight,
        leadingDistribution: TextLeadingDistribution.even,
        fontWeight: FontWeight.w500,
        letterSpacing: 0,
        color: AppTokens.text1,
      ),
    );

    return DecoratedBox(
      key: ValueKey('action-label-backplate-$label'),
      decoration: const BoxDecoration(
        color: AppTokens.bgBase,
        borderRadius: BorderRadius.all(Radius.circular(3)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: VideoActionRailLayout.labelHorizontalPadding,
          vertical: VideoActionRailLayout.labelVerticalPadding,
        ),
        // Align the Noto CJK ink center instead of the font's line box, so
        // captions remain visually centered at different text scales without
        // moving the backplate or changing the hit target.
        child: inherited.fontFamily == 'Noto Sans SC'
            ? SizedBox(
                height: lineHeight,
                child: Baseline(
                  baseline: lineHeight / 2 + scaledFont * 0.385,
                  baselineType: TextBaseline.alphabetic,
                  child: text,
                ),
              )
            : text,
      ),
    );
  }
}
