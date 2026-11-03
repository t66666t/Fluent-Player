import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/services/video_compose/video_compose_artifact_cleaner.dart';

void main() {
  for (final mobile in [false, true]) {
    test(
      '${mobile ? 'mobile' : 'platform'} output cleanup refuses a same-name directory',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'compose-output-owner-',
        );
        addTearDown(() => root.delete(recursive: true));
        // An encoder cannot publish a file over this pre-existing directory.
        // Removing its failed task must not turn that failure into recursive loss.
        final collision = Directory(
          p.join(root.path, 'video_compose_12345.mp4'),
        );
        await collision.create();
        final original = File(p.join(collision.path, 'original.txt'));
        await original.writeAsString('existing user data', flush: true);
        final cleaner = VideoComposeArtifactCleaner();
        final deleted = mobile
            ? await cleaner.deleteMobileComposeOutputs(collision.path)
            : await cleaner.deleteOutputFileByPlatform(collision.path);
        expect(
          deleted,
          isFalse,
          reason: 'A directory is not this task’s output file',
        );
        expect(await original.exists(), isTrue);
        expect(await original.readAsString(), 'existing user data');
      },
    );

    test(
      '${mobile ? 'mobile' : 'platform'} output cleanup still deletes an ordinary file',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'compose-output-file-',
        );
        addTearDown(() => root.delete(recursive: true));
        final output = File(p.join(root.path, 'video_compose_12345.mp4'));
        final unrelated = File(p.join(root.path, 'video_compose_54321.mp4'));
        await output.writeAsString('created output');
        await unrelated.writeAsString('other task');
        final cleaner = VideoComposeArtifactCleaner();
        expect(
          mobile
              ? await cleaner.deleteMobileComposeOutputs(output.path)
              : await cleaner.deleteOutputFileByPlatform(output.path),
          isTrue,
        );
        expect(await output.exists(), isFalse);
        expect(await unrelated.readAsString(), 'other task');
      },
    );

    test(
      '${mobile ? 'mobile' : 'platform'} output cleanup does not follow a directory link',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'compose-output-link-',
        );
        addTearDown(() => root.delete(recursive: true));
        final originalDirectory = Directory(p.join(root.path, 'original'));
        await originalDirectory.create();
        final original = File(p.join(originalDirectory.path, 'original.txt'));
        await original.writeAsString('existing user data');
        final output = Link(p.join(root.path, 'video_compose_12345.mp4'));
        try {
          await output.create(originalDirectory.path);
        } on FileSystemException catch (error) {
          if (Platform.isWindows && error.osError?.errorCode == 1314) {
            markTestSkipped(
              'Windows does not permit this process to create links',
            );
            return;
          }
          rethrow;
        }
        final cleaner = VideoComposeArtifactCleaner();
        expect(
          mobile
              ? await cleaner.deleteMobileComposeOutputs(output.path)
              : await cleaner.deleteOutputFileByPlatform(output.path),
          isFalse,
        );
        expect(await output.exists(), isTrue);
        expect(await original.readAsString(), 'existing user data');
      },
    );
  }

  test(
    'explicitly tracked staging directories retain recursive cleanup',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'compose-owned-staging-',
      );
      addTearDown(() => root.delete(recursive: true));
      final staging = Directory(p.join(root.path, '.compose_owned'));
      await staging.create();
      await File(
        p.join(staging.path, 'encoded.mp4'),
      ).writeAsString('incomplete output');
      final cleaner = VideoComposeArtifactCleaner()
        ..trackTaskArtifact('job', staging.path);
      expect(await cleaner.cleanupTaskArtifacts('job'), isTrue);
      expect(await staging.exists(), isFalse);
    },
  );
}
