import 'dart:io';
import '../debug/developer_log.dart' as developer;
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'ffmpeg_utils.dart';

class SubtitleConverter {
  /// 将字幕文件转换为指定格式
  /// 返回转换后的文件路径，如果转换失败或不需要转换则返回 null
  static Future<String?> convert({
    required String inputPath,
    required String targetExtension, // e.g., ".srt" or ".sup"
  }) async {
    final file = File(inputPath);
    if (!await file.exists()) return null;

    final inputName = p.basenameWithoutExtension(inputPath);
    
    // 使用临时目录存放转换结果，避免污染源目录
    final tempDir = await getTemporaryDirectory();
    final outputPath = p.join(tempDir.path, "converted_${inputName}_${DateTime.now().millisecondsSinceEpoch}$targetExtension");

    // 构造 FFmpeg 命令
    // -y: 覆盖输出文件
    String command = "-y -i \"$inputPath\" ";
    
    if (targetExtension == ".sup") {
      // 转为 PGS
      command += "-c:s hdmv_pgs_subtitle \"$outputPath\"";
    } else if (targetExtension == ".srt") {
      // 转为 SRT
      command += "-c:s text \"$outputPath\""; // 或 subrip
    } else {
      command += "\"$outputPath\"";
    }

    try {
      if (FFmpegUtils.preferSystemFfmpeg) {
        await FFmpegUtils.ensureAvailable();
        final ffmpegPath = await FFmpegUtils.ffmpegPath;
        final args = <String>['-y', '-i', inputPath];
        if (targetExtension == ".sup") {
          args.addAll(['-c:s', 'hdmv_pgs_subtitle']);
        } else if (targetExtension == ".srt") {
          args.addAll(['-c:s', 'text']);
        }
        args.add(outputPath);
        final result = await Process.run(ffmpegPath, args)
            .timeout(const Duration(seconds: 60));
        if (result.exitCode == 0) {
          return outputPath;
        }
        developer.log(
          'Subtitle conversion failed (system ffmpeg)',
          error: result.stderr,
        );
        return null;
      }

      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();

      if (ReturnCode.isSuccess(returnCode)) {
        return outputPath;
      } else {
        final logs = await session.getAllLogsAsString();
        developer.log('Subtitle conversion failed', error: logs);
        return null;
      }
    } catch (e) {
      developer.log('Subtitle conversion error', error: e);
      return null;
    }
  }

  /// 检查是否是 MicroDVD 格式的 .sub 文件 (文本)
  /// 如果是二进制 VobSub，则返回 false
  static Future<bool> isMicroDvdSub(String path) async {
    try {
      final file = File(path);
      // 读取前几个字节/字符
      final bytes = await file.openRead(0, 50).first; 
      // 尝试解码为文本
      try {
        final content = String.fromCharCodes(bytes);
        // MicroDVD 特征: {0}{25} 或 {100}{200}
        return content.trim().startsWith('{');
      } catch (e) {
        return false; // 解码失败，可能是二进制
      }
    } catch (e) {
      return false;
    }
  }
}
