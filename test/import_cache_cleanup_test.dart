import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/services/import_cache_cleanup.dart';

void main() {
  late Directory root;
  late Directory cache;
  late File source;
  late File persisted;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('import_cache_release_test_');
    cache = await Directory(p.join(root.path, 'cache')).create();
    source = File(p.join(cache.path, 'file_picker', 'pick', 'video.mp4'));
    await source.parent.create(recursive: true);
    await source.writeAsBytes([1, 2, 3]);
    persisted = await source.copy(p.join(root.path, 'library_video.mp4'));
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });
  Future<bool> release({bool referenced = false, String? sourcePath}) =>
      releaseVerifiedImportCacheCopy(
        sourcePath: sourcePath ?? source.path,
        persistedPath: persisted.path,
        cacheRoots: [cache],
        scopedRoots: true,
        isReferenced: (_) => referenced,
      );

  test(
    'only verified source copy is removed; persisted media and sibling remain',
    () async {
      final sibling = await File(
        p.join(source.parent.path, 'other.mp4'),
      ).writeAsBytes([9]);
      expect(await release(), true);
      expect(await source.exists(), false);
      expect(await persisted.readAsBytes(), [1, 2, 3]);
      expect(await sibling.exists(), true);
    },
  );
  test('reference to cache media keeps the original', () async {
    expect(await release(referenced: true), false);
    expect(await source.exists(), true);
  });
  test('failed or truncated copy never releases source', () async {
    await persisted.writeAsBytes([1]);
    expect(await release(), false);
    expect(await source.exists(), true);
  });
  test('file outside known cache scope stays untouched', () async {
    final outside = await File(
      p.join(cache.path, 'other.mp4'),
    ).writeAsBytes([1, 2, 3]);
    expect(await release(sourcePath: outside.path), false);
    expect(await outside.exists(), true);
  });
  test('same path is never deleted', () async {
    expect(
      await releaseVerifiedImportCacheCopy(
        sourcePath: source.path,
        persistedPath: source.path,
        cacheRoots: [cache],
        scopedRoots: false,
        isReferenced: (_) => false,
      ),
      false,
    );
    expect(await source.exists(), true);
  });
}
