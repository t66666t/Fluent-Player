import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'settings_service.dart';

/// The single gateway for app-wide haptic feedback.
///
/// Keeping the platform and preference checks here prevents individual
/// interactions from bypassing the user's vibration setting.
/// Use selection ticks or light button feedback; the OS controls the final
/// strength for the device and the user's system touch-feedback preferences.
class AppHaptics {
  const AppHaptics._();

  static bool get isSupportedPlatform {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  static bool _canVibrate(SettingsService settings) {
    return isSupportedPlatform && settings.enableHapticFeedback;
  }

  static Future<void> _perform(
    SettingsService settings,
    Future<void> Function() feedback,
  ) async {
    if (!_canVibrate(settings)) return;
    try {
      await feedback();
    } catch (error) {
      debugPrint('Haptic feedback unavailable: $error');
    }
  }

  static Future<void> selectionClick(SettingsService settings) async {
    await _perform(settings, HapticFeedback.selectionClick);
  }

  static Future<void> sidebarOpened(SettingsService settings) =>
      lightTap(settings);

  static Future<void> dragStarted(SettingsService settings) =>
      selectionClick(settings);

  static Future<void> dragTick(SettingsService settings) => lightTap(settings);

  static Future<void> dragCommitted(SettingsService settings) =>
      lightTap(settings);

  static Future<void> cancelAreaEntered(SettingsService settings) =>
      lightTap(settings);

  static Future<void> resizeBoundaryReached(SettingsService settings) =>
      lightTap(settings);

  static Future<void> cardTap(SettingsService settings) => lightTap(settings);

  static Future<void> longPressStarted(SettingsService settings) async {
    await lightTap(settings);
  }

  static Future<void> reorderDragStarted(SettingsService settings) async {
    await lightTap(settings);
  }

  static Future<void> reorderTargetChanged(SettingsService settings) async {
    await _perform(settings, HapticFeedback.selectionClick);
  }

  static Future<void> reorderDragCompleted(SettingsService settings) async {
    await _perform(settings, HapticFeedback.lightImpact);
  }

  static Future<void> doubleTapSeek(SettingsService settings) async {
    await lightTap(settings);
  }

  /// A button or state release: play, pause or seek step.
  static Future<void> lightTap(SettingsService settings) async {
    await _perform(settings, HapticFeedback.lightImpact);
  }

  /// Fire-and-forget pulse for ordinary call sites.
  ///
  /// [light] selects button feedback ([lightTap]); the default is the quieter
  /// selection tick used by switches, menus and setting rows.
  static void pulse({bool light = false}) {
    final settings = SettingsService();
    unawaited(light ? lightTap(settings) : selectionClick(settings));
  }

  /// Wraps a nullable callback with a pulse.
  ///
  /// `null` stays `null`: wrapping must never turn a disabled control into an
  /// enabled one. Prefer this over hand-written closures at shared widgets.
  static VoidCallback? wrap(VoidCallback? action, {bool light = false}) {
    if (action == null) return null;
    return () {
      pulse(light: light);
      action();
    };
  }

  /// [wrap] for value callbacks such as `Switch.onChanged`.
  static ValueChanged<T>? wrapValue<T>(
    ValueChanged<T>? callback, {
    bool light = false,
  }) {
    if (callback == null) return null;
    return (T value) {
      pulse(light: light);
      callback(value);
    };
  }
}
