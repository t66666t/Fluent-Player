import 'package:dio/dio.dart';
import 'import_card_placement.dart';
import 'download_import_context.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/media_chapter.dart';

int _bilibiliTaskIdSeed = 0;

String _generateBilibiliTaskId() {
  _bilibiliTaskIdSeed = (_bilibiliTaskIdSeed + 1) & 0x7fffffff;
  return 'bbtask_${DateTime.now().microsecondsSinceEpoch}_$_bilibiliTaskIdSeed';
}

enum DownloadStatus {
  pending,
  queued, // Waiting in queue
  fetchingInfo, // Fetching streams/qualities
  downloading,
  merging,
  checking, // Verifying playback compatibility
  repairing, // Transcoding to fix compatibility
  completed,
  failed,
}

/// Library publication is independent of the completed media transfer.
enum BilibiliImportState { pending, importing, failed, imported }

class DownloadRangePartState {
  final int start;
  final int endInclusive;
  final int downloadedBytes;
  final String? tempPath;

  const DownloadRangePartState({
    required this.start,
    required this.endInclusive,
    this.downloadedBytes = 0,
    this.tempPath,
  });

  int get length => endInclusive >= start ? endInclusive - start + 1 : 0;
  bool get isComplete => length > 0 && downloadedBytes == length;
  int get nextByte => start + downloadedBytes;

  DownloadRangePartState copyWith({int? downloadedBytes, String? tempPath}) {
    return DownloadRangePartState(
      start: start,
      endInclusive: endInclusive,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      tempPath: tempPath ?? this.tempPath,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'start': start,
    'endInclusive': endInclusive,
    'downloadedBytes': downloadedBytes,
    'tempPath': tempPath,
  };

  factory DownloadRangePartState.fromJson(Map<String, dynamic> json) {
    return DownloadRangePartState(
      start: _readJsonInt(json['start']),
      endInclusive: _readJsonInt(json['endInclusive'], fallback: -1),
      downloadedBytes: _readJsonInt(json['downloadedBytes']),
      tempPath: json['tempPath']?.toString(),
    );
  }
}

class DownloadPartResumeState {
  final String tempPath;
  final String? url;
  final int downloadedBytes;
  final int? totalBytes;
  final int streamId;
  final int codecid;
  final String codecs;
  final String? mimeType;
  final bool supportsRange;
  final List<DownloadRangePartState> rangeParts;

  const DownloadPartResumeState({
    required this.tempPath,
    this.url,
    required this.downloadedBytes,
    this.totalBytes,
    required this.streamId,
    required this.codecid,
    required this.codecs,
    this.mimeType,
    this.supportsRange = false,
    this.rangeParts = const <DownloadRangePartState>[],
  });

  bool get hasData =>
      downloadedBytes > 0 || rangeParts.any((part) => part.downloadedBytes > 0);
  bool get isComplete =>
      totalBytes != null && totalBytes! > 0 && downloadedBytes >= totalBytes!;

  Map<String, dynamic> toJson() {
    return {
      'tempPath': tempPath,
      'url': url,
      'downloadedBytes': downloadedBytes,
      'totalBytes': totalBytes,
      'streamId': streamId,
      'codecid': codecid,
      'codecs': codecs,
      'mimeType': mimeType,
      'supportsRange': supportsRange,
      'rangeParts': rangeParts.map((part) => part.toJson()).toList(),
    };
  }

