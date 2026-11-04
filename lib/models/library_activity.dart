import 'dart:collection';
import 'download_import_context.dart';

/// Local-only learning activity stored beside library.json, never on VideoItem.
///
/// The block has its own version so media schema 2 migrations stay untouched.
/// [recentDismissedIds] stays on version 1: a version bump would make an older
/// build treat the whole activity block as unreadable.
class LibraryActivityStore {
  static const int currentVersion = 1;
  static const String snapshotKey = 'activity';

  LibraryActivityStore({
    Map<String, MediaActivityRecord>? media,
    List<ImportBatchRecord>? batches,
    List<String>? pinnedIds,
    Iterable<String>? recentDismissedIds,
  }) : media = media ?? <String, MediaActivityRecord>{},
       batches = batches ?? <ImportBatchRecord>[],
       pinnedIds = pinnedIds ?? <String>[],
       recentDismissedIds = LinkedHashSet<String>.of(
         recentDismissedIds ?? const <String>[],
       );

  factory LibraryActivityStore.empty() => LibraryActivityStore();

  final Map<String, MediaActivityRecord> media;
  final List<ImportBatchRecord> batches;
  final List<String> pinnedIds;

  /// Media and folder ids hidden from 最近添加 only.
  ///
  /// Not the continue-learning [MediaActivityRecord.hidden] flag. Playback
  /// does not remove an id from this set.
  final LinkedHashSet<String> recentDismissedIds;

  MediaActivityRecord ensureMedia(String mediaId) {
    return media.putIfAbsent(
      mediaId,
      () => MediaActivityRecord(mediaId: mediaId),
    );
  }

  /// Reorders visible pins like folder-grid drop: drop onto a later card
  /// inserts after it; drop onto an earlier card inserts before it.
  ///
  /// Hidden / recycled IDs keep their list slots so restore can return to
  /// the same neighbors. Does not copy or move media in the folder tree.
  static List<String> reorderVisiblePinnedIds({
    required List<String> pinnedIds,
    required Set<String> visibleIds,
    required int fromVisibleIndex,
    required int toVisibleIndex,
  }) {
    if (fromVisibleIndex == toVisibleIndex) {
      return List<String>.from(pinnedIds);
    }
    final visibleSlots = <int>[];
    for (var i = 0; i < pinnedIds.length; i++) {
      if (visibleIds.contains(pinnedIds[i])) visibleSlots.add(i);
    }
    if (fromVisibleIndex < 0 ||
        toVisibleIndex < 0 ||
        fromVisibleIndex >= visibleSlots.length ||
        toVisibleIndex >= visibleSlots.length) {
      return List<String>.from(pinnedIds);
    }
    final visible = [for (final slot in visibleSlots) pinnedIds[slot]];
    final moved = visible[fromVisibleIndex];
    final insertBeforeIndex = fromVisibleIndex < toVisibleIndex
        ? toVisibleIndex + 1
        : toVisibleIndex;
    final insertBeforeId = insertBeforeIndex < visible.length
        ? visible[insertBeforeIndex]
        : null;
    visible.removeAt(fromVisibleIndex);
    if (insertBeforeId == null) {
      visible.add(moved);
    } else {
      visible.insert(visible.indexOf(insertBeforeId), moved);
    }
    final next = List<String>.from(pinnedIds);
    for (var i = 0; i < visibleSlots.length; i++) {
      next[visibleSlots[i]] = visible[i];
    }
    return next;
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'version': currentVersion,
      'media': media.values.map((record) => record.toJson()).toList(),
      'batches': batches.map((batch) => batch.toJson()).toList(),
      'pinnedIds': List<String>.from(pinnedIds),
      'recentDismissedIds': recentDismissedIds.toList(growable: false),
    };
  }

  /// Parses a snapshot activity object. Unknown future versions are not applied.
  static LibraryActivityParseResult parse(Object? raw) {
    if (raw == null) {
      return LibraryActivityParseResult.missing();
    }
    if (raw is! Map) {
      return LibraryActivityParseResult.partial(LibraryActivityStore.empty());
    }
    final json = Map<String, dynamic>.from(raw);
    final version = _readInt(json['version']) ?? currentVersion;
    if (version > currentVersion) {
      return LibraryActivityParseResult.unsupportedFuture(json);
    }

    final store = LibraryActivityStore.empty();
    final mediaRaw = json['media'];
    if (mediaRaw is List) {
      for (final entry in mediaRaw) {
        final record = MediaActivityRecord.tryParse(entry);
        if (record == null) continue;
        store.media[record.mediaId] = record;
      }
    } else if (mediaRaw is Map) {
      // Tolerate an object map keyed by id from a hand-edited file.
      for (final entry in mediaRaw.entries) {
        final record = MediaActivityRecord.tryParse(
          entry.value,
          fallbackId: entry.key.toString(),
        );
        if (record == null) continue;
        store.media[record.mediaId] = record;
      }
    }

    final batchesRaw = json['batches'];
    if (batchesRaw is List) {
      for (final entry in batchesRaw) {
        final batch = ImportBatchRecord.tryParse(entry);
        if (batch == null) continue;
        store.batches.add(batch);
      }
    }

    final pinsRaw = json['pinnedIds'];
    if (pinsRaw is List) {
      final seen = <String>{};
      for (final entry in pinsRaw) {
        if (entry is! String) continue;
        final id = entry.trim();
        if (id.isEmpty || !seen.add(id)) continue;
        store.pinnedIds.add(id);
      }
    }

    final dismissedRaw = json['recentDismissedIds'];
    if (dismissedRaw is List) {
      for (final entry in dismissedRaw) {
        if (entry is! String) continue;
        final id = entry.trim();
        if (id.isEmpty) continue;
        store.recentDismissedIds.add(id);
      }
    }

    return LibraryActivityParseResult.ok(store);
  }
}

