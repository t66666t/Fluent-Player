import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/utils/pgs_parser.dart';
import 'package:video_player_app/utils/subtitle_parser.dart';
import 'package:video_player_app/utils/youtube_auto_caption_normalizer.dart';

List<int> _toUtf16LeBytes(String value, {bool withBom = false}) {
  final codeUnits = value.codeUnits;
  final bytes = <int>[];
  if (withBom) {
    bytes.addAll([0xFF, 0xFE]);
  }
  for (final unit in codeUnits) {
    bytes.add(unit & 0xFF);
    bytes.add((unit >> 8) & 0xFF);
  }
  return bytes;
}

void main() {
  test('decodeBytes handles utf8 bom', () {
    final content = '1\n00:00:01,000 --> 00:00:02,000\nHello\n\n';
    final bytes = [0xEF, 0xBB, 0xBF, ...content.codeUnits];
    final decoded = SubtitleParser.decodeBytes(bytes);
    final parsed = SubtitleParser.parse(decoded);
    expect(parsed.length, 1);
    expect(parsed.first.text, 'Hello');
    expect(parsed.first.startTime.inMilliseconds, 1000);
  });

  test('decodeBytes handles utf16le bom', () {
    final content = '1\n00:00:03,000 --> 00:00:04,000\nWorld\n\n';
    final bytes = _toUtf16LeBytes(content, withBom: true);
    final decoded = SubtitleParser.decodeBytes(bytes);
    final parsed = SubtitleParser.parse(decoded);
    expect(parsed.length, 1);
    expect(parsed.first.text, 'World');
    expect(parsed.first.startTime.inMilliseconds, 3000);
  });

  test('parseSrt supports dot milliseconds', () {
    final content = '1\n00:00:05.5 --> 00:00:06.75\nDot\n\n';
    final parsed = SubtitleParser.parse(content);
    expect(parsed.length, 1);
    expect(parsed.first.startTime.inMilliseconds, 5500);
    expect(parsed.first.endTime.inMilliseconds, 6750);
  });

  test('parseSrt strips brace style tokens', () {
    final content = '1\n00:00:07,000 --> 00:00:08,000\n{\\fs16\\an2\\b0}字幕\n\n';
    final parsed = SubtitleParser.parse(content);
    expect(parsed.length, 1);
    expect(parsed.first.text, '字幕');
  });

  test('parseSrt strips html style tags', () {
    final content =
        '1\n00:00:09,000 --> 00:00:10,000\n<font face="微软雅黑" size="54"><b>我是你们的陈 sir </b></font>\n\n';
    final parsed = SubtitleParser.parse(content);
    expect(parsed.length, 1);
    expect(parsed.first.text, '我是你们的陈 sir');
  });

  test('parse sup file yields image data when available', () async {
    final file = File(
      r'd:\1spbfq\字幕示例\58c06d2d-608c-435c-9af4-1dc77ae18ae5_main.sup',
    );
    if (!file.existsSync()) return;
    final parsed = await PgsParser.parse(file.path);
    expect(parsed.isNotEmpty, true);
    final itemWithImage = parsed.firstWhere(
      (item) => item.imageLoader != null,
      orElse: () => parsed.first,
    );
    final image = await itemWithImage.imageLoader?.call();
    expect(image != null && image.isNotEmpty, true);
  });

  test(
    'normalizes overlapping youtube auto captions into single active line',
    () {
      const content = '''
1
00:00:00,210 --> 00:00:07,359
[Applause]

2
00:00:05,680 --> 00:00:12,360
seven and0 when James Duncan had not

3
00:00:07,359 --> 00:00:12,360
played but those were all at home Curry

4
00:00:14,400 --> 00:00:20,960
three 11 16 St Curry coming up with the

5
00:00:18,560 --> 00:00:22,840
steel one-on-one on Parker behind the
''';
      final parsed = SubtitleParser.parse(content);
      final _ = VideoItem(
        id: 'video-1',
        path: r'D:\videos\sample.mkv',
        title: 'sample',
        durationMs: 0,
        lastUpdated: 0,
        subtitlePath: r'D:\subs\abc123_English_自动.srt',
        additionalSubtitles: {'English (自动)': r'D:\subs\abc123_English_自动.srt'},
        usesManagedAssociatedSubtitles: true,
        sourceRef: const MediaSourceRef(
          value: 'https://www.youtube.com/watch?v=test',
          kind: MediaSourceKind.url,
        ),
      );

      final shouldNormalize = YouTubeAutoCaptionNormalizer.shouldNormalize(
        parsed,
      );
      expect(shouldNormalize, isTrue);

      final normalized = YouTubeAutoCaptionNormalizer.normalize(parsed);
      expect(normalized.length, 5);
      expect(normalized[0].endTime.inMilliseconds, 5680);
      expect(normalized[1].endTime.inMilliseconds, 7359);
      expect(normalized[2].endTime.inMilliseconds, 12360);
      expect(normalized[3].endTime.inMilliseconds, 18560);
      expect(normalized[4].endTime.inMilliseconds, 22840);
    },
  );

  test('does not normalize regular subtitles without youtube auto markers', () {
    const content = '''
1
00:00:01,000 --> 00:00:04,000
Hello

2
00:00:04,000 --> 00:00:06,000
World

3
00:00:06,000 --> 00:00:08,000
Again
''';
    final parsed = SubtitleParser.parse(content);
    final _ = VideoItem(
      id: 'video-2',
      path: r'D:\videos\sample.mkv',
      title: 'sample',
      durationMs: 0,
      lastUpdated: 0,
      subtitlePath: r'D:\subs\regular_en.srt',
      usesManagedAssociatedSubtitles: true,
      sourceRef: const MediaSourceRef(
        value: 'https://www.youtube.com/watch?v=test',
        kind: MediaSourceKind.url,
      ),
    );

    final shouldNormalize = YouTubeAutoCaptionNormalizer.shouldNormalize(
      parsed,
    );
    expect(shouldNormalize, isFalse);
  });

  test('normalizes imported sliding captions without source metadata', () {
    const content = '''
1
00:00:00,000 --> 00:00:04,000
First

2
00:00:02,000 --> 00:00:06,000
Second

3
00:00:04,000 --> 00:00:08,000
Third

4
00:00:06,000 --> 00:00:10,000
Fourth
''';

    final parsed = SubtitleParser.parse(content);
    expect(YouTubeAutoCaptionNormalizer.shouldNormalize(parsed), isTrue);

    final normalized = YouTubeAutoCaptionNormalizer.normalize(parsed);
    expect(normalized.map((item) => item.endTime.inMilliseconds), [
      2000,
      4000,
      6000,
      10000,
    ]);
  });

  test('does not normalize bilibili exported subtitles', () {
    const content = '''
1
00:00:01,000 --> 00:00:04,000
Hello

2
00:00:03,000 --> 00:00:06,000
World

3
00:00:05,000 --> 00:00:08,000
Again
''';
    final parsed = SubtitleParser.parse(content);
    final _ = VideoItem(
      id: 'video-3',
      path: r'D:\videos\bilibili_sample.mkv',
      title: 'sample',
      durationMs: 0,
      lastUpdated: 0,
      subtitlePath: r'D:\subs\abc123_English_自动.srt',
      usesManagedAssociatedSubtitles: true,
      isBilibiliExported: true,
      sourceRef: const MediaSourceRef(
        value: 'https://www.youtube.com/watch?v=test',
        kind: MediaSourceKind.url,
      ),
    );

    final shouldNormalize = YouTubeAutoCaptionNormalizer.shouldNormalize(
      parsed,
    );
    expect(shouldNormalize, isFalse);
  });
}
