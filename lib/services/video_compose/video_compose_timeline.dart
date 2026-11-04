import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import '../../models/subtitle_model.dart';

class ComposeSceneEntry {
  final int? index;
  final String text;
  final String? secondaryText;
  final Future<Uint8List?> Function()? imageLoader;
  final int? imageIdentity;
  const ComposeSceneEntry({
    required this.index,
    required this.text,
    required this.secondaryText,
    required this.imageLoader,
    this.imageIdentity,
  });
}

class ComposeSceneSegment {
  final int startMs;
  final int endMs;
  final List<ComposeSceneEntry> entries;
  final String signature;
  ComposeSceneSegment(this.startMs, this.endMs, this.entries)
    : signature = jsonEncode([
        for (final entry in entries)
          [entry.text, entry.secondaryText, entry.imageIdentity],
      ]);
}

/// Sweep cue boundaries once instead of scanning every cue for every scene.
/// Active entries retain input order, including overlapping/unsorted tracks.
List<ComposeSceneSegment> buildComposeTimeline({
  required Duration duration,
  required List<SubtitleItem> primary,
  required List<SubtitleItem> secondary,
  required bool splitSubtitleByLine,
}) {
  var endMs = duration.inMilliseconds;
  if (endMs <= 0) {
    for (final item in [...primary, ...secondary]) {
      if (item.endTime.inMilliseconds > endMs) {
        endMs = item.endTime.inMilliseconds;
      }
    }
  }
  if (endMs <= 0) return [];
  final events =
      SplayTreeMap<int, List<({int id, bool secondary, bool start})>>();
  events[0] = [];
  events[endMs] = [];
  for (final track in [(primary, false), (secondary, true)]) {
    for (var id = 0; id < track.$1.length; id++) {
      final item = track.$1[id];
      final start = item.startTime.inMilliseconds.clamp(0, endMs);
      final end = item.endTime.inMilliseconds.clamp(0, endMs);
      if (end <= start) continue;
      events.putIfAbsent(start, () => []).add((
        id: id,
        secondary: track.$2,
        start: true,
      ));
      events.putIfAbsent(end, () => []).add((
        id: id,
        secondary: track.$2,
        start: false,
      ));
    }
  }
  final activePrimary = SplayTreeMap<int, SubtitleItem>();
  final activeSecondary = SplayTreeMap<int, SubtitleItem>();
  final result = <ComposeSceneSegment>[];
  final times = events.keys.toList();
  for (var i = 0; i < times.length - 1; i++) {
    final start = times[i], end = times[i + 1];
    for (final event in events[start]!) {
      final active = event.secondary ? activeSecondary : activePrimary;
      if (event.start) {
        active[event.id] = (event.secondary ? secondary : primary)[event.id];
      } else {
        active.remove(event.id);
      }
    }
    final entries = <ComposeSceneEntry>[];
    if (activePrimary.isNotEmpty) {
      for (final entry in activePrimary.entries) {
        final item = entry.value;
        var text = item.imageLoader == null ? item.text : '';
        String? secondaryText;
        if (item.imageLoader == null) {
          SubtitleItem? closest;
          var distance = 0;
          for (final candidate in activeSecondary.values) {
            final next = (candidate.startTime - item.startTime).inMicroseconds
                .abs();
            if (closest == null || next < distance) {
              closest = candidate;
              distance = next;
            }
          }
          if (closest != null) {
            secondaryText = closest.text;
          } else if (splitSubtitleByLine && text.contains('\n')) {
            final lines = text.split('\n');
            text = lines.first;
            secondaryText = lines.skip(1).join('\n');
          }
        }
        entries.add(
          ComposeSceneEntry(
            index: item.index,
            text: text,
            secondaryText: secondaryText,
            imageLoader: item.imageLoader,
            imageIdentity: item.imageLoader == null ? null : entry.key,
          ),
        );
      }
    } else {
      for (final entry in activeSecondary.entries) {
        final item = entry.value;
        entries.add(
          ComposeSceneEntry(
            index: item.index,
            text: '',
            secondaryText: item.text,
            imageLoader: item.imageLoader,
            imageIdentity: item.imageLoader == null
                ? null
                : primary.length + entry.key,
          ),
        );
      }
    }
    final segment = ComposeSceneSegment(start, end, entries);
    if (result.isNotEmpty && result.last.signature == segment.signature) {
      final previous = result.removeLast();
      result.add(ComposeSceneSegment(previous.startMs, end, previous.entries));
    } else {
      result.add(segment);
    }
  }
  return result;
}
