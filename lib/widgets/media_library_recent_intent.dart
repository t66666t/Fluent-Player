import 'package:flutter/foundation.dart';

import '../models/library_activity.dart';
import '../services/library_service.dart';
import '../utils/app_toast.dart';

/// Cross-route request to open 最近添加 on a specific import batch.
class MediaLibraryRecentIntent {
  MediaLibraryRecentIntent._();

  static final ValueNotifier<String?> pendingBatchId = ValueNotifier<String?>(
    null,
  );

  static void viewBatch(String? batchId) {
    if (batchId == null || batchId.isEmpty) return;
    pendingBatchId.value = batchId;
  }

  static String? latestCommittedBatchId(LibraryService library) {
    if (library.importBatches.isEmpty) return null;
    final batches = List<ImportBatchRecord>.from(library.importBatches);
    batches.sort((a, b) {
      final byTime = b.startedAtMs.compareTo(a.startedAtMs);
      if (byTime != 0) return byTime;
      return b.id.compareTo(a.id);
    });
    return batches.first.id;
  }
}

/// Reuses the existing top toast. Skips when library.json has not landed so
/// the persistence failure notice stays the one users see.
void showLibraryImportAddedToast({
  required LibraryService library,
  required String message,
  String? batchId,
  Duration duration = const Duration(milliseconds: 1200),
  AppToastType type = AppToastType.info,
}) {
  if (library.hasPersistenceFailure) return;
  final resolved = (batchId != null && batchId.isNotEmpty)
      ? batchId
      : MediaLibraryRecentIntent.latestCommittedBatchId(library);
  AppToast.show(
    message,
    type: type,
    duration: duration,
    action: resolved == null
        ? null
        : AppToastAction(
            label: '查看',
            onPressed: () => MediaLibraryRecentIntent.viewBatch(resolved),
          ),
  );
}
