import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/widgets.dart';

import 'network_models.dart';
import 'network_proxy_bridge.dart';
import 'network_settings_service.dart';
import 'network_recovery.dart';
import 'platform_proxy_resolver.dart';

export 'network_models.dart';
export 'network_dio_stream.dart';
export 'network_response.dart';
export 'network_settings_service.dart';

class NetworkHttp with WidgetsBindingObserver {
  static const speechRecognitionDirectRecoveryKey =
      'speechRecognitionDirectRecovery';
  static const translationConnectionReuseKey = 'translationConnectionReuse';
  static const mediaConnectionReuseKey = 'mediaConnectionReuse';
  static const modelDownloadFreshConnectionKey = 'modelDownloadFreshConnection';
  static final instance = NetworkHttp();
  final NetworkSettingsService settings;
  final NetworkProxyBridge bridge;
  StreamSubscription<dynamic>? _events;
  Timer? _networkDebounce;
  bool _observing = false;
  NetworkHttp({NetworkSettingsService? settings, NetworkProxyBridge? bridge})
    : settings = settings ?? NetworkSettingsService.instance,
      bridge = bridge ?? NetworkProxyBridge(settings: settings);

  void observeDeviceNetwork() {
    if (_observing) return;
    _observing = true;
    WidgetsBinding.instance.addObserver(this);
    NetworkRecovery.handleLifecycle(WidgetsBinding.instance.lifecycleState);
    _events = PlatformProxyResolver.events.receiveBroadcastStream().listen((_) {
      _networkDebounce?.cancel();
      _networkDebounce = Timer(
        const Duration(milliseconds: 200),
        settings.deviceNetworkChanged,
      );
    }, onError: (_) {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Focus/visibility changes say nothing about the network route. Native
    // network/proxy notifications remain the source of device changes.
    NetworkRecovery.handleLifecycle(state);
  }

  HttpClient createClient({
    NetworkScope scope = NetworkScope.other,
    Uri? source,
    RequestNetworkContext? context,
    NetworkMode? modeOverride,
    bool cancelOnChange = true,
    SecurityContext? securityContext,
  }) {
    final client = HttpClient(context: securityContext);
    if ((context?.scope == NetworkScope.speechRecognition ||
            context?.scope == NetworkScope.cloudTranscription ||
            context?.scope == NetworkScope.modelDownloads) &&
        context?.mode == NetworkMode.direct) {
      // This route has already been selected by NetworkDioAdapter. Native
      // direct connections retain TLS verification and can reuse keep-alive
      // sockets without rebuilding a loopback CONNECT tunnel for each poll.
      client.findProxy = (_) => 'DIRECT';
      return client;
    }
    if (context?.scope == NetworkScope.cloudTranscription ||
        context?.scope == NetworkScope.modelDownloads) {
      // Pool by origin, including through a proxy. Dart otherwise creates a
      // proxy target for every request while returning the TLS tunnel to an
      // origin target, so retaining HttpClient alone does not reuse it.
      client.findProxy = (_) => 'DIRECT';
      client.connectionFactory = (uri, _, _) async {
        if (NetworkSites.isLoopback(uri.host)) {
          return _connectDirect(uri, securityContext);
        }
        final endpoint = await bridge.endpoint(context!);
        return _cloudConnection(uri, endpoint, securityContext);
      };
      return client;
    }
    final selected = <NetworkScope, Future<RequestNetworkContext>>{};
    // The placeholder is never connected to. It lets Dart prepare CONNECT while
    // the asynchronous connection factory loads settings and device PAC results.
    client.findProxy = (uri) =>
        NetworkSites.isLoopback(uri.host) ? 'DIRECT' : 'PROXY 127.0.0.1:1';
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      // Loopback gateways always connect directly. External connections wait
      // for migration before selecting a route.
      if (NetworkSites.isLoopback(uri.host)) {
        return _connectDirect(uri, securityContext);
      }
      await settings.ready;
      final requestScope = context?.scope ?? scope;
      final actualScope =
          requestScope == NetworkScope.podcasts ||
              requestScope == NetworkScope.podcastsDomestic
          ? NetworkSites.forPodcast(uri)
          : requestScope;
      var current = await (selected[actualScope] ??=
          context != null && context.scope == actualScope
          ? Future.value(context)
          : settings.context(
              actualScope,
              source: source ?? uri,
              cancelOnChange: cancelOnChange,
              modeOverride: modeOverride,
            ));
      if (context == null && !settings.isCurrent(current)) {
        current = await settings.context(
          actualScope,
          source: source ?? uri,
          cancelOnChange: cancelOnChange,
          modeOverride: modeOverride,
        );
        selected[actualScope] = Future.value(current);
      }
      final endpoint = await bridge.endpoint(current);
      return Socket.startConnect(endpoint.host, endpoint.port);
    };
    return client;
  }

  /// Automatic podcast routes apply only while no unified policy is selected.
  /// Direct sockets avoid a loopback hop; device proxy/PAC is evaluated by the
  /// existing bridge only when the destination needs the system route.
  HttpClient createPodcastClient({
    required NetworkMode Function(Uri) routeFor,
    SecurityContext? securityContext,
  }) {
    final client = HttpClient(context: securityContext);
    client.findProxy = (uri) =>
        NetworkSites.isLoopback(uri.host) ||
            settings.isLoaded &&
                (settings.configuration.unifiedMode ?? routeFor(uri)) ==
                    NetworkMode.direct
        ? 'DIRECT'
        : 'PROXY 127.0.0.1:1';
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      if (proxyHost == null || NetworkSites.isLoopback(uri.host)) {
        return _connectDirect(uri, securityContext);
      }
      await settings.ready;
      final unified = settings.configuration.unifiedMode;
      final automatic = routeFor(uri);
      final endpoint = unified == null && automatic == NetworkMode.system
          ? await bridge.podcastSystemEndpoint()
          : await bridge.endpoint(
              await settings.context(
                NetworkSites.forPodcast(uri),
                source: uri,
                modeOverride: unified == null ? automatic : null,
              ),
            );
      return Socket.startConnect(endpoint.host, endpoint.port);
    };
    return client;
  }

