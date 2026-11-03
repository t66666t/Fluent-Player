// Community edition: executable downloader implementation removed.
import '../../../services/app_storage_service.dart';
import 'package:video_player_app/services/network/network_http.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/youtube_download/models/youtube_download_models.dart';
import 'package:video_player_app/features/youtube_download/platform/yt_dlp_native_bridge.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_audio_format_order.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_binary_installer.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_binary_location_store.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_binary_updater.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_meta_parser.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_video_format_selector.dart';
import 'package:video_player_app/services/temporary_storage_cleanup_models.dart';

/// 任务状态的 JSON 编解码全部在后台 Isolate 中完成，避免任务较多时阻塞 UI。
/// 尚未拿到格式的解析占位不落盘，避免中途退出后留下无法继续的任务。
@visibleForTesting
String encodeYtDlpTaskStateV2(List<YtDlpTaskRecord> tasks) => jsonEncode(
  AppStorageService.instance.encodePaths({
    'version': 2,
    'tasks': tasks
        .where((task) => !isUnpersistedResolvePlaceholder(task))
        .map((task) => task.toJson())
        .toList(growable: false),
  }),
);

@visibleForTesting
bool isUnpersistedResolvePlaceholder(YtDlpTaskRecord task) {
  return task.status == YtDlpTaskStatus.resolving && task.meta == null;
}

@visibleForTesting
List<YtDlpTaskRecord> decodeYtDlpTaskState(String raw) {
  final decoded = AppStorageService.instance.decodePaths(jsonDecode(raw));
  return _ytDlpTasksFromValue(decoded);
}

List<YtDlpTaskRecord> _ytDlpTasksFromValue(dynamic decoded) {
  if (decoded is! List &&
      !(decoded is Map &&
          decoded['tasks'] is List &&
          (decoded['version'] == null ||
              decoded['version'] == 1 ||
              decoded['version'] == 2))) {
    throw const FormatException('下载记录格式无效或来自更新版本；已保留原记录');
  }
  final rawTasks = decoded is Map
      ? (decoded['tasks'] as List? ?? const [])
      : (decoded as List? ?? const []);
  if (rawTasks.any((value) => value is! Map)) {
    throw const FormatException('下载记录包含无法读取的条目；已保留原记录');
  }
  return rawTasks
      .whereType<Map>()
      .map((item) => YtDlpTaskRecord.fromJson(Map<String, dynamic>.from(item)))
      .toList(growable: false);
}

/// Task removal may delete resumable artifacts and thumbnail sidecars written
/// beside the download. The finished video, subtitles, and unrelated files
/// stay on disk.
@visibleForTesting
bool isSafeYtDlpTaskRemovalArtifact(String filePath, String taskId) {
  final name = p.basename(filePath);
  if (!name.contains('__$taskId.')) {
    return false;
  }
  final lower = name.toLowerCase();
  return lower.endsWith('.part') ||
      lower.endsWith('.ytdl') ||
      lower.endsWith('.tmp') ||
      lower.endsWith('.temp') ||
      lower.endsWith('.frag') ||
      lower.endsWith('.png') ||
      lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.webp') ||
      RegExp(r'\.f\d+\.[^.]+$').hasMatch(lower);
}

/// True when yt-dlp `--dump-single-json` already emitted a thumbnail field.
/// Windows uses the same `"thumbnail":` marker before skipping a second process.
@visibleForTesting
bool dumpSingleJsonHasThumbnailKey(String rawJson) {
  return rawJson.contains('"thumbnail":');
}

/// Some CDNs reject Dart's default client for signed image URLs.
/// Send a browser identity and the watch page as Referer.
@visibleForTesting
Map<String, String> ytDlpThumbnailRequestHeaders({String? webpageUrl}) {
  final headers = <String, String>{
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
    'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
  };
  final referer = webpageUrl?.trim() ?? '';
  if (referer.startsWith('http://') || referer.startsWith('https://')) {
    headers['Referer'] = referer;
  }
  return headers;
}

class YtDlpResolveNoFormatException implements Exception {
  const YtDlpResolveNoFormatException();

  @override
  String toString() => '已拿到元数据，但没有可用格式，请尝试调整会话设置或切换策略';
}

