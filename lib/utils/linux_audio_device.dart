import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:universal_platform/universal_platform.dart';

import 'app_toast.dart';

/// Linux ALSA card detection for UX hints when the host has no sound device.
class LinuxAudioDevice {
  LinuxAudioDevice._();

  static bool _noAudioHintShownThisSession = false;

  static const String noAudioDeviceMessage =
      '本机未检测到音频设备，画面可播但无声音（环境限制）';

  @visibleForTesting
  static void resetSessionHintForTesting() {
    _noAudioHintShownThisSession = false;
  }

  /// Non-Linux hosts are treated as having audio output.
  ///
  /// On Linux, returns false when `/proc/asound/cards` is missing, empty, or
  /// contains no usable card lines (e.g. "--- no soundcards ---").
  static Future<bool> hasLinuxAudioOutput({
    Future<String> Function()? readCardsContent,
  }) async {
    if (!UniversalPlatform.isLinux && readCardsContent == null) {
      return true;
    }
    try {
      final content = readCardsContent != null
          ? await readCardsContent()
          : await File('/proc/asound/cards').readAsString();
      return parseHasUsableAlsaCard(content);
    } on FileSystemException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Parses `/proc/asound/cards` body. Card lines look like:
  /// ` 0 [PCH            ]: HDA-Intel - HDA Intel PCH`
  @visibleForTesting
  static bool parseHasUsableAlsaCard(String cardsContent) {
    final cardLine = RegExp(r'^\s*\d+\s+\[');
    for (final line in cardsContent.split('\n')) {
      if (cardLine.hasMatch(line)) return true;
    }
    return false;
  }

  /// Shows a once-per-session toast on Linux hosts without ALSA output.
  /// Safe to call on every seek / play — subsequent calls are no-ops.
  static Future<void> maybeShowNoAudioDeviceHint() async {
    if (_noAudioHintShownThisSession) return;
    if (!UniversalPlatform.isLinux) return;
    final hasOutput = await hasLinuxAudioOutput();
    if (hasOutput) return;
    _noAudioHintShownThisSession = true;
    AppToast.show(
      noAudioDeviceMessage,
      type: AppToastType.info,
      duration: const Duration(seconds: 4),
    );
  }
}
