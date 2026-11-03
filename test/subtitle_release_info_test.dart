import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_release_info.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_batch_matcher.dart';

void main() {
  test(
    'recognizes episodes, ranges, quarters and continuous anime numbering',
    () {
      for (final name in [
        'Show.S02E03.mkv',
        'Show.2x03.srt',
        '番剧 第二季 第三话.ass',
        '番剧 第２季 第３話.ass',
      ]) {
        final info = SubtitleReleaseInfo.parse(name);
        expect(info.season, 2, reason: name);
        expect(info.episode, 3, reason: name);
      }
      final absolute = SubtitleReleaseInfo.parse(
        '[Group] Show - 113v2 [1080p].mkv',
      );
      expect(absolute.episode, 113);
      expect(absolute.season, isNull);
      final range = SubtitleReleaseInfo.parse(
        '[DBD-Raws][葬送的芙莉莲][01-28TV全集+特典映像][1080P]',
      );
      expect(range.episode, 1);
      expect(range.episodeEnd, 28);
      expect(range.pack, isTrue);
      expect(range.special, isFalse);
      final seasons = SubtitleReleaseInfo.parse(
        'Breaking.Bad.S01-05.1080p.BluRay',
      );
      expect(seasons.seasonEnd, 5);
      expect(seasons.accepts(3, 14), isTrue);
      expect(seasons.accepts(6, 1), isFalse);
      expect(
        SubtitleReleaseInfo.parse('Sousou no Frieren 2nd Season').season,
        2,
      );
      expect(SubtitleReleaseInfo.parse('葬送のフリーレン 第2期').season, 2);
      expect(SubtitleReleaseInfo.parse('Season 02/01.ass').season, 2);
      expect(SubtitleReleaseInfo.parse('Season 02/01.ass').episode, 1);
      expect(SubtitleReleaseInfo.parse('特典/01.ass').special, isTrue);
    },
  );

  test(
    'cleaning keeps bracketed anime titles and excludes years and specials from ordinary episode matching',
    () {
      expect(
        SubtitleReleaseInfo.cleanTitle(
          '[Group][葬送的芙莉莲][01][1080P][HEVC-10bit].mkv',
        ),
        '葬送的芙莉莲',
      );
      expect(
        SubtitleReleaseInfo.cleanTitle('[Group] Frieren - 01v2 [1080p].mkv'),
        'Frieren',
      );
      for (final name in [
        'Movie.2024.1080p.mkv',
        'Show NCOP 01.mkv',
        'Show OVA 01.mkv',
        'Show - 2024.mkv',
      ]) {
        expect(SubtitleEpisode.parse(name), isNull, reason: name);
      }
    },
  );
}
