import '../../../services/community_media_input.dart';
import 'dart:async';
import '../../media_cache/media_cache_reads.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart' show CancelToken;
import '../../../services/bilibili/media_connection_pool.dart';

import '../../../services/network/network_http.dart';
import '../../../services/network/network_recovery.dart';
import '../../../services/network/recoverable_media_stream.dart';
import '../models/cloud_drive_models.dart';
import '../providers/cloud_drive_http.dart';
import 'baidu_hls_hosts.dart';
import 'baidu_hls_timeline.dart';
import 'cloud_drive_hls_plan.dart';

class CloudDriveUpstreamRequest {
  const CloudDriveUpstreamRequest({
    required this.method,
    required this.uri,
    this.headers = const <String, String>{},
    this.headersFor,
    this.headerTimeout = const Duration(seconds: 8),
    this.cancelToken,
    this.connectionScope,
    this.networkGeneration,
  });

  final String method;
  final Uri uri;
  final Map<String, String> headers;

  /// Recomputed after every redirect so cookies follow the new host.
  final Map<String, String> Function(Uri uri)? headersFor;

  /// Connect and response headers for the whole redirect chain, not per hop.
  final Duration headerTimeout;
  final CloudDriveCancelToken? cancelToken;
  final String? connectionScope;
  final int? networkGeneration;
}

class CloudDriveUpstreamResponse {
  const CloudDriveUpstreamResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
    required this.close,
    this.effectiveUri,
  });

  final int statusCode;
  final Map<String, String> headers;
  final Stream<List<int>>? body;
  final Future<void> Function() close;

  /// URI of the response after relative redirects. Playlist bases use this.
  final Uri? effectiveUri;
}

abstract class CloudDriveUpstreamClient {
  Future<CloudDriveUpstreamResponse> open(CloudDriveUpstreamRequest request);
}

class NetworkCloudDriveUpstreamClient implements CloudDriveUpstreamClient {
  NetworkCloudDriveUpstreamClient({NetworkHttp? network})
    : _network = network ?? NetworkHttp.instance;

  final NetworkHttp _network;

  @override
  Future<CloudDriveUpstreamResponse> open(
    CloudDriveUpstreamRequest request,
  ) async {
    requireCommunityAuthorizedCloudDrive();
    final cancel = CancelToken();
    final unbind = request.cancelToken?.onCancel(() => cancel.cancel());
    BilibiliMediaConnectionPermit permit;
    try {
      permit = await BilibiliMediaConnectionPool.shared.acquire(
        cancelToken: cancel,
        playback: true,
      );
    } catch (_) {
      unbind?.call();
      rethrow;
    }
    var attached = false;
    try {
      final response = await _openNetwork(request);
      Future<void>? closing;
      Future<void> close() => closing ??= () async {
        try {
          await response.close();
        } finally {
          unbind?.call();
          permit.release();
        }
      }();
      attached = true;
      return CloudDriveUpstreamResponse(
        statusCode: response.statusCode,
        headers: response.headers,
        body: response.body,
        effectiveUri: response.effectiveUri,
        close: close,
      );
    } finally {
      if (!attached) {
        unbind?.call();
        permit.release();
      }
    }
  }

  Future<CloudDriveUpstreamResponse> _openNetwork(
    CloudDriveUpstreamRequest request,
  ) async {
    final scope = request.connectionScope ?? request.uri.host;
    final generation =
        request.networkGeneration ?? cloudDriveNetworkGeneration();
    final client = CloudDriveClientPools.checkout(
      scope: scope,
      generation: generation,
      createClient: () => _network.createClient(
        scope: NetworkScope.cloudDrive,
        source: request.uri,
      ),
    );
    final deadline = DateTime.now().add(request.headerTimeout);
    Duration left() {
      final remain = deadline.difference(DateTime.now());
      if (remain <= Duration.zero) throw TimeoutException('连接网盘超时');
      return remain;
    }

    var handedOff = false;
    void Function()? removeAbort;
    try {
      var current = request;
      HttpClientResponse? response;
      for (var hop = 0; hop < 5; hop++) {
        removeAbort?.call();
        final io = await openCloudDriveRequest(
          client,
          current.method,
          current.uri,
          timeout: left(),
          cancelToken: request.cancelToken,
        );
        removeAbort = request.cancelToken?.onCancel(io.abort);
        io.followRedirects = false;
        final headers =
            current.headersFor?.call(current.uri) ?? current.headers;
        headers.forEach(io.headers.set);
        try {
          response = await io.close().timeout(left());
        } on TimeoutException {
          io.abort();
          rethrow;
        }
        if (request.cancelToken?.isCancelled == true) {
          await response.listen((_) {}).cancel();
          throw const CloudDriveFailure(
            CloudDriveFailureKind.network,
            '网盘请求已取消',
          );
        }
        if (response.statusCode < 300 || response.statusCode >= 400) break;
        final location = response.headers.value(HttpHeaders.locationHeader);
        // A redirect is complete at its headers. Waiting for an unbounded
        // error/redirect body can consume the entire player startup deadline.
        await response.listen((_) {}).cancel();
        response = null;
        if (location == null || location.isEmpty) break;
        final next = current.uri.resolve(location);
        if (next.scheme != 'http' && next.scheme != 'https') break;
        current = CloudDriveUpstreamRequest(
          method: current.method == 'HEAD' ? 'HEAD' : 'GET',
          uri: next,
          headers: cloudDriveRedirectHeaders(current.headers),
          headersFor: current.headersFor,
          headerTimeout: left(),
          cancelToken: current.cancelToken,
          connectionScope: current.connectionScope,
          networkGeneration: current.networkGeneration,
        );
      }
      final settled = response;
      if (settled == null) {
        throw const CloudDriveFailure(
          CloudDriveFailureKind.network,
          '网盘重定向次数过多',
        );
      }
      final headers = <String, String>{};
      settled.headers.forEach((name, values) {
        headers[name.toLowerCase()] = values.join(',');
      });
      final iterator = StreamIterator<List<int>>(settled);
      Stream<List<int>> body() async* {
        try {
          if (request.cancelToken?.isCancelled == true) return;
          while (await iterator.moveNext()) {
            if (request.cancelToken?.isCancelled == true) return;
            yield iterator.current;
          }
        } catch (_) {
          // Once headers have been returned, intentional cancellation closes
          // the byte stream. Throwing here can outlive a disconnected player's
          // subscription and surface as an unhandled server-side exception.
          if (request.cancelToken?.isCancelled != true) rethrow;
        } finally {
          await iterator.cancel();
        }
      }

      Future<void>? closing;
      void Function()? removeBodyCancel;
      Future<void> close() => closing ??= () async {
        removeAbort?.call();
        removeBodyCancel?.call();
        try {
          await iterator.cancel();
        } finally {
          CloudDriveClientPools.release(scope: scope, generation: generation);
        }
      }();
      removeBodyCancel = request.cancelToken?.onCancel(
        () => unawaited(close()),
      );
      handedOff = true;
      return CloudDriveUpstreamResponse(
        statusCode: settled.statusCode,
        headers: headers,
        body: current.method == 'HEAD' ? null : body(),
        effectiveUri: current.uri,
        close: close,
      );
    } finally {
      if (!handedOff) {
        removeAbort?.call();
        CloudDriveClientPools.release(scope: scope, generation: generation);
      }
    }
  }
}

