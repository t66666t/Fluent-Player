import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

void main() {
  final path =
      '${Directory.current.path}\\native\\subtitle_archive\\prebuilt\\windows-x64\\subtitle_unrar.dll';
  stdout.writeln('exists=${File(path).existsSync()} path=$path');
  try {
    final library = DynamicLibrary.open(path);
    final version = library
        .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
          'sub_unrar_version',
        )()
        .toDartString();
    stdout.writeln('version=$version');
  } catch (error, stack) {
    stdout.writeln('OPEN FAILED $error');
    stdout.writeln(stack);
  }
}
