// Community edition: executable downloader implementation removed.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../models/import_card_placement.dart';
import '../../models/download_import_context.dart';
import '../../services/library_service.dart';
import 'douyin_models.dart';
import 'douyin_transfer.dart';

enum DouyinTaskStatus {
  ready,
  waiting,
  queued,
  downloading,
  downloaded,
  importing,
  imported,
  failed,
  cancelled,
}

class DouyinDownloadTask {
  DouyinDownloadTask(this.video) : variant = video.variants.firstOrNull;
  DouyinVideo video;
  DouyinVideoVariant? variant;
  DouyinTaskStatus status = DouyinTaskStatus.ready;
  bool selected = true;
  int received = 0;
  int? total;
  double bytesPerSecond = 0;
  double? mergeProgress;
  String? error;
  String? filePath;
  String? targetFolderId;
  ImportPlacementRequest? importPlacement;
  DownloadImportContext? importContext;
  bool queueSelected = false;
  String? activityBatchId;
  String? libraryVideoId;
  Map<String, Map<String, String>> headers = {};
  bool get busy => [
    DouyinTaskStatus.queued,
    DouyinTaskStatus.downloading,
    DouyinTaskStatus.importing,
  ].contains(status);
  bool get canDownload =>
      !busy &&
      variant != null &&
      variant!.isCompleteSource &&
      filePath == null &&
      status != DouyinTaskStatus.imported;
  double? get progress =>
      mergeProgress ??
      (total != null && total! > 0 ? (received / total!).clamp(0, 1) : null);
}

/// Shared by download pages so a route change does not cancel a transfer.
/// On restart only metadata and completed file paths are restored. Expiring
/// media URLs and browser credentials are deliberately absent from the journal.
class DouyinDownloadController extends ChangeNotifier {
  DouyinDownloadController({
    Future<Directory> Function()? directoryResolver,
    DouyinTransfer Function()? transferFactory,
  }) : _directoryResolver = directoryResolver ?? _defaultDirectory,
       _transferFactory = transferFactory ?? DouyinTransfer.new,
       _customDirectory = directoryResolver != null;

  static final shared = DouyinDownloadController();
  final Future<Directory> Function() _directoryResolver;
  final DouyinTransfer Function() _transferFactory;
  final List<DouyinDownloadTask> tasks = [];

  final bool _customDirectory;

  bool _pumping = false;

  bool preparingQueue = false;
  bool autoRemoveAfterImport = false;
  String? storageWarning;
  Future<void> flush() async {}

  bool get hasActiveTasks =>
      _pumping || preparingQueue || tasks.any((task) => task.busy);
  List<DouyinDownloadTask> get selectedTasks =>
      tasks.where((task) => task.selected).toList();

  static Future<Directory> _defaultDirectory() async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  Future<void> init() async {}

  void addVideos(List<DouyinVideo> videos) {}

  void select(DouyinDownloadTask task, bool value) {}

  void selectAll(bool value) {}

  void setVariant(DouyinDownloadTask task, DouyinVideoVariant variant) {}

  Future<void> enqueue(
    List<DouyinDownloadTask> selection, {
    String? targetFolderId,
  }) async {
    throw UnsupportedError('开源版不提供媒体下载或网站提取');
  }

  /// Only an explicit start action authorizes these tasks to run. Adding new
  /// waiting tasks while another batch is downloading never starts those tasks.
  Future<void> start(
    List<DouyinDownloadTask> selection, {
    required Future<Map<String, String>> Function(Uri) headersFor,
    required LibraryService library,
    String? targetFolderId,
  }) async {
    throw UnsupportedError('开源版不提供媒体下载或网站提取');
  }

  Future<void> importTask(
    DouyinDownloadTask task,
    LibraryService library,
  ) async {
    throw UnsupportedError('开源版不提供媒体下载或网站提取');
  }

  void cancel(DouyinDownloadTask task) {}

  void remove(DouyinDownloadTask task) {}

  Future<void> prepareStorageMigration() async {}

  @override
  void dispose() {
    super.dispose();
  }
}