typedef CloudDriveDescriptorRefresher =
    Future<CloudDrivePlaybackDescriptor> Function(
      CloudDrivePlaybackDescriptor current,
    );

typedef CancellableCloudDriveDescriptorRefresher =
    Future<CloudDrivePlaybackDescriptor> Function(
      CloudDrivePlaybackDescriptor current,
      CloudDriveCancelToken cancelToken,
    );

class CloudDrivePlaybackLease {
  CloudDrivePlaybackLease({
    required this.sessionId,
    required this.loopbackUri,
    required CloudDrivePlaybackDescriptor descriptor,
    required this.accountLocalId,
    required Future<void> Function() release,
  }) : _descriptor = descriptor,
       _release = release;

  final String sessionId;
  final Uri loopbackUri;
  final String accountLocalId;
  CloudDrivePlaybackDescriptor _descriptor;
  final Future<void> Function() _release;
  var released = false;
  final ValueNotifier<bool> reopenRequired = ValueNotifier(false);
  bool get needsReopen => reopenRequired.value;
  set needsReopen(bool value) {
    if (!released) reopenRequired.value = value;
  }

  CloudDrivePlaybackDescriptor get descriptor => _descriptor;

  void replaceDescriptor(CloudDrivePlaybackDescriptor next) {
    if (released) return;
    _descriptor = next;
  }

  Future<void> release() async {
    if (released) return;
    released = true;
    // A consumer may release directly from the reopen notification.
    scheduleMicrotask(reopenRequired.dispose);
    await _release();
  }
}

enum CloudDriveGatewayResource {
  manifest,
  segment,
  initSegment,
  key,
  subtitle,
  progressive,
}

/// Loopback proxy that keeps one stable URL while the signed upstream moves.
class CloudDriveStreamGateway {
  CloudDriveStreamGateway({
    CloudDriveUpstreamClient? upstream,
    this.refresher,
    this.cancellableRefresher,
    this.onDiagnostic,
    Random? random,
    this.headerTimeout = const Duration(seconds: 8),
    this.refreshTimeout = const Duration(seconds: 8),
    this.idleTimeout = const Duration(seconds: 20),
    this.retryDelays = NetworkRecovery.retryDelays,
  }) : _upstream = upstream ?? NetworkCloudDriveUpstreamClient(),
       _random = random ?? Random.secure();

  final CloudDriveUpstreamClient _upstream;
  CloudDriveDescriptorRefresher? refresher;
  CancellableCloudDriveDescriptorRefresher? cancellableRefresher;
  void Function(String message)? onDiagnostic;
  final Random _random;
  final Duration headerTimeout;
  final Duration refreshTimeout;
  final Duration idleTimeout;
  final List<Duration> retryDelays;
  HttpServer? _server;
  Future<HttpServer>? _starting;
  final Map<String, _GatewaySession> _sessions = {};

