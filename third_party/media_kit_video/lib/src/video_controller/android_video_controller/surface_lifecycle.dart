import 'dart:async';

import 'package:flutter/foundation.dart';

import '../video_output_state.dart';

/// Serializes output changes without acquiring Player's transport lock.
/// Cleanup invalidates readiness immediately, even while an old bind is pending.
class AndroidSurfaceLifecycle {
  AndroidSurfaceLifecycle({
    required this.setProperty,
    required this.getProperty,
    required this.redrawCurrentFrame,
    required this.vo,
    this.onError,
  });

  final Future<void> Function(String, String) setProperty;
  final Future<String> Function(String) getProperty;
  final Future<void> Function() redrawCurrentFrame;
  final String vo;
  final void Function(Object, StackTrace)? onError;
  final ValueNotifier<VideoOutputState> state = ValueNotifier(
    const VideoOutputState(generation: 0, available: false),
  );
  Future<void> _tail = Future<void>.value();
  int _revision = 0;
  bool _disposed = false;

  Future<void> update(
      {required int wid, required int width, required int height}) {
    if (_disposed) return Future<void>.value();
    final revision = ++_revision;
    state.value = VideoOutputState(generation: revision, available: false);
    bool current() => !_disposed && _revision == revision;
    final operation = _tail.then((_) async {
      if (!current()) return;
      // vo=null is required before clearing wid to avoid a native crash.
      await setProperty('vo', 'null');
      if (!current()) return;
      if (wid != 0) {
        await setProperty('android-surface-size', '${width}x$height');
      }
      if (!current()) return;
      await setProperty('wid', wid.toString());
      if (!current() || wid == 0) return;
      await setProperty('vo', vo);
      if (!current()) return;
      if (vo == 'mediacodec_embed') {
        // Reinitialize the codec with the latest selection, including vid=no.
        final selected = await getProperty('vid');
        if (!current()) return;
        await setProperty('vid', selected);
      }
      if (!current()) return;
      final paused = await getProperty('pause');
      final selected = await getProperty('vid');
      final path = await getProperty('path');
      if (!current()) return;
      if (paused == 'yes' && selected != 'no' && path.isNotEmpty) {
        // A paused decoder needs a redraw. A relative zero seek uses the native
        // position at execution, preserving a newer user seek and pause intent.
        await redrawCurrentFrame();
      }
      if (current()) {
        state.value = VideoOutputState(generation: revision, available: true);
      }
    });
    _tail = operation.catchError((Object error, StackTrace stack) {
      onError?.call(error, stack);
    });
    return _tail;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    state.value = VideoOutputState(generation: ++_revision, available: false);
    state.dispose();
  }
}
