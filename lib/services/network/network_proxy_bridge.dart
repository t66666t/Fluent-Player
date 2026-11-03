import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'network_models.dart';
import 'network_settings_service.dart';
import 'platform_proxy_resolver.dart';

/// Timings only: no request paths, signed query strings or proxy credentials.
class NetworkConnectionTiming {
  const NetworkConnectionTiming(
    this.scope,
    this.connectionId,
    this.host,
    this.phase,
    this.elapsedMilliseconds,
  );
  final NetworkScope scope;
  final int connectionId;
  final String host;
  final String phase;
  final int elapsedMilliseconds;
}

/// A loopback forwarder for clients that cannot evaluate device proxy settings.
/// HTTPS uses CONNECT: origin TLS is still verified by the original client.
/// Upstream proxy credentials never leave this process or enter child arguments.
class NetworkProxyBridge {
  final _connectionTimings =
      StreamController<NetworkConnectionTiming>.broadcast();
  int _connectionSequence = 0;
  Stream<NetworkConnectionTiming> get connectionTimings =>
      _connectionTimings.stream;
  static const podcastFailureHeader = 'x-app-podcast-connection-error';
  final podcastFailureToken = base64Url.encode(
    List<int>.generate(24, (_) => Random.secure().nextInt(256)),
  );
  final NetworkSettingsService settings;
  final SystemProxyResolver resolver;
  final Future<Socket> Function(String host, int port, bool secure)?
  socketConnector;
  final Duration handshakeTimeout;
  final Map<String, Future<_Endpoint>> _endpoints = {};
  NetworkProxyBridge({
    NetworkSettingsService? settings,
    SystemProxyResolver? resolver,
    this.socketConnector,
    this.handshakeTimeout = const Duration(seconds: 20),
  }) : settings = settings ?? NetworkSettingsService.instance,
       resolver = resolver ?? PlatformProxyResolver();

  Future<Uri> endpoint(RequestNetworkContext context) async {
    await settings.ready;
    // A stable listener chooses the latest route for each NEW connection.
    // Established transfers drain on their chosen route instead of being
    // destroyed by a focus change, proxy edit, or network notification.
    // Protected submissions retain their original snapshot and are never replayed.
    final endpoint = await _acquire(
      context.cancelOnChange
          ? 'current:${context.scope.name}:${context.modeOverride?.name ?? 'feature'}'
          : '${context.key}:${context.modeOverride?.name ?? 'feature'}',
      context,
      stable: context.cancelOnChange,
    );
    return Uri(scheme: 'http', host: '127.0.0.1', port: endpoint.server.port);
  }

  /// Podcast automatic routing reads device proxies without inheriting manual
  /// feature modes, custom proxy credentials, or settings migration failures.
  Future<Uri> podcastSystemEndpoint() async {
    final endpoint = await _acquire(
      'podcast:auto:system',
      RequestNetworkContext(
        scope: NetworkScope.podcasts,
        configuration: NetworkConfiguration(),
        cancelOnChange: false,
      ),
    );
    return Uri(scheme: 'http', host: '127.0.0.1', port: endpoint.server.port);
  }

  /// Native browsers retain proxy addresses. Keep their loopback port stable
  /// and choose the current policy for each new connection after a switch.
  Future<Uri> browserEndpoint(NetworkScope scope, {Uri? source}) async {
    final context = await settings.context(scope, source: source);
    final endpoint = await _acquire(
      'browser:${scope.name}',
      context,
      stable: true,
    );
    return Uri(scheme: 'http', host: '127.0.0.1', port: endpoint.server.port);
  }

  Future<_Endpoint> _acquire(
    String key,
    RequestNetworkContext context, {
    bool stable = false,
  }) async {
    final future = _endpoints[key] ??= _start(context, stable: stable);
    try {
      return await future;
    } catch (_) {
      if (identical(_endpoints[key], future)) _endpoints.remove(key);
      rethrow;
    }
  }

