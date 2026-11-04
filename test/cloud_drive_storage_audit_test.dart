import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/services/storage_audit_models.dart';
import 'package:video_player_app/services/storage_audit_service.dart';
import 'package:video_player_app/services/storage_contributors.dart';

import 'support/storage_directory_alias.dart';

void main() {
  late Directory workspace;
  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('cloud_storage_audit_');
  });
  tearDown(() async {
    if (await workspace.exists()) await workspace.delete(recursive: true);
  });

  Future<File> write(String path, List<int> bytes) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    return file;
  }

  Future<StorageSnapshot> scan(
    Directory data, {
    StorageLiveProtection live = const StorageLiveProtection(),
    List<StorageCloudOwnerHint> owners = const [],
  }) {
    final inspection = inspectStorageFeatures(
      dataRoot: data,
      live: live,
      cloudOwners: owners,
    );
    return scanStorageFiles(
      StorageScanInput(
        roots: [
          StorageRoot(data.path, '媒体库数据', StorageRootKind.data),
          ...inspection.roots,
        ],
        assets: inspection.assets,
        verifiedPaths: inspection.verifiedPaths,
        warnings: inspection.warnings,
      ),
    );
  }

  void manifest(Directory directory, Map<String, Object?> json) {
    File(
      p.join(directory.path, 'manifest.json'),
    ).writeAsStringSync(jsonEncode(json));
  }

  test('selected feature inspection preserves aliases and live protection', () async {
    final data = await Directory(p.join(workspace.path, 'data')).create();
    final material = await Directory(p.join(workspace.path, 'material')).create();
    final directory = await Directory(p.join(material.path, 'one')).create();
    final media = await write(p.join(directory.path, 'media.bin'), [1, 2, 3]);
    manifest(directory, {
      'schema': 2, 'kind': 'cloudDrive', 'revision': '1',
      'path': 'media.bin', 'size': 3,
    });
    final alias = p.join(workspace.path, 'data-alias');
    final featureAlias = p.join(data.path, 'cloud_drive_material');
    await createStorageDirectoryAlias(alias, data.path);
    await createStorageDirectoryAlias(featureAlias, material.path);
    try {
      final original = inspectStorageFeatures(dataRoot: Directory(alias));
      final selected = inspectStorageFeatures(dataRoot: Directory(alias), onlyPaths: [media.path]);
      expect(selected.assets.single.deletable, isTrue);
      expect(selected.assets.single.version, original.assets.single.version);
      final protected = inspectStorageFeatures(
        dataRoot: Directory(alias), onlyPaths: [media.path],
        live: StorageLiveProtection(cloudDirectories: {p.join(alias, 'cloud_drive_material', 'one')}),
      );
      expect(protected.assets.single.protected, isTrue);
      expect(protected.assets.single.deletable, isFalse);
    } finally {
      await Link(featureAlias).delete();
      await Link(alias).delete();
    }
  });

  test('selected inspection does not read unrelated feature trees', () async {
    final data = Directory(p.join(workspace.path, 'library'));
    final directory = Directory(
      p.join(data.path, 'cloud_drive_material', 'selected'),
    );
    final media = await write(p.join(directory.path, 'media.bin'), [1, 2, 3]);
    manifest(directory, {
      'schema': 2,
      'kind': 'cloudDrive',
      'revision': '1',
      'path': 'media.bin',
      'size': 3,
    });
    await write(
      p.join(data.path, 'cloud_drive_material', 'unrelated', 'manifest.json'),
      utf8.encode('broken manifest'),
    );
    await write(p.join(data.path, 'podcasts', 'podcasts.sqlite'), [0]);
    await write(p.join(data.path, 'artwork', 'index.sqlite'), [0]);
    final inspection = inspectStorageFeatures(
      dataRoot: data,
      onlyPaths: [media.path],
    );
    expect(inspection.warnings, hasLength(1));
    expect(inspection.warnings.single, contains('系统安全存储'));
    final asset = inspection.assets.single;
    expect(asset.directory, directory.path);
    expect(asset.deletable, isTrue);
    final full = inspectStorageFeatures(dataRoot: data);
    final original = full.assets.singleWhere(
      (a) => a.directory == directory.path,
    );
    expect(asset.version, original.version);
    expect(full.warnings.length, greaterThan(inspection.warnings.length));
  });

  test(
    'selecting a subtitle stamp inspects only its body and preserves edits',
    () async {
      final data = Directory(p.join(workspace.path, 'library'));
      final text = utf8.encode('original subtitle');
      final body = await write(
        p.join(data.path, 'cloud_drive_subtitles', 'nested', 'a.srt'),
        text,
      );
      final stamp = await write(
        '${body.path}.stamp',
        utf8.encode(sha256.convert(text).toString()),
      );
      await write(
        p.join(body.parent.path, 'unselected.srt'),
        utf8.encode('unrelated'),
      );
      StorageAssetDescriptor inspect() => inspectStorageFeatures(
        dataRoot: data,
        onlyPaths: [stamp.path],
      ).assets.single;
      final original = inspect();
      expect(original.paths, [body.path, stamp.path]);
      expect(original.deletable, isTrue);
      await body.writeAsString('edited subtitle');
      final edited = inspect();
      expect(edited.deletable, isFalse);
      expect(edited.policy, StorageCleanupPolicy.savedContent);
    },
  );

  test('progressive, hls and sealed material keep separate cleanup rules', () async {
    final data = Directory(p.join(workspace.path, 'library'));
    final progressive = Directory(
      p.join(data.path, 'cloud_drive_material', 'progressive'),
    );
    await progressive.create(recursive: true);
    await write(p.join(progressive.path, 'media.bin.part'), [1, 2, 3]);
    await write(
      p.join(progressive.path, 'media.bin.part.json'),
      utf8.encode('{"received":3}'),
    );
    manifest(progressive, {
      'schema': 2,
      'kind': 'cloudDrive',
      'providerId': 'baidu',
      'remoteAccountId': 'account-a',
      'driveId': 'drive-a',
      'fileId': 'file-a',
      'revision': '1',
      'representation': '480',
      'path': 'media.bin',
      'size': 3,
      'itemId': 'card-a',
      'qualityLabel': '480p',
    });
    final hls = Directory(p.join(data.path, 'cloud_drive_material', 'hls'));
    await hls.create(recursive: true);
    await write(p.join(hls.path, 'seg-0.part'), [4, 4]);
    await write(p.join(hls.path, 'init.map'), [5]);
    await write(
      p.join(hls.path, 'hls-checkpoint.json'),
      utf8.encode('{"done":[0]}'),
    );
    manifest(hls, {
      'schema': 2,
      'kind': 'cloudDrive',
      'providerId': 'quark',
      'remoteAccountId': 'account-b',
      'driveId': 'drive-b',
      'fileId': 'file-b',
      'revision': '2',
      'representation': '720',
      'path': 'media.bin',
      'size': 8,
      'itemId': 'card-b',
    });
    final sealed = Directory(p.join(data.path, 'cloud_drive_material', 'sealed'));
    await sealed.create(recursive: true);
    final media = await write(p.join(sealed.path, 'media.bin'), [6, 6, 6, 6]);
    await write(p.join(sealed.path, 'seg-0.part'), [7]);
    manifest(sealed, {
      'schema': 2,
      'kind': 'cloudDrive',
      'providerId': 'baidu',
      'remoteAccountId': 'account-a',
      'driveId': 'drive-a',
      'fileId': 'file-c',
      'revision': '3',
      'representation': '1080',
      'path': 'media.bin',
      'size': media.lengthSync(),
      'itemId': 'card-c',
      'qualityLabel': '1080p',
    });
    final snapshot = await scan(
      data,
      owners: const [
        StorageCloudOwnerHint(
          itemId: 'card-c',
          title: '共享影片',
          providerId: 'baidu',
          remoteAccountId: 'account-a',
          driveId: 'drive-a',
          fileId: 'file-c',
        ),
        StorageCloudOwnerHint(
          itemId: 'card-c-copy',
          title: '另一张卡片',
          providerId: 'baidu',
          remoteAccountId: 'account-a',
          driveId: 'drive-a',
          fileId: 'file-c',
        ),
      ],
    );
    final part = snapshot.files.firstWhere(
      (file) => file.path.endsWith('media.bin.part'),
    );
    expect(part.category, StorageCategory.downloadTemp);
    expect(
      storageDeletionPermitted(StorageCleanupAction.clearCache, part),
      isFalse,
    );
    expect(
      storageDeletionPermitted(StorageCleanupAction.abandonResume, part),
      isTrue,
    );
    expect(part.ownerTitles.join(), isNot(contains('另一张卡片')));
    final residue = snapshot.files.firstWhere(
      (file) => file.path.contains('sealed') && file.path.endsWith('seg-0.part'),
    );
    expect(residue.canDelete, isTrue);
    final sealedMedia = snapshot.files.firstWhere(
      (file) => file.path == media.path,
    );
    expect(sealedMedia.category, StorageCategory.materialized);
    expect(sealedMedia.canDelete, isTrue);
    expect(sealedMedia.ownerIds, containsAll(['card-c', 'card-c-copy']));
    expect(sealedMedia.bytes, 4);
    expect(
      snapshot.origins.fold<int>(0, (sum, origin) => sum + origin.bytes),
      snapshot.appBytes,
    );
  });

  test('an in-use directory and a file added after confirmation stay', () async {
    final data = Directory(p.join(workspace.path, 'library'));
    final directory = Directory(p.join(data.path, 'cloud_drive_material', 'one'));
    await directory.create(recursive: true);
    final media = await write(p.join(directory.path, 'media.bin'), [1, 2, 3, 4]);
    manifest(directory, {
      'schema': 2,
      'kind': 'cloudDrive',
      'providerId': 'baidu',
      'remoteAccountId': 'a',
      'driveId': 'd',
      'fileId': 'f',
      'revision': '1',
      'representation': 'original',
      'path': 'media.bin',
      'size': 4,
      'itemId': 'item',
    });
    final protected = await scan(
      data,
      live: StorageLiveProtection(cloudDirectories: {directory.path}),
    );
    expect(
      protected.files.firstWhere((file) => file.path == media.path).canDelete,
      isFalse,
    );
    Future<StorageScanInput> input() async {
      final inspection = inspectStorageFeatures(dataRoot: data);
      return StorageScanInput(
        roots: [
          StorageRoot(data.path, '媒体库数据', StorageRootKind.data),
          ...inspection.roots,
        ],
        assets: inspection.assets,
        verifiedPaths: inspection.verifiedPaths,
      );
    }

    final audit = StorageAuditService(
      buildInput: input,
      deletionBlockedReason: () => null,
    );
    addTearDown(audit.dispose);
    final open = await audit.scan();
    final selected = open.files.firstWhere((file) => file.path == media.path);
    final added = await write(p.join(directory.path, 'seg-9.part'), [8, 8, 8]);
    final result = await audit.delete(
      StorageDeletionPlan(
        [selected],
        action: StorageCleanupAction.clearCache,
      ),
    );
    expect(result.deletedPaths, isEmpty);
    expect(result.skipped[media.path], contains('版本'));
    expect(await added.exists(), isTrue);
    expect(await media.exists(), isTrue);
  });

  test('subtitle stamp, missing stamp and saved kinds stay distinct', () async {
    final data = Directory(p.join(workspace.path, 'library'));
    final freshText = '1\n00:00:00,000 --> 00:00:01,000\nhello\n';
    final fresh = await write(
      p.join(data.path, 'cloud_drive_subtitles', 'baidu', 'acc', 'file', 'track.srt'),
      utf8.encode(freshText),
    );
    await write(
      File('${fresh.path}.stamp').path,
      utf8.encode(sha256.convert(utf8.encode(freshText)).toString()),
    );
    final edited = await write(
      p.join(
        data.path,
        'cloud_drive_subtitles',
        'baidu',
        'acc',
        'file',
        'edited.srt',
      ),
      utf8.encode('changed'),
    );
    await write(File('${edited.path}.stamp').path, utf8.encode('not-the-hash'));
    final missing = await write(
      p.join(data.path, 'cloud_drive_subtitles', 'baidu', 'acc', 'file', 'plain.srt'),
      utf8.encode('plain'),
    );
    final official = await write(
      p.join(data.path, 'subtitles', 'tasks', 'item', 'official.srt'),
      utf8.encode('official'),
    );
    final snapshot = await scanStorageFiles(
      StorageScanInput(
        roots: [StorageRoot(data.path, '媒体库数据', StorageRootKind.data)],
        assets: inspectStorageFeatures(dataRoot: data).assets,
        references: [
          StorageReference(
            path: official.path,
            ownerId: 'item',
            ownerTitle: '网盘影片',
            category: StorageCategory.subtitles,
            origin: StorageOrigin.cloudDrive,
            subtitleKind: StorageSubtitleKinds.cloudOfficialAi,
            assetKey: 'cloud-official-baidu-track',
          ),
        ],
      ),
    );
    final freshEntry = snapshot.files.firstWhere((file) => file.path == fresh.path);
    expect(freshEntry.canDelete, isTrue);
    expect(freshEntry.subtitleKind, StorageSubtitleKinds.cloudSidecar);
    final editedEntry = snapshot.files.firstWhere(
      (file) => file.path == edited.path,
    );
    expect(editedEntry.explicitDelete, isTrue);
    expect(editedEntry.canDelete, isFalse);
    expect(
      snapshot.files.firstWhere((file) => file.path == missing.path).subtitleKind,
      StorageSubtitleKinds.unverified,
    );
    final officialEntry = snapshot.files.firstWhere(
      (file) => file.path == official.path,
    );
    expect(officialEntry.subtitleKind, StorageSubtitleKinds.cloudOfficialAi);
    expect(officialEntry.category, StorageCategory.subtitles);
    expect(
      storageDeletionPermitted(
        StorageCleanupAction.clearCache,
        officialEntry,
      ),
      isFalse,
    );
    expect(
      storageDeletionPermitted(
        StorageCleanupAction.deleteSubtitle,
        officialEntry,
      ),
      isTrue,
    );
  });
}
