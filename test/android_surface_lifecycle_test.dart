import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/src/video_controller/android_video_controller/surface_lifecycle.dart';

void main() {
  late Map<String, String> native;
  late List<String> commands;
  late AndroidSurfaceLifecycle surface;
  late int redraws;
  setUp(() {
    native = {
      'pause': 'yes',
      'vid': '3',
      'path': 'movie.mp4',
      'time-pos': '66',
    };
    commands = [];
    redraws = 0;
    surface = AndroidSurfaceLifecycle(
      vo: 'gpu',
      setProperty: (key, value) async {
        commands.add('$key=$value');
        native[key] = value;
      },
      getProperty: (key) async => native[key] ?? '',
      redrawCurrentFrame: () async => redraws++,
    );
  });
  tearDown(() => surface.dispose());

  test(
    'cleanup invalidates the output without seeking or changing the track',
    () async {
      await surface.update(wid: 10, width: 960, height: 720);
      final generation = surface.state.value.generation;
      redraws = 0;
      final cleanup = surface.update(wid: 0, width: 960, height: 720);
      expect(surface.state.value.available, isFalse);
      expect(surface.state.value.generation, greaterThan(generation));
      await cleanup;
      expect(native['wid'], '0');
      expect(native['vo'], 'null');
      expect(native['vid'], '3');
      expect(native['time-pos'], '66');
      expect(redraws, 0);
    },
  );

  test(
    'paused restore redraws the current position and preserves user state',
    () async {
      await surface.update(wid: 0, width: 960, height: 720);
      await surface.update(wid: 11, width: 960, height: 720);
      expect(surface.state.value.available, isTrue);
      expect(native['time-pos'], '66');
      expect(native['pause'], 'yes');
      expect(native['vid'], '3');
      expect(redraws, 1);
    },
  );

  test('playing restore does not seek the live audio clock', () async {
    native['pause'] = 'no';
    await surface.update(wid: 11, width: 960, height: 720);
    expect(redraws, 0);
    expect(native['vid'], '3');
  });

  test('audio-only restore does not select or decode a video track', () async {
    native['vid'] = 'no';
    await surface.update(wid: 11, width: 960, height: 720);
    expect(native['vid'], 'no');
    expect(redraws, 0);
  });

  test('late bind cannot mark a recycled surface available', () async {
    surface.dispose();
    final blocked = Completer<void>();
    surface = AndroidSurfaceLifecycle(
      vo: 'gpu',
      setProperty: (key, value) async {
        commands.add('$key=$value');
        if (value == 'gpu') await blocked.future;
      },
      getProperty: (key) async => native[key] ?? '',
      redrawCurrentFrame: () async => redraws++,
    );
    final bind = surface.update(wid: 10, width: 960, height: 720);
    await Future<void>.delayed(Duration.zero);
    final cleanup = surface.update(wid: 0, width: 960, height: 720);
    expect(surface.state.value.available, isFalse);
    blocked.complete();
    await Future.wait([bind, cleanup]);
    expect(surface.state.value.available, isFalse);
    expect(commands.last, 'wid=0');
    expect(redraws, 0);
  });

  test(
    'a failed native bind remains unavailable and the next bind can succeed',
    () async {
      surface.dispose();
      var fail = true;
      var errors = 0;
      surface = AndroidSurfaceLifecycle(
        vo: 'gpu',
        setProperty: (key, value) async {
          if (fail) throw StateError('surface gone');
        },
        getProperty: (key) async => native[key] ?? '',
        redrawCurrentFrame: () async {},
        onError: (_, _) => errors++,
      );
      await surface.update(wid: 10, width: 960, height: 720);
      expect(surface.state.value.available, isFalse);
      expect(errors, 1);
      fail = false;
      await surface.update(wid: 11, width: 960, height: 720);
      expect(surface.state.value.available, isTrue);
    },
  );

  test(
    'disposal invalidates queued work without waiting on the transport',
    () async {
      surface.dispose();
      final blocked = Completer<void>();
      surface = AndroidSurfaceLifecycle(
        vo: 'gpu',
        setProperty: (_, _) => blocked.future,
        getProperty: (key) async => native[key] ?? '',
        redrawCurrentFrame: () async => redraws++,
      );
      final bind = surface.update(wid: 10, width: 960, height: 720);
      await Future<void>.delayed(Duration.zero);
      surface.dispose();
      blocked.complete();
      await bind;
      expect(redraws, 0);
    },
  );
}
