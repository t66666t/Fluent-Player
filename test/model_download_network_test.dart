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
  test(
    'model ranges reuse a system-route tunnel and route changes retire it',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final ports = <int>{};
      origin.listen((request) async {
        ports.add(request.connectionInfo!.remotePort);
        request.response.write('weights');
        await request.response.close();
      });
      final settings = NetworkSettingsService(
        store: MemoryNetworkStore(),
        credentials: MemoryCredentials(),
        migrateLegacy: false,
      );
      await settings.ready;
      await settings.setMode(NetworkScope.modelDownloads, NetworkMode.system);
      final resolver = FakeProxyResolver([null]);
      var connections = 0;
      final bridge = NetworkProxyBridge(
        settings: settings,
        resolver: resolver,
        socketConnector: (host, port, secure) {
          connections++;
          return Socket.connect('127.0.0.1', origin.port);
        },
      );
      final network = NetworkHttp(settings: settings, bridge: bridge);
      final dio = network.createDio(scope: NetworkScope.modelDownloads);
      addTearDown(() async {
        dio.close(force: true);
        await network.dispose();
        settings.dispose();
        await origin.close(force: true);
      });
      for (var i = 0; i < 5; i++) {
        expect(
          (await dio.get<String>('http://model.test/range$i')).data,
          'weights',
        );
      }
      expect(connections, 1);
      expect(ports.length, 1);
      expect(resolver.calls, 1);
      expect(
        (await dio.get<String>(
          'http://model.test/recover',
          options: Options(
            extra: {NetworkHttp.modelDownloadFreshConnectionKey: true},
          ),
        )).data,
        'weights',
      );
      expect(
        connections,
        2,
        reason: 'recovery creates a fresh socket on the same proxy route',
      );
      expect(ports.length, 2);
      expect(resolver.calls, 2);
      expect(
        (await dio.get<String>('http://model.test/healthy')).data,
        'weights',
      );
      expect(connections, 2, reason: 'healthy pooled connections are retained');
      settings.deviceNetworkChanged();
      expect((await dio.get<String>('http://model.test/next')).data, 'weights');
      expect(connections, 3);
      await settings.setUnifiedMode(NetworkMode.direct);
      final context = await settings.context(NetworkScope.modelDownloads);
      final direct = network.createClient(context: context);
      try {
        direct.connectionFactory = (uri, proxyHost, proxyPort) {
          expect(
            proxyHost,
            isNull,
            reason: 'direct model traffic must not open a loopback proxy',
          );
          return Socket.startConnect('127.0.0.1', origin.port);
        };
        final response = await (await direct.getUrl(
          Uri.parse('http://model.test/direct'),
        )).close();
        await response.drain<void>();
        expect(connections, 3);
      } finally {
        direct.close(force: true);
      }
    },
  );
}
