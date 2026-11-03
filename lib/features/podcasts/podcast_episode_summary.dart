import 'package:flutter/material.dart';
import '../../theme/app_tokens.dart';
import 'podcast_typography.dart';

/// Folded description. Only the trailing control expands or collapses it.
///
/// The copy itself is not a button, so a tap on an episode summary reaches
/// the surrounding row and opens that episode.
class PodcastEpisodeSummary extends StatefulWidget {
  const PodcastEpisodeSummary({
    super.key,
    required this.text,
    this.enabled = true,
    this.style,
    this.expanded,
    this.onExpandedChanged,
    this.semanticLabel = '节目简介',
    this.collapsedLines = 3,
  });

  final String text;
  final bool enabled;
  final TextStyle? style;
  final bool? expanded;
  final ValueChanged<bool>? onExpandedChanged;
  final String semanticLabel;
  final int collapsedLines;

  @override
  State<PodcastEpisodeSummary> createState() => _PodcastEpisodeSummaryState();
}

class _PodcastEpisodeSummaryState extends State<PodcastEpisodeSummary> {
  bool _expanded = false;
  ({
    String text,
    TextStyle style,
    TextScaler scaler,
    TextDirection direction,
    double width,
    int lines,
  })?
  _measurement;
  bool _overflows = false;

  @override
  void didUpdateWidget(covariant PodcastEpisodeSummary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _expanded = false;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      // Reading copy uses Noto Sans SC Regular. Merging the caller's style
      // afterwards keeps a page-specific size or line height.
      final style = DefaultTextStyle.of(context).style
          .merge(PodcastType.prose)
          .copyWith(fontSize: 12, height: 1.5, color: AppTokens.text2)
          .merge(widget.style);
      final measurement = (
        text: widget.text,
        style: style,
        scaler: MediaQuery.textScalerOf(context),
        direction: Directionality.of(context),
        width: bounds.maxWidth,
        lines: widget.collapsedLines,
      );
      // Expansion and row updates don't change the folded text metrics.
      // Remeasure only when content, typography or available width changes.
      if (_measurement != measurement) {
        final measure = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: widget.collapsedLines,
          textDirection: measurement.direction,
          textScaler: measurement.scaler,
        )..layout(maxWidth: measurement.width);
        _overflows = measure.didExceedMaxLines;
        measure.dispose();
        _measurement = measurement;
      }
      final overflows = _overflows;
      final expandable = widget.enabled && overflows;
      final expanded = expandable && (widget.expanded ?? _expanded);
      final content = Text(
        widget.text,
        maxLines: !overflows || expanded ? null : widget.collapsedLines,
        overflow: !overflows || expanded
            ? TextOverflow.visible
            : TextOverflow.ellipsis,
        style: style,
      );
      if (!expandable) return content;
      final label = expanded ? '收起' : '展开';
      final body = Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: content),
            const SizedBox(width: 8),
            // Keep the gesture on the control. A tap on the copy must not
            // expand, so the episode row underneath can open playback.
            Semantics(
              button: true,
              expanded: expanded,
              label: '$label${widget.semanticLabel}',
              child: InkWell(
                borderRadius: BorderRadius.circular(5),
                onTap: () {
                  setState(() => _expanded = !expanded);
                  widget.onExpandedChanged?.call(!expanded);
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(label, style: style.copyWith(fontSize: 11)),
                    Icon(
                      expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 16,
                      color: AppTokens.text2,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
      return MediaQuery.disableAnimationsOf(context)
          ? body
          : AnimatedSize(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topLeft,
              child: body,
            );
    },
  );
}
