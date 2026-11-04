// Community edition: executable downloader implementation removed.
import '../../services/app_storage_service.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../models/import_card_placement.dart';
import '../../models/download_import_context.dart';
import '../../services/settings_service.dart';
import '../../services/library_service.dart';
import 'web_media_click_diagnostics.dart';
import 'web_media_download_service.dart';
import 'web_media_download_size.dart';
import 'web_media_resource.dart';
import 'web_media_download_target.dart';
import 'web_media_queue_settings.dart';
import 'web_media_queue_store.dart';
import 'web_media_transfer_snapshot.dart';
import 'web_media_task_network.dart';

export 'web_media_queue_settings.dart';
export 'web_media_transfer_snapshot.dart';
export 'web_media_task_network.dart';

enum WebMediaTaskStatus {
  pending,
  queued,
  resolving,
  downloading,
  postProcessing,
  pausing,
  paused,
  completed,
  exported,
  failed,
  cancelled,
}

enum WebMediaQueueFilter { all, waiting, active, paused, completed, failed }

bool webMediaQueueWaiting(WebMediaTaskStatus status) =>
    status == WebMediaTaskStatus.pending ||
    status == WebMediaTaskStatus.queued ||
    status == WebMediaTaskStatus.resolving;
bool webMediaQueueActive(WebMediaTaskStatus status) =>
    status == WebMediaTaskStatus.downloading ||
    status == WebMediaTaskStatus.postProcessing ||
    status == WebMediaTaskStatus.pausing;
bool webMediaQueueMatches(
  WebMediaTaskStatus status,
  WebMediaQueueFilter filter,
) => switch (filter) {
  WebMediaQueueFilter.all => true,
  WebMediaQueueFilter.waiting => webMediaQueueWaiting(status),
  WebMediaQueueFilter.active => webMediaQueueActive(status),
  WebMediaQueueFilter.paused => status == WebMediaTaskStatus.paused,
  WebMediaQueueFilter.completed =>
    status == WebMediaTaskStatus.completed ||
        status == WebMediaTaskStatus.exported,
  WebMediaQueueFilter.failed =>
    status == WebMediaTaskStatus.failed ||
        status == WebMediaTaskStatus.cancelled,
};

String webMediaQueueStatus(WebMediaTaskStatus status) => switch (status) {
  WebMediaTaskStatus.pending => '待下载',
  WebMediaTaskStatus.queued => '排队中',
  WebMediaTaskStatus.resolving => '正在准备下载',
  WebMediaTaskStatus.downloading => '下载中',
  WebMediaTaskStatus.postProcessing => '合并 / 保存中',
  WebMediaTaskStatus.pausing => '正在暂停',
  WebMediaTaskStatus.paused => '已暂停',
  WebMediaTaskStatus.completed => '已完成',
  WebMediaTaskStatus.exported => '已加入媒体库',
  WebMediaTaskStatus.failed => '失败',
  WebMediaTaskStatus.cancelled => '已取消',
};

/// Fine-grained step inside [WebMediaTaskStatus]. Scheduling still uses the
/// status alone; the phase only explains what the task is doing right now.
enum WebMediaTaskPhase {
  waitingResources,
  parsingManifest,
  queued,
  downloading,
  merging,
  validating,
  waitingToSave,
  saving,
  completed,
}

String webMediaTaskPhaseLabel(WebMediaTaskPhase phase) => switch (phase) {
  WebMediaTaskPhase.waitingResources => '等待播放资源',
  WebMediaTaskPhase.parsingManifest => '解析清单',
  WebMediaTaskPhase.queued => '排队',
  WebMediaTaskPhase.downloading => '下载',
  WebMediaTaskPhase.merging => '合并',
  WebMediaTaskPhase.validating => '校验',
  WebMediaTaskPhase.waitingToSave => '等待入库',
  WebMediaTaskPhase.saving => '入库',
  WebMediaTaskPhase.completed => '完成',
};

