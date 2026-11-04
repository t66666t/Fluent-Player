import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/progress_sync/folder_direct_transport.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_lan.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_models.dart';

class _DirectHttp extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..findProxy = (_) => 'DIRECT';
}

void main() {
  late Directory root;
  late ProgressSyncLan a, b;
  late FolderDirectTransport sender, receiver;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('direct_media_test_');
    Future<ProgressSyncLan> device(String id) async {
      final key = await X25519().newKeyPair();
      return ProgressSyncLan(
        deviceId: id,
        deviceName: id,
        privateKeyBytes: await key.extractPrivateKeyBytes(),
        trustedPeerPublicKeys: {},
        onTrustChanged: (_) {},
        onReadChanges: (_) async => [],
        onChanges: (_, _) async {},
      );
    }

    a = await device('sender');
    b = await device('receiver');
    await a.start(
      bindAddress: InternetAddress.loopbackIPv4,
      enableDiscovery: false,
    );
    await b.start(
      bindAddress: InternetAddress.loopbackIPv4,
      enableDiscovery: false,
    );
    final peer = await a.connectAddress('127.0.0.1:${b.port}');
    final pairing = await a.requestPair(peer);
    await a.approvePair(pairing.id, expectedCode: pairing.code);
    await b.approvePair(pairing.id, expectedCode: pairing.code);
    sender = FolderDirectTransport(a);
    receiver = FolderDirectTransport(b);
  });
  tearDown(() async {
    await sender.close();
    await receiver.close();
    await a.stop();
    await b.stop();
    a.dispose();
    b.dispose();
    await root.delete(recursive: true);
  });
  Future<PortableFolderFiles> plan(
    int size, {
    String path = '课程/video.mp4',
  }) async {
    final file = File(p.join(root.path, 'source.mp4'));
    final output = await file.open(mode: FileMode.write);
    final chunk = Uint8List.fromList(List.generate(64 * 1024, (i) => i % 251));
    for (var written = 0; written < size; written += chunk.length) {
      await output.writeFrom(
        chunk,
        0,
        size - written < chunk.length ? size - written : chunk.length,
      );
    }
    await output.close();
    final stat = await file.stat();
    return PortableFolderFiles(
      manifest: const {'packageName': '课程'},
      files: [
        PortableFolderFile(
          path: file.path,
          relativePath: path,
          size: size,
          modifiedMs: stat.modified.millisecondsSinceEpoch,
        ),
      ],
    );
  }

  test(
    'original media streams without packing and progress counts written bytes',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        const benchmark = bool.fromEnvironment('RUN_DIRECT_BENCHMARK');
        final source = await plan(
          benchmark ? 64 * 1024 * 1024 : 2 * 1024 * 1024 + 11,
        );
        var finalizations = 0;
        final offer = await sender.prepare(
          id: 'direct-media-test',
          peerId: 'receiver',
          plan: source,
          complete: (hashes) async {
            finalizations++;
            return {'hashes': hashes};
          },
        );
        expect(await root.list().length, 1);
        final states = <int>[];
        final watch = Stopwatch()..start();
        final directory = Directory(p.join(root.path, 'received'));
        final result = await receiver.receive(
          id: 'direct-media-test',
          peerId: 'sender',
          host: '127.0.0.1',
          offer: offer,
          directory: directory,
          isCancelled: () => false,
          onProgress: (done, total, _) {
            expect(done, inInclusiveRange(0, total));
            states.add(done);
          },
        );
        watch.stop();
        expect(states.last, source.totalBytes);
        expect(states, orderedEquals([...states]..sort()));
        expect(finalizations, 1);
        expect(
          (result['hashes'] as Map).values.single,
          matches(RegExp(r'^[a-f0-9]{64}$')),
        );
        final target = File(p.join(directory.path, '课程', 'video.mp4'));
        expect(await target.length(), source.totalBytes);
        if (!benchmark) {
          expect(
            await target.readAsBytes(),
            await File(source.files.single.path).readAsBytes(),
          );
        }
        if (benchmark) {
          stdout.writeln(
            'Direct original-file loopback: 64 MiB in ${watch.elapsedMilliseconds} ms, '
            '${(64 * 1000 / watch.elapsedMilliseconds).toStringAsFixed(1)} MiB/s (Flutter test VM, not physical Wi-Fi)',
          );
        }
      }, _DirectHttp());
    },
  );
  test(
    'interrupted direct file resumes without a completed-file verification pass',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final source = await plan(512 * 1024);
        final offer = await sender.prepare(
          id: 'direct-resume-test',
          peerId: 'receiver',
          plan: source,
          complete: (hashes) async => {'hashes': hashes},
        );
        final directory = Directory(p.join(root.path, 'received'));
        var cancel = false;
        await expectLater(
          receiver.receive(
            id: 'direct-resume-test',
            peerId: 'sender',
            host: '127.0.0.1',
            offer: offer,
            directory: directory,
            bytesPerSecondLimit: 256 * 1024,
            isCancelled: () => cancel,
            onProgress: (done, _, _) {
              if (done > 0) cancel = true;
            },
          ),
          throwsA(isA<FormatException>()),
        );
        final partial = File(p.join(root.path, 'direct-parts', '0.part'));
        expect(await partial.length(), greaterThan(0));
        await receiver.close();
        receiver = FolderDirectTransport(b);
        var done = 0;
        await receiver.receive(
          id: 'direct-resume-test',
          peerId: 'sender',
          host: '127.0.0.1',
          offer: offer,
          directory: directory,
          isCancelled: () => false,
          onProgress: (completed, _, _) => done = completed,
        );
        expect(done, source.totalBytes);
        expect(
          await File(p.join(directory.path, '课程', 'video.mp4')).readAsBytes(),
          await File(source.files.single.path).readAsBytes(),
        );
      }, _DirectHttp());
    },
  );
  test(
    'unsafe remote filenames are rejected before creating destination files',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final source = await plan(32, path: '../escaped.mp4');
        final offer = await sender.prepare(
          id: 'direct-path-test',
          peerId: 'receiver',
          plan: source,
          complete: (_) async => {},
        );
        final destination = Directory(p.join(root.path, 'received'));
        await expectLater(
          receiver.receive(
            id: 'direct-path-test',
            peerId: 'sender',
            host: '127.0.0.1',
            offer: offer,
            directory: destination,
            isCancelled: () => false,
            onProgress: (_, _, _) {},
          ),
          throwsA(isA<FormatException>()),
        );
        expect(await destination.exists(), isFalse);
      }, _DirectHttp());
    },
  );

  test('a corrupt receipt does not resume an unknown partial', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final source = await plan(64 * 1024);
      final offer = await sender.prepare(
        id: 'direct-corrupt-journal',
        peerId: 'receiver',
        plan: source,
        complete: (hashes) async => {'hashes': hashes},
      );
      final directory = Directory(p.join(root.path, 'received'));
      final partials = Directory(p.join(root.path, 'direct-parts'));
      await partials.create(recursive: true);
      await File(
        p.join(partials.path, '0.part'),
      ).writeAsBytes(List<int>.filled(1000, 9));
      await File(p.join(root.path, 'direct-receipt.json')).writeAsString('{');
      await receiver.receive(
        id: 'direct-corrupt-journal',
        peerId: 'sender',
        host: '127.0.0.1',
        offer: offer,
        directory: directory,
        isCancelled: () => false,
        onProgress: (_, _, speed) {
          expect(speed.isFinite, isTrue);
          expect(speed, greaterThanOrEqualTo(0));
        },
      );
      expect(
        await File(p.join(directory.path, '课程', 'video.mp4')).readAsBytes(),
        await File(source.files.single.path).readAsBytes(),
      );
    }, _DirectHttp());
  });

  for (final corruptCompleted in [false, true]) {
    test(
      'a corrupt ${corruptCompleted ? 'completed file' : 'partial prefix'} is repaired against sender bytes',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          final source = await plan(512 * 1024);
          final offer = await sender.prepare(
            id: 'corruption-repair',
            peerId: 'receiver',
            plan: source,
            complete: (hashes) async => {'hashes': hashes},
          );
          final directory = Directory(p.join(root.path, 'received'));
          var cancel = false;
          Future<Map<String, dynamic>> receive({bool interrupt = false}) =>
              receiver.receive(
                id: 'corruption-repair',
                peerId: 'sender',
                host: '127.0.0.1',
                offer: offer,
                directory: directory,
                bytesPerSecondLimit: interrupt ? 256 * 1024 : 0,
                isCancelled: () => cancel,
                onProgress: (done, _, _) {
                  if (interrupt && done > 0) cancel = true;
                },
              );
          if (corruptCompleted) {
            await receive();
          } else {
            await expectLater(
              receive(interrupt: true),
              throwsA(isA<FormatException>()),
            );
          }
          final damaged = File(
            corruptCompleted
                ? p.join(directory.path, '课程', 'video.mp4')
                : p.join(root.path, 'direct-parts', '0.part'),
          );
          final bytes = await damaged.readAsBytes();
          expect(bytes, isNotEmpty);
          bytes[0] ^= 127;
          await damaged.writeAsBytes(bytes, flush: true);
          await receiver.close();
          receiver = FolderDirectTransport(b);
          cancel = false;
          await receive();
          expect(
            await File(p.join(directory.path, '课程', 'video.mp4')).readAsBytes(),
            await File(source.files.single.path).readAsBytes(),
          );
        }, _DirectHttp());
      },
    );
  }

  test('wire hides media and metadata; replayed request is rejected', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final source = await plan(128 * 1024);
      final secret = utf8.encode('PRIVATE-MEDIA-NOT-FOR-THE-NETWORK');
      final handle = await File(
        source.files.single.path,
      ).open(mode: FileMode.append);
      await handle.setPosition(0);
      await handle.writeFrom(secret);
      await handle.close();
      final file = File(source.files.single.path), stat = await file.stat();
      final amended = PortableFolderFiles(
        manifest: {'private-title': 'private-card-metadata'},
        files: [
          PortableFolderFile(
            path: file.path,
            relativePath: 'private-card/video.mp4',
            size: stat.size,
            modifiedMs: stat.modified.millisecondsSinceEpoch,
          ),
        ],
      );
      final offer = await sender.prepare(
        id: 'wire-private',
        peerId: 'receiver',
        plan: amended,
        complete: (hashes) async => {'hashes': hashes},
      );
      expect(offer['protocol'], 3);
      final proxy = await _RecordingProxy.start(offer['port'] as int);
      addTearDown(proxy.close);
      await receiver.receive(
        id: 'wire-private',
        peerId: 'sender',
        host: '127.0.0.1',
        offer: {...offer, 'port': proxy.port},
        directory: Directory(p.join(root.path, 'received')),
        isCancelled: () => false,
        onProgress: (_, _, _) {},
      );
      final wire = latin1.decode(proxy.bytes);
      expect(wire, isNot(contains(utf8.decode(secret))));
      expect(wire, isNot(contains('private-card-metadata')));
      expect(wire, isNot(contains('private-card/video.mp4')));
      expect(wire, isNot(contains(offer['key'])));
      final original = proxy.requests.first;
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      try {
        final request = await client.postUrl(
          Uri.parse('http://127.0.0.1:${offer['port']}${original.$1}'),
        );
        request.headers.set('X-Fluent-Transfer', offer['token']!);
        request.add(original.$2);
        final response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, 409);
      } finally {
        client.close(force: true);
      }
    }, _DirectHttp());
  });

  test('tampered encrypted media cannot publish a completed file', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final source = await plan(128 * 1024);
      final offer = await sender.prepare(
        id: 'wire-tampered',
        peerId: 'receiver',
        plan: source,
        complete: (_) async {
          fail('Tampered transfer must not complete');
        },
      );
      final proxy = await _RecordingProxy.start(
        offer['port'] as int,
        tamper: true,
      );
      addTearDown(proxy.close);
      final directory = Directory(p.join(root.path, 'received'));
      await expectLater(
        receiver.receive(
          id: 'wire-tampered',
          peerId: 'sender',
          host: '127.0.0.1',
          offer: {...offer, 'port': proxy.port},
          directory: directory,
          isCancelled: () => false,
          onProgress: (_, _, _) {},
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        await File(p.join(directory.path, '课程', 'video.mp4')).exists(),
        isFalse,
      );
    }, _DirectHttp());
  });

  test('receiver cannot define an unsent source file identity', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final source = await plan(1024);
      var completed = false;
      final offer = await sender.prepare(
        id: 'forged-receipt',
        peerId: 'receiver',
        plan: source,
        complete: (_) async {
          completed = true;
          return {};
        },
      );
      final key = SecretKey(base64Decode(offer['key'] as String));
      final aad = utf8.encode(
        jsonEncode([
          'FluentPlayer.Direct.v3',
          'forged-receipt',
          'complete',
          'request',
          '',
          null,
        ]),
      );
      final sealed = await AesGcm.with256bits().encrypt(
        utf8.encode(
          jsonEncode({
            'hashes': {'课程/video.mp4': 'f' * 64},
          }),
        ),
        secretKey: key,
        aad: aad,
      );
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      try {
        final request = await client.postUrl(
          Uri.parse(
            'http://127.0.0.1:${offer['port']}/direct/forged-receipt/complete',
          ),
        );
        request.headers.set('X-Fluent-Transfer', offer['token']!);
        request.add(sealed.concatenation());
        final response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, 409);
        expect(completed, isFalse);
      } finally {
        client.close(force: true);
      }
    }, _DirectHttp());
  });

  test('plaintext legacy direct offers fail before writing files', () async {
    final directory = Directory(p.join(root.path, 'received'));
    await expectLater(
      receiver.receive(
        id: 'legacy',
        peerId: 'sender',
        host: '127.0.0.1',
        offer: {'protocol': 2},
        directory: directory,
        isCancelled: () => false,
        onProgress: (_, _, _) {},
      ),
      throwsA(isA<FormatException>()),
    );
    expect(await directory.exists(), isFalse);
  });

  test('source edits during transfer prevent completion', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final source = await plan(512 * 1024);
      final offer = await sender.prepare(
        id: 'source-edited',
        peerId: 'receiver',
        plan: source,
        complete: (_) async {
          fail('Changed source must not complete');
        },
      );
      var edited = false;
      final directory = Directory(p.join(root.path, 'received'));
      await expectLater(
        receiver.receive(
          id: 'source-edited',
          peerId: 'sender',
          host: '127.0.0.1',
          offer: offer,
          directory: directory,
          bytesPerSecondLimit: 256 * 1024,
          isCancelled: () => false,
          onProgress: (done, _, _) {
            if (!edited && done > 0) {
              edited = true;
              File(source.files.single.path).setLastModifiedSync(
                DateTime.now().add(const Duration(seconds: 5)),
              );
            }
          },
        ),
        throwsA(isA<FormatException>()),
      );
    }, _DirectHttp());
  });

  test('recovered prefix bytes do not create a speed spike', () {
    final window = TransferSpeedWindow();
    expect(window.add(0, 0), 0);
    // A multi-megabyte prefix inside the first 200 ms is not a speed sample.
    expect(window.add(50000, 8 * 1024 * 1024), 0);
    expect(window.add(1000000, 500000), closeTo(500000, 1));
  });
}

