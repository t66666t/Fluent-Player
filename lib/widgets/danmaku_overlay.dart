import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../services/subtitle_font_service.dart';
import '../services/danmaku_collision_layout.dart';
import '../models/danmaku_model.dart';
import '../models/danmaku_style.dart';
import '../utils/danmaku_ass_parser.dart';
import '../utils/subtitle_parser.dart';

const int _unrestrictedDanmakuAdmissions = 0x3fffffff;
const int _normalDanmakuAdmissionCap = 640;
const int _adaptiveDanmakuAdmissionCap = 320;
const int _severeDanmakuAdmissionCap = 200;

DanmakuDocument _parseDanmakuBytes(Uint8List bytes) {
  return DanmakuAssParser.parse(SubtitleParser.decodeBytes(bytes));
}

class _DanmakuFileStamp {
  const _DanmakuFileStamp(this.modifiedMs, this.size);

  final int modifiedMs;
  final int size;
}

class _CachedDanmakuDocument {
  const _CachedDanmakuDocument(this.path, this.stamp, this.document);

  final String path;
  final _DanmakuFileStamp stamp;
  final DanmakuDocument document;
}

/// Parsed documents survive the overlay. Landscape and portrait are different
/// routes, so each one used to re-read and re-parse before it could draw the
/// comments already on screen.
class _DanmakuDocumentCache {
  static const int _limit = 2;
  static final List<_CachedDanmakuDocument> _entries =
      <_CachedDanmakuDocument>[];

  static DanmakuDocument? peek(String path, _DanmakuFileStamp stamp) {
    for (var i = _entries.length - 1; i >= 0; i--) {
      final entry = _entries[i];
      if (entry.path == path &&
          entry.stamp.modifiedMs == stamp.modifiedMs &&
          entry.stamp.size == stamp.size) {
        return entry.document;
      }
    }
    return null;
  }

  static void store(
    String path,
    _DanmakuFileStamp stamp,
    DanmakuDocument document,
  ) {
    _entries.removeWhere(
      (entry) =>
          entry.path == path &&
          entry.stamp.modifiedMs == stamp.modifiedMs &&
          entry.stamp.size == stamp.size,
    );
    _entries.add(_CachedDanmakuDocument(path, stamp, document));
    while (_entries.length > _limit) {
      _entries.removeAt(0);
    }
  }
}

_DanmakuFileStamp? _readDanmakuFileStampSync(String path) {
  try {
    final file = File(path);
    if (!file.existsSync()) return null;
    final stat = file.statSync();
    return _DanmakuFileStamp(stat.modified.millisecondsSinceEpoch, stat.size);
  } catch (_) {
    return null;
  }
}

class DanmakuOverlay extends StatefulWidget {
  final String path;
  final ValueListenable<Duration> position;
  final double displayArea;
  final double opacity;
  final double fontScale;
  final bool useReadableFontDefaults;
  final DanmakuPresentationMode presentationMode;
  final double density;

  /// Media-time motion multiplier. Playback speed must not be multiplied here:
  /// [position] already advances at the native rate. Callers that treat a
  /// locked playback rate as 1x must divide the slider speed by that rate
  /// before passing it in.
  final double speed;
  final String? fontFamily;
  final int fontWeight;
  final double outlineScale;
  final double shadowScale;
  final double letterSpacing;
  final DanmakuOutlineType outlineType;
  final double playerHeight;

  const DanmakuOverlay({
    super.key,
    required this.path,
    required this.position,
    required this.displayArea,
    required this.opacity,
    required this.fontScale,
    this.useReadableFontDefaults = false,
    this.presentationMode = DanmakuPresentationMode.landscape,
    this.density = 1.0,
    required this.speed,
    required this.fontFamily,
    required this.fontWeight,
    this.outlineScale = 1.0,
    this.shadowScale = 1.0,
    this.letterSpacing = 0.0,
    required this.outlineType,
    required this.playerHeight,
  });

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<DanmakuOverlay>
    with WidgetsBindingObserver {
  DanmakuDocument? _document;
  DanmakuActiveSet? _activeSet;
  int _loadToken = 0;
  late final _DanmakuAtlasManager _atlasManager;
  late final _DanmakuPerformanceGovernor _performanceGovernor;
  final DanmakuAssetAdmissionGate _assetAdmissionGate =
      DanmakuAssetAdmissionGate();
  final DanmakuCollisionGate _collisionGate = DanmakuCollisionGate();
  _DanmakuAtlasStyle? _preparedStyle;
  int? _requestedPrefetchBucket;
  int? _completedPrefetchBucket;
  int? _completedPrefetchGeneration;
  bool _prefetchScheduled = false;
  bool _prefetchRunning = false;
  double _viewportWidth = 1920;
  double _viewportHeight = 1080;

  int _prefetchRevision = 0;
  final _motionMetrics = _DanmakuMotionMetrics();
  final _paintPosition = ValueNotifier(Duration.zero);
  bool _routeVisible = true;
  bool _appVisible = true;
  bool _visuallyActive = false;

  @override
  void initState() {
    super.initState();
    _atlasManager = _DanmakuAtlasManager(maximumBytes: _atlasMemoryBudget());
    _performanceGovernor = _DanmakuPerformanceGovernor();
    _performanceGovernor.addListener(_onPerformancePolicyChanged);
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _appVisible =
        state == null ||
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    // The other orientation already parsed this file. Draw from that document
    // on the first frame instead of waiting out another read and parse.
    _adoptCachedDocumentIfPresent();
    _load();
    unawaited(_loadFont());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // TickerMode follows actual opaque coverage, leaving visible comments
    // live during page transitions and under transparent dialogs.
    _routeVisible = TickerMode.valuesOf(context).enabled;
    _syncActivity();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appVisible =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    final wasActive = _visuallyActive;
    _syncActivity();
    if (wasActive != _visuallyActive) setState(() {});
  }

  void _syncActivity() {
    final active = _routeVisible && _appVisible;
    if (_visuallyActive == active) return;
    _visuallyActive = active;
    _invalidatePrefetchProgress();
    if (active) {
      // New entries may have crossed the prefetch runway while hidden. Give
      // their first upload the same grace as a cold page or style rebuild.
      _assetAdmissionGate.suspendEntrySuppression();
      widget.position.addListener(_onPositionChanged);
      _paintPosition.value = widget.position.value;
      _performanceGovernor.start();
      _schedulePrefetch();
    } else {
      widget.position.removeListener(_onPositionChanged);
      _performanceGovernor.stop();
    }
  }

  void _adoptCachedDocumentIfPresent() {
    final stamp = _readDanmakuFileStampSync(widget.path);
    if (stamp == null) return;
    final cached = _DanmakuDocumentCache.peek(widget.path, stamp);
    if (cached == null) return;
    _document = cached;
    _activeSet = DanmakuActiveSet(cached.items);
  }

  @override
  void didUpdateWidget(covariant DanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fontFamily != widget.fontFamily) unawaited(_loadFont());
    if (oldWidget.path != widget.path) {
      // Item indices belong to one file. Drop glyphs before swapping documents
      // so a reused index cannot draw the previous video's text.
      _atlasManager.clear();
      _invalidatePrefetchProgress();
      _adoptCachedDocumentIfPresent();
      _load();
    }
    if (oldWidget.position != widget.position) {
      if (_visuallyActive) {
        oldWidget.position.removeListener(_onPositionChanged);
        widget.position.addListener(_onPositionChanged);
        _paintPosition.value = widget.position.value;
      }
      _invalidatePrefetchProgress();
      _schedulePrefetch();
    }
    if (oldWidget.displayArea != widget.displayArea ||
        oldWidget.presentationMode != widget.presentationMode ||
        oldWidget.density != widget.density ||
        oldWidget.fontScale != widget.fontScale ||
        oldWidget.useReadableFontDefaults != widget.useReadableFontDefaults ||
        oldWidget.fontFamily != widget.fontFamily ||
        oldWidget.fontWeight != widget.fontWeight ||
        oldWidget.outlineScale != widget.outlineScale ||
        oldWidget.shadowScale != widget.shadowScale ||
        oldWidget.letterSpacing != widget.letterSpacing ||
        oldWidget.outlineType != widget.outlineType ||
        oldWidget.playerHeight != widget.playerHeight ||
        (oldWidget.speed - widget.speed).abs() >= 0.001) {
      // The previous bitmaps stay up while the new atlas is built. Comments
      // that start during that rebuild must not be blacklisted for a glyph
      // that does not exist yet.
      _assetAdmissionGate.suspendEntrySuppression();
      _invalidatePrefetchProgress();
      _schedulePrefetch();
    }
  }

  Future<void> _loadFont() async {
    final family = widget.fontFamily;
    if (family == null || SubtitleFontService.instance.isLoaded(family)) return;
    try {
      await SubtitleFontService.instance.ensureLoaded(family);
      if (!mounted || widget.fontFamily != family) return;
      _atlasManager.clear();
      _invalidatePrefetchProgress();
      setState(() {});
    } catch (error) {
      debugPrint('Danmaku font unavailable: $error');
    }
  }

  Future<void> _load() async {
    final token = ++_loadToken;
    final path = widget.path;
    // A new document is a cold atlas. Hold entry suppression until the first
    // prefetch cycle finishes, or comments already on screen are blacklisted
    // for missing glyphs that have not been uploaded yet.
    _assetAdmissionGate.reset();
    try {
      final file = File(path);
      final stat = await file.stat();
      final stamp = _DanmakuFileStamp(
        stat.modified.millisecondsSinceEpoch,
        stat.size,
      );
      final cached = _DanmakuDocumentCache.peek(path, stamp);
      if (token != _loadToken) return;
      if (cached != null) {
        if (!mounted) return;
        if (!identical(_document, cached)) {
          setState(() {
            _document = cached;
            _activeSet = DanmakuActiveSet(cached.items);
          });
        }
        _schedulePrefetch();
        return;
      }
      final bytes = await file.readAsBytes();
      final document = await compute(
        _parseDanmakuBytes,
        bytes,
        debugLabel: 'parse-bilibili-danmaku',
      );
      if (token != _loadToken) return;
      // Store even if this overlay is already gone, so the page we navigated
      // to can paint the same file without parsing it again.
      _DanmakuDocumentCache.store(path, stamp, document);
      if (!mounted) return;
      _atlasManager.clear();
      _invalidatePrefetchProgress();
      setState(() {
        _document = document;
        _activeSet = DanmakuActiveSet(document.items);
      });
      _schedulePrefetch();
    } catch (_) {
      if (!mounted || token != _loadToken) return;
      _atlasManager.clear();
      setState(() {
        _document = null;
        _activeSet = null;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_visuallyActive) widget.position.removeListener(_onPositionChanged);
    _paintPosition.dispose();
    _performanceGovernor.removeListener(_onPerformancePolicyChanged);
    _performanceGovernor.dispose();
    _atlasManager.dispose();
    super.dispose();
  }

  void _onPositionChanged() {
    if (!_visuallyActive) return;
    _paintPosition.value = widget.position.value;
    _schedulePrefetch();
  }

  void _onPerformancePolicyChanged() {
    if (!_visuallyActive) return;
    _invalidatePrefetchProgress();
    _schedulePrefetch();
  }

  void _invalidatePrefetchProgress() {
    _prefetchRevision++;
    _requestedPrefetchBucket = null;
    _completedPrefetchBucket = null;
  }

  void _schedulePrefetch() {
    if (!mounted || !_visuallyActive) return;
    // One maintenance pass per second is enough because upcoming atlas work is
    // grouped into stable five-second media-time segments below. Running this
    // four times per second caused small but measurable periodic UI work.
    final positionBucket = widget.position.value.inMilliseconds ~/ 1000;
    if (_completedPrefetchBucket == positionBucket &&
        _completedPrefetchGeneration == _atlasManager.generation) {
      return;
    }
    if (_requestedPrefetchBucket == positionBucket &&
        (_prefetchScheduled || _prefetchRunning)) {
      return;
    }
    _requestedPrefetchBucket = positionBucket;
    if (_prefetchScheduled || _prefetchRunning) return;
    _prefetchScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _prefetchScheduled = false;
      if (!mounted || !_visuallyActive || _prefetchRunning) return;
      unawaited(_runPrefetchLoop());
    });
  }

