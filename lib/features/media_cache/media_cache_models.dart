import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../models/media_source_ref.dart';
import '../../models/video_item.dart';

String cacheDigest(String value) =>
    sha256.convert(utf8.encode(value)).toString();

enum CacheTaskState {
  queued,
  resolving,
  downloading,
  retrying,
  waitingNetwork,
  waitingLogin,
  waitingStorage,
  waitingSystem,
  paused,
  verifying, // Legacy journal value; new cache tasks never enter this phase.
  publishing,
  merging,
  completed,
  failed,
}

extension CacheTaskStatePresentation on CacheTaskState {
  bool get canPause =>
      running ||
      this == CacheTaskState.queued ||
      this == CacheTaskState.retrying;
  bool get canRetry => this == CacheTaskState.failed;
  bool get canResume =>
      this != CacheTaskState.completed && !canPause && !canRetry;
  String get primaryActionLabel => canPause
      ? '暂停'
      : canRetry
      ? '重试'
      : '继续';

  bool get running => const {
    CacheTaskState.resolving,
    CacheTaskState.downloading,
    CacheTaskState.verifying,
    CacheTaskState.publishing,
    CacheTaskState.merging,
  }.contains(this);
  String get label => switch (this) {
    CacheTaskState.queued => '排队中',
    CacheTaskState.resolving => '正在获取画质',
    CacheTaskState.downloading => '正在缓存',
    CacheTaskState.retrying => '正在重试',
    CacheTaskState.waitingNetwork => '等待网络',
    CacheTaskState.waitingLogin => '需要重新登录',
    CacheTaskState.waitingStorage => '等待存储空间',
    CacheTaskState.waitingSystem => '等待系统允许继续',
    CacheTaskState.paused => '已暂停',
    CacheTaskState.verifying || CacheTaskState.publishing => '正在保存',
    CacheTaskState.merging => '正在合并',
    CacheTaskState.completed => '已缓存',
    CacheTaskState.failed => '缓存失败',
  };
}

/// Durable media identity. Credentials and expiring CDN URLs never enter this
/// record. A media can have several library cards and several local qualities.
class CacheSource {
  const CacheSource({
    required this.ref,
    required this.itemId,
    required this.title,
    required this.kind,
    this.thumbnail,
    this.durationMs = 0,
    this.legacyPath,
    this.remoteParentId,
  });

  final MediaSourceRef ref;
  final String itemId, title;
  final MediaType kind;
  final String? thumbnail, legacyPath;
  final String? remoteParentId;
  final int durationMs;
  bool get isPodcast => ref.podcast != null;
  bool get isBilibili => ref.cloudDrive == null && !isPodcast;
  String get provider => isPodcast
      ? 'podcast'
      : isBilibili
      ? 'bilibili'
      : ref.cloudDrive!.providerId;
  String get providerLabel => switch (provider) {
    'bilibili' => '哔哩哔哩',
    'baidu' => '百度网盘',
    'quark' => '夸克网盘',
    'uc' => 'UC网盘',
    'aliyun' => '阿里云盘',
    'podcast' => '播客',
    _ => '网盘',
  };
  String get key => isPodcast
      ? cacheDigest(
          'podcast:${ref.podcast!.episodeId}:${ref.podcast!.mediaUrl}',
        )
      : isBilibili
      ? cacheDigest('bilibili:${ref.bvid}:${ref.cid}')
      : ref.cloudDrive!.sourceKey;

  static CacheSource? fromItem(VideoItem item) {
    final source = item.sourceRef;
    if (source == null) return null;
    final cloud = source.cloudDrive;
    if (cloud != null &&
        !const {'baidu', 'quark', 'uc', 'aliyun'}.contains(cloud.providerId)) {
      return null;
    }
    if (cloud == null &&
        source.podcast == null &&
        ((source.bvid?.isEmpty ?? true) ||
            (source.cid ?? 0) <= 0 ||
            !(source.kind == MediaSourceKind.url && item.isBilibiliExported) &&
                !const {
                  MediaSourceKind.bilibiliStream,
                  MediaSourceKind.bilibiliBv,
                  MediaSourceKind.bilibiliId,
                }.contains(source.kind))) {
      return null;
    }
    return CacheSource(
      ref: source,
      itemId: item.id,
      title: item.title,
      thumbnail: item.thumbnailPath,
      kind: item.type,
      durationMs: item.durationMs,
      legacyPath: item.path.contains('://') ? null : item.path,
    );
  }

