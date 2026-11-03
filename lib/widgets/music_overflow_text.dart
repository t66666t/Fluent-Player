import 'dart:async';

import 'package:flutter/material.dart';

/// Wraps when space permits; overflowing metadata can be read in full by a
/// slow, reversible scroll. Reduced motion keeps manual scrolling available.
class MusicOverflowText extends StatefulWidget {
  const MusicOverflowText({
    super.key,
    required this.text,
    required this.style,
    this.maxLines = 1,
  });

  final String text;
  final TextStyle style;
  final int maxLines;

  @override
  State<MusicOverflowText> createState() => _MusicOverflowTextState();
}

class _MusicOverflowTextState extends State<MusicOverflowText> {
  final _scroll = ScrollController();
  Timer? _pause;
  Object? _configuration;
  int _generation = 0;

  void _configure(Object configuration, bool animate) {
    if (_configuration == configuration) return;
    _configuration = configuration;
    final generation = ++_generation;
    _pause?.cancel();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation) return;
      if (_scroll.hasClients) _scroll.jumpTo(0);
      if (animate) _schedule(generation, true);
    });
  }

  void _schedule(int generation, bool forward) {
    _pause = Timer(const Duration(seconds: 2), () async {
      if (!mounted || generation != _generation || !_scroll.hasClients) return;
      final target = forward ? _scroll.position.maxScrollExtent : 0.0;
      final distance = (target - _scroll.offset).abs();
      if (distance > 0) {
        await _scroll.animateTo(
          target,
          duration: Duration(
            milliseconds: (distance / 24 * 1000).round().clamp(300, 3600000),
          ),
          curve: Curves.linear,
        );
      }
      if (mounted && generation == _generation) _schedule(generation, !forward);
    });
  }

  @override
  void dispose() {
    _generation++;
    _pause?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scaler = MediaQuery.textScalerOf(context);
      final direction = Directionality.of(context);
      final painter = TextPainter(
        text: TextSpan(text: widget.text, style: widget.style),
        maxLines: widget.maxLines,
        textDirection: direction,
        textScaler: scaler,
      )..layout(maxWidth: constraints.maxWidth);
      final overflows =
          painter.didExceedMaxLines || painter.width > constraints.maxWidth;
      painter.dispose();
      final animate =
          overflows &&
          !MediaQuery.disableAnimationsOf(context) &&
          !MediaQuery.accessibleNavigationOf(context);
      _configure((
        widget.text,
        widget.style,
        constraints.maxWidth,
        scaler,
        direction,
        animate,
      ), animate);
      if (!overflows) {
        return Text(
          widget.text,
          style: widget.style,
          maxLines: widget.maxLines,
          textAlign: TextAlign.center,
        );
      }
      return Semantics(
        label: widget.text,
        excludeSemantics: true,
        child: ClipRect(
          child: SingleChildScrollView(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            child: Text(
              widget.text.replaceAll('\n', ' '),
              style: widget.style,
              maxLines: 1,
              softWrap: false,
            ),
          ),
        ),
      );
    },
  );
}
