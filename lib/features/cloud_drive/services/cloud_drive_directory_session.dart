import 'package:flutter/foundation.dart';
import '../models/cloud_drive_models.dart';
import '../models/cloud_drive_view_options.dart';
import 'cloud_drive_browser_controller.dart';
import 'cloud_drive_runtime.dart';

/// Retained by both the browser and playback. A later browse cannot redirect it.
class CloudDriveDirectorySession extends ChangeNotifier {
  CloudDriveDirectorySession({
    required CloudDriveRuntime runtime,
    required this.account,
    required this.directoryId,
  }) : _browser = CloudDriveBrowserController(
         providers: runtime.providers,
         accounts: runtime.accounts,
       );

  final CloudDriveAccount account;
  final String directoryId;
  final CloudDriveBrowserController _browser;
  List<CloudDriveEntry> entries = const [];
  CloudDriveFailure? error;
  bool complete = false;
  bool loading = false;
  bool _opened = false;
  bool _paused = false;
  bool _closed = false;
  int _owners = 1;
  Future<void>? _pending;

  void retain() {
    assert(!_closed);
    _owners++;
  }

  void release() {
    if (--_owners > 0) return;
    _closed = true;
    _browser.close();
    super.dispose();
  }

  void pause() {
    _paused = true;
  }

  Future<void> finish() {
    if (_closed || complete) return Future.value();
    return _pending ??= _read().whenComplete(() => _pending = null);
  }

  Future<void> _read() async {
    _paused = false;
    loading = true;
    error = null;
    notifyListeners();
    try {
      do {
        final previousCursor = _browser.cursor;
        final snapshot = !_opened
            ? await _browser.openAccount(account, directoryId: directoryId)
            : await _browser.loadMore();
        if (_closed) return;
        if (snapshot.error != null) throw snapshot.error!;
        _opened = true;
        final seen = <String>{};
        entries = List.unmodifiable(
          snapshot.entries.where((e) => seen.add(cloudDriveEntryKey(e))),
        );
        complete = !snapshot.hasMore;
        if (!complete && _browser.cursor == previousCursor) {
          throw const CloudDriveFailure(
            CloudDriveFailureKind.unavailable,
            '目录分页未能继续，请重试',
          );
        }
        notifyListeners();
      } while (!complete && !_paused && !_closed);
    } catch (failure) {
      if (_closed) return;
      error = failure is CloudDriveFailure
          ? failure
          : const CloudDriveFailure(
              CloudDriveFailureKind.network,
              '目录读取失败，请重试',
            );
      rethrow;
    } finally {
      if (!_closed) {
        loading = false;
        notifyListeners();
      }
    }
  }
}
