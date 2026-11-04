import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/services/quark_subtitle_text.dart';
import 'package:video_player_app/utils/subtitle_parser.dart';

void main() {
  test('Quark Base64 SRT decodes UTF-8 and rejects encoded errors', () {
    const text = '1\n00:00:01,000 --> 00:00:02,000\n中文字幕\n';
    expect(decodeQuarkSubtitleBody(base64.encode(utf8.encode(text))), text);
    expect(decodeQuarkSubtitleBody(text), text);
    for (final invalid in [
      'bad base64!',
      '<html>login</html>',
      '{"code":14001}',
      'no cues',
    ]) {
      expect(
        () => decodeQuarkSubtitleBody(base64.encode(utf8.encode(invalid))),
        throwsA(isA<CloudDriveFailure>()),
      );
    }
  });

  test(
    'bilingual subtitles keep both timelines with gaps and merged sentences',
    () {
      final body = mergeQuarkBilingualSubtitles(
        '1\n00:00:01,000 --> 00:00:03,000\n甲\n\n'
            '2\n00:00:04,000 --> 00:00:05,000\n乙\n',
        '1\n00:00:02,000 --> 00:00:04,500\nCombined translation\n',
      );
      final cues = SubtitleParser.parse(body);
      expect(cues.map((c) => c.text), [
        '甲',
        '甲\nCombined translation',
        'Combined translation',
        '乙\nCombined translation',
        '乙',
      ]);
      expect(cues.map((c) => c.startTime.inMilliseconds), [
        1000,
        2000,
        3000,
        4000,
        4500,
      ]);
      expect(cues.map((c) => c.endTime.inMilliseconds), [
        2000,
        3000,
        4000,
        4500,
        5000,
      ]);
    },
  );

  test(
    'bilingual subtitles preserve overlapping cues and coalesce equal text',
    () {
      final body = mergeQuarkBilingualSubtitles(
        '1\n00:00:01,000 --> 00:00:03,000\n甲\n\n'
            '2\n00:00:02,000 --> 00:00:03,000\n乙\n',
        '1\n00:00:01,000 --> 00:00:02,000\nEnglish\n\n'
            '2\n00:00:02,000 --> 00:00:03,000\nEnglish\n',
      );
      expect(SubtitleParser.parse(body).map((c) => c.text), [
        '甲\nEnglish',
        '甲\n乙\nEnglish',
      ]);
      expect(
        () => mergeQuarkBilingualSubtitles('bad', body),
        throwsA(isA<CloudDriveFailure>()),
      );
    },
  );
}
