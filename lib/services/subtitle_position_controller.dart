import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../models/subtitle_position.dart';
import '../utils/subtitle_position_geometry.dart';

typedef SubtitleFrameScheduler = void Function(FrameCallback callback);

typedef SubtitlePositionCommit =
    Future<void> Function(
      SubtitlePositionTarget target,
      SubtitlePlacement placement,
    );

/// Pointers that already belong to a subtitle drag. Ancestors that listen
/// outside the gesture arena (video transform) must ignore them.
class SubtitleDragPointerOwner {
  static final Set<int> _pointers = <int>{};
  static bool editing = false;
  static Rect? globalHitRect;

  static bool owns(int pointer) => _pointers.contains(pointer);

  static void claim(int pointer) => _pointers.add(pointer);

  static void release(int pointer) => _pointers.remove(pointer);

  static bool claimsGlobal(Offset global) {
    final Rect? rect = globalHitRect;
    if (!editing || rect == null) return false;
    return rect.contains(global);
  }

  static void clear() {
    _pointers.clear();
    globalHitRect = null;
    editing = false;
  }
}

/// Draft position for one edit session.
///
/// Move events only update the latest sample. A frame callback publishes at
/// most once per frame. Commit reads the latest sample, not the last painted
/// one, and a stale callback cannot write after the session ends.
class SubtitlePositionController extends ChangeNotifier {
  SubtitlePositionController({this.frameScheduler});

  final SubtitleFrameScheduler? frameScheduler;
  final SubtitleGeometryHandle geometry = SubtitleGeometryHandle();

  SubtitlePositionCommit? onCommit;
  SubtitlePositionTarget? target;

  bool editing = false;
  bool dragging = false;
  Offset? draftOrigin;
  bool guideX = false;
  bool guideY = false;
  bool snappedX = false;
  bool snappedY = false;

  int _session = 0;
  int? _pointer;
  Offset _grab = Offset.zero;
  Offset _downOrigin = Offset.zero;
  Offset? _pendingDisplay;
  Alignment? _awaitingAlignment;
  SubtitleSnapMemory _memory = const SubtitleSnapMemory();
  bool _moved = false;
  bool _frameQueued = false;
  int _grabGeneration = -1;
  Offset _lastLocal = Offset.zero;
  bool _closed = false;

  bool get hasCustomDraft => draftOrigin != null;

  void beginEditing(SubtitlePositionTarget next) {
    if (_closed) return;
    if (target != next) {
      seal();
      // An in-flight save for another channel/preset must not position this
      // target while its own saved alignment is being mounted.
      draftOrigin = null;
      _awaitingAlignment = null;
      target = next;
      if (editing) {
        notifyListeners();
      }
    }
    if (editing) return;
    editing = true;
    SubtitleDragPointerOwner.editing = true;
    notifyListeners();
  }

  /// Ends the pointer, commits a real move, and leaves edit mode.
  void endEditing() {
    if (_closed) return;
    _finishPointer(commit: true);
    if (!editing && draftOrigin == null) return;
    editing = false;
    SubtitleDragPointerOwner.editing = false;
    SubtitleDragPointerOwner.globalHitRect = null;
    notifyListeners();
  }

  /// Commits without dropping edit mode. Used before switching targets.
  void seal() {
    if (_closed) return;
    _finishPointer(commit: true);
  }

  bool pointerDown({required int pointer, required Offset local}) {
    if (_closed || _pointer != null) return false;
    final SubtitleLaidOutGeometry? laid = geometry.current;
    if (laid == null || laid.viewport.width <= 0 || laid.viewport.height <= 0) {
      return false;
    }
    if (laid.contentSize.width <= 0 && laid.contentSize.height <= 0) {
      return false;
    }
    _pointer = pointer;
    _grab = local - laid.origin;
    _downOrigin = laid.origin;
    _lastLocal = local;
    _pendingDisplay = laid.origin;
    _memory = const SubtitleSnapMemory();
    _moved = false;
    dragging = true;
    _grabGeneration = geometry.generation;
    SubtitleDragPointerOwner.claim(pointer);
    notifyListeners();
    return true;
  }

