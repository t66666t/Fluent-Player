import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';
import 'package:video_player_app/services/transcription_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('自动方向按字幕正文在中英之间选择，判断不了就译成简体中文', () {
    final chinese = resolveTranscriptTranslation(
      direction: TranscriptTranslateDirection.auto,
      subtitleText: '1\n00:00:01,000 --> 00:00:02,000\n今天天气很好，我们出去走走。',
    );
    expect(chinese.targetLanguage, 'en');
    expect(chinese.assumedSimplifiedChinese, isFalse);

    final english = resolveTranscriptTranslation(
      direction: TranscriptTranslateDirection.auto,
      subtitleText: 'Hello there, this is a spoken sentence for the test.',
    );
    expect(english.sourceLanguage, 'en');
    expect(english.targetLanguage, 'zh-CN');

    final unclear = resolveTranscriptTranslation(
      direction: TranscriptTranslateDirection.auto,
      subtitleText: '123',
    );
    expect(unclear.targetLanguage, 'zh-CN');
    expect(unclear.assumedSimplifiedChinese, isTrue);

    final forced = resolveTranscriptTranslation(
      direction: TranscriptTranslateDirection.toEnglish,
      subtitleText: '今天天气很好',
    );
    expect(forced.targetLanguage, 'en');
    expect(forced.assumedSimplifiedChinese, isFalse);
  });

  test('翻译服务和方向写入同一份设置', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SubtitleTranslateSettings();
    await settings.ensureLoaded();
    expect(settings.providerEnZh, SubtitleTranslateProvider.bing);
    expect(settings.direction, TranscriptTranslateDirection.auto);

    await settings.setProviderEnZh(SubtitleTranslateProvider.bing);
    await settings.setDirection(TranscriptTranslateDirection.toChinese);
    final again = SubtitleTranslateSettings();
    await again.ensureLoaded();
    expect(again.providerEnZh, SubtitleTranslateProvider.bing);
    expect(again.direction, TranscriptTranslateDirection.toChinese);
    expect(again.summary, '必应翻译 · 自动检测 → 简体中文');
  });

  test('未开始的批量任务不会翻译，点开始时才记下选择', () async {
    final manager = TranscriptionManager();
    addTearDown(manager.dispose);
    await manager.startTranscription(
      'plain.mp4',
      autoStart: false,
      translateChoice: const TranscriptTranslateChoice.off(),
    );
    await manager.startTranscription('waiting.mp4', autoStart: false);
    await manager.startTranscription(
      'translate.mp4',
      autoStart: false,
      translateChoice: const TranscriptTranslateChoice.automatic(),
    );

    expect(manager.translateEnabledForVideo('plain.mp4'), isFalse);
    expect(manager.translateEnabledForVideo('waiting.mp4'), isFalse);
    expect(manager.translateEnabledForVideo('translate.mp4'), isTrue);
  });

  for (final legacy in ['google', 'so360', 'mymemory', 'reverso', 'unknown']) {
    test('已移除的服务 $legacy 自动迁移为必应并保留翻译方向', () async {
      SharedPreferences.setMockInitialValues({
        SubtitleTranslateSettings.providerEnZhKey: legacy,
        SubtitleTranslateSettings.directionKey: 'toEnglish',
      });
      final settings = SubtitleTranslateSettings();
      addTearDown(settings.dispose);
      await settings.ensureLoaded();
      expect(settings.providerEnZh, SubtitleTranslateProvider.bing);
      expect(settings.direction, TranscriptTranslateDirection.toEnglish);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(SubtitleTranslateSettings.providerEnZhKey),
        'bing',
      );
    });
  }

  for (final provider in SubtitleTranslateProvider.values) {
    test('保留 ${provider.name} 的现有选择', () async {
      SharedPreferences.setMockInitialValues({
        SubtitleTranslateSettings.providerEnZhKey: provider.name,
      });
      final settings = SubtitleTranslateSettings();
      addTearDown(settings.dispose);
      await settings.ensureLoaded();
      expect(settings.providerEnZh, provider);
      expect(subtitleTranslateProviderLabels.keys, [
        SubtitleTranslateProvider.bing,
        SubtitleTranslateProvider.ai,
        SubtitleTranslateProvider.local,
      ]);
    });
  }
}
