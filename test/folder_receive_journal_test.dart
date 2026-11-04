import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/progress_sync/folder_media_committer.dart';
import 'package:video_player_app/features/progress_sync/folder_receive_journal.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('receive_journal_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('journal save is readable and a newer schema is preserved', () async {
    final file = File(p.join(root.path, 'receive-journal.json'));
    const journal = FolderReceiveJournal(
      transferId: 'transfer-1',
      groupId: 'group-1',
      peerId: 'peer-1',
      manifestRevision: 'rev-1',
      assets: [
        ReceiveAssetRecord(
          assetId: 'asset-1',
          nodeIds: ['node-1'],
          role: 'primary',
          expectedLength: 4,
          stage: ReceiveAssetStage.fileCommitted,
          permanentPath: r'C:\library\asset-1.mp4',
          cardId: 'card-1',
        ),
      ],
    );
    await FolderReceiveJournal.save(file, journal);
    final loaded = await FolderReceiveJournal.load(file);
    expect(loaded?.assets.single.stage, ReceiveAssetStage.fileCommitted);
    expect(loaded?.assets.single.cardId, 'card-1');

    await file.writeAsString('{"schemaVersion": 9, "transferId": "keep"}');
    expect(
      () => FolderReceiveJournal.load(file),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('更新'),
        ),
      ),
    );
    expect(await file.readAsString(), contains('"schemaVersion": 9'));
  });

  test('strict commit throws instead of keeping a temporary path', () async {
    final sourceDir = Directory(p.join(root.path, 'incoming'));
    final permanent = Directory(p.join(root.path, 'library'));
    await sourceDir.create();
    final source = File(p.join(sourceDir.path, 'clip.mp4'));
    await source.writeAsBytes([1, 2, 3, 4]);
    final committed = await const FolderMediaCommitter().commitFile(
      sourcePath: source.path,
      permanentDirectory: permanent,
      expectedLength: 4,
      reservedFileName: 'card.mp4',
    );
    expect(p.isWithin(permanent.path, committed), isTrue);
    expect(await File(committed).readAsBytes(), [1, 2, 3, 4]);
    expect(
      () => const FolderMediaCommitter().commitFile(
        sourcePath: p.join(sourceDir.path, 'missing.mp4'),
        permanentDirectory: permanent,
      ),
      throwsA(isA<FileSystemException>()),
    );
  });
}
