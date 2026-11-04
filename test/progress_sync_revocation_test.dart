import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_lan.dart';

void main() {
  for (final stop in [false, true]) {
    test(
      'in-flight authenticated reply cannot apply or reconnect after ${stop ? 'stop' : 'unpair'}',
      () async {
        final ka = await X25519().newKeyPair();
        final kb = await X25519().newKeyPair();
        final pa = base64Encode((await ka.extractPublicKey()).bytes);
        final pb = base64Encode((await kb.extractPublicKey()).bytes);
        final responseStarted = Completer<void>();
        final releaseResponse = Completer<void>();
        final received = <Map<String, dynamic>>[];
        final a = ProgressSyncLan(
          deviceId: 'a',
          deviceName: 'A',
          privateKeyBytes: await ka.extractPrivateKeyBytes(),
          trustedPeerPublicKeys: {'b': pb},
          onTrustChanged: (_) {},
          onReadChanges: (_) async => [],
          onChanges: (_, changes) async => received.addAll(changes),
        );
        final b = ProgressSyncLan(
          deviceId: 'b',
          deviceName: 'B',
          privateKeyBytes: await kb.extractPrivateKeyBytes(),
          trustedPeerPublicKeys: {'a': pa},
          onTrustChanged: (_) {},
          onReadChanges: (_) async {
            responseStarted.complete();
            await releaseResponse.future;
            return [
              {'kind': 'invite', 'groupId': 'after-unpair'},
            ];
          },
          onChanges: (_, changes) async {},
        );
        addTearDown(() async {
          if (!releaseResponse.isCompleted) releaseResponse.complete();
          await a.stop();
          await b.stop();
          a.dispose();
          b.dispose();
        });
        await a.start(
          bindAddress: InternetAddress.loopbackIPv4,
          enableDiscovery: false,
        );
        await b.start(
          bindAddress: InternetAddress.loopbackIPv4,
          enableDiscovery: false,
        );
        final peer = await a.connectAddress('127.0.0.1:${b.port}');
        final sync = a.syncPeer(peer);
        await responseStarted.future.timeout(const Duration(seconds: 5));
        if (stop) {
          await a.stop();
        } else {
          await a.removePeer('b');
        }
        expect(a.isTrustedPeer('b'), stop);
        releaseResponse.complete();
        await expectLater(sync, throwsA(isA<StateError>()));
        expect(a.isTrustedPeer('b'), stop);
        expect(received, isEmpty);
        expect(a.connectedPeers, isNot(contains('b')));
      },
    );
  }
}
