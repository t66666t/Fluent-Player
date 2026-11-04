import 'dart:convert';

import '../models/media_library_root_entry.dart';

/// Visible item plus optional pixel offset for one root entry.
///
/// Item IDs are the durable restore key. Pixel offsets are a hint and must
/// be discarded when the item is gone or the layout no longer matches.
class MediaLibraryScrollAnchor {
  const MediaLibraryScrollAnchor({this.itemId, this.offset});

  final String? itemId;
  final double? offset;

  bool get isEmpty =>
      (itemId == null || itemId!.isEmpty) && (offset == null || offset == 0);

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      if (itemId != null && itemId!.isNotEmpty) 'itemId': itemId,
      if (offset != null) 'offset': offset,
    };
  }

  static MediaLibraryScrollAnchor fromJson(dynamic raw) {
    if (raw is! Map) return const MediaLibraryScrollAnchor();
    final itemId = raw['itemId'] as String?;
    final offsetRaw = raw['offset'];
    final offset = offsetRaw is num ? offsetRaw.toDouble() : null;
    return MediaLibraryScrollAnchor(itemId: itemId, offset: offset);
  }
}

/// Result of applying stored prefs + library readiness to the root shell.
class MediaLibraryNavigationPlan {
  const MediaLibraryNavigationPlan({
    required this.preferredEntry,
    required this.displayedEntry,
    required this.persistPreferred,
    required this.hideSwitcher,
    required this.forceFoldersForLocate,
    this.folderToOpen,
  });

  /// Stored or first-run default, including entries not mounted yet.
  final MediaLibraryRootEntry preferredEntry;

  /// Entry whose content is actually shown (never an empty placeholder).
  final MediaLibraryRootEntry displayedEntry;

  /// Persist [preferredEntry] without marking it user-chosen.
  final bool persistPreferred;

  /// Locate / search-return copies keep the original chrome, not the switcher.
  final bool hideSwitcher;

  /// Reveal-in-directory must ignore the last global root entry.
  final bool forceFoldersForLocate;

  /// Nested folder to open once after init; null means stay on the root grid.
  final String? folderToOpen;
}

/// Pure navigation decisions so tests do not load HomeScreen or the player.
class MediaLibraryNavigation {
  static const foldersFallback = MediaLibraryRootEntry.folders;

  static MediaLibraryRootEntry firstRunDefault({
    required bool hasExistingLibraryContent,
  }) {
    // New install: land on 最近添加. Existing libraries keep 文件夹 on first
    // upgrade so the previous browsing surface is unchanged.
    return hasExistingLibraryContent
        ? MediaLibraryRootEntry.folders
        : MediaLibraryRootEntry.recent;
  }

  static MediaLibraryRootEntry displayedEntry({
    required MediaLibraryRootEntry preferred,
    required Set<MediaLibraryRootEntry> availableEntries,
  }) {
    if (!preferred.isLocal) {
      return foldersFallback;
    }
    if (availableEntries.contains(preferred)) return preferred;
    if (availableEntries.contains(foldersFallback)) return foldersFallback;
    return availableEntries.where((entry) => entry.isLocal).firstOrNull ??
        foldersFallback;
  }

  /// Walk recycled/missing folders toward the nearest living ancestor.
  static String? resolveLivingFolderId({
    required String? requestedId,
    required bool Function(String id) isActiveFolder,
    required String? Function(String id) parentIdOf,
  }) {
    var currentId = requestedId;
    if (currentId == null || currentId.isEmpty) return null;
    final seen = <String>{};
    while (currentId != null && currentId.isNotEmpty && seen.add(currentId)) {
      if (isActiveFolder(currentId)) return currentId;
      currentId = parentIdOf(currentId);
    }
    return null;
  }

