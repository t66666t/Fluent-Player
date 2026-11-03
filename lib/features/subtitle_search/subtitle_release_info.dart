import 'package:path/path.dart' as p;

/// Shared filename interpretation for search, result labels and batch import.
/// Missing seasons stay unknown: an anime's absolute episode is not S01.
class SubtitleReleaseInfo {
  const SubtitleReleaseInfo({
    this.season,
    this.seasonEnd,
    this.episode,
    this.episodeEnd,
    this.pack = false,
    this.special = false,
    this.series = '',
    this.videoSource = '',
    this.part,
    this.specialKind = '',
  });
  final int? season, seasonEnd, episode, episodeEnd, part;
  final bool pack, special;
  final String series, videoSource, specialKind;

  String get label {
    if (special) return '特别篇 / 特典';
    final parts = <String>[
      if (season != null)
        seasonEnd != null && seasonEnd != season
            ? '第 $season—$seasonEnd 季'
            : '第 $season 季',
      if (episode != null)
        episodeEnd != null && episodeEnd != episode
            ? '第 $episode—$episodeEnd 集'
            : '第 $episode 集',
      if (pack && episode == null) '整季 / 合集',
    ];
    return parts.isEmpty ? '季集未标注' : parts.join(' · ');
  }

  bool accepts(int? wantedSeason, int? wantedEpisode) {
    if (special && (wantedSeason != null || wantedEpisode != null)) {
      return false;
    }
    if (wantedSeason != null &&
        season != null &&
        (wantedSeason < season! || wantedSeason > (seasonEnd ?? season!))) {
      return false;
    }
    if (wantedEpisode != null &&
        episode != null &&
        (wantedEpisode < episode! ||
            wantedEpisode > (episodeEnd ?? episode!))) {
      return false;
    }
    return true;
  }

  static String normalize(String text) => text.toLowerCase().replaceAll(
    RegExp(r'[^\p{L}\p{N}]', unicode: true),
    '',
  );

  static String _numbers(String input) =>
      String.fromCharCodes(
        input.runes.map((c) => c >= 0xff10 && c <= 0xff19 ? c - 0xfee0 : c),
      ).replaceAllMapped(RegExp(r'第([零〇一二两三四五六七八九十百千]+)([季期集话話])'), (m) {
        const digits = {
          '零': 0,
          '〇': 0,
          '一': 1,
          '二': 2,
          '两': 2,
          '三': 3,
          '四': 4,
          '五': 5,
          '六': 6,
          '七': 7,
          '八': 8,
          '九': 9,
        };
        var total = 0, digit = 0;
        for (final c in m[1]!.split('')) {
          final unit = const {'十': 10, '百': 100, '千': 1000}[c];
          if (unit == null) {
            digit = digits[c]!;
          } else {
            total += (digit == 0 ? 1 : digit) * unit;
            digit = 0;
          }
        }
        return '第${total + digit}${m[2]}';
      });

