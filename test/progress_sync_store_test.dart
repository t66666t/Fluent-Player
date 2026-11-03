import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cryptography/cryptography.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  FileProgressSyncStore store() =>
      FileProgressSyncStore(directoryProvider: () async => root);
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('progress_sync_store_');
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'credentials and private progress are encrypted and survive restart',
    () async {
      final original = store();
      expect(await original.read(), isNull);
      final state = {
        'version': 1,
        'password': 'private-cloud-password',
        'title': '我的私人课程',
        'positionMs': 125000,
      };
      await original.write(state);
      final contents = await File(
        '${root.path}/progress_sync_v1.enc',
      ).readAsString();
      expect(contents, isNot(contains('private-cloud-password')));
      expect(contents, isNot(contains('我的私人课程')));
      expect(await store().read(), state);
      expect(
        await File('${root.path}/progress_sync_v1.enc.tmp').exists(),
        isFalse,
      );
    },
  );

  test(
    'concurrent checkpoints are serialized and last submitted checkpoint wins',
    () async {
      final current = store();
      await Future.wait(
        List.generate(12, (i) => current.write({'checkpoint': i})),
      );
      expect(await store().read(), {'checkpoint': 11});
    },
  );

  test(
    'tampered encrypted state is rejected rather than accepted as progress',
    () async {
      await store().write({'version': 1, 'positionMs': 42000});
      final file = File('${root.path}/progress_sync_v1.enc');
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final bytes = base64Decode(data['cipherText'] as String);
      bytes[0] ^= 1;
      data['cipherText'] = base64Encode(bytes);
      await file.writeAsString(jsonEncode(data));
      await expectLater(store().read(), throwsA(anything));
    },
  );

  test(
    'missing wrapping key never silently replaces existing encrypted state',
    () async {
      await store().write({'version': 1, 'positionMs': 42000});
      final file = File('${root.path}/progress_sync_v1.enc');
      final original = await file.readAsString();
      FlutterSecureStorage.setMockInitialValues({});
      await expectLater(store().read(), throwsFormatException);
      await expectLater(
        store().write({'positionMs': 0}),
        throwsFormatException,
      );
      expect(await file.readAsString(), original);
    },
  );

  test('large catalog checkpoints compress and survive restart', () async {
    final state = {'version': 1, 'catalog': 'catalog-entry-' * 100000};
    final current = FileProgressSyncStore(
      directoryProvider: () async => root,
      maxStoredBytes: 64 * 1024,
    );
    await current.write(state);
    final file = File('${root.path}/progress_sync_v1.enc');
    expect(await file.length(), lessThan(64 * 1024));
    expect(
      (jsonDecode(await file.readAsString()) as Map)['compression'],
      'gzip',
    );
    expect(
      await FileProgressSyncStore(
        directoryProvider: () async => root,
        maxStoredBytes: 64 * 1024,
      ).read(),
      state,
    );
    await expectLater(
      FileProgressSyncStore(
        directoryProvider: () async => root,
        maxPlainBytes: 4096,
      ).read(),
      throwsFormatException,
    );
  });

  test(
    'legacy oversized checkpoints can be read and compacted safely',
    () async {
      await store().write({'initial': true});
      final rawKey = await const FlutterSecureStorage().read(
        key: 'fluent_player_progress_sync_key_v1',
      );
      final state = {'version': 1, 'catalog': 'old-entry-' * 120000};
      final box = await AesGcm.with256bits().encrypt(
        utf8.encode(jsonEncode(state)),
        secretKey: SecretKey(base64Decode(rawKey!)),
        aad: utf8.encode('FluentPlayer.ProgressSync.Store.v1'),
      );
      final file = File('${root.path}/progress_sync_v1.enc');
      await file.writeAsString(
        jsonEncode({
          'version': 1,
          'nonce': base64Encode(box.nonce),
          'cipherText': base64Encode(box.cipherText),
          'mac': base64Encode(box.mac.bytes),
        }),
      );
      expect(await file.length(), greaterThan(64 * 1024));
      final current = FileProgressSyncStore(
        directoryProvider: () async => root,
        maxStoredBytes: 64 * 1024,
      );
      expect(await current.read(), state);
      await current.write(state);
      expect(await file.length(), lessThan(64 * 1024));
      expect(await current.read(), state);
    },
  );

  test(
    'oversized writes preserve the last readable encrypted checkpoint',
    () async {
      final current = FileProgressSyncStore(
        directoryProvider: () async => root,
        maxStoredBytes: 512,
        maxPlainBytes: 2048,
      );
      await current.write({'checkpoint': 1});
      final file = File('${root.path}/progress_sync_v1.enc');
      final original = await file.readAsBytes();
      await expectLater(
        current.write({'catalog': 'x' * 900}),
        throwsFormatException,
      );
      expect(await file.readAsBytes(), original);
      await expectLater(
        current.write({'catalog': 'x' * 4096}),
        throwsFormatException,
      );
      expect(await file.readAsBytes(), original);
      expect(await current.read(), {'checkpoint': 1});
    },
  );
}
