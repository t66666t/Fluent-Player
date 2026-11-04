import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_models.dart';
import 'package:video_player_app/features/ai_chat/ai_conversation_export.dart';
import 'package:video_player_app/features/ai_chat/ai_video_context.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/video_item.dart';

VideoItem _video() => VideoItem(
  id: 'media',
  path: r'C:\private\lesson.mp4',
  title: '课程',
  durationMs: 600000,
  lastUpdated: 0,
);

AiConversation _record({
  String id = 'conversation',
  List<AiChatMessage>? messages,
  Set<String>? tracks,
}) => AiConversation(
  id: id,
  videoId: 'media',
  title: '完整学习笔记',
  selectedTrackIds: tracks,
  messages:
      messages ??
      [
        AiChatMessage(id: 'question', role: 'user', content: '请总结'),
        AiChatMessage(
          id: 'answer',
          role: 'assistant',
          content:
              r'公式 $x^2$ 和 [00:01]，表格、代码与换行'
              '\n```dart\nprint(1);\n```',
          reasoning: '私有思考内容',
          status: 'cancelled',
        ),
      ],
  draftText: '尚未发送的私密草稿',
  lastRequest: const AiRequestPreview(
    systemPrompt: '系统提示和凭据不应导出',
    messages: [
      {'role': 'system', 'content': 'request secret'},
    ],
    contextText: '',
    estimatedTokens: 0,
    omittedMessages: 0,
    warnings: [],
    selectedChunks: [],
  ),
);

void main() {
  test(
    'exports all original turns instead of clipped request or compacted memory',
    () {
      final messages = [
        for (var i = 0; i < 500; i++)
          AiChatMessage(
            id: 'm$i',
            role: i.isEven ? 'user' : 'assistant',
            content: '第 $i 轮：${'长文本' * 20}',
          ),
      ];
      final record = _record(messages: messages);
      final document = AiConversationExport(
        video: _video(),
        conversations: [record],
      );
      final json = document.data;
      expect(
        (json['conversations'] as List).single['messages'],
        hasLength(500),
      );
      for (final format in AiConversationExportFormat.values) {
        final contents = document.render(format);
        expect(contents, contains('第 0 轮'));
        expect(contents, contains('第 499 轮'));
        expect(contents, isNot(contains('request secret')));
        expect(contents, isNot(contains('私密草稿')));
        expect(contents, isNot(contains(r'C:\private')));
      }
    },
  );

  test('keeps original markdown and statuses, with reasoning opt-in', () {
    final record = _record();
    for (final format in AiConversationExportFormat.values) {
      final basic = AiConversationExport(
        video: _video(),
        conversations: [record],
      ).render(format);
      expect(basic, contains('print(1);'));
      expect(basic, contains('cancelled'));
      expect(basic, isNot(contains('私有思考内容')));
      final extended = AiConversationExport(
        video: _video(),
        conversations: [record],
        includeReasoning: true,
      ).render(format);
      expect(extended, contains('私有思考内容'));
    }
  });

  test('preserves branch ancestry and excludes records from another media', () {
    final branch = AiConversation(
      id: 'branch',
      videoId: 'media',
      title: '分支',
      parentConversationId: 'conversation',
      parentMessageId: 'answer',
      messages: _record().messages,
    );
    final foreign = AiConversation(
      id: 'foreign',
      videoId: 'another-media',
      title: '不得混入',
      messages: _record().messages,
    );
    final document = AiConversationExport(
      video: _video(),
      conversations: [_record(), branch, foreign],
    );
    final records =
        jsonDecode(
              document.render(AiConversationExportFormat.json),
            )['conversations']
            as List;
    expect(records, hasLength(2));
    expect(records.last['parentConversationId'], 'conversation');
    expect(records.last['parentMessageId'], 'answer');
    expect(document.render(), contains('分支来源：conversation'));
    expect(document.render(), isNot(contains('不得混入')));
  });

  test(
    'attaches complete selected transcripts with timestamps, aliases and missing sources',
    () {
      final context = AiVideoContext(
        videoId: 'media',
        title: '课程',
        metadata: {
          'source':
              'https://user:password@example.com/course?token=secret#private',
          'apiKey': 'must not export',
        },
        tracks: [
          AiSubtitleTrack(
            id: 'stable',
            aliases: {'old-track'},
            label: '中文',
            cues: [
              for (var i = 0; i < 1000; i++)
                SubtitleItem(
                  index: i,
                  startTime: Duration(milliseconds: i * 600),
                  endTime: Duration(milliseconds: (i + 1) * 600),
                  text: '文稿 $i',
                ),
            ],
          ),
          AiSubtitleTrack(
            id: 'unselected',
            label: '其他语言',
            cues: [
              SubtitleItem(
                index: 0,
                startTime: Duration.zero,
                endTime: const Duration(seconds: 1),
                text: '不应附加',
              ),
            ],
          ),
        ],
      );
      final document = AiConversationExport(
        video: _video(),
        conversations: [
          _record(tracks: {'old-track', 'missing'}),
        ],
        videoContext: context,
        includeTranscripts: true,
      );
      final transcript = document.data['transcripts'] as Map;
      expect(transcript['missingTrackIds'], ['missing']);
      expect((transcript['tracks'] as List).single['cues'], hasLength(1000));
      final markdown = document.render();
      expect(markdown, contains('文稿 999'));
      expect(markdown, contains('[00:00:00.000–00:00:00.600]'));
      expect(markdown, contains('https://example.com/course'));
      expect(markdown, isNot(contains('token=secret')));
      expect(markdown, isNot(contains('password')));
      expect(markdown, isNot(contains('不应附加')));
      expect(
        document.render(AiConversationExportFormat.json),
        isNot(contains('must not export')),
      );
      final noSelection = AiConversationExport(
        video: _video(),
        conversations: [_record(tracks: {})],
        videoContext: context,
        includeTranscripts: true,
      );
      expect(noSelection.tracks, isEmpty);
      expect(noSelection.render(), contains('没有可附加的所选文稿'));
    },
  );

  test('source attachment is opt-in and filenames are Windows-safe', () {
    final record = AiConversation(
      id: 'c',
      videoId: 'media',
      title: 'CON:/\\<>*?. ',
      messages: _record().messages,
    );
    final document = AiConversationExport(
      video: _video(),
      conversations: [record],
    );
    expect(document.data.containsKey('transcripts'), isFalse);
    expect(
      document.fileName(AiConversationExportFormat.markdown),
      endsWith('.md'),
    );
    expect(
      document.fileName(AiConversationExportFormat.text),
      isNot(contains(RegExp(r'[<>:"/\\|?*]'))),
    );
  });
}