  Future<void> _runPrefetchLoop() async {
    _prefetchRunning = true;
    try {
      while (mounted && _visuallyActive) {
        final document = _document;
        final style = _preparedStyle;
        final requestedBucket = _requestedPrefetchBucket;
        if (document == null || style == null || requestedBucket == null) {
          return;
        }

        final generation = _atlasManager.generation;
        final revision = _prefetchRevision;
        bool isCurrent() =>
            mounted &&
            _visuallyActive &&
            generation == _atlasManager.generation &&
            revision == _prefetchRevision &&
            requestedBucket == _requestedPrefetchBucket;
        final positionUs = widget.position.value.inMicroseconds;
        // Visible comments come first so a style change or a newly opened
        // player can redraw what is already on screen. The runway still
        // follows; once those glyphs are cached, later ticks only pay for
        // comments that have not started yet.
        final indices = resolveDanmakuPrefetchIndices(
          document.items,
          positionUs: positionUs,
          speed: widget.speed,
          viewportWidth: _viewportWidth,
          referenceWidth: document.referenceWidth,
          textWidthOf: _motionMetrics.widthOf,
          textWidthPerCodeUnit: _motionMetrics.widthBound,
          maximumActiveItems: _performanceGovernor.constrainPrefetch
              ? math.min(_performanceGovernor.admissionCap, 200)
              : 640,
          maximumUpcomingItems: _performanceGovernor.constrainPrefetch
              ? 128
              : 800,
          // Keep the horizon in media time at ten seconds. At an 8x temporary
          // playback rate that is only 1.25 seconds of wall-clock preparation;
          // reducing it further would recreate the late-entry race.
          lookAheadUs: 10000000,
          atlasSegmentUs: _performanceGovernor.constrainPrefetch
              ? 1000000
              : 5000000,
          includeItem: (item) =>
              danmakuPassesDensity(item, widget.density) &&
              danmakuLaneIntersectsViewport(
                item,
                viewportHeight: _viewportHeight,
                displayArea: widget.displayArea,
                fontSize: style.fontSize,
                referenceHeight: document.referenceHeight,
              ),
        );

        // Software fallback owns native text layouts instead of bounded atlas
        // pages. Keep the full runway plus all actual painter admissions;
        // pruning a single batch would discard other comments still in use.
        if (_atlasManager.usesFallback) {
          _atlasManager.retainFallbackItems(
            indices.map((index) => document.items[index].index),
            activeItems:
                _activeSet?._active.map(
                  (index) => document.items[index].index,
                ) ??
                const <int>[],
          );
        }
        _atlasManager.beginPrefetchCycle();
        _atlasManager.pinPreparedItems(<int>[
          for (final index in indices)
            if (document.items[index].startTime.inMicroseconds <= positionUs)
              index,
        ]);
        // Text layout and Picture.toImage both share frame-critical resources.
        // Smaller pages reduce the size of each individual raster/upload spike
        // while the video and the danmaku animation are already running.
        var visibleEnd = 0;
        while (visibleEnd < indices.length &&
            document.items[indices[visibleEnd]].startTime.inMicroseconds <=
                positionUs) {
          visibleEnd++;
        }
        var handedOff = false;
        const batchSize = 32;
        for (var offset = 0; offset < indices.length; offset += batchSize) {
          // Abandon stale work between uploads after a seek, resize or style
          // change. An upload already in flight is allowed to finish safely.
          if (!isCurrent()) break;
          final end = math.min(offset + batchSize, indices.length);
          final items = <DanmakuItem>[
            for (var i = offset; i < end; i++) document.items[indices[i]],
          ];
          final pinsCurrentFrame = items.any((item) {
            final elapsedUs = positionUs - item.startTime.inMicroseconds;
            final durationUs = resolveDanmakuDurationUs(
              item,
              speed: widget.speed,
              viewportWidth: _viewportWidth,
              referenceWidth: document.referenceWidth,
              textWidth: _motionMetrics.widthOf(item),
            );
            return elapsedUs >= 0 && elapsedUs < durationUs;
          });
          final preparedNewAssets = await _atlasManager.prepare(
            items,
            generation: generation,
            pinPages: pinsCurrentFrame,
            // Page open has no previous atlas. Draw these comments as text
            // while their bitmap is uploading so the stage is not empty.
            provisional: offset < visibleEnd,
            shouldContinue: isCurrent,
            shouldNotify: () => mounted && _visuallyActive,
          );
          if (!isCurrent()) break;
          // Swap only after the comments already on screen exist in the new
          // atlas. Swapping on the first batch used to delete them, because
          // that batch is only a slice of the visible set.
          if (!handedOff &&
              visibleEnd > 0 &&
              end >= visibleEnd &&
              isCurrent()) {
            handedOff = _atlasManager.commitHandover();
          }
          // Atlas construction is kept outside paint() and yields after every
          // batch, so a dense burst cannot monopolize the UI isolate.
          if (preparedNewAssets && end < indices.length && mounted) {
            await WidgetsBinding.instance.endOfFrame;
          }
        }

        if (isCurrent()) {
          _atlasManager.commitHandover(discardIfEmpty: true);
          _completedPrefetchBucket = requestedBucket;
          _completedPrefetchGeneration = generation;
          // Glyphs for the current window exist. Later misses are real late
          // uploads and should not pop in halfway across the screen.
          _assetAdmissionGate.resumeEntrySuppression();
          return;
        }
      }
    } finally {
      _prefetchRunning = false;
      if (mounted &&
          _visuallyActive &&
          (_requestedPrefetchBucket != _completedPrefetchBucket ||
              _completedPrefetchGeneration != _atlasManager.generation) &&
          !_prefetchScheduled) {
        _schedulePrefetch();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // The atlas belongs to this state and survives coverage. Removing only
    // the painter also prevents late upload notifications requesting paints.
    if (!_visuallyActive) return const SizedBox.shrink();
    _performanceGovernor.updateView(View.of(context));
    final document = _document;
    final activeSet = _activeSet;
    if (document == null || document.items.isEmpty || activeSet == null) {
      return const SizedBox.shrink();
    }
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final style = _DanmakuAtlasStyle(
      fontSize: resolveDanmakuFontSize(
        playerHeight: widget.playerHeight,
        fontScale: widget.fontScale,
        presentationMode: widget.presentationMode,
        screenSize:
            widget.useReadableFontDefaults ||
                widget.presentationMode == DanmakuPresentationMode.portrait
            ? MediaQuery.sizeOf(context)
            : null,
      ),
      devicePixelRatio: devicePixelRatio,
      fontFamily: widget.fontFamily,
      fontWeight: widget.fontWeight,
      outlineScale: widget.outlineScale,
      shadowScale: widget.shadowScale,
      letterSpacing: widget.letterSpacing,
      outlineType: widget.outlineType,
    );
    _motionMetrics.ensureStyle(style);
    _atlasManager.ensureStyle(style);
    _preparedStyle = style;
    _schedulePrefetch();

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportWidth =
            constraints.hasBoundedWidth &&
                constraints.maxWidth.isFinite &&
                constraints.maxWidth > 0
            ? constraints.maxWidth
            : document.referenceWidth;
        final viewportHeight =
            constraints.hasBoundedHeight && constraints.maxHeight > 0
            ? constraints.maxHeight
            : document.referenceHeight;
        if ((_viewportWidth - viewportWidth).abs() >= 0.5 ||
            (_viewportHeight - viewportHeight).abs() >= 0.5) {
          _viewportWidth = viewportWidth;
          _viewportHeight = viewportHeight;
          _assetAdmissionGate.suspendEntrySuppression();
          _invalidatePrefetchProgress();
          _schedulePrefetch();
        }
        return IgnorePointer(
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _DanmakuPainter(
                document: document,
                // Keep the painter off the upstream clock. Hidden apps may
                // not rebuild, so lifecycle detachment must be synchronous.
                position: _paintPosition,
                displayArea: widget.displayArea,
                density: widget.density,
                opacity: widget.opacity,
                speed: widget.speed,
                requestedFontSize: style.fontSize,
                activeSet: activeSet,
                motionMetrics: _motionMetrics,
                atlasManager: _atlasManager,
                performanceGovernor: _performanceGovernor,
                assetAdmissionGate: _assetAdmissionGate,
                collisionGate: _collisionGate,
              ),
              // The overlay changes on every VSync. Marking it as complex
              // invites a raster-cache attempt which cannot be reused.
              isComplex: false,
              willChange: true,
              size: Size.infinite,
            ),
          ),
        );
      },
    );
  }
}

class _DanmakuPainter extends CustomPainter {
  final DanmakuDocument document;
  final ValueListenable<Duration> position;
  final double displayArea;
  final double density;
  final double opacity;
  final double speed;
  final double requestedFontSize;
  final DanmakuActiveSet activeSet;
  final _DanmakuMotionMetrics motionMetrics;
  final _DanmakuAtlasManager atlasManager;
  final _DanmakuPerformanceGovernor performanceGovernor;
  final DanmakuAssetAdmissionGate assetAdmissionGate;
  final DanmakuCollisionGate collisionGate;
  late final Paint _atlasPaint = Paint()
    ..isAntiAlias = true
    // Scrolling comments deliberately retain a fractional X coordinate. Linear
    // sampling lets those sub-pixel steps remain continuous instead of turning
    // them into a repeated-frame/one-pixel-jump pattern on high-refresh-rate
    // Windows displays.
    ..filterQuality = FilterQuality.low;
  Size? _layoutSize;
  int _layoutMembershipRevision = -1;
  int _layoutAtlasRevision = -1;
  final List<_DanmakuDrawItem> _drawItems = <_DanmakuDrawItem>[];
  final Map<int, _DanmakuDrawItem> _itemLayouts = <int, _DanmakuDrawItem>{};

