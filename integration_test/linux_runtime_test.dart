import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_player/video_player.dart';
import 'package:window_manager/window_manager.dart';

import 'package:video_player_app/platform/linux_file_picker.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'GTK import and software video survive desktop resizing',
    (tester) async {
      Future<void> nativeOperation(Future<void> operation) async {
        var done = false;
        Object? failure;
        StackTrace? trace;
        operation.then(
          (_) {
            done = true;
          },
          onError: (Object error, StackTrace stack) {
            failure = error;
            trace = stack;
            done = true;
          },
        );
        final watch = Stopwatch()..start();
        while (!done && watch.elapsed < const Duration(seconds: 45)) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        if (!done) {
          throw TimeoutException('Native video did not complete with frames');
        }
        if (failure != null) {
          Error.throwWithStackTrace(failure!, trace!);
        }
      }

      LinuxFilePicker.install();
      NativeVideoPlayerMediaKit.ensureInitialized();
      await windowManager.ensureInitialized();
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Linux native runtime check')),
        ),
      );
      debugPrint('Linux smoke: opening native GTK chooser');
      // linux_integration_driver.py selects the generated local sample in the
      // real GTK dialog. No portal, file-picker mock or network account is used.
      final selection = await FilePicker.platform
          .pickFiles(
            dialogTitle: 'Fluent file dialog smoke',
            type: FileType.custom,
            allowedExtensions: ['mkv'],
            withData: false,
          )
          .timeout(const Duration(seconds: 45));
      debugPrint('Linux smoke: GTK selection received');
      expect(selection?.files.length, 1);
      final file = File(selection!.files.single.path!);
      expect(await file.exists(), isTrue);
      final controller = VideoPlayerController.file(file);
      try {
        debugPrint('Linux smoke: initializing native video');
        await nativeOperation(controller.initialize());
        debugPrint('Linux smoke: native video initialized');
        await controller.setLooping(true);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: AspectRatio(
                  aspectRatio: controller.value.aspectRatio,
                  child: VideoPlayer(controller),
                ),
              ),
            ),
          ),
        );
        await controller.play();
        debugPrint('Linux smoke: playback started');
        for (final size in [
          const Size(1280, 720),
          const Size(1920, 1176),
          const Size(800, 600),
        ]) {
          final beforeResize = controller.value.position;
          await windowManager.setSize(size);
          await tester.pump(const Duration(seconds: 2));
          // The short sample loops. Sampling exactly at its boundary can
          // legitimately return zero, so require observable progress instead
          // of treating a single boundary timestamp as a playback failure.
          final progressWatch = Stopwatch()..start();
          while ((controller.value.position == Duration.zero ||
                  controller.value.position == beforeResize) &&
              progressWatch.elapsed < const Duration(seconds: 5)) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(controller.value.isInitialized, isTrue);
          expect(controller.value.hasError, isFalse);
          expect(controller.value.position, greaterThan(Duration.zero));
          expect(controller.value.position, isNot(beforeResize));
          debugPrint('Linux smoke: playback survived resize to $size');
        }
      } finally {
        await nativeOperation(controller.dispose());
      }
    },
    skip: !Platform.isLinux,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