class _RecordingProxy {
  _RecordingProxy(this.server, this.client);
  final HttpServer server;
  final HttpClient client;
  final List<int> bytes = [];
  final List<(String, List<int>)> requests = [];
  int get port => server.port;
  static Future<_RecordingProxy> start(
    int destination, {
    bool tamper = false,
  }) async {
    final proxy = _RecordingProxy(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      HttpClient()..findProxy = (_) => 'DIRECT',
    );
    proxy.server.listen((incoming) async {
      try {
        final body = await incoming.fold<List<int>>(
          [],
          (all, part) => all..addAll(part),
        );
        proxy.bytes.addAll(body);
        proxy.requests.add((incoming.uri.toString(), body));
        final outgoing = await proxy.client.postUrl(
          Uri.parse('http://127.0.0.1:$destination${incoming.uri}'),
        );
        outgoing.headers.set(
          'X-Fluent-Transfer',
          incoming.headers.value('X-Fluent-Transfer')!,
        );
        outgoing.add(body);
        final response = await outgoing.close();
        final data = await response.fold<List<int>>(
          [],
          (all, part) => all..addAll(part),
        );
        proxy.bytes.addAll(data);
        if (tamper && incoming.uri.path.endsWith('/file') && data.length > 30) {
          data[30] ^= 1;
        }
        incoming.response.statusCode = response.statusCode;
        incoming.response.add(data);
        await incoming.response.close();
      } catch (_) {
        try {
          await incoming.response.close();
        } catch (_) {}
      }
    });
    return proxy;
  }

  Future<void> close() async {
    client.close(force: true);
    await server.close(force: true);
  }
}
