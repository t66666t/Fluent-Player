import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';

void main() {
  group('SubtitleTranslationService.isEnZhDirection 方向判定', () {
    final service = SubtitleTranslationService();

    test('英 → 简中 为中英方向', () {
      expect(service.isEnZhDirection('en', 'zh-CN'), isTrue);
    });

    test('简中 → 英 为中英方向', () {
      expect(service.isEnZhDirection('zh-CN', 'en'), isTrue);
    });

    test('英 → 繁体 为中英方向', () {
      expect(service.isEnZhDirection('en', 'zh-TW'), isTrue);
    });

    test('繁体 → 英 为中英方向', () {
      expect(service.isEnZhDirection('zh-TW', 'en'), isTrue);
    });

    test('auto → 中文 为中英方向', () {
      expect(service.isEnZhDirection('auto', 'zh-CN'), isTrue);
    });

    test('英 → auto 为中英方向', () {
      expect(service.isEnZhDirection('en', 'auto'), isTrue);
    });

    test('日语 → 中文 不是中英方向', () {
      expect(service.isEnZhDirection('ja', 'zh-CN'), isFalse);
    });

    test('中文 → 日语 不是中英方向', () {
      expect(service.isEnZhDirection('zh-CN', 'ja'), isFalse);
    });

    test('英语 → 日语 不是中英方向', () {
      expect(service.isEnZhDirection('en', 'ja'), isFalse);
    });

    test('葡萄牙语 → 中文 不是中英方向', () {
      expect(service.isEnZhDirection('pt', 'zh-CN'), isFalse);
    });

    test('中文 → 法语 不是中英方向', () {
      expect(service.isEnZhDirection('zh-CN', 'fr'), isFalse);
    });

    test('韩语 → 日语 不是中英方向', () {
      expect(service.isEnZhDirection('ko', 'ja'), isFalse);
    });
  });
}
