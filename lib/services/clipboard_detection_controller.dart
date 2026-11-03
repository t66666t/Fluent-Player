import 'dart:async';

import 'package:flutter/foundation.dart';

import 'settings_service.dart';

class ClipboardDetectionCancelled implements Exception {
  const ClipboardDetectionCancelled();
}

/// One shared, synchronous preference gates automatic Bilibili previews and
/// offline clipboard routing; explicit drops have their own generation.
/// Invalidating a generation releases pending waits;
/// results from uncancellable platform/shared-service calls are discarded.
class ClipboardDetectionController extends ChangeNotifier {
  ClipboardDetectionController(this.settings)
    : _enabled = settings.clipboardLinkDetectionEnabled,
      _skipRepeated = settings.skipRepeatedClipboardText {
    settings.addListener(_settingsChanged);
  }

  final SettingsService settings;
  bool _enabled;
  bool _skipRepeated;
  bool _disposed = false;
  int _revision = 0;
  Completer<void> _cancelled = Completer<void>();
  int _manualRevision = 0;
  Completer<void> _manualCancelled = Completer<void>();

  bool get enabled =>
      !_disposed && _enabled && settings.clipboardLinkDetectionEnabled;

  void _settingsChanged() {
    final next = settings.clipboardLinkDetectionEnabled;
    final skipRepeated = settings.skipRepeatedClipboardText;
    if (_disposed || (next == _enabled && skipRepeated == _skipRepeated)) {
      return;
    }
    _enabled = next;
    _skipRepeated = skipRepeated;
    _invalidateAutomatic();
    notifyListeners();
  }

  void invalidate() {
    _invalidateAutomatic();
    _manualRevision++;
    _manualCancelled.complete();
    _manualCancelled = Completer<void>();
  }

  void _invalidateAutomatic() {
    _revision++;
    _cancelled.complete();
    _cancelled = Completer<void>();
  }

  ClipboardDetectionAttempt? begin() => enabled
      ? ClipboardDetectionAttempt._(this, _revision, _cancelled.future)
      : null;

  /// An explicit drop does not enable automatic reads or follow their switch.
  /// Page/lifecycle changes and disposal still invalidate its pending work.
  ClipboardDetectionAttempt? beginManual() => _disposed
      ? null
      : ClipboardDetectionAttempt._(
          this,
          _manualRevision,
          _manualCancelled.future,
          manual: true,
        );

  @override
  void dispose() {
    settings.removeListener(_settingsChanged);
    _disposed = true;
    invalidate();
    super.dispose();
  }
}

class ClipboardDetectionAttempt {
  ClipboardDetectionAttempt._(
    this._owner,
    this._revision,
    this._cancelled, {
    this.manual = false,
  });
  final ClipboardDetectionController _owner;
  final int _revision;
  final Future<void> _cancelled;
  final bool manual;

  bool get isCurrent => manual
      ? !_owner._disposed && _owner._manualRevision == _revision
      : _owner.enabled && _owner._revision == _revision;

  void ensureCurrent() {
    if (!isCurrent) throw const ClipboardDetectionCancelled();
  }

  Future<T> wait<T>(Future<T> operation) async {
    // Always attach an error handler to the operation, including when it is
    // already stale. A late platform/network failure must not go unhandled.
    final result = await Future.any<T>([
      operation,
      _cancelled.then<T>((_) => throw const ClipboardDetectionCancelled()),
    ]);
    ensureCurrent();
    return result;
  }
}
