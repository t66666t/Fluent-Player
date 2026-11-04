import '../../../services/community_media_input.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../../services/network/network_http.dart';
import '../models/cloud_drive_models.dart';

/// How much of an upstream body this client is allowed to buffer.
///
/// Media playback does not use this client. A two-byte probe must stop after
/// the prefix it needs, otherwise an ignored Range downloads the whole file
/// and then fails the 2MB cap.
enum CloudDriveReadMode { json, text, probe }

class CloudDriveCancelToken {
  var _cancelled = false;
  final List<void Function()> _listeners = <void Function()>[];
  final _cancelSignal = Completer<void>();

  bool get isCancelled => _cancelled;
  Future<void> get whenCancelled => _cancelSignal.future;

  /// Runs [listener] now when this token is already cancelled.
  void Function() onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _cancelSignal.complete();
    final pending = List<void Function()>.of(_listeners);
    _listeners.clear();
    for (final listener in pending) {
      try {
        listener();
      } catch (_) {
        // A failed abort must not hide the cancellation itself.
      }
    }
  }
}

/// Stop waiting for a connection without closing other requests in its pool.
/// A socket acquired after cancellation/timeout must never submit a late request.
Future<HttpClientRequest> openCloudDriveRequest(
  HttpClient client,
  String method,
  Uri uri, {
  required Duration timeout,
  CloudDriveCancelToken? cancelToken,
}) async {
  requireCommunityAuthorizedCloudDrive();
  const cancelled = CloudDriveFailure(CloudDriveFailureKind.network, '网盘请求已取消');
  if (cancelToken?.isCancelled == true) throw cancelled;
  return openNetworkRequest(
    client,
    method,
    uri,
    timeout: timeout,
    cancelSignal: cancelToken?.whenCancelled,
    cancellationError: cancelled,
  );
}

/// Retain only media negotiation headers. Credentials and provider-specific
/// headers require headersFor to explicitly select the new destination.
Map<String, String> cloudDriveRedirectHeaders(Map<String, String> headers) => {
  for (final entry in headers.entries)
    if (const {
      'range',
      'if-range',
      'accept',
      'accept-encoding',
      'accept-language',
      'user-agent',
    }.contains(entry.key.toLowerCase()))
      entry.key: entry.value,
};

class CloudDriveHttpRequest {
  const CloudDriveHttpRequest({
    required this.method,
    required this.uri,
    this.headers = const <String, String>{},
    this.headersFor,
    this.body,
    this.timeout = const Duration(seconds: 20),
    this.range,
    this.readMode = CloudDriveReadMode.json,
    this.maxBytes = 2 * 1024 * 1024,
    this.connectionScope,
    this.networkGeneration,
  });

  final String method;
  final Uri uri;
  final Map<String, String> headers;

  /// Recomputed on every redirect so a cookie is not forwarded to a new host
  /// unless that host is inside the cookie's own domain.
  final Map<String, String> Function(Uri uri)? headersFor;
  final List<int>? body;
  final Duration timeout;

  /// Inclusive byte range used only to probe a media response.
  final (int, int?)? range;
  final CloudDriveReadMode readMode;
  final int maxBytes;

  /// Accounts do not share a client. Null falls back to the request host.
  final String? connectionScope;

  /// When the network policy changes, the previous pool is retired.
  final int? networkGeneration;
}

class CloudDriveHttpResponse {
  const CloudDriveHttpResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
    required this.finalUri,
    this.cookies = const <CloudDriveCookie>[],
  });

  final int statusCode;
  final Map<String, String> headers;
  final List<int> body;

  /// The URI that produced [statusCode], after relative redirects are resolved.
  final Uri finalUri;

  /// Response cookies stay in memory and may rotate a provider session.
  final List<CloudDriveCookie> cookies;

  String get text => utf8.decode(body, allowMalformed: true);

  Map<String, dynamic>? get jsonMap {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }
}

/// Small JSON/probe client. Media bytes go through the stream gateway instead.
abstract class CloudDriveHttp {
  Future<CloudDriveHttpResponse> send(
    CloudDriveHttpRequest request, {
    Object? cancelToken,
  });
}

class NetworkCloudDriveHttp implements CloudDriveHttp {
  NetworkCloudDriveHttp({NetworkHttp? network})
    : _network = network ?? NetworkHttp.instance;

  final NetworkHttp _network;

