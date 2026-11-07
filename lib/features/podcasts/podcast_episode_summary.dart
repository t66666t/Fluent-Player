import 'package:flutter/material.dart';
import 'dart:math' as math;
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
    this.availableHeight,
    this.controlBelow = false,
  });

  final String text;
  final bool enabled;
  final TextStyle? style;
  final bool? expanded;
  final ValueChanged<bool>? onExpandedChanged;
  final String semanticLabel;
  final int collapsedLines;

  /// For a bounded sidebar, fold only when the full text cannot fit here.
  final double? availableHeight;
  final bool controlBelow;

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
    double? availableHeight,
    bool controlBelow,
    Locale? locale,
  })?
  _measurement;
  bool _overflows = false;
  int _visibleLines = 3;

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
        availableHeight: widget.availableHeight,
        controlBelow: widget.controlBelow,
        locale: Localizations.maybeLocaleOf(context),
      );
      // Expansion and row updates don't change the folded text metrics.
      // Remeasure only when content, typography or available width changes.
      if (_measurement != measurement) {
        final height = measurement.availableHeight;
        final boundedHeight = height != null && height.isFinite ? height : null;
        final measure = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: boundedHeight == null ? widget.collapsedLines : null,
          textDirection: measurement.direction,
          textScaler: measurement.scaler,
          locale: measurement.locale,
        )..layout(maxWidth: measurement.width);
        _visibleLines = widget.collapsedLines;
        if (boundedHeight == null) {
          _overflows = measure.didExceedMaxLines;
        } else {
          _overflows = measure.height > boundedHeight + .5;
          if (_overflows) {
            final label = TextPainter(
              text: TextSpan(text: '展开', style: style.copyWith(fontSize: 11)),
              textDirection: measurement.direction,
              textScaler: measurement.scaler,
              locale: measurement.locale,
            )..layout();
            final controlHeight = math.max(16.0, label.height) + 6;
            label.dispose();
            final textHeight = math.max(0.0, boundedHeight - controlHeight);
            final fitting = measure
                .computeLineMetrics()
                .takeWhile(
                  (line) => line.baseline + line.descent <= textHeight + .5,
                )
                .length;
            _visibleLines = math.max(1, fitting);
          }
        }
        measure.dispose();
        _measurement = measurement;
      }
      final overflows = _overflows;
      final expandable = widget.enabled && overflows;
      final expanded = expandable && (widget.expanded ?? _expanded);
      final content = Text(
        widget.text,
        maxLines: !overflows || expanded ? null : _visibleLines,
        overflow: !overflows || expanded
            ? TextOverflow.visible
            : TextOverflow.ellipsis,
        style: style,
      );
      if (!expandable) return content;
      final label = expanded ? '收起' : '展开';
      // Keep the gesture on the control. A tap on the copy must not expand,
      // so the episode row underneath can open playback.
      final control = Semantics(
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
      );
      final body = Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: widget.controlBelow
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: double.infinity, child: content),
                  const SizedBox(height: 4),
                  Align(alignment: Alignment.centerRight, child: control),
                ],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: content),
                  const SizedBox(width: 8),
                  control,
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
