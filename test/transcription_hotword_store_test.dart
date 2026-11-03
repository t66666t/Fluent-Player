import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/transcription_hotword_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('video words remain isolated and survive reopening', () async {
    final store = TranscriptionHotwordStore();
    await store.setWords('id:video-a', ' 张三 \r\n\nOpenAI\n张三 ');
    expect(store.wordsFor('id:video-a'), '张三\nOpenAI');
    expect(store.wordsFor('id:video-b'), isEmpty);
    await store.setWords('id:video-b', '李四');
    final reopened = TranscriptionHotwordStore();
    await reopened.load();
    expect(reopened.wordsFor('id:video-a'), '张三\nOpenAI');
    expect(reopened.wordsFor('id:video-b'), '李四');
    await reopened.setWords('id:video-a', '');
    expect(reopened.wordsFor('id:video-b'), '李四');
    expect(reopened.wordsFor('id:video-a'), isEmpty);
  });

  test(
    'named presets do not apply until explicitly copied to one video',
    () async {
      final store = TranscriptionHotwordStore();
      await store.savePreset(name: ' 医学讲座 ', words: '心房颤动\n电生理');
      final preset = store.presets.single;
      expect(preset.name, '医学讲座');
      expect(store.wordsFor('id:a'), isEmpty);
      await store.setWords('id:a', preset.words);
      expect(store.wordsFor('id:b'), isEmpty);
      await store.savePreset(id: preset.id, name: '心内科', words: '消融');
      expect(store.presets.single.name, '心内科');
      expect(store.wordsFor('id:a'), '心房颤动\n电生理');
      final reopened = TranscriptionHotwordStore();
      await reopened.load();
      expect(reopened.presets.single.words, '消融');
      await reopened.deletePreset(preset.id);
      expect(reopened.presets, isEmpty);
      expect(reopened.wordsFor('id:a'), '心房颤动\n电生理');
    },
  );

  test(
    'legacy words become a reusable preset once and never a video default',
    () async {
      final store = TranscriptionHotwordStore();
      await store.preserveLegacyWords('原有名词');
      expect(store.presets.single.id, 'legacy-hotwords');
      expect(store.wordsFor('id:a'), isEmpty);
      await store.deletePreset('legacy-hotwords');
      final reopened = TranscriptionHotwordStore();
      await reopened.preserveLegacyWords('原有名词');
      expect(reopened.presets, isEmpty);
    },
  );

  test('concurrent saves retain each video and preset', () async {
    final store = TranscriptionHotwordStore();
    await Future.wait([
      store.setWords('id:a', '甲'),
      store.setWords('id:b', '乙'),
      store.savePreset(name: '领域一', words: '词一'),
      store.savePreset(name: '领域二', words: '词二'),
    ]);
    expect(store.wordsFor('id:a'), '甲');
    expect(store.wordsFor('id:b'), '乙');
    expect(store.presets.map((p) => p.name), ['领域一', '领域二']);
  });

  test('corrupt data is preserved and can be retried after recovery', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(TranscriptionHotwordStore.presetsKey, '{invalid');
    final store = TranscriptionHotwordStore();
    await expectLater(store.load(), throwsFormatException);
    await expectLater(store.setWords('id:a', '新词'), throwsFormatException);
    expect(prefs.getString(TranscriptionHotwordStore.presetsKey), '{invalid');
    expect(prefs.getString(TranscriptionHotwordStore.videosKey), isNull);
    await prefs.setString(
      TranscriptionHotwordStore.presetsKey,
      jsonEncode({'version': 1, 'presets': []}),
    );
    await store.setWords('id:a', '新词');
    expect(store.wordsFor('id:a'), '新词');
  });

  test(
    'invalid or duplicate names and oversized words do not replace presets',
    () async {
      final store = TranscriptionHotwordStore();
      await store.savePreset(name: 'OpenAI', words: 'Whisper');
      await expectLater(
        store.savePreset(name: 'openai', words: 'Other'),
        throwsFormatException,
      );
      expect(
        () => store.savePreset(name: '', words: '内容'),
        throwsFormatException,
      );
      expect(
        () =>
            store.setWords('id:a', List.generate(101, (i) => '词$i').join('\n')),
        throwsFormatException,
      );
      expect(() => store.setWords('id:a', '词' * 121), throwsFormatException);
      expect(store.presets.single.words, 'Whisper');
    },
  );
}
