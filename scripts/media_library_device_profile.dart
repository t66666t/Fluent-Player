// Opt-in real-app probe. Uses the existing library and never clears app data.
// Build with --profile/-release -t scripts/media_library_device_profile.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player_app/main.dart' as application;
import 'package:video_player_app/services/library_service.dart';

final _clock = Stopwatch();
final _frames = <ui.FrameTiming>[];
int _window = 0;

Map<String, num> _distribution(Iterable<int> samples) {
  final values = samples.toList()..sort();
  if (values.isEmpty) return {};
  double at(double p) => values[((values.length - 1) * p).round()] / 1000;
  return {'p50': at(.5), 'p95': at(.95), 'p99': at(.99), 'max': at(1)};
}

void _report() {
  final rate = WidgetsBinding
      .instance
      .platformDispatcher
      .views
      .first
      .display
      .refreshRate;
  final budget = 1000000 / rate;
  final cache = PaintingBinding.instance.imageCache;
  debugPrint(
    'FLUENT_PERF ${jsonEncode({'kind': 'frames', 'window': ++_window, 'atMs': _clock.elapsedMilliseconds, 'profile': kProfileMode, 'release': kReleaseMode, 'hz': rate, 'count': _frames.length, 'buildMs': _distribution(_frames.map((f) => f.buildDuration.inMicroseconds)), 'rasterMs': _distribution(_frames.map((f) => f.rasterDuration.inMicroseconds)), 'overBudget': _frames.where((f) => f.buildDuration.inMicroseconds > budget || f.rasterDuration.inMicroseconds > budget).length, 'over50ms': _frames.where((f) => f.buildDuration.inMilliseconds > 50 || f.rasterDuration.inMilliseconds > 50).length, 'rss': ProcessInfo.currentRss, 'decodedBytes': cache.currentSizeBytes, 'liveImages': cache.liveImageCount})}',
  );
  _frames.clear();
}

class _ProbeBinding extends WidgetsFlutterBinding {
  bool _reported = false;
  @override
  void drawFrame() {
    super.drawFrame();
    if (_reported || !LibraryService().isInitialized) return;
    _reported = true;
    debugPrint(
      'FLUENT_PERF ${jsonEncode({'kind': 'home', 'dartToHomeMs': _clock.elapsedMilliseconds, 'mediaCount': LibraryService().storageVideos.length})}',
    );
  }
}

Future<void> main() async {
  _clock.start();
  _ProbeBinding();
  WidgetsBinding.instance.addTimingsCallback(_frames.addAll);
  Timer.periodic(const Duration(seconds: 10), (_) => _report());
  application.main();
}
