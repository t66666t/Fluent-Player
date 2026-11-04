import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../debug/developer_log.dart' as developer;
import '../media_playback_service.dart';
import 'bilibili_startup.dart';

/// Millisecond marks from tapping a Bilibili video to it playing, for
/// finding where the wait goes. Only written to the log in debug builds;
/// tests read [marks]. Holds the BV id and step names only, never request
/// headers or cookies.
class BilibiliOpenTimeline {
  BilibiliOpenTimeline(this.bvid, {Stopwatch? stopwatch})
    : _stopwatch = (stopwatch ?? Stopwatch())..start();

  final String bvid;
  final Stopwatch _stopwatch;
  late final BilibiliStartupContext startup = BilibiliStartupContext(
    elapsed: () => _stopwatch.elapsed,
    onMark: mark,
  );
  final List<({String step, int ms})> _marks = <({String step, int ms})>[];

  /// Timelines of videos that have opened, by card id, so steps that finish
  /// later (the card's extra data) can still be marked.
  static final Map<String, BilibiliOpenTimeline> _byItem =
      <String, BilibiliOpenTimeline>{};

  List<({String step, int ms})> get marks =>
      List<({String step, int ms})>.unmodifiable(_marks);

  int get elapsedMs => _stopwatch.elapsedMilliseconds;

  /// Milliseconds of the first mark named [step], or null.
  int? msOf(String step) {
    for (final mark in _marks) {
      if (mark.step == step) return mark.ms;
    }
    return null;
  }

  void mark(String step) {
    final ms = _stopwatch.elapsedMilliseconds;
    _marks.add((step: step, ms: ms));
    if (kDebugMode) {
      developer.log('$bvid +${ms}ms $step', name: 'BilibiliOpen');
    }
  }

  /// One line per mark, for the debug log.
  String summary() =>
      [for (final mark in _marks) '+${mark.ms}ms ${mark.step}'].join(' | ');

  /// Keeps this timeline reachable by [itemId] for [keep].
  void attachTo(String itemId, {Duration keep = const Duration(minutes: 1)}) {
    _byItem[itemId] = this;
    Timer(keep, () {
      if (identical(_byItem[itemId], this)) _byItem.remove(itemId);
    });
  }

  static BilibiliOpenTimeline? ofItem(String itemId) => _byItem[itemId];

  /// Marks `playing` once [playback] plays [itemId] (or `paused` when the
  /// page opens paused), giving up after [limit].
  void followPlayback(
    MediaPlaybackService playback,
    String itemId, {
    Duration limit = const Duration(seconds: 30),
  }) {
    Timer? timer;
    void listener() {
      if (playback.currentItem?.id != itemId) return;
      final state = playback.state;
      if (state != PlaybackState.playing && state != PlaybackState.paused) {
        return;
      }
      if (playback.state == PlaybackState.paused &&
          playback.controller == null) {
        return;
      }
      playback.removeListener(listener);
      timer?.cancel();
      mark(state == PlaybackState.playing ? 'playing' : 'paused');
      if (kDebugMode) {
        developer.log('$bvid ${summary()}', name: 'BilibiliOpen');
      }
    }

    playback.addListener(listener);
    timer = Timer(limit, () => playback.removeListener(listener));
    listener();
  }
}
