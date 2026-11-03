import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel(
  'com.example.video_player_app/progress_sync_network',
);
const _queryTimeout = Duration(seconds: 3);

/// Space available to this user on the destination volume, in bytes.
///
/// A future task directory may not exist yet, so query its nearest existing
/// parent. A failed query is unknown (null), never an artificial zero: actual
/// writes still report space errors if the platform cannot perform a precheck.
Future<int?> availableBytes(Directory path) async {
  if (path.path.contains('\u0000')) return null;
  try {
    var existing = path.absolute;
    while (!await existing.exists().timeout(_queryTimeout)) {
      final parent = existing.parent;
      if (parent.path == existing.path) return null;
      existing = parent;
    }
    final target = existing.path;
    if (Platform.isWindows) {
      return await Isolate.run(
        () => _windowsAvailableBytes(target),
      ).timeout(_queryTimeout);
    }
    if (Platform.isAndroid || Platform.isIOS) {
      final value = await _channel
          .invokeMethod<int>('availableBytes', {'path': target})
          .timeout(_queryTimeout);
      return value?.clamp(0, 0x7fffffffffffffff);
    }
    if (Platform.isMacOS || Platform.isLinux) {
      final result = await Process.run(
        'df',
        ['-Pk', target],
        environment: {'LC_ALL': 'C', 'LANG': 'C'},
        runInShell: false,
      ).timeout(_queryTimeout);
      return result.exitCode == 0 && result.stdout is String
          ? parseDfAvailableBytes(result.stdout as String)
          : null;
    }
  } catch (_) {
    // Prechecks must not prevent reception on unsupported or restricted hosts.
  }
  return null;
}

typedef _GetDiskFreeSpaceNative =
    Int32 Function(
      Pointer<Utf16>,
      Pointer<Uint64>,
      Pointer<Uint64>,
      Pointer<Uint64>,
    );
typedef _GetDiskFreeSpace =
    int Function(
      Pointer<Utf16>,
      Pointer<Uint64>,
      Pointer<Uint64>,
      Pointer<Uint64>,
    );

int? _windowsAvailableBytes(String path) {
  final getSpace = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<_GetDiskFreeSpaceNative, _GetDiskFreeSpace>(
        'GetDiskFreeSpaceExW',
      );
  // UNC paths require a trailing separator. It is also valid for local paths.
  final nativePath = path.endsWith(r'\') ? path : '$path\\';
  final widePath = nativePath.toNativeUtf16();
  final available = calloc<Uint64>();
  try {
    // Caller-available space respects quotas; total free space may overpromise.
    return getSpace(widePath, available, nullptr, nullptr) != 0
        ? available.value
        : null;
  } finally {
    calloc.free(available);
    malloc.free(widePath);
  }
}

/// `df -Pk` uses POSIX rows and 1024-byte blocks on both macOS and Linux.
@visibleForTesting
int? parseDfAvailableBytes(String output) {
  final row = RegExp(r'^\s*.+?\s+\d+\s+\d+\s+(-?\d+)\s+\d+%\s+.+$');
  for (final line in output.split(RegExp(r'\r?\n')).reversed) {
    final match = row.firstMatch(line);
    if (match == null) continue;
    final blocks = int.tryParse(match.group(1)!);
    if (blocks == null) return null;
    return blocks < 0 ? 0 : blocks * 1024;
  }
  return null;
}
