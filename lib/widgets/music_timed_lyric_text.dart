import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import '../models/subtitle_model.dart';
import 'music_lyric_frame_coordinator.dart';

TextSpan _tintedSpan(TextSpan span, Color color) {
  final style = span.style?.copyWith(color: color);
  final children = span.children;
  if (children == null || children.isEmpty) {
    return TextSpan(text: span.text, style: style);
  }
  return TextSpan(
    style: style,
    children: [
      for (final child in children)
        child is TextSpan ? _tintedSpan(child, color) : child,
    ],
  );
}

double musicTimedSpanProgress(SubtitleTimedSpan span, Duration position) {
  if (position <= span.startTime) return 0;
  if (position >= span.endTime) return 1;
  return (position - span.startTime).inMicroseconds /
      (span.endTime - span.startTime).inMicroseconds;
}

({SubtitleItem main, List<SubtitleItem> background}) musicLyricVisualCues(
  SubtitleItem cue,
) {
  final bg = cue.timedSpans.where((span) => span.role == 'x-bg').toList()
    ..sort((a, b) => a.textStart.compareTo(b.textStart));
  if (bg.isEmpty) return (main: cue, background: const []);
  final ranges = <(int, int)>[];
  for (final span in bg) {
    if (ranges.isNotEmpty &&
        (span.textStart <= ranges.last.$2 ||
            cue.text
                .substring(ranges.last.$2, span.textStart)
                .trim()
                .isEmpty)) {
      ranges[ranges.length - 1] = (
        ranges.last.$1,
        math.max(ranges.last.$2, span.textEnd),
      );
    } else {
      ranges.add((span.textStart, span.textEnd));
    }
  }
  final background = <SubtitleItem>[];
  for (final (from, to) in ranges) {
    final spans = bg
        .where((span) => span.textStart >= from && span.textEnd <= to)
        .map((span) => span.shifted(Duration.zero, textOffset: -from))
        .toList();
    background.add(
      SubtitleItem(
        index: cue.index,
        startTime: cue.startTime,
        endTime: cue.endTime,
        text: cue.text.substring(from, to),
        timedSpans: spans,
        isBackgroundLyric: true,
        isStructuredLyric: true,
        lyricAgent: cue.lyricAgent,
      ).trimmed(),
    );
  }
  final text = StringBuffer();
  var cursor = 0;
  for (final (from, to) in ranges) {
    text.write(cue.text.substring(cursor, from));
    cursor = to;
  }
  text.write(cue.text.substring(cursor));
  final spans = <SubtitleTimedSpan>[];
  for (final span in cue.timedSpans.where((s) => s.role != 'x-bg')) {
    final removed = ranges
        .where((range) => range.$2 <= span.textStart)
        .fold<int>(0, (sum, range) => sum + range.$2 - range.$1);
    spans.add(span.shifted(Duration.zero, textOffset: -removed));
  }
  return (
    main: cue.copyWith(text: text.toString(), timedSpans: spans).trimmed(),
    background: background,
  );
}

class MusicLyricSpringCurve extends Curve {
  const MusicLyricSpringCurve();
  static final _spring = SpringSimulation(
    const SpringDescription(mass: 1, stiffness: 100, damping: 20),
    0,
    1,
    0,
  );
  @override
  double transformInternal(double t) =>
      (_spring.x(t * 0.8) / _spring.x(0.8)).clamp(0.0, 1.0);
}

/// Shares the row fade with timed ink so activating word dimming cannot
/// multiply the still-faded row into a darker intermediate frame.
class MusicLyricRowOpacity extends AnimatedOpacity {
  const MusicLyricRowOpacity({
    super.key,
    required super.opacity,
    required super.duration,
    super.curve,
    required super.child,
  });

  @override
  ImplicitlyAnimatedWidgetState<AnimatedOpacity> createState() =>
      _MusicLyricRowOpacityState();
}

class _MusicLyricRowOpacityState
    extends ImplicitlyAnimatedWidgetState<AnimatedOpacity> {
  Tween<double>? _opacity;
  late Animation<double> _fade;

  @override
  void forEachTween(TweenVisitor<dynamic> visitor) {
    _opacity =
        visitor(
              _opacity,
              widget.opacity,
              (value) => Tween<double>(begin: value as double),
            )
            as Tween<double>?;
  }

  @override
  void didUpdateTweens() {
    _fade = animation.drive(_opacity!);
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _fade,
    child: _LyricRowOpacityScope(opacity: _fade, child: widget.child!),
  );
}

class _LyricRowOpacityScope extends InheritedWidget {
  final Animation<double> opacity;
  const _LyricRowOpacityScope({required this.opacity, required super.child});

  @override
  bool updateShouldNotify(_LyricRowOpacityScope oldWidget) =>
      oldWidget.opacity != opacity;
}

/// Shape the whole paragraph once, then move slices of those shaped glyphs.
/// The transparent Text keeps layout, selection semantics and row hit geometry.
/// Both dim and lit ink move together; all motion uses the media clock.
class MusicTimedLyricText extends StatefulWidget {
  final String text;
  final List<SubtitleTimedSpan> spans;
  final TextStyle style;

  /// Per-script faces for one lyric line. Null keeps a single style, which
  /// timed slicing and the glyph atlas already expect.
  final List<TextSpan>? fontRuns;
  final ValueListenable<Duration>? position;
  final Duration fallbackPosition;
  final TextAlign textAlign;
  final bool reduceMotion;
  final bool dimUnplayed;

  /// Clears skipped words during a seek without replacing the shaped text or
  /// interrupting the surrounding row's opacity animation.
  final bool suppressWordHighlight;
  const MusicTimedLyricText({
    super.key,
    required this.text,
    required this.spans,
    required this.style,
    this.fontRuns,
    this.position,
    this.fallbackPosition = Duration.zero,
    this.textAlign = TextAlign.left,
    this.reduceMotion = false,
    this.dimUnplayed = true,
    this.suppressWordHighlight = false,
  });
  @override
  State<MusicTimedLyricText> createState() => _MusicTimedLyricTextState();
}

