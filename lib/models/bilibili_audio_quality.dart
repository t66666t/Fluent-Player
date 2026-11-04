import 'bilibili_models.dart';

/// An actual audio representation returned for this video and account.
class BilibiliAudioQuality {
  final int id;
  final String label;
  final bool isSpecial;

  const BilibiliAudioQuality({
    required this.id,
    required this.label,
    this.isSpecial = false,
  });

  factory BilibiliAudioQuality.fromStream(StreamItem track) {
    final codec = track.codecs.toLowerCase();
    final String label;
    final bool special;
    if (track.id == 30251 ||
        codec.contains('flac') ||
        track.qualityName == 'Hi-Res无损') {
      label = 'Hi-Res无损';
      special = true;
    } else if (track.id == 30250 ||
        codec.contains('ec-3') ||
        codec.contains('eac3') ||
        track.qualityName == '杜比全景声') {
      label = '杜比全景声';
      special = true;
    } else {
      special = false;
      label = '普通音质';
    }
    return BilibiliAudioQuality(id: track.id, label: label, isSpecial: special);
  }

  @override
  bool operator ==(Object other) =>
      other is BilibiliAudioQuality &&
      other.id == id &&
      other.label == label &&
      other.isSpecial == isSpecial;

  @override
  int get hashCode => Object.hash(id, label, isSpecial);
}
