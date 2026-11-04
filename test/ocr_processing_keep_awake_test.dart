import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/ocr_subtitle_models.dart';
import 'package:video_player_app/services/app_wakelock_coordinator.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/ocr_processing_keep_awake.dart';
import 'package:video_player_app/services/ocr_subtitle_manager.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// The public platform implementation supplies the interface without a new
// dependency. No native Windows methods are called by this recording override.
class _RecordingWakelock extends WakelockPlusWindowsPlugin {
  final calls = <bool>[];
  bool applied = false;
  Completer<void>? nextEnable;
  Completer<void>? nextDisable;

  @override
  Future<void> toggle({required bool enable}) async {
    calls.add(enable);
    final pending = enable ? nextEnable : nextDisable;
    if (enable) {
      nextEnable = null;
    } else {
      nextDisable = null;
    }
    if (pending != null) await pending.future;
    applied = enable;
  }

  @override
  Future<bool> get enabled async => applied;
}

class _PreferencesManager extends OcrSubtitleManager {
  _PreferencesManager() : super(library: LibraryService());

  @override
  Future<void> cleanupStaleTemporaryFiles() async {}
}

const _preferenceKey = 'ocrSubtitleKeepScreenAwakeDuringProcessing';
const _request = OcrSubtitleJob(
  videoId: 'video',
  videoPath: 'video.mp4',
  tracks: [
    OcrSubtitleTrack(
      number: 1,
      region: NormalizedOcrRegion.subtitleDefault(),
      language: OcrSubtitleLanguage.chinese,
    ),
  ],
  start: Duration.zero,
  end: Duration(minutes: 1),
);

