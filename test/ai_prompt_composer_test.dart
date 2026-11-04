import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_models.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_prompt_composer.dart';
import 'package:video_player_app/features/ai_chat/ai_video_context.dart';
import 'package:video_player_app/models/subtitle_model.dart';

void main() {
  test(
    'changing retrieved passages and playback preserve the stable API history prefix',
    () {
      const settings = AiChatSettings(
        contextTokens: 6000,
        maxOutputTokens: 1500,
      );
      final video = AiVideoContext(
        videoId: 'v',
        title: '同一视频',
        tracks: [
          AiSubtitleTrack(
            id: 'a',
            label: '中文',
            cues: List.generate(
              200,
              (i) => SubtitleItem(
                index: i,
                startTime: Duration(seconds: i),
                endTime: Duration(seconds: i + 1),
                text: '${i < 100 ? '苹果' : '香蕉'} ${'相关材料' * 40}',
              ),
            ),
          ),
        ],
      );
      final history = [
        AiChatMessage(id: 'u', role: 'user', content: '先前提问'),
        AiChatMessage(id: 'a', role: 'assistant', content: '先前的回答'),
      ];
      final composer = AiPromptComposer();
      final first = composer.build(
        settings: settings,
        video: video,
        question: '苹果的内容是什么',
        selectedTrackIds: {'a'},
        history: history,
      );
      final second = composer.build(
        settings: settings,
        video: AiVideoContext(
          videoId: video.videoId,
          title: video.title,
          tracks: video.tracks,
          position: const Duration(seconds: 150),
        ),
        question: '香蕉的内容是什么',
        selectedTrackIds: {'a'},
        history: history,
      );
      expect(first.contextComplete, isFalse);
      final firstAnswer = first.messages.indexWhere(
        (message) => message['role'] == 'assistant',
      );
      final secondAnswer = second.messages.indexWhere(
        (message) => message['role'] == 'assistant',
      );
      expect(firstAnswer, secondAnswer);
      expect(
        first.messages.take(firstAnswer + 1).toList(),
        second.messages.take(secondAnswer + 1).toList(),
      );
      expect(first.messages.last['content'], '苹果的内容是什么');
      expect(second.messages.last['content'], '香蕉的内容是什么');
      expect(
        first.messages.skip(firstAnswer + 1).toString(),
        isNot(second.messages.skip(secondAnswer + 1).toString()),
      );
      expect(
        first.estimatedTokens,
        lessThanOrEqualTo(
          settings.contextTokens - settings.maxOutputTokens - 512,
        ),
      );
    },
  );
  test('developer parameters preserve native protocol without credentials', () {
    const settings = AiChatSettings(
      apiProtocol: AiApiProtocol.gemini,
      baseUrl: 'https://gemini.example/v1beta',
      apiKey: 'private-secret',
      model: 'gemini-test',
    );
    final request = AiPromptComposer().build(
      settings: settings,
      video: const AiVideoContext(videoId: 'v', title: '视频'),
      question: '总结',
      selectedTrackIds: {},
    );
    expect(request.apiProtocol, 'gemini');
    expect(request.requestParameters?['model'], 'gemini-test');
    expect(request.requestParameters?.containsKey('contents'), isFalse);
    expect(
      request.requestParameters.toString(),
      isNot(contains('private-secret')),
    );
    final restored = AiRequestPreview.fromJson(request.toJson());
    expect(restored.requestParameters, request.requestParameters);
    expect(restored.messages, request.messages);
  });
  final context = AiVideoContext(
    videoId: 'video',
    title: '标题',
    tracks: [
      AiSubtitleTrack(
        id: 'a',
        label: '轨道',
        cues: List.generate(
          4000,
          (i) => SubtitleItem(
            index: i,
            startTime: Duration(seconds: i),
            endTime: Duration(seconds: i + 1),
            text: '段落$i ${'文稿' * 100}',
          ),
        ),
      ),
    ],
  );
  test(
    'long input stays below the window with reserved output and complete latest question',
    () {
      const settings = AiChatSettings(
        contextTokens: 6000,
        maxOutputTokens: 1500,
      );
      final history = List.generate(
        24,
        (i) => AiChatMessage(
          id: 'm$i',
          role: i.isEven ? 'user' : 'assistant',
          content: '历史$i ${'文本' * 100}',
        ),
      );
      final request = AiPromptComposer().build(
        settings: settings,
        video: context,
        question: '总结全片',
        selectedTrackIds: {'a'},
        history: history,
      );
      expect(
        request.estimatedTokens,
        lessThanOrEqualTo(
          settings.contextTokens - settings.maxOutputTokens - 512,
        ),
      );
      expect(request.messages.last, {'role': 'user', 'content': '总结全片'});
      expect(request.omittedMessages, greaterThan(0));
      expect(request.warnings.any((w) => w.contains('原文摘录')), isTrue);
      expect(request.selectedChunks, isNotEmpty);
      expect(history.length, 24);
    },
  );
  test(
    'rejects oversized question instead of silently truncating user input',
    () {
      expect(
        () => AiPromptComposer().build(
          settings: const AiChatSettings(
            contextTokens: 3000,
            maxOutputTokens: 1000,
          ),
          video: context,
          question: '问题' * 3000,
          selectedTrackIds: {'a'},
        ),
        throwsStateError,
      );
    },
  );
  test('does not pass reasoning or incomplete answers in recent history', () {
    final request = AiPromptComposer().build(
      settings: const AiChatSettings(),
      video: context,
      question: '新问题',
      selectedTrackIds: {},
      history: [
        AiChatMessage(id: '1', role: 'user', content: '第一问'),
        AiChatMessage(
          id: '2',
          role: 'assistant',
          content: '完整答',
          reasoning: '私有思考',
        ),
        AiChatMessage(id: '3', role: 'user', content: '中断问'),
        AiChatMessage(
          id: '4',
          role: 'assistant',
          content: '不完整答',
          status: 'cancelled',
        ),
      ],
    );
    expect(
      request.messages.where((m) => m['role'] == 'assistant').single['content'],
      '完整答',
    );
    expect(request.messages.toString(), isNot(contains('私有思考')));
    expect(request.contextText, contains('字幕资料：无'));
  });
  test('UTF-8 truncation does not split emoji or Chinese codepoints', () {
    final value = AiPromptComposer.truncateBytes('中文🙂文本' * 30, 31);
    expect(value, isNot(contains('\uFFFD')));
    expect(AiPromptComposer.estimateTokens(value), lessThanOrEqualTo(31));
  });
  test('CLI wrappers are budgeted and stored exactly with the request', () {
    final request = AiPromptComposer().build(
      settings: const AiChatSettings(
        backend: AiBackend.codex,
        cliPrompt: '自定义 CLI 附加提示',
      ),
      video: context,
      question: '当前片段',
      selectedTrackIds: {'a'},
    );
    expect(request.cliInput, startsWith('自定义 CLI 附加提示\n'));
    expect(request.cliInput, contains('当前片段'));
    expect(
      AiRequestPreview.fromJson(request.toJson()).cliInput,
      request.cliInput,
    );
    expect(
      () => AiPromptComposer().build(
        settings: AiChatSettings(
          backend: AiBackend.codex,
          cliPrompt: '过长' * 100000,
        ),
        video: context,
        question: '问题',
        selectedTrackIds: {},
      ),
      throwsStateError,
    );
  });
}
