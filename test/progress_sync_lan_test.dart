import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/app_branding.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_lan.dart';

void main() {
  late _Fixture fixture;

  setUp(() async {
    fixture = _Fixture();
    await fixture.start();
  });

  tearDown(() async {
    await fixture.close();
  });

  test('manual discovery exposes identity but no library records', () async {
    final peer = await fixture.a.connectAddress('127.0.0.1:${fixture.b.port}');
    expect(peer.id, 'beta');
    expect(fixture.a.nearbyDevices.single.id, 'beta');
    expect(fixture.reads, 0);
    expect(fixture.receivedA, isEmpty);
    final hello = await _http(fixture.b.port!, '/v1/hello');
    expect(hello.status, 200);
    expect(hello.body, isNot(contains('private-video.mp4')));
    expect(hello.json.keys.toSet(), {
      'v',
      'edition',
      'id',
      'name',
      'port',
      'publicKey',
      'boot',
    });
  });

  test(
    'repeated discovery of a paired identity under stale IDs never adds device rows',
    () async {
      await fixture.pair();
      var id = 'stale-0';
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.write(
          jsonEncode({
            'v': 1,
            'edition': kApplicationId,
            'id': id,
            'name': '同一台手机',
            'port': server.port,
            'publicKey': fixture.b.publicKeyBase64,
            'boot': 'restarted',
          }),
        );
        await request.response.close();
      });
      var notifications = 0;
      void changed() {
        notifications++;
      }

      fixture.a.addListener(changed);
      try {
        for (var i = 0; i < 30; i++) {
          id = 'stale-$i';
          await fixture.a.connectAddress('127.0.0.1:${server.port}');
        }
        expect(fixture.a.nearbyDevices.map((device) => device.id), ['beta']);
        expect(fixture.a.connectedPeers, contains('beta'));
        // A final pairing acknowledgement may notify once concurrently; thirty
        // rediscoveries must not generate a notification for every announcement.
        expect(notifications, lessThan(5));
      } finally {
        fixture.a.removeListener(changed);
        await server.close(force: true);
      }
    },
  );

  test('different editions reject manual discovery and pairing', () async {
    final key = await X25519().newKeyPair();
    var applied = false;
    final foreign = ProgressSyncLan(
      deviceId: 'foreign',
      deviceName: '其他版本',
      editionForTesting: 'a.different.edition',
      privateKeyBytes: await key.extractPrivateKeyBytes(),
      trustedPeerPublicKeys: {},
      onTrustChanged: (_) {},
      onReadChanges: (_) async => [],
      onChanges: (_, _) async {
        applied = true;
      },
    );
    await foreign.start(
      bindAddress: InternetAddress.loopbackIPv4,
      enableDiscovery: false,
    );
    try {
      await expectLater(
        fixture.a.connectAddress('127.0.0.1:${foreign.port}'),
        throwsFormatException,
      );
      await expectLater(
        foreign.connectAddress('127.0.0.1:${fixture.a.port}'),
        throwsFormatException,
      );
      final hello = (await _http(fixture.a.port!, '/v1/hello')).json;
      final response = await _http(foreign.port!, '/v1/pair', hello);
      expect(response.status, isNot(200));
      expect(fixture.a.nearbyDevices, isEmpty);
      expect(foreign.nearbyDevices, isEmpty);
      expect(fixture.trustA, isEmpty);
      expect(applied, isFalse);
    } finally {
      await foreign.stop();
      foreign.dispose();
    }
  });

  test('both devices must explicitly approve the same code', () async {
    final peer = await fixture.a.connectAddress('127.0.0.1:${fixture.b.port}');
    final pair = await fixture.a.requestPair(peer);
    expect(pair.code, matches(RegExp(r'^\d{6}$')));
    expect(fixture.b.pairings.single.code, pair.code);
    await fixture.a.approvePair(pair.id, expectedCode: pair.code);
    expect(fixture.trustA, isEmpty);
    expect(fixture.trustB, isEmpty);
    await expectLater(fixture.a.syncPeer(peer), throwsStateError);
    await fixture.b.approvePair(pair.id, expectedCode: pair.code);
    await _eventually(() => fixture.trustA.containsKey('beta'));
    expect(fixture.trustB['alpha'], fixture.a.publicKeyBase64);
    expect(fixture.trustA['beta'], fixture.b.publicKeyBase64);
    expect(fixture.a.pairings, isEmpty);
    expect(fixture.b.pairings, isEmpty);
  });

  test(
    'repeated connection taps reuse one request and paired devices never reappear as requests',
    () async {
      final peer = await fixture.a.connectAddress(
        '127.0.0.1:${fixture.b.port}',
      );
      final first = await fixture.a.requestPair(peer);
      for (var i = 0; i < 20; i++) {
        expect((await fixture.a.requestPair(peer)).id, first.id);
      }
      expect(fixture.a.pairings, hasLength(1));
      expect(fixture.b.pairings, hasLength(1));
      await fixture.a.approvePair(first.id, expectedCode: first.code);
      await fixture.b.approvePair(first.id, expectedCode: first.code);
      for (var i = 0; i < 20; i++) {
        await fixture.a.requestPair(peer);
      }
      expect(fixture.a.pairings, isEmpty);
      expect(fixture.b.pairings, isEmpty);
      expect(fixture.a.nearbyDevices, hasLength(1));
    },
  );

  test('wrong code and rejected pair do not grant trust', () async {
    final peer = await fixture.a.connectAddress('127.0.0.1:${fixture.b.port}');
    final pair = await fixture.a.requestPair(peer);
    final wrong = pair.code == '000000' ? '111111' : '000000';
    await expectLater(
      fixture.a.approvePair(pair.id, expectedCode: wrong),
      throwsStateError,
    );
    expect(pair.localApproved, isFalse);
    await fixture.b.rejectPair(pair.id);
    expect(fixture.a.pairings, isEmpty);
    expect(fixture.b.pairings, isEmpty);
    expect(fixture.trustA, isEmpty);
    expect(fixture.trustB, isEmpty);
  });

  test('authenticated exchange applies records in both directions', () async {
    final peer = await fixture.pair();
    await fixture.a.syncPeer(peer);
    expect(fixture.receivedB.single['file'], 'private-video.mp4');
    expect(fixture.receivedB.single['position'], 750000);
    expect(fixture.receivedA.single['kind'], 'invite');
    expect(fixture.a.connectedPeers, contains('beta'));
    expect(fixture.b.connectedPeers, contains('alpha'));
    expect(fixture.a.errors['beta'], isNull);
  });

  test(
    'paired control RPC authenticates identity and returns encrypted results',
    () async {
      final peer = await fixture.pair();
      fixture.b.onControl = (peerId, method, payload) async {
        expect(peerId, 'alpha');
        expect(method, 'transfer.offer');
        expect(payload['secret'], 'never-discover');
        return {'accepted': true, 'key': 'encrypted-result'};
      };
      final result = await fixture.a.sendControl(peer, 'transfer.offer', {
        'secret': 'never-discover',
      });
      expect(result['accepted'], true);
      expect(result['key'], 'encrypted-result');
      expect(fixture.a.isTrustedPeer('beta'), true);
      await fixture.b.removePeer('alpha');
      await expectLater(
        fixture.a.sendControl(peer, 'transfer.offer', {}),
        throwsA(isA<HttpException>()),
      );
    },
  );

  test(
    'control RPC denies unpaired identities and oversized envelopes',
    () async {
      final peer = await fixture.a.connectAddress(
        '127.0.0.1:${fixture.b.port}',
      );
      await expectLater(
        fixture.a.sendControl(peer, 'transfer.offer', {}),
        throwsStateError,
      );
      final raw = await _http(fixture.b.port!, '/v1/control', {
        'from': 'unknown',
      });
      expect(raw.status, 403);
      final pair = await fixture.a.requestPair(peer);
      await fixture.a.approvePair(pair.id, expectedCode: pair.code);
      await fixture.b.approvePair(pair.id, expectedCode: pair.code);
      fixture.b.onControl = (id, method, payload) async => {};
      await expectLater(
        fixture.a.sendControl(peer, 'transfer.offer', {
          'tooLarge': List.filled(2 * 1024 * 1024, 'x').join(),
        }),
        throwsStateError,
      );
    },
  );

  test(
    'large libraries drain bounded encrypted pages in both directions',
    () async {
      final peer = await fixture.pair();
      final padding = List.filled(1000, '进度').join();
      fixture.sourceA = List.generate(
        3000,
        (i) => {'kind': 'event', 'id': 'a-$i', 'payload': padding},
      );
      fixture.sourceB = List.generate(
        3000,
        (i) => {'kind': 'event', 'id': 'b-$i', 'payload': padding},
      );
      expect(
        utf8.encode(jsonEncode(fixture.sourceA)).length,
        greaterThan(2 * 1024 * 1024),
      );
      await fixture.a.syncPeer(peer);
      expect(fixture.receivedA.length, 3000);
      expect(fixture.receivedB.length, 3000);
      expect(fixture.receivedA.map((r) => r['id']).toSet().length, 3000);
      expect(fixture.receivedB.map((r) => r['id']).toSet().length, 3000);
      expect(fixture.largestBatchA, lessThanOrEqualTo(250));
      expect(fixture.largestBatchB, lessThanOrEqualTo(250));
      expect(fixture.largestBytesA, lessThanOrEqualTo(384 * 1024));
      expect(fixture.largestBytesB, lessThanOrEqualTo(384 * 1024));
    },
  );

  test(
    'paging drains a larger inbound library after outbound is exhausted',
    () async {
      final peer = await fixture.pair();
      fixture.sourceA = const [];
      fixture.sourceB = List.generate(
        601,
        (i) => {'kind': 'event', 'id': 'b-$i'},
      );
      await fixture.a.syncPeer(peer);
      expect(fixture.receivedA.length, 601);
      expect(fixture.receivedB, isEmpty);
      expect(fixture.receivedA.map((r) => r['id']).toSet().length, 601);
      final readsBefore = fixture.readsB;
      fixture.receivedA.clear();
      fixture.receivedB.clear();
      fixture.sourceA = List.generate(601, (i) => {'id': 'a-$i'});
      fixture.sourceB = const [];
      await fixture.a.syncPeer(peer);
      expect(fixture.receivedB.length, 601);
      expect(fixture.receivedA, isEmpty);
      expect(fixture.readsB - readsBefore, 1);
    },
  );

  test(
    'server pages retain one deep snapshot while incoming merges reorder source',
    () async {
      final peer = await fixture.pair();
      fixture.sourceA = List.generate(601, (i) => {'id': 'a-$i'});
      fixture.sourceB = List.generate(
        601,
        (i) => {'id': 'b-$i', 'position': i},
      );
      var appliedBatches = 0;
      fixture.onAppliedB = () {
        if (++appliedBatches == 1) return;
        for (final record in fixture.sourceB!) {
          record['position'] = -1;
        }
        fixture.sourceB!
          ..removeAt(0)
          ..insert(0, {'id': 'inserted-$appliedBatches', 'position': -1});
        fixture.sourceB = fixture.sourceB!.reversed.toList();
      };
      await fixture.a.syncPeer(peer);
      expect(appliedBatches, 3);
      expect(fixture.readsA, 1);
      expect(fixture.readsB, 1);
      expect(fixture.receivedA.length, 601);
      expect(fixture.receivedA.map((r) => r['id']).toSet(), {
        for (var i = 0; i < 601; i++) 'b-$i',
      });
      for (final record in fixture.receivedA) {
        expect(
          record['position'],
          int.parse((record['id'] as String).substring(2)),
        );
      }
    },
  );

  test('unknown devices cannot read or write library records', () async {
    final response = await _http(fixture.b.port!, '/v1/sync', {
      'v': 1,
      'from': 'unpaired',
      'to': 'beta',
      'changes': [
        {'file': 'should-not-apply.mp4'},
      ],
    });
    expect(response.status, 403);
    expect(response.body, isEmpty);
    expect(fixture.reads, 0);
    expect(fixture.receivedB, isEmpty);
  });

  test(
    'wire records are encrypted, authenticated and replay protected',
    () async {
      final peer = await fixture.pair();
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      Map<String, dynamic>? captured;
      final subscription = proxy.listen((request) async {
        final bytes = await request.fold<List<int>>([], (a, b) => a..addAll(b));
        Map<String, dynamic>? body;
        if (bytes.isNotEmpty) {
          body = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        }
        if (request.uri.path == '/v1/sync') captured = body;
        final forwarded = await _http(fixture.b.port!, request.uri.path, body);
        request.response.statusCode = forwarded.status;
        request.response.write(forwarded.body);
        await request.response.close();
      });
      try {
        await fixture.a.syncPeer(
          LanSyncDevice(
            id: peer.id,
            name: peer.name,
            host: peer.host,
            port: proxy.port,
            lastSeen: peer.lastSeen,
            publicKeyBase64: peer.publicKeyBase64,
          ),
        );
        expect(captured, isNotNull);
        expect(jsonEncode(captured), isNot(contains('private-video.mp4')));
        expect(captured!['ciphertext'], isA<String>());
        final applied = fixture.receivedB.length;
        final replay = await _http(fixture.b.port!, '/v1/sync', captured);
        expect(replay.status, 409);
        final tampered = {...captured!};
        tampered['nonce'] = base64Encode(List<int>.filled(12, 123));
        final altered = await _http(fixture.b.port!, '/v1/sync', tampered);
        expect(altered.status, 400);
        final crossEdition = {...captured!, 'edition': 'another.edition'};
        final rejected = await _http(fixture.b.port!, '/v1/sync', crossEdition);
        expect(rejected.status, 403);
        expect(fixture.receivedB.length, applied);
        await fixture.b.stop();
        await fixture.b.start(
          bindAddress: InternetAddress.loopbackIPv4,
          enableDiscovery: false,
        );
        final oldSession = await _http(fixture.b.port!, '/v1/sync', captured);
        expect(oldSession.status, 403);
        expect(fixture.receivedB.length, applied);
      } finally {
        await subscription.cancel();
        await proxy.close(force: true);
      }
    },
  );

  test(
    'legacy trust cannot authenticate another edition with a relabelled envelope',
    () async {
      await fixture.pair();
      final helloA = (await _http(fixture.a.port!, '/v1/hello')).json;
      final helloB = (await _http(fixture.b.port!, '/v1/hello')).json;
      final keyPair = await X25519().newKeyPairFromSeed(fixture.privateA);
      final shared = await X25519().sharedSecretKey(
        keyPair: keyPair,
        remotePublicKey: SimplePublicKey(
          base64Decode(fixture.b.publicKeyBase64!),
          type: KeyPairType.x25519,
        ),
      );
      final identities = [
        'alpha:${fixture.a.publicKeyBase64}',
        'beta:${fixture.b.publicKeyBase64}',
      ]..sort();
      final foreignKey = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
          .deriveKey(
            secretKey: shared,
            nonce: utf8.encode(jsonEncode(identities)),
            info: utf8.encode(
              'video-player-progress/v2/another.edition/trusted',
            ),
          );
      final cipher = AesGcm.with256bits();
      final nonce = cipher.newNonce();
      final header = <String, dynamic>{
        'v': 1,
        'edition': kApplicationId,
        'from': 'alpha',
        'to': 'beta',
        'scope': 'sync',
        'senderBoot': helloA['boot'],
        'receiverBoot': helloB['boot'],
        'nonce': base64Encode(nonce),
        'sequence': 100,
      };
      final box = await cipher.encrypt(
        utf8.encode(
          jsonEncode({
            'changes': [
              {'file': 'foreign'},
            ],
          }),
        ),
        secretKey: foreignKey,
        nonce: nonce,
        aad: utf8.encode(jsonEncode(header)),
      );
      final before = fixture.receivedB.length;
      final response = await _http(fixture.b.port!, '/v1/sync', {
        ...header,
        'ciphertext': base64Encode(box.cipherText),
        'mac': base64Encode(box.mac.bytes),
      });
      expect(response.status, isNot(200));
      expect(fixture.receivedB.length, before);
    },
  );

  test(
    'authenticated sequence window rejects expired and duplicate messages',
    () async {
      await fixture.pair();
      final helloA = (await _http(fixture.a.port!, '/v1/hello')).json;
      final helloB = (await _http(fixture.b.port!, '/v1/hello')).json;
      final keyPair = await X25519().newKeyPairFromSeed(fixture.privateA);
      final shared = await X25519().sharedSecretKey(
        keyPair: keyPair,
        remotePublicKey: SimplePublicKey(
          base64Decode(fixture.b.publicKeyBase64!),
          type: KeyPairType.x25519,
        ),
      );
      final identities = [
        'alpha:${fixture.a.publicKeyBase64}',
        'beta:${fixture.b.publicKeyBase64}',
      ]..sort();
      final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
        secretKey: shared,
        nonce: utf8.encode(jsonEncode(identities)),
        info: utf8.encode('video-player-progress/v2/$kApplicationId/trusted'),
      );
      Future<int> send(int sequence) async {
        final cipher = AesGcm.with256bits();
        final nonce = cipher.newNonce();
        final header = {
          'v': 1,
          'edition': kApplicationId,
          'from': 'alpha',
          'to': 'beta',
          'scope': 'sync',
          'senderBoot': helloA['boot'],
          'receiverBoot': helloB['boot'],
          'nonce': base64Encode(nonce),
          'sequence': sequence,
        };
        final encrypted = await cipher.encrypt(
          utf8.encode(
            jsonEncode({
              'changes': [
                {'id': 'sequence-$sequence'},
              ],
              'readOffset': 0,
              'syncId': base64Encode(List<int>.filled(18, sequence % 256)),
              'hasMoreOutgoing': false,
            }),
          ),
          secretKey: key,
          nonce: nonce,
          aad: utf8.encode(jsonEncode(header)),
        );
        return (await _http(fixture.b.port!, '/v1/sync', {
          ...header,
          'ciphertext': base64Encode(encrypted.cipherText),
          'mac': base64Encode(encrypted.mac.bytes),
        })).status;
      }

      expect(await send(5000), 200);
      expect(await send(4999), 200); // A delayed response inside the window.
      expect(await send(5000), 409); // Different nonce, same sequence.
      expect(await send(100), 409); // Unseen sequence outside the window.
      expect(fixture.receivedB.length, 2);
    },
  );

  test('removed trust rejects previously authenticated peer', () async {
    final peer = await fixture.pair();
    await fixture.b.removePeer('alpha');
    expect(fixture.trustB, isEmpty);
    await expectLater(fixture.a.syncPeer(peer), throwsA(isA<HttpException>()));
    expect(fixture.receivedB, isEmpty);
    expect(fixture.a.errors['beta'], 'syncUnavailable');
  });

  test(
    'saved identities reconnect after restart without pairing again',
    () async {
      await fixture.pair();
      await fixture.a.stop();
      await fixture.b.stop();
      await fixture.a.start(
        bindAddress: InternetAddress.loopbackIPv4,
        enableDiscovery: false,
      );
      await fixture.b.start(
        bindAddress: InternetAddress.loopbackIPv4,
        enableDiscovery: false,
      );
      final peer = await fixture.a.connectAddress(
        '127.0.0.1:${fixture.b.port}',
      );
      await fixture.a.syncPeer(peer);
      expect(fixture.receivedA, isNotEmpty);
      expect(fixture.receivedB, isNotEmpty);
      expect(fixture.a.pairings, isEmpty);
    },
  );

  test('trusted identity cannot silently change its public key', () async {
    final peer = await fixture.pair();
    final other = await X25519().newKeyPair();
    final spoof = LanSyncDevice(
      id: peer.id,
      name: peer.name,
      host: peer.host,
      port: peer.port,
      lastSeen: peer.lastSeen,
      publicKeyBase64: base64Encode((await other.extractPublicKey()).bytes),
    );
    await expectLater(fixture.a.requestPair(spoof), throwsStateError);
    expect(fixture.a.errors['beta'], 'identityChanged');
    expect(fixture.trustA['beta'], peer.publicKeyBase64);
  });

  test(
    'public addresses are refused before attempting network access',
    () async {
      await expectLater(
        fixture.a.connectAddress('https://127.0.0.1'),
        throwsFormatException,
      );
      await expectLater(
        fixture.a.connectAddress('8.8.8.8:47791'),
        throwsFormatException,
      );
      expect(fixture.a.nearbyDevices, isEmpty);
    },
  );

  test('concurrent start calls share one listener', () async {
    await fixture.a.stop();
    await Future.wait([
      fixture.a.start(
        bindAddress: InternetAddress.loopbackIPv4,
        enableDiscovery: false,
      ),
      fixture.a.start(
        bindAddress: InternetAddress.loopbackIPv4,
        enableDiscovery: false,
      ),
    ]);
    expect(fixture.a.isRunning, isTrue);
    final response = await _http(fixture.a.port!, '/v1/hello');
    expect(response.status, 200);
  });

  test(
    'multicast discovers both listeners across local interfaces',
    () async {
      await fixture.a.stop();
      await fixture.b.stop();
      await fixture.a.start();
      await fixture.b.start();
      await fixture.a.discover();
      await fixture.b.discover();
      await _eventually(
        () =>
            fixture.a.nearbyDevices.any((peer) => peer.id == 'beta') &&
            fixture.b.nearbyDevices.any((peer) => peer.id == 'alpha'),
      );
      expect(fixture.a.errors['discovery'], isNull);
      expect(fixture.b.errors['discovery'], isNull);
      final pair = await fixture.a.requestPair(fixture.a.nearbyDevices.single);
      await fixture.a.approvePair(pair.id, expectedCode: pair.code);
      await fixture.b.approvePair(pair.id, expectedCode: pair.code);
      await _eventually(() => fixture.trustA.isNotEmpty);
      await fixture.a.syncPeer(fixture.a.nearbyDevices.single);
      expect(fixture.receivedB, isNotEmpty);
    },
    skip: !const bool.fromEnvironment('RUN_LAN_DISCOVERY_TEST'),
  );
}

