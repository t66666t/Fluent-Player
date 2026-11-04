import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import 'windows_video_player_media_kit.dart';
import '../services/app_wakelock_coordinator.dart';

/// Keeps video_player's one-shot initialization size in sync with native
/// presentation changes (late video tracks, rotation and adaptive streams).
class AppVideoPlayerController extends VideoPlayerController {
  AppVideoPlayerController.file(
    super.file, {
    super.closedCaptionFile,
    super.videoPlayerOptions,
    super.httpHeaders,
    super.viewType,
  }) : super.file() {
    addListener(_syncProtectionActivity);
  }

  AppVideoPlayerController.networkUrl(
    super.url, {
    super.formatHint,
    super.closedCaptionFile,
    super.videoPlayerOptions,
    super.httpHeaders,
    super.viewType,
  }) : super.networkUrl() {
    addListener(_syncProtectionActivity);
  }

  ValueListenable<Size?>? _displaySize;
  bool _disposing = false;
  bool _initializing = false;

  void _syncProtectionActivity() {
    AppWakelockCoordinator.setProtectionBlocked(
      this,
      !_disposing &&
          !value.hasError &&
          (_initializing || value.isPlaying || value.isBuffering),
    );
  }

  @protected
  ValueListenable<Size?>? get nativeDisplaySize =>
      // ignore: invalid_use_of_visible_for_testing_member
      NativeVideoPlayerMediaKit.displaySizeFor(playerId);

  @override
  Future<void> initialize() async {
    _initializing = true;
    _syncProtectionActivity();
    try {
      await super.initialize();
    } finally {
      _initializing = false;
      _syncProtectionActivity();
    }
    if (_disposing) return;
    _displaySize = nativeDisplaySize;
    _displaySize?.addListener(_updateDisplaySize);
    // A videoParams event may have arrived while initialize was completing.
    _updateDisplaySize();
  }

  void _updateDisplaySize() {
    if (_disposing || !value.isInitialized || value.hasError) return;
    final size = _displaySize?.value;
    if (size == null ||
        !size.width.isFinite ||
        !size.height.isFinite ||
        size.width <= 0 ||
        size.height <= 0 ||
        size == value.size) {
      return;
    }
    value = value.copyWith(size: size);
  }

  @override
  Future<void> dispose() {
    _disposing = true;
    removeListener(_syncProtectionActivity);
    AppWakelockCoordinator.setProtectionBlocked(this, false);
    _displaySize?.removeListener(_updateDisplaySize);
    _displaySize = null;
    return super.dispose();
  }
}
