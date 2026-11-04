import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/subtitle_word_timing_store.dart';
import 'package:video_player_app/services/task_subtitle_storage_service.dart';
import 'package:video_player_app/services/transcription_reliability.dart';
import 'package:video_player_app/utils/subtitle_parser.dart';
import 'package:video_player_app/utils/timed_subtitle_parser.dart';
import 'package:video_player_app/utils/youtube_auto_caption_normalizer.dart';
import 'package:video_player_app/widgets/music_timed_lyric_text.dart';

Duration ms(int value) => Duration(milliseconds: value);
List<String> tokens(SubtitleItem cue) => cue.timedSpans
    .map((s) => cue.text.substring(s.textStart, s.textEnd))
    .toList();

void main() {
  test(
    'enhanced LRC keeps a line and timed text ranges, including held gaps',
    () {
      final cues = SubtitleParser.parse(
        '[00:01.00]<00:01.00>Hello <00:02.00>world<00:03.00>\n[00:04.00]Next',
      );
      expect(cues.length, 2);
      expect(cues.first.text, 'Hello world');
      expect(tokens(cues.first), ['Hello', 'world']);
      expect(cues.first.timedSpans.last.endTime, ms(3000));
      expect(cues.first.endTime, ms(3000));
      expect(cues.last.timedSpans, isEmpty);
    },
  );
  test(
    'SPL square timestamps and positive offset preserve sentence binding',
    () {
      final cue = SubtitleParser.parse(
        '[offset:100]\n[00:01.000]你好[00:02.000]世界[00:03.000]',
      ).single;
      expect(cue.startTime, ms(900));
      expect(cue.endTime, ms(2900));
      expect(tokens(cue), ['你好', '世界']);
      expect(cue.timedSpans.last.startTime, ms(1900));
    },
  );
  test('ordinary repeated LRC remains separate sentence cues', () {
    final cues = SubtitleParser.parse('[00:01.00][00:04.00]Repeated');
    expect(cues.length, 2);
    expect(cues.every((cue) => cue.timedSpans.isEmpty), isTrue);
    expect(cues.first.startTime, ms(1000));
  });
  test('last enhanced token with unknown end is not given a fake duration', () {
    final cue = SubtitleParser.parse(
      '[00:01.00]<00:01.00>Hello <00:02.00>world',
    ).single;
    expect(tokens(cue), ['Hello']);
    final knownEnd = SubtitleParser.parse(
      '[00:01.00]<00:01.00>Hello <00:02.00>world',
      mediaDuration: ms(3500),
    ).single;
    expect(tokens(knownEnd), ['Hello', 'world']);
    expect(knownEnd.timedSpans.last.endTime, ms(3500));
  });
  test('WebVTT inline tags survive legacy style cleanup', () {
    final cues = SubtitleParser.parse(
      'WEBVTT\n\n00:00:01.000 --> 00:00:03.000\n'
      '<c.green>Hello</c> <00:00:02.000>world\n\n00:00:04.000 --> 00:00:05.000\nSentence',
    );
    expect(cues.first.text, 'Hello world');
    expect(tokens(cues.first), ['Hello', 'world']);
    expect(cues.last.timedSpans, isEmpty);
  });
  for (final tag in ['k', 'K', 'kf', 'ko']) {
    test('ASS $tag retains centisecond timing and existing text', () {
      final cue = SubtitleParser.parse(
        '[Events]\n'
        'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n'
        'Dialogue: 0,0:00:01.00,0:00:05.00,Default,,0,0,0,,{\\${tag}100}Hello {\\${tag}200}world',
      ).single;
      expect(cue.text, 'Hello world');
      expect(tokens(cue), ['Hello', 'world']);
      expect(cue.timedSpans.last.startTime, ms(2000));
      expect(cue.timedSpans.last.endTime, ms(4000));
    });
  }
  test('ASS kt explicitly places the next syllable within the event', () {
    final cue = SubtitleParser.parse(
      '[Events]\n'
      r'Dialogue: 0,0:00:01.00,0:00:05.00,Default,,0,0,0,,{\kt100\kf50}Hi',
    ).single;
    expect(cue.timedSpans.single.startTime, ms(2000));
    expect(cue.timedSpans.single.endTime, ms(2500));
  });
  test(
    'Apple TTML retains absolute timing, translation and background voice',
    () {
      final cue = SubtitleParser.parse(
        '''<tt xmlns="http://www.w3.org/ns/ttml"
      xmlns:itunes="http://itunes.apple.com/lyric-ttml-extensions"
      xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
      <body><div begin="00:10.000"><p begin="00:10.000" end="00:13.000" ttm:agent="v1"><span begin="00:10.000" end="00:11.000">Hello</span> <span ttm:role="x-bg"><span begin="00:10.500" end="00:12.000">(hey)</span></span> <span begin="00:11.000" end="00:13.000">world</span><span ttm:role="x-translation">你好世界</span></p></div></body></tt>''',
      ).single;
      expect(cue.startTime, ms(10000));
      expect(cue.text, 'Hello (hey) world');
      expect(cue.lyricTranslation, '你好世界');
      expect(cue.timedSpans[1].role, 'x-bg');
      final visual = musicLyricVisualCues(cue);
      expect(visual.main.text, 'Hello  world');
      expect(tokens(visual.main), ['Hello', 'world']);
      expect(visual.background.single.text, '(hey)');
    },
  );
  test(
    'TTML translation and romanization keep independent word clocks through storage',
    () {
      final cue = SubtitleParser.parse('''<tt
      xmlns="http://www.w3.org/ns/ttml"
      xmlns:itunes="http://itunes.apple.com/lyric-ttml-extensions"
      xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
      <body><p begin="00:10.000" end="00:14.000">
      <span begin="00:10.000" end="00:11.000">Hello</span>
      <span ttm:role="x-translation"> <span begin="00:10.200" end="00:11.200">你好</span><span begin="00:12.000" end="00:13.000">世界</span> </span>
      <span ttm:role="x-roman"> <span begin="00:10.500" end="00:11.500">ni hao</span> <span begin="00:12.500" end="00:13.500">shi jie</span> </span>
      </p></body></tt>''').single;
      expect(cue.text, 'Hello');
      expect(cue.lyricTranslation, '你好世界');
      expect(cue.lyricRomanization, 'ni hao shi jie');
      expect(
        cue.lyricTranslationSpans.map(
          (s) => cue.lyricTranslation.substring(s.textStart, s.textEnd),
        ),
        ['你好', '世界'],
      );
      expect(
        cue.lyricRomanizationSpans.map(
          (s) => cue.lyricRomanization.substring(s.textStart, s.textEnd),
        ),
        ['ni hao', 'shi jie'],
      );
      expect(cue.lyricTranslationSpans.first.startTime, ms(10200));
      expect(cue.lyricRomanizationSpans.first.startTime, ms(10500));
      expect(cue.lyricRomanizationSpans.last.endTime, ms(13500));
      const source = '1\n00:00:10,000 --> 00:00:14,000\nHello\n';
      final restored = SubtitleWordTimingStore.decode(
        source,
        SubtitleWordTimingStore.encode(source, [cue]),
        SubtitleParser.parse(source),
      ).single;
      expect(restored.lyricTranslationSpans, cue.lyricTranslationSpans);
      expect(restored.lyricRomanizationSpans, cue.lyricRomanizationSpans);
    },
  );
  test('standard TTML inherits relative time, duration and frame units', () {
    final cue = SubtitleParser.parse(
      '''<tt xmlns="http://www.w3.org/ns/ttml"
      xmlns:ttp="http://www.w3.org/ns/ttml#parameter" ttp:frameRate="25">
      <body begin="10s"><div begin="2s"><p begin="1s" dur="3s"><span begin="0s" dur="25f">字</span><span begin="1s" dur="2s">词</span></p></div></body></tt>''',
    ).single;
    expect(cue.startTime, ms(13000));
    expect(cue.timedSpans.first.endTime, ms(14000));
    expect(cue.timedSpans.last.endTime, ms(16000));
  });
  test('TTML does not invent word timing on a sentence-only line', () {
    final cue = SubtitleParser.parse(
      '<tt><body><p begin="1s" end="3s">Sentence</p></body></tt>',
    ).single;
    expect(cue.timedSpans, isEmpty);
  });
  final platform = {
    'YRC': '[1000,2000](1000,1000,0)Hello (2000,1000,0)world',
    'QRC': '[1000,2000]Hello (1000,1000)world(2000,1000)',
    'KRC': '[1000,2000]<0,1000,0>Hello <1000,1000,0>world',
    'Lyricify': '[4]Hello (1000,1000)world(2000,1000)',
  };
  for (final entry in platform.entries) {
    test('${entry.key} converts its own time base correctly', () {
      final cue = SubtitleParser.parse(entry.value).single;
      expect(cue.text, 'Hello world');
      expect(tokens(cue), ['Hello', 'world']);
      expect(cue.timedSpans.last.startTime, ms(2000));
      expect(cue.timedSpans.last.endTime, ms(3000));
    });
  }
  test('Lyricify Lines identifies end times from its file type', () {
    final cue = SubtitleParser.parse(
      '[1000,3000]Hello',
      sourcePath: 'sample.lyl',
    ).single;
    expect(cue.endTime, ms(3000));
    expect(cue.timedSpans, isEmpty);
  });
  test('binary KRC is XOR decoded then inflated before timing parsing', () {
    final compressed = ZLibEncoder().encodeBytes(utf8.encode(platform['KRC']!));
    const key = [
      0x40,
      0x47,
      0x61,
      0x77,
      0x5e,
      0x32,
      0x74,
      0x47,
      0x51,
      0x36,
      0x31,
      0x2d,
      0xce,
      0xd2,
      0x6e,
      0x69,
    ];
    final bytes = [
      ...ascii.encode('krc1'),
      for (var i = 0; i < compressed.length; i++)
        compressed[i] ^ key[i % key.length],
    ];
    expect(
      tokens(SubtitleParser.parse(SubtitleParser.decodeBytes(bytes)).single),
      ['Hello', 'world'],
    );
  });
  test('QRC encrypted vector from the independent AMLL codec decrypts', () {
    const hex =
        'd6a2be95d6447372499f58d3fd074a3d777af214671e749d630114f20768df6040a848e62efb6474';
    final text = SubtitleParser.decodeBytes(ascii.encode(hex));
    expect(text, platform['QRC']);
    expect(tokens(SubtitleParser.parse(text).single), ['Hello', 'world']);
  });
  test('QRC XML attribute envelope is unwrapped', () {
    final cue = SubtitleParser.parse(
      '<QrcInfos><Lyric_1 LyricContent="${platform['QRC']!}"/></QrcInfos>',
    ).single;
    expect(tokens(cue), ['Hello', 'world']);
  });
  test('QQ local QRC magic header and outer XOR envelope are decoded', () {
    const hex =
        '9825b0ace3028368e8fc6cb43de59cd6872de76a004bc283dfd802cbea496069dd33e95e91becd56b02b71c43796733338a27d';
    final bytes = [
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];
    expect(
      SubtitleParser.decodeBytes(bytes, sourcePath: 'local.qrc'),
      platform['QRC'],
    );
  });
  test('single enhanced word uses an explicitly supplied media end', () {
    final cue = SubtitleParser.parse(
      '[00:01.00]<00:01.00>Hello',
      mediaDuration: ms(3000),
    ).single;
    expect(tokens(cue), ['Hello']);
    expect(cue.timedSpans.single.endTime, ms(3000));
  });
  test(
    'Azure fast transcription keeps millisecond phrase and word offsets',
    () {
      final cue = SubtitleParser.parse(
        jsonEncode({
          'phrases': [
            {
              'text': 'Hello world',
              'offsetMilliseconds': 1000,
              'durationMilliseconds': 2000,
              'words': [
                {
                  'text': 'Hello',
                  'offsetMilliseconds': 1000,
                  'durationMilliseconds': 1000,
                },
                {
                  'text': 'world',
                  'offsetMilliseconds': 2000,
                  'durationMilliseconds': 1000,
                },
              ],
            },
          ],
        }),
      ).single;
      expect(tokens(cue), ['Hello', 'world']);
      expect(cue.timedSpans.last.startTime, ms(2000));
    },
  );
  final jsonFixtures = <String, Map>{
    'Whisper': {
      'segments': [
        {
          'start': 1,
          'end': 3,
          'text': 'Hello world',
          'words': [
            {'word': ' Hello', 'start': 1, 'end': 2},
            {'word': ' world', 'start': 2, 'end': 3},
          ],
        },
      ],
    },
    'Gongyi': {
      'utterances': [
        {
          'start_time': 1000,
          'end_time': 3000,
          'transcript': 'Hello world',
          'words': [
            {'label': 'Hello', 'start_time': 1000, 'end_time': 2000},
            {'label': 'world', 'start_time': 2000, 'end_time': 3000},
          ],
        },
      ],
    },
    'Doubao': {
      'result': {
        'utterances': [
          {
            'start_time': 1000,
            'end_time': 3000,
            'text': 'Hello world',
            'words': [
              {'text': 'Hello', 'start_time': 1000, 'end_time': 2000},
              {'text': 'world', 'start_time': 2000, 'end_time': 3000},
            ],
          },
        ],
      },
    },
    'Tencent': {
      'Response': {
        'Data': {
          'ResultDetail': [
            {
              'StartMs': 1000,
              'EndMs': 3000,
              'FinalSentence': 'Hello world',
              'Words': [
                {'Word': 'Hello', 'OffsetStartMs': 0, 'OffsetEndMs': 1000},
                {'Word': 'world', 'OffsetStartMs': 1000, 'OffsetEndMs': 2000},
              ],
            },
          ],
        },
      },
    },
    'Aliyun': {
      'Result': {
        'Sentences': [
          {'BeginTime': 1000, 'EndTime': 3000, 'Text': 'Hello world'},
        ],
        'Words': [
          {'Word': 'Hello', 'BeginTime': 1000, 'EndTime': 2000},
          {'Word': 'world', 'BeginTime': 2000, 'EndTime': 3000},
        ],
      },
    },
    'Azure ticks': {
      'recognizedPhrases': [
        {
          'offsetInTicks': 10000000,
          'durationInTicks': 20000000,
          'nBest': [
            {
              'display': 'Hello world',
              'displayWords': [
                {
                  'displayText': 'Hello',
                  'offsetInTicks': 10000000,
                  'durationInTicks': 10000000,
                },
                {
                  'displayText': 'world',
                  'offsetInTicks': 20000000,
                  'durationInTicks': 10000000,
                },
              ],
            },
          ],
        },
      ],
    },
    'Azure ISO': {
      'recognizedPhrases': [
        {
          'offset': 'PT1S',
          'duration': 'PT2S',
          'nBest': [
            {
              'display': 'Hello world',
              'words': [
                {'word': 'Hello', 'offset': 'PT1S', 'duration': 'PT1S'},
                {'word': 'world', 'offset': 'PT2S', 'duration': 'PT1S'},
              ],
            },
          ],
        },
      ],
    },
    'Google v1': {
      'results': [
        {
          'alternatives': [
            {
              'transcript': 'Hello world',
              'words': [
                {'word': 'Hello', 'startTime': '1s', 'endTime': '2s'},
                {'word': 'world', 'startTime': '2s', 'endTime': '3s'},
              ],
            },
          ],
        },
      ],
    },
    'Google v2': {
      'results': [
        {
          'alternatives': [
            {
              'transcript': 'Hello world',
              'words': [
                {'word': 'Hello', 'startOffset': '1s', 'endOffset': '2s'},
                {'word': 'world', 'startOffset': '2s', 'endOffset': '3s'},
              ],
            },
          ],
        },
      ],
    },
  };
  for (final entry in jsonFixtures.entries) {
    test('${entry.key} preserves source text and converts units once', () {
      final cue = SubtitleParser.parse(jsonEncode(entry.value)).single;
      expect(cue.text, 'Hello world');
      expect(cue.startTime, ms(1000));
      expect(cue.endTime, ms(3000));
      expect(tokens(cue), ['Hello', 'world']);
      expect(cue.timedSpans.last.startTime, ms(2000));
    });
  }
  test('Amazon untimed punctuation stays attached to the previous word', () {
    final cue = SubtitleParser.parse(
      jsonEncode({
        'results': {
          'transcripts': [
            {'transcript': 'Hello world!'},
          ],
          'items': [
            {
              'type': 'pronunciation',
              'start_time': '1',
              'end_time': '2',
              'alternatives': [
                {'content': 'Hello'},
              ],
            },
            {
              'type': 'pronunciation',
              'start_time': '2',
              'end_time': '3',
              'alternatives': [
                {'content': 'world'},
              ],
            },
            {
              'type': 'punctuation',
              'alternatives': [
                {'content': '!'},
              ],
            },
          ],
        },
      }),
    ).single;
    expect(cue.text, 'Hello world!');
    expect(tokens(cue), ['Hello', 'world!']);
  });
  test('FunASR tokens and punctuation use millisecond intervals', () {
    final cue = SubtitleParser.parse(
      jsonEncode([
        {
          'text': '你好，世界！',
          'timestamp': [
            [1000, 1500],
            [1500, 2000],
            [2000, 2500],
            [2500, 3000],
          ],
        },
      ]),
    ).single;
    expect(cue.text, '你好，世界！');
    expect(tokens(cue), ['你', '好', '世', '界']);
    expect(cue.timedSpans.last.endTime, ms(3000));
  });
  test('unknown JSON fails explicitly rather than guessing timing fields', () {
    expect(() => SubtitleParser.parse('{"foo":[1,2]}'), throwsFormatException);
  });
  test('failed text correspondence falls back to the original sentence', () {
    final cue = SubtitleParser.parse(
      jsonEncode({
        'segments': [
          {
            'start': 1,
            'end': 3,
            'text': 'Actual sentence',
            'words': [
              {'word': 'Unrelated', 'start': 1, 'end': 3},
            ],
          },
        ],
      }),
    ).single;
    expect(cue.text, 'Actual sentence');
    expect(cue.timedSpans, isEmpty);
  });
  const wordSrt =
      '1\n00:00:01,000 --> 00:00:02,000\nHello\n\n'
      '2\n00:00:02,000 --> 00:00:03,000\nworld!\n\n'
      '3\n00:00:04,000 --> 00:00:05,000\nNext\n';
  test('ordinary SRT remains ungrouped unless word import is chosen', () {
    expect(SubtitleParser.parse(wordSrt).length, 3);
    final grouped = TimedSubtitleParser.parseWordSrt(wordSrt);
    expect(grouped.length, 2);
    expect(grouped.first.text, 'Hello world!');
    expect(tokens(grouped.first), ['Hello', 'world!']);
  });
  test('Whisper underline SRT reconstructs one sentence with two ranges', () {
    final cues = TimedSubtitleParser.parseWordSrt(
      '1\n00:00:01,000 --> 00:00:02,000\n<u>Hello</u> world\n\n'
      '2\n00:00:02,000 --> 00:00:03,000\nHello <u>world</u>\n',
    );
    expect(cues.length, 1);
    expect(tokens(cues.single), ['Hello', 'world']);
  });
  test('grapheme clusters are never split while mapping words', () {
    expect(
      TimedSubtitleParser.alignWords('e\u0301🙂', [
        TimedSubtitleWord('e', ms(1000), ms(2000)),
      ]),
      isEmpty,
    );
    expect(
      TimedSubtitleParser.alignWords('e\u0301🙂', [
        TimedSubtitleWord('e\u0301', ms(1000), ms(2000)),
        TimedSubtitleWord('🙂', ms(2000), ms(3000)),
      ]).length,
      2,
    );
  });
  test(
    'slice placement, reindexing and checkpoint recovery keep word ranges',
    () {
      final original = SubtitleParser.parse(
        jsonEncode(jsonFixtures['Whisper']),
      ).single;
      final placed = TranscriptionSubtitleMerger.placeSlice(
        relative: [original],
        sliceStart: const Duration(seconds: 10),
        overlap: Duration.zero,
        sliceLength: const Duration(seconds: 5),
      );
      final result = TranscriptionSubtitleMerger.finish(placed).single;
      expect(result.startTime, ms(11000));
      expect(result.timedSpans.last.startTime, ms(12000));
      final checkpoint = TranscriptionPieceRecord(
        startMs: 10000,
        lengthMs: 5000,
        cues: [result],
      );
      final restored = TranscriptionPieceRecord.tryParse(
        jsonDecode(jsonEncode(checkpoint.toJson())),
      )!;
      expect(restored.cues.single.timedSpans.last.endTime, ms(13000));
    },
  );
  test(
    'editing invalidates only the edited cue; the undo snapshot still has timing',
    () {
      final original = SubtitleParser.parse(
        jsonEncode(jsonFixtures['Whisper']),
      ).single;
      expect(original.copyWith(text: 'New sentence').timedSpans, isEmpty);
      expect(original.timedSpans.length, 2);
      expect(original.copyWith(index: 5).timedSpans.length, 2);
    },
  );
  test(
    'structured overlapping lyrics bypass sliding-caption normalization',
    () {
      final cues = List.generate(
        5,
        (i) => SubtitleItem(
          index: i,
          startTime: ms(i * 100),
          endTime: ms(1000),
          text: 'Voice $i',
          isStructuredLyric: true,
        ),
      );
      expect(YouTubeAutoCaptionNormalizer.shouldNormalize(cues), isFalse);
    },
  );
  test(
    'progress clamps at exact word boundaries and holds after completion',
    () {
      final span = SubtitleTimedSpan(
        textStart: 0,
        textEnd: 1,
        startTime: ms(1000),
        endTime: ms(2000),
      );
      expect(musicTimedSpanProgress(span, ms(0)), 0);
      expect(musicTimedSpanProgress(span, ms(1500)), 0.5);
      expect(musicTimedSpanProgress(span, ms(2500)), 1);
    },
  );
  test(
    'companions validate text, stay hidden and follow task copies',
    () async {
      final root = await Directory.systemTemp.createTemp('word_timing_');
      addTearDown(() => root.delete(recursive: true));
      final primary = File('${root.path}/source.srt');
      const source = '1\n00:00:01,000 --> 00:00:03,000\nHello world\n';
      await primary.writeAsString(source);
      final cue = SubtitleParser.parse(
        jsonEncode(jsonFixtures['Whisper']),
      ).single;
      final sidecarPath = await SubtitleWordTimingStore.write(primary.path, [
        cue,
      ]);
      final decoded = await SubtitleWordTimingStore.attach(
        primary.path,
        source,
        SubtitleParser.parse(source),
      );
      expect(tokens(decoded.single), ['Hello', 'world']);
      expect(
        SubtitleWordTimingStore.decode(
          '${source}changed',
          await File(sidecarPath!).readAsString(),
          SubtitleParser.parse(source),
        ).single.timedSpans,
        isEmpty,
      );
      final storage = TaskSubtitleStorageService(dataRootOverride: root);
      final copy = await storage.copyIntoTask('card-a', primary.path);
      expect(
        await File(SubtitleWordTimingStore.pathFor(copy)).exists(),
        isTrue,
      );
      expect((await storage.listTaskSubtitles('card-a')).length, 1);
      expect(
        await storage.taskDirectorySize('card-a'),
        await File(copy).length() +
            await File(SubtitleWordTimingStore.pathFor(copy)).length(),
      );
      await storage.deleteTaskDirectory('card-a');
      expect(await File(copy).exists(), isFalse);
      expect(await File(sidecarPath).exists(), isTrue);
    },
  );
}
