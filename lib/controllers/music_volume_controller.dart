import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:volume_controller/volume_controller.dart';

import '../services/media_playback_service.dart';

/// Uses the same volume domain as the video player's vertical gesture:
/// system media volume on Android/iOS, playback gain on desktop.
class MusicVolumeController extends ChangeNotifier {
  MusicVolumeController(this.playback, {bool? useSystemVolume})
    : usesSystemVolume =
          useSystemVolume ??
          (!kIsWeb &&
              (defaultTargetPlatform == TargetPlatform.android ||
                  defaultTargetPlatform == TargetPlatform.iOS)),
      _volume = playback.volume,
      _muted = playback.isMuted {
    playback.addListener(_onPlaybackChanged);
    if (usesSystemVolume) {
      unawaited(refresh());
    }
  }

  final MediaPlaybackService playback;
  final bool usesSystemVolume;
  StreamSubscription<double>? _subscription;
  double _volume;
  bool _muted;
  double? _pendingVolume;
  bool _writing = false;
  bool _dragging = false;
  bool _disposed = false;
  int _revision = 0;
  int _muteRevision = 0;

  double get volume => _volume;
  bool get isMuted => playback.isMuted;

  void _onPlaybackChanged() {
    final oldVolume = _volume;
    if (!usesSystemVolume && !_writing && !_dragging) {
      _volume = playback.volume;
    }
    final changed = oldVolume != _volume || _muted != playback.isMuted;
    _muted = playback.isMuted;
    if (!_disposed && changed) notifyListeners();
  }

  void _onSystemVolume(double value) {
    // Native volume is often quantized. Its echoes must not pull the thumb
    // backwards or snap it to hardware steps while the pointer is held.
    if (_disposed || _writing || _dragging) return;
    _volume = value.clamp(0.0, 1.0);
    notifyListeners();
  }

  Future<void> refresh() async {
    if (!usesSystemVolume) return;
    final revision = _revision;
    try {
      final value = await VolumeController.instance.getVolume();
      if (_disposed) return;
      if (_subscription == null) {
        _subscription = VolumeController.instance.addListener(
          _onSystemVolume,
          fetchInitialVolume: false,
        );
        _subscription!.onError((Object _) {});
      }
      if (revision == _revision) _onSystemVolume(value);
    } catch (_) {
      // Keep the last known value if a native volume read is unavailable.
    }
  }

  void beginDrag() => _dragging = true;
  void endDrag() => _dragging = false;

  void setVolume(double value) {
    if (_disposed) return;
    _revision++;
    _volume = value.clamp(0.0, 1.0);
    _pendingVolume = _volume;
    notifyListeners();
    if (!_writing) unawaited(_flushVolume());
  }

  Future<void> _flushVolume() async {
    _writing = true;
    try {
      // Keep at most one outstanding native write and one latest value.
      // A fast drag cannot build an obsolete queue of platform calls.
      while (_pendingVolume != null) {
        final value = _pendingVolume!;
        final muteRevision = _muteRevision;
        final wasMuted = playback.isMuted;
        _pendingVolume = null;
        try {
          if (usesSystemVolume) {
            VolumeController.instance.showSystemUI = false;
            await VolumeController.instance.setVolume(value);
          } else {
            await playback.setVolume(value);
          }
          if (value > 0 &&
              wasMuted &&
              playback.isMuted &&
              muteRevision == _muteRevision) {
            await playback.toggleMute();
          }
        } catch (_) {
          // The next drag or refresh can recover from a lost native session.
        }
      }
    } finally {
      _writing = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> toggleMute() async {
    _muteRevision++;
    await playback.toggleMute();
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription?.cancel();
    playback.removeListener(_onPlaybackChanged);
    super.dispose();
  }
}
