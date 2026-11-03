import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/cloud_drive_models.dart';

/// Turns a provider body into text the existing SRT/VTT parser can read.
///
/// HTML login pages and error JSON are rejected. Platform JSON becomes SRT.
/// Segmented WebVTT keeps playlist time instead of restarting every part.
String interpretCloudDriveSubtitleBody(
  String raw, {
  String? format,
  List<({Duration playlistStart, String body})> segments = const [],
}) {
  if (segments.isNotEmpty) return mergeSegmentedWebVtt(segments);
  final text = raw.replaceAll('\uFEFF', '').trim();
  if (text.isEmpty) {
    throw const CloudDriveFailure(
      CloudDriveFailureKind.unavailable,
      '字幕内容是空的',
    );
  }
  final lower = text.toLowerCase();
  if (lower.startsWith('<!doctype') ||
      lower.startsWith('<html') ||
      (text.startsWith('<') && lower.contains('<body'))) {
    throw const CloudDriveFailure(
      CloudDriveFailureKind.unavailable,
      '返回了网页而不是字幕',
    );
  }
  if (text.startsWith('{') || text.startsWith('[')) {
    return _jsonToSrt(text);
  }
  if (lower.startsWith('#extm3u')) {
    throw const CloudDriveFailure(
      CloudDriveFailureKind.unavailable,
      '字幕是分片列表，需要先合并分片',
    );
  }
  final hint = format?.toLowerCase();
  if (hint == 'json') return _jsonToSrt(text);
  if (text.startsWith('WEBVTT') ||
      text.contains('-->') ||
      text.contains('[Script Info]') ||
      hint == 'srt' ||
      hint == 'vtt' ||
      hint == 'ass') {
    return raw.replaceAll('\uFEFF', '');
  }
  throw const CloudDriveFailure(
    CloudDriveFailureKind.unavailable,
    '字幕内容无法识别',
  );
}

String mergeSegmentedWebVtt(List<({Duration playlistStart, String body})> parts) {
  final cues = <_Cue>[];
  final seen = <String>{};
  for (final part in parts) {
    for (final cue in _cuesIn(part.body)) {
      var start = cue.start;
      var end = cue.end;
      if (part.playlistStart > const Duration(seconds: 1) &&
          start < const Duration(seconds: 1)) {
        start += part.playlistStart;
        end += part.playlistStart;
      }
      final key = '${start.inMilliseconds}|${cue.text}';
      if (!seen.add(key)) continue;
      cues.add(_Cue(start, end, cue.text));
    }
  }
  cues.sort((a, b) => a.start.compareTo(b.start));
  if (cues.isEmpty) {
    throw const CloudDriveFailure(
      CloudDriveFailureKind.unavailable,
      '分片字幕里没有可用台词',
    );
  }
  final buffer = StringBuffer('WEBVTT\n\n');
  for (final cue in cues) {
    buffer
      ..writeln('${_vtt(cue.start)} --> ${_vtt(cue.end)}')
      ..writeln(cue.text)
      ..writeln();
  }
  return buffer.toString();
}

class SubtitlePlaylistSegment {
  const SubtitlePlaylistSegment({
    required this.start,
    required this.uri,
  });

  final Duration start;
  final Uri uri;
}

/// Media playlist of subtitle parts. Master playlists are not segmented text.
List<SubtitlePlaylistSegment> subtitlePlaylistSegments(
  String playlist,
  Uri base,
) {
  if (!playlist.trimLeft().startsWith('#EXTM3U')) return const [];
  if (playlist.contains('#EXT-X-STREAM-INF')) return const [];
  final lines = const LineSplitter().convert(playlist);
  final segments = <SubtitlePlaylistSegment>[];
  var clock = Duration.zero;
  var pending = false;
  var duration = Duration.zero;
  for (final raw in lines) {
    final line = raw.trim();
    if (line.startsWith('#EXTINF:')) {
      final seconds = double.tryParse(line.substring(8).split(',').first) ?? 0;
      duration = Duration(milliseconds: (seconds * 1000).round());
      pending = true;
      continue;
    }
    if (line.isEmpty || line.startsWith('#')) continue;
    if (!pending) continue;
    segments.add(
      SubtitlePlaylistSegment(
        start: clock,
        uri: base.resolve(line),
      ),
    );
    clock += duration;
    pending = false;
  }
  return segments;
}

