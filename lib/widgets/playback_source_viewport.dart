import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

bool _isPlaybackCover(Route<dynamic> route) => const {
  '/playback/portrait',
  '/playback/landscape',
  '/playback/podcast',
  '/bilibili/watch-loading',
}.contains(route.settings.name);

// IME animation consumes padding but does not change the browsing coordinate
// system. Keep physical safe areas in the comparison used to restore anchors.
EdgeInsets _systemPadding(MediaQueryData media) => EdgeInsets.fromLTRB(
  math.max(media.padding.left, media.viewPadding.left),
  math.max(media.padding.top, media.viewPadding.top),
  math.max(media.padding.right, media.viewPadding.right),
  math.max(media.padding.bottom, media.viewPadding.bottom),
);

/// Route-local, in-memory state. Nothing here owns a player or changes Back.
class PlaybackViewportRegistry {
  PlaybackViewportRegistry._();

  static final Set<_PlaybackSourceViewportState> _sources = {};
  static List<Route<dynamic>> _routes = const [];

  @visibleForTesting
  static int get retainedSnapshotCount => _sources.fold(
    0,
    (count, source) =>
        count + source._positions.where((p) => p._snapshot != null).length,
  );

  @visibleForTesting
  static int get registeredSourceCount => _sources.length;

  /// Called after one atomic navigator operation, including replacements.
  static void updateRoutes(Iterable<Route<dynamic>> routes) {
    _routes = routes.toList(growable: false);
    for (final source in _sources.toList(growable: false)) {
      _sync(source);
    }
  }

  static void _sync(_PlaybackSourceViewportState source) {
    final root = source._rootRoute;
    final index = root == null ? -1 : _routes.indexOf(root);
    final covered = index >= 0 && _routes.skip(index + 1).any(_isPlaybackCover);
    source._setCovered(covered);
  }
}

/// Protects the last visible geometry while playback covers a browsing route.
/// Nested library routes inherit their outer navigator's cover state. Data,
/// theme, text scaling and accessibility settings continue to update.
class PlaybackSourceViewport extends StatefulWidget {
  const PlaybackSourceViewport({super.key, required this.child});

  final Widget child;

  @override
  State<PlaybackSourceViewport> createState() => _PlaybackSourceViewportState();
}

class _PlaybackSourceViewportState extends State<PlaybackSourceViewport> {
  final Set<_PlaybackScrollPosition> _positions = {};
  Route<dynamic>? _rootRoute;
  ModalRoute<dynamic>? _localRoute;
  MediaQueryData? _lastMedia;
  Size? _lastSize;
  bool _covered = false;
  bool _rebuildQueued = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    _localRoute = route;
    final parent = context
        .dependOnInheritedWidgetOfExactType<_PlaybackViewportScope>()
        ?.owner;
    _rootRoute = parent?._rootRoute ?? route;
    if (route != null && _isPlaybackCover(route)) _rootRoute = null;
    PlaybackViewportRegistry._sources.add(this);
    PlaybackViewportRegistry._sync(this);
  }

  void _setCovered(bool value) {
    if (_covered == value) return;
    _covered = value;
    for (final position in _positions.toList(growable: false)) {
      if (value) {
        if (_localRoute?.navigator == _rootRoute?.navigator ||
            (_localRoute?.isCurrent ?? true)) {
          position._capture();
        }
      } else {
        position._release(protectUpdates: true);
      }
    }
    // Navigator may report initial routes while building its overlay.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_rebuildQueued) return;
      _rebuildQueued = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _rebuildQueued = false;
        if (mounted) setState(() {});
      });
    } else if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    PlaybackViewportRegistry._sources.remove(this);
    for (final position in _positions) {
      position._owner = null;
      position._snapshot = null;
    }
    _positions.clear();
    if (PlaybackViewportRegistry._sources.isEmpty) {
      PlaybackViewportRegistry._routes = const [];
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final live = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final previous = _lastMedia;
        if (!_covered &&
            previous != null &&
            (_lastSize != constraints.biggest ||
                previous.size != live.size ||
                _systemPadding(previous) != _systemPadding(live) ||
                previous.viewPadding != live.viewPadding ||
                previous.devicePixelRatio != live.devicePixelRatio ||
                previous.textScaler != live.textScaler)) {
          // Native orientation and system-bar updates can arrive after pop's
          // first frame. Anchor real geometry changes, not IME-only updates:
          // those would force another sliver layout on every keyboard frame.
          for (final position in _positions.toList(growable: false)) {
            position._capture();
            position._release();
          }
        }
        if (!_covered || _lastSize == null) {
          _lastSize = constraints.biggest;
          _lastMedia = live;
        }
        final size = _lastSize!;
        final held = _lastMedia!;
        final media = !_covered
            ? live
            : live.copyWith(
                size: held.size,
                devicePixelRatio: held.devicePixelRatio,
                padding: held.padding,
                viewPadding: held.viewPadding,
                viewInsets: held.viewInsets,
                systemGestureInsets: held.systemGestureInsets,
                displayFeatures: held.displayFeatures,
              );
        return _PlaybackViewportScope(
          owner: this,
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: size.width,
            maxWidth: size.width,
            minHeight: size.height,
            maxHeight: size.height,
            child: MediaQuery(data: media, child: widget.child),
          ),
        );
      },
    );
  }
}

