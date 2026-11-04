import 'dart:math';

import '../models/playback_mode.dart';

/// Playback order is independent of the source listing. Planning on a copy
/// keeps getters, prefetch and queued skips from consuming the live queue.
class PlaybackQueueOrder {
  PlaybackQueueOrder({int? seed}) : seed = seed ?? Random().nextInt(1 << 30);

  final int seed;
  PlaybackMode mode = PlaybackMode.sequential;
  String? currentId;
  int round = 0;
  List<String> _source = [];
  List<String> _pending = [];
  final Set<String> _played = {};
  List<String> _history = [];
  int _historyIndex = -1;

  PlaybackQueueOrder copy() => PlaybackQueueOrder(seed: seed)
    ..mode = mode
    ..currentId = currentId
    ..round = round
    .._source = List.of(_source)
    .._pending = List.of(_pending)
    .._played.addAll(_played)
    .._history = List.of(_history)
    .._historyIndex = _historyIndex;

  void synchronize(Iterable<String> ids, String? selectedId) {
    final source = ids.toSet().toList();
    final valid = source.toSet();
    final previousIds = _source.toSet();
    final added = source.where((id) => !previousIds.contains(id)).toList();
    final historyCurrent = _historyIndex >= 0 && _historyIndex < _history.length
        ? _history[_historyIndex]
        : null;
    final before = _history
        .take(_historyIndex + 1)
        .where(valid.contains)
        .length;
    _history = _history.where(valid.contains).toList();
    _historyIndex = before - 1;
    if (historyCurrent != null && !valid.contains(historyCurrent)) {
      _historyIndex = _historyIndex.clamp(-1, _history.length - 1);
    }
    _played.retainAll(valid);
    _pending = _pending.where(valid.contains).toList();
    _source = source;
    if (mode == PlaybackMode.shuffle) {
      added.removeWhere((id) => _played.contains(id) || _pending.contains(id));
      added.shuffle(Random(seed + round + source.length));
      _pending.addAll(added);
    }
    if (selectedId == currentId &&
        valid.contains(selectedId) &&
        (_historyIndex < 0 || _history[_historyIndex] != selectedId)) {
      currentId = null;
    }
    if (selectedId != currentId || _history.isEmpty) select(selectedId);
  }

  void setMode(PlaybackMode value) {
    if (mode == value) return;
    mode = value;
    if (value == PlaybackMode.shuffle) {
      _pending = _source.where((id) => !_played.contains(id)).toList()
        ..shuffle(Random(seed + round));
      _pending.remove(currentId);
    }
  }

  /// Coalesced key presses may traverse several candidates, but only the
  /// final target was actually opened. Previous must not visit those skipped
  /// candidates as though the player had played them.
  void keepCommittedHistory(PlaybackQueueOrder previous) {
    if (mode != PlaybackMode.shuffle || currentId == previous.currentId) return;
    if (_historyIndex < previous._history.length &&
        _historyIndex >= 0 &&
        previous._history[_historyIndex] == currentId) {
      _history = List.of(previous._history);
      return;
    }
    _history = previous._history.take(previous._historyIndex + 1).toList();
    _history.add(currentId!);
    _historyIndex = _history.length - 1;
  }

  void select(String? id) {
    if (currentId == id && _history.isNotEmpty) return;
    currentId = id;
    if (id == null || !_source.contains(id)) return;
    _pending.remove(id);
    _played.add(id);
    if (_historyIndex + 1 < _history.length) {
      _history.removeRange(_historyIndex + 1, _history.length);
    }
    _history.add(id);
    if (_history.length > 1000) _history.removeAt(0);
    _historyIndex = _history.length - 1;
  }

  /// Returns the selected id, or null at a real boundary. A repeat-one mode
  /// changes EOF handling only; explicit skips use the original source order.
  String? move(
    int delta, {
    required bool wrap,
    bool includeCurrentAfterWrap = false,
  }) {
    if (currentId == null || !_source.contains(currentId)) return null;
    if (_source.length == 1) {
      return wrap && includeCurrentAfterWrap ? currentId : null;
    }
    if (mode != PlaybackMode.shuffle) {
      final index = _source.indexOf(currentId!);
      var target = index + (delta > 0 ? 1 : -1);
      if (target < 0 || target >= _source.length) {
        if (!wrap) return null;
        target %= _source.length;
        if (delta > 0) {
          round++;
          _played.clear();
        }
      }
      final id = _source[target];
      select(id);
      return id;
    }

    if (delta < 0) {
      if (_historyIndex <= 0) return null;
      currentId = _history[--_historyIndex];
      return currentId;
    }
    if (_historyIndex + 1 < _history.length) {
      currentId = _history[++_historyIndex];
      return currentId;
    }
    if (_pending.isEmpty) {
      if (!wrap) return null;
      round++;
      _played.clear();
      _pending = List.of(_source)..shuffle(Random(seed + round));
      if (_pending.first == currentId) {
        final first = _pending[0];
        _pending[0] = _pending[1];
        _pending[1] = first;
      }
    }
    final id = _pending.first;
    select(id);
    return id;
  }

  List<String> get queueIds {
    if (mode == PlaybackMode.shuffle && currentId == null) {
      return List.unmodifiable({..._pending, ..._source});
    }
    if (mode != PlaybackMode.shuffle || !_source.contains(currentId)) {
      return List.unmodifiable(_source);
    }
    final future = <String>{..._history.skip(_historyIndex + 1), ..._pending}
      ..remove(currentId);
    final past = <String>{
      ..._history.take(_historyIndex + 1),
      ..._source.where((id) => !future.contains(id)),
    }..remove(currentId);
    past.removeAll(future);
    return [...past, currentId!, ...future];
  }

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'seed': seed,
    'round': round,
    'source': List.of(_source),
    'currentId': currentId,
    'pending': List.of(_pending),
    'played': _played.toList(),
    'history': List.of(_history),
    'historyIndex': _historyIndex,
  };

  factory PlaybackQueueOrder.fromJson(Map<String, dynamic> json) {
    List<String> strings(String key) =>
        (json[key] is List ? json[key] as List : const [])
            .whereType<String>()
            .toList();
    final order = PlaybackQueueOrder(seed: json['seed'] as int?);
    order.mode = PlaybackMode.values.firstWhere(
      (mode) => mode.name == json['mode'],
      orElse: () => PlaybackMode.sequential,
    );
    order.round = (json['round'] as int? ?? 0).clamp(0, 1 << 30);
    order._source = strings('source').toSet().toList();
    final valid = order._source.toSet();
    order.currentId = json['currentId'] as String?;
    order._played.addAll(strings('played').where(valid.contains));
    if (valid.contains(order.currentId)) order._played.add(order.currentId!);
    order._pending = strings('pending').where(valid.contains).toSet().toList()
      ..removeWhere(order._played.contains);
    order._history = strings(
      'history',
    ).where(valid.contains).take(1000).toList();
    order._historyIndex = (json['historyIndex'] as int? ?? -1).clamp(
      -1,
      order._history.length - 1,
    );
    return order;
  }
}
