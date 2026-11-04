import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';
import 'package:video_player_app/features/ai_chat/ai_transcript_preparation.dart';
import 'package:video_player_app/features/ai_chat/ai_video_context.dart';
import 'package:video_player_app/models/subtitle_model.dart';

class _Transport extends AiChatTransport {
  final inputs = <String>[];
  int? cancelAt;
  bool truncated = false;
  bool verbose = false;
  @override
  Stream<AiChatDelta> stream({
    required AiChatSettings settings,
    required List<Map<String, String>> messages,
    required AiChatCancellation cancellation,
  }) async* {
    inputs.add(messages.last['content']!);
    if (cancelAt == inputs.length) {
      cancellation.cancel();
      return;
    }
    yield AiChatDelta(
      content: verbose && !messages.last['content']!.startsWith('合并')
          ? '独有记录${inputs.length} ${'细节' * 200}'
          : '本段记录 [00:12] 独有事实与例子。',
      usage: const {
        'prompt_tokens': 100,
        'completion_tokens': 20,
        'prompt_cache_hit_tokens': 80,
      },
      finishReason: truncated ? 'length' : 'stop',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Transport transport;
  late AiVideoContext video;
  const settings = AiChatSettings(
    backend: AiBackend.codex,
    contextTokens: 6000,
    maxOutputTokens: 1500,
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ai_transcript_');
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
    AiTranscriptPreparation? engine,
    String question = '总结整个视频',
    AiChatCancellation? cancellation,
    void Function(Map<String, dynamic>)? onUsage,
  }) => (engine ?? AiTranscriptPreparation(transport: transport, root: root))
      .prepare(
        video: video,
        selectedTrackIds: {'p'},
        settings: settings,
        question: question,
        targetTokens: 3500,
        cancellation: cancellation ?? AiChatCancellation(),
        onProgress: (_, _, _) {},
        onUsage: onUsage,
      );

  test(
    'every source cue is sent and future summaries reuse persistent results',
    () async {
      final result = await prepare();
      expect(result.segments, greaterThan(3));
      for (var i = 0; i < 60; i++) {
        expect(transport.inputs.join('\n'), contains('独有事实编号$i '));
      }
      expect(result.usage['calls'], result.segments);
      expect(result.usage['total_tokens'], result.segments * 120);
      final before = transport.inputs.length;
      final restored = await prepare(question: '概括全片');
      expect(restored.reused, result.segments);
      expect(transport.inputs.length, before);
      expect(restored.usage['calls'], 0);
      expect(restored.text, result.text);
    },
  );
  test(
    'question-specific exhaustive scan does not reuse a generic summary',
    () async {
      await prepare();
      final before = transport.inputs.length;
      await prepare(question: '列出所有反例');
      expect(transport.inputs.length, greaterThan(before));
      expect(transport.inputs.last, contains('核查问题："列出所有反例"'));
    },
  );
  test(
    'stopping keeps completed segments and retry skips those calls',
    () async {
      transport.cancelAt = 2;
      Map<String, dynamic>? usage;
      await expectLater(
        prepare(onUsage: (value) => usage = value),
        throwsA(isA<AiChatException>()),
      );
      expect(usage?['calls'], 2);
      expect(usage?['reported_calls'], 1);
      transport.cancelAt = null;
      final completed = await prepare();
      expect(completed.reused, 1);
      expect(completed.usage['calls'], completed.segments - 1);
    },
  );
  test(
    'truncated summaries are rejected and never reused as complete',
    () async {
      transport.truncated = true;
      await expectLater(prepare(), throwsA(isA<AiChatException>()));
      transport.truncated = false;
      final result = await prepare();
      expect(result.reused, 0);
    },
  );
  test('oversized single cue preserves every Unicode rune', () async {
    final text = List.generate(1300, (index) => '中🙂末尾事实$index；').join();
    video = AiVideoContext(
      videoId: 'v',
      title: '单条超长字幕',
      tracks: [
        AiSubtitleTrack(
          id: 'p',
          label: '主字幕',
          cues: [
            SubtitleItem(
              index: 0,
              startTime: Duration.zero,
              endTime: const Duration(hours: 1),
              text: text,
            ),
          ],
        ),
      ],
    );
    await prepare();
    final pieces = RegExp(
      r'^\[00:00\] (.*)$',
      multiLine: true,
    ).allMatches(transport.inputs.join('\n')).map((match) => match[1]).join();
    expect(pieces, text);
    expect(pieces, isNot(contains('\uFFFD')));
  });
  test('editing a source regenerates only its affected segment', () async {
    final first = await prepare();
    final track = video.tracks.first;
    final cues = [...track.cues];
    final last = cues.last;
    cues[cues.length - 1] = SubtitleItem(
      index: last.index,
      startTime: last.startTime,
      endTime: last.endTime,
      text: last.text.replaceFirst('知识', '改字'),
    );
    video = AiVideoContext(
      videoId: 'v',
      title: '长视频',
      tracks: [AiSubtitleTrack(id: 'p', label: '主字幕', cues: cues)],
    );
    final changed = await prepare();
    expect(changed.reused, first.segments - 1);
    expect(changed.usage['calls'], 1);
  });

  test(
    'hierarchical merging includes every segment record and counts its calls',
    () async {
      transport.verbose = true;
      final result = await prepare();
      final merges = transport.inputs
          .where((input) => input.startsWith('合并'))
          .join('\n');
      expect(merges, isNotEmpty);
      for (var i = 1; i <= result.segments; i++) {
        expect(merges, contains('独有记录$i '));
      }
      expect(result.usage['calls'], greaterThan(result.segments));
      final before = transport.inputs.length;
      await prepare();
      expect(transport.inputs.length, before);
    },
  );
  test(
    'a corrupt cache record is regenerated without trusting edited text',
    () async {
      final result = await prepare();
      final files = await Directory('${root.path}/ai_transcript_cache')
          .list()
          .where((file) => file.path.endsWith('.json'))
          .cast<File>()
          .toList();
      final data =
          jsonDecode(await files.first.readAsString()) as Map<String, dynamic>;
      data['text'] = '未校验的篡改内容';
      await files.first.writeAsString(jsonEncode(data));
      final next = await prepare();
      expect(next.text, isNot(contains('未校验的篡改内容')));
      expect(next.reused, result.segments - 1);
      expect(next.usage['calls'], 1);
    },
  );
}