class _PlaybackViewportScope extends InheritedWidget {
  const _PlaybackViewportScope({required this.owner, required super.child});

  final _PlaybackSourceViewportState owner;

  @override
  bool updateShouldNotify(_PlaybackViewportScope oldWidget) =>
      owner != oldWidget.owner;
}

/// Parked root tabs remain mounted, but only the visible tab needs a snapshot.
class PlaybackViewportActivity extends InheritedWidget {
  const PlaybackViewportActivity({
    super.key,
    required this.active,
    required super.child,
  });

  final bool active;

  @override
  bool updateShouldNotify(PlaybackViewportActivity oldWidget) =>
      active != oldWidget.active;
}

class _VisibleAnchor {
  const _VisibleAnchor(this.region, this.key, this.index, this.localOffset);

  final Object region;
  final Object key;
  final int index;
  final double localOffset;
}

/// One visit to one scrollable; never shared between routes or video IDs.
class PlaybackViewportSnapshot {
  PlaybackViewportSnapshot._(this.offset, this.viewport, this._anchors);

  final double offset;
  final double viewport;
  final List<_VisibleAnchor> _anchors;
}

/// The normal ScrollController contract, with a one-shot layout restoration.
/// No scroll listener, timer, persistence or per-frame capture is installed.
class PlaybackScrollController extends ScrollController {
  PlaybackScrollController({
    super.initialScrollOffset,
    super.keepScrollOffset,
    super.debugLabel,
  });

