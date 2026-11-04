// Isolated Windows AOT diagnostic, never the production entry point.
// POWER_AUDIT_MEDIA must name a local fixture. Preferences and progress are
// isolated; no media library, accounts, downloads or models are initialized.
// The buffering gate is deliberately injected into VideoPlayerController's
// Dart view while real libmpv playback continues. This diagnoses presentation
// scheduling, not actual network buffering or battery energy consumption.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:window_manager/window_manager.dart';
import 'package:video_player_app/models/danmaku_style.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playback_state_store.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/progress_tracker.dart';
import 'package:video_player_app/widgets/danmaku_overlay.dart';

const _media = String.fromEnvironment('POWER_AUDIT_MEDIA');
const _port = int.fromEnvironment('POWER_AUDIT_PORT', defaultValue: 8779);
final _service = MediaPlaybackService();
late final String _commentsPath;

class _CountingPosition implements ValueListenable<Duration> {
  _CountingPosition(this.source);
  final ValueListenable<Duration> source;
  final List<VoidCallback> _listeners = [];
  int reads = 0;
  int get listeners => _listeners.length;
  @override
  Duration get value {
    reads++;
    return source.value;
  }

  @override
  void addListener(VoidCallback listener) {
    _listeners.add(listener);
    source.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    if (_listeners.remove(listener)) source.removeListener(listener);
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isWindows || _media.isEmpty) exit(2);
  SharedPreferences.setMockInitialValues({});
  NativeVideoPlayerMediaKit.ensureInitialized();
  await windowManager.ensureInitialized();
  final directory = await Directory.systemTemp.createTemp('windows_power_');
  _commentsPath = '${directory.path}/comments.ass';
  await File(_commentsPath).writeAsString('''
[Script Info]
PlayResX: 640
PlayResY: 360
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
${List.generate(100, (i) => r'Dialogue: 0,0:00:00.00,0:02:00.00,Medium,,0,0,0,,{\move(640,'
      '${i % 20 * 16},-200,${i % 20 * 16})}native comment $i').join('\n')}
''');
  await _service.initialize(
    playlistManager: PlaylistManager(),
    progressTracker: ProgressTracker(
      playbackStateStore: PlaybackStateStore(
        directoryProvider: () async => directory,
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
  VideoPlayerController? _controller;
  bool _ready = false, _subscribed = false, _injectedBuffering = false;
  bool _showVideo = false, _assertingBuffering = false;
  bool _overlayMounted = false, _overlayVisible = false;
  late final _CountingPosition _danmakuPosition;
  String? _error;
  int _frames = 0, _buildUs = 0, _rasterUs = 0, _positionNotifications = 0;

  @override
  void initState() {
    super.initState();
    _danmakuPosition = _CountingPosition(_service.danmakuPosition);
    WidgetsBinding.instance.addObserver(this);
    SchedulerBinding.instance.addTimingsCallback(_timings);
    unawaited(_start());
  }

  void _timings(List<FrameTiming> timings) {
    for (final timing in timings) {
      _frames++;
      _buildUs += timing.buildDuration.inMicroseconds;
      _rasterUs += timing.rasterDuration.inMicroseconds;
    }
  }

  void _position() => _positionNotifications++;

  void _holdBufferingView() {
    final controller = _controller;
    if (!_injectedBuffering ||
        controller == null ||
        controller.value.isBuffering ||
        _assertingBuffering) {
      return;
    }
    _assertingBuffering = true;
    try {
      controller.value = controller.value.copyWith(isBuffering: true);
    } finally {
      _assertingBuffering = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _service.handleAppLifecycleState(state);
  }

  Future<void> _start() async {
    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, _port);
      _server!.listen((request) => unawaited(_request(request)));
      _service.setPlaybackPageVisible(this, true);
      final pump = Timer.periodic(const Duration(milliseconds: 16), (_) {
        WidgetsBinding.instance.scheduleFrame();
      });
      try {
        await _service
            .play(
              VideoItem(
                id: 'windows-power-audit',
                path: _media,
                title: 'Isolated Windows power diagnostic',
                type: MediaType.video,
                durationMs: 0,
                lastUpdated: 0,
              ),
              autoPlay: true,
            )
            .timeout(const Duration(seconds: 40));
        _controller = _service.controller!;
        _controller!.addListener(_holdBufferingView);
        await _service.setVolume(0);
        await _controller!.setLooping(true);
      } finally {
        pump.cancel();
      }
      _ready = true;
    } catch (error, stack) {
      _error = '$error\n$stack';
    }
    if (mounted) setState(() {});
  }

  Future<Map<String, Object?>> _status() async => {
    'ready': _ready,
    'error': _error,
    'release': const bool.fromEnvironment('dart.vm.product'),
    'platform': Platform.operatingSystem,
    'lifecycle': WidgetsBinding.instance.lifecycleState?.name,
    'displayHz': View.of(context).display.refreshRate,
    'frames': _frames,
    'buildUs': _buildUs,
    'rasterUs': _rasterUs,
    'positionNotifications': _positionNotifications,
    'scheduled': SchedulerBinding.instance.hasScheduledFrame,
    'transientCallbacks': SchedulerBinding.instance.transientCallbackCount,
    'subscribed': _subscribed,
    'injectedDartBuffering': _injectedBuffering,
    'videoVisible': _showVideo,
    'overlayMounted': _overlayMounted,
    'overlayVisible': _overlayVisible,
    'overlayPositionReads': _danmakuPosition.reads,
    'overlayPositionListeners': _danmakuPosition.listeners,
    'playing': _service.isPlaying,
    'buffering': _controller?.value.isBuffering,
    'presentedMs': _service.positionNotifier.value.inMilliseconds,
    'cachedPositionMs': _controller?.value.position.inMilliseconds,
    'mpvPositionMs': _controller == null
        ? null
        : (await NativeVideoPlayerMediaKit.transportPositionFor(
            _controller!.playerId,
          ))?.inMilliseconds,
    'rate': _service.confirmedPlaybackSpeed,
    'rssBytes': ProcessInfo.currentRss,
  };

  Future<void> _request(HttpRequest request) async {
    try {
      final query = request.uri.queryParameters;
      switch (request.uri.path) {
        case '/state':
          final subscribed = query['subscribed'] == '1';
          if (subscribed != _subscribed) {
            _subscribed = subscribed;
            if (subscribed) {
              _service.positionNotifier.addListener(_position);
            } else {
              _service.positionNotifier.removeListener(_position);
            }
          }
          _injectedBuffering = query['buffering'] == '1';
          if (_injectedBuffering) {
            _holdBufferingView();
          } else if (_controller != null) {
            _controller!.value = _controller!.value.copyWith(
              isBuffering: false,
            );
          }
          setState(() {
            _showVideo = query['video'] == '1';
            _overlayMounted = query['overlay'] != null;
            _overlayVisible = query['overlay'] == 'visible';
          });
        case '/play':
          await _service.resume();
        case '/pause':
          await _service.pause();
        case '/seek':
          await _service.seekTo(
            Duration(milliseconds: int.parse(query['ms']!)),
          );
        case '/rate':
          await _service.setPlaybackSpeed(double.parse(query['value']!));
        case '/stop':
          await _service.stop();
        case '/close':
          await _service.stop();
          await request.response.close();
          exit(0);
        case '/status':
          break;
        default:
          request.response.statusCode = HttpStatus.notFound;
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(await _status()));
    } catch (error, stack) {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write(
        jsonEncode({'error': '$error', 'stack': '$stack'}),
      );
    } finally {
      await request.response.close();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Stack(
      fit: StackFit.expand,
      children: [
        Center(
          child: !_ready
              ? Text(_error ?? 'Preparing isolated native playback')
              : _showVideo
              ? AspectRatio(
                  aspectRatio: _controller!.value.aspectRatio,
                  child: VideoPlayer(_controller!),
                )
              : const Text('Isolated native playback diagnostic'),
        ),
        if (_ready && _overlayMounted)
          TickerMode(
            enabled: _overlayVisible,
            child: Offstage(
              offstage: !_overlayVisible,
              child: DanmakuOverlay(
                path: _commentsPath,
                position: _danmakuPosition,
                displayArea: 1,
                opacity: 1,
                fontScale: 1,
                speed: 1,
                fontFamily: null,
                fontWeight: 600,
                outlineType: DanmakuOutlineType.standard,
                playerHeight: 360,
              ),
            ),
          ),
      ],
    ),
  );

  @override
  void dispose() {
    _controller?.removeListener(_holdBufferingView);
    _service.positionNotifier.removeListener(_position);
    _service.setPlaybackPageVisible(this, false);
    WidgetsBinding.instance.removeObserver(this);
    SchedulerBinding.instance.removeTimingsCallback(_timings);
    unawaited(_server?.close(force: true));
    super.dispose();
  }
}
