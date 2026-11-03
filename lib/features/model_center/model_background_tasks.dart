import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

/// Android's foreground notification belongs to work, never to a route.
class ModelBackgroundTasks {
  static const _channel = MethodChannel(
    'com.example.video_player_app/model_tasks',
  );
  static int _downloads = 0;
  static int _inference = 0;
  static void Function()? onInterrupted;
  static bool _registered = false;
  static Future<void> _writes = Future<void>.value();
  static int _revision = 0;

  @visibleForTesting
  static bool? debugNativeTasksSupported;

  @visibleForTesting
  static Future<void> settleForTesting() async {
    while (true) {
      final writes = _writes;
      await writes;
      if (identical(writes, _writes)) return;
    }
  }

  /// Call only after outstanding native replies have settled.
  @visibleForTesting
  static void resetForTesting() {
    _downloads = 0;
    _inference = 0;
    onInterrupted = null;
    _registered = false;
    _writes = Future<void>.value();
    _revision = 0;
    debugNativeTasksSupported = null;
    _channel.setMethodCallHandler(null);
  }

  static void downloads(int count) {
    if (_downloads == count) return;
    _downloads = count;
    _publish();
  }

  static void inference(int delta) {
    _inference = (_inference + delta).clamp(0, 100);
    _publish();
  }

  static void _publish() {
    if (!(debugNativeTasksSupported ??
        (Platform.isAndroid || Platform.isIOS))) {
      return;
    }
    if (!_registered) {
      _registered = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'interrupted') onInterrupted?.call();
      });
    }
    final downloads = _downloads;
    final inference = _inference;
    final revision = ++_revision;
    _writes = _writes.then((_) async {
      try {
        await _channel.invokeMethod<void>('setActive', {
          'downloads': downloads,
          'inference': inference,
        });
      } on MissingPluginException {
        /* test or older host */
      } on PlatformException catch (error) {
        // A delayed refusal belongs to this publication, not a replacement
        // task. Stopping the service or an older host lacking the method must
        // not interrupt unrelated work through the application's handler.
        if (error.code == 'BACKGROUND_START' &&
            revision == _revision &&
            downloads + inference > 0 &&
            _downloads + _inference > 0) {
          onInterrupted?.call();
        }
      }
    });
  }
}