/// Whether a failed resolve should drop player-client, visitor data, and PO
/// tokens and try once more. Timeouts and transport failures stay single-shot.
/// An empty format list is retried explicitly so broad words like "format" do
/// not force a second full extraction.
@visibleForTesting
bool shouldRetryResolveWithSaferConfig({
  required String errorText,
  required bool sessionConfigsDiffer,
  bool noUsableFormat = false,
}) {
  if (!sessionConfigsDiffer) {
    return false;
  }
  final lower = errorText.toLowerCase();
  if (lower.contains('timeout') ||
      lower.contains('timed out') ||
      lower.contains('network') ||
      lower.contains('socket') ||
      lower.contains('proxy')) {
    return false;
  }
  if (noUsableFormat) {
    return true;
  }
  const keywords = <String>[
    'player_client',
    'player client',
    'visitor_data',
    'visitor data',
    'po_token',
    'po token',
    'unable to extract',
    'sign in',
    '403',
    'forbidden',
  ];
  return keywords.any(lower.contains);
}

class _YtDlpPauseCancellation implements Exception {
  const _YtDlpPauseCancellation();

  @override
  String toString() => '任务已暂停';
}

class _YtDlpFfmpegFailure implements Exception {
  const _YtDlpFfmpegFailure(this.code, this.summary, this.logs);

  final int? code;
  final String summary;
  final String logs;

  @override
  String toString() => summary;
}

class _DesktopVerificationStopped implements Exception {}

/// Owns the local phase after the native downloader has already exited.
class _DesktopVerification {
  _DesktopVerification(this.generation);
  final int? generation;
  final cancelled = Completer<void>();
  final finished = Completer<void>();
  YtDlpTaskStatus? stopStatus;

  void stop(YtDlpTaskStatus status) {
    // A subsequent cancel/delete takes precedence over a pending pause.
    if (stopStatus != YtDlpTaskStatus.cancelled) stopStatus = status;
    if (!cancelled.isCompleted) cancelled.complete();
  }

  void check() {
    if (cancelled.isCompleted) throw _DesktopVerificationStopped();
  }
}

class YtDlpDownloadService extends ChangeNotifier with WidgetsBindingObserver {
  bool? _mobileArtifactsForTesting;
  bool get _usesMobileArtifacts =>
      _mobileArtifactsForTesting ?? (Platform.isAndroid || Platform.isIOS);

  YtDlpDownloadService() : _nativeBridge = YtDlpNativeBridge() {}

  @visibleForTesting
  YtDlpDownloadService.forTesting({
    required YtDlpNativeBridge nativeBridge,
    required YtDlpBinaryStatus binaryStatus,
    required DownloadSessionConfig sessionConfig,
    NetworkSettingsService? networkSettings,
    bool? usesMobileArtifacts,
  }) : _nativeBridge = nativeBridge {}

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {}

  @override
  void dispose() {
    super.dispose();
  }

  final YtDlpNativeBridge _nativeBridge;

  // Native events no longer own a generation once its download has completed.

  @visibleForTesting
  Future<void> Function(YtDlpTaskRecord, String?, Future<void>)?
  verifyYoutubeOutputForTesting;

  final List<YtDlpTaskRecord> tasks = [];

  // 缓存的任务 ID 列表，仅在任务结构变更时更新，避免 Selector 每次 notify 都重建列表
  List<String> _cachedTaskIds = const [];

  Future<void>? _initFuture;

  DownloadSessionConfig _sessionConfig = DownloadSessionConfig.defaults();
  YtDlpDownloadPreferences _downloadPreferences =
      YtDlpDownloadPreferences.defaults();
  YtDlpBinaryStatus _binaryStatus = const YtDlpBinaryStatus();
  YtDlpBinaryLocationSettings? _binaryLocationSettings;
  YtDlpBinaryReleaseInfo? _latestYtDlpRelease;

  // Reserve before any async preparation and retain ownership until the native
  // terminal event. A queued UI status alone does not mean no start was sent.

  bool _isInitialized = false;

  bool _isUpdatingYtDlp = false;
  double? _ytDlpUpdateProgress;
  String _ytDlpUpdateStage = '准备更新';
  String? _ytDlpUpdateError;
  String? _managedYtDlpVersion;
  String? _customYtDlpVersion;
  String? _managedYtDlpPathError;
  String? _customYtDlpPathError;
  bool _isApplyingYtDlpPath = false;
  bool keepScreenAwakeDuringProcessing = false;

  bool isResolving = false;

