import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/network/network_http.dart';
import 'package:video_player_app/services/network/network_proxy_bridge.dart';

import 'network_proxy_bridge_test.dart' show FakeProxyResolver;
import 'network_settings_service_test.dart'
    show MemoryNetworkStore, MemoryCredentials;
import 'network_transport_security_test.dart' show serverTls, trustedTls;

class _TrustedNetwork extends NetworkHttp {
  _TrustedNetwork({required super.settings, required super.bridge});
  int clientsCreated = 0;
  @override
  HttpClient createClient({
    NetworkScope scope = NetworkScope.other,
    Uri? source,
    RequestNetworkContext? context,
    NetworkMode? modeOverride,
    bool cancelOnChange = true,
    SecurityContext? securityContext,
  }) {
    clientsCreated++;
    final client = super.createClient(
      scope: scope,
      source: source,
      context: context,
      modeOverride: modeOverride,
      cancelOnChange: cancelOnChange,
      securityContext: trustedTls(),
    );
    if (context?.mode == NetworkMode.direct) {
      // Map the fixture hostname to localhost while retaining hostname and
      // certificate verification, matching the native direct path in production.
      client.connectionFactory = (uri, _, _) async {
        final socket = await Socket.connect('127.0.0.1', uri.port);
        final secured = SecureSocket.secure(
          socket,
          host: uri.host,
          context: trustedTls(),
        );
        return ConnectionTask.fromSocket(secured, socket.destroy);
      };
    }
    return client;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;
  late NetworkSettingsService settings;
  late _TrustedNetwork network;
  late Dio dio;
  late String url;
  final ports = <int>[];
  late Future<void> Function(HttpRequest) respond;

  setUp(() async {
    HttpOverrides.global = null;
    ports.clear();
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      serverTls(),
    );
    settings = NetworkSettingsService(
      store: MemoryNetworkStore(),
      credentials: MemoryCredentials(),
      migrateLegacy: false,
    );
    await settings.ready;
    network = _TrustedNetwork(
      settings: settings,
      bridge: NetworkProxyBridge(
        settings: settings,
        resolver: FakeProxyResolver([null]),
        socketConnector: (_, _, _) => Socket.connect('127.0.0.1', server.port),
      ),
    );
    dio = network.createDio(scope: NetworkScope.speechRecognition);
    url = 'https://origin.test:${server.port}/task/result';
    respond = (request) async {
      request.response.write('result');
      await request.response.close();
    };
    server.listen((request) async {
      ports.add(request.connectionInfo!.remotePort);
      await request.drain<void>();
      await respond(request);
    }, onError: (_) {});
  });

  tearDown(() async {
    dio.close(force: true);
    await network.dispose();
    await server.close(force: true);
  });

  test('repeated result polls reuse a verified TLS connection', () async {
    for (var i = 0; i < 4; i++) {
      expect((await dio.get<String>(url)).data, 'result');
    }
    expect(ports, hasLength(4));
    expect(ports.toSet(), hasLength(1));
    expect(network.clientsCreated, 1);
  });

  test(
    'changing the network route rotates the pool and drains the old body',
    () async {
      final release = Completer<void>();
      final started = Completer<void>();
      respond = (request) async {
        if (request.uri.path == '/slow') {
          request.response.bufferOutput = false;
          request.response.contentLength = 6;
          request.response.write('old');
          await request.response.flush();
          started.complete();
          await release.future;
          request.response.write('end');
        } else {
          request.response.write('new');
        }
        await request.response.close();
      };
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final old = dio.get<String>('https://origin.test:${server.port}/slow');
      await started.future;
      await settings.setMode(
        NetworkScope.speechRecognition,
        NetworkMode.system,
      );
      expect((await dio.get<String>(url)).data, 'new');
      release.complete();
      expect((await old).data, 'oldend');
      expect((await dio.get<String>(url)).data, 'new');
      expect(ports[0], isNot(ports[1]));
      expect(ports[0], isNot(ports[2]));
    },
  );

  test(
    'cancelling one request does not close a peer on the shared client',
    () async {
      final release = Completer<void>();
      final started = Completer<void>();
      final cancelStarted = Completer<void>();
      respond = (request) async {
        if (request.uri.path == '/slow') {
          request.response.bufferOutput = false;
          request.response.contentLength = 6;
          request.response.write('old');
          await request.response.flush();
          started.complete();
          await release.future;
          request.response.write('end');
        } else if (request.uri.path == '/cancel') {
          request.response.bufferOutput = false;
          request.response.contentLength = 4;
          request.response.write('c');
          await request.response.flush();
          cancelStarted.complete();
          await release.future;
          try {
            request.response.write('end');
            await request.response.close();
          } catch (_) {
            /* The caller intentionally cancelled this response. */
          }
          return;
        } else {
          request.response.write('result');
        }
        await request.response.close();
      };
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final peer = dio.get<String>('https://origin.test:${server.port}/slow');
      await started.future;
      final cancellation = CancelToken();
      final cancelled = expectLater(
        dio.get<String>(
          'https://origin.test:${server.port}/cancel',
          cancelToken: cancellation,
        ),
        throwsA(
          isA<DioException>().having(CancelToken.isCancel, 'cancelled', isTrue),
        ),
      );
      await cancelStarted.future;
      cancellation.cancel('pause caller');
      await cancelled;
      release.complete();
      expect((await peer).data, 'oldend');
      expect((await dio.get<String>(url)).data, 'result');
    },
  );
}
