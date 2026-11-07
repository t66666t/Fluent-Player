import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/services/storage_audit_models.dart';
import 'package:video_player_app/services/storage_audit_service.dart';

void main() {
  late Directory sandbox;
  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('storage_classification_');
  });
  tearDown(() async {
    await sandbox.delete(recursive: true);
  });

  Future<File> write(String relative) async {
    final file = File(p.joinAll([sandbox.path, ...relative.split('/')]));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List.filled(17, 1));
    return file;
  }

  test(
    'cache cleanup preserves exports, saved covers, media and OCR models',
    () async {
      final saved = [
        await write('portable_transfer/lesson.fluentpack'),
        await write('imported_videos/original.mp4'),
        await write('subtitles/unlinked.srt'),
        await write('yt_dlp_downloads/finished.mp4'),
        await write('thumbnails/selected-cover.jpg'),
        await write('ocr_models/det.onnx'),
      ];
      final cache = [
        await write('chapter_thumbnails/scene.jpg'),
        await write('ocr_temp/frame.png'),
      ];
      final input = StorageScanInput(
        roots: [StorageRoot(sandbox.path, 'data', StorageRootKind.data)],
      );
      final service = StorageAuditService(
        buildInput: () async => input,
        deletionBlockedReason: () => null,
      );
      addTearDown(service.dispose);
      final snapshot = await service.scan();
      for (final file in snapshot.files.where(
        (entry) => saved.any((file) => file.path == entry.path),
      )) {
        expect(file.canDelete, isTrue, reason: file.path);
        expect(
          storageDeletionPermitted(StorageCleanupAction.clearCache, file),
          isFalse,
          reason: file.path,
        );
      }
      final result = await service.delete(
        StorageDeletionPlan(
          snapshot.files,
          action: StorageCleanupAction.clearCache,
        ),
      );
      expect(
        result.deletedPaths,
        unorderedEquals(cache.map((file) => file.path)),
      );
      expect(result.skipped, hasLength(saved.length));
      for (final file in saved) {
        expect(await file.exists(), isTrue, reason: file.path);
      }
      expect(service.lastSnapshot!.appBytes, 17 * saved.length);
    },
  );

  test(
    'Agent journals and managed media workspaces retain their purpose',
    () async {
      final records = [
        await write('external_ai/actions-v1.json'),
        await write('external_ai/actions-v1.json.bak'),
        await write('external_ai/actions-v1.json.tmp'),
      ];
      final work = await write('protected_media_workspaces_v1/task/audio.wav');
      final snapshot = await scanStorageFiles(
        StorageScanInput(
          roots: [
            StorageRoot(
              sandbox.path,
              'data',
              StorageRootKind.data,
              scoped: true,
            ),
          ],
        ),
      );
      expect(snapshot.files, hasLength(4));
      for (final file in snapshot.files) {
        expect(
          file.category,
          records.any((record) => record.path == file.path)
              ? StorageCategory.metadata
              : StorageCategory.workTemp,
        );
        expect(file.canDelete, isFalse, reason: file.path);
        expect(file.explicitDelete, isFalse, reason: file.path);
      }
      expect(snapshot.files.any((file) => file.path == work.path), isTrue);
    },
  );

  test(
    'origins follow logical roots rather than unrelated absolute path names',
    () async {
      final examples = <String, StorageOrigin>{
        'downloads/bilibili/files/a.mp4': StorageOrigin.bilibili,
        'downloads/douyin/files/a.mp4': StorageOrigin.douyin,
        'downloads/web/files/a.mp4': StorageOrigin.web,
        'downloads/yt_dlp/files/a.mp4': StorageOrigin.ytDlp,
        'web_media_downloads/a.mp4': StorageOrigin.web,
        'douyin_browser/Default/History': StorageOrigin.douyin,
        'external_ai/actions-v1.json': StorageOrigin.appData,
        'imported_media/bilibili-holiday.mp4': StorageOrigin.localMedia,
        'personal_bilibili_export.bin': StorageOrigin.unknown,
      };
      for (final path in examples.keys) {
        await write(path);
      }
      final snapshot = await scanStorageFiles(
        StorageScanInput(
          roots: [StorageRoot(sandbox.path, 'data', StorageRootKind.data)],
        ),
      );
      for (final file in snapshot.files) {
        final relative = p
            .relative(file.path, from: sandbox.path)
            .replaceAll('\\', '/');
        expect(file.origin, examples[relative], reason: relative);
      }
      final renamed = await write('historical-destination/files/a.mp4');
      final restored = await scanStorageFiles(
        StorageScanInput(
          roots: [
            StorageRoot(
              renamed.parent.parent.path,
              'restored',
              StorageRootKind.data,
              feature: 'web_media_downloads',
            ),
          ],
        ),
      );
      expect(restored.files.single.origin, StorageOrigin.web);
    },
  );

  test(
    'models and their partial downloads keep their category across roots',
    () async {
      final paths = [
        'local_models/asr-revision/model.int8.onnx',
        'local_models/asr-revision/tokens.txt',
        'local_models/asr-revision/installed.json',
        'local_models/translation-revision/model.bin.part',
        'local_models/translation-revision/tokenizer.json.import',
        'local_models/enhancement-revision/vocab.json',
        'local_models/silero_vad.onnx',
      ];
      for (final path in paths) {
        await write(path);
      }
      for (final scoped in [false, true]) {
        for (final registered in [false, true]) {
          final snapshot = await scanStorageFiles(
            StorageScanInput(
              roots: [
                StorageRoot(
                  sandbox.path,
                  'data',
                  StorageRootKind.data,
                  scoped: scoped,
                ),
                if (registered)
                  StorageRoot(
                    p.join(sandbox.path, 'local_models'),
                    'registered models',
                    StorageRootKind.data,
                    feature: 'local_models',
                  ),
              ],
            ),
          );
          expect(snapshot.files, hasLength(paths.length));
          expect(snapshot.appBytes, 17 * paths.length);
          expect(snapshot.clearableBytes, 0);
          for (final file in snapshot.files) {
            expect(file.category, StorageCategory.models, reason: file.path);
            expect(file.canDelete, isFalse);
            expect(file.explicitDelete, isFalse);
            expect(file.cleanupPolicy, StorageCleanupPolicy.featureManaged);
          }
        }
      }
    },
  );

  test(
    'renamed registered feature roots preserve all existing folder rules',
    () async {
      final examples = <String, (String, StorageCategory, bool)>{
        'local_models': ('model.onnx.part', StorageCategory.models, false),
        'model_jobs': ('asr-key.json.tmp', StorageCategory.metadata, false),
        'ocr_models': ('det.onnx', StorageCategory.models, true),
        'ocr_temp': ('frame.png', StorageCategory.workTemp, true),
        'yt_dlp': ('python/python.exe', StorageCategory.models, false),
        'thumbnails': ('cover.jpg', StorageCategory.thumbnails, true),
        'subtitles': ('lost.srt', StorageCategory.orphaned, true),
        'downloads': (
          'web/tasks/task/file.part',
          StorageCategory.downloadTemp,
          false,
        ),
        'imported_videos': ('lost.mp4', StorageCategory.orphaned, true),
        'exports': ('movie.mp4', StorageCategory.transfer, false),
        'portable_transfer': (
          'nearby/task/receive.json',
          StorageCategory.transfer,
          true,
        ),
        'podcasts': ('podcasts.sqlite', StorageCategory.metadata, false),
        'cloud_drive_material': (
          'task/media.bin',
          StorageCategory.materialized,
          false,
        ),
        'cloud_drive_subtitles': ('sub.srt', StorageCategory.subtitles, false),
      };
      var index = 0;
      final roots = <StorageRoot>[];
      final expected = <String, (StorageCategory, bool)>{};
      for (final entry in examples.entries) {
        final directory = 'restored-${index++}';
        final file = await write('$directory/${entry.value.$1}');
        roots.add(
          StorageRoot(
            p.join(sandbox.path, directory),
            'unlabelled historical root',
            StorageRootKind.data,
          ),
        );
        roots.add(
          StorageRoot(
            p.join(sandbox.path, directory),
            'registered ${entry.key}',
            StorageRootKind.data,
            feature: entry.key,
          ),
        );
        expected[file.path] = (entry.value.$2, entry.value.$3);
      }
      final snapshot = await scanStorageFiles(StorageScanInput(roots: roots));
      expect(snapshot.files, hasLength(expected.length));
      for (final file in snapshot.files) {
        expect(
          (file.category, file.canDelete),
          expected[file.path],
          reason: file.path,
        );
      }
    },
  );

  test(
    'new feature files are separated from downloads and temporary material',
    () async {
      final examples = <String, StorageCategory>{
        'model_center.json': StorageCategory.metadata,
        'model_center.json.bak.tmp': StorageCategory.metadata,
        'model_jobs/asr-key.json.appendlog': StorageCategory.metadata,
        'model_jobs/translation-key.diagnostic.json.tmp':
            StorageCategory.metadata,
        'model_jobs/service-probe-123.wav': StorageCategory.workTemp,
        'model_jobs/asr-gpu-run-123/cache.bin': StorageCategory.workTemp,
        'model_jobs/asr-benchmark-123/vad.onnx': StorageCategory.workTemp,
        'batch_import_state.json': StorageCategory.metadata,
        'batch_import_cache.json.bak': StorageCategory.metadata,
        'bilibili_download_tasks.json.tmp': StorageCategory.metadata,
        'network_settings_v1.json.bak.tmp': StorageCategory.metadata,
        'playback_state_snapshot.json.tmp': StorageCategory.metadata,
        'progress_sync_v1.enc.tmp': StorageCategory.metadata,
        'shared_preferences.json': StorageCategory.metadata,
        'subtitle_fonts/user.ttf': StorageCategory.metadata,
        'web_media_browser/Default/Cookies': StorageCategory.metadata,
        'web_media_chromium/Default/History': StorageCategory.metadata,
        'douyin_browser/Default/Cookies': StorageCategory.metadata,
        'douyin_browser_chromium/Local State': StorageCategory.metadata,
        'video_player_app/ai_chat/video/conversation.json.bak':
            StorageCategory.metadata,
        'ai_transcript_cache/transcript.json': StorageCategory.workTemp,
        'batch_import_cache/input.mp4': StorageCategory.picker,
        'yt_dlp/cookies/cookies.txt': StorageCategory.metadata,
        'downloads/web/tasks/index.json.bak': StorageCategory.metadata,
        'downloads/douyin/tasks/tasks.json.tmp': StorageCategory.metadata,
        'downloads/bilibili/tasks/id/video.m4s.part0':
            StorageCategory.downloadTemp,
        'downloads/web/files/movie.mp4': StorageCategory.downloads,
        'web_media_downloads/queue_v2/index.json.bak': StorageCategory.metadata,
        'web_media_downloads/queue_v2/tasks/id/checkpoint.json':
            StorageCategory.metadata,
        'web_media_downloads/queue_v2/tasks/id/seg-1.ts':
            StorageCategory.downloadTemp,
        'web_media_downloads/movie.part.mp4': StorageCategory.downloadTemp,
        'web_media_downloads/hls_segments_123/seg.ts':
            StorageCategory.downloadTemp,
        'web_media_downloads/movie.mp4': StorageCategory.downloads,
        'douyin_downloads/tasks.json': StorageCategory.metadata,
        'douyin_downloads/movie.part': StorageCategory.downloadTemp,
        'douyin_downloads/movie.mp4': StorageCategory.downloads,
        'yt_dlp_downloads/movie.mp4.part': StorageCategory.downloadTemp,
      };
      final expected = <String, StorageCategory>{};
      for (final entry in examples.entries) {
        expected[(await write(entry.key)).path] = entry.value;
      }
      final snapshot = await scanStorageFiles(
        StorageScanInput(
          roots: [StorageRoot(sandbox.path, 'data', StorageRootKind.data)],
        ),
      );
      expect(snapshot.files, hasLength(expected.length));
      expect(snapshot.appBytes, 17 * expected.length);
      for (final file in snapshot.files) {
        expect(file.category, expected[file.path], reason: file.path);
        expect(file.canDelete, isFalse, reason: file.path);
        expect(file.explicitDelete, isFalse, reason: file.path);
      }
    },
  );

  test(
    'shared documents include new known records without scanning personal files',
    () async {
      final known = [
        await write('local_models/model/model.onnx'),
        await write('model_jobs/asr-key.json.tmp'),
        await write('model_center.json.bak'),
        await write('web_media_downloads/queue_v2/index.json'),
        await write('douyin_downloads/tasks.json'),
        await write('video_player_app/ai_chat/video/conversation.json'),
      ];
      await write('my-model.onnx');
      await write('personal.json.bak');
      await write('podcasts/personal.mp3');
      await write('artwork/personal.jpg');
      final snapshot = await scanStorageFiles(
        StorageScanInput(
          roots: [
            StorageRoot(
              sandbox.path,
              'documents',
              StorageRootKind.data,
              scoped: true,
            ),
          ],
        ),
      );
      expect(
        snapshot.files.map((file) => file.path),
        unorderedEquals(known.map((file) => file.path)),
      );
      expect(snapshot.clearableBytes, 0);
      expect(
        snapshot.files.any((file) => file.category == StorageCategory.other),
        isFalse,
      );
    },
  );

  test(
    'atomic metadata writes cannot become abandonable download parts',
    () async {
      final accounts = await write('cloud_drive_accounts.json.tmp');
      final snapshot = await scanStorageFiles(
        StorageScanInput(
          roots: [StorageRoot(sandbox.path, 'data', StorageRootKind.data)],
          assets: [
            StorageAssetDescriptor(
              assetKey: 'accounts',
              origin: StorageOrigin.cloudDrive,
              category: StorageCategory.metadata,
              policy: StorageCleanupPolicy.featureManaged,
              title: 'accounts',
              paths: [accounts.path],
            ),
          ],
        ),
      );
      final entry = snapshot.files.single;
      expect(entry.category, StorageCategory.metadata);
      expect(entry.cleanupPolicy, StorageCleanupPolicy.featureManaged);
      expect(entry.explicitDelete, isFalse);
      expect(
        storageDeletionPermitted(StorageCleanupAction.abandonResume, entry),
        isFalse,
      );
    },
  );

  test(
    'unknown model-like files stay unknown and application control records are protected',
    () async {
      final unknown = await write('my-model.onnx');
      final other = await write('my-settings.json');
      final layout = await write('storage/layout.json');
      final snapshot = await scanStorageFiles(
        StorageScanInput(
          roots: [
            StorageRoot(sandbox.path, 'support', StorageRootKind.support),
          ],
        ),
      );
      final entries = {for (final file in snapshot.files) file.path: file};
      expect(entries[unknown.path]!.category, StorageCategory.other);
      expect(entries[other.path]!.category, StorageCategory.other);
      expect(entries[layout.path]!.category, StorageCategory.metadata);
      expect(snapshot.clearableBytes, 0);
    },
  );
}
