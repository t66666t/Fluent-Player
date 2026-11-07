import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/model_center/asr_enhancement_processing.dart';
import 'package:video_player_app/features/model_center/subtitle_segmentation.dart';
import 'package:video_player_app/models/subtitle_model.dart';

SubtitleItem _plain(String text, Duration end) =>
    SubtitleItem(index: 1, startTime: Duration.zero, endTime: end, text: text);

void main() {
  const options = SubtitleSegmentationOptions.natural;
  const chinese = '今天天气很好。我们一起去公园散步，然后回家吃饭。这个句子故意写长，用来覆盖慢语速。';

  test('versions 1 and 2 keep an unaligned sentence intact', () {
    final cue = _plain(chinese, const Duration(seconds: 12));
    final v1 = segmentAsrSubtitles([cue], options, textProcessingVersion: 1);
    final v2 = segmentAsrSubtitles([cue], options, textProcessingVersion: 2);
    final unchanged = segmentAsrSubtitles([cue], options);
    expect(v1.single.text, chinese);
    expect(v2.single.text, chinese);
    expect(unchanged.single.text, chinese);
  });

  test('v3 splits a long unaligned sentence inside the reading window', () {
    final cue = _plain(chinese, const Duration(seconds: 12));
    final pieces = segmentAsrSubtitles(
      [cue],
      options,
      textProcessingVersion: 3,
    );
    expect(pieces.length, greaterThan(1));
    expect(pieces.map((c) => c.text).join(), chinese);
    for (final piece in pieces) {
      final duration = piece.endTime - piece.startTime;
      expect(duration.inMilliseconds, inInclusiveRange(830, 7000));
      expect(piece.timedSpans, isEmpty);
      expect(piece.asrInfo.pauses, isEmpty);
      expect(piece.asrInfo.notes.any((note) => note.contains('分句时间')), isTrue);
    }
  });

  test('v3 keeps Korean word boundaries and splits fast timed Chinese', () {
    const korean = '오늘 날씨가 좋아서 공원에 갔습니다 그리고 집에 돌아왔습니다';
    final koreanPieces = segmentAsrSubtitles(
      [_plain(korean, const Duration(seconds: 12))],
      options,
      textProcessingVersion: 3,
    );
    expect(koreanPieces.map((c) => c.text).join(), korean);
    final words = korean.split(' ');
    for (final piece in koreanPieces) {
      for (final token in piece.text.trim().split(RegExp(r'\s+'))) {
        expect(words, contains(token));
      }
    }

    final fast = _glyphCue('今天天气真的很好我们出门去散步然后回家吃饭并且继续聊天到很晚再看一会书', tick: 280);
    final split = segmentAsrSubtitles(
      [fast],
      options,
      textProcessingVersion: 3,
    );
    expect(split.length, greaterThan(1));
    expect(split.map((c) => c.text).join(), fast.text);
    for (final piece in split) {
      final duration = piece.endTime - piece.startTime;
      expect(duration.inMilliseconds, inInclusiveRange(830, 7000));
    }
  });

  test('v3 does not invent cuts inside unspaced Southeast Asian text', () {
    const thai = 'สวัสดีครับวันนี้อากาศดีมากเราไปเดินเล่นกันเถอะ';
    final pieces = segmentAsrSubtitles(
      [_plain(thai, const Duration(seconds: 12))],
      options,
      textProcessingVersion: 3,
    );
    expect(pieces, hasLength(1));
    expect(pieces.single.text, thai);
    expect(pieces.single.asrInfo.notes.join(), contains('无空格文字'));
  });

  test(
    'a 120 ms internal dip becomes a pause anchor and a short dip does not',
    () {
      final audio = Float32List(16000 * 3);
      for (var i = 0; i < 16000; i++) {
        audio[i] = .2;
      }
      for (var i = 32000; i < audio.length; i++) {
        audio[i] = .2;
      }
      final anchored = attachAsrPauseAnchors(
        _plain('前半后半', const Duration(seconds: 3)),
        audio,
      );
      expect(anchored.asrInfo.pauses, isNotEmpty);

      final brief = Float32List(16000 * 2);
      for (var i = 0; i < brief.length; i++) {
        brief[i] = .2;
      }
      for (var i = 16000; i < 16000 + 320; i++) {
        brief[i] = 0;
      }
      expect(
        attachAsrPauseAnchors(
          _plain('短', const Duration(seconds: 2)),
          brief,
        ).asrInfo.pauses,
        isEmpty,
      );
    },
  );

  test('japanese two-line overflow keeps the verb together', () {
    const text = '興味をそそられる村を30分ほど散策するのは歌しがあります。';
    final pieces = segmentAsrSubtitles(
      [_glyphCue(text, tick: 127)],
      options,
      textProcessingVersion: 3,
    );
    expect(pieces.map((piece) => piece.text).join(), text);
    expect(pieces.first.text, contains('そそられる'));
    expect(pieces.every((piece) => piece.text.length > 2), isTrue);
    for (final piece in pieces) {
      final duration = piece.endTime - piece.startTime;
      expect(duration.inMilliseconds, inInclusiveRange(830, 7000));
    }
  });
}

SubtitleItem _glyphCue(String text, {int tick = 200}) {
  final spans = <SubtitleTimedSpan>[];
  var at = 0;
  for (final glyph in text.split('')) {
    spans.add(
      SubtitleTimedSpan(
        textStart: at,
        textEnd: at + glyph.length,
        startTime: Duration(milliseconds: spans.length * tick),
        endTime: Duration(milliseconds: (spans.length + 1) * tick),
        role: 'token',
      ),
    );
    at += glyph.length;
  }
  return SubtitleItem(
    index: 1,
    startTime: Duration.zero,
    endTime: Duration(milliseconds: spans.length * tick),
    text: text,
    timedSpans: spans,
  );
}
