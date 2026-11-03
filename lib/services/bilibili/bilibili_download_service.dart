// Community edition: executable downloader implementation removed.
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'bilibili_audio_selection.dart';
export 'bilibili_audio_selection.dart' show BilibiliAudioPreference;
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_streaming_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_stream_card.dart';
import 'package:video_player_app/services/bilibili/download_manager.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_materialization_service.dart';
import 'package:video_player_app/services/temporary_storage_cleanup_models.dart';
import 'package:video_player_app/services/network/network_http.dart';

class _RetryPauseRequested implements Exception {
  const _RetryPauseRequested();
}

class BilibiliDanmakuUpdateException implements Exception {
  final String message;

  const BilibiliDanmakuUpdateException(this.message);

  @override
  String toString() => message;
}

/// Outcome of one silent danmaku refresh. Callers record cooldowns from this
/// and leave the existing sidecar untouched unless [updated].
enum BilibiliDanmakuAutoUpdateStatus {
  updated,
  unchanged,
  skipped,
  durationMismatch,
  failedNetwork,
  failedHard,
}

class BilibiliDanmakuAutoUpdateResult {
  final BilibiliDanmakuAutoUpdateStatus status;

  const BilibiliDanmakuAutoUpdateResult(this.status);

  bool get checkedSuccessfully =>
      status == BilibiliDanmakuAutoUpdateStatus.updated ||
      status == BilibiliDanmakuAutoUpdateStatus.unchanged;

  /// Video is gone, empty, or its timeline no longer matches the local file.
  bool get hardFailure =>
      status == BilibiliDanmakuAutoUpdateStatus.durationMismatch ||
      status == BilibiliDanmakuAutoUpdateStatus.failedHard;
}

/// Local duration and the online page duration differ enough that new
/// comments would land on the wrong frames. A few seconds of container
/// rounding is ignored; [onlineDurationSeconds] is Bilibili's page length.
bool bilibiliDanmakuTimelineDiffers(
  int localDurationMs,
  int onlineDurationSeconds,
) {
  if (localDurationMs <= 0 || onlineDurationSeconds <= 0) return false;
  return (localDurationMs - onlineDurationSeconds * 1000).abs() > 5000;
}

class BilibiliDownloadService extends ChangeNotifier {
  final BilibiliApiService apiService;

  /// Public-read client (short links and the like), created on first use.
  BilibiliPublicApiService? _publicApi;
  BilibiliPublicApiService get publicApi =>
      _publicApi ??= BilibiliPublicApiService();
  late final BilibiliStreamingService streamingService;
  late final MediaMaterializationService materializationService;

  late BilibiliDownloadManager _downloadManager;

  bool _settingsLoaded = false;
  bool get settingsLoaded => _settingsLoaded;
  Future<void> flushPreferencesForTrial() async {}

  Future<void> reloadPreferencesForTrial() async {}

  List<String> _cachedTaskIds = const [];

  int _listStructureRevision = 0;

  // State
  List<BilibiliDownloadTask> tasks = [];

  int maxConcurrentDownloads = 1;
  int maxConnectionsPerVideo = 2;
  int preferredQuality = 116;
  BilibiliAudioPreference preferredAudioQuality =
      BilibiliAudioPreference.bestAvailable;
  String preferredSubtitleLang = "zh";
  bool preferAiSubtitles = false;
  bool downloadDanmaku = true;
  bool autoDeleteTaskAfterImport = false;
  bool autoDeleteOnlineTaskAfterImport = false;
  bool keepScreenAwakeDuringProcessing = false;
  String? customDownloadPath;

  LibraryService? libraryService;

  int _taskCount = 0;
  int _selectedEpisodeCount = 0;
  BilibiliSelectionSummary _selectionSummary = const BilibiliSelectionSummary();
  int _processingEpisodeCount = 0;

  bool isParsing = false;
  String? parsingStatus;

  BilibiliDownloadService({
    BilibiliApiService? apiService,
    BilibiliPublicApiService? publicApi,
    NetworkSettingsService? networkSettings,
  }) : apiService = apiService ?? BilibiliApiService(),
       _publicApi = publicApi {
    _downloadManager = BilibiliDownloadManager(this.apiService);
    streamingService = BilibiliStreamingService(
      this.apiService,
      networkSettings: networkSettings,
    );
    materializationService = MediaMaterializationService(this.apiService);
  }