  VideoItem toItem() => VideoItem(
    id: itemId,
    path:
        (isPodcast ? 'podcast:${ref.podcast!.episodeId}' : null) ??
        ref.cloudDrive?.logicalUri ??
        'bilibili://stream/${ref.bvid}/${ref.cid}',
    sourceRef: isBilibili
        ? ref.copyWith(kind: MediaSourceKind.bilibiliStream)
        : ref,
    title: title,
    thumbnailPath: thumbnail,
    durationMs: durationMs,
    type: kind,
    lastUpdated: DateTime.now().millisecondsSinceEpoch,
  );

  Map<String, dynamic> toJson() => {
    'ref': ref.toJson(),
    'itemId': itemId,
    'title': title,
    'kind': kind.name,
    'thumbnail': thumbnail,
    'durationMs': durationMs,
    'legacyPath': legacyPath,
    'remoteParentId': remoteParentId,
  };
  factory CacheSource.fromJson(Map<String, dynamic> json) => CacheSource(
    ref: MediaSourceRef.fromJson(Map<String, dynamic>.from(json['ref'] as Map)),
    itemId: json['itemId'] as String,
    title: json['title'] as String,
    kind: json['kind'] == 'audio' ? MediaType.audio : MediaType.video,
    thumbnail: json['thumbnail'] as String?,
    legacyPath: json['legacyPath'] as String?,
    remoteParentId: json['remoteParentId'] as String?,
    durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
  );
}

class CacheQuality {
  const CacheQuality({
    required this.id,
    required this.label,
    this.height,
    this.width,
    this.codec = '',
    this.revision = '',
    this.available = true,
  });
  final String id, label, codec, revision;
  final int? height, width;

  /// Portrait and landscape versions share the same resolution ceiling.
  int? get resolutionHeight =>
      height != null && width != null && width! > 0 && height! > 0
      ? (width! < height! ? width : height)
      : height;
  final bool available;
  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'height': height,
    'width': width,
    'codec': codec,
    'revision': revision,
  };
  factory CacheQuality.fromJson(Map<String, dynamic> json) => CacheQuality(
    id: json['id'] as String,
    label: json['label'] as String,
    height: (json['height'] as num?)?.toInt(),
    width: (json['width'] as num?)?.toInt(),
    codec: json['codec'] as String? ?? '',
    revision: json['revision'] as String? ?? '',
  );
}

/// A complete source file and a complete isolated track are distinct assets.
/// A video track can feed OCR/playback without claiming offline audio exists.
enum CacheContent { media, video, audio }

class CacheVariant {
  CacheVariant({
    required this.source,
    required this.quality,
    required this.path,
    required this.bytes,
    required this.createdAt,
    this.managed = true,
    this.pendingDelete = false,
    this.sha256 = '',
    this.modifiedMicros = 0,
    this.content = CacheContent.media,
    this.assetId,
  });
  final CacheSource source;
  final CacheQuality quality;
  final String path, sha256;
  final int bytes, createdAt;
  final bool managed;
  final CacheContent content;

  /// A separately published download can share a rendition with another file.
  /// Absent on existing managed variants, whose IDs remain unchanged.
  final String? assetId;
  bool get completeMedia => content == CacheContent.media;
  String get contentLabel => switch (content) {
    CacheContent.media => '已缓存',
    CacheContent.video => '视频轨已缓存',
    CacheContent.audio => '音轨已缓存',
  };
  bool pendingDelete;
  bool available = true;
  int modifiedMicros;
  String get id => cacheDigest(
    '${source.key}:${quality.revision}:${quality.id}:${quality.codec}${content == CacheContent.media ? '' : ':${content.name}'}${assetId == null ? '' : ':asset:$assetId'}',
  );
  Map<String, dynamic> toJson() => {
    'source': source.toJson(),
    'quality': quality.toJson(),
    'path': path,
    'bytes': bytes,
    'createdAt': createdAt,
    'managed': managed,
    'pendingDelete': pendingDelete,
    'sha256': sha256,
    'modifiedMicros': modifiedMicros,
    'content': content.name,
    if (assetId != null) 'assetId': assetId,
  };
  factory CacheVariant.fromJson(Map<String, dynamic> json) => CacheVariant(
    source: CacheSource.fromJson(
      Map<String, dynamic>.from(json['source'] as Map),
    ),
    quality: CacheQuality.fromJson(
      Map<String, dynamic>.from(json['quality'] as Map),
    ),
    path: json['path'] as String,
    bytes: (json['bytes'] as num).toInt(),
    createdAt: (json['createdAt'] as num).toInt(),
    managed: json['managed'] != false,
    pendingDelete: json['pendingDelete'] == true,
    sha256: json['sha256'] as String? ?? '',
    modifiedMicros: (json['modifiedMicros'] as num?)?.toInt() ?? 0,
    assetId: json['assetId'] as String?,
    content: CacheContent.values.firstWhere(
      (v) => v.name == json['content'],
      orElse: () => CacheContent.media,
    ),
  );
}