  String? resolvingStatus;
  int _processingTaskCount = 0;
  int _selectedCount = 0;
  int _selectedRunnableCount = 0;
  int _selectedPausableCount = 0;
  int _selectedPrioritizableCount = 0;
  int _selectedCancellableCount = 0;
  int _selectedRetryableCount = 0;
  int _selectedCompletedCount = 0;
  int _queuedCount = 0;
  int _activeCount = 0;
  int _failedCount = 0;
  int _completedCount = 0;

  DownloadSessionConfig get sessionConfig => _sessionConfig;
  Future<void> flushPreferencesForTrial() async {}

  Future<void> reloadPreferencesForTrial() async {}

  YtDlpDownloadPreferences get downloadPreferences => _downloadPreferences;
  bool get supportsConcurrentDownloads =>
      supportsDesktopYtDlpPaths && !_usesMobileArtifacts;
  int get maxConcurrentDownloads => supportsConcurrentDownloads
      ? YtDlpDownloadPreferences.normalizeConcurrentDownloads(
          _downloadPreferences.maxConcurrentDownloads,
        )
      : 1;
  YtDlpBinaryStatus get binaryStatus => _binaryStatus;
  YtDlpBinaryLocationSettings? get binaryLocationSettings =>
      _binaryLocationSettings;
  YtDlpBinaryReleaseInfo? get latestYtDlpRelease => _latestYtDlpRelease;
  bool get supportsOnlineYtDlpUpdate =>
      YtDlpBinaryUpdater.supportsOnlineUpdate &&
      (!supportsDesktopYtDlpPaths || usesManagedYtDlp);
  bool get supportsLatestYtDlpReleaseCheck =>
      YtDlpBinaryUpdater.supportsLatestReleaseCheck;
  bool get isUpdatingYtDlp => _isUpdatingYtDlp;
  double? get ytDlpUpdateProgress => _ytDlpUpdateProgress;
  String get ytDlpUpdateStage => _ytDlpUpdateStage;
  String? get ytDlpUpdateError => _ytDlpUpdateError;
  String? get managedYtDlpVersion => _managedYtDlpVersion;
  String? get customYtDlpVersion => _customYtDlpVersion;
  String? get managedYtDlpPathError => _managedYtDlpPathError;
  String? get customYtDlpPathError => _customYtDlpPathError;
  bool get isApplyingYtDlpPath => _isApplyingYtDlpPath;
  bool get supportsDesktopYtDlpPaths =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
  bool get usesManagedYtDlp =>
      _binaryLocationSettings?.source != YtDlpBinarySource.custom;
  String get bundledYtDlpVersion => YtDlpBinaryInstaller.bundledYtDlpVersion;
  bool get hasNewerYtDlpRelease {
    final latest = _normalizeBinaryVersion(_latestYtDlpRelease?.version);
    final current = _normalizeBinaryVersion(_binaryStatus.ytDlpVersion);
    return latest != null &&
        current != null &&
        YtDlpBinaryUpdater.compareVersions(latest, current) > 0;
  }

  bool get isInitialized => _isInitialized;
  bool get isInitializing => _initFuture != null && !_isInitialized;

  bool get supportsProcessingKeepAwakeToggle =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  bool get isProcessingKeepAwakeActive =>
      keepScreenAwakeDuringProcessing && hasProcessingTasks;

  bool get hasProcessingTasks => _processingTaskCount > 0;

  Future<void> forgetStorageFiles(List<String> paths) async {}

  @override
  void notifyListeners() {}

  Future<void> init() async {}

  Future<void> ensureReady({
    bool activatePage = false,
    bool requireRuntime = false,
  }) async {}

  Future<void> activatePage() async {}

  Future<void> deactivatePage() async {}

  Future<void> refreshDesktopYtDlpPaths() async {}

  Future<bool> selectYtDlpBinarySource(YtDlpBinarySource source) async {
    return false;
  }

  Future<bool> applyCustomYtDlpPath(String path) async {
    return false;
  }

  Future<bool> migrateManagedYtDlpDirectory(String path) async {
    return false;
  }

  Future<void> prepareStorageMigration() async {}

  Future<void> shutdown() async {}

  Future<void> saveTasks({bool flush = false}) async {}

  Future<void> saveSessionConfig(DownloadSessionConfig config) async {}

  Future<void> saveDownloadPreferences(
    YtDlpDownloadPreferences preferences,
  ) async {}

