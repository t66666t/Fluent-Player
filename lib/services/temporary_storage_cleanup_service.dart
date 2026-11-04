import 'dart:io';

import 'package:video_player_app/features/youtube_download/services/yt_dlp_download_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/storage_contributors.dart';
import 'package:video_player_app/services/temporary_storage_cleanup_models.dart';
import 'package:video_player_app/services/transcription_manager.dart';

class TemporaryStorageCleanupService {
  final TranscriptionManager transcriptionManager;
  final LibraryService libraryService;
  final BilibiliDownloadService bilibiliDownloadService;
  final YtDlpDownloadService ytDlpDownloadService;

  const TemporaryStorageCleanupService({
    required this.transcriptionManager,
    required this.libraryService,
    required this.bilibiliDownloadService,
    required this.ytDlpDownloadService,
  });

  Future<TemporaryStorageScanReport> scan() async {
    final categories = await Future.wait([
      transcriptionManager.buildTemporaryStorageReport(),
      libraryService.buildArchiveTemporaryStorageReport(),
      bilibiliDownloadService.buildTemporaryStorageReport(),
      ytDlpDownloadService.buildTemporaryStorageReport(),
      _featureResidue(),
    ]);
    return TemporaryStorageScanReport(
      categories: categories.where((item) => item.hasVisibleContent).toList(),
    );
  }

  Future<TemporaryStorageScanReport> clearAll() async {
    await transcriptionManager.clearTemporaryStorageArtifacts();
    await libraryService.clearArchiveTemporaryStorageArtifacts();
    await bilibiliDownloadService.clearTemporaryStorageArtifacts();
    await ytDlpDownloadService.clearTemporaryStorageArtifacts();
    final root = libraryService.dataRootDirOrNull;
    if (root != null) {
      await clearFeatureTemporaryFiles(
        dataRoot: root,
        systemTemp: Directory.systemTemp,
      );
    }
    return scan();
  }

  Future<TemporaryStorageCategoryReport> _featureResidue() async {
    final root = libraryService.dataRootDirOrNull;
    if (root == null) {
      return const TemporaryStorageCategoryReport(
        id: 'feature-residue',
        title: '播客与网盘临时残留',
        description: '媒体库尚未加载，暂时不能核对这些残留。',
        fileCount: 0,
        totalBytes: 0,
        canClean: false,
        note: '完整的播客、网盘和封面占用在存储空间管理中查看。',
      );
    }
    return inspectFeatureTemporaryFiles(
      dataRoot: root,
      systemTemp: Directory.systemTemp,
    );
  }
}
