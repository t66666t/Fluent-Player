import '../../utils/media_library_range_selection.dart';

/// Episode selection stored by logical id.
///
/// List indexes and generated media ids are not identities: a refresh can
/// insert a row, and a projection id can differ from the episode id.
class PodcastEpisodeSelection {
  final Set<String> ids = <String>{};
  String? anchorId;
  bool active = false;

  bool contains(String id) => ids.contains(id);

  void begin(String id) {
    active = true;
    ids
      ..clear()
      ..add(id);
    anchorId = id;
  }

  /// Plain tap while selecting. Shift and Ctrl/Command are handled by the page
  /// through [extendTo] and [toggle].
  void toggle(String id) {
    active = true;
    if (!ids.remove(id)) {
      ids.add(id);
      anchorId = id;
    }
  }

  void extendTo(List<String> order, String targetId) {
    active = true;
    final anchor = anchorId;
    final start = anchor == null ? -1 : order.indexOf(anchor);
    final current = order.indexOf(targetId);
    if (start < 0 || current < 0) {
      ids.add(targetId);
      anchorId ??= targetId;
      return;
    }
    final snapshot = anchor == null ? <String>{} : <String>{anchor};
    ids
      ..clear()
      ..addAll(
        MediaLibraryRangeSelection.mergeSnapshotWithIndexRange(
          snapshot: snapshot,
          startIndex: start,
          currentIndex: current,
          itemCount: order.length,
          idAt: (index) => order[index],
        ),
      );
  }

  /// Adds the range on top of the selection that existed when the drag began.
  void extendFromSnapshot(
    List<String> order,
    Set<String> snapshot,
    int start,
    int current,
  ) {
    active = true;
    ids
      ..clear()
      ..addAll(
        MediaLibraryRangeSelection.mergeSnapshotWithIndexRange(
          snapshot: snapshot,
          startIndex: start,
          currentIndex: current,
          itemCount: order.length,
          idAt: (index) =>
              index < 0 || index >= order.length ? null : order[index],
        ),
      );
  }

  /// Drops the current ids but stays in selection mode. [clear] is the exit.
  void deselectAll() {
    ids.clear();
    anchorId = null;
  }

  /// Every id in the current query, including rows that have no widget yet.
  void selectAll(Iterable<String> queryIds) {
    active = true;
    ids
      ..clear()
      ..addAll(queryIds);
    if (ids.isNotEmpty) anchorId ??= ids.first;
  }

  /// A refresh may add episodes. Those new ids stay unselected.
  /// An empty selection that the user just opened stays open until they leave it.
  void retain(Iterable<String> stillVisible) {
    final before = ids.length;
    final visible = stillVisible.toSet();
    ids.removeWhere((id) => !visible.contains(id));
    if (anchorId != null && !visible.contains(anchorId)) {
      anchorId = ids.isEmpty ? null : ids.first;
    }
    if (before > 0 && ids.isEmpty) active = false;
  }

  void clear() {
    ids.clear();
    anchorId = null;
    active = false;
  }

  /// Selected ids in the order they appear on screen, so a dragged block does
  /// not reverse itself.
  List<String> ordered(List<String> displayOrder) {
    final selected = ids.toSet();
    return displayOrder.where(selected.contains).toList(growable: false);
  }
}
