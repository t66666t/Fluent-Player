import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:media_kit/media_kit.dart';

/// Repairs the samples discarded by older audio outputs when they stop their
/// device queue. The device really pauses; no silent output, timer or decoder
/// work is kept alive for the duration of the pause.
///
/// Capture the audible position at the native pause boundary, then reconstruct
/// the discarded tail through an exact, normally cached seek immediately
/// before resuming. Pausing itself does not seek or restart decoding. Explicit
/// seeks invalidate this work before entering the queue.
class NativeAudioPauseRepair {
  NativeAudioPauseRepair({
    required Future<Duration?> Function() pauseAndCapture,
    required Future<void> Function() play,
    required Future<void> Function(Duration) restore,
    required bool Function() canRestore,
    required bool Function() isCurrent,
  }) : _pauseAndCapture = pauseAndCapture,
       _play = play,
       _restore = restore,
       _canRestore = canRestore,
       _isCurrent = isCurrent;

  factory NativeAudioPauseRepair.forPlayer(
    Player player, {
    required bool Function() isCurrent,
  }) {
    final native = player.platform;
    if (native is! NativePlayer) {
      throw StateError('Native pause repair requires NativePlayer');
    }
    final boundary = _NativePauseBoundary(player, native);
    return NativeAudioPauseRepair(
      pauseAndCapture: boundary.pauseAndCapture,
      play: player.play,
      restore: boundary.restore,
      canRestore: boundary.canRestore,
      isCurrent: isCurrent,
    );
  }

  final Future<Duration?> Function() _pauseAndCapture;
  final Future<void> Function() _play;
  final Future<void> Function(Duration) _restore;
  final bool Function() _canRestore;
  final bool Function() _isCurrent;
  Future<void> _tail = Future<void>.value();
  int _pendingCommands = 0;
  int _positionRevision = 0;
  bool _disposed = false;
  Duration? _unrestoredPosition;
  Duration? _lastPausePosition;

  /// The native audible boundary, useful for verifying continuity independently
  /// of wall time spent warming an audio device after resume.
  Duration? get lastPausePosition => _lastPausePosition;

  /// The audible pause boundary. Legacy outputs report the discarded queue
  /// advancing after pause, even though the device has already stopped.
  Duration? get pausedPosition => _unrestoredPosition;

  bool get _current => !_disposed && _isCurrent();

  Future<void> _enqueue(Future<void> Function() operation) {
    final gate = Completer<void>();
    final previous = _tail;
    final idle = _pendingCommands++ == 0;
    // Publish before invoking anything that can synchronously notify listeners.
    _tail = gate.future;
    Future<void> run() async {
      try {
        if (_current) await operation();
      } finally {
        _pendingCommands--;
        gate.complete();
      }
    }

    return idle ? run() : previous.then((_) => run());
  }

  Future<void> pause() => _enqueue(() async {
    final revision = _positionRevision;
    final position = await _pauseAndCapture();
    if (!_current || revision != _positionRevision || position == null) return;
    if (!_canRestore()) return;
    _lastPausePosition = position;
    _unrestoredPosition = position;
  });

  Future<void> _restorePending() async {
    final position = _unrestoredPosition;
    if (position == null || !_current) return;
    final revision = _positionRevision;
    if (!_canRestore()) {
      _unrestoredPosition = null;
      return;
    }
    if (!_current ||
        revision != _positionRevision ||
        _unrestoredPosition != position) {
      return;
    }
    await _restore(position);
    if (revision == _positionRevision) _unrestoredPosition = null;
  }

  Future<void> play() => _enqueue(() async {
    // If a native recovery failed, retry before playing rather than silently
    // starting after the discarded audio. A newer seek clears this target.
    await _restorePending();
    if (_current) await _play();
  });

  Future<void> seek(Future<void> Function() operation) {
    invalidatePosition();
    return _enqueue(operation);
  }

  /// Also called before native seeks used by video-output/track recovery.
  void invalidatePosition() {
    _positionRevision++;
    _unrestoredPosition = null;
    _lastPausePosition = null;
  }

