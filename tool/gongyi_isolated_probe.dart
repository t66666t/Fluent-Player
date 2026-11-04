// 一次只测一个音频，并且和上一次探针强制隔开。
//
// 用法:
//   dart run tool/gongyi_isolated_probe.dart <audio.m4a>
//
// 上一次探针还在冷却期内会直接退出，不会发请求。
// 查询一旦返回 412 就停止，不再重试，避免把下一次测试也卷进风控。
import 'dart:convert';
import 'dart:io';

import 'package:video_player_app/services/gongyi_asr_service.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('用法: dart run tool/gongyi_isolated_probe.dart <audio.m4a>');
    exit(2);
  }
  final audioPath = args.first;
  final file = File(audioPath);
  if (!file.existsSync()) {
    stderr.writeln('音频不存在: $audioPath');
    exit(2);
  }

  final journal = File(
    '${Directory.systemTemp.path}${Platform.pathSeparator}gongyi_isolated_probe.json',
  );
  final now = DateTime.now();
  final previous = _readJournal(journal);
  final quietUntil = previous == null
      ? null
      : DateTime.tryParse(previous['quietUntil']?.toString() ?? '');
  if (quietUntil != null && now.isBefore(quietUntil)) {
    final left = quietUntil.difference(now);
    final minutes = left.inMinutes + (left.inSeconds.remainder(60) > 0 ? 1 : 0);
    stderr.writeln(
      '[isolated] 上一次探针还没冷却完，还要等约 $minutes 分钟。'
      '这次不会发请求，避免和上次混在一起。',
    );
    stderr.writeln(
      '[isolated] 上次结果: ${previous?['result']}  ${previous?['audio']}',
    );
    exit(2);
  }

  // 先占住冷却窗口。中途退出也不会让下一次立刻跟上。
  _writeJournal(journal, {
    'startedAt': now.toIso8601String(),
    'quietUntil': now.add(const Duration(minutes: 30)).toIso8601String(),
    'result': 'running',
    'audio': audioPath,
    'bytes': file.lengthSync(),
  });

  stdout.writeln('[isolated] 音频大小: ${file.lengthSync()} bytes');
  stdout.writeln('[isolated] 只发这一次。查询遇到访问限制会立刻停止。');
  final service = GongyiAsrService(maxPollRiskWaits: 0);
  final started = DateTime.now();
  try {
    final subtitles = await service.transcribeAudio(
      audioPath,
      onProgress: (progress, message) =>
          stdout.writeln('[isolated] ${progress.toStringAsFixed(2)} $message'),
    );
    final elapsed = DateTime.now().difference(started);
    stdout.writeln(
      '[isolated] 成功。${subtitles.length} 条字幕，用时 ${elapsed.inSeconds} 秒。',
    );
    for (final cue in subtitles.take(5)) {
      stdout.writeln('  ${cue.startTime} -> ${cue.endTime}: ${cue.text}');
    }
    _writeJournal(journal, {
      'finishedAt': DateTime.now().toIso8601String(),
      'quietUntil': DateTime.now()
          .add(const Duration(minutes: 30))
          .toIso8601String(),
      'result': 'success',
      'audio': audioPath,
      'bytes': file.lengthSync(),
      'cues': subtitles.length,
      'seconds': elapsed.inSeconds,
    });
    exit(0);
  } on GongyiAsrException catch (error) {
    final risk = error.isRiskControl;
    stderr.writeln('[isolated] 失败: $error');
    if (risk) {
      stderr.writeln('[isolated] 这是访问限制，不是这段音频太长。请至少隔 60 分钟再测下一段。');
    }
    _writeJournal(journal, {
      'finishedAt': DateTime.now().toIso8601String(),
      'quietUntil': DateTime.now()
          .add(Duration(minutes: risk ? 60 : 20))
          .toIso8601String(),
      'result': risk ? 'risk' : error.kind.name,
      'audio': audioPath,
      'bytes': file.lengthSync(),
      'message': error.message,
    });
    exit(risk ? 3 : 1);
  } catch (error, stack) {
    stderr.writeln('[isolated] 失败: $error');
    stderr.writeln(stack);
    _writeJournal(journal, {
      'finishedAt': DateTime.now().toIso8601String(),
      'quietUntil': DateTime.now()
          .add(const Duration(minutes: 20))
          .toIso8601String(),
      'result': 'error',
      'audio': audioPath,
      'bytes': file.lengthSync(),
      'message': error.toString(),
    });
    exit(1);
  }
}

Map<String, Object?>? _readJournal(File journal) {
  if (!journal.existsSync()) return null;
  try {
    final decoded = jsonDecode(journal.readAsStringSync());
    if (decoded is Map) return Map<String, Object?>.from(decoded);
  } catch (_) {}
  return null;
}

void _writeJournal(File journal, Map<String, Object?> data) {
  journal.writeAsStringSync(jsonEncode(data));
}