/// Baidu's `M3U8_SUBTITLE_SRT` directory.
///
/// The official player reads a URI attribute or the first URI line after
/// `#EXT-X-MEDIA`. Those lines are subtitle addresses, not HLS media segments.
/// A signed query is not part of the track id, so a refreshed address still
/// matches the same track. HTML and error JSON are rejected instead of being
/// reported as an empty directory.
List<CloudDriveSubtitleTrack> parseBaiduSubtitleDirectory(
  String playlist, {
  required Uri base,
  required String accountId,
  required String fileId,
  required String revision,
}) {
  var text = playlist;
  if (text.startsWith('\uFEFF')) text = text.substring(1);
  text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    throw const CloudDriveFailure(
      CloudDriveFailureKind.unavailable,
      '字幕目录是空的',
    );
  }
  final lower = trimmed.toLowerCase();
  if (lower.startsWith('<!doctype') ||
      lower.startsWith('<html') ||
      (trimmed.startsWith('<') && lower.contains('<body'))) {
    throw const CloudDriveFailure(
      CloudDriveFailureKind.unavailable,
      '返回了网页而不是字幕目录',
    );
  }
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    throw const CloudDriveFailure(
      CloudDriveFailureKind.unavailable,
      '字幕目录返回了错误',
    );
  }
  if (!trimmed.contains('#EXTM3U') && !trimmed.contains('#EXT-X-MEDIA')) {
    throw const CloudDriveFailure(
      CloudDriveFailureKind.unavailable,
      '字幕目录无法识别',
    );
  }
  final tracks = <CloudDriveSubtitleTrack>[];
  final seen = <String, int>{};
  Map<String, String>? pending;
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#EXT-X-MEDIA:')) {
      final attributes = parseQuotedAttributes(
        line.substring('#EXT-X-MEDIA:'.length),
      );
      final type = (attributes['TYPE'] ?? '').toUpperCase();
      if (type == 'AUDIO' || type == 'VIDEO') {
        pending = null;
        continue;
      }
      final inline = attributes['URI'];
      if (inline != null && inline.isNotEmpty) {
        _addBaiduTrack(
          tracks,
          seen,
          attributes: attributes,
          uriText: inline,
          base: base,
          accountId: accountId,
          fileId: fileId,
          revision: revision,
        );
        pending = null;
      } else {
        pending = attributes;
      }
      continue;
    }
    if (line.startsWith('#')) continue;
    if (pending == null) continue;
    _addBaiduTrack(
      tracks,
      seen,
      attributes: pending,
      uriText: line,
      base: base,
      accountId: accountId,
      fileId: fileId,
      revision: revision,
    );
    pending = null;
  }
  return tracks;
}

/// Attribute text that keeps commas, equals signs and escapes inside quotes.
Map<String, String> parseQuotedAttributes(String raw) {
  final values = <String, String>{};
  var index = 0;
  while (index < raw.length) {
    while (index < raw.length && ' \t,'.contains(raw[index])) {
      index++;
    }
    if (index >= raw.length) break;
    final nameStart = index;
    while (index < raw.length && _isAttributeName(raw[index])) {
      index++;
    }
    if (nameStart == index || index >= raw.length || raw[index] != '=') {
      while (index < raw.length && raw[index] != ',') {
        index++;
      }
      continue;
    }
    final name = raw.substring(nameStart, index).toUpperCase();
    index++;
    String value;
    if (index < raw.length && raw[index] == '"') {
      index++;
      final buffer = StringBuffer();
      while (index < raw.length) {
        final character = raw[index];
        if (character == '\\' && index + 1 < raw.length) {
          buffer.write(raw[index + 1]);
          index += 2;
          continue;
        }
        if (character == '"') {
          index++;
          break;
        }
        buffer.write(character);
        index++;
      }
      value = buffer.toString();
    } else {
      final valueStart = index;
      while (index < raw.length && raw[index] != ',') {
        index++;
      }
      value = raw.substring(valueStart, index).trim();
    }
    if (name.isNotEmpty) values[name] = value;
  }
  return values;
}

bool _isAttributeName(String character) {
  final code = character.codeUnitAt(0);
  return (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122) ||
      (code >= 48 && code <= 57) ||
      character == '_' ||
      character == '-';
}