class _MusicTimedLyricTextState extends State<MusicTimedLyricText>
    with SingleTickerProviderStateMixin {
  _TimedGlyphLayout? _layout;
  Object? _layoutKey;
  late final _TimedLyricRepaint _repaint;
  late final AnimationController _dimAlpha;
  late final _LyricDimRepaint _dimRepaint;
  _TimedLyricStationaryRepaint? _stationaryRepaint;
  final _LyricRasterCache _raster = _LyricRasterCache();
  final _LyricRasterCache _movingRaster = _LyricRasterCache();
  bool _reduced = false;
  MusicLyricRowClock? _rowClock;
  ValueListenable<Duration>? get _clock =>
      widget.position != null &&
          _rowClock != null &&
          identical(_rowClock!.owner.source, widget.position)
      ? _rowClock
      : widget.position;
  double get _dimTarget =>
      widget.spans.isNotEmpty && widget.dimUnplayed ? 0.35 : 1;

  @override
  void initState() {
    super.initState();
    _repaint = _TimedLyricRepaint(widget.position, widget.spans);
    _dimAlpha = AnimationController(
      vsync: this,
      value: _dimTarget,
      duration: const Duration(milliseconds: 360),
    );
    _dimRepaint = _LyricDimRepaint(_dimAlpha);
  }

  @override
  void didUpdateWidget(MusicTimedLyricText oldWidget) {
    super.didUpdateWidget(oldWidget);
    _repaint.update(_clock, widget.spans);
    if (oldWidget.dimUnplayed != widget.dimUnplayed ||
        oldWidget.spans.isEmpty != widget.spans.isEmpty) {
      // Dim immediately on activation so unplayed words never flash fully lit.
      if (_reduced ||
          oldWidget.spans.isEmpty != widget.spans.isEmpty ||
          _dimTarget < _dimAlpha.value) {
        _dimAlpha.value = _dimTarget;
      } else {
        _dimAlpha.animateTo(_dimTarget, curve: Curves.easeInOutCubic);
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _rowClock = MusicLyricRowFrameScope.maybeOf(context);
    _repaint.update(_clock, widget.spans);
    _reduced = MediaQuery.disableAnimationsOf(context);
    if (_reduced) _dimAlpha.value = _dimTarget;
  }

  @override
  void dispose() {
    _layout?.dispose();
    _stationaryRepaint?.dispose();
    _repaint.dispose();
    _dimRepaint.dispose();
    _dimAlpha.dispose();
    _raster.dispose();
    _movingRaster.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _reduced = MediaQuery.disableAnimationsOf(context);
    final focus = _LyricFocusScope.maybeOf(context);
    final rowOpacity = widget.spans.isEmpty
        ? null
        : context
              .dependOnInheritedWidgetOfExactType<_LyricRowOpacityScope>()
              ?.opacity;
    _dimRepaint.update(rowOpacity);
    if (widget.spans.isEmpty && focus == null) {
      _stationaryRepaint?.active = false;
      _layout?.dispose();
      _raster.dispose();
      _movingRaster.dispose();
      _layout = null;
      _layoutKey = null;
      return Text(
        widget.text,
        textAlign: widget.textAlign,
        softWrap: true,
        maxLines: null,
        style: widget.style,
      );
    }
    final effectiveStyle = DefaultTextStyle.of(
      context,
    ).style.merge(widget.style);
    // Lyric colours change with activation; glyph geometry does not. Keep a
    // white atlas and tint its draws rather than reshaping the paragraph.
    final tintable =
        effectiveStyle.foreground == null &&
        effectiveStyle.background == null &&
        effectiveStyle.backgroundColor == null &&
        (effectiveStyle.decoration == null ||
            effectiveStyle.decoration == TextDecoration.none) &&
        (effectiveStyle.shadows?.isEmpty ?? true);
    final layoutStyle = tintable
        ? effectiveStyle.copyWith(color: Colors.white)
        : effectiveStyle;
    final inkColor = tintable
        ? effectiveStyle.color ?? Colors.white
        : Colors.white;
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final fontRunKey = Object.hashAll([
          for (final run in widget.fontRuns ?? const <TextSpan>[])
            (run.text, run.style),
        ]);
        final key = (
          widget.text,
          layoutStyle,
          constraints.maxWidth,
          scaler,
          direction,
          Object.hashAll(widget.spans),
          widget.textAlign,
          fontRunKey,
        );
        final layoutRuns = widget.fontRuns == null
            ? null
            : [
                for (final run in widget.fontRuns!)
                  TextSpan(
                    text: run.text,
                    style: tintable
                        ? run.style?.copyWith(color: Colors.white)
                        : run.style,
                  ),
              ];
        if (_layoutKey != key) {
          _layout?.dispose();
          _raster.dispose();
          _movingRaster.dispose();
          _layout = _TimedGlyphLayout(
            widget.text,
            layoutStyle,
            constraints.maxWidth,
            scaler,
            direction,
            widget.spans,
            widget.textAlign,
            fontRuns: layoutRuns,
          );
          _layoutKey = key;
        }
        if (_layout!.inkColor != inkColor) {
          _layout!.setInkColor(inkColor);
          _raster.dispose();
          _movingRaster.dispose();
        }
        final splitInk =
            focus == null &&
            _layout!.regions.isNotEmpty &&
            _layout!.separateRegions;
        final stationary = splitInk
            ? (_stationaryRepaint ??= _TimedLyricStationaryRepaint(
                _repaint,
                _dimRepaint,
              ))
            : null;
        _stationaryRepaint?.active = splitInk;
        stationary?.update(
          _clock,
          widget.spans,
          widget.fallbackPosition,
          widget.suppressWordHighlight,
        );
        _TimedGlyphPainter painter(Listenable repaint, _LyricInkPart part) =>
            _TimedGlyphPainter(
              _layout!,
              repaint,
              _clock,
              widget.fallbackPosition,
              widget.reduceMotion,
              widget.suppressWordHighlight,
              _dimRepaint,
              focus,
              _raster,
              _movingRaster,
              MediaQuery.devicePixelRatioOf(context),
              inkColor,
              part,
            );
        final liveInk = RepaintBoundary(
          child: CustomPaint(
            foregroundPainter: painter(
              Listenable.merge([_repaint, _dimRepaint, ?focus]),
              splitInk ? _LyricInkPart.moving : _LyricInkPart.combined,
            ),
            child: Text(
              widget.text,
              textAlign: widget.textAlign,
              softWrap: true,
              maxLines: null,
              style: widget.style.copyWith(color: Colors.transparent),
            ),
          ),
        );
        return SizedBox(
          width: constraints.maxWidth,
          child: stationary == null
              ? liveInk
              : Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: _LyricStationaryInk(
                        painter(stationary, _LyricInkPart.stationary),
                      ),
                    ),
                    liveInk,
                  ],
                ),
        );
      },
    );
  }
}

/// A row-only fade normally changes compositing, not the text pixels. Only
/// repaint when the compensation actually changes the unplayed ink alpha.
class _LyricDimRepaint extends ChangeNotifier {
  final Animation<double> dim;
  Animation<double>? _row;
  late double _previous;

  _LyricDimRepaint(this.dim) {
    _previous = value;
    dim.addListener(_tick);
  }

  double get value => _row == null
      ? dim.value
      : (dim.value / math.max(0.00001, _row!.value)).clamp(0.0, 1.0);

  bool get isAnimating =>
      dim.isAnimating ||
      (_row != null && _row!.isAnimating && dim.value < _row!.value);

  void update(Animation<double>? row) {
    if (row == _row) return;
    _row?.removeListener(_tick);
    _row = row;
    _row?.addListener(_tick);
    _tick();
  }

  void _tick() {
    final next = value;
    if (next == _previous) return;
    _previous = next;
    notifyListeners();
  }

  @override
  void dispose() {
    dim.removeListener(_tick);
    _row?.removeListener(_tick);
    super.dispose();
  }
}

/// A stationary word has no new pixels to paint. Keep media-clock changes
/// during gaps, before a cue and after it has finished out of the paint tree.
class _TimedLyricRepaint extends ChangeNotifier {
  ValueListenable<Duration>? _clock;
  List<SubtitleTimedSpan> _spans;
  Duration _previous;
  int? _firstUs;
  int? _lastUs;
  _TimedLyricRepaint(this._clock, this._spans)
    : _previous = _clock?.value ?? Duration.zero {
    _readBounds();
    if (_firstUs != null) _clock?.addListener(_tick);
  }

  void _readBounds() {
    _firstUs = null;
    _lastUs = null;
    for (final span in _spans) {
      if (span.endTime <= span.startTime) continue;
      final start = span.startTime.inMicroseconds;
      final end = span.endTime.inMicroseconds;
      if (_firstUs == null || start < _firstUs!) _firstUs = start;
      if (_lastUs == null || end > _lastUs!) _lastUs = end;
    }
  }

  void update(ValueListenable<Duration>? clock, List<SubtitleTimedSpan> spans) {
    final wasTimed = _firstUs != null;
    if (!identical(spans, _spans)) {
      _spans = spans;
      _readBounds();
    }
    if (clock != _clock || wasTimed != (_firstUs != null)) {
      if (wasTimed) _clock?.removeListener(_tick);
      _clock = clock;
      if (_firstUs != null) _clock?.addListener(_tick);
    }
    _previous = _clock?.value ?? Duration.zero;
  }

  void _tick() {
    final current = _clock!.value;
    final previous = _previous;
    _previous = current;
    final beforeUs = previous.inMicroseconds;
    final afterUs = current.inMicroseconds;
    if ((beforeUs <= _firstUs! && afterUs <= _firstUs!) ||
        (beforeUs >= _lastUs! && afterUs >= _lastUs!)) {
      return;
    }
    for (final span in _spans) {
      if (span.endTime <= span.startTime) continue;
      final before = previous.inMicroseconds.clamp(
        span.startTime.inMicroseconds,
        span.endTime.inMicroseconds,
      );
      final after = current.inMicroseconds.clamp(
        span.startTime.inMicroseconds,
        span.endTime.inMicroseconds,
      );
      if (before != after) {
        notifyListeners();
        return;
      }
    }
  }

  @override
  void dispose() {
    if (_firstUs != null) _clock?.removeListener(_tick);
    super.dispose();
  }
}

/// Stable words keep their own retained layer. The display clock invalidates
/// it only at a word boundary, rather than replaying every completed glyph and
/// long-note glow while the next word is moving.
class _TimedLyricStationaryRepaint extends ChangeNotifier {
  _TimedLyricStationaryRepaint(this.source, this.dim);

  final _TimedLyricRepaint source;
  final _LyricDimRepaint dim;
  ValueListenable<Duration>? _clock;
  List<SubtitleTimedSpan> _spans = const [];
  List<int> _states = [];
  Duration _fallback = Duration.zero;
  bool _suppressed = false;
  bool _active = false;
  bool _dimAnimating = false;

