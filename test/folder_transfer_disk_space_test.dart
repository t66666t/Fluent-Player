import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/progress_sync/folder_transfer_disk_space.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('POSIX df parser uses available blocks rather than total or used', () {
    const linux = '''Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/sda1 104857600 41943040 62914560 40% /home
''';
    expect(parseDfAvailableBytes(linux), 62914560 * 1024);
    const mac = '''Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/disk3s1 1000000000 350000000 650000000 35% /System/Volumes/Data
''';
    expect(parseDfAvailableBytes(mac), 650000000 * 1024);
  });

  test('df parser supports spaced mount names and 64-bit capacity', () {
    const output = '''Filesystem 1024-blocks Used Available Capacity Mounted on
server:/shared media 10000000000 1000000000 9000000000 10% /media/My Videos
''';
    expect(parseDfAvailableBytes(output), 9216000000000);
  });

  test(
    'full and over-quota volumes report zero, malformed output stays unknown',
    () {
      expect(parseDfAvailableBytes('/dev/full 100 100 0 100% /'), 0);
      expect(parseDfAvailableBytes('/dev/quota 100 110 -10 110% /'), 0);
      for (final text in [
        '',
        'df: permission denied',
        'Filesystem Used Available',
        '/dev/a 100 invalid 50 50% /',
        '/dev/a 100 50 nan 50% /',
      ]) {
        expect(parseDfAvailableBytes(text), isNull);
      }
    },
  );

  test(
    'current Windows volume reports a real 64-bit available value',
    () async {
      if (!Platform.isWindows) return;
      final free = await availableBytes(Directory.current);
      expect(free, isNotNull);
      expect(free, greaterThan(0));
      expect(free, lessThan(0x7fffffffffffffff));
    },
  );

  test(
    'uncreated destination uses an existing ancestor without creating files',
    () async {
      final path = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}fluent-not-created-${DateTime.now().microsecondsSinceEpoch}${Platform.pathSeparator}nested',
      );
      expect(await path.exists(), isFalse);
      final free = await availableBytes(path);
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        expect(free, isNotNull);
        expect(free, greaterThanOrEqualTo(0));
      }
      expect(await path.exists(), isFalse);
    },
  );

  test('Windows UTF-16 directory names are queried successfully', () async {
    if (!Platform.isWindows) return;
    final directory = await Directory.systemTemp.createTemp('空间预检_');
    try {
      expect(await availableBytes(directory), greaterThanOrEqualTo(0));
    } finally {
      await directory.delete();
    }
  });

  test('invalid paths are unknown rather than blocking reception', () async {
    expect(await availableBytes(Directory('invalid\u0000path')), isNull);
  });
}
