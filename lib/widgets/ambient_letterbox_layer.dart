import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../platform/windows_video_player_media_kit.dart';
import 'ambient_letterbox_policy.dart';

/// Soft color field behind the sharp landscape video.
///
/// Painted in the player column only. Zoom, pan, rotation, and mirror stay on
/// the video widget above this layer, so the matte never becomes a second
/// moving picture.
class AmbientLetterboxLayer extends StatefulWidget {
  const AmbientLetterboxLayer({
    super.key,
    required this.enabled,
    required this.mediaId,
    required this.playerId,
    required this.controller,
    required this.scrubbing,
    required this.transforming,
    required this.seekHold,
    required this.columnSize,
    required this.containedVideoSize,
    required this.userScale,
    required this.userRotation,
    required this.userOffset,
    this.captureFrame = NativeVideoPlayerMediaKit.ambientThumbnailFrameFor,
  });

  final bool enabled;
  final String? mediaId;
  final int? playerId;
  final VideoPlayerController? controller;
  final bool scrubbing;
  final bool transforming;
  final bool seekHold;
  final Size columnSize;
  final Size containedVideoSize;
  final double userScale;
  final double userRotation;
  final Offset userOffset;

  @visibleForTesting
  final Future<Uint8List?> Function(int playerId) captureFrame;

  @override
  State<AmbientLetterboxLayer> createState() => _AmbientLetterboxLayerState();
}

