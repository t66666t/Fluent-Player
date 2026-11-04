import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:flutter/services.dart';

import '../models/ocr_subtitle_models.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

typedef OcrRegionFrameLoader = Future<String> Function(Duration position);
typedef OcrRegionFrameReleaser = Future<void> Function(String? path);

Future<List<NormalizedOcrRegion>?> showOcrRegionEditor(
  BuildContext context, {
  required String framePath,
  required List<NormalizedOcrRegion> initialRegions,
  required Duration duration,
  required Duration initialPosition,
  required OcrRegionFrameLoader loadFrameAt,
  OcrRegionFrameLoader? loadFastFrameAt,
  required OcrRegionFrameReleaser releaseFrame,
}) => Navigator.of(context).push<List<NormalizedOcrRegion>>(
  AppMaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => OcrRegionEditor(
      framePath: framePath,
      initialRegions: initialRegions,
      duration: duration,
      initialPosition: initialPosition,
      loadFrameAt: loadFrameAt,
      loadFastFrameAt: loadFastFrameAt,
      releaseFrame: releaseFrame,
    ),
  ),
);

class OcrRegionEditor extends StatefulWidget {
  final String framePath;
  final List<NormalizedOcrRegion> initialRegions;
  final Duration duration;
  final Duration initialPosition;
  final OcrRegionFrameLoader? loadFrameAt;
  final OcrRegionFrameLoader? loadFastFrameAt;
  final OcrRegionFrameReleaser? releaseFrame;
  const OcrRegionEditor({
    super.key,
    required this.framePath,
    required this.initialRegions,
    this.duration = Duration.zero,
    this.initialPosition = Duration.zero,
    this.loadFrameAt,
    this.loadFastFrameAt,
    this.releaseFrame,
  });

  @override
  State<OcrRegionEditor> createState() => _OcrRegionEditorState();
}

enum _DragMode {
  none,
  create,
  move,
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
}

class _OcrRegionEditorState extends State<OcrRegionEditor> {
  final FocusNode _focusNode = FocusNode();
  ui.Image? _image;
  int? _sourceWidth;
  int? _sourceHeight;
  late List<NormalizedOcrRegion> _regions;
  late double _timelineMs;
  bool _timelineLoading = false;
  String? _timelineFramePath;
  double? _pendingTimelineMs;
  bool _pendingTimelinePrecise = false;
  bool _timelineWorkerRunning = false;
  int _timelineRequestSerial = 0;
  Timer? _timelineSettleTimer;
  int _selectedIndex = 0;
  _DragMode _dragMode = _DragMode.none;
  Offset? _pointerStart;
  NormalizedOcrRegion? _regionStart;
  PointerDeviceKind _pointerKind = PointerDeviceKind.touch;
  bool _dragStarted = false;
  double _zoom = 1;
  Offset _pan = Offset.zero;
  Offset? _pointerLocal;
  bool _pinching = false;
  double _scaleStartZoom = 1;
  Offset _scaleStartPan = Offset.zero;
  Offset _scaleStartFocal = Offset.zero;

  @override
  void initState() {
    super.initState();
    _regions = widget.initialRegions.isEmpty
        ? <NormalizedOcrRegion>[const NormalizedOcrRegion.subtitleDefault()]
        : widget.initialRegions
              .take(5)
              .map((region) => region.normalized())
              .toList();
    final durationMs = math.max(0, widget.duration.inMilliseconds);
    _timelineMs = widget.initialPosition.inMilliseconds
        .clamp(0, durationMs)
        .toDouble();
    _loadImage();
  }

  NormalizedOcrRegion get _region => _regions[_selectedIndex];

  void _replaceSelected(NormalizedOcrRegion region) {
    _regions[_selectedIndex] = region.normalized();
  }

  Future<void> _loadImage() async {
    final bytes = await File(widget.framePath).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    if (!mounted) {
      frame.image.dispose();
      return;
    }
    setState(() {
      _image = frame.image;
      _sourceWidth = frame.image.width;
      _sourceHeight = frame.image.height;
    });
  }

  @override
  void dispose() {
    _timelineRequestSerial++;
    _timelineSettleTimer?.cancel();
    _focusNode.dispose();
    _image?.dispose();
    final timelineFramePath = _timelineFramePath;
    if (timelineFramePath != null) {
      unawaited(widget.releaseFrame?.call(timelineFramePath));
    }
    super.dispose();
  }