class LibraryActivityParseResult {
  LibraryActivityParseResult._({
    required this.store,
    required this.unsupportedFutureVersion,
    this.preservedRaw,
    this.wasMissing = false,
  });

  factory LibraryActivityParseResult.ok(LibraryActivityStore store) {
    return LibraryActivityParseResult._(
      store: store,
      unsupportedFutureVersion: false,
    );
  }

  factory LibraryActivityParseResult.missing() {
    return LibraryActivityParseResult._(
      store: LibraryActivityStore.empty(),
      unsupportedFutureVersion: false,
      wasMissing: true,
    );
  }

  factory LibraryActivityParseResult.partial(LibraryActivityStore store) {
    return LibraryActivityParseResult._(
      store: store,
      unsupportedFutureVersion: false,
    );
  }

  factory LibraryActivityParseResult.unsupportedFuture(
    Map<String, dynamic> raw,
  ) {
    return LibraryActivityParseResult._(
      store: LibraryActivityStore.empty(),
      unsupportedFutureVersion: true,
      preservedRaw: raw,
    );
  }

  final LibraryActivityStore store;
  final bool unsupportedFutureVersion;
  final Map<String, dynamic>? preservedRaw;
  final bool wasMissing;
}

class MediaActivityRecord {
  MediaActivityRecord({
    required this.mediaId,
    this.addedAtMs,
    this.lastPlayedAtMs,
    this.accumulatedWatchMs = 0,
    this.completed = false,
    this.hidden = false,
    this.sharedLastPlayedCardId,
    this.downloadImport,
    bool? continueEnrolled,
  }) : continueEnrolled = continueEnrolled ?? lastPlayedAtMs != null;

  final String mediaId;
  int? addedAtMs;
  int? lastPlayedAtMs;
  int accumulatedWatchMs;
  bool completed;
  bool hidden;
  String? sharedLastPlayedCardId;
  DownloadImportContext? downloadImport;

  /// Reached the continue-learning watch threshold at least once.
  /// Missing in old snapshots: inferred from [lastPlayedAtMs].
  bool continueEnrolled;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': mediaId,
      'addedAtMs': addedAtMs,
      'lastPlayedAtMs': lastPlayedAtMs,
      'accumulatedWatchMs': accumulatedWatchMs,
      'completed': completed,
      'hidden': hidden,
      if (sharedLastPlayedCardId != null)
        'sharedLastPlayedCardId': sharedLastPlayedCardId,
      if (downloadImport != null) 'downloadImport': downloadImport!.toJson(),
      'continueEnrolled': continueEnrolled,
    };
  }

  static MediaActivityRecord? tryParse(Object? raw, {String? fallbackId}) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    final id = _readNonEmptyString(json['id']) ?? fallbackId;
    if (id == null) return null;
    final lastPlayedAtMs = _readInt(json['lastPlayedAtMs']);
    return MediaActivityRecord(
      mediaId: id,
      addedAtMs: _readInt(json['addedAtMs']),
      lastPlayedAtMs: lastPlayedAtMs,
      accumulatedWatchMs: _readInt(json['accumulatedWatchMs']) ?? 0,
      completed: json['completed'] == true,
      hidden: json['hidden'] == true,
      sharedLastPlayedCardId: _readNonEmptyString(
        json['sharedLastPlayedCardId'],
      ),
      downloadImport: DownloadImportContext.fromJson(json['downloadImport']),
      continueEnrolled: json.containsKey('continueEnrolled')
          ? json['continueEnrolled'] == true
          : lastPlayedAtMs != null,
    );
  }
}

class ImportBatchRecord {
  ImportBatchRecord({
    required this.id,
    required this.startedAtMs,
    required this.title,
    required this.sourceKind,
    this.targetCollectionId,
    List<String>? createdMediaIds,
    List<String>? createdCollectionIds,
    Map<String, String>? downloadFolders,
    Map<String, String>? downloadReceipts,
    Set<String>? manualOrderParents,
  }) : createdMediaIds = createdMediaIds ?? <String>[],
       createdCollectionIds = createdCollectionIds ?? <String>[],
       downloadFolders = downloadFolders ?? <String, String>{},
       downloadReceipts = downloadReceipts ?? <String, String>{},
       manualOrderParents = manualOrderParents ?? <String>{};

