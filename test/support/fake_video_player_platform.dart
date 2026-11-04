import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// An in-memory native-player substitute for timing and transport UI tests.
/// It never opens a URL or reads media, regardless of the supplied data source.
class FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  FakeVideoPlayerPlatform({this.duration = const Duration(minutes: 2)});

  final Duration duration;
  final _events = <int, StreamController<VideoEvent>>{};
  final _positions = <int, Duration>{};
  final playing = <int, bool>{};
  int _nextId = 0;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = ++_nextId;
    final events = StreamController<VideoEvent>();
    _events[id] = events;
    _positions[id] = Duration.zero;
    playing[id] = false;
    scheduleMicrotask(() {
      if (!events.isClosed) {
        events.add(
          VideoEvent(
            eventType: VideoEventType.initialized,
            duration: duration,
            size: const Size(1280, 720),
          ),
        );
      }
    });
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  @override
  Future<void> play(int playerId) async {
    if (_events.containsKey(playerId)) playing[playerId] = true;
  }

  @override
  Future<void> pause(int playerId) async {
    if (_events.containsKey(playerId)) playing[playerId] = false;
  }

  @override
  Future<Duration> getPosition(int playerId) async =>
      _positions[playerId] ?? Duration.zero;

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    _positions[playerId] = position;
  }

  @override
  Future<void> dispose(int playerId) async {
    await _events.remove(playerId)?.close();
    _positions.remove(playerId);
    playing.remove(playerId);
  }

  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
  @override
  Future<void> setAllowBackgroundPlayback(bool allowBackgroundPlayback) async {}
}