class _AmbientLetterboxLayerState extends State<AmbientLetterboxLayer>
    with WidgetsBindingObserver {
  Timer? _timer;
  Timer? _pausedFrameTimer;
  VideoPlayerController? _controller;
  ui.Image? _image;
  String? _imageMediaId;
  bool _buffering = false;
  bool _playing = false;
  bool _initialized = false;
  Duration? _position;
  bool _routeVisible = false;
  late bool _appVisible;
  bool _captureInFlight = false;
  bool _samplePending = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _appVisible = _isVisibleLifecycle(WidgetsBinding.instance.lifecycleState);
    WidgetsBinding.instance.addObserver(this);
    _bindController(widget.controller);
  }

  static bool _isVisibleLifecycle(AppLifecycleState? state) =>
      state != AppLifecycleState.hidden &&
      state != AppLifecycleState.paused &&
      state != AppLifecycleState.detached;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    final becameVisible = visible && !_routeVisible;
    _routeVisible = visible;
    _syncClock(sampleNow: becameVisible);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final visible = _isVisibleLifecycle(state);
    if (_appVisible == visible) return;
    _appVisible = visible;
    _syncClock(sampleNow: visible);
  }

  @override
  void didUpdateWidget(AmbientLetterboxLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final controllerChanged = oldWidget.controller != widget.controller;
    if (controllerChanged) {
      _bindController(widget.controller);
    }
    final playerChanged =
        controllerChanged || oldWidget.playerId != widget.playerId;
    if (playerChanged) _generation++;
    final mediaChanged = oldWidget.mediaId != widget.mediaId;
    if (mediaChanged) {
      _dropImage();
    }
    // Column resize is layout only. The policy refuses a new frame for it;
    // the image already on screen is refit by BoxFit.cover.
    final sampleForLayout = AmbientLetterboxPolicy.requestsFrameForColumnResize(
      oldWidget.columnSize,
      widget.columnSize,
    );
    final turnedOn = !oldWidget.enabled && widget.enabled;
    final holdReleased =
        (oldWidget.scrubbing && !widget.scrubbing) ||
        (oldWidget.transforming && !widget.transforming) ||
        (oldWidget.seekHold && !widget.seekHold);
    final gapRevealed = !_hasVisibleGap(oldWidget) && _visibleGap;
    _syncClock(
      sampleNow:
          mediaChanged ||
          playerChanged ||
          turnedOn ||
          sampleForLayout ||
          holdReleased ||
          gapRevealed,
    );
  }

  @override
  void dispose() {
    _generation++;
    _samplePending = false;
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _pausedFrameTimer?.cancel();
    _controller?.removeListener(_onController);
    _image?.dispose();
    super.dispose();
  }

  void _bindController(VideoPlayerController? next) {
    if (identical(_controller, next)) return;
    _controller?.removeListener(_onController);
    _controller = next;
    _buffering = next?.value.isBuffering ?? false;
    _playing = next?.value.isPlaying ?? false;
    _initialized = next?.value.isInitialized ?? false;
    _position = next?.value.position;
    next?.addListener(_onController);
  }

  void _onController() {
    final buffering = _controller?.value.isBuffering ?? false;
    final playing = _controller?.value.isPlaying ?? false;
    final initialized = _controller?.value.isInitialized ?? false;
    final position = _controller?.value.position;
    final bufferingChanged = buffering != _buffering;
    final playingChanged = playing != _playing;
    final initializedChanged = initialized != _initialized;
    final pausedSeek = !playing && position != _position;
    _position = position;
    if (!mounted ||
        (!bufferingChanged &&
            !playingChanged &&
            !initializedChanged &&
            !pausedSeek)) {
      return;
    }
    _buffering = buffering;
    _playing = playing;
    _initialized = initialized;
    // A paused frame stays useful. Refresh it for seek/transport changes,
    // without continuously capturing and blurring the same frame each second.
    _syncClock(sampleNow: playingChanged || pausedSeek || !buffering);
  }

  void _dropImage() {
    _generation++;
    final previous = _image;
    _image = null;
    _imageMediaId = null;
    previous?.dispose();
  }

  void _syncClock({required bool sampleNow}) {
    final canSample =
        widget.enabled &&
        _playablePlayerId != null &&
        _appVisible &&
        _routeVisible &&
        _visibleGap;
    if (!canSample) {
      // Discard a capture already awaiting native readback or image decoding.
      _generation++;
      _timer?.cancel();
      _timer = null;
      _pausedFrameTimer?.cancel();
      _pausedFrameTimer = null;
      if (!widget.enabled && _image != null) _dropImage();
      return;
    }
    if (_playing) {
      _pausedFrameTimer?.cancel();
      _pausedFrameTimer = null;
      _timer ??= Timer.periodic(
        AmbientLetterboxPolicy.sampleInterval,
        (_) => unawaited(_sample()),
      );
    } else {
      _timer?.cancel();
      _timer = null;
      if (sampleNow) {
        _pausedFrameTimer?.cancel();
        // Seek notifications and initialization can precede presentation of
        // the decoded frame. Keep one sample on the original one-second
        // cadence so a paused seek cannot leave the old matte indefinitely.
        _pausedFrameTimer = Timer(
          AmbientLetterboxPolicy.sampleInterval,
          () => unawaited(_sample(requestAfterCapture: true)),
        );
      }
    }
    if (sampleNow) unawaited(_sample(requestAfterCapture: true));
  }

  int? get _playablePlayerId {
    final playerId = widget.playerId;
    if (playerId == null || playerId < 0) return null;
    return playerId;
  }

  bool get _visibleGap => _hasVisibleGap(widget);

  static bool _hasVisibleGap(AmbientLetterboxLayer layer) =>
      AmbientLetterboxPolicy.hasVisibleGap(
        columnSize: layer.columnSize,
        containedVideoSize: layer.containedVideoSize,
        userScale: layer.userScale,
        userRotation: layer.userRotation,
        userOffset: layer.userOffset,
      );

  Future<void> _sample({bool requestAfterCapture = false}) async {
    if (!mounted || !_appVisible || !_routeVisible) return;
    final playerId = _playablePlayerId;
    final mediaId = widget.mediaId;
    if (!AmbientLetterboxPolicy.shouldSample(
      enabled: widget.enabled,
      hasPlayableVideo: playerId != null,
      visibleGap: _visibleGap,
      seeking: widget.scrubbing || widget.seekHold,
      buffering: _buffering,
      transforming: widget.transforming,
      captureInFlight: false,
    )) {
      return;
    }
    if (_captureInFlight) {
      _samplePending |= requestAfterCapture;
      return;
    }
    final generation = _generation;
    _captureInFlight = true;
    try {
      final jpeg = await widget.captureFrame(playerId!);
      if (!mounted ||
          generation != _generation ||
          jpeg == null ||
          jpeg.isEmpty) {
        return;
      }
      final image = await _blurredImage(jpeg);
      if (!mounted || generation != _generation || image == null) {
        image?.dispose();
        return;
      }
      final previous = _image;
      setState(() {
        _image = image;
        _imageMediaId = mediaId;
      });
      previous?.dispose();
    } catch (_) {
      // A failed grab leaves the previous matte, or black if there is none.
    } finally {
      _captureInFlight = false;
      if (_samplePending) {
        _samplePending = false;
        unawaited(_sample());
      }
    }
  }

  Future<ui.Image?> _blurredImage(Uint8List jpeg) async {
    final codec = await ui.instantiateImageCodec(
      jpeg,
      targetWidth: AmbientLetterboxPolicy.targetWidth,
    );
    try {
      final frame = await codec.getNextFrame();
      final source = frame.image;
      final bytes = await source.toByteData(format: ui.ImageByteFormat.rawRgba);
      final width = source.width;
      final height = source.height;
      source.dispose();
      if (bytes == null) return null;
      final blurred = blurAmbientRgba(
        pixels: bytes.buffer.asUint8List(
          bytes.offsetInBytes,
          bytes.lengthInBytes,
        ),
        width: width,
        height: height,
      );
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        blurred,
        width,
        height,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      return completer.future;
    } finally {
      codec.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final current = image != null && _imageMediaId == widget.mediaId;
    if (!widget.enabled || !current) return const SizedBox.shrink();
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          FittedBox(
            fit: BoxFit.cover,
            child: RawImage(image: image, filterQuality: FilterQuality.low),
          ),
          const ColoredBox(color: AmbientLetterboxPolicy.scrim),
        ],
      ),
    );
  }
}
