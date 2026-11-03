import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Extract-only binding to the bundled UnRAR 7.13 bridge.
///
/// The library is optional at runtime. Callers must keep working, with an
/// explicit unsupported-format error, when this process has no bridge.
class SubtitleUnrar {
  SubtitleUnrar._(DynamicLibrary library)
    : version = library
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'sub_unrar_version',
          )()
          .toDartString(),
      _open = library.lookupFunction<
        Pointer<Void> Function(Pointer<Utf16>, Pointer<Utf16>, Uint64, Pointer<Int32>),
        Pointer<Void> Function(Pointer<Utf16>, Pointer<Utf16>, int, Pointer<Int32>)
      >('sub_unrar_open'),
      _cancel = library.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
        'sub_unrar_cancel',
      ),
      _message = library.lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Utf16>, Int32),
        int Function(Pointer<Void>, Pointer<Utf16>, int)
      >('sub_unrar_message'),
      _next = library.lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<SubEntryView>),
        int Function(Pointer<Void>, Pointer<SubEntryView>)
      >('sub_unrar_next'),
      _skip = library.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
        'sub_unrar_skip',
      ),
      _extract = library.lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Utf16>, Pointer<Utf16>),
        int Function(Pointer<Void>, Pointer<Utf16>, Pointer<Utf16>)
      >('sub_unrar_extract'),
      _close = library.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
        'sub_unrar_close',
      );

  static SubtitleUnrar? _cached;
  static var _unavailable = false;
  final String version;
  final Pointer<Void> Function(Pointer<Utf16>, Pointer<Utf16>, int, Pointer<Int32>) _open;
  final void Function(Pointer<Void>) _cancel;
  final int Function(Pointer<Void>, Pointer<Utf16>, int) _message;
  final int Function(Pointer<Void>, Pointer<SubEntryView>) _next;
  final int Function(Pointer<Void>) _skip;
  final int Function(Pointer<Void>, Pointer<Utf16>, Pointer<Utf16>) _extract;
  final void Function(Pointer<Void>) _close;

  static const end = 10;
  static const badData = 12;
  static const badArchive = 13;
  static const unknownFormat = 14;
  static const missingPassword = 22;
  static const badPassword = 24;
  static const largeDict = 25;
  static const missingVolume = 30;
  static const cancelled = 31;
  static const limit = 33;

  static SubtitleUnrar? tryLoad() {
    if (_cached != null) return _cached;
    if (_unavailable) return null;
    final path = locateLibrary();
    if (path == null) {
      _unavailable = true;
      return null;
    }
    try {
      return _cached = SubtitleUnrar._(DynamicLibrary.open(path));
    } catch (_) {
      _unavailable = true;
      return null;
    }
  }

  static String? locateTool() {
    const names = ['subtitle_unrar_tool.exe'];
    final candidates = <String>[
      for (final name in names) ...[
        '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}$name',
        '${Directory.current.path}${Platform.pathSeparator}native${Platform.pathSeparator}subtitle_archive${Platform.pathSeparator}prebuilt${Platform.pathSeparator}windows-x64${Platform.pathSeparator}$name',
      ],
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  static String? locateLibrary() {
    final override = Platform.environment['SUBTITLE_UNRAR_DLL'];
    final names = Platform.isWindows
        ? const ['subtitle_unrar.dll']
        : Platform.isMacOS
        ? const ['libsubtitle_unrar.dylib', 'subtitle_unrar.dylib']
        : const ['libsubtitle_unrar.so'];
    final candidates = <String>[
      if (override != null && override.isNotEmpty) override,
      for (final name in names) ...[
        '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}$name',
        '${Directory.current.path}${Platform.pathSeparator}native${Platform.pathSeparator}subtitle_archive${Platform.pathSeparator}prebuilt${Platform.pathSeparator}windows-x64${Platform.pathSeparator}$name',
      ],
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  UnrarSession open(String path, {String password = '', int dictLimitBytes = 0}) {
    final nativePath = path.toNativeUtf16();
    final nativePassword = password.toNativeUtf16();
    final error = calloc<Int32>();
    try {
      final handle = _open(nativePath, nativePassword, dictLimitBytes, error);
      if (handle == nullptr) {
        throw UnrarException(error.value, '');
      }
      return UnrarSession._(this, handle);
    } finally {
      calloc.free(nativePath);
      calloc.free(nativePassword);
      calloc.free(error);
    }
  }
}

final class SubEntryView extends Struct {
  @Uint32()
  external int flags;
  @Uint32()
  external int method;
  @Uint32()
  external int dictKib;
  @Uint32()
  external int crc32;
  @Uint32()
  external int unpackedLow;
  @Uint32()
  external int unpackedHigh;
  @Uint32()
  external int packedLow;
  @Uint32()
  external int packedHigh;
  @Uint32()
  external int attributes;
  @Uint32()
  external int nameBytes;
  @Array(2048)
  external Array<Uint8> nameUtf8;
}

class UnrarEntry {
  const UnrarEntry({
    required this.name,
    required this.flags,
    required this.method,
    required this.dictKib,
    required this.crc32,
    required this.unpacked,
    required this.packed,
  });

  final String name;
  final int flags;
  final int method;
  final int dictKib;
  final int crc32;
  final int unpacked;
  final int packed;
  bool get isDirectory => flags & 1 != 0;
  bool get encrypted => flags & 2 != 0;
  bool get solid => flags & 4 != 0;
  bool get link => flags & 8 != 0;
  bool get splitAfter => flags & 32 != 0;
}

class UnrarException implements Exception {
  const UnrarException(this.code, this.detail);
  final int code;
  final String detail;
  @override
  String toString() => 'UnRAR $code $detail';
}

class UnrarSession {
  UnrarSession._(this._library, this._handle);
  final SubtitleUnrar _library;
  final Pointer<Void> _handle;
  var _closed = false;
  int get address => _handle.address;

  void cancel() {
    if (!_closed) _library._cancel(_handle);
  }

  String message() {
    if (_closed) return '';
    final buffer = calloc<Uint16>(512);
    try {
      _library._message(_handle, buffer.cast(), 512);
      return buffer.cast<Utf16>().toDartString();
    } finally {
      calloc.free(buffer);
    }
  }

  /// Reads the next header. The header stays pending until [skip] or [extract].
  UnrarEntry? next() {
    final view = calloc<SubEntryView>();
    try {
      final code = _library._next(_handle, view);
      if (code == SubtitleUnrar.end) return null;
      if (code != 0) throw UnrarException(code, message());
      final name = utf8Name(view.ref);
      final unpacked = view.ref.unpackedLow.toUnsigned(32) |
          (view.ref.unpackedHigh.toUnsigned(32) << 32);
      final packed = view.ref.packedLow.toUnsigned(32) |
          (view.ref.packedHigh.toUnsigned(32) << 32);
      return UnrarEntry(
        name: name,
        flags: view.ref.flags,
        method: view.ref.method,
        dictKib: view.ref.dictKib,
        crc32: view.ref.crc32,
        unpacked: unpacked,
        packed: packed,
      );
    } finally {
      calloc.free(view);
    }
  }

  void skip() {
    final code = _library._skip(_handle);
    if (code != 0) throw UnrarException(code, message());
  }

  void extract(String directory, String fileName) {
    final nativeDirectory = directory.toNativeUtf16();
    final nativeName = fileName.toNativeUtf16();
    try {
      final code = _library._extract(_handle, nativeDirectory, nativeName);
      if (code != 0) throw UnrarException(code, message());
    } finally {
      calloc.free(nativeDirectory);
      calloc.free(nativeName);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _library._close(_handle);
  }

  static String utf8Name(SubEntryView view) {
    final bytes = <int>[];
    final count = view.nameBytes.clamp(0, 2047);
    for (var i = 0; i < count; i++) {
      bytes.add(view.nameUtf8[i]);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }
}
