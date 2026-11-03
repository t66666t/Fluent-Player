import 'package:path/path.dart' as p;

import 'subtitle_entry_metadata.dart';
import 'subtitle_search_models.dart';
import 'subtitle_release_info.dart';

class SubtitleBatchTarget {
  const SubtitleBatchTarget({
    required this.id,
    required this.title,
    required this.path,
    this.hasSubtitle = false,
  });
  final String id, title, path;
  final bool hasSubtitle;
  SubtitleEpisode? get episode =>
      SubtitleEpisode.parse(title) ?? SubtitleEpisode.parse(p.basename(path));
}

class SubtitleBatchCandidate {
  const SubtitleBatchCandidate({
    required this.hit,
    required this.file,
    this.document,
  });
  final SubtitleSearchHit hit;
  final SubtitleSearchFile file;
  final SubtitleSearchDocument? document;
  String get name => document?.name ?? file.name;
  String get key => '${hit.key}|${file.id}|$name';
  SubtitleEpisode? get episode {
    final parsed = SubtitleEpisode.parse(name);
    if (parsed == null) return null;
    final release = hit.releaseInfo;
    return SubtitleEpisode(
      parsed.number,
      season:
          parsed.season ?? (release.seasonEnd == null ? release.season : null),
      series: parsed.series,
    );
  }
}

class SubtitleEpisode {
  const SubtitleEpisode(this.number, {this.season, this.series = ''});
  final int number;
  final int? season;
  final String series;
  String get label => season == null
      ? '第 $number 集'
      : 'S${season.toString().padLeft(2, '0')}E${number.toString().padLeft(2, '0')}';

  static SubtitleEpisode? parse(String input) {
    final info = SubtitleReleaseInfo.parse(input);
    if (info.special || info.episode == null || info.episodeEnd != null) {
      return null;
    }
    return SubtitleEpisode(
      info.episode!,
      season: info.season,
      series: info.series,
    );
  }
}

class SubtitleBatchMatch {
  SubtitleBatchMatch({
    required this.target,
    required this.options,
    required this.confident,
    required this.reason,
  });
  final SubtitleBatchTarget target;
  final List<SubtitleBatchCandidate> options;
  final bool confident;
  final String reason;
}