  /// Downloads, converts and replaces a library item's danmaku sidecar.
  ///
  /// The converted document is built in memory first and the stable sidecar is
  /// then overwritten directly. No backup or temporary sidecar is created, so
  /// interruption cannot leave an extra file and the same path remains safely
  /// retryable on the next attempt.
  Future<void> updateDanmakuForVideo(
    VideoItem item,
    LibraryService library,
  ) async {}

  /// Silent refresh for the video that just started playing.
  ///
  /// Local files stay on the cid saved at download, and are left alone when
  /// the online page length no longer matches. Online playback follows the
  /// current part, including a replaced cid. Failures never clear the sidecar.
  Future<BilibiliDanmakuAutoUpdateResult> autoUpdateDanmakuForVideo(
    VideoItem item,
    LibraryService library,
  ) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  Future<BilibiliDanmakuAutoUpdateResult> autoUpdateDanmakuForCachedVideo(
    VideoItem item,
    LibraryService library,
  ) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  @override
  void notifyListeners() {}

  int _sanitizeMaxConnectionsPerVideo(int value) {
    return 0;
  }

  int get effectiveMaxConnectionsPerVideo {
    // Keep newly-created media connections within an eight-connection budget.
    // Existing task concurrency remains respected, and high task concurrency
    // automatically turns per-video acceleration down to one connection.
    final perTaskBudget = 8 ~/ maxConcurrentDownloads.clamp(1, 10);
    return _sanitizeMaxConnectionsPerVideo(
      maxConnectionsPerVideo.clamp(1, perTaskBudget.clamp(1, 4)),
    );
  }

  List<String> get taskIds => _cachedTaskIds;

  List<String> taskIdsForMode(bool streaming) {
    return [];
  }

  List<BilibiliDownloadTask> tasksForMode(bool streaming) {
    return [];
  }

  /// Without a selection, queue actions target this mode's current list.
  /// A caller-supplied snapshot never changes checkboxes or includes another mode.
  List<BilibiliDownloadEpisode> actionScopeForMode(
    bool streaming, {
    Iterable<BilibiliDownloadEpisode>? episodes,
  }) {
    return [];
  }

