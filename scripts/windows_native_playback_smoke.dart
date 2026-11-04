// Native regression harness; run with flutter run -d windows --release
// -t scripts/windows_native_playback_smoke.dart
// --dart-define=SMOKE_MEDIA=<absolute video path>
// --dart-define=SMOKE_REPORT=<absolute report path>
// This target never initializes or writes the application's media library.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:window_manager/window_manager.dart';

import 'package:video_player_app/platform/windows_video_player_media_kit.dart';

const _media = String.fromEnvironment('SMOKE_MEDIA');
const _report = String.fromEnvironment('SMOKE_REPORT');
final _navigator = GlobalKey<NavigatorState>();
final _sidebar = ValueNotifier<bool>(true);

void _record(String message) {
  File(_report).writeAsStringSync(
    '${DateTime.now().toIso8601String()} $message\n',
    mode: FileMode.append,
    flush: true,
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isWindows || _media.isEmpty || _report.isEmpty) exit(2);
  File(_report).writeAsStringSync('START native Windows playback smoke\n');
  FlutterError.onError = (details) {
    _record('FAIL Flutter: ${details.exceptionAsString()}');
    exit(1);
  };
  NativeVideoPlayerMediaKit.ensureInitialized();
  await windowManager.ensureInitialized();
  runApp(
    MaterialApp(
      navigatorKey: _navigator,
      theme: ThemeData.dark(),
      home: const Scaffold(
        body: Center(child: Text('Native playback regression')),
      ),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_exercise()));
}

Future<void> _exercise() async {
  try {
    await windowManager.setSize(const Size(1100, 720));
    for (var session = 0; session < 3; session++) {
      final controller = VideoPlayerController.file(File(_media));
      // media_kit waits for a post-frame callback before native creation.
      // This standalone idle home has no loading UI to request those frames.
      final framePump = Timer.periodic(const Duration(milliseconds: 16), (_) {
        WidgetsBinding.instance.scheduleFrame();
      });
      try {
        await controller.initialize().timeout(const Duration(seconds: 25));
      } finally {
        framePump.cancel();
      }
      await controller.setVolume(0);
      await controller.setLooping(true);
      await controller.play();
      _record('session $session initialized');
      for (var visit = 0; visit < 2; visit++) {
        unawaited(
          _navigator.currentState!.push(
            MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                body: ValueListenableBuilder<bool>(
                  valueListenable: _sidebar,
                  builder: (_, open, _) => Row(
                    children: [
                      Expanded(
                        child: Center(
                          child: AspectRatio(
                            aspectRatio: controller.value.aspectRatio,
                            child: VideoPlayer(controller),
                          ),
                        ),
                      ),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        width: open ? 340 : 0,
                        color: Colors.blueGrey,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final firstFrame = NativeVideoPlayerMediaKit.firstFrameRenderedFor(
          // Native integration harness needs the adapter's player identifier.
          // ignore: invalid_use_of_visible_for_testing_member
          controller.playerId,
        );
        if (firstFrame == null) throw StateError('Missing native video output');
        await firstFrame.timeout(const Duration(seconds: 15));
        for (var step = 0; step < 12; step++) {
          _sidebar.value = !_sidebar.value;
          await windowManager.setSize(
            Size(850 + (step % 4) * 110, 540 + (step % 3) * 80),
          );
          await Future<void>.delayed(const Duration(milliseconds: 300));
          if (controller.value.hasError) {
            throw StateError(controller.value.errorDescription!);
          }
        }
        final before = await controller.position;
        await Future<void>.delayed(const Duration(milliseconds: 450));
        final after = await controller.position;
        if (before == after) throw StateError('Playback clock stopped');
        _navigator.currentState!.pop();
        await Future<void>.delayed(const Duration(milliseconds: 450));
        _record(
          'session $session visit $visit: first frame, 12 resizes, clock and return OK',
        );
      }
      await controller.dispose();
      _record('session $session disposed');
    }
    _record(
      'PASS: 6 route entries/returns, 72 sidebar and window resizes, 3 native controller lifecycles',
    );
    await windowManager.close();
  } catch (error, stack) {
    _record('FAIL: $error\n$stack');
    exit(1);
  }
}
