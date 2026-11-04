/// Literal title matcher used by media-library search.
///
/// Search deliberately knows nothing about file paths, parent-folder names,
/// thumbnails or metadata. A result is included only when the text rendered as
/// that card's own title contains the normalized query.
class MediaLibrarySearchQuery {
  MediaLibrarySearchQuery(String query) : normalized = _normalize(query);

  final String normalized;

  bool get isEmpty => normalized.isEmpty;

  bool matchesTitle(String title) {
    if (isEmpty) return false;
    return _normalize(title).contains(normalized);
  }

  int rankTitle(String title) {
    final normalizedTitle = _normalize(title);
    if (normalizedTitle == normalized) return 0;
    if (normalizedTitle.startsWith(normalized)) return 1;
    if (normalizedTitle
        .split(RegExp(r'[\s_\-.]+'))
        .any((part) => part.startsWith(normalized))) {
      return 2;
    }
    return 3;
  }

  static String _normalize(String value) {
    return value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  }
}