/// Distinguishable reasons for a task that is not moving. Codes never claim a
/// cause the code cannot observe: only explicit evidence sets them.
enum WebMediaTaskReason {
  none,
  awaitingResources,
  awaitingNetwork,
  retrying,
  loginRequired,
  unsupported,
}

String webMediaTaskReasonLabel(WebMediaTaskReason reason) => switch (reason) {
  WebMediaTaskReason.none => '',
  WebMediaTaskReason.awaitingResources => '等待网页提供媒体资源',
  WebMediaTaskReason.awaitingNetwork => '等待网络恢复',
  WebMediaTaskReason.retrying => '连接中断，正在重试',
  WebMediaTaskReason.loginRequired => '需要重新登录网页',
  WebMediaTaskReason.unsupported => '当前资源类型暂不支持',
};

/// Classifies a download failure only when its own message proves the cause.
WebMediaTaskReason webMediaReasonForError(Object error) {
  final text = error is WebMediaDownloadException ? error.message : '$error';
  if (text.contains('登录') || text.contains('401') || text.contains('403')) {
    return WebMediaTaskReason.loginRequired;
  }
  if (text.contains('直播') ||
      text.contains('DRM') ||
      text.contains('受保护') ||
      text.contains('需要网站播放器') ||
      text.contains('分段数量超出')) {
    return WebMediaTaskReason.unsupported;
  }
  if (error is SocketException ||
      error is TimeoutException ||
      text.contains('网络') ||
      text.contains('连接') ||
      text.contains('超时')) {
    return WebMediaTaskReason.awaitingNetwork;
  }
  return WebMediaTaskReason.none;
}

class WebMediaNativeQueueTask {
  WebMediaNativeQueueTask({
    required this.resource,
    this.audioCompanion,
    this.targetFolderId,
    this.variants = const [],
    this.validateAudio = false,
    this.requireVideo = false,
    this.identity,
    ImportPlacementRequest? importPlacement,
    String? id,
  }) : id = id ?? const Uuid().v4(),
       importPlacement =
           importPlacement ??
           SettingsService().captureImportPlacement(
             ImportCardFeature.webMedia,
             openedFromFolderId: targetFolderId,
           );
  final String id;
  WebMediaResource resource;
  WebMediaResource? audioCompanion;
  final String? targetFolderId;
  final ImportPlacementRequest importPlacement;
  DownloadImportContext? downloadContext;
  bool restoredFromJournal = false;
  final String? identity;
  List<WebMediaResource> variants;
  final bool validateAudio;
  final bool requireVideo;
  final Set<String> capturedKeys = {};
  bool allowVideoOnly = false;
  bool inspecting = false;
  bool automatic = false;
  bool awaitingResources = false;
  bool removed = false;
  int automaticGeneration = 0;
  WebMediaDownloadTarget? target;
  Future<List<WebMediaResource>> Function(WebMediaDownloadTarget)? resolver;
  Future<List<WebMediaResource>> Function(
    WebMediaDownloadTarget,
    WebMediaTaskNetwork,
  )?
  networkResolver;
  Timer? fallbackTimer;
  Timer? waitTimer;
  Timer? reconnectTimer;
  int automaticReconnects = 0;
  int stalledReconnects = 0;
  int reconnectHighWater = 0;
  int? reconnectConnectionLimit;
  bool fallbackStarted = false;
  String? resolvedTitle;
  bool preparingAutomatic = false;
  bool runAllowed = false;
  WebMediaTaskNetwork network = WebMediaTaskNetwork.followSettings;
  Future<void> networkUpdates = Future.value();
  bool userPaused = false;
  bool requeueAfterPause = false;
  int runGeneration = 0;
  int queueOrder = 0;
  int startOrder = 0;
  final updates = ValueNotifier<int>(0);
  WebMediaTransferSnapshot? snapshot;
  WebMediaSpeedMeter? speedMeter;
  double? bytesPerSecond;
  final List<double> speedHistory = [];
  bool meterSeeded = false;
  Duration? get remaining =>
      totalBytes != null &&
          bytesPerSecond != null &&
          bytesPerSecond! > 0 &&
          totalBytes! > downloadedBytes
      ? Duration(
          seconds: ((totalBytes! - downloadedBytes) / bytesPerSecond!).ceil(),
        )
      : null;
  bool get canDownload =>
      output != null ||
      (automatic
          ? !awaitingResources &&
                (!requireVideo || !resource.isAudio) &&
                (!resource.requiresAudio ||
                    resource.metadata.hasAudio == true ||
                    audioCompanion != null ||
                    allowVideoOnly)
          : !validateAudio ||
                (resource.metadata.state == WebMediaProbeState.complete &&
                    (!requireVideo || resource.metadata.hasVideo == true) &&
                    (resource.isAudio ||
                        resource.metadata.hasAudio == true ||
                        _hasCompleteAudio ||
                        allowVideoOnly)));
  bool get _hasCompleteAudio {
    final audio = audioCompanion;
    return audio != null &&
        audio.metadata.state == WebMediaProbeState.complete &&
        audio.metadata.hasAudio == true &&
        audio.sourcePage == resource.sourcePage &&
        audio.playerIds.any(resource.playerIds.contains) &&
        (resource.audioGroup == null ||
            resource.audioGroup == audio.audioGroup) &&
        audio.duration != null &&
        resource.duration != null &&
        (audio.duration! - resource.duration!).inMilliseconds.abs() <= 2000;
  }

