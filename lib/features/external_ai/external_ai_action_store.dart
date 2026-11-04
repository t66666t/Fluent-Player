import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

/// App-private journals, never a file-serving or arbitrary-path interface.
/// The backup also recovers a process exit between the two Windows renames.
class ExternalAiActionStore {
  ExternalAiActionStore(this.root, {this.name = 'actions-v1'});
  final Directory root;
  final String name;
  static const maximumBytes = 48 * 1024 * 1024;
  File get _file => File(p.join(root.path, 'external_ai', '$name.json'));

  Future<Map<String, dynamic>> load() async {
    final file = _file;
    final backup = File('${file.path}.bak');
    final source = await file.exists() ? file : backup;
    if (!await source.exists()) return {'version': 1};
    if (await source.length() > maximumBytes) {
      throw const FormatException('journal too large');
    }
    final data = jsonDecode(await source.readAsString());
    if (data is! Map<String, dynamic> || data['version'] != 1) {
      throw const FormatException('invalid journal');
    }
    return data;
  }

  Future<void> save(Map<String, dynamic> state) async {
    final bytes = utf8.encode(jsonEncode(state));
    if (bytes.length > maximumBytes) throw StateError('journal full');
    final file = _file;
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    final backup = File('${file.path}.bak');
    await temporary.writeAsBytes(bytes, flush: true);
    if (await file.exists()) {
      if (await backup.exists()) await backup.delete();
      await file.rename(backup.path);
    }
    try {
      await temporary.rename(file.path);
    } catch (_) {
      if (!await file.exists() && await backup.exists()) {
        await backup.rename(file.path);
      }
      rethrow;
    }
  }
}
