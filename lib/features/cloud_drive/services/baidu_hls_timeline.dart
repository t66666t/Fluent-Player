import 'dart:convert';

import 'cloud_drive_hls_plan.dart';

/// Sent only by our libmpv adapter to the loopback gateway; never upstream.
const cloudDriveNativeTimelineHeader = 'x-fluent-player-native-timeline';

/// Baidu can package HEVC as independent MP4 files, each starting near zero,
/// with periodic DISCONTINUITY markers. FFmpeg's HLS demuxer seeks by the
/// global timestamp inside these local timelines and reaches EOF without a
/// frame. mpv's EDL assigns each file its own offset and opens only the selected
/// segment. There is no re-encoding, whole-file download or signed URL exposure.
String? baiduIndependentMp4Timeline(
  String playlist,
  Uri base,
  String Function(Uri uri) localize, {
  required bool verifiedMp4,
}) {
  if (!verifiedMp4 || !playlist.contains('#EXT-X-ENDLIST')) return null;
  final plan = parseHlsMediaPlan(playlist, base);
  if (plan == null ||
      plan.isMaster ||
      plan.encrypted ||
      plan.mapUri != null ||
      plan.audioPlaylistUri != null ||
      plan.segments.isEmpty) {
    return null;
  }
  final discontinuities = playlist
      .split('\n')
      .where((line) => line.trim() == '#EXT-X-DISCONTINUITY')
      .length;
  if (discontinuities == 0 ||
      plan.segments.any(
        (segment) => segment.durationMs <= 0 || segment.byteLength != null,
      )) {
    return null;
  }
  final result = StringBuffer(
    '# mpv EDL v0\n!no_chapters\n'
    '!delay_open,media_type=video\n!delay_open,media_type=audio\n',
  );
  for (final segment in plan.segments) {
    final uri = localize(segment.uri);
    result.writeln(
      '%${utf8.encode(uri).length}%$uri,0,'
      '${(segment.durationMs / 1000).toStringAsFixed(3)}',
    );
  }
  return result.toString();
}
