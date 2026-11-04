// Offline Android regression entrypoint. Copy synthetic fixture files named
// leading-no-pts.mp4 and audio.m4a into the application's external files
// directory under yt-merge-probe via USB before launching this entrypoint.
// Uses an isolated storage root and in-memory preferences, with a bridge that
// rejects all downloads. Never starts the normal app or reads user tasks.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/youtube_download/models/youtube_download_models.dart';
import 'package:video_player_app/features/youtube_download/platform/yt_dlp_native_bridge.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_download_service.dart';
import 'package:video_player_app/services/app_storage_service.dart';

class _OfflineBridge extends YtDlpNativeBridge {
  int downloads = 0;
  @override
  Stream<DownloadTaskEvent> taskEvents() => const Stream.empty();
  @override
  Future<bool> startYoutubeDownload(
    NativeDownloadRequest request, {
    required int generation,
  }) async {
    downloads++;
    throw StateError('Network downloads are forbidden in this offline probe');
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('YT-DLP 离线合并验证（不下载）'))),
    ),
  );
  final root = await (await getTemporaryDirectory()).createTemp(
    'yt_finalize_probe_',
  );
  final external = await getExternalStorageDirectory();
  final report = <String, dynamic>{};
  YtDlpDownloadService? service;
  try {
    SharedPreferences.setMockInitialValues({});
    AppStorageService.instance = AppStorageService(
      locations: () async => StorageLocations(
        platform: StoragePlatform.android,
        support: Directory(p.join(root.path, 'support')),
        documents: Directory(p.join(root.path, 'documents')),
        defaultData: Directory(p.join(root.path, 'data')),
        executable: Directory(p.join(root.path, 'program')),
      ),
    );
    await AppStorageService.instance.initialize();
    final fixtures = Directory(p.join(external!.path, 'yt-merge-probe'));
    final tasks = await AppStorageService.instance.downloadTasks('yt_dlp');
    final video = await File(
      p.join(fixtures.path, 'leading-no-pts.mp4'),
    ).copy(p.join(tasks.path, 'ytdlp_fixture_312.mp4'));
    final audio = await File(
      p.join(fixtures.path, 'audio.m4a'),
    ).copy(p.join(tasks.path, 'ytdlp_fixture_140.m4a'));
    final bridge = _OfflineBridge();
    service = YtDlpDownloadService.forTesting(
      nativeBridge: bridge,
      binaryStatus: const YtDlpBinaryStatus(
        ytDlpReady: true,
        ffmpegReady: true,
      ),
      sessionConfig: const DownloadSessionConfig(),
    );
    service.tasks.add(
      YtDlpTaskRecord(
        taskId: 'fixture',
        sourceUrl: 'https://www.youtube.com/watch?v=offline',
        createdAtIso: '',
        status: YtDlpTaskStatus.failed,
        pendingLocalPostProcess: true,
        tempArtifactKey: 'fixture',
        producedPaths: [video.path, audio.path],
        selection: const DownloadSelection(
          selectedVideoFormatId: '312',
          selectedAudioFormatIds: ['140'],
          outputContainer: 'mkv',
        ),
        meta: const VideoMeta(
          id: 'offline',
          source: 'youtube',
          webpageUrl: '',
          title: 'Offline finalize regression',
          uploader: '',
          durationSeconds: 2,
          videoFormats: [
            VideoFormat(formatId: '312', ext: 'mp4', videoCodec: 'h264'),
          ],
          audioFormats: [
            AudioFormat(formatId: '140', ext: 'm4a', audioCodec: 'aac'),
          ],
        ),
        request: NativeDownloadRequest(
          taskId: 'fixture',
          url: '',
          outputDir: tasks.path,
          outputTemplate: '',
          args: const [],
          debugContext: const {
            'resolvedVideoFormatId': '312',
            'resolvedAudioFormatIds': ['140'],
          },
        ),
      ),
    );
    await service.saveTasks();
    await service.startTask(service.tasks.single);
    final result = service.tasks.single;
    report.addAll({
      'status': result.status.name,
      'error': result.errorMessage,
      'downloads': bridge.downloads,
      'pendingLocalPostProcess': result.pendingLocalPostProcess,
    });
    if (result.status != YtDlpTaskStatus.completed || bridge.downloads != 0) {
      throw StateError(
        'Offline production finalize failed: ${result.errorMessage}',
      );
    }
    await File(
      p.join(fixtures.path, 'production-fixed.mkv'),
    ).writeAsBytes(await File(result.outputPath!).readAsBytes(), flush: true);
    report['passed'] = true;
  } catch (error, stack) {
    report.addAll({'passed': false, 'error': '$error', 'stack': '$stack'});
  } finally {
    await service?.shutdown();
    service?.dispose();
    if (external != null) {
      await File(
        p.join(external.path, 'yt-merge-probe', 'production-report.json'),
      ).writeAsString(jsonEncode(report), flush: true);
    }
    // The probe owns only this fresh isolated directory.
    await root.delete(recursive: true);
  }
  debugPrint('YTDLP_OFFLINE_FINALIZE ${jsonEncode(report)}', wrapWidth: 600);
}
