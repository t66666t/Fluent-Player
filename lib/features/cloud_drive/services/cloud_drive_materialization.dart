// Community edition: executable downloader implementation removed.
import '../../../services/app_storage_service.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:dio/dio.dart' show CancelToken;
import '../../../services/bilibili/media_connection_pool.dart';
import '../../../services/download_content_digest.dart';

import '../../../models/video_item.dart';
import '../../../services/media_materialization_service.dart';
import '../../../services/community_media_input.dart';
import '../../../services/network/network_http.dart';
import '../../../services/network/network_recovery.dart';
import '../models/cloud_drive_models.dart';
import '../providers/cloud_drive_http.dart';
import '../providers/cloud_drive_provider.dart';
import 'cloud_drive_account_repository.dart';
import 'cloud_drive_hls_plan.dart';
import 'cloud_drive_resume.dart';
import '../../media_cache/media_cache_reads.dart';
import '../../media_cache/media_cache_hooks.dart';
import '../../media_cache/media_cache_models.dart';
import '../../media_cache/cloud_cache_quality_resolver.dart';
import '../../../models/cloud_drive_source_ref.dart';

/// Signed URL plus the stable identity of one representation.
///
/// The URL is only for this transfer. Cache keys use the identity fields.
class CloudDriveDownloadSource {
  const CloudDriveDownloadSource({
    required this.uri,
    required this.transport,
    required this.providerId,
    required this.remoteAccountId,
    required this.driveId,
    required this.fileId,
    required this.revision,
    required this.representation,
    this.cookies = const <CloudDriveCookie>[],
    this.userAgent = '',
    this.referer = '',
    this.sizeBytes,
    this.containsAudio = true,
    this.audioFile = false,
    this.qualityLabel = '网盘文件',
    this.complete = true,
  });

  final Uri uri;
  final CloudDriveTransport transport;
  final String providerId;
  final String remoteAccountId;
  final String driveId;
  final String fileId;
  final String revision;
  final String representation;
  final List<CloudDriveCookie> cookies;
  final String userAgent;
  final String referer;
  final int? sizeBytes;
  final bool containsAudio;
  final bool audioFile;
  final String qualityLabel;
  final bool complete;

  factory CloudDriveDownloadSource.fromDescriptor(
    CloudDrivePlaybackDescriptor descriptor,
  ) {
    return CloudDriveDownloadSource(
      uri: descriptor.upstreamUri,
      transport: descriptor.transport,
      providerId: descriptor.providerId,
      remoteAccountId: descriptor.remoteAccountId,
      driveId: descriptor.driveId,
      fileId: descriptor.fileId,
      revision: descriptor.revision,
      representation: descriptor.quality.id,
      cookies: descriptor.cookies,
      userAgent: descriptor.userAgent,
      referer: descriptor.referer,
      sizeBytes: descriptor.sizeBytes,
      containsAudio: descriptor.mediaKind != CloudDriveMediaKind.unknown,
      audioFile: descriptor.mediaKind == CloudDriveMediaKind.audio,
      qualityLabel: descriptor.quality.label,
      complete:
          descriptor.complete &&
          (descriptor.transport == CloudDriveTransport.progressive ||
              descriptor.verifiedComplete),
    );
  }

  bool sameResource(CloudDriveDownloadSource other) =>
      providerId == other.providerId &&
      remoteAccountId == other.remoteAccountId &&
      driveId == other.driveId &&
      fileId == other.fileId &&
      revision == other.revision &&
      representation == other.representation;
}

class _StoredMaterial {
  const _StoredMaterial({
    required this.path,
    required this.size,
    required this.sha256,
    required this.containsAudio,
    required this.audioFile,
    required this.qualityLabel,
    required this.representation,
    this.sourceKey = '',
    this.revision = '',
    this.complete = true,
  });

  final String path;
  final int size;
  final String sha256;
  final bool containsAudio;
  final bool audioFile;
  final String qualityLabel;
  final String representation;
  final String sourceKey, revision;
  final bool complete;
}

typedef CloudDriveNativeDownload =
    Future<bool> Function(
      CloudDriveDownloadSource source,
      Uri uri,
      File target, {
      int? byteStart,
      int? byteLength,
      void Function(int received, int? total)? onBytes,
    });

