import 'package:path/path.dart' as p;
import '../app_storage_service.dart';
import 'dart:io';

class VideoComposeOutputPathService {
  const VideoComposeOutputPathService();

  Future<void> ensureParentDirectory(String outputPath) async {
    final Directory dir = Directory(p.dirname(outputPath));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  Future<String> buildOutputPath(String title) async {
    final Directory outputDir = await AppStorageService.instance
        .exportDirectory();
    if (!await outputDir.exists()) {
      await outputDir.create(recursive: true);
    }
    final String fileName = buildOutputFileName(title);
    return p.join(outputDir.path, fileName);
  }

  String buildOutputFileName(String title) {
    final String safeTitle = title
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final String baseName = safeTitle.isEmpty ? 'video' : safeTitle;
    return '${baseName}_compose_${DateTime.now().millisecondsSinceEpoch}.mp4';
  }
}
