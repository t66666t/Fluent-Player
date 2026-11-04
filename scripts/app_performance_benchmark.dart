// Standalone Profile/Release fixture. Never opens the user's media library.
// flutter run -d windows --profile -t scripts/app_performance_benchmark.dart
// --dart-define=PERF_REPORT=<absolute JSON path>
// FLUENT_PERF_MODE=memory-legacy|memory-compact runs a separate buffer process.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';
import 'package:video_player_app/features/media_cache/media_cache_backend.dart';
import 'package:video_player_app/features/media_cache/media_cache_models.dart';
import 'package:video_player_app/features/media_cache/media_cache_service.dart';
import 'package:video_player_app/models/library_activity.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/library_activity_projection.dart';
import 'package:video_player_app/services/library_snapshot_reader.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';

final _navigator = GlobalKey<NavigatorState>();
final _frames = <FrameTiming>[];
final _ticks = <int>[];
final _samples = <Map<String, Object?>>[];
final _label = ValueNotifier('Preparing isolated fixtures');

Map<String, Object> _distribution(Iterable<num> data) {
  final values = data.toList()..sort();
  if (values.isEmpty) return {'count': 0};
  num percentile(double value) => values[((values.length - 1) * value).round()];
  return {
    'count': values.length,
    'p50': percentile(.5),
    'p95': percentile(.95),
    'p99': percentile(.99),
    'max': values.last,
  };
}

Future<void> _measure(String name, Future<void> Function() operation) async {
  _label.value = name;
  await SchedulerBinding.instance.endOfFrame;
  final start = DateTime.now().microsecondsSinceEpoch;
  final clock = Stopwatch()..start();
  await operation();
  clock.stop();
  await SchedulerBinding.instance.endOfFrame;
  _samples.add({
    'name': name,
    'elapsedMs': clock.elapsedMicroseconds / 1000,
    'startUs': start,
    'endUs': DateTime.now().microsecondsSinceEpoch,
  });
}

// The pre-change foreground read pipeline, retained only for a controlled A/B
// fixture. Production always calls readLibrarySnapshot.
Future<LoadedLibrarySnapshot> _foregroundRead(
  File file,
  StoragePathEncodingSnapshot paths,
) async {
  final data = paths.decodePaths(jsonDecode(await file.readAsString())) as Map;
  return LoadedLibrarySnapshot(
    collections: {
      for (final raw in data['collections'] as List)
        if (VideoCollection.fromJson(raw) case final item) item.id: item,
    },
    videos: {
      for (final raw in data['videos'] as List)
        if (VideoItem.fromJson(raw) case final item) item.id: item,
    },
    rootChildrenIds: (data['rootChildrenIds'] as List).cast<String>(),
    activity: LibraryActivityStore.parse(
      data[LibraryActivityStore.snapshotKey],
    ),
    recycleBin: null,
    schemaVersion: 2,
  );
}

Future<void> _readAndProjectionBenchmark(Directory root) async {
  for (final count in [0, 1000, 10000]) {
    final fixtureRoot = await Directory(
      p.join(root.path, 'fixtures', '$count'),
    ).create(recursive: true);
    final storage = AppStorageService()..roots['data'] = fixtureRoot;
    final paths = storage.capturePathEncoding();
    final items = List.generate(
      count,
      (i) => VideoItem(
        id: 'v$i',
        path: p.join(fixtureRoot.path, 'videos', '$i.mp4'),
        title: '课程标题 $i / A reasonably long media title',
        durationMs: 120000,
        lastUpdated: i + 1,
        lastPositionMs: 40000,
        parentId: 'f${i ~/ 100}',
        hasProbedChapters: true,
        hasProbedAudioCover: true,
      ),
    );
    final folders = <String, VideoCollection>{
      for (var i = 0; i < (count + 99) ~/ 100; i++)
        'f$i': VideoCollection(
          id: 'f$i',
          name: 'Folder $i',
          createTime: i + 1,
          childrenIds: items.skip(i * 100).take(100).map((v) => v.id).toList(),
        ),
    };
    final activity = LibraryActivityStore(
      media: {
        for (var i = 0; i < items.length; i++)
          items[i].id: MediaActivityRecord(
            mediaId: items[i].id,
            addedAtMs: i + 1,
            accumulatedWatchMs: 40000,
            lastPlayedAtMs: i.isEven ? 100000 + i : null,
          ),
      },
    );
    final file = File(p.join(fixtureRoot.path, 'library.json'));
    await file.writeAsString(
      jsonEncode(
        storage.encodePaths({
          'schemaVersion': 2,
          'collections': folders.values.map((v) => v.toJson()).toList(),
          'videos': items.map((v) => v.toJson()).toList(),
          'rootChildrenIds': folders.keys.toList(),
          LibraryActivityStore.snapshotKey: activity.toJson(),
        }),
      ),
    );
    LoadedLibrarySnapshot? loaded;
    Future<void> foreground() async {
      loaded = await _foregroundRead(file, paths);
    }

    Future<void> worker() async {
      loaded = await readLibrarySnapshot(
        file.path,
        pathEncoding: paths,
        maximumSchemaVersion: 2,
      );
    }

    await foreground();
    await worker();
    for (var repeat = 0; repeat < 10; repeat++) {
      if (repeat.isEven) {
        await _measure('read_${count}_foreground', foreground);
        await _measure('read_${count}_worker', worker);
      } else {
        await _measure('read_${count}_worker', worker);
        await _measure('read_${count}_foreground', foreground);
      }
      if (loaded!.videos!.length != count) {
        throw StateError('Lost library rows');
      }
    }
    if (count != 10000) continue;
    final videos = {for (final item in items) item.id: item};
    final projection = LibraryActivityProjection(
      store: activity,
      videoOf: (id) => videos[id],
      collectionOf: (id) => folders[id],
      allVideos: () => videos.values,
    );
    var groups = 0;
    for (var i = 0; i < 10; i++) {
      await _measure('projection_two_passes', () async {
        groups =
            projection.continueLearningGroups().length +
            projection.continueLearningGroups(unknownPlayedOnly: true).length;
      });
      final expected = groups;
      await _measure('projection_one_pass', () async {
        final sections = projection.continueLearningSections();
        groups = sections.recent.length + sections.unknown.length;
      });
      if (groups != expected) throw StateError('Projection mismatch');
    }
  }
}