  /// Preserve visible content when an adaptive list changes its row grouping.
  static void preserveForRelayout(ScrollController controller) {
    for (final position in controller.positions) {
      if (position is _PlaybackScrollPosition && !position._holding) {
        position._capture();
        position._release();
      }
    }
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _PlaybackScrollPosition(
    physics: physics,
    context: context,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    oldPosition: oldPosition,
    debugLabel: debugLabel,
  );
}

class _PlaybackScrollPosition extends ScrollPositionWithSingleContext {
  _PlaybackScrollPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    ScrollPosition? oldPosition,
    super.debugLabel,
  }) : super(oldPosition: oldPosition) {
    _owner = context.storageContext
        .getInheritedWidgetOfExactType<_PlaybackViewportScope>()
        ?.owner;
    _owner?._positions.add(this);
    if (oldPosition is _PlaybackScrollPosition) {
      _snapshot = oldPosition._snapshot;
      _holding = oldPosition._holding;
      _preserveVisibleChanges = oldPosition._preserveVisibleChanges;
      oldPosition._snapshot = null;
    }
  }

  _PlaybackSourceViewportState? _owner;
  final Set<_RenderPlaybackRegion> _regions = {};
  PlaybackViewportSnapshot? _snapshot;
  Map<(Object, Object), int>? _resolvedIndexes;
  bool _holding = false;
  bool _preserveVisibleChanges = false;
  int _corrections = 0;

  void _capture() {
    if (_holding || !hasPixels || !hasViewportDimension) return;
    if (context.storageContext
            .getInheritedWidgetOfExactType<PlaybackViewportActivity>()
            ?.active ==
        false) {
      return;
    }
    if (_snapshot != null) {
      _holding = true;
      return;
    }
    final anchors = <_VisibleAnchor>[];
    for (final region in _regions) {
      if (region.attached && region.geometry != null) {
        anchors.addAll(region.capture(pixels, viewportDimension));
      }
    }
    anchors.sort((a, b) => a.localOffset.compareTo(b.localOffset));
    _snapshot = PlaybackViewportSnapshot._(
      pixels,
      viewportDimension,
      anchors.take(8).toList(growable: false),
    );
    _resolvedIndexes = null;
    _holding = true;
    _corrections = 0;
    if (isScrollingNotifier.value) goIdle();
  }

  void _release({bool protectUpdates = false}) {
    _holding = false;
    if (_snapshot == null) return;
    _preserveVisibleChanges |= protectUpdates;
    _corrections = 0;
    for (final region in _regions) {
      if (region.attached) region.markNeedsLayout();
    }
  }

  double _target(PlaybackViewportSnapshot snapshot) {
    for (final anchor in snapshot._anchors) {
      for (final region in _regions) {
        if (region.regionId != anchor.region || !region.attached) continue;
        final cacheKey = (anchor.region, anchor.key);
        final hint = _resolvedIndexes?[cacheKey] ?? anchor.index;
        if (hint < 0) continue;
        final index = region.indexOf(anchor.key, hint);
        if (index != anchor.index) {
          (_resolvedIndexes ??= {})[cacheKey] = index ?? -1;
        }
        if (index == null) continue;
        final offset = region.offsetFor(index);
        if (offset != null) return offset - anchor.localOffset;
      }
    }
    for (final anchor in snapshot._anchors) {
      for (final region in _regions) {
        if (region.regionId != anchor.region || region.itemCount == 0) continue;
        final offset = region.offsetFor(
          anchor.index.clamp(0, region.itemCount - 1),
        );
        if (offset != null) return offset - anchor.localOffset;
      }
    }
    return snapshot.offset;
  }

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final accepted = super.applyContentDimensions(
      minScrollExtent,
      maxScrollExtent,
    );
    if (!accepted) return false;
    final snapshot = _snapshot;
    if (snapshot == null || _holding) return true;
    final target = _target(snapshot).clamp(minScrollExtent, maxScrollExtent);
    if (target.isFinite && (target - pixels).abs() > 0.25 && _corrections < 4) {
      _corrections++;
      correctPixels(target);
      // RenderViewport repeats layout in this frame, before any paint.
      return false;
    }
    _snapshot = null;
    _resolvedIndexes = null;
    return true;
  }

  @override
  void jumpTo(double value) {
    // Explicit locate/selection navigation takes priority over a saved visit.
    _snapshot = null;
    _resolvedIndexes = null;
    _preserveVisibleChanges = false;
    super.jumpTo(value);
  }

  @override
  Future<void> animateTo(
    double to, {
    required Duration duration,
    required Curve curve,
  }) {
    _snapshot = null;
    _resolvedIndexes = null;
    _preserveVisibleChanges = false;
    return super.animateTo(to, duration: duration, curve: curve);
  }

  @override
  void applyUserOffset(double delta) {
    _snapshot = null;
    _resolvedIndexes = null;
    _preserveVisibleChanges = false;
    super.applyUserOffset(delta);
  }

  @override
  void pointerScroll(double delta) {
    _snapshot = null;
    _resolvedIndexes = null;
    _preserveVisibleChanges = false;
    super.pointerScroll(delta);
  }

  @override
  void dispose() {
    _owner?._positions.remove(this);
    _owner = null;
    _snapshot = null;
    _resolvedIndexes = null;
    _regions.clear();
    super.dispose();
  }
}

