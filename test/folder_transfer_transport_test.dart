import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as digest;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/progress_sync/folder_transfer_transport.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_lan.dart';

void main() {
  late Directory directory;
  late ProgressSyncLan a, b;
  late FolderTransferTransport sender, receiver;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('folder_transfer_');
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
    sender = FolderTransferTransport(lan: a);
    receiver = FolderTransferTransport(lan: b);
  });
  tearDown(() async {
    await sender.close();
    await receiver.close();
    await a.stop();
    await b.stop();
    a.dispose();
    b.dispose();
    if (await directory.exists()) await directory.delete(recursive: true);
  });
  Future<File> source([int size = 1024 * 1024 + 123]) async {
    final bytes = Uint8List(size);
    for (var i = 0; i < size; i++) {
      bytes[i] = (i * 37 + i ~/ 251) % 256;
    }
    return File('${directory.path}/source.fluentpack').writeAsBytes(bytes);
  }

  test(
    'parallel binary transfer verifies full SHA and exact durable progress',
    () async {
      const benchmark = bool.fromEnvironment('RUN_FOLDER_TRANSFER_BENCHMARK');
      final file = await source(
        benchmark ? 16 * 1024 * 1024 + 123 : 1024 * 1024 + 123,
      );
      final hashing = <FolderTransferProgress>[];
      final offer = await sender.prepareSend(
        file,
        peerId: 'receiver',
        chunkSize: benchmark ? 2 * 1024 * 1024 : 64 * 1024,
        onProgress: hashing.add,
      );
      final restored = FolderTransferOffer.fromJson(offer.toJson());
      final states = <FolderTransferProgress>[];
      final elapsed = Stopwatch()..start();
      final output = await receiver.receive(
        restored,
        destination: File('${directory.path}/received.fluentpack'),
        parallelism: 4,
        onProgress: states.add,
      );
      expect(await output.readAsBytes(), await file.readAsBytes());
      expect(
        offer.sha256,
        digest.sha256.convert(await file.readAsBytes()).toString(),
      );
      expect(hashing.last.phaseBytes, offer.size);
      expect(states.last.phase, FolderTransferPhase.completed);
      expect(states.last.receivedBytes, offer.size);
      expect(states.last.verifiedBytes, offer.size);
      expect(states.last.resumedBytes, 0);
      expect(
        states.any(
          (p) =>
              p.phase == FolderTransferPhase.verifying &&
              p.phaseBytes == offer.size,
        ),
        true,
      );
      expect(
        states.every(
          (p) =>
              p.verifiedBytes <= p.receivedBytes &&
              p.receivedBytes <= p.totalBytes,
        ),
        true,
      );
      expect(await File('${output.path}.transfer.jsonl').exists(), true);
      if (benchmark) {
        stdout.writeln(
          'Encrypted loopback: ${(offer.size / 1048576).toStringAsFixed(1)} MiB in ${elapsed.elapsedMilliseconds} ms, ${(offer.size / 1048576 * 1000 / elapsed.elapsedMilliseconds).toStringAsFixed(1)} MiB/s; four workers, full disk flush + SHA included',
        );
      }
    },
  );

  test(
    'cancelled transfer resumes only authenticated durable chunks from disk',
    () async {
      final file = await source(3 * 1024 * 1024 + 91);
      final offer = await sender.prepareSend(
        file,
        peerId: 'receiver',
        chunkSize: 64 * 1024,
      );
      final output = File('${directory.path}/resumed.fluentpack');
      final cancellation = FolderTransferCancellation();
      await expectLater(
        receiver.receive(
          offer,
          destination: output,
          parallelism: 2,
          cancellation: cancellation,
          onProgress: (p) {
            if (p.phase == FolderTransferPhase.transferring &&
                p.verifiedBytes >= 128 * 1024) {
              cancellation.cancel();
            }
          },
        ),
        throwsA(isA<FolderTransferCancelled>()),
      );
      final journal = File('${output.path}.transfer.jsonl');
      final rows = (await journal.readAsLines())
          .skip(1)
          .where((s) => s.isNotEmpty)
          .toList();
      expect(rows, isNotEmpty);
      await journal.writeAsString(
        '{"index":',
        mode: FileMode.append,
        flush: true,
      );
      final damagedIndex = (jsonDecode(rows.first) as Map)['index'] as int;
      final original = await output.open(mode: FileMode.append);
      await original.setPosition(damagedIndex * offer.chunkSize);
      await original.writeByte(255);
      await original.close();
      final recordedBytes = rows
          .map((row) => (jsonDecode(row) as Map)['index'] as int)
          .toSet()
          .fold<int>(
            0,
            (bytes, index) =>
                bytes +
                (index == offer.chunkCount - 1
                    ? offer.size - index * offer.chunkSize
                    : offer.chunkSize),
          );
      final states = <FolderTransferProgress>[];
      await receiver.close();
      receiver = FolderTransferTransport(lan: b);
      await receiver.receive(
        offer,
        destination: output,
        parallelism: 4,
        onProgress: states.add,
      );
      expect(states.last.resumedBytes, greaterThan(0));
      expect(states.last.resumedBytes, lessThan(offer.size));
      expect(states.last.resumedBytes, lessThan(recordedBytes));
      expect(await output.readAsBytes(), await file.readAsBytes());
    },
  );

  test('four workers share one aggregate byte-rate allowance', () async {
    const chunk = 64 * 1024;
    const limit = 128 * 1024;
    final file = await source(5 * chunk);
    final offer = await sender.prepareSend(
      file,
      peerId: 'receiver',
      chunkSize: chunk,
    );
    final states = <FolderTransferProgress>[];
    final elapsed = Stopwatch()..start();
    final output = await receiver.receive(
      offer,
      destination: File('${directory.path}/limited.fluentpack'),
      parallelism: 4,
      bytesPerSecondLimit: limit,
      onProgress: states.add,
    );
    elapsed.stop();
    // The first chunk may burst immediately. Four remaining chunks need two
    // seconds at the shared 128 KiB/s limit. A per-worker limiter incorrectly
    // permits four initial chunks and finishes in roughly half a second.
    expect(
      elapsed.elapsed,
      greaterThanOrEqualTo(const Duration(milliseconds: 1500)),
    );
    expect(await output.readAsBytes(), await file.readAsBytes());
    expect(states.last.phase, FolderTransferPhase.completed);
    expect(states.last.verifiedBytes, 5 * chunk);
  });

  test(
    'cancellation interrupts workers waiting for a distant rate permit',
    () async {
      const chunk = 64 * 1024;
      final file = await source(5 * chunk);
      final offer = await sender.prepareSend(
        file,
        peerId: 'receiver',
        chunkSize: chunk,
      );
      final cancellation = FolderTransferCancellation();
      final firstChunk = Completer<void>();
      final states = <FolderTransferProgress>[];
      final output = File('${directory.path}/cancel-limited.fluentpack');
      final work = receiver.receive(
        offer,
        destination: output,
        parallelism: 4,
        bytesPerSecondLimit: 4 * 1024,
        cancellation: cancellation,
        onProgress: (progress) {
          states.add(progress);
          if (progress.phase == FolderTransferPhase.transferring &&
              progress.verifiedBytes >= chunk &&
              !firstChunk.isCompleted) {
            firstChunk.complete();
          }
        },
      );
      final failed = expectLater(work, throwsA(isA<FolderTransferCancelled>()));
      await firstChunk.future.timeout(const Duration(seconds: 8));
      // Every remaining chunk is queued behind a permit at least sixteen
      // seconds away. Cancelling must not wait for that permit to expire.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(states.last.verifiedBytes, chunk);
      final cancelElapsed = Stopwatch()..start();
      cancellation.cancel();
      await failed.timeout(const Duration(seconds: 3));
      cancelElapsed.stop();
      expect(cancelElapsed.elapsed, lessThan(const Duration(seconds: 3)));
      expect(states.last.phase, FolderTransferPhase.cancelled);
      expect(states.last.verifiedBytes, chunk);
      expect(await File('${output.path}.transfer.jsonl').exists(), isTrue);
    },
  );

  test('hashing can be cancelled without granting a file capability', () async {
    final cancel = FolderTransferCancellation();
    await expectLater(
      sender.prepareSend(
        await source(8 * 1024 * 1024),
        peerId: 'receiver',
        cancellation: cancel,
        onProgress: (p) {
          if (p.phaseBytes > 0) cancel.cancel();
        },
      ),
      throwsA(isA<FolderTransferCancelled>()),
    );
  });

  test(
    'removing the sender pairing cancels reception and preserves a resumable checkpoint',
    () async {
      final offer = await sender.prepareSend(
        await source(),
        peerId: 'receiver',
      );
      Future<void>? revocation;
      final output = File('${directory.path}/unpaired.fluentpack');
      await expectLater(
        receiver.receive(
          offer,
          destination: output,
          maxRetries: 0,
          onProgress: (p) {
            if (p.phase == FolderTransferPhase.transferring &&
                revocation == null) {
              revocation = b.removePeer('sender');
            }
          },
        ),
        throwsA(isA<FolderTransferException>()),
      );
      await revocation;
      expect(b.isTrustedPeer('sender'), false);
      expect(await File('${output.path}.transfer.jsonl').exists(), true);
    },
  );

  test(
    'encrypted binary ranges retry tampering and reject replayed requests',
    () async {
      final file = await source(5 * 64 * 1024 + 41);
      final offer = await sender.prepareSend(
        file,
        peerId: 'receiver',
        chunkSize: 64 * 1024,
      );
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      Map<String, List<String>>? captured;
      List<int>? capturedWire;
      var modified = false;
      final subscription = proxy.listen((request) async {
        final client = HttpClient()..findProxy = (_) => 'DIRECT';
        try {
          final forwarded = await client.getUrl(
            Uri(
              scheme: 'http',
              host: '127.0.0.1',
              port: offer.port,
              path: request.uri.path,
            ),
          );
          request.headers.forEach((name, values) {
            if (name.toLowerCase() != 'host') {
              forwarded.headers.set(name, values);
            }
          });
          final response = await forwarded.close();
          final bytes = await response.fold<List<int>>(
            [],
            (a, b) => a..addAll(b),
          );
          if (!request.uri.path.endsWith('/session') &&
              !modified &&
              response.statusCode == 206) {
            modified = true;
            captured = {};
            request.headers.forEach(
              (key, value) => captured![key] = List.of(value),
            );
            capturedWire = List.of(bytes);
            bytes[12] ^= 1;
          }
          request.response.statusCode = response.statusCode;
          request.response.contentLength = bytes.length;
          final contentRange = response.headers.value(
            HttpHeaders.contentRangeHeader,
          );
          if (contentRange != null) {
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              contentRange,
            );
          }
          request.response.add(bytes);
          await request.response.close();
        } finally {
          client.close(force: true);
        }
      });
      try {
        final proxiedOffer = FolderTransferOffer.fromJson({
          ...offer.toJson(),
          'port': proxy.port,
        });
        final result = await receiver.receive(
          proxiedOffer,
          destination: File('${directory.path}/tamper.fluentpack'),
          host: '127.0.0.1',
          maxRetries: 2,
        );
        expect(modified, true);
        expect(await result.readAsBytes(), await file.readAsBytes());
        expect(capturedWire!.length, 64 * 1024 + 28);
        expect(
          capturedWire!.sublist(12, 76),
          isNot((await file.readAsBytes()).sublist(0, 64)),
        );
        final replay = HttpClient()..findProxy = (_) => 'DIRECT';
        try {
          final request = await replay.getUrl(
            Uri.parse(
              'http://127.0.0.1:${offer.port}/folder-transfer/v1/${offer.transferId}',
            ),
          );
          captured!.forEach((name, values) {
            if (name.toLowerCase() != 'host') request.headers.set(name, values);
          });
          final response = await request.close();
          expect(response.statusCode, 409);
          expect(
            await response.fold<int>(0, (n, bytes) => n + bytes.length),
            0,
          );
        } finally {
          replay.close(force: true);
        }
      } finally {
        await subscription.cancel();
        await proxy.close(force: true);
      }
    },
  );

  test(
    'whole-file SHA rejects source changes even if size and timestamp are preserved',
    () async {
      final file = await source(128 * 1024 + 91);
      final offer = await sender.prepareSend(
        file,
        peerId: 'receiver',
        chunkSize: 64 * 1024,
      );
      final time = (await file.stat()).modified;
      final edit = await file.open(mode: FileMode.append);
      await edit.setPosition(17);
      await edit.writeByte(255);
      await edit.close();
      await file.setLastModified(time);
      final output = File('${directory.path}/bad-hash.fluentpack');
      await expectLater(
        receiver.receive(offer, destination: output, maxRetries: 0),
        throwsA(
          isA<FolderTransferException>().having(
            (e) => e.code,
            'code',
            'checksumMismatch',
          ),
        ),
      );
      expect(
        (await File('${output.path}.transfer.jsonl').readAsLines()).length,
        1,
      );
    },
  );

  test(
    'anonymous requests and revoked capabilities return no file bytes',
    () async {
      final offer = await sender.prepareSend(
        await source(),
        peerId: 'receiver',
      );
      Future<int> raw() async {
        final client = HttpClient()..findProxy = (_) => 'DIRECT';
        try {
          final request = await client.getUrl(
            Uri.parse(
              'http://127.0.0.1:${offer.port}/folder-transfer/v1/${offer.transferId}',
            ),
          );
          request.headers.set(
            HttpHeaders.rangeHeader,
            'bytes=0-${offer.size - 1}',
          );
          final response = await request.close();
          expect(
            await response.fold<int>(0, (n, bytes) => n + bytes.length),
            0,
          );
          return response.statusCode;
        } finally {
          client.close(force: true);
        }
      }

      expect(await raw(), 403);
      sender.cancelSend(offer.transferId);
      await expectLater(
        receiver.receive(
          offer,
          destination: File('${directory.path}/revoked.fluentpack'),
          maxRetries: 0,
        ),
        throwsA(isA<FolderTransferException>()),
      );
      expect(await raw(), 403);
    },
  );

  test(
    'wrong session key cannot download and existing output is preserved',
    () async {
      final offer = await sender.prepareSend(
        await source(),
        peerId: 'receiver',
      );
      final wrong = FolderTransferOffer.fromJson({
        ...offer.toJson(),
        'sessionKey': base64Encode(List.filled(32, 1)),
      });
      await expectLater(
        receiver.receive(
          wrong,
          destination: File('${directory.path}/wrong.fluentpack'),
          maxRetries: 0,
        ),
        throwsA(isA<FolderTransferException>()),
      );
      final existing = File('${directory.path}/keep.fluentpack');
      await existing.writeAsString('keep this');
      await expectLater(
        receiver.receive(offer, destination: existing),
        throwsA(isA<FolderTransferException>()),
      );
      expect(await existing.readAsString(), 'keep this');
    },
  );

  test(
    'unknown cipher and protocol versions are rejected without downgrade',
    () async {
      final offer = await sender.prepareSend(
        await source(32),
        peerId: 'receiver',
      );
      for (final change in [
        {'cipher': 'aes-gcm'},
        {'cipher': null},
        {'version': 2},
      ]) {
        expect(
          () => FolderTransferOffer.fromJson({...offer.toJson(), ...change}),
          throwsA(isA<FolderTransferException>()),
        );
      }
    },
  );

  test(
    'concurrent receive of one capability cannot race its checkpoint',
    () async {
      final offer = await sender.prepareSend(
        await source(),
        peerId: 'receiver',
        chunkSize: 64 * 1024,
      );
      final output = File('${directory.path}/one-receiver.fluentpack');
      final first = receiver.receive(offer, destination: output);
      await expectLater(
        receiver.receive(offer, destination: output),
        throwsA(
          isA<FolderTransferException>().having(
            (e) => e.code,
            'code',
            'alreadyReceiving',
          ),
        ),
      );
      await first;
    },
  );
}