Future<void> _cacheBenchmark(Directory root) async {
  final variants = <CacheVariant>[];
  for (var i = 0; i < 128; i++) {
    final file = await File(
      p.join(root.path, 'cache-$i.mp4'),
    ).writeAsBytes([1, 2, 3]);
    variants.add(
      CacheVariant(
        source: CacheSource(
          ref: MediaSourceRef(
            value: 'BV$i',
            bvid: 'BV$i',
            cid: 1,
            kind: MediaSourceKind.bilibiliStream,
          ),
          itemId: 'v$i',
          title: '$i',
          kind: MediaType.video,
        ),
        quality: const CacheQuality(
          id: 'legacy',
          label: 'legacy',
          revision: 'cid',
        ),
        path: file.path,
        bytes: 3,
        createdAt: 1,
        managed: false,
      ),
    );
  }
  for (var trial = 0; trial < 10; trial++) {
    for (final batch in trial.isEven ? [false, true] : [true, false]) {
      final service = MediaCacheService(
        backend: _NoDownloads(),
        journal: File(p.join(root.path, 'cache-$trial-$batch.json')),
        observeNetwork: false,
      );
      await service.initialize();
      var notifications = 0;
      service.addListener(() => notifications++);
      await _measure(
        batch ? 'legacy_batch_128' : 'legacy_single_128',
        () async {
          if (batch) {
            await service.registerLegacyBatch(Stream.fromIterable(variants));
          } else {
            for (final variant in variants) {
              await service.registerLegacy(variant);
            }
          }
        },
      );
      _samples.last['notifications'] = notifications;
      if (service.variants.length != variants.length) {
        throw StateError('Cache registration result mismatch');
      }
      await service.shutdown();
      service.dispose();
    }
  }
}

Future<void> _routeBenchmark() async {
  final memory = <Map<String, int>>[];
  await _measure('shared_route_50_cycles', () async {
    for (var cycle = 0; cycle < 50; cycle++) {
      final route = AppMaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Transition stress fixture')),
          body: ListView.builder(
            itemCount: 10000,
            itemBuilder: (_, i) => ListTile(
              title: Text('Media item $i'),
              subtitle: const Text('Stable content'),
            ),
          ),
        ),
      );
      unawaited(_navigator.currentState!.push(route));
      // Navigator can install a push on the following frame. Observe an actual
      // route frame before checking its animation or requesting a pop.
      await SchedulerBinding.instance.endOfFrame;
      while (route.animation!.status != AnimationStatus.completed) {
        await SchedulerBinding.instance.endOfFrame;
      }
      _navigator.currentState!.pop();
      await route.completed;
      if ((cycle + 1) % 10 == 0) {
        memory.add({
          'cycle': cycle + 1,
          'rssBytes': ProcessInfo.currentRss,
          'decodedImageCacheBytes':
              PaintingBinding.instance.imageCache.currentSizeBytes,
        });
      }
    }
  });
  _samples.last['memoryCheckpoints'] = memory;
}

