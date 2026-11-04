// Profile the real application without modifying its production entry point.
// flutter run -d windows --profile --no-resident
// -t scripts/windows_app_frame_profile.dart
// --dart-define=FRAME_DIRECTORY=<absolute output directory>
// A loopback-only endpoint records named phases through /start?label=... and
// /stop. No media paths, titles or library contents are included in the report.
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player_app/main.dart' as app;

const directory = String.fromEnvironment('FRAME_DIRECTORY');
final frames = <FrameTiming>[];
int startedUs = 0;
int endedUs = 0;
String label = '';

Map<String, Object> distribution(Iterable<int> samples) {
  final values = samples.toList()..sort();
  if (values.isEmpty) return {'count': 0};
  double percentile(double p) =>
      values[((values.length - 1) * p).round()] / 1000;
  return {
    'count': values.length,
    'p50Ms': percentile(.5),
    'p95Ms': percentile(.95),
    'p99Ms': percentile(.99),
    'maxMs': values.last / 1000,
    'over8_33ms': values.where((v) => v > 8334).length,
    'over16_67ms': values.where((v) => v > 16668).length,
  };
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isWindows || directory.isEmpty) exit(2);
  Directory(directory).createSync(recursive: true);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  File(
    '$directory/endpoint.json',
  ).writeAsStringSync(jsonEncode({'port': server.port}));
  SchedulerBinding.instance.addTimingsCallback((batch) {
    if (startedUs == 0) return;
    for (final timing in batch) {
      final wall = timing.timestampInMicroseconds(
        FramePhase.rasterFinishWallTime,
      );
      if (wall >= startedUs &&
          (endedUs == 0 || wall <= endedUs) &&
          frames.length < 30000) {
        frames.add(timing);
      }
    }
  });
  app.main();
  await for (final request in server) {
    request.response.headers.contentType = ContentType.json;
    if (request.uri.path == '/start') {
      frames.clear();
      label = (request.uri.queryParameters['label'] ?? 'phase').replaceAll(
        RegExp('[^a-zA-Z0-9_-]'),
        '_',
      );
      startedUs = DateTime.now().microsecondsSinceEpoch;
      endedUs = 0;
      request.response.write(jsonEncode({'recording': label}));
    } else if (request.uri.path == '/stop') {
      endedUs = DateTime.now().microsecondsSinceEpoch;
      // Flutter delivers profile frame timings in batches. Include the tail,
      // but exclude frames whose wall timestamp is after this phase ended.
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      final data = frames.toList();
      startedUs = 0;
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      final summary = {
        'phase': label,
        'reportedHz': view.display.refreshRate,
        'build': distribution(data.map((t) => t.buildDuration.inMicroseconds)),
        'raster': distribution(
          data.map((t) => t.rasterDuration.inMicroseconds),
        ),
        'vsyncOverhead': distribution(
          data.map((t) => t.vsyncOverhead.inMicroseconds),
        ),
        'totalSpan': distribution(data.map((t) => t.totalSpan.inMicroseconds)),
      };
      await File('$directory/$label.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          ...summary,
          'frames': data
              .map(
                (t) => {
                  'vsyncUs': t.timestampInMicroseconds(FramePhase.vsyncStart),
                  'buildUs': t.buildDuration.inMicroseconds,
                  'rasterUs': t.rasterDuration.inMicroseconds,
                  'vsyncOverheadUs': t.vsyncOverhead.inMicroseconds,
                  'totalUs': t.totalSpan.inMicroseconds,
                },
              )
              .toList(),
        }),
      );
      request.response.write(jsonEncode(summary));
    } else {
      request.response.statusCode = HttpStatus.notFound;
    }
    await request.response.close();
  }
}
