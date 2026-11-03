import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_controller.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_models.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';
import 'package:video_player_app/features/ai_chat/ai_compaction_dialog.dart';
import 'package:video_player_app/features/ai_chat/ai_context_compaction.dart';
import 'package:video_player_app/features/ai_chat/ai_conversation_store.dart';
import 'package:video_player_app/features/ai_chat/ai_native_api_transport.dart';
import 'package:video_player_app/features/ai_chat/ai_prompt_composer.dart';
import 'package:video_player_app/features/ai_chat/ai_turn_plan.dart';
import 'package:video_player_app/features/ai_chat/ai_video_context.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/models/subtitle_model.dart';

const _summary = '用户纠正：不用英语，不要自动继续旧任务。结论：参数为42；待核查字幕 中文 [01:20]。';
const _videoContext = AiVideoContext(videoId: 'v', title: '视频');
final _video = VideoItem(
  id: 'v',
  path: 'video.mp4',
  title: '视频',
  durationMs: 1000,
  lastUpdated: 1,
);

List<AiChatMessage> _history({int turns = 6, int size = 500}) => [
  for (var i = 0; i < turns; i++) ...[
    AiChatMessage(
      id: 'u$i',
      role: 'user',
      content: '原始问题$i 不用英语 ${'甲' * size}',
    ),
    AiChatMessage(
      id: 'a$i',
      role: 'assistant',
      content: '原始回答$i ${'乙' * size}',
    ),
  ],
];

class _Transport extends AiChatTransport {
  String summary = _summary;
  String? finish = 'stop';
  bool failSummary = false;
  bool overflow = false;
  bool overflowAfterText = false;
  bool alwaysOverflow = false;
  bool failAnswer = false;
  bool waitSummary = false;
  Completer<void>? summaryGate;
  final started = Completer<void>();
  int answers = 0;
  final summaryRequests = <List<Map<String, String>>>[];
  final answerRequests = <List<Map<String, String>>>[];
  final configurations = <AiChatSettings>[];
  @override
  Stream<AiChatDelta> stream({
    required AiChatSettings settings,
    required List<Map<String, String>> messages,
    required AiChatCancellation cancellation,
  }) async* {
    if (messages.first['content'] == AiTurnPlanner.prompt) {
      yield const AiChatDelta(
        content:
            '{"source":"none","relation":"followup","query":"","task":"answer"}',
        finishReason: 'stop',
      );
      return;
    }
    if (messages.first['content']!.startsWith(AiContextCompaction.prompt)) {
      summaryRequests.add(messages);
      configurations.add(settings);
      if (!started.isCompleted) started.complete();
      await summaryGate?.future;
      if (waitSummary) {
        await cancellation.whenCancelled;
        return;
      }
      if (failSummary) throw const AiChatException('模拟摘要失败');
      yield AiChatDelta(
        content: summary,
        finishReason: finish,
        usage: const {
          'prompt_tokens': 100,
          'completion_tokens': 40,
          'total_tokens': 140,
        },
      );
      return;
    }
    answers++;
    answerRequests.add(messages);
    if (failAnswer) throw const AiChatException('模拟回答失败');
    if (overflow && (answers == 1 || alwaysOverflow)) {
      if (overflowAfterText) yield const AiChatDelta(content: '已输出');
      throw const AiChatException(
        'maximum context length exceeded',
        contextOverflow: true,
      );
    }
    yield const AiChatDelta(
      content: '正常回答',
      finishReason: 'stop',
      usage: {
        'prompt_tokens': 200,
        'completion_tokens': 20,
        'total_tokens': 220,
      },
    );
  }
}

