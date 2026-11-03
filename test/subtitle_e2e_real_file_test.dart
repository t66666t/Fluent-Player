import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';

/// 端到端验证：用用户提供的真实字幕文件翻译。
/// 1. 必应 批量翻译（原字幕是中文，翻译成英文）
/// 2. 空数据不报错、行数不丢失
void main() {
  test('必应 批量翻译真实字幕文件（zh-CN → en）', () async {
    final runLive =
        const bool.fromEnvironment('BING_LIVE_TEST', defaultValue: false);
    if (!runLive) {
      markTestSkipped('未启用在线测试，使用 --dart-define=BING_LIVE_TEST=true 运行');
      return;
    }

    final inputPath = 'D:/1Download/4059045f-3b9c-4181-9dae-e19be53eebe0_ai-zh.srt';
    if (!File(inputPath).existsSync()) {
      markTestSkipped('真实字幕文件不存在');
      return;
    }

    final service = SubtitleTranslationService();
    final stopwatch = Stopwatch()..start();
    final result = await service.translateSubtitleFile(
      inputPath: inputPath,
      sourceLanguage: 'zh-CN',
      targetLanguage: 'en',
      provider: SubtitleTranslateProvider.bing,
      onProgress: (progress) {
        final percent = (progress * 100).toStringAsFixed(0);
        stdout.writeln('  进度: $percent%');
      },
    );
    stopwatch.stop();

    expect(result.totalCount, 40);
    final content = File(result.outputPath).readAsStringSync();
    final textLines = content
        .split('\r\n')
        .where((l) => l.isNotEmpty)
        .where((l) => !RegExp(r'^\d+$').hasMatch(l))
        .where((l) => !l.contains('-->'))
        .toList();
    // 行数不丢失（关键：空数据不丢行）
    expect(textLines.length, 40,
        reason: '翻译后行数必须保持 40 行，实际 ${textLines.length}');
    stdout.writeln('翻译完成: 40 行, 耗时 ${stopwatch.elapsed.inSeconds} 秒');
    stdout.writeln('\n=== 翻译结果前 8 条 ===');
    for (var i = 0; i < 8 && i < textLines.length; i++) {
      stdout.writeln('  ${i + 1}. ${textLines[i]}');
    }
  });
}