class _Fixture {
  late ProgressSyncLan a;
  late ProgressSyncLan b;
  Map<String, String> trustA = {};
  Map<String, String> trustB = {};
  final receivedA = <Map<String, dynamic>>[];
  final receivedB = <Map<String, dynamic>>[];
  List<Map<String, dynamic>>? sourceA;
  List<Map<String, dynamic>>? sourceB;
  late List<int> privateA;
  int largestBatchA = 0, largestBatchB = 0;
  int largestBytesA = 0, largestBytesB = 0;
  int reads = 0;
  int readsA = 0, readsB = 0;
  void Function()? onAppliedB;

  Future<void> start() async {
    final keyA = await X25519().newKeyPair();
    final keyB = await X25519().newKeyPair();
    privateA = await keyA.extractPrivateKeyBytes();
    a = ProgressSyncLan(
      deviceId: 'alpha',
      deviceName: '电脑',
      privateKeyBytes: privateA,
      trustedPeerPublicKeys: {},
      onTrustChanged: (map) {
        trustA = Map.of(map);
      },
      onReadChanges: (peer) async {
        expect(peer, 'beta');
        reads++;
        readsA++;
        return sourceA ??
            [
              {
                'kind': 'event',
                'file': 'private-video.mp4',
                'position': 750000,
              },
            ];
      },
      onChanges: (peer, changes) async {
        expect(peer, 'beta');
        if (changes.length > largestBatchA) largestBatchA = changes.length;
        final size = utf8.encode(jsonEncode(changes)).length;
        if (size > largestBytesA) largestBytesA = size;
        receivedA.addAll(changes);
      },
    );
    b = ProgressSyncLan(
      deviceId: 'beta',
      deviceName: '手机',
      privateKeyBytes: await keyB.extractPrivateKeyBytes(),
      trustedPeerPublicKeys: {},
      onTrustChanged: (map) {
        trustB = Map.of(map);
      },
      onReadChanges: (peer) async {
        expect(peer, 'alpha');
        reads++;
        readsB++;
        return sourceB ??
            [
              {'kind': 'invite', 'folderId': 'shared-1'},
            ];
      },
      onChanges: (peer, changes) async {
        expect(peer, 'alpha');
        if (changes.length > largestBatchB) largestBatchB = changes.length;
        final size = utf8.encode(jsonEncode(changes)).length;
        if (size > largestBytesB) largestBytesB = size;
        receivedB.addAll(changes);
        onAppliedB?.call();
      },
    );
    await a.start(
      bindAddress: InternetAddress.loopbackIPv4,
      enableDiscovery: false,
    );
    await b.start(
      bindAddress: InternetAddress.loopbackIPv4,
      enableDiscovery: false,
    );
  }