  Future<CloudDrivePlaybackLease> open({
    required CloudDrivePlaybackDescriptor descriptor,
    required String accountLocalId,
  }) async {
    requireCommunityAuthorizedCloudDrive();
    final server = await _ensureServer();
    final token = _token();
    final session = _GatewaySession(descriptor)
      ..accountLocalId = accountLocalId;
    _sessions[token] = session;
    final uri = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: server.port,
      path: '/cd/$token',
    );
    final lease = CloudDrivePlaybackLease(
      sessionId: token,
      loopbackUri: uri,
      descriptor: descriptor,
      accountLocalId: accountLocalId,
      release: () async {
        final current = _sessions.remove(token);
        await current?.close();
      },
    );
    session.onNeedsReopen = () => lease.needsReopen = true;
    session.onDescriptor = lease.replaceDescriptor;
    _note(
      'gateway open session=${descriptor.playbackSessionId} '
      'transport=${descriptor.transport.name} quality=${descriptor.quality.id}',
    );
    return lease;
  }

  Future<void> releaseAccount(String accountLocalId) async {
    final tokens = _sessions.entries
        .where((entry) => entry.value.accountLocalId == accountLocalId)
        .map((entry) => entry.key)
        .toList();
    for (final token in tokens) {
      await _sessions.remove(token)?.close();
    }
  }

  void bindAccount(String token, String accountLocalId) {
    _sessions[token]?.accountLocalId = accountLocalId;
  }

  Future<void> close() async {
    final sessions = _sessions.values.toList();
    _sessions.clear();
    for (final session in sessions) {
      await session.close();
    }
    final server = _server;
    _server = null;
    _starting = null;
    await server?.close(force: true);
  }

  Future<HttpServer> _ensureServer() {
    final existing = _server;
    if (existing != null) return Future.value(existing);
    return _starting ??= () async {
      final server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
        shared: false,
      );
      _server = server;
      unawaited(server.forEach(_handle));
      return server;
    }();
  }

  String _token() {
    final bytes = List<int>.generate(24, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  Future<void> _handle(HttpRequest request) async {
    _GatewaySession? activeSession;
    String resource = 'entry';
    try {
      final token = _tokenOf(request.uri.path);
      final session = token == null ? null : _sessions[token.session];
      activeSession = session;
      resource = token?.hlsId ?? 'root';
      if (token == null || session == null || session.closed) {
        await _finish(request, HttpStatus.notFound, '播放地址已失效');
        return;
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        await _finish(request, HttpStatus.methodNotAllowed, '只支持读取播放数据');
        return;
      }
      if (request.uri.queryParameters.containsKey('url')) {
        await _finish(request, HttpStatus.badRequest, '网关不接受任意地址');
        return;
      }
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null && range.contains(',')) {
        await _finish(request, HttpStatus.notImplemented, '不支持多个 Range');
        return;
      }
      final target = token.hlsId == null
          ? session.descriptor.upstreamUri
          : session.hlsTargets[token.hlsId!];
      if (target == null) {
        await _finish(request, HttpStatus.notFound, '找不到这一段媒体');
        return;
      }
      final parsedRange = range == null
          ? null
          : parseCloudDriveByteRange(range);
      if (range != null &&
          session.descriptor.seekable == false &&
          parsedRange != null &&
          !parsedRange.startsAtZero) {
        _rangeNotSatisfiable(request.response, session.descriptor.sizeBytes);
        await request.response.close();
        return;
      }
      final cancel = CloudDriveCancelToken();
      session.reads.add(cancel);
      unawaited(
        request.response.done.then<void>(
          (_) {},
          onError: (Object _, StackTrace _) => cancel.cancel(),
        ),
      );
      try {
        await _proxy(
          request: request,
          session: session,
          hlsId: token.hlsId,
          target: target,
          range: range,
          parsedRange: parsedRange,
          cancel: cancel,
        );
        if (cancel.isCancelled) throw const _CloudDriveTransferCancelled();
      } finally {
        session.reads.remove(cancel);
      }
    } on _CloudDriveTransferCancelled {
      _note(
        'gateway cancelled session=${activeSession?.descriptor.playbackSessionId ?? 'unknown'} resource=$resource',
      );
      try {
        request.response.statusCode = HttpStatus.gone;
        await request.response.close();
      } catch (_) {}
    } catch (error, stack) {
      final frames = stack
          .toString()
          .split('\n')
          .take(4)
          .map(
            (line) =>
                line.replaceFirst(RegExp(r'^#\d+\s+'), '').split(' (').first,
          )
          .join(' > ');
      final detail = redactCloudDriveLog(
        '$error',
      ).replaceAll(RegExp(r'\s+'), ' ');
      _note(
        'gateway error ${error.runtimeType} '
        'session=${activeSession?.descriptor.playbackSessionId ?? 'unknown'} '
        'resource=$resource method=${request.method} '
        'detail=${detail.length > 240 ? detail.substring(0, 240) : detail} '
        'at=$frames',
      );
      try {
        await _finish(request, HttpStatus.badGateway, '网盘传输中断');
      } catch (_) {}
    }
  }

  Future<void> _proxy({
    required HttpRequest request,
    required _GatewaySession session,
    required String? hlsId,
    required Uri target,
    required String? range,
    required CloudDriveByteRange? parsedRange,
    required CloudDriveCancelToken cancel,
  }) async {
    final cacheRead = MediaCacheReadHooks.cloud;
    final cachedPrefix = request.method == 'HEAD'
        ? null
        : await cacheRead?.call(session.descriptor, target, range);
    if (cachedPrefix != null &&
        cachedPrefix.completeRequest &&
        await MediaCacheReadHooks.serve(request, Future.value(cachedPrefix))) {
      return;
    }
    if (cachedPrefix != null) {
      range =
          'bytes=${cachedPrefix.start + cachedPrefix.bytes.length}-${cachedPrefix.requestEnd}';
      parsedRange = parseCloudDriveByteRange(range);
    }
    if (hlsId == null &&
        session.descriptor.transport == CloudDriveTransport.hls &&
        (range == null || range == 'bytes=0-') &&
        await _servePreparedManifest(request, session, cancel)) {
      return;
    }
    Future<CloudDriveUpstreamResponse> fetchOnce(
      Uri uri, {
      String? range,
      String? validator,
      Duration? timeout,
    }) {
      final attemptCancel = CloudDriveCancelToken();
      cancel.onCancel(attemptCancel.cancel);
      final timeoutBudget = timeout ?? headerTimeout;
      final pending = _upstream.open(
        CloudDriveUpstreamRequest(
          method: request.method,
          uri: uri,
          headersFor: (target) => {
            ..._upstreamHeaders(session.descriptor, target, range: range),
            'If-Range': ?validator,
          },
          headerTimeout: timeoutBudget,
          cancelToken: attemptCancel,
          connectionScope:
              session.accountLocalId ?? session.descriptor.accountLocalId,
        ),
      );
      return pending.timeout(
        timeoutBudget,
        onTimeout: () {
          attemptCancel.cancel();
          // Future.timeout does not stop the source. Close a lease that
          // arrives after the caller has already given up.
          unawaited(
            pending.then(
              (response) => response.close(),
              onError: (Object _) {},
            ),
          );
          throw TimeoutException('连接网盘超时');
        },
      );
    }

    void checkSession() {
      if (session.closed || cancel.isCancelled) {
        throw const _CloudDriveTransferCancelled();
      }
    }

    Future<CloudDriveUpstreamResponse> fetch(
      Uri uri, {
      String? range,
      String? validator,
    }) async {
      final deadline = DateTime.now().add(headerTimeout);
      final routes = hlsId == null ? [uri] : _baiduHlsCandidates(session, uri);
      var routeIndex = 0;
      var retries = 0;
      for (var attempt = 0; ; attempt++) {
        checkSession();
        final remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) throw TimeoutException('网盘响应头重试超时');
        final hasFallback = routeIndex + 1 < routes.length;
        // A stalled first node must leave time to try the declared backups.
        final timeout = hasFallback
            ? Duration(
                microseconds: min(
                  const Duration(seconds: 2).inMicroseconds,
                  remaining.inMicroseconds ~/ (routes.length - routeIndex),
                ),
              )
            : remaining;
        final candidate = routes[routeIndex];
        try {
          final result = await fetchOnce(
            candidate,
            range: range,
            validator: validator,
            timeout: timeout,
          );
          if (hlsId == null || attempt > 0 || result.statusCode >= 400) {
            _note(
              'gateway upstream session=${session.descriptor.playbackSessionId} '
              'resource=${hlsId ?? 'root'} status=${result.statusCode} attempt=${attempt + 1}'
              '${result.headers.containsKey('x-app-network-error') ? ' route=unavailable' : ''}',
            );
          }
          final contentType = (result.headers['content-type'] ?? '')
              .toLowerCase();
          final rejectedBody =
              contentType.contains('text/html') ||
              contentType.contains('application/json');
          if (hasFallback &&
              (result.statusCode == 401 ||
                  result.statusCode == 403 ||
                  result.statusCode == 404 ||
                  NetworkRecovery.transientStatus(result.statusCode) ||
                  rejectedBody)) {
            await result.close();
            checkSession();
            routeIndex++;
            _note(
              'gateway baidu host fallback session=${session.descriptor.playbackSessionId} '
              'resource=$hlsId route=$routeIndex status=${result.statusCode}',
            );
            continue;
          }
          if (result.statusCode >= 500 && result.statusCode <= 504) {
            await result.close();
            throw HttpException('HTTP ${result.statusCode}');
          }
          if (routes.length > 1 &&
              result.statusCode >= 200 &&
              result.statusCode < 300 &&
              !rejectedBody) {
            session.baiduHlsHosts[uri.authority] = candidate.authority;
          }
          return result;
        } catch (error) {
          _note(
            'gateway upstream failure session=${session.descriptor.playbackSessionId} '
            'resource=${hlsId ?? 'root'} attempt=${attempt + 1} '
            'error=${error.runtimeType} detail=${redactCloudDriveLog('$error').replaceAll(RegExp(r'\s+'), ' ')}',
          );
          checkSession();
          if (hasFallback &&
              (NetworkRecovery.isTransient(error) || error is TlsException)) {
            routeIndex++;
            _note(
              'gateway baidu host fallback session=${session.descriptor.playbackSessionId} '
              'resource=$hlsId route=$routeIndex error=${error.runtimeType}',
            );
            continue;
          }
          if (retries >= retryDelays.length ||
              !NetworkRecovery.isTransient(error)) {
            rethrow;
          }
          final left = deadline.difference(DateTime.now());
          if (left <= Duration.zero) rethrow;
          final delay = retryDelays[retries] < left
              ? retryDelays[retries]
              : left;
          retries++;
          await NetworkRecovery.wait(delay, checkCancelled: checkSession);
        }
      }
    }

    var mediaOrigin = target;
    CloudDriveUpstreamResponse upstream;
    try {
      upstream = await fetch(target, range: range);
    } on TimeoutException {
      _note(
        'gateway header timeout session=${session.descriptor.playbackSessionId}',
      );
      await _finish(request, HttpStatus.gatewayTimeout, '连接网盘超时');
      return;
    }
    if (session.closed) {
      await upstream.close();
      return;
    }
    bool needsRefresh(int status) =>
        status == 401 ||
        status == 403 ||
        (status == 412 &&
            const {'quark', 'uc'}.contains(session.descriptor.providerId));
    if (needsRefresh(upstream.statusCode)) {
      await upstream.close();
      final refreshed = await session.refresh(
        refresher,
        cancellableRefresher,
        refreshTimeout,
      );
      if (session.closed) return;
      if (refreshed == null) {
        await _finish(
          request,
          upstream.statusCode == 401
              ? HttpStatus.unauthorized
              : HttpStatus.forbidden,
          '网盘没有继续提供这个地址',
        );
        return;
      }
      if (refreshed.fileId != session.descriptor.fileId ||
          refreshed.revision != session.descriptor.revision ||
          refreshed.quality.id != session.descriptor.quality.id ||
          refreshed.transport != session.descriptor.transport ||
          refreshed.sizeBytes != null &&
              session.descriptor.sizeBytes != null &&
              refreshed.sizeBytes != session.descriptor.sizeBytes) {
        session.needsReopen = true;
        session.onNeedsReopen?.call();
        await _finish(request, HttpStatus.conflict, '播放源已变化，需要重新打开');
        return;
      }
      session.adopt(refreshed);
      final Uri retryUri;
      if (hlsId == null) {
        retryUri = refreshed.upstreamUri;
      } else {
        final remapped = await _remapHls(
          session,
          hlsId,
          refreshed.upstreamUri,
          cancel,
        );
        if (remapped == null) {
          session.needsReopen = true;
          session.onNeedsReopen?.call();
          await _finish(request, HttpStatus.conflict, '分片地址无法安全续期');
          return;
        }
        session.hlsTargets[hlsId] = remapped;
        retryUri = remapped;
      }
      try {
        mediaOrigin = retryUri;
        upstream = await fetch(retryUri, range: range);
      } on TimeoutException {
        await _finish(request, HttpStatus.gatewayTimeout, '连接网盘超时');
        return;
      }
      if (needsRefresh(upstream.statusCode)) {
        await upstream.close();
        await _finish(request, HttpStatus.forbidden, '刷新后网盘仍拒绝这一段');
        return;
      }
    }
    if (upstream.statusCode == 429) {
      await upstream.close();
      request.response.statusCode = HttpStatus.tooManyRequests;
      final retry = upstream.headers['retry-after'];
      if (retry != null) request.response.headers.set('retry-after', retry);
      await request.response.close();
      return;
    }
    final decision = decideCloudDriveRange(
      requestRange: parsedRange,
      upstreamStatus: upstream.statusCode,
      upstreamContentRange: upstream.headers['content-range'],
      upstreamContentLength: int.tryParse(
        upstream.headers['content-length'] ?? '',
      ),
    );
    if (decision.reject) {
      if (decision.markUnseekable) {
        session.adopt(session.descriptor.copyWith(seekable: false));
      }
      await upstream.close();
      _rangeNotSatisfiable(request.response, decision.totalLength);
      await request.response.close();
      return;
    }
    if (decision.markUnseekable) {
      session.adopt(session.descriptor.copyWith(seekable: false));
    }
    final resource = classifyCloudDriveGatewayResource(
      target: upstream.effectiveUri ?? target,
      hlsRoot:
          hlsId == null &&
          session.descriptor.transport == CloudDriveTransport.hls,
      contentType: upstream.headers['content-type'],
    );
    if (resource == CloudDriveGatewayResource.manifest &&
        request.method != 'HEAD') {
      final text = await _readText(upstream, maxBytes: 2 * 1024 * 1024);
      await upstream.close();
      if (text == null) {
        await _finish(request, HttpStatus.badGateway, '播放列表过大');
        return;
      }
      if (text.trimLeft().startsWith('<') || text.trimLeft().startsWith('{')) {
        await _finish(request, HttpStatus.badGateway, '网盘返回的不是播放列表');
        return;
      }
      final base = upstream.effectiveUri ?? target;
      await _detectBaiduMp4Timeline(request, session, text, base, cancel);
      final rewritten = _rewritePlaybackPlaylist(request, session, text, base);
      session.playlistText = text;
      session.playlistBase = base;
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType(
        'application',
        rewritten.startsWith('# mpv EDL') ? 'x-mpv-edl' : 'vnd.apple.mpegurl',
        charset: 'utf-8',
      );
      request.response.write(rewritten);
      await request.response.close();
      return;
    }
    if (resource == CloudDriveGatewayResource.subtitle &&
        request.method != 'HEAD') {
      final text = await _readText(upstream, maxBytes: 1024 * 1024);
      await upstream.close();
      if (text == null) {
        await _finish(request, HttpStatus.badGateway, '字幕文本过大');
        return;
      }
      request.response.statusCode = upstream.statusCode;
      _copyMediaHeaders(upstream.headers, request.response, dropLength: true);
      request.response.write(text);
      await request.response.close();
      return;
    }
    final type = (upstream.headers['content-type'] ?? '').toLowerCase();
    if (type.contains('text/html') || type.contains('application/json')) {
      await upstream.close();
      await _finish(request, HttpStatus.badGateway, '网盘返回了网页而不是媒体');
      return;
    }
    if (cachedPrefix != null &&
        (decision.totalLength != cachedPrefix.total ||
            upstream.statusCode != HttpStatus.partialContent)) {
      await upstream.close();
      await _finish(request, HttpStatus.badGateway, '来源资源已变化，请重新打开');
      return;
    }
    request.response.statusCode = upstream.statusCode;
    _copyMediaHeaders(upstream.headers, request.response, dropLength: false);
    if (cachedPrefix != null) {
      request.response.statusCode = cachedPrefix.partial
          ? HttpStatus.partialContent
          : HttpStatus.ok;
      request.response.contentLength =
          cachedPrefix.requestEnd - cachedPrefix.start + 1;
      if (cachedPrefix.partial) {
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes ${cachedPrefix.start}-${cachedPrefix.requestEnd}/${cachedPrefix.total}',
        );
      } else {
        request.response.headers.removeAll(HttpHeaders.contentRangeHeader);
      }
      request.response.add(cachedPrefix.bytes);
    }
    if (resource == CloudDriveGatewayResource.manifest) {
      request.response.headers.contentType = ContentType(
        'application',
        'vnd.apple.mpegurl',
        charset: 'utf-8',
      );
    }
    if (request.method == 'HEAD' || upstream.body == null) {
      await upstream.close();
      await request.response.close();
      return;
    }
    NetworkMediaResponse wrap(CloudDriveUpstreamResponse response) =>
        NetworkMediaResponse(
          status: response.statusCode,
          headers: response.headers,
          body: response.body ?? const Stream<List<int>>.empty(),
          close: response.close,
        );
    final body = recoverableMediaStream(
      initial: wrap(upstream),
      idleTimeout: idleTimeout,
      retryDelays: retryDelays,
      checkCancelled: checkSession,
      isCancelled: () => session.closed || cancel.isCancelled,
      reopen: (start, end, validator) async {
        final useBaiduHosts =
            _baiduHlsCandidates(session, mediaOrigin).length > 1;
        final response = useBaiduHosts
            ? await fetch(
                mediaOrigin,
                range: 'bytes=$start-${end ?? ''}',
                validator: validator,
              )
            : await fetchOnce(
                upstream.effectiveUri ?? mediaOrigin,
                range: 'bytes=$start-${end ?? ''}',
                validator: validator,
              );
        return wrap(response);
      },
    );
    try {
      await request.response.addStream(body);
      await request.response.close();
    } catch (error) {
      _note(
        'gateway transfer stopped ${error.runtimeType} session=${session.descriptor.playbackSessionId} '
        'resource=${hlsId ?? 'root'} detail=${redactCloudDriveLog('$error')}',
      );
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  /// The resolver already downloaded this playlist. Serving it here avoids a
  /// second round trip before the player can ask for the first segment.
  /// HEAD stays header-only. A mutable playlist is consumed once.
  Future<bool> _servePreparedManifest(
    HttpRequest request,
    _GatewaySession session,
    CloudDriveCancelToken cancel,
  ) async {
    if (!_manifestSeedUsable(session.descriptor)) return false;
    final seed = session.descriptor.manifest!;
    final token = _tokenOf(request.uri.path);
    if (token == null) return false;
    await _detectBaiduMp4Timeline(
      request,
      session,
      seed.text,
      seed.baseUri,
      cancel,
    );
    final rewritten = _rewritePlaybackPlaylist(
      request,
      session,
      seed.text,
      seed.baseUri,
    );
    session.playlistText = seed.text;
    session.playlistBase = seed.baseUri;
    final bytes = utf8.encode(rewritten);
    request.response.statusCode = HttpStatus.ok;
    request.response.contentLength = bytes.length;
    request.response.headers.contentType = ContentType(
      'application',
      rewritten.startsWith('# mpv EDL') ? 'x-mpv-edl' : 'vnd.apple.mpegurl',
      charset: 'utf-8',
    );
    if (request.method != 'HEAD') {
      request.response.add(bytes);
    }
    await request.response.close();
    if (seed.mutable) {
      session.adopt(session.descriptor.copyWith(dropManifest: true));
    }
    _note(
      'gateway manifest seed session=${session.descriptor.playbackSessionId} '
      'bytes=${bytes.length} mutable=${seed.mutable}',
    );
    return true;
  }

  bool _manifestSeedUsable(CloudDrivePlaybackDescriptor descriptor) {
    final seed = descriptor.manifest;
    if (seed == null || !seed.text.trimLeft().startsWith('#EXTM3U')) {
      return false;
    }
    final age = DateTime.now().difference(seed.fetchedAt);
    if (age.isNegative || age > const Duration(minutes: 2)) return false;
    final expires = descriptor.expiresAt;
    if (expires != null &&
        !expires.isAfter(DateTime.now().add(const Duration(seconds: 15)))) {
      return false;
    }
    return true;
  }

  String _rewritePlaybackPlaylist(
    HttpRequest request,
    _GatewaySession session,
    String text,
    Uri base,
  ) {
    var order = 0;
    String localize(Uri resolved) => _rememberHls(
      session,
      _tokenOf(request.uri.path)!.session,
      resolved,
      order++,
    );
    if (session.descriptor.providerId == 'baidu' &&
        request.headers.value(cloudDriveNativeTimelineHeader) == '1') {
      final timeline = baiduIndependentMp4Timeline(
        text,
        base,
        localize,
        verifiedMp4: session.baiduMp4Timeline == true,
      );
      if (timeline != null) {
        _note(
          'gateway baidu independent-mp4 timeline '
          'session=${session.descriptor.playbackSessionId} segments=$order',
        );
        return timeline;
      }
    }
    return rewriteHlsPlaylist(text, base, localize);
  }

  Future<void> _detectBaiduMp4Timeline(
    HttpRequest request,
    _GatewaySession session,
    String text,
    Uri base,
    CloudDriveCancelToken cancel,
  ) async {
    if (session.descriptor.providerId != 'baidu' ||
        request.headers.value(cloudDriveNativeTimelineHeader) != '1' ||
        !text.contains('#EXT-X-DISCONTINUITY') ||
        !text.contains('#EXT-X-ENDLIST')) {
      return;
    }
    final plan = parseHlsMediaPlan(text, base);
    if (plan == null ||
        plan.isMaster ||
        plan.encrypted ||
        plan.mapUri != null ||
        plan.audioPlaylistUri != null ||
        plan.segments.isEmpty) {
      return;
    }
    session.baiduMp4Timeline = await (session.baiduMp4Probe ??= () async {
      final source = plan.segments.first.uri;
      _rememberBaiduHlsHosts(session, source);
      final routes = _baiduHlsCandidates(session, source);
      final deadline = DateTime.now().add(headerTimeout);
      for (var index = 0; index < routes.length; index++) {
        final left = deadline.difference(DateTime.now());
        if (left <= Duration.zero) throw TimeoutException('网盘分片格式确认超时');
        final timeout = Duration(
          microseconds: left.inMicroseconds ~/ (routes.length - index),
        );
        final attempt = CloudDriveCancelToken();
        cancel.onCancel(attempt.cancel);
        CloudDriveUpstreamResponse? response;
        try {
          final pending = _upstream.open(
            CloudDriveUpstreamRequest(
              method: 'GET',
              uri: routes[index],
              headersFor: (uri) => _upstreamHeaders(
                session.descriptor,
                uri,
                range: 'bytes=0-15',
              ),
              headerTimeout: timeout,
              cancelToken: attempt,
              connectionScope: session.accountLocalId,
            ),
          );
          response = await pending.timeout(
            timeout,
            onTimeout: () {
              attempt.cancel();
              unawaited(pending.then((r) => r.close(), onError: (Object _) {}));
              throw TimeoutException('网盘分片格式确认超时');
            },
          );
          if (response.statusCode != 200 && response.statusCode != 206) {
            throw HttpException('HTTP ${response.statusCode}');
          }
          final prefix = <int>[];
          final bodyTime = deadline.difference(DateTime.now());
          if (bodyTime <= Duration.zero) {
            throw TimeoutException('网盘分片格式确认超时');
          }
          await for (final chunk
              in (response.body ?? const Stream<List<int>>.empty()).timeout(
                bodyTime < timeout ? bodyTime : timeout,
              )) {
            prefix.addAll(chunk.take(16 - prefix.length));
            if (prefix.length >= 16) break;
          }
          session.baiduHlsHosts[source.authority] = routes[index].authority;
          return prefix.length >= 8 &&
              ascii.decode(prefix.sublist(4, 8), allowInvalid: true) == 'ftyp';
        } catch (_) {
          if (cancel.isCancelled || session.closed) {
            throw const _CloudDriveTransferCancelled();
          }
          if (index == routes.length - 1) rethrow;
        } finally {
          await response?.close();
        }
      }
      return false;
    }());
  }

  String _rememberHls(
    _GatewaySession session,
    String token,
    Uri target,
    int order,
  ) {
    _rememberBaiduHlsHosts(session, target);
    final existing = session.hlsIds[target.toString()];
    // FFmpeg checks HLS segment extensions before opening them. Opaque /h/1
    // addresses are rejected even when their bytes are valid MPEG-TS. Keep a
    // small, validated container suffix without exposing the upstream name.
    final suffix =
        RegExp(
          r'\.(m3u8|ts|m4s|mp4|aac|mp3|vtt|webvtt|key|cmfv|cmfa)$',
          caseSensitive: false,
        ).firstMatch(target.path)?.group(0)?.toLowerCase() ??
        '';
    final id = existing ?? '${session.hlsIds.length + 1}$suffix';
    session.hlsIds[target.toString()] = id;
    session.hlsTargets[id] = target;
    session.hlsOrder[id] = order;
    final port = _server?.port ?? 0;
    return 'http://127.0.0.1:$port/cd/$token/h/$id';
  }

  void _rememberBaiduHlsHosts(_GatewaySession session, Uri target) {
    if (session.descriptor.providerId != 'baidu' ||
        session.descriptor.transport != CloudDriveTransport.hls ||
        !target.queryParameters.containsKey('backhost')) {
      return;
    }
    final routes = baiduHlsHostCandidates(target);
    if (routes.length > 1) {
      // The real playlist declares backups on its FIRST segment only. Save
      // them while rewriting, before a non-zero start requests a later segment.
      session.baiduHlsBackups[target.authority] = routes
          .skip(1)
          .map((uri) => uri.authority)
          .toList(growable: false);
    }
  }

  List<Uri> _baiduHlsCandidates(_GatewaySession session, Uri target) {
    if (session.descriptor.providerId != 'baidu' ||
        session.descriptor.transport != CloudDriveTransport.hls) {
      return [target];
    }
    return baiduHlsHostCandidates(
      target,
      preferredAuthority: session.baiduHlsHosts[target.authority],
      inheritedAuthorities:
          session.baiduHlsBackups[target.authority] ?? const [],
    );
  }

  Future<Uri?> _remapHls(
    _GatewaySession session,
    String hlsId,
    Uri playlistUri,
    CloudDriveCancelToken cancel,
  ) async {
    final old = session.hlsTargets[hlsId];
    if (old == null) return null;
    final upstream = await _upstream.open(
      CloudDriveUpstreamRequest(
        method: 'GET',
        uri: playlistUri,
        headersFor: (target) => _upstreamHeaders(session.descriptor, target),
        cancelToken: cancel,
        headerTimeout: headerTimeout,
        connectionScope: session.accountLocalId,
      ),
    );
    final text = await _readText(upstream, maxBytes: 2 * 1024 * 1024);
    await upstream.close();
    if (text == null || !text.contains('#EXTM3U')) return null;
    final base = upstream.effectiveUri ?? playlistUri;
    session.playlistText = text;
    session.playlistBase = base;
    final uris = extractHlsUris(text, base);
    for (final uri in uris) {
      _rememberBaiduHlsHosts(session, uri);
    }
    final name = old.pathSegments.isEmpty ? '' : old.pathSegments.last;
    final named = uris
        .where(
          (uri) => uri.pathSegments.isNotEmpty && uri.pathSegments.last == name,
        )
        .toList();
    if (named.length == 1) return named.single;
    final index = session.hlsOrder[hlsId];
    if (index != null && index >= 0 && index < uris.length) return uris[index];
    return null;
  }

  Map<String, String> _upstreamHeaders(
    CloudDrivePlaybackDescriptor descriptor,
    Uri uri, {
    String? range,
  }) {
    final cookie = CloudDriveCredential(
      cookies: descriptor.cookies,
    ).headerFor(uri);
    return {
      'User-Agent': descriptor.userAgent,
      'Referer': descriptor.referer,
      if (cookie.isNotEmpty) 'Cookie': cookie,
      'Range': ?range,
    };
  }

  void _copyMediaHeaders(
    Map<String, String> headers,
    HttpResponse response, {
    required bool dropLength,
  }) {
    const allowed = {
      'content-type',
      'content-length',
      'content-range',
      'accept-ranges',
    };
    for (final entry in headers.entries) {
      if (!allowed.contains(entry.key)) continue;
      if (dropLength && entry.key == 'content-length') continue;
      response.headers.set(entry.key, entry.value);
    }
  }

  void _rangeNotSatisfiable(HttpResponse response, int? total) {
    response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
    final header = unsatisfiableContentRange(total);
    if (header != null) {
      response.headers.set(HttpHeaders.contentRangeHeader, header);
    }
  }

  Future<void> _finish(HttpRequest request, int status, String message) async {
    _note('gateway status=$status');
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType(
      'text',
      'plain',
      charset: 'utf-8',
    );
    if (request.method != 'HEAD') request.response.write(message);
    await request.response.close();
  }

  /// Returns null when the body exceeds [maxBytes]. Never UTF-8 decodes media.
  Future<String?> _readText(
    CloudDriveUpstreamResponse upstream, {
    required int maxBytes,
  }) async {
    final body = upstream.body;
    if (body == null) return '';
    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in body) {
      total += chunk.length;
      if (total > maxBytes) return null;
      builder.add(chunk);
    }
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  }

  _ParsedToken? _tokenOf(String path) {
    final parts = Uri.parse(path).pathSegments;
    if (parts.length == 2 && parts[0] == 'cd') {
      return _ParsedToken(parts[1], null);
    }
    if (parts.length == 4 && parts[0] == 'cd' && parts[2] == 'h') {
      return _ParsedToken(parts[1], parts[3]);
    }
    return null;
  }

  void _note(String message) {
    final sink = onDiagnostic;
    if (sink == null) return;
    sink(redactCloudDriveLog(message));
  }
}