  List<WebMediaResource> get videoOptions =>
      variants.where((r) => !r.isAudio).toList();
  List<WebMediaResource> get audioOptions =>
      variants.where((r) => r.isAudio).toList();
  final WebMediaResumeState resume = WebMediaResumeState();
  WebMediaTaskStatus status = WebMediaTaskStatus.pending;
  double? progress;
  int downloadedBytes = 0;
  int? totalBytes;
  String? speed;
  WebMediaTransferDiagnostics? diagnostics;
  String? message;

  /// Why the task is not progressing, when the cause is actually known.
  WebMediaTaskReason reason = WebMediaTaskReason.none;

  /// Narrower stage than [status]; null falls back to the status label.
  WebMediaTaskPhase? phase;

  /// In-memory click trace from the webpage; attached once and kept for the
  /// copy-diagnostics entry of this task.
  WebMediaClickDiagnostics? clickTrace;
  File? output;
  String? libraryId;

  /// The last durable import; libraryId can also represent an unfinished save.
  String? importedLibraryId;
  File? subtitle;
  WebMediaDownloadService? transfer;
  Future<void>? operation;
  Future<WebMediaResource?> Function(WebMediaResource)? refreshResource;
  Future<WebMediaResource> Function(WebMediaResource)? prepareResource;
  String? customTitle;
  String get title => customTitle ?? resource.title;

  /// Stable user-facing stage. Terminal and paused states win over the finer
  /// phase so a paused task never reads as "下载".
  String get phaseLabel {
    switch (status) {
      case WebMediaTaskStatus.paused:
      case WebMediaTaskStatus.pausing:
      case WebMediaTaskStatus.failed:
      case WebMediaTaskStatus.cancelled:
      case WebMediaTaskStatus.completed:
      case WebMediaTaskStatus.exported:
        return webMediaQueueStatus(status);
      case WebMediaTaskStatus.pending:
      case WebMediaTaskStatus.queued:
      case WebMediaTaskStatus.resolving:
      case WebMediaTaskStatus.downloading:
      case WebMediaTaskStatus.postProcessing:
        return phase == null
            ? webMediaQueueStatus(status)
            : webMediaTaskPhaseLabel(phase!);
    }
  }