  static Future<ConnectionTask<Socket>> _connectDirect(
    Uri uri,
    SecurityContext? securityContext,
  ) {
    final host = NetworkSites.socketHost(uri.host);
    // A custom connectionFactory owns the TLS handshake for direct requests.
    // HttpClient only adds TLS itself when tunnelling through a proxy.
    return uri.scheme == 'https'
        ? SecureSocket.startConnect(host, uri.port, context: securityContext)
        : Socket.startConnect(host, uri.port);
  }

  static ConnectionTask<Socket> _cloudConnection(
    Uri uri,
    Uri endpoint,
    SecurityContext? securityContext,
  ) {
    Socket? socket;
    var cancelled = false;
    Future<Socket> connect() async {
      try {
        socket = await Socket.connect(
          endpoint.host,
          endpoint.port,
          timeout: const Duration(seconds: 20),
        );
        if (cancelled) throw const SocketException('连接已取消');
        final host = NetworkSites.socketHost(uri.host);
        final authority =
            '${host.contains(':') ? '[$host]' : host}:${uri.port}';
        socket!.add(
          ascii.encode(
            'CONNECT $authority HTTP/1.1\r\nHost: $authority\r\n\r\n',
          ),
        );
        await socket!.flush();
        final input = StreamIterator<Uint8List>(socket!);
        final header = <int>[];
        var end = -1;
        while (end < 0 && header.length < 32768 && await input.moveNext()) {
          final from = math.max(0, header.length - 3);
          header.addAll(input.current);
          for (var i = from; i + 3 < header.length; i++) {
            if (header[i] == 13 &&
                header[i + 1] == 10 &&
                header[i + 2] == 13 &&
                header[i + 3] == 10) {
              end = i + 4;
              break;
            }
          }
        }
        if (end < 0 ||
            !RegExp(
              r'^HTTP/1\.[01] 200(?: |\r)',
            ).hasMatch(latin1.decode(header.take(end).toList()))) {
          throw const SocketException('所选网络方式连接失败');
        }
        final buffered = header.sublist(end);
        if (cancelled) throw const SocketException('连接已取消');
        if (uri.scheme == 'https') {
          if (buffered.isNotEmpty) throw const SocketException('代理隧道返回了额外数据');
          // StreamIterator pauses its subscription at the header boundary;
          // SecureSocket takes ownership of the original raw socket here.
          socket = await SecureSocket.secure(
            socket!,
            host: uri.host,
            context: securityContext,
          );
        } else {
          Stream<Uint8List> remaining() async* {
            if (buffered.isNotEmpty) yield Uint8List.fromList(buffered);
            while (await input.moveNext()) {
              yield input.current;
            }
          }

          socket = _CloudTunnelSocket(socket!, remaining());
        }
        if (cancelled) throw const SocketException('连接已取消');
        return socket!;
      } catch (_) {
        socket?.destroy();
        rethrow;
      }
    }

    final opening = connect().timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        cancelled = true;
        socket?.destroy();
        throw const SocketException('代理连接等待超时');
      },
    );
    return ConnectionTask.fromSocket(opening, () {
      cancelled = true;
      socket?.destroy();
    });
  }

  bool isPodcastConnectionFailure(HttpClientResponse response) =>
      response.statusCode == 502 &&
      response.headers.value(NetworkProxyBridge.podcastFailureHeader) ==
          bridge.podcastFailureToken;

  Dio createDio({
    BaseOptions? options,
    NetworkScope scope = NetworkScope.other,
    Uri? source,
    NetworkMode? modeOverride,
  }) => configureDio(
    Dio(options),
    scope: scope,
    source: source,
    modeOverride: modeOverride,
  );

  Dio configureDio(
    Dio dio, {
    NetworkScope scope = NetworkScope.other,
    Uri? source,
    NetworkMode? modeOverride,
  }) {
    dio.httpClientAdapter = NetworkDioAdapter(
      this,
      scope,
      source,
      modeOverride,
    );
    // A valid response remains valid after a policy switch. Do not turn a
    // completed read into a cancellation or replay an already submitted write.
    return dio;
  }

  Future<Uri> externalProxy(
    NetworkScope scope, {
    Uri? source,
    RequestNetworkContext? context,
  }) async =>
      bridge.endpoint(context ?? await settings.context(scope, source: source));

  /// includeParentEnvironment must be false for child processes using this map.
  static Map<String, String> childEnvironment({
    Map<String, String>? environment,
  }) => {
    for (final entry in (environment ?? Platform.environment).entries)
      if (!{
        'http_proxy',
        'https_proxy',
        'all_proxy',
        'ftp_proxy',
        'no_proxy',
        'cgi_http_proxy',
        'request_method',
      }.contains(entry.key.toLowerCase()))
        entry.key: entry.value,
    'NO_PROXY': 'localhost,127.0.0.1,::1',
    'no_proxy': 'localhost,127.0.0.1,::1',
  };

  Future<void> dispose() async {
    _networkDebounce?.cancel();
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    await _events?.cancel();
    await bridge.close();
  }
}

