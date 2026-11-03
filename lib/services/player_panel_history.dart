/// Navigation shared by the portrait and landscape player tools.
///
/// The current panel belongs to the page. This stores the complete return path,
/// including an explicitly empty sidebar. Opening an ancestor rewinds to it,
/// so switching tools never creates a cycle or a panel that returns to itself.
class PlayerPanelHistory<T> {
  final List<T> _panels = [];

  List<T> get panels => List.unmodifiable(_panels);
  T? get previous => _panels.isEmpty ? null : _panels.last;
  bool get isNotEmpty => _panels.isNotEmpty;
  bool contains(T panel) => _panels.contains(panel);

  void open({required T current, required T target}) {
    if (current == target) return;
    final ancestor = _panels.indexOf(target);
    if (ancestor >= 0) {
      _panels.removeRange(ancestor, _panels.length);
    } else {
      _panels.add(current);
    }
  }

  T pop({required T fallback}) =>
      _panels.isEmpty ? fallback : _panels.removeLast();

  void clear() => _panels.clear();

  void discardCurrent(T current) {
    while (_panels.isNotEmpty && _panels.last == current) {
      _panels.removeLast();
    }
  }

  /// Apply layout/media availability changes to every return destination.
  void remap(T Function(T panel) map) {
    final next = <T>[];
    for (final panel in _panels) {
      final mapped = map(panel);
      final ancestor = next.indexOf(mapped);
      if (ancestor >= 0) {
        next.removeRange(ancestor + 1, next.length);
      } else {
        next.add(mapped);
      }
    }
    _panels
      ..clear()
      ..addAll(next);
  }
}