  String get reasonLabel => webMediaTaskReasonLabel(reason);
  bool get canPause =>
      automatic && status == WebMediaTaskStatus.resolving ||
      status == WebMediaTaskStatus.downloading ||
      status == WebMediaTaskStatus.queued ||
      status == WebMediaTaskStatus.postProcessing &&
          phase != WebMediaTaskPhase.saving;
  bool get canStart =>
      status == WebMediaTaskStatus.pending ||
      status == WebMediaTaskStatus.paused ||
      status == WebMediaTaskStatus.failed ||
      status == WebMediaTaskStatus.cancelled;
  bool get canResumeBytes =>
      audioCompanion == null &&
      resource.kind != WebMediaKind.hls &&
      resource.kind != WebMediaKind.dash;
  WebMediaDownloadSize? get size {
    if (totalBytes != null && totalBytes! > 0) {
      return WebMediaDownloadSize(totalBytes!);
    }
    final video = resource.metadata.byteSize;
    final audio = audioCompanion?.metadata.byteSize;
    if (video == null || (audioCompanion != null && audio == null)) return null;
    return WebMediaDownloadSize(
      video + (audio ?? 0),
      estimated:
          resource.metadata.sizeEstimated ||
          (audioCompanion?.metadata.sizeEstimated ?? false),
    );
  }
}

class WebMediaDiscoveryTask {
  WebMediaDiscoveryTask(
    this.target, {
    this.targetFolderId,
    String? id,
    ImportPlacementRequest? importPlacement,
  }) : id = id ?? const Uuid().v4(),
       importPlacement =
           importPlacement ??
           SettingsService().captureImportPlacement(
             ImportCardFeature.webMedia,
             openedFromFolderId: targetFolderId,
           );
  final String id;
  final WebMediaDownloadTarget target;
  final String? targetFolderId;
  final ImportPlacementRequest importPlacement;
  String? customTitle;
  String get title => customTitle ?? target.title ?? '网页视频';
  WebMediaTaskStatus status = WebMediaTaskStatus.resolving;
  String message = '正在等待网页媒体资源，请让这个视频开始播放';
  Future<void> Function()? retry;
}

class _NativeProbe {
  _NativeProbe(this.task, this.candidate, this.epoch);
  final WebMediaNativeQueueTask task;
  final WebMediaResource candidate;
  final int epoch;
  final result = Completer<WebMediaResource?>();
  WebMediaDownloadService? service;
  bool _closed = false;

  void complete(WebMediaResource? value) {
    if (!result.isCompleted) result.complete(value);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    service?.close();
  }
}

/// One browser-owned queue for captured and automatically resolved media.
class WebMediaDownloadQueue extends ChangeNotifier {
  WebMediaDownloadQueue(
    Object owner, {
    WebMediaDownloadService Function()? transferFactory,
    Future<Directory> Function()? directoryProvider,
    WebMediaQueueStore Function(Directory)? storeFactory,
  }) : _transferFactory = transferFactory ?? WebMediaDownloadService.new,
       _directoryProvider =
           directoryProvider ??
           (() async => (await AppStorageService.instance.downloadRecord(
             'web',
             'index.json',
             'web_media_downloads',
             legacyRelative: 'queue_v2/index.json',
           )).parent),
       _storeFactory =
           storeFactory ??
           (directoryProvider == null
               ? WebMediaQueueStore.atRoot
               : WebMediaQueueStore.new),
       _unifiedStorage = directoryProvider == null && storeFactory == null;

  static final _communityQueues = Expando<WebMediaDownloadQueue>();
  static WebMediaDownloadQueue forLibrary(LibraryService library) =>
      _communityQueues[library] ??= WebMediaDownloadQueue(library);

  /// Observe already-loaded preferences without opening/restarting a queue.
  static WebMediaQueueSettings? settingsForLibrary(LibraryService library) {
    return null;
  }

  static Future<void> flushPreferencesForTrial(LibraryService library) async {}

  static Future<void> reloadPreferencesForTrial(LibraryService library) async {}

