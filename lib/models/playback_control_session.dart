import 'package:flutter/foundation.dart';

@immutable
class PlaybackSeekableRange {
  const PlaybackSeekableRange(this.start, this.end);
  final Duration start;
  final Duration end;
  bool contains(Duration position) => position >= start && position <= end;
}

@immutable
class PlaybackControlCapabilities {
  const PlaybackControlCapabilities({
    this.canPlay = false,
    this.canPause = false,
    this.canSeek = false,
    this.canSetRate = false,
    this.canSetVolume = false,
    this.canMute = false,
    this.canSelectMedia = false,
  });
  final bool canPlay, canPause, canSeek, canSetRate, canSetVolume, canMute;
  final bool canSelectMedia;
}

@immutable
class PlaybackMediaCandidate {
  const PlaybackMediaCandidate({
    required this.id,
    required this.label,
    this.selected = false,
  });
  final String id;
  final String label;
  final bool selected;
}

@immutable
class PlaybackControlSnapshot {
  const PlaybackControlSnapshot({
    this.ready = false,
    this.playing = false,
    this.buffering = false,
    this.seeking = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.rate = 1,
    this.volume = 1,
    this.muted = false,
    this.seekableRanges = const [],
    this.capabilities = const PlaybackControlCapabilities(),
    this.mediaCandidates = const [],
    this.mediaId,
    this.error,
    this.pendingSeek,
  });
  final bool ready, playing, buffering, seeking, muted;
  final Duration position, duration;
  final double rate, volume;
  final List<PlaybackSeekableRange> seekableRanges;
  final PlaybackControlCapabilities capabilities;
  final List<PlaybackMediaCandidate> mediaCandidates;
  final String? mediaId;
  final String? error;

  /// A requested target for pending UI only; [position] remains a player readback.
  final Duration? pendingSeek;

  PlaybackControlSnapshot copyWith({
    bool? ready,
    bool? playing,
    bool? buffering,
    bool? seeking,
    Duration? position,
    Duration? duration,
    double? rate,
    double? volume,
    bool? muted,
    List<PlaybackSeekableRange>? seekableRanges,
    PlaybackControlCapabilities? capabilities,
    List<PlaybackMediaCandidate>? mediaCandidates,
    String? mediaId,
    String? error,
    bool clearError = false,
    Duration? pendingSeek,
    bool clearPendingSeek = false,
  }) => PlaybackControlSnapshot(
    ready: ready ?? this.ready,
    playing: playing ?? this.playing,
    buffering: buffering ?? this.buffering,
    seeking: seeking ?? this.seeking,
    position: position ?? this.position,
    duration: duration ?? this.duration,
    rate: rate ?? this.rate,
    volume: volume ?? this.volume,
    muted: muted ?? this.muted,
    seekableRanges: seekableRanges ?? this.seekableRanges,
    capabilities: capabilities ?? this.capabilities,
    mediaCandidates: mediaCandidates ?? this.mediaCandidates,
    mediaId: mediaId ?? this.mediaId,
    error: clearError ? null : error ?? this.error,
    pendingSeek: clearPendingSeek ? null : pendingSeek ?? this.pendingSeek,
  );
}

enum PlaybackCommandStatus {
  confirmed,
  unsupported,
  notReady,
  superseded,
  timedOut,
  failed,
  disposed,
}

@immutable
class PlaybackCommandResult {
  const PlaybackCommandResult(this.status, {this.error, this.position});
  const PlaybackCommandResult.confirmed({this.position})
    : status = PlaybackCommandStatus.confirmed,
      error = null;
  final PlaybackCommandStatus status;
  final String? error;
  final Duration? position;
  bool get succeeded => status == PlaybackCommandStatus.confirmed;
  bool get isSuccess => succeeded;
}

/// The control seam shared by native, official API and standard webpage players.
/// Implementations own their session; commands must never fall back to a global
/// native player when the current source is a WebView.
abstract class PlaybackControlSession extends ChangeNotifier
    implements ValueListenable<PlaybackControlSnapshot> {
  PlaybackControlSnapshot get snapshot => value;
  bool get isDisposed;
  Future<PlaybackCommandResult> play();
  Future<PlaybackCommandResult> pause();
  Future<PlaybackCommandResult> seekTo(Duration position);
  Future<PlaybackCommandResult> seekBy(Duration delta) =>
      seekTo((value.pendingSeek ?? value.position) + delta);
  Future<PlaybackCommandResult> setRate(double rate);
  Future<PlaybackCommandResult> setVolume(double volume);
  Future<PlaybackCommandResult> setMuted(bool muted);
  Future<PlaybackCommandResult> selectMedia(String mediaId) async =>
      const PlaybackCommandResult(PlaybackCommandStatus.unsupported);
  Future<PlaybackCommandResult> suspend() => pause();
  Future<PlaybackCommandResult> togglePlay() =>
      value.playing ? pause() : play();
  Future<PlaybackCommandResult> toggleMute() => setMuted(!value.muted);
}
