import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/media_cache/media_cache_backend.dart';
import 'package:video_player_app/features/media_cache/media_cache_models.dart';
import 'package:video_player_app/features/media_cache/media_cache_service.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/cloud_drive_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/app_default_settings_trial.dart';

CacheSource source([String id = 'one']) => CacheSource(
  ref: MediaSourceRef(
    value: 'BV$id',
    kind: MediaSourceKind.bilibiliStream,
    bvid: 'BV$id',
    cid: 123,
  ),
  itemId: id,
  title: 'Video $id',
  kind: MediaType.video,
);

class CountingSource extends CacheSource {
  CountingSource(String id)
    : super(
        ref: MediaSourceRef(
          value: 'BV$id',
          kind: MediaSourceKind.bilibiliStream,
          bvid: 'BV$id',
          cid: 123,
        ),
        itemId: id,
        title: id,
        kind: MediaType.video,
      );
  final calls = [0];
  @override
  String get key {
    calls[0]++;
    return super.key;
  }
}

class FakeBackend implements MediaCacheBackend {
  FakeBackend(this.root);
  final Directory root;
  int calls = 0, active = 0, maxActive = 0;
  bool slow = false, lateCompletion = false;
  Object? failure;
  @override
  Future<List<CacheQuality>> qualities(CacheSource source) async => const [
    CacheQuality(id: '360', label: '360P', height: 360, revision: 'v1'),
    CacheQuality(id: '1080', label: '1080P', height: 1080, revision: 'v1'),
  ];
  @override
  Future<CacheDownloadPlan> resolve(CacheTask task, CancelToken cancel) async =>
      CacheDownloadPlan(
        quality: CacheQuality(
          id: task.requestedQuality ?? '1080',
          label: '${task.requestedQuality ?? '1080'}P',
          height: int.tryParse(task.requestedQuality ?? '1080'),
          revision: 'v1',
        ),
      );
  @override
  Future<Directory> outputDirectory(CacheSource source) async =>
      Directory(p.join(root.path, 'files'))..createSync();
  @override
  Future<Directory> taskDirectory(CacheTask task) async =>
      Directory(p.join(root.path, 'tasks', 'cache_${task.id}'))
        ..createSync(recursive: true);
  @override
  Future<File> download(
    CacheTask task,
    CacheDownloadPlan plan,
    MediaCachePreferences preferences,
    CancelToken cancel,
    void Function(CacheTransferProgress) onProgress,
  ) async {
    calls++;
    active++;
    if (active > maxActive) maxActive = active;
    final file = File(p.join(task.workDirectory!, 'media.part'));
    try {
      if (failure != null) throw failure!;
      final old = await file.exists() ? await file.length() : 0;
      final handle = await file.open(mode: FileMode.append);
      try {
        for (var offset = old; offset < 4096; offset += 512) {
          await Future<void>.delayed(Duration(milliseconds: slow ? 30 : 2));
          if (!lateCompletion) cancel.throwIfCancellationRequested();
          await handle.writeFrom(List<int>.filled(512, offset % 251));
          task.resume = {'offset': offset + 512};
          onProgress(
            CacheTransferProgress(received: offset + 512, total: 4096),
          );
        }
        await handle.flush();
      } finally {
        await handle.close();
      }
      return file;
    } finally {
      active--;
    }
  }
}