  set active(bool value) {
    if (value == _active) return;
    _active = value;
    if (value) {
      source.addListener(_onClock);
      dim.addListener(_onDim);
    } else {
      source.removeListener(_onClock);
      dim.removeListener(_onDim);
    }
  }

  void update(
    ValueListenable<Duration>? clock,
    List<SubtitleTimedSpan> spans,
    Duration fallback,
    bool suppressed,
  ) {
    _clock = clock;
    _spans = spans;
    _fallback = fallback;
    _suppressed = suppressed;
    if (_states.length != spans.length) _states = List.filled(spans.length, -1);
    _readStates();
  }

  bool _readStates() {
    final now = (_clock?.value ?? _fallback).inMicroseconds;
    var changed = _dimAnimating != dim.isAnimating;
    _dimAnimating = dim.isAnimating;
    for (var i = 0; i < _spans.length; i++) {
      final span = _spans[i];
      final state = _suppressed || now < span.startTime.inMicroseconds
          ? 0
          : now < span.endTime.inMicroseconds
          ? 1
          : 2;
      changed |= _states[i] != state;
      _states[i] = state;
    }
    return changed;
  }

  void _onClock() {
    if (_readStates()) notifyListeners();
  }

  void _onDim() {
    _readStates();
    notifyListeners();
  }

  @override
  void dispose() {
    active = false;
    super.dispose();
  }
}

/// A paint-only leaf lets the foreground CustomPaint keep its existing text
/// layout and semantics, while Flutter can cache the stationary ink separately.
class _LyricStationaryInk extends LeafRenderObjectWidget {
  const _LyricStationaryInk(this.painter);
  final CustomPainter painter;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderLyricStationaryInk(painter);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderLyricStationaryInk object,
  ) => object.painter = painter;
}

class _RenderLyricStationaryInk extends RenderBox {
  _RenderLyricStationaryInk(this._painter);
  CustomPainter _painter;

  set painter(CustomPainter value) {
    final previous = _painter;
    if (previous == value) return;
    if (attached) previous.removeListener(markNeedsPaint);
    _painter = value;
    if (attached) value.addListener(markNeedsPaint);
    if (value.shouldRepaint(previous)) markNeedsPaint();
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performResize() => size = computeDryLayout(constraints);

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _painter.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _painter.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  bool hitTestSelf(Offset position) => false;

  @override
  void paint(PaintingContext context, Offset offset) {
    final canvas = context.canvas;
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    _painter.paint(canvas, size);
    canvas.restore();
  }
}

class _LyricGlyphSlice {
  final Rect rect;
  final TextDirection direction;
  final double advance;
  _LyricGlyphSlice(this.rect, this.direction, this.advance);
}

class _TimedGlyphRegion {
  final SubtitleTimedSpan span;
  final List<TextBox> boxes;
  final List<_LyricGlyphSlice> glyphs;
  final double width;
  ui.Picture? held;
  ui.Image? heldGlow;
  _TimedGlyphRegion(this.span, this.boxes, this.glyphs)
    : width = boxes.fold(0.0, (sum, box) => sum + box.right - box.left);

  void clearHeld() {
    held?.dispose();
    held = null;
    heldGlow?.dispose();
    heldGlow = null;
  }
}

class _TimedGlyphLayout {
  final TextPainter bright;
  final List<_TimedGlyphRegion> regions = [];
  bool separateRegions = true;
  final double em;
  ui.Image? _atlas;
  double _atlasRatio = 1;
  bool _atlasTooLarge = false;
  Rect _atlasBounds = Rect.zero;
  Rect _atlasSource = Rect.zero;
  final Paint _atlasPaint = Paint()..filterQuality = FilterQuality.low;
  Color inkColor = Colors.white;
  ColorFilter? _inkFilter;
  TextPainter? _vectorInk;
  int heldGlowPixels = 0;

  void _clearHeld() {
    for (final region in regions) {
      region.clearHeld();
    }
    heldGlowPixels = 0;
  }

  void setInkColor(Color value) {
    if (inkColor == value) return;
    inkColor = value;
    _inkFilter = value == Colors.white
        ? null
        : ColorFilter.mode(value, BlendMode.srcIn);
    _atlasPaint.colorFilter = _inkFilter;
    _vectorInk?.dispose();
    _vectorInk = null;
    _clearHeld();
  }

  _TimedGlyphLayout(
    String text,
    TextStyle style,
    double width,
    TextScaler scaler,
    TextDirection direction,
    List<SubtitleTimedSpan> spans,
    TextAlign align, {
    List<TextSpan>? fontRuns,
  }) : em = scaler.scale(style.fontSize ?? 24),
       bright = TextPainter(
         text: fontRuns == null
             ? TextSpan(text: text, style: style)
             : TextSpan(style: style, children: fontRuns),
         textDirection: direction,
         textAlign: align,
         textScaler: scaler,
       ) {
    bright.layout(minWidth: width, maxWidth: width);
    for (var i = 0; i < spans.length; i++) {
      final span = spans[i];
      if (!span.isValidFor(text)) continue;
      if (i > 0 && span.textStart < spans[i - 1].textEnd) {
        separateRegions = false;
      }
      var end = span.textEnd;
      final nextStart = i + 1 < spans.length
          ? spans[i + 1].textStart
          : text.length;
      if (nextStart >= end &&
          !RegExp(
            r'[\p{L}\p{N}]',
            unicode: true,
          ).hasMatch(text.substring(end, nextStart))) {
        end = nextStart;
      }
      final boxes = bright.getBoxesForSelection(
        TextSelection(baseOffset: span.textStart, extentOffset: end),
      );
      if (boxes.isEmpty) continue;
      final glyphs = <_LyricGlyphSlice>[];
      // Connected scripts stay shaped and move as a run. CJK, Latin, emoji and
      // combining marks use grapheme clusters, never individual UTF-16 units.
      final connected = RegExp(
        r'[\u0600-\u08ff\u0900-\u0dff]',
      ).hasMatch(text.substring(span.textStart, end));
      final pieces = <TextBox>[];
      if (connected) {
        pieces.addAll(boxes);
      } else {
        var cursor = span.textStart;
        for (final cluster in text.substring(span.textStart, end).characters) {
          pieces.addAll(
            bright.getBoxesForSelection(
              TextSelection(
                baseOffset: cursor,
                extentOffset: cursor + cluster.length,
              ),
            ),
          );
          cursor += cluster.length;
        }
      }
      for (final box in pieces) {
        if (box.right <= box.left) continue;
        var advance = 0.0;
        var matched = false;
        for (final run in boxes) {
          if ((run.top - box.top).abs() < 0.5 &&
              box.left >= run.left - 0.5 &&
              box.right <= run.right + 0.5) {
            advance += run.direction == TextDirection.rtl
                ? run.right - box.right
                : box.left - run.left;
            matched = true;
            break;
          }
          advance += run.right - run.left;
        }
        if (!matched) continue;
        glyphs.add(_LyricGlyphSlice(box.toRect(), box.direction, advance));
      }
      regions.add(_TimedGlyphRegion(span, boxes, glyphs));
    }
  }

  void ensureAtlas(double pixelRatio) {
    if ((_atlas != null || _atlasTooLarge) && _atlasRatio == pixelRatio) return;
    _clearHeld();
    _atlas?.dispose();
    _atlas = null;
    _atlasRatio = pixelRatio;
    final bounds = (Offset.zero & bright.size).inflate(math.max(9, em * 0.4));
    // Align texels to logical coordinates. Fractional paragraph heights must
    // not stretch the atlas each time it is sampled at a different scale.
    _atlasBounds = Rect.fromLTRB(
      (bounds.left * pixelRatio).floor() / pixelRatio,
      (bounds.top * pixelRatio).floor() / pixelRatio,
      (bounds.right * pixelRatio).ceil() / pixelRatio,
      (bounds.bottom * pixelRatio).ceil() / pixelRatio,
    );
    final width = (_atlasBounds.width * pixelRatio).round();
    final height = (_atlasBounds.height * pixelRatio).round();
    // Oversized paragraphs retain vector painting instead of requiring a
    // giant texture. Keep this independent of the device's GPU limits.
    _atlasTooLarge = width > 4096 || height > 4096 || width * height > 4194304;
    if (_atlasTooLarge) return;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..scale(pixelRatio)
      ..translate(-_atlasBounds.left, -_atlasBounds.top);
    bright.paint(canvas, Offset.zero);
    final picture = recorder.endRecording();
    _atlas = picture.toImageSync(width, height);
    _atlasSource = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
    picture.dispose();
  }