  factory DownloadPartResumeState.fromJson(Map<String, dynamic> json) {
    return DownloadPartResumeState(
      tempPath: json['tempPath'] ?? '',
      url: json['url'],
      downloadedBytes: _readJsonInt(json['downloadedBytes']),
      totalBytes: _readNullablePositiveJsonInt(json['totalBytes']),
      streamId: _readJsonInt(json['streamId']),
      codecid: _readJsonInt(json['codecid']),
      codecs: json['codecs'] ?? '',
      mimeType: json['mimeType'],
      supportsRange: json['supportsRange'] ?? false,
      rangeParts: (json['rangeParts'] as List? ?? const <dynamic>[])
          .whereType<Map>()
          .map(
            (part) => DownloadRangePartState.fromJson(
              Map<String, dynamic>.from(part),
            ),
          )
          .toList(growable: false),
    );
  }
}

int _readJsonInt(dynamic value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

int? _readNullablePositiveJsonInt(dynamic value) {
  if (value == null) return null;
  final parsed = _readJsonInt(value, fallback: -1);
  return parsed > 0 ? parsed : null;
}

class BilibiliDownloadTask {
  final String taskId;
  // If collectionInfo is present, it's a Collection (Level 1)
  final BilibiliCollectionInfo? collectionInfo;

  // If not a collection, this is the main video info (Level 2)
  final BilibiliVideoInfo? singleVideoInfo;

  // Flattened access to all episodes? No, we need structure.
  // Level 2 Items (Videos).
  // If Single Video Task: this list has 1 item (the single video).
  // If Collection Task: this list has N items (videos in collection).
  final List<BilibiliVideoItem> videos;
  final MediaSourceRef? sourceRef;
  bool isStreamingImport;
  ImportPlacementRequest? downloadPlacement;
  ImportPlacementRequest? streamingPlacement;

  bool isExpanded;
  bool isSelected;

  BilibiliDownloadTask({
    String? taskId,
    this.collectionInfo,
    this.singleVideoInfo,
    required this.videos,
    this.sourceRef,
    this.isStreamingImport = false,
    this.downloadPlacement,
    this.streamingPlacement,
    this.isExpanded = true,
    this.isSelected = false,
  }) : taskId = taskId ?? _generateBilibiliTaskId();

  bool get isCollection => collectionInfo != null;
  String get title =>
      isCollection ? collectionInfo!.title : (singleVideoInfo?.title ?? "");
  String get cover =>
      isCollection ? collectionInfo!.cover : (singleVideoInfo?.pic ?? "");

  Map<String, dynamic> toJson() {
    return {
      'taskId': taskId,
      'collectionInfo': collectionInfo?.toJson(),
      'singleVideoInfo': singleVideoInfo?.toJson(),
      'videos': videos.map((v) => v.toJson()).toList(),
      'sourceRef': sourceRef?.toJson(),
      'isStreamingImport': isStreamingImport,
      'downloadPlacement': downloadPlacement?.toJson(),
      'streamingPlacement': streamingPlacement?.toJson(),
      'isExpanded': isExpanded,
      'isSelected': isSelected,
    };
  }

  factory BilibiliDownloadTask.fromJson(Map<String, dynamic> json) {
    return BilibiliDownloadTask(
      taskId: (json['taskId']?.toString().trim().isNotEmpty ?? false)
          ? json['taskId'].toString()
          : null,
      collectionInfo: json['collectionInfo'] != null
          ? BilibiliCollectionInfo.fromMap(json['collectionInfo'])
          : null,
      singleVideoInfo: json['singleVideoInfo'] != null
          ? BilibiliVideoInfo.fromMap(json['singleVideoInfo'])
          : null,
      videos: (json['videos'] as List)
          .map((e) => BilibiliVideoItem.fromJson(e))
          .toList(),
      sourceRef: MediaSourceRef.fromJsonOrNull(json['sourceRef']),
      isStreamingImport: json['isStreamingImport'] == true,
      downloadPlacement: ImportPlacementRequest.fromJson(
        json['downloadPlacement'],
      ),
      streamingPlacement: ImportPlacementRequest.fromJson(
        json['streamingPlacement'],
      ),
      isExpanded: json['isExpanded'] ?? true,
      isSelected: json['isSelected'] ?? false,
    );
  }
}

/// A selection snapshot grouped by the hierarchy shown on the Bilibili page.
///
/// [selectedItemCount] is the actionable download-unit count (episodes/pages).
/// Parent videos and collections are counted once when at least one of their
/// children is selected, so partial selections never inflate the parent count.
class BilibiliSelectionSummary {
  final int selectedItemCount;
  final int standaloneVideoCount;
  final int multipartVideoCount;
  final int multipartPartCount;
  final int collectionCount;
  final int collectionVideoCount;
  final int collectionItemCount;

  const BilibiliSelectionSummary({
    this.selectedItemCount = 0,
    this.standaloneVideoCount = 0,
    this.multipartVideoCount = 0,
    this.multipartPartCount = 0,
    this.collectionCount = 0,
    this.collectionVideoCount = 0,
    this.collectionItemCount = 0,
  });

  factory BilibiliSelectionSummary.fromTasks(
    Iterable<BilibiliDownloadTask> tasks,
  ) {
    var selectedItems = 0;
    var standaloneVideos = 0;
    var multipartVideos = 0;
    var multipartParts = 0;
    var collections = 0;
    var collectionVideos = 0;
    var collectionItems = 0;

    for (final task in tasks) {
      var hasSelectedCollectionItem = false;
      for (final video in task.videos) {
        final selectedInVideo = video.episodes
            .where((episode) => episode.isSelected)
            .length;
        if (selectedInVideo == 0) continue;

        selectedItems += selectedInVideo;
        if (task.isCollection) {
          hasSelectedCollectionItem = true;
          collectionVideos++;
          collectionItems += selectedInVideo;
        } else if (video.episodes.length <= 1) {
          standaloneVideos++;
        } else {
          multipartVideos++;
          multipartParts += selectedInVideo;
        }
      }
      if (task.isCollection && hasSelectedCollectionItem) {
        collections++;
      }
    }

    return BilibiliSelectionSummary(
      selectedItemCount: selectedItems,
      standaloneVideoCount: standaloneVideos,
      multipartVideoCount: multipartVideos,
      multipartPartCount: multipartParts,
      collectionCount: collections,
      collectionVideoCount: collectionVideos,
      collectionItemCount: collectionItems,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is BilibiliSelectionSummary &&
        selectedItemCount == other.selectedItemCount &&
        standaloneVideoCount == other.standaloneVideoCount &&
        multipartVideoCount == other.multipartVideoCount &&
        multipartPartCount == other.multipartPartCount &&
        collectionCount == other.collectionCount &&
        collectionVideoCount == other.collectionVideoCount &&
        collectionItemCount == other.collectionItemCount;
  }

  @override
  int get hashCode => Object.hash(
    selectedItemCount,
    standaloneVideoCount,
    multipartVideoCount,
    multipartPartCount,
    collectionCount,
    collectionVideoCount,
    collectionItemCount,
  );
}

class BilibiliVideoItem {
  final BilibiliVideoInfo videoInfo;
  final List<BilibiliDownloadEpisode> episodes; // Level 3 (Parts)
  final MediaSourceRef? sourceRef;

  bool isExpanded;
  bool isSelected;

  BilibiliVideoItem({
    required this.videoInfo,
    required this.episodes,
    this.sourceRef,
    this.isExpanded = false,
    this.isSelected = false,
  });

  Map<String, dynamic> toJson() {
    return {
      'videoInfo': videoInfo.toJson(),
      'episodes': episodes.map((e) => e.toJson()).toList(),
      'sourceRef': sourceRef?.toJson(),
      'isExpanded': isExpanded,
      'isSelected': isSelected,
    };
  }

  factory BilibiliVideoItem.fromJson(Map<String, dynamic> json) {
    return BilibiliVideoItem(
      videoInfo: BilibiliVideoInfo.fromMap(json['videoInfo']),
      episodes: (json['episodes'] as List)
          .map((e) => BilibiliDownloadEpisode.fromJson(e))
          .toList(),
      sourceRef: MediaSourceRef.fromJsonOrNull(json['sourceRef']),
      isExpanded: json['isExpanded'] ?? false,
      isSelected: json['isSelected'] ?? false,
    );
  }
}

class BilibiliDownloadEpisode {
  final BilibiliPage page;
  final String bvid; // Need parent BVID for API calls

  // Selection
  bool isSelected;

  // Options
  StreamItem? selectedVideoQuality;

  /// Immutable facts of the stream that produced the completed file.
  StreamItem? downloadedVideoQuality;
  StreamItem? selectedAudioQuality;
  StreamItem? downloadedAudioQuality;
  List<StreamItem> availableAudioQualities;

  /// Publication receipt, independent of the disposable download output.
  String? publishedMediaPath;
  List<StreamItem> availableVideoQualities;

  BilibiliSubtitle? selectedSubtitle;
  List<BilibiliSubtitle> availableSubtitles;
  List<MediaChapter> chapters;

  // Status
  DownloadStatus status;
  double progress;
  String? downloadSpeed; // New: Formatted speed string (e.g. "2.5 MB/s")
  String? downloadSize; // New: Formatted size string (e.g. "150MB / 200MB")
  bool isExported; // New: Track if exported to library
  BilibiliImportState importState;
  String? importError;
  DownloadImportContext? importContext;
  String? error;
  String? outputPath; // Final mp4 path
  String? danmakuPath;
  String? danmakuError;
  String?
  importedOutputPath; // Output path snapshot for the latest imported download
  List<String>
  importedVideoIds; // Imported library item ids for the latest imported download
  String? tempArtifactKey; // Temp artifact group key for safe cleanup
  DownloadPartResumeState? videoResumeState;
  DownloadPartResumeState? audioResumeState;
  int resumeVersion;
  bool canResume;

  // Runtime control (not serialized)
  CancelToken? cancelToken;

  BilibiliDownloadEpisode({
    required this.page,
    required this.bvid,
    this.isSelected = false,
    this.selectedVideoQuality,
    this.downloadedVideoQuality,
    this.selectedAudioQuality,
    this.downloadedAudioQuality,
    this.availableAudioQualities = const [],
    this.publishedMediaPath,
    this.availableVideoQualities = const [],
    this.selectedSubtitle,
    this.availableSubtitles = const [],
    this.chapters = const <MediaChapter>[],
    this.status = DownloadStatus.pending,
    this.progress = 0.0,
    this.downloadSpeed,
    this.downloadSize,
    this.isExported = false,
    this.importState = BilibiliImportState.pending,
    this.importError,
    this.importContext,
    this.error,
    this.outputPath,
    this.danmakuPath,
    this.danmakuError,
    this.importedOutputPath,
    this.importedVideoIds = const [],
    this.tempArtifactKey,
    this.videoResumeState,
    this.audioResumeState,
    this.resumeVersion = 1,
    this.canResume = false,
    this.cancelToken,
  });

  bool get hasResumeData =>
      canResume &&
      ((videoResumeState?.hasData ?? false) ||
          (audioResumeState?.hasData ?? false));

  String? get latestImportedVideoId =>
      importedVideoIds.where((id) => id.trim().isNotEmpty).lastOrNull;

  double get resumableProgress {
    final videoDownloaded = videoResumeState?.downloadedBytes ?? 0;
    final audioDownloaded = audioResumeState?.downloadedBytes ?? 0;
    final videoTotal = videoResumeState?.totalBytes;
    final audioTotal = audioResumeState?.totalBytes;
    final knownTotal = (videoTotal ?? 0) + (audioTotal ?? 0);
    if (knownTotal > 0) {
      final downloaded = videoDownloaded + audioDownloaded;
      final value = downloaded / knownTotal;
      return (value * 0.85).clamp(0.0, 0.85);
    }
    return progress.clamp(0.0, 0.85);
  }

  void clearResumeState() {
    videoResumeState = null;
    audioResumeState = null;
    canResume = false;
  }

  Map<String, dynamic> toJson() {
    return {
      'page': page.toJson(),
      'bvid': bvid,
      'isSelected': isSelected,
      'selectedVideoQuality': selectedVideoQuality?.toJson(),
      'downloadedVideoQuality': downloadedVideoQuality?.toJson(),
      'selectedAudioQuality': selectedAudioQuality?.toJson(),
      'downloadedAudioQuality': downloadedAudioQuality?.toJson(),
      'availableAudioQualities': availableAudioQualities
          .map((e) => e.toJson())
          .toList(),
      'publishedMediaPath': publishedMediaPath,
      'availableVideoQualities': availableVideoQualities
          .map((e) => e.toJson())
          .toList(),
      'selectedSubtitle': selectedSubtitle?.toJson(),
      'availableSubtitles': availableSubtitles.map((e) => e.toJson()).toList(),
      'chapters': chapters.map((chapter) => chapter.toJson()).toList(),
      'status': status.index,
      'progress': progress,
      'isExported': isExported, // Persist export status
      'importState': importState.name,
      'importError': importError,
      'importContext': importContext?.toJson(),
      'error': error,
      'outputPath': outputPath,
      'danmakuPath': danmakuPath,
      'danmakuError': danmakuError,
      'importedOutputPath': importedOutputPath,
      'importedVideoIds': importedVideoIds,
      'tempArtifactKey': tempArtifactKey,
      'videoResumeState': videoResumeState?.toJson(),
      'audioResumeState': audioResumeState?.toJson(),
      'resumeVersion': resumeVersion,
      'canResume': canResume,
    };
  }

  factory BilibiliDownloadEpisode.fromJson(Map<String, dynamic> json) {
    return BilibiliDownloadEpisode(
      page: BilibiliPage.fromJson(json['page']),
      bvid: json['bvid'],
      isSelected: json['isSelected'] ?? false,
      selectedVideoQuality: json['selectedVideoQuality'] != null
          ? StreamItem.fromJson(json['selectedVideoQuality'])
          : null,
      downloadedVideoQuality: json['downloadedVideoQuality'] is Map
          ? StreamItem.fromJson(json['downloadedVideoQuality'])
          : null,
      selectedAudioQuality: json['selectedAudioQuality'] is Map
          ? StreamItem.fromJson(
              Map<String, dynamic>.from(json['selectedAudioQuality']),
            )
          : null,
      downloadedAudioQuality: json['downloadedAudioQuality'] is Map
          ? StreamItem.fromJson(
              Map<String, dynamic>.from(json['downloadedAudioQuality']),
            )
          : null,
      availableAudioQualities:
          (json['availableAudioQualities'] as List?)
              ?.whereType<Map>()
              .map(
                (value) =>
                    StreamItem.fromJson(Map<String, dynamic>.from(value)),
              )
              .toList() ??
          [],
      publishedMediaPath: json['publishedMediaPath'] as String?,
      availableVideoQualities:
          (json['availableVideoQualities'] as List?)
              ?.map((e) => StreamItem.fromJson(e))
              .toList() ??
          [],
      selectedSubtitle: json['selectedSubtitle'] != null
          ? BilibiliSubtitle.fromJson(json['selectedSubtitle'])
          : null,
      availableSubtitles:
          (json['availableSubtitles'] as List?)
              ?.map((e) => BilibiliSubtitle.fromJson(e))
              .toList() ??
          [],
      chapters: MediaChapter.normalize(
        (json['chapters'] as List? ?? const []).whereType<Map>().map(
          (chapter) =>
              MediaChapter.fromJson(Map<String, dynamic>.from(chapter)),
        ),
        durationMs:
            (((json['page'] is Map ? json['page']['duration'] as num? : null) ??
                        0) *
                    1000)
                .round(),
      ),
      status: DownloadStatus.values[json['status'] ?? 0],
      progress: json['progress'] ?? 0.0,
      isExported: json['isExported'] ?? false,
      importState: BilibiliImportState.values.firstWhere(
        (state) => state.name == json['importState'],
        orElse: () => json['isExported'] == true
            ? BilibiliImportState.imported
            : BilibiliImportState.pending,
      ),
      importError: json['importError'] as String?,
      importContext: DownloadImportContext.fromJson(json['importContext']),
      error: json['error'],
      outputPath: json['outputPath'],
      danmakuPath: json['danmakuPath'],
      danmakuError: json['danmakuError'],
      importedOutputPath: json['importedOutputPath'],
      importedVideoIds:
          (json['importedVideoIds'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      tempArtifactKey: json['tempArtifactKey'],
      videoResumeState: json['videoResumeState'] != null
          ? DownloadPartResumeState.fromJson(json['videoResumeState'])
          : null,
      audioResumeState: json['audioResumeState'] != null
          ? DownloadPartResumeState.fromJson(json['audioResumeState'])
          : null,
      resumeVersion: json['resumeVersion'] ?? 1,
      canResume: json['canResume'] ?? false,
    );
  }
}

class BilibiliSubtitle {
  final String id;
  final String lan;
  final String lanDoc; // Display name
  final String url;
  final bool isAi;

  BilibiliSubtitle({
    required this.id,
    required this.lan,
    required this.lanDoc,
    required this.url,
    required this.isAi,
  });

  Map<String, dynamic> toJson() {
    return {'id': id, 'lan': lan, 'lanDoc': lanDoc, 'url': url, 'isAi': isAi};
  }

  factory BilibiliSubtitle.fromJson(Map<String, dynamic> json) {
    return BilibiliSubtitle(
      id: json['id'],
      lan: json['lan'],
      lanDoc: json['lanDoc'],
      url: json['url'],
      isAi: json['isAi'],
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BilibiliSubtitle &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          lan == other.lan;

  @override
  int get hashCode => id.hashCode ^ lan.hashCode;
}
