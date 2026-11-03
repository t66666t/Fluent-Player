import 'dart:collection';
import 'dart:convert';

import '../../../utils/subtitle_parser.dart';
import '../models/cloud_drive_models.dart';
import 'cloud_drive_subtitle_text.dart';

/// Completed Quark tasks return UTF-8 SRT in a Base64 subtitle_content field.
/// Validate the decoded text too: an encoded error page is not a subtitle.
String decodeQuarkSubtitleBody(String content) {
  const limit = 8 * 1024 * 1024;
  if (content.length > (limit * 4 / 3).ceil() + 4) {
    throw const CloudDriveFailure(
      CloudDriveFailureKind.unavailable,
      '夸克字幕内容过大',
    );
  }
  String body;
  try {
    body = interpretCloudDriveSubtitleBody(content);
  } on CloudDriveFailure {
    try {
      body = interpretCloudDriveSubtitleBody(
        utf8.decode(base64.decode(base64.normalize(content.trim()))),
      );
    } on FormatException {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.unavailable,
        '夸克字幕内容无法识别',
      );
    }
  }
  if (utf8.encode(body).length > limit || SubtitleParser.parse(body).isEmpty) {
    throw const CloudDriveFailure(
      CloudDriveFailureKind.unavailable,
      '夸克字幕内容无法识别',
    );
  }
  return body;
}

/// Quark's third menu item displays the existing source and translation
/// together. Split at both tracks' cue boundaries, rather than pairing by row
/// number: translations may combine sentences or use different timings.
String mergeQuarkBilingualSubtitles(String source, String translation) {
  final first = SubtitleParser.parse(source);
  final second = SubtitleParser.parse(translation);
  if (first.isEmpty || second.isEmpty) {
    throw const CloudDriveFailure(
      CloudDriveFailureKind.unavailable,
      '双语字幕缺少可读的原文或译文',
    );
  }
  final events = <int, List<({int lane, int index, String? text})>>{};
  for (var lane = 0; lane < 2; lane++) {
    final cues = lane == 0 ? first : second;
    for (var i = 0; i < cues.length; i++) {
      final cue = cues[i];
      if (cue.endTime <= cue.startTime || cue.text.trim().isEmpty) continue;
      (events[cue.startTime.inMilliseconds] ??= []).add((
        lane: lane,
        index: i,
        text: cue.text,
      ));
      (events[cue.endTime.inMilliseconds] ??= []).add((
        lane: lane,
        index: i,
        text: null,
      ));
    }
  }
  final times = events.keys.toList()..sort();
  final active = [SplayTreeMap<int, String>(), SplayTreeMap<int, String>()];
  final merged = <({int start, int end, String text})>[];
  for (var i = 0; i + 1 < times.length; i++) {
    final time = times[i];
    for (final event in events[time]!) {
      if (event.text == null) {
        active[event.lane].remove(event.index);
      } else {
        active[event.lane][event.index] = event.text!;
      }
    }
    final text = {...active[0].values, ...active[1].values}.join('\n');
    if (text.isEmpty) continue;
    if (merged.isNotEmpty &&
        merged.last.end == time &&
        merged.last.text == text) {
      merged[merged.length - 1] = (
        start: merged.last.start,
        end: times[i + 1],
        text: text,
      );
    } else {
      merged.add((start: time, end: times[i + 1], text: text));
    }
  }
  final body = StringBuffer();
  for (var i = 0; i < merged.length; i++) {
    final cue = merged[i];
    body
      ..writeln(i + 1)
      ..writeln('${_srtTime(cue.start)} --> ${_srtTime(cue.end)}')
      ..writeln(cue.text)
      ..writeln();
  }
  return decodeQuarkSubtitleBody(body.toString());
}

String _srtTime(int millis) {
  final time = Duration(milliseconds: millis);
  return '${time.inHours.toString().padLeft(2, '0')}:'
      '${time.inMinutes.remainder(60).toString().padLeft(2, '0')}:'
      '${time.inSeconds.remainder(60).toString().padLeft(2, '0')},'
      '${time.inMilliseconds.remainder(1000).toString().padLeft(3, '0')}';
}
