import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_batch_matcher.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_search_models.dart';

SubtitleBatchCandidate candidate(
  String name, {
  SubtitleSearchDocument? document,
}) => SubtitleBatchCandidate(
  hit: const SubtitleSearchHit(
    source: SubtitleSearchSource.jimaku,
    id: '729',
    title: 'Frieren',
  ),
  file: SubtitleSearchFile(
    id: name,
    name: name,
    url: 'https://jimaku.cc/entry/729/download/file.srt',
  ),
  document: document,
);

void main() {
  test(
    'a similarly named spinoff and an upstream fallback title cannot authorize a different series',
    () {
      final rows = const SubtitleBatchMatcher().match(
        anchorTitle: 'Breaking.Bad.S01E01',
        targets: const [
          SubtitleBatchTarget(
            id: 'main',
            title: 'Breaking.Bad.S01E01',
            path: '1.mkv',
          ),
          SubtitleBatchTarget(
            id: 'spinoff',
            title: 'Breaking.Bad.Minisodes.S01E01',
            path: '2.mkv',
          ),
        ],
        candidates: [
          const SubtitleBatchCandidate(
            hit: SubtitleSearchHit(
              source: SubtitleSearchSource.xunlei,
              id: '1',
              title: 'Breaking Bad',
            ),
            file: SubtitleSearchFile(
              id: '1',
              name: 'Breaking.Bad.Minisodes.S01E01.srt',
            ),
          ),
        ],
      );
      expect(rows.every((r) => r.options.isEmpty), isTrue);
    },
  );
  test(
    'a chosen catalog permits localized filenames but a cross-season pack without file seasons stays manual',
    () {
      SubtitleBatchCandidate sub(String release) => SubtitleBatchCandidate(
        hit: SubtitleSearchHit(
          source: SubtitleSearchSource.subhd,
          id: 'pack',
          catalogId: '123',
          title: '葬送的芙莉莲',
          release: release,
        ),
        file: const SubtitleSearchFile(
          id: 'file',
          name: 'Sousou no Frieren - 01.srt',
        ),
      );
      final known = const SubtitleBatchMatcher().match(
        anchorTitle: '葬送的芙莉莲 - 01',
        catalogId: '123',
        targets: const [
          SubtitleBatchTarget(id: '1', title: '葬送的芙莉莲 - 01', path: '1.mkv'),
        ],
        candidates: [sub('Sousou no Frieren - 01')],
      );
      expect(known.single.confident, isTrue);
      final unknown = const SubtitleBatchMatcher().match(
        anchorTitle: '葬送的芙莉莲.S02E01',
        catalogId: '123',
        targets: const [
          SubtitleBatchTarget(id: '1', title: '葬送的芙莉莲.S02E01', path: '1.mkv'),
        ],
        candidates: [sub('Sousou no Frieren.S01-03')],
      );
      expect(unknown.single.confident, isFalse);
      expect(unknown.single.reason, contains('合集跨季'));
    },
  );
  test(
    'batch uses language folders and ignores bracketed episode numbers when ranking editions',
    () {
      final rows = const SubtitleBatchMatcher().match(
        anchorTitle: 'Frieren [01].mkv',
        preferredName: '简日/[Group] Frieren [01].scjp.ass',
        targets: const [
          SubtitleBatchTarget(id: 'two', title: 'Frieren [02]', path: '02.mkv'),
        ],
        candidates: [
          candidate('繁日/[Group] Frieren [02].tcjp.ass'),
          candidate('简日/[Group] Frieren [02].scjp.ass'),
        ],
      );
      expect(rows.single.confident, isTrue);
      expect(rows.single.options.first.name, startsWith('简日/'));
    },
  );
  test(
    'explicit episode offsets match continuous numbering without crossing seasons or unrelated series',
    () {
      final rows = const SubtitleBatchMatcher().match(
        anchorTitle: '番剧.S02E01.mkv',
        episodeOffset: 12,
        seriesAliases: const ['番剧', 'Anime Title'],
        targets: const [
          SubtitleBatchTarget(id: 'a', title: '番剧.S02E01', path: '1.mkv'),
        ],
        candidates: [
          candidate('Anime Title - 13.srt'),
          candidate('Other Show - 13.srt'),
          candidate('Anime Title.S01E13.srt'),
        ],
      );
      expect(rows.single.options.map((c) => c.name), ['Anime Title - 13.srt']);
      expect(rows.single.reason, contains('13'));
    },
  );
  test(
    'recognizes season episodes, Chinese and Japanese numbering and anime absolute episodes',
    () {
      expect(SubtitleEpisode.parse('Show.S02E03.1080p.mkv')!.season, 2);
      expect(SubtitleEpisode.parse('Show.2x03.mkv')!.number, 3);
      expect(SubtitleEpisode.parse('番剧 第12集.mp4')!.number, 12);
      expect(SubtitleEpisode.parse('番組 第12話.ass')!.number, 12);
      expect(SubtitleEpisode.parse('番剧 第二季 第十二集.mp4')!.number, 12);
      expect(SubtitleEpisode.parse('番剧 第二季 第十二集.mp4')!.season, 2);
      expect(SubtitleEpisode.parse('番組 第１２話.ass')!.number, 12);
      expect(
        SubtitleEpisode.parse('[Group] Frieren - 01v2 [1080p].mkv')!.number,
        1,
      );
      expect(SubtitleEpisode.parse('01.mp4')!.number, 1);
      expect(SubtitleEpisode.parse('Show [12].srt')!.number, 12);
      expect(SubtitleEpisode.parse('Show.EP123.srt')!.number, 123);
    },
  );
  test(
    'does not mistake specials, release years or video resolutions for regular episodes',
    () {
      for (final name in [
        'Show NCOP 01.mkv',
        'Show OVA 01.mkv',
        'Show - 2024.mkv',
        'Show.1080p.mkv',
        '电影 特典01.mp4',
      ]) {
        expect(SubtitleEpisode.parse(name), isNull, reason: name);
      }
    },
  );
  test(
    'ranks the chosen edition and leaves tied versions for manual confirmation',
    () {
      final matches = const SubtitleBatchMatcher().match(
        anchorTitle: 'Frieren - 01.mkv',
        preferredName: 'Frieren - 01 (AT-X 1280x720).srt',
        targets: const [
          SubtitleBatchTarget(id: 'two', title: 'Frieren - 02', path: '02.mkv'),
          SubtitleBatchTarget(
            id: 'three',
            title: 'Frieren - 03',
            path: '03.mkv',
          ),
        ],
        candidates: [
          candidate('Frieren - 02 (NF).srt'),
          candidate('Frieren - 02 (AT-X 1280x720).srt'),
          candidate('Frieren - 03 (NF).srt'),
          candidate('Frieren - 03 (CR).srt'),
        ],
      );
      expect(matches[0].confident, isTrue);
      expect(matches[0].options.first.name, contains('AT-X'));
      expect(matches[1].confident, isFalse);
    },
  );
  test(
    'rejects other shows and seasons and preserves missing episodes as review rows',
    () {
      final matches = const SubtitleBatchMatcher().match(
        anchorTitle: 'Frieren.S01E01.mkv',
        targets: const [
          SubtitleBatchTarget(id: 'a', title: 'Frieren.S01E02', path: 'a.mkv'),
          SubtitleBatchTarget(
            id: 'b',
            title: 'Different.S01E02',
            path: 'b.mkv',
          ),
          SubtitleBatchTarget(id: 'c', title: 'Frieren.S02E02', path: 'c.mkv'),
          SubtitleBatchTarget(id: 'd', title: 'Frieren.S01E04', path: 'd.mkv'),
        ],
        candidates: [
          candidate('Frieren.S01E02.srt'),
          candidate('Frieren.S02E02.srt'),
        ],
      );
      expect(matches[0].options.single.name, 'Frieren.S01E02.srt');
      expect(matches.skip(1).every((m) => m.options.isEmpty), isTrue);
    },
  );
}