  static MediaLibraryNavigationPlan plan({
    required bool libraryInitialized,
    required bool hasExistingLibraryContent,
    required String storedEntry,
    required bool userChosen,
    required String lastFolderId,
    required Set<MediaLibraryRootEntry> availableEntries,
    required String? revealItemId,
    required bool returnToSearchResults,
    required bool Function(String id) isActiveFolder,
    required String? Function(String id) parentIdOf,
    bool restoreLastPage = true,
    String startupEntry = '',
  }) {
    final locateHome = revealItemId != null || returnToSearchResults;
    final stored = MediaLibraryRootEntryX.tryParse(storedEntry);
    final parsedStored = stored?.isLocal == true ? stored : null;
    final MediaLibraryRootEntry preferred;
    if (!restoreLastPage) {
      final startup = MediaLibraryRootEntryX.tryParse(startupEntry);
      preferred = startup?.isLocal == true ? startup! : foldersFallback;
    } else if (userChosen && parsedStored != null) {
      preferred = parsedStored;
    } else if (parsedStored != null && libraryInitialized) {
      preferred = parsedStored;
    } else if (!libraryInitialized) {
      // Do not treat "JSON not read yet" as an empty new library.
      preferred = foldersFallback;
    } else {
      preferred = firstRunDefault(
        hasExistingLibraryContent: hasExistingLibraryContent,
      );
    }

    // Keep the last real visit on disk while restore is off, so turning the
    // setting back on still returns to that page.
    final persistPreferred =
        restoreLastPage &&
        libraryInitialized &&
        !userChosen &&
        (storedEntry.isEmpty || parsedStored != preferred);

    var displayed = displayedEntry(
      preferred: preferred,
      availableEntries: availableEntries,
    );
    var folderToOpen = null as String?;
    if (locateHome) {
      displayed = displayedEntry(
        preferred: MediaLibraryRootEntry.folders,
        availableEntries: availableEntries,
      );
    } else if (restoreLastPage &&
        libraryInitialized &&
        displayed == MediaLibraryRootEntry.folders) {
      folderToOpen = resolveLivingFolderId(
        requestedId: lastFolderId,
        isActiveFolder: isActiveFolder,
        parentIdOf: parentIdOf,
      );
    }

    return MediaLibraryNavigationPlan(
      preferredEntry: preferred,
      displayedEntry: displayed,
      persistPreferred: persistPreferred && !locateHome,
      hideSwitcher: returnToSearchResults || locateHome,
      forceFoldersForLocate: locateHome,
      folderToOpen: folderToOpen,
    );
  }

  static String encodeAnchors(
    Map<MediaLibraryRootEntry, MediaLibraryScrollAnchor> anchors,
  ) {
    final encoded = <String, dynamic>{};
    for (final entry in MediaLibraryRootEntry.values) {
      final anchor = anchors[entry];
      if (anchor == null || anchor.isEmpty) continue;
      encoded[entry.storageValue] = anchor.toJson();
    }
    if (encoded.isEmpty) return '';
    return jsonEncode(encoded);
  }

  static Map<MediaLibraryRootEntry, MediaLibraryScrollAnchor> decodeAnchors(
    String raw,
  ) {
    if (raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      final result = <MediaLibraryRootEntry, MediaLibraryScrollAnchor>{};
      for (final entry in MediaLibraryRootEntry.values) {
        if (!decoded.containsKey(entry.storageValue)) continue;
        result[entry] = MediaLibraryScrollAnchor.fromJson(
          decoded[entry.storageValue],
        );
      }
      return result;
    } catch (_) {
      return const {};
    }
  }

  /// Drop pixel offsets when the anchored item is no longer in the view.
  static MediaLibraryScrollAnchor sanitizeAnchor({
    required MediaLibraryScrollAnchor anchor,
    required Set<String> visibleItemIds,
  }) {
    final itemId = anchor.itemId;
    if (itemId == null || itemId.isEmpty || !visibleItemIds.contains(itemId)) {
      return const MediaLibraryScrollAnchor();
    }
    return anchor;
  }
}
