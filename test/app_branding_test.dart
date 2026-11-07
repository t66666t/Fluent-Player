import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_lan.dart';
import 'package:video_player_app/utils/app_branding.dart';
import 'package:video_player_app/utils/app_data_paths.dart';

void main() {
  test('product, data and external-client identity stay edition-specific', () {
    expect(kAppDisplayName, 'Fluent Player');
    expect(kApplicationId, 'cn.teezy.fluentplayer.standard');
    expect(kAppDataFolderName, kApplicationId);
    expect(kIsCommunityEdition, true);
    expect(kMcpServerName, 'fluent_player');
    expect(kExternalAiDefaultPort, 38462);
    expect(kProgressSyncDefaultPort, 47793);
    expect(kProgressSyncDiscoveryPort, 47794);
    expect(ProgressSyncLan.defaultPort, kProgressSyncDefaultPort);
    expect(ProgressSyncLan.discoveryPort, kProgressSyncDiscoveryPort);
    expect(ProgressSyncLan.discoveryTargetPorts, [47794]);
  });

  test(
    'both editions can bind independent TCP and UDP listener ports',
    () async {
      final http = <HttpServer>[];
      final udp = <RawDatagramSocket>[];
      RawDatagramSocket? sender;
      final subscriptions = <StreamSubscription<RawSocketEvent>>[];
      try {
        for (final port in [47791, 47793]) {
          http.add(
            await HttpServer.bind(
              InternetAddress.loopbackIPv4,
              port,
              shared: false,
            ),
          );
        }
        final received = <Future<void>>[];
        final receivedPorts = <int>{};
        for (final port in [47792, 47794]) {
          final socket = await RawDatagramSocket.bind(
            InternetAddress.loopbackIPv4,
            port,
            reuseAddress: false,
          );
          udp.add(socket);
          final done = Completer<void>();
          received.add(done.future);
          subscriptions.add(
            socket.listen((event) {
              if (event == RawSocketEvent.read) {
                final packet = socket.receive();
                if (packet != null &&
                    packet.data.length == 1 &&
                    !done.isCompleted) {
                  receivedPorts.add(port);
                  done.complete();
                }
              }
            }),
          );
        }
        sender = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
        for (final port in ProgressSyncLan.discoveryTargetPorts) {
          // UDP send is non-blocking; Windows may report a not-yet-writable
          // socket immediately after bind. Yield to IO for a bounded interval.
          final deadline = DateTime.now().add(const Duration(seconds: 2));
          while (true) {
            final sent = sender.send([1], InternetAddress.loopbackIPv4, port);
            if (sent == 1) break;
            expect(sent, 0);
            if (!DateTime.now().isBefore(deadline)) {
              fail('UDP sender did not become writable for port $port');
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        }
        await received[1].timeout(const Duration(seconds: 3));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(receivedPorts, {47794});
        expect(http.map((server) => server.port).toSet(), {47791, 47793});
      } finally {
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
        sender?.close();
        for (final socket in udp) {
          socket.close();
        }
        for (final server in http) {
          await server.close(force: true);
        }
      }
    },
    skip: !const bool.fromEnvironment('RUN_EDITION_NETWORK_BIND_TEST'),
    timeout: const Timeout(Duration(seconds: 10)),
  );
}