  bool get _hasTimeline =>
      widget.duration > Duration.zero && widget.loadFrameAt != null;

  void _queueTimelineFrame(double value, {bool precise = false}) {
    final maxMs = math.max(0, widget.duration.inMilliseconds).toDouble();
    final next = value.clamp(0.0, maxMs);
    setState(() {
      _timelineMs = next;
      _pendingTimelineMs = next;
      _pendingTimelinePrecise = precise;
      _timelineLoading = true;
    });
    _timelineRequestSerial++;
    _timelineSettleTimer?.cancel();
    if (!precise) {
      _timelineSettleTimer = Timer(const Duration(milliseconds: 150), () {
        if (mounted) _queueTimelineFrame(_timelineMs, precise: true);
      });
    }
    if (!_timelineWorkerRunning) unawaited(_runTimelineWorker());
  }

  Future<void> _runTimelineWorker() async {
    if (_timelineWorkerRunning) return;
    _timelineWorkerRunning = true;
    try {
      while (mounted && _pendingTimelineMs != null) {
        final requestMs = _pendingTimelineMs!;
        final precise = _pendingTimelinePrecise;
        _pendingTimelineMs = null;
        final serial = _timelineRequestSerial;
        String? path;
        try {
          final loader = precise
              ? widget.loadFrameAt!
              : widget.loadFastFrameAt ?? widget.loadFrameAt!;
          path = await loader(Duration(milliseconds: requestMs.round()));
          final bytes = await File(path).readAsBytes();
          final codec = await ui.instantiateImageCodec(bytes);
          final frame = await codec.getNextFrame();
          codec.dispose();
          if (!mounted) {
            frame.image.dispose();
            await widget.releaseFrame?.call(path);
            break;
          }
          final previousImage = _image;
          final previousPath = _timelineFramePath;
          setState(() {
            _image = frame.image;
            _timelineFramePath = path;
            _timelineLoading =
                serial != _timelineRequestSerial || _pendingTimelineMs != null;
            _zoom = 1;
            _pan = Offset.zero;
          });
          previousImage?.dispose();
          if (previousPath != null && previousPath != path) {
            await widget.releaseFrame?.call(previousPath);
          }
        } catch (_) {
          if (path != null) await widget.releaseFrame?.call(path);
          if (mounted && serial == _timelineRequestSerial) {
            setState(() => _timelineLoading = false);
          }
        }
      }
    } finally {
      _timelineWorkerRunning = false;
      if (mounted && _pendingTimelineMs != null) {
        unawaited(_runTimelineWorker());
      }
    }
  }

  void _skipTimeline(Duration delta) {
    if (!_hasTimeline) return;
    _queueTimelineFrame(_timelineMs + delta.inMilliseconds);
  }

  void _hoverTimeline(PointerHoverEvent event, double width) {
    if (!_hasTimeline || width <= 20) return;
    const thumbInset = 10.0;
    final fraction =
        ((event.localPosition.dx - thumbInset) / (width - thumbInset * 2))
            .clamp(0.0, 1.0);
    final next = widget.duration.inMilliseconds * fraction;
    if ((next - _timelineMs).abs() < 0.5) return;
    _queueTimelineFrame(next);
  }

  String _formatTimelineTime(double milliseconds) {
    final duration = Duration(milliseconds: milliseconds.round());
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  Rect _imageRect(Size size) {
    final image = _image;
    if (image == null) return Rect.zero;
    final ratio = image.width / image.height;
    var width = size.width;
    var height = width / ratio;
    if (height > size.height) {
      height = size.height;
      width = height * ratio;
    }
    final base = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: width,
      height: height,
    );
    return Rect.fromCenter(
      center: base.center + _pan,
      width: base.width * _zoom,
      height: base.height * _zoom,
    );
  }

  Rect _selectionRect(Rect imageRect, NormalizedOcrRegion region) =>
      Rect.fromLTRB(
        imageRect.left + region.left * imageRect.width,
        imageRect.top + region.top * imageRect.height,
        imageRect.left + region.right * imageRect.width,
        imageRect.top + region.bottom * imageRect.height,
      );

