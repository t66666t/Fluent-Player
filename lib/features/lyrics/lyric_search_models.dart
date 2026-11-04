import '../../models/subtitle_model.dart';

enum LyricSource {
  netease('网易云音乐'),
  qqMusic('QQ 音乐'),
  lrclib('LRCLIB');

  const LyricSource(this.label);
  final String label;
}

class LyricSearchTrack {
  const LyricSearchTrack({
    required this.source,
    required this.id,
    required this.title,
    this.artist = '',
    this.album = '',
    this.duration = Duration.zero,
    this.secondaryId = '',
    this.syncedLyrics,
  });

  final LyricSource source;
  final String id;
  final String secondaryId;
  final String title;
  final String artist;
  final String album;
  final Duration duration;
  final String? syncedLyrics;
  String get key => '${source.name}:$id';
}

enum LyricSourcePhase { pending, retrying, loadingLyrics, ready, failed }

/// One provider's progress inside a single search.
///
/// Sources publish independently so a slow or flaky provider can retry
/// without hiding tracks that another provider has already returned.
class LyricSourceStatus {
  const LyricSourceStatus({
    required this.source,
    required this.phase,
    this.attempt = 1,
    this.maxAttempts = 3,
    this.trackCount = 0,
    this.checkedCount = 0,
    this.message,
  });

  final LyricSource source;
  final LyricSourcePhase phase;
  final int attempt;
  final int maxAttempts;
  final int trackCount;
  final int checkedCount;
  final String? message;

  String get summary => switch (phase) {
    LyricSourcePhase.pending => '${source.label} 正在搜索',
    LyricSourcePhase.retrying => '${source.label} 正在重试 $attempt/$maxAttempts',
    LyricSourcePhase.loadingLyrics =>
      '${source.label} 正在获取歌词 $checkedCount/$trackCount',
    LyricSourcePhase.ready =>
      '${source.label} $trackCount 首${message == null ? '' : ' · $message'}',
    LyricSourcePhase.failed => '${source.label} ${message ?? '加载失败'}',
  };
}

/// A successful provider response without an importable lyric timeline.
/// Retrying the same response cannot make an instrumental or untimed song usable.
class LyricUnavailableException extends FormatException {
  const LyricUnavailableException() : super('这首歌曲没有可用的逐句时间轴，请选择其他版本或来源');
}

class LyricSearchResults {
  const LyricSearchResults(
    this.tracks, {
    this.errors = const {},
    this.statuses = const {},
  });
  final List<LyricSearchTrack> tracks;
  final Map<LyricSource, String> errors;
  final Map<LyricSource, LyricSourceStatus> statuses;
}

class DownloadedLyrics {
  DownloadedLyrics({
    required this.track,
    required List<SubtitleItem> original,
    List<SubtitleItem> translation = const [],
  }) : original = List.unmodifiable(original),
       translation = List.unmodifiable(translation);

  final LyricSearchTrack track;
  final List<SubtitleItem> original;
  final List<SubtitleItem> translation;
  bool get hasWordTiming => original.any((cue) => cue.timedSpans.isNotEmpty);
  bool get hasChineseTranslation => translation.isNotEmpty;

  List<SubtitleItem> shifted(List<SubtitleItem> cues, Duration offset) => [
    for (final cue in cues)
      if (cue.endTime + offset > Duration.zero)
        cue.copyWith(
          startTime: cue.startTime + offset < Duration.zero
              ? Duration.zero
              : cue.startTime + offset,
          endTime: cue.endTime + offset,
          timedSpans: [
            for (final span in cue.timedSpans)
              if (span.endTime + offset > Duration.zero)
                SubtitleTimedSpan(
                  textStart: span.textStart,
                  textEnd: span.textEnd,
                  startTime: span.startTime + offset < Duration.zero
                      ? Duration.zero
                      : span.startTime + offset,
                  endTime: span.endTime + offset,
                  role: span.role,
                  agentId: span.agentId,
                ),
          ],
        ),
  ];
}

/// Conservative filename cleanup: keep version words such as Live/Remix,
/// because they identify a different recording and timeline.
class LyricSearchQuery {
  static String fileStem(String name) => name.trim().replaceFirst(
    RegExp(
      r'\.(mp3|flac|wav|m4a|aac|ogg|opus|wma|aiff|alac|mp4|mkv|webm|mov)$',
      caseSensitive: false,
    ),
    '',
  );

  static String clean(String name) => fileStem(name)
      .replaceAll(
        RegExp(
          r'[\[【(（](?:[^\]】)）]*(?:\d{3,4}p|\d{2,3}kbps|flac|mp3|无损|高音质|高清|官方MV)[^\]】)）]*)[\]】)）]',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceFirst(RegExp(r'^\s*\d{1,3}[.、_-]\s*'), '')
      .replaceAll('_', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static List<String> suggestions(String name) {
    final stem = fileStem(name);
    return {
      clean(name),
      for (final part in stem.split(RegExp(r'\s+[-–—|·]\s+|【|】|\[|\]')))
        clean(part),
    }.where((part) => part.isNotEmpty).take(8).toList();
  }
}
