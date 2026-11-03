import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_models.dart';
import 'package:video_player_app/features/ai_chat/ai_conversation_store.dart';

void main() {
  late Directory directory;
  late AiConversationStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ai_store_test_');
    store = AiConversationStore(root: directory);
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  AiConversation conversation(String title) => AiConversation(
    id: '../unsafe-id',
    videoId: '../video',
    title: title,
    messages: [
      AiChatMessage(
        id: 'message',
        role: 'assistant',
        content: '部分回答',
        status: 'streaming',
      ),
    ],
  );
  test(
    'serializes concurrent writes and restores streaming messages as interrupted',
    () async {
      final first = store.save(conversation('第一版'));
      final second = store.save(conversation('第二版'));
      await Future.wait([first, second]);
      final loaded = await store.load('../video');
      expect(loaded.single.title, '第二版');
      expect(loaded.single.messages.single.status, 'cancelled');
      expect(await store.load('another-video'), isEmpty);
      final files = await directory
          .list(recursive: true)
          .where((e) => e is File)
          .toList();
      expect(files.every((e) => e.path.startsWith(directory.path)), isTrue);
    },
  );
  test(
    'recovers corrupted latest file from backup and preserves damaged file',
    () async {
      await store.save(conversation('有效备份'));
      await store.save(conversation('最新版本'));
      final file =
          (await directory
                      .list(recursive: true)
                      .where((e) => e is File && e.path.endsWith('.json'))
                      .toList())
                  .single
              as File;
      await file.writeAsString('{broken');
      final loaded = await store.load('../video');
      expect(loaded.single.title, '有效备份');
      expect(store.warnings, isNotEmpty);
      expect(await file.readAsString(), '{broken');
    },
  );
  test('delete removes both record and backup', () async {
    await store.save(conversation('旧版'));
    await store.save(conversation('新版'));
    await store.delete('../video', '../unsafe-id');
    expect(await store.load('../video'), isEmpty);
  });
  test('branch origin and intentionally empty selection survive roundtrip', () {
    final branch = AiConversation(
      id: 'branch',
      videoId: 'v',
      title: '分支',
      parentConversationId: 'origin',
      parentMessageId: 'turn',
      selectedTrackIds: {},
      selectionIsAutomatic: false,
    );
    final restored = AiConversation.fromJson(
      jsonDecode(jsonEncode(branch.toJson())) as Map<String, dynamic>,
    );
    expect(restored.parentConversationId, 'origin');
    expect(restored.parentMessageId, 'turn');
    expect(restored.selectedTrackIds, isEmpty);
    expect(restored.selectionIsAutomatic, isFalse);
  });
  test('old explicitly saved selections are retained as manual', () {
    final json = conversation('旧记录').copyWith(selectedTrackIds: {}).toJson()
      ..remove('selectionIsAutomatic');
    expect(AiConversation.fromJson(json).selectionIsAutomatic, isFalse);
    json.remove('selectedTrackIds');
    expect(AiConversation.fromJson(json).selectionIsAutomatic, isTrue);
  });
}
