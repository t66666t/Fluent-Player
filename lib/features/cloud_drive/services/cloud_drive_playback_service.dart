import '../../../services/community_media_input.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../../models/cloud_drive_source_ref.dart';
import '../../../models/media_source_ref.dart';
import '../../../models/video_item.dart';
import '../models/cloud_drive_models.dart';
import '../models/cloud_drive_quality_order.dart';
import '../providers/cloud_drive_http.dart';
import '../providers/cloud_drive_provider.dart';
import '../../../services/storage_runtime_registry.dart';
import 'cloud_drive_account_repository.dart';
import 'cloud_drive_stream_gateway.dart';
import '../../media_cache/media_cache_hooks.dart';

class CloudDrivePreparedPlayback {
  const CloudDrivePreparedPlayback({
    required this.lease,
    required this.qualities,
    required this.selectedQualityId,
    required this.transcoded,
    required this.notice,
    required this.mediaKind,
    required this.playbackSessionId,
    this.durationMs,
    this.backgroundQualities,
    this.firstVerifiedFallback,
    this.operationDeadline,
  });

  final CloudDrivePlaybackLease lease;
  final List<CloudDriveQualityChoice> qualities;
  final String selectedQualityId;
  final bool transcoded;
  final String notice;
  final CloudDriveMediaKind mediaKind;
  final String playbackSessionId;
  final int? durationMs;

  /// Rungs probed after the first source is already playing.
  final Future<List<CloudDriveQualityChoice>>? backgroundQualities;

  /// Completes when one verified transcode exists, before the ladder finishes.
  final Future<CloudDrivePlaybackDescriptor?>? firstVerifiedFallback;

  /// Shared with the caller so a fallback cannot start a fresh long wait.
  final DateTime? operationDeadline;
}

class CloudDriveCachedSubtitle {
  const CloudDriveCachedSubtitle({
    required this.track,
    required this.path,
    required this.autoSelect,
  });

  final CloudDriveSubtitleTrack track;
  final String path;
  final bool autoSelect;
}

/// Resolves one file into a loopback lease the existing player can open.
class CloudDrivePlaybackService {
  CloudDrivePlaybackService({
    required CloudDriveProviderRegistry providers,
    required CloudDriveAccountRepository accounts,
    CloudDriveStreamGateway? gateway,
    Directory? subtitleCacheRoot,
    String Function()? sessionIdFactory,
  }) : _providers = providers,
       _accounts = accounts,
       _gateway = gateway ?? CloudDriveStreamGateway(),
       _subtitleCacheRoot = subtitleCacheRoot,
       _sessionIdFactory = sessionIdFactory ?? _defaultSessionId;

  final CloudDriveProviderRegistry _providers;
  final CloudDriveAccountRepository _accounts;
  final CloudDriveStreamGateway _gateway;
  final Directory? _subtitleCacheRoot;
  Directory? _fallbackCache;
  final String Function() _sessionIdFactory;
  final List<String> _diagnostic = <String>[];
  var _gatewayWired = false;
  String? subtitleDiscoveryNote;
  final Map<String, ({CloudDrivePlaybackDescriptor descriptor, DateTime at})>
  _qualityCache = {};

  CloudDriveStreamGateway get gateway => _gateway;
  String get diagnosticText => _diagnostic.join('\n');

