import 'dart:async';

import 'package:flutter/widgets.dart';

/// Retained for callers that want to calculate the original row spacing.
Duration mediaCoverRevealDelay({
  required int index,
  required int crossAxisCount,
}) {
  if (index < 0) return Duration.zero;
  final columns = crossAxisCount < 1 ? 1 : crossAxisCount;
  final row = index ~/ columns;
  if (row >= 5) return Duration.zero;
  return Duration(milliseconds: row * 72 + (index % columns) * 36);
}

/// Identifies a cell in a lazily built media grid.
class MediaCoverRevealStamp extends InheritedWidget {
  const MediaCoverRevealStamp({
    super.key,
    required this.index,
    required this.crossAxisCount,
    required super.child,
  });

  final int index;
  final int crossAxisCount;

  static MediaCoverRevealStamp? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MediaCoverRevealStamp>();

  @override
  bool updateShouldNotify(MediaCoverRevealStamp oldWidget) =>
      index != oldWidget.index || crossAxisCount != oldWidget.crossAxisCount;
}

final Expando<MediaCoverRevealCoordinator> _scrollReveals = Expando();

MediaCoverRevealCoordinator? mediaCoverRevealCoordinatorOf(
  BuildContext context,
) {
  final scrollable = Scrollable.maybeOf(context);
  if (scrollable == null) return null;
  return _scrollReveals[scrollable] ??= MediaCoverRevealCoordinator();
}

class MediaCoverRevealTicket {
  MediaCoverRevealTicket._(this._coordinator, this.index, this._reveal);

  final MediaCoverRevealCoordinator _coordinator;
  final int index;
  final VoidCallback _reveal;
  bool _ready = false;
  bool _removed = false;

  void ready() {
    if (_removed || _ready) return;
    _ready = true;
    _coordinator._schedule();
  }

  void dispose() {
    if (_removed) return;
    _removed = true;
    _coordinator._tickets.remove(this);
    _coordinator._schedule();
  }
}

/// Coordinates only mounted cells. A slow or missing cover is given a short
/// head start, then skipped so it cannot hold the rest of the screen hostage.
class MediaCoverRevealCoordinator {
  final Set<MediaCoverRevealTicket> _tickets = {};
  Timer? _timer;
  bool _waitingForSlow = false;
  bool _scheduled = false;
  bool _skipSlow = false;
  int _burst = 0;

  MediaCoverRevealTicket register(int index, VoidCallback reveal) {
    final ticket = MediaCoverRevealTicket._(this, index, reveal);
    _tickets.add(ticket);
    return ticket;
  }

  void _schedule() {
    if (_tickets.isEmpty || (_waitingForSlow && !_hasBlockedReady())) {
      _timer?.cancel();
      _timer = null;
      _waitingForSlow = false;
    }
    if (_scheduled) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      _pump();
    });
  }

  bool _hasBlockedReady() {
    int? firstReady;
    for (final ticket in _tickets) {
      if (ticket._ready && (firstReady == null || ticket.index < firstReady)) {
        firstReady = ticket.index;
      }
    }
    return firstReady != null &&
        _tickets.any((ticket) => !ticket._ready && ticket.index < firstReady!);
  }

  void _pump() {
    if (_timer != null) return;
    MediaCoverRevealTicket? next;
    for (final ticket in _tickets) {
      if (ticket._ready && (next == null || ticket.index < next.index)) {
        next = ticket;
      }
    }
    if (next == null) {
      _skipSlow = false;
      _burst = 0;
      return;
    }
    if (!_skipSlow &&
        _tickets.any(
          (ticket) => !ticket._ready && ticket.index < next!.index,
        )) {
      _waitingForSlow = true;
      _timer = Timer(const Duration(milliseconds: 100), () {
        _timer = null;
        _waitingForSlow = false;
        _skipSlow = true;
        _pump();
      });
      return;
    }
    _tickets.remove(next);
    next._removed = true;
    next._reveal();
    _burst++;
    if (_tickets.isEmpty) {
      _skipSlow = false;
      _burst = 0;
      return;
    }
    // Release in small groups so a dense viewport does not start hundreds of
    // composited fades on one frame. Only mounted cells participate.
    if (_burst.isOdd) {
      _schedule();
    } else {
      _timer = Timer(const Duration(milliseconds: 18), () {
        _timer = null;
        _pump();
      });
    }
  }
}
