import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// No command line or URL parser sees the filename. A PIDL identifies the
/// exact filesystem item, even when its name contains commas, #, %, or Unicode.
Future<bool> revealWindowsFile(String path) => Isolate.run(
  () =>
      withWindowsShellItem(
        path,
        (item) => _shell.openFolderAndSelectItems(item, 0, nullptr, 0) >= 0,
      ) ??
      false,
);

/// Scopes COM and the Shell allocation to one thread. Also used by native
/// round-trip tests, which inspect the PIDL without opening Explorer windows.
@visibleForTesting
T? withWindowsShellItem<T>(String path, T Function(Pointer<Void>) action) {
  if (!Platform.isWindows ||
      path.contains('\u0000') ||
      !File(path).isAbsolute) {
    return null;
  }
  if (!File(path).existsSync()) return null;
  final initialized = _shell.coInitializeEx(nullptr, 2); // apartment threaded
  // RPC_E_CHANGED_MODE means this thread already has a different COM apartment.
  if (initialized < 0 && initialized != -2147417850) return null;
  final name = path.toNativeUtf16();
  final item = calloc<Pointer<Void>>();
  try {
    if (_shell.parseDisplayName(name, nullptr, item, 0, nullptr) < 0 ||
        item.value == nullptr) {
      return null;
    }
    return action(item.value);
  } finally {
    if (item.value != nullptr) _shell.coTaskMemFree(item.value);
    calloc.free(item);
    calloc.free(name);
    if (initialized >= 0) _shell.coUninitialize();
  }
}

final _shell = _WindowsShell();

class _WindowsShell {
  final _shell32 = DynamicLibrary.open('shell32.dll');
  final _ole32 = DynamicLibrary.open('ole32.dll');

  late final coInitializeEx = _ole32
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int)
      >('CoInitializeEx');
  late final coUninitialize = _ole32
      .lookupFunction<Void Function(), void Function()>('CoUninitialize');
  late final coTaskMemFree = _ole32
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('CoTaskMemFree');
  late final parseDisplayName = _shell32
      .lookupFunction<
        Int32 Function(
          Pointer<Utf16>,
          Pointer<Void>,
          Pointer<Pointer<Void>>,
          Uint32,
          Pointer<Uint32>,
        ),
        int Function(
          Pointer<Utf16>,
          Pointer<Void>,
          Pointer<Pointer<Void>>,
          int,
          Pointer<Uint32>,
        )
      >('SHParseDisplayName');
  late final openFolderAndSelectItems = _shell32
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Pointer<Void>>, Uint32),
        int Function(Pointer<Void>, int, Pointer<Pointer<Void>>, int)
      >('SHOpenFolderAndSelectItems');
}
