import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/utils/windows_file_manager.dart';

void main() {
  test(
    'Windows Shell resolves special filenames to the exact existing file',
    () async {
      final root = await Directory.systemTemp.createTemp('source_shell_');
      addTearDown(() => root.delete(recursive: true));
      final getPath = DynamicLibrary.open('shell32.dll')
          .lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Utf16>, Uint32, Uint32),
            int Function(Pointer<Void>, Pointer<Utf16>, int, int)
          >('SHGetPathFromIDListEx');
      for (final name in [
        '中文 空格, #100% %20 & [a] (1).mp4',
        '%TEMP% ,;= 测试.mp3',
        '文件😀 #.mkv',
      ]) {
        final file = await File(
          p.join(root.path, name),
        ).writeAsString('source');
        final resolved = withWindowsShellItem(file.path, (item) {
          final buffer = calloc<Uint16>(32768).cast<Utf16>();
          try {
            expect(getPath(item, buffer, 32768, 0), isNot(0));
            return buffer.toDartString();
          } finally {
            calloc.free(buffer);
          }
        });
        expect(resolved, file.path);
      }
      expect(
        withWindowsShellItem(p.join(root.path, 'missing.mp4'), (_) => true),
        isNull,
      );
      expect(
        withWindowsShellItem('${root.path}\u0000wrong.mp4', (_) => true),
        isNull,
      );
      expect(withWindowsShellItem('relative.mp4', (_) => true), isNull);
    },
    skip: !Platform.isWindows,
  );
}