  _DanmakuPainter({
    required this.document,
    required this.position,
    required this.displayArea,
    required this.density,
    required this.opacity,
    required this.speed,
    required this.requestedFontSize,
    required this.activeSet,
    required this.motionMetrics,
    required this.atlasManager,
    required this.performanceGovernor,
    required this.assetAdmissionGate,
    required this.collisionGate,
  }) : super(
         repaint: Listenable.merge(<Listenable>[
           position,
           atlasManager,
           performanceGovernor,
         ]),
       );

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final positionUs = position.value.inMicroseconds;
    assetAdmissionGate.beginFrame(positionUs);
    // All movement is derived from shared media time. At 2x, position itself
    // advances twice as fast in wall time, so danmaku accelerates with the
    // video without maintaining a second, drift-prone animation clock.
    final visibleHeight =
        size.height *
        displayArea.clamp(kDanmakuDisplayAreaMin, kDanmakuDisplayAreaMax);
    // Lane size tracks the slider immediately. Bitmaps rasterized at the
    // previous size are scaled into this lane until the new atlas is ready,
    // so a font-size change does not clip the old glyphs out of the track.
    final fontSize = requestedFontSize;
    final edgePadding = math.max(2.0, fontSize * 0.1);
    final laneExtent = fontSize + edgePadding;
    final renderRect = Rect.fromLTWH(0, 0, size.width, visibleHeight);
    final contentRect = Rect.fromLTRB(
      renderRect.left + edgePadding,
      renderRect.top + edgePadding,
      math.max(renderRect.left + edgePadding, renderRect.right - edgePadding),
      math.max(renderRect.top + edgePadding, renderRect.bottom - edgePadding),
    );
    final collisionReset = collisionGate.beginFrame(
      positionUs,
      layoutKey: (
        document,
        size,
        displayArea,
        density,
        speed,
        requestedFontSize,
        atlasManager._requestedStyle,
      ),
    );
    final activeIndices = activeSet.update(
      positionUs: positionUs,
      speed: speed,
      admissionCap: performanceGovernor.admissionCap,
      viewportWidth: contentRect.width,
      textWidthOf: motionMetrics.widthOf,
      metricsKey: motionMetrics._style,
      textWidthPerCodeUnit: motionMetrics.widthBound,
      referenceWidth: document.referenceWidth,
      density: density,
    );
    if (activeIndices.isEmpty) {
      _drawItems.clear();
      _itemLayouts.clear();
      collisionGate.retainActive({});
      return;
    }

    // Glyph metrics and lanes stay constant between membership/atlas/layout
    // changes. Reuse them across VSyncs; only horizontal motion needs time.
    if (collisionReset ||
        _layoutSize != size ||
        _layoutMembershipRevision != activeSet.revision ||
        _layoutAtlasRevision != atlasManager.revision) {
      if (collisionReset ||
          _layoutSize != size ||
          _layoutAtlasRevision != atlasManager.revision) {
        _itemLayouts.clear();
      }
      _prepareDrawItems(
        activeIndices,
        positionUs,
        renderRect,
        contentRect,
        laneExtent,
      );
      _layoutSize = size;
      _layoutMembershipRevision = activeSet.revision;
      _layoutAtlasRevision = atlasManager.revision;
    }

    atlasManager.beginFrame();
    canvas.save();
    canvas.clipRect(renderRect);
    final usesFallback = atlasManager.usesFallback;
    if (usesFallback && opacity < 0.999) {
      canvas.saveLayer(
        renderRect,
        Paint()..color = Color.fromRGBO(255, 255, 255, opacity.clamp(0.1, 1.0)),
      );
    }
    for (final item in _drawItems) {
      final elapsedUs = positionUs - item.startUs;
      final progress = elapsedUs / item.durationUs;
      final x = item.scrolling
          ? contentRect.right - progress * (contentRect.width + item.width)
          : contentRect.center.dx - item.width / 2;
      final sprite = item.sprite;
      if (sprite != null) {
        atlasManager.addSprite(
          sprite,
          x,
          item.y,
          continuousHorizontal: item.scrolling,
          glyphScale: item.glyphScale,
        );
      } else {
        // Preserve the per-comment opacity semantics while uploads complete.
        final fadeSeparately = !usesFallback && opacity < 0.999;
        if (fadeSeparately) {
          canvas.saveLayer(
            Rect.fromLTWH(x, item.y, item.width, item.height),
            Paint()
              ..color = Color.fromRGBO(255, 255, 255, opacity.clamp(0.1, 1.0)),
          );
        }
        item.fallback!.paintTextAt(canvas, x, item.y);
        if (fadeSeparately) canvas.restore();
      }
    }

    atlasManager.paintFrame(canvas, _atlasPaint, opacity.clamp(0.1, 1.0));
    if (usesFallback && opacity < 0.999) canvas.restore();
    canvas.restore();
  }

  void _prepareDrawItems(
    List<int> activeIndices,
    int positionUs,
    Rect renderRect,
    Rect contentRect,
    double laneExtent,
  ) {
    _drawItems.clear();
    collisionGate.retainActive({
      for (final index in activeIndices) document.items[index].index,
    });
    // Admission follows source time, never performance-ranking or atlas order.
    final orderedIndices = List<int>.of(activeIndices)..sort();
    for (final activeIndex in orderedIndices) {
      final item = document.items[activeIndex];
      final cached = _itemLayouts[item.index];
      if (cached != null) {
        _drawItems.add(cached);
        continue;
      }
      final elapsedUs = positionUs - item.startTime.inMicroseconds;
      final durationUs = resolveDanmakuDurationUs(
        item,
        speed: speed,
        viewportWidth: contentRect.width,
        textWidth: motionMetrics.widthOf(item),
        referenceWidth: document.referenceWidth,
      );
      if (elapsedUs < 0 || elapsedUs >= durationUs) continue;

      final sprite = atlasManager.lookup(item.index);
      final fallback = atlasManager.lookupFallback(item.index);
      final glyphScale = sprite == null
          ? 1.0
          : _danmakuGlyphScale(sprite.fontSize, requestedFontSize);
      final layoutWidth = sprite != null
          ? sprite.width * glyphScale
          : fallback?.width;
      final layoutHeight = sprite != null
          ? sprite.height * glyphScale
          : fallback?.height;
      if (!assetAdmissionGate.shouldPaint(
            itemIndex: item.index,
            assetReady: layoutWidth != null && layoutHeight != null,
            atEntry: danmakuAssetMissIsEntry(elapsedUs, durationUs),
          ) ||
          layoutWidth == null ||
          layoutHeight == null) {
        continue;
      }
      // Source lanes were allocated on a 1080px ASS canvas. Repack all of
      // them into the selected display area instead of discarding lower ones.
      final laneYs = _danmakuLaneYs(
        item,
        contentTop: contentRect.top,
        contentBottom: contentRect.bottom,
        laneExtent: laneExtent,
        glyphHeight: layoutHeight,
        referenceHeight: document.referenceHeight,
      );
      if (laneYs.isEmpty) continue;
      final scrolling = item.type == DanmakuType.scroll;
      final fixedX = contentRect.center.dx - layoutWidth / 2;
      final placement = collisionGate.place(
        DanmakuCollisionBox(
          index: item.index,
          startUs: item.startTime.inMicroseconds,
          durationUs: durationUs,
          startX: scrolling ? contentRect.right : fixedX,
          endX: scrolling ? contentRect.left - layoutWidth : fixedX,
          y: laneYs.first,
          width: layoutWidth,
          height: layoutHeight,
          padding: sprite != null
              ? sprite.imagePadding * glyphScale
              : fallback!.imagePadding,
          horizontalGap: 0,
          type: item.type,
        ),
        candidateYs: laneYs.skip(1),
      );
      if (placement == null) continue;
      final layout = _DanmakuDrawItem(
        startUs: item.startTime.inMicroseconds,
        durationUs: durationUs,
        scrolling: scrolling,
        sprite: sprite,
        fallback: sprite == null ? fallback : null,
        glyphScale: glyphScale,
        width: layoutWidth,
        height: layoutHeight,
        y: placement.y,
      );
      _itemLayouts[item.index] = layout;
      _drawItems.add(layout);
    }
    // Membership can change every frame in a dense stream. Reuse surviving
    // layouts rather than allocating the entire visible set again, and bound
    // retained entries so a long video cannot grow this cache indefinitely.
    if (_itemLayouts.length > math.max(64, activeIndices.length * 2)) {
      final retained = <int>{
        for (final index in activeIndices) document.items[index].index,
      };
      _itemLayouts.removeWhere((index, _) => !retained.contains(index));
    }
  }

  @override
  bool shouldRepaint(covariant _DanmakuPainter oldDelegate) {
    return oldDelegate.document != document ||
        oldDelegate.displayArea != displayArea ||
        oldDelegate.density != density ||
        oldDelegate.opacity != opacity ||
        (oldDelegate.speed - speed).abs() >= 0.001 ||
        oldDelegate.requestedFontSize != requestedFontSize;
  }
}

class _DanmakuDrawItem {
  const _DanmakuDrawItem({
    required this.startUs,
    required this.durationUs,
    required this.scrolling,
    required this.sprite,
    required this.fallback,
    required this.glyphScale,
    required this.width,
    required this.height,
    required this.y,
  });

  final int startUs;
  final int durationUs;
  final bool scrolling;
  final _DanmakuSprite? sprite;
  final _PreparedDanmakuText? fallback;
  final double glyphScale;
  final double width;
  final double height;
  final double y;
}

Iterable<double> _danmakuLaneYs(
  DanmakuItem item, {
  required double contentTop,
  required double contentBottom,
  required double laneExtent,
  required double glyphHeight,
  required double referenceHeight,
}) sync* {
  if (contentBottom - contentTop < glyphHeight) return;
  final count =
      ((contentBottom - contentTop - glyphHeight) / laneExtent).floor() + 1;
  final bottom = item.type == DanmakuType.bottom;
  final sourceLane = bottom
      ? math.max(0, ((referenceHeight - item.sourceY) / 40).floor() - 1)
      : (item.sourceY / 40).floor();
  for (var offset = 0; offset < count; offset++) {
    final lane = (sourceLane + offset) % count;
    yield bottom
        ? contentBottom - glyphHeight - lane * laneExtent
        : contentTop + lane * laneExtent;
  }
}

/// Source lanes are repacked at paint time. Only reject prefetch when no row
/// can fit at all; a high source Y must not erase comments on a short phone.
@visibleForTesting
bool danmakuLaneIntersectsViewport(
  DanmakuItem item, {
  required double viewportHeight,
  required double displayArea,
  required double fontSize,
  double referenceHeight = 1080,
}) {
  if (!viewportHeight.isFinite || viewportHeight <= 0) return true;
  final padding = math.max(2.0, fontSize * 0.1);
  final bottom = math.max(
    padding,
    viewportHeight *
            displayArea.clamp(kDanmakuDisplayAreaMin, kDanmakuDisplayAreaMax) -
        padding,
  );
  return _danmakuLaneYs(
    item,
    contentTop: padding,
    contentBottom: bottom,
    laneExtent: fontSize + padding,
    glyphHeight: fontSize,
    referenceHeight: referenceHeight,
  ).isNotEmpty;
}

/// Prevents an asset which missed its entry deadline from appearing halfway
/// across the screen once its asynchronous atlas upload eventually finishes.
///
/// A seek clears the suppression set because it establishes a new presentation
/// epoch. Normal playback-rate changes remain continuous and therefore never
/// clear it. A cold atlas (page open, or a newly parsed file) suspends that
/// rule until the first prefetch cycle finishes: the comments already in
/// flight must appear at their real position, not stay hidden until later
/// timestamps arrive.
@visibleForTesting
class DanmakuAssetAdmissionGate {
  int? _lastPositionUs;
  final Set<int> _suppressedItems = <int>{};
  bool _suppressLateEntries = true;

  void beginFrame(int positionUs) {
    final previous = _lastPositionUs;
    if (previous != null && positionUs < previous) {
      _suppressedItems.clear();
    }
    _lastPositionUs = positionUs;
  }

  /// A missing glyph is only an entry miss while the comment is still on the
  /// leading edge. A comment already traveling (settings rebuild, cold start,
  /// orientation change) is drawn at its true position once the glyph exists.
  bool shouldPaint({
    required int itemIndex,
    required bool assetReady,
    required bool atEntry,
  }) {
    if (_suppressedItems.contains(itemIndex)) return false;
    if (assetReady) return true;
    if (atEntry && _suppressLateEntries) _suppressedItems.add(itemIndex);
    return false;
  }

  void suspendEntrySuppression() {
    // Leave comments that already missed their entrance suppressed. Clearing
    // the set here would pop them in halfway through a font or outline change.
    _suppressLateEntries = false;
  }