/// Request clients retain submitted writes on their selected route. New read
/// connections adopt the current policy without interrupting in-flight bodies.
class NetworkDioAdapter implements HttpClientAdapter {
  final NetworkHttp network;
  final NetworkScope scope;
  final Uri? source;
  final NetworkMode? modeOverride;
  final Set<IOHttpClientAdapter> _active = {};
  // Model ranges share this file transfer's clients; translation/media opt in.
  final Map<String, _NetworkConnectionPool> _connectionPools = {};
  bool _closed = false;
  NetworkDioAdapter(this.network, this.scope, this.source, [this.modeOverride]);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (_closed) throw StateError('网络连接已关闭');
    final safe = const {
      'GET',
      'HEAD',
      'OPTIONS',
    }.contains(options.method.toUpperCase());
    var context = NetworkSites.isLoopback(options.uri.host)
        ? RequestNetworkContext(
            scope: scope,
            source: source,
            configuration: network.settings.configuration,
            cancelOnChange: false,
          )
        : await network.settings.context(
            scope,
            source: source,
            modeOverride: modeOverride,
            cancelOnChange:
                safe && options.extra['networkProtectSubmission'] != true,
          );
    if (scope == NetworkScope.speechRecognition &&
        options.extra[NetworkHttp.speechRecognitionDirectRecoveryKey] == true) {
      context = context.recoverSpeechRecognitionDirectly();
    }
    options.extra['appNetworkContext'] = context;
    _NetworkConnectionPool? pool;
    final reuse =
        scope == NetworkScope.cloudTranscription ||
        scope == NetworkScope.speechRecognition &&
            context.mode == NetworkMode.direct ||
        scope == NetworkScope.translation &&
            options.extra[NetworkHttp.translationConnectionReuseKey] == true ||
        scope == NetworkScope.modelDownloads &&
            safe &&
            options.extra[NetworkHttp.modelDownloadFreshConnectionKey] !=
                true ||
        scope == NetworkScope.other &&
            safe &&
            options.extra[NetworkHttp.mediaConnectionReuseKey] == true;
    if (reuse || scope == NetworkScope.speechRecognition) {
      for (final entry in _connectionPools.entries.toList()) {
        if (entry.key == context.key ||
            network.settings.isCurrent(entry.value.context)) {
          continue;
        }
        _connectionPools.remove(entry.key);
        entry.value.retired = true;
        if (entry.value.active == 0) entry.value.adapter.close();
      }
    }
    if (reuse) {
      pool = _connectionPools.putIfAbsent(
        context.key,
        () => _NetworkConnectionPool(
          context,
          IOHttpClientAdapter(
            createHttpClient: () => network.createClient(context: context),
          ),
        ),
      );
      pool.active++;
    }
    final adapter =
        pool?.adapter ??
        IOHttpClientAdapter(
          createHttpClient: () => network.createClient(context: context),
        );
    _active.add(adapter);
    var released = false;
    void release() {
      if (released) return;
      released = true;
      if (pool != null) {
        pool.active--;
        if (pool.active == 0) {
          _active.remove(adapter);
          if (pool.retired) adapter.close();
        }
      } else {
        _active.remove(adapter);
        adapter.close(force: true);
      }
    }

