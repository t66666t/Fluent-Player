import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:video_player_app/theme/app_typography.dart';
import 'package:video_player_app/utils/bilibili_description_links.dart';

/// Description text whose URLs, BV ids and av numbers are tappable.
class BilibiliDescriptionText extends StatefulWidget {
  const BilibiliDescriptionText({
    super.key,
    required this.text,
    required this.onLinkTap,
  });

  final String text;
  final ValueChanged<BilibiliDescriptionSegment> onLinkTap;

  @override
  State<BilibiliDescriptionText> createState() =>
      _BilibiliDescriptionTextState();
}

class _BilibiliDescriptionTextState extends State<BilibiliDescriptionText> {
  List<BilibiliDescriptionSegment> _segments = const [];
  final List<TapGestureRecognizer> _recognizers = <TapGestureRecognizer>[];

  @override
  void initState() {
    super.initState();
    _rebuildSegments();
  }

  @override
  void didUpdateWidget(covariant BilibiliDescriptionText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _rebuildSegments();
  }

  void _rebuildSegments() {
    _disposeRecognizers();
    _segments = splitBilibiliDescription(widget.text);
    for (final segment in _segments) {
      if (!segment.isLink) continue;
      _recognizers.add(
        TapGestureRecognizer()..onTap = () => widget.onLinkTap(segment),
      );
    }
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.text.trim().isEmpty) {
      return const Text(
        '暂无简介',
        style: TextStyle(color: AppTokens.text3, fontSize: 13),
      );
    }
    var linkIndex = 0;
    return SelectableText.rich(
      TextSpan(
        style: appReadingStyle.copyWith(
          color: AppTokens.text2,
          fontSize: 13,
          height: 1.5,
        ),
        children: [
          for (final segment in _segments)
            if (segment.isLink)
              TextSpan(
                text: segment.text,
                style: const TextStyle(color: AppTokens.accent),
                recognizer: _recognizers[linkIndex++],
              )
            else
              TextSpan(text: segment.text),
        ],
      ),
    );
  }
}
