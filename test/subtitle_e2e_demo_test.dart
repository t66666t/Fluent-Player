import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';

/// 端到端演示：使用示例字幕文件（31 句英文）通过 必应 翻译为简体中文，
/// 验证完整流程（解析 -> 逐条翻译 -> 写出 SRT）。
void main() {
  test(
    '必应 端到端翻译示例字幕（31 句英 -> 简中）',
    () async {
      // 在线端到端测试使用明确开关启用。
      final runLive =
          const bool.fromEnvironment('BING_LIVE_TEST', defaultValue: false);
      if (!runLive) {
        markTestSkipped('未启用在线测试，使用 --dart-define=BING_LIVE_TEST=true 运行');
        return;
      }

      final inputPath = 'D:/1spbfq/ms_translate_test.srt';
      if (!File(inputPath).existsSync()) {
        markTestSkipped('示例字幕文件不存在: $inputPath');
        return;
      }

      final service = SubtitleTranslationService();
      final result = await service.translateSubtitleFile(
        inputPath: inputPath,
        sourceLanguage: 'en',
        targetLanguage: 'zh-CN',
        provider: SubtitleTranslateProvider.bing,
        onProgress: (progress) {
          final percent = (progress * 100).toStringAsFixed(0);
          stdout.writeln('  进度: $percent%');
        },
      );

      expect(result.totalCount, 31);
      final outputPath = result.outputPath;
      stdout.writeln('输出文件: $outputPath');
      expect(File(outputPath).existsSync(), isTrue);

      final content = File(outputPath).readAsStringSync();
      final lines = content.split('\r\n');
      expect(lines.length, greaterThan(60));
      stdout.writeln('\n=== 翻译结果前 5 条 ===');
      final textLines = lines
          .where((l) => l.isNotEmpty)
          .where((l) => !RegExp(r'^\d+$').hasMatch(l))
          .where((l) => !l.contains('-->'))
          .toList();
      for (var i = 0; i < 5 && i < textLines.length; i++) {
        stdout.writeln('  ${i + 1}. ${textLines[i]}');
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
