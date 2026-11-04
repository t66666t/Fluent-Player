import 'package:video_player/video_player.dart';

import '../models/playback_control_session.dart';
import 'media_playback_service.dart';

/// Adapts the established native transport without changing its seeking,
/// subtitle, queue or decoder ownership. A page-bound adapter never controls a
/// different item that subsequently becomes current in the shared service.
class NativePlaybackControlSession extends PlaybackControlSession {
  NativePlaybackControlSession(
    this.service, {
    String? itemId,
    VideoPlayerController? expectedController,
  }) : _itemId = itemId ?? service.currentItem?.id,
       _expectedController = expectedController {
    service.addListener(_sync);
    service.positionNotifier.addListener(_sync);
    _sync();
  }
  final MediaPlaybackService service;
  final VideoPlayerController? _expectedController;
  String? _itemId;
  bool _disposed = false;
  PlaybackControlSnapshot _value = const PlaybackControlSnapshot();
  @override
  bool get isDisposed => _disposed;
  @override
  PlaybackControlSnapshot get value => _value;

  bool get _ownsCurrent =>
      _itemId != null &&
      service.currentItem?.id == _itemId &&
      (_expectedController == null ||
          identical(service.controller, _expectedController));

  /// A scoped bridge for existing playback-page callbacks. It preserves the
  /// original seek source tag and all native policies, without keeping a second
  /// owner/listener alive or adopting an independent preview controller.
  static Future<PlaybackCommandResult> seekOwned({
    required MediaPlaybackService service,
    required VideoPlayerController expectedController,
    required Duration position,
    String source = 'control_session',
  }) async {
    if (!identical(service.controller, expectedController) ||
        service.currentItem == null) {
      return const PlaybackCommandResult(PlaybackCommandStatus.notReady);
    }
    final adapter = NativePlaybackControlSession(
      service,
      itemId: service.currentItem!.id,
      expectedController: expectedController,
    );
    try {
      return await adapter.seekTo(position, source: source);
    } finally {
      adapter.dispose();
    }
  }

  void _sync() {
    if (_disposed) return;
    _itemId ??= service.currentItem?.id;
    final controller = service.controller;
    final ready = _ownsCurrent && controller?.value.isInitialized == true;
    final duration = !ready
        ? Duration.zero
        : service.duration > Duration.zero
        ? service.duration
        : controller!.value.duration;
    _value = PlaybackControlSnapshot(
      ready: ready,
      playing: ready && service.isPlaying,
      buffering:
          _ownsCurrent &&
          (service.state == PlaybackState.loading ||
              controller?.value.isBuffering == true),
      position: ready ? service.position : Duration.zero,
      duration: duration,
      rate: service.playbackSpeed,
      volume: service.volume,
      muted: service.isMuted,
      seekableRanges: duration > Duration.zero
          ? List.unmodifiable([PlaybackSeekableRange(Duration.zero, duration)])
          : const [],
      capabilities: PlaybackControlCapabilities(
        canPlay: ready,
        canPause: ready,
        canSeek: ready && duration > Duration.zero,
        canSetRate: ready,
        canSetVolume: ready,
        canMute: ready,
      ),
      mediaId: _itemId,
      error: _ownsCurrent ? controller?.value.errorDescription : null,
    );
    notifyListeners();
  }

  Future<PlaybackCommandResult> _run(
    bool supported,
    Future<void> Function() operation,
  ) async {
    if (_disposed) {
      return const PlaybackCommandResult(PlaybackCommandStatus.disposed);
    }
    if (!_ownsCurrent || !_value.ready) {
      return const PlaybackCommandResult(
        PlaybackCommandStatus.notReady,
        error: '当前播放器会话尚未就绪',
      );
    }
    if (!supported) {
      return const PlaybackCommandResult(PlaybackCommandStatus.unsupported);
    }
    try {
      await operation();
      if (_disposed) {
        return const PlaybackCommandResult(PlaybackCommandStatus.disposed);
      }
      if (!_ownsCurrent) {
        return const PlaybackCommandResult(PlaybackCommandStatus.superseded);
      }
      _sync();
      if (!_value.ready) {
        return const PlaybackCommandResult(PlaybackCommandStatus.notReady);
      }
      return PlaybackCommandResult.confirmed(position: _value.position);
    } catch (error) {
      if (!_disposed) {
        _value = _value.copyWith(error: '播放器未完成操作，请重试');
        notifyListeners();
      }
      return const PlaybackCommandResult(
        PlaybackCommandStatus.failed,
        error: '播放器未完成操作，请重试',
      );
    }
  }

  @override
  Future<PlaybackCommandResult> play() =>
      _run(_value.capabilities.canPlay, service.resume);
  @override
  Future<PlaybackCommandResult> pause() => _run(
    _value.capabilities.canPause,
    () => service.pause(expectedItemId: _itemId),
  );
  @override
  Future<PlaybackCommandResult> seekTo(
    Duration position, {
    String source = 'control_session',
  }) => _run(
    _value.capabilities.canSeek,
    () => service.seekTo(
      position < Duration.zero
          ? Duration.zero
          : position > _value.duration
          ? _value.duration
          : position,
      source: source,
    ),
  );
  @override
  Future<PlaybackCommandResult> setRate(double rate) {
    if (!rate.isFinite || rate <= 0) {
      return Future.value(
        const PlaybackCommandResult(
          PlaybackCommandStatus.failed,
          error: '倍速无效',
        ),
      );
    }
    return _run(
      _value.capabilities.canSetRate,
      () => service.setPlaybackSpeed(rate),
    );
  }

  @override
  Future<PlaybackCommandResult> setVolume(double volume) {
    if (!volume.isFinite) {
      return Future.value(
        const PlaybackCommandResult(
          PlaybackCommandStatus.failed,
          error: '音量无效',
        ),
      );
    }
    return _run(
      _value.capabilities.canSetVolume,
      () => service.setVolume(volume.clamp(0.0, 1.0)),
    );
  }

  @override
  Future<PlaybackCommandResult> setMuted(bool muted) =>
      _run(_value.capabilities.canMute, () async {
        if (service.isMuted != muted) await service.toggleMute();
      });

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    service.removeListener(_sync);
    service.positionNotifier.removeListener(_sync);
    super.dispose();
  }
}
