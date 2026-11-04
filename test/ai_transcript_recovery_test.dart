import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';
import 'package:video_player_app/features/ai_chat/ai_transcript_preparation.dart';
import 'package:video_player_app/features/ai_chat/ai_video_context.dart';
import 'package:video_player_app/models/subtitle_model.dart';

class _Transport extends AiChatTransport {
  final requests = <AiChatSettings>[];
  final conversations = <List<Map<String, String>>>[];
  final successfulInputs = <String>[];
  bool failFirst = false,
      thoughtOnlyFirst = false,
      filter = false,
      alwaysLength = false;
  int? maximumSourceCharacters;
  @override
  Stream<AiChatDelta> stream({
    required AiChatSettings settings,
    required List<Map<String, String>> messages,
    required AiChatCancellation cancellation,
  }) async* {
    requests.add(settings);
    conversations.add(messages);
    final text = messages.firstWhere(
      (message) =>
          message['role'] == 'user' && message['content']!.contains('\n资料开始\n'),
    )['content']!;
    final source = RegExp(
      r'\n资料开始\n([\s\S]*)\n资料结束$',
    ).firstMatch(text)!.group(1)!;
    final failed =
        alwaysLength ||
        (failFirst && requests.length == 1) ||
        (maximumSourceCharacters != null &&
            source.length > maximumSourceCharacters!);
    final thoughtOnly = thoughtOnlyFirst && requests.length == 1;
    if (!failed && !thoughtOnly && !filter) successfulInputs.add(source);
    yield AiChatDelta(
      content: filter || thoughtOnly
          ? ''
          : failed
          ? '已完成条目一，'
          : '完整记录 [00:10] 事实与例子。',
      reasoning: thoughtOnly ? '服务仍在思考，还没有正文' : '',
      finishReason: filter
          ? 'content_filter'
          : failed
          ? 'length'
          : 'stop',
      usage: {
        'prompt_tokens': 100,
        'completion_tokens': failed || thoughtOnly
            ? settings.maxOutputTokens
            : 20,
      },
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Transport transport;
  late AiVideoContext video;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ai_recovery_');
    transport = _Transport();
    video = AiVideoContext(
      videoId: 'v',
      title: '长视频',
      tracks: [
        AiSubtitleTrack(
          id: 'p',
          label: '主字幕',
          cues: List.generate(
            60,
            (i) => SubtitleItem(
              index: i,
              startTime: Duration(seconds: i * 10),
              endTime: Duration(seconds: i * 10 + 9),
              text: '独有事实编号$i ${'知识' * 70}',
            ),
          ),
        ),
      ],
    );
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  Future<AiPreparedTranscript> prepare({
    AiChatSettings settings = const AiChatSettings(),
    AiChatCancellation? cancellation,
    void Function(String)? onRecovery,
    void Function(Map<String, dynamic>)? onUsage,
  }) => AiTranscriptPreparation(transport: transport, root: root).prepare(
    video: video,
    selectedTrackIds: {'p'},
    settings: settings,
    question: '总结整个视频',
    targetTokens: 3500,
    cancellation: cancellation ?? AiChatCancellation(),
    onProgress: (_, _, _) {},
    onRecovery: onRecovery,
    onUsage: onUsage,
  );

  test(
    'compact theme indexing has a bounded output and disables optional thinking',
    () async {
      final result = await prepare();
      expect(transport.requests.first.maxOutputTokens, lessThanOrEqualTo(2048));
      expect(result.usage['record_style'], 'topic_index');
      expect(transport.requests.first.thinkingEnabled, isFalse);
      final body = AiChatTransport.apiRequestBody(transport.requests.first, [
        {'role': 'user', 'content': 'test'},
      ]);
      expect(body['thinking'], {'type': 'disabled'});
      expect(result.usage['calls'], result.segments);
      final attempt = (result.usage['attempts'] as List).first as Map;
      expect(attempt['output_limit'], transport.requests.first.maxOutputTokens);
      expect(attempt['finish_reason'], 'stop');
    },
  );

  test(
    'length continues from the partial record and charges both attempts before caching completion',
    () async {
      transport.failFirst = true;
      final status = <String>[];
      final result = await prepare(onRecovery: status.add);
      expect(
        transport.requests[1].maxOutputTokens,
        transport.requests.first.maxOutputTokens,
      );
      expect(result.usage['calls'], result.segments + 1);
      expect(
        result.usage['completion_tokens'],
        transport.requests.first.maxOutputTokens + result.segments * 20,
      );
      expect('已完成条目一，'.allMatches(result.text), hasLength(1));
      expect(transport.conversations[1][2]['role'], 'assistant');
      expect(transport.conversations[1][2]['content'], '已完成条目一，');
      expect((result.usage['attempts'] as List)[1]['action'], 'continue');
      expect(status.any((value) => value.contains('接着')), isTrue);
      final calls = transport.requests.length;
      final cached = await prepare();
      expect(transport.requests.length, calls);
      expect(cached.usage['calls'], 0);
      expect(cached.usage['estimated_input_spent'], 0);
    },
  );

  test(
    'repeated length splits source, processes every cue, and caches the complete parent',
    () async {
      transport.maximumSourceCharacters = 4000;
      final result = await prepare();
      for (var i = 0; i < 60; i++) {
        expect(transport.successfulInputs.join('\n'), contains('独有事实编号$i '));
      }
      expect(result.usage['calls'], greaterThan(result.segments));
      expect(result.text, isNot(contains('已完成条目一，')));
      final calls = transport.requests.length;
      await prepare();
      expect(transport.requests.length, calls);
    },
  );

  test(
    'reasoning-only output recovers with lowest supported effort and room for a body',
    () async {
      transport.thoughtOnlyFirst = true;
      const config = AiChatSettings(
        baseUrl: 'https://provider.example/v1',
        model: 'required-thinking',
        modelCatalogBaseUrl: 'https://provider.example/v1',
        savedModels: [
          AiModelInfo(
            id: 'required-thinking',
            supportsThinking: true,
            canDisableThinking: false,
            reasoningEfforts: ['low', 'high'],
            maxOutputTokens: 32768,
          ),
        ],
      );
      final result = await prepare(settings: config);
      expect(transport.requests.first.thinkingEnabled, isTrue);
      expect(transport.requests.first.reasoningEffort, 'low');
      expect(
        transport.requests[1].maxOutputTokens,
        greaterThan(transport.requests.first.maxOutputTokens),
      );
      expect(result.text, contains('完整记录'));
    },
  );

  test(
    'filter failures show segment details and do not trigger retries',
    () async {
      transport.filter = true;
      await expectLater(
        prepare(),
        throwsA(
          isA<AiChatException>().having(
            (error) => error.message,
            'message',
            contains('内容过滤'),
          ),
        ),
      );
      expect(transport.requests.length, 1);
    },
  );

  test(
    'cancel during automatic recovery prevents another charged request',
    () async {
      transport.failFirst = true;
      final cancellation = AiChatCancellation();
      await expectLater(
        prepare(
          cancellation: cancellation,
          onRecovery: (_) => cancellation.cancel(),
        ),
        throwsA(isA<AiChatException>()),
      );
      expect(transport.requests.length, 1);
    },
  );

  test('output allocation respects model output limit', () async {
    const config = AiChatSettings(
      baseUrl: 'https://provider.example/v1',
      model: 'small',
      contextTokens: 6000,
      maxOutputTokens: 1000,
      modelCatalogBaseUrl: 'https://provider.example/v1',
      savedModels: [
        AiModelInfo(id: 'small', contextWindow: 6000, maxOutputTokens: 1500),
      ],
    );
    await prepare(settings: config);
    expect(
      transport.requests.every((request) => request.maxOutputTokens <= 1500),
      isTrue,
    );
  });

  test(
    'permanent truncation is bounded and retains diagnostics and charged tokens',
    () async {
      transport.alwaysLength = true;
      Map<String, dynamic>? usage;
      await expectLater(
        prepare(onUsage: (value) => usage = value),
        throwsA(
          isA<AiChatException>().having(
            (error) => error.message,
            'message',
            contains('预算'),
          ),
        ),
      );
      expect(transport.requests.length, lessThanOrEqualTo(8));
      expect(usage?['calls'], transport.requests.length);
      expect(usage?['attempts'], hasLength(transport.requests.length));
      expect(usage?['total_tokens'], greaterThan(0));
      expect(usage?['calls'], lessThanOrEqualTo(usage!['call_limit'] as int));
      expect(
        usage?['estimated_input_spent'],
        lessThanOrEqualTo(usage!['estimated_input_limit'] as int),
      );
    },
  );
}