class _ParsedToken {
  const _ParsedToken(this.session, this.hlsId);
  final String session;
  final String? hlsId;
}

class _CloudDriveTransferCancelled implements Exception {
  const _CloudDriveTransferCancelled();
}

class _GatewaySession {
  _GatewaySession(this.descriptor);

  CloudDrivePlaybackDescriptor descriptor;
  String? accountLocalId;
  final Map<String, Uri> hlsTargets = {};
  final Map<String, String> hlsIds = {};
  final Map<String, int> hlsOrder = {};
  // Per lease: a healthy backup serves following segments without repeating
  // the failed PCDN redirect. No signed addresses are persisted.
  final Map<String, String> baiduHlsHosts = {};
  final Map<String, List<String>> baiduHlsBackups = {};
  bool? baiduMp4Timeline;
  Future<bool>? baiduMp4Probe;
  final Set<CloudDriveCancelToken> reads = {};
  String? playlistText;
  Uri? playlistBase;
  Future<CloudDrivePlaybackDescriptor?>? _refreshing;
  var closed = false;
  var needsReopen = false;
  void Function()? onNeedsReopen;
  void Function(CloudDrivePlaybackDescriptor)? onDescriptor;

  void adopt(CloudDrivePlaybackDescriptor next) {
    if (closed) return;
    descriptor = next;
    onDescriptor?.call(next);
  }

