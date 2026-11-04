import 'dart:io';

import 'package:flutter/foundation.dart';

/// Platforms that can receive shortcuts from an attached physical keyboard.
bool supportsHardwareKeyboardShortcutsOn(TargetPlatform platform) {
  return switch (platform) {
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.windows ||
    TargetPlatform.macOS ||
    TargetPlatform.linux => true,
    TargetPlatform.fuchsia => false,
  };
}

TargetPlatform? get currentNativeTargetPlatform {
  if (kIsWeb) return null;
  if (Platform.isAndroid) return TargetPlatform.android;
  if (Platform.isIOS) return TargetPlatform.iOS;
  if (Platform.isWindows) return TargetPlatform.windows;
  if (Platform.isMacOS) return TargetPlatform.macOS;
  if (Platform.isLinux) return TargetPlatform.linux;
  return null;
}

bool get supportsNativeHardwareKeyboardShortcuts {
  final platform = currentNativeTargetPlatform;
  return platform != null && supportsHardwareKeyboardShortcutsOn(platform);
}

/// Platforms where an attached mouse/trackpad can drive hover interactions.
bool supportsPlayerPointerHoverOn(TargetPlatform platform) {
  return switch (platform) {
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.windows ||
    TargetPlatform.macOS ||
    TargetPlatform.linux => true,
    TargetPlatform.fuchsia => false,
  };
}