  void paintInk(Canvas canvas, {double opacity = 1}) {
    final image = _atlas;
    if (image == null) {
      // Oversized or non-rasterized paragraphs retain group opacity: a text
      // style alpha would change overlapping glyphs, decorations and shadows.
      if (opacity < 0.99999) {
        canvas.saveLayer(
          Offset.zero & bright.size,
          Paint()..color = Colors.white.withValues(alpha: opacity),
        );
      }
      if (inkColor == Colors.white) {
        bright.paint(canvas, Offset.zero);
      } else {
        final span = bright.text! as TextSpan;
        final painter = _vectorInk ??= TextPainter(
          text: _tintedSpan(span, inkColor),
          textDirection: bright.textDirection,
          textAlign: bright.textAlign,
          textScaler: bright.textScaler,
        )..layout(minWidth: bright.width, maxWidth: bright.width);
        painter.paint(canvas, Offset.zero);
      }
      if (opacity < 0.99999) canvas.restore();
      return;
    }
    // This is already one premultiplied image draw. Applying its opacity in
    // the paint is equivalent to fading a temporary layer around that draw,
    // without an offscreen render pass for every dim or partially lit glyph.
    _atlasPaint.color = Colors.white.withValues(alpha: opacity);
    canvas.drawImageRect(image, _atlasSource, _atlasBounds, _atlasPaint);
  }

  void paintGlyph(Canvas canvas, _LyricGlyphSlice glyph, {double opacity = 1}) {
    canvas.save();
    canvas.clipRect(glyph.rect);
    paintInk(canvas, opacity: opacity);
    canvas.restore();
  }

  void dispose() {
    _clearHeld();
    _atlas?.dispose();
    _vectorInk?.dispose();
    bright.dispose();
  }
}

/// A row's real painted position determines its depth, independently of cue
/// boundaries. Paragraphs subscribe only for repainting, never text layout.
class _LyricFocusSignal extends ChangeNotifier {
  final double Function() read;
  _LyricFocusSignal(this.read);
  void invalidate() => notifyListeners();
}

class _LyricFocusScope extends InheritedWidget {
  final _LyricFocusSignal signal;
  const _LyricFocusScope({required this.signal, required super.child});
  static _LyricFocusSignal? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_LyricFocusScope>()?.signal;
  @override
  bool updateShouldNotify(_LyricFocusScope oldWidget) =>
      signal != oldWidget.signal;
}

/// Three fixed focus surfaces. Only their weights change while a row moves;
/// no animated Gaussian radius can switch kernels halfway through a word.
class _LyricRasterCache {
  static final _filters = [
    null,
    ui.ImageFilter.blur(sigmaX: 1.25, sigmaY: 1.25),
    ui.ImageFilter.blur(sigmaX: 2.5, sigmaY: 2.5),
  ];
  Object? key;
  ui.Picture? ink;
  final List<ui.Image?> _images = [null, null, null];
  Rect bounds = Rect.zero;
  double ratio = 1;
  void update(
    Object nextKey,
    Size size,
    double pad,
    double pixelRatio,
    void Function(Canvas) draw, {
    Rect? inkBounds,
  }) {
    if (nextKey == key && ratio == pixelRatio) return;
    dispose();
    key = nextKey;
    ratio = pixelRatio;
    bounds = (inkBounds ?? (Offset.zero & size)).inflate(pad);
    final recorder = ui.PictureRecorder();
    draw(Canvas(recorder));
    ink = recorder.endRecording();
  }

  ui.Image image(int level) {
    final cached = _images[level];
    if (cached != null) return cached;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..scale(ratio)
      ..translate(-bounds.left, -bounds.top);
    if (level > 0) {
      canvas.saveLayer(bounds, Paint()..imageFilter = _filters[level]);
    }
    canvas.drawPicture(ink!);
    if (level > 0) canvas.restore();
    final picture = recorder.endRecording();
    final result = picture.toImageSync(
      (bounds.width * ratio).ceil(),
      (bounds.height * ratio).ceil(),
    );
    picture.dispose();
    return _images[level] = result;
  }

  void paint(Canvas canvas, double amount, {required bool cacheImages}) {
    final t = amount.clamp(0.0, 1.0);
    if (!cacheImages) {
      // A changing word or dim transition invalidates every focus surface.
      // Paint its retained commands directly rather than allocating up to
      // three short-lived GPU images on every media-clock frame. The same
      // fixed kernels and additive weights preserve the focus transition.
      if (t < 0.00001) {
        canvas.drawPicture(ink!);
      } else if (t > 0.99999) {
        canvas.saveLayer(bounds, Paint()..imageFilter = _filters[2]);
        canvas.drawPicture(ink!);
        canvas.restore();
      } else {
        final weights = [(1 - t) * (1 - t), 2 * t * (1 - t), t * t];
        canvas.saveLayer(bounds, Paint());
        for (var level = 0; level < weights.length; level++) {
          if (weights[level] < 0.00001) continue;
          canvas.saveLayer(
            bounds,
            Paint()
              ..imageFilter = _filters[level]
              ..color = Colors.white.withValues(alpha: weights[level])
              ..blendMode = BlendMode.plus,
          );
          canvas.drawPicture(ink!);
          canvas.restore();
        }
        canvas.restore();
      }
      return;
    }
    if (t < 0.00001 || t > 0.99999) {
      final texture = image(t < 0.5 ? 0 : 2);
      canvas.drawImageRect(
        texture,
        Rect.fromLTWH(
          0,
          0,
          texture.width.toDouble(),
          texture.height.toDouble(),
        ),
        bounds,
        Paint()..filterQuality = FilterQuality.low,
      );
      return;
    }
    final weights = [(1 - t) * (1 - t), 2 * t * (1 - t), t * t];
    // Add premultiplied colours in one layer so crossfading cannot dim ink.
    canvas.saveLayer(bounds, Paint());
    for (var level = 0; level < 3; level++) {
      if (weights[level] < 0.00001) continue;
      final texture = image(level);
      canvas.drawImageRect(
        texture,
        Rect.fromLTWH(
          0,
          0,
          texture.width.toDouble(),
          texture.height.toDouble(),
        ),
        bounds,
        Paint()
          ..filterQuality = FilterQuality.low
          ..color = Colors.white.withValues(alpha: weights[level])
          ..blendMode = BlendMode.plus,
      );
    }
    canvas.restore();
  }

  void dispose() {
    ink?.dispose();
    ink = null;
    key = null;
    for (var i = 0; i < _images.length; i++) {
      _images[i]?.dispose();
      _images[i] = null;
    }
  }
}

enum _LyricInkPart { combined, stationary, moving }

class _TimedGlyphPainter extends CustomPainter {
  final _TimedGlyphLayout layout;
  final ValueListenable<Duration>? clock;
  final Duration fallback;
  final bool reduceMotion;
  final bool suppressWordHighlight;
  final _LyricDimRepaint dim;
  final _LyricFocusSignal? focus;
  final _LyricRasterCache raster;
  final _LyricRasterCache movingRaster;
  final double pixelRatio;
  final Color inkColor;
  final _LyricInkPart part;
  _TimedGlyphPainter(
    this.layout,
    Listenable repaint,
    this.clock,
    this.fallback,
    this.reduceMotion,
    this.suppressWordHighlight,
    this.dim,
    this.focus,
    this.raster,
    this.movingRaster,
    this.pixelRatio,
    this.inkColor,
    this.part,
  ) : super(repaint: repaint);

  // Keep the composed unplayed opacity at its target while the row brightens.
  // At rest, inactive rows still use their original row-only opacity.
  double get _effectiveDimAlpha => dim.value;

  double _spanProgress(SubtitleTimedSpan span) => suppressWordHighlight
      ? 0
      : musicTimedSpanProgress(span, clock?.value ?? fallback);

