import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:video_player_app/platform/app_video_player_controller.dart';
import 'package:video_player_app/services/app_wakelock_coordinator.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'support/fake_video_player_platform.dart';

class _Wake extends WakelockPlusWindowsPlugin {
  final calls = <bool>[];
  @override
  Future<void> toggle({required bool enable}) async => calls.add(enable);
}

class _Platform extends FakeVideoPlayerPlatform {
  Completer<void>? creation;
  bool fail = false;
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    await creation?.future;
    if (fail) return 999;
    return super.createWithOptions(options);
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => fail
      ? Stream.error(
          PlatformException(
            code: 'unavailable',
            message: 'Decoder unavailable',
          ),
        )
      : super.videoEventsFor(playerId);

  @override
  Future<void> dispose(int playerId) async {
    if (!fail) await super.dispose(playerId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late VideoPlayerPlatform originalPlayer;
  final originalWake = wakelockPlusPlatformInstance;
  late _Platform platform;
  late _Wake wake;
  setUp(() async {
    originalPlayer = VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = platform = _Platform();
    wakelockPlusPlatformInstance = wake = _Wake();
    AppWakelockCoordinator.setActive(
      AppWakelockCoordinator.ocrProcessingReason,
      true,
    );
    await Future<void>.delayed(Duration.zero);
  });
  tearDown(() async {
    AppWakelockCoordinator.setActive(
      AppWakelockCoordinator.ocrProcessingReason,
      false,
    );
    await Future<void>.delayed(Duration.zero);
    VideoPlayerPlatform.instance = originalPlayer;
    wakelockPlusPlatformInstance = originalWake;
  });

  test(
    'loading, playback and buffering block protection without changing wake locks',
    () async {
      final controller = AppVideoPlayerController.file(File('preview.mp4'));
      platform.creation = Completer<void>();
      final initialize = controller.initialize();
      expect(AppWakelockCoordinator.canProtect, isFalse);
      platform.creation!.complete();
      await initialize;
      expect(AppWakelockCoordinator.canProtect, isTrue);
      await controller.play();
      expect(AppWakelockCoordinator.canProtect, isFalse);
      await controller.pause();
      expect(AppWakelockCoordinator.canProtect, isTrue);
      controller.value = controller.value.copyWith(isBuffering: true);
      expect(AppWakelockCoordinator.canProtect, isFalse);
      controller.value = controller.value.copyWith(isBuffering: false);
      expect(AppWakelockCoordinator.canProtect, isTrue);
      await controller.dispose();
      expect(wake.calls, [true]);
    },
  );

  test(
    'retiring one decoder cannot unblock a different active preview',
    () async {
      final first = AppVideoPlayerController.file(File('first.mp4'));
      final second = AppVideoPlayerController.file(File('second.mp4'));
      const playing = VideoPlayerValue(
        duration: Duration(minutes: 2),
        isInitialized: true,
        isPlaying: true,
      );
      first.value = playing;
      second.value = playing;
      await first.dispose();
      expect(AppWakelockCoordinator.canProtect, isFalse);
      second.value = playing.copyWith(isPlaying: false);
      expect(AppWakelockCoordinator.canProtect, isTrue);
      second.value = playing;
      await second.dispose();
      expect(AppWakelockCoordinator.canProtect, isTrue);
    },
  );

  test('failed initialization releases the protection blocker', () async {
    platform.fail = true;
    final controller = AppVideoPlayerController.file(File('broken.mp4'));
    await expectLater(
      controller.initialize(),
      throwsA(isA<PlatformException>()),
    );
    expect(AppWakelockCoordinator.canProtect, isTrue);
    await controller.dispose();
  });
}