class SubtitleBatchMatcher {
  const SubtitleBatchMatcher();
  List<SubtitleBatchMatch> match({
    required List<SubtitleBatchTarget> targets,
    required List<SubtitleBatchCandidate> candidates,
    required String anchorTitle,
    String preferredName = '',
    int episodeOffset = 0,
    List<String> seriesAliases = const [],
    String? catalogId,
  }) {
    final anchorEpisode = SubtitleEpisode.parse(anchorTitle);
    final anchor = anchorEpisode?.series ?? '';
    final aliases = seriesAliases
        .map(SubtitleReleaseInfo.cleanTitle)
        .map(SubtitleReleaseInfo.normalize)
        .where((s) => s.isNotEmpty)
        .toSet();
    bool sameSeries(String a, String b) =>
        a.isEmpty ||
        b.isEmpty ||
        a == b ||
        aliases.contains(a) && aliases.contains(b);
    String edition(String name) => [
      p.posix.dirname(name.replaceAll('\\', '/')).toLowerCase(),
      ...RegExp(r'\([^)]*\)|\[[^\]]*\]')
          .allMatches(name)
          .map((m) => m[0]!.toLowerCase())
          .where(
            (s) => !RegExp(
              r'^\[(?:\d+(?:v\d+)?|[a-f\d]{8}|\d{3,4}p|HEVC[^\]]*|x26[45][^\]]*|FLAC[^\]]*|AAC[^\]]*|OPUS[^\]]*)\]$',
              caseSensitive: false,
            ).hasMatch(s),
          ),
      RegExp(
            r'\.(?:chs|cht|scjp|tcjp|ja|jp|en|eng)(?:&eng)?(?=\.)',
            caseSensitive: false,
          ).firstMatch(name)?[0] ??
          '',
    ].join('|');
    final preferredEdition = edition(preferredName);
    final preferredExtension = p.extension(preferredName).toLowerCase();
    final preferredFolder = p.posix
        .dirname(preferredName.replaceAll('\\', '/'))
        .toLowerCase();
    // Parse each subtitle once and index by episode. Large anime folders must
    // not repeatedly parse every filename for every video on the UI isolate.
    final parsed = <String, SubtitleEpisode>{};
    final byEpisode = <int, List<SubtitleBatchCandidate>>{};
    final versionScores = <String, int>{};
    for (final candidate in candidates) {
      final episode = candidate.episode;
      if (episode == null) {
        continue;
      }
      parsed[candidate.key] = episode;
      (byEpisode[episode.number] ??= []).add(candidate);
      versionScores[candidate.key] =
          (preferredFolder != '.' &&
                  p.posix
                          .dirname(candidate.name.replaceAll('\\', '/'))
                          .toLowerCase() ==
                      preferredFolder
              ? 24
              : 0) +
          (preferredEdition.isNotEmpty &&
                  edition(candidate.name) == preferredEdition
              ? 12
              : 0) +
          (preferredExtension.isNotEmpty &&
                  p.extension(candidate.name).toLowerCase() ==
                      preferredExtension
              ? 3
              : 0);
    }
    return [
      for (final target in targets)
        () {
          final episode = target.episode;
          if (episode == null) {
            final info = SubtitleReleaseInfo.parse(target.title);
            final pathInfo = SubtitleReleaseInfo.parse(p.basename(target.path));
            return SubtitleBatchMatch(
              target: target,
              options: [],
              confident: false,
              reason: info.special || pathInfo.special
                  ? '特别篇需要单独确认，不会自动当作正片'
                  : '无法识别集数，需手动选择',
            );
          }
          if (anchorEpisode?.season != null &&
              episode.season != null &&
              anchorEpisode!.season != episode.season) {
            return SubtitleBatchMatch(
              target: target,
              options: [],
              confident: false,
              reason: '与当前剧集的季数不同，已跳过',
            );
          }
          if (!sameSeries(anchor, episode.series)) {
            return SubtitleBatchMatch(
              target: target,
              options: [],
              confident: false,
              reason: '片名与当前剧集不同，已跳过',
            );
          }
          final options =
              (byEpisode[episode.number + episodeOffset] ??
                      <SubtitleBatchCandidate>[])
                  .where((c) {
                    final e = parsed[c.key];
                    return e != null &&
                        e.number == episode.number + episodeOffset &&
                        (sameSeries(anchor, e.series) ||
                            catalogId != null &&
                                c.hit.catalogId == catalogId) &&
                        (e.season == null ||
                            episode.season == null ||
                            e.season == episode.season);
                  })
                  .toList();
          int score(SubtitleBatchCandidate c) =>
              (versionScores[c.key] ?? 0) +
              (parsed[c.key]!.season != null &&
                      parsed[c.key]!.season == episode.season
                  ? 20
                  : 0);
          options.sort((a, b) => score(b).compareTo(score(a)));
          final ambiguousSeason =
              options.isNotEmpty &&
              parsed[options.first.key]?.season == null &&
              options.first.hit.releaseInfo.seasonEnd != null;
          final preferredHits = preferredEdition.isEmpty
              ? const <SubtitleBatchCandidate>[]
              : options
                    .where((c) => edition(c.name) == preferredEdition)
                    .toList();
          final uniquePreferred = preferredHits.length == 1;
          final groups = options
              .map((c) => subtitleEditionGroup(c.name))
              .where((group) => group.isNotEmpty)
              .toSet();
          // A higher preference score is only a sort key. Automatic selection
          // needs one remaining candidate, or the edition the user already chose.
          final confident =
              !ambiguousSeason &&
              options.isNotEmpty &&
              (options.length == 1 || uniquePreferred) &&
              (groups.length <= 1 || uniquePreferred);
          return SubtitleBatchMatch(
            target: target,
            options: options,
            confident: confident,
            reason: options.isEmpty
                ? '没有对应集数的字幕'
                : confident
                ? '集数匹配${episodeOffset == 0 ? '' : ' · 字幕第 ${episode.number + episodeOffset} 集'}${target.hasSubtitle ? ' · 已有主字幕' : ''}'
                : ambiguousSeason
                ? '合集跨季，字幕未标季数，请手动确认'
                : '同集有多个版本，请选择',
          );
        }(),
    ];
  }
}
