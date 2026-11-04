import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/models/transcription_status.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/transcription_manager.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

/// Hold at configuration capture, before any inference or network request.
/// Tests can exercise scheduling and cancellation without real media/models.
class _GatedCenter extends ModelCenterService {
  final captures = <Completer<ModelJobSpec>>[];
  @override
  bool get started => true;
  @override
  Future<ModelJobSpec> captureTranscription() {
    final capture = Completer<ModelJobSpec>();
    captures.add(capture);
    return capture.future;
  }

  void release() {
    for (final capture in captures) {
      if (!capture.isCompleted) {
        capture.complete(
          const ModelJobSpec(profile: ModelCenterService.legacyProfile),
        );
      }
    }
  }
}

Future<void> _until(bool Function() condition) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 5)) {
      fail('queue did not settle');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform oldPaths;
  late _GatedCenter center;
  late TranscriptionManager manager;
  final settings = SettingsService();

  setUp(() async {
    root = await Directory.systemTemp.createTemp('queue-scheduling-');
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    SharedPreferences.setMockInitialValues({'batchSubtitleAutoDelete': false});
    settings.resetForTest();
    await settings.init();
    center = _GatedCenter();
    manager = TranscriptionManager(settings: settings, modelCenter: center);
    await manager.initialize();
  });

  tearDown(() async {
    manager.pauseAllTasks();
    center.release();
    await _until(() => !manager.isQueueRunning);
    await manager.shutdown();
    manager.dispose();
    center.dispose();
    settings.resetForTest();
    PathProviderPlatform.instance = oldPaths;
    await root.delete(recursive: true);
  });

  Future<TranscriptionEnqueueResult> add(
    String id, {
    bool start = false,
    TranscriptTranslateChoice? translate,
  }) => manager.startTranscription(
    p.join(root.path, '$id.m4a'),
    videoId: id,
    autoStart: start,
    translateChoice: translate,
  );

  List<String> keys() =>
      manager.getQueueSnapshot().map((task) => task.mediaKey).toList();

  for (final translate in [false, true]) {
    test(
      'media-page start takes priority over unstarted tasks: $translate',
      () async {
        await add('old-a');
        await add('old-b');
        await add(
          'current',
          start: true,
          translate: translate
              ? const TranscriptTranslateChoice.automatic()
              : const TranscriptTranslateChoice.off(),
        );
        expect(keys(), ['id:current', 'id:old-a', 'id:old-b']);
        expect(manager.currentVideoId, 'current');
        expect(center.captures, hasLength(1));
        expect(
          manager.translateEnabledForVideo(
            p.join(root.path, 'current.m4a'),
            videoId: 'current',
          ),
          translate,
        );

        await add('next', start: true);
        expect(keys(), ['id:current', 'id:next', 'id:old-a', 'id:old-b']);
        expect(center.captures, hasLength(1), reason: 'one worker at a time');
        final next = manager.getQueueSnapshot()[1];
        expect(next.statusMessage, '已加入队列，当前顺位：2');
        expect(
          manager.queuePositionForVideo(next.videoPath, videoId: 'next'),
          2,
        );
        expect(
          manager
              .taskSnapshotForVideo(next.videoPath, videoId: 'next')!
              .statusMessage,
          next.statusMessage,
        );
        expect(
          await add('next', start: true),
          TranscriptionEnqueueResult.alreadyQueued,
        );

        expect(manager.pauseTask('id:current'), isTrue);
        center.release();
        await _until(() => manager.currentVideoId == 'next');
        expect(keys(), ['id:next', 'id:old-a', 'id:old-b', 'id:current']);
        expect(
          manager.isVideoPaused(
            p.join(root.path, 'current.m4a'),
            videoId: 'current',
          ),
          isTrue,
        );
        expect(center.captures, hasLength(2));
      },
    );
  }

  test('reordering both waiting groups agrees with actual execution', () async {
    await add('active', start: true);
    for (final id in ['paused-a', 'ready-a', 'paused-b', 'ready-b']) {
      await add(id);
    }
    manager.startTask('id:ready-a');
    manager.startTask('id:ready-b');
    expect(keys(), [
      'id:active',
      'id:ready-a',
      'id:ready-b',
      'id:paused-a',
      'id:paused-b',
    ]);
    expect(manager.reorderTask('id:ready-b', 0), isTrue);
    expect(manager.reorderTask('id:paused-b', 2), isTrue);
    expect(keys(), [
      'id:active',
      'id:ready-b',
      'id:ready-a',
      'id:paused-b',
      'id:paused-a',
    ]);
    // Crossing a group boundary cannot put paused work ahead of runnable work.
    expect(manager.reorderTask('id:paused-a', 0), isTrue);
    expect(keys(), [
      'id:active',
      'id:ready-b',
      'id:ready-a',
      'id:paused-a',
      'id:paused-b',
    ]);
    expect(manager.reorderTask('id:active', 0), isFalse);
    expect(manager.reorderTask('missing', 0), isFalse);
    expect(manager.reorderTask('id:ready-a', 4), isFalse);

    manager.pauseTask('id:active');
    center.release();
    await _until(() => manager.currentVideoId == 'ready-b');
    expect(manager.getQueueSnapshot()[1].statusMessage, '已加入队列，当前顺位：2');
    manager.pauseTask('id:ready-b');
    center.release();
    await _until(() => manager.currentVideoId == 'ready-a');
    manager.pauseTask('id:ready-a');
    center.release();
    await _until(() => !manager.isQueueRunning);
    expect(center.captures, hasLength(3));

    final beforeRestart = keys();
    await manager.shutdown();
    manager.dispose();
    manager = TranscriptionManager(settings: settings, modelCenter: center);
    await manager.initialize();
    expect(keys(), beforeRestart);
    expect(manager.canPauseAll, isFalse);
    expect(manager.getQueueSnapshot().every((task) => !task.isStarted), isTrue);
  });

  test(
    'removing the active task reserves its identity until the worker stops',
    () async {
      await add('active', start: true);
      await add('next', start: true);
      expect(manager.removeFromQueue('id:active'), isTrue);
      expect(keys(), ['id:next']);
      expect(
        await add('active', start: true),
        TranscriptionEnqueueResult.alreadyQueued,
      );
      center.release();
      await _until(() => manager.currentVideoId == 'next');
      expect(await add('active'), TranscriptionEnqueueResult.added);
      expect(keys(), ['id:next', 'id:active']);
    },
  );

  test(
    'failure keeps pause-all actionable until scheduled work is stopped',
    () async {
      await add('first', start: true);
      await add('next', start: true);
      bool? canPauseAtFailure;
      Future<TranscriptionEnqueueResult>? duplicate;
      manager.addListener(() {
        if (manager.status != TranscriptionStatus.error ||
            canPauseAtFailure != null) {
          return;
        }
        canPauseAtFailure = manager.canPauseAll;
        duplicate = add('first', start: true);
        manager.pauseAllTasks();
      });
      center.captures.single.completeError(
        StateError('test configuration failure'),
      );
      await _until(() => !manager.isQueueRunning);
      expect(canPauseAtFailure, isTrue);
      expect(await duplicate, TranscriptionEnqueueResult.alreadyQueued);
      expect(center.captures, hasLength(1));
      expect(
        manager.isVideoFailed(p.join(root.path, 'first.m4a'), videoId: 'first'),
        isTrue,
      );
      expect(
        manager.isVideoPaused(p.join(root.path, 'next.m4a'), videoId: 'next'),
        isTrue,
      );
      expect(manager.canPauseAll, isFalse);
      await manager.shutdown();
      final saved =
          jsonDecode(
                await File(
                  p.join(root.path, 'transcription_queue_cache.json'),
                ).readAsString(),
              )
              as Map;
      expect(saved['active'], isNull);
      expect((saved['failed'] as List).single['mediaKey'], 'id:first');
      expect(manager.retryTask('id:first'), isTrue);
      expect(keys().first, 'id:first');
    },
  );

  test('ordinary failure advances to the next started task only', () async {
    await add('first', start: true);
    await add('paused');
    await add('next', start: true);
    center.captures.single.completeError(StateError('test failure'));
    await _until(() => manager.currentVideoId == 'next');
    expect(keys(), ['id:next', 'id:first', 'id:paused']);
    expect(manager.getQueueSnapshot()[1].status, TranscriptionStatus.error);
    expect(center.captures, hasLength(2));
  });

  test('resuming a paused task clears its previous paused status', () async {
    await add('media', start: true);
    manager.pauseTask('id:media');
    center.release();
    await _until(() => !manager.isQueueRunning);
    expect(manager.getQueueSnapshot().single.statusMessage, '已暂停');
    String? resumedMessage;
    manager.addListener(() {
      if (!manager.isProcessing || resumedMessage != null) return;
      resumedMessage = manager.getQueueSnapshot().single.statusMessage;
      manager.pauseTask('id:media');
    });
    manager.startTask('id:media');
    await _until(() => !manager.isQueueRunning);
    expect(resumedMessage, isEmpty);
  });

  test(
    'a fresh replacement retains its place in execution as well as display',
    () async {
      await add('first', start: true);
      center.captures.single.completeError(StateError('test failure'));
      await _until(() => !manager.isQueueRunning);
      await add('second');
      await add('third');
      expect(await add('first'), TranscriptionEnqueueResult.added);
      expect(keys(), ['id:first', 'id:second', 'id:third']);
      manager.startAllTasks();
      expect(manager.currentVideoId, 'first');
    },
  );

  test('a damaged queue cache recovers the previous complete order', () async {
    await add('first');
    await add('second');
    manager.reorderTask('id:second', 0);
    await manager.shutdown();
    await add('third');
    await manager.shutdown();
    manager.dispose();
    final cache = File(p.join(root.path, 'transcription_queue_cache.json'));
    await cache.writeAsString('{interrupted-write');
    manager = TranscriptionManager(settings: settings, modelCenter: center);
    await manager.initialize();
    expect(keys(), ['id:second', 'id:first']);
    expect(manager.queuedCount, 2);
    expect(manager.isQueueRunning, isFalse);
    expect(manager.getQueueSnapshot().every((task) => !task.isStarted), isTrue);
  });

  test('older caches schedule tasks in their saved displayed order', () async {
    await manager.shutdown();
    manager.dispose();
    await File(
      p.join(root.path, 'transcription_queue_cache.json'),
    ).writeAsString(
      jsonEncode({
        'version': 2,
        'queue': [
          for (final id in ['a', 'b', 'c'])
            {
              'videoPath': p.join(root.path, '$id.m4a'),
              'videoId': id,
              'mediaKey': 'id:$id',
            },
        ],
        'taskOrder': ['id:c', 'id:a', 'id:b'],
      }),
    );
    manager = TranscriptionManager(settings: settings, modelCenter: center);
    await manager.initialize();
    expect(keys(), ['id:c', 'id:a', 'id:b']);
    manager.startAllTasks();
    expect(manager.currentVideoId, 'c');
  });
}
