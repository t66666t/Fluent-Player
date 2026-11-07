import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/portable_transfer/portable_folder_transfer.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_service.dart';
import 'package:video_player_app/models/library_activity.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';

import 'test_dir_cleanup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late LibraryService library;
  late PortableTransferService service;
  late PortableFolderTransfer transfer;
  final originalProvider = PathProviderPlatform.instance;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('portable_folder_');
    PathProviderPlatform.instance = _Paths(temp.path);
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    SettingsService().largeDataRootPath = temp.path;
    library = LibraryService()..resetLibraryForTesting();
    await library.init();
    library.skipImportSidecarWorkForTesting = true;
    service = PortableTransferService.forTesting();
    transfer = PortableFolderTransfer(service: service);
  });

  tearDown(() async {
    service.dispose();
    library.resetLibraryForTesting();
    SettingsService().resetForTest();
    PathProviderPlatform.instance = originalProvider;
    await deleteTestTempDir(temp);
  });

  Future<VideoItem> addMedia(
    String parent,
    String name,
    List<int> bytes,
  ) async {
    final file = File(p.join(temp.path, '$name.mp4'));
    await file.writeAsBytes(bytes);
    final item = VideoItem(
      id: name,
      path: file.path,
      title: name,
      durationMs: 100000,
      lastPositionMs: 32000,
      lastUpdated: 1,
      parentId: parent,
      hasProbedChapters: true,
    );
    await library.addSingleVideo(item, useOriginalPath: true);
    return item;
  }

  Future<({String root, PortablePreparedFolderPackage package})>
  prepare() async {
    final folder = await library.createCollection('课程', null);
    final child = await library.createCollection('章节', folder.id);
    await addMedia(child.id, 'lesson', [1, 3, 5, 7, 9]);
    final package = await transfer.prepareFolderPackage(
      library: library,
      collectionId: folder.id,
      outputPath: p.join(temp.path, 'lesson.fluentpack'),
    );
    return (root: folder.id, package: package);
  }

  void becomeReceiver() {
    library.resetLibraryForTesting();
    library.skipImportSidecarWorkForTesting = true;
  }

  test(
    'received local video survives cleanup when desktop temp is outside the data directory',
    () async {
      final prepared = await prepare();
      final outside = await Directory.systemTemp.createTemp(
        'outside_media_data_',
      );
      PathProviderPlatform.instance = _SeparatedPaths(temp.path, outside.path);
      try {
        becomeReceiver();
        final received = await transfer.importReceivedFolder(
          library: library,
          packagePath: prepared.package.path,
          originDeviceId: 'android',
          sourceCollectionId: prepared.root,
        );
        final item = library.mediaInFolderTree(received.collectionId).single;
        expect(p.isWithin(outside.path, item.path), isFalse);
        expect(p.isWithin(temp.path, item.path), isTrue);
        expect(await File(item.path).readAsBytes(), [1, 3, 5, 7, 9]);
        expect(
          await Directory(
            p.join(outside.path, 'fluent_transfer'),
          ).list().isEmpty,
          isTrue,
        );
      } finally {
        await deleteTestTempDir(outside);
      }
    },
  );

  test(
    'direct received files move to permanent storage before publishing a card',
    () async {
      final folder = await library.createCollection('直接发送', null);
      await addMedia(folder.id, 'direct-local', [2, 4, 6, 8]);
      final direct = await transfer.prepareDirectFiles(
        library: library,
        collectionId: folder.id,
      );
      final outside = await Directory.systemTemp.createTemp(
        'direct_outside_data_',
      );
      final incoming = Directory(p.join(outside.path, 'received-originals'));
      try {
        final checksums = <String, String>{};
        for (final file in direct.files) {
          final target = File(
            p.joinAll([incoming.path, ...file.relativePath.split('/')]),
          );
          await target.parent.create(recursive: true);
          await File(file.path).copy(target.path);
          checksums[file.relativePath] = sha256
              .convert(await target.readAsBytes())
              .toString();
        }
        becomeReceiver();
        final received = await transfer.importReceivedFolder(
          library: library,
          packagePath: '',
          originDeviceId: 'android',
          sourceCollectionId: folder.id,
          receivedDirectory: incoming,
          receivedManifest: {...direct.manifest, 'checksums': checksums},
        );
        final item = library.mediaInFolderTree(received.collectionId).single;
        // The network receive directory stays until the transfer task commits.
        // Deleting it afterwards must not take the published original with it.
        expect(await incoming.exists(), isTrue);
        expect(p.isWithin(incoming.path, item.path), isFalse);
        expect(p.isWithin(outside.path, item.path), isFalse);
        expect(await File(item.path).readAsBytes(), [2, 4, 6, 8]);
        await incoming.delete(recursive: true);
        expect(await File(item.path).readAsBytes(), [2, 4, 6, 8]);
      } finally {
        await deleteTestTempDir(outside);
      }
    },
  );

  test('a missing original is an explicit unavailable result', () async {
    final folder = await library.createCollection('缺文件', null);
    final missing = VideoItem(
      id: 'gone',
      path: p.join(temp.path, 'missing.mp4'),
      title: 'gone',
      durationMs: 1000,
      lastUpdated: 1,
      parentId: folder.id,
      hasProbedChapters: true,
    );
    folder.childrenIds.add(missing.id);
    library.seedVideoForTesting(missing);
    final direct = await transfer.prepareDirectFiles(
      library: library,
      collectionId: folder.id,
    );
    expect(direct.files, isEmpty);
    expect(direct.manifest['unavailableCount'], 1);
    final results = direct.manifest['resourceResults'] as List;
    expect(results.single['result'], 'unavailable');
    expect((direct.manifest['snapshot'] as Map)['videos'], isEmpty);
  });

  test('a downloaded Bilibili file is transferred as local bytes', () async {
    final folder = await library.createCollection('本地下载', null);
    final file = File(p.join(temp.path, 'local-bili.mp4'));
    await file.writeAsBytes([9, 8, 7, 6]);
    final item = VideoItem(
      id: 'local-bili',
      path: file.path,
      title: 'local-bili',
      durationMs: 1000,
      lastUpdated: 1,
      parentId: folder.id,
      hasProbedChapters: true,
      sourceRef: const MediaSourceRef(
        value: 'BV1xx',
        kind: MediaSourceKind.bilibiliStream,
        bvid: 'BV1xx',
        cid: 12,
      ),
    );
    await library.addSingleVideo(item, useOriginalPath: true);
    final direct = await transfer.prepareDirectFiles(
      library: library,
      collectionId: folder.id,
    );
    expect(direct.files, isNotEmpty);
    expect(direct.manifest['unavailableCount'], 0);
    final videos = (direct.manifest['snapshot'] as Map)['videos'] as List;
    expect(videos.single['isOnline'], isNot(true));
  });

  test(
    'estimates assets without hashing and stores verified fluentpack media',
    () async {
      final folder = await library.createCollection('课程', null);
      final media = await addMedia(folder.id, 'lesson', [1, 2, 3, 4, 5]);
      final estimate = await transfer.estimateFolder(
        library: library,
        collectionId: folder.id,
      );
      expect(estimate.name, '课程');
      expect(estimate.mediaCount, 1);
      expect(estimate.folderCount, 1);
      expect(estimate.totalBytes, 5);
      final package = await transfer.prepareFolderPackage(
        library: library,
        collectionId: folder.id,
        outputPath: p.join(temp.path, 'test.fluentpack'),
      );
      expect(
        package.fingerprints[media.id]?.sha256,
        sha256.convert([1, 2, 3, 4, 5]).toString(),
      );
      final input = InputFileStream(package.path);
      final archive = ZipDecoder().decodeStream(input);
      final video = archive.files.singleWhere(
        (file) => file.name.endsWith('.mp4'),
      );
      expect(video.compression, CompressionType.none);
      archive.clear();
      await input.close();
    },
  );

  test(
    'receives one folder preserving tree and resetting progress for sync',
    () async {
      final source = await prepare();
      becomeReceiver();
      final result = await transfer.importReceivedFolder(
        library: library,
        packagePath: source.package.path,
        originDeviceId: 'laptop',
        sourceCollectionId: source.root,
      );
      final root = library.getCollection(result.collectionId)!;
      expect(root.name, '课程');
      expect(root.parentId, isNull);
      expect(library.storageCollections.length, 2);
      final children = library.getContents(root.id);
      expect(children.length, 1);
      final videos = library.mediaInFolderTree(root.id);
      expect(videos.length, 1);
      expect(await File(videos.single.path).readAsBytes(), [1, 3, 5, 7, 9]);
      expect(videos.single.lastPositionMs, 0);
      expect(result.importedMediaCount, 1);
      expect(result.sourceToLocalIds[source.root], root.id);
      expect(
        result.fingerprints[videos.single.id]?.sha256,
        sha256.convert([1, 3, 5, 7, 9]).toString(),
      );
    },
  );

  test(
    'repeat receipt after service restart reuses IDs and receiver progress',
    () async {
      final source = await prepare();
      becomeReceiver();
      final first = await transfer.importReceivedFolder(
        library: library,
        packagePath: source.package.path,
        originDeviceId: 'laptop',
        sourceCollectionId: source.root,
      );
      final video = library.mediaInFolderTree(first.collectionId).single;
      video.lastPositionMs = 65000;
      library.seedMediaActivityForTesting(
        MediaActivityRecord(
          mediaId: video.id,
          addedAtMs: 4,
          lastPlayedAtMs: 9,
          completed: true,
          continueEnrolled: true,
        ),
      );
      final nextService = PortableTransferService.forTesting();
      final second = await PortableFolderTransfer(service: nextService)
          .importReceivedFolder(
            library: library,
            packagePath: source.package.path,
            originDeviceId: 'laptop',
            sourceCollectionId: source.root,
          );
      expect(second.collectionId, first.collectionId);
      expect(second.sourceToLocalIds, first.sourceToLocalIds);
      expect(second.importedMediaCount, 0);
      expect(second.skippedMediaCount, 1);
      expect(library.getVideo(video.id)?.lastPositionMs, 65000);
      expect(library.storageCollections.length, 2);
      nextService.dispose();
    },
  );

  test(
    'existing target full-content match skips a renamed local file',
    () async {
      final source = await prepare();
      becomeReceiver();
      final target = await library.createCollection('我的课程', null);
      final child = await library.createCollection('章节', target.id);
      final local = await addMedia(child.id, 'renamed', [1, 3, 5, 7, 9]);
      local.lastPositionMs = 19000;
      final result = await transfer.importReceivedFolder(
        library: library,
        packagePath: source.package.path,
        originDeviceId: 'laptop',
        sourceCollectionId: source.root,
        existingTargetCollectionId: target.id,
      );
      expect(result.collectionId, target.id);
      expect(result.importedMediaCount, 0);
      expect(result.skippedMediaCount, 1);
      expect(library.mediaInFolderTree(target.id).single.id, local.id);
      expect(library.getVideo(local.id)?.lastPositionMs, 19000);
      expect(library.getCollection(target.id)?.name, '我的课程');
    },
  );

  test(
    'failed append rolls back new records without removing existing target',
    () async {
      final source = await prepare();
      becomeReceiver();
      final target = await library.createCollection('保留', null);
      final keep = await addMedia(target.id, 'keep', [99, 98]);
      library.failAddSingleVideoAfterInsertForTesting = true;
      await expectLater(
        transfer.importReceivedFolder(
          library: library,
          packagePath: source.package.path,
          originDeviceId: 'laptop',
          sourceCollectionId: source.root,
          existingTargetCollectionId: target.id,
        ),
        throwsStateError,
      );
      expect(library.getCollection(target.id)?.name, '保留');
      expect(library.mediaInFolderTree(target.id).map((e) => e.id), [keep.id]);
      expect(library.collections.length, 1);
      expect(await File(keep.path).readAsBytes(), [99, 98]);
    },
  );

  test(
    'cancel before prepare or receipt leaves no folder or partial file',
    () async {
      final source = await prepare();
      await expectLater(
        transfer.prepareFolderPackage(
          library: library,
          collectionId: source.root,
          outputPath: p.join(temp.path, 'cancel.fluentpack'),
          isCancelled: () => true,
        ),
        throwsA(isA<PortableExportCancelled>()),
      );
      expect(
        await File(p.join(temp.path, 'cancel.fluentpack.part')).exists(),
        false,
      );
      becomeReceiver();
      await expectLater(
        transfer.importReceivedFolder(
          library: library,
          packagePath: source.package.path,
          originDeviceId: 'laptop',
          sourceCollectionId: source.root,
          isCancelled: () => true,
        ),
        throwsA(isA<PortableExportCancelled>()),
      );
      expect(library.collections, isEmpty);
    },
  );

  test(
    'snapshot source-root mismatch is rejected before changing library',
    () async {
      final source = await prepare();
      becomeReceiver();
      await expectLater(
        transfer.importReceivedFolder(
          library: library,
          packagePath: source.package.path,
          originDeviceId: 'laptop',
          sourceCollectionId: 'different-root',
        ),
        throwsFormatException,
      );
      expect(library.collections, isEmpty);
    },
  );

  test('retired Bilibili cards are not recreated by folder transfer', () async {
    final folder = await library.createCollection('在线', null);
    final online = VideoItem(
      id: 'online',
      path: 'bilibili://stream/BVexample?cid=12',
      title: 'Online',
      durationMs: 10000,
      lastUpdated: 1,
      parentId: folder.id,
      sourceRef: const MediaSourceRef(
        value: 'BVexample',
        kind: MediaSourceKind.bilibiliStream,
        bvid: 'BVexample',
        cid: 12,
      ),
    );
    await library.addSingleVideo(online, useOriginalPath: true);
    final estimate = await transfer.estimateFolder(
      library: library,
      collectionId: folder.id,
    );
    expect(estimate.totalBytes, 0);
    final package = await transfer.prepareFolderPackage(
      library: library,
      collectionId: folder.id,
      outputPath: p.join(temp.path, 'online.fluentpack'),
    );
    becomeReceiver();
    final result = await transfer.importReceivedFolder(
      library: library,
      packagePath: package.path,
      originDeviceId: 'laptop',
      sourceCollectionId: folder.id,
    );
    expect(library.mediaInFolderTree(result.collectionId), isEmpty);
    expect(result.fingerprints, isEmpty);
  });
  test(
    'same-named distinct subfolders preserve their separate trees',
    () async {
      final folder = await library.createCollection('课程', null);
      final first = await library.createCollection('章节', folder.id);
      final second = await library.createCollection('章节', folder.id);
      await addMedia(first.id, 'first', [1, 2, 3]);
      await addMedia(second.id, 'second', [4, 5, 6]);
      final package = await transfer.prepareFolderPackage(
        library: library,
        collectionId: folder.id,
        outputPath: p.join(temp.path, 'twins.fluentpack'),
      );
      becomeReceiver();
      final result = await transfer.importReceivedFolder(
        library: library,
        packagePath: package.path,
        originDeviceId: 'laptop',
        sourceCollectionId: folder.id,
      );
      final children = library.getContents(result.collectionId);
      expect(children.length, 2);
      expect(
        result.sourceToLocalIds[first.id],
        isNot(result.sourceToLocalIds[second.id]),
      );
      expect(library.mediaInFolderTree(result.collectionId).length, 2);
    },
  );

  test(
    'same name with different full content is added rather than skipped',
    () async {
      final source = await prepare();
      becomeReceiver();
      final target = await library.createCollection('课程', null);
      final child = await library.createCollection('章节', target.id);
      final old = await addMedia(child.id, 'lesson', [9, 7, 5, 3, 1]);
      final result = await transfer.importReceivedFolder(
        library: library,
        packagePath: source.package.path,
        originDeviceId: 'laptop',
        sourceCollectionId: source.root,
        existingTargetCollectionId: target.id,
      );
      expect(result.skippedMediaCount, 0);
      expect(result.importedMediaCount, 1);
      expect(library.mediaInFolderTree(target.id).length, 2);
      expect(library.getVideo(old.id)?.lastPositionMs, 32000);
    },
  );

  test('cancel during append rolls back only this delivery', () async {
    final source = await prepare();
    becomeReceiver();
    final target = await library.createCollection('保留', null);
    final keep = await addMedia(target.id, 'keep', [7]);
    var cancelled = false;
    await expectLater(
      transfer.importReceivedFolder(
        library: library,
        packagePath: source.package.path,
        originDeviceId: 'laptop',
        sourceCollectionId: source.root,
        existingTargetCollectionId: target.id,
        isCancelled: () => cancelled,
        onProgress: (_, status) {
          if (status.startsWith('正在恢复卡片')) cancelled = true;
        },
      ),
      throwsA(isA<PortableExportCancelled>()),
    );
    expect(library.getCollection(target.id), isNotNull);
    expect(library.mediaInFolderTree(target.id).map((item) => item.id), [
      keep.id,
    ]);
    expect(library.storageCollections.length, 1);
  });

  test('tampered media fails checksum before creating a destination', () async {
    final source = await prepare();
    final stream = InputFileStream(source.package.path);
    final decoded = ZipDecoder().decodeStream(stream);
    final target = File(p.join(temp.path, 'tampered.fluentpack'));
    final encoder = ZipFileEncoder()..create(target.path);
    for (final entry in decoded.files) {
      final bytes = entry.name.endsWith('.mp4')
          ? [0, 0, 0, 0, 0]
          : entry.content;
      encoder.addArchiveFile(ArchiveFile(entry.name, bytes.length, bytes));
    }
    await encoder.close();
    decoded.clear();
    await stream.close();
    becomeReceiver();
    await expectLater(
      transfer.importReceivedFolder(
        library: library,
        packagePath: target.path,
        originDeviceId: 'laptop',
        sourceCollectionId: source.root,
      ),
      throwsFormatException,
    );
    expect(library.storageCollections, isEmpty);
  });

  test('simultaneous redeliveries serialize into one stable folder', () async {
    final source = await prepare();
    becomeReceiver();
    final results = await Future.wait(
      List.generate(
        2,
        (_) => transfer.importReceivedFolder(
          library: library,
          packagePath: source.package.path,
          originDeviceId: 'laptop',
          sourceCollectionId: source.root,
        ),
      ),
    );
    expect(results[0].collectionId, results[1].collectionId);
    expect(results.map((item) => item.importedMediaCount), [1, 0]);
    expect(library.storageCollections.length, 2);
    expect(library.mediaInFolderTree(results[0].collectionId).length, 1);
  });
  test(
    'delta omits existing large media and orphan assets, then adds only new media',
    () async {
      final folder = await library.createCollection('课程', null);
      final child = await library.createCollection('章节', folder.id);
      final big = await addMedia(
        child.id,
        'large',
        List<int>.generate(4 * 1024 * 1024, (i) => i % 251),
      );
      final subtitle = File(p.join(temp.path, 'old-only.srt'));
      await subtitle.writeAsString(List.filled(8000, 'old subtitle').join());
      big.subtitlePath = subtitle.path;
      final full = await transfer.prepareFolderPackage(
        library: library,
        collectionId: folder.id,
        outputPath: p.join(temp.path, 'full.fluentpack'),
      );
      final first = await transfer.importReceivedFolder(
        library: library,
        packagePath: full.path,
        originDeviceId: 'laptop',
        sourceCollectionId: folder.id,
      );
      final local = library.mediaInFolderTree(first.collectionId).single;
      local.lastPositionMs = 88000;
      final newMedia = await addMedia(child.id, 'new-lesson', [3, 4, 5, 6]);
      final oldFingerprint = full.fingerprints[big.id]!;
      int? payloadBytes;
      final deltaPath = p.join(temp.path, 'delta.fluentpack');
      final delta = await transfer.prepareFolderPackage(
        library: library,
        collectionId: folder.id,
        outputPath: deltaPath,
        skipContentKeys: {
          'sha256:${oldFingerprint.size}:${oldFingerprint.sha256}',
        },
        knownFingerprints: full.fingerprints,
        onPayloadSize: (bytes) async {
          payloadBytes = bytes;
          expect(await File(deltaPath).exists(), false);
        },
      );
      expect(payloadBytes, 4);
      expect(delta.mediaCount, 1);
      expect(delta.totalBytes, lessThan(16000));
      expect(delta.fingerprints.keys, containsAll([big.id, newMedia.id]));
      final contents = await _packageContents(delta.path);
      expect(contents.names.any((name) => name.endsWith('large.mp4')), false);
      expect(
        contents.names.any((name) => name.endsWith('old-only.srt')),
        false,
      );
      expect(
        (contents.manifest['snapshot'] as Map)['collections'],
        hasLength(2),
      );
      final received = await transfer.importReceivedFolder(
        library: library,
        packagePath: delta.path,
        originDeviceId: 'laptop',
        sourceCollectionId: folder.id,
        existingTargetCollectionId: first.collectionId,
      );
      expect(received.importedMediaCount, 1);
      expect(library.mediaInFolderTree(first.collectionId), hasLength(2));
      expect(library.getVideo(local.id)?.lastPositionMs, 88000);
      final again = await transfer.importReceivedFolder(
        library: library,
        packagePath: delta.path,
        originDeviceId: 'laptop',
        sourceCollectionId: folder.id,
        existingTargetCollectionId: first.collectionId,
      );
      expect(again.importedMediaCount, 0);
      expect(library.mediaInFolderTree(first.collectionId), hasLength(2));
    },
  );

  test(
    'zero-payload delta preserves logical media using the existing target resource',
    () async {
      final source = await prepare();
      final first = await transfer.importReceivedFolder(
        library: library,
        packagePath: source.package.path,
        originDeviceId: 'laptop',
        sourceCollectionId: source.root,
      );
      final fingerprint = source.package.fingerprints['lesson']!;
      final delta = await transfer.prepareFolderPackage(
        library: library,
        collectionId: source.root,
        outputPath: p.join(temp.path, 'zero.fluentpack'),
        skipContentKeys: {'sha256:${fingerprint.size}:${fingerprint.sha256}'},
        knownFingerprints: source.package.fingerprints,
      );
      expect(delta.mediaCount, 0);
      expect(delta.totalBytes, lessThan(8000));
      final contents = await _packageContents(delta.path);
      expect(contents.names, ['manifest.json']);
      expect(contents.manifest['checksums'], isEmpty);
      final received = await transfer.importReceivedFolder(
        library: library,
        packagePath: delta.path,
        originDeviceId: 'laptop',
        sourceCollectionId: source.root,
        existingTargetCollectionId: first.collectionId,
      );
      expect(received.importedMediaCount, 0);
      expect(received.collectionId, first.collectionId);
      expect(library.mediaInFolderTree(received.collectionId), hasLength(1));
      expect((contents.manifest['snapshot'] as Map)['videos'], hasLength(1));
    },
  );

  test(
    'delta retains a shared asset still referenced by a newly sent card',
    () async {
      final folder = await library.createCollection('课程', null);
      final old = await addMedia(folder.id, 'old', [1, 2, 3, 4]);
      final fresh = await addMedia(folder.id, 'fresh', [5, 6, 7, 8]);
      final shared = File(p.join(temp.path, 'shared.srt'));
      await shared.writeAsString('shared subtitle');
      old.subtitlePath = shared.path;
      fresh.subtitlePath = shared.path;
      final initial = await transfer.prepareFolderPackage(
        library: library,
        collectionId: folder.id,
        outputPath: p.join(temp.path, 'old.fluentpack'),
        includeMediaIds: {old.id},
      );
      final first = await transfer.importReceivedFolder(
        library: library,
        packagePath: initial.path,
        originDeviceId: 'laptop',
        sourceCollectionId: folder.id,
      );
      final hash = sha256.convert([1, 2, 3, 4]).toString();
      final delta = await transfer.prepareFolderPackage(
        library: library,
        collectionId: folder.id,
        outputPath: p.join(temp.path, 'shared.fluentpack'),
        skipContentKeys: {'sha256:4:$hash'},
      );
      expect(delta.mediaCount, 1);
      final contents = await _packageContents(delta.path);
      expect(contents.names.any((name) => name.endsWith('shared.srt')), true);
      final received = await transfer.importReceivedFolder(
        library: library,
        packagePath: delta.path,
        originDeviceId: 'laptop',
        sourceCollectionId: folder.id,
        existingTargetCollectionId: first.collectionId,
      );
      final media = library.getVideo(received.sourceToLocalIds[fresh.id]!)!;
      expect(await File(media.subtitlePath!).readAsString(), 'shared subtitle');
      expect(await File(media.path).readAsBytes(), [5, 6, 7, 8]);
    },
  );

  test(
    'stale source fingerprint cannot omit changed content at the same path',
    () async {
      final source = await prepare();
      final old = source.package.fingerprints['lesson']!;
      await File(old.path).writeAsBytes([9, 9, 9, 9, 9]);
      await File(old.path).setLastModified(
        DateTime.fromMillisecondsSinceEpoch(old.modifiedMs + 1000),
      );
      final delta = await transfer.prepareFolderPackage(
        library: library,
        collectionId: source.root,
        outputPath: p.join(temp.path, 'changed.fluentpack'),
        skipContentKeys: {'sha256:${old.size}:${old.sha256}'},
        knownFingerprints: source.package.fingerprints,
      );
      expect(delta.mediaCount, 1);
      expect(
        delta.fingerprints['lesson']?.sha256,
        sha256.convert([9, 9, 9, 9, 9]).toString(),
      );
      becomeReceiver();
      final received = await transfer.importReceivedFolder(
        library: library,
        packagePath: delta.path,
        originDeviceId: 'laptop',
        sourceCollectionId: source.root,
      );
      expect(
        await File(
          library.mediaInFolderTree(received.collectionId).single.path,
        ).readAsBytes(),
        [9, 9, 9, 9, 9],
      );
    },
  );

  test(
    'receiver inventory of a corrupted same-path file does not skip the valid source',
    () async {
      final source = await prepare();
      final first = await transfer.importReceivedFolder(
        library: library,
        packagePath: source.package.path,
        originDeviceId: 'laptop',
        sourceCollectionId: source.root,
      );
      final local = library.mediaInFolderTree(first.collectionId).single;
      await File(local.path).writeAsBytes([8, 8, 8, 8, 8]);
      final currentHash = (await sha256.bind(File(local.path).openRead()).first)
          .toString();
      final delta = await transfer.prepareFolderPackage(
        library: library,
        collectionId: source.root,
        outputPath: p.join(temp.path, 'repair.fluentpack'),
        skipContentKeys: {'sha256:5:$currentHash'},
        knownFingerprints: source.package.fingerprints,
      );
      expect(delta.mediaCount, 1);
      final result = await transfer.importReceivedFolder(
        library: library,
        packagePath: delta.path,
        originDeviceId: 'laptop',
        sourceCollectionId: source.root,
        existingTargetCollectionId: first.collectionId,
      );
      expect(result.importedMediaCount, 1);
      final intact = library.mediaInFolderTree(first.collectionId).single;
      expect(intact.id, local.id);
      expect(await File(intact.path).readAsBytes(), [1, 3, 5, 7, 9]);
    },
  );
  test(
    'network import protects extraction directories through success and cancellation',
    () async {
      final source = await prepare();
      for (final cancelDuringImport in [false, true]) {
        becomeReceiver();
        final observed = <String>{};
        final lifecycle = <Set<String>>[];
        void changed() {
          final active = service.storageTemporaryDirectoriesInUse;
          observed.addAll(active);
          lifecycle.add(active);
          for (final path in active) {
            expect(
              p.isWithin(p.join(temp.path, 'fluent_transfer'), path),
              true,
            );
            expect(Directory(path).existsSync(), true);
          }
        }

        service.addListener(changed);
        var cancelled = false;
        final operation = transfer.importReceivedFolder(
          library: library,
          packagePath: source.package.path,
          originDeviceId: cancelDuringImport ? 'other-device' : 'laptop',
          sourceCollectionId: source.root,
          isCancelled: () => cancelled,
          onProgress: (_, status) {
            expect(service.storageTemporaryDirectoriesInUse, isNotEmpty);
            if (cancelDuringImport && status.startsWith('正在恢复卡片')) {
              cancelled = true;
            }
          },
        );
        try {
          if (cancelDuringImport) {
            await expectLater(
              operation,
              throwsA(isA<PortableExportCancelled>()),
            );
          } else {
            await operation;
          }
        } finally {
          service.removeListener(changed);
        }
        expect(observed, hasLength(1));
        expect(lifecycle.any((active) => active.isNotEmpty), true);
        expect(lifecycle.last, isEmpty);
        expect(service.storageTemporaryDirectoriesInUse, isEmpty);
        expect(service.tasks, isEmpty);
        for (final path in observed) {
          expect(await Directory(path).exists(), false);
        }
      }
    },
  );
}

Future<({List<String> names, Map<String, dynamic> manifest})> _packageContents(
  String path,
) async {
  final input = InputFileStream(path);
  final archive = ZipDecoder().decodeStream(input);
  try {
    final manifest = archive.files.singleWhere(
      (file) => file.name == 'manifest.json',
    );
    return (
      names: archive.files.map((file) => file.name).toList(),
      manifest:
          jsonDecode(utf8.decode(manifest.content)) as Map<String, dynamic>,
    );
  } finally {
    archive.clear();
    await input.close();
  }
}

class _Paths extends PathProviderPlatform {
  final String root;
  _Paths(this.root);
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getDownloadsPath() async => root;
}

class _SeparatedPaths extends _Paths {
  _SeparatedPaths(super.root, this.temporary);
  final String temporary;
  @override
  Future<String?> getTemporaryPath() async => temporary;
}
