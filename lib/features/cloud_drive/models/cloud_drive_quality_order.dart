import 'cloud_drive_models.dart';

int _height(CloudDriveQualityChoice quality) {
  // Provider tier names are not pixel counts: UC's "high" may be 540P.
  final pixels = RegExp(r'(\d{2,4})\s*[pP]').firstMatch(quality.label);
  if (pixels != null) return int.parse(pixels[1]!);
  final text = '${quality.id} ${quality.label}'.toLowerCase();
  if (text.contains('8k')) return 4320;
  if (text.contains('4k')) return 2160;
  if (text.contains('2k')) return 1440;
  return switch (quality.id.toLowerCase()) {
    'uhd' => 2160,
    'qhd' => 1440,
    'super' || 'fhd' => 1080,
    'high' || 'hd' => 720,
    'sd' => 540,
    'normal' => 480,
    'ld' => 360,
    'low' => 270,
    _ => 0,
  };
}

/// Original first, then descending actual resolution. Equal-resolution tiers
/// retain their source order; unavailable tiers remain visible but unselectable.
List<CloudDriveQualityChoice> sortCloudDriveQualities(
  Iterable<CloudDriveQualityChoice> qualities,
) {
  final indexed = qualities.indexed.toList();
  indexed.sort((a, b) {
    final original = (b.$2.id == 'original' ? 1 : 0).compareTo(
      a.$2.id == 'original' ? 1 : 0,
    );
    if (original != 0) return original;
    final resolution = _height(b.$2).compareTo(_height(a.$2));
    return resolution != 0 ? resolution : a.$1.compareTo(b.$1);
  });
  return [for (final entry in indexed) entry.$2];
}
