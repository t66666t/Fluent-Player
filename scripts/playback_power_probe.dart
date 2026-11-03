// Isolated native playback probe. Build only in a source snapshot with a
// separate Android applicationId; never distribute this target as the app.
// flutter build apk --release -t scripts/playback_power_probe.dart
// --dart-define=POWER_MEDIA=/absolute/path/to/a/video-with-audio.mp4
// Forward TCP 8768 with adb for Android. The localhost API drives the probe
// without touching the user's library, preferences, accounts or media queue.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:window_manager/window_manager.dart';

import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playback_state_store.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/progress_tracker.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/system_media_session_service.dart';
import 'package:video_player_app/widgets/ambient_letterbox_layer.dart';

const _media = String.fromEnvironment('POWER_MEDIA');
const _port = int.fromEnvironment('POWER_PORT', defaultValue: 8768);
final _service = MediaPlaybackService();
final _playlist = PlaylistManager();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  NativeVideoPlayerMediaKit.ensureInitialized();
  if (Platform.isWindows) await windowManager.ensureInitialized();
  final isolated = await Directory.systemTemp.createTemp('playback_power_');
  await _service.initialize(
    playlistManager: _playlist,
    progressTracker: ProgressTracker(
      playbackStateStore: PlaybackStateStore(
        directoryProvider: () async => isolated,
      ),
    ),
  );
  runApp(const MaterialApp(home: _Probe()));
}

class _Probe extends StatefulWidget {
  const _Probe();
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> with WidgetsBindingObserver {
  HttpServer? _server;
  bool _subscribed = false;
  bool _ambient = false;
  bool _visible = true;
  bool _ready = false;
  bool _openingNetworkVideo = false;
  String? _error;
  int _frames = 0, _captures = 0, _notifications = 0;
  int _captureMicros = 0, _captureBytes = 0, _captureCompleted = 0;
  int? _lastCaptureBytes;
  int? _captureMetadataPlayerId, _captureFrameWidth, _captureFrameHeight;
  int _buildMicros = 0, _rasterMicros = 0;
  final _clock = Stopwatch()..start();
  AppLifecycleState? _lifecycle;
  late final AppLifecycleState? _initialBindingLifecycle;

  @override
  void initState() {
    super.initState();
    _initialBindingLifecycle = WidgetsBinding.instance.lifecycleState;
    WidgetsBinding.instance.addObserver(this);
    SchedulerBinding.instance.addTimingsCallback(_timings);
    unawaited(_start());
  }

  void _timings(List<FrameTiming> values) {
    for (final value in values) {
      _frames++;
      _buildMicros += value.buildDuration.inMicroseconds;
      _rasterMicros += value.rasterDuration.inMicroseconds;
    }
  }

  void _position() => _notifications++;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    _service.handleAppLifecycleState(state);
  }

