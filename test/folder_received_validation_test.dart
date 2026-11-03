import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/progress_sync/folder_receive_journal.dart';
import 'package:video_player_app/features/progress_sync/folder_received_validation.dart';

void main() {
  late Directory root;
  late File media, journal;
  late List<int> original;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('received-validation-');
    media = File(p.join(root.path, 'permanent.mp4'));
    journal = File(p.join(root.path, 'receive-journal.json'));
    original = List.generate(256 * 1024, (i) => i % 251);
    await media.writeAsBytes(original, flush: true);
    await FolderReceiveJournal.save(
      journal,
      FolderReceiveJournal(
        transferId: 'transfer-1',
        groupId: 'group-1',
        peerId: 'peer-1',
        manifestRevision: 'transfer-1',
        targetRootId: 'folder-1',
        assets: [
          ReceiveAssetRecord(
            assetId: 'media-1',
            nodeIds: const ['node-1'],
            role: 'primary',
            expectedLength: original.length,
            stage: ReceiveAssetStage.attached,
            permanentPath: media.path,
            cardId: 'card-1',
            contentIdentity: sha256.convert(original).toString(),
            confirmedBytes: original.length,
          ),
        ],
      ),
    );
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });
  Future<bool> validate({bool Function()? cancel, String? path}) =>
      validateReceivedFolderFiles(
        journalFile: journal,
        transferId: 'transfer-1',
        peerId: 'peer-1',
        targetRootId: 'folder-1',
        currentMediaPath: (id) => id == 'card-1' ? path ?? media.path : null,
        isCancelled: cancel,
      );

  test(
    'valid published bytes satisfy recovery without modifying files',
    () async {
      final before = await media.stat(), receipt = await journal.readAsBytes();
      expect(await validate(), isTrue);
      expect(await media.readAsBytes(), original);
      expect((await media.stat()).modified, before.modified);
      expect(await journal.readAsBytes(), receipt);
    },
  );

  test(
    'same-length corruption is rejected even with original modification time',
    () async {
      final modified = (await media.stat()).modified;
      final corrupt = List<int>.of(original)..[100] = 127;
      await media.writeAsBytes(corrupt, flush: true);
      await media.setLastModified(modified);
      expect(await validate(), isFalse);
    },
  );

  test(
    'missing and truncated published files do not prove completion',
    () async {
      await media.writeAsBytes(original.sublist(0, 100));
      expect(await validate(), isFalse);
      await media.delete();
      expect(await validate(), isFalse);
    },
  );

  test('a non-file at the published path cannot satisfy recovery', () async {
    await media.delete();
    await Directory(media.path).create();
    expect(await validate(), isFalse);
  });

  test('unreadable locked file returns false', () async {
    final handle = await media.open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.exclusive, 0, original.length);
      final valid = await validate();
      // POSIX locks are advisory, while Windows denies the conflicting read.
      expect(valid, Platform.isWindows ? isFalse : isTrue);
    } finally {
      await handle.unlock(0, original.length);
      await handle.close();
    }
  });

  test('missing, corrupt and mismatched journal cannot skip receive', () async {
    final raw = jsonDecode(await journal.readAsString()) as Map;
    raw['peerId'] = 'another-peer';
    await journal.writeAsString(jsonEncode(raw));
    expect(await validate(), isFalse);
    await journal.writeAsString('{');
    expect(await validate(), isFalse);
    await journal.delete();
    expect(await validate(), isFalse);
  });

  test('unknown journal schema stays untouched and requires update', () async {
    final raw = jsonDecode(await journal.readAsString()) as Map;
    raw['schemaVersion'] = 2;
    final encoded = jsonEncode(raw);
    await journal.writeAsString(encoded);
    await expectLater(validate(), throwsFormatException);
    expect(await journal.readAsString(), encoded);
  });

  test(
    'changed card path or cancelled recovery cannot claim completion',
    () async {
      expect(await validate(path: p.join(root.path, 'different.mp4')), isFalse);
      expect(await validate(cancel: () => true), isFalse);
    },
  );

  test(
    'malformed asset list is not treated as an empty successful transfer',
    () async {
      final raw = jsonDecode(await journal.readAsString()) as Map;
      raw['assets'] = [null];
      await journal.writeAsString(jsonEncode(raw));
      expect(await validate(), isFalse);
    },
  );
}
