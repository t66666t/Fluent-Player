import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/model_center/cloud_asr_transport.dart';
import 'package:video_player_app/features/model_center/cloud_asr_types.dart';
import 'package:video_player_app/services/network/network_http.dart';
import 'package:video_player_app/services/network/network_proxy_bridge.dart';

import 'cloud_asr_test_support.dart';
import 'network_proxy_bridge_test.dart' show FakeProxyResolver;
import 'network_settings_service_test.dart'
    show MemoryNetworkStore, MemoryCredentials;
import 'network_transport_security_test.dart' show serverTls, trustedTls, Bytes;

class _TlsNetwork extends NetworkHttp {
  _TlsNetwork({
    required super.settings,
    required super.bridge,
    this.trust = true,
  });
  final bool trust;
  @override
  HttpClient createClient({
    NetworkScope scope = NetworkScope.other,
    Uri? source,
    RequestNetworkContext? context,
    NetworkMode? modeOverride,
    bool cancelOnChange = true,
    SecurityContext? securityContext,
  }) => super.createClient(
    scope: scope,
    source: source,
    context: context,
    modeOverride: modeOverride,
    cancelOnChange: cancelOnChange,
    securityContext: trust ? trustedTls() : securityContext,
  );
}

class _NeverSends implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    await cancelFuture;
    throw DioException.requestCancelled(
      requestOptions: options,
      reason: 'upload stalled',
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = null);
  NetworkSettingsService settings() => NetworkSettingsService(
    store: MemoryNetworkStore(),
    credentials: MemoryCredentials(),
    migrateLegacy: false,
  );

  test(
    'SOCKS5 keeps remote DNS and TLS reuse; a changed device route affects the next connection',
    () async {
      final origin = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        serverTls(),
      );
      final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[], originPorts = <int>{};
      var tunnels = 0;
      origin.listen((request) async {
        originPorts.add(request.connectionInfo!.remotePort);
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        request.response.write('{}');
        await request.response.close();
      }, onError: (_) {});
      proxy.listen((socket) async {
        sockets.add(socket);
        tunnels++;
        final input = Bytes(socket);
        expect(await input.take(3), [5, 1, 0]);
        socket.add([5, 0]);
        await socket.flush();
        expect(await input.take(4), [5, 1, 0, 3]);
        expect(
          utf8.decode(await input.take((await input.take(1)).single)),
          'origin.test',
        );
        expect(await input.take(2), [origin.port >> 8, origin.port & 255]);
        final upstream = await Socket.connect('127.0.0.1', origin.port);
        sockets.add(upstream);
        socket.add([5, 0, 0, 1, 127, 0, 0, 1, 0, 0]);
        await socket.flush();
        Stream<List<int>> remaining() async* {
          if (input.buffered.isNotEmpty) yield input.buffered;
          while (await input.iterator.moveNext()) {
            yield input.iterator.current;
          }
        }

        unawaited(
          upstream
              .addStream(remaining())
              .catchError((_) {})
              .whenComplete(upstream.destroy),
        );
        unawaited(
          socket
              .addStream(upstream)
              .catchError((_) {})
              .whenComplete(socket.destroy),
        );
      });
      final config = settings();
      await config.ready;
      final resolver = FakeProxyResolver([
        ProxyProfile(
          protocol: ProxyProtocol.socks5,
          host: '127.0.0.1',
          port: proxy.port,
        ),
      ]);
      final bridge = NetworkProxyBridge(
        settings: config,
        resolver: resolver,
        socketConnector: (host, port, secure) => Socket.connect(
          '127.0.0.1',
          host == 'origin.test' ? origin.port : port,
        ),
      );
      final network = _TlsNetwork(settings: config, bridge: bridge);
      final transport = CloudAsrTransport(
        cloudConnection(
          CloudAsrProvider.soniox,
          endpoint: 'https://origin.test:${origin.port}',
        ),
        dio: network.createDio(scope: NetworkScope.cloudTranscription),
      );
      addTearDown(() async {
        transport.close();
        await network.dispose();
        config.dispose();
        for (final socket in sockets) {
          socket.destroy();
        }
        await proxy.close();
        await origin.close(force: true);
      });
      for (var i = 0; i < 3; i++) {
        await transport.request('POST', '/submit', CancelToken(), data: {});
      }
      expect(tunnels, 1);
      expect(originPorts.length, 1);
      expect(resolver.calls, 1);
      resolver.routes = [null];
      config.deviceNetworkChanged();
      await transport.request('POST', '/new-route', CancelToken(), data: {});
      expect(tunnels, 1);
      expect(originPorts.length, 2);
      expect(resolver.calls, 2);
    },
  );

  test(
    'new network scope follows device settings and existing public policy is preserved',
    () async {
      final config = settings();
      addTearDown(config.dispose);
      await config.ready;
      expect(
        config.configuration.modes[NetworkScope.cloudTranscription],
        NetworkMode.system,
      );
      expect(
        config.configuration.modes[NetworkScope.speechRecognition],
        NetworkMode.direct,
      );
      final legacyJson = NetworkConfiguration().toJson();
      (legacyJson['modes'] as Map).remove('cloudTranscription');
      final old = NetworkConfiguration.fromJson(legacyJson);
      expect(old.modes[NetworkScope.cloudTranscription], NetworkMode.system);
      await config.setUnifiedMode(NetworkMode.direct);
      expect(
        (await config.context(NetworkScope.cloudTranscription)).mode,
        NetworkMode.direct,
      );
    },
  );

  test(
    'system/custom/direct connections are reused; new routes retain a submitted upload exactly once',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final systemProxy = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final customProxy = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final gate = Completer<void>(), submitted = Completer<void>();
      final calls = <String, int>{}, ports = <String, Set<int>>{};
      final routePorts = <int, String>{};
      for (final entry in {
        'direct': origin,
        'system': systemProxy,
        'custom': customProxy,
      }.entries) {
        entry.value.listen((request) async {
          if (request.method == 'CONNECT') {
            expect(request.headers.value('authorization'), isNull);
            final upstream = await Socket.connect('127.0.0.1', origin.port);
            routePorts[upstream.port] = entry.key;
            final downstream = await request.response.detachSocket(
              writeHeaders: false,
            );
            downstream.add(
              ascii.encode('HTTP/1.1 200 Connection Established\r\n\r\n'),
            );
            await downstream.flush();
            unawaited(
              upstream
                  .addStream(downstream)
                  .catchError((_) {})
                  .whenComplete(upstream.destroy),
            );
            unawaited(
              downstream
                  .addStream(upstream)
                  .catchError((_) {})
                  .whenComplete(downstream.destroy),
            );
            return;
          }
          final route =
              routePorts[request.connectionInfo!.remotePort] ?? 'direct';
          calls.update(
            '$route:${request.uri.path}',
            (n) => n + 1,
            ifAbsent: () => 1,
          );
          (ports[route] ??= {}).add(request.connectionInfo!.remotePort);
          expect(request.headers.value('authorization'), 'Token test-secret');
          await request.drain<void>();
          if (request.uri.path == '/submitted') {
            submitted.complete();
            await gate.future;
          }
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'route': route}));
          await request.response.close();
        });
      }
      final config = settings();
      await config.ready;
      final bridge = NetworkProxyBridge(
        settings: config,
        resolver: FakeProxyResolver([
          ProxyProfile(
            protocol: ProxyProtocol.http,
            host: '127.0.0.1',
            port: systemProxy.port,
          ),
        ]),
        socketConnector: (host, port, secure) => Socket.connect(
          '127.0.0.1',
          host == '127.0.0.1' ? port : origin.port,
        ),
      );
      final network = NetworkHttp(settings: config, bridge: bridge);
      final transport = CloudAsrTransport(
        cloudConnection(
          CloudAsrProvider.deepgram,
          endpoint: 'https://cloud.test',
        ),
        dio: network.createDio(scope: NetworkScope.cloudTranscription),
      );
      // HTTP origin routing is tested separately from verified TLS below.
      Future<String> request(String path) async {
        final host =
            config.configuration.modes[NetworkScope.cloudTranscription] ==
                NetworkMode.direct
            ? '127.0.0.1:${origin.port}'
            : 'cloud.test';
        return (await transport.dio.post<dynamic>(
              'http://$host$path',
              data: 'body',
              options: Options(
                headers: transport.connection.headers,
                extra: {'networkProtectSubmission': true},
              ),
            )).data['route']
            as String;
      }

      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
        transport.close();
        await network.dispose();
        config.dispose();
        await Future.wait([
          origin.close(force: true),
          systemProxy.close(force: true),
          customProxy.close(force: true),
        ]);
      });
      for (var i = 0; i < 3; i++) {
        expect(await request('/reuse'), 'system');
      }
      expect(ports['system']!.length, 1);
      final inFlight = request('/submitted');
      await submitted.future;
      await config.saveProxy(
        profile: ProxyProfile(
          protocol: ProxyProtocol.http,
          host: '127.0.0.1',
          port: customProxy.port,
        ),
        password: null,
      );
      await config.setMode(NetworkScope.cloudTranscription, NetworkMode.custom);
      expect(await request('/next'), 'custom');
      expect(await request('/again'), 'custom');
      expect(ports['custom']!.length, 1);
      gate.complete();
      expect(await inFlight, 'system');
      expect(calls['system:/submitted'], 1);
      expect(calls['custom:/submitted'], isNull);
      await config.setMode(NetworkScope.cloudTranscription, NetworkMode.direct);
      expect(await request('/direct'), 'direct');
      expect(await request('/again'), 'direct');
      expect(ports['direct']!.length, 1);
      await config.setUnifiedMode(NetworkMode.system);
      expect(await request('/global'), 'system');
    },
  );

  for (final secureProxy in [false, true]) {
    test(
      'TLS and ${secureProxy ? 'HTTPS' : 'HTTP'} proxy tunnel reuse retain certificate verification',
      () async {
        final origin = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          serverTls(),
        );
        final proxy = secureProxy
            ? await HttpServer.bindSecure(
                InternetAddress.loopbackIPv4,
                0,
                serverTls(),
              )
            : await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final ports = <int>{};
        var tunnels = 0, calls = 0;
        origin.listen((request) async {
          ports.add(request.connectionInfo!.remotePort);
          calls++;
          await request.drain<void>();
          request.response.headers.contentType = ContentType.json;
          request.response.write('{}');
          await request.response.close();
        }, onError: (_) {});
        proxy.listen((request) async {
          tunnels++;
          expect(request.method, 'CONNECT');
          expect(request.uri.toString(), 'origin.test:${origin.port}');
          final upstream = await Socket.connect('127.0.0.1', origin.port);
          final downstream = await request.response.detachSocket(
            writeHeaders: false,
          );
          downstream.add(
            ascii.encode('HTTP/1.1 200 Connection Established\r\n\r\n'),
          );
          await downstream.flush();
          unawaited(
            upstream
                .addStream(downstream)
                .catchError((_) {})
                .whenComplete(upstream.destroy),
          );
          unawaited(
            downstream
                .addStream(upstream)
                .catchError((_) {})
                .whenComplete(downstream.destroy),
          );
        }, onError: (_) {});
        final config = settings();
        await config.ready;
        await config.saveProxy(
          profile: ProxyProfile(
            protocol: secureProxy ? ProxyProtocol.https : ProxyProtocol.http,
            host: secureProxy ? 'proxy.test' : '127.0.0.1',
            port: proxy.port,
          ),
          password: null,
          applyTo: NetworkScope.cloudTranscription,
        );
        final bridge = NetworkProxyBridge(
          settings: config,
          socketConnector: (host, port, secure) async {
            final socket = await Socket.connect('127.0.0.1', port);
            return secure
                ? SecureSocket.secure(socket, host: host, context: trustedTls())
                : socket;
          },
        );
        final network = _TlsNetwork(settings: config, bridge: bridge);
        final untrusted = _TlsNetwork(
          settings: config,
          bridge: bridge,
          trust: false,
        );
        final connection = cloudConnection(
          CloudAsrProvider.soniox,
          endpoint: 'https://origin.test:${origin.port}',
        );
        final transport = CloudAsrTransport(
          connection,
          dio: network.createDio(scope: NetworkScope.cloudTranscription),
        );
        final invalid = CloudAsrTransport(
          connection,
          dio: untrusted.createDio(scope: NetworkScope.cloudTranscription),
        );
        addTearDown(() async {
          transport.close();
          invalid.close();
          await network.dispose();
          await untrusted.dispose();
          config.dispose();
          await origin.close(force: true);
          await proxy.close(force: true);
        });
        for (var i = 0; i < 3; i++) {
          await transport.request(
            'POST',
            '/transcribe',
            CancelToken(),
            data: {'test': true},
          );
        }
        expect(calls, 3);
        expect(ports.length, 1);
        expect(tunnels, 1);
        await expectLater(
          invalid.request('POST', '/transcribe', CancelToken(), data: {}),
          throwsA(isA<CloudAsrException>()),
        );
        expect(
          calls,
          3,
          reason:
              'Untrusted TLS must fail before an HTTP write reaches the origin',
        );
      },
    );
  }

  test(
    'cancelling one cloud request leaves pooled peers and later requests intact',
    () async {
      final server = await CloudWireServer.start();
      final ready = Completer<void>(), release = Completer<void>();
      server.handler = (request, response) async {
        if (request.uri.path != '/later') {
          if (server.requests.length == 2) ready.complete();
          await release.future;
        }
        response.write('{}');
      };
      final config = settings();
      final network = NetworkHttp(settings: config);
      final transport = CloudAsrTransport(
        cloudConnection(CloudAsrProvider.soniox, endpoint: server.endpoint),
        dio: network.createDio(scope: NetworkScope.cloudTranscription),
      );
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        transport.close();
        await network.dispose();
        config.dispose();
        await server.close();
      });
      final token = CancelToken();
      final cancelled = expectLater(
        transport.request('POST', '/cancel', token, data: {}),
        throwsA(isA<DioException>()),
      );
      final peer = transport.request('POST', '/peer', CancelToken(), data: {});
      await ready.future;
      token.cancel();
      await cancelled;
      release.complete();
      await peer;
      await transport.request('GET', '/later', CancelToken());
      expect(server.requests.length, 3);
    },
  );

  test('failed system proxy never quietly retries directly', () async {
    var directCalls = 0;
    final config = settings();
    await config.ready;
    final unused = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = unused.port;
    await unused.close();
    final bridge = NetworkProxyBridge(
      settings: config,
      resolver: FakeProxyResolver([
        ProxyProfile(
          protocol: ProxyProtocol.http,
          host: '127.0.0.1',
          port: port,
        ),
      ]),
      socketConnector: (host, port, secure) {
        if (host != '127.0.0.1') directCalls++;
        return Socket.connect(host, port);
      },
    );
    final network = NetworkHttp(settings: config, bridge: bridge);
    final transport = CloudAsrTransport(
      cloudConnection(CloudAsrProvider.soniox, endpoint: 'https://origin.test'),
      dio: network.createDio(scope: NetworkScope.cloudTranscription),
    );
    addTearDown(() async {
      transport.close();
      await network.dispose();
      config.dispose();
    });
    await expectLater(
      transport.request('POST', '/test', CancelToken(), data: {}),
      throwsA(isA<CloudAsrException>()),
    );
    expect(directCalls, 0);
  });

  test(
    'upload watchdog stops after sending; processing wait is independent',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'cloud-upload-watchdog-',
      );
      final audio = await File(
        '${root.path}/audio.mp3',
      ).writeAsBytes(List.filled(1024, 0));
      final server = await CloudWireServer.start();
      server.handler = (_, response) async {
        await Future<void>.delayed(const Duration(milliseconds: 180));
        response.write('{}');
      };
      final transport = CloudAsrTransport(
        cloudConnection(CloudAsrProvider.deepgram, endpoint: server.endpoint),
        dio: cloudTestDio(),
        uploadIdle: const Duration(milliseconds: 60),
      );
      addTearDown(() async {
        transport.close();
        await server.close();
        await root.delete(recursive: true);
      });
      expect(transport.dio.options.connectTimeout, const Duration(seconds: 20));
      expect(transport.dio.options.sendTimeout, isNull);
      await transport.upload(
        '/test',
        audio.path,
        CancelToken(),
        binary: true,
        slow: true,
        progress: (_, _, _) {},
      );
      transport.budget.limited(const Duration(milliseconds: 200));
      await transport.upload(
        '/after-cooldown',
        audio.path,
        CancelToken(),
        binary: true,
        slow: true,
        progress: (_, _, _) {},
      );
      expect(
        server.requests.length,
        2,
        reason: 'Retry-After waits must not consume the upload idle timeout',
      );
      final stalled = CloudAsrTransport(
        cloudConnection(CloudAsrProvider.deepgram),
        dio: Dio()..httpClientAdapter = _NeverSends(),
        uploadIdle: const Duration(milliseconds: 30),
      );
      addTearDown(stalled.close);
      await expectLater(
        stalled.upload(
          '/test',
          audio.path,
          CancelToken(),
          binary: true,
          progress: (_, _, _) {},
        ),
        throwsA(
          isA<CloudAsrException>().having(
            (e) => '$e',
            'message',
            contains('无进展'),
          ),
        ),
      );
    },
  );
}