  // Rise once as the highlight crosses each glyph, then hold. A completed
  // word must never fall back while the rest of the sentence is still sung.
  double _rise(double fill) {
    final x = fill.clamp(0.0, 1.0);
    return x * x * x * (x * (x * 6 - 15) + 10);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (layout.regions.isNotEmpty) layout.ensureAtlas(pixelRatio);
    final amount = focus?.read() ?? 0;
    if (focus == null && layout.regions.isEmpty) {
      _paintInk(canvas, size);
      return;
    }
    final now = (clock?.value ?? fallback).inMicroseconds;
    var progress = 0;
    var changing = dim.isAnimating;
    final moving = <_TimedGlyphRegion>[];
    final stationary = <_TimedGlyphRegion>[];
    final states = <int>[];
    for (final region in layout.regions) {
      if (suppressWordHighlight) {
        stationary.add(region);
        states.add(0);
        continue;
      }
      if (now >= region.span.startTime.inMicroseconds &&
          now < region.span.endTime.inMicroseconds) {
        changing = true;
        moving.add(region);
        states.add(1);
      } else {
        stationary.add(region);
        states.add(now < region.span.startTime.inMicroseconds ? 0 : 2);
      }
      progress += (now - region.span.startTime.inMicroseconds).clamp(
        0,
        (region.span.endTime - region.span.startTime).inMicroseconds,
      );
    }
    if (part == _LyricInkPart.moving && moving.isEmpty) return;
    if (part == _LyricInkPart.stationary &&
        moving.isNotEmpty &&
        (dim.isAnimating || !layout.separateRegions)) {
      return;
    }
    if (moving.isNotEmpty && !dim.isAnimating && layout.separateRegions) {
      // Only the currently sung words change within this frame. Keep the
      // rest of the paragraph (including raised completed words) in reusable
      // focus textures. Blur the moving ink inside its own small bounds.
      final wordMask = Path();
      Rect? wordBounds;
      for (final region in moving) {
        for (final box in region.boxes) {
          final rect = box.toRect();
          wordMask.addRect(rect);
          wordBounds = wordBounds?.expandToInclude(rect) ?? rect;
        }
      }
      final pad = math.max(9.0, layout.em * 0.5);
      if (part != _LyricInkPart.moving) {
        raster.update(
          (
            layout,
            reduceMotion,
            suppressWordHighlight,
            _effectiveDimAlpha,
            Object.hashAll(states),
          ),
          size,
          pad,
          pixelRatio,
          (target) => _paintInk(
            target,
            size,
            regions: stationary,
            restingExclusions: wordMask,
          ),
        );
      }
      if (part != _LyricInkPart.stationary) {
        movingRaster.update(
          (
            layout,
            reduceMotion,
            suppressWordHighlight,
            _effectiveDimAlpha,
            progress,
          ),
          size,
          pad,
          pixelRatio,
          (target) =>
              _paintInk(target, size, regions: moving, restingClip: wordMask),
          inkBounds: wordBounds,
        );
      }
      if (focus == null) {
        // Mobile depth is composited around this group. Retain stationary
        // drawing commands, without adding paragraph textures or blur layers.
        if (part != _LyricInkPart.moving) {
          raster.paint(canvas, 0, cacheImages: false);
        }
        if (part != _LyricInkPart.stationary) {
          movingRaster.paint(canvas, 0, cacheImages: false);
        }
        return;
      }
      // Focus kernels are linear. Add the two independently filtered masks
      // so their soft edges keep the original brightness at word boundaries.
      canvas.saveLayer(raster.bounds, Paint());
      raster.paint(canvas, amount, cacheImages: true);
      canvas.saveLayer(
        movingRaster.bounds,
        Paint()..blendMode = BlendMode.plus,
      );
      movingRaster.paint(canvas, amount, cacheImages: false);
      canvas.restore();
      canvas.restore();
      return;
    }
    raster.update(
      (
        layout,
        reduceMotion,
        suppressWordHighlight,
        _effectiveDimAlpha,
        progress,
      ),
      size,
      math.max(9, layout.em * 0.4),
      pixelRatio,
      (target) => _paintInk(target, size),
    );
    raster.paint(canvas, amount, cacheImages: focus != null && !changing);
  }

  void _paintInk(
    Canvas canvas,
    Size size, {
    List<_TimedGlyphRegion>? regions,
    Path? restingClip,
    Path? restingExclusions,
  }) {
    regions ??= layout.regions;
    final held = <ui.Picture>[];
    final moving =
        <
          ({
            _LyricGlyphSlice glyph,
            _TimedGlyphRegion region,
            double emphasis,
            double strength,
            double progress,
          })
        >[];
    final exclusions = Path();
    if (restingExclusions != null) {
      exclusions.addPath(restingExclusions, Offset.zero);
    }
    if (!reduceMotion) {
      for (final region in regions) {
        final duration =
            (region.span.endTime - region.span.startTime).inMicroseconds / 1000;
        final strength = (duration / 1800).clamp(0.20, 1.0);
        final progress = _spanProgress(region.span);
        if (progress <= 0) continue;
        if (progress >= 1) {
          for (final box in region.boxes) {
            exclusions.addRect(box.toRect());
          }
          held.add(region.held ??= _heldRegion(region, strength));
          continue;
        }
        for (final glyph in region.glyphs) {
          final emphasis = _rise(
            (region.width * progress - glyph.advance) / glyph.rect.width,
          );
          if (emphasis < 0.0001) continue;
          exclusions.addRect(glyph.rect);
          moving.add((
            glyph: glyph,
            region: region,
            emphasis: emphasis,
            strength: strength,
            progress: progress,
          ));
        }
      }
    }
    // Remove the resting ink underneath animated slices, so moving letters
    // cannot leave a dim stationary duplicate or be cropped by the old mask.
    canvas.save();
    if (restingClip != null) canvas.clipPath(restingClip);
    if (moving.isNotEmpty || held.isNotEmpty || restingExclusions != null) {
      canvas.clipPath(
        Path.combine(
          PathOperation.difference,
          Path()..addRect(Offset.zero & size),
          exclusions,
        ),
      );
    }
    // Preserve group rasterization for a completely resting paragraph. It is
    // retained between word boundaries, so its one-off layer has no per-frame
    // cost and keeps the original first-frame glyph edges.
    final restingGroup =
        moving.isEmpty &&
        held.isEmpty &&
        restingClip == null &&
        restingExclusions == null &&
        _effectiveDimAlpha < 0.99999;
    if (restingGroup) {
      canvas.saveLayer(
        Offset.zero & size,
        Paint()..color = Colors.white.withValues(alpha: _effectiveDimAlpha),
      );
    }
    layout.paintInk(canvas, opacity: restingGroup ? 1 : _effectiveDimAlpha);
    if (restingGroup) canvas.restore();
    final complete = Path();
    var hasComplete = false;
    for (final region in regions) {
      final progress = _spanProgress(region.span);
      if (progress <= 0) continue;
      if (progress >= 1) {
        hasComplete = true;
        for (final box in region.boxes) {
          complete.addRect(box.toRect());
        }
      } else {
        var remaining = region.width * progress;
        for (final box in region.boxes) {
          _reveal(
            canvas,
            box.toRect(),
            box.direction,
            remaining,
            () => layout.paintInk(canvas),
          );
          remaining -= box.right - box.left;
        }
      }
    }
    if (hasComplete) {
      canvas.save();
      canvas.clipPath(complete);
      layout.paintInk(canvas);
      canvas.restore();
    }
    canvas.restore();

    for (final picture in held) {
      canvas.drawPicture(picture);
    }
    // Long-note glow is one offscreen surface per word. Short words retain
    // the same lift/spread but need no blur surface for every letter/frame.
    for (final region in regions) {
      if (region.span.endTime - region.span.startTime <
          const Duration(seconds: 1)) {
        continue;
      }
      final word = moving
          .where((item) => identical(item.region, region))
          .toList();
      if (word.isEmpty) continue;
      final bounds = region.boxes
          .map((box) => box.toRect())
          .reduce((a, b) => a.expandToInclude(b))
          .inflate(layout.em * 0.5);
      canvas.saveLayer(
        bounds,
        Paint()
          ..color = Colors.white.withValues(alpha: word.first.strength * 0.28)
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: layout.em * 0.07,
            sigmaY: layout.em * 0.07,
          ),
      );
      for (final item in word) {
        _paintMovingGlyph(
          canvas,
          item.glyph,
          item.region,
          item.emphasis,
          item.strength,
          item.progress,
          glowOnly: true,
        );
      }
      canvas.restore();
    }
    for (final item in moving) {
      _paintMovingGlyph(
        canvas,
        item.glyph,
        item.region,
        item.emphasis,
        item.strength,
        item.progress,
      );
    }
  }