  void resumeEntrySuppression() {
    _suppressLateEntries = true;
  }

  void reset() {
    _lastPositionUs = null;
    _suppressedItems.clear();
    _suppressLateEntries = false;
  }
}

/// True while a missing glyph would still be entering from the leading edge.
@visibleForTesting
bool danmakuAssetMissIsEntry(int elapsedUs, int durationUs) {
  if (elapsedUs <= 0) return true;
  final safeDuration = math.max(1, durationUs);
  final graceUs = math.max(200000, (safeDuration * 0.03).round());
  return elapsedUs <= graceUs;
}

double _danmakuGlyphScale(double sourceFontSize, double requestedFontSize) {
  if (sourceFontSize <= 0 || requestedFontSize <= 0) return 1;
  if ((sourceFontSize - requestedFontSize).abs() < 0.05) return 1;
  return requestedFontSize / sourceFontSize;
}

@visibleForTesting
double resolveDanmakuFontSize({
  required double playerHeight,
  required double fontScale,
  Size? screenSize,
  DanmakuPresentationMode presentationMode = DanmakuPresentationMode.landscape,
}) {
  if (presentationMode == DanmakuPresentationMode.portrait) {
    return (resolvePortraitDanmakuBaseFontSize(screenSize ?? Size.zero) *
            fontScale.clamp(kDanmakuFontScaleMin, kDanmakuFontScaleMax))
        .clamp(2.0, 160.0);
  }
  // Opt-in trial defaults use logical window dimensions. The short side is
  // stable across rotation and independent of video bands/sidebar widths.
  // Bound only the default base; keep the user's percentage multiplicative.
  if (screenSize != null &&
      screenSize.width.isFinite &&
      screenSize.height.isFinite &&
      screenSize.shortestSide > 0) {
    final base = (14 * math.pow(screenSize.shortestSide / 390, .35)).clamp(
      14.0,
      22.0,
    );
    return (base * fontScale.clamp(kDanmakuFontScaleMin, kDanmakuFontScaleMax))
        .clamp(2.0, 160.0);
  }
  const referencePlayerHeight = 1080.0;
  const referenceFontSize = 40.0;
  final safePlayerHeight = playerHeight.isFinite && playerHeight > 0
      ? playerHeight
      : referencePlayerHeight;
  // Square root keeps a short portrait video band from shrinking to a few
  // pixels, while a 1080-tall stage stays on the ASS reference size. The
  // user scale still multiplies the whole result, so the slider is not
  // overridden by a second design floor.
  final heightRatio = safePlayerHeight / referencePlayerHeight;
  return (referenceFontSize *
          math.sqrt(heightRatio) *
          fontScale.clamp(kDanmakuFontScaleMin, kDanmakuFontScaleMax))
      .clamp(2.0, 160.0);
}

/// Legacy geometry helper retained for callers of the test API.
/// Fixed-velocity playback no longer uses a screen motion anchor.
@visibleForTesting
double resolveDanmakuScreenMotionAnchor(
  Size screenSize, {
  DanmakuPresentationMode presentationMode = DanmakuPresentationMode.landscape,
}) {
  // Preserve the historical helper result; it does not control playback.
  if (presentationMode == DanmakuPresentationMode.portrait) return 1920;
  final width = screenSize.width.isFinite && screenSize.width > 0
      ? screenSize.width
      : 0.0;
  final height = screenSize.height.isFinite && screenSize.height > 0
      ? screenSize.height
      : 0.0;
  return math.max(width, height);
}

/// Legacy geometry helper; scroll lifetime now uses the actual visible width.
@visibleForTesting
double resolveDanmakuMotionWidth({
  required double viewportWidth,
  required double referenceWidth,
  double? motionAnchorWidth,
}) {
  final safeReference = referenceWidth.isFinite && referenceWidth > 0
      ? referenceWidth
      : 1920.0;
  final safeViewport = viewportWidth.isFinite && viewportWidth > 0
      ? viewportWidth
      : safeReference;
  final anchor = motionAnchorWidth;
  if (anchor == null || !anchor.isFinite || anchor <= 0) {
    return safeViewport;
  }
  return math.max(safeViewport, anchor);
}

// Logical pixels per media second at 1.0; playback baseline compensation is
// applied by SettingsService before reaching the overlay.
const double kDanmakuScrollPixelsPerSecond = 60;

double _motionSpeed(double speed) => speed.isFinite && speed > 0 ? speed : 1.0;

/// Scroll lifetime includes the measured text tail, independent of ASS duration,
/// screen orientation and reference resolution. Fixed comments keep their timing.
@visibleForTesting
int resolveDanmakuDurationUs(
  DanmakuItem item, {
  required double speed,
  required double viewportWidth,
  required double referenceWidth,
  double? motionAnchorWidth,
  double textWidth = 0,
}) {
  final safeSpeed = _motionSpeed(speed);
  if (item.type != DanmakuType.scroll) {
    return math.max(1, (item.duration.inMicroseconds / safeSpeed).round());
  }
  final width = viewportWidth.isFinite && viewportWidth > 0
      ? viewportWidth
      : 1920.0;
  return math.max(
    1,
    ((width + math.max(0.0, textWidth)) /
            (kDanmakuScrollPixelsPerSecond * safeSpeed) *
            1000000)
        .ceil(),
  );
}

// A conservative search bound, not the actual lifetime. Actual text metrics
// are resolved lazily only for candidates in this window and cached by style.
final _searchBounds = Expando<(int, int)>();
(int, int) _danmakuSearchBounds(List<DanmakuItem> items) =>
    _searchBounds[items] ??= (
      items.fold<int>(
        0,
        (n, item) =>
            item.type == DanmakuType.scroll ? math.max(n, item.text.length) : n,
      ),
      items.fold<int>(
        0,
        (n, item) => item.type != DanmakuType.scroll
            ? math.max(n, item.duration.inMicroseconds)
            : n,
      ),
    );

int _maximumMotionDuration(
  List<DanmakuItem> items,
  double width,
  double speed,
  double textWidthPerCodeUnit,
) {
  final bounds = _danmakuSearchBounds(items);
  return (math.max(
            bounds.$2.toDouble(),
            (width + bounds.$1 * textWidthPerCodeUnit) /
                kDanmakuScrollPixelsPerSecond *
                1000000,
          ) /
          _motionSpeed(speed))
      .ceil();
}

@visibleForTesting
class DanmakuIndexRange {
  final int start;
  final int endExclusive;

  const DanmakuIndexRange(this.start, this.endExclusive);

  bool get isEmpty => start >= endExclusive;
  int get length => math.max(0, endExclusive - start);
}

@visibleForTesting
DanmakuIndexRange resolveDanmakuActiveRange(
  List<DanmakuItem> items, {
  required int positionUs,
  required double speed,
  double viewportWidth = 1920,
  double referenceWidth = 1920,
  double textWidthPerCodeUnit = 640,
}) {
  if (items.isEmpty) return const DanmakuIndexRange(0, 0);
  final earliestStartUs =
      positionUs -
      _maximumMotionDuration(items, viewportWidth, speed, textWidthPerCodeUnit);
  return DanmakuIndexRange(
    _firstStartAtOrAfter(items, earliestStartUs),
    _firstStartAfter(items, positionUs),
  );
}

@visibleForTesting
List<int> resolveDanmakuPrefetchIndices(
  List<DanmakuItem> items, {
  required int positionUs,
  required double speed,
  double viewportWidth = 1920,
  double referenceWidth = 1920,
  double? motionAnchorWidth,
  int maximumActiveItems = 640,
  int maximumUpcomingItems = 800,
  int lookAheadUs = 10000000,
  int atlasSegmentUs = 5000000,
  bool Function(DanmakuItem item)? includeItem,
  double textWidthPerCodeUnit = 640,
  double Function(DanmakuItem item)? textWidthOf,
}) {
  final result = <int>[];
  final active = resolveDanmakuActiveRange(
    items,
    positionUs: positionUs,
    speed: speed,
    viewportWidth: viewportWidth,
    referenceWidth: referenceWidth,
    textWidthPerCodeUnit: textWidthPerCodeUnit,
  );
  final safeMaximumUpcomingItems = math.max(0, maximumUpcomingItems);
  final safeLookAheadUs = math.max(0, lookAheadUs);
  final safeAtlasSegmentUs = math.max(1, atlasSegmentUs);
  final requestedFutureUs = positionUs + safeLookAheadUs;
  final alignedFutureUs =
      ((requestedFutureUs + safeAtlasSegmentUs - 1) ~/ safeAtlasSegmentUs) *
      safeAtlasSegmentUs;
  final upcomingEnd = _firstStartAfter(items, alignedFutureUs);
  // Filtering must not turn a bounded maintenance pass into a scan of an
  // arbitrarily dense hidden burst on the UI isolate.
  const maximumFilteredCandidates = 16384;
  final activeStart = includeItem == null
      ? active.start
      : math.max(active.start, active.endExclusive - maximumFilteredCandidates);
  final upcomingLimit = includeItem == null
      ? upcomingEnd
      : math.min(upcomingEnd, active.endExclusive + maximumFilteredCandidates);
  final safeMaximumActiveItems = math.max(0, maximumActiveItems);
  var activeCount = 0;
  for (
    var i = active.endExclusive - 1;
    i >= activeStart && activeCount < safeMaximumActiveItems;
    i--
  ) {
    if (includeItem != null && !includeItem(items[i])) continue;
    if (textWidthOf != null &&
        positionUs - items[i].startTime.inMicroseconds >=
            resolveDanmakuDurationUs(
              items[i],
              speed: speed,
              viewportWidth: viewportWidth,
              referenceWidth: referenceWidth,
              textWidth: textWidthOf(items[i]),
            )) {
      continue;
    }
    result.add(i);
    activeCount++;
  }
  var upcomingCount = 0;
  for (
    var i = active.endExclusive;
    i < upcomingLimit && upcomingCount < safeMaximumUpcomingItems;
    i++
  ) {
    if (includeItem != null && !includeItem(items[i])) continue;
    result.add(i);
    upcomingCount++;
  }
  return result;
}

int _firstStartAtOrAfter(List<DanmakuItem> items, int positionUs) {
  var low = 0;
  var high = items.length;
  while (low < high) {
    final mid = (low + high) >> 1;
    if (items[mid].startTime.inMicroseconds < positionUs) {
      low = mid + 1;
    } else {
      high = mid;
    }
  }
  return low;
}

int _firstStartAfter(List<DanmakuItem> items, int positionUs) {
  var low = 0;
  var high = items.length;
  while (low < high) {
    final mid = (low + high) >> 1;
    if (items[mid].startTime.inMicroseconds <= positionUs) {
      low = mid + 1;
    } else {
      high = mid;
    }
  }
  return low;
}

/// Incremental media-time index used by the painter's hot path.
///
/// This is public only so the overload behavior can be regression-tested
/// without pumping a platform-specific raster surface.
@visibleForTesting
class DanmakuActiveSet {
  DanmakuActiveSet(this.items);

  final List<DanmakuItem> items;
  double Function(DanmakuItem)? _textWidthOf;
  Object? _metricsKey;
  double _textWidthPerCodeUnit = 640;
  final List<int> _active = <int>[];
  final Map<String, int> _activeTextCounts = <String, int>{};
  int _nextStartIndex = 0;
  int? _lastPositionUs;
  double? _lastSpeed;
  double? _lastViewportWidth;
  double _density = 1.0;
  int? _nextExpiryUs;
  int _revision = 0;

  int get revision => _revision;

