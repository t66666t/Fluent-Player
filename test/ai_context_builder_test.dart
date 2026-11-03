import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_context_builder.dart';
import 'package:video_player_app/features/ai_chat/ai_video_context.dart';
import 'package:video_player_app/models/subtitle_model.dart';

SubtitleItem cue(int index, String text, {int? seconds}) => SubtitleItem(
  index: index,
  startTime: Duration(seconds: seconds ?? index * 10),
  endTime: Duration(seconds: (seconds ?? index * 10) + 9),
  text: text,
);

AiVideoContext video(
  List<AiSubtitleTrack> tracks, {
  Duration position = Duration.zero,
  Map<String, dynamic> metadata = const {},
}) => AiVideoContext(
  videoId: 'video',
  title: '教学视频',
  tracks: tracks,
  position: position,
  metadata: metadata,
);

void main() {
  test(
    'long overview retains beginning middle and end within 1500 characters',
    () {
      final track = AiSubtitleTrack(
        id: 'other',
        label: '未指定字幕',
        cues: List.generate(6000, (i) => cue(i, '第$i段讲授${'教学内容' * 12}')),
      );
      final result = AiContextBuilder().build(
        video: video([track], metadata: {'description': '很长简介' * 10000}),
        question: '概括整个视频',
        selectedTrackIds: {'other'},
        maxCharacters: 1500,
      );
      expect(result.usedCharacters, lessThanOrEqualTo(1500));
      expect(result.usedCharacters, result.text.length);
      expect(result.totalCharacters, greaterThan(100000));
      expect(result.isTruncated, isTrue);
      expect(result.selectedChunks.first.start.inSeconds, lessThan(100));
      expect(
        result.selectedChunks.any(
          (chunk) =>
              chunk.start.inSeconds > 25000 && chunk.start.inSeconds < 35000,
        ),
        isTrue,
      );
      expect(
        result.selectedChunks.any((chunk) => chunk.start.inSeconds > 59000),
        isTrue,
      );
      expect(result.warnings.join(' '), contains('可能遗漏'));
      expect(result.text, contains('不可信数据'));
    },
  );

  test('Chinese bigram retrieval finds a rare topic deep in a giant cue', () {
    final track = AiSubtitleTrack(
      id: 'cn',
      label: '中文',
      cues: [
        cue(0, '${'常规课程讲解。' * 12000}量子纠缠揭示两个粒子关联的现象。${'常规课程讲解。' * 12000}'),
      ],
    );
    final result = AiContextBuilder().build(
      video: video([track]),
      question: '量子纠缠如何解释？',
      selectedTrackIds: {'cn'},
      maxCharacters: 1800,
    );
    expect(result.selectedChunks.first.text, contains('量子纠缠'));
    expect(result.text, contains('[00:00:00]'));
    expect(result.usedCharacters, lessThanOrEqualTo(1800));
  });

  test('all selected tracks are represented despite different languages', () {
    final cn = AiSubtitleTrack(
      id: 'cn',
      label: '主字幕',
      role: 'primary',
      cues: List.generate(500, (i) => cue(i, '量子纠缠是粒子关联的重要现象，第$i段')),
    );
    final en = AiSubtitleTrack(
      id: 'en',
      label: 'English',
      role: 'other',
      cues: List.generate(
        500,
        (i) => cue(
          i,
          'A translated lesson about correlated particles section $i.',
        ),
      ),
    );
    final hidden = AiSubtitleTrack(
      id: 'hidden',
      label: '不选择',
      cues: [cue(0, 'UNSELECTED_SECRET')],
    );
    final result = AiContextBuilder().build(
      video: video([cn, en, hidden]),
      question: '解释量子纠缠',
      selectedTrackIds: {'cn', 'en'},
      maxCharacters: 1600,
    );
    expect(result.selectedChunks.map((chunk) => chunk.trackId).toSet(), {
      'cn',
      'en',
    });
    expect(result.text, isNot(contains('UNSELECTED_SECRET')));
  });

  test('primary and secondary retrieval precedes others while preserving every chosen track', () {
    AiSubtitleTrack track(String id, String role) => AiSubtitleTrack(
      id: id,
      label: '$role 字幕',
      role: role,
      fileName: 'private-internal-cache-name.srt',
      sourceDescription: '手工编辑 · 已关联',
      cues: List.generate(1000, (i) => cue(i, '解释量子纠缠的机制，第$i段。')),
    );
    final result = AiContextBuilder().build(
      video: video([track('other', 'other'), track('secondary', 'secondary'), track('primary', 'primary')]),
      question: '解释量子纠缠',
      selectedTrackIds: {'other', 'secondary', 'primary'},
      maxCharacters: 2100,
    );
    expect(result.selectedChunks.take(3).map((chunk) => chunk.trackId), ['primary', 'secondary', 'other']);
    expect(result.selectedChunks.map((chunk) => chunk.trackId).toSet(), {'primary', 'secondary', 'other'});
    expect(result.usedCharacters, lessThanOrEqualTo(2100));
    expect(result.text, isNot(contains('private-internal-cache-name')));
  });

  test(
    'no selected subtitle never implicitly includes active or detached tracks',
    () {
      final result = AiContextBuilder().build(
        video: video([
          AiSubtitleTrack(
            id: 'main',
            label: '主字幕',
            role: 'primary',
            cues: [cue(0, 'SHOULD_NOT_SEND')],
          ),
        ]),
        question: '这个视频讲什么',
        selectedTrackIds: {},
        maxCharacters: 1000,
      );
      expect(result.selectedChunks, isEmpty);
      expect(result.text, isNot(contains('SHOULD_NOT_SEND')));
      expect(result.warnings.join(' '), contains('未选择字幕'));
    },
  );

  test(
    'current playback and explicit timestamp focus use their own locations',
    () {
      final track = AiSubtitleTrack(
        id: 'cn',
        label: '字幕',
        cues: List.generate(1000, (i) => cue(i, '这是第$i节的讲解。')),
      );
      final builder = AiContextBuilder();
      final data = video([track], position: const Duration(seconds: 5000));
      final current = builder.build(
        video: data,
        question: '当前这段在说什么',
        selectedTrackIds: {'cn'},
        maxCharacters: 1800,
      );
      final explicit = builder.build(
        video: data,
        question: '01:40:00 处在说什么',
        selectedTrackIds: {'cn'},
        maxCharacters: 1800,
      );
      expect(
        current.selectedChunks.first.start.inSeconds,
        inInclusiveRange(4900, 5000),
      );
      expect(
        explicit.selectedChunks.first.start.inSeconds,
        inInclusiveRange(5900, 6000),
      );
      final currentSummary = builder.build(
        video: data,
        question: '总结当前这段的内容',
        selectedTrackIds: {'cn'},
        maxCharacters: 1800,
      );
      expect(
        currentSummary.selectedChunks.first.start.inSeconds,
        inInclusiveRange(4900, 5000),
      );
    },
  );

  test('short selected transcript is complete and tiny budgets are exact', () {
    final data = video([
      AiSubtitleTrack(
        id: 'cn',
        label: '字幕',
        cues: [cue(0, '最初的介绍'), cue(1, '最后的结论')],
      ),
    ]);
    final builder = AiContextBuilder();
    final result = builder.build(
      video: data,
      question: '介绍',
      selectedTrackIds: {'cn'},
      maxCharacters: 1000,
    );
    expect(result.text, contains('最初的介绍'));
    expect(result.text, contains('最后的结论'));
    expect(result.isTruncated, isFalse);
    for (final budget in [0, 1, 10, 99, 120, 200]) {
      final tiny = builder.build(
        video: data,
        question: '😀介绍',
        selectedTrackIds: {'cn'},
        maxCharacters: budget,
      );
      expect(tiny.usedCharacters, lessThanOrEqualTo(budget));
    }
  });

  test(
    'async index preparation supports giant tracks and cached followup',
    () async {
      final track = AiSubtitleTrack(
        id: 'cn',
        label: '字幕',
        cues: List.generate(
          2000,
          (i) => cue(i, i == 1500 ? '这里是稀有的黑洞蒸发机制' : '普通讲解内容'),
        ),
      );
      final data = video([track]);
      final builder = AiContextBuilder();
      await builder.prepare(data);
      final result = builder.build(
        video: data,
        question: '黑洞蒸发机制',
        selectedTrackIds: {'cn'},
        maxCharacters: 1800,
      );
      expect(result.text, contains('黑洞蒸发'));
      await builder.prepare(data);
      final followup = builder.build(
        video: data,
        question: '解释黑洞蒸发机制',
        selectedTrackIds: {'cn'},
        maxCharacters: 1800,
      );
      expect(followup.text, contains('黑洞蒸发'));
    },
  );
}