  void _paintMovingGlyph(
    Canvas canvas,
    _LyricGlyphSlice glyph,
    _TimedGlyphRegion region,
    double emphasis,
    double strength,
    double progress, {
    bool glowOnly = false,
  }) {
    final amount = emphasis * strength;
    final center = glyph.rect.center;
    final spread = (glyph.advance + glyph.rect.width / 2) / region.width - 0.5;
    final horizontal =
        spread *
        layout.em *
        0.10 *
        amount *
        (glyph.direction == TextDirection.rtl ? -1 : 1);
    canvas.save();
    canvas.translate(
      center.dx + horizontal,
      center.dy - layout.em * 0.075 * amount,
    );
    canvas.scale(1 + 0.08 * amount);
    canvas.translate(-center.dx, -center.dy);
    final fill = region.width * progress - glyph.advance;
    final lit = (fill / glyph.rect.width).clamp(0.0, 1.0);
    if (lit >= 1) {
      layout.paintGlyph(canvas, glyph);
    } else {
      if (!glowOnly) {
        layout.paintGlyph(canvas, glyph, opacity: _effectiveDimAlpha);
      }
      _reveal(
        canvas,
        glyph.rect,
        glyph.direction,
        fill,
        () => layout.paintGlyph(canvas, glyph),
      );
    }
    canvas.restore();
  }

  // Cache the completed word in its raised pose. Its glow is one layer for
  // the whole word, so holding earlier words does not add per-glyph filters
  // to every subsequent playback frame.
  ui.Picture _heldRegion(_TimedGlyphRegion region, double strength) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    for (final glyph in region.glyphs) {
      final center = glyph.rect.center;
      final spread =
          (glyph.advance + glyph.rect.width / 2) / region.width - 0.5;
      final horizontal =
          spread *
          layout.em *
          0.10 *
          strength *
          (glyph.direction == TextDirection.rtl ? -1 : 1);
      canvas.save();
      canvas.translate(
        center.dx + horizontal,
        center.dy - layout.em * 0.075 * strength,
      );
      canvas.scale(1 + 0.08 * strength);
      canvas.translate(-center.dx, -center.dy);
      layout.paintGlyph(canvas, glyph);
      canvas.restore();
    }
    final ink = recorder.endRecording();
    final output = ui.PictureRecorder();
    final target = Canvas(output);
    final bounds = region.boxes
        .map((box) => box.toRect())
        .reduce((a, b) => a.expandToInclude(b))
        .inflate(layout.em * 0.5);
    if (region.span.endTime - region.span.startTime >=
        const Duration(seconds: 1)) {
      final glowPaint = Paint()
        ..color = Colors.white.withValues(alpha: strength * 0.28)
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: layout.em * 0.07,
          sigmaY: layout.em * 0.07,
        );
      // Keep the sharp, raised glyphs as their original retained commands.
      // Only the already-soft completed glow becomes a bounded image. This
      // avoids replaying its Gaussian pass on every subsequent word frame.
      final aligned = Rect.fromLTRB(
        (bounds.left * pixelRatio).floor() / pixelRatio,
        (bounds.top * pixelRatio).floor() / pixelRatio,
        (bounds.right * pixelRatio).ceil() / pixelRatio,
        (bounds.bottom * pixelRatio).ceil() / pixelRatio,
      );
      final width = (aligned.width * pixelRatio).round();
      final height = (aligned.height * pixelRatio).round();
      if (width > 0 &&
          height > 0 &&
          width <= 4096 &&
          height <= 4096 &&
          width * height + layout.heldGlowPixels <= 500000) {
        final glowRecorder = ui.PictureRecorder();
        Canvas(glowRecorder)
          ..scale(pixelRatio)
          ..translate(-aligned.left, -aligned.top)
          ..saveLayer(bounds, glowPaint)
          ..drawPicture(ink)
          ..restore();
        final glow = glowRecorder.endRecording();
        try {
          region.heldGlow = glow.toImageSync(width, height);
          layout.heldGlowPixels += width * height;
        } catch (_) {
          // Unsupported image captures retain the original glow commands.
        } finally {
          glow.dispose();
        }
      }
      final cached = region.heldGlow;
      if (cached != null) {
        target.drawImageRect(
          cached,
          Rect.fromLTWH(
            0,
            0,
            cached.width.toDouble(),
            cached.height.toDouble(),
          ),
          aligned,
          Paint()..filterQuality = FilterQuality.low,
        );
      } else {
        target.saveLayer(bounds, glowPaint);
        target.drawPicture(ink);
        target.restore();
      }
    }
    target.drawPicture(ink);
    final picture = output.endRecording();
    ink.dispose();
    return picture;
  }

  void _reveal(
    Canvas canvas,
    Rect rect,
    TextDirection direction,
    double width,
    VoidCallback draw,
  ) {
    if (width <= 0 || rect.width <= 0) return;
    final rtl = direction == TextDirection.rtl;
    canvas.save();
    if (width >= rect.width) {
      canvas.clipRect(rect);
      draw();
    } else {
      final feather = math.min(layout.em * 0.12, rect.width * 0.4);
      final boundary = rtl ? rect.right - width : rect.left + width;
      final clip = rtl
          ? Rect.fromLTRB(
              math.max(rect.left, boundary - feather),
              rect.top,
              rect.right,
              rect.bottom,
            )
          : Rect.fromLTRB(
              rect.left,
              rect.top,
              math.min(rect.right, boundary + feather),
              rect.bottom,
            );
      final edge = rtl
          ? Rect.fromLTRB(
              clip.left,
              rect.top,
              math.min(rect.right, boundary + feather),
              rect.bottom,
            )
          : Rect.fromLTRB(
              math.max(rect.left, boundary - feather),
              rect.top,
              clip.right,
              rect.bottom,
            );
      canvas.clipRect(clip);
      canvas.saveLayer(clip, Paint());
      draw();
      canvas.drawRect(
        edge,
        Paint()
          ..blendMode = BlendMode.dstIn
          ..shader = LinearGradient(
            begin: rtl ? Alignment.centerRight : Alignment.centerLeft,
            end: rtl ? Alignment.centerLeft : Alignment.centerRight,
            colors: const [Colors.white, Color(0x00FFFFFF)],
          ).createShader(edge),
      );
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TimedGlyphPainter old) =>
      old.part != part ||
      old.layout != layout ||
      old.clock != clock ||
      old.fallback != fallback ||
      old.reduceMotion != reduceMotion ||
      old.suppressWordHighlight != suppressWordHighlight ||
      old.focus != focus ||
      old.dim != dim ||
      old.pixelRatio != pixelRatio ||
      old.inkColor != inkColor;
}

/// One shared scroll displacement; rows retain their own spring velocity.
class MusicLyricFollowMotion extends ChangeNotifier {
  bool _enabled = false;
  double offset = 0;
  bool get enabled => _enabled;
  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    // Stop adding viewport displacement, but retain its coordinate origin.
    // Existing row springs can settle without jumping when a drag/tap takes over.
    notifyListeners();
  }

  void advance(double delta) {
    if (delta == 0) return;
    if (_enabled) offset += delta;
    notifyListeners();
  }
}

/// Let adjacent lines follow the actual viewport movement with a small,
/// critically damped lag. The painted transform also transforms hit testing.
class MusicLyricFollow extends StatefulWidget {
  final MusicLyricFollowMotion motion;
  final int distance;
  final Widget child;
  const MusicLyricFollow({
    super.key,
    required this.motion,
    required this.distance,
    required this.child,
  });
  @override
  State<MusicLyricFollow> createState() => _MusicLyricFollowState();
}

/// Exact critically damped step; retargeting preserves position and velocity.
/// Unlike restarting animateWith on every scroll sample, this keeps advancing
/// on the same frame clock even while the viewport supplies a moving target.
class _LyricSpringValue {
  double position;
  double velocity = 0;
  _LyricSpringValue(this.position);

  void step(double target, double omega, double seconds) {
    final displacement = position - target;
    final coefficient = velocity + omega * displacement;
    final decay = math.exp(-omega * seconds);
    position = target + (displacement + coefficient * seconds) * decay;
    velocity = (velocity - omega * coefficient * seconds) * decay;
  }

  bool settled(double target, double tolerance) =>
      (position - target).abs() < tolerance && velocity.abs() < tolerance * 10;

  void reset(double value) {
    position = value;
    velocity = 0;
  }
}

