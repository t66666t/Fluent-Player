import '../../widgets/media_library_page_shortcuts.dart';

/// Podcast-specific name retained for callers of the shared page key scope.
class PodcastPageShortcuts extends MediaLibraryPageShortcuts {
  const PodcastPageShortcuts({
    super.key,
    required super.child,
    super.enabled,
    super.bindings,
    super.onEscape,
    super.onSelectAll,
  });
}
