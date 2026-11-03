import '../../services/app_storage_service.dart';
import 'dart:io';
import 'package:path/path.dart' as p;

Future<void> writeWebMediaJson(File file, Object value) =>
    writeStorageJson(file, value);

class WebMediaQueueStore {
  WebMediaQueueStore(Directory documents)
    : root = Directory(
        p.join(documents.path, 'web_media_downloads', 'queue_v2'),
      );
  WebMediaQueueStore.atRoot(this.root);
  final Directory root;
  Directory get filesDirectory => p.basename(root.path) == 'queue_v2'
      ? root.parent
      : Directory(p.join(root.parent.path, 'files'));
  Directory get ownedDirectory => root.parent;
  File get index => File(p.join(root.path, 'index.json'));
  Directory taskDirectory(String id) {
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) {
      throw const FormatException('无效任务标识');
    }
    return Directory(
      p.basename(root.path) == 'queue_v2'
          ? p.join(root.path, 'tasks', id)
          : p.join(root.path, id),
    );
  }

  Future<Map<String, dynamic>?> read() async {
    final raw = await readStorageJson(index);
    if (raw == null) return null;
    final value = AppStorageService.instance.decodePaths(raw);
    if (value is! Map || value['version'] != 2) {
      throw const FormatException('下载队列记录无效');
    }
    return Map<String, dynamic>.from(value);
  }

  Future<void> write(Map<String, dynamic> value) => writeWebMediaJson(
    index,
    AppStorageService.instance.encodePaths({'version': 2, ...value}),
  );
  Future<void> deleteTask(String id) async {
    final directory = taskDirectory(id);
    // Never follow a link when deleting an owned workspace.
    if (await FileSystemEntity.type(directory.path, followLinks: false) ==
        FileSystemEntityType.link) {
      await Link(directory.path).delete();
    } else if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}
