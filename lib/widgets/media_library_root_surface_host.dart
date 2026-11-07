import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../models/media_library_root_entry.dart';
import '../models/media_library_root_entry_order.dart';
import '../models/media_library_root_swipe_policy.dart';
import '../theme/app_tokens.dart';
import '../utils/ui_idle_gate.dart';
import 'playback_source_viewport.dart';

/// Builds one root surface. [isActive] is true only for the painted entry.
typedef MediaLibraryRootSurfaceBuilder =
    Widget Function(BuildContext context, bool isActive);

/// Incoming-library fade. Alpha changes on the composited layer only.
const Duration kMediaLibraryRootFadeDuration = Duration(milliseconds: 150);

/// Idle gap before the other two root pages are laid out off the tap path.
const Duration kMediaLibraryRootPrewarmDelay = Duration(milliseconds: 450);

const Duration kMediaLibraryRootSwipeSnapDuration = Duration(milliseconds: 280);

/// Test hook for the alpha of a surface paint that actually recorded pixels.
/// A fade that only retints its layer does not call this.
@visibleForTesting
void Function(int alpha)? debugMediaLibrarySurfacePaintAlpha;

/// Keeps visited 继续学习 / 最近添加 / 文件夹 trees without paging.
///
/// An explicit selection mounts the page in the same build. Windows presents
/// it opaque on that frame; other platforms keep the existing fade. Optional
/// idle prewarm lays other pages out under the current page.
/// The prewarm paint is fully transparent, so it is not a retained picture: a
/// near-zero first fade frame is often dropped by the GPU, and later alpha
/// bumps would retint that empty texture for the rest of the session. Fade-in
/// therefore repaints until the layer is opaque. After that, fade-out only
/// rewrites the layer alpha. Visited pages stay mounted so the next tap does
/// not recreate them. The other pages are prewarmed once the first frame has
/// settled; an early tap never waits for those hidden preparation frames.
///
/// Touch/stylus may slide between tabs. A drag that passes a full page keeps
/// going into the next one, and a flick back returns to the page the gesture
/// started on. Mouse and trackpad cannot: they would fight box-select, file
/// drops, and scrolling.
class MediaLibraryRootSurfaceHost extends StatefulWidget {
  const MediaLibraryRootSurfaceHost({
    super.key,
    required this.displayedEntry,
    required this.continueBuilder,
    required this.recentBuilder,
    required this.foldersBuilder,
    this.podcastsBuilder,
    this.onUserSwipe,
    this.swipeEnabled = true,
    this.swipeHighlightIndex,
    this.swipeSettled,
    this.entryOrder = MediaLibraryRootEntryOrder.defaults,
  });

  final MediaLibraryRootEntry displayedEntry;
  final MediaLibraryRootSurfaceBuilder continueBuilder;
  final MediaLibraryRootSurfaceBuilder recentBuilder;
  final MediaLibraryRootSurfaceBuilder foldersBuilder;
  final MediaLibraryRootSurfaceBuilder? podcastsBuilder;

  /// Fired after an interactive swipe commits, so the chip and prefs match.
  final ValueChanged<MediaLibraryRootEntry>? onUserSwipe;
  final bool swipeEnabled;

  /// Fractional chip index while the finger (or snap) is moving. The app
  /// bar listens without rebuilding the library grids.
  final ValueNotifier<double>? swipeHighlightIndex;

  /// True only when a full page is parked (no swipe/fade in flight).
  final ValueNotifier<bool>? swipeSettled;

  /// Chip/swipe order. Changing this must not rebuild parked grids.
  final List<MediaLibraryRootEntry> entryOrder;

  @override
  State<MediaLibraryRootSurfaceHost> createState() =>
      _MediaLibraryRootSurfaceHostState();
}