  @override
  Future<CloudDriveHttpResponse> send(
    CloudDriveHttpRequest request, {
    Object? cancelToken,
  }) async {
    requireCommunityAuthorizedCloudDrive();
    final token = cancelToken is CloudDriveCancelToken ? cancelToken : null;
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
    // Redirects share one deadline. A new hop must not restart the full wait.
    final deadline = DateTime.now().add(request.timeout);
    Duration left() {
      final remain = deadline.difference(DateTime.now());
      if (remain <= Duration.zero) {
        throw TimeoutException('网盘请求超时');
      }
      return remain;
    }

    void Function()? removeAbort;
    try {
      if (token?.isCancelled == true) {
        throw const CloudDriveFailure(CloudDriveFailureKind.network, '网盘请求已取消');
      }
      var uri = request.uri;
      var method = request.method;
      for (var hop = 0; hop < 5; hop++) {
        removeAbort?.call();
        final ioRequest = await openCloudDriveRequest(
          client,
          method,
          uri,
          timeout: left(),
          cancelToken: token,
        );
        removeAbort = token?.onCancel(ioRequest.abort);
        ioRequest.followRedirects = false;
        final headers = _headersForHop(request, uri, hop);
        headers.forEach(ioRequest.headers.set);
        final range = request.range;
        if (range != null && (method == 'GET' || method == 'HEAD')) {
          final end = range.$2;
          ioRequest.headers.set(
            HttpHeaders.rangeHeader,
            end == null ? 'bytes=${range.$1}-' : 'bytes=${range.$1}-$end',
          );
        }
        if (request.body != null &&
            hop == 0 &&
            method != 'GET' &&
            method != 'HEAD') {
          ioRequest.add(request.body!);
        }
        final HttpClientResponse response;
        try {
          response = await ioRequest.close().timeout(left());
        } on TimeoutException {
          ioRequest.abort();
          rethrow;
        }
        if (token?.isCancelled == true) {
          await response.listen((_) {}).cancel();
          throw const CloudDriveFailure(
            CloudDriveFailureKind.network,
            '网盘请求已取消',
          );
        }
        if (response.statusCode >= 300 && response.statusCode < 400) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          await response.listen((_) {}).cancel();
          if (location == null || location.isEmpty) break;
          uri = resolveCloudDriveRedirect(uri, location);
          if (method != 'HEAD') method = 'GET';
          continue;
        }
        final bytes = await _readLimited(response, request, token, left());
        final headersOut = <String, String>{};
        response.headers.forEach((name, values) {
          headersOut[name.toLowerCase()] = values.join(',');
        });
        return CloudDriveHttpResponse(
          statusCode: response.statusCode,
          headers: headersOut,
          body: bytes,
          finalUri: uri,
          cookies: response.cookies
              .map((cookie) {
                return CloudDriveCookie(
                  name: cookie.name,
                  value: cookie.value,
                  domain: cookie.domain ?? uri.host,
                  path: cookie.path ?? '/',
                  secure: cookie.secure,
                );
              })
              .where((cookie) => cookie.matches(uri))
              .toList(growable: false),
        );
      }
      throw const CloudDriveFailure(CloudDriveFailureKind.network, '网盘重定向次数过多');
    } on CloudDriveFailure {
      rethrow;
    } on TimeoutException {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.network,
        '网盘请求超时，请稍后重试',
      );
    } on SocketException {
      throw CloudDriveFailure(
        CloudDriveFailureKind.network,
        token?.isCancelled == true ? '网盘请求已取消' : '暂时连不上网盘，请检查网络后重试',
      );
    } on HttpException {
      // abort() may complete close() before the response-body listener starts.
      throw CloudDriveFailure(
        CloudDriveFailureKind.network,
        token?.isCancelled == true ? '网盘请求已取消' : '网盘连接中断，请稍后重试',
      );
    } finally {
      removeAbort?.call();
      // Returning the client to the pool keeps the connection. Closing it
      // here would make the next manifest or Range pay for a new handshake.
      CloudDriveClientPools.release(scope: scope, generation: generation);
    }
  }

  Map<String, String> _headersForHop(
    CloudDriveHttpRequest request,
    Uri uri,
    int hop,
  ) {
    final computed = request.headersFor?.call(uri);
    if (computed != null) return computed;
    if (hop == 0) return request.headers;
    return cloudDriveRedirectHeaders(request.headers);
  }

  Future<List<int>> _readLimited(
    HttpClientResponse response,
    CloudDriveHttpRequest request,
    CloudDriveCancelToken? token,
    Duration timeout,
  ) async {
    final builder = BytesBuilder(copy: false);
    final completer = Completer<List<int>>();
    var total = 0;
    late final StreamSubscription<List<int>> subscription;
    subscription = response.listen(
      (chunk) {
        if (completer.isCompleted) return;
        if (token?.isCancelled == true) {
          unawaited(subscription.cancel());
          if (!completer.isCompleted) {
            completer.completeError(
              const CloudDriveFailure(CloudDriveFailureKind.network, '网盘请求已取消'),
            );
          }
          return;
        }
        final room = request.maxBytes - total;
        if (chunk.length > room) {
          if (request.readMode == CloudDriveReadMode.probe && room > 0) {
            builder.add(chunk.sublist(0, room));
          }
          unawaited(subscription.cancel());
          if (!completer.isCompleted) {
            if (request.readMode == CloudDriveReadMode.probe) {
              completer.complete(builder.takeBytes());
            } else {
              completer.completeError(
                CloudDriveFailure(
                  CloudDriveFailureKind.unavailable,
                  request.readMode == CloudDriveReadMode.text
                      ? '网盘文本超出读取上限'
                      : '网盘返回的数据超出读取上限',
                ),
              );
            }
          }
          return;
        }
        total += chunk.length;
        builder.add(chunk);
        if (total >= request.maxBytes &&
            request.readMode == CloudDriveReadMode.probe) {
          unawaited(subscription.cancel());
          if (!completer.isCompleted) completer.complete(builder.takeBytes());
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!completer.isCompleted) completer.completeError(error, stack);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete(builder.takeBytes());
      },
      cancelOnError: true,
    );
    final removeCancel = token?.onCancel(() {
      if (!completer.isCompleted) {
        completer.completeError(
          const CloudDriveFailure(CloudDriveFailureKind.network, '网盘请求已取消'),
        );
      }
    });
    try {
      return await completer.future.timeout(timeout);
    } finally {
      removeCancel?.call();
      await subscription.cancel();
    }
  }
}

