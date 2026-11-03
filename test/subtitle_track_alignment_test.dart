import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/utils/subtitle_display_resolver.dart';

import 'support/subtitle_alignment_fixture.dart';

SubtitleItem cue(int index, int startMs, int endMs, [String? text]) {
  return SubtitleItem(
    index: index,
    startTime: Duration(milliseconds: startMs),
    endTime: Duration(milliseconds: endMs),
    text: text ?? 'cue $index',
  );
}

void main() {
  test('all 47 Chinese OCR cues retain the correct English lyric', () {
    final primary = loadAlignmentLyrics('zh');
    final secondary = loadAlignmentLyrics('en');
    expect(primary, hasLength(47));
    expect(secondary, hasLength(40));

    final result = matchSubtitleTracks(
      primarySubtitles: primary,
      secondarySubtitles: secondary,
    );
    expect(result.primaryToSecondary, {
      for (int i = 0; i < expectedEnglishIndices.length; i++)
        i: expectedEnglishIndices[i],
    });
    expect(result.primaryToSecondaryIndices, {
      for (int i = 0; i < expectedEnglishIndices.length; i++)
        i: [expectedEnglishIndices[i]],
    });
    expect(result.secondaryToPrimaryIndices.keys, hasLength(40));
  });

  test(
    'reversing the real tracks preserves all Chinese fragments in order',
    () {
      final result = matchSubtitleTracks(
        primarySubtitles: loadAlignmentLyrics('en'),
        secondarySubtitles: loadAlignmentLyrics('zh'),
      );
      expect(result.primaryToSecondaryIndices, {
        for (int english = 0; english < 40; english++)
          english: [
            for (
              int chinese = 0;
              chinese < expectedEnglishIndices.length;
              chinese++
            )
              if (expectedEnglishIndices[chinese] == english) chinese,
          ],
      });
      expect(result.secondaryToPrimaryIndices, {
        for (int i = 0; i < expectedEnglishIndices.length; i++)
          i: [expectedEnglishIndices[i]],
      });
    },
  );

  test('merged translation can be shared by several primary fragments', () {
    final secondary = [cue(20, 700, 6700, 'Translation')];
    final result = matchSubtitleTracks(
      primarySubtitles: [
        cue(10, 0, 2000),
        cue(11, 2000, 4000),
        cue(12, 4000, 6000),
      ],
      secondarySubtitles: secondary,
    );
    expect(result.primaryToSecondaryIndices, {
      0: [0],
      1: [0],
      2: [0],
    });
    expect(result.secondaryToPrimaryIndices, {
      0: [0, 1, 2],
    });
    expect(result.secondaryTextForPrimary(2, secondary), 'Translation');
  });

  test('a long sentence retains more than six translated fragments', () {
    final secondary = List.generate(
      10,
      (i) => cue(i, i * 1000, (i + 1) * 1000),
    );
    final result = matchSubtitleTracks(
      primarySubtitles: [cue(0, 0, 10000)],
      secondarySubtitles: secondary,
    );
    expect(result.primaryToSecondaryIndices, {0: List.generate(10, (i) => i)});
    expect(
      result.secondaryTextForPrimary(0, secondary).split('\n'),
      hasLength(10),
    );
  });

  test('small boundary overlap cannot mix in the adjacent sentence', () {
    final result = matchSubtitleTracks(
      primarySubtitles: [cue(0, 300, 6300), cue(1, 6300, 12100)],
      secondarySubtitles: [cue(0, 0, 6000), cue(1, 6000, 12000)],
    );
    expect(result.primaryToSecondaryIndices, {
      0: [0],
      1: [1],
    });
  });

  test('different sentence boundaries allow many-to-many interval matches', () {
    final result = matchSubtitleTracks(
      primarySubtitles: [cue(0, 0, 6000), cue(1, 6000, 12000)],
      secondarySubtitles: [
        cue(0, 0, 4000),
        cue(1, 4000, 8000),
        cue(2, 8000, 12000),
      ],
    );
    expect(result.primaryToSecondaryIndices, {
      0: [0, 1],
      1: [1, 2],
    });
    expect(result.secondaryToPrimaryIndices, {
      0: [0],
      1: [0, 1],
      2: [1],
    });
  });

  test(
    'near starts do not bypass a strict gap limit for tiny disjoint cues',
    () {
      final result = matchSubtitleTracks(
        primarySubtitles: [cue(0, 0, 20)],
        secondarySubtitles: [cue(0, 100, 120)],
        maxGapMs: 0,
      );
      expect(result.hasMatches, isFalse);
    },
  );

  test('real silence is not extended into unrelated translations', () {
    final result = matchSubtitleTracks(
      primarySubtitles: [cue(0, 0, 1000), cue(1, 20000, 21000)],
      secondarySubtitles: [cue(0, 10000, 11000)],
    );
    expect(result.hasMatches, isFalse);
  });

  test('missing middle cue cannot steal an already matched neighbour', () {
    final result = matchSubtitleTracks(
      primarySubtitles: [cue(0, 0, 500), cue(1, 500, 1000), cue(2, 1000, 1500)],
      secondarySubtitles: [cue(0, 0, 500), cue(1, 1000, 1500)],
    );
    expect(result.primaryToSecondaryIndices, {
      0: [0],
      2: [1],
    });
  });

  test('isolated small timing gaps use a bounded mutual fallback', () {
    final primary = [cue(0, 1000, 1800), cue(1, 5000, 5800)];
    final secondary = [cue(0, 1900, 2700), cue(1, 5900, 6700)];
    final result = matchSubtitleTracks(
      primarySubtitles: primary,
      secondarySubtitles: secondary,
    );
    expect(result.primaryToSecondaryIndices, {
      0: [0],
      1: [1],
    });
    expect(
      matchSubtitleTracks(
        primarySubtitles: primary,
        secondarySubtitles: secondary,
        maxGapMs: 500,
      ).hasMatches,
      isFalse,
    );
  });

  test('90 percent timeline agreement does not force the outlier by index', () {
    final primary = List.generate(10, (i) => cue(i, i * 2000, i * 2000 + 1000));
    final secondary = List.generate(
      10,
      (i) => i == 9 ? cue(i, 45000, 46000) : cue(i, i * 2000, i * 2000 + 1000),
    );
    final result = matchSubtitleTracks(
      primarySubtitles: primary,
      secondarySubtitles: secondary,
    );
    expect(result.matchCount, 9);
    expect(result.primaryToSecondary.containsKey(9), isFalse);
  });

  test(
    'parallel cues with the same timeline retain their original pairing',
    () {
      final result = matchSubtitleTracks(
        primarySubtitles: [cue(0, 0, 2000), cue(1, 0, 2000)],
        secondarySubtitles: [cue(0, 0, 2000), cue(1, 0, 2000)],
      );
      expect(result.primaryToSecondaryIndices, {
        0: [0],
        1: [1],
      });
    },
  );

  test('unsorted source lists keep their original list indices', () {
    final result = matchSubtitleTracks(
      primarySubtitles: [cue(10, 4000, 7000), cue(11, 0, 4000)],
      secondarySubtitles: [
        cue(20, 5000, 7000),
        cue(21, 0, 4000),
        cue(22, 4000, 5000),
      ],
    );
    expect(result.primaryToSecondaryIndices, {
      0: [2, 0],
      1: [1],
    });
  });

  test('timestamp-only cues can derive a usable end from the next start', () {
    final result = matchSubtitleTracks(
      primarySubtitles: [cue(0, 0, 0), cue(1, 3000, 4000)],
      secondarySubtitles: [cue(0, 700, 3000), cue(1, 3000, 4000)],
    );
    expect(result.primaryToSecondaryIndices, {
      0: [0],
      1: [1],
    });
  });

  test('duplicate adjacent translation fragments are displayed once', () {
    final secondary = [
      cue(0, 0, 1000, 'same text'),
      cue(1, 1000, 2000, 'same  text'),
      cue(2, 2000, 3000, 'next text'),
    ];
    final result = matchSubtitleTracks(
      primarySubtitles: [cue(0, 0, 3000)],
      secondarySubtitles: secondary,
    );
    expect(
      result.secondaryTextForPrimary(0, secondary),
      'same text\nnext text',
    );
  });

  test('empty tracks leave both directions empty', () {
    final result = matchSubtitleTracks(
      primarySubtitles: [cue(0, 0, 1000)],
      secondarySubtitles: const [],
    );
    expect(result.hasMatches, isFalse);
    expect(result.primaryToSecondaryIndices, isEmpty);
    expect(result.secondaryToPrimaryIndices, isEmpty);
  });
}