AiRequestPreview _request({int fixed = 500, int window = 16000}) =>
    AiRequestPreview(
      systemPrompt: '',
      messages: const [],
      contextText: '',
      estimatedTokens: fixed,
      fixedTokens: fixed,
      contextLimit: window,
      omittedMessages: 0,
      warnings: const [],
      selectedChunks: const [],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'checkpoint rejects edits, rollback and malformed data while preserving old archives',
    () {
      final history = _history();
      final cp = AiContextCheckpoint(
        summary: _summary,
        coveredMessages: 8,
        prefixHash: AiContextCheckpoint.hashPrefix(history, 8),
        createdAt: DateTime.now(),
      );
      expect(cp.matches(history), isTrue);
      expect(cp.matches(history.take(7).toList()), isFalse);
      expect(
        cp.matches([
          history.first.copyWith(content: 'edited'),
          ...history.skip(1),
        ]),
        isFalse,
      );
      expect(
        AiContextCheckpoint.tryParse(cp.toJson())!.matches(history),
        isTrue,
      );
      expect(AiContextCheckpoint.tryParse({'version': 99}), isNull);
      final record = AiConversation(
        id: 'c',
        videoId: 'v',
        title: 't',
        messages: history,
        contextCheckpoint: cp,
      );
      expect(
        AiConversation.fromJson(
          record.toJson(),
        ).contextCheckpoint!.matches(history),
        isTrue,
      );
      final old = record.toJson()
        ..remove('contextCheckpoint')
        ..remove('compactionInfo');
      expect(AiConversation.fromJson(old).contextCheckpoint, isNull);
    },
  );

  for (final backend in AiBackend.values) {
    for (final protocol
        in backend == AiBackend.api
            ? AiApiProtocol.values
            : [AiApiProtocol.openAiCompatible]) {
      test(
        'portable compaction reuses $backend/$protocol without changing transcript',
        () async {
          final transport = _Transport();
          final history = _history();
          final settings = AiChatSettings(
            backend: backend,
            apiProtocol: protocol,
            model: 'private-model',
            baseUrl: 'http://localhost:1234/private',
            apiKey: 'private-key',
            contextTokens: 16000,
            maxOutputTokens: 1000,
            titlePrompt: '',
          );
          final plan = AiContextCompaction.plan(
            history: history,
            settings: settings,
            request: _request(),
            force: true,
          )!;
          expect(plan.end, 8);
          final result = await AiContextCompaction(transport).compact(
            plan: plan,
            history: history,
            settings: settings,
            cancellation: AiChatCancellation(),
            focus: '保留纠正和时间戳',
          );
          expect(result.checkpoint!.matches(history), isTrue);
          expect(history.length, 12);
          expect(transport.configurations.single.backend, backend);
          expect(transport.configurations.single.apiProtocol, protocol);
          expect(transport.configurations.single.apiKey, 'private-key');
          expect(transport.configurations.single.baseUrl, settings.baseUrl);
          expect(
            transport.summaryRequests.single.first['content'],
            contains('保留纠正和时间戳'),
          );
          expect(
            transport.summaryRequests.single.last['content'],
            isNot(contains('原始问题5')),
          );
          expect(
            result.info['after_tokens'],
            lessThan(result.info['before_tokens'] as int),
          );
          expect(result.info['usage']['total_tokens'], 140);
        },
      );
    }
  }

  test(
    'pressure uses untrimmed complete history and keeps failed answers out of memory',
    () {
      const settings = AiChatSettings(
        contextTokens: 16000,
        maxOutputTokens: 1000,
      );
      final history = [
        ..._history(turns: 12),
        AiChatMessage(id: 'failed-user', role: 'user', content: 'failed'),
        AiChatMessage(
          id: 'failed-answer',
          role: 'assistant',
          content: 'bad',
          status: 'error',
        ),
      ];
      final request = AiPromptComposer().build(
        settings: settings,
        video: _videoContext,
        question: '继续',
        selectedTrackIds: {},
        history: history,
      );
      expect(request.untrimmedTokens, greaterThan(request.estimatedTokens));
      final plan = AiContextCompaction.plan(
        history: history,
        settings: settings,
        request: request,
      )!;
      expect(plan.records.join(), isNot(contains('failed-answer')));
      expect(plan.beforeTokens, greaterThan(settings.requestInputBudget * .8));
      expect(
        AiContextCompaction.plan(
          history: _history(turns: 2, size: 1),
          settings: settings,
          request: _request(),
        ),
        isNull,
      );
    },
  );

  test(
    'incremental compaction combines previous summary with only newly covered turns',
    () async {
      final h = _history(turns: 8);
      final cp = AiContextCheckpoint(
        summary: _summary,
        coveredMessages: 4,
        prefixHash: AiContextCheckpoint.hashPrefix(h, 4),
        createdAt: DateTime.now(),
      );
      const settings = AiChatSettings(
        contextTokens: 16000,
        maxOutputTokens: 1000,
      );
      final plan = AiContextCompaction.plan(
        history: h,
        checkpoint: cp,
        settings: settings,
        request: _request(),
        force: true,
      )!;
      expect(plan.records.join(), contains(_summary));
      expect(plan.records.join(), contains('原始问题2'));
      expect(plan.records.join(), isNot(contains('原始问题0')));
      expect(plan.end, 12);
    },
  );

  for (final failure in ['empty', 'length', 'exception', 'larger', 'cancel']) {
    test('$failure summary never commits a replacement', () async {
      final t = _Transport();
      if (failure == 'empty') t.summary = '';
      if (failure == 'length') t.finish = 'length';
      if (failure == 'exception') t.failSummary = true;
      if (failure == 'larger') t.summary = '新增' * 5000;
      if (failure == 'cancel') t.waitSummary = true;
      final token = AiChatCancellation();
      final h = _history();
      const settings = AiChatSettings(
        contextTokens: 16000,
        maxOutputTokens: 1000,
      );
      final plan = AiContextCompaction.plan(
        history: h,
        settings: settings,
        request: _request(),
        force: true,
      )!;
      final pending = AiContextCompaction(t).compact(
        plan: plan,
        history: h,
        settings: settings,
        cancellation: token,
      );
      if (failure == 'cancel') {
        await t.started.future;
        token.cancel();
      }
      final result = await pending;
      expect(result.checkpoint, isNull);
      expect(
        result.info['status'],
        failure == 'cancel'
            ? 'cancelled'
            : failure == 'larger'
            ? 'skipped'
            : 'failed',
      );
    });
  }

  test(
    'Unicode source splitting is bounded and never truncates a completed checkpoint',
    () async {
      final t = _Transport();
      final h = _history(turns: 4, size: 10000);
      const settings = AiChatSettings(
        contextTokens: 6000,
        maxOutputTokens: 1000,
      );
      final plan = AiContextCompaction.plan(
        history: h,
        settings: settings,
        request: _request(window: 6000),
        force: true,
      )!;
      final result = await AiContextCompaction(t).compact(
        plan: plan,
        history: h,
        settings: settings,
        cancellation: AiChatCancellation(),
      );
      expect(result.checkpoint, isNull);
      expect(result.info['status'], 'failed');
      expect(t.summaryRequests.length, lessThanOrEqualTo(8));
    },
  );

  test(
    'summary survives retrieval resets and model changes without replaying covered raw turns',
    () {
      final h = _history();
      final cp = AiContextCheckpoint(
        summary: _summary,
        coveredMessages: 8,
        prefixHash: AiContextCheckpoint.hashPrefix(h, 8),
        createdAt: DateTime.now(),
      );
      for (final relation in ['new', 'repair', 'unclear', 'followup']) {
        final r = AiPromptComposer().build(
          settings: const AiChatSettings(model: 'other-model'),
          video: _videoContext,
          question: '最新完整问题',
          selectedTrackIds: {},
          history: h,
          checkpoint: cp,
          turnPlan: AiTurnPlan(source: 'none', relation: relation, query: ''),
        );
        final text = r.messages.map((m) => m['content']).join();
        expect(text, contains(_summary));
        expect(text, isNot(contains('原始问题0')));
        expect(text, contains('原始问题5'));
        expect(r.messages.last['content'], '最新完整问题');
      }
    },
  );

  test(
    'independent input/output limits do not subtract output twice and survive serialization',
    () {
      const base = AiChatSettings(
        model: 'native',
        baseUrl: 'http://private',
        contextTokens: 8000,
        maxOutputTokens: 2000,
        modelCatalogBaseUrl: 'http://private',
        savedModels: [
          AiModelInfo(
            id: 'native',
            contextWindow: 10000,
            maxInputTokens: 8000,
            maxOutputTokens: 4000,
            separateInputOutputLimits: true,
          ),
        ],
      );
      expect(base.requestInputBudget, 7488);
      expect(AiChatSettings.fromJson(base.toJson()).requestInputBudget, 7488);
      expect(AiChatSettings.fromJson({}).autoCompact, isTrue);
      expect(
        AiChatSettings.fromJson(
          base.copyWith(autoCompact: false).toJson(),
        ).autoCompact,
        isFalse,
      );
      final native = base.copyWith(
        apiProtocol: AiApiProtocol.gemini,
        modelCatalogProtocol: AiApiProtocol.gemini,
        requestInputTokens: 7500,
      );
      expect(
        () => AiNativeApiTransport.requestBody(native, const [
          {'role': 'user', 'content': 'input'},
        ]),
        returnsNormally,
      );
    },
  );

  test('only explicit input context errors qualify for overflow recovery', () {
    for (final text in [
      'context_length_exceeded',
      'maximum context length is 8192',
      'prompt is too long',
      'input token count exceeds maximum tokens',
    ]) {
      expect(AiChatException.isContextOverflow(text, statusCode: 400), isTrue);
      expect(AiChatException.isContextOverflow(text, statusCode: 429), isFalse);
    }
    for (final text in [
      'invalid API key',
      'invalid max_tokens',
      'payload too large',
      'MAX_TOKENS',
      'length',
    ]) {
      expect(AiChatException.isContextOverflow(text, statusCode: 400), isFalse);
    }
  });

  test('full subtitle source stays verbatim alongside conversation memory', () {
    final h = _history();
    final cp = AiContextCheckpoint(
      summary: _summary,
      coveredMessages: 8,
      prefixHash: AiContextCheckpoint.hashPrefix(h, 8),
      createdAt: DateTime.now(),
    );
    final video = AiVideoContext(
      videoId: 'v',
      title: '视频',
      tracks: [
        AiSubtitleTrack(
          id: 'raw',
          label: '中文',
          cues: [
            SubtitleItem(
              index: 0,
              startTime: const Duration(seconds: 80),
              endTime: const Duration(seconds: 90),
              text: '逐字原文：E=mc²，不能用聊天摘要替换本句。',
            ),
          ],
        ),
      ],
    );
    final request = AiPromptComposer().build(
      settings: const AiChatSettings(contextMode: AiContextMode.full),
      video: video,
      question: '解释原文公式',
      selectedTrackIds: {'raw'},
      history: h,
      checkpoint: cp,
    );
    expect(request.contextComplete, isTrue);
    expect(request.contextText, contains('E=mc²，不能用聊天摘要替换本句。'));
    expect(
      request.messages.map((m) => m['content']).join(),
      contains(_summary),
    );
  });

  for (final protocol in AiApiProtocol.values) {
    test(
      'real local HTTP roundtrip for summary uses $protocol wire format',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final requests = <Map<String, dynamic>>[];
        server.listen((request) async {
          requests.add(
            Map<String, dynamic>.from(
              jsonDecode(await utf8.decoder.bind(request).join()),
            ),
          );
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          void event(Map<String, dynamic> value) => request.response.add(
            utf8.encode('data: ${jsonEncode(value)}\n\n'),
          );
          switch (protocol) {
            case AiApiProtocol.openAiCompatible:
              event({
                'choices': [
                  {
                    'delta': {'content': _summary},
                    'finish_reason': 'stop',
                  },
                ],
                'usage': {
                  'prompt_tokens': 100,
                  'completion_tokens': 40,
                  'total_tokens': 140,
                },
              });
              request.response.write('data: [DONE]\n\n');
            case AiApiProtocol.anthropic:
              event({
                'type': 'message_start',
                'message': {
                  'usage': {'input_tokens': 100},
                },
              });
              event({
                'type': 'content_block_delta',
                'delta': {'type': 'text_delta', 'text': _summary},
              });
              event({
                'type': 'message_delta',
                'delta': {'stop_reason': 'end_turn'},
                'usage': {'output_tokens': 40},
              });
              event({'type': 'message_stop'});
            case AiApiProtocol.gemini:
              event({
                'candidates': [
                  {
                    'content': {
                      'parts': [
                        {'text': _summary},
                      ],
                    },
                    'finishReason': 'STOP',
                  },
                ],
                'usageMetadata': {
                  'promptTokenCount': 100,
                  'candidatesTokenCount': 40,
                  'totalTokenCount': 140,
                },
              });
          }
          await request.response.close();
        });
        final transport = AiChatTransport(
          httpClientFactory: () => HttpOverrides.runWithHttpOverrides(
            () => HttpClient()..findProxy = (_) => 'DIRECT',
            _RealOverrides(),
          ),
        );
        final h = _history();
        final settings = AiChatSettings(
          apiProtocol: protocol,
          model: 'private-model',
          baseUrl: 'http://127.0.0.1:${server.port}',
          apiKey: 'local-test-key',
          contextTokens: 16000,
          maxOutputTokens: 1000,
        );
        final plan = AiContextCompaction.plan(
          history: h,
          settings: settings,
          request: _request(),
          force: true,
        )!;
        final result = await AiContextCompaction(transport).compact(
          plan: plan,
          history: h,
          settings: settings,
          cancellation: AiChatCancellation(),
        );
        expect(
          result.checkpoint?.summary,
          _summary,
          reason: result.info.toString(),
        );
        expect(result.info['usage']['total_tokens'], 140);
        expect(
          requests.single.containsKey(
            protocol == AiApiProtocol.gemini ? 'contents' : 'messages',
          ),
          isTrue,
        );
      },
    );
  }

  group('controller', () {
    late Directory root;
    late AiConversationStore store;
    late AiChatController c;
    late _Transport t;
    Future<void> seed({
      bool auto = false,
      int turns = 6,
      int size = 500,
      AiBackend backend = AiBackend.codex,
    }) async {
      await store.save(
        AiConversation(
          id: 'c',
          videoId: 'v',
          title: '历史',
          messages: _history(turns: turns, size: size),
        ),
      );
      c = AiChatController(
        video: _video,
        transport: t,
        conversationStore: store,
        initialSettings: AiChatSettings(
          backend: backend,
          autoCompact: auto,
          contextTokens: 16000,
          maxOutputTokens: 1000,
          titlePrompt: '',
        ),
      );
      await c.initialize();
    }

    setUp(() async {
      root = await Directory.systemTemp.createTemp('context_compaction_');
      store = AiConversationStore(root: root);
      t = _Transport();
    });
    tearDown(() async {
      c.dispose();
      await store.load('v');
      await root.delete(recursive: true);
    });

    test(
      'manual compaction persists and pure preview never makes requests',
      () async {
        await seed();
        for (var i = 0; i < 4; i++) {
          c.preview('草稿$i');
        }
        expect(t.summaryRequests, isEmpty);
        await c.compactContext(focus: '保留纠正');
        expect(c.active!.messages.length, 12);
        expect(c.contextCheckpoint, isNotNull);
        expect(
          (await store.load('v')).single.contextCheckpoint!.summary,
          _summary,
        );
        expect(c.lastRequest, isNull);
        final request = c.preview('继续');
        expect(
          request.messages.map((m) => m['content']).join(),
          contains(_summary),
        );
        c.dispose();
        c = AiChatController(
          video: _video,
          transport: t,
          conversationStore: store,
          initialSettings: const AiChatSettings(backend: AiBackend.codex),
        );
        await c.initialize();
        expect(c.contextCheckpoint!.summary, _summary);
      },
    );

    test(
      'automatic compaction happens before clipped history reaches the model',
      () async {
        await seed(auto: true, turns: 12);
        await c.send('继续');
        expect(t.summaryRequests.length, inInclusiveRange(1, 8));
        expect(
          t.answerRequests.single.map((m) => m['content']).join(),
          contains(_summary),
        );
        expect(c.active!.messages.length, 26);
        expect(c.active!.messages.last.status, 'complete');
        expect(
          c.active!.messages.last.responseInfo!['compaction']['status'],
          'completed',
        );
      },
    );

    test(
      'failed automatic range cools down but manual retry remains available',
      () async {
        await seed(auto: true, turns: 12);
        t.failSummary = true;
        t.failAnswer = true;
        await c.send('继续');
        final attempts = t.summaryRequests.length;
        await c.send('另一个问题，但历史仍未新增完整轮次');
        expect(t.summaryRequests.length, attempts);
        c.preview('继续');
        c.preview('继续');
        expect(t.summaryRequests.length, attempts);
        t.failSummary = false;
        await c.compactContext();
        expect(c.contextCheckpoint, isNotNull);
      },
    );

    test(
      'stop and conversation navigation preserve ownership and prior checkpoint',
      () async {
        await seed();
        t.waitSummary = true;
        final pending = c.compactContext();
        await t.started.future;
        expect(c.compacting, isTrue);
        c.stop();
        await pending;
        expect(c.contextCheckpoint, isNull);
        expect(c.active!.compactionInfo!['status'], 'cancelled');
        expect(c.active!.messages.length, 12);
      },
    );

    test(
      'edit and branch validate checkpoints against their actual prefix',
      () async {
        await seed();
        await c.compactContext();
        await c.forkAt('a5');
        expect(c.contextCheckpoint, isNotNull);
        await c.forkAt('a1');
        expect(c.contextCheckpoint, isNull);
        await c.selectConversation('c');
        await c.editMessage('u0', '改正开头');
        expect(c.contextCheckpoint, isNull);
        expect(c.active!.messages.length, 2);
        expect(
          c.preview('继续').messages.map((m) => m['content']).join(),
          isNot(contains(_summary)),
        );
      },
    );

    test(
      'explicit overflow compresses once and retries while keeping the user turn whole',
      () async {
        await seed(auto: true, turns: 3, size: 100);
        t.overflow = true;
        await c.send('最新用户问题不得改写');
        expect(t.answers, 2);
        expect(t.summaryRequests, hasLength(1));
        expect(c.active!.messages.last.status, 'complete');
        expect(c.active!.messages.last.responseInfo!['overflow_retries'], 1);
        expect(t.answerRequests.last.last['content'], '最新用户问题不得改写');
      },
    );

    test('overflow after visible text is never replayed', () async {
      await seed(auto: true, turns: 3, size: 100);
      t.overflow = true;
      t.overflowAfterText = true;
      await c.send('最新问题');
      expect(t.answers, 1);
      expect(t.summaryRequests, isEmpty);
      expect(c.active!.messages.last.content, '已输出');
      expect(c.active!.messages.last.status, 'error');
    });

    test(
      'background compression commits only to its originating conversation',
      () async {
        await seed();
        final gate = Completer<void>();
        t.summaryGate = gate;
        final pending = c.compactContext();
        await t.started.future;
        await c.createConversation();
        final next = c.active!.id;
        c.updateDraft('新对话草稿');
        c.stop();
        gate.complete();
        await pending;
        expect(c.active!.id, next);
        expect(c.contextCheckpoint, isNull);
        expect(c.active!.draftText, '新对话草稿');
        expect(
          c.conversations
              .singleWhere((record) => record.id == 'c')
              .contextCheckpoint,
          isNotNull,
        );
      },
    );

    test(
      'a second explicit overflow fails without a second compression loop',
      () async {
        await seed(auto: true, turns: 3, size: 100);
        t.overflow = true;
        t.alwaysOverflow = true;
        await c.send('问题');
        expect(t.answers, 2);
        expect(t.summaryRequests, hasLength(1));
        expect(c.active!.messages.last.status, 'error');
      },
    );

    test(
      'failure and cancellation preserve an existing valid checkpoint and request',
      () async {
        await seed();
        await c.compactContext();
        final checkpoint = c.contextCheckpoint!;
        await c.send('新的完整轮次一');
        await c.send('新的完整轮次二');
        final request = c.lastRequest;
        t.failSummary = true;
        await c.compactContext();
        expect(c.contextCheckpoint!.prefixHash, checkpoint.prefixHash);
        expect(c.lastRequest, same(request));
        t.failSummary = false;
        t.waitSummary = true;
        final pending = c.compactContext();
        await Future<void>.delayed(Duration.zero);
        c.stop();
        await pending;
        expect(c.contextCheckpoint!.prefixHash, checkpoint.prefixHash);
        expect(c.lastRequest, same(request));
        expect(
          (await store.load('v')).single.contextCheckpoint!.prefixHash,
          checkpoint.prefixHash,
        );
      },
    );

    for (final size in [const Size(180, 360), const Size(400, 240)]) {
      testWidgets('compression controls fit $size with enlarged text', (
        tester,
      ) async {
        await tester.runAsync(() => seed());
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(2)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showAiCompactionDialog(context, c),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('ai-compact-now')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets(
      'narrow dialog supports focus, live result and viewing a stored summary',
      (tester) async {
        await tester.runAsync(() async {
          await seed();
          await (FontLoader('MiSans')
                ..addFont(rootBundle.load('assets/fonts/MiSans-Regular.otf')))
              .load();
          await (FontLoader('MaterialIcons')
                ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
              .load();
        });
        tester.view.physicalSize = const Size(240, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          RepaintBoundary(
            key: const ValueKey('compaction-preview'),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(fontFamily: 'MiSans'),
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => showAiCompactionDialog(context, c),
                    child: const Text('打开'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('ai-compaction-focus')),
          '保留纠正',
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('ai-compact-now')),
        );
        await tester.runAsync(() async {
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('ai-compact-now')),
              )
              .onPressed!();
          while (c.busy) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        await tester.pumpAndSettle();
        expect(c.contextCheckpoint, isNotNull);
        expect(
          find.byKey(const ValueKey('ai-compaction-result')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('ai-compaction-summary')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('compaction-preview')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              '.artifacts/ai-chat/context-compaction-preview.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      },
    );
  });
}

class _RealOverrides extends HttpOverrides {}
