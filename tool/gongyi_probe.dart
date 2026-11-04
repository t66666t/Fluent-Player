// 在线转录端到端探针，需显式传入待识别的音频文件。
// 用法: dart run tool/gongyi_probe.dart <audio.m4a>
import 'dart:io';

import 'package:video_player_app/services/gongyi_asr_service.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('用法: dart run tool/gongyi_probe.dart <audio.m4a>');
    exit(2);
  }
  final audioPath = args.first;
  final file = File(audioPath);
  if (!file.existsSync()) {
    stderr.writeln('音频不存在: $audioPath');
    exit(2);
  }
  stdout.writeln('[probe] 音频大小: ${file.lengthSync()} bytes');

  final service = GongyiAsrService();
  try {
    final subs = await service.transcribeAudio(
      audioPath,
      onProgress: (p, msg) =>
          stdout.writeln('[probe] ${p.toStringAsFixed(2)} $msg'),
    );
    stdout.writeln('[probe] 成功! 共 ${subs.length} 条字幕');
    for (final s in subs.take(10)) {
      stdout.writeln('  ${s.startTime} -> ${s.endTime}: ${s.text}');
    }
    exit(0);
  } catch (e, st) {
    stderr.writeln('[probe] 失败: $e');
    stderr.writeln(st);
    exit(1);
  }
}
