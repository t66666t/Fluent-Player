import '../app_storage_service.dart';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../utils/app_data_paths.dart';
import '../../models/bilibili_download_task.dart';

/// 后台 Isolate 中执行的 JSON 编码 + 文件写入
Future<void> _saveTaskListToDisk(
  (String, List<Map<String, dynamic>>) args,
) async {
  await writeStorageJson(File(args.$1), args.$2);
}

class BilibiliDownloadStateManager {
  static const String _fileName = 'bilibili_download_tasks.json';
  static Future<void> _saveQueue = Future<void>.value();
  static final Set<String> _unreadablePaths = {};

  static Future<String> _getFilePath() async {
    final directory = await resolveAppDataDirectory();
    return '${directory.path}/$_fileName';
  }

  static Future<void> saveTasks(List<BilibiliDownloadTask> tasks) async {
    final snapshots = tasks
        .map(
          (task) => Map<String, dynamic>.from(
            AppStorageService.instance.encodePaths(task.toJson()),
          ),
        )
        .toList(growable: false);
    await saveTaskSnapshots(snapshots);
  }

  static Future<void> saveTaskSnapshots(List<Map<String, dynamic>> snapshots) {
    // A previous, slower write must never finish after a newer reorder and
    // restore stale task ordering. Serializing writes also lets every save use
    // the same staging path safely.
    final encodedSnapshots = snapshots
        .map(
          (e) => Map<String, dynamic>.from(
            AppStorageService.instance.encodePaths(e),
          ),
        )
        .toList();
    final operation = _saveQueue.then((_) async {
      try {
        final path = await _getFilePath();
        if (_unreadablePaths.contains(path)) return;
        // 在后台 Isolate 中执行 JSON 编码 + 同目录临时文件替换，避免主线程卡顿，
        // 同时避免进程中断留下半份 JSON。
        await compute(_saveTaskListToDisk, (path, encodedSnapshots));
      } catch (e) {
        debugPrint("Error saving Bilibili download tasks: $e");
      }
    });
    _saveQueue = operation;
    return operation;
  }

  static Future<List<BilibiliDownloadTask>> loadTasks() async {
    try {
      final path = await _getFilePath();
      final file = File(path);

      final raw = await readStorageJson(file);
      if (raw == null) return [];
      final jsonList = raw as List<dynamic>;
      _unreadablePaths.remove(path);

      return jsonList.map<BilibiliDownloadTask>((e) {
        final task = BilibiliDownloadTask.fromJson(
          AppStorageService.instance.decodePaths(e),
        );
        // 重启后状态修正：保留任务列表，但将活跃任务标记为已中断
        for (var video in task.videos) {
          for (var ep in video.episodes) {
            if (ep.status == DownloadStatus.downloading ||
                ep.status == DownloadStatus.merging ||
                ep.status == DownloadStatus.fetchingInfo ||
                ep.status == DownloadStatus.checking ||
                ep.status == DownloadStatus.repairing) {
              if (ep.hasResumeData) {
                ep.status = DownloadStatus.pending;
                ep.error = "已暂停";
                ep.progress = ep.resumableProgress;
              } else {
                ep.status = DownloadStatus.failed;
                ep.error = "进程中断";
              }
            } else if (ep.status == DownloadStatus.queued) {
              ep.status = DownloadStatus.pending;
            } else if (ep.hasResumeData) {
              ep.progress = ep.resumableProgress;
            }
          }
        }
        return task;
      }).toList();
    } catch (e) {
      _unreadablePaths.add(await _getFilePath());
      debugPrint("Error loading Bilibili download tasks: $e");
      return [];
    }
  }
}
