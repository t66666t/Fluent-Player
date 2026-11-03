import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/network/network_http.dart';
import 'package:video_player_app/services/network/network_proxy_bridge.dart';
import 'network_proxy_bridge_test.dart' show FakeProxyResolver;
import 'network_settings_service_test.dart'
    show MemoryNetworkStore, MemoryCredentials;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final behavior in ['bridge', 'client', 'deadline']) {
    test('$behavior releases a proxy still negotiating CONNECT', () async {
      HttpOverrides.global = null;
      final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final seen = Completer<void>(), gone = Completer<void>();
      final sockets = <Socket>[];
      Timer? trickle;
      proxy.listen((socket) {
        sockets.add(socket);
        socket.listen(
          (_) {
            if (!seen.isCompleted) {
              socket.write('HTTP/1.1 200 ');
              if (behavior == 'deadline') {
                trickle = Timer.periodic(const Duration(milliseconds: 20), (_) {
                  socket.write(' ');
                });
              }
              seen.complete();
            }
          },
          onDone: () {
            if (!gone.isCompleted) gone.complete();
          },
          onError: (Object _) {
            if (!gone.isCompleted) gone.complete();
          },
        );
      });
      final settings = NetworkSettingsService(
        store: MemoryNetworkStore(),
        credentials: MemoryCredentials(),
        migrateLegacy: false,
      );
      await settings.ready;
      final bridge = NetworkProxyBridge(
        settings: settings,
        handshakeTimeout: behavior != 'bridge'
            ? const Duration(milliseconds: 100)
            : const Duration(seconds: 20),
        resolver: FakeProxyResolver([
          ProxyProfile(
            protocol: ProxyProtocol.http,
            host: '127.0.0.1',
            port: proxy.port,
          ),
        ]),
      );
      final network = NetworkHttp(settings: settings, bridge: bridge);
      final client = network.createClient();
      addTearDown(() async {
        trickle?.cancel();
        client.close(force: true);
        await network.dispose();
        settings.dispose();
        for (final socket in sockets) {
          socket.destroy();
        }
        await proxy.close();
      });
      final opening = client.getUrl(Uri.parse('https://origin.test/media'));
      final failed = expectLater(opening, throwsA(anything));
      await seen.future;
      if (behavior == 'bridge') {
        await network.dispose();
      } else if (behavior == 'client') {
        client.close(force: true);
      }
      await gone.future.timeout(const Duration(milliseconds: 700));
      await failed;
    });
  }
}
