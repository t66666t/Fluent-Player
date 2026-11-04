import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Requests ordinary Android notifications once, after the first-use flow.
/// MediaSession notifications do not require this permission. Explicit
/// notification settings actions may still request it independently.
class StartupNotificationPermission {
  StartupNotificationPermission({
    bool? isAndroid,
    Future<PermissionStatus> Function()? readStatus,
    Future<PermissionStatus> Function()? request,
    Future<bool> Function()? shouldShowRationale,
  }) : _isAndroid = isAndroid ?? Platform.isAndroid,
       _readStatus = readStatus ?? (() => Permission.notification.status),
       _request = request ?? (() => Permission.notification.request()),
       _shouldShowRationale =
           shouldShowRationale ??
           (() => Permission.notification.shouldShowRequestRationale);

  static final instance = StartupNotificationPermission();

  // Device-local prompt history must not travel in exported preferences.
  static const handledKey = 'notification_permission_startup_handled_v1';

  final bool _isAndroid;
  final Future<PermissionStatus> Function() _readStatus;
  final Future<PermissionStatus> Function() _request;
  final Future<bool> Function() _shouldShowRationale;
  Future<void>? _pending;

  Future<void> requestOnce() {
    if (!_isAndroid) return Future.value();
    return _pending ??= _run().whenComplete(() => _pending = null);
  }

  Future<void> _run() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(handledKey) == true) return;
      final status = await _readStatus();
      // Preserve a previous denial on upgrades, even before prompt history was
      // introduced. A retry belongs to a deliberate notification setting action.
      final previouslyDenied = status.isDenied && await _shouldShowRationale();
      if (!await prefs.setBool(handledKey, true)) return;
      if (status.isDenied && !previouslyDenied) await _request();
    } catch (error) {
      debugPrint('Startup notification permission unavailable: $error');
    }
  }
}
