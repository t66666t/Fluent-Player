import '../../../models/video_collection.dart';
import 'package:flutter/foundation.dart';
import '../../../models/video_item.dart';
import '../../../services/library_service.dart';
import '../models/cloud_drive_models.dart';
import '../models/cloud_drive_view_options.dart';
import 'cloud_drive_directory_session.dart';
import 'cloud_drive_runtime.dart';

/// Metadata-only import. Directory reads use the existing authenticated API.
class CloudDriveReferenceImport extends ChangeNotifier {
  CloudDriveReferenceImport({
    required this.runtime,
    required this.account,
    required this.targetFolderId,
  });
  final CloudDriveRuntime runtime;
  final CloudDriveAccount account;
  final String? targetFolderId;
  LibraryService get library => runtime.launch.library;
  int created = 0;
  int reused = 0;
  int failed = 0;
  int folders = 0;
  bool cancelled = false;
  bool running = false;
  bool persisted = false;
  String currentName = '';
  final failures = <CloudDriveEntry>[];
  final _seen = <String>{};
  final _visitedFolders = <String>{};
  CloudDriveDirectorySession? _reading;

  void cancel() {
    cancelled = true;
    _reading?.pause();
    notifyListeners();
  }

  Future<void> run(List<CloudDriveEntry> selection) async {
    running = true;
    notifyListeners();
    try {
      final ordered = List<CloudDriveEntry>.of(selection)
        ..sort((a, b) {
          final folder = (a.kind == CloudDriveEntryKind.folder ? 0 : 1)
              .compareTo(b.kind == CloudDriveEntryKind.folder ? 0 : 1);
          if (folder != 0) return folder;
          if (a.fileId == b.parentFileId) return -1;
          if (b.fileId == a.parentFileId) return 1;
          return (a.pathHint ?? '')
              .split('/')
              .length
              .compareTo((b.pathHint ?? '').split('/').length);
        });
      for (final entry in ordered) {
        if (cancelled) break;
        await _visit(entry, targetFolderId);
      }
    } finally {
      try {
        await library.commitCloudDriveReferences();
        persisted = true;
      } finally {
        running = false;
        notifyListeners();
      }
    }
  }

  Future<void> _visit(CloudDriveEntry entry, String? parentId) async {
    if (cancelled) return;
    final key = cloudDriveEntryKey(entry);
    if (!_seen.add(key)) return;
    currentName = entry.name;
    notifyListeners();
    try {
      if (entry.kind == CloudDriveEntryKind.folder) {
        if (!_visitedFolders.add(key)) return;
        final source = cloudDriveEntrySource(entry);
        final candidates = library.getContents(parentId);
        final matching = candidates
            .whereType<VideoCollection>()
            .where((v) => v.sourceRef?.cloudDrive?.sourceKey == key)
            .firstOrNull;
        String folderId;
        if (matching != null) {
          folderId = matching.id;
        } else {
          final names = candidates
              .map(
                (v) => v is VideoItem ? v.title : (v as VideoCollection).name,
              )
              .toSet();
          var name = entry.name;
          var serial = 2;
          while (names.contains(name)) {
            name = '${entry.name} (${serial++})';
          }
          final folder = await library.createCollection(
            name,
            parentId,
            sourceRef: source,
          );
          folderId = folder.id;
          folders++;
        }
        final directory = CloudDriveDirectorySession(
          runtime: runtime,
          account: account,
          directoryId: entry.providerId == 'baidu'
              ? entry.pathHint ?? entry.fileId
              : entry.fileId,
        );
        _reading = directory;
        List<CloudDriveEntry> children;
        try {
          await directory.finish();
          children = List.of(directory.entries);
        } finally {
          _reading = null;
          directory.release();
        }
        if (cancelled) return;
        children.sort(const CloudDriveViewOptions().compare);
        for (final child in children) {
          if (cancelled) break;
          await _visit(child, folderId);
        }
      } else if (entry.kind == CloudDriveEntryKind.video ||
          entry.kind == CloudDriveEntryKind.audio) {
        final exists = library
            .getVideosInFolder(parentId)
            .any((v) => v.sourceRef?.cloudDrive?.sourceKey == key);
        await library.upsertCloudDriveCard(
          source: cloudDriveEntrySource(entry),
          title: entry.name,
          openedFromFolderId: parentId,
          explicitPlacement: true,
          save: false,
          thumbnailRef: entry.thumbnailRef,
          durationMs: entry.durationMs ?? 0,
          mediaType: entry.kind == CloudDriveEntryKind.audio
              ? MediaType.audio
              : MediaType.video,
        );
        if (exists) {
          reused++;
        } else {
          created++;
        }
        if ((created + reused) % 20 == 0) {
          await library.commitCloudDriveReferences();
        }
      }
    } catch (_) {
      failed++;
      failures.add(entry);
    }
    notifyListeners();
  }
}