Future<void> _drain() => Future<void>.delayed(Duration.zero);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final originalPlatform = wakelockPlusPlatformInstance;
  late _RecordingWakelock platform;
  late OcrProcessingKeepAwake keepAwake;
  var disposed = false;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    platform = _RecordingWakelock();
    wakelockPlusPlatformInstance = platform;
    keepAwake = OcrProcessingKeepAwake(platform: TargetPlatform.android);
    disposed = false;
  });

  tearDown(() async {
    if (!disposed) keepAwake.dispose();
    AppWakelockCoordinator.setActive(
      AppWakelockCoordinator.mediaPlaybackReason,
      false,
    );
    await _drain();
    wakelockPlusPlatformInstance = originalPlatform;
  });

  test(
    'default on stays idle until a task starts and releases when it ends',
    () async {
      expect(keepAwake.enabled, isTrue);
      expect(keepAwake.isActive, isFalse);
      expect(platform.calls, isEmpty);
      keepAwake.updateJob(
        _request.copyWith(status: OcrSubtitleJobStatus.recognizing),
      );
      await _drain();
      expect(keepAwake.isActive, isTrue);
      expect(platform.applied, isTrue);
      keepAwake.updateJob(null);
      await _drain();
      expect(keepAwake.enabled, isTrue);
      expect(keepAwake.isActive, isFalse);
      expect(platform.calls, [true, false]);
    },
  );

  for (final status in [
    OcrSubtitleJobStatus.preparing,
    OcrSubtitleJobStatus.downloading,
    OcrSubtitleJobStatus.materializing,
    OcrSubtitleJobStatus.extracting,
    OcrSubtitleJobStatus.recognizing,
    OcrSubtitleJobStatus.writing,
  ]) {
    test('holds a foreground request during ${status.name}', () async {
      keepAwake.setEnabled(true);
      keepAwake.updateJob(_request.copyWith(status: status));
      await _drain();
      expect(keepAwake.isActive, isTrue);
      expect(platform.applied, isTrue);
      expect(platform.calls, [true]);
    });
  }

  for (final status in OcrSubtitleJobStatus.values.where(
    (status) => !_request.copyWith(status: status).isRunning,
  )) {
    test(
      'releases after ${status.name} and preserves the preference',
      () async {
        keepAwake.setEnabled(true);
        keepAwake.updateJob(
          _request.copyWith(status: OcrSubtitleJobStatus.recognizing),
        );
        await _drain();
        keepAwake.updateJob(_request.copyWith(status: status));
        await _drain();
        expect(keepAwake.enabled, isTrue);
        expect(keepAwake.isActive, isFalse);
        expect(platform.applied, isFalse);
        expect(platform.calls, [true, false]);
      },
    );
  }

  test('can enable and disable during an existing job', () async {
    keepAwake.setEnabled(false);
    keepAwake.updateJob(
      _request.copyWith(status: OcrSubtitleJobStatus.recognizing),
    );
    expect(keepAwake.isActive, isFalse);
    keepAwake.setEnabled(true);
    await _drain();
    expect(platform.applied, isTrue);
    keepAwake.setEnabled(false);
    await _drain();
    expect(platform.applied, isFalse);
    expect(keepAwake.isActive, isFalse);
  });

  test('background releases, foreground restores only a running job', () async {
    keepAwake.setEnabled(true);
    keepAwake.updateJob(
      _request.copyWith(status: OcrSubtitleJobStatus.recognizing),
    );
    await _drain();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await _drain();
    expect(
      keepAwake.isActive,
      isTrue,
      reason: 'an unfocused view is still visible',
    );
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
    ]) {
      binding.handleAppLifecycleStateChanged(state);
      await _drain();
      expect(keepAwake.isActive, isFalse);
      expect(platform.applied, isFalse);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _drain();
      expect(keepAwake.isActive, isTrue);
    }
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    keepAwake.updateJob(
      _request.copyWith(status: OcrSubtitleJobStatus.completed),
    );
    await _drain();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _drain();
    expect(keepAwake.isActive, isFalse);
    expect(platform.applied, isFalse);
  });

  for (final target in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    test(
      '${target.name} keeps an ongoing job awake across window switches',
      () async {
        keepAwake.dispose();
        keepAwake = OcrProcessingKeepAwake(platform: target);
        keepAwake.setEnabled(true);
        keepAwake.updateJob(
          _request.copyWith(status: OcrSubtitleJobStatus.recognizing),
        );
        await _drain();
        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
        ]) {
          binding.handleAppLifecycleStateChanged(state);
          await _drain();
          expect(keepAwake.isActive, isTrue);
          expect(platform.applied, isTrue);
        }
        keepAwake.updateJob(
          _request.copyWith(status: OcrSubtitleJobStatus.completed),
        );
        await _drain();
        expect(keepAwake.isActive, isFalse);
        expect(platform.calls, [true, false]);
      },
    );
  }

  test(
    'iOS releases in the background and restores only while processing',
    () async {
      keepAwake.dispose();
      keepAwake = OcrProcessingKeepAwake(platform: TargetPlatform.iOS);
      keepAwake.setEnabled(true);
      keepAwake.updateJob(
        _request.copyWith(status: OcrSubtitleJobStatus.recognizing),
      );
      await _drain();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await _drain();
      expect(platform.applied, isTrue);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await _drain();
      expect(platform.applied, isFalse);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _drain();
      expect(platform.applied, isTrue);
      keepAwake.updateJob(
        _request.copyWith(status: OcrSubtitleJobStatus.failed),
      );
      await _drain();
      expect(platform.applied, isFalse);
    },
  );

  test(
    'finishing while native acquisition is pending still releases',
    () async {
      final pending = Completer<void>();
      platform.nextEnable = pending;
      keepAwake.setEnabled(true);
      keepAwake.updateJob(
        _request.copyWith(status: OcrSubtitleJobStatus.recognizing),
      );
      keepAwake.updateJob(
        _request.copyWith(status: OcrSubtitleJobStatus.completed),
      );
      expect(platform.calls, [true]);
      pending.complete();
      await _drain();
      expect(platform.calls, [true, false]);
      expect(platform.applied, isFalse);
    },
  );

  test('a new task during native release reacquires afterwards', () async {
    keepAwake.setEnabled(true);
    final running = _request.copyWith(status: OcrSubtitleJobStatus.recognizing);
    keepAwake.updateJob(running);
    await _drain();
    final pending = Completer<void>();
    platform.nextDisable = pending;
    keepAwake.updateJob(
      _request.copyWith(status: OcrSubtitleJobStatus.completed),
    );
    keepAwake.updateJob(running);
    expect(platform.calls, [true, false]);
    pending.complete();
    await _drain();
    expect(platform.calls, [true, false, true]);
    expect(platform.applied, isTrue);
  });

  test('OCR finishing leaves ongoing playback awake', () async {
    AppWakelockCoordinator.setActive(
      AppWakelockCoordinator.mediaPlaybackReason,
      true,
    );
    keepAwake.setEnabled(true);
    keepAwake.updateJob(
      _request.copyWith(status: OcrSubtitleJobStatus.recognizing),
    );
    await _drain();
    keepAwake.updateJob(
      _request.copyWith(status: OcrSubtitleJobStatus.completed),
    );
    await _drain();
    expect(keepAwake.isActive, isFalse);
    expect(platform.calls, [true]);
    expect(platform.applied, isTrue);
    AppWakelockCoordinator.setActive(
      AppWakelockCoordinator.mediaPlaybackReason,
      false,
    );
    await _drain();
    expect(platform.calls, [true, false]);
  });

  test('disposal releases and late events cannot reacquire', () async {
    keepAwake.setEnabled(true);
    final running = _request.copyWith(status: OcrSubtitleJobStatus.recognizing);
    keepAwake.updateJob(running);
    await _drain();
    keepAwake.dispose();
    disposed = true;
    expect(keepAwake.isActive, isFalse);
    keepAwake.updateJob(running);
    keepAwake.setEnabled(true);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _drain();
    expect(platform.calls, [true, false]);
    expect(platform.applied, isFalse);
  });

  test(
    'manager remembers the option without acquiring an idle request',
    () async {
      final first = _PreferencesManager();
      await first.initialize();
      expect(first.keepScreenAwakeDuringProcessing, isTrue);
      expect(first.processingKeepAwake.isActive, isFalse);
      await first.setKeepScreenAwakeDuringProcessing(false);
      first.dispose();
      final second = _PreferencesManager();
      addTearDown(second.dispose);
      await second.initialize();
      expect(second.keepScreenAwakeDuringProcessing, isFalse);
      expect(second.processingKeepAwake.isActive, isFalse);
      expect(platform.calls, isEmpty);
      await second.setKeepScreenAwakeDuringProcessing(true);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(_preferenceKey), isTrue);
    },
  );

  test('restored unfinished OCR never acquires a request at startup', () async {
    SharedPreferences.setMockInitialValues({
      _preferenceKey: true,
      'ocrSubtitleActiveJobV1': jsonEncode({
        'videoId': 'video',
        'videoPath': 'video.mp4',
        'tracks': _request.tracks.map((track) => track.toJson()).toList(),
        'startMs': 0,
        'endMs': 60000,
        'status': OcrSubtitleJobStatus.recognizing.name,
      }),
    });
    final manager = _PreferencesManager();
    addTearDown(manager.dispose);
    await manager.initialize();
    expect(manager.job!.status, OcrSubtitleJobStatus.interrupted);
    expect(manager.keepScreenAwakeDuringProcessing, isTrue);
    expect(manager.processingKeepAwake.isActive, isFalse);
    expect(platform.calls, isEmpty);
  });
}