Future<void> until(bool Function() predicate) async {
  final end = DateTime.now().add(const Duration(seconds: 8));
  while (!predicate() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(
    predicate(),
    isTrue,
    reason: 'expected cache transition before timeout',
  );
}

class _ManualPeriodicTimer implements Timer {
  _ManualPeriodicTimer(this.callback);
  final void Function(Timer) callback;
  @override
  bool isActive = true;
  @override
  int tick = 0;
  @override
  void cancel() => isActive = false;
  void fire() {
    if (!isActive) return;
    tick++;
    callback(this);
  }
}

class _MaintenanceProbeService extends MediaCacheService {
  _MaintenanceProbeService({required super.backend, required super.journal})
    : super(observeNetwork: false);
  int availabilityScans = 0;

  @override
  Future<void> refreshAvailability({String? mediaKey}) {
    availabilityScans++;
    return super.refreshAvailability(mediaKey: mediaKey);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late FakeBackend backend;
  late MediaCacheService service;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('media_cache_service_');
    backend = FakeBackend(root);
    service = MediaCacheService(
      backend: backend,
      journal: File(p.join(root.path, 'media_cache.json')),
      observeNetwork: false,
    );
    await service.initialize();
  });
  tearDown(() async {
    await service.shutdown();
    service.dispose();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<CacheVariant> legacy(String id, {String quality = 'legacy'}) async {
    final file = File(p.join(root.path, '$id.mp4'));
    await file.writeAsBytes([1, 2, 3]);
    return CacheVariant(
      source: source(id),
      quality: CacheQuality(id: quality, label: quality, revision: 'cid'),
      path: file.path,
      bytes: 3,
      createdAt: 1,
      managed: false,
    );
  }

  test(
    'background pauses full-cache maintenance and resume reconciles',
    () async {
      await service.shutdown();
      service.dispose();
      final timers = <_ManualPeriodicTimer>[];
      await runZoned(
        () async {
          final probe = _MaintenanceProbeService(
            backend: backend,
            journal: File(p.join(root.path, 'media_cache.json')),
          );
          service = probe;
          await probe.initialize();
          expect(timers, hasLength(1));
          timers.single.fire();
          await Future<void>.delayed(Duration.zero);
          expect(probe.availabilityScans, 1);

          probe.didChangeAppLifecycleState(AppLifecycleState.paused);
          expect(timers.single.isActive, isFalse);
          timers.single.fire();
          expect(probe.availabilityScans, 1);

          probe.didChangeAppLifecycleState(AppLifecycleState.resumed);
          expect(probe.availabilityScans, 2);
          expect(timers, hasLength(2));
          expect(timers.last.isActive, isTrue);
        },
        zoneSpecification: ZoneSpecification(
          createPeriodicTimer: (self, parent, zone, duration, callback) {
            expect(duration, const Duration(seconds: 15));
            final timer = _ManualPeriodicTimer(
              zone.bindUnaryCallbackGuarded(callback),
            );
            timers.add(timer);
            return timer;
          },
        ),
      );
    },
  );

  test('initialization while hidden schedules no cache sweep', () async {
    await service.shutdown();
    service.dispose();
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    var periodicTimers = 0;
    try {
      await runZoned(
        () async {
          service = MediaCacheService(
            backend: backend,
            journal: File(p.join(root.path, 'media_cache.json')),
            observeNetwork: false,
          );
          await service.initialize();
          expect(periodicTimers, 0);
        },
        zoneSpecification: ZoneSpecification(
          createPeriodicTimer: (self, parent, zone, duration, callback) {
            periodicTimers++;
            return parent.createPeriodicTimer(zone, duration, callback);
          },
        ),
      );
    } finally {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }
  });

  test(
    'background transfers still finalize, clean up and release deleted media',
    () async {
      service.didChangeAppLifecycleState(AppLifecycleState.paused);
      backend.slow = true;
      final task = (await service.enqueue(source()))!;
      await until(() => task.state == CacheTaskState.completed);
      await until(() => !Directory(task.workDirectory!).existsSync());
      final variant = service.variants.single;
      final lease = await service.acquire(source().toItem());
      expect(lease, isNotNull);
      await service.deleteVariant(variant.id);
      expect(File(variant.path).existsSync(), isTrue);
      await lease!.release();
      expect(File(variant.path).existsSync(), isFalse);
      expect(service.variants, isEmpty);
    },
  );

  test(
    'live default trial serializes with progress saves and keeps newly registered variants',
    () async {
      service.preferences = MediaCachePreferences(
        parallelTasks: 3,
        connectionsPerTask: 4,
        pruneLower: true,
      );
      final original = TrialFieldMask.capture(
        {'preferences': service.preferences.toJson()},
        const {'preferences'},
      );
      await service.flush();
      final applying = service.patchPreferencesForTrial({
        'preferences': MediaCachePreferences(
          parallelTasks: 1,
          connectionsPerTask: 2,
          pruneLower: false,
        ).toJson(),
      }, false);
      final progressSave = service.flush();
      await Future.wait([applying, progressSave]);
      expect(service.preferences.parallelTasks, 1);
      await service.registerLegacyBatch(
        Stream.value(await legacy('new-during-trial')),
      );
      final restoring = service.patchPreferencesForTrial(original, true);
      final concurrentSave = service.flush();
      await Future.wait([restoring, concurrentSave]);
      await service.reloadPreferencesForTrial();
      expect(service.preferences.parallelTasks, 3);
      expect(service.preferences.connectionsPerTask, 4);
      expect(service.preferences.pruneLower, true);
      expect(service.variants, hasLength(1));
      final stored =
          jsonDecode(
                await File(
                  p.join(root.path, 'media_cache.json'),
                ).readAsString(),
              )
              as Map;
      expect(stored['variants'], hasLength(1));
      expect(stored['preferences']['parallelTasks'], 3);
    },
  );

  test(
    'legacy batch publishes one generation and duplicate import writes nothing',
    () async {
      final variants = [
        await legacy('a'),
        await legacy('b'),
        await legacy('c'),
      ];
      var notifications = 0;
      service.addListener(() => notifications++);
      await service.registerLegacyBatch(Stream.fromIterable(variants));
      expect(notifications, 1);
      final file = File(p.join(root.path, 'media_cache.json'));
      final backup = File('${file.path}.bak');
      expect(
        (jsonDecode(await file.readAsString()) as Map)['variants'],
        hasLength(3),
      );
      // A per-entry save would leave two entries in the previous generation.
      expect(
        (jsonDecode(await backup.readAsString()) as Map)['variants'],
        isEmpty,
      );
      final before = await backup.readAsString();
      await service.registerLegacyBatch(Stream.fromIterable(variants));
      expect(notifications, 1);
      expect(await backup.readAsString(), before);
    },
  );

  test(
    'interrupted legacy batch saves its prefix and does not poison later imports',
    () async {
      final first = await legacy('first');
      final next = await legacy('next');
      Stream<CacheVariant> interrupted() async* {
        yield first;
        throw StateError('producer interrupted');
      }

      await expectLater(
        service.registerLegacyBatch(interrupted()),
        throwsA(isA<StateError>()),
      );
      final file = File(p.join(root.path, 'media_cache.json'));
      expect(
        (jsonDecode(await file.readAsString()) as Map)['variants'],
        hasLength(1),
      );
      await service.registerLegacy(next);
      final restored = MediaCacheService(
        backend: backend,
        journal: file,
        observeNetwork: false,
      );
      try {
        await restored.initialize();
        expect(restored.variants.map((v) => v.source.itemId), [
          'first',
          'next',
        ]);
      } finally {
        await restored.shutdown();
        restored.dispose();
      }
    },
  );

  test(
    'legacy quality upgrades once without downgrading a known quality',
    () async {
      final old = await legacy('same');
      final upgraded = await legacy('same', quality: '360');
      await service.registerLegacyBatch(
        Stream.fromIterable([old, upgraded, old]),
      );
      expect(service.variants, hasLength(1));
      expect(service.variants.single.quality.id, '360');
      expect(service.variants.single.managed, isFalse);
    },
  );

  test('legacy batch computes source identities linearly', () async {
    final sources = List.generate(128, (i) => CountingSource('$i'));
    final variants = <CacheVariant>[];
    for (final source in sources) {
      final file = await File(
        p.join(root.path, '${source.itemId}.mp4'),
      ).writeAsBytes([1]);
      variants.add(
        CacheVariant(
          source: source,
          quality: const CacheQuality(
            id: 'legacy',
            label: 'legacy',
            revision: 'cid',
          ),
          path: file.path,
          bytes: 1,
          createdAt: 1,
          managed: false,
        ),
      );
    }
    await service.registerLegacyBatch(Stream.fromIterable(variants));
    expect(service.variants, hasLength(128));
    expect(
      sources.fold<int>(0, (sum, source) => sum + source.calls[0]),
      lessThan(128 * 20),
    );
  });

  test(
    'legacy index notices a concurrent deletion between producer yields',
    () async {
      final known = await legacy('deleted', quality: '360');
      final unknown = await legacy('deleted');
      Stream<CacheVariant> producer() async* {
        yield known;
        await service.forgetDeletedFiles([known.path]);
        yield unknown;
      }

      await service.registerLegacyBatch(producer());
      expect(service.variants, hasLength(1));
      expect(service.variants.single.quality.id, 'legacy');
    },
  );

  test(
    'legacy upgrades preserve first-match order for duplicate saved paths',
    () async {
      final first = await legacy('duplicate');
      final second = CacheVariant(
        source: first.source,
        quality: const CacheQuality(
          id: 'legacy',
          label: 'old',
          revision: 'older',
        ),
        path: first.path,
        bytes: 3,
        createdAt: 1,
        managed: false,
      );
      await service.shutdown();
      service.dispose();
      final file = File(p.join(root.path, 'media_cache.json'));
      final raw = jsonDecode(await file.readAsString()) as Map;
      raw['variants'] = [first.toJson(), second.toJson()];
      await file.writeAsString(jsonEncode(raw));
      service = MediaCacheService(
        backend: backend,
        journal: file,
        observeNetwork: false,
      );
      await service.initialize();
      await service.registerLegacyBatch(
        Stream.fromIterable([
          await legacy('duplicate', quality: '360'),
          await legacy('duplicate', quality: '720'),
        ]),
      );
      expect(service.variants.map((v) => v.quality.id).toList()..sort(), [
        '360',
        '720',
      ]);
    },
  );

  test(
    'shutdown waits for an in-flight legacy prefix and rejects its tail',
    () async {
      final first = await legacy('before-close');
      final next = await legacy('after-close');
      final produced = Completer<void>();
      final release = Completer<void>();
      Stream<CacheVariant> paused() async* {
        yield first;
        produced.complete();
        await release.future;
        yield next;
      }

      final registration = service.registerLegacyBatch(paused());
      await produced.future;
      var closed = false;
      final shutdown = service.shutdown().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      release.complete();
      await registration;
      await shutdown;
      expect(service.variants.map((v) => v.source.itemId), ['before-close']);
      final raw =
          jsonDecode(
                await File(
                  p.join(root.path, 'media_cache.json'),
                ).readAsString(),
              )
              as Map;
      expect(raw['variants'], hasLength(1));
    },
  );

  test(
    'verified original cloud cache ranks first and prunes only its own transcoded revision',
    () async {
      const cloud = CacheSource(
        ref: MediaSourceRef(
          kind: MediaSourceKind.cloudDrive,
          value: 'cloud',
          cloudDrive: CloudDriveSourceRef(
            providerId: 'baidu',
            remoteAccountId: 'u',
            driveId: '0',
            fileId: 'f',
            revision: 'v1',
          ),
        ),
        itemId: 'cloud',
        title: 'media.mp4',
        kind: MediaType.video,
      );
      final low = (await service.enqueue(cloud, qualityId: '720'))!;
      await until(() => low.state == CacheTaskState.completed);
      final oldPath = service.variantsFor(cloud.key).single.path;
      final original = (await service.enqueue(cloud, qualityId: 'original'))!;
      await until(
        () =>
            original.state == CacheTaskState.completed &&
            service.variantsFor(cloud.key).length == 1,
      );
      expect(service.variantsFor(cloud.key).single.quality.id, 'original');
      await until(() => !File(oldPath).existsSync());
      expect(await File(oldPath).exists(), isFalse);
    },
  );

  test(
    'same identity deduplicates tasks; different qualities coexist without duplicate media',
    () async {
      service.preferences.pruneLower = false;
      final first = await service.enqueue(source(), qualityId: '360');
      final duplicate = await service.enqueue(source(), qualityId: '360');
      expect(duplicate?.id, first?.id);
      await service.enqueue(source(), qualityId: '1080');
      await until(() => service.variants.length == 2);
      expect(backend.calls, 2);
      expect(service.variants.map((v) => v.source.key).toSet(), hasLength(1));
      expect(await service.enqueue(source(), qualityId: '1080'), isNull);
      expect(service.runningCount, 0);
    },
  );
  test(
    'resolution ceilings treat portrait and landscape equally without changing playback dimensions',
    () {
      const portrait = CacheQuality(
        id: '80',
        label: '1080P',
        width: 1080,
        height: 1920,
      );
      const landscape = CacheQuality(
        id: '80',
        label: '1080P',
        width: 1920,
        height: 1080,
      );
      expect(portrait.resolutionHeight, 1080);
      expect(landscape.resolutionHeight, 1080);
      expect(portrait.height, 1920);
    },
  );

  test(
    'batch skips complete and queued sources and ignores duplicate selections',
    () async {
      backend.slow = true;
      expect(await service.enqueueAll([source(), source(), source('two')]), 2);
      expect(await service.enqueueAll([source(), source('two')]), 0);
      await until(() => service.variants.length == 2);
      expect(await service.enqueueAll([source(), source('two')]), 0);
    },
  );

  test(
    'pause preserves durable partial bytes; resume completes the same task',
    () async {
      backend.slow = true;
      final task = (await service.enqueue(source()))!;
      await until(() => task.received >= 512);
      await service.pause(task.id);
      final bytes = task.received;
      expect(task.state, CacheTaskState.paused);
      expect(service.runningCount, 0);
      expect(task.resume['offset'], greaterThan(0));
      await service.resume(task.id);
      await until(() => service.variants.isNotEmpty);
      expect(task.received, 4096);
      expect(bytes, lessThan(4096));
      expect(task.state, CacheTaskState.completed);
    },
  );

  test(
    'manual pause survives journal reload and does not start by itself',
    () async {
      backend.slow = true;
      final task = (await service.enqueue(source()))!;
      await until(() => task.received >= 512);
      await service.pause(task.id);
      await service.shutdown();
      service.dispose();
      final nextBackend = FakeBackend(root);
      service = MediaCacheService(
        backend: nextBackend,
        journal: File(p.join(root.path, 'media_cache.json')),
        observeNetwork: false,
      );
      await service.initialize();
      expect(service.tasks.single.state, CacheTaskState.paused);
      expect(nextBackend.calls, 0);
      await service.resume(task.id);
      await until(() => service.variants.isNotEmpty);
      expect(service.tasks.single.state, CacheTaskState.completed);
    },
  );

  test(
    'late completion cannot resurrect a cancelled task or publish a cache',
    () async {
      backend.lateCompletion = true;
      final task = (await service.enqueue(source()))!;
      await until(() => backend.active == 1);
      await service.cancel(task.id);
      expect(service.tasks, isEmpty);
      expect(service.variants, isEmpty);
      expect(Directory(task.workDirectory!).existsSync(), isFalse);
    },
  );

  test(
    'higher quality is committed before pruning and leased lower quality is deferred',
    () async {
      await service.enqueue(source(), qualityId: '360');
      await until(() => service.variants.length == 1);
      final low = service.variants.single;
      final lease = await service.acquire(source().toItem(), qualityId: '360');
      expect(lease, isNotNull);
      await service.enqueue(source(), qualityId: '1080');
      await until(() => service.variants.length == 2 && low.pendingDelete);
      expect(File(low.path).existsSync(), isTrue);
      expect(service.variantsFor(source().key).single.quality.id, '1080');
      await lease!.release();
      expect(File(low.path).existsSync(), isFalse);
      expect(service.variants.single.quality.id, '1080');
    },
  );

  test(
    'complete copies and identities survive restart; external deletion repairs tasks',
    () async {
      await service.enqueue(source());
      await until(() => service.variants.isNotEmpty);
      await service.shutdown();
      service.dispose();
      service = MediaCacheService(
        backend: FakeBackend(root),
        journal: File(p.join(root.path, 'media_cache.json')),
        observeNetwork: false,
      );
      await service.initialize();
      expect(service.hasCache(source().key), isTrue);
      final path = service.variants.single.path;
      await File(path).delete();
      await service.forgetDeletedFiles([path]);
      expect(service.hasCache(source().key), isFalse);
      expect(service.tasks.single.state, CacheTaskState.failed);
    },
  );

  test('global task concurrency remains bounded', () async {
    service.preferences.parallelTasks = 2;
    backend.slow = true;
    await service.enqueueAll([for (var i = 0; i < 5; i++) source('$i')]);
    await until(() => service.variants.length == 5);
    expect(backend.maxActive, 2);
  });

  test(
    'login and disk failures retain recoverable tasks and can continue',
    () async {
      backend.failure = const CacheLoginRequired();
      final task = (await service.enqueue(source()))!;
      await until(() => task.state == CacheTaskState.waitingLogin);
      backend.failure = const FileSystemException(
        'disk full',
        '',
        OSError('full', 112),
      );
      await service.resume(task.id);
      await until(() => task.state == CacheTaskState.waitingStorage);
      backend.failure = null;
      await service.resume(task.id);
      await until(() => service.variants.isNotEmpty);
      expect(service.tasks.single.id, task.id);
    },
  );
  test(
    'expired authorization and detached storage remain recoverable',
    () async {
      final request = RequestOptions(path: '');
      backend.failure = DioException(
        requestOptions: request,
        response: Response(requestOptions: request, statusCode: 401),
      );
      final task = (await service.enqueue(source()))!;
      await until(() => task.state == CacheTaskState.waitingLogin);
      backend.failure = const FileSystemException(
        'device unavailable',
        '',
        OSError('missing', 19),
      );
      await service.resume(task.id);
      await until(() => task.state == CacheTaskState.waitingStorage);
      backend.failure = null;
      await service.resume(task.id);
      await until(() => task.state == CacheTaskState.completed);
    },
  );

  for (final staging in [false, true]) {
    test(
      'published receipt reconciles a crash without a digest: staging=$staging',
      () async {
        await service.shutdown();
        service.dispose();
        final task = CacheTask(
          id: 'recovery',
          source: source(),
          createdAt: 1,
          state: CacheTaskState.failed,
          workDirectory: p.join(root.path, 'tasks', 'cache_recovery'),
        );
        final file = File(p.join(root.path, 'files', 'cache_ready.mp4'))
          ..parent.createSync(recursive: true);
        await file.writeAsBytes([1, 2, 3, 4]);
        final variant = CacheVariant(
          source: source(),
          quality: const CacheQuality(id: '80', label: '1080P'),
          path: file.path,
          bytes: 4,
          createdAt: 1,
        );
        if (staging) await file.rename('${file.path}.publishing');
        final receipt = File(
          p.join(task.workDirectory!, 'published_variant.json'),
        )..parent.createSync(recursive: true);
        await receipt.writeAsString(jsonEncode(variant.toJson()));
        await File(p.join(root.path, 'media_cache.json')).writeAsString(
          jsonEncode({
            'version': 1,
            'tasks': [task.toJson()],
            'variants': [],
          }),
        );
        service = MediaCacheService(
          backend: FakeBackend(root),
          journal: File(p.join(root.path, 'media_cache.json')),
          observeNetwork: false,
        );
        await service.initialize();
        expect(service.tasks.single.state, CacheTaskState.completed);
        expect(service.variants.single.path, file.path);
        expect((service.backend as FakeBackend).calls, 0);
      },
    );
  }

  test(
    'temporarily missing disk retains ownership and returns after remount',
    () async {
      await service.enqueue(source());
      await until(() => service.variants.isNotEmpty);
      await service.shutdown();
      service.dispose();
      final files = Directory(p.join(root.path, 'files'));
      final hidden = await files.rename(p.join(root.path, 'unplugged'));
      service = MediaCacheService(
        backend: FakeBackend(root),
        journal: File(p.join(root.path, 'media_cache.json')),
        observeNetwork: false,
      );
      await service.initialize();
      expect(service.variants, hasLength(1));
      expect(service.hasCache(source().key), isFalse);
      await hidden.rename(files.path);
      await service.reconcile();
      expect(service.hasCache(source().key), isTrue);
    },
  );

  test(
    'active caches use size checks without rehashing unchanged-length files',
    () async {
      await service.enqueue(source());
      await until(() => service.variants.isNotEmpty);
      final file = File(service.variants.single.path);
      await file.writeAsBytes(
        List.filled(await file.length(), 255),
        flush: true,
      );
      await file.setLastModified(
        DateTime.now().add(const Duration(seconds: 3)),
      );
      final lease = await service.acquire(source().toItem());
      expect(lease, isNotNull);
      await lease!.release();
      expect(service.variants, hasLength(1));
      await file.writeAsBytes([1], flush: true);
      expect(await service.acquire(source().toItem()), isNull);
      expect(service.variants, isEmpty);
    },
  );

  test(
    'cache publication has no content digest or verification stage',
    () async {
      final stages = <CacheTaskState>{};
      service.addListener(
        () => stages.addAll(service.tasks.map((t) => t.state)),
      );
      final task = (await service.enqueue(source()))!;
      await until(() => task.state == CacheTaskState.completed);
      expect(service.variants.single.sha256, isEmpty);
      expect(stages, isNot(contains(CacheTaskState.verifying)));
      expect(await File(service.variants.single.path).length(), 4096);
    },
  );

  test(
    'pause, cancel and resume races cannot recreate a removed task',
    () async {
      backend.slow = true;
      final task = (await service.enqueue(source()))!;
      await until(() => task.received >= 512);
      await Future.wait([
        service.cancel(task.id),
        service.resume(task.id),
        service.pause(task.id),
      ]);
      expect(service.tasks, isEmpty);
      expect(service.variants, isEmpty);
    },
  );
  test(
    'a pending leased deletion cannot be overwritten by recaching the same quality',
    () async {
      await service.enqueue(source(), qualityId: '360');
      await until(() => service.variants.isNotEmpty);
      final old = service.variants.single;
      final lease = (await service.acquire(
        source().toItem(),
        qualityId: '360',
      ))!;
      await service.deleteVariant(old.id);
      final task = (await service.enqueue(source(), qualityId: '360'))!;
      await until(() => task.state == CacheTaskState.failed);
      expect(File(old.path).existsSync(), isTrue);
      await lease.release();
      expect(service.variants, isEmpty);
      await service.resume(task.id);
      await until(() => service.variants.isNotEmpty);
      expect(service.variants.single.pendingDelete, isFalse);
      expect(File(service.variants.single.path).existsSync(), isTrue);
    },
  );
  test(
    'shared physical media counts once and remains until its last owner is removed',
    () async {
      final file = File(p.join(root.path, 'shared.mp4'))
        ..writeAsBytesSync(List.filled(100, 7));
      final a = CacheVariant(
        source: source('one'),
        quality: const CacheQuality(id: '80', label: '1080P'),
        path: file.path,
        bytes: 100,
        createdAt: 1,
        managed: false,
      );
      final b = CacheVariant(
        source: source('two'),
        quality: const CacheQuality(id: '80', label: '1080P'),
        path: file.path,
        bytes: 100,
        createdAt: 1,
        managed: false,
      );
      await service.registerLegacy(a);
      await service.registerLegacy(b);
      expect(service.cachedBytes, 100);
      await service.deleteVariant(a.id);
      expect(file.existsSync(), isTrue);
      await service.deleteVariant(b.id);
      expect(file.existsSync(), isFalse);
      expect(service.cachedBytes, 0);
    },
  );
}
