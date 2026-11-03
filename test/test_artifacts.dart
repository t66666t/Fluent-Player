import 'dart:io';

/// Each test process gets its own output directory so image previews from a
/// previous run can stay open on Windows without blocking the next run.
final Directory testArtifactDirectory = Directory(
  Platform.environment['FLUENT_TEST_ARTIFACT_DIR'] ?? '.artifacts/test-runs',
)..createSync(recursive: true);

final Directory _runDirectory = testArtifactDirectory.createTempSync('run-');

File testArtifact(String name) {
  final file = File('${_runDirectory.path}/$name');
  file.parent.createSync(recursive: true);
  return file;
}