class CacheTask {
  CacheTask({
    required this.id,
    required this.source,
    required this.createdAt,
    this.requestedQuality,
    this.maxHeight,
    this.state = CacheTaskState.queued,
    this.quality,
    this.received = 0,
    this.total,
    this.fraction,
    this.error,
    this.workDirectory,
    this.outputDirectory,
    this.resume = const {},
    this.generation = 0,
  });
  final String id;
  final CacheSource source;
  final int createdAt;
  final String? requestedQuality;
  final int? maxHeight;
  CacheTaskState state;
  CacheQuality? quality;
  int received, generation;
  int? total;
  double? fraction;
  String? error, workDirectory, outputDirectory;
  Map<String, dynamic> resume;
  double bytesPerSecond = 0;
  double? get progress => state == CacheTaskState.completed
      ? 1
      : total != null && total! > 0
      ? (received / total!).clamp(0.0, 0.99)
      : fraction?.clamp(0.0, 0.99);
  Duration? get remaining =>
      total != null && total! >= received && bytesPerSecond > 0
      ? Duration(seconds: ((total! - received) / bytesPerSecond).ceil())
      : null;
  bool get unfinished => state != CacheTaskState.completed;
  Map<String, dynamic> toJson() => {
    'id': id,
    'source': source.toJson(),
    'createdAt': createdAt,
    'requestedQuality': requestedQuality,
    'maxHeight': maxHeight,
    'state': state.name,
    'quality': quality?.toJson(),
    'received': received,
    'total': total,
    'fraction': fraction,
    'error': error,
    'workDirectory': workDirectory,
    'outputDirectory': outputDirectory,
    'resume': resume,
    'generation': generation,
  };
  factory CacheTask.fromJson(Map<String, dynamic> json) => CacheTask(
    id: json['id'] as String,
    source: CacheSource.fromJson(
      Map<String, dynamic>.from(json['source'] as Map),
    ),
    createdAt: (json['createdAt'] as num).toInt(),
    requestedQuality: json['requestedQuality'] as String?,
    maxHeight: (json['maxHeight'] as num?)?.toInt(),
    state: CacheTaskState.values.firstWhere(
      (s) => s.name == json['state'],
      orElse: () => CacheTaskState.paused,
    ),
    quality: json['quality'] is Map
        ? CacheQuality.fromJson(
            Map<String, dynamic>.from(json['quality'] as Map),
          )
        : null,
    received: (json['received'] as num?)?.toInt() ?? 0,
    total: (json['total'] as num?)?.toInt(),
    fraction: (json['fraction'] as num?)?.toDouble(),
    error: json['error'] as String?,
    workDirectory: json['workDirectory'] as String?,
    outputDirectory: json['outputDirectory'] as String?,
    resume: Map<String, dynamic>.from(json['resume'] as Map? ?? {}),
    generation: (json['generation'] as num?)?.toInt() ?? 0,
  );
}

class MediaCachePreferences {
  MediaCachePreferences({
    Map<String, int?>? limits,
    this.pruneLower = true,
    this.parallelTasks = 2,
    this.connectionsPerTask = 4,
    this.connectionBudget = 8,
  }) : limits = {
         'bilibili': null,
         'baidu': null,
         'quark': null,
         'uc': null,
         'aliyun': null,
         ...?limits,
       };
  final Map<String, int?> limits;
  bool pruneLower;
  int parallelTasks, connectionsPerTask, connectionBudget;
  Map<String, dynamic> toJson() => {
    'limits': limits,
    'pruneLower': pruneLower,
    'parallelTasks': parallelTasks,
    'connectionsPerTask': connectionsPerTask,
    'connectionBudget': connectionBudget,
  };
  factory MediaCachePreferences.fromJson(Map<String, dynamic> json) =>
      MediaCachePreferences(
        limits: (json['limits'] as Map?)?.map(
          (k, v) => MapEntry('$k', (v as num?)?.toInt()),
        ),
        pruneLower: json['pruneLower'] != false,
        parallelTasks: ((json['parallelTasks'] as num?)?.toInt() ?? 2).clamp(
          1,
          8,
        ),
        connectionsPerTask: ((json['connectionsPerTask'] as num?)?.toInt() ?? 4)
            .clamp(1, 4),
        connectionBudget: ((json['connectionBudget'] as num?)?.toInt() ?? 8)
            .clamp(1, 16),
      );
}
