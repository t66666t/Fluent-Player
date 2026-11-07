import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/video_compose/video_compose_artifact_cleaner.dart';
import 'package:video_player_app/services/video_compose/video_compose_output_path_service.dart';
import 'package:video_player_app/services/video_compose_manager.dart';

import 'support/compose_queue_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'rapid outputs with the same title have distinct cleanup identities',
    () {
      const paths = VideoComposeOutputPathService();
      final names = List.generate(
        5000,
        (_) => paths.buildOutputFileName('测试 视频'),
      );
      expect(names.toSet(), hasLength(names.length));
      final pattern = VideoComposeArtifactCleaner().buildComposeOutputPattern(
        names.first,
      );
      expect(pattern, isNotNull);
      expect(pattern!.hasMatch(names.first), isTrue);
      expect(pattern.hasMatch(names.last), isFalse);
    },
  );

  test(
    'concurrent jobs for one media retain distinct task IDs and output paths',
    () async {
      final runner = ControlledComposeOrchestrator();
      final manager = VideoComposeManager(
        taskStore: MemoryComposeStore(),
        artifactCleaner: RecordingComposeCleaner(),
        orchestrator: runner,
      );
      await manager.ready;
      final tasks = await Future.wait(
        List.generate(30, (_) => enqueueCompose(manager, 'same')),
      );
      expect(tasks.map((task) => task.taskId).toSet(), hasLength(tasks.length));
      expect(
        tasks.map((task) => task.request.outputPath).toSet(),
        hasLength(tasks.length),
      );
      expect(manager.allTasks, hasLength(tasks.length));
      final clearing = manager.clearTasksAndFiles(deleteOutput: false);
      await Future<void>.delayed(Duration.zero);
      runner.running[runner.started.first]!.complete();
      await clearing;
      manager.dispose();
    },
  );
}
