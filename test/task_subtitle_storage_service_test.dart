import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/services/task_subtitle_storage_service.dart';

void main() {
  group('TaskSubtitleStorageService', () {
    late Directory root;
    late TaskSubtitleStorageService storage;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('task_subtitle_storage_');
      storage = TaskSubtitleStorageService(dataRootOverride: root);
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test('readable subtitle names keep the label and separate duplicates', () {
      final first = TaskSubtitleStorageService.readableSubtitleFileName(
        label: '中文(简体) (自动)',
        extension: 'srt',
        uniqueId: 'abcd1234ef',
      );
      final second = TaskSubtitleStorageService.readableSubtitleFileName(
        label: '中文(简体) (自动)',
        extension: '.srt',
        uniqueId: '9999aaaa',
      );
      expect(first, '中文(简体) (自动).abcd1234.srt');
      expect(second, '中文(简体) (自动).9999aaaa.srt');
      expect(
        TaskSubtitleStorageService.readableSubtitleFileName(
          label: 'a/b:c',
          extension: '.ass',
          uniqueId: '1234abcd',
        ),
        'a b c.1234abcd.ass',
      );

      final bound = bindSubtitleLabels(const <({String label, String path})>[
        (label: '中文', path: r'C:\tasks\中文.aaaa1111.srt'),
        (label: '中文', path: r'C:\tasks\中文.bbbb2222.srt'),
      ]);
      expect(bound.map((entry) => entry.displayName), <String>['中文', '中文']);
      expect(bound[0].storageKey, '中文');
      expect(bound[1].storageKey, isNot('中文'));
      expect(bound[0].path, isNot(bound[1].path));
    });

    test('isolates files by media card id', () async {
      final taskAPath = await storage.allocatePath('task-a', 'translated.srt');
      final taskBPath = await storage.allocatePath('task-b', 'translated.srt');
      await File(taskAPath).writeAsString('A');
      await File(taskBPath).writeAsString('B');
      final sidecar = File(p.join(root.path, 'movie.srt'));
      await sidecar.writeAsString('shared');

      expect(
        p.normalize(taskAPath),
        p.normalize(
          p.join(root.path, 'subtitles', 'tasks', 'task-a', 'translated.srt'),
        ),
      );
      expect(await storage.isTaskOwnedPath(taskAPath, 'task-a'), isTrue);
      expect(await storage.isTaskOwnedPath(taskAPath, 'task-b'), isFalse);

      await storage.deleteTaskDirectory('task-a');

      expect(await File(taskAPath).exists(), isFalse);
      expect(await File(taskBPath).exists(), isTrue);
      expect(await sidecar.exists(), isTrue);
    });

    test('keeps one hundred cards for the same media fully isolated', () async {
      final sidecar = File(p.join(root.path, 'same-video.srt'));
      await sidecar.writeAsString('companion');
      final taskPaths = <String>[];
      for (var index = 0; index < 100; index++) {
        final path = await storage.allocatePath('card-$index', 'ai.srt');
        await File(path).writeAsString('task $index');
        taskPaths.add(path);
      }

      for (var index = 0; index < 100; index++) {
        final files = await storage.listTaskSubtitles('card-$index');
        expect(files.map((file) => file.path), <String>[taskPaths[index]]);
      }
      expect(await sidecar.exists(), isTrue);
    });

    test(
      'allocates collision-free names and enumerates supported files',
      () async {
        final first = await storage.allocatePath('task-1', 'manual.srt');
        await File(first).writeAsString('first');
        final second = await storage.allocatePath('task-1', 'manual.srt');
        await File(second).writeAsString('second');
        final directory = await storage.taskDirectory('task-1');
        await File(
          p.join(directory.path, 'notes.txt'),
        ).writeAsString('ignored');

        expect(p.basename(second), 'manual.2.srt');
        expect(
          (await storage.listTaskSubtitles('task-1')).map((file) => file.path),
          containsAll(<String>[first, second]),
        );
        expect(await storage.taskDirectorySize('task-1'), 18);
      },
    );

    test(
      'copy stays inside task directory even with traversal-like name',
      () async {
        final source = File(p.join(root.path, 'source.ass'));
        await source.writeAsString('subtitle');

        final copied = await storage.copyIntoTask(
          'safe-task',
          source.path,
          preferredFileName: '../../outside.ass',
        );
        final taskDirectory = await storage.taskDirectory('safe-task');

        expect(p.isWithin(taskDirectory.path, copied), isTrue);
        expect(p.basename(copied), 'outside.ass');
        expect(await File(copied).readAsString(), 'subtitle');
      },
    );

    test('rejects invalid task ids and unsupported output formats', () async {
      expect(() => storage.taskDirectory('../escape'), throwsArgumentError);
      expect(
        () => storage.allocatePath('task-1', 'subtitle.exe'),
        throwsArgumentError,
      );
    });
  });
}