/// Downloads cloud media into the existing materialization lease.
///
/// Progressive files resume with HTTP Range. HLS resumes by completed
/// segment, then assembles a real container. A partial file is never leased.
class CloudDriveMaterialization {
  CloudDriveMaterialization({
    CloudDriveProviderRegistry? providers,
    CloudDriveAccountRepository? accounts,
    Directory? cacheRoot,
    this.resolveOverride,
    this.reserveSpace,
    this.retryDelays = NetworkRecovery.retryDelays,
    this.maxParallelSegments = 1,
    this.connectionPool,
    this.muxHls,
    this.joinHlsSegments,
    this.nativeDownload,
    this.onReadable,
    this.requireCompletePlaylist = false,
    this.parallelProgressive = true,
    this.verifyContent = true,
  }) : _providers = providers,
       _accounts = accounts,
       _cacheRoot = cacheRoot;

  final CloudDriveProviderRegistry? _providers;
  final CloudDriveAccountRepository? _accounts;
  final Directory? _cacheRoot;
  final Future<CloudDriveDownloadSource> Function(VideoItem item)?
  resolveOverride;
  final Future<void> Function(int additionalBytes)? reserveSpace;
  final List<Duration> retryDelays;
  final int maxParallelSegments;
  final BilibiliMediaConnectionPool? connectionPool;
  final Future<File> Function(File video, File audio, File output)? muxHls;
  final Future<File> Function(
    List<File> segments,
    List<int> durationsMs,
    File output,
  )?
  joinHlsSegments;
  final CloudDriveNativeDownload? nativeDownload;
  final bool requireCompletePlaylist;
  final bool parallelProgressive;

  /// Active offline caching opts out of full-file hashing. Other materialization
  /// clients retain their existing validation policy until changed explicitly.
  final bool verifyContent;
  final void Function(
    CloudDriveDownloadSource source,
    Uri uri,
    File file,
    int resourceStart,
    int availableBytes,
    int total,
    bool complete,
  )?
  onReadable;

  final Map<String, Future<_StoredMaterial>> _operations = {};
  final Map<String, Map<String, List<String>>> _baiduBackups = {};
  final Map<String, Map<String, String>> _baiduPreferred = {};
  bool _storageClosed = false;
  Future<void> prepareStorageMigration() async {
    _storageClosed = true;
    for (final client in _clients.values.expand((c) => c).toList()) {
      client.close(force: true);
    }
    await Future.wait(
      _operations.values.toList().map((future) async {
        try {
          await future;
        } catch (_) {
          /* resumable data remains on disk */
        }
      }),
    );
  }

  final Map<String, int> _waiters = {};
  final Map<String, int> _leases = {};
  final Map<String, Set<HttpClient>> _clients = {};
  final Map<HttpClient, int> _clientUsers = {};
  final Map<String, Set<String>> _transportScopes = {};
  final Map<String, CancelToken> _cancelTokens = {};
  void _closeClients(String id) {
    for (final client in _clients.remove(id) ?? <HttpClient>{}) {
      client.close(force: true);
    }
    _cancelTokens[id]?.cancel('素材下载已暂停');
    for (final scope in _transportScopes.remove(id) ?? <String>{}) {
      CloudDriveClientPools.discard(scope: scope);
    }
  }

  final Set<String> _paused = {};
  final Map<String, _StoredMaterial> _memory = {};
  var _active = 0;
  final List<Completer<void>> _slots = [];

  static const int maxConcurrentDownloads = 1;

  /// Local video already verified for this card, if this process has sealed it.
  String? readyLocalVideoPath(String itemId) => _byItem[itemId];

  final Map<String, String> _byItem = {};
  final Map<String, String> _directoryByIdentity = {};

  /// Directories with an acquire, waiter or lease. Paths come from [_directory].
  Set<String> get storageProtectedDirectories {
    final keys = <String>{
      ..._operations.keys,
      for (final entry in _waiters.entries)
        if (entry.value > 0) entry.key,
      for (final entry in _leases.entries)
        if (entry.value > 0) entry.key,
    };
    return {
      for (final key in keys)
        if (_directoryByIdentity[key] != null) _directoryByIdentity[key]!,
    };
  }

  /// Drops cached paths after the storage page deleted those exact files.
  void forgetDeletedStorage(Iterable<String> paths) {
    final gone = paths.map(_storageKey).toSet();
    _memory.removeWhere(
      (dir, stored) =>
          gone.contains(_storageKey(stored.path)) ||
          gone.contains(_storageKey(dir)),
    );
    _byItem.removeWhere(
      (_, path) => gone.contains(_storageKey(path)) || !File(path).existsSync(),
    );
  }