  Future<void> updateDownloadPreferences({
    String? preferredQuality,
    List<String>? preferredSubtitleLanguages,
    bool? autoDeleteTaskAfterImport,
  }) async {}

  Future<String?> importCookiesFile(String sourcePath) async {
    return null;
  }

  Future<void> saveLastSelection(DownloadSelection selection) async {}

  Future<DownloadSelection> loadLastSelection() async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  Future<bool> toggleKeepScreenAwakeDuringProcessing() async {
    return false;
  }

  /// Browser fallback without adding a task or loading the download UI's choices.
  Future<VideoMeta> resolveAutomaticBrowserMedia(
    String url,
    DownloadSessionConfig config, {
    NetworkMode? networkMode,
  }) async {
    throw UnsupportedError('开源版不提供媒体下载或网站提取');
  }

  Future<VideoMeta?> resolveBrowserUrl(
    String url, {
    required String taskId,
    required BrowserDownloadOptions options,
    DownloadSessionConfig? sessionConfig,
    Future<void> Function()? releaseContext,
  }) async {
    throw UnsupportedError('开源版不提供媒体下载或网站提取');
  }

  Future<void> releaseBrowserContext(String taskId) async {}

  Future<VideoMeta?> resolveUrl(String url, {String? existingTaskId}) async {
    throw UnsupportedError('开源版不提供媒体下载或网站提取');
  }

  Future<void> redownloadTask(YtDlpTaskRecord task) async {
    throw UnsupportedError('开源版不提供媒体下载或网站提取');
  }

  Future<void> startTask(
    YtDlpTaskRecord task, {
    bool prioritize = false,
  }) async {
    throw UnsupportedError('开源版不提供媒体下载或网站提取');
  }

  Future<void> prioritizeTask(YtDlpTaskRecord task) async {}

  Future<void> pauseTask(
    YtDlpTaskRecord task, {
    bool automatic = false,
  }) async {}

  Future<void> cancelTask(YtDlpTaskRecord task) async {}

  Future<void> retryTask(YtDlpTaskRecord task) async {}

  Future<void> removeTask(YtDlpTaskRecord task) async {}

  Future<void> clearAllTasks() async {}

  Future<void> clearCompletedTasks() async {}

  void selectAll() {}

  List<YtDlpTaskRecord> actionTasks({Iterable<String>? taskIds}) {
    return [];
  }

  Future<void> removeSelected({Iterable<String>? taskIds}) async {}

  Future<void> pauseSelected({Iterable<String>? taskIds}) async {}

  Future<void> cancelSelected({Iterable<String>? taskIds}) async {}

  Future<void> retrySelected({Iterable<String>? taskIds}) async {}

  Future<void> startSelected({Iterable<String>? taskIds}) async {
    throw UnsupportedError('开源版不提供媒体下载或网站提取');
  }

  Future<void> prioritizeSelected({Iterable<String>? taskIds}) async {}

  Future<void> renameTask(String taskId, String name) async {}

  Future<void> setTaskConnections(String taskId, int connections) async {}

  void updateTaskSelection(String taskId, bool selected) {}

  Future<void> updateTaskSelectionModel(
    String taskId,
    DownloadSelection selection,
  ) async {}

  int get selectedCount => _selectedCount;

  int get selectedRunnableCount => _selectedRunnableCount;

  int get selectedPausableCount => _selectedPausableCount;

  int get selectedPrioritizableCount => _selectedPrioritizableCount;

  int get selectedCancellableCount => _selectedCancellableCount;

  int get selectedRetryableCount => _selectedRetryableCount;

  int get selectedCompletedCount => _selectedCompletedCount;

  int get queuedCount => _queuedCount;

  int get activeCount => _activeCount;

  int get failedCount => _failedCount;

  int get completedCount => _completedCount;

  Future<String> resolveEffectiveOutputDirectoryPath([
    DownloadSessionConfig? config,
  ]) async {
    return '';
  }

  void rememberImportFolder(String? folderId) {}

  Future<String?> importedLibraryId(YtDlpTaskRecord task) async {
    return null;
  }

  Future<int> importToLibrary({
    YtDlpTaskRecord? task,
    Iterable<String>? taskIds,
    String? targetFolderId,
    bool folderExplicit = false,
  }) async {
    return 0;
  }

  bool isImportingTask(String taskId) {
    return false;
  }

  Future<void> refreshBinaryStatus() async {}

