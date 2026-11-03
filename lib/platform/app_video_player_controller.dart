import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import 'windows_video_player_media_kit.dart';

/// Keeps video_player's one-shot initialization size in sync with native
/// presentation changes (late video tracks, rotation and adaptive streams).
class AppVideoPlayerController extends VideoPlayerController {
  AppVideoPlayerController.file(
    super.file, {
    super.closedCaptionFile,
    super.videoPlayerOptions,
    super.httpHeaders,
    super.viewType,
  }) : super.file();

  AppVideoPlayerController.networkUrl(
    super.url, {
    super.formatHint,
    super.closedCaptionFile,
    super.videoPlayerOptions,
    super.httpHeaders,
    super.viewType,
  }) : super.networkUrl();

  ValueListenable<Size?>? _displaySize;
  bool _disposing = false;

  @protected
  ValueListenable<Size?>? get nativeDisplaySize =>
      // ignore: invalid_use_of_visible_for_testing_member
      NativeVideoPlayerMediaKit.displaySizeFor(playerId);

  @override
  Future<void> initialize() async {
    await super.initialize();
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
    _displaySize?.removeListener(_updateDisplaySize);
    _displaySize = null;
    return super.dispose();
  }
}