  Future<void> _start() async {
    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, _port);
      _server!.listen((request) => unawaited(_request(request)));
      await SystemMediaSessionService.instance.initialize(
        playbackService: _service,
        playlistManager: _playlist,
      );
      _service.setPlaybackPageVisible(this, true);
      final pump = Timer.periodic(const Duration(milliseconds: 16), (_) {
        WidgetsBinding.instance.scheduleFrame();
      });
      try {
        await _service
            .play(
              VideoItem(
                id: 'power-probe',
                path: _media,
                title: 'Isolated power probe',
                type: MediaType.video,
                durationMs: 0,
                lastUpdated: 0,
              ),
              autoPlay: true,
            )
            .timeout(const Duration(seconds: 40));
      } finally {
        pump.cancel();
      }
      await _service.setVolume(0);
      await _service.controller!.setLooping(true);
      _ready = true;
    } catch (error, stack) {
      _error = '$error\n$stack';
    }
    if (mounted) setState(() {});
  }

  Map<String, Object?> _status() => {
    'ready': _ready,
    'error': _error,
    'platform': Platform.operatingSystem,
    'release': const bool.fromEnvironment('dart.vm.product'),
    'elapsedMs': _clock.elapsedMilliseconds,
    'lifecycle': _lifecycle?.name,
    'initialBindingLifecycle': _initialBindingLifecycle?.name,
    'bindingLifecycle': WidgetsBinding.instance.lifecycleState?.name,
    'pausePlaybackWhenAppBackgrounded':
        SettingsService().pausePlaybackWhenAppBackgrounded,
    'subscribed': _subscribed,
    'ambient': _ambient,
    'visible': _visible,
    'frames': _frames,
    'captures': _captures,
    'captureCompleted': _captureCompleted,
    'captureMicros': _captureMicros,
    'captureBytes': _captureBytes,
    'lastCaptureBytes': _lastCaptureBytes,
    'captureFrameWidth': _captureFrameWidth,
    'captureFrameHeight': _captureFrameHeight,
    'positionNotifications': _notifications,
    'buildMicros': _buildMicros,
    'rasterMicros': _rasterMicros,
    'positionMs': _service.position.inMilliseconds,
    'presentedMs': _service.positionNotifier.value.inMilliseconds,
    'nativeMs': _service.controller?.value.position.inMilliseconds,
    'playerId': _service.controller?.playerId,
    'managedByMediaKit':
        _service.controller != null &&
        NativeVideoPlayerMediaKit.positionStreamFor(
              _service.controller!.playerId,
            ) !=
            null,
    'videoWidth': _service.controller?.value.size.width,
    'videoHeight': _service.controller?.value.size.height,
    'controllerInitialized': _service.controller?.value.isInitialized,
    'controllerError': _service.controller?.value.errorDescription,
    'playing': _service.isPlaying,
    'rate': _service.confirmedPlaybackSpeed,
    'buffering': _service.controller?.value.isBuffering,
    'rssBytes': ProcessInfo.currentRss,
    'scheduled': SchedulerBinding.instance.hasScheduledFrame,
  };

  Future<void> _openNetworkVideo() async {
    if (_openingNetworkVideo || !_ready || !mounted) {
      throw StateError('Probe is not ready to replace its video');
    }
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == AppLifecycleState.hidden ||
        lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.detached) {
      throw StateError('Open the network video while the probe is visible');
    }
    _openingNetworkVideo = true;
    final previous = _service.controller;
    VideoPlayerController? candidate;
    // This temporary pump serves initialization and the unmount of the old
    // texture. It is always removed before a measurement can begin.
    final pump = Timer.periodic(const Duration(milliseconds: 16), (_) {
      WidgetsBinding.instance.scheduleFrame();
    });
    try {
      await _service.pause();
      if (!mounted) throw StateError('Probe was disposed');
      setState(() {
        _ready = false;
        _error = null;
      });
      // Detach the old Flutter texture before releasing its native decoder.
      // Release completes before constructing another decoder on Android.
      await WidgetsBinding.instance.endOfFrame;
      _service.clearController();
      await previous?.dispose();
      if (!mounted) throw StateError('Probe was disposed');

      final uri = Uri.parse('http://127.0.0.1:$_port/fixture');
      candidate = VideoPlayerController.networkUrl(
        uri,
        videoPlayerOptions: MediaPlaybackService.buildVideoPlayerOptions(),
      );
      await candidate.initialize().timeout(const Duration(seconds: 30));
      await candidate.setVolume(0);
      await candidate.setLooping(true);
      await candidate.play();
      if (!mounted) throw StateError('Probe was disposed');
      await _service.setController(candidate);
      // Keep the same item identity captured by native-position listeners,
      // and align the service session with the newly transferred controller.
      await _service.updateMetadata(
        VideoItem(
          id: _service.currentItem?.id ?? 'power-probe',
          path: uri.toString(),
          title: 'Isolated network video probe',
          type: MediaType.video,
          durationMs: candidate.value.duration.inMilliseconds,
          lastUpdated: 0,
        ),
      );
      await _service.setVolume(0);
      if (!mounted) throw StateError('Probe was disposed');
      setState(() => _ready = true);
      await _service.resume();
    } catch (error, stack) {
      if (candidate != null) {
        if (identical(_service.controller, candidate)) {
          await _service.pause();
          _service.clearController();
        }
        await candidate.dispose();
      }
      _ready = false;
      _error = '$error\n$stack';
      rethrow;
    } finally {
      pump.cancel();
      _openingNetworkVideo = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _request(HttpRequest request) async {
    try {
      if (request.uri.path == '/fixture') {
        final file = File(_media);
        final length = await file.length();
        var start = 0, end = length - 1;
        final range = request.headers.value(HttpHeaders.rangeHeader);
        final match = RegExp(r'^bytes=(\d+)-(\d*)').firstMatch(range ?? '');
        if (match != null) {
          start = int.parse(match[1]!);
          if (match[2]!.isNotEmpty) {
            end = int.parse(match[2]!).clamp(start, length - 1);
          }
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            'Content-Range',
            'bytes $start-$end/$length',
          );
        }
        request.response.headers.set('Accept-Ranges', 'bytes');
        request.response.headers.contentType = ContentType('video', 'mp4');
        request.response.contentLength = end - start + 1;
        if (request.method != 'HEAD') {
          await request.response.addStream(file.openRead(start, end + 1));
        }
        await request.response.close();
        return;
      }
      if (_openingNetworkVideo && request.uri.path != '/status') {
        request.response.statusCode = HttpStatus.conflict;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({'error': 'Video replacement in progress'}),
        );
        return;
      }
      Map<String, Object?>? extra;
      switch (request.uri.path) {
        case '/control':
          final query = request.uri.queryParameters;
          final subscribed = query['subscribed'] == '1';
          if (subscribed != _subscribed) {
            _subscribed = subscribed;
            if (subscribed) {
              _service.positionNotifier.addListener(_position);
            } else {
              _service.positionNotifier.removeListener(_position);
            }
          }
          setState(() {
            _ambient = query['ambient'] == '1';
            _visible = query['visible'] != '0';
          });
        case '/pause':
          await _service.pause();
        case '/play':
          await _service.resume();
        case '/seek':
          await _service.seekTo(
            Duration(
              milliseconds: int.parse(request.uri.queryParameters['ms']!),
            ),
          );
        case '/rate':
          await _service.setPlaybackSpeed(
            double.parse(request.uri.queryParameters['value']!),
          );
        case '/background-policy':
          final pause = request.uri.queryParameters['pause'];
          if (pause != '0' && pause != '1') {
            throw const FormatException('pause must be 0 or 1');
          }
          SettingsService().pausePlaybackWhenAppBackgrounded = pause == '1';
        case '/network-video':
          await _openNetworkVideo();
        case '/ambient-diagnostics':
          if (_ambient && request.uri.queryParameters['software'] == '1') {
            throw StateError('Disable ambient capture before the software probe');
          }
          extra = await NativeVideoPlayerMediaKit.ambientThumbnailDiagnosticsFor(
            _service.controller!.playerId,
            captureRaw: request.uri.queryParameters['raw'] == '1',
            softwareCapture: request.uri.queryParameters['software'] == '1',
          );
        case '/transport-state':
          extra = {
            'backendTransport': await NativeVideoPlayerMediaKit.transportStateFor(
              _service.controller!.playerId,
            ),
          };
        case '/audio-check':
          final controller = VideoPlayerController.networkUrl(
            Uri.parse('http://127.0.0.1:$_port/fixture'),
            httpHeaders: {
              NativeVideoPlayerMediaKit.audioPrimaryStreamHeader: '1',
            },
          );
          // MediaKit initialization needs a frame even on an idle test surface.
          final pump = Timer.periodic(
            const Duration(milliseconds: 16),
            (_) => WidgetsBinding.instance.scheduleFrame(),
          );
          try {
            await controller.initialize().timeout(const Duration(seconds: 30));
            await controller.setVolume(0);
            await controller.play();
            await Future<void>.delayed(const Duration(seconds: 2));
            final output = NativeVideoPlayerMediaKit.firstFrameRenderedFor(
              controller.playerId,
            );
            extra = {
              'audioInitialized': controller.value.isInitialized,
              'audioPositionMs': controller.value.position.inMilliseconds,
              'audioHasVideoOutput': output != null,
            };
          } finally {
            pump.cancel();
            await controller.dispose();
          }
        case '/stop':
          await _service.stop();
        case '/status':
          break;
        default:
          request.response.statusCode = HttpStatus.notFound;
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({..._status(), ...?extra}));
    } catch (error, stack) {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write(
        jsonEncode({'error': '$error', 'stack': '$stack'}),
      );
    } finally {
      await request.response.close();
    }
  }

  Future<Uint8List?> _capture(int playerId) async {
    _captures++;
    final clock = Stopwatch()..start();
    try {
      final bytes = await NativeVideoPlayerMediaKit.ambientThumbnailFrameFor(
        playerId,
      );
      _captureCompleted++;
      _lastCaptureBytes = bytes?.length;
      _captureBytes += bytes?.length ?? 0;
      if (bytes != null &&
          bytes.isNotEmpty &&
          _captureMetadataPlayerId != playerId) {
        // Inspect one encoded frame per player for proof that the thumbnail
        // path was used. Do not add image decoding to the steady-state probe.
        final codec = await instantiateImageCodec(bytes);
        try {
          final frame = await codec.getNextFrame();
          _captureFrameWidth = frame.image.width;
          _captureFrameHeight = frame.image.height;
          frame.image.dispose();
          _captureMetadataPlayerId = playerId;
        } finally {
          codec.dispose();
        }
      }
      return bytes;
    } finally {
      _captureMicros += clock.elapsedMicroseconds;
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _service.controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: !_ready || controller == null
          ? Center(child: Text(_error ?? 'Preparing isolated playback probe'))
          : LayoutBuilder(
              builder: (_, constraints) => TickerMode(
                enabled: _visible,
                child: Stack(
                  children: [
                    AmbientLetterboxLayer(
                      enabled: _ambient,
                      mediaId: 'power-probe',
                      playerId: controller.playerId,
                      controller: controller,
                      scrubbing: false,
                      transforming: false,
                      seekHold: false,
                      columnSize: constraints.biggest,
                      containedVideoSize: Size(
                        constraints.maxWidth,
                        constraints.maxWidth / controller.value.aspectRatio,
                      ),
                      userScale: 1,
                      userRotation: 0,
                      userOffset: Offset.zero,
                      captureFrame: _capture,
                    ),
                    if (_visible)
                      Center(
                        child: AspectRatio(
                          aspectRatio: controller.value.aspectRatio,
                          child: VideoPlayer(controller),
                        ),
                      ),
                  ],
                ),
              ),
            ),
    );
  }

  @override
  void dispose() {
    _service.positionNotifier.removeListener(_position);
    _service.setPlaybackPageVisible(this, false);
    SchedulerBinding.instance.removeTimingsCallback(_timings);
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_server?.close(force: true));
    super.dispose();
  }
}
