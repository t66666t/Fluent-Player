import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../../utils/app_data_paths.dart';
import 'ai_chat_models.dart';

/// One recoverable file per conversation. Writes are serialized and use a
/// temporary file + last good backup, including on Windows where rename cannot
/// replace an existing file.
class AiConversationStore {
  final Directory? root;
  Future<void> _pending = Future.value();
  final List<String> warnings = [];
  AiConversationStore({this.root});

  Future<Directory> _directory(String videoId) async {
    final base =
        root ??
        Directory(
          p.join(
            (await resolveAppDataDirectory()).path,
            'video_player_app',
            'ai_chat',
          ),
        );
    final key = sha256.convert(utf8.encode(videoId)).toString();
    return Directory(p.join(base.path, key));
  }

  String _fileName(String id) => sha256.convert(utf8.encode(id)).toString();

  Future<List<AiConversation>> load(String videoId) async {
    await _pending;
    warnings.clear();
    final dir = await _directory(videoId);
    if (!await dir.exists()) return [];
    final conversations = <AiConversation>[];
    final files = await dir
        .list()
        .where((file) => file is File)
        .cast<File>()
        .toList();
    final names = files
        .where(
          (file) =>
              file.path.endsWith('.json') || file.path.endsWith('.json.bak'),
        )
        .map((file) => file.path.replaceFirst(RegExp(r'\.bak$'), ''))
        .toSet();
    for (final path in names) {
      AiConversation? restored;
      for (final candidate in [path, '$path.bak']) {
        try {
          if (!await File(candidate).exists()) continue;
          final parsed = AiConversation.fromJson(
            Map<String, dynamic>.from(
              jsonDecode(await File(candidate).readAsString()),
            ),
          );
          if (parsed.videoId != videoId) continue;
          restored = parsed;
          if (candidate.endsWith('.bak')) warnings.add('一条对话已从上次完整备份恢复。');
          break;
        } catch (_) {
          /* Keep corrupted data intact for recovery. */
        }
      }
      if (restored != null) {
        conversations.add(restored);
      } else {
        warnings.add('一条对话文件无法读取，原文件已保留。');
      }
    }
    conversations.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return conversations;
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.catchError((Object _) {});
    return result;
  }

  Future<void> save(AiConversation conversation) => _enqueue(() async {
    final dir = await _directory(conversation.videoId);
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, '${_fileName(conversation.id)}.json'));
    final temporary = File('${file.path}.tmp');
    final backup = File('${file.path}.bak');
    await temporary.writeAsString(
      jsonEncode(conversation.toJson()),
      flush: true,
    );
    if (await file.exists()) {
      if (await backup.exists()) await backup.delete();
      await file.rename(backup.path);
    }
    await temporary.rename(file.path);
  });

  Future<void> delete(String videoId, String id) => _enqueue(() async {
    final dir = await _directory(videoId);
    final path = p.join(dir.path, '${_fileName(id)}.json');
    for (final candidate in [path, '$path.bak', '$path.tmp']) {
      final file = File(candidate);
      if (await file.exists()) await file.delete();
    }
  });
}