void _addBaiduTrack(
  List<CloudDriveSubtitleTrack> tracks,
  Map<String, int> seen, {
  required Map<String, String> attributes,
  required String uriText,
  required Uri base,
  required String accountId,
  required String fileId,
  required String revision,
}) {
  final resolved = _resolveSubtitleUri(base, uriText);
  if (resolved == null) return;
  final name = _optionalAttribute(attributes['NAME']) ??
      _optionalAttribute(attributes['LANGUAGE']) ??
      '网盘字幕';
  final language = _optionalAttribute(attributes['LANGUAGE']);
  final videoLanguage = _optionalAttribute(attributes['VIDEO_LAN']) ?? '';
  final format = _baiduSubtitleFormat(attributes['FORMAT']);
  final isAi = _baiduAiFlag(attributes['AI_SUB']);
  final serverId = _optionalAttribute(attributes['ID']) ??
      _optionalAttribute(attributes['SUBTITLE_ID']) ??
      _optionalAttribute(attributes['TRACK_ID']);
  var id = baiduOfficialTrackIdentity(
    accountId: accountId,
    fileId: fileId,
    revision: revision,
    serverId: serverId,
    name: name,
    language: language ?? '',
    format: format,
    isAi: isAi,
    videoLanguage: videoLanguage,
  );
  final count = seen[id] ?? 0;
  seen[id] = count + 1;
  if (count > 0) id = '$id:${count + 1}';
  tracks.add(
    CloudDriveSubtitleTrack(
      id: id,
      label: name,
      language: language,
      format: format,
      origin: CloudDriveSubtitleOrigin.provider,
      remoteUri: resolved,
      textAvailable: true,
      autoSelect: false,
      isAi: isAi,
      revision: revision,
    ),
  );
}

/// Stable identity for one official track. A signed URL is not an identity.
String baiduOfficialTrackIdentity({
  required String accountId,
  required String fileId,
  required String revision,
  String? serverId,
  required String name,
  required String language,
  required String format,
  required bool isAi,
  required String videoLanguage,
}) {
  final stableServerId = serverId?.trim() ?? '';
  if (stableServerId.isNotEmpty) {
    return 'baidu:$accountId:$fileId:$stableServerId';
  }
  final canonical = [
    accountId,
    fileId,
    revision,
    language,
    name,
    format,
    isAi ? 'ai' : 'human',
    videoLanguage,
  ].join('\u001f');
  return 'baidu:${sha256.convert(utf8.encode(canonical))}';
}

Uri? _resolveSubtitleUri(Uri base, String raw) {
  final text = raw.trim();
  if (text.isEmpty || text.startsWith('#')) return null;
  final parsed = Uri.tryParse(text);
  if (parsed == null) return null;
  if (parsed.hasScheme) {
    if (parsed.scheme != 'https' && parsed.scheme != 'http') return null;
    return parsed;
  }
  return base.resolve(text);
}

String _baiduSubtitleFormat(String? raw) {
  switch (raw?.trim().toLowerCase()) {
    case 'vtt':
    case 'webvtt':
      return 'vtt';
    case 'ass':
    case 'ssa':
      return 'ass';
    case 'json':
      return 'json';
    default:
      return 'srt';
  }
}

bool _baiduAiFlag(String? raw) {
  switch (raw?.trim().toLowerCase()) {
    case '1':
    case 'true':
    case 'yes':
      return true;
    default:
      return false;
  }
}

String? _optionalAttribute(String? value) {
  final text = value?.trim() ?? '';
  return text.isEmpty ? null : text;
}

/// `EXT-X-MEDIA:TYPE=SUBTITLES` entries. Unverified filemetas fields stay out.
List<CloudDriveSubtitleTrack> hlsSubtitleTracks(String playlist, Uri base) {
  if (!playlist.contains('TYPE=SUBTITLES')) return const [];
  final tracks = <CloudDriveSubtitleTrack>[];
  for (final raw in const LineSplitter().convert(playlist)) {
    final line = raw.trim();
    if (!line.startsWith('#EXT-X-MEDIA:') || !line.contains('TYPE=SUBTITLES')) {
      continue;
    }
    final attributes = _attributes(line.substring('#EXT-X-MEDIA:'.length));
    final uri = attributes['URI'];
    if (uri == null || uri.isEmpty) continue;
    tracks.add(
      CloudDriveSubtitleTrack(
        id: 'hls-${attributes['NAME'] ?? tracks.length}',
        label: attributes['NAME'] ?? attributes['LANGUAGE'] ?? '网盘字幕',
        language: attributes['LANGUAGE'],
        format: 'vtt',
        origin: CloudDriveSubtitleOrigin.provider,
        remoteUri: base.resolve(uri),
        textAvailable: true,
        autoSelect: tracks.isEmpty,
      ),
    );
  }
  return tracks;
}