  Offset _normalizedPoint(Offset local, Rect imageRect) => Offset(
    ((local.dx - imageRect.left) / imageRect.width).clamp(0.0, 1.0),
    ((local.dy - imageRect.top) / imageRect.height).clamp(0.0, 1.0),
  );

  _DragMode _hitTest(Offset point, Rect selection) {
    final hit = _pointerKind == PointerDeviceKind.touch ? 48.0 : 18.0;
    final corners = <_DragMode, Offset>{
      _DragMode.topLeft: selection.topLeft,
      _DragMode.topRight: selection.topRight,
      _DragMode.bottomLeft: selection.bottomLeft,
      _DragMode.bottomRight: selection.bottomRight,
    };
    for (final entry in corners.entries) {
      if ((point - entry.value).distance <= hit / 2) return entry.key;
    }
    if (selection.contains(point)) return _DragMode.move;
    return _DragMode.create;
  }

  void _pointerDown(PointerDownEvent event, Rect imageRect) {
    if (_pinching) return;
    if (!imageRect.contains(event.localPosition)) return;
    _focusNode.requestFocus();
    _pointerKind = event.kind;
    final selectedRect = _selectionRect(imageRect, _region);
    var hitIndex = _selectedIndex;
    var mode = _hitTest(event.localPosition, selectedRect);
    if (mode == _DragMode.create) {
      mode = _DragMode.none;
      for (var index = _regions.length - 1; index >= 0; index--) {
        final rect = _selectionRect(imageRect, _regions[index]);
        if (rect.contains(event.localPosition)) {
          hitIndex = index;
          mode = _DragMode.move;
          break;
        }
      }
    }
    if (mode == _DragMode.none) return;
    if (hitIndex != _selectedIndex) {
      setState(() => _selectedIndex = hitIndex);
    }
    _pointerLocal = event.localPosition;
    _pointerStart = _normalizedPoint(event.localPosition, imageRect);
    _regionStart = _regions[hitIndex];
    _dragMode = mode;
    _dragStarted = false;
  }

  void _pointerMove(PointerMoveEvent event, Rect imageRect) {
    if (_pinching) return;
    final start = _pointerStart;
    final original = _regionStart;
    if (start == null || original == null) return;
    _pointerLocal = event.localPosition;
    final current = _normalizedPoint(event.localPosition, imageRect);
    final threshold =
        (_pointerKind == PointerDeviceKind.touch ? 6.0 : 3.0) /
        math.max(imageRect.width, imageRect.height);
    if (!_dragStarted && (current - start).distance < threshold) {
      setState(() {});
      return;
    }
    _dragStarted = true;
    final dx = current.dx - start.dx;
    final dy = current.dy - start.dy;
    late NormalizedOcrRegion next;
    switch (_dragMode) {
      case _DragMode.create:
        next = NormalizedOcrRegion(
          left: math.min(start.dx, current.dx),
          top: math.min(start.dy, current.dy),
          right: math.max(start.dx, current.dx),
          bottom: math.max(start.dy, current.dy),
        );
      case _DragMode.move:
        final moveX = dx.clamp(-original.left, 1 - original.right);
        final moveY = dy.clamp(-original.top, 1 - original.bottom);
        next = NormalizedOcrRegion(
          left: original.left + moveX,
          top: original.top + moveY,
          right: original.right + moveX,
          bottom: original.bottom + moveY,
        );
      case _DragMode.topLeft:
        next = NormalizedOcrRegion(
          left: current.dx,
          top: current.dy,
          right: original.right,
          bottom: original.bottom,
        );
      case _DragMode.topRight:
        next = NormalizedOcrRegion(
          left: original.left,
          top: current.dy,
          right: current.dx,
          bottom: original.bottom,
        );
      case _DragMode.bottomLeft:
        next = NormalizedOcrRegion(
          left: current.dx,
          top: original.top,
          right: original.right,
          bottom: current.dy,
        );
      case _DragMode.bottomRight:
        next = NormalizedOcrRegion(
          left: original.left,
          top: original.top,
          right: current.dx,
          bottom: current.dy,
        );
      case _DragMode.none:
        return;
    }
    setState(() => _replaceSelected(next));
  }

