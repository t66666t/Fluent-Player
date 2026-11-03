import 'dart:io';

/// Removes a test's temp directory. On Windows a file handle released a
/// moment earlier can still block the delete (errno 32), so it is retried a
/// few times; a directory that still cannot be removed is left to the system
/// temp cleanup rather than failing the run.
Future<void> deleteTestTempDir(Directory dir) async {
  const attempts = 5;
  for (var attempt = 1; attempt <= attempts; attempt++) {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
      return;
    } on FileSystemException {
      if (attempt == attempts) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
}
