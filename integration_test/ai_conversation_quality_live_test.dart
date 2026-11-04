import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_controller.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_models.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';
import 'package:video_player_app/features/ai_chat/ai_conversation_store.dart';
import 'package:video_player_app/features/ai_chat/ai_turn_plan.dart';
import 'package:video_player_app/features/ai_chat/ai_transcript_preparation.dart';
import 'package:video_player_app/features/ai_chat/ai_prompt_composer.dart';
import 'package:video_player_app/features/ai_chat/ai_token_usage.dart';
import 'package:video_player_app/features/ai_chat/ai_video_context.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/utils/subtitle_parser.dart';

class _Loader extends AiVideoContextLoader {
  _Loader(this.source);
  final AiVideoContext source;
  @override
  Future<AiVideoContext> load({
    required VideoItem video,
    List<SubtitleItem> primarySubtitles = const [],
    List<SubtitleItem> secondarySubtitles = const [],
    Duration position = Duration.zero,
    String? primaryPath,
    String? secondaryPath,
  }) async => source;
}

class _RecordingTransport extends AiChatTransport {
  final sourceInputs = <String>[];
  @override
  Stream<AiChatDelta> stream({
    required AiChatSettings settings,
    required List<Map<String, String>> messages,
    required AiChatCancellation cancellation,
  }) {
    if (messages.first['content'] == settings.transcriptPrompt) {
      sourceInputs.add(
        messages.firstWhere((message) => message['role'] == 'user')['content']!,
      );
    }
    return super.stream(
      settings: settings,
      messages: messages,
      cancellation: cancellation,
    );
  }
}