  void _pointerUp(PointerEvent event) {
    if (!mounted) return;
    setState(() {
      _pointerStart = null;
      _regionStart = null;
      _dragMode = _DragMode.none;
      _dragStarted = false;
      _pointerLocal = null;
    });
  }

  void _scaleStart(ScaleStartDetails details) {
    if (details.pointerCount < 2) return;
    _pinching = true;
    _pointerUp(const PointerCancelEvent());
    _scaleStartZoom = _zoom;
    _scaleStartPan = _pan;
    _scaleStartFocal = details.localFocalPoint;
  }

  void _scaleUpdate(ScaleUpdateDetails details) {
    if (!_pinching || details.pointerCount < 2) return;
    setState(() {
      _zoom = (_scaleStartZoom * details.scale).clamp(1.0, 5.0);
      _pan = _scaleStartPan + (details.localFocalPoint - _scaleStartFocal);
    });
  }

  void _scaleEnd(ScaleEndDetails details) {
    _pinching = false;
  }

  void _pointerSignal(PointerSignalEvent event, Size viewport) {
    if (event is! PointerScrollEvent) return;
    final oldRect = _imageRect(viewport);
    final sourcePoint = Offset(
      (event.localPosition.dx - oldRect.left) / oldRect.width,
      (event.localPosition.dy - oldRect.top) / oldRect.height,
    );
    final factor = event.scrollDelta.dy < 0 ? 1.15 : 1 / 1.15;
    final nextZoom = (_zoom * factor).clamp(1.0, 5.0);
    if (nextZoom == _zoom) return;
    setState(() {
      _zoom = nextZoom;
      final nextRect = _imageRect(viewport);
      final nextPoint = Offset(
        nextRect.left + sourcePoint.dx * nextRect.width,
        nextRect.top + sourcePoint.dy * nextRect.height,
      );
      _pan += event.localPosition - nextPoint;
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.pop(context);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      Navigator.pop(context, List<NormalizedOcrRegion>.from(_regions));
      return KeyEventResult.handled;
    }
    final image = _image;
    if (image == null) return KeyEventResult.ignored;
    final sourceWidth = _sourceWidth ?? image.width;
    final sourceHeight = _sourceHeight ?? image.height;
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    final stepPixels =
        keys.contains(LogicalKeyboardKey.shiftLeft) ||
            keys.contains(LogicalKeyboardKey.shiftRight)
        ? 10.0
        : 1.0;
    var dx = 0.0;
    var dy = 0.0;
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      dx = -stepPixels / sourceWidth;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      dx = stepPixels / sourceWidth;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      dy = -stepPixels / sourceHeight;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      dy = stepPixels / sourceHeight;
    }
    if (dx == 0 && dy == 0) return KeyEventResult.ignored;
    dx = dx.clamp(-_region.left, 1 - _region.right);
    dy = dy.clamp(-_region.top, 1 - _region.bottom);
    setState(
      () => _replaceSelected(
        NormalizedOcrRegion(
          left: _region.left + dx,
          top: _region.top + dy,
          right: _region.right + dx,
          bottom: _region.bottom + dy,
        ),
      ),
    );
    return KeyEventResult.handled;
  }

  void _addRegion() {
    if (_regions.length >= 5) return;
    final index = _regions.length;
    const height = 0.16;
    final bottom = (0.70 - (index - 1) * 0.18).clamp(height, 0.70);
    final region = NormalizedOcrRegion(
      left: 0.08,
      top: bottom - height,
      right: 0.92,
      bottom: bottom,
    ).normalized();
    setState(() {
      _regions.add(region);
      _selectedIndex = _regions.length - 1;
    });
  }

  void _deleteSelected() {
    if (_regions.length <= 1) return;
    setState(() {
      _regions.removeAt(_selectedIndex);
      _selectedIndex = _selectedIndex.clamp(0, _regions.length - 1);
    });
  }

  void _mergeWith(int otherIndex) {
    if (otherIndex < 0 || otherIndex >= _regions.length) return;
    if (otherIndex == _selectedIndex) return;
    final firstIndex = math.min(_selectedIndex, otherIndex);
    final secondIndex = math.max(_selectedIndex, otherIndex);
    final merged = _regions[firstIndex].union(_regions[secondIndex]);
    setState(() {
      _regions[firstIndex] = merged;
      _regions.removeAt(secondIndex);
      _selectedIndex = firstIndex;
    });
  }

