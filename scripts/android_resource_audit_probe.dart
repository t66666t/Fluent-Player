// Explicit isolated Android Release entry; never a production application target.
// Snapshot preparation assigns com.example.video_player_app.android_resource_audit.
// Preferences are mocked, media are synthetic, no library/model manager starts.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';
import 'package:video_player_app/widgets/ui_refresh_rate_scope.dart';

import 'android_resource_compose_audit.dart';

const _audit = MethodChannel('resource_audit/private');
const _asr = MethodChannel('com.example.video_player_app/asr_acceleration');
const _qwen = MethodChannel('com.example.video_player_app/qwen_asr');
const _bridges = {
  'asr': _asr,
  'qwen': _qwen,
  'cohere': MethodChannel('com.example.video_player_app/cohere_asr'),
  'japanese': MethodChannel('com.example.video_player_app/parakeet_ja'),
};
const _port = 8783;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isAndroid) exit(2);
  SharedPreferences.setMockInitialValues({});
  NativeVideoPlayerMediaKit.ensureInitialized();
  final directory = await Directory.systemTemp.createTemp('resource_audit_');
  final bytes = await rootBundle.load('assets/resource-audit/fixture.mp4');
  final fixture = File('${directory.path}/fixture.mp4');
  await fixture.writeAsBytes(bytes.buffer.asUint8List());
  runApp(MaterialApp(home: UiRefreshRateScope(child: _Probe(fixture))));
}

class _Probe extends StatefulWidget {
  const _Probe(this.fixture);
  final File fixture;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  String _backend = 'none';
  bool _visible = true;
  int _frames = 0, _buildUs = 0, _rasterUs = 0;
  AppLifecycleState? _lifecycle;
  HttpServer? _server;
  late final Ticker _animationTicker;
  final _marker = ValueNotifier<double>(0);
  bool _animationRequested = false;
  int _animationFrames = 0, _animationIntervals = 0;
  int _animationIntervalSumUs = 0, _animationMaxIntervalUs = 0;
  int _animationOverBudget = 0;
  int? _previousAnimationUs;
  static const _animationFrameBudgetUs = 6945; // Nominal 144 Hz.
  static const _animationBudgetToleranceUs = 1000;

  @override
  void initState() {
    super.initState();
    _animationTicker = Ticker(_animate, debugLabel: 'explicit audit stress');
    WidgetsBinding.instance.addObserver(this);
    SchedulerBinding.instance.addTimingsCallback(_timings);
    unawaited(_start());
  }

