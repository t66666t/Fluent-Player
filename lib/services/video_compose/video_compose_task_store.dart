import '../app_storage_service.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../../utils/app_data_paths.dart';

import '../../models/video_compose_models.dart';

class VideoComposeTaskStore {
  static final Set<String> _unreadablePaths = {};
  // Several managers and stage notifications can save before the previous
  // write closes its handles. Serialize reads as well as writes, including
  // across store instances, so .next/.bak never have competing owners.
  static Future<void> _pendingIo = Future<void>.value();
  final File? taskFile;
  const VideoComposeTaskStore({this.taskFile});

  static Future<T> _serialize<T>(Future<T> Function() work) {
    final result = _pendingIo.then((_) => work());
    _pendingIo = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<List<VideoComposeTaskState>> loadTasks() => _serialize(_loadTasks);

  Future<List<VideoComposeTaskState>> _loadTasks() async {
    try {
      final File file = await _taskFile();
      if (!await file.exists() && !await File('${file.path}.bak').exists()) {
        return const <VideoComposeTaskState>[];
      }
      final raw = await _retryFileAccess(() => readStorageJson(file));
      final List<dynamic> list =
          AppStorageService.instance.decodePaths(raw) as List<dynamic>;
      final List<VideoComposeTaskState> tasks = <VideoComposeTaskState>[];
      for (final dynamic item in list) {
        try {
          tasks.add(
            VideoComposeTaskState.fromJson(item as Map<String, dynamic>),
          );
        } catch (error) {
          _unreadablePaths.add(file.path);
          debugPrint('Failed to load task: $error');
        }
      }
      return tasks;
    } catch (error) {
      _unreadablePaths.add((await _taskFile()).path);
      debugPrint('Failed to load compose tasks: $error');
      return const <VideoComposeTaskState>[];
    }
  }

  Future<void> saveTasks(Iterable<VideoComposeTaskState> tasks) {
    // Freeze the snapshot before yielding: callers often pass Map.values.
    final list = tasks.map((task) => task.toJson()).toList();
    return _serialize(() => _saveTasks(list));
  }

  Future<void> _saveTasks(List<Map<String, dynamic>> list) async {
    try {
      final File file = await _taskFile();
      if (_unreadablePaths.contains(file.path)) return;
      final encoded = AppStorageService.instance.encodePaths(list);
      await _retryFileAccess(() => writeStorageJson(file, encoded));
    } catch (error) {
      debugPrint('Failed to save compose tasks: $error');
    }
  }

  Future<File> _taskFile() async {
    if (taskFile != null) return taskFile!;
    final Directory dir = await resolveAppDataDirectory();
    return File(p.join(dir.path, 'compose_tasks.json'));
  }

  Future<T> _retryFileAccess<T>(Future<T> Function() operation) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await operation();
      } on FileSystemException catch (error) {
        // Antivirus/indexing can briefly hold a Windows file even after our
        // own handles close. Never truncate the live file to work around it.
        final code = error.osError?.errorCode;
        if (!Platform.isWindows || (code != 32 && code != 33) || attempt >= 5) {
          rethrow;
        }
        await Future<void>.delayed(Duration(milliseconds: 30 << attempt));
      }
    }
  }
}
