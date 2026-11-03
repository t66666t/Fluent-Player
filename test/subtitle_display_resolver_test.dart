import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/utils/subtitle_display_resolver.dart';

SubtitleItem _item(int index, int startMs, int endMs, String text) {
  return SubtitleItem(
    index: index,
    startTime: Duration(milliseconds: startMs),
    endTime: Duration(milliseconds: endMs),
    text: text,
  );
}

void main() {
  group('matchSubtitleTracks', () {
    test(
      'matches overlapping subtitles even when start offset exceeds 500ms',
      () {
        final primary = <SubtitleItem>[
          _item(0, 0, 2000, '主1'),
          _item(1, 2500, 4500, '主2'),
        ];
        final secondary = <SubtitleItem>[
          _item(0, 700, 2100, '副1'),
          _item(1, 3200, 4700, '副2'),
        ];

        final result = matchSubtitleTracks(
          primarySubtitles: primary,
          secondarySubtitles: secondary,
        );

        expect(result.primaryToSecondary, equals(<int, int>{0: 0, 1: 1}));
        expect(result.secondaryToPrimary, equals(<int, int>{0: 0, 1: 1}));
      },
    );

    test('retains split translations and exposes the strongest anchor', () {
      final primary = <SubtitleItem>[
        _item(0, 0, 2000, '主1'),
        _item(1, 2200, 4200, '主2'),
      ];
      final secondary = <SubtitleItem>[
        _item(0, 100, 1800, '副1'),
        _item(1, 2400, 3000, '副2-前'),
        _item(2, 3000, 4300, '副2-后'),
      ];

      final result = matchSubtitleTracks(
        primarySubtitles: primary,
        secondarySubtitles: secondary,
      );

      expect(result.primaryToSecondary[0], 0);
      expect(result.primaryToSecondary[1], 2);
      expect(result.primaryToSecondaryIndices, {
        0: [0],
        1: [1, 2],
      });
      expect(result.secondaryToPrimaryIndices, {
        0: [0],
        1: [1],
        2: [1],
      });
      expect(result.secondaryTextForPrimary(1, secondary), '副2-前\n副2-后');
    });
  });

  group('resolveSubtitleDisplaySelection', () {
    test('uses secondary subtitles as the display source in mode 2', () {
      final primary = <SubtitleItem>[
        _item(0, 0, 1000, '主1'),
        _item(1, 1000, 2000, '主2'),
      ];
      final secondary = <SubtitleItem>[
        _item(0, 100, 600, '副1'),
        _item(1, 700, 1200, '副2'),
        _item(2, 1500, 2200, '副3'),
      ];

      final selection = resolveSubtitleDisplaySelection(
        lineFilterMode: 2,
        primarySubtitles: primary,
        secondarySubtitles: secondary,
      );

      expect(selection.usesSecondaryTrack, isTrue);
      expect(selection.subtitles.length, 3);
      expect(selection.subtitles[0].text, '副1');
      expect(selection.subtitles[2].startTime.inMilliseconds, 1500);
    });

    test(
      'falls back to primary subtitles when no external secondary track exists',
      () {
        final primary = <SubtitleItem>[_item(0, 0, 1000, '主1\n副1')];

        final selection = resolveSubtitleDisplaySelection(
          lineFilterMode: 2,
          primarySubtitles: primary,
          secondarySubtitles: const <SubtitleItem>[],
        );

        expect(selection.usesSecondaryTrack, isFalse);
        expect(selection.subtitles, same(primary));
      },
    );
  });
}
