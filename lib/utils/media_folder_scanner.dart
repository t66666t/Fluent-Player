import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../services/library_service.dart';

/// 扫描超时上限。与 [LibraryService.analyzeFolderSelection] 保持一致，
/// 防止超大文件夹或软链接环路导致任务无限挂起。
const Duration kMediaFolderScanTimeout = Duration(seconds: 30);

/// 扫描并排序文件夹内的所有媒体文件（含多级子文件夹）。
///
/// 排序规则：深度优先遍历；每层先按文件名自然排序依次递归处理所有子文件夹，
/// 再按文件名自然排序加入当前层内的媒体文件（文件夹优先）。
///
/// 返回已按上述顺序排好的媒体文件绝对路径列表。仅包含可识别的视频/音频
/// 扩展名（由 [LibraryService.supportedMediaExtensions] 决定），非媒体文件
/// 一律过滤。
///
/// 递归遍历在独立 Isolate 中执行，避免大文件夹扫描阻塞 UI 线程
/// （Windows 端"导入文件夹时点击即闪退"的核心根因）。
Future<List<String>> scanMediaFolderOrdered(String rootPath) async {
  final rootDir = Directory(rootPath);
  if (!await rootDir.exists()) {
    throw FileSystemException('目录不存在', rootPath);
  }

  return compute(_scanMediaFolderIsolate, rootPath).timeout(
    kMediaFolderScanTimeout,
    onTimeout: () {
      throw TimeoutException('文件夹扫描超时（${kMediaFolderScanTimeout.inSeconds}秒），请检查目录是否过大或包含软链接环路');
    },
  );
}

/// 在独立 Isolate 中执行的深度优先扫描。
///
/// 使用 listSync 同步遍历（Isolate 内同步不影响 UI），每层先处理所有子
/// 文件夹（按文件名自然排序），再追加当前层媒体文件（同样自然排序），
/// 返回跨 Isolate 可安全传输的 `List<String>`。
List<String> _scanMediaFolderIsolate(String rootPath) {
  final result = <String>[];

  void visit(Directory dir) {
    final subDirs = <Directory>[];
    final mediaFiles = <File>[];

    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } catch (e) {
      // 跳过无法访问的目录（权限不足、已被删除等），不让单个目录拖垮整体扫描。
      debugPrint('扫描目录失败: ${dir.path}, $e');
      return;
    }

    for (final entity in entries) {
      if (entity is Directory) {
        subDirs.add(entity);
      } else if (entity is File &&
          LibraryService.isSupportedMediaPath(entity.path)) {
        mediaFiles.add(entity);
      }
    }

    subDirs.sort(
      (a, b) => LibraryService.compareStructuredImportNames(
        p.basename(a.path),
        p.basename(b.path),
      ),
    );
    mediaFiles.sort(
      (a, b) => LibraryService.compareStructuredImportNames(
        p.basename(a.path),
        p.basename(b.path),
      ),
    );

    for (final sub in subDirs) {
      visit(sub);
    }
    result.addAll(mediaFiles.map((f) => f.path));
  }

  visit(Directory(rootPath));
  return result;
}
