import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';
import 'package:video_player_app/features/ai_chat/ai_transcript_pipeline.dart';
import 'package:video_player_app/features/ai_chat/ai_video_context.dart';
import 'package:video_player_app/models/subtitle_model.dart';

class _ParallelTransport extends AiChatTransport {
  int active = 0, peak = 0, finished = 0;
  final inputs = <String>[];
  bool fail = false;
  @override
  Stream<AiChatDelta> stream({
    required AiChatSettings settings,
    required List<Map<String, String>> messages,
    required AiChatCancellation cancellation,
  }) async* {
    final input = messages.last['content']!;
    inputs.add(input);
    final order = inputs.length;
    active++;
    if (active > peak) peak = active;
    try {
      if (fail) {
        if (order == 1) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          throw const AiChatException('test transport failure');
        }
        await cancellation.whenCancelled;
        return;
      }
      await Future<void>.delayed(Duration(milliseconds: order.isOdd ? 30 : 5));
      final id = RegExp(r'事实编号(\d+)').firstMatch(input)!.group(1);
      yield AiChatDelta(
        content: '记录$id [00:10]。',
        finishReason: 'stop',
        usage: const {'prompt_tokens': 100, 'completion_tokens': 20},
      );
    } finally {
      active--;
      finished++;
    }
  }
}

void main() {
  final video = AiVideoContext(
    videoId: 'parallel',
    title: '完整来源',
    tracks: [
      for (var track = 0; track < 2; track++)
        AiSubtitleTrack(
          id: 't$track',
          label: '字幕$track',
          cues: List.generate(
            40,
            (i) => SubtitleItem(
              index: i,
              startTime: Duration(seconds: i * 10),
              endTime: Duration(seconds: i * 10 + 9),
              text: '事实编号${track * 40 + i} ${'独有资料' * 30}',
            ),
          ),
        ),
    ],
  );
  const settings = AiChatSettings(contextTokens: 6000, maxOutputTokens: 1000);
  late _ParallelTransport transport;
  late Map<String, String> cache;
  setUp(() {
    transport = _ParallelTransport();
    cache = {};
  });
  Future<AiTranscriptPipelineResult> prepare({
    AiBackend backend = AiBackend.api,
    AiChatCancellation? cancellation,
    bool exhaustive = false,
    String question = '总结全文',
  }) =>
      AiTranscriptPipeline(
        transport: transport,
        readRecord: (key) async => cache[key],
        writeRecord: (key, text) async {
          cache[key] = text;
        },
      ).prepare(
        video: video,
        selectedTrackIds: {'t0', 't1'},
        settings: settings.copyWith(backend: backend),
        question: question,
        exhaustive: exhaustive,
        targetTokens: 3500,
        cancellation: cancellation ?? AiChatCancellation(),
        onProgress: (_, _, _) {},
      );

  test(
    'bounded parallel processing preserves all source text and source order',
    () async {
      final result = await prepare();
      expect(result.segments, greaterThan(2));
      expect(transport.peak, 2);
      expect(transport.active, 0);
      expect(transport.finished, result.segments);
      expect(result.usage['peak_concurrency'], 2);
      final all = transport.inputs.join('\n');
      for (var i = 0; i < 80; i++) {
        expect('事实编号$i '.allMatches(all), hasLength(1));
      }
      final sourceOrder = transport.inputs.map(
        (input) => RegExp(r'事实编号(\d+)').firstMatch(input)!.group(1)!,
      );
      final outputOrder = RegExp(
        r'记录(\d+)',
      ).allMatches(result.text).map((m) => m.group(1));
      expect(outputOrder, orderedEquals(sourceOrder));
      expect(
        result.usage['estimated_input_spent'],
        lessThanOrEqualTo(result.usage['estimated_input_limit'] as int),
      );
      final calls = transport.inputs.length;
      final restored = await prepare(question: '概述全部主题');
      expect(transport.inputs.length, calls);
      expect(restored.reused, result.segments);
      expect(restored.usage['calls'], 0);
    },
  );

  test(
    'failure cancels and drains siblings before returning, without new calls or partial cache',
    () async {
      transport.fail = true;
      await expectLater(prepare(), throwsA(isA<AiChatException>()));
      expect(transport.inputs, hasLength(2));
      expect(transport.active, 0);
      expect(transport.finished, 2);
      expect(cache, isEmpty);
    },
  );

  test('CLI preparation is serial', () async {
    final result = await prepare(backend: AiBackend.codex);
    expect(transport.peak, 1);
    expect(result.usage['concurrency_limit'], 1);
  });

  test(
    'exhaustive evidence uses an isolated question-specific cache and covers both tracks',
    () async {
      await prepare();
      final before = transport.inputs.length;
      final result = await prepare(exhaustive: true, question: '有没有讲反例');
      expect(result.reused, 0);
      expect(result.usage['record_style'], 'query_evidence');
      final all = transport.inputs.skip(before).join('\n');
      for (var i = 0; i < 80; i++) {
        expect(all, contains('事实编号$i '));
      }
      expect(all, contains('核查问题："有没有讲反例"'));
      final calls = transport.inputs.length;
      await prepare(exhaustive: true, question: '有没有讲证明');
      expect(transport.inputs.length, greaterThan(calls));
    },
  );
}
