import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/app_haptics.dart';
import '../../services/settings_service.dart';

/// How long a primary button must stay down before an episode row selects.
///
/// This is the framework long-press deadline. A normal click, including a
/// slow one, finishes well before it.
const Duration podcastEpisodeLongPressDelay = kLongPressTimeout;

/// Movement that is still "the mouse did not really move".
///
/// Windows reports a logical pixel or two during a click that the hand never
/// made. Flutter's mouse drag slop is 1 logical pixel, so that noise used to
/// win the gesture arena and enter selection. A deliberate drag is larger.
const double podcastEpisodePressSlop = 10;

/// Click versus long-press for one episode row.
///
/// A primary click opens the episode. Holding still past
/// [podcastEpisodeLongPressDelay] selects it, and that release is not also a
/// click. Shift/Ctrl (and Command on macOS) still modify a click, but a key
/// that was already stuck down — most often the Windows key after the Start
/// menu swallows its key-up — does not.
class PodcastEpisodePress extends StatefulWidget {
  const PodcastEpisodePress({
    super.key,
    required this.child,
    required this.onOpen,
    required this.selecting,
    this.onSelect,
    this.onRangeSelect,
    this.onLongPress,
    this.borderRadius,
  });

  final Widget child;
  final VoidCallback onOpen;
  final VoidCallback? onSelect;

  /// Shift-click while the shift key was actually pressed for this gesture.
  final VoidCallback? onRangeSelect;
  final VoidCallback? onLongPress;
  final bool selecting;
  final BorderRadius? borderRadius;

  @override
  State<PodcastEpisodePress> createState() => _PodcastEpisodePressState();
}