/// Explicit opt-in paid evaluation using the installed app's native credential
/// store. No credentials, profiles, or private conversation history are logged.
/// Bounded to 14 planner calls and 4 answers, each answer at most 768 tokens.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('AI_LIVE_QUALITY');
  testWidgets(
    'DeepSeek conversational intent and sampled real transcript',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('正在验证 AI 对话，结果将保存到项目测试记录。'))),
        ),
      );
      final settingStore = AiChatSettingsStore();
      final installed = await settingStore.load();
      expect(Uri.parse(installed.baseUrl).host, 'api.deepseek.com');
      expect(
        installed.apiKey.isNotEmpty,
        isTrue,
        reason: 'Expected existing native credential',
      );
      // Explicitly requested by the user: restore the default system prompt only.
      await settingStore.save(
        installed.copyWith(systemPrompt: AiChatSettings.defaultSystemPrompt),
      );
      final settings = installed.copyWith(
        backend: AiBackend.api,
        systemPrompt: AiChatSettings.defaultSystemPrompt,
        titlePrompt: '',
        maxOutputTokens: 768,
        thinkingEnabled: false,
        temperature: 0.2,
        contextTokens: 16000,
        contextMode: AiContextMode.automatic,
      );
      final transport = AiChatTransport(
        idleTimeout: const Duration(seconds: 45),
      );
      final output = File(
        r'.\.artifacts\ai-chat\context-design-live-results.json',
      );
      final cases = <Map<String, dynamic>>[];
      // Reuse completed measurements when continuing an interrupted evaluation.
      // They are evidence for these fixed fixtures, not a production plan cache.
      final measured = <String, Map<String, dynamic>>{};
      if (await output.exists()) {
        final previous = jsonDecode(await output.readAsString());
        if (previous is Map && previous['model'] == settings.model) {
          for (final row in previous['plannerCases'] as List? ?? []) {
            if (row is Map && row['warning'] == null && row['plan'] is Map) {
              measured[row['question'] as String] = Map<String, dynamic>.from(
                row,
              );
            }
          }
        }
      }
      Future<void> save() => output.writeAsString(
        const JsonEncoder.withIndent(
          '  ',
        ).convert({'model': settings.model, 'plannerCases': cases}),
      );
      final history = [
        AiChatMessage(id: 'u', role: 'user', content: '请解释函数极限。'),
        AiChatMessage(
          id: 'a',
          role: 'assistant',
          content: '函数极限描述自变量趋近某点时函数值趋近的值；它与该点的函数值可以不同。',
        ),
      ];
      final tests = <(String, List<AiChatMessage>, Set<String>)>[
        ('总结全文', [], {'whole'}),
        ('概括函数极限这个知识点', history, {'topic'}),
        ('?', history, {'none'}),
        ('嗯？', history, {'none'}),
        ('不对', history, {'none', 'topic'}),
        ('你跑题了', history, {'none'}),
        ('换个例子', history, {'none', 'topic'}),
        ('它和连续有什么区别', history, {'topic'}),
        ('现在我想问一下贝叶斯定理', history, {'none', 'topic'}),
        ('刚才播放的这段在讲什么', history, {'playback'}),
      ];
      for (final entry in tests) {
        final cached = measured[entry.$1];
        if (cached != null &&
            entry.$3.contains((cached['plan'] as Map)['source'])) {
          cases.add({...cached, 'acceptableSource': entry.$3.toList()});
          continue;
        }
        final watch = Stopwatch()..start();
        final result = await AiTurnPlanner(transport: transport).plan(
          settings: settings,
          question: entry.$1,
          title: '函数极限课程',
          hasTranscript: true,
          history: entry.$2,
          cancellation: AiChatCancellation(),
        );
        cases.add({
          'question': entry.$1,
          'plan': result.plan?.toJson(),
          'usage': result.usage,
          'warning': result.warning,
          'durationMs': watch.elapsedMilliseconds,
          'acceptableSource': entry.$3.toList(),
        });
        await save();
        expect(result.plan, isNotNull, reason: entry.$1);
        expect(entry.$3, contains(result.plan!.source), reason: entry.$1);
      }
      final original = SubtitleParser.parseSrt(
        await File(
          r'.\build\windows\x64\runner\Release\Downloads\ai.srt',
        ).readAsString(),
      );
      final sample = [
        ...original.take(30),
        ...original.skip(original.length ~/ 2).take(30),
        ...original.skip(original.length - 30),
      ];
      final source = AiVideoContext(
        videoId: 'quality-fixture',
        title: 'AI发展访谈的测试节选',
        position: original.last.startTime,
        metadata: {'coverage': '测试节选，原视频开头、中间、结尾各30条字幕，非原视频全文'},
        tracks: [
          AiSubtitleTrack(
            id: 'sample',
            label: '访谈字幕节选',
            role: 'primary',
            cues: sample,
          ),
        ],
      );
      final root = Directory(
        r'.\.artifacts\ai-chat\quality-test-conversations',
      );
      final store = AiConversationStore(root: root);
      final controller = AiChatController(
        video: VideoItem(
          id: source.videoId,
          path: 'quality-fixture.mp4',
          title: source.title,
          lastUpdated: 1,
          durationMs: original.last.endTime.inMilliseconds,
        ),
        transport: transport,
        conversationStore: store,
        contextLoader: _Loader(source),
        initialSettings: settings,
      );
      final turns = <Map<String, dynamic>>[];
      try {
        await controller.initialize();
        await controller.createConversation();
        for (final question in [
          '概括当前提供的全部文稿，最多三点。',
          '解释“AI泡沫”这个概念，两句话就好。',
          '?',
          '刚才的问题我想换成：用一个日常例子解释泡沫。',
        ]) {
          final watch = Stopwatch()..start();
          await controller.send(question);
          final answer = controller.active!.messages.last;
          turns.add({
            'question': question,
            'answer': answer.content,
            'status': answer.status,
            'usage': answer.usage,
            'responseInfo': answer.responseInfo,
            'durationMs': watch.elapsedMilliseconds,
            'positionInjected': controller.lastRequest!.messages
                .toString()
                .contains('playbackPosition'),
          });
          await output.writeAsString(
            const JsonEncoder.withIndent('  ').convert({
              'model': settings.model,
              'plannerCases': cases,
              'realSubtitleTurns': turns,
              'sampleCues': sample.length,
              'originalCues': original.length,
            }),
          );
          expect(controller.error, isNull);
          expect(answer.status, 'complete');
          expect(turns.last['positionInjected'], isFalse);
        }
      } finally {
        controller.dispose();
        await store.load(source.videoId);
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 6)),
  );
  const pipelineEnabled = bool.fromEnvironment('AI_LIVE_TRANSCRIPT_PIPELINE');
  testWidgets(
    'real complete transcript indexing, bounded concurrency, and persistent reuse',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('正在验证全文整理与复用。'))),
        ),
      );
      final installed = await AiChatSettingsStore().load();
      expect(Uri.parse(installed.baseUrl).host, 'api.deepseek.com');
      expect(installed.apiKey.isNotEmpty, isTrue);
      final settings = installed.copyWith(
        backend: AiBackend.api,
        systemPrompt: AiChatSettings.defaultSystemPrompt,
        transcriptPrompt: AiChatSettings.defaultTranscriptPrompt,
        titlePrompt: '',
        contextTokens: 12000,
        maxOutputTokens: 512,
        thinkingEnabled: false,
        contextMode: AiContextMode.segmented,
      );
      final original = SubtitleParser.parseSrt(
        await File(
          r'D:\Fluent Player\VideoPlayerData\subtitles\tasks\cd288792-21a7-48f2-be0e-b32f5c755a83\ai.srt',
        ).readAsString(),
      );
      final source = AiVideoContext(
        videoId: 'pipeline-live',
        title: '2.2.2定义求极限习题.mp4',
        tracks: [AiSubtitleTrack(id: 'math', label: '数学课完整字幕', cues: original)],
      );
      const previousRoot = String.fromEnvironment('AI_LIVE_PIPELINE_CACHE');
      final root = previousRoot.isNotEmpty
          ? Directory(previousRoot)
          : await Directory(
              r'.\.artifacts\ai-chat',
            ).createTemp('pipeline-native-');
      final transport = _RecordingTransport();
      final engine = AiTranscriptPreparation(transport: transport, root: root);
      const question = '用三个短要点概括这节课，不展开完整推导。';
      final diagnostics = File(
        r'.\.artifacts\ai-chat\transcript-pipeline-live-progress.json',
      );
      Future<AiPreparedTranscript> prepare(AiTranscriptPreparation current) =>
          current.prepare(
            video: source,
            selectedTrackIds: {'math'},
            settings: settings,
            question: question,
            targetTokens: 7000,
            cancellation: AiChatCancellation(),
            exhaustiveTask: false,
            onProgress: (_, _, _) {},
            onUsage: (value) {
              diagnostics.writeAsStringSync(
                const JsonEncoder.withIndent('  ').convert(value),
              );
            },
          );
      final watch = Stopwatch()..start();
      final prepared = await prepare(engine);
      final coldMs = watch.elapsedMilliseconds;
      final calls = transport.sourceInputs.length;
      final sourceText = transport.sourceInputs.join('\n');
      final missing = original
          .where((cue) => !sourceText.contains(cue.text.trim()))
          .length;
      watch.reset();
      final restored = await prepare(
        AiTranscriptPreparation(transport: transport, root: root),
      );
      final warmMs = watch.elapsedMilliseconds;
      final request = AiPromptComposer().build(
        settings: settings,
        video: source,
        question: question,
        selectedTrackIds: {'math'},
        transcriptDigest: prepared.text,
      );
      final answer = StringBuffer();
      Map<String, dynamic>? usage;
      String? finish;
      watch.reset();
      await for (final delta in transport.stream(
        settings: settings,
        messages: request.messages,
        cancellation: AiChatCancellation(),
      )) {
        answer.write(delta.content);
        usage = AiTokenUsage.merge(usage, delta.usage);
        finish = delta.finishReason ?? finish;
      }
      await File(
        r'.\.artifacts\ai-chat\transcript-pipeline-live-result.json',
      ).writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'model': settings.model,
          'sourceCues': original.length,
          'missingCues': previousRoot.isEmpty ? missing : null,
          'coverageNote': previousRoot.isEmpty
              ? '逐条核对原始字幕确实进入本次预处理请求。'
              : '本轮复用先前已完成的原文分段，仅发送合并记录；原文全量装包覆盖由离线测试逐条验证。',
          'costScope': previousRoot.isEmpty
              ? '本次首次处理与短答。'
              : '本次恢复合并与短答，不含先前失败处理的消耗；并非完整冷启动用量。',
          'preparationMs': coldMs,
          'initialReused': prepared.reused,
          'recoveredExistingWork': previousRoot.isNotEmpty,
          'warmMs': warmMs,
          'answerMs': watch.elapsedMilliseconds,
          'segments': prepared.segments,
          'preparationUsage': prepared.usage,
          'warmUsage': restored.usage,
          'warmReused': restored.reused,
          'recordCharacters': prepared.text.length,
          'records': prepared.text,
          'answer': answer.toString(),
          'answerUsage': usage,
          'answerFinishReason': finish,
        }),
      );
      if (previousRoot.isEmpty) {
        expect(missing, 0);
        expect(prepared.usage['peak_concurrency'], 2);
      } else {
        expect(prepared.reused, prepared.segments);
      }
      expect(
        (prepared.usage['attempts'] as List).every(
          (a) => a['finish_reason'] == 'stop',
        ),
        isTrue,
      );
      expect(transport.sourceInputs.length, calls);
      expect(restored.usage['calls'], 0);
      expect(restored.reused, prepared.segments);
      expect(restored.text, prepared.text);
      expect(answer.isNotEmpty, isTrue);
      expect(finish, 'stop');
    },
    skip: !pipelineEnabled,
    timeout: const Timeout(Duration(minutes: 4)),
  );
  const playbackEnabled = bool.fromEnvironment('AI_LIVE_PLAYBACK_BACKGROUND');
  testWidgets(
    'real playback question sees the entire mathematics transcript',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('正在验证当前位置问题的全文背景。'))),
        ),
      );
      final installed = await AiChatSettingsStore().load();
      expect(Uri.parse(installed.baseUrl).host, 'api.deepseek.com');
      expect(installed.apiKey.isNotEmpty, isTrue);
      final settings = installed.copyWith(
        backend: AiBackend.api,
        titlePrompt: '',
        systemPrompt: AiChatSettings.defaultSystemPrompt,
        maxOutputTokens: 384,
        thinkingEnabled: false,
        contextTokens: 64000,
        contextMode: AiContextMode.automatic,
      );
      final original = SubtitleParser.parseSrt(
        await File(
          r'D:\Fluent Player\VideoPlayerData\subtitles\tasks\cd288792-21a7-48f2-be0e-b32f5c755a83\ai.srt',
        ).readAsString(),
      );
      final source = AiVideoContext(
        videoId: 'playback-full-math-test',
        title: '2.2.2定义求极限习题.mp4',
        position: const Duration(minutes: 12),
        tracks: [
          AiSubtitleTrack(
            id: 'math',
            label: '数学课完整字幕',
            role: 'primary',
            cues: original,
          ),
        ],
      );
      final store = AiConversationStore(
        root: Directory(
          r'.\.artifacts\ai-chat\playback-test-conversations',
        ),
      );
      final controller = AiChatController(
        video: VideoItem(
          id: source.videoId,
          path: 'playback-test.mp4',
          title: source.title,
          durationMs: original.last.endTime.inMilliseconds,
          lastUpdated: 1,
        ),
        transport: AiChatTransport(),
        contextLoader: _Loader(source),
        conversationStore: store,
        initialSettings: settings,
      );
      try {
        await controller.initialize();
        await controller.createConversation();
        final watch = Stopwatch()..start();
        await controller.send('现在在讲啥？简要说明这段在整节课里的作用。');
        final request = controller.lastRequest!;
        final answer = controller.active!.messages.last;
        final missing = original
            .where((cue) => !request.contextText.contains(cue.text.trim()))
            .length;
        await File(
          r'.\.artifacts\ai-chat\playback-background-live-result.json',
        ).writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'model': settings.model,
            'subtitleCues': original.length,
            'missingCues': missing,
            'rawSourceComplete': request.rawSourceComplete,
            'contextComplete': request.contextComplete,
            'contextLimit': request.contextLimit,
            'durationMs': watch.elapsedMilliseconds,
            'answer': answer.content,
            'finishReason': answer.finishReason,
            'usage': answer.usage,
            'responseInfo': answer.responseInfo,
          }),
        );
        expect(controller.error, isNull);
        expect(request.turnPlan?['source'], 'playback');
        expect(request.rawSourceComplete, isTrue);
        expect(missing, 0);
        expect(answer.status, 'complete');
      } finally {
        controller.dispose();
        await store.load(source.videoId);
      }
    },
    skip: !playbackEnabled,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
