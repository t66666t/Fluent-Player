import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/network/network_http.dart';
import 'package:video_player_app/services/network/network_proxy_bridge.dart';

import 'network_proxy_bridge_test.dart' show FakeProxyResolver;
import 'network_settings_service_test.dart'
    show MemoryNetworkStore, MemoryCredentials;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = null);
  final reuse = Options(
    extra: {NetworkHttp.translationConnectionReuseKey: true},
  );

  test(
    'Bing opt-in reuses sockets; other translation clients retain their lifecycle',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final ports = <int>{};
      origin.listen((request) async {
        ports.add(request.connectionInfo!.remotePort);
        request.response.write('translated');
        await request.response.close();
      });
      final network = NetworkHttp(
        settings: NetworkSettingsService(
          store: MemoryNetworkStore(),
          credentials: MemoryCredentials(),
          migrateLegacy: false,
        ),
      );
      final dio = network.createDio(scope: NetworkScope.translation);
      addTearDown(() async {
        dio.close(force: true);
        await network.dispose();
        await origin.close(force: true);
      });
      final url = 'http://127.0.0.1:${origin.port}/translate';
      for (var i = 0; i < 3; i++) {
        expect(
          (await dio.post<String>(url, data: 'text', options: reuse)).data,
          'translated',
        );
      }
      expect(ports.length, 1);
      ports.clear();
      for (var i = 0; i < 3; i++) {
        await dio.post<String>(url, data: 'text');
      }
      expect(ports.length, 3);
    },
  );

  test(
    'cancelling one pooled translation leaves other requests and future use intact',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final bothStarted = Completer<void>(), release = Completer<void>();
      var calls = 0;
      origin.listen((request) async {
        if (++calls == 2) bothStarted.complete();
        await release.future;
        try {
          request.response.write(request.uri.path);
          await request.response.close();
        } catch (_) {}
      });
      final network = NetworkHttp(
        settings: NetworkSettingsService(
          store: MemoryNetworkStore(),
          credentials: MemoryCredentials(),
          migrateLegacy: false,
        ),
      );
      final dio = network.createDio(scope: NetworkScope.translation);
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        dio.close(force: true);
        await network.dispose();
        await origin.close(force: true);
      });
      final url = 'http://127.0.0.1:${origin.port}';
      final token = CancelToken();
      final first = dio.post<String>(
        '$url/cancel',
        options: reuse,
        cancelToken: token,
      );
      final rejected = expectLater(
        first,
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      final second = dio.post<String>('$url/keep', options: reuse);
      await bothStarted.future;
      token.cancel();
      await rejected;
      release.complete();
      expect((await second).data, '/keep');
      expect(
        (await dio.post<String>('$url/next', options: reuse)).data,
        '/next',
      );
    },
  );

  test(
    'translation reuse follows system/custom/direct settings and retires old routes',
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
      for (final entry in {
        'direct': origin,
        'system': systemProxy,
        'custom': customProxy,
      }.entries) {
        entry.value.listen((request) async {
          if (request.uri.path == '/submitted') {
            submitted.complete();
            await gate.future;
          }
          request.response.write(entry.key);
          await request.response.close();
        });
      }
      final settings = NetworkSettingsService(
        store: MemoryNetworkStore()
          ..saved = NetworkConfiguration(
            modes: {NetworkScope.translation: NetworkMode.system},
          ),
        credentials: MemoryCredentials(),
        migrateLegacy: false,
      );
      await settings.ready;
      final bridge = NetworkProxyBridge(
        settings: settings,
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
      final network = NetworkHttp(settings: settings, bridge: bridge);
      final dio = network.createDio(scope: NetworkScope.translation);
      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
        dio.close(force: true);
        await network.dispose();
        await origin.close(force: true);
        await systemProxy.close(force: true);
        await customProxy.close(force: true);
      });
      const url = 'http://translator.test';
      expect(
        (await dio.post<String>('$url/first', options: reuse)).data,
        'system',
      );
      final inFlight = dio.post<String>('$url/submitted', options: reuse);
      await submitted.future;
      await settings.saveProxy(
        password: null,
        profile: ProxyProfile(
          protocol: ProxyProtocol.http,
          host: '127.0.0.1',
          port: customProxy.port,
        ),
      );
      await settings.setMode(NetworkScope.translation, NetworkMode.custom);
      expect(
        (await dio.post<String>('$url/next', options: reuse)).data,
        'custom',
      );
      gate.complete();
      expect((await inFlight).data, 'system');
      await settings.setMode(NetworkScope.translation, NetworkMode.direct);
      expect(
        (await dio.post<String>('$url/direct', options: reuse)).data,
        'direct',
      );
      await settings.setUnifiedMode(NetworkMode.system);
      expect(
        (await dio.post<String>('$url/unified', options: reuse)).data,
        'system',
      );
    },
  );
}