class _PodcastEpisodePressState extends State<PodcastEpisodePress>
    with WidgetsBindingObserver {
  static final _modifierKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
  };

  final Set<LogicalKeyboardKey> _staleModifiers = <LogicalKeyboardKey>{};
  Offset? _origin;
  int? _pointer;
  Timer? _holdTimer;
  _EpisodeTapSuppressor? _suppressor;
  bool _selectingFromHold = false;
  bool _movedPastClick = false;

  /// Stays set through the arena sweep so releasing a hold or swipe cannot
  /// also open or toggle the row.
  bool _swallowRelease = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_onKey);
    // Keys already down were not pressed for this row. A stuck Windows key
    // otherwise turns every later click into Ctrl/Command-click.
    _freezeStuckModifiers();
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _suppressor?.dispose();
    HardwareKeyboard.instance.removeHandler(_onKey);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Focus leaving the window drops the key-up. Treat whatever is still
    // reported as down as stuck until the user presses that key again.
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.resumed) {
      _freezeStuckModifiers();
    }
  }

  bool _onKey(KeyEvent event) {
    if (!_modifierKeys.contains(event.logicalKey)) return false;
    if (event is KeyDownEvent || event is KeyUpEvent) {
      _staleModifiers.remove(event.logicalKey);
    }
    return false;
  }

  void _freezeStuckModifiers() {
    _staleModifiers
      ..clear()
      ..addAll(
        HardwareKeyboard.instance.logicalKeysPressed.where(
          _modifierKeys.contains,
        ),
      );
  }

  bool _live(LogicalKeyboardKey key) {
    return HardwareKeyboard.instance.isLogicalKeyPressed(key) &&
        !_staleModifiers.contains(key);
  }

  /// Shift and Ctrl everywhere. Command only on macOS — the Windows key is
  /// not a selection modifier, and it is the key that sticks.
  bool get _liveShift =>
      _live(LogicalKeyboardKey.shiftLeft) ||
      _live(LogicalKeyboardKey.shiftRight);

  bool get _liveSelectionModifier {
    final command =
        defaultTargetPlatform == TargetPlatform.macOS &&
        (_live(LogicalKeyboardKey.metaLeft) ||
            _live(LogicalKeyboardKey.metaRight));
    return _liveShift ||
        _live(LogicalKeyboardKey.controlLeft) ||
        _live(LogicalKeyboardKey.controlRight) ||
        command;
  }

  void _activate() {
    if (_swallowRelease || _selectingFromHold) return;
    if (_liveShift && widget.onRangeSelect != null) {
      widget.onRangeSelect!.call();
      return;
    }
    if (widget.selecting || _liveSelectionModifier) {
      widget.onSelect?.call();
    } else {
      unawaited(AppHaptics.cardTap(SettingsService()));
      widget.onOpen();
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    if (event.buttons != kPrimaryButton) return;
    if (_pointer != null) {
      _dropPress();
      return;
    }
    _pointer = event.pointer;
    _origin = event.position;
    _selectingFromHold = false;
    _movedPastClick = false;
    _swallowRelease = false;
    _suppressor?.dispose();
    _suppressor = _EpisodeTapSuppressor()..addPointer(event);
    _holdTimer?.cancel();
    if (widget.onLongPress == null) return;
    _holdTimer = Timer(podcastEpisodeLongPressDelay, () {
      if (!mounted || _pointer == null || _movedPastClick) return;
      _selectingFromHold = true;
      widget.onLongPress?.call();
    });
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    final origin = _origin;
    if (origin == null || _selectingFromHold) return;
    if ((event.position - origin).distance <= podcastEpisodePressSlop) return;
    // InkWell tolerates more movement than this row's click threshold. Keep
    // the release suppressed through the arena sweep, including short swipes
    // that never moved far enough for the surrounding scrollable to win.
    _movedPastClick = true;
    _swallowRelease = true;
    _holdTimer?.cancel();
    _holdTimer = null;
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    final origin = _origin;
    final distance = origin == null ? 0.0 : (event.position - origin).distance;
    final heldForSelection = _selectingFromHold;
    final movedPastClick = _movedPastClick;
    _finishPointer();
    if (heldForSelection) {
      // Release after a real hold must not open the episode or toggle the
      // selection the hold just made. The flag outlives this callback: the
      // tap recognizer runs later, during the arena sweep.
      _swallowRelease = true;
      _suppressor?.stealTap();
      _suppressor = null;
      return;
    }
    _suppressor?.rejectTap();
    _suppressor = null;
    // InkWell already accepts a release inside its own slop. Only a release
    // that moved far enough to lose that tap, but not a real drag, is filled
    // back in here.
    if (movedPastClick) return;
    if (distance > _inkTapSlop()) _activate();
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer != _pointer) return;
    _swallowRelease = true;
    _dropPress();
  }

  void _dropPress() {
    _finishPointer();
    _suppressor?.rejectTap();
    _suppressor = null;
  }

  void _finishPointer() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _pointer = null;
    _origin = null;
    _movedPastClick = false;
    _selectingFromHold = false;
  }

  /// Distance at which the row [InkWell] itself gives up on the click.
  ///
  /// That recognizer uses the touch slop, not the 1px mouse hit slop. Using
  /// the mouse slop here would fire [onOpen] again on top of the [InkWell].
  double _inkTapSlop() {
    final settings = MediaQuery.maybeGestureSettingsOf(context);
    return settings?.touchSlop ?? kTouchSlop;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.deferToChild,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: InkWell(
        borderRadius: widget.borderRadius,
        onTap: _activate,
        child: widget.child,
      ),
    );
  }
}

/// Wins the arena only after a hold already selected the row.
///
/// Added on pointer down so it can accept before the sweep. A short click
/// rejects it, leaving the row [InkWell] free to open the episode.
class _EpisodeTapSuppressor extends OneSequenceGestureRecognizer {
  void stealTap() => resolve(GestureDisposition.accepted);

  void rejectTap() => resolve(GestureDisposition.rejected);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    startTrackingPointer(event.pointer, event.transform);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'podcast episode tap suppressor';
}