  List<int> update({
    required int positionUs,
    required double speed,
    required int admissionCap,
    double viewportWidth = 1920,
    double referenceWidth = 1920,
    double? motionAnchorWidth,
    double density = 1.0,
    double Function(DanmakuItem)? textWidthOf,
    Object? metricsKey,
    double textWidthPerCodeUnit = 640,
  }) {
    final previousCount = _active.length;
    final previousNextStartIndex = _nextStartIndex;
    final motionWidth = viewportWidth;
    final safeSpeed = _motionSpeed(speed);
    final currentWidth = viewportWidth;
    final metricsChanged = _metricsKey != metricsKey;
    _metricsKey = metricsKey;
    _textWidthOf = textWidthOf;
    _textWidthPerCodeUnit = textWidthPerCodeUnit;
    final densityChanged = _density != density;
    _density = density;
    final mustReset =
        metricsChanged ||
        densityChanged ||
        _lastPositionUs == null ||
        positionUs < _lastPositionUs! ||
        positionUs - _lastPositionUs! > 2000000 ||
        _lastSpeed != safeSpeed ||
        _lastViewportWidth == null ||
        _lastViewportWidth != currentWidth;
    if (mustReset) {
      _reset(positionUs, safeSpeed, admissionCap, motionWidth, referenceWidth);
    } else {
      _removeExpired(positionUs, safeSpeed, motionWidth, referenceWidth);
      _addNew(positionUs, safeSpeed, admissionCap, motionWidth, referenceWidth);
      // A performance-policy change can lower the cap while a dense burst is
      // already on screen. Only applying the cap in _addNew leaves all of the
      // existing items alive for their full duration, which is exactly when
      // the raster thread most needs relief.
      _trimToAdmissionCap(admissionCap);
    }
    _lastPositionUs = positionUs;
    _lastSpeed = safeSpeed;
    _lastViewportWidth = currentWidth;
    if (mustReset ||
        previousCount != _active.length ||
        previousNextStartIndex != _nextStartIndex) {
      _revision++;
    }
    return _active;
  }

  void _reset(
    int positionUs,
    double speed,
    int admissionCap,
    double viewportWidth,
    double referenceWidth,
  ) {
    _active.clear();
    _activeTextCounts.clear();
    _nextExpiryUs = null;
    final earliest =
        positionUs -
        _maximumMotionDuration(
          items,
          viewportWidth,
          speed,
          _textWidthPerCodeUnit,
        );
    final first = _firstStartAtOrAfter(items, earliest);
    _nextStartIndex = _firstStartAfter(items, positionUs);
    final candidates = <int>[];
    for (var index = first; index < _nextStartIndex; index++) {
      if (_isActive(
        items[index],
        positionUs,
        speed,
        viewportWidth,
        referenceWidth,
      )) {
        candidates.add(index);
      }
    }
    _admit(candidates, admissionCap);
  }

  void _removeExpired(
    int positionUs,
    double speed,
    double viewportWidth,
    double referenceWidth,
  ) {
    // Most frames have no membership changes. Keep the earliest expiry as an
    // event boundary instead of resolving every active duration on every VSync.
    if (_nextExpiryUs != null && positionUs < _nextExpiryUs!) return;
    _nextExpiryUs = null;
    var write = 0;
    for (final index in _active) {
      final item = items[index];
      if (_isActive(item, positionUs, speed, viewportWidth, referenceWidth)) {
        _active[write++] = index;
      } else {
        final count = _activeTextCounts[item.text] ?? 0;
        if (count <= 1) {
          _activeTextCounts.remove(item.text);
        } else {
          _activeTextCounts[item.text] = count - 1;
        }
      }
    }
    _active.length = write;
  }

  void _addNew(
    int positionUs,
    double speed,
    int admissionCap,
    double viewportWidth,
    double referenceWidth,
  ) {
    if (_nextStartIndex >= items.length ||
        items[_nextStartIndex].startTime.inMicroseconds > positionUs) {
      return;
    }
    final candidates = <int>[];
    while (_nextStartIndex < items.length &&
        items[_nextStartIndex].startTime.inMicroseconds <= positionUs) {
      final index = _nextStartIndex++;
      if (_isActive(
        items[index],
        positionUs,
        speed,
        viewportWidth,
        referenceWidth,
      )) {
        candidates.add(index);
      }
    }
    _admit(candidates, admissionCap);
  }