  BilibiliSelectionSummary selectionSummaryForMode(bool streaming) {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  int get listStructureRevision => _listStructureRevision;

  int taskRevision(String taskId) {
    return 0;
  }

  int episodeRevision(BilibiliDownloadEpisode episode) {
    return 0;
  }

  bool isStreamingImporting(BilibiliDownloadEpisode episode) {
    return false;
  }

  String episodeKey(BilibiliDownloadEpisode episode) {
    return '';
  }

  BilibiliDownloadTask? getTaskById(String taskId) {
    return null;
  }

  @visibleForTesting
  void replaceTasksForTesting(List<BilibiliDownloadTask> replacement) {}

  @visibleForTesting
  void markEpisodeProgressChangedForTesting(BilibiliDownloadEpisode episode) {}

  @visibleForTesting
  void setRunningEpisodeOperationForTesting(
    BilibiliDownloadEpisode episode,
    Future<void>? operation,
  ) {}

  @visibleForTesting
  void setEpisodeImportingForTesting(
    BilibiliDownloadEpisode episode,
    bool importing,
  ) {}

  void setTaskExpanded(BilibiliDownloadTask task, bool expanded) {}

  /// Moves one top-level Bilibili task to an insertion boundary.
  ///
  /// [insertionIndex] is in the unmodified task list and may range from zero
  /// (before the first task) through [tasks.length] (after the last task).
  /// Keeping the conversion here gives every UI the same stable semantics and
  /// ensures collections and multipart videos always move as one unit.
  bool moveTaskToInsertionIndex(String taskId, int insertionIndex) {
    return false;
  }

  void setTaskSelected(BilibiliDownloadTask task, bool selected) {}

  void setVideoSelected(
    BilibiliDownloadTask task,
    BilibiliVideoItem video,
    bool selected,
  ) {}

  void setEpisodeSelected(
    BilibiliDownloadTask task,
    BilibiliVideoItem video,
    BilibiliDownloadEpisode episode,
    bool selected,
  ) {}

  void setEpisodeVideoQuality(
    BilibiliDownloadTask task,
    BilibiliDownloadEpisode episode,
    StreamItem? quality,
  ) {}

  void setEpisodeSubtitle(
    BilibiliDownloadTask task,
    BilibiliDownloadEpisode episode,
    BilibiliSubtitle? subtitle,
  ) {}

  bool canSelectEpisodeAudio(BilibiliDownloadEpisode episode) {
    return false;
  }

  void setEpisodeAudioQuality(
    BilibiliDownloadTask task,
    BilibiliDownloadEpisode episode,
    StreamItem? quality,
  ) {}

  Future<void> init() async {}

  /// Remembers the library folder that was open when the download page opened.
  /// Auto-import uses it when placement follows the current folder.
  void rememberImportFolder(String? folderId) {}

  @visibleForTesting
  Future<void> loadSettingsForTesting() async {}

  Future<void> saveSettings() async {}

  Future<void> updateSettings(
    int maxConcurrent,
    int quality,
    String subLang,
    bool preferAi,
    bool autoDelete, {
    String? customPath,
    int? videoConnections,
    bool? shouldDownloadDanmaku,
    BilibiliAudioPreference? audioQuality,
  }) async {}

  Future<void> updateStreamingSettings({
    required String subtitleLanguage,
    required bool preferAi,
    required bool autoDelete,
  }) async {}

  Future<void> setDownloadDanmaku(bool value) async {}

  bool get supportsProcessingKeepAwakeToggle =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  bool get hasProcessingEpisodes {
    return _processingEpisodeCount > 0;
  }

  /// Updates completed tasks after exact output deletion in storage management.
  Future<void> forgetStorageFiles(List<String> paths) async {}

  int get taskCount => _taskCount;

  int get selectedEpisodeCount => _selectedEpisodeCount;

  BilibiliSelectionSummary get selectionSummary => _selectionSummary;

  bool get isProcessingKeepAwakeActive =>
      supportsProcessingKeepAwakeToggle &&
      keepScreenAwakeDuringProcessing &&
      hasProcessingEpisodes;

  Future<bool> toggleKeepScreenAwakeDuringProcessing() async {
    return false;
  }

  Future<void> saveTasks({
    BilibiliDownloadTask? task,
    BilibiliDownloadEpisode? episode,
  }) async {}

  void scheduleSaveTasks({
    bool notifyNow = false,
    BilibiliDownloadTask? task,
    BilibiliDownloadEpisode? episode,
  }) {}

  @visibleForTesting
  int refreshDirtyTaskSnapshotsForTesting() {
    return 0;
  }

  @visibleForTesting
  Map<String, dynamic>? taskSnapshotForTesting(String taskId) {
    return null;
  }

  Future<void> shutdown() async {}

  @override
  void dispose() {
    super.dispose();
  }

  // --- Parsing ---

  /// [preferredPage] (1-based) keeps only that part selected when the input
  /// resolves to a single multi-part video; other tasks are unaffected.
  Future<bool> parseVideo(
    String rawInput, {
    Future<bool> Function(String title)? onConfirmCollection,
    bool asStreamingImport = false,
    int? preferredPage,
  }) async {
    return false;
  }

  Future<BilibiliDownloadTask?> parseSingleLine(
    String line, {
    Future<bool> Function(String title)? onConfirmCollection,
  }) async {
    return null;
  }

  // --- Sequential Export Logic ---

  Future<int> ensureEpisodeImported(BilibiliDownloadEpisode episode) async {
    return 0;
  }

  bool isEpisodeImporting(BilibiliDownloadEpisode episode) {
    return false;
  }

  @visibleForTesting
  void freezeImportBatchForTesting(List<BilibiliDownloadEpisode> episodes) {}

  // Batch Pause
  Future<void> pauseSelected({
    Iterable<BilibiliDownloadEpisode>? episodes,
  }) async {}

  // --- Info Fetching ---

  Future<void> fetchAllInfos() async {}

  Future<void> fetchEpisodeInfo(
    BilibiliDownloadEpisode episode, {
    bool preserveRunningState = false,
  }) async {}

  Future<void> refreshEpisodeInfo(BilibiliDownloadEpisode episode) async {}

  // --- Download Logic ---

  Future<void> startDownloadSelected({
    Iterable<BilibiliDownloadEpisode>? episodes,
  }) async {
    throw UnsupportedError('开源版不提供媒体下载或网站提取');
  }

  Future<void> startSingleDownload(
    BilibiliDownloadEpisode ep, {
    bool toTop = false,
  }) async {
    throw UnsupportedError('开源版不提供媒体下载或网站提取');
  }

  Future<void> pauseDownload(BilibiliDownloadEpisode ep) async {}

  void processQueue() {}

  // --- Management ---

  Future<TemporaryStorageCategoryReport> buildTemporaryStorageReport() async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  Future<void> clearTemporaryStorageArtifacts() async {}

  void removeSelected({
    bool? streaming,
    Iterable<BilibiliDownloadEpisode>? episodes,
  }) {}

  Future<void> removeCommittedEpisodeRecord(
    BilibiliDownloadEpisode ep,
    BilibiliDownloadTask task,
  ) async {}

  Future<void> clearImportedRecordsForMode(
    bool streaming, {
    Iterable<BilibiliDownloadEpisode>? episodes,
  }) async {}

  Future<void> removeEpisode(
    BilibiliDownloadEpisode ep,
    BilibiliDownloadTask task,
  ) async {}

  void deleteAllTasks() {}

  void selectAll() {}

  void deleteAllTasksForMode(bool streaming) {}

  void clearSelection() {}

  void selectAllForMode(bool streaming) {}

  void applyQualitySettingsToPendingTasks({
    bool updateQuality = true,
    bool updateAudio = false,
  }) {}

  // --- Helper Methods for Library Import ---

  // --- Import ---

  /// Single entry for Bilibili online cards (`MediaSourceKind.bilibiliStream`),
  /// keyed by BV id + part number.
  ///
  /// With [reuseExisting] a live card for the same BV and part is returned as
  /// is (no request, no new card); concurrent calls for the same part share one
  /// creation. Otherwise, or when none exists, a new card is built: player
  /// metadata, cover, subtitles, danmaku and preview frames, then it is added
  /// to the library under the folder returned by [resolveParentId].
  ///
  /// [episode] is the parse-list row being exported, if any; it receives the
  /// subtitle/danmaku state exactly as before. [onStage] reports the coarse
  /// stages with their progress weight inside one card (0.12 / 0.48 / 0.86).
  /// [deferPlayerData] saves the playable card first. Its durable pending data
  /// can then be completed by [resumePendingStreamCardData].
  Future<BilibiliStreamCardResult> obtainStreamCard(
    LibraryService library, {
    required BilibiliVideoInfo videoInfo,
    required BilibiliPage page,
    required bool reuseExisting,
    BilibiliDownloadEpisode? episode,
    String? originalSourceValue,
    String? activityBatchId,
    Future<String?> Function()? resolveParentId,
    BilibiliStreamCardDirectories? directories,
    void Function(String status, double weight)? onStage,
    bool deferPlayerData = false,
  }) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  /// Live (not recycled) online card for [bvid] + [page], or null.
  VideoItem? findStreamCard(
    LibraryService library, {
    required String bvid,
    required BilibiliPage page,
  }) {
    return null;
  }

  /// Resumes saved imports even when their parse-list task was auto-deleted or
  /// the app exited before the optional files arrived. At most two cards load
  /// at once; a large multi-part import must not flood the network.
  void resumePendingStreamCardData(LibraryService library) {}

  @visibleForTesting
  Future<void> waitForPendingStreamCardData() async {}

  /// Episode-list entries for the parts of a multi-part video that are not
  /// watched yet: watch-only cards holding only what the video info already
  /// says (title, part, duration). Nothing is requested and no file is
  /// written until a part is switched to ([completeWatchPart]).
  Future<List<VideoItem>> addWatchParts(
    LibraryService library, {
    required BilibiliVideoInfo videoInfo,
    required Iterable<BilibiliPage> pages,
  }) async {
    return [];
  }

  /// [addWatchParts] for parts of several videos at once, in their order
  /// (parts without a BV or cid are skipped).
  Future<List<VideoItem>> addWatchEntries(
    LibraryService library,
    Iterable<(BilibiliVideoInfo, BilibiliPage)> parts,
  ) async {
    return [];
  }

  /// Whether [itemId] is still waiting for its player data.
  bool isWatchPlaceholder(String itemId) {
    return false;
  }

  /// Downloads the cover of the watch part [itemId] that has none yet to the
  /// file its completion writes, so the playback page opened next shows it
  /// from its first frame. Best effort: failures leave the entry as it was.
  Future<void> prefetchWatchCover(
    LibraryService library,
    String itemId,
  ) async {}

  /// Whether [itemId] is an episode-list entry still without player data.
  bool isPendingWatchPart(String itemId) {
    return false;
  }

  /// Gives an episode-list entry or deferred online import its player data,
  /// in place. Saved imports can be reconstructed without the parse task.
  /// Returns false when [itemId] is no such entry or the requests failed
  /// (it stays pending and can be tried again). If the entry was removed in
  /// the meantime, whatever was written is removed too.
  Future<bool> completeWatchPart(LibraryService library, String itemId) async {
    return false;
  }

  /// Watch-only entry of the in-app Bilibili pages: the card that plays
  /// [bvid] part [page] without adding anything to the media library.
  ///
  /// A live library card for the same BV + part is returned as is, and so is
  /// a watch-only card that is still alive (for example in the mini player).
  /// Otherwise a new watch-only card is built with the same player data as a
  /// library card and registered through [LibraryService.addTransientVideo];
  /// concurrent calls for the same part share one creation.
  ///
  /// With [deferPlayerData] the card is ready as soon as the video info is:
  /// a new card holds only what the info says, like an episode-list entry
  /// ([addWatchParts]), and an entry still without player data is returned
  /// as is. Its cover, subtitles, danmaku and chapters come from
  /// [completeWatchPart] once it plays, so they never hold up playback.
  Future<BilibiliStreamCardResult> obtainWatchCard(
    LibraryService library, {
    required String bvid,
    required int page,
    BilibiliVideoInfo? videoInfo,
    bool deferPlayerData = false,
  }) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  /// Entry for the in-app Bilibili pages (search / video detail): makes sure
  /// online cards exist for [pages] (1-based part numbers) of [bvid], reusing
  /// any live card for the same BV + part.
  ///
  /// New cards go to the default import location of online cards, or to
  /// [targetFolderId] (null = library root) when [useDefaultLocation] is
  /// false. Parts of a multi-part video stay in one folder: an existing sibling
  /// card's folder is used, otherwise a folder named after the video is
  /// created like the parse-list export does. A failing part is skipped and
  /// reported in [BilibiliStreamCardBatch.failedPages]; when no requested part
  /// is available at all the first error is rethrown.
  Future<BilibiliStreamCardBatch> obtainStreamCardsForVideo(
    LibraryService library, {
    required String bvid,
    required List<int> pages,
    BilibiliVideoInfo? videoInfo,
    bool useDefaultLocation = true,
    String? targetFolderId,
  }) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  Future<int> importStreamingToLibrary(
    LibraryService library, {
    BilibiliDownloadEpisode? episode,
    Iterable<BilibiliDownloadEpisode>? episodes,
    String? targetFolderId,
    bool folderExplicit = false,
  }) async {
    return 0;
  }

  /// Clipboard online-card import: put the same task on the Bilibili online
  /// parse list first, then export it so both surfaces share live progress.
  /// Same BV/url is always added again; only the identical list node is skipped.
  Future<int> importParsedStreamingTaskToLibrary(
    LibraryService library,
    BilibiliDownloadTask parsedTask, {
    String? targetFolderId,
    bool folderExplicit = false,
    bool Function()? shouldContinue,
  }) async {
    return 0;
  }

  /// Recover links before local locators become logical stream locators.
  Future<void> restoreDownloadedCardLinks(LibraryService library) async {}

  String? findDownloadedLibraryCardId(
    LibraryService library,
    BilibiliDownloadEpisode episode,
  ) {
    return null;
  }

  Future<int> importToLibrary(
    LibraryService library, {
    BilibiliDownloadEpisode? episode,
    Iterable<BilibiliDownloadEpisode>? episodes,
    String? targetFolderId,
    bool folderExplicit = false,
  }) async {
    return 0;
  }

  Future<Directory> resolveDefaultImportDirectory() async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }
}

/// What an episode-list entry needs to be completed later.
class _PendingWatchPart {
  const _PendingWatchPart({
    required this.videoInfo,
    required this.page,
    required this.bvid,
  }) : episode = null;

  final BilibiliVideoInfo videoInfo;
  final BilibiliPage page;
  final String bvid;
  final BilibiliDownloadEpisode? episode;
}