String _jsonToSrt(String text) {
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } catch (_) {
    throw const CloudDriveFailure(
      CloudDriveFailureKind.unavailable,
      '字幕内容无法识别',
    );
  }
  if (decoded is Map) {
    final map = Map<String, dynamic>.from(decoded);
    final errno = map['errno'];
    if (errno is num && errno != 0) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.unavailable,
        '字幕接口返回了错误',
      );
    }
    if (map.containsKey('error') || map.containsKey('error_code')) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.unavailable,
        '字幕接口返回了错误',
      );
    }
  }
  final rows = _cueRows(decoded);
  if (rows.isEmpty) {
    throw const CloudDriveFailure(
      CloudDriveFailureKind.unavailable,
      '字幕内容无法识别',
    );
  }
  final buffer = StringBuffer();
  var index = 1;
  for (final row in rows) {
    buffer
      ..writeln(index++)
      ..writeln('${_srt(row.start)} --> ${_srt(row.end)}')
      ..writeln(row.text)
      ..writeln();
  }
  return buffer.toString();
}

List<_Cue> _cueRows(Object? decoded) {
  final lists = <List>[];
  if (decoded is List) {
    lists.add(decoded);
  } else if (decoded is Map) {
    for (final key in const ['body', 'subtitle', 'subtitles', 'cues', 'data']) {
      final value = decoded[key];
      if (value is List) lists.add(value);
    }
  }
  final cues = <_Cue>[];
  for (final list in lists) {
    for (final item in list.whereType<Map>()) {
      final map = Map<String, dynamic>.from(item);
      final text = _text(map['content'] ?? map['text'] ?? map['line']);
      if (text == null) continue;
      final start = _time(map['from'] ?? map['start'] ?? map['start_ms']);
      final end = _time(map['to'] ?? map['end'] ?? map['end_ms']);
      if (start == null || end == null || end < start) continue;
      cues.add(_Cue(start, end, text));
    }
  }
  return cues;
}

Duration? _time(Object? value) {
  if (value == null) return null;
  if (value is num) {
    final number = value.toDouble();
    if (number > 100000) return Duration(milliseconds: number.round());
    return Duration(milliseconds: (number * 1000).round());
  }
  final text = value.toString().trim();
  final asNumber = double.tryParse(text);
  if (asNumber != null) return _time(asNumber);
  final match = RegExp(
    r'(?:(\d+):)?(\d+):(\d+)[.,](\d+)',
  ).firstMatch(text);
  if (match == null) return null;
  final hours = int.parse(match.group(1) ?? '0');
  final minutes = int.parse(match.group(2)!);
  final seconds = int.parse(match.group(3)!);
  final fraction = match.group(4)!;
  final millis = int.parse(fraction.padRight(3, '0').substring(0, 3));
  return Duration(
    hours: hours,
    minutes: minutes,
    seconds: seconds,
    milliseconds: millis,
  );
}

List<_Cue> _cuesIn(String body) {
  final normalized = body.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final cues = <_Cue>[];
  final pattern = RegExp(
    r'(\d{2}:\d{2}:\d{2}[.,]\d{3})\s+-->\s+(\d{2}:\d{2}:\d{2}[.,]\d{3})[^\n]*\n([\s\S]*?)(?=\n\n|\n\d{2}:\d{2}:|\n\d+\n|$)',
  );
  for (final match in pattern.allMatches(normalized)) {
    final start = _time(match.group(1));
    final end = _time(match.group(2));
    final text = match.group(3)?.trim();
    if (start == null || end == null || text == null || text.isEmpty) continue;
    cues.add(_Cue(start, end, text));
  }
  return cues;
}

Map<String, String> _attributes(String raw) {
  final values = <String, String>{};
  for (final match in RegExp(
    r'([A-Z0-9-]+)=("[^"]*"|[^,]*)',
  ).allMatches(raw)) {
    var value = match.group(2)!;
    if (value.startsWith('"') && value.endsWith('"') && value.length >= 2) {
      value = value.substring(1, value.length - 1);
    }
    values[match.group(1)!] = value;
  }
  return values;
}

String? _text(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}

String _srt(Duration value) {
  final hours = value.inHours.toString().padLeft(2, '0');
  final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  final millis = value.inMilliseconds.remainder(1000).toString().padLeft(3, '0');
  return '$hours:$minutes:$seconds,$millis';
}

String _vtt(Duration value) => _srt(value).replaceFirst(',', '.');

class _Cue {
  const _Cue(this.start, this.end, this.text);

  final Duration start;
  final Duration end;
  final String text;
}