  void _admit(List<int> candidates, int admissionCap) {
    if (candidates.isEmpty) return;
    final isAdaptiveOverload = admissionCap < _normalDanmakuAdmissionCap;
    if (isAdaptiveOverload) {
      final priorities = <int, int>{
        for (final index in candidates) index: _stablePriority(items[index]),
      };
      candidates.sort((left, right) {
        final leftDuplicate = _activeTextCounts.containsKey(items[left].text);
        final rightDuplicate = _activeTextCounts.containsKey(items[right].text);
        if (leftDuplicate != rightDuplicate) return leftDuplicate ? 1 : -1;
        return priorities[right]!.compareTo(priorities[left]!);
      });
    }
    for (final index in candidates) {
      if (!danmakuPassesDensity(items[index], _density)) continue;
      if (_active.length >= admissionCap) break;
      final item = items[index];
      if (isAdaptiveOverload &&
          _active.length >= admissionCap * 3 ~/ 4 &&
          _activeTextCounts.containsKey(item.text)) {
        continue;
      }
      _active.add(index);
      _activeTextCounts.update(
        item.text,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
  }

  void _trimToAdmissionCap(int admissionCap) {
    if (admissionCap >= _unrestrictedDanmakuAdmissions ||
        _active.length <= admissionCap) {
      return;
    }
    if (admissionCap <= 0) {
      _active.clear();
      _activeTextCounts.clear();
      return;
    }

    // Keep the reduction deterministic so a policy transition never causes
    // random-looking flicker. Prefer one copy of each text before duplicates,
    // then use the same stable priority as admission for both groups.
    final priorities = <int, int>{
      for (final index in _active) index: _stablePriority(items[index]),
    };
    final ranked = List<int>.of(_active)
      ..sort((left, right) => priorities[right]!.compareTo(priorities[left]!));
    final selected = <int>[];
    final selectedIndices = <int>{};
    final selectedTexts = <String>{};
    for (final index in ranked) {
      if (selectedTexts.add(items[index].text)) {
        selected.add(index);
        selectedIndices.add(index);
      }
      if (selected.length == admissionCap) break;
    }
    if (selected.length < admissionCap) {
      for (final index in ranked) {
        if (!selectedIndices.add(index)) continue;
        selected.add(index);
        if (selected.length == admissionCap) break;
      }
    }
    selected.sort();
    _active
      ..clear()
      ..addAll(selected);
    _rebuildTextCounts();
  }

  void _rebuildTextCounts() {
    _activeTextCounts.clear();
    for (final index in _active) {
      _activeTextCounts.update(
        items[index].text,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
  }

  bool _isActive(
    DanmakuItem item,
    int positionUs,
    double speed,
    double viewportWidth,
    double referenceWidth,
  ) {
    final elapsedUs = positionUs - item.startTime.inMicroseconds;
    final durationUs = resolveDanmakuDurationUs(
      item,
      speed: speed,
      viewportWidth: viewportWidth,
      referenceWidth: referenceWidth,
      textWidth: _textWidthOf?.call(item) ?? 0,
    );
    final active = elapsedUs >= 0 && elapsedUs < durationUs;
    if (active) {
      final expiry = item.startTime.inMicroseconds + durationUs;
      if (_nextExpiryUs == null || expiry < _nextExpiryUs!) {
        _nextExpiryUs = expiry;
      }
    }
    return active;
  }

  int _stablePriority(DanmakuItem item) {
    var hash = item.index * 0x1f1f1f1f;
    for (final codeUnit in item.text.codeUnits) {
      hash = 0x1fffffff & (hash * 31 + codeUnit);
    }
    return hash;
  }
}

class _DanmakuMotionMetrics {
  _DanmakuAtlasStyle? _style;
  final Map<String, double> _widths = {};
  void ensureStyle(_DanmakuAtlasStyle style) {
    if (_style == style) return;
    _style = style;
    _widths.clear();
  }

  double get widthBound => _style!.fontSize * (4 + _style!.letterSpacing.abs());
  double widthOf(DanmakuItem item) {
    if (item.type != DanmakuType.scroll) return 0;
    if (_widths.length > 8192) _widths.clear();
    return _widths.putIfAbsent(item.text, () {
      final style = _style!;
      final painter = TextPainter(
        text: TextSpan(
          text: item.text.replaceAll(RegExp(r'[\r\n]+'), ' '),
          style: TextStyle(
            fontSize: style.fontSize,
            fontFamily: style.fontFamily,
            fontWeight: danmakuFontWeight(style.fontWeight),
            height: 1,
            letterSpacing: style.fontSize * style.letterSpacing,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    });
  }
}

class _DanmakuAtlasStyle {
  const _DanmakuAtlasStyle({
    required this.fontSize,
    required this.devicePixelRatio,
    required this.fontFamily,
    required this.fontWeight,
    this.outlineScale = 1.0,
    this.shadowScale = 1.0,
    this.letterSpacing = 0.0,
    required this.outlineType,
  });

  final double fontSize;
  final double devicePixelRatio;
  final String? fontFamily;
  final int fontWeight;
  final double outlineScale;
  final double shadowScale;
  final double letterSpacing;
  final DanmakuOutlineType outlineType;

  @override
  bool operator ==(Object other) {
    return other is _DanmakuAtlasStyle &&
        other.fontSize == fontSize &&
        other.devicePixelRatio == devicePixelRatio &&
        other.fontFamily == fontFamily &&
        other.fontWeight == fontWeight &&
        other.outlineScale == outlineScale &&
        other.shadowScale == shadowScale &&
        other.letterSpacing == letterSpacing &&
        other.outlineType == outlineType;
  }

  @override
  int get hashCode => Object.hash(
    fontSize,
    devicePixelRatio,
    fontFamily,
    fontWeight,
    outlineScale,
    shadowScale,
    letterSpacing,
    outlineType,
  );
}

class _DanmakuSpriteKey {
  const _DanmakuSpriteKey(this.text, this.colorValue);

  final String text;
  final int colorValue;

  @override
  bool operator ==(Object other) {
    return other is _DanmakuSpriteKey &&
        other.text == text &&
        other.colorValue == colorValue;
  }

  @override
  int get hashCode => Object.hash(text, colorValue);
}

class _DanmakuAtlasManager extends ChangeNotifier {
  _DanmakuAtlasManager({required this.maximumBytes, this.rasterize});

  final int maximumBytes;
  final Future<ui.Image> Function(ui.Picture, int, int)? rasterize;
  _DanmakuAtlasStyle? _requestedStyle;
  _DanmakuAtlasCache? _active;
  _DanmakuAtlasCache? _building;
  _DanmakuAtlasStyle? _fallbackStyle;
  final Map<_DanmakuSpriteKey, _PreparedDanmakuText> _fallbackSprites =
      <_DanmakuSpriteKey, _PreparedDanmakuText>{};
  final Map<int, _PreparedDanmakuText> _fallbackItems =
      <int, _PreparedDanmakuText>{};
  final Map<int, _PreparedDanmakuText> _provisionalItems =
      <int, _PreparedDanmakuText>{};
  int _generation = 0;
  int _revision = 0;
  bool _disposed = false;
  bool _fallbackEnabled = false;
  bool _fallbackNotificationScheduled = false;

  int get generation => _generation;
  int get revision => _revision;
  bool get usesFallback => _fallbackEnabled;

  void ensureStyle(_DanmakuAtlasStyle style) {
    if (_requestedStyle == style) return;
    _requestedStyle = style;
    _generation++;
    _revision++;
    if (_fallbackEnabled) {
      _disposeFallbackLayouts();
      _fallbackStyle = style;
      return;
    }
    if (_active == null) {
      _active = _DanmakuAtlasCache(style, maximumBytes, rasterize: rasterize);
    } else {
      _building?.dispose();
      _building = _DanmakuAtlasCache(style, maximumBytes, rasterize: rasterize);
      // Stand-in text was laid out at the previous size. The next visible
      // batch publishes it again for the style the slider is on now.
      _disposeProvisional();
    }
  }

  void beginPrefetchCycle() {
    _active?.unpinAll();
    _building?.unpinAll();
  }

  void pinPreparedItems(Iterable<int> itemIndices) {
    _active?.pinItems(itemIndices);
    _building?.pinItems(itemIndices);
  }

  void retainFallbackItems(
    Iterable<int> requestedItems, {
    Iterable<int> activeItems = const <int>[],
  }) {
    if (_disposed || !_fallbackEnabled) return;
    final retained = <int>{...requestedItems, ...activeItems};
    var changed = false;
    _fallbackItems.removeWhere((index, _) {
      if (retained.contains(index)) return false;
      changed = true;
      return true;
    });
    // Different item IDs can share the same normalized text/color layout.
    // Dispose only after its last retained alias has gone.
    final liveLayouts = _fallbackItems.values.toSet();
    _fallbackSprites.removeWhere((_, layout) {
      if (liveLayouts.contains(layout)) return false;
      layout.dispose();
      changed = true;
      return true;
    });
    if (changed) {
      // Painter caches can still hold expired layouts. Invalidate them before
      // the next real paint without requesting a frame just for cleanup.
      _revision++;
    }
  }

  Future<bool> prepare(
    List<DanmakuItem> items, {
    required int generation,
    required bool pinPages,
    bool provisional = false,
    bool Function()? shouldContinue,
    bool Function()? shouldNotify,
  }) async {
    if (_disposed ||
        generation != _generation ||
        items.isEmpty ||
        shouldContinue?.call() == false) {
      return false;
    }
    if (_fallbackEnabled) {
      final changed = _prepareFallback(items);
      if (changed) notifyListeners();
      return changed;
    }
    final target = _building ?? _active;
    if (target == null) return false;
    // Previous bitmaps stay on screen through a style rebuild. Items that
    // have no bitmap yet (a new page, or a comment that started during the
    // rebuild) draw as text until their atlas page is the one on screen.
    if (provisional) {
      _publishProvisional(items, target.style);
    }
    bool changed;
    try {
      changed = await target.prepareBatch(
        items,
        pinPages: pinPages,
        shouldContinue: shouldContinue,
      );
    } catch (_) {
      if (!_disposed &&
          generation == _generation &&
          shouldContinue?.call() != false) {
        _activateFallback(target.style, items);
        notifyListeners();
      }
      return true;
    } finally {
      // A rebuild stores the new glyphs in `_building`, which paint does not
      // read yet. Keep the text up until handover, or those comments vanish
      // for the rest of the upload.
      if (identical(target, _active)) {
        _releaseProvisional(items, notify: shouldNotify?.call() != false);
      }
    }
    if (_disposed || generation != _generation) return false;
    // The new atlas stays in `_building` until the visible set is complete.
    // Promoting the first batch used to dispose the comments already on screen.
    if (identical(_active, target) && changed) {
      if (shouldNotify?.call() != false) {
        notifyListeners();
      } else {
        _revision++;
      }
    }
    return shouldContinue?.call() != false && changed;
  }

  /// Promotes a finished style atlas. Returns false when there is nothing new
  /// to show, so the caller can keep the previous glyphs.
  bool commitHandover({bool discardIfEmpty = false}) {
    final building = _building;
    if (building == null) return false;
    if (!building.hasSprites) {
      if (discardIfEmpty) {
        building.dispose();
        _building = null;
      }
      return false;
    }
    final previous = _active;
    _active = building;
    _building = null;
    previous?.dispose();
    // The new atlas is what paint reads now. Drop the stand-in text so it
    // cannot outlive the bitmaps it was covering for.
    _disposeProvisional();
    notifyListeners();
    return true;
  }

  _DanmakuSprite? lookup(int itemIndex) => _active?.lookup(itemIndex);

  _PreparedDanmakuText? lookupFallback(int itemIndex) {
    return _fallbackItems[itemIndex] ?? _provisionalItems[itemIndex];
  }

  void _publishProvisional(List<DanmakuItem> items, _DanmakuAtlasStyle style) {
    var changed = false;
    for (final item in items) {
      if (lookup(item.index) != null ||
          _provisionalItems.containsKey(item.index)) {
        continue;
      }
      _provisionalItems[item.index] = _PreparedDanmakuText(item, style);
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void _releaseProvisional(List<DanmakuItem> items, {bool notify = true}) {
    var changed = false;
    for (final item in items) {
      final layout = _provisionalItems.remove(item.index);
      if (layout == null) continue;
      layout.dispose();
      changed = true;
    }
    if (changed) {
      if (notify) {
        notifyListeners();
      } else {
        // A visible request can replace this one before its upload finishes.
        // Invalidate retained painter layouts even when hidden cleanup has
        // no reason to request another frame.
        _revision++;
      }
    }
  }

  void _disposeProvisional() {
    for (final layout in _provisionalItems.values) {
      layout.dispose();
    }
    _provisionalItems.clear();
  }

  void beginFrame() => _active?.beginFrame();

  void addSprite(
    _DanmakuSprite sprite,
    double x,
    double y, {
    required bool continuousHorizontal,
    double glyphScale = 1,
  }) {
    _active?.addSprite(
      sprite,
      x,
      y,
      continuousHorizontal: continuousHorizontal,
      glyphScale: glyphScale,
    );
  }

  void paintFrame(Canvas canvas, Paint paint, double opacity) {
    if (_fallbackEnabled) return;
    try {
      _active?.paintFrame(canvas, paint, opacity);
    } catch (_) {
      final style = _active?.style ?? _requestedStyle;
      if (style == null) return;
      _activateFallback(style, const <DanmakuItem>[]);
      if (_fallbackNotificationScheduled) return;
      _fallbackNotificationScheduled = true;
      scheduleMicrotask(() {
        _fallbackNotificationScheduled = false;
        if (!_disposed) notifyListeners();
      });
    }
  }

  void _activateFallback(
    _DanmakuAtlasStyle style,
    List<DanmakuItem> initialItems,
  ) {
    _revision++;
    _active?.dispose();
    _building?.dispose();
    _active = null;
    _building = null;
    _disposeProvisional();
    _fallbackEnabled = true;
    _fallbackStyle = style;
    _disposeFallbackLayouts();
    _prepareFallback(initialItems);
  }

  bool _prepareFallback(List<DanmakuItem> items) {
    final style = _fallbackStyle;
    if (style == null) return false;
    var changed = false;
    for (final item in items) {
      final text = item.text.replaceAll(RegExp(r'[\r\n]+'), ' ');
      final key = _DanmakuSpriteKey(text, item.colorValue);
      final layout = _fallbackSprites.putIfAbsent(
        key,
        () => _PreparedDanmakuText(item, style),
      );
      if (!_fallbackItems.containsKey(item.index)) changed = true;
      _fallbackItems[item.index] = layout;
    }
    return changed;
  }

  void _disposeFallbackLayouts() {
    for (final layout in _fallbackSprites.values) {
      layout.dispose();
    }
    _fallbackSprites.clear();
    _fallbackItems.clear();
  }

  void clear() {
    _generation++;
    _revision++;
    _active?.dispose();
    _building?.dispose();
    _disposeFallbackLayouts();
    _disposeProvisional();
    _active = null;
    _building = null;
    _fallbackStyle = null;
    _fallbackEnabled = false;
    _requestedStyle = null;
  }

  @override
  void notifyListeners() {
    _revision++;
    super.notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    clear();
    super.dispose();
  }
}

/// Exercises the private fallback owner with real layouts and injected upload
/// failures. This is not used by the application or the normal atlas path.
@visibleForTesting
class DanmakuFallbackRetentionProbe {
  DanmakuFallbackRetentionProbe({
    required Future<ui.Image> Function(ui.Picture, int, int) rasterize,
  }) : _manager = _DanmakuAtlasManager(
         maximumBytes: 1024 * 1024,
         rasterize: rasterize,
       ) {
    _manager.ensureStyle(
      const _DanmakuAtlasStyle(
        fontSize: 24,
        devicePixelRatio: 1,
        fontFamily: null,
        fontWeight: 600,
        outlineScale: 1,
        shadowScale: 1,
        letterSpacing: 0,
        outlineType: DanmakuOutlineType.standard,
      ),
    );
  }

  final _DanmakuAtlasManager _manager;

  bool get usesFallback => _manager.usesFallback;
  int get itemCount => _manager._fallbackItems.length;
  int get layoutCount => _manager._fallbackSprites.length;
  int get revision => _manager.revision;

  Future<void> prepare(List<DanmakuItem> items) async {
    await _manager.prepare(
      items,
      generation: _manager.generation,
      pinPages: true,
    );
  }

  void retain(
    Iterable<int> requestedItems, {
    Iterable<int> activeItems = const <int>[],
  }) => _manager.retainFallbackItems(requestedItems, activeItems: activeItems);

  List<TextPainter> paintersFor(int itemIndex) {
    final layout = _manager.lookupFallback(itemIndex);
    if (layout == null) return const <TextPainter>[];
    return [layout._fill, layout._stroke, ?layout._projection];
  }

  void paint(Canvas canvas, int itemIndex, Offset offset) => _manager
      .lookupFallback(itemIndex)!
      .paintTextAt(canvas, offset.dx, offset.dy);

  void dispose() => _manager.dispose();
}

class _DanmakuAtlasCache {
  _DanmakuAtlasCache(this.style, this.maximumBytes, {this.rasterize});

  static const int _pageWidth = 2048;
  static const int _pageHeight = 1024;
  static const int _gutter = 2;

  final _DanmakuAtlasStyle style;
  final int maximumBytes;
  final Future<ui.Image> Function(ui.Picture, int, int)? rasterize;
  final Map<_DanmakuSpriteKey, _DanmakuSprite> _sprites =
      <_DanmakuSpriteKey, _DanmakuSprite>{};
  final Map<int, _DanmakuSprite> _itemSprites = <int, _DanmakuSprite>{};
  final List<_DanmakuAtlasPage> _pages = <_DanmakuAtlasPage>[];
  final List<_DanmakuAtlasPage> _framePages = <_DanmakuAtlasPage>[];
  int _byteSize = 0;
  int _touchSequence = 0;
  bool _disposed = false;

  bool get hasSprites => _sprites.isNotEmpty;

  _DanmakuSprite? lookup(int itemIndex) => _itemSprites[itemIndex];

  void unpinAll() {
    for (final page in _pages) {
      page.pinned = false;
    }
  }

  void pinItems(Iterable<int> itemIndices) {
    for (final itemIndex in itemIndices) {
      final sprite = _itemSprites[itemIndex];
      if (sprite == null) continue;
      sprite.page.pinned = true;
      sprite.page.lastTouch = ++_touchSequence;
    }
  }

  Future<bool> prepareBatch(
    List<DanmakuItem> items, {
    required bool pinPages,
    bool Function()? shouldContinue,
  }) async {
    if (_disposed) return false;
    final pending = <_DanmakuSpriteKey, _PendingDanmakuSprite>{};
    var changed = false;
    for (final item in items) {
      // The same prefetch window is revisited repeatedly. Resolve known item
      // IDs before normalizing and hashing potentially long comment strings.
      final existing = _itemSprites[item.index];
      if (existing != null) {
        existing.page.pinned = existing.page.pinned || pinPages;
        existing.page.lastTouch = ++_touchSequence;
        continue;
      }
      final normalizedText = item.text.replaceAll(RegExp(r'[\r\n]+'), ' ');
      final key = _DanmakuSpriteKey(normalizedText, item.colorValue);
      final cached = _sprites[key];
      if (cached != null) {
        _itemSprites[item.index] = cached;
        cached.page.itemIndices.add(item.index);
        changed = true;
        cached.page.pinned = cached.page.pinned || pinPages;
        cached.page.lastTouch = ++_touchSequence;
        continue;
      }
      final entry = pending.putIfAbsent(
        key,
        () => _PendingDanmakuSprite(
          key: key,
          prepared: _PreparedDanmakuText(item, style),
        ),
      );
      entry.itemIndices.add(item.index);
    }
    if (pending.isEmpty) return changed;

    final plans = <_DanmakuAtlasPagePlan>[];
    _DanmakuAtlasPagePlan? current;
    for (final entry in pending.values) {
      final prepared = entry.prepared;
      if (prepared.pixelWidth + _gutter * 2 > _pageWidth ||
          prepared.pixelHeight + _gutter * 2 > _pageHeight) {
        final dedicated = _DanmakuAtlasPagePlan(
          math.max(1, prepared.pixelWidth + _gutter * 2),
          math.max(1, prepared.pixelHeight + _gutter * 2),
          _gutter,
        );
        dedicated.tryPlace(entry);
        plans.add(dedicated);
        continue;
      }
      current ??= _DanmakuAtlasPagePlan(_pageWidth, _pageHeight, _gutter);
      if (!current.tryPlace(entry)) {
        plans.add(current);
        current = _DanmakuAtlasPagePlan(_pageWidth, _pageHeight, _gutter)
          ..tryPlace(entry);
      }
    }
    if (current != null && current.placements.isNotEmpty) plans.add(current);

    try {
      for (final plan in plans) {
        // Finish and retain an upload already in flight, but do not start a
        // second page after the overlay is hidden or its request is replaced.
        if (_disposed || shouldContinue?.call() == false) return changed;
        final recorder = ui.PictureRecorder();
        final pictureCanvas = Canvas(recorder)..scale(style.devicePixelRatio);
        for (final placement in plan.placements) {
          placement.pending.prepared.paint(
            pictureCanvas,
            placement.left / style.devicePixelRatio,
            placement.top / style.devicePixelRatio,
          );
        }
        final picture = recorder.endRecording();
        ui.Image image;
        try {
          image =
              await (rasterize?.call(
                    picture,
                    plan.usedWidth,
                    plan.usedHeight,
                  ) ??
                  picture.toImage(plan.usedWidth, plan.usedHeight));
        } finally {
          picture.dispose();
        }
        if (_disposed) {
          image.dispose();
          return false;
        }
        final page = _DanmakuAtlasPage(
          image: image,
          devicePixelRatio: style.devicePixelRatio,
          byteSize: plan.usedWidth * plan.usedHeight * 4,
          pinned: pinPages,
          lastTouch: ++_touchSequence,
        );
        _pages.add(page);
        _byteSize += page.byteSize;
        for (final placement in plan.placements) {
          final pendingSprite = placement.pending;
          final prepared = pendingSprite.prepared;
          final sprite = _DanmakuSprite(
            page: page,
            sourceLeft: placement.left.toDouble(),
            sourceTop: placement.top.toDouble(),
            sourceWidth: prepared.pixelWidth.toDouble(),
            sourceHeight: prepared.pixelHeight.toDouble(),
            width: prepared.width,
            height: prepared.height,
            imagePadding: prepared.imagePadding,
            fontSize: style.fontSize,
          );
          _sprites[pendingSprite.key] = sprite;
          page.keys.add(pendingSprite.key);
          for (final itemIndex in pendingSprite.itemIndices) {
            _itemSprites[itemIndex] = sprite;
            page.itemIndices.add(itemIndex);
          }
        }
        changed = true;
        _evictIfNeeded();
      }
      return changed;
    } finally {
      for (final entry in pending.values) {
        entry.prepared.dispose();
      }
    }
  }

  void _evictIfNeeded() {
    while (_byteSize > maximumBytes && _pages.length > 1) {
      _DanmakuAtlasPage? oldest;
      for (final page in _pages) {
        if (page.pinned) continue;
        if (oldest == null || page.lastTouch < oldest.lastTouch) oldest = page;
      }
      if (oldest == null) return;
      _pages.remove(oldest);
      _byteSize -= oldest.byteSize;
      // Eviction cost depends on the evicted page, not the entire cache (which
      // may contain many aliases for repeated text in a long video).
      for (final key in oldest.keys) {
        _sprites.remove(key);
      }
      for (final index in oldest.itemIndices) {
        _itemSprites.remove(index);
      }
      oldest.dispose();
    }
  }

  void beginFrame() {
    // Cached pages can far outnumber the pages visible in one frame. Reset
    // only pages used by the previous frame and collect this frame lazily.
    for (final page in _framePages) {
      page.beginFrame();
    }
    _framePages.clear();
  }

  void addSprite(
    _DanmakuSprite sprite,
    double x,
    double y, {
    required bool continuousHorizontal,
    double glyphScale = 1,
  }) {
    final page = sprite.page;
    if (!page.inFrame) {
      page.inFrame = true;
      _framePages.add(page);
    }
    page.addSprite(
      sprite,
      x,
      y,
      continuousHorizontal: continuousHorizontal,
      glyphScale: glyphScale,
    );
  }

  void paintFrame(Canvas canvas, Paint paint, double opacity) {
    for (final page in _framePages) {
      page.paint(canvas, paint, opacity);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final page in _pages) {
      page.dispose();
    }
    _pages.clear();
    _framePages.clear();
    _sprites.clear();
    _itemSprites.clear();
    _byteSize = 0;
  }
}

class _PendingDanmakuSprite {
  _PendingDanmakuSprite({required this.key, required this.prepared});

  final _DanmakuSpriteKey key;
  final _PreparedDanmakuText prepared;
  final List<int> itemIndices = <int>[];
}

class _PreparedDanmakuText {
  _PreparedDanmakuText(DanmakuItem item, _DanmakuAtlasStyle style)
    : _devicePixelRatio = style.devicePixelRatio {
    final text = item.text.replaceAll(RegExp(r'[\r\n]+'), ' ');
    _fill = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Color(item.colorValue),
          fontSize: style.fontSize,
          letterSpacing: style.fontSize * style.letterSpacing,
          fontFamily: style.fontFamily,
          fontWeight: danmakuFontWeight(style.fontWeight),
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final strokeWidth =
        resolveDanmakuOutlineWidth(style.outlineType, style.fontSize) *
        style.outlineScale;
    _hasStroke = strokeWidth > 0;
    _stroke = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: style.fontSize,
          letterSpacing: style.fontSize * style.letterSpacing,
          fontFamily: style.fontFamily,
          fontWeight: danmakuFontWeight(style.fontWeight),
          height: 1,
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeJoin = StrokeJoin.round
            ..strokeWidth = strokeWidth
            ..color = Colors.black.withValues(alpha: 0.9),
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    _projectionDistance =
        resolveDanmakuProjectionDistance(style.outlineType, style.fontSize) *
        style.shadowScale;
    _projection = _projectionDistance > 0
        ? (TextPainter(
            text: TextSpan(
              text: text,
              style: TextStyle(
                color: Colors.black.withValues(alpha: 0.9),
                shadows: style.outlineType == DanmakuOutlineType.shadow
                    ? [
                        Shadow(
                          color: Colors.black87,
                          blurRadius: resolveDanmakuShadowBlur(
                            style.outlineType,
                            style.fontSize,
                          ),
                        ),
                      ]
                    : null,
                fontSize: style.fontSize,
                letterSpacing: style.fontSize * style.letterSpacing,
                fontFamily: style.fontFamily,
                fontWeight: danmakuFontWeight(style.fontWeight),
                height: 1,
              ),
            ),
            textDirection: TextDirection.ltr,
            maxLines: 1,
          )..layout())
        : null;
    width = _fill.width;
    height = _fill.height;
    imagePadding =
        strokeWidth / 2 +
        _projectionDistance +
        resolveDanmakuShadowBlur(style.outlineType, style.fontSize) * 2 +
        1;
    pixelWidth = math.max(
      1,
      ((width + imagePadding * 2) * _devicePixelRatio).ceil(),
    );
    pixelHeight = math.max(
      1,
      ((height + imagePadding * 2) * _devicePixelRatio).ceil(),
    );
  }

  late final TextPainter _fill;
  late final bool _hasStroke;
  late final TextPainter _stroke;
  late final TextPainter? _projection;
  late final double _projectionDistance;
  final double _devicePixelRatio;
  late final double width;
  late final double height;
  late final double imagePadding;
  late final int pixelWidth;
  late final int pixelHeight;

  void paint(Canvas canvas, double left, double top) {
    final textOffset = Offset(left + imagePadding, top + imagePadding);
    final projection = _projection;
    if (projection != null) {
      projection.paint(
        canvas,
        textOffset + Offset(_projectionDistance, _projectionDistance),
      );
    }
    if (_hasStroke) _stroke.paint(canvas, textOffset);
    _fill.paint(canvas, textOffset);
  }

  void paintTextAt(Canvas canvas, double x, double y) {
    paint(canvas, x - imagePadding, y - imagePadding);
  }

  void dispose() {
    _fill.dispose();
    _stroke.dispose();
    _projection?.dispose();
  }
}

class _DanmakuAtlasPlacement {
  const _DanmakuAtlasPlacement(this.pending, this.left, this.top);

  final _PendingDanmakuSprite pending;
  final int left;
  final int top;
}

class _DanmakuAtlasPagePlan {
  _DanmakuAtlasPagePlan(this.maximumWidth, this.maximumHeight, this.gutter)
    : _cursorX = gutter,
      _cursorY = gutter;

  final int maximumWidth;
  final int maximumHeight;
  final int gutter;
  final List<_DanmakuAtlasPlacement> placements = <_DanmakuAtlasPlacement>[];
  int _cursorX;
  int _cursorY;
  int _rowHeight = 0;
  int usedWidth = 1;
  int usedHeight = 1;

  bool tryPlace(_PendingDanmakuSprite pending) {
    final width = pending.prepared.pixelWidth;
    final height = pending.prepared.pixelHeight;
    if (width + gutter * 2 > maximumWidth ||
        height + gutter * 2 > maximumHeight) {
      return false;
    }
    if (_cursorX + width + gutter > maximumWidth) {
      _cursorX = gutter;
      _cursorY += _rowHeight + gutter;
      _rowHeight = 0;
    }
    if (_cursorY + height + gutter > maximumHeight) return false;
    placements.add(_DanmakuAtlasPlacement(pending, _cursorX, _cursorY));
    usedWidth = math.max(usedWidth, _cursorX + width + gutter);
    usedHeight = math.max(usedHeight, _cursorY + height + gutter);
    _cursorX += width + gutter;
    _rowHeight = math.max(_rowHeight, height);
    return true;
  }
}

class _DanmakuSprite {
  const _DanmakuSprite({
    required this.page,
    required this.sourceLeft,
    required this.sourceTop,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.width,
    required this.height,
    required this.imagePadding,
    required this.fontSize,
  });

  final _DanmakuAtlasPage page;
  final double sourceLeft;
  final double sourceTop;
  final double sourceWidth;
  final double sourceHeight;
  final double width;
  final double height;
  final double imagePadding;
  final double fontSize;
}

class _DanmakuAtlasPage {
  _DanmakuAtlasPage({
    required this.image,
    required this.devicePixelRatio,
    required this.byteSize,
    required this.pinned,
    required this.lastTouch,
  });

  final ui.Image image;
  final double devicePixelRatio;
  final int byteSize;
  final Set<_DanmakuSpriteKey> keys = <_DanmakuSpriteKey>{};
  final Set<int> itemIndices = <int>{};
  bool pinned;
  int lastTouch;
  bool inFrame = false;
  Float32List _transforms = Float32List(64 * 4);
  Float32List _rects = Float32List(64 * 4);
  Int32List _colors = Int32List(64);
  int _spriteCount = 0;
  int _viewSpriteCount = -1;
  late Float32List _transformView;
  late Float32List _rectView;
  late Int32List _colorView;
  int _colorAlpha = -1;
  int _coloredCount = 0;

  void beginFrame() {
    _spriteCount = 0;
    inFrame = false;
  }

  void addSprite(
    _DanmakuSprite sprite,
    double x,
    double y, {
    required bool continuousHorizontal,
    double glyphScale = 1,
  }) {
    _ensureCapacity(_spriteCount + 1);
    final offset = _spriteCount * 4;
    // A font-size drag scales the previous bitmap into the new lane until the
    // matching atlas is ready. Scale 1 keeps the uploaded glyph pixel-exact.
    final safeGlyphScale = glyphScale.isFinite && glyphScale > 0
        ? glyphScale
        : 1.0;
    final scale = safeGlyphScale / devicePixelRatio;
    final destinationX = x - sprite.imagePadding * safeGlyphScale;
    final destinationY = y - sprite.imagePadding * safeGlyphScale;
    _transforms[offset] = scale;
    _transforms[offset + 1] = 0;
    // Preserve fractional scrolling X and exactly the same static pixel snap
    // without allocating an Offset for every sprite on every frame.
    _transforms[offset + 2] = continuousHorizontal
        ? destinationX
        : _snapDanmakuLogicalPixel(destinationX, devicePixelRatio);
    _transforms[offset + 3] = _snapDanmakuLogicalPixel(
      destinationY,
      devicePixelRatio,
    );
    _rects[offset] = sprite.sourceLeft;
    _rects[offset + 1] = sprite.sourceTop;
    _rects[offset + 2] = sprite.sourceLeft + sprite.sourceWidth;
    _rects[offset + 3] = sprite.sourceTop + sprite.sourceHeight;
    _spriteCount++;
  }

  void _ensureCapacity(int required) {
    final currentCapacity = _transforms.length ~/ 4;
    if (required <= currentCapacity) return;
    var nextCapacity = currentCapacity;
    while (nextCapacity < required) {
      nextCapacity *= 2;
    }
    final nextTransforms = Float32List(nextCapacity * 4)
      ..setRange(0, _transforms.length, _transforms);
    final nextRects = Float32List(nextCapacity * 4)
      ..setRange(0, _rects.length, _rects);
    final nextColors = Int32List(nextCapacity)
      ..setRange(0, _colors.length, _colors);
    _transforms = nextTransforms;
    _rects = nextRects;
    _colors = nextColors;
    _viewSpriteCount = -1;
  }

  void paint(Canvas canvas, Paint paint, double opacity) {
    if (_spriteCount == 0) return;
    final valueCount = _spriteCount * 4;
    final alpha = (opacity * 255).round().clamp(0, 255);
    final useColors = alpha < 255;
    if (useColors) {
      if (_colorAlpha != alpha) {
        _colors.fillRange(0, _spriteCount, alpha << 24);
        _colorAlpha = alpha;
        _coloredCount = _spriteCount;
      } else if (_spriteCount > _coloredCount) {
        _colors.fillRange(_coloredCount, _spriteCount, alpha << 24);
        _coloredCount = _spriteCount;
      }
    }
    // The backing buffers remain stable until capacity grows. Keep their
    // bounded views too, instead of allocating new views on every VSync.
    if (_viewSpriteCount != _spriteCount) {
      _transformView = Float32List.sublistView(_transforms, 0, valueCount);
      _rectView = Float32List.sublistView(_rects, 0, valueCount);
      _colorView = Int32List.sublistView(_colors, 0, _spriteCount);
      _viewSpriteCount = _spriteCount;
    }
    canvas.drawRawAtlas(
      image,
      _transformView,
      _rectView,
      useColors ? _colorView : null,
      useColors ? BlendMode.srcIn : null,
      null,
      paint,
    );
  }

  void dispose() => image.dispose();
}

@visibleForTesting
Offset resolveDanmakuAtlasDestination(
  double x,
  double y,
  double devicePixelRatio, {
  bool continuousHorizontal = true,
}) {
  return Offset(
    continuousHorizontal ? x : _snapDanmakuLogicalPixel(x, devicePixelRatio),
    _snapDanmakuLogicalPixel(y, devicePixelRatio),
  );
}

double _snapDanmakuLogicalPixel(double value, double devicePixelRatio) {
  final dpr = devicePixelRatio.isFinite && devicePixelRatio > 0
      ? devicePixelRatio
      : 1.0;
  return (value * dpr).round() / dpr;
}

class _DanmakuPerformanceGovernor extends ChangeNotifier {
  final Queue<bool> _overBudgetWindow = Queue<bool>();
  final Queue<int> _vsyncIntervalsUs = Queue<int>();
  TimingsCallback? _callback;
  int? _lastVsyncUs;
  int _level = 0;
  int _admissionCap = _unrestrictedDanmakuAdmissions;
  int _recoveryFrames = 0;
  int _consecutiveSevereFrames = 0;
  double? _refreshRate;
  ui.FlutterView? _view;

  bool get constrainPrefetch => _level >= 1;
  int get admissionCap => _admissionCap;

  void updateView(ui.FlutterView view) {
    _view = view;
    try {
      updateRefreshRate(view.display.refreshRate);
    } catch (_) {
      // A monitor/view can disappear while its last timings are delivered.
      // Keep the VSync-based fallback usable during that handover.
      _refreshRate = null;
    }
  }

  void updateRefreshRate(double refreshRate) {
    _refreshRate =
        refreshRate.isFinite && refreshRate >= 1 && refreshRate <= 2000
        ? refreshRate
        : null;
  }

  void start() {
    if (_callback != null) return;
    _callback = _handleTimings;
    SchedulerBinding.instance.addTimingsCallback(_callback!);
  }

  void stop() {
    final callback = _callback;
    if (callback == null) return;
    SchedulerBinding.instance.removeTimingsCallback(callback);
    _callback = null;
    _lastVsyncUs = null;
    _vsyncIntervalsUs.clear();
    _overBudgetWindow.clear();
    _consecutiveSevereFrames = 0;
    _recoveryFrames = 0;
  }

  void _handleTimings(List<FrameTiming> timings) {
    if (_callback == null) return;
    // A display/VRR change need not rebuild the overlay. Read the view again
    // per timing batch while keeping widget-tree lookups out of frame paint.
    final view = _view;
    if (view != null) updateView(view);
    var changed = false;
    for (final timing in timings) {
      final vsyncUs = timing.timestampInMicroseconds(ui.FramePhase.vsyncStart);
      final intervalUs = _lastVsyncUs == null ? 16667 : vsyncUs - _lastVsyncUs!;
      _lastVsyncUs = vsyncUs;
      if (intervalUs >= 500 && intervalUs <= 1000000) {
        _vsyncIntervalsUs.addLast(intervalUs);
        if (_vsyncIntervalsUs.length > 60) _vsyncIntervalsUs.removeFirst();
      }
      final budgetUs = _resolveFrameBudgetUs();
      final workUs = math.max(
        timing.buildDuration.inMicroseconds,
        timing.rasterDuration.inMicroseconds,
      );
      final overBudget = workUs > budgetUs * 0.8;
      _overBudgetWindow.addLast(overBudget);
      if (_overBudgetWindow.length > 12) _overBudgetWindow.removeFirst();

      if (workUs < budgetUs * 0.6) {
        _recoveryFrames++;
      } else {
        _recoveryFrames = 0;
      }

      if (workUs > budgetUs * 1.2) {
        _consecutiveSevereFrames++;
      } else {
        _consecutiveSevereFrames = 0;
      }

      if (_consecutiveSevereFrames >= 3) {
        _consecutiveSevereFrames = 0;
        _recoveryFrames = 0;
        _overBudgetWindow.clear();
        if (_level == 0) {
          _level = 1;
          _admissionCap = _adaptiveDanmakuAdmissionCap;
          changed = true;
        } else if (_level == 1) {
          _level = 2;
          _admissionCap = _severeDanmakuAdmissionCap;
          changed = true;
        } else {
          final reduced = math.max(32, (_admissionCap * 0.8).floor());
          if (reduced != _admissionCap) {
            _admissionCap = reduced;
            changed = true;
          }
        }
      } else if (_overBudgetWindow.length == 12 &&
          _overBudgetWindow.where((value) => value).length >= 8) {
        _recoveryFrames = 0;
        _overBudgetWindow.clear();
        if (_level == 0) {
          _level = 1;
          _admissionCap = _adaptiveDanmakuAdmissionCap;
          changed = true;
        } else if (_level == 1) {
          _level = 2;
          _admissionCap = _severeDanmakuAdmissionCap;
          changed = true;
        } else {
          final reduced = math.max(32, (_admissionCap * 0.8).floor());
          if (reduced != _admissionCap) {
            _admissionCap = reduced;
            changed = true;
          }
        }
      } else if (_recoveryFrames >= 120 && _level > 0) {
        _recoveryFrames = 0;
        _overBudgetWindow.clear();
        if (_level == 2) {
          if (_admissionCap < _severeDanmakuAdmissionCap) {
            _admissionCap = math.min(
              _severeDanmakuAdmissionCap,
              math.max(_admissionCap + 1, (_admissionCap * 1.25).ceil()),
            );
          } else {
            _level = 1;
            _admissionCap = _adaptiveDanmakuAdmissionCap;
          }
        } else {
          _level = 0;
          _admissionCap = _unrestrictedDanmakuAdmissions;
        }
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  int _resolveFrameBudgetUs() {
    return resolveDanmakuFrameBudgetUs(
      refreshRate: _refreshRate,
      vsyncIntervalsUs: _vsyncIntervalsUs,
    );
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}

@visibleForTesting
int resolveDanmakuFrameBudgetUs({
  double? refreshRate,
  Iterable<int> vsyncIntervalsUs = const <int>[],
}) {
  // Reject invalid driver metadata while allowing low-refresh panels and
  // high-refresh displays. Animation itself always follows actual VSync.
  if (refreshRate != null &&
      refreshRate.isFinite &&
      refreshRate >= 1 &&
      refreshRate <= 2000) {
    return (1000000 / refreshRate).round();
  }
  final samples = vsyncIntervalsUs
      .where((interval) => interval >= 500 && interval <= 1000000)
      .toList();
  if (samples.length < 4) return 16667;
  samples.sort();
  // Retain the lower quartile so missed frames cannot increase the allowed
  // work and trigger further misses. Do not impose a 60/200Hz fallback floor.
  return samples[((samples.length - 1) * 0.25).round()];
}

int _atlasMemoryBudget() {
  if (kIsWeb) return 64 * 1024 * 1024;
  return switch (defaultTargetPlatform) {
    TargetPlatform.android || TargetPlatform.iOS => 64 * 1024 * 1024,
    _ => 128 * 1024 * 1024,
  };
}
