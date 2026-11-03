import 'dart:ffi';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/ocr_subtitle_models.dart';
import 'package:video_player_app/services/ocr_processing_keep_awake.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Windows native display request survives window switches and ends with OCR',
    () async {
      const continuous = 0x80000000;
      const displayRequired = 0x00000002;
      final executionState = DynamicLibrary.open('kernel32.dll')
          .lookupFunction<Uint32 Function(Uint32), int Function(int)>(
            'SetThreadExecutionState',
          );
      final originalState = executionState(continuous);
      expect(originalState, isNot(0));
      final originalPlatform = wakelockPlusPlatformInstance;
      wakelockPlusPlatformInstance = WakelockPlusWindowsPlugin();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final keepAwake = OcrProcessingKeepAwake(
        platform: TargetPlatform.windows,
      );
      const request = OcrSubtitleJob(
        videoId: 'native-windows-check',
        videoPath: 'unused.mp4',
        tracks: [],
        start: Duration.zero,
        end: Duration(minutes: 1),
        status: OcrSubtitleJobStatus.recognizing,
      );
      try {
        keepAwake.setEnabled(true);
        await Future<void>.delayed(Duration.zero);
        expect(executionState(continuous) & displayRequired, 0);

        keepAwake.updateJob(request);
        await Future<void>.delayed(Duration.zero);
        expect(
          executionState(continuous | displayRequired) & displayRequired,
          displayRequired,
          reason: 'the OS thread must own an actual display request',
        );

        binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        await Future<void>.delayed(Duration.zero);
        expect(
          executionState(continuous | displayRequired) & displayRequired,
          displayRequired,
          reason: 'minimizing must preserve an ongoing desktop task request',
        );

        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await Future<void>.delayed(Duration.zero);
        expect(
          executionState(continuous | displayRequired) & displayRequired,
          displayRequired,
        );

        keepAwake.updateJob(
          request.copyWith(status: OcrSubtitleJobStatus.completed),
        );
        await Future<void>.delayed(Duration.zero);
        expect(executionState(continuous) & displayRequired, 0);
      } finally {
        keepAwake.dispose();
        await Future<void>.delayed(Duration.zero);
        wakelockPlusPlatformInstance = originalPlatform;
        executionState(originalState);
      }
    },
    skip:
        !Platform.isWindows ||
        !const bool.fromEnvironment('OCR_WAKELOCK_NATIVE'),
  );
}
