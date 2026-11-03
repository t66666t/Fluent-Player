import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/platform/native_audio_pause_repair.dart';

class _Transport {
  final calls = <String>[];
  bool current = true;
  bool restorable = true;
  bool failRestore = false;
  Duration? captured = const Duration(milliseconds: 12345);
  Completer<Duration?>? pauseGate;
  late final repair = NativeAudioPauseRepair(
    pauseAndCapture: () {
      calls.add('pause');
      return pauseGate?.future ?? Future.value(captured);
    },
    play: () async => calls.add('play'),
    restore: (target) async {
      calls.add('restore:${target.inMicroseconds}');
      if (failRestore) throw StateError('native seek rejected');
    },
    canRestore: () => restorable,
    isCurrent: () => current,
  );
}

void main() {
  test(
    'pause alone keeps the device stopped without seeking or decoding',
    () async {
      final native = _Transport();
      await native.repair.pause();
      expect(native.calls, ['pause']);
      expect(native.repair.pausedPosition, native.captured);
      await native.repair.play();
      expect(native.calls, ['pause', 'restore:12345000', 'play']);
      expect(native.repair.pausedPosition, isNull);
    },
  );

  test('a queued resume follows the audible-position repair', () async {
    final native = _Transport()..pauseGate = Completer<Duration?>();
    final paused = native.repair.pause();
    final resumed = native.repair.play();
    expect(native.calls, ['pause']);
    native.pauseGate!.complete(native.captured);
    await Future.wait([paused, resumed]);
    expect(native.calls, ['pause', 'restore:12345000', 'play']);
    expect(native.repair.lastPausePosition, native.captured);
  });

  test('a newer user seek wins over a delayed pause snapshot', () async {
    final native = _Transport()..pauseGate = Completer<Duration?>();
    final paused = native.repair.pause();
    final sought = native.repair.seek(() async => native.calls.add('seek:20'));
    final resumed = native.repair.play();
    native.pauseGate!.complete(native.captured);
    await Future.wait([paused, sought, resumed]);
    expect(native.calls, ['pause', 'seek:20', 'play']);
    expect(native.repair.lastPausePosition, isNull);
  });

  test('native video-output seeks invalidate an older pause', () async {
    final native = _Transport()..pauseGate = Completer<Duration?>();
    final paused = native.repair.pause();
    native.repair.invalidatePosition();
    native.pauseGate!.complete(native.captured);
    await paused;
    expect(native.calls, ['pause']);
  });

  test(
    'an already paused, video-only or unseekable output is not sought',
    () async {
      final native = _Transport()..captured = null;
      await native.repair.pause();
      await native.repair.play();
      expect(native.calls, ['pause', 'play']);
    },
  );

  test(
    'EOF remains completed instead of rewinding the finished item',
    () async {
      final native = _Transport()..restorable = false;
      await native.repair.pause();
      expect(native.calls, ['pause']);
      expect(native.repair.lastPausePosition, isNull);
    },
  );

  test('a replaced controller cannot restore or play the old media', () async {
    final native = _Transport()..pauseGate = Completer<Duration?>();
    final paused = native.repair.pause();
    final resumed = native.repair.play();
    native.current = false;
    native.pauseGate!.complete(native.captured);
    await Future.wait([paused, resumed]);
    expect(native.calls, ['pause']);
  });

  test(
    'dispose drains an accepted pause without dispatching queued work',
    () async {
      final native = _Transport()..pauseGate = Completer<Duration?>();
      final paused = native.repair.pause();
      final resumed = native.repair.play();
      final disposed = native.repair.dispose();
      native.pauseGate!.complete(native.captured);
      await Future.wait([paused, resumed, disposed]);
      expect(native.calls, ['pause']);
    },
  );

  test('failed restoration is retried before any resume can play', () async {
    final native = _Transport()..failRestore = true;
    await native.repair.pause();
    await expectLater(native.repair.play(), throwsStateError);
    await expectLater(native.repair.play(), throwsStateError);
    expect(native.calls, ['pause', 'restore:12345000', 'restore:12345000']);
    native.failRestore = false;
    await native.repair.play();
    expect(native.calls.last, 'play');
    expect(native.calls[native.calls.length - 2], 'restore:12345000');
  });

  test('an explicit seek clears a failed recovery target', () async {
    final native = _Transport()..failRestore = true;
    await native.repair.pause();
    await expectLater(native.repair.play(), throwsStateError);
    await native.repair.seek(() async => native.calls.add('seek:30'));
    await native.repair.play();
    expect(native.calls, ['pause', 'restore:12345000', 'seek:30', 'play']);
  });

  test(
    'retained-device outputs and file writers keep their original pause',
    () {
      for (final output in ['pulse', 'null', 'pcm', '']) {
        expect(NativeAudioPauseRepair.needsRepair(output), isFalse);
      }
      for (final output in [
        'opensles',
        'audiotrack',
        'wasapi',
        'coreaudio',
        'audiounit',
        'alsa',
        'pipewire',
      ]) {
        expect(NativeAudioPauseRepair.needsRepair(output), isTrue);
      }
    },
  );
}