  /// One refresh is shared by concurrent failures. A later expiry may refresh
  /// again; a single request still retries the new address only once.
  Future<CloudDrivePlaybackDescriptor?> refresh(
    CloudDriveDescriptorRefresher? refresher,
    CancellableCloudDriveDescriptorRefresher? cancellableRefresher,
    Duration timeout,
  ) {
    final existing = _refreshing;
    if (existing != null) return existing;
    if ((refresher == null && cancellableRefresher == null) || closed) {
      return Future.value();
    }
    final cancel = CloudDriveCancelToken();
    reads.add(cancel);
    late final Future<CloudDrivePlaybackDescriptor?> future;
    future = Future<void>.value().then((_) async {
      try {
        if (closed || cancel.isCancelled) return null;
        final work = cancellableRefresher != null
            ? cancellableRefresher(descriptor, cancel)
            : refresher!(descriptor);
        final result =
            await Future.any<CloudDrivePlaybackDescriptor?>([
              work,
              cancel.whenCancelled.then((_) => null),
            ]).timeout(
              timeout,
              onTimeout: () {
                cancel.cancel();
                return null;
              },
            );
        return closed || cancel.isCancelled ? null : result;
      } catch (_) {
        return null;
      } finally {
        reads.remove(cancel);
        if (identical(_refreshing, future)) _refreshing = null;
      }
    });
    _refreshing = future;
    return future;
  }

