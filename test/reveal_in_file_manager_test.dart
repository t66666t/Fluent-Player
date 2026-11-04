import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/reveal_in_file_manager.dart';

void main() {
  test(
    'source reveal rejects a missing file and directory without opening a fallback',
    () async {
      final root = await Directory.systemTemp.createTemp('strict_reveal_');
      addTearDown(() => root.delete(recursive: true));
      expect(
        await revealInFileManager(
          '${root.path}/gone.mp4',
          requireExistingFile: true,
        ),
        isFalse,
      );
      expect(
        await revealInFileManager(root.path, requireExistingFile: true),
        isFalse,
      );
      expect(await revealInFileManager('', requireExistingFile: true), isFalse);
      expect(
        await revealInFileManager(
          '${root.path}\u0000wrong.mp4',
          requireExistingFile: true,
        ),
        isFalse,
      );
    },
  );

  test('Linux URI preserves the exact filename after DBus array encoding', () {
    const path = '/media/中文 #100% %20, "quote" & [a];\nclip.mp4 ';
    final args = linuxDbusShowItemsArguments(linuxFileManagerItemUri(path));
    final uri = args
        .singleWhere((arg) => arg.startsWith('array:string:'))
        .substring('array:string:'.length);
    expect(uri, isNot(contains(',')));
    expect(Uri.parse(uri).toFilePath(windows: false), path);
  });

  test('Linux FileManager URI percent-encodes spaces', () {
    final String uri = linuxFileManagerItemUri('/home/user/My Videos/clip.mp4');
    expect(uri, startsWith('file://'));
    expect(uri, contains('My%20Videos'));
    expect(uri, isNot(contains(' ')));
  });

  test('Linux dbus ShowItems args keep URI as one array:string token', () {
    final String uri = linuxFileManagerItemUri('/tmp/a b,c.mp4');
    final List<String> args = linuxDbusShowItemsArguments(uri);
    expect(args, contains('org.freedesktop.FileManager1.ShowItems'));
    expect(args, contains('--print-reply'));
    expect(args, contains('--reply-timeout=2000'));
    final String arrayArg = args.firstWhere(
      (a) => a.startsWith('array:string:'),
    );
    // Comma in the path must not create a second array element.
    expect(arrayArg.split(',').length, 1);
    expect(arrayArg, contains('%2C'));
    expect(args.last, 'string:');
  });

  test('reveal fallback directory prefers parent of an existing file', () {
    expect(
      revealFallbackDirectoryPath(
        normalizedPath: '/videos/en/clip.mp4',
        fileExists: true,
        directoryExists: false,
      ),
      '/videos/en',
    );
    expect(
      revealFallbackDirectoryPath(
        normalizedPath: '/videos/en',
        fileExists: false,
        directoryExists: true,
      ),
      '/videos/en',
    );
    expect(
      revealFallbackDirectoryPath(
        normalizedPath: '/videos/en/missing.mp4',
        fileExists: false,
        directoryExists: false,
      ),
      '/videos/en',
    );
  });
}