  Future<_Endpoint> _start(
    RequestNetworkContext context, {
    bool stable = false,
  }) async {
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
      shared: false,
    );
    final endpoint = _Endpoint(server, context, stable: stable);
    server.listen((request) => unawaited(_serve(endpoint, request)));
    return endpoint;
  }

  Future<List<ProxyProfile?>> _routes(
    RequestNetworkContext context,
    Uri uri,
  ) async {
    if (NetworkSites.isLoopback(uri.host) ||
        context.mode == NetworkMode.direct) {
      return [null];
    }
    if (context.mode == NetworkMode.custom) {
      final profile = context.configuration.proxy;
      if (profile == null) throw const NetworkSettingsException('请先保存代理配置');
      return [profile];
    }
    return resolver.resolve(uri);
  }

  Future<void> _serve(_Endpoint endpoint, HttpRequest request) async {
    final watch = Stopwatch()..start();
    final connectionId = ++_connectionSequence;
    _Connection? connection;
    Socket? local;
    Socket? connecting;
    var peerClosed = false;
    unawaited(
      request.response.done.then<void>(
        (_) {},
        onError: (Object _) {
          peerClosed = true;
          connecting?.destroy();
        },
      ),
    );
    try {
      final context = endpoint.stable
          ? await settings.context(
              endpoint.context.scope,
              source: endpoint.context.source,
              modeOverride: endpoint.context.modeOverride,
              cancelOnChange: const [
                'GET',
                'HEAD',
                'OPTIONS',
                'CONNECT',
              ].contains(request.method),
            )
          : endpoint.context;
      final connect = request.method == 'CONNECT';
      final target = connect
          ? Uri.parse('https://${request.uri}')
          : request.uri;
      if (!target.hasAuthority ||
          !['http', 'https'].contains(target.scheme) ||
          target.userInfo.isNotEmpty ||
          target.port < 1 ||
          target.port > 65535) {
        request.response.statusCode = 400;
        await request.response.close();
        return;
      }
      final routes = await _routes(context, target);
      void timing(String phase) {
        if (_connectionTimings.hasListener) {
          _connectionTimings.add(
            NetworkConnectionTiming(
              context.scope,
              connectionId,
              target.host,
              phase,
              watch.elapsedMilliseconds,
            ),
          );
        }
      }

      timing('route resolved');
      Object? failure;
      for (final route in routes) {
        try {
          if (endpoint.closed || peerClosed) {
            throw const SocketException('连接已关闭');
          }
          connection = await _connect(
            context,
            target,
            route,
            tunnel: connect,
            onPhase: (phase) =>
                timing('${route?.protocol.name ?? 'direct'} $phase'),
            onSocket: (socket) {
              connecting = socket;
              endpoint.sockets.add(socket);
              if (endpoint.closed || peerClosed) {
                throw const SocketException('连接已关闭');
              }
            },
          );
          break;
        } catch (error) {
          failure = error;
          if (connecting != null) endpoint.sockets.remove(connecting);
          connecting = null;
          if (endpoint.closed || peerClosed) break;
        }
      }
      if (connection == null) throw failure ?? const SocketException('代理连接失败');
      endpoint.sockets.add(connection.socket);
      if (!context.cancelOnChange) {
        endpoint.protectedSockets.add(connection.socket);
      }
      if (endpoint.closed) throw const SocketException('网络设置已更新');
      if (!connect) {
        final absolute = connection.httpProxy;
        final path = target.replace(fragment: '').toString();
        final originPath =
            '${target.path.isEmpty ? '/' : target.path}${target.hasQuery ? '?${target.query}' : ''}';
        final headers = StringBuffer(
          '${request.method} ${absolute ? path : originPath} HTTP/1.1\r\n',
        );
        const excluded = {
          'proxy-authorization',
          'proxy-connection',
          'connection',
          'keep-alive',
          'transfer-encoding',
          'expect',
          'upgrade',
        };
        request.headers.forEach((name, values) {
          if (!excluded.contains(name.toLowerCase())) {
            for (final value in values) {
              headers.write('$name: $value\r\n');
            }
          }
        });
        headers.write('Connection: close\r\n');
        if (connection.httpProxy && connection.authorization != null) {
          headers.write('Proxy-Authorization: ${connection.authorization}\r\n');
        }
        final chunked = request.contentLength < 0;
        if (chunked) headers.write('Transfer-Encoding: chunked\r\n');
        headers.write('\r\n');
        connection.socket.add(latin1.encode(headers.toString()));
        await connection.socket.addStream(
          request.map(
            (chunk) => chunked
                ? <int>[
                    ...ascii.encode('${chunk.length.toRadixString(16)}\r\n'),
                    ...chunk,
                    13,
                    10,
                  ]
                : chunk,
          ),
        );
        if (chunked) connection.socket.add(ascii.encode('0\r\n\r\n'));
        await connection.socket.flush();
      }
      local = await request.response.detachSocket(writeHeaders: false);
      endpoint.sockets.add(local);
      if (!context.cancelOnChange) endpoint.protectedSockets.add(local);
      if (connect) {
        local.add(ascii.encode('HTTP/1.1 200 Connection Established\r\n\r\n'));
        await local.flush();
      }
      // addStream applies backpressure to both directions; media is not buffered.
      final upstream = connection;
      await Future.wait([
        local
            .addStream(upstream.reader.remaining())
            .then((_) => local!.close()),
        if (connect)
          upstream.socket.addStream(local).then((_) => upstream.socket.close()),
      ]);
    } catch (_) {
      if (local == null) {
        try {
          request.response.statusCode = 502;
          request.response.headers.set(
            'x-app-network-error',
            'selected-route-unavailable',
          );
          if (endpoint.context.scope == NetworkScope.podcasts) {
            // The token is generated locally and is never sent upstream.
            request.response.headers.set(
              podcastFailureHeader,
              podcastFailureToken,
            );
          }
          request.response.write('所选网络方式连接失败');
          await request.response.close();
        } catch (_) {
          /* Peer already cancelled. */
        }
      }
    } finally {
      if (connection != null) {
        endpoint.sockets.remove(connection.socket);
        endpoint.protectedSockets.remove(connection.socket);
        connection.socket.destroy();
      }
      if (local != null) {
        endpoint.sockets.remove(local);
        endpoint.protectedSockets.remove(local);
        local.destroy();
      }
    }
  }

  Future<_Connection> _connect(
    RequestNetworkContext context,
    Uri target,
    ProxyProfile? proxy, {
    required bool tunnel,
    required void Function(Socket) onSocket,
    void Function(String)? onPhase,
  }) async {
    final secure = proxy?.protocol == ProxyProtocol.https;
    final socket = socketConnector != null
        ? await socketConnector!(
            NetworkSites.socketHost(proxy?.host ?? target.host),
            proxy?.port ?? target.port,
            secure,
          )
        : secure
        ? await SecureSocket.connect(
            NetworkSites.socketHost(proxy!.host),
            proxy.port,
            timeout: const Duration(seconds: 15),
          )
        : await Socket.connect(
            NetworkSites.socketHost(proxy?.host ?? target.host),
            proxy?.port ?? target.port,
            timeout: const Duration(seconds: 15),
          );
    final reader = _SocketReader(socket);
    try {
      onSocket(socket);
      onPhase?.call('socket connected');
      final password = proxy?.credentialKey != null
          ? await settings.passwordFor(proxy)
          : proxy?.transientPassword;
      final username = proxy?.username;
      final authorization = username == null
          ? null
          : 'Basic ${base64Encode(utf8.encode('$username:${password ?? ''}'))}';
      if (proxy?.protocol == ProxyProtocol.socks5) {
        await _socks(
          socket,
          reader,
          target,
          username,
          password,
        ).timeout(handshakeTimeout);
      } else if (proxy != null && tunnel) {
        final host = NetworkSites.socketHost(target.host);
        final authority =
            '${host.contains(':') ? '[$host]' : host}:${target.port}';
        socket.add(
          ascii.encode(
            'CONNECT $authority HTTP/1.1\r\nHost: $authority\r\n'
            '${authorization == null ? '' : 'Proxy-Authorization: $authorization\r\n'}\r\n',
          ),
        );
        await socket.flush();
        // A per-byte idle timeout alone lets a drip-fed handshake wait forever.
        final header = await reader.header().timeout(handshakeTimeout);
        if (!RegExp(
          r'^HTTP/1\.[01] 200(?: |\r)',
        ).hasMatch(latin1.decode(header))) {
          throw const SocketException('代理拒绝连接');
        }
      }
      onPhase?.call('connection ready');
      return _Connection(
        socket,
        reader,
        httpProxy:
            proxy != null && !tunnel && proxy.protocol != ProxyProtocol.socks5,
        authorization: authorization,
      );
    } catch (_) {
      socket.destroy();
      rethrow;
    }
  }

  Future<void> _socks(
    Socket socket,
    _SocketReader reader,
    Uri target,
    String? username,
    String? password,
  ) async {
    socket.add(username == null ? [5, 1, 0] : [5, 1, 2]);
    await socket.flush();
    final greeting = await reader.exact(2);
    if (greeting[0] != 5 || greeting[1] != (username == null ? 0 : 2)) {
      throw const SocketException('SOCKS5 认证方式不受支持');
    }
    if (username != null) {
      final user = utf8.encode(username), pass = utf8.encode(password ?? '');
      if (user.length > 255 || pass.length > 255) {
        throw const SocketException('SOCKS5 凭据过长');
      }
      socket.add([1, user.length, ...user, pass.length, ...pass]);
      await socket.flush();
      final auth = await reader.exact(2);
      if (auth[0] != 1 || auth[1] != 0) {
        throw const SocketException('SOCKS5 认证失败');
      }
    }
    // Domain-name requests preserve proxy DNS. Numeric IPv6 is encoded as IPv6.
    final address = InternetAddress.tryParse(
      NetworkSites.socketHost(target.host),
    );
    final host = utf8.encode(NetworkSites.socketHost(target.host));
    if (host.length > 255) throw const SocketException('主机名过长');
    final destination = address == null
        ? [3, host.length, ...host]
        : [
            address.type == InternetAddressType.IPv4 ? 1 : 4,
            ...address.rawAddress,
          ];
    socket.add([5, 1, 0, ...destination, target.port >> 8, target.port & 255]);
    await socket.flush();
    final reply = await reader.exact(4);
    if (reply[0] != 5 || reply[1] != 0) {
      throw const SocketException('SOCKS5 连接失败');
    }
    final length = switch (reply[3]) {
      1 => 4,
      4 => 16,
      3 => (await reader.exact(1))[0],
      _ => throw const SocketException('SOCKS5 响应无效'),
    };
    await reader.exact(length + 2);
  }

  Future<void> close() async {
    for (final endpoint in _endpoints.values) {
      try {
        (await endpoint).close();
      } catch (_) {
        /* Failed bind has no socket. */
      }
    }
    _endpoints.clear();
  }
}