  void _resetRegions() {
    setState(() {
      _regions = <NormalizedOcrRegion>[
        const NormalizedOcrRegion.subtitleDefault(),
      ];
      _selectedIndex = 0;
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) =>
        _buildEditor(context, constraints.maxWidth),
  );

  Widget _buildEditor(BuildContext context, double width) {
    final image = _image;
    final availableWidth = width - MediaQuery.paddingOf(context).horizontal;
    final compactToolbar = availableWidth < 640;
    final actionStyle = IconButton.styleFrom(
      fixedSize: const Size.square(48),
      minimumSize: const Size.square(48),
      maximumSize: const Size.square(48),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.standard,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      foregroundColor: Colors.white,
      disabledForegroundColor: Colors.white38,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );
    final regionActions = <Widget>[
      DesktopButtonClickRegion(
        child: IconButton(
          tooltip: '新增字幕区域（最多 5 个）',
          style: actionStyle,
          iconSize: 22,
          onPressed: _regions.length >= 5 ? null : _addRegion,
          icon: const Icon(Icons.add_box_outlined),
        ),
      ),
      DesktopButtonClickRegion(
        child: IconButton(
          tooltip: '删除当前区域',
          style: actionStyle,
          iconSize: 22,
          onPressed: _regions.length <= 1 ? null : _deleteSelected,
          icon: const Icon(Icons.delete_outline),
        ),
      ),
      DesktopButtonClickRegion(
        child: IconButton(
          tooltip: '与上方区域合并',
          style: actionStyle,
          iconSize: 22,
          onPressed: _selectedIndex > 0
              ? () => _mergeWith(_selectedIndex - 1)
              : null,
          icon: const Icon(Icons.vertical_align_top),
        ),
      ),
      DesktopButtonClickRegion(
        child: IconButton(
          tooltip: '与下方区域合并',
          style: actionStyle,
          iconSize: 22,
          onPressed: _selectedIndex < _regions.length - 1
              ? () => _mergeWith(_selectedIndex + 1)
              : null,
          icon: const Icon(Icons.vertical_align_bottom),
        ),
      ),
      DesktopButtonClickRegion(
        child: IconButton(
          tooltip: '重置全部区域',
          style: actionStyle,
          iconSize: 22,
          onPressed: _resetRegions,
          icon: const Icon(Icons.restart_alt),
        ),
      ),
    ];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF17191D),
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
        leading: Center(
          child: DesktopButtonClickRegion(
            child: IconButton(
              tooltip: '取消',
              style: actionStyle,
              iconSize: 22,
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
          ),
        ),
        title: Text(
          '字幕区域 ${_selectedIndex + 1}/${_regions.length}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (!compactToolbar) ...[
            Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 4,
              children: regionActions,
            ),
            const SizedBox(width: 8),
            const SizedBox(
              height: 24,
              child: VerticalDivider(width: 1, color: Colors.white12),
            ),
            const SizedBox(width: 8),
          ],
          DesktopButtonClickRegion(
            child: IconButton(
              tooltip: '确认区域',
              style: actionStyle.copyWith(
                foregroundColor: const WidgetStatePropertyAll(
                  Color(0xFF8EBBFF),
                ),
                backgroundColor: const WidgetStatePropertyAll(
                  Color(0x1F65A2FF),
                ),
              ),
              iconSize: 24,
              onPressed: () => Navigator.pop(
                context,
                List<NormalizedOcrRegion>.from(_regions),
              ),
              icon: const Icon(Icons.check),
            ),
          ),
          const SizedBox(width: 12),
        ],
        bottom: compactToolbar
            ? PreferredSize(
                preferredSize: const Size.fromHeight(56),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    spacing: 4,
                    children: regionActions,
                  ),
                ),
              )
            : null,
      ),
      body: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _onKey,
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (image == null) {
              return const Center(child: CircularProgressIndicator());
            }
            final size = Size(constraints.maxWidth, constraints.maxHeight);
            final imageRect = _imageRect(size);
            final selections = [
              for (final region in _regions) _selectionRect(imageRect, region),
            ];
            return GestureDetector(
              key: const ValueKey('ocr_region_canvas'),
              behavior: HitTestBehavior.opaque,
              onScaleStart: _scaleStart,
              onScaleUpdate: _scaleUpdate,
              onScaleEnd: _scaleEnd,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (e) => _pointerDown(e, imageRect),
                onPointerMove: (e) => _pointerMove(e, imageRect),
                onPointerUp: _pointerUp,
                onPointerCancel: _pointerUp,
                onPointerSignal: (e) => _pointerSignal(e, size),
                child: Stack(
                  children: [
                    Positioned.fromRect(
                      rect: imageRect,
                      child: RawImage(image: image, fit: BoxFit.fill),
                    ),
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _RegionPainter(
                          imageRect,
                          selections,
                          _selectedIndex,
                        ),
                      ),
                    ),
                    if (_zoom > 1 && _pointerLocal != null)
                      Positioned(
                        left: (_pointerLocal!.dx + 20).clamp(
                          8,
                          math.max(8, size.width - 128),
                        ),
                        top: (_pointerLocal!.dy - 96).clamp(
                          8,
                          math.max(8, size.height - 88),
                        ),
                        child: IgnorePointer(
                          child: CustomPaint(
                            size: const Size(120, 80),
                            painter: _PixelMagnifierPainter(
                              image: image,
                              sourcePoint: _normalizedPoint(
                                _pointerLocal!,
                                imageRect,
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (_timelineLoading)
                      const Positioned(
                        right: 12,
                        top: 12,
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Color(0xCC17191D),
                              shape: BoxShape.circle,
                            ),
                            child: Padding(
                              padding: EdgeInsets.all(9),
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.2,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
      bottomNavigationBar: image == null
          ? null
          : SafeArea(
              top: false,
              child: Container(
                color: const Color(0xFF17191D),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_hasTimeline)
                      _buildTimeline(widget.duration.inMilliseconds.toDouble()),
                    Container(
                      key: const ValueKey('ocr_region_info_bar'),
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: const BoxDecoration(
                        border: Border(top: BorderSide(color: Colors.white12)),
                      ),
                      child: Text(
                        '区域 ${_selectedIndex + 1} · '
                        '${(_region.left * (_sourceWidth ?? image.width)).round()}, '
                        '${(_region.top * (_sourceHeight ?? image.height)).round()} · '
                        '${(_region.width * (_sourceWidth ?? image.width)).round()} × '
                        '${(_region.height * (_sourceHeight ?? image.height)).round()} px\n'
                        '点 + 新增，点框切换；拖动框内移动，拖动四角缩放',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildTimeline(double maxMs) => Container(
    key: const ValueKey('ocr_region_timeline'),
    padding: const EdgeInsets.fromLTRB(8, 5, 8, 2),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Text(
                _formatTimelineTime(_timelineMs),
                style: const TextStyle(
                  color: Color(0xFF8EBBFF),
                  fontSize: 12,
                  fontFeatures: <ui.FontFeature>[
                    ui.FontFeature.tabularFigures(),
                  ],
                ),
              ),
              const Spacer(),
              Text(
                _formatTimelineTime(maxMs),
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                  fontFeatures: <ui.FontFeature>[
                    ui.FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ],
          ),
        ),
        Row(
          children: [
            DesktopButtonClickRegion(
              child: IconButton(
                key: const ValueKey('ocr_timeline_back_10'),
                tooltip: '后退 10 秒',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: _timelineLoading
                    ? null
                    : () => _skipTimeline(const Duration(seconds: -10)),
                icon: const Icon(Icons.replay_10, color: Colors.white70),
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => MouseRegion(
                  key: const ValueKey('ocr_timeline_hover_region'),
                  cursor: SystemMouseCursors.click,
                  onHover: (event) =>
                      _hoverTimeline(event, constraints.maxWidth),
                  child: SizedBox(
                    height: 48,
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: const Color(0xFF65A2FF),
                        inactiveTrackColor: Colors.white24,
                        thumbColor: const Color(0xFF8EBBFF),
                        overlayColor: const Color(0x3365A2FF),
                        trackHeight: 6,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 10,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 24,
                        ),
                      ),
                      child: Slider(
                        key: const ValueKey('ocr_timeline_slider'),
                        min: 0,
                        max: math.max(1, maxMs),
                        value: _timelineMs.clamp(0, math.max(1, maxMs)),
                        onChanged: _queueTimelineFrame,
                        onChangeEnd: (value) =>
                            _queueTimelineFrame(value, precise: true),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            DesktopButtonClickRegion(
              child: IconButton(
                key: const ValueKey('ocr_timeline_forward_10'),
                tooltip: '前进 10 秒',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: _timelineLoading
                    ? null
                    : () => _skipTimeline(const Duration(seconds: 10)),
                icon: const Icon(Icons.forward_10, color: Colors.white70),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _RegionPainter extends CustomPainter {
  final Rect imageRect;
  final List<Rect> selections;
  final int selectedIndex;
  const _RegionPainter(this.imageRect, this.selections, this.selectedIndex);

  @override
  void paint(Canvas canvas, Size size) {
    final shade = Paint()..color = Colors.black.withValues(alpha: 0.58);
    final cutouts = Path();
    for (final selection in selections) {
      cutouts.addRect(selection);
    }
    final outside = Path.combine(
      PathOperation.difference,
      Path()..addRect(imageRect),
      cutouts,
    );
    canvas.drawPath(outside, shade);
    for (var index = 0; index < selections.length; index++) {
      final selection = selections[index];
      final selected = index == selectedIndex;
      final color = selected
          ? const Color(0xFF64A7FF)
          : const Color(0xFFFFC857);
      canvas.drawRect(
        selection,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = selected ? 3 : 2,
      );
      if (selected) {
        final handle = Paint()..color = Colors.white;
        for (final point in [
          selection.topLeft,
          selection.topRight,
          selection.bottomLeft,
          selection.bottomRight,
        ]) {
          canvas.drawCircle(point, 6, handle);
          canvas.drawCircle(
            point,
            6,
            Paint()
              ..color = const Color(0xFF287DFF)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2,
          );
        }
      }
      final badge = Rect.fromLTWH(
        selection.left + 5,
        selection.top + 5,
        24,
        24,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(badge, const Radius.circular(6)),
        Paint()..color = color,
      );
      final textPainter = TextPainter(
        text: TextSpan(
          text: '${index + 1}',
          style: const TextStyle(
            color: Colors.black,
            fontSize: 13,
            fontWeight: FontWeight.w800,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(
        canvas,
        badge.center - Offset(textPainter.width / 2, textPainter.height / 2),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RegionPainter oldDelegate) =>
      oldDelegate.imageRect != imageRect ||
      oldDelegate.selectedIndex != selectedIndex ||
      !_sameRects(oldDelegate.selections, selections);

  bool _sameRects(List<Rect> first, List<Rect> second) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (first[index] != second[index]) return false;
    }
    return true;
  }
}

class _PixelMagnifierPainter extends CustomPainter {
  final ui.Image image;
  final Offset sourcePoint;

  const _PixelMagnifierPainter({
    required this.image,
    required this.sourcePoint,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final sourceWidth = math.min(60.0, image.width.toDouble());
    final sourceHeight = math.min(40.0, image.height.toDouble());
    final centerX = sourcePoint.dx * image.width;
    final centerY = sourcePoint.dy * image.height;
    final left = (centerX - sourceWidth / 2).clamp(
      0.0,
      math.max(0.0, image.width - sourceWidth),
    );
    final top = (centerY - sourceHeight / 2).clamp(
      0.0,
      math.max(0.0, image.height - sourceHeight),
    );
    final destination = Offset.zero & size;
    final border = RRect.fromRectAndRadius(
      destination,
      const Radius.circular(8),
    );
    canvas.save();
    canvas.clipRRect(border);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(left.toDouble(), top.toDouble(), sourceWidth, sourceHeight),
      destination,
      Paint()..filterQuality = FilterQuality.none,
    );
    final guide = Paint()
      ..color = const Color(0xFFFFD54F)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(size.width / 2, 0),
      Offset(size.width / 2, size.height),
      guide,
    );
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      guide,
    );
    canvas.restore();
    canvas.drawRRect(
      border,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _PixelMagnifierPainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.sourcePoint != sourcePoint;
}
