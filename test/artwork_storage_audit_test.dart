import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/services/storage_audit_models.dart';
import 'package:video_player_app/services/storage_audit_service.dart';
import 'package:video_player_app/services/storage_contributors.dart';

void main() {
  late Directory workspace;
  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('artwork_storage_audit_');
  });
  tearDown(() async {
    if (await workspace.exists()) await workspace.delete(recursive: true);
  });

  Future<StorageSnapshot> scan(Directory data, {bool busy = false}) {
    final inspection = inspectStorageFeatures(
      dataRoot: data,
      live: StorageLiveProtection(artworkBusy: busy),
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
        minimumTemporaryAge: const Duration(minutes: 10),
      ),
    );
  }

  void createIndex(Directory root) {
    final database = sqlite3.open(p.join(root.path, 'index.sqlite'));
    database.execute(
      'CREATE TABLE blobs (blob_hash TEXT PRIMARY KEY, relative_path TEXT, bytes INTEGER, format TEXT, width INTEGER, height INTEGER, used_ms INTEGER, published INTEGER)',
    );
    database.execute(
      'CREATE TABLE aliases (request_key TEXT PRIMARY KEY, blob_hash TEXT, adapter TEXT, url_digest TEXT, persistent INTEGER, exportable INTEGER)',
    );
    database.execute(
      'CREATE TABLE owners (owner_kind TEXT, owner_id TEXT, request_key TEXT, expires_ms INTEGER)',
    );
    database.execute(
      'CREATE TABLE palettes (blob_hash TEXT, algorithm INTEGER, argb INTEGER)',
    );
    database.execute('CREATE TABLE leases (request_key TEXT, lease_id TEXT)');
    database.execute(
      "INSERT INTO blobs(blob_hash, relative_path, bytes, format, width, height, used_ms, published) VALUES('hash','blobs/hash.png',4,'png',1,1,0,1)",
    );
    database.execute(
      "INSERT INTO aliases(request_key, blob_hash, adapter, url_digest, persistent, exportable) VALUES('req','hash','https', 'digest', 0, 1)",
    );
    database.execute(
      "INSERT INTO owners(owner_kind, owner_id, request_key, expires_ms) VALUES('podcast','ep-1','req',0)",
    );
    database.execute(
      "INSERT INTO owners(owner_kind, owner_id, request_key, expires_ms) VALUES('library','card-1','req',0)",
    );
    database.execute(
      "INSERT INTO palettes(blob_hash, algorithm, argb) VALUES('hash',1,1)",
    );
    database.dispose();
  }

  test('one shared blob is counted once and a lease keeps it', () async {
    final data = Directory(p.join(workspace.path, 'library'));
    final root = Directory(p.join(data.path, 'artwork'));
    await Directory(p.join(root.path, 'blobs')).create(recursive: true);
    final blob = File(p.join(root.path, 'blobs', 'hash.png'));
    await blob.writeAsBytes([1, 2, 3, 4]);
    await blob.setLastModified(
      DateTime.now().subtract(const Duration(minutes: 30)),
    );
    createIndex(root);
    await File(p.join(root.path, 'index.sqlite-wal')).writeAsBytes([9]);
    final open = await scan(data);
    final image = open.files.singleWhere((file) => file.path == blob.path);
    expect(image.bytes, 4);
    expect(open.appBytes, greaterThanOrEqualTo(4));
    expect(
      open.files.where((file) => file.path == blob.path),
      hasLength(1),
    );
    expect(image.origin, StorageOrigin.shared);
    expect(image.sourceTags, contains(StorageOrigin.podcast));
    expect(image.ownerIds, containsAll(['ep-1', 'card-1']));
    expect(image.canDelete, isTrue);
    final index = open.files.firstWhere(
      (file) => p.basename(file.path) == 'index.sqlite',
    );
    expect(index.category, StorageCategory.metadata);
    expect(index.canDelete, isFalse);
    expect(
      open.files
          .firstWhere((file) => file.path.endsWith('index.sqlite-wal'))
          .canDelete,
      isFalse,
    );

    final database = sqlite3.open(p.join(root.path, 'index.sqlite'));
    database.execute(
      "INSERT INTO leases(request_key, lease_id) VALUES('req','lease-1')",
    );
    database.dispose();
    final leased = await scan(data);
    expect(
      leased.files.singleWhere((file) => file.path == blob.path).canDelete,
      isFalse,
    );
  });

  test('deleting a blob clears the hash but keeps the request identity', () async {
    final data = Directory(p.join(workspace.path, 'library'));
    final root = Directory(p.join(data.path, 'artwork'));
    await Directory(p.join(root.path, 'blobs')).create(recursive: true);
    final blob = File(p.join(root.path, 'blobs', 'hash.png'));
    await blob.writeAsBytes([1, 2, 3, 4]);
    final staging = File(p.join(root.path, 'staging', 'new.png'));
    await staging.parent.create(recursive: true);
    await staging.writeAsBytes([5]);
    await staging.setLastModified(
      DateTime.now().subtract(const Duration(minutes: 30)),
    );
    createIndex(root);
    final snapshot = await scan(data);
    expect(
      snapshot.files.singleWhere((file) => file.path == staging.path).canDelete,
      isTrue,
    );
    await blob.delete();
    final warnings = await correctDeletedStorageFiles(
      dataRoot: data,
      deletedPaths: [blob.path],
    );
    expect(warnings, isEmpty);
    final database = sqlite3.open(p.join(root.path, 'index.sqlite'));
    final blobs = database.select('SELECT * FROM blobs');
    final alias = database.select('SELECT blob_hash FROM aliases');
    final owners = database.select('SELECT * FROM owners');
    database.dispose();
    expect(blobs, isEmpty);
    expect(alias.single['blob_hash'], isNull);
    expect(owners, hasLength(2));
    expect(await File(p.join(root.path, 'index.sqlite')).exists(), isTrue);
  });

  test('a user-selected blob without a network adapter is kept', () async {
    final data = Directory(p.join(workspace.path, 'library'));
    final root = Directory(p.join(data.path, 'artwork'));
    await Directory(p.join(root.path, 'blobs')).create(recursive: true);
    final blob = File(p.join(root.path, 'blobs', 'hash.png'));
    await blob.writeAsBytes([1, 2, 3, 4]);
    await blob.setLastModified(
      DateTime.now().subtract(const Duration(minutes: 30)),
    );
    createIndex(root);
    final database = sqlite3.open(p.join(root.path, 'index.sqlite'));
    database.execute("UPDATE aliases SET adapter='', persistent=1");
    database.dispose();
    final snapshot = await scan(data);
    final image = snapshot.files.singleWhere((file) => file.path == blob.path);
    expect(image.canDelete, isFalse);
    expect(image.explicitDelete, isTrue);
  });
}
