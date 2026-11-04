import 'dart:async';
import 'dart:io';
import 'package:uuid/uuid.dart';
import '../../models/video_item.dart';
import '../../services/media_materialization_service.dart';
import '../cloud_drive/models/cloud_drive_models.dart';
import '../cloud_drive/services/cloud_drive_playback_service.dart';
import '../cloud_drive/services/cloud_drive_stream_gateway.dart';
import 'media_cache_hooks.dart';
import 'media_cache_models.dart';
import 'media_cache_service.dart';
import 'media_cache_reads.dart';

/// Retained copies play without remote authentication. A tokenized loopback
/// file lease gives the existing cloud player the same seekable HTTP interface.
class MediaCachePlayback {
  MediaCachePlayback(this.service);
  final MediaCacheService service;
  HttpServer? _server;
  Future<HttpServer>? _opening;
  final Map<String, _PlaybackFile> _files = {};
  void install() {
    MediaCacheReadHooks.bilibili = service.readBilibili;
    MediaCacheReadHooks.cloud = service.readCloud;
    MediaCacheHooks.acquire = service.acquire;
    MediaCacheHooks.acquireMaterial = service.acquireMaterial;
    MediaCacheHooks.publish = service.registerMaterial;
    MediaCacheHooks.qualities = (item) {
      final source = CacheSource.fromItem(item);
      return source == null
          ? []
          : service
                .variantsFor(source.key)
                .where((v) => v.completeMedia)
                .map((v) => v.quality)
                .toList();
    };
    MediaCacheHooks.openCloud = openCloud;
  }

  Future<HttpServer> _listen() => _opening ??= () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((request) => unawaited(_serve(request)));
    return server;
  }();
  Future<CloudDrivePreparedPlayback?> openCloud(
    VideoItem item, {
    String? qualityId,
  }) async {
    final source = CacheSource.fromItem(item);
    if (source == null || source.isBilibili || source.isPodcast) return null;
    final local = await service.acquire(item, qualityId: qualityId);
    if (local == null) return null;
    try {
      final variant = service
          .variantsFor(source.key)
          .where((v) => v.path == local.requiredVideoPath)
          .first;
      final server = await _listen();
      final token = const Uuid().v4();
      final entry = _PlaybackFile(variant.path, local);
      _files[token] = entry;
      final uri = Uri.parse('http://127.0.0.1:${server.port}/$token');
      final qualities = service
          .variantsFor(source.key)
          .where((v) => v.completeMedia)
          .map(
            (v) => CloudDriveQualityChoice(
              id: v.quality.id,
              label: v.quality.label,
              transcoded: v.quality.id != 'original',
              complete: true,
            ),
          )
          .toList();
      final q = qualities.firstWhere((q) => q.id == variant.quality.id);
      final descriptor = CloudDrivePlaybackDescriptor(
        upstreamUri: uri,
        transport: CloudDriveTransport.progressive,
        quality: q,
        fileId: source.ref.cloudDrive!.fileId,
        revision: variant.quality.revision,
        complete: true,
        verifiedComplete: true,
        seekable: true,
        userAgent: '',
        referer: '',
        cookies: const [],
        providerId: source.provider,
        remoteAccountId: source.ref.cloudDrive!.remoteAccountId,
        driveId: source.ref.cloudDrive!.driveId,
        sizeBytes: variant.bytes,
        mediaKind: item.type == MediaType.audio
            ? CloudDriveMediaKind.audio
            : CloudDriveMediaKind.video,
        durationMs: item.durationMs,
        qualities: qualities,
        playbackSessionId: token,
      );
      return CloudDrivePreparedPlayback(
        lease: CloudDrivePlaybackLease(
          sessionId: token,
          loopbackUri: uri,
          descriptor: descriptor,
          accountLocalId: '',
          release: () async {
            _files.remove(token);
            await entry.close();
          },
        ),
        qualities: qualities,
        selectedQualityId: q.id,
        transcoded: false,
        notice: '正在播放本地缓存',
        mediaKind: descriptor.mediaKind,
        playbackSessionId: token,
        durationMs: item.durationMs,
        backgroundQualities: service.backend
            .qualities(source)
            .then(
              (choices) => <String, CloudDriveQualityChoice>{
                for (final choice in choices)
                  choice.id: CloudDriveQualityChoice(
                    id: choice.id,
                    label: choice.label,
                    transcoded: choice.id != 'original',
                    complete: choice.available,
                    availability: choice.available
                        ? CloudDriveQualityAvailability.available
                        : CloudDriveQualityAvailability.unavailable,
                  ),
                for (final cached in qualities) cached.id: cached,
              }.values.toList(),
            )
            .catchError((Object _) => qualities),
      );
    } catch (_) {
      await local.release();
      rethrow;
    }
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    _PlaybackFile? active;
    try {
      final name = request.uri.pathSegments.length == 1
          ? request.uri.pathSegments.single
          : '';
      final entry = _files[name];
      if (entry == null ||
          entry.closed ||
          !const {'GET', 'HEAD'}.contains(request.method)) {
        response.statusCode = entry == null || entry.closed ? 404 : 405;
        await response.close();
        return;
      }
      active = entry;
      entry.readers++;
      final file = File(entry.path);
      final length = await file.length();
      var start = 0, end = length - 1;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range);
        if (match == null || match[1]!.isEmpty && match[2]!.isEmpty) {
          response.statusCode = 416;
          response.headers.set('Content-Range', 'bytes */$length');
          await response.close();
          return;
        }
        if (match[1]!.isEmpty) {
          final suffix = int.parse(match[2]!);
          start = (length - suffix).clamp(0, length);
        } else {
          start = int.parse(match[1]!);
          if (match[2]!.isNotEmpty) {
            end = int.parse(match[2]!).clamp(0, length - 1);
          }
        }
        if (start >= length || start > end) {
          response.statusCode = 416;
          response.headers.set('Content-Range', 'bytes */$length');
          await response.close();
          return;
        }
        response.statusCode = 206;
        response.headers.set('Content-Range', 'bytes $start-$end/$length');
      }
      response.headers.set('Accept-Ranges', 'bytes');
      response.headers.contentType = ContentType.binary;
      response.contentLength = end - start + 1;
      if (request.method != 'HEAD') {
        await response.addStream(file.openRead(start, end + 1));
      }
      await response.close();
    } catch (_) {
      try {
        await response.close();
      } catch (_) {}
    } finally {
      if (active != null) {
        active.readers--;
        if (active.closed && active.readers == 0) await active.release();
      }
    }
  }

  Future<void> shutdown() async {
    final entries = _files.values.toList();
    _files.clear();
    await _server?.close(force: true);
    await Future.wait(entries.map((entry) => entry.close()));
  }
}

class _PlaybackFile {
  _PlaybackFile(this.path, this.owner);
  final String path;
  final MaterializedMediaLease owner;
  int readers = 0;
  bool closed = false;
  final done = Completer<void>();
  Future<void>? _releasing;
  Future<void> close() async {
    closed = true;
    if (readers == 0) await release();
    return done.future;
  }

  Future<void> release() => _releasing ??= () async {
    try {
      await owner.release();
      done.complete();
    } catch (error, stack) {
      done.completeError(error, stack);
    }
  }();
}