  Future<YtDlpBinaryReleaseInfo?> refreshLatestYtDlpRelease() async {
    return null;
  }

  Future<YtDlpBinaryUpdateResult> updateYtDlpToLatest() async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  String? _normalizeBinaryVersion(String? version) {
    return null;
  }

  /// Same normalization as startup, without loading tasks, starting downloads
  /// or writing migration markers during a settings export.
  static DownloadSessionConfig sessionPreferencesForExport(
    DownloadSessionConfig config, {
    required bool speedAndRetryDefaultsApplied,
    required bool parallelDefaultsApplied,
  }) {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  /// 获取缓存的任务 ID 列表，仅在任务结构变更时更新
  List<String> get taskIds => _cachedTaskIds;

  YtDlpTaskRecord? getTaskById(String taskId) {
    return null;
  }

  // Legacy staged Android path kept only for rollback/reference.
  // ignore: unused_element

  // ignore: unused_element

  // ignore: unused_element

  Future<TemporaryStorageCategoryReport> buildTemporaryStorageReport() async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  Future<void> clearTemporaryStorageArtifacts() async {}
}

Map<String, dynamic> _readResolvedRawInfo(Map<String, dynamic> rawPayload) {
  final rawInfoPath = rawPayload['rawInfoPath']?.toString().trim() ?? '';
  if (rawInfoPath.isNotEmpty) {
    try {
      final decoded = jsonDecode(File(rawInfoPath).readAsStringSync());
      if (decoded is Map && decoded.isNotEmpty) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      throw Exception('yt-dlp 返回的元数据无法解析，请检查日志或调整会话设置');
    }
    throw Exception('yt-dlp 返回了空或不可解析的元数据，请检查日志或调整会话设置');
  }
  final structured = rawPayload['rawInfo'];
  if (structured is Map && structured.isNotEmpty) {
    return Map<String, dynamic>.from(structured);
  }
  final rawJson = rawPayload['rawInfoJson']?.toString();
  if (rawJson != null && rawJson.isNotEmpty) {
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is Map && decoded.isNotEmpty) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      throw Exception('yt-dlp 返回的元数据无法解析，请检查日志或调整会话设置');
    }
  }
  throw Exception('yt-dlp 返回了空或不可解析的元数据，请检查日志或调整会话设置');
}

VideoMeta _parseResolvedMetaOnWorker(Map<String, dynamic> rawPayload) {
  final rawInfo = _readResolvedRawInfo(rawPayload);
  final resolvedThumbnailUrl = rawPayload['thumbnailUrl']?.toString().trim();
  if (resolvedThumbnailUrl != null && resolvedThumbnailUrl.isNotEmpty) {
    rawInfo['thumbnail'] = resolvedThumbnailUrl;
    final existingThumbnails = (rawInfo['thumbnails'] as List? ?? const [])
        .whereType<Object?>()
        .map((item) => item is Map ? Map<String, dynamic>.from(item) : null)
        .whereType<Map<String, dynamic>>()
        .toList();
    final alreadyExists = existingThumbnails.any(
      (item) => item['url']?.toString().trim() == resolvedThumbnailUrl,
    );
    if (!alreadyExists) {
      existingThumbnails.insert(0, {'url': resolvedThumbnailUrl});
      rawInfo['thumbnails'] = existingThumbnails;
    }
  }
  return const YtDlpMetaParser().parse(rawInfo);
}

DownloadSelection _applyMetaRecommendationsOnWorker(
  Map<String, dynamic> payload,
) {
  final selection = DownloadSelection.fromJson(
    Map<String, dynamic>.from(payload['selection'] as Map),
  );
  final meta = VideoMeta.fromJson(
    Map<String, dynamic>.from(payload['meta'] as Map),
  );
  final preferences = YtDlpDownloadPreferences.fromJson(
    Map<String, dynamic>.from(
      payload['preferences'] as Map? ?? const <String, dynamic>{},
    ),
  );
  return _buildSelectionFromPreferences(
    selection: selection,
    meta: meta,
    preferences: preferences,
  );
}