  Future<LanSyncDevice> pair() async {
    final peer = await a.connectAddress('127.0.0.1:${b.port}');
    final pair = await a.requestPair(peer);
    await a.approvePair(pair.id, expectedCode: pair.code);
    await b.approvePair(pair.id, expectedCode: pair.code);
    await _eventually(() => trustA.containsKey('beta'));
    return peer;
  }

  Future<void> close() async {
    await a.stop();
    await b.stop();
    a.dispose();
    b.dispose();
  }
}

class _Response {
  _Response(this.status, this.body);
  final int status;
  final String body;
  Map<String, dynamic> get json => jsonDecode(body) as Map<String, dynamic>;
}

Future<_Response> _http(
  int port,
  String path, [
  Map<String, dynamic>? body,
]) async {
  final client = HttpClient()..findProxy = (_) => 'DIRECT';
  try {
    final request = await client.openUrl(
      body == null ? 'GET' : 'POST',
      Uri(scheme: 'http', host: '127.0.0.1', port: port, path: path),
    );
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    return _Response(
      response.statusCode,
      await utf8.decoder.bind(response).join(),
    );
  } finally {
    client.close(force: true);
  }
}

Future<void> _eventually(bool Function() condition) async {
  final until = DateTime.now().add(const Duration(seconds: 6));
  while (!condition()) {
    if (DateTime.now().isAfter(until)) fail('Pairing did not converge');
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
}