  String _storageKey(String path) =>
      Platform.isWindows ? p.normalize(path).toLowerCase() : p.normalize(path);

  Future<void> loadIndex() async {
    final root = await _root();
    if (!await root.exists()) return;
    await for (final entity in root.list()) {
      if (entity is! Directory) continue;
      final stored = await _readManifest(entity);
      if (stored == null) continue;
      _memory[entity.path] = stored;
    }
  }

  Future<MediaMaterializationEstimate> estimate(
    VideoItem item,
    MediaMaterializationRequirement requirement,
  ) async {
    requireCommunityLocalMedia(item.path);
    final cached = await _cached(item);
    if (cached != null && _satisfies(cached, requirement)) {
      _byItem[item.id] = cached.path;
      return MediaMaterializationEstimate(
        estimatedBytes: 0,
        qualityId: null,
        width: null,
        height: null,
        qualityLabel: '使用已缓存素材 · ${cached.qualityLabel}',
        alreadyAvailable: true,
        requiresVideoDownload: false,
        requiresAudioDownload: false,
      );
    }
    final source = await _resolve(item);
    final needsVideo =
        requirement != MediaMaterializationRequirement.audioOnly ||
        !source.audioFile;
    return MediaMaterializationEstimate(
      estimatedBytes: source.sizeBytes,
      qualityId: null,
      width: null,
      height: null,
      qualityLabel: source.audioFile
          ? source.qualityLabel
          : requirement == MediaMaterializationRequirement.audioOnly
          ? '${source.qualityLabel} · 需下载视频以提取音频'
          : source.qualityLabel,
      alreadyAvailable: false,
      requiresVideoDownload: needsVideo && cached == null,
      requiresAudioDownload: false,
    );
  }

  Future<MaterializedMediaLease> acquire(
    VideoItem item,
    MediaMaterializationRequirement requirement, {
    void Function(MediaMaterializationProgress progress)? onProgress,
    Future<void>? cancelSignal,
  }) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  /// Stops the transfer and keeps the partial file for the next acquire.
  void pause(String itemId) {
    _paused.add(itemId);
    _closeClients(itemId);
  }

  Future<void> discard(VideoItem item) async {
    final key = _identity(item);
    if ((_leases[key] ?? 0) > 0 || _operations.containsKey(key)) {
      throw StateError('素材正在使用，不能清理');
    }
    final dir = Directory(await _directory(item));
    if (await dir.exists()) await dir.delete(recursive: true);
    _memory.remove(dir.path);
    _byItem.remove(item.id);
  }

  Future<_StoredMaterial> _download(
    VideoItem item,
    MediaMaterializationRequirement requirement,
    void Function(MediaMaterializationProgress progress)? onProgress,
  ) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  Future<File> _downloadProgressive(
    VideoItem item,
    CloudDriveDownloadSource source,
    String message,
    void Function(MediaMaterializationProgress progress)? onProgress,
  ) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  Future<File?> _downloadProgressiveRanges(
    VideoItem item,
    CloudDriveDownloadSource source,
    String message,
    void Function(MediaMaterializationProgress)? onProgress,
  ) async {
    return null;
  }

  Future<File> _downloadHls(
    VideoItem item,
    CloudDriveDownloadSource source,
    String message,
    void Function(MediaMaterializationProgress progress)? onProgress,
  ) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  Future<void> _downloadNamed(
    VideoItem item,
    CloudDriveDownloadSource source,
    Uri uri,
    File target,
  ) async {}

  Future<void> _downloadNamedOnce(
    VideoItem item,
    CloudDriveDownloadSource source,
    Uri uri,
    File target, {
    required Uri resourceUri,
    required bool retry,
    required Duration headerTimeout,
  }) async {}

