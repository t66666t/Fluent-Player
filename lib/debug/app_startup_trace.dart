import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';

/// Enabled only in explicit performance builds; never logs paths or titles.
class AppStartupTrace {
  static const enabled = bool.fromEnvironment('FLUENT_STARTUP_TRACE');
  static final _clock = Stopwatch();
  static void start() {
    if (enabled) _clock.start();
  }

  static void mark(String stage, [int? elapsedUs]) {
    if (!enabled) return;
    debugPrint(
      'FLUENT_STARTUP ${jsonEncode({'stage': stage, 'atUs': _clock.elapsedMicroseconds, 'elapsedUs': elapsedUs})}',
    );
  }

  static Future<T> measure<T>(String stage, Future<T> Function() work) async {
    if (!enabled) return work();
    final watch = Stopwatch()..start();
    final task = developer.TimelineTask()..start('startup:$stage');
    try {
      return await work();
    } finally {
      task.finish();
      mark(stage, watch.elapsedMicroseconds);
    }
  }
}