  Future<void> close() async {
    closed = true;
    for (final read in reads.toList()) {
      read.cancel();
    }
  }
}

class CloudDriveByteRange {
  const CloudDriveByteRange({
    required this.start,
    required this.suffix,
    this.endInclusive,
    this.suffixLength,
  });

  final int? start;
  final bool suffix;
  final int? endInclusive;
  final int? suffixLength;

  bool get startsAtZero => !suffix && (start ?? 0) == 0;
}

CloudDriveByteRange? parseCloudDriveByteRange(String header) {
  final match = RegExp(r'^\s*bytes=(\d*)-(\d*)\s*$').firstMatch(header);
  if (match == null) return null;
  final startText = match.group(1)!;
  final end = int.tryParse(match.group(2)!);
  if (startText.isEmpty) {
    if (end == null || end <= 0) return null;
    return CloudDriveByteRange(start: null, suffix: true, suffixLength: end);
  }
  final start = int.parse(startText);
  if (end != null && end < start) return null;
  return CloudDriveByteRange(start: start, suffix: false, endInclusive: end);
}

class CloudDriveRangeDecision {
  const CloudDriveRangeDecision({
    required this.reject,
    required this.markUnseekable,
    this.totalLength,
  });

  final bool reject;
  final bool markUnseekable;
  final int? totalLength;
}