DownloadSelection _buildSelectionFromPreferences({
  required DownloadSelection selection,
  required VideoMeta meta,
  required YtDlpDownloadPreferences preferences,
  bool forceVideoPreference = false,
}) {
  final resolvedVideoId =
      forceVideoPreference ||
          selection.selectedVideoFormatId?.isNotEmpty != true
      ? _pickPreferredVideoFormatId(meta, preferences.preferredQuality)
      : selection.selectedVideoFormatId;
  final selectedVideoFormat = meta.videoFormats
      .where((item) => item.formatId == resolvedVideoId)
      .cast<VideoFormat?>()
      .firstOrNull;
  final separateAudio =
      selection.audioOnly ||
      (!selection.removeAudio &&
          YtDlpVideoFormatSelector.needsSeparateAudioTrack(
            selectedVideoFormat,
            source: meta.source,
          ));
  // A progressive X MP4 already includes AAC. Keeping a previously chosen
  // hls-audio id here would schedule the slow fragment download again.
  final resolvedAudioIds = !separateAudio
      ? const <String>[]
      : selection.selectedAudioFormatIds.isNotEmpty
      ? selection.selectedAudioFormatIds
      : [
          if ((_pickPreferredAudioFormatId(meta)?.isNotEmpty ?? false))
            _pickPreferredAudioFormatId(meta)!,
        ];
  final preferredSubtitleLanguages =
      selection.selectedSubtitleTrackKeys.isNotEmpty ||
          selection.subtitleLanguages.isNotEmpty
      ? selection.subtitleLanguages
      : preferences.preferredSubtitleLanguages.isNotEmpty
      ? preferences.preferredSubtitleLanguages
      : meta.recommendedSubtitleLanguages;
  final resolvedSubtitleTracks = selection.selectedSubtitleTrackKeys.isNotEmpty
      ? selection.selectedSubtitleTrackKeys
            .map(
              (item) => {
                for (final track in meta.subtitles) track.selectionKey: track,
              }[item],
            )
            .whereType<SubtitleTrack>()
            .toList()
      : _resolveTracksForPreferredLanguagesOrdered(
          meta.subtitles,
          preferredSubtitleLanguages,
        );
  final resolvedSubtitleLanguages = _orderedUniqueStrings(
    resolvedSubtitleTracks.map((item) => item.languageCode),
  );

  return selection.copyWith(
    selectedVideoFormatId: resolvedVideoId,
    selectedAudioFormatIds: resolvedAudioIds,
    outputContainer: selection.audioOnly
        ? _normalizeAudioOnlyOutputContainerValue(selection.outputContainer)
        : 'mkv',
    selectedSubtitleTrackKeys: resolvedSubtitleTracks
        .map((item) => item.selectionKey)
        .toList(),
    subtitleLanguages: resolvedSubtitleLanguages,
    writeSubtitles: resolvedSubtitleTracks.any((item) => !item.isAutoGenerated),
    writeAutoSubtitles: resolvedSubtitleTracks.any(
      (item) => item.isAutoGenerated,
    ),
    embedSubtitles: resolvedSubtitleTracks.isNotEmpty,
  );
}

String? _pickPreferredVideoFormatId(VideoMeta meta, String preferredQuality) {
  return YtDlpVideoFormatSelector.pickFormatId(
        meta.videoFormats,
        preferredQuality: preferredQuality,
      ) ??
      meta.recommendedVideoFormatId;
}

String? _pickPreferredAudioFormatId(VideoMeta meta) {
  return YtDlpAudioFormatOrder.pickFormatId(meta.audioFormats) ??
      meta.recommendedAudioFormatId;
}

List<SubtitleTrack> _resolveTracksForPreferredLanguagesOrdered(
  List<SubtitleTrack> subtitles,
  List<String> preferredLanguages,
) {
  final tracks = <SubtitleTrack>[];
  final used = <String>{};
  for (final language in preferredLanguages) {
    for (final track in subtitles) {
      if (!YtDlpMetaParser.matchesPreferenceLanguage(
        language,
        track.languageCode,
      )) {
        continue;
      }
      if (used.add(track.selectionKey)) {
        tracks.add(track);
      }
    }
  }
  return tracks;
}

List<String> _orderedUniqueStrings(Iterable<String> values) {
  final result = <String>[];
  final seen = <String>{};
  for (final value in values) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || !seen.add(trimmed)) {
      continue;
    }
    result.add(trimmed);
  }
  return result;
}

String _normalizeAudioOnlyOutputContainerValue(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'mp3':
    case 'aac':
    case 'm4a':
    case 'wav':
    case 'opus':
    case 'best':
      return raw.trim().toLowerCase();
    default:
      return 'm4a';
  }
}