/// Wrap the lazy sliver, inside its padding, so precedingScrollExtent gives
/// the exact position even when its target grid cell has not been built.
class PlaybackSliverRegion extends SingleChildRenderObjectWidget {
  const PlaybackSliverRegion({
    super.key,
    required this.regionId,
    required this.itemCount,
    required this.itemKey,
    this.columns = 1,
    this.findIndex,
    required Widget sliver,
  }) : super(child: sliver);

  final Object regionId;
  final int itemCount;
  final Object Function(int) itemKey;
  final int columns;
  final int? Function(Object key)? findIndex;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPlaybackRegion(
        Scrollable.maybeOf(context)?.position,
        regionId,
        itemCount,
        itemKey,
        columns,
        findIndex,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderProxySliver renderObject,
  ) {
    (renderObject as _RenderPlaybackRegion).update(
      Scrollable.maybeOf(context)?.position,
      regionId,
      itemCount,
      itemKey,
      columns,
      findIndex,
    );
  }
}

class _RenderPlaybackRegion extends RenderProxySliver {
  _RenderPlaybackRegion(
    ScrollPosition? position,
    this.regionId,
    this.itemCount,
    this.itemKey,
    this.columns,
    this.findIndex,
  ) {
    _position = position is _PlaybackScrollPosition ? position : null;
  }

  _PlaybackScrollPosition? _position;
  Object regionId;
  int itemCount;
  Object Function(int) itemKey;
  int columns;
  int? Function(Object)? findIndex;

  void update(
    ScrollPosition? position,
    Object id,
    int count,
    Object Function(int) keyAt,
    int cols,
    int? Function(Object)? indexOfKey,
  ) {
    final next = position is _PlaybackScrollPosition ? position : null;
    final geometryChanged =
        regionId != id || itemCount != count || columns != cols;
    if (next != null &&
        next._preserveVisibleChanges &&
        !next._holding &&
        !next.isScrollingNotifier.value &&
        !identical(itemKey, keyAt)) {
      // Late projection updates still belong to the return until the user
      // scrolls or explicitly navigates. Capture the old rendered identities.
      next._capture();
      next._release();
    }
    if (next != _position) {
      _position?._regions.remove(this);
      _position = next;
      if (attached) _position?._regions.add(this);
    }
    regionId = id;
    itemCount = count;
    itemKey = keyAt;
    columns = cols;
    findIndex = indexOfKey;
    if (geometryChanged || next?._snapshot != null) markNeedsLayout();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _position?._regions.add(this);
  }

  @override
  void detach() {
    _position?._regions.remove(this);
    super.detach();
  }

  int? indexOf(Object key, int hint) {
    if (hint < itemCount && itemKey(hint) == key) return hint;
    final lookup = findIndex;
    if (lookup != null) {
      final index = lookup(key);
      return index != null &&
              index >= 0 &&
              index < itemCount &&
              itemKey(index) == key
          ? index
          : null;
    }
    for (var i = 0; i < itemCount; i++) {
      if (itemKey(i) == key) return i;
    }
    return null;
  }