/// Applies Range to an upstream that may ignore it.
///
/// A 200 from byte 0 is playable. Some providers label a valid Content-Range
/// as 200; preserve that compatibility, but refuse a later response unless its
/// range matches the request. `bytes */*` is never produced.
CloudDriveRangeDecision decideCloudDriveRange({
  required CloudDriveByteRange? requestRange,
  required int upstreamStatus,
  required String? upstreamContentRange,
  required int? upstreamContentLength,
}) {
  if (requestRange == null) {
    return const CloudDriveRangeDecision(reject: false, markUnseekable: false);
  }
  if (upstreamStatus == HttpStatus.partialContent ||
      upstreamStatus == HttpStatus.ok && upstreamContentRange != null) {
    final match = RegExp(
      r'^bytes (\d+)-(\d+)/(\d+|\*)$',
      caseSensitive: false,
    ).firstMatch(upstreamContentRange ?? '');
    final start = int.tryParse(match?[1] ?? '');
    final end = int.tryParse(match?[2] ?? '');
    final total = int.tryParse(match?[3] ?? '');
    final expectedStart = requestRange.suffix
        ? total == null || requestRange.suffixLength == null
              ? null
              : max(0, total - requestRange.suffixLength!)
        : requestRange.start;
    // A successful HTTP status alone does not prove this is the requested
    // suffix. Forwarding byte-zero here can replay the opening mid-stream.
    final valid =
        start != null &&
        end != null &&
        end >= start &&
        (total == null || end < total) &&
        expectedStart != null &&
        start == expectedStart &&
        (requestRange.endInclusive == null ||
            end <= requestRange.endInclusive!) &&
        (upstreamContentLength == null ||
            upstreamContentLength == end - start + 1);
    return CloudDriveRangeDecision(
      reject: !valid,
      markUnseekable: false,
      totalLength: total,
    );
  }
  if (upstreamStatus == HttpStatus.ok && requestRange.startsAtZero) {
    return const CloudDriveRangeDecision(reject: false, markUnseekable: true);
  }
  if (upstreamStatus == HttpStatus.ok ||
      upstreamStatus == HttpStatus.requestedRangeNotSatisfiable) {
    return CloudDriveRangeDecision(
      reject: true,
      markUnseekable: true,
      totalLength: upstreamContentLength,
    );
  }
  return const CloudDriveRangeDecision(reject: false, markUnseekable: false);
}