  @visibleForTesting
  static void installForLibraryForTesting(
    LibraryService library,
    WebMediaDownloadQueue queue,
  ) {}

  final WebMediaDownloadService Function() _transferFactory;
  final Future<Directory> Function() _directoryProvider;
  final WebMediaQueueStore Function(Directory) _storeFactory;
  final bool _unifiedStorage;

  final List<WebMediaNativeQueueTask> nativeTasks = [];
  final List<WebMediaDiscoveryTask> discoveries = [];

  WebMediaQueueSettings settings = const WebMediaQueueSettings();
  int get connections => settings.connections;
  String? settingsError;
  String? persistenceError;
  bool queuePaused = false;

  final _networkTasks = <WebMediaNativeQueueTask>{};

  final transferUpdates = ValueNotifier<int>(0);

  double get totalBytesPerSecond =>
      _networkTasks.fold(0, (n, t) => n + (t.bytesPerSecond ?? 0));
  int get runningCount => _networkTasks.length;

  Future<void> loadSettings() async {}

  Future<void> setConnections(int value) async {}

  Future<void> setTaskNetwork(
    WebMediaNativeQueueTask task,
    WebMediaTaskNetwork network,
  ) async {}

  Future<void> updateSettings(WebMediaQueueSettings value) async {}

  Future<void> renameNative(WebMediaNativeQueueTask task, String name) async {}

  Future<void> renameDiscovery(WebMediaDiscoveryTask task, String name) async {}

  Future<void> replaceNativeUrl(
    WebMediaNativeQueueTask task,
    String url,
  ) async {}

  Future<void> refreshNative(WebMediaNativeQueueTask task) async {}

  Future<void> persistNative() async {}

  int count(WebMediaQueueFilter filter) {
    return 0;
  }

  int get badgeCount =>
      count(WebMediaQueueFilter.waiting) + count(WebMediaQueueFilter.active);

  void discoveryMessage(String id, String message) {}

  void removeDiscovery(WebMediaDiscoveryTask task) {}

  Future<String> addTarget(
    WebMediaDownloadTarget target, {
    LibraryService? library,
    String? targetFolderId,
    Future<WebMediaResource?> Function(WebMediaResource)? refreshResource,
    Future<WebMediaResource> Function(WebMediaResource)? prepareResource,
  }) async {
    return '';
  }

  Future<void> inspectNative(WebMediaNativeQueueTask task) async {}

  void selectNative(WebMediaNativeQueueTask task, WebMediaResource resource) {}

  void selectNativeAudio(
    WebMediaNativeQueueTask task,
    WebMediaResource? audio, {
    bool onlyPicture = false,
  }) {}

  WebMediaNativeQueueTask addResource(
    WebMediaResource resource,
    LibraryService library, {
    WebMediaResource? audioCompanion,
    String? targetFolderId,
    Future<WebMediaResource?> Function(WebMediaResource)? refreshResource,
  }) {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  void startNative(WebMediaNativeQueueTask task) {
    throw UnsupportedError('开源版不提供媒体下载或网站提取');
  }

  Future<void> pauseNative(
    WebMediaNativeQueueTask task, {
    bool requeue = false,
  }) async {}

  Future<void> cancelNative(WebMediaNativeQueueTask task) async {}

  Future<void> restartNative(WebMediaNativeQueueTask task) async {}

  void moveWaiting(WebMediaNativeQueueTask task, int direction) {}

  Future<void> retryFailed() async {}

  Future<void> removeNative(WebMediaNativeQueueTask task) async {}

  /// Freeze only the first start; later priority changes keep acquisition order.
  Future<void> startTasks(Iterable<String> ids) async {
    throw UnsupportedError('开源版不提供媒体下载或网站提取');
  }

  Future<void> startWaiting() async {
    throw UnsupportedError('开源版不提供媒体下载或网站提取');
  }

  Future<void> pauseAll() async {}

  Future<void> shutdown() async {}

  @override
  void dispose() {
    super.dispose();
  }
}
