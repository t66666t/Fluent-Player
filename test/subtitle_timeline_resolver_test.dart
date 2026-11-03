import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/subtitle_timeline_resolver.dart';

SubtitleItem _subtitle(int index, int startMs, int endMs, String text) {
  return SubtitleItem(
    index: index,
    startTime: Duration(milliseconds: startMs),
    endTime: Duration(milliseconds: endMs),
    text: text,
  );
}

void main() {
  group('SubtitleTimelineResolver', () {
    final subtitles = <SubtitleItem>[
      _subtitle(1, 1000, 2000, 'first'),
      _subtitle(2, 2000, 3200, 'second'),
      _subtitle(3, 4000, 5200, 'third'),
    ];
    final resolver = SubtitleTimelineResolver(subtitles);

    test('在字幕区间内返回当前字幕索引', () {
      expect(resolver.indexAtMs(1000), 0);
      expect(resolver.indexAtMs(1999), 0);
      expect(resolver.indexAtMs(2000), 1);
      expect(resolver.indexAtMs(4500), 2);
    });

    test('遵循现有时间轴规则处理间隙与越界', () {
      expect(resolver.indexAtMs(999), -1);
      expect(resolver.indexAtMs(3200), 1);
      expect(resolver.indexAtMs(3999), 1);
      expect(resolver.indexAtMs(5300), -1);
      expect(
        resolver.subtitleAt(const Duration(milliseconds: 3200))?.text,
        'second',
      );
    });

    test('preferredIndex 命中当前或下一条字幕', () {
      expect(resolver.indexAtMs(1500, preferredIndex: 0), 0);
      expect(resolver.indexAtMs(2100, preferredIndex: 0), 1);
      expect(resolver.indexAtMs(4500, preferredIndex: 1), 2);
    });

    test('可计算下一个字幕边界', () {
      expect(
        resolver.nextBoundaryAfter(const Duration(milliseconds: 1500)),
        const Duration(milliseconds: 2000),
      );
      expect(
        resolver.nextBoundaryAfter(const Duration(milliseconds: 3200)),
        const Duration(milliseconds: 4000),
      );
      expect(
        resolver.nextBoundaryAfter(const Duration(milliseconds: 4500)),
        const Duration(milliseconds: 5200),
      );
      expect(
        resolver.nextBoundaryAfter(const Duration(milliseconds: 5200)),
        isNull,
      );
    });

    test('continuous display fills gaps without shortening overlaps', () {
      final resolver = SubtitleTimelineResolver(<SubtitleItem>[
        _subtitle(1, 1000, 5000, 'narration'),
        _subtitle(2, 3000, 4000, 'on-screen translation'),
        _subtitle(3, 6000, 7000, 'next'),
      ]);

      expect(resolver.activeIndicesAtMs(3500, extendToNextStart: true), <int>[
        0,
        1,
      ]);
      expect(resolver.activeIndicesAtMs(5500, extendToNextStart: true), <int>[
        0,
      ]);
      expect(resolver.activeIndicesAtMs(4500, extendToNextStart: true), <int>[
        0,
      ]);
    });

    test('finds a long cue across already-ended cues between it and now', () {
      final resolver = SubtitleTimelineResolver(<SubtitleItem>[
        _subtitle(1, 0, 10000, 'long narration'),
        _subtitle(2, 1000, 2000, 'short one'),
        _subtitle(3, 3000, 4000, 'short two'),
      ]);

      expect(resolver.activeIndicesAtMs(3500), <int>[0, 2]);
      expect(resolver.activeIndicesAtMs(5000), <int>[0]);
    });

    test('continuous display extends only across a real gap', () {
      final resolver = SubtitleTimelineResolver(<SubtitleItem>[
        _subtitle(1, 1000, 2000, 'first'),
        _subtitle(2, 4000, 5000, 'second'),
      ]);

      expect(resolver.activeIndicesAtMs(3000), isEmpty);
      expect(resolver.activeIndicesAtMs(3000, extendToNextStart: true), <int>[
        0,
      ]);
      expect(resolver.activeIndicesAtMs(4000, extendToNextStart: true), <int>[
        1,
      ]);
    });

    test('duplicate same-end cues stay highlighted together across a gap', () {
      final resolver = SubtitleTimelineResolver(<SubtitleItem>[
        _subtitle(1, 0, 5000, 'hello'),
        _subtitle(2, 0, 5000, '你好'),
        _subtitle(3, 8000, 9000, 'next'),
      ]);

      expect(resolver.activeIndicesAtMs(2500, extendToNextStart: true), <int>[
        0,
        1,
      ]);
      expect(resolver.activeIndicesAtMs(6500, extendToNextStart: true), <int>[
        0,
        1,
      ]);
      expect(resolver.activeIndicesAtMs(8000, extendToNextStart: true), <int>[
        2,
      ]);
    });

    test(
      'partial overlap keeps the later-ending cue across the following gap',
      () {
        final resolver = SubtitleTimelineResolver(<SubtitleItem>[
          _subtitle(1, 0, 5000, 'first'),
          _subtitle(2, 4000, 8000, 'second'),
          _subtitle(3, 10000, 11000, 'third'),
        ]);

        expect(resolver.activeIndicesAtMs(4500, extendToNextStart: true), <int>[
          0,
          1,
        ]);
        expect(resolver.activeIndicesAtMs(6000, extendToNextStart: true), <int>[
          1,
        ]);
        expect(resolver.activeIndicesAtMs(9000, extendToNextStart: true), <int>[
          1,
        ]);
        expect(resolver.activeIndicesAtMs(10000, extendToNextStart: true), <int>[
          2,
        ]);
      },
    );
  });
}