String? unsatisfiableContentRange(int? total) {
  if (total == null || total < 0) return null;
  return 'bytes */$total';
}

CloudDriveGatewayResource classifyCloudDriveGatewayResource({
  required Uri target,
  required bool hlsRoot,
  String? contentType,
}) {
  final type = (contentType ?? '').toLowerCase();
  final path = target.path.toLowerCase();
  if (type.contains('mpegurl') ||
      type.contains('m3u8') ||
      path.endsWith('.m3u8')) {
    return CloudDriveGatewayResource.manifest;
  }
  if (hlsRoot) return CloudDriveGatewayResource.manifest;
  if (path.endsWith('.vtt') ||
      path.endsWith('.srt') ||
      path.endsWith('.ass') ||
      path.endsWith('.ssa')) {
    return CloudDriveGatewayResource.subtitle;
  }
  if (path.endsWith('.key')) return CloudDriveGatewayResource.key;
  if (path.endsWith('.mp4') ||
      path.endsWith('.m4s') ||
      path.endsWith('.cmfv')) {
    return CloudDriveGatewayResource.initSegment;
  }
  if (path.endsWith('.ts') || path.endsWith('.aac') || path.endsWith('.m4a')) {
    return CloudDriveGatewayResource.segment;
  }
  return CloudDriveGatewayResource.progressive;
}

/// Rewrites playlist references onto opaque loopback ids.
///
/// Only playlist text is rewritten. The caller must not send media bytes here.
String rewriteHlsPlaylist(
  String playlist,
  Uri base,
  String Function(Uri resolved) mapUrl,
) {
  final lines = const LineSplitter().convert(playlist.replaceAll('\r\n', '\n'));
  final output = <String>[];
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      output.add(line);
      continue;
    }
    if (_hlsLineCarriesUri(trimmed)) {
      output.add(
        trimmed.replaceAllMapped(RegExp('URI="([^"]*)"'), (match) {
          final resolved = base.resolve(match.group(1)!);
          return 'URI="${mapUrl(resolved)}"';
        }),
      );
      continue;
    }
    if (trimmed.startsWith('#')) {
      output.add(line);
      continue;
    }
    output.add(mapUrl(base.resolve(trimmed)));
  }
  return '${output.join('\n')}\n';
}

List<Uri> extractHlsUris(String playlist, Uri base) {
  final uris = <Uri>[];
  rewriteHlsPlaylist(playlist, base, (uri) {
    uris.add(uri);
    return uri.toString();
  });
  return uris;
}

bool _hlsLineCarriesUri(String line) {
  final upper = line.toUpperCase();
  return upper.startsWith('#EXT-X-KEY') ||
      upper.startsWith('#EXT-X-MAP') ||
      upper.startsWith('#EXT-X-MEDIA') ||
      upper.startsWith('#EXT-X-I-FRAME-STREAM-INF') ||
      upper.startsWith('#EXT-X-SESSION-KEY') ||
      upper.startsWith('#EXT-X-IMAGE-STREAM-INF') ||
      upper.startsWith('#EXT-X-PRELOAD-HINT');
}