  Future<_StoredMaterial> _seal(
    VideoItem item,
    CloudDriveDownloadSource source,
    File file, {
    String? downloadDigest,
  }) async {
    final bytes = await file.length();
    if (source.sizeBytes != null &&
        source.transport != CloudDriveTransport.hls &&
        bytes != source.sizeBytes) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.unavailable,
        '下载大小和网盘记录不一致',
      );
    }
    final digest = verifyContent ? downloadDigest ?? await _hash(file) : '';
    final manifest = <String, Object?>{
      'schema': 2,
      'kind': 'cloudDrive',
      'providerId': source.providerId,
      'remoteAccountId': source.remoteAccountId,
      'driveId': source.driveId,
      'fileId': source.fileId,
      'revision': source.revision,
      'representation': source.representation,
      'path': p.basename(file.path),
      'size': bytes,
      'sha256': digest,
      'containsAudio': source.containsAudio,
      'audioFile': source.audioFile,
      'qualityLabel': source.qualityLabel,
      'itemId': item.id,
      'completeSource': source.complete,
    };
    final dir = file.parent;
    final temp = File(p.join(dir.path, 'manifest.json.tmp'));
    await temp.writeAsString(
      jsonEncode(AppStorageService.instance.encodePaths(manifest)),
      flush: true,
    );
    final dest = File(p.join(dir.path, 'manifest.json'));
    if (await dest.exists()) await dest.delete();
    await temp.rename(dest.path);
    final stored = _StoredMaterial(
      path: file.path,
      size: bytes,
      sha256: digest,
      containsAudio: source.containsAudio,
      audioFile: source.audioFile,
      qualityLabel: source.qualityLabel,
      representation: source.representation,
      sourceKey: cloudDriveSourceKey(
        providerId: source.providerId,
        remoteAccountId: source.remoteAccountId,
        driveId: source.driveId,
        fileId: source.fileId,
      ),
      revision: source.revision,
      complete: source.complete,
    );
    _memory[dir.path] = stored;
    if (!stored.audioFile) _byItem[item.id] = stored.path;
    try {
      final variant = await _cacheVariant(item, stored);
      if (variant != null) await MediaCacheHooks.publish?.call([variant]);
    } catch (_) {
      /* Cache indexing must not turn a sealed OCR source into a failed download. */
    }
    return stored;
  }

  Future<CacheVariant?> _cacheVariant(
    VideoItem item,
    _StoredMaterial stored,
  ) async {
    final source = CacheSource.fromItem(item);
    if (source == null ||
        !stored.complete ||
        source.key != stored.sourceKey ||
        (source.ref.cloudDrive?.revision?.isNotEmpty == true &&
            source.ref.cloudDrive!.revision != stored.revision)) {
      return null;
    }
    final stat = await File(stored.path).stat();
    if (stat.type != FileSystemEntityType.file ||
        stat.size != stored.size ||
        stat.size <= 0) {
      return null;
    }
    return CacheVariant(
      source: source,
      quality: CacheQuality(
        id: stored.representation,
        label: stored.qualityLabel,
        height: cloudCacheQualityHeight(
          stored.representation,
          stored.qualityLabel,
        ),
        revision: stored.revision,
      ),
      path: stored.path,
      bytes: stored.size,
      createdAt: stat.modified.millisecondsSinceEpoch,
      content: stored.audioFile || stored.containsAudio
          ? CacheContent.media
          : CacheContent.video,
    );
  }

  bool _cacheIndexLoaded = false;
  Future<List<CacheVariant>> cacheVariants(VideoItem item) async {
    if (!_cacheIndexLoaded) {
      await loadIndex();
      _cacheIndexLoaded = true;
    }
    final result = <CacheVariant>[];
    for (final stored in _memory.values.toList()) {
      final variant = await _cacheVariant(item, stored);
      if (variant != null) result.add(variant);
    }
    return result;
  }

  MaterializedMediaLease _lease(
    VideoItem item,
    _StoredMaterial stored,
    MediaMaterializationRequirement requirement,
  ) {
    final key = _identity(item);
    _leases[key] = (_leases[key] ?? 0) + 1;
    _byItem[item.id] = stored.path;
    final audio = requirement == MediaMaterializationRequirement.videoFrames
        ? null
        : stored.containsAudio
        ? stored.path
        : null;
    final video = stored.audioFile ? null : stored.path;
    return MaterializedMediaLease(
      videoId: item.id,
      audioPath: audio,
      videoPath: video ?? stored.path,
      completePath: stored.audioFile ? null : stored.path,
      qualityId: null,
      width: null,
      height: null,
      onRelease: () async {
        final left = (_leases[key] ?? 1) - 1;
        if (left <= 0) {
          _leases.remove(key);
        } else {
          _leases[key] = left;
        }
      },
    );
  }

  bool _satisfies(
    _StoredMaterial stored,
    MediaMaterializationRequirement requirement,
  ) {
    if (requirement == MediaMaterializationRequirement.audioOnly) {
      return stored.containsAudio;
    }
    if (stored.audioFile) return false;
    if (requirement == MediaMaterializationRequirement.completeMedia) {
      return stored.containsAudio;
    }
    return true;
  }

  Future<List<CacheQuality>> videoQualities(VideoItem item) async {
    final cloud = await _playbackRequest(item);
    final qualities = await cloud.provider.discoverQualities(cloud.request);
    return [
      for (final quality in qualities)
        if (quality.selectable)
          CacheQuality(
            id: quality.id,
            label: quality.label,
            height: cloudCacheQualityHeight(quality.id, quality.label),
          ),
    ];
  }

  Future<CloudDriveDownloadSource> _resolve(VideoItem item) async {
    final override = resolveOverride;
    if (override != null) return override(item);
    final cloud = await _playbackRequest(item);
    final descriptor = await resolveCloudCacheQuality(
      cloud.provider,
      cloud.request,
    );
    return CloudDriveDownloadSource.fromDescriptor(descriptor);
  }

  Future<({CloudDriveProvider provider, CloudDrivePlaybackRequest request})>
  _playbackRequest(VideoItem item) async {
    final cloud = item.sourceRef?.cloudDrive;
    final providers = _providers;
    final accounts = _accounts;
    if (cloud == null || providers == null || accounts == null) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.unavailable,
        '网盘素材服务尚未初始化',
      );
    }
    final account = accounts.findRemote(
      cloud.providerId,
      cloud.remoteAccountId,
    );
    final provider = providers[cloud.providerId];
    final credential = account == null
        ? null
        : await accounts.credentialFor(account);
    if (account == null ||
        provider == null ||
        credential == null ||
        account.authState == CloudDriveAuthState.needsLogin) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.notLoggedIn,
        '需要重新登录后才能下载网盘素材',
      );
    }
    return (
      provider: provider,
      request: CloudDrivePlaybackRequest(
        credential: credential,
        accountLocalId: account.localId,
        remoteAccountId: account.remoteAccountId,
        driveId: cloud.driveId,
        fileId: cloud.fileId,
        pathHint: cloud.pathHint,
        name: item.title,
        durationMs: item.durationMs > 0 ? item.durationMs : null,
        preferredQualityId: cloud.preferredQuality,
        revision: cloud.revision,
        playbackSessionId: item.id,
      ),
    );
  }

  Future<_StoredMaterial?> _cached(VideoItem item) async {
    final dir = Directory(await _directory(item));
    final stored = await _readManifest(dir);
    if (stored == null) return null;
    final file = File(stored.path);
    if (!await file.exists() || await file.length() != stored.size) return null;
    if (verifyContent) {
      if (stored.sha256.isEmpty || await _hash(file) != stored.sha256) {
        return null;
      }
    }
    _memory[dir.path] = stored;
    if (!stored.audioFile) _byItem[item.id] = stored.path;
    return stored;
  }

  Future<_StoredMaterial?> _readManifest(Directory dir) async {
    final file = File(p.join(dir.path, 'manifest.json'));
    if (!await file.exists()) return null;
    try {
      final json = AppStorageService.instance.decodePaths(
        jsonDecode(await file.readAsString()),
      );
      if (json is! Map || json['schema'] != 2 || json['kind'] != 'cloudDrive') {
        return null;
      }
      final name = json['path']?.toString() ?? '';
      if (name.isEmpty || p.basename(name) != name) return null;
      return _StoredMaterial(
        path: p.join(dir.path, name),
        size: json['size'] is int ? json['size'] as int : 0,
        sha256: json['sha256']?.toString() ?? '',
        containsAudio: json['containsAudio'] != false,
        audioFile: json['audioFile'] == true,
        qualityLabel: json['qualityLabel']?.toString() ?? '网盘文件',
        representation: json['representation']?.toString() ?? '',
        sourceKey: cloudDriveSourceKey(
          providerId: json['providerId']?.toString() ?? '',
          remoteAccountId: json['remoteAccountId']?.toString() ?? '',
          driveId: json['driveId']?.toString() ?? '',
          fileId: json['fileId']?.toString() ?? '',
        ),
        revision: json['revision']?.toString() ?? '',
        complete: json['completeSource'] != false,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeBody(
    String itemId,
    _OpenedResponse opened,
    File part, {
    required bool append,
    required int? total,
    required int already,
    required String message,
    required void Function(MediaMaterializationProgress progress)? onProgress,
    required String revision,
    required String representation,
    required String? etag,
    DownloadContentDigest? contentDigest,
    void Function(int received)? onReadable,
  }) async {
    final extra = opened.contentLength ?? 0;
    if (reserveSpace != null && extra > 0) await reserveSpace!(extra);
    final checkpoint = File('${part.path}.json');
    await writeStorageJson(checkpoint, {
      'revision': revision,
      'representation': representation,
      'etag': etag,
      'localBytes': already,
    });
    final sink = part.openWrite(
      mode: append ? FileMode.append : FileMode.write,
    );
    var received = already;
    var lastReport = DateTime.now();
    Object? failure;
    try {
      await for (final chunk in opened.response.timeout(
        const Duration(seconds: 30),
      )) {
        _throwIfPaused(itemId);
        sink.add(chunk);
        contentDigest?.add(chunk);
        received += chunk.length;
        final now = DateTime.now();
        if (now.difference(lastReport) > const Duration(milliseconds: 200)) {
          lastReport = now;
          onReadable?.call(received);
          onProgress?.call(
            MediaMaterializationProgress(
              stage: MediaMaterializationStage.downloadingVideo,
              progress: total == null || total == 0 ? 0 : received / total,
              message: message,
              receivedBytes: received,
              totalBytes: total,
            ),
          );
        }
      }
      await sink.flush();
      onReadable?.call(received);
    } catch (error) {
      failure = error;
    } finally {
      await sink.close();
    }
    if (await part.exists()) {
      await writeStorageJson(checkpoint, {
        'revision': revision,
        'representation': representation,
        'etag': etag,
        'localBytes': await part.length(),
      });
    }
    if (_paused.contains(itemId) || failure is StateError) {
      _paused.remove(itemId);
      throw StateError('下载已暂停，已保留已下载的部分');
    }
    if (failure != null) throw failure;
  }

  Future<bool> _checkpointMatches(
    File part,
    CloudDriveDownloadSource source,
  ) async {
    final file = File('${part.path}.json');
    if (!await file.exists()) return false;
    try {
      final json = AppStorageService.instance.decodePaths(
        await readStorageJson(file),
      );
      return json is Map &&
          json['revision'] == source.revision &&
          json['representation'] == source.representation;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _checkpointEtag(File part) async {
    final file = File('${part.path}.json');
    if (!await file.exists()) return null;
    try {
      final json = AppStorageService.instance.decodePaths(
        await readStorageJson(file),
      );
      return json is Map ? json['etag']?.toString() : null;
    } catch (_) {
      return null;
    }
  }

  Future<File> _promotePart(File part, File target) async {
    await CacheFileAccess.mutate(part.path, () async {
      if (await target.exists()) await target.delete();
      await part.rename(target.path);
    });
    return target;
  }

  Future<_OpenedResponse> _open(
    String itemId,
    CloudDriveDownloadSource source, {
    Uri? uri,
    int? rangeStart,
    int? rangeEnd,
    String? ifRange,
    bool retry = true,
    Duration headerTimeout = const Duration(seconds: 30),
  }) async {
    for (var attempt = 0; ; attempt++) {
      _throwIfPaused(itemId);
      try {
        return await _openOnce(
          itemId,
          source,
          uri: uri,
          rangeStart: rangeStart,
          rangeEnd: rangeEnd,
          ifRange: ifRange,
          headerTimeout: headerTimeout,
        );
      } catch (error) {
        _throwIfPaused(itemId);
        if (!retry ||
            attempt >= retryDelays.length ||
            !NetworkRecovery.isTransient(error)) {
          rethrow;
        }
        await NetworkRecovery.wait(
          NetworkRecovery.retryDelay(error, retryDelays[attempt]),
          checkCancelled: () => _throwIfPaused(itemId),
        );
      }
    }
  }

  Future<_OpenedResponse> _openOnce(
    String itemId,
    CloudDriveDownloadSource source, {
    Uri? uri,
    int? rangeStart,
    int? rangeEnd,
    String? ifRange,
    Duration headerTimeout = const Duration(seconds: 30),
  }) async {
    final permit = await connectionPool?.acquire(
      cancelToken: _cancelTokens[itemId],
    );
    try {
      _throwIfPaused(itemId);
    } catch (_) {
      permit?.release();
      rethrow;
    }
    final scope = 'material:${identityHashCode(this)}:$itemId';
    final generation = cloudDriveNetworkGeneration();
    _transportScopes.putIfAbsent(itemId, () => {}).add(scope);
    HttpClient client;
    try {
      client = CloudDriveClientPools.checkout(
        scope: scope,
        generation: generation,
        createClient: () => NetworkHttp.instance.createClient(
          scope: NetworkScope.cloudDrive,
          source: uri ?? source.uri,
        ),
      );
    } catch (_) {
      permit?.release();
      rethrow;
    }
    _clients.putIfAbsent(itemId, () => {}).add(client);
    _clientUsers[client] = (_clientUsers[client] ?? 0) + 1;
    var released = false;
    void release() {
      if (released) return;
      released = true;
      final users = (_clientUsers[client] ?? 1) - 1;
      if (users <= 0) {
        _clientUsers.remove(client);
        _clients[itemId]?.remove(client);
      } else {
        _clientUsers[client] = users;
      }
      CloudDriveClientPools.release(scope: scope, generation: generation);
      permit?.release();
    }

    client.userAgent = source.userAgent;
    var current = uri ?? source.uri;
    HttpClientRequest? activeRequest;
    try {
      for (var hop = 0; hop < 5; hop++) {
        final request = await openNetworkRequest(
          client,
          'GET',
          current,
          timeout: headerTimeout,
          cancelSignal: _cancelTokens[itemId]?.whenCancel,
        );
        activeRequest = request;
        request.followRedirects = false;
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        if (source.userAgent.isNotEmpty) {
          request.headers.set(HttpHeaders.userAgentHeader, source.userAgent);
        }
        if (source.referer.isNotEmpty) {
          request.headers.set(HttpHeaders.refererHeader, source.referer);
        }
        final cookie = CloudDriveCredential(
          cookies: source.cookies,
        ).headerFor(current);
        if (cookie.isNotEmpty) {
          request.headers.set(HttpHeaders.cookieHeader, cookie);
        }
        if (rangeStart != null) {
          request.headers.set(
            HttpHeaders.rangeHeader,
            rangeEnd == null
                ? 'bytes=$rangeStart-'
                : 'bytes=$rangeStart-$rangeEnd',
          );
          if (ifRange != null && ifRange.isNotEmpty) {
            request.headers.set(HttpHeaders.ifRangeHeader, ifRange);
          }
        }
        final response = await request.close().timeout(headerTimeout);
        if (NetworkRecovery.transientStatus(response.statusCode)) {
          final hint = response.headers.value(HttpHeaders.retryAfterHeader);
          await response.listen((_) {}).cancel();
          throw RecoverableMediaHttpException(
            response.statusCode,
            retryAfter: hint,
          );
        }
        if (response.statusCode >= 300 && response.statusCode < 400) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          await response.listen((_) {}).cancel();
          if (location == null || location.isEmpty) break;
          current = resolveCloudDriveRedirect(current, location);
          continue;
        }
        final range = parseContentRange(
          response.headers.value(HttpHeaders.contentRangeHeader),
        );
        final length = response.contentLength >= 0
            ? response.contentLength
            : null;
        return _OpenedResponse(
          status: response.statusCode,
          response: response,
          client: client,
          finalUri: current,
          range: range,
          total: range?.total ?? (rangeStart == null ? length : null),
          contentLength: length,
          etag: response.headers.value(HttpHeaders.etagHeader),
          encoding: response.headers.value(HttpHeaders.contentEncodingHeader),
          closeClient: false,
          onClosed: release,
        );
      }
      throw const CloudDriveFailure(CloudDriveFailureKind.network, '下载重定向次数过多');
    } catch (_) {
      activeRequest?.abort();
      release();
      rethrow;
    }
  }

  Future<void> _acquireSlot() async {
    if (_active < maxConcurrentDownloads) {
      _active++;
      return;
    }
    final gate = Completer<void>();
    _slots.add(gate);
    await gate.future;
    _active++;
  }

  void _releaseSlot() {
    _active--;
    if (_slots.isNotEmpty) _slots.removeAt(0).complete();
  }

  void _throwIfPaused(String itemId) {
    if (_storageClosed) throw StateError('存储迁移已暂停下载，断点已保留');
    if (_paused.contains(itemId) ||
        _cancelTokens[itemId]?.isCancelled == true) {
      throw StateError('下载已暂停，已保留已下载的部分');
    }
  }

  CloudDriveDownloadSource _retarget(
    CloudDriveDownloadSource source,
    Uri uri, {
    String? representation,
  }) {
    return CloudDriveDownloadSource(
      uri: uri,
      transport: source.transport,
      providerId: source.providerId,
      remoteAccountId: source.remoteAccountId,
      driveId: source.driveId,
      fileId: source.fileId,
      revision: source.revision,
      representation: representation ?? source.representation,
      cookies: source.cookies,
      userAgent: source.userAgent,
      referer: source.referer,
      sizeBytes: source.sizeBytes,
      containsAudio: source.containsAudio,
      audioFile: source.audioFile,
      qualityLabel: source.qualityLabel,
    );
  }

  String _identity(VideoItem item) {
    final cloud = item.sourceRef?.cloudDrive;
    return [
      item.id,
      cloud?.providerId ?? '',
      cloud?.remoteAccountId ?? '',
      cloud?.fileId ?? '',
      cloud?.revision ?? '',
      cloud?.preferredQuality ?? 'original',
    ].join('|');
  }

  Future<Directory> _root() async {
    final root = _cacheRoot;
    if (root != null) return root;
    throw const CloudDriveFailure(
      CloudDriveFailureKind.unavailable,
      '还没有素材缓存目录',
    );
  }

  Future<String> _directory(
    VideoItem item, [
    CloudDriveDownloadSource? source,
  ]) async {
    final cloud = item.sourceRef?.cloudDrive;
    final canonical = [
      source?.providerId ?? cloud?.providerId ?? '',
      source?.remoteAccountId ?? cloud?.remoteAccountId ?? '',
      source?.driveId ?? cloud?.driveId ?? '',
      source?.fileId ?? cloud?.fileId ?? '',
      source?.revision ?? cloud?.revision ?? '',
      source?.representation ?? cloud?.preferredQuality ?? 'original',
    ].join('\n');
    final hash = sha256.convert(utf8.encode(canonical)).toString();
    return p.join((await _root()).path, hash);
  }

  Future<Set<int>> _readHlsCheckpoint(File file, HlsMediaPlan plan) async {
    try {
      final json = AppStorageService.instance.decodePaths(
        await readStorageJson(file),
      );
      if (json is! Map || json['fingerprint'] != plan.fingerprint) {
        return <int>{};
      }
      final raw = json['done'];
      if (raw is! List) return <int>{};
      return raw.whereType<int>().toSet();
    } catch (_) {
      return <int>{};
    }
  }

  Future<void> _writeHlsCheckpoint(
    File file,
    HlsMediaPlan plan,
    Set<int> done,
  ) async {
    await writeStorageJson(file, {
      'fingerprint': plan.fingerprint,
      'done': done.toList()..sort(),
    });
  }

  Future<String> _hash(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  Future<List<int>> _prefix(File file) async {
    final handle = await file.open();
    try {
      return await handle.read(16);
    } finally {
      await handle.close();
    }
  }

  String _requirementLabel(MediaMaterializationRequirement requirement) {
    return switch (requirement) {
      MediaMaterializationRequirement.audioOnly => '音频',
      MediaMaterializationRequirement.videoFrames => '视频画面',
      MediaMaterializationRequirement.completeMedia => '完整视频',
    };
  }
}

class _OpenedResponse {
  _OpenedResponse({
    required this.status,
    required this.response,
    required this.client,
    required this.finalUri,
    required this.range,
    required this.total,
    required this.contentLength,
    required this.etag,
    required this.encoding,
    this.onClosed,
    this.closeClient = true,
  });

  final int status;
  final HttpClientResponse response;
  final HttpClient client;
  final Uri finalUri;
  final ParsedContentRange? range;
  final int? total;
  final int? contentLength;
  final String? etag;
  final String? encoding;
  final void Function()? onClosed;
  final bool closeClient;
  bool _closed = false;

  Future<void> discard() => response.listen((_) {}).cancel();

  Future<String> readText() async {
    final bytes = await readNetworkResponseBytes(
      response,
      maxBytes: 8 * 1024 * 1024,
      totalTimeout: const Duration(seconds: 30),
    );
    return utf8.decode(bytes, allowMalformed: true);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (closeClient) client.close(force: false);
    onClosed?.call();
  }
}
