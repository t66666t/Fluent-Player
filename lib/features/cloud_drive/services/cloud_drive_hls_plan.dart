/// One media playlist, identified without its signed URLs.
class HlsMediaPlan {
  const HlsMediaPlan({
    required this.mediaSequence,
    required this.segments,
    this.mapUri,
    this.encrypted = false,
    this.audioPlaylistUri,
    this.variantPlaylistUri,
    this.endList = true,
  });

  final int mediaSequence;
  final List<HlsSegmentPlan> segments;
  final Uri? mapUri;
  final bool encrypted;
  final Uri? audioPlaylistUri;
  final Uri? variantPlaylistUri;
  final bool endList;

  bool get isMaster => variantPlaylistUri != null;

  /// Sequence, duration and byte range. Signed URLs are not part of identity.
  String get fingerprint => segments
      .map(
        (segment) =>
            '${segment.sequence}:${segment.durationMs}:${segment.byteStart ?? ''}:${segment.byteLength ?? ''}',
      )
      .join('|');
}

class HlsSegmentPlan {
  const HlsSegmentPlan({
    required this.sequence,
    required this.uri,
    required this.durationMs,
    this.byteStart,
    this.byteLength,
  });

  final int sequence;
  final Uri uri;
  final int durationMs;
  final int? byteStart;
  final int? byteLength;
}

HlsMediaPlan? parseHlsMediaPlan(String playlist, Uri base) {
  if (!playlist.trimLeft().startsWith('#EXTM3U')) return null;
  final lines = playlist.split(RegExp(r'\r?\n'));
  var mediaSequence = 0;
  Uri? mapUri;
  Uri? audioPlaylist;
  Uri? variant;
  var encrypted = false;
  var pendingDurationMs = 0;
  var pendingByteStart = 0;
  int? pendingByteLength;
  var sawInf = false;
  var endList = false;
  final segments = <HlsSegmentPlan>[];
  var sequence = 0;
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index].trim();
    if (line == '#EXT-X-ENDLIST') endList = true;
    if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
      mediaSequence = int.tryParse(line.substring(22).trim()) ?? 0;
      sequence = mediaSequence;
      continue;
    }
    if (line.startsWith('#EXT-X-MAP:')) {
      final uri = _attr(line, 'URI');
      if (uri != null) mapUri = base.resolve(uri);
      continue;
    }
    if (line.startsWith('#EXT-X-KEY:')) {
      final method = _attr(line, 'METHOD') ?? '';
      if (method.isNotEmpty && method.toUpperCase() != 'NONE') encrypted = true;
      continue;
    }
    if (line.startsWith('#EXT-X-MEDIA:') && line.contains('TYPE=AUDIO')) {
      final uri = _attr(line, 'URI');
      if (uri != null && uri.isNotEmpty) audioPlaylist = base.resolve(uri);
      continue;
    }
    if (line.startsWith('#EXT-X-STREAM-INF:')) {
      final next = index + 1 < lines.length ? lines[index + 1].trim() : '';
      if (next.isNotEmpty && !next.startsWith('#')) {
        variant = base.resolve(next);
      }
      continue;
    }
    if (line.startsWith('#EXTINF:')) {
      final seconds = double.tryParse(line.substring(8).split(',').first) ?? 0;
      pendingDurationMs = (seconds * 1000).round();
      sawInf = true;
      continue;
    }
    if (line.startsWith('#EXT-X-BYTERANGE:')) {
      final spec = line.substring('#EXT-X-BYTERANGE:'.length).trim();
      final parts = spec.split('@');
      pendingByteLength = int.tryParse(parts.first);
      if (parts.length > 1) pendingByteStart = int.tryParse(parts[1]) ?? 0;
      continue;
    }
    if (line.isEmpty || line.startsWith('#')) continue;
    if (!sawInf) continue;
    segments.add(
      HlsSegmentPlan(
        sequence: sequence,
        uri: base.resolve(line),
        durationMs: pendingDurationMs,
        byteStart: pendingByteLength == null ? null : pendingByteStart,
        byteLength: pendingByteLength,
      ),
    );
    if (pendingByteLength != null) pendingByteStart += pendingByteLength;
    pendingByteLength = null;
    sequence += 1;
    sawInf = false;
  }
  if (variant != null && segments.isEmpty) {
    return HlsMediaPlan(
      mediaSequence: mediaSequence,
      segments: const [],
      audioPlaylistUri: audioPlaylist,
      variantPlaylistUri: variant,
    );
  }
  if (segments.isEmpty && mapUri == null) return null;
  return HlsMediaPlan(
    mediaSequence: mediaSequence,
    segments: segments,
    mapUri: mapUri,
    encrypted: encrypted,
    audioPlaylistUri: audioPlaylist,
    endList: endList,
  );
}

bool hlsPlansMatch(HlsMediaPlan left, HlsMediaPlan right) =>
    left.fingerprint == right.fingerprint && left.encrypted == right.encrypted;

String? _attr(String line, String name) {
  final match = RegExp('$name="?([^",]*)"?').firstMatch(line);
  return match?.group(1);
}