  double? offsetFor(int index) {
    final sliver = child;
    if (sliver == null || sliver.geometry == null) return null;
    final base = constraints.precedingScrollExtent;
    if (sliver is RenderSliverGrid) {
      return base +
          sliver.gridDelegate
              .getLayout(sliver.constraints)
              .getGeometryForChildIndex(index)
              .scrollOffset;
    }
    if (sliver is RenderSliverMultiBoxAdaptor) {
      var box = sliver.firstChild;
      while (box != null) {
        final data = box.parentData! as SliverMultiBoxAdaptorParentData;
        if (data.index == index ~/ columns && data.layoutOffset != null) {
          return base + data.layoutOffset!;
        }
        box = sliver.childAfter(box);
      }
    }
    final rows = (itemCount + columns - 1) ~/ columns;
    if (rows == 0) return null;
    return base + (sliver.geometry!.scrollExtent / rows) * (index ~/ columns);
  }

  Iterable<_VisibleAnchor> capture(double pixels, double viewport) sync* {
    if (itemCount == 0 || child == null || geometry == null) return;
    final base = constraints.precedingScrollExtent;
    if (base + geometry!.scrollExtent <= pixels || base >= pixels + viewport) {
      return;
    }
    final sliver = child!;
    if (sliver is RenderSliverGrid) {
      final layout = sliver.gridDelegate.getLayout(sliver.constraints);
      final first = layout.getMinChildIndexForScrollOffset(
        math.max(0, pixels - base),
      );
      for (var i = first; i < math.min(itemCount, first + 8); i++) {
        final offset = base + layout.getGeometryForChildIndex(i).scrollOffset;
        if (offset >= pixels + viewport) break;
        yield _VisibleAnchor(regionId, itemKey(i), i, offset - pixels);
      }
    } else if (sliver is RenderSliverMultiBoxAdaptor) {
      var box = sliver.firstChild;
      var saved = 0;
      while (box != null && saved < 8) {
        final data = box.parentData! as SliverMultiBoxAdaptorParentData;
        final offset = base + (data.layoutOffset ?? 0);
        if (data.index != null &&
            offset + box.size.height > pixels &&
            offset < pixels + viewport) {
          final i = data.index! * columns;
          if (i < itemCount) {
            yield _VisibleAnchor(regionId, itemKey(i), i, offset - pixels);
            saved++;
          }
        }
        box = sliver.childAfter(box);
      }
    }
  }
}

/// GridView's existing lazy layout and input behavior, plus stable identities.
class PlaybackGridView extends GridView {
  PlaybackGridView.builder({
    super.key,
    super.controller,
    super.padding,
    required super.gridDelegate,
    required super.itemBuilder,
    required int itemCount,
    required this.itemKey,
    this.regionId = 'grid',
    super.findChildIndexCallback,
  }) : _count = itemCount,
       super.builder(itemCount: itemCount);

  final Object Function(int) itemKey;
  final Object regionId;
  final int _count;

  @override
  Widget buildChildLayout(BuildContext context) => PlaybackSliverRegion(
    regionId: regionId,
    itemCount: _count,
    itemKey: itemKey,
    sliver: super.buildChildLayout(context),
  );
}

class PlaybackSliverGrid extends PlaybackSliverRegion {
  PlaybackSliverGrid({
    super.key,
    required super.regionId,
    required super.itemCount,
    required super.itemKey,
    required SliverGridDelegate gridDelegate,
    required SliverChildDelegate delegate,
  }) : super(
         sliver: SliverGrid(gridDelegate: gridDelegate, delegate: delegate),
       );
}

class PlaybackListView extends ListView {
  PlaybackListView.builder({
    super.key,
    super.controller,
    super.padding,
    required super.itemBuilder,
    required int itemCount,
    required this.itemKey,
    this.regionId = 'list',
    this.columns = 1,
    int? anchorItemCount,
  }) : _count = anchorItemCount ?? itemCount,
       super.builder(itemCount: itemCount);

  final Object Function(int) itemKey;
  final Object regionId;
  final int columns;
  final int _count;

  @override
  Widget buildChildLayout(BuildContext context) => PlaybackSliverRegion(
    regionId: regionId,
    itemCount: _count,
    itemKey: itemKey,
    columns: columns,
    sliver: super.buildChildLayout(context),
  );
}