  Future<CloudDrivePreparedPlayback> open(
    VideoItem item, {
    String? qualityId,
    bool refresh = false,
    DateTime? operationDeadline,
    Object? cancelToken,
  }) async {
    requireCommunityAuthorizedCloudDrive();
    final cachedMedia = await MediaCacheHooks.openCloud?.call(
      item,
      qualityId: qualityId,
    );
    if (cachedMedia != null) return cachedMedia;
    _wireRefresh();
    final source = item.sourceRef?.cloudDrive;
    if (source == null) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.unsupported,
        '这张卡片没有网盘来源',
      );
    }
    final account = _accounts.findRemote(
      source.providerId,
      source.remoteAccountId,
    );
    if (account == null ||
        account.authState == CloudDriveAuthState.needsLogin) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.notLoggedIn,
        '需要重新登录后才能播放',
      );
    }
    final provider = _providers[source.providerId];
    final credential = await _accounts.credentialFor(account);
    if (provider == null || credential == null) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.notLoggedIn,
        '需要重新登录后才能播放',
      );
    }
    final playbackSessionId = _sessionIdFactory();
    final request = _request(
      item: item,
      source: source,
      account: account,
      credential: credential,
      qualityId: qualityId ?? source.preferredQuality,
      playbackSessionId: playbackSessionId,
    );
    _log(
      'resolve start session=$playbackSessionId provider=${provider.id} '
      'quality=${request.preferredQualityId ?? 'auto'}',
    );
    final cacheKey = _descriptorCacheKey(request);
    final cached = !refresh ? _qualityCache[cacheKey] : null;
    final cacheFresh =
        cached != null &&
        DateTime.now().difference(cached.at) < const Duration(minutes: 2) &&
        (cached.descriptor.expiresAt == null ||
            cached.descriptor.expiresAt!.isAfter(
              DateTime.now().add(const Duration(seconds: 15)),
            ));
    // A known rung, including the last automatic choice, skips another full
    // discovery. The signed URL and playlist snapshot still expire.
    late final CloudDrivePlaybackDescriptor descriptor;
    try {
      descriptor = cacheFresh
          ? cached.descriptor.copyWith(playbackSessionId: playbackSessionId)
          : await provider.resolvePlayback(request, cancelToken: cancelToken);
    } on CloudDriveFailure catch (error) {
      _log(
        'resolve failed session=$playbackSessionId provider=${provider.id} '
        'kind=${error.kind.name}'
        '${error.diagnostic == null ? '' : ' ${error.diagnostic}'}',
      );
      rethrow;
    } catch (error) {
      _log(
        'resolve failed session=$playbackSessionId provider=${provider.id} '
        'type=${error.runtimeType}',
      );
      rethrow;
    }
    if (!cacheFresh) {
      _qualityCache[cacheKey] = (descriptor: descriptor, at: DateTime.now());
      final selectedKey = _descriptorCacheKey(
        _request(
          item: item,
          source: source,
          account: account,
          credential: credential,
          qualityId: descriptor.quality.id,
          playbackSessionId: playbackSessionId,
        ),
      );
      _qualityCache[selectedKey] = (descriptor: descriptor, at: DateTime.now());
    }
    if (!descriptor.complete) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.previewOnly,
        '当前只拿到试看流，不能当作完整视频播放',
      );
    }
    if (qualityId != null && descriptor.quality.id != qualityId) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.unavailable,
        '所选画质暂时不可用，已保留当前画质',
      );
    }
    final tagged = descriptor.playbackSessionId.isEmpty
        ? descriptor.copyWith(playbackSessionId: playbackSessionId)
        : descriptor;
    final lease = await _gateway.open(
      descriptor: tagged,
      accountLocalId: account.localId,
    );
    final qualities = <CloudDriveQualityChoice>[...tagged.qualities];
    if (tagged.mediaKind != CloudDriveMediaKind.audio && qualityId == null) {
      for (final placeholder in provider.qualityPlaceholders(request)) {
        if (qualities.every((item) => item.id != placeholder.id)) {
          qualities.add(placeholder);
        }
      }
    }
    final discovery =
        tagged.mediaKind == CloudDriveMediaKind.audio || qualityId != null
        ? null
        : provider.beginQualityDiscovery(request);
    final notice = _notice(tagged);
    _log(
      'resolve done session=$playbackSessionId transport=${tagged.transport.name} '
      'quality=${tagged.quality.id} verified=${tagged.verifiedComplete}',
    );
    return CloudDrivePreparedPlayback(
      lease: lease,
      qualities: sortCloudDriveQualities(qualities),
      selectedQualityId: tagged.quality.id,
      transcoded: tagged.transcoded,
      notice: notice,
      mediaKind: tagged.mediaKind,
      playbackSessionId: playbackSessionId,
      durationMs: tagged.durationMs,
      backgroundQualities: discovery?.choices,
      firstVerifiedFallback: discovery?.firstVerified,
      operationDeadline:
          operationDeadline ?? DateTime.now().add(const Duration(seconds: 30)),
    );
  }

  /// Writes sidecar and provider text tracks into the cache directory.
  ///
  /// A cache file whose bytes no longer match the stamp we wrote is left
  /// alone, so a later refresh cannot wipe an edit made on that copy.
  Future<List<CloudDriveCachedSubtitle>> loadSubtitles(VideoItem item) async {
    requireCommunityAuthorizedCloudDrive();
    final source = item.sourceRef?.cloudDrive;
    if (source == null) return const [];
    final account = _accounts.findRemote(
      source.providerId,
      source.remoteAccountId,
    );
    final provider = _providers[source.providerId];
    final credential = account == null
        ? null
        : await _accounts.credentialFor(account);
    if (account == null || provider == null || credential == null) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.notLoggedIn,
        '需要重新登录后才能读取字幕',
      );
    }
    // Sidecars only. Official tracks are listed and fetched one at a time by
    // CloudDriveSubtitleTracks, so opening a video does not download them
    // or race the subtitle panel.
    final catalog = await provider.discoverSidecarCatalog(
      _request(
        item: item,
        source: source,
        account: account,
        credential: credential,
        playbackSessionId: item.id,
      ),
    );
    subtitleDiscoveryNote = catalog.warning;
    final tracks = catalog.tracks;
    if (tracks.isEmpty) return const [];
    final root = await _cacheDir();
    final cached = <CloudDriveCachedSubtitle>[];
    final failures = <String>[];
    for (final track in tracks.where((item) => item.textAvailable)) {
      if (track.origin != CloudDriveSubtitleOrigin.sidecar) continue;
      try {
        final text = await provider.readSubtitleText(
          CloudDriveSubtitleReadRequest(
            credential: credential,
            accountLocalId: account.localId,
            remoteAccountId: account.remoteAccountId,
            driveId: source.driveId,
            track: track,
          ),
        );
        final path = await _writeSubtitleCache(
          root: root,
          providerId: source.providerId,
          accountLocalId: account.localId,
          fileId: source.fileId,
          track: track,
          text: text,
        );
        if (path == null) continue;
        cached.add(
          CloudDriveCachedSubtitle(
            track: track,
            path: path,
            autoSelect: track.autoSelect,
          ),
        );
      } catch (error) {
        failures.add('${track.label}: $error');
      }
    }
    if (failures.isNotEmpty) {
      final note = failures.join('；');
      subtitleDiscoveryNote = subtitleDiscoveryNote == null
          ? note
          : '${subtitleDiscoveryNote!}；$note';
    }
    if (cached.isEmpty && failures.isNotEmpty) {
      throw CloudDriveFailure(
        CloudDriveFailureKind.unavailable,
        failures.join('；'),
      );
    }
    return cached;
  }

  Future<void> releaseAccount(String localId) {
    _qualityCache.removeWhere((key, _) => key.startsWith('$localId|'));
    CloudDriveClientPools.discard(scope: localId);
    return _gateway.releaseAccount(localId);
  }

  Future<void> close() async {
    final fallback = _fallbackCache;
    _fallbackCache = null;
    if (fallback != null) StorageRuntimeRegistry.deactivate(fallback.path);
    await _gateway.close();
  }

  String _descriptorCacheKey(CloudDrivePlaybackRequest request) {
    final quality = request.preferredQualityId ?? 'auto';
    return '${request.accountLocalId}|${request.remoteAccountId}|${request.driveId}|'
        '${request.fileId}|${request.revision ?? ''}|$quality|'
        '${cloudDriveCredentialStamp(request.credential)}';
  }

  CloudDrivePlaybackRequest _request({
    required VideoItem item,
    required CloudDriveSourceRef source,
    required CloudDriveAccount account,
    required CloudDriveCredential credential,
    String? qualityId,
    String? playbackSessionId,
  }) {
    return CloudDrivePlaybackRequest(
      credential: credential,
      accountLocalId: account.localId,
      remoteAccountId: account.remoteAccountId,
      driveId: source.driveId,
      fileId: source.fileId,
      pathHint: source.pathHint,
      name: item.title,
      durationMs: item.durationMs > 0 ? item.durationMs : null,
      preferredQualityId: qualityId,
      revision: source.revision,
      playbackSessionId: playbackSessionId,
    );
  }

  String _notice(CloudDrivePlaybackDescriptor descriptor) {
    if (descriptor.mediaKind == CloudDriveMediaKind.audio) return '正在缓冲';
    if (descriptor.transcoded && !descriptor.verifiedComplete) {
      return '当前为转码画质，未能用时长确认是否完整';
    }
    if (descriptor.transcoded) return '当前为转码画质';
    return '正在缓冲';
  }

  Future<Directory> _cacheDir() async {
    final configured = _subtitleCacheRoot;
    if (configured != null) return configured;
    final existing = _fallbackCache;
    if (existing != null) return existing;
    final created = await Directory.systemTemp.createTemp(
      'cloud_drive_subtitles',
    );
    await markOwnedTemporaryDirectory(
      created,
      marker: 'cloud-drive-subtitles/1',
    );
    StorageRuntimeRegistry.activate(created.path);
    await StorageRuntimeRegistry.remember(
      kind: 'cloudSubtitlesFallback',
      path: created.path,
    );
    _fallbackCache = created;
    return created;
  }

  Future<String?> _writeSubtitleCache({
    required Directory root,
    required String providerId,
    required String accountLocalId,
    required String fileId,
    required CloudDriveSubtitleTrack track,
    required String text,
  }) async {
    final directory = Directory(
      p.join(root.path, providerId, accountLocalId, fileId),
    );
    await directory.create(recursive: true);
    final format = track.format.isEmpty ? 'srt' : track.format;
    final name = '${_safe(track.id)}-${_safe(track.revision ?? '0')}.$format';
    final file = File(p.join(directory.path, name));
    final stamp = File('${file.path}.stamp');
    final digest = sha256.convert(utf8.encode(text)).toString();
    if (await file.exists() && await stamp.exists()) {
      final previous = (await stamp.readAsString()).trim();
      final current = sha256.convert(await file.readAsBytes()).toString();
      // The stamp records the last remote copy. A different hash means the
      // user edited this file, so a refresh must not replace it.
      if (previous.isNotEmpty && previous != current) return file.path;
    }
    await file.writeAsString(text, flush: true);
    await stamp.writeAsString(digest, flush: true);
    return file.path;
  }

  void _wireRefresh() {
    if (_gatewayWired) return;
    _gatewayWired = true;
    _gateway.onDiagnostic = _log;
    if (_gateway.refresher != null || _gateway.cancellableRefresher != null) {
      return;
    }
    _gateway.cancellableRefresher = (current, cancelToken) async {
      final provider = _providers[current.providerId];
      final account = _accounts.findLocal(current.accountLocalId);
      final credential = account == null
          ? null
          : await _accounts.credentialFor(account);
      if (cancelToken.isCancelled) {
        throw const CloudDriveFailure(CloudDriveFailureKind.network, '网盘续期已取消');
      }
      if (provider == null || account == null || credential == null) {
        throw const CloudDriveFailure(
          CloudDriveFailureKind.notLoggedIn,
          '需要重新登录后才能继续播放',
        );
      }
      _log(
        'refresh session=${current.playbackSessionId} generation=${current.generation}',
      );
      final next = await provider.resolvePlayback(
        CloudDrivePlaybackRequest(
          credential: credential,
          accountLocalId: account.localId,
          remoteAccountId: account.remoteAccountId,
          driveId: current.driveId,
          fileId: current.fileId,
          pathHint: current.pathHint,
          name: _fileName(current.pathHint),
          durationMs: current.durationMs,
          size: current.sizeBytes,
          preferredQualityId: current.quality.id,
          revision: current.revision,
          playbackSessionId: current.playbackSessionId,
        ),
        cancelToken: cancelToken,
      );
      if (cancelToken.isCancelled) {
        throw const CloudDriveFailure(CloudDriveFailureKind.network, '网盘续期已取消');
      }
      // A reopen after changed content must not select the descriptor that
      // just failed from the two-minute quality cache. Disk media is untouched.
      _qualityCache.removeWhere(
        (_, entry) =>
            entry.descriptor.providerId == current.providerId &&
            entry.descriptor.accountLocalId == current.accountLocalId &&
            entry.descriptor.fileId == current.fileId,
      );
      return next.copyWith(
        generation: current.generation + 1,
        durationMs: next.durationMs ?? current.durationMs,
        sizeBytes: next.sizeBytes ?? current.sizeBytes,
        playbackSessionId: current.playbackSessionId,
      );
    };
  }

  void _log(String line) {
    _diagnostic.add(redactCloudDriveLog(line));
    if (_diagnostic.length > 40) _diagnostic.removeAt(0);
  }

  static String _defaultSessionId() {
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    return 'cd$now';
  }

  static String _safe(String value) {
    final cleaned = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    return cleaned.isEmpty ? 'track' : cleaned;
  }
}

String? _fileName(String? path) {
  if (path == null || path.isEmpty) return null;
  final index = path.lastIndexOf('/');
  return index < 0 ? path : path.substring(index + 1);
}

/// Builds the library source stored on a cloud file card.
MediaSourceRef cloudDriveMediaSource({
  required String providerId,
  required String remoteAccountId,
  required String driveId,
  required String fileId,
  String? pathHint,
  String? revision,
  String? preferredQuality,
}) {
  final cloud = CloudDriveSourceRef(
    providerId: providerId,
    remoteAccountId: remoteAccountId,
    driveId: driveId,
    fileId: fileId,
    pathHint: pathHint,
    revision: revision,
    preferredQuality: preferredQuality,
  );
  return MediaSourceRef(
    value: cloud.sourceKey,
    kind: MediaSourceKind.cloudDrive,
    cloudDrive: cloud,
  );
}
