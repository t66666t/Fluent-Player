import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/app_wakelock_coordinator.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class _RecordingWakelock extends WakelockPlusWindowsPlugin {
  final calls = <bool>[];
  bool applied = false;
  Completer<void>? pendingEnable;
  @override
  Future<void> toggle({required bool enable}) async {
    calls.add(enable);
    if (enable) await pendingEnable?.future;
    applied = enable;
  }

  @override
  Future<bool> get enabled async => applied;
}

class _ProcessingManager extends TranscriptionManager {
  _ProcessingManager(SettingsService settings) : super(settings: settings);
  bool processing = false;
  @override
  bool get isProcessing => processing;
  void setProcessing(bool value) {
    processing = value;
    notifyListeners();
  }
}

Future<void> drain() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final original = wakelockPlusPlatformInstance;
  late _RecordingWakelock platform;
  late SettingsService settings;
  late _ProcessingManager manager;
  var disposed = false;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService()..resetForTest();
    await settings.init();
    platform = _RecordingWakelock();
    wakelockPlusPlatformInstance = platform;
    manager = _ProcessingManager(settings);
    disposed = false;
  });
  tearDown(() async {
    if (!disposed) manager.dispose();
    AppWakelockCoordinator.setActive(
      AppWakelockCoordinator.mediaPlaybackReason,
      false,
    );
    await drain();
    wakelockPlusPlatformInstance = original;
  });

  test(
    'opt in persists and idle or queued work never keeps the display awake',
    () async {
      expect(settings.batchSubtitleKeepScreenAwake, isFalse);
      manager.setProcessing(true);
      await drain();
      expect(platform.calls, isEmpty);
      manager.setProcessing(false);
      await settings.updateBatchSubtitleKeepScreenAwake(true);
      await manager.startTranscription('queued.mp4', videoId: 'queued');
      await drain();
      expect(platform.calls, isEmpty);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'batchSubtitleKeepScreenAwake',
        ),
        isTrue,
      );
      settings.resetForTest();
      await settings.init();
      expect(settings.batchSubtitleKeepScreenAwake, isTrue);
    },
  );

  test(
    'processing, pause, completion and turning the option off update the lock',
    () async {
      await settings.updateBatchSubtitleKeepScreenAwake(true);
      manager.setProcessing(true);
      await drain();
      expect(platform.applied, isTrue);
      manager.setProcessing(true);
      await drain();
      expect(platform.calls, [true]);
      manager.setProcessing(false);
      await drain();
      expect(platform.applied, isFalse);
      manager.setProcessing(true);
      await drain();
      await settings.updateBatchSubtitleKeepScreenAwake(false);
      await drain();
      expect(platform.calls, [true, false, true, false]);
      await settings.updateBatchSubtitleKeepScreenAwake(true);
      await drain();
      expect(platform.applied, isTrue);
      manager.dispose();
      disposed = true;
      await drain();
      expect(platform.applied, isFalse);
    },
  );

  test('ending transcription does not turn off a playback request', () async {
    AppWakelockCoordinator.setActive(
      AppWakelockCoordinator.mediaPlaybackReason,
      true,
    );
    await settings.updateBatchSubtitleKeepScreenAwake(true);
    manager.setProcessing(true);
    await drain();
    manager.setProcessing(false);
    await drain();
    expect(
      AppWakelockCoordinator.isReasonActive(
        AppWakelockCoordinator.transcriptionReason,
      ),
      isFalse,
    );
    expect(platform.calls, [true]);
    expect(platform.applied, isTrue);
  });

  test(
    'a task ending while native enable is pending releases after enable',
    () async {
      platform.pendingEnable = Completer<void>();
      await settings.updateBatchSubtitleKeepScreenAwake(true);
      manager.setProcessing(true);
      manager.setProcessing(false);
      platform.pendingEnable!.complete();
      await drain();
      expect(platform.calls, [true, false]);
      expect(platform.applied, isFalse);
    },
  );
}