    try {
      final body = await adapter.fetch(options, requestStream, cancelFuture);
      final upstream = body.stream;
      late StreamController<Uint8List> forwarded;
      StreamSubscription<Uint8List>? subscription;
      forwarded = StreamController<Uint8List>(
        onListen: () {
          subscription = upstream.listen(
            forwarded.add,
            onError: (Object error, StackTrace stack) {
              release();
              forwarded.addError(error, stack);
            },
            onDone: () {
              release();
              forwarded.close();
            },
          );
        },
        onPause: () => subscription?.pause(),
        onResume: () => subscription?.resume(),
        onCancel: () async {
          await subscription?.cancel();
          release();
        },
      );
      body.stream = forwarded.stream;
      cancelFuture?.whenComplete(release);
      return body;
    } catch (_) {
      release();
      rethrow;
    }
  }

  @override
  void close({bool force = false}) {
    _closed = true;
    for (final adapter in {
      ..._active,
      ..._connectionPools.values.map((p) => p.adapter),
    }) {
      adapter.close(force: force);
    }
    _active.clear();
    _connectionPools.clear();
  }
}

class _NetworkConnectionPool {
  final RequestNetworkContext context;
  final IOHttpClientAdapter adapter;
  int active = 0;
  bool retired = false;
  _NetworkConnectionPool(this.context, this.adapter);
}

/// Plain HTTP gateways keep their bytes after the CONNECT header too.
/// Production cloud endpoints use the verified SecureSocket branch above.
class _CloudTunnelSocket extends StreamView<Uint8List> implements Socket {
  _CloudTunnelSocket(this.socket, super.stream);
  final Socket socket;
  @override
  Encoding get encoding => socket.encoding;
  @override
  set encoding(Encoding value) => socket.encoding = value;
  @override
  void write(Object? value) => socket.write(value);
  @override
  void writeln([Object? value = '']) => socket.writeln(value);
  @override
  void writeCharCode(int value) => socket.writeCharCode(value);
  @override
  void writeAll(Iterable values, [String separator = '']) =>
      socket.writeAll(values, separator);
  @override
  void add(List<int> bytes) => socket.add(bytes);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      socket.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) => socket.addStream(stream);
  @override
  void destroy() => socket.destroy();
  @override
  Future<void> flush() => socket.flush();
  @override
  Future<void> close() async => socket.close();
  @override
  Future<void> get done async => socket.done;
  @override
  int get port => socket.port;
  @override
  InternetAddress get address => socket.address;
  @override
  InternetAddress get remoteAddress => socket.remoteAddress;
  @override
  int get remotePort => socket.remotePort;
  @override
  bool setOption(SocketOption option, bool enabled) =>
      socket.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) => socket.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => socket.setRawOption(option);
}
