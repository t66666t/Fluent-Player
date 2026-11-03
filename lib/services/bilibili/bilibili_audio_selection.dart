import '../../models/bilibili_audio_quality.dart';
import '../../models/bilibili_models.dart';

enum BilibiliAudioPreference {
  bestAvailable('自动最高音质'),
  hiRes('Hi-Res无损优先'),
  dolby('杜比全景声优先'),
  standard('普通音质');

  const BilibiliAudioPreference(this.label);
  final String label;

  static BilibiliAudioPreference fromStorage(String? value) =>
      values.where((option) => option.name == value).firstOrNull ??
      bestAvailable;
}

bool isBilibiliLosslessAudio(StreamItem track) =>
    track.id == 30251 || track.codecs.toLowerCase().contains('flac');

bool isBilibiliDolbyAudio(StreamItem track) {
  final codec = track.codecs.toLowerCase();
  return track.id == 30250 || codec.contains('ec-3') || codec.contains('eac3');
}

bool _isAac(StreamItem track) => track.codecs.toLowerCase().startsWith('mp4a');

bool _hasMediaAddress(StreamItem track) =>
    [track.baseUrl, ...track.backupUrls].any((value) {
      final uri = Uri.tryParse(value);
      return uri != null &&
          uri.host.isNotEmpty &&
          (uri.scheme == 'https' || uri.scheme == 'http');
    });

/// Select only representations actually returned with usable addresses for
/// this account. Lossless fidelity and spatial audio are separate preferences;
/// bitrate alone cannot rank an AAC stream above FLAC or Dolby.
StreamItem? selectBilibiliAudioTrack(
  Iterable<StreamItem> streams, {
  BilibiliAudioPreference preference = BilibiliAudioPreference.bestAvailable,
  int? preferredId,
}) {
  final available = streams.where(_hasMediaAddress).toList();
  if (preferredId != null) {
    final exact = available.where((track) => track.id == preferredId).toList()
      ..sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
    if (exact.isNotEmpty) return exact.first;
  }
  int rank(StreamItem track) {
    if ((preference == BilibiliAudioPreference.hiRes &&
            isBilibiliLosslessAudio(track)) ||
        (preference == BilibiliAudioPreference.dolby &&
            isBilibiliDolbyAudio(track)) ||
        (preference == BilibiliAudioPreference.standard && _isAac(track))) {
      return -1;
    }
    if (isBilibiliLosslessAudio(track)) return 0;
    if (isBilibiliDolbyAudio(track)) return 1;
    if (track.codecs.toLowerCase().contains('opus')) return 2;
    if (_isAac(track)) return 3;
    return 4;
  }

  available.sort((a, b) {
    final kind = rank(a).compareTo(rank(b));
    if (kind != 0) return kind;
    final bitrate = b.bandwidth.compareTo(a.bandwidth);
    return bitrate != 0 ? bitrate : b.id.compareTo(a.id);
  });
  return available.firstOrNull;
}

/// Some bundled FFmpeg builds still gate FLAC-in-MP4 behind this muxer flag.
/// Copy the compressed packets so neither lossless samples nor Atmos metadata
/// are converted to AAC during merging or video compatibility repair.
List<String> bilibiliAudioCopyArguments(StreamItem track) => [
  '-c:a',
  'copy',
  if (isBilibiliLosslessAudio(track)) ...['-strict', 'experimental'],
];

List<String> bilibiliAudioRepairArguments(StreamItem track) =>
    _isAac(track) ? ['-c:a', 'aac'] : bilibiliAudioCopyArguments(track);

/// Quality menus describe meaningful audio features, not encoder/bitrate
/// variants. Ordinary-only videos need no audio control; special videos get
/// one entry per feature and a single best ordinary-audio fallback.
List<StreamItem> bilibiliAudioMenuTracks(Iterable<StreamItem> streams) {
  final tracks = streams.where(_hasMediaAddress).toList()
    ..sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
  final special = <String, StreamItem>{};
  final ordinary = <StreamItem>[];
  for (final track in tracks) {
    final quality = BilibiliAudioQuality.fromStream(track);
    if (quality.isSpecial) {
      special.putIfAbsent(quality.label, () => track);
    } else {
      ordinary.add(track);
    }
  }
  if (special.isEmpty) return const [];
  final standard = selectBilibiliAudioTrack(
    ordinary,
    preference: BilibiliAudioPreference.standard,
  );
  return List.unmodifiable([...special.values, if (standard != null) standard]);
}
