import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/models/video_compose_models.dart';
import 'package:video_player_app/services/video_compose/video_compose_task_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File file;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('compose store ');
    file = File('${root.path}/compose_tasks.json');
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'parallel saves and reads across instances keep complete ordered snapshots',
    () async {
      final first = VideoComposeTaskStore(taskFile: file);
      final second = VideoComposeTaskStore(taskFile: file);
      final pending = <Future<void>>[];
      final tasks = <VideoComposeTaskState>[];
      for (var i = 0; i < 40; i++) {
        tasks.add(_task(i));
        pending.add((i.isEven ? first : second).saveTasks(tasks));
        pending.add(
          first.loadTasks().then((loaded) {
            expect(loaded.length, i + 1);
            expect(loaded.last.taskId, '$i');
          }),
        );
      }
      tasks.clear(); // Deferred IO must not retain a mutable caller collection.
      await Future.wait(pending);
      expect(await first.loadTasks(), hasLength(40));
      final backup =
          jsonDecode(await File('${file.path}.bak').readAsString()) as List;
      expect(backup, hasLength(39));
      expect(await File('${file.path}.next').exists(), isFalse);
    },
  );

  test('corrupt current generation recovers the preserved backup', () async {
    final store = VideoComposeTaskStore(taskFile: file);
    await store.saveTasks([_task(0)]);
    await store.saveTasks([_task(1)]);
    await file.writeAsString('interrupted');
    expect((await store.loadTasks()).single.taskId, '0');
    await store.saveTasks([_task(2)]);
    expect((await store.loadTasks()).single.taskId, '2');
    final backup =
        jsonDecode(await File('${file.path}.bak').readAsString()) as List;
    expect((backup.single as Map)['taskId'], '0');
  });

  test(
    'Windows sharing violation retries after an external reader releases the file',
    () async {
      final store = VideoComposeTaskStore(taskFile: file);
      await store.saveTasks([_task(0)]);
      final locker = await Process.start(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          r'''
$stream = [System.IO.File]::Open($env:COMPOSE_STORE_LOCK_PATH,
  [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
  [System.IO.FileShare]::ReadWrite)
[Console]::WriteLine('locked')
Start-Sleep -Milliseconds 350
$stream.Dispose()
''',
        ],
        environment: {'COMPOSE_STORE_LOCK_PATH': file.path},
      );
      final errors = locker.stderr.transform(utf8.decoder).join();
      try {
        expect(
          await locker.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first,
          'locked',
        );
        final saving = store.saveTasks([_task(1)]);
        await Future<void>.delayed(const Duration(milliseconds: 140));
        // An open reader disallows replacement; the previous valid file survives.
        expect(
          (jsonDecode(await file.readAsString()) as List).single['taskId'],
          '0',
        );
        expect(await locker.exitCode, 0, reason: await errors);
        await saving;
        expect((await store.loadTasks()).single.taskId, '1');
        expect(await File('${file.path}.next').exists(), isFalse);
      } finally {
        locker.kill();
      }
    },
    skip: !Platform.isWindows,
  );
}

VideoComposeTaskState _task(int id) => VideoComposeTaskState(
  taskId: '$id',
  createdAt: DateTime(2026),
  stage: VideoComposeStage.queued,
  progress: 0,
  message: 'queued',
  request: VideoComposeRequest(
    videoId: '$id',
    videoPath: 'input.mp4',
    title: 'test',
    renderSecondarySubtitle: false,
    continuousSubtitle: false,
    embedSoftSubtitles: false,
    softSubtitleOnly: false,
    softSubtitleUseSourceQuality: true,
    softSubtitleTracks: [],
    resolution: VideoComposeResolution.source,
    subtitleStyle: const SubtitleStyle(),
    subtitleAlignment: Alignment.bottomCenter,
    outputPath: 'output.mp4',
  ),
);