/// Resolves one redirect hop. A relative Location stays on the current host.
Uri resolveCloudDriveRedirect(Uri current, String location) {
  return current.resolve(location);
}

/// One HttpClient per account/network generation. A response close must not
/// dispose the client, or the next request cannot reuse the connection.
class CloudDriveClientPools {
  static final Map<String, _PooledHttpClient> _pools = {};

  static HttpClient checkout({
    required String scope,
    required int generation,
    required HttpClient Function() createClient,
  }) {
    final key = '$scope|$generation';
    final stale = _pools.keys
        .where((item) => item.startsWith('$scope|') && item != key)
        .toList();
    for (final item in stale) {
      _pools.remove(item)?.retire();
    }
    final existing = _pools[key];
    if (existing != null) {
      existing.users++;
      existing.touch();
      return existing.client;
    }
    final client = createClient()
      ..idleTimeout = const Duration(seconds: 15)
      ..maxConnectionsPerHost = 6
      ..connectionTimeout = const Duration(seconds: 8);
    final pooled = _PooledHttpClient(client)..users = 1;
    _pools[key] = pooled;
    return client;
  }

  static void release({required String scope, required int generation}) {
    final pooled = _pools['$scope|$generation'];
    if (pooled == null) return;
    if (pooled.users > 0) pooled.users--;
    pooled.touch();
  }

  static void discard({required String scope, int? generation}) {
    final keys = _pools.keys.where((item) {
      if (!item.startsWith('$scope|')) return false;
      if (generation == null) return true;
      return item == '$scope|$generation';
    }).toList();
    for (final key in keys) {
      _pools.remove(key)?.retire();
    }
  }

  static void discardAll() {
    final pools = _pools.values.toList();
    _pools.clear();
    for (final pooled in pools) {
      pooled.retire();
    }
  }
}

class _PooledHttpClient {
  _PooledHttpClient(this.client);
  final HttpClient client;
  var users = 0;
  Timer? _idle;

  void touch() {
    _idle?.cancel();
    if (users > 0) return;
    _idle = Timer(const Duration(seconds: 15), () {
      CloudDriveClientPools._pools.removeWhere(
        (_, value) => identical(value, this),
      );
      retire();
    });
  }

  void retire() {
    _idle?.cancel();
    client.close(force: false);
  }
}

/// Network policy identity. A failure to read settings keeps one process-local
/// pool instead of opening a client per request.
int cloudDriveNetworkGeneration() {
  try {
    final settings = NetworkSettingsService.instance;
    return Object.hash(
      settings.configuration.revision,
      settings.deviceGeneration,
      settings.imageGeneration(NetworkScope.cloudDrive),
    );
  } catch (_) {
    return 0;
  }
}
