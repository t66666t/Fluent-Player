import 'dart:io';

/// Junctions need no elevation on Windows; Unix uses a directory symlink.
Future<void> createStorageDirectoryAlias(String alias, String target) async {
  if (!Platform.isWindows) {
    await Link(alias).create(target);
    return;
  }
  final result = await Process.run('cmd.exe', [
    '/d',
    '/c',
    'mklink',
    '/J',
    alias,
    target,
  ]);
  if (result.exitCode != 0) {
    throw FileSystemException(
      'Cannot create test junction: ${result.stderr}',
      alias,
    );
  }
}