class _Endpoint {
  final bool stable;
  final HttpServer server;
  final RequestNetworkContext context;
  final Set<Socket> sockets = {};
  final Set<Socket> protectedSockets = {};
  bool closed = false;
  _Endpoint(this.server, this.context, {this.stable = false});
  void stopConnections({bool includeProtected = false}) {
    for (final socket in sockets.toList()) {
      if (!includeProtected && protectedSockets.contains(socket)) continue;
      socket.destroy();
      sockets.remove(socket);
      protectedSockets.remove(socket);
    }
  }

  void close() {
    closed = true;
    stopConnections(includeProtected: true);
    unawaited(server.close(force: true));
  }
}

class _Connection {
  final Socket socket;
  final _SocketReader reader;
  final bool httpProxy;
  final String? authorization;
  _Connection(
    this.socket,
    this.reader, {
    this.httpProxy = false,
    this.authorization,
  });
}

class _SocketReader {
  final StreamIterator<Uint8List> iterator;
  Uint8List _buffer = Uint8List(0);
  _SocketReader(Socket socket) : iterator = StreamIterator(socket);
  Future<List<int>> exact(int count) async {
    final result = <int>[];
    while (result.length < count) {
      if (_buffer.isEmpty) {
        if (!await iterator.moveNext().timeout(const Duration(seconds: 20))) {
          throw const SocketException('连接提前关闭');
        }
        _buffer = iterator.current;
      }
      final take = count - result.length < _buffer.length
          ? count - result.length
          : _buffer.length;
      result.addAll(_buffer.sublist(0, take));
      _buffer = _buffer.sublist(take);
    }
    return result;
  }

  Future<List<int>> header() async {
    final bytes = <int>[];
    while (bytes.length < 32768) {
      bytes.add((await exact(1))[0]);
      if (bytes.length >= 4 &&
          bytes[bytes.length - 4] == 13 &&
          bytes[bytes.length - 3] == 10 &&
          bytes[bytes.length - 2] == 13 &&
          bytes.last == 10) {
        return bytes;
      }
    }
    throw const SocketException('代理响应头过长');
  }

  Stream<Uint8List> remaining() async* {
    if (_buffer.isNotEmpty) {
      yield _buffer;
      _buffer = Uint8List(0);
    }
    while (await iterator.moveNext()) {
      yield iterator.current;
    }
  }
}
