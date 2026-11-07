import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:wakelock_plus/wakelock_plus.dart';

/// 协调多个业务场景对亮屏的请求，避免互相覆盖关闭。
class AppWakelockCoordinator {
  static const String mediaPlaybackReason = 'media_playback';
  static const String bilibiliDownloadReason = 'bilibili_download_processing';
  static const String ytDlpDownloadReason = 'yt_dlp_download_processing';
  static const String transcriptionReason = 'subtitle_transcription_processing';
  static const String ocrProcessingReason = 'ocr_subtitle_processing';

  static final Set<String> _activeReasons = <String>{};
  // Playback activity is independent of requests to keep the display awake.
  // Separate owners prevent a preview or retiring decoder clearing another
  // player's protection blocker. This never acquires a wake lock itself.
  static final Set<Object> _protectionBlockers = <Object>{};

  /// Readers are sampled by the protection view, never on every progress event.
  static final Map<String, String Function()> _details = {};
  static final ValueNotifier<int> changes = ValueNotifier(0);
  static bool get canProtect =>
      _activeReasons.isNotEmpty &&
      _protectionBlockers.isEmpty &&
      !_activeReasons.contains(mediaPlaybackReason);

  static void setProtectionBlocked(Object owner, bool blocked) {
    final changed = blocked
        ? _protectionBlockers.add(owner)
        : _protectionBlockers.remove(owner);
    if (changed) changes.value++;
  }

  static List<String> protectionDetails() => [
    for (final reason in _activeReasons)
      if (reason != mediaPlaybackReason) _readDetail(reason),
  ];

  static String _readDetail(String reason) {
    try {
      final reader = _details[reason];
      if (reader != null) return reader();
    } catch (_) {
      // A disposed or changing task must never break the exit surface.
    }
    return switch (reason) {
      bilibiliDownloadReason => 'B 站下载进行中',
      ytDlpDownloadReason => '视频下载进行中',
      transcriptionReason => '字幕转录进行中',
      ocrProcessingReason => '字幕识别进行中',
      'douyin_download' => '抖音下载进行中',
      _ => '文件传输进行中',
    };
  }

  static bool _wakelockApplied = false;
  static bool _syncing = false;

  static void setActive(
    String reason,
    bool active, {
    String Function()? detail,
  }) {
    final wasActive = _activeReasons.contains(reason);
    if (active) {
      _activeReasons.add(reason);
      if (detail != null) _details[reason] = detail;
    } else {
      _activeReasons.remove(reason);
      _details.remove(reason);
    }
    if (wasActive != active) changes.value++;
    unawaited(_sync());
  }

  static bool isReasonActive(String reason) => _activeReasons.contains(reason);

  static Future<void> _sync() async {
    if (_syncing) return;
    _syncing = true;
    try {
      // Some platforms acquire the request asynchronously. A task finishing
      // during enable must release it after acquisition, never before it.
      while (_wakelockApplied != _activeReasons.isNotEmpty) {
        final shouldEnable = _activeReasons.isNotEmpty;
        await WakelockPlus.toggle(enable: shouldEnable);
        _wakelockApplied = shouldEnable;
      }
    } catch (_) {
      // Leave the applied state unchanged so a later request can retry.
    } finally {
      _syncing = false;
    }
  }
}
