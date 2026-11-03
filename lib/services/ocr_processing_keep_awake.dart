import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../models/ocr_subtitle_models.dart';
import 'app_wakelock_coordinator.dart';

/// Owns only the OCR request, independently of the panel and video playback.
class OcrProcessingKeepAwake extends ChangeNotifier
    with WidgetsBindingObserver {
  OcrProcessingKeepAwake({TargetPlatform? platform})
    : _platform = platform ?? defaultTargetPlatform {
    final binding = WidgetsBinding.instance;
    _visible = _isVisible(binding.lifecycleState);
    binding.addObserver(this);
  }

  final TargetPlatform _platform;
  bool _enabled = true;
  bool _processing = false;
  bool _visible = false;
  bool _active = false;
  bool _disposed = false;
  double _progress = 0;

  bool get enabled => _enabled;
  bool get isActive => _active;

  bool get _desktop => switch (_platform) {
    TargetPlatform.windows ||
    TargetPlatform.macOS ||
    TargetPlatform.linux => true,
    _ => false,
  };

  bool _isVisible(AppLifecycleState? state) =>
      state == null ||
      state == AppLifecycleState.resumed ||
      state == AppLifecycleState.inactive;

  void setEnabled(bool value) {
    if (_disposed || _enabled == value) return;
    _enabled = value;
    _sync(preferenceChanged: true);
  }

  void updateJob(OcrSubtitleJob? job) {
    if (_disposed) return;
    _progress = job?.progress ?? 0;
    final processing = job?.isRunning ?? false;
    if (_processing == processing) return;
    _processing = processing;
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    _visible = _isVisible(state);
    _sync();
  }

  void _sync({bool preferenceChanged = false}) {
    // Desktop jobs continue when another window is focused or the app is
    // minimized. Mobile display requests apply only while the app is visible.
    final active = _enabled && _processing && (_desktop || _visible);
    AppWakelockCoordinator.setActive(
      AppWakelockCoordinator.ocrProcessingReason,
      active,
      detail: () => '字幕识别 · ${(_progress.clamp(0, 1) * 100).floor()}%',
    );
    if (_active == active && !preferenceChanged) return;
    _active = active;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _active = false;
    WidgetsBinding.instance.removeObserver(this);
    AppWakelockCoordinator.setActive(
      AppWakelockCoordinator.ocrProcessingReason,
      false,
    );
    super.dispose();
  }
}
