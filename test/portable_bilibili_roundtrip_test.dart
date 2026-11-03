import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_models.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_service.dart';
import 'package:video_player_app/models/bilibili_video_shot.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'test_dir_cleanup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Bilibili online card round-trips with offline assets but without media cache',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      SettingsService().resetForTest();
      final root = await Directory.systemTemp.createTemp(
        'portable_bilibili_roundtrip_',
      );
      final originalPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProvider(root.path);
      SettingsService().largeDataRootPath = root.path;
      addTearDown(() async {
        PathProviderPlatform.instance = originalPathProvider;
        SettingsService().resetForTest();
        await deleteTestTempDir(root);
      });

      final cover = await File(
        p.join(root.path, 'cover.jpg'),
      ).writeAsString('cover');
      final subtitle = await File(
        p.join(root.path, 'online.zh-CN.srt'),
      ).writeAsString('1\n00:00:00,000 --> 00:00:01,000\n你好\n');
      final danmaku = await File(
        p.join(root.path, 'online.ass'),
      ).writeAsString('[Script Info]\nTitle: danmaku\n');
      final sprite = await File(
        p.join(root.path, 'sprite_000.jpg'),
      ).writeAsString('sprite');
      await File(
        p.join(root.path, 'materialized_playback_q80.mp4'),
      ).writeAsString('this must never be exported');
      await File(
        p.join(root.path, 'transcription_audio.m4a'),
      ).writeAsString('this must never be exported either');

      final library = LibraryService();
      await library.init();
      final collection = await library.createCollection('在线合集', null);
      const source = MediaSourceRef(
        value: 'BV1TESTCARD',
        kind: MediaSourceKind.bilibiliStream,
        originalValue: 'https://www.bilibili.com/video/BV1TESTCARD',
        bvid: 'BV1TESTCARD',
        aid: '123',
        cid: 456,
        page: 1,
      );
      final original = VideoItem(
        id: 'original-online-card',
        path: 'bilibili://stream/BV1TESTCARD?cid=456',
        title: '在线测试视频',
        thumbnailPath: cover.path,
        durationMs: 120000,
        lastPositionMs: 34567,
        subtitlePath: subtitle.path,
        additionalSubtitles: <String, String>{'中文': subtitle.path},
        danmakuPath: danmaku.path,
        lastUpdated: DateTime.now().millisecondsSinceEpoch,
        parentId: collection.id,
        sourceFingerprint: 'bilibili-stream-card:original-online-card',
        sourceRef: source,
        bilibiliVideoShot: BilibiliVideoShot(
          spritePaths: <String>[sprite.path],
          timestampsSeconds: const <int>[0],
          columns: 1,
          rows: 1,
          cellWidth: 160,
          cellHeight: 90,
        ),
        hasProbedChapters: true,
      );
      await library.addSingleVideo(original, reuseExistingItem: false);

      final package = p.join(root.path, 'online-card.fluentpack');
      final service = PortableTransferService.instance;
      final exportTask = await service.exportSelection(
        library: library,
        rootIds: <String>[collection.id],
        outputPath: package,
        options: const PortableExportOptions(
          packageName: '在线卡片迁移',
          includeSidecars: true,
          verifyChecksums: true,
        ),
      );
      await _waitForTask(exportTask);
      expect(exportTask.status, PortableTransferStatus.completed);

      final input = InputFileStream(package);
      final archive = ZipDecoder().decodeStream(input, verify: true);
      final names = archive.files.map((entry) => entry.name).toList();
      expect(names.any((name) => name.endsWith('cover.jpg')), isTrue);
      expect(names.any((name) => name.endsWith('.srt')), isTrue);
      expect(names.any((name) => name.endsWith('.ass')), isTrue);
      expect(names.any((name) => name.contains('videoshot')), isTrue);
      expect(
        names.any((name) => name.contains('materialized_playback')),
        isFalse,
      );
      expect(
        names.any((name) => name.contains('transcription_audio')),
        isFalse,
      );
      final manifestFile = archive.files.singleWhere(
        (entry) => p.posix.basename(entry.name) == 'manifest.json',
      );
      final manifest = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(manifestFile.content)) as Map,
      );
      final snapshot = Map<String, dynamic>.from(manifest['snapshot'] as Map);
      final exportedVideo = Map<String, dynamic>.from(
        (snapshot['videos'] as List).single as Map,
      );
      expect(exportedVideo['isOnline'], isTrue);
      expect(
        (exportedVideo['video'] as Map)['path'],
        'bilibili://stream/BV1TESTCARD?cid=456',
      );
      archive.clear();
      await input.close();

      final preview = await service.inspectPackage(package);
      final importTask = await service.importPackage(
        library: library,
        packagePath: package,
        preview: preview,
        deletePackageWhenDone: true,
      );
      await _waitForTask(importTask);
      expect(importTask.status, PortableTransferStatus.completed);
      expect(await File(package).exists(), isFalse);

      final cards = library.bilibiliStreamItems;
      expect(cards, hasLength(2));
      final restored = cards.singleWhere((item) => item.id != original.id);
      expect(restored.id, isNot(original.id));
      expect(restored.sourceFingerprint, 'bilibili-stream-card:${restored.id}');
      expect(restored.sourceRef?.bvid, source.bvid);
      expect(restored.sourceRef?.cid, source.cid);
      expect(restored.title, original.title);
      expect(restored.lastPositionMs, original.lastPositionMs);
      expect(await File(restored.thumbnailPath!).exists(), isTrue);
      expect(await File(restored.subtitlePath!).exists(), isTrue);
      expect(await File(restored.danmakuPath!).exists(), isTrue);
      expect(restored.bilibiliVideoShot?.hasLocalSprites, isTrue);

      final sameNamedCollections = _allCollections(
        library,
      ).where((item) => item.name == '在线合集').toList();
      expect(sameNamedCollections, hasLength(2));
      expect(sameNamedCollections.map((item) => item.id).toSet(), hasLength(2));
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}

Future<void> _waitForTask(PortableTransferTask task) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (task.isActive && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  if (task.isActive) throw TimeoutException('portable task did not finish');
  if (task.status == PortableTransferStatus.failed) {
    fail(task.error ?? task.subtitle);
  }
}

List<dynamic> _allCollections(LibraryService library) {
  final result = <dynamic>[];
  void visit(String? parentId) {
    for (final item in library.getContents(parentId)) {
      if (item is! VideoItem) {
        result.add(item);
        visit(item.id as String);
      }
    }
  }

  visit(null);
  return result;
}

class _FakePathProvider extends PathProviderPlatform {
  final String rootPath;

  _FakePathProvider(this.rootPath);

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;

  @override
  Future<String?> getTemporaryPath() async => rootPath;
}
