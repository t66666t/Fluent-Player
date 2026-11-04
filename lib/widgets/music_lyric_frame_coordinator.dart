import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// The lyric list owns the one upstream clock subscription. Cached rows only
/// join this dispatch while visible (plus one row of prefetch on either side).
class MusicLyricFrameCoordinator {
  MusicLyricFrameCoordinator(this.source);

  ValueListenable<Duration>? source;
  final _rows = <MusicLyricRowClock>{};
  final _subscribers = <MusicLyricRowClock>{};
  List<MusicLyricRowClock>? _subscriberSnapshot;
  int? _first;
  int? _last;
  bool _locating = false;
  bool _endLocatePending = false;

  Duration get position => source?.value ?? Duration.zero;
  int get mountedRows => _rows.length;
  int get activeRows => _rows.where((row) => row.activity.value).length;

  MusicLyricRowClock register(int index) {
    final row = MusicLyricRowClock._(this, index, _visible(index));
    _rows.add(row);
    return row;
  }

  bool _visible(int index) => _locating || isInVisibleWindow(index);

  bool isInVisibleWindow(int index) =>
      _first == null || (index >= _first! - 1 && index <= _last! + 1);

  void setLocating(bool value) {
    if (!value && _locating) {
      // The second viewport becomes primary before its public positions are
      // published. Keep both awake until that committed range arrives.
      _endLocatePending = true;
      return;
    }
    _endLocatePending = false;
    if (_locating == value) return;
    _locating = value;
    _updateActivity();
  }

  void setVisibleRange(int? first, int? last) {
    if (_first == first && _last == last && !_endLocatePending) return;
    if (_endLocatePending) {
      _locating = false;
      _endLocatePending = false;
    }
    _first = first;
    _last = last;
    _updateActivity();
  }

  void _updateActivity() {
    for (final row in _rows.toList(growable: false)) {
      final active = _visible(row.index);
      if (row.activity.value == active) continue;
      if (!active) _unsubscribe(row);
      row.activity.value = active;
      if (active && row.listening) {
        _subscribe(row);
        // Catch up from the current media time, including seeks while cached.
        row.publish();
      }
    }
  }

  void publishPosition() {
    // A listener may synchronously dispose or mount a row during a seek.
    final snapshot = _subscriberSnapshot ??= _subscribers.toList(
      growable: false,
    );
    for (final row in snapshot) {
      if (_subscribers.contains(row)) row.publish();
    }
  }

  void _subscribe(MusicLyricRowClock row) {
    if (_subscribers.add(row)) _subscriberSnapshot = null;
  }

  void _unsubscribe(MusicLyricRowClock row) {
    if (_subscribers.remove(row)) _subscriberSnapshot = null;
  }
}

class MusicLyricRowClock extends ChangeNotifier
    implements ValueListenable<Duration> {
  MusicLyricRowClock._(this.owner, this.index, bool active)
    : activity = ValueNotifier(active);

  final MusicLyricFrameCoordinator owner;
  final int index;
  final ValueNotifier<bool> activity;

  @override
  Duration get value => owner.position;

  bool get listening => hasListeners;

  void publish() => notifyListeners();

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    if (activity.value) owner._subscribe(this);
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) owner._unsubscribe(this);
  }

  @override
  void dispose() {
    owner._unsubscribe(this);
    owner._rows.remove(this);
    activity.dispose();
    super.dispose();
  }
}

class MusicLyricRowFrame extends StatefulWidget {
  const MusicLyricRowFrame({
    super.key,
    required this.coordinator,
    required this.index,
    required this.child,
  });

  final MusicLyricFrameCoordinator coordinator;
  final int index;
  final Widget child;

  @override
  State<MusicLyricRowFrame> createState() => _MusicLyricRowFrameState();
}

class _MusicLyricRowFrameState extends State<MusicLyricRowFrame> {
  late MusicLyricRowClock _clock;

  @override
  void initState() {
    super.initState();
    _clock = widget.coordinator.register(widget.index);
  }

  @override
  void didUpdateWidget(MusicLyricRowFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coordinator != widget.coordinator ||
        oldWidget.index != widget.index) {
      _clock.dispose();
      _clock = widget.coordinator.register(widget.index);
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: _clock.activity,
    child: MusicLyricRowFrameScope(clock: _clock, child: widget.child),
    builder: (context, active, child) =>
        TickerMode(enabled: active, child: child!),
  );
}

class MusicLyricRowFrameScope extends InheritedWidget {
  const MusicLyricRowFrameScope({
    super.key,
    required this.clock,
    required super.child,
  });

  final MusicLyricRowClock clock;

  static MusicLyricRowClock? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<MusicLyricRowFrameScope>()
      ?.clock;

  @override
  bool updateShouldNotify(MusicLyricRowFrameScope oldWidget) =>
      oldWidget.clock != clock;
}