class _MediaLibraryRootSurfaceHostState
    extends State<MediaLibraryRootSurfaceHost>
    with TickerProviderStateMixin {
  late List<MediaLibraryRootEntry> _entryOrder =
      MediaLibraryRootEntryOrder.normalize(widget.entryOrder);

  MediaLibraryRootEntry get _selectedEntry => widget.displayedEntry.isAvailable
      ? widget.displayedEntry
      : MediaLibraryRootEntry.folders;

  final Set<MediaLibraryRootEntry> _visited = <MediaLibraryRootEntry>{};
  final Set<MediaLibraryRootEntry> _rasterReady = <MediaLibraryRootEntry>{};
  final Map<MediaLibraryRootEntry, ValueNotifier<double>> _opacity = {
    for (final entry in MediaLibraryRootEntryOrder.defaults)
      entry: ValueNotifier<double>(0),
  };
  late MediaLibraryRootEntry _paintedEntry;
  MediaLibraryRootEntry? _warmingEntry;
  MediaLibraryRootEntry? _fadingOutEntry;
  MediaLibraryRootEntry? _fadingInEntry;
  late final AnimationController _fade;
  late final AnimationController _snap;
  late final Animation<double> _snapCurve;
  int _prewarmGeneration = 0;
  int _snapGeneration = 0;
  Timer? _prewarmTimer;
  UiIdleGate? _prewarmIdle = UiIdleGate();
  bool _publicationScheduled = false;

  /// Finger offset. A [ValueNotifier] so layers can slide without setState
  /// on the parked grids.
  final ValueNotifier<double> _dragDx = ValueNotifier<double>(0);

  /// True only while a snap animation is playing. A live finger uses the
  /// cheaper unfiltered transform so a sudden reverse does not re-rasterize.
  final ValueNotifier<bool> _settling = ValueNotifier<bool>(false);
  MediaLibraryRootEntry? _dragTarget;
  bool _dragging = false;
  bool _incomingNeedsLiveLayout = false;
  bool _originNeedsLiveLayout = false;
  double _lastWidth = 0;
  VoidCallback? _snapTick;

  /// Page the in-flight snap is heading to. A tiny follow-up pointer must
  /// not throw that snap away.
  MediaLibraryRootEntry? _snapTarget;
  MediaLibraryRootEntry? _handoffPending;
  double _handoffTravel = 0;
  double _swipeTravelDx = 0;
  double _handoffDirection = 0;
  bool _swipeActive = false;

  @override
  void initState() {
    super.initState();
    _paintedEntry = _selectedEntry;
    _visited.add(_paintedEntry);
    _rasterReady.add(_paintedEntry);
    _opacity[_paintedEntry]!.value = 1;
    _fade = AnimationController(
      vsync: this,
      duration: kMediaLibraryRootFadeDuration,
      value: 1,
    );
    _fade.addListener(_onFadeTick);
    _fade.addStatusListener(_onFadeStatus);
    _prewarmTimer = Timer(kMediaLibraryRootPrewarmDelay, _prewarmNext);
    _snap = AnimationController(
      vsync: this,
      duration: kMediaLibraryRootSwipeSnapDuration,
    );
    _snapCurve = CurvedAnimation(parent: _snap, curve: Curves.easeOutCubic);
    _publishHighlight();
    _publishSettled();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disable = MediaQuery.disableAnimationsOf(context);
    // Keep release-to-select in the title's input arbiter. Once it confirms a
    // click, Windows must paint the destination on that frame, rather than
    // paint the old page once more and then reveal the new one over 150 ms.
    // Reuse the reduced-motion commit path; touch swipes still use _snap.
    final immediateSelection =
        disable || Theme.of(context).platform == TargetPlatform.windows;
    _fade.duration = immediateSelection
        ? Duration.zero
        : kMediaLibraryRootFadeDuration;
    _snap.duration = disable
        ? Duration.zero
        : kMediaLibraryRootSwipeSnapDuration;
  }

  @override
  void didUpdateWidget(covariant MediaLibraryRootSurfaceHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextOrder = MediaLibraryRootEntryOrder.normalize(widget.entryOrder);
    final orderChanged = !listEquals(_entryOrder, nextOrder);
    _entryOrder = nextOrder;
    if (oldWidget.swipeHighlightIndex != widget.swipeHighlightIndex ||
        orderChanged) {
      _publishHighlight();
    }
    if (oldWidget.swipeSettled != widget.swipeSettled) {
      _publishSettled();
    }
    final oldEntry = oldWidget.displayedEntry.isAvailable
        ? oldWidget.displayedEntry
        : MediaLibraryRootEntry.folders;
    if (oldEntry == _selectedEntry) return;
    if (_selectedEntry == _paintedEntry && _fadingInEntry == null) {
      _publishHighlight();
      return;
    }
    _cancelDrag(snap: false);
    _prewarmGeneration++;
    final next = _selectedEntry;
    // This build can lay out the incoming page before the fade paints it.
    // Waiting for the idle prewarm's three post-frame callbacks instead kept
    // the old page visible after mouse release, even for an empty destination.
    // _RenderInactiveLayoutGate repaints the reveal through its opaque frame,
    // so a cold page does not need a transparent raster pass before selection.
    _visited.add(next);
    _rasterReady.add(next);
    _commit(next);
  }

  void _onFadeTick() {
    final incoming = _fadingInEntry;
    if (incoming == null) return;
    final t = _fade.value;
    final inNotifier = _opacity[incoming]!;
    if (inNotifier.value != t) inNotifier.value = t;
    final outgoing = _fadingOutEntry;
    if (outgoing == null || outgoing == incoming) return;
    final out = 1 - t;
    final outNotifier = _opacity[outgoing]!;
    if (outNotifier.value != out) outNotifier.value = out;
  }

  void _onFadeStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    final incoming = _fadingInEntry;
    final outgoing = _fadingOutEntry;
    if (incoming != null && _opacity[incoming]!.value != 1) {
      _opacity[incoming]!.value = 1;
    }
    if (outgoing != null &&
        outgoing != incoming &&
        _opacity[outgoing]!.value != 0) {
      _opacity[outgoing]!.value = 0;
    }
    _fadingInEntry = null;
    _fadingOutEntry = null;
    _publishSettled();
    _schedulePrewarm();
  }

  /// Idle prewarm only: layout, then one covered paint, then [onReady].
  /// Explicit selections use the immediate build/fade path above.
  void _prepareLayer(
    MediaLibraryRootEntry entry, {
    required bool Function() live,
    required VoidCallback onReady,
  }) {
    if (_rasterReady.contains(entry)) {
      onReady();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!live()) {
        _abandonWarmup(entry);
        return;
      }
      setState(() {
        _visited.add(entry);
        _warmingEntry = entry;
      });
      _publishSettled();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!live()) {
          _abandonWarmup(entry);
          return;
        }
        setState(() {
          _rasterReady.add(entry);
          if (_warmingEntry == entry) _warmingEntry = null;
        });
        _publishSettled();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!live()) {
            _abandonWarmup(entry);
            return;
          }
          onReady();
        });
      });
    });
    // A timer can start prewarming while the UI is idle. A post-frame
    // callback alone does not request the frame needed to run it.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// A swipe can start on the same frame a hidden page was about to warm.
  /// Dropping that attempt without retrying left the page unvisited, so the
  /// next fling had nothing to slide in.
  void _abandonWarmup(MediaLibraryRootEntry entry) {
    if (!mounted) return;
    if (_warmingEntry == entry) {
      setState(() => _warmingEntry = null);
    }
    _schedulePrewarm();
  }

  void _schedulePrewarm() {
    _prewarmTimer?.cancel();
    if (_entryOrder.every(_rasterReady.contains)) {
      _prewarmIdle?.dispose();
      _prewarmIdle = null;
      return;
    }
    _prewarmTimer = Timer(kMediaLibraryRootPrewarmDelay, _prewarmNext);
  }

  Future<void> _prewarmNext() async {
    final waitingGeneration = _prewarmGeneration;
    final idle = _prewarmIdle ??= UiIdleGate();
    if (!await idle.waitUntilIdle() ||
        !mounted ||
        waitingGeneration != _prewarmGeneration) {
      return;
    }
    if (!mounted ||
        _dragging ||
        _warmingEntry != null ||
        _fadingInEntry != null) {
      if (mounted) _schedulePrewarm();
      return;
    }
    MediaLibraryRootEntry? pending;
    for (final entry in _entryOrder) {
      if (!_rasterReady.contains(entry)) {
        pending = entry;
        break;
      }
    }
    if (pending == null) {
      idle.dispose();
      if (identical(_prewarmIdle, idle)) _prewarmIdle = null;
      return;
    }
    final entry = pending;
    final generation = ++_prewarmGeneration;
    _prepareLayer(
      entry,
      live: () =>
          mounted &&
          generation == _prewarmGeneration &&
          !_dragging &&
          _fadingInEntry == null,
      onReady: () {
        if (!mounted || generation != _prewarmGeneration) return;
        // The finger may already be holding this page. Zeroing it here is
        // what made a just-opened folder look like it never loaded.
        if (entry != _paintedEntry &&
            entry != _fadingOutEntry &&
            entry != _dragTarget) {
          _opacity[entry]!.value = 0;
        }
        _schedulePrewarm();
      },
    );
  }

  void _commit(MediaLibraryRootEntry next) {
    if (next == _paintedEntry) {
      _warmingEntry = null;
      return;
    }
    final previous = _paintedEntry;
    _fadingOutEntry = previous;
    _paintedEntry = next;
    _warmingEntry = null;
    _fadingInEntry = next;
    if (_opacity[previous]!.value != 1) {
      _opacity[previous]!.value = 1;
    }
    for (final entry in MediaLibraryRootEntryOrder.defaults) {
      if (entry == next || entry == previous) continue;
      if (_opacity[entry]!.value != 0) _opacity[entry]!.value = 0;
    }
    _publishHighlight();
    _opacity[next]!.value = 0;
    _fade.forward(from: 0);
    _publishSettled();
  }

  double _hostWidth() {
    final box = context.findRenderObject() as RenderBox?;
    final fromBox = box?.size.width ?? 0;
    return fromBox > 0 ? fromBox : _lastWidth;
  }

  void _setDx(double value) {
    if (_dragDx.value != value) {
      _dragDx.value = value;
    }
    _publishHighlight();
    _publishSettled();
  }

  void _publishHighlight() {
    if (_deferPublicationDuringBuild()) return;
    final notifier = widget.swipeHighlightIndex;
    if (notifier == null) return;
    notifier.value = MediaLibraryRootSwipePolicy.highlightIndex(
      current: _paintedEntry,
      dragDx: _dragDx.value,
      width: _hostWidth(),
      order: _entryOrder,
    );
  }

  void _publishSettled() {
    if (_deferPublicationDuringBuild()) return;
    final notifier = widget.swipeSettled;
    if (notifier == null) return;
    notifier.value =
        !_dragging && _dragDx.value.abs() < 0.5 && _warmingEntry == null;
  }

  bool _deferPublicationDuringBuild() {
    if (SchedulerBinding.instance.schedulerPhase !=
        SchedulerPhase.persistentCallbacks) {
      return false;
    }
    // The title is a sibling of the body and may have finished building
    // before this host mounts in a LayoutBuilder. Notifying it here leaves
    // it dirty in the wrong build scope, including in release builds.
    if (!_publicationScheduled) {
      _publicationScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _publicationScheduled = false;
        if (!mounted) return;
        _publishHighlight();
        _publishSettled();
      });
    }
    return true;
  }

  void _onSwipeStart(DragStartDetails details) {
    final handoff = _dragging;
    final pending = handoff ? _snapTarget : null;
    _handoffDirection = pending == null
        ? 0
        : (_entryOrder.indexOf(_paintedEntry) - _entryOrder.indexOf(pending))
              .sign
              .toDouble();
    _abortSnap();
    _snapTarget = null;
    _handoffPending = pending;
    _handoffTravel = 0;
    _swipeTravelDx = 0;
    _swipeActive = true;
    _fadingInEntry = null;
    if (_opacity[_paintedEntry]!.value != 1) {
      _opacity[_paintedEntry]!.value = 1;
    }
    // A swipe that starts during the snap keeps the offset and follows the
    // finger. Travel past a full page is carried in the update, so the new
    // move can reach the page after the one already on screen.
    if (handoff) {
      // Measure from the page already under the finger, keeping its exact
      // screen position. A late reverse can then go back to the previous page.
      if (pending != null && _dragDx.value.abs() >= _hostWidth() / 2) {
        _rebaseDragOrigin(pending);
      }
      _publishSettled();
      return;
    }
    setState(() {
      _dragging = true;
      _dragTarget = null;
      _incomingNeedsLiveLayout = false;
      _originNeedsLiveLayout = false;
      _fadingOutEntry = null;
      _fade.value = 1;
    });
    _setDx(0);
    _publishSettled();
  }

  void _onSwipeUpdate(DragUpdateDetails details) {
    if (!_dragging) return;
    _handoffTravel += details.delta.dx.abs();
    _swipeTravelDx += details.delta.dx;
    final width = _hostWidth();
    final carried = _carryPastFullPages(
      _dragDx.value + details.delta.dx,
      width,
    );
    final neighbor = MediaLibraryRootSwipePolicy.neighbor(
      current: _paintedEntry,
      dx: carried,
      order: _entryOrder,
    );
    final clamped = MediaLibraryRootSwipePolicy.clampDrag(
      dx: carried,
      width: width,
      hasNeighbor: neighbor != null,
    );
    _showDragNeighbor(neighbor);
    _setDx(clamped);
  }

  void _rebaseDragOrigin(MediaLibraryRootEntry next) {
    if (next == _paintedEntry) return;
    final delta =
        _entryOrder.indexOf(next) - _entryOrder.indexOf(_paintedEntry);
    final dx = _dragDx.value + delta * _hostWidth();
    _promoteDragOrigin(next);
    _showDragNeighbor(
      MediaLibraryRootSwipePolicy.neighbor(
        current: _paintedEntry,
        dx: dx,
        order: _entryOrder,
      ),
    );
    _setDx(dx);
  }

  /// Adopts each page the finger has fully crossed so the leftover distance
  /// can open the page after it. Stops at the first or last chip.
  double _carryPastFullPages(double dx, double width) {
    var remaining = dx;
    for (var n = 0; n < _entryOrder.length; n++) {
      final shift = MediaLibraryRootSwipePolicy.shiftOrigin(
        dragDx: remaining,
        width: width,
      );
      if (shift == null) return remaining;
      final index = _entryOrder.indexOf(_paintedEntry);
      final nextIndex = index + shift.indexDelta;
      if (index < 0 || nextIndex < 0 || nextIndex >= _entryOrder.length) {
        return remaining;
      }
      _promoteDragOrigin(_entryOrder[nextIndex]);
      remaining = shift.residualDx;
    }
    return remaining;
  }

  void _promoteDragOrigin(MediaLibraryRootEntry next) {
    if (next == _paintedEntry) return;
    final previous = _paintedEntry;
    final cold = !_rasterReady.contains(next);
    _paintedEntry = next;
    _opacity[next]!.value = 1;
    _opacity[previous]!.value = 0;
    _visited.add(next);
    if (_dragTarget == next) _dragTarget = null;
    if (!cold) {
      _rasterReady.add(next);
      _originNeedsLiveLayout = false;
      return;
    }
    _originNeedsLiveLayout = true;
    widget.onUserSwipe?.call(next);
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_dragging || !_originNeedsLiveLayout) return;
      if (_paintedEntry != next) return;
      setState(() {
        _originNeedsLiveLayout = false;
        _rasterReady.add(next);
      });
    });
  }

  /// Keeps the page beside the finger in sync. A reversal slides back
  /// toward the page the gesture started on.
  void _showDragNeighbor(MediaLibraryRootEntry? neighbor) {
    if (neighbor == _dragTarget) return;
    final firstVisit = neighbor != null && !_rasterReady.contains(neighbor);
    final previousTarget = _dragTarget;
    if (previousTarget != null &&
        previousTarget != _paintedEntry &&
        previousTarget != neighbor) {
      _opacity[previousTarget]!.value = 0;
    }
    if (neighbor != null) _opacity[neighbor]!.value = 1;
    _dragTarget = neighbor;
    if (neighbor != null) {
      _visited.add(neighbor);
      if (!firstVisit) _rasterReady.add(neighbor);
    }
    _incomingNeedsLiveLayout = firstVisit;
    // A page that is already painted only changes offset and alpha.
    // setState here relayouts the grids and is the stall on a reverse.
    if (firstVisit) {
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_dragging) return;
        if (!_incomingNeedsLiveLayout) return;
        final shown = _dragTarget;
        setState(() {
          _incomingNeedsLiveLayout = false;
          if (shown != null) _rasterReady.add(shown);
        });
      });
    }
  }

  void _onSwipeEnd(DragEndDetails details) {
    if (!_swipeActive) return;
    _swipeActive = false;
    final pending = _handoffPending;
    _handoffPending = null;
    if (pending != null && _handoffTravel < 18) {
      _settleSwipe(pending);
      return;
    }
    final width = _hostWidth();
    final velocity = details.velocity.pixelsPerSecond.dx;
    var target = MediaLibraryRootSwipePolicy.settleTarget(
      current: _paintedEntry,
      dragDx: _dragDx.value,
      width: width,
      velocityDx: velocity,
      order: _entryOrder,
    );
    if (pending != null &&
        _swipeTravelDx * _handoffDirection > 0 &&
        velocity * _handoffDirection >=
            -MediaLibraryRootSwipePolicy.commitVelocity &&
        MediaLibraryRootSwipePolicy.shouldCommit(
          dragDx: _swipeTravelDx,
          width: width,
          velocityDx: velocity,
        )) {
      // New travel is independent of the unfinished snap distance. Once the
      // finger passes that destination, the usual residual-distance rule wins.
      final remaining =
          (_entryOrder.indexOf(pending) - _entryOrder.indexOf(_paintedEntry)) *
          -_handoffDirection;
      if (remaining >= 0) {
        if (remaining > 0) _rebaseDragOrigin(pending);
        target = MediaLibraryRootSwipePolicy.neighbor(
          current: _paintedEntry,
          dx: _swipeTravelDx,
          order: _entryOrder,
        );
      }
    }
    _settleSwipe(target);
  }

  void _settleSwipe(MediaLibraryRootEntry? target) {
    if (target != null && target != _paintedEntry) {
      final from = _entryOrder.indexOf(_paintedEntry);
      final to = _entryOrder.indexOf(target);
      final width = _hostWidth();
      final end = to > from ? -width : width;
      _snapTarget = target;
      _animateDragTo(end, () => _finishSwipe(target));
      return;
    }
    _snapTarget = null;
    _animateDragTo(0, () {
      if (!mounted) return;
      setState(() {
        _dragging = false;
        _dragTarget = null;
        _incomingNeedsLiveLayout = false;
        _originNeedsLiveLayout = false;
        _rasterReady.add(_paintedEntry);
        if (_warmingEntry != _paintedEntry) {
          _warmingEntry = null;
        }
      });
      _hideParkedPages();
      _setDx(0);
      _notifyIfOriginChanged();
    });
  }

  /// A drag that crossed onto another page and then settled there still has
  /// to tell the chip row. The snap-to-neighbor path notifies from
  /// [_finishSwipe].
  void _notifyIfOriginChanged() {
    if (!mounted || _paintedEntry == _selectedEntry) return;
    widget.onUserSwipe?.call(_paintedEntry);
  }

  void _hideParkedPages() {
    for (final entry in MediaLibraryRootEntryOrder.defaults) {
      if (entry == _paintedEntry || entry == _fadingOutEntry) continue;
      if (_opacity[entry]!.value != 0) _opacity[entry]!.value = 0;
    }
  }

  void _cancelDrag({required bool snap}) {
    _swipeActive = false;
    _handoffPending = null;
    _snapTarget = null;
    if (!_dragging && _dragDx.value == 0) return;
    if (!snap) {
      _abortSnap();
      _dragging = false;
      _dragTarget = null;
      _incomingNeedsLiveLayout = false;
      _originNeedsLiveLayout = false;
      _hideParkedPages();
      _setDx(0);
      return;
    }
    _animateDragTo(0, () {
      if (!mounted) return;
      setState(() {
        _dragging = false;
        _dragTarget = null;
        _incomingNeedsLiveLayout = false;
        _originNeedsLiveLayout = false;
      });
      _setDx(0);
      _notifyIfOriginChanged();
    });
  }

  void _onSwipeCancel() {
    // Drag recognizers also cancel taps and vertical gestures that never
    // started a horizontal swipe. Those must leave the running snap alone.
    if (!_swipeActive) return;
    _swipeActive = false;
    if (_handoffPending != null && _handoffTravel < 18) {
      final pending = _handoffPending!;
      _handoffPending = null;
      _settleSwipe(pending);
      return;
    }
    _handoffPending = null;
    _snapTarget = null;
    _cancelDrag(snap: true);
  }

  void _clearSnapTick() {
    if (_snapTick == null) return;
    _snap.removeListener(_snapTick!);
    _snapTick = null;
  }

  void _abortSnap() {
    _snapGeneration++;
    _clearSnapTick();
    _settling.value = false;
    if (_snap.isAnimating) _snap.stop();
  }

  void _animateDragTo(double end, VoidCallback onDone) {
    _clearSnapTick();
    final generation = ++_snapGeneration;
    final start = _dragDx.value;
    final width = _hostWidth() <= 1 ? 1.0 : _hostWidth();
    final fraction = ((end - start).abs() / width).clamp(0.18, 1.0);
    final reduceMotion = mounted && MediaQuery.disableAnimationsOf(context);
    _snap.duration = reduceMotion
        ? Duration.zero
        : Duration(milliseconds: (160 + 180 * fraction).round());
    _settling.value = !reduceMotion;
    late final VoidCallback tick;
    tick = () {
      if (!mounted || generation != _snapGeneration) return;
      final dx = start + (end - start) * _snapCurve.value;
      _showDragNeighbor(
        MediaLibraryRootSwipePolicy.neighbor(
          current: _paintedEntry,
          dx: dx,
          order: _entryOrder,
        ),
      );
      _setDx(dx);
    };
    _snapTick = tick;
    _snap.addListener(tick);
    _snap.forward(from: 0).whenComplete(() {
      if (generation != _snapGeneration) return;
      _settling.value = false;
      _clearSnapTick();
      onDone();
    });
  }

  void _finishSwipe(MediaLibraryRootEntry next) {
    _snapTarget = null;
    _handoffPending = null;
    _swipeActive = false;
    _paintedEntry = next;
    _warmingEntry = null;
    _fadingOutEntry = null;
    _fadingInEntry = null;
    _dragging = false;
    _dragTarget = null;
    _incomingNeedsLiveLayout = false;
    _originNeedsLiveLayout = false;
    _visited.add(next);
    _rasterReady.add(next);
    _fade.value = 1;
    for (final entry in MediaLibraryRootEntryOrder.defaults) {
      _opacity[entry]!.value = entry == next ? 1 : 0;
    }
    _prewarmGeneration++;
    _setDx(0);
    widget.onUserSwipe?.call(next);
    if (mounted) setState(() {});
    _schedulePrewarm();
  }

  @override
  void dispose() {
    _prewarmIdle?.dispose();
    _prewarmTimer?.cancel();
    _clearSnapTick();
    _fade.removeListener(_onFadeTick);
    _fade.removeStatusListener(_onFadeStatus);
    _fade.dispose();
    _snap.dispose();
    _dragDx.dispose();
    _settling.dispose();
    for (final notifier in _opacity.values) {
      notifier.dispose();
    }
    super.dispose();
  }

  List<MediaLibraryRootEntry> get _paintOrder {
    final below = <MediaLibraryRootEntry>[];
    for (final entry in MediaLibraryRootEntryOrder.defaults) {
      if (!_visited.contains(entry) || entry == _paintedEntry) continue;
      below.add(entry);
    }
    if (_visited.contains(_paintedEntry)) below.add(_paintedEntry);
    return below;
  }

  MediaLibraryRootSurfaceBuilder _builderFor(MediaLibraryRootEntry entry) {
    return switch (entry) {
      MediaLibraryRootEntry.continueLearning => widget.continueBuilder,
      MediaLibraryRootEntry.recent => widget.recentBuilder,
      MediaLibraryRootEntry.folders => widget.foldersBuilder,
      MediaLibraryRootEntry.podcasts =>
        widget.podcastsBuilder ?? ((_, _) => const SizedBox.shrink()),
      MediaLibraryRootEntry.bilibili ||
      MediaLibraryRootEntry.cloudDrive => widget.foldersBuilder,
    };
  }

  double _offsetFor(MediaLibraryRootEntry entry, double dx, double width) {
    if (dx == 0 && !_dragging) return 0;
    if (entry == _paintedEntry) return dx;
    if (entry == _dragTarget) {
      return dx < 0 ? dx + width : dx - width;
    }
    return 0;
  }

  bool _entryActive(MediaLibraryRootEntry entry) {
    if (_dragging) {
      if (_originNeedsLiveLayout && entry == _paintedEntry) return true;
      return _incomingNeedsLiveLayout && entry == _dragTarget;
    }
    return entry == _paintedEntry || entry == _warmingEntry;
  }

  Map<Type, GestureRecognizerFactory> _swipeGestures() {
    if (!widget.swipeEnabled) return const {};
    return {
      MediaLibraryRootSwipeRecognizer:
          GestureRecognizerFactoryWithHandlers<MediaLibraryRootSwipeRecognizer>(
            () => MediaLibraryRootSwipeRecognizer(widthOf: _hostWidth),
            (recognizer) {
              recognizer
                ..onStart = _onSwipeStart
                ..onUpdate = _onSwipeUpdate
                ..onEnd = _onSwipeEnd
                ..onCancel = _onSwipeCancel;
            },
          ),
    };
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _lastWidth = constraints.maxWidth;
        return RawGestureDetector(
          behavior: HitTestBehavior.translucent,
          gestures: _swipeGestures(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              for (final entry in _paintOrder)
                _FollowFingerSlide(
                  key: ValueKey<MediaLibraryRootEntry>(entry),
                  dx: _dragDx,
                  settling: _settling,
                  offsetFor: (dx) => _offsetFor(entry, dx, _lastWidth),
                  child: _ParkedRootSurface(
                    allowLayout:
                        _visited.contains(entry) ||
                        entry == _warmingEntry ||
                        entry == _dragTarget,
                    allowPaint:
                        _rasterReady.contains(entry) ||
                        entry == _paintedEntry ||
                        entry == _dragTarget,
                    allowHit: !_dragging && entry == _paintedEntry,
                    opacity: _opacity[entry]!,
                    active: _entryActive(entry),
                    builder: _builderFor(entry),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Translates one parked surface from a [ValueNotifier] so pointer moves
/// do not rebuild the grid underneath.
class _FollowFingerSlide extends StatelessWidget {
  const _FollowFingerSlide({
    super.key,
    required this.dx,
    required this.settling,
    required this.offsetFor,
    required this.child,
  });

  final ValueListenable<double> dx;
  final ValueListenable<bool> settling;
  final double Function(double dx) offsetFor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[dx, settling]),
      child: child,
      builder: (context, child) {
        final offset = offsetFor(dx.value);
        return Transform.translate(
          offset: Offset(offset, 0),
          // A live finger stays unfiltered. Filtering the whole library on
          // every move re-rasters when the finger reverses.
          filterQuality: settling.value && offset != 0
              ? FilterQuality.low
              : FilterQuality.none,
          child: child,
        );
      },
    );
  }
}

/// Touch/stylus horizontal drag that ignores mouse, trackpad, and back-edge
/// starts so it cannot steal box-select or system back.
class MediaLibraryRootSwipeRecognizer extends HorizontalDragGestureRecognizer {
  MediaLibraryRootSwipeRecognizer({required this.widthOf})
    : super(
        supportedDevices: const {
          PointerDeviceKind.touch,
          PointerDeviceKind.stylus,
        },
      ) {
    dragStartBehavior = DragStartBehavior.down;
    onlyAcceptDragOnThreshold = true;
  }

  final double Function() widthOf;

  Offset? _down;
  bool _acceptedEarly = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (!MediaLibraryRootSwipePolicy.isEligiblePointer(event.kind)) return;
    if (!MediaLibraryRootSwipePolicy.isAwayFromSystemEdges(
      localX: event.localPosition.dx,
      width: widthOf(),
    )) {
      return;
    }
    _down = event.position;
    _acceptedEarly = false;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    final origin = _down;
    if (!_acceptedEarly && origin != null && event is PointerMoveEvent) {
      final delta = event.position - origin;
      // Claim a clearly horizontal move before a vertical list takes a
      // fast swipe that is only slightly diagonal.
      if (delta.dx.abs() >= 8 && delta.dx.abs() > delta.dy.abs() + 1) {
        _acceptedEarly = true;
      }
    }
    super.handleEvent(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) {
    return _acceptedEarly ||
        super.hasSufficientGlobalDistanceToAccept(
          pointerDeviceKind,
          deviceTouchSlop,
        );
  }
}

/// Calls [builder] for the first frame, while visible, and once when hiding.
/// Hidden frames reuse the last widget so a parent rebuild cannot walk the grid.
class _ParkedRootSurface extends StatefulWidget {
  const _ParkedRootSurface({
    required this.allowLayout,
    required this.allowPaint,
    required this.allowHit,
    required this.opacity,
    required this.active,
    required this.builder,
  });

  final bool allowLayout;
  final bool allowPaint;
  final bool allowHit;
  final ValueListenable<double> opacity;
  final bool active;
  final MediaLibraryRootSurfaceBuilder builder;

  @override
  State<_ParkedRootSurface> createState() => _ParkedRootSurfaceState();
}

class _ParkedRootSurfaceState extends State<_ParkedRootSurface> {
  Widget? _child;
  bool _wasActive = true;

  @override
  Widget build(BuildContext context) {
    final activeChanged = _child == null || _wasActive != widget.active;
    if (widget.active || activeChanged) {
      _child = widget.builder(context, widget.active);
    }
    _wasActive = widget.active;
    return _InactiveLayoutGate(
      allowLayout: widget.allowLayout,
      allowPaint: widget.allowPaint,
      allowHit: widget.allowHit,
      opacity: widget.opacity,
      child: ExcludeFocus(
        excluding: !widget.active,
        // Hidden pages stay muted, including the one-frame warmup. The cover
        // cascade only advances once this surface is actually on screen.
        child: ListenableBuilder(
          listenable: widget.opacity,
          builder: (context, child) {
            final shown = widget.opacity.value > 0.001;
            return TickerMode(enabled: shown, child: child!);
          },
          child: PlaybackViewportActivity(
            active: widget.active,
            child: RepaintBoundary(
              child: ColoredBox(color: AppTokens.bgBase, child: _child!),
            ),
          ),
        ),
      ),
    );
  }
}

/// Occupies the stack slot. Layout and paint are independently gated so an
/// incoming library can warm without replacing the outgoing pixels yet.
class _InactiveLayoutGate extends SingleChildRenderObjectWidget {
  const _InactiveLayoutGate({
    required this.allowLayout,
    required this.allowPaint,
    required this.allowHit,
    required this.opacity,
    required super.child,
  });

  final bool allowLayout;
  final bool allowPaint;
  final bool allowHit;
  final ValueListenable<double> opacity;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderInactiveLayoutGate(
      allowLayout: allowLayout,
      allowPaint: allowPaint,
      allowHit: allowHit,
      opacity: opacity,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderInactiveLayoutGate renderObject,
  ) {
    renderObject
      ..allowLayout = allowLayout
      ..allowPaint = allowPaint
      ..allowHit = allowHit
      ..opacity = opacity;
  }
}

class _RenderInactiveLayoutGate extends RenderProxyBox {
  _RenderInactiveLayoutGate({
    required bool allowLayout,
    required bool allowPaint,
    required bool allowHit,
    required ValueListenable<double> opacity,
  }) : _allowLayout = allowLayout,
       _allowPaint = allowPaint,
       _allowHit = allowHit,
       _opacity = opacity;

  bool _allowLayout;
  bool _allowPaint;
  bool _allowHit;
  ValueListenable<double> _opacity;
  bool _pictureReady = false;

  set allowLayout(bool value) {
    if (_allowLayout == value) return;
    _allowLayout = value;
    markNeedsLayout();
  }

  set allowPaint(bool value) {
    if (_allowPaint == value) return;
    _allowPaint = value;
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  set allowHit(bool value) {
    if (_allowHit == value) return;
    _allowHit = value;
  }

  set opacity(ValueListenable<double> value) {
    if (identical(_opacity, value)) return;
    if (attached) _opacity.removeListener(_onOpacity);
    _opacity = value;
    if (attached) _opacity.addListener(_onOpacity);
    _syncAlpha(forcePaint: !_pictureReady);
  }

  int _lastAlpha = -1;

  void _onOpacity() => _syncAlpha(forcePaint: false);

  void _syncAlpha({required bool forcePaint}) {
    final alpha = _compositedAlpha;
    if (alpha <= 0) {
      // A fully transparent layer is often never stored. The next reveal
      // has to paint again; retinting this one leaves the page blank.
      _pictureReady = false;
    }
    if (alpha == _lastAlpha && !forcePaint) return;
    final risingFromHidden = _lastAlpha <= 0 && alpha > 0;
    _lastAlpha = alpha;
    markNeedsSemanticsUpdate();
    if (alpha <= 0) {
      markNeedsCompositedLayerUpdate();
      return;
    }
    // Partial fade-in frames are not a retained picture. Keep painting until
    // an opaque frame lands. Fade-out of that opaque picture only retints.
    if (forcePaint || !_pictureReady || risingFromHidden) {
      // The hidden pass may have run before the surface had a real size.
      // A layer-only alpha change would keep that empty layout.
      if (risingFromHidden) markNeedsLayout();
      markNeedsPaint();
      return;
    }
    markNeedsCompositedLayerUpdate();
  }

  int get _compositedAlpha {
    final raw = _opacity.value;
    if (raw <= 0) return 0;
    if (raw >= 1) return 255;
    return (255 * raw).round();
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  OffsetLayer updateCompositedLayer({
    required covariant OpacityLayer? oldLayer,
  }) {
    final layer = oldLayer ?? OpacityLayer();
    layer.alpha = _compositedAlpha;
    return layer;
  }

  @override
  void detach() {
    _opacity.removeListener(_onOpacity);
    super.detach();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _opacity.addListener(_onOpacity);
    _lastAlpha = _compositedAlpha;
  }

  @override
  void performLayout() {
    size = constraints.biggest;
    final child = this.child;
    // debugNeedsLayout is assert-only and throws in release, which aborted
    // the whole library frame on a hidden page. Skip the child outright
    // while layout is gated; turning the gate back on marks us dirty.
    if (child == null || !_allowLayout) return;
    child.layout(constraints, parentUsesSize: false);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    // Alpha 0 must not record a picture. Doing so, then bumping the layer
    // alpha, is what left a just-opened folder blank until restart.
    if (!_allowPaint || child == null || _compositedAlpha <= 0) return;
    super.paint(context, offset);
    debugMediaLibrarySurfacePaintAlpha?.call(_compositedAlpha);
    if (_compositedAlpha >= 255) _pictureReady = true;
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (!_allowHit || !_allowPaint || _compositedAlpha <= 0) return false;
    return super.hitTestChildren(result, position: position);
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (_allowPaint && _compositedAlpha > 0) {
      super.visitChildrenForSemantics(visitor);
    }
  }
}

/// Reuses the last child instance while inactive so a parent rebuild cannot
/// walk a full thumbnail grid that is not on screen.
class MediaLibraryFrozenWhenInactive extends StatefulWidget {
  const MediaLibraryFrozenWhenInactive({
    super.key,
    required this.active,
    required this.child,
    this.changes,
  });

  final bool active;
  final Widget child;

  /// Notifies when the hidden tree is stale and must be rebuilt on the next
  /// activation. A notification that arrives on the last active prewarm frame
  /// still counts: that frame's rebuild is the one that turns the page off.
  /// A clean reactivation keeps the last element tree.
  final Listenable? changes;

  @override
  State<MediaLibraryFrozenWhenInactive> createState() =>
      _MediaLibraryFrozenWhenInactiveState();
}

class _MediaLibraryFrozenWhenInactiveState
    extends State<MediaLibraryFrozenWhenInactive> {
  Widget? _frozen;
  bool _dirtyWhileHidden = false;
  bool _reuseFrozen = false;

  @override
  void initState() {
    super.initState();
    widget.changes?.addListener(_markDirty);
  }

  @override
  void didUpdateWidget(covariant MediaLibraryFrozenWhenInactive oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.changes != widget.changes) {
      oldWidget.changes?.removeListener(_markDirty);
      widget.changes?.addListener(_markDirty);
    }
    if (widget.changes != null &&
        widget.active &&
        !oldWidget.active &&
        !_dirtyWhileHidden &&
        _frozen != null) {
      _reuseFrozen = true;
    }
  }

  @override
  void dispose() {
    widget.changes?.removeListener(_markDirty);
    super.dispose();
  }

  void _markDirty() {
    // Include the last active prewarm frame. The library notification is
    // delivered before the next frame turns the page off, and skipping it
    // froze the empty grid for the rest of the session.
    _dirtyWhileHidden = true;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) {
      _reuseFrozen = false;
      if (_dirtyWhileHidden || _frozen == null) {
        _dirtyWhileHidden = false;
        _frozen = widget.child;
      }
      return _frozen!;
    }
    if (_reuseFrozen && _frozen != null) {
      _reuseFrozen = false;
      _dirtyWhileHidden = false;
      return _frozen!;
    }
    _dirtyWhileHidden = false;
    _frozen = widget.child;
    return widget.child;
  }
}