  Future<void> dispose() {
    _disposed = true;
    invalidatePosition();
    return _tail;
  }

  /// Older versions of these outputs can reset their device queue on pause.
  /// PulseAudio, null and file-writing outputs keep their
  /// original transport behavior.
  static bool needsRepair(String output) => const {
    'opensles',
    'audiotrack',
    'wasapi',
    'coreaudio',
    'audiounit',
    'alsa',
    'pipewire',
  }.contains(output);
}

class _NativePauseBoundary {
  _NativePauseBoundary(this.player, this.native);

  final Player player;
  final NativePlayer native;
  static const _bookmark = 'user-data/fluent-player-pause-audio-pts';

  String _read(String property) {
    if (native.disposed || native.ctx == nullptr) return '';
    final name = property.toNativeUtf8();
    try {
      final value = native.mpv.mpv_get_property_string(native.ctx, name.cast());
      if (value == nullptr) return '';
      try {
        return value.cast<Utf8>().toDartString();
      } finally {
        native.mpv.mpv_free(value.cast());
      }
    } finally {
      calloc.free(name);
    }
  }

  void _command(String command) {
    final encoded = command.toNativeUtf8();
    try {
      final result = native.mpv.mpv_command_string(native.ctx, encoded.cast());
      if (result < 0) {
        throw StateError('Native audio pause command failed ($result)');
      }
    } finally {
      calloc.free(encoded);
    }
  }

  bool canRestore() =>
      !native.disposed &&
      _read('pause') == 'yes' &&
      _read('seeking') != 'yes' &&
      _read('eof-reached') != 'yes';

  bool _canSeekBack(double position) {
    if (_read('seekable') == 'yes') return true;
    // A live/nonseekable transport may still have a native rewind window.
    // mpv restricts such a seek to its cache; never force network seekability.
    try {
      final cache = jsonDecode(_read('demuxer-cache-state'));
      final ranges = cache is Map ? cache['seekable-ranges'] : null;
      if (ranges is! List) return false;
      return ranges.any((range) {
        if (range is! Map) return false;
        final start = range['start'];
        final end = range['end'];
        return start is num &&
            end is num &&
            start <= position &&
            position <= end;
      });
    } on FormatException {
      return false;
    }
  }

  Future<Duration?> pauseAndCapture() async {
    Duration? target;
    try {
      final position = double.tryParse(_read('audio-pts'));
      if (position != null &&
          position.isFinite &&
          NativeAudioPauseRepair.needsRepair(_read('current-ao')) &&
          _read('pause') == 'no' &&
          _read('seeking') == 'no' &&
          _read('paused-for-cache') == 'no' &&
          _read('eof-reached') != 'yes' &&
          _canSeekBack(position < 0 ? 0 : position)) {
        double? captured;
        if (_read('user-data').isNotEmpty) {
          // These two commands execute together on mpv's core. Capturing
          // before the pause clears the queue avoids the later ghost time
          // reported as that discarded device delay counts down.
          _command(
            r'no-osd set user-data/fluent-player-pause-audio-pts ${=audio-pts}; '
            r'no-osd set pause yes',
          );
          final raw = _read(_bookmark);
          final decoded = raw.isEmpty ? null : jsonDecode(raw);
          captured = double.tryParse(decoded.toString());
        } else {
          // Older libmpv builds have no user-data property. Keep capture and
          // the native pause in this synchronous turn, before UI listeners.
          captured = double.tryParse(_read('audio-pts'));
          await native.setProperty(
            'pause',
            'yes',
            waitForInitialization: false,
          );
        }
        if (captured != null && captured.isFinite) {
          target = Duration(
            microseconds: (captured < 0 ? 0 : captured * 1000000).round(),
          );
        }
      }
    } finally {
      // Keep media_kit's state/streams in sync even when metadata is missing
      // or snapshotting fails. The real device pause has already gone out.
      await player.pause();
    }
    return target;
  }

  Future<void> restore(Duration position) async {
    _command(
      'no-osd seek ${(position.inMicroseconds / 1000000).toStringAsFixed(6)} '
      'absolute+exact',
    );
  }
}