Future<Map<String, Object?>> _memoryBenchmark(String mode) async {
  final source = Uint8List(512 * 1024);
  for (var i = 0; i < source.length; i++) {
    source[i] = i & 255;
  }
  final before = ProcessInfo.currentRss;
  final retained = <List<int>>[
    for (var i = 0; i < 16; i++)
      mode == 'memory-legacy'
          ? List<int>.of(source)
          : Uint8List.fromList(source),
  ];
  final after = ProcessInfo.currentRss;
  return {
    'mode': mode,
    'entries': retained.length,
    'payloadBytes': 16 * source.length,
    'rssBeforeBytes': before,
    'rssAfterBytes': after,
    'rssDeltaBytes': after - before,
    'checksum': retained.fold<int>(0, (sum, bytes) => sum + bytes.last),
  };
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final output =
      Platform.environment['FLUENT_PERF_REPORT'] ??
      const String.fromEnvironment('PERF_REPORT');
  if (!p.isAbsolute(output)) {
    throw ArgumentError('PERF_REPORT must be absolute');
  }
  final mode = Platform.environment['FLUENT_PERF_MODE'] ?? 'all';
  final report = File(output);
  await report.parent.create(recursive: true);
  try {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      await windowManager.ensureInitialized();
    }
    SchedulerBinding.instance.addTimingsCallback(_frames.addAll);
    runApp(
      MaterialApp(
        navigatorKey: _navigator,
        theme: ThemeData.dark().copyWith(
          pageTransitionsTheme: appPageTransitionsTheme,
        ),
        home: const _MotionFixture(),
      ),
    );
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      await windowManager.setSize(const Size(1280, 720));
      await windowManager.show();
    }
    await Future<void>.delayed(const Duration(milliseconds: 800));
    Map<String, Object?> data;
    if (mode.startsWith('memory-')) {
      data = await _memoryBenchmark(mode);
    } else {
      await _readAndProjectionBenchmark(report.parent);
      final cacheRoot = await Directory(
        p.join(
          report.parent.path,
          'cache-fixture',
          '${DateTime.now().microsecondsSinceEpoch}',
        ),
      ).create(recursive: true);
      await _cacheBenchmark(cacheRoot);
      await _routeBenchmark();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      final refreshHz = WidgetsBinding
          .instance
          .platformDispatcher
          .views
          .first
          .display
          .refreshRate;
      final frameBudgetMs = 1000 / (refreshHz > 0 ? refreshHz : 60);
      final names = _samples.map((s) => s['name']! as String).toSet();
      final phases = <String, Object>{};
      for (final name in names) {
        final samples = _samples.where((s) => s['name'] == name).toList();
        final frames = _frames.where((f) {
          final wall = f.timestampInMicroseconds(
            FramePhase.rasterFinishWallTime,
          );
          return samples.any(
            (s) =>
                wall >= (s['startUs']! as int) && wall <= (s['endUs']! as int),
          );
        }).toList();
        final gaps = <double>[];
        for (var i = 1; i < _ticks.length; i++) {
          if (samples.any(
            (s) =>
                _ticks[i] >= (s['startUs']! as int) &&
                _ticks[i] <= (s['endUs']! as int),
          )) {
            gaps.add((_ticks[i] - _ticks[i - 1]) / 1000);
          }
        }
        phases[name] = {
          'frameBudgetMs': frameBudgetMs,
          'frameCount': frames.length,
          'overBudgetFrameCount': frames
              .where(
                (f) =>
                    f.buildDuration.inMicroseconds / 1000 > frameBudgetMs ||
                    f.rasterDuration.inMicroseconds / 1000 > frameBudgetMs,
              )
              .length,
          'overBudgetFramePercent': frames.isEmpty
              ? null
              : 100 *
                    frames
                        .where(
                          (f) =>
                              f.buildDuration.inMicroseconds / 1000 >
                                  frameBudgetMs ||
                              f.rasterDuration.inMicroseconds / 1000 >
                                  frameBudgetMs,
                        )
                        .length /
                    frames.length,
          'elapsedMs': _distribution(
            samples.map((s) => s['elapsedMs']! as num),
          ),
          'buildMs': _distribution(
            frames.map((f) => f.buildDuration.inMicroseconds / 1000),
          ),
          'rasterMs': _distribution(
            frames.map((f) => f.rasterDuration.inMicroseconds / 1000),
          ),
          'callbackGapMs': _distribution(gaps),
        };
      }
      data = {
        'phases': phases,
        'samples': _samples,
        'reportedRefreshHz': refreshHz,
        'note':
            'Layer A/B fixture and shared-route stress, not OS launch time or measured scanout FPS.',
      };
    }
    await report.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'status': 'passed',
        'platform': Platform.operatingSystem,
        'profile': const bool.fromEnvironment('dart.vm.profile'),
        ...data,
      }),
    );
    if (Platform.isWindows) {
      await windowManager.close();
    } else {
      exit(0);
    }
  } catch (error, stack) {
    await report.writeAsString(
      jsonEncode({'status': 'failed', 'error': '$error', 'stack': '$stack'}),
    );
    exit(1);
  }
}

class _MotionFixture extends StatefulWidget {
  const _MotionFixture();
  @override
  State<_MotionFixture> createState() => _MotionFixtureState();
}

class _MotionFixtureState extends State<_MotionFixture>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion =
      AnimationController(vsync: this, duration: const Duration(seconds: 1))
        ..addListener(() {
          _ticks.add(DateTime.now().microsecondsSinceEpoch);
        })
        ..repeat(reverse: true);
  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ValueListenableBuilder<String>(
            valueListenable: _label,
            builder: (_, label, _) => Text(label),
          ),
          AnimatedBuilder(
            animation: _motion,
            builder: (_, _) => Transform.translate(
              offset: Offset(_motion.value * 100, 0),
              child: const FlutterLogo(size: 48),
            ),
          ),
        ],
      ),
    ),
  );
}

class _NoDownloads implements MediaCacheBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Benchmark attempted a download');
}
