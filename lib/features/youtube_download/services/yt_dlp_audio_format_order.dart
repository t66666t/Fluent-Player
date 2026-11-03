import 'package:video_player_app/features/youtube_download/models/youtube_download_models.dart';

/// List order and the default audio pick share this comparator.
///
/// Language groups come first so a dubbed track cannot jump ahead of the
/// original just because its container scores well. Inside a group, bitrate
/// decides quality. Codec is only a tie-break: a 48 kbps AAC must stay below
/// a 160 kbps Opus.
class YtDlpAudioFormatOrder {
  const YtDlpAudioFormatOrder._();

  static List<AudioFormat> sorted(Iterable<AudioFormat> formats) {
    final copy = formats.toList();
    copy.sort(compare);
    return copy;
  }

  static String? pickFormatId(Iterable<AudioFormat> formats) {
    final ordered = sorted(formats);
    if (ordered.isEmpty) return null;
    return ordered.first.formatId;
  }

  static int compare(AudioFormat a, AudioFormat b) {
    final group = _languageGroup(a).compareTo(_languageGroup(b));
    if (group != 0) return group;

    // A missing language on an original rendition must not put an unknown
    // bitrate ahead of an explicitly identified original audio track.
    final known = (_knownBitrate(a) == null ? 1 : 0).compareTo(
      _knownBitrate(b) == null ? 1 : 0,
    );
    if (known != 0) return known;
    final language = _languageClusterKey(a).compareTo(_languageClusterKey(b));
    if (language != 0) return language;

    final bitrate = _comparePreferHigher(_knownBitrate(a), _knownBitrate(b));
    if (bitrate != 0) return bitrate;
    if (_knownBitrate(a) == null && _knownBitrate(b) == null) {
      final quality = _comparePreferHigher(a.qualityRank, b.qualityRank);
      if (quality != 0) return quality;
    }

    // Codec before DRC so `140-drc` stays beside `140`, not after every
    // other codec that happens to share the bitrate.
    final codec = _codecRank(a).compareTo(_codecRank(b));
    if (codec != 0) return codec;

    final drc = (a.isDynamicRangeCompressed ? 1 : 0).compareTo(
      b.isDynamicRangeCompressed ? 1 : 0,
    );
    if (drc != 0) return drc;

    final sampleRate = _comparePreferHigher(
      a.audioSampleRate,
      b.audioSampleRate,
    );
    if (sampleRate != 0) return sampleRate;

    return a.formatId.compareTo(b.formatId);
  }

  /// 0 original, 1 Chinese, 2 English, 3 other tagged languages, 4 untagged.
  static int _languageGroup(AudioFormat format) {
    if (format.isDefaultTrack) return 0;
    final primary = _primaryLanguage(format.language);
    if (primary == null) return 4;
    if (primary == 'zh' || primary == 'cmn') return 1;
    if (primary == 'en') return 2;
    return 3;
  }

  /// Original and "other language" buckets stay clustered by language code.
  /// Chinese and English are already their own groups, so bitrate applies
  /// across simplified/traditional and regional English variants.
  static String _languageClusterKey(AudioFormat format) {
    final group = _languageGroup(format);
    if (group == 1 || group == 2 || group == 4) return '';
    return _primaryLanguage(format.language) ?? '';
  }

  static String? _primaryLanguage(String? language) {
    final normalized =
        language?.trim().replaceAll('_', '-').toLowerCase() ?? '';
    if (normalized.isEmpty || RegExp(r'^\d+$').hasMatch(normalized)) {
      return null;
    }
    final primary = normalized.split('-').first.trim();
    if (primary.isEmpty || RegExp(r'^\d+$').hasMatch(primary)) return null;
    return primary;
  }

  static int? _knownBitrate(AudioFormat format) {
    final bitrate = format.bitrate;
    if (bitrate == null || bitrate <= 0) return null;
    return bitrate;
  }

  /// Nulls sort after any real value. Otherwise higher values come first.
  static int _comparePreferHigher(int? a, int? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return b.compareTo(a);
  }

  /// Lower rank wins a bitrate tie. AAC/m4a is the compatibility preference.
  static int _codecRank(AudioFormat format) {
    final codec = (format.audioCodec ?? '').toLowerCase();
    final ext = format.ext.trim().toLowerCase();
    final isAac =
        codec.contains('aac') ||
        codec.contains('mp4a') ||
        ext == 'm4a' ||
        ext == 'aac';
    if (isAac) return 0;
    if (codec.contains('opus') || ext == 'opus') return 1;
    return 2;
  }
}