  final String id;
  int startedAtMs;
  final String title;
  LibraryImportSourceKind sourceKind;
  final String? targetCollectionId;
  final List<String> createdMediaIds;
  final Map<String, String> downloadFolders;
  final Map<String, String> downloadReceipts;
  final Set<String> manualOrderParents;

  /// Folders created for this import, root first. Recent view shows their
  /// first layer instead of flattening every descendant file.
  final List<String> createdCollectionIds;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'startedAtMs': startedAtMs,
      'title': title,
      'sourceKind': sourceKind.storageValue,
      'targetCollectionId': targetCollectionId,
      'createdMediaIds': List<String>.from(createdMediaIds),
      'createdCollectionIds': List<String>.from(createdCollectionIds),
      if (downloadFolders.isNotEmpty)
        'downloadFolders': Map<String, String>.from(downloadFolders),
      if (downloadReceipts.isNotEmpty)
        'downloadReceipts': Map<String, String>.from(downloadReceipts),
      if (manualOrderParents.isNotEmpty)
        'manualOrderParents': manualOrderParents.toList(),
    };
  }

  static ImportBatchRecord? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    final id = _readNonEmptyString(json['id']);
    final startedAtMs = _readInt(json['startedAtMs']);
    final title = _readNonEmptyString(json['title']);
    if (id == null || startedAtMs == null || title == null) return null;
    final members = <String>[];
    final seen = <String>{};
    final membersRaw = json['createdMediaIds'];
    if (membersRaw is List) {
      for (final entry in membersRaw) {
        if (entry is! String) continue;
        final mediaId = entry.trim();
        if (mediaId.isEmpty || !seen.add(mediaId)) continue;
        members.add(mediaId);
      }
    }
    return ImportBatchRecord(
      id: id,
      startedAtMs: startedAtMs,
      title: title,
      sourceKind: LibraryImportSourceKindX.fromStorage(json['sourceKind']),
      targetCollectionId: _readNonEmptyString(json['targetCollectionId']),
      createdMediaIds: members,
      createdCollectionIds: _readIdList(json['createdCollectionIds']),
      downloadFolders: json['downloadFolders'] is Map
          ? {
              for (final entry in (json['downloadFolders'] as Map).entries)
                if (entry.key is String && entry.value is String)
                  entry.key as String: entry.value as String,
            }
          : null,
      manualOrderParents: _readIdList(json['manualOrderParents']).toSet(),
      downloadReceipts: json['downloadReceipts'] is Map
          ? {
              for (final entry in (json['downloadReceipts'] as Map).entries)
                if (entry.key is String && entry.value is String)
                  entry.key as String: entry.value as String,
            }
          : null,
    );
  }

  static List<String> _readIdList(Object? raw) {
    final ids = <String>[];
    final seen = <String>{};
    if (raw is! List) return ids;
    for (final entry in raw) {
      if (entry is! String) continue;
      final id = entry.trim();
      if (id.isEmpty || !seen.add(id)) continue;
      ids.add(id);
    }
    return ids;
  }
}

enum LibraryImportSourceKind {
  localFile,
  folder,
  archive,
  share,
  bilibili,
  ytDlp,
  fluentPack,
  cloudDrive,
}

extension LibraryImportSourceKindX on LibraryImportSourceKind {
  String get storageValue {
    switch (this) {
      case LibraryImportSourceKind.localFile:
        return 'localFile';
      case LibraryImportSourceKind.folder:
        return 'folder';
      case LibraryImportSourceKind.archive:
        return 'archive';
      case LibraryImportSourceKind.share:
        return 'share';
      case LibraryImportSourceKind.bilibili:
        return 'bilibili';
      case LibraryImportSourceKind.ytDlp:
        return 'ytDlp';
      case LibraryImportSourceKind.fluentPack:
        return 'fluentPack';
      case LibraryImportSourceKind.cloudDrive:
        return 'cloudDrive';
    }
  }

  static LibraryImportSourceKind fromStorage(Object? raw) {
    switch (raw) {
      case 'folder':
        return LibraryImportSourceKind.folder;
      case 'archive':
        return LibraryImportSourceKind.archive;
      case 'share':
        return LibraryImportSourceKind.share;
      case 'bilibili':
        return LibraryImportSourceKind.bilibili;
      case 'ytDlp':
        return LibraryImportSourceKind.ytDlp;
      case 'fluentPack':
        return LibraryImportSourceKind.fluentPack;
      case 'cloudDrive':
        return LibraryImportSourceKind.cloudDrive;
      case 'localFile':
      default:
        return LibraryImportSourceKind.localFile;
    }
  }
}

int? _readInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

String? _readNonEmptyString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
