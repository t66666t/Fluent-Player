import 'package:flutter/widgets.dart';

import '../utils/media_library_range_selection.dart';

/// Geometry for multi-section virtual pages (继续学习 / 最近添加).
///
/// Cards register [GlobalKey]s; range and box select hit those rects instead of
/// assuming a single flat [MediaLibraryGridGeometry].
class MediaLibraryVirtualSelectionHost {
  List<String> _orderedIds = const <String>[];
  final Map<String, GlobalKey> _keys = <String, GlobalKey>{};

  List<String> get orderedIds => _orderedIds;

  int get itemCount => _orderedIds.length;

  /// Replaces the reading-order list built by the active virtual view.
  void updateOrderedIds(Iterable<String> ids) {
    _orderedIds = List<String>.unmodifiable(ids);
    final live = _orderedIds.toSet();
    _keys.removeWhere((id, _) => !live.contains(id));
  }

  GlobalKey keyFor(String id) => _keys.putIfAbsent(id, GlobalKey.new);

  int? indexOf(String id) {
    final index = _orderedIds.indexOf(id);
    return index < 0 ? null : index;
  }

  String? idAt(int index) {
    if (index < 0 || index >= _orderedIds.length) return null;
    return _orderedIds[index];
  }

  Rect? globalRectOf(String id) {
    final context = _keys[id]?.currentContext;
    if (context == null || !context.mounted) return null;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final origin = box.localToGlobal(Offset.zero);
    return origin & box.size;
  }

  /// True when [global] lies inside a registered card.
  bool hitsCard(Offset global) => idContaining(global) != null;

  String? idContaining(Offset global) {
    for (final id in _orderedIds) {
      final rect = globalRectOf(id);
      if (rect != null && rect.contains(global)) return id;
    }
    return null;
  }

  /// Nearest visible card for album-style range drag when the pointer leaves
  /// a cell. Prefers containment, then the closest card center.
  int? indexForDragSelection(Offset global) {
    if (_orderedIds.isEmpty) return null;
    final containing = idContaining(global);
    if (containing != null) return indexOf(containing);

    // Cards that are not built have no rect. Defaulting to index 0 here made
    // an edge drag select every item from the anchor back to the start, and
    // those off-screen cards never showed a selection circle.
    int? bestIndex;
    var bestDistance = double.infinity;
    for (var i = 0; i < _orderedIds.length; i++) {
      final rect = globalRectOf(_orderedIds[i]);
      if (rect == null) continue;
      final dx = (global.dx - rect.center.dx).abs();
      final dy = (global.dy - rect.center.dy).abs();
      final distance = dx * dx + dy * dy;
      if (distance < bestDistance) {
        bestDistance = distance;
        bestIndex = i;
      }
    }
    return bestIndex;
  }

  Set<String> idsOverlapping(Rect globalRect) {
    final hit = <String>{};
    for (final id in _orderedIds) {
      final rect = globalRectOf(id);
      if (rect != null && rect.overlaps(globalRect)) {
        hit.add(id);
      }
    }
    return hit;
  }

  /// Merges a checkbox-drag range using the host's reading order.
  Set<String> mergeRange({
    required Set<String> snapshot,
    required int startIndex,
    required int currentIndex,
  }) {
    return MediaLibraryRangeSelection.mergeSnapshotWithIndexRange(
      snapshot: snapshot,
      startIndex: startIndex,
      currentIndex: currentIndex,
      itemCount: itemCount,
      idAt: idAt,
    );
  }
}

/// Selection callbacks passed into virtual views so HomeScreen keeps the set.
class MediaLibraryVirtualSelectionBinding {
  const MediaLibraryVirtualSelectionBinding({
    required this.isSelectionMode,
    required this.selectedIds,
    required this.host,
    required this.onToggle,
    required this.onEnter,
    required this.onSecondaryTap,
    required this.onRangeStart,
    required this.onRangeUpdate,
    required this.onRangeEnd,
  });

  final bool isSelectionMode;
  final Set<String> selectedIds;
  final MediaLibraryVirtualSelectionHost host;
  final ValueChanged<String> onToggle;
  final ValueChanged<String> onEnter;
  final ValueChanged<String> onSecondaryTap;
  final void Function(String id, Offset globalPosition) onRangeStart;
  final ValueChanged<Offset> onRangeUpdate;
  final VoidCallback onRangeEnd;

  bool isSelected(String id) => selectedIds.contains(id);

  /// Fingerprint so frozen virtual trees rebuild when selection changes.
  String get freezeToken {
    if (!isSelectionMode) return 'off';
    final ids = selectedIds.toList()..sort();
    return 'on:${ids.join(',')}';
  }
}
