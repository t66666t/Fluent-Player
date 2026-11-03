import 'dart:async';

import 'package:flutter/foundation.dart';

/// Cooperative headroom for foreground gestures and animation. Acquiring a
/// lease starts no timer, polling, model, or frame; owners release on lifecycle
/// changes as well as on completion. Nested surfaces cannot cancel each other.
class UiInteractionBudget extends ChangeNotifier {
  static final instance = UiInteractionBudget();
  int _leases = 0;
  bool _active = false;
  bool get isActive => _active;

  VoidCallback acquire() {
    _leases++;
    if (!_active) {
      _active = true;
      notifyListeners();
    }
    var released = false;
    return () {
      if (released) return;
      released = true;
      if (--_leases == 0) {
        // Pointer-up can release browsing just before the same event's onTap
        // starts a locate. Do not grant a heavy batch in that tiny handover.
        scheduleMicrotask(() {
          if (_leases == 0 && _active) {
            _active = false;
            notifyListeners();
          }
        });
      }
    };
  }
}