  void pointerMove({required int pointer, required Offset local}) {
    if (_closed || _pointer != pointer) return;
    final SubtitleLaidOutGeometry? laid = geometry.current;
    if (laid == null) return;
    if (geometry.generation != _grabGeneration) {
      // The surface was resized under the pointer. Rebuild the grab from the
      // origin still on screen, then apply this sample's delta.
      final Offset displayed = draftOrigin ?? laid.origin;
      _grab = _lastLocal - displayed;
      _grabGeneration = geometry.generation;
    }
    final SubtitleDragSample sample = sampleSubtitleDrag(
      pointerLocal: local,
      grab: _grab,
      memory: _memory,
      viewport: laid.viewportRect,
      content: laid.contentSize,
    );
    _grab = sample.grab;
    _memory = sample.memory;
    _lastLocal = local;
    _pendingDisplay = sample.displayOrigin;
    if ((sample.displayOrigin - _downOrigin).distance > 0.5) {
      _moved = true;
    }
    guideX = sample.guideX;
    guideY = sample.guideY;
    snappedX = sample.snappedX;
    snappedY = sample.snappedY;
    _schedule();
  }

  SubtitlePlacement? pointerUp({required int pointer, Offset? local}) {
    if (_pointer != pointer) return null;
    if (local != null) {
      pointerMove(pointer: pointer, local: local);
    }
    return _finishPointer(commit: true);
  }

  void pointerCancel({required int pointer}) {
    if (_pointer != pointer) return;
    _finishPointer(commit: true);
  }

  SubtitlePlacement? _finishPointer({required bool commit}) {
    if (_pointer == null && _pendingDisplay == null) return null;
    final int pointer = _pointer ?? -1;
    _session++;
    _frameQueued = false;
    final Offset? latest = _pendingDisplay;
    final bool moved = _moved;
    if (latest != null) {
      draftOrigin = latest;
    }
    dragging = false;
    _pointer = null;
    _pendingDisplay = null;
    _memory = const SubtitleSnapMemory();
    guideX = false;
    guideY = false;
    snappedX = false;
    snappedY = false;
    if (pointer >= 0) SubtitleDragPointerOwner.release(pointer);
    SubtitlePlacement? placement;
    if (commit && moved && latest != null && target != null) {
      placement = CustomAlignmentPlacement.clamped(_alignmentFor(latest));
      // Keep the draft until the committed alignment is on the next layout,
      // but publish it now so the up-frame does not tween.
      final SubtitlePositionCommit? callback = onCommit;
      final SubtitlePositionTarget committedTarget = target!;
      if (callback != null) {
        _awaitingAlignment = placement.alignment;
        _moved = false;
        notifyListeners();
        callback(committedTarget, placement);
        return placement;
      }
      draftOrigin = null;
      _moved = false;
      notifyListeners();
      return placement;
    }
    // A quick second press can end before the preceding save has reached the
    // view. Keep that settled draft until the view acknowledges its alignment.
    if (_awaitingAlignment == null) {
      draftOrigin = null;
    }
    _moved = false;
    notifyListeners();
    return null;
  }

  /// Called by the layout that has received the committed position. No
  /// notification is sent during layout: that very layout now paints the
  /// saved alignment in place of the identical draft, without an old frame.
  bool acknowledgePlacement(Alignment alignment) {
    if (_closed || dragging || _awaitingAlignment != alignment) return false;
    _awaitingAlignment = null;
    draftOrigin = null;
    return true;
  }

  Alignment _alignmentFor(Offset origin) {
    final SubtitleLaidOutGeometry? laid = geometry.current;
    if (laid == null) return const Alignment(0, 0.9);
    final SubtitleMoveSpace space = SubtitleMoveSpace.fromViewport(
      laid.viewportRect,
      laid.contentSize,
    );
    return space.originToAlignment(origin, preserved: const Alignment(0, 1));
  }

  void _schedule() {
    if (_frameQueued) return;
    _frameQueued = true;
    final int session = _session;
    void callback(Duration _) {
      _frameQueued = false;
      if (session != _session || _closed) return;
      final Offset? next = _pendingDisplay;
      if (next == null) return;
      draftOrigin = next;
      notifyListeners();
    }

    final SubtitleFrameScheduler schedule =
        frameScheduler ?? SchedulerBinding.instance.scheduleFrameCallback;
    schedule(callback);
  }

  @override
  void dispose() {
    _closed = true;
    _session++;
    _pointer = null;
    editing = false;
    dragging = false;
    SubtitleDragPointerOwner.clear();
    super.dispose();
  }

  /// Test hook: run a queued frame callback's body without a binding.
  @visibleForTesting
  void debugPublishPending() {
    if (_pendingDisplay == null) return;
    _frameQueued = false;
    draftOrigin = _pendingDisplay;
    notifyListeners();
  }
}