  static SubtitleReleaseInfo parse(String input) {
    final parent = _numbers(p.posix.dirname(input.replaceAll('\\', '/')));
    final text = _numbers(p.posix.basename(input.replaceAll('\\', '/')))
        .replaceFirst(
          RegExp(
            r'\.(mkv|mp4|avi|mov|webm|ts|srt|ass|ssa|vtt|zip|rar|7z)$',
            caseSensitive: false,
          ),
          '',
        );
    final partMatch = RegExp(
      r'(?:Part|Cour)\s*(\d{1,2})|第\s*(\d{1,2})\s*(?:部分|クール)',
      caseSensitive: false,
    ).firstMatch(text);
    final part = int.tryParse(partMatch?.group(1) ?? partMatch?.group(2) ?? '');
    // Part 2 is a cour split, not a season and not the episode number.
    final episodeSource = partMatch == null
        ? text
        : text.replaceRange(partMatch.start, partMatch.end, ' ');
    final special =
        RegExp(
          r'(?:^|[\[\] ._-])(?:OVA|OAD|SP|NCOP|NCED|OP|ED)(?:[\[\] ._\-\d]|$)|短篇',
          caseSensitive: false,
        ).hasMatch(text) ||
        RegExp(
          r'(^|/)(?:SP|OVA|OAD|NCOP|NCED|特典)(/|$)',
          caseSensitive: false,
        ).hasMatch(parent) ||
        RegExp(r'特典|特别篇|特別編').hasMatch(text) &&
            !RegExp(r'全集|合集|整季').hasMatch(text);
    var pair =
        RegExp(
          r'S(\d{1,3})[ ._-]*EP?(\d{1,4})(?:v\d)?(?:\s*[-~～—]\s*(?:E|EP)?(\d{1,4}))?\b',
          caseSensitive: false,
        ).firstMatch(text) ??
        RegExp(
          r'\b(\d{1,2})x(\d{1,4})(?:\s*[-~]\s*(\d{1,4}))?\b',
        ).firstMatch(text);
    final seasonMatch =
        RegExp(
          r'(?:\bS|Season\s*)(\d{1,3})(?:\s*[-~～—]\s*(?:S)?(\d{1,3}))?\b',
          caseSensitive: false,
        ).firstMatch(text) ??
        RegExp(r'第\s*(\d{1,3})\s*[季期]').firstMatch(text) ??
        RegExp(
          r'\b(\d{1,2})(?:st|nd|rd|th)\s+Season\b',
          caseSensitive: false,
        ).firstMatch(text);
    final parentSeason = RegExp(
      r'(?:\bS|Season\s*)(\d{1,3})\b|第\s*(\d{1,3})\s*[季期]',
      caseSensitive: false,
    ).firstMatch(parent);
    final season = pair != null
        ? int.tryParse(pair[1]!)
        : int.tryParse(
            seasonMatch?[1] ?? parentSeason?[1] ?? parentSeason?[2] ?? '',
          );
    final seasonEnd =
        pair == null && seasonMatch != null && seasonMatch.groupCount > 1
        ? int.tryParse(seasonMatch[2] ?? '')
        : null;
    RegExpMatch? epMatch;
    if (pair == null) {
      epMatch =
          RegExp(
            r'第\s*(\d{1,4})(?:\s*[-~～—]\s*(\d{1,4}))?\s*[集话話]',
          ).firstMatch(episodeSource) ??
          RegExp(
            r'(?:^|[ ._\-\[])EP?\s*(\d{1,4})(?:v\d)?(?:\s*[-~～—]\s*(?:EP?)?(\d{1,4}))?(?:\b|\])',
            caseSensitive: false,
          ).firstMatch(episodeSource) ??
          RegExp(
            r'(?:\s-\s|\[)(\d{1,4})(?:v\d)?(?:\s*[-~～—]\s*(\d{1,4}))?(?=\]|\s|$|TV|集|话)',
            caseSensitive: false,
          ).firstMatch(episodeSource);
      if (epMatch == null && seasonMatch == null) {
        epMatch = RegExp(
          r'(?:^|[ ._-])(\d{1,3})(?:v\d)?(?:$|[ ._-])',
          caseSensitive: false,
        ).firstMatch(episodeSource);
      }
    }
    var episode = int.tryParse(pair?[2] ?? epMatch?[1] ?? '');
    var end = int.tryParse(
      pair?[3] ??
          (epMatch != null && epMatch.groupCount > 1 ? epMatch[2] : null) ??
          '',
    );
    if (episode != null &&
        ({480, 576, 720, 1080, 2160}.contains(episode) ||
            episode >= 1900 && episode <= 2099)) {
      episode = end = null;
    }
    if (end != null && episode != null && (end < episode || end > 9999)) {
      end = null;
    }
    final marker = pair?.start ?? epMatch?.start ?? seasonMatch?.start;
    final rawSeries = marker == null ? text : text.substring(0, marker);
    final series = normalize(cleanTitle(rawSeries));
    final source =
        RegExp(
          r'\b(Blu[ ._-]?Ray|BDRip|WEB[ ._-]?DL|WEBRip|HDTV|DVDRip)\b',
          caseSensitive: false,
        ).firstMatch(text)?[1] ??
        '';
    return SubtitleReleaseInfo(
      season: season,
      seasonEnd: seasonEnd,
      episode: special ? null : episode,
      episodeEnd: special ? null : end,
      special: special,
      series: series,
      pack:
          end != null ||
          seasonEnd != null ||
          season != null && episode == null ||
          RegExp(
            r'整季|合集|全集|全\d+|complete',
            caseSensitive: false,
          ).hasMatch(text),
      videoSource: source.toUpperCase().replaceAll(RegExp(r'[ ._-]'), ''),
      part: part,
      specialKind: RegExp(
        r'OVA|OAD|NCOP|NCED|特典|特别篇|特別編',
        caseSensitive: false,
      ).firstMatch('$parent $text')?.group(0)?.toUpperCase() ?? '',
    );
  }

  static String cleanTitle(String input) {
    var title = p.posix
        .basename(_numbers(input).replaceAll('\\', '/'))
        .replaceFirst(
          RegExp(
            r'\.(mp4|mkv|avi|mov|webm|m4v|ts|m2ts|flv|srt|ass|ssa|vtt|zip)$',
            caseSensitive: false,
          ),
          '',
        );
    // Bracketed anime titles are meaningful. Keep non-technical groups when
    // the entire release is bracketed, rather than deleting the whole title.
    final outside = title
        .replaceAll(RegExp(r'\[[^\]]*\]|【[^】]*】'), '')
        .replaceAll(RegExp(r'[ ._-]'), '');
    title = title.replaceAllMapped(RegExp(r'\[([^\]]*)\]|【([^】]*)】'), (m) {
      final value = m[1] ?? m[2] ?? '';
      if (outside.isNotEmpty) return ' ';
      if (RegExp(
        r'^\d+(?:v\d+)?$|\d{3,4}[pP]|x26[45]|HEVC|FLAC|AAC|BDRip|WebRip|Raws\b|Subs?\b|Group\b|字幕组|^[a-f\d]{8}$',
        caseSensitive: false,
      ).hasMatch(value)) {
        return ' ';
      }
      return ' $value ';
    });
    title = title
        .replaceAll(
          RegExp(
            r'\bS\d{1,3}(?:[ ._-]*EP?\d{1,4}(?:[-~]\d+)?)?\b|\b\d{1,2}x\d{1,4}\b|第\s*\d+\s*[集话話季期]',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(
          RegExp(r'\s-\s\d{1,4}(?:v\d+)?(?:\s|$).*', caseSensitive: false),
          ' ',
        )
        .replaceAll(
          RegExp(
            r'\b(?:2160p|1080p|720p|480p|x26[45]|h26[45]|HEVC|BluRay|BDRip|WEB-DL|WEBRip)\b',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(RegExp(r'[._]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return title;
  }
}
