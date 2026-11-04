import 'media_library_root_entry.dart';

/// Display/swipe order for root library pages.
///
/// Enum declaration order stays a stable identity. This list is what the
/// chips and adjacent-swipe use, so a later fourth page can append here
/// without rewriting storage keys.
class MediaLibraryRootEntryOrder {
  const MediaLibraryRootEntryOrder._();

  /// Only local library surfaces are mounted. Legacy online IDs are ignored.
  static const List<MediaLibraryRootEntry> defaults = [
    MediaLibraryRootEntry.continueLearning,
    MediaLibraryRootEntry.folders,
    MediaLibraryRootEntry.recent,
  ];

  static List<MediaLibraryRootEntry> normalize(
    Iterable<MediaLibraryRootEntry?> raw,
  ) {
    final seen = <MediaLibraryRootEntry>{};
    final out = <MediaLibraryRootEntry>[];
    for (final entry in raw) {
      if (entry == null || !entry.isLocal || !seen.add(entry)) {
        continue;
      }
      out.add(entry);
    }
    for (final entry in defaults) {
      if (seen.add(entry)) out.add(entry);
    }
    return out;
  }

  static List<MediaLibraryRootEntry> parse(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return List<MediaLibraryRootEntry>.of(defaults);
    }
    return normalize(
      raw
          .split(',')
          .map((part) => MediaLibraryRootEntryX.tryParse(part.trim())),
    );
  }

  static String encode(List<MediaLibraryRootEntry> order) {
    return normalize(order).map((entry) => entry.storageValue).join(',');
  }

  /// [oldIndex] / [newIndex] are already insertion indices after removal
  /// (Flutter [ReorderableListView.onReorderItem]).
  static List<MediaLibraryRootEntry> moved(
    List<MediaLibraryRootEntry> order, {
    required int oldIndex,
    required int newIndex,
  }) {
    final next = normalize(order);
    if (oldIndex < 0 || oldIndex >= next.length) return next;
    if (newIndex < 0) return next;
    if (oldIndex == newIndex) return next;
    final item = next.removeAt(oldIndex);
    final dest = newIndex.clamp(0, next.length);
    next.insert(dest, item);
    return next;
  }
}