class _MusicLyricFollowState extends State<MusicLyricFollow>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  late final _LyricSpringValue _spring;
  final ValueNotifier<double> _paintOffset = ValueNotifier(0);
  Duration _lastElapsed = Duration.zero;
  MusicLyricRowClock? _rowClock;
  bool _listeningToMotion = false;
  bool get _visible => _rowClock?.activity.value ?? true;
  bool get _near => widget.distance.abs() <= 4;
  @override
  void initState() {
    super.initState();
    _spring = _LyricSpringValue(widget.motion.offset);
    _ticker = createTicker(_tick);
    _syncMotionListener();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final rowClock = MusicLyricRowFrameScope.maybeOf(context);
    if (rowClock == _rowClock) return;
    _rowClock?.activity.removeListener(_activityChanged);
    _rowClock = rowClock;
    _rowClock?.activity.addListener(_activityChanged);
    _activityChanged();
  }

  void _syncMotionListener() {
    final listen = _near && _visible;
    if (_listeningToMotion == listen) return;
    _listeningToMotion = listen;
    if (listen) {
      widget.motion.addListener(_follow);
    } else {
      widget.motion.removeListener(_follow);
    }
  }

  void _activityChanged() {
    _syncMotionListener();
    // Only fully offscreen rows are suspended. Their prefetch margin restores
    // the current viewport state before they can become visible again.
    _ticker.stop();
    _lastElapsed = Duration.zero;
    _spring.reset(widget.motion.offset);
    _paintOffset.value = 0;
  }

  @override
  void didUpdateWidget(MusicLyricFollow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.motion != widget.motion ||
        (oldWidget.distance.abs() <= 4) != _near) {
      if (_listeningToMotion) oldWidget.motion.removeListener(_follow);
      _listeningToMotion = false;
      _ticker.stop();
      _lastElapsed = Duration.zero;
      _spring.reset(widget.motion.offset);
      _paintOffset.value = 0;
      _syncMotionListener();
    }
  }

  double get _offset {
    final lag = widget.motion.offset - _spring.position;
    // A smooth bound avoids the velocity kink of clamp(-40, 40) on long rows.
    return lag / math.sqrt(1 + lag * lag / 1600);
  }

  void _follow() {
    if (!_visible) return;
    if (_spring.settled(widget.motion.offset, 0.005)) {
      _ticker.stop();
      _lastElapsed = Duration.zero;
      _spring.reset(widget.motion.offset);
      _paintOffset.value = 0;
      return;
    }
    _paintOffset.value = _offset;
    if (!_ticker.isActive) {
      _lastElapsed = Duration.zero;
      _ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    final previous = _lastElapsed;
    _lastElapsed = elapsed;
    final seconds = (elapsed - previous).inMicroseconds / 1000000;
    if (seconds <= 0) return;
    final stiffness = widget.distance <= 0
        ? 3600.0
        : 2200.0 / (1 + widget.distance * 0.35);
    _spring.step(widget.motion.offset, math.sqrt(stiffness), seconds);
    if (_spring.settled(widget.motion.offset, 0.005)) {
      _spring.reset(widget.motion.offset);
      _ticker.stop();
      _lastElapsed = Duration.zero;
    }
    _paintOffset.value = _offset;
  }

  @override
  void dispose() {
    _rowClock?.activity.removeListener(_activityChanged);
    widget.motion.removeListener(_follow);
    _ticker.dispose();
    _paintOffset.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _LyricRenderTransform(
    animation: _paintOffset,
    readTransform: () => Matrix4.translationValues(0, _paintOffset.value, 0),
    child: widget.child,
  );
}

/// The transform and hit geometry change without rebuilding a widget per tick.
class _LyricRenderTransform extends SingleChildRenderObjectWidget {
  const _LyricRenderTransform({
    required this.animation,
    required this.readTransform,
    this.alignment,
    required super.child,
  });

  final Listenable animation;
  final Matrix4 Function() readTransform;
  final Alignment? alignment;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderLyricTransform(animation, readTransform, alignment);

  @override
  void updateRenderObject(BuildContext context, _RenderLyricTransform object) {
    object
      ..animation = animation
      ..readTransform = readTransform
      ..alignment = alignment;
  }
}

class _RenderLyricTransform extends RenderTransform {
  _RenderLyricTransform(this._animation, this._readTransform, Alignment? align)
    : super(transform: _readTransform(), alignment: align);

  Listenable _animation;
  Matrix4 Function() _readTransform;

  set animation(Listenable value) {
    if (_animation == value) return;
    if (attached) _animation.removeListener(_updateTransform);
    _animation = value;
    if (attached) _animation.addListener(_updateTransform);
  }

  set readTransform(Matrix4 Function() value) {
    _readTransform = value;
    _updateTransform();
  }

  void _updateTransform() => transform = _readTransform();

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _animation.addListener(_updateTransform);
    _updateTransform();
  }

  @override
  void detach() {
    _animation.removeListener(_updateTransform);
    super.detach();
  }
}

class MusicLyricDepth extends StatefulWidget {
  final bool active;
  final int distance;
  final bool browsing;
  final Alignment alignment;
  final Widget child;
  final GlobalKey? viewportKey;
  final double anchorFraction;
  final MusicLyricFollowMotion? motion;
  final bool rasterFocus;
  final bool preserveActiveClarity;

  /// 非当前行的景深模糊。关闭后远处歌词保持清晰，只保留明暗和轻微缩放。
  final bool blurEnabled;
  const MusicLyricDepth({
    super.key,
    required this.active,
    required this.distance,
    required this.browsing,
    this.alignment = Alignment.topLeft,
    required this.child,
    this.viewportKey,
    this.anchorFraction = 0.3,
    this.motion,
    this.rasterFocus = false,
    this.preserveActiveClarity = false,
    this.blurEnabled = true,
  });
  @override
  State<MusicLyricDepth> createState() => _MusicLyricDepthState();
}