  void _timings(List<FrameTiming> values) {
    for (final value in values) {
      _frames++;
      _buildUs += value.buildDuration.inMicroseconds;
      _rasterUs += value.rasterDuration.inMicroseconds;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    _syncAnimation();
  }

  void _syncAnimation() {
    final lifecycle = _lifecycle ?? WidgetsBinding.instance.lifecycleState;
    final foreground =
        lifecycle != AppLifecycleState.hidden &&
        lifecycle != AppLifecycleState.paused &&
        lifecycle != AppLifecycleState.detached;
    final active =
        _animationRequested &&
        _visible &&
        foreground &&
        (_controller?.value.isInitialized ?? false) &&
        (_controller?.value.isPlaying ?? false);
    if (active == _animationTicker.isActive) return;
    _previousAnimationUs = null;
    if (active) {
      _animationTicker.start();
    } else {
      _animationTicker.stop();
    }
  }

  void _animate(Duration elapsed) {
    final now = SchedulerBinding.instance.currentFrameTimeStamp.inMicroseconds;
    final previous = _previousAnimationUs;
    _animationFrames++;
    if (previous != null && now > previous) {
      final interval = now - previous;
      _animationIntervals++;
      _animationIntervalSumUs += interval;
      if (interval > _animationMaxIntervalUs) {
        _animationMaxIntervalUs = interval;
      }
      if (interval > _animationFrameBudgetUs + _animationBudgetToleranceUs) {
        _animationOverBudget++;
      }
    }
    _previousAnimationUs = now;
    _marker.value = (now % 2000000) / 2000000;
  }

  void _setAnimation(bool active, {bool reset = false}) {
    if (reset) {
      _animationFrames = 0;
      _animationIntervals = 0;
      _animationIntervalSumUs = 0;
      _animationMaxIntervalUs = 0;
      _animationOverBudget = 0;
      _previousAnimationUs = null;
    }
    _animationRequested = active;
    _syncAnimation();
  }

  Future<void> _start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, _port);
    _server!.listen((request) => unawaited(_request(request)));
  }

  Future<Map<String, Object?>> _status({bool light = false}) async {
    final controller = _controller;
    return {
      'probeDiagnosticRevision': 'high-refresh-v2',
      'lightSample': light,
      'backend': _backend,
      'visible': _visible,
      'lifecycle': (_lifecycle ?? WidgetsBinding.instance.lifecycleState)?.name,
      'ready': controller?.value.isInitialized ?? false,
      'playing': controller?.value.isPlaying,
      'positionMs': controller?.value.position.inMilliseconds,
      'durationMs': controller?.value.duration.inMilliseconds,
      'size': '${controller?.value.size}',
      'error': controller?.value.errorDescription,
      'frames': _frames,
      'buildUs': _buildUs,
      'rasterUs': _rasterUs,
      'scheduled': SchedulerBinding.instance.hasScheduledFrame,
      'animationRequested': _animationRequested,
      'animationRunning': _animationTicker.isActive,
      'animationFrames': _animationFrames,
      'animationIntervals': _animationIntervals,
      'animationIntervalSumUs': _animationIntervalSumUs,
      'animationMaxIntervalUs': _animationMaxIntervalUs,
      'animationOverBudget': _animationOverBudget,
      'animationFrameBudgetUs': _animationFrameBudgetUs,
      'animationBudgetToleranceUs': _animationBudgetToleranceUs,
      'nativePositionMs': controller == null
          ? null
          : (await NativeVideoPlayerMediaKit.transportPositionFor(
              controller.playerId,
            ))?.inMilliseconds,
      'managedByMediaKit':
          controller != null &&
          NativeVideoPlayerMediaKit.transportUsableFor(controller.playerId) !=
              null,
      'native': light
          ? null
          : await _audit.invokeMapMethod<String, dynamic>('stats'),
      'rssBytes': light ? null : ProcessInfo.currentRss,
      'maxRssBytes': light ? null : ProcessInfo.maxRss,
    };
  }

  Future<void> _disposeController() async {
    final old = _controller;
    old?.removeListener(_syncAnimation);
    _setAnimation(false);
    setState(() => _controller = null);
    await WidgetsBinding.instance.endOfFrame;
    await old?.dispose();
  }

  Future<void> _open(String backend) async {
    await _disposeController();
    final pump = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => WidgetsBinding.instance.scheduleFrame(),
    );
    try {
      final options = VideoPlayerOptions(
        mixWithOthers: true,
        allowBackgroundPlayback: true,
      );
      final controller = backend == 'platform'
          ? VideoPlayerController.file(
              widget.fixture,
              videoPlayerOptions: options,
            )
          : VideoPlayerController.networkUrl(
              Uri.parse('http://127.0.0.1:$_port/fixture'),
              videoPlayerOptions: options,
            );
      await controller.initialize().timeout(const Duration(seconds: 40));
      await controller.setVolume(0);
      await controller.setLooping(true);
      setState(() {
        _controller = controller;
        _backend = backend;
        _visible = true;
      });
      controller.addListener(_syncAnimation);
      await controller.play();
    } finally {
      pump.cancel();
    }
  }

  Future<void> _fixture(HttpRequest request) async {
    final length = await widget.fixture.length();
    int start = 0, end = length - 1;
    final match = RegExp(
      r'^bytes=(\d+)-(\d*)',
    ).firstMatch(request.headers.value('range') ?? '');
    if (match != null) {
      start = int.parse(match[1]!);
      if (match[2]!.isNotEmpty) end = int.parse(match[2]!).clamp(start, end);
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
      await request.response.addStream(widget.fixture.openRead(start, end + 1));
    }
    await request.response.close();
  }

  Future<void> _request(HttpRequest request) async {
    if (request.uri.path == '/fixture') {
      await _fixture(request);
      return;
    }
    try {
      final query = request.uri.queryParameters;
      Object? result;
      switch (request.uri.path) {
        case '/status':
          break;
        case '/open':
          await _open(query['backend']!);
        case '/pause':
          await _controller!.pause();
          _syncAnimation();
        case '/play':
          await _controller!.play();
          _syncAnimation();
        case '/seek':
          await _controller!.seekTo(
            Duration(milliseconds: int.parse(query['ms']!)),
          );
        case '/rate':
          await _controller!.setPlaybackSpeed(double.parse(query['value']!));
        case '/visible':
          setState(() => _visible = query['value'] == '1');
          _syncAnimation();
        case '/animation':
          _setAnimation(query['active'] == '1', reset: query['reset'] == '1');
        case '/resize':
          result = await _audit.invokeMethod('resize', {
            'width': int.parse(query['w']!),
            'height': int.parse(query['h']!),
          });
        case '/dispose':
          await _disposeController();
        case '/detach-engine':
          result = await _audit.invokeMethod('detachEngine');
        case '/fire-timeout':
          result = await _audit.invokeMethod('fireTimeout', {
            'label': query['label']!,
          });
        case '/compose':
          result = await runAndroidResourceComposeAudit(widget.fixture);
        case '/bridge':
          final body =
              jsonDecode(await utf8.decoder.bind(request).join())
                  as Map<String, dynamic>;
          final channel = _bridges[query['kind']];
          if (channel == null) {
            throw const FormatException('Unsupported audit bridge');
          }
          result = await channel.invokeMethod(
            query['method'] ?? 'request',
            body,
          );
        case '/write':
          final native = await _audit.invokeMapMethod<String, dynamic>('stats');
          final directory = Directory(
            '${native!['externalFiles']}/resource-audit',
          );
          await directory.create(recursive: true);
          final name = query['name']!;
          if (!RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(name)) {
            throw const FormatException('Unsafe diagnostic filename');
          }
          final file = File('${directory.path}/$name');
          final sink = file.openWrite();
          await sink.addStream(request);
          await sink.close();
          result = {'path': file.path, 'bytes': await file.length()};
        default:
          throw StateError('Unknown diagnostic path');
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          ...await _status(light: query['light'] == '1'),
          'result': result,
        }),
      );
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
    backgroundColor: Colors.black,
    body: SafeArea(
      child: Column(
        children: [
          Text(
            'Isolated Android resource audit / $_backend',
            style: const TextStyle(color: Colors.white),
          ),
          SizedBox(
            height: 6,
            child: ValueListenableBuilder<double>(
              valueListenable: _marker,
              builder: (context, value, child) =>
                  Align(alignment: Alignment(value * 2 - 1, 0), child: child),
              child: const SizedBox(
                width: 6,
                height: 6,
                child: ColoredBox(color: Colors.white),
              ),
            ),
          ),
          Expanded(
            child: Center(
              child: _controller == null
                  ? const SizedBox.shrink()
                  : TickerMode(
                      enabled: _visible,
                      child: Offstage(
                        offstage: !_visible,
                        child: AspectRatio(
                          aspectRatio: _controller!.value.aspectRatio,
                          child: VideoPlayer(_controller!),
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    ),
  );
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SchedulerBinding.instance.removeTimingsCallback(_timings);
    _controller?.removeListener(_syncAnimation);
    _animationTicker.dispose();
    _marker.dispose();
    unawaited(_server?.close(force: true));
    unawaited(_controller?.dispose());
    super.dispose();
  }
}