class _MusicLyricDepthState extends State<MusicLyricDepth>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  late final _LyricSpringValue _blur;
  late final _LyricSpringValue _scale;
  final ValueNotifier<int> _frames = ValueNotifier(0);
  Duration _lastElapsed = Duration.zero;
  bool _initialized = false;
  late final _LyricFocusSignal _focus;
  MusicLyricRowClock? _rowClock;
  bool _listeningToMotion = false;
  bool get _visible => _rowClock?.activity.value ?? true;

  void _onViewportMotion() {
    // Once browsing or disabled blur has settled at zero, scrolling changes
    // only the row's position. Its clear text pixels remain reusable.
    if (_initialized && _visible && !_reduced && _blur.position > 0) {
      _focus.invalidate();
    }
  }

  double _readFocus() {
    if (_reduced) return 0;
    final row = context.findRenderObject();
    final viewport = widget.viewportKey?.currentContext?.findRenderObject();
    if (row is RenderBox &&
        viewport is RenderBox &&
        row.hasSize &&
        viewport.hasSize) {
      final anchor = viewport.size.height * widget.anchorFraction;
      final distance =
          (row.localToGlobal(Offset.zero, ancestor: viewport).dy - anchor)
              .abs() /
          math.max(64, row.size.height);
      return (distance * 0.75 / 2.5).clamp(0.0, 1.0) *
          (_blur.position / 2.5).clamp(0.0, 1.0);
    }
    return (_blur.position / 2.5).clamp(0.0, 1.0);
  }

  bool _reduced = false;
  bool _mobile = false;
  bool get _layerFocus => widget.rasterFocus && _mobile;

  double _readLayerBlur() {
    final t = _readFocus();
    // Match the variance of the existing three-kernel focus blend with one
    // composited filter, avoiding per-paragraph images and additive layers.
    return 1.25 * math.sqrt(2 * t * (1 + t));
  }

  double get _targetScale => widget.active || _reduced ? 1.0 : 0.96;

  /// 模糊关掉时目标直接归零，弹簧会从当前虚化收到清晰，而不是瞬间切图层。
  double get _targetBlur {
    if (!widget.blurEnabled) return 0;
    if (widget.rasterFocus) {
      return _reduced || widget.browsing || widget.preserveActiveClarity
          ? 0
          : 2.5;
    }
    if (widget.active || widget.browsing || _reduced) return 0;
    return math.min(2.5, widget.distance.abs() * 0.75);
  }

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    _focus = _LyricFocusSignal(_readFocus);
    _syncMotionListener();
  }

  void _syncMotionListener() {
    final listen = _visible && widget.motion != null;
    if (listen == _listeningToMotion) return;
    _listeningToMotion = listen;
    if (listen) {
      widget.motion?.addListener(_onViewportMotion);
    } else {
      widget.motion?.removeListener(_onViewportMotion);
    }
  }

  void _activityChanged() {
    _syncMotionListener();
    if (!_initialized) return;
    _retarget();
    _frames.value++;
    _focus.invalidate();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final rowClock = MusicLyricRowFrameScope.maybeOf(context);
    if (rowClock != _rowClock) {
      _rowClock?.activity.removeListener(_activityChanged);
      _rowClock = rowClock;
      _rowClock?.activity.addListener(_activityChanged);
      _syncMotionListener();
    }
    _reduced = MediaQuery.disableAnimationsOf(context);
    final platform = Theme.of(context).platform;
    _mobile =
        platform == TargetPlatform.android || platform == TargetPlatform.iOS;
    if (!_initialized) {
      _blur = _LyricSpringValue(_targetBlur);
      _scale = _LyricSpringValue(_targetScale);
      _initialized = true;
    } else {
      _retarget();
    }
  }

  @override
  void didUpdateWidget(MusicLyricDepth oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.motion != widget.motion) {
      if (_listeningToMotion) {
        oldWidget.motion?.removeListener(_onViewportMotion);
      }
      _listeningToMotion = false;
      _syncMotionListener();
    }
    _retarget();
  }

  void _retarget() {
    if (_reduced || !_visible) {
      _ticker.stop();
      _lastElapsed = Duration.zero;
      _blur.reset(_targetBlur);
      _scale.reset(_targetScale);
    } else if ((!_blur.settled(_targetBlur, 0.0001) ||
            !_scale.settled(_targetScale, 0.00001)) &&
        !_ticker.isActive) {
      _lastElapsed = Duration.zero;
      _ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    final previous = _lastElapsed;
    _lastElapsed = elapsed;
    final seconds = (elapsed - previous).inMicroseconds / 1000000;
    if (seconds <= 0) return;
    // One continuous clock for blur and scale, matching the scroll's damped
    // approach. A new cue changes only the targets, never the current velocity.
    _blur.step(_targetBlur, 10, seconds);
    _scale.step(_targetScale, 10, seconds);
    if (_blur.settled(_targetBlur, 0.0001) &&
        _scale.settled(_targetScale, 0.00001)) {
      _blur.reset(_targetBlur);
      _scale.reset(_targetScale);
      _ticker.stop();
      _lastElapsed = Duration.zero;
    }
    _frames.value++;
    _focus.invalidate();
  }

  @override
  void dispose() {
    _rowClock?.activity.removeListener(_activityChanged);
    widget.motion?.removeListener(_onViewportMotion);
    _focus.dispose();
    _ticker.dispose();
    _frames.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_layerFocus) {
      return _LyricRenderTransform(
        animation: _frames,
        readTransform: () {
          final scale = _scale.position.clamp(0.96, 1.0);
          return Matrix4.diagonal3Values(scale, scale, 1);
        },
        alignment: widget.alignment,
        child: _SpatialLyricFilter(
          repaint: _focus,
          readBlur: _readLayerBlur,
          readEnabled: () =>
              !_reduced && (widget.blurEnabled || _blur.position > 0),
          enabled: !_reduced && (widget.blurEnabled || _blur.position > 0),
          child: widget.child,
        ),
      );
    }
    return AnimatedBuilder(
      animation: _frames,
      child: widget.rasterFocus && !_layerFocus
          ? _LyricFocusScope(signal: _focus, child: widget.child)
          : widget.child,
      builder: (context, child) => Transform.scale(
        scale: _scale.position.clamp(0.96, 1.0),
        alignment: widget.alignment,
        child: _layerFocus
            ? _SpatialLyricFilter(
                repaint: _focus,
                readBlur: _readLayerBlur,
                enabled:
                    !_reduced && (widget.blurEnabled || _blur.position > 0),
                child: child!,
              )
            : ImageFiltered(
                imageFilter: ui.ImageFilter.blur(
                  sigmaX: widget.rasterFocus ? 0 : math.max(0, _blur.position),
                  sigmaY: widget.rasterFocus ? 0 : math.max(0, _blur.position),
                ),
                // Keep the compositing boundary through zero, including a retarget.
                enabled: !_reduced,
                child: child,
              ),
      ),
    );
  }
}

/// Sample the laid-out row position when updating its retained layer. Scroll
/// notifications can arrive after build; they must not rebuild or repaint the
/// paragraph subtree just to change its focus.
class _SpatialLyricFilter extends ImageFiltered {
  static final _identity = ui.ImageFilter.blur(sigmaX: 0, sigmaY: 0);
  final Listenable repaint;
  final double Function() readBlur;
  final bool Function()? readEnabled;

  _SpatialLyricFilter({
    required this.repaint,
    required this.readBlur,
    this.readEnabled,
    required super.enabled,
    required Widget child,
  }) : super(imageFilter: _identity, child: child);

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSpatialLyricFilter(repaint, readBlur, enabled, readEnabled);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderSpatialLyricFilter)
      ..repaint = repaint
      ..enabled = enabled
      ..readEnabled = readEnabled
      ..readBlur = readBlur;
  }
}

class _RenderSpatialLyricFilter extends RenderProxyBox {
  Listenable _repaint;
  double Function() _readBlur;
  bool _enabled;
  bool Function()? readEnabled;
  double? _lastBlur;
  ui.ImageFilter? _filter;

  _RenderSpatialLyricFilter(
    this._repaint,
    this._readBlur,
    this._enabled,
    this.readEnabled,
  );

  set repaint(Listenable value) {
    if (value == _repaint) return;
    if (attached) _repaint.removeListener(_updateFilter);
    _repaint = value;
    if (attached) _repaint.addListener(_updateFilter);
  }

  set readBlur(double Function() value) {
    _readBlur = value;
    _updateFilter();
  }

  set enabled(bool value) {
    if (value == _enabled) return;
    final wasBoundary = isRepaintBoundary;
    _enabled = value;
    if (wasBoundary != isRepaintBoundary) markNeedsCompositingBitsUpdate();
    markNeedsPaint();
  }

  void _updateFilter() {
    if (readEnabled != null) enabled = readEnabled!();
    if (_enabled) markNeedsCompositedLayerUpdate();
  }

  @override
  bool get alwaysNeedsCompositing => child != null && _enabled;

  @override
  bool get isRepaintBoundary => alwaysNeedsCompositing;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _repaint.addListener(_updateFilter);
  }

  @override
  void detach() {
    _repaint.removeListener(_updateFilter);
    super.detach();
  }

  @override
  OffsetLayer updateCompositedLayer({
    required covariant ImageFilterLayer? oldLayer,
  }) {
    final layer = oldLayer ?? ImageFilterLayer();
    final blur = _readBlur().clamp(0.0, 2.5);
    if (_lastBlur != blur || _filter == null) {
      _lastBlur = blur;
      _filter = ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur);
    }
    layer.imageFilter = _filter;
    return layer;
  }
}

/// Derived from explicit cue gaps, never from gap-filled subtitle display times.
class MusicLyricInterlude extends StatelessWidget {
  final Duration start;
  final Duration end;
  final ValueListenable<Duration>? clock;
  final double em;
  const MusicLyricInterlude({
    super.key,
    required this.start,
    required this.end,
    this.clock,
    required this.em,
  });
  @override
  Widget build(BuildContext context) {
    final row = MusicLyricRowFrameScope.maybeOf(context);
    final effectiveClock = clock != null && identical(row?.owner.source, clock)
        ? row ?? clock
        : clock;
    return IgnorePointer(
      child: SizedBox(
        width: em * 1.6,
        height: em,
        child: CustomPaint(
          painter: _InterludePainter(
            start,
            end,
            effectiveClock,
            em,
            MediaQuery.disableAnimationsOf(context),
          ),
        ),
      ),
    );
  }
}

class _InterludePainter extends CustomPainter {
  final Duration start;
  final Duration end;
  final ValueListenable<Duration>? clock;
  final double em;
  final bool reduced;
  _InterludePainter(this.start, this.end, this.clock, this.em, this.reduced)
    : super(repaint: clock);

  @override
  void paint(Canvas canvas, Size size) {
    final now = clock?.value ?? Duration.zero;
    if (now < start || now >= end) return;
    final elapsed = (now - start).inMilliseconds;
    final remaining = (end - now).inMilliseconds;
    final fade = math.min(1.0, math.min(elapsed / 200, remaining / 200));
    final unit = math.min(em, size.width / 1.6);
    for (var i = 0; i < 3; i++) {
      final breathe = reduced
          ? 1.0
          : 0.7 + 0.3 * math.sin((elapsed / 4000 - i * 0.12) * math.pi * 2);
      canvas.drawCircle(
        Offset(unit * (0.2 + i * 0.48), size.height * 0.5),
        unit * 0.12 * breathe,
        Paint()..color = Colors.white.withValues(alpha: 0.85 * fade * breathe),
      );
    }
  }

  @override
  bool shouldRepaint(_InterludePainter old) =>
      old.start != start ||
      old.end != end ||
      old.clock != clock ||
      old.em != em ||
      old.reduced != reduced;
}
