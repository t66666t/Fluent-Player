import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/inference_scheduler.dart';
import 'package:video_player_app/features/model_center/inference_resource_governor.dart';
import 'package:video_player_app/features/model_center/device_resource_snapshot.dart';
import 'package:video_player_app/features/model_center/local_subtitle_translator.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/features/model_center/translation_inference.dart';
import 'package:video_player_app/features/model_center/translation_performance.dart';
import 'package:video_player_app/services/app_storage_service.dart';

class _Center extends ModelCenterService {
  _Center(this.model, this.directory, {required super.storage}) {
    catalog = [model];
    downloads[model.id] = ModelDownload(
      artifactId: model.id, phase: ModelDownloadPhase.installed,
    );
  }
  final ModelArtifact model;
  final Directory directory;
  @override
  Future<void> initialize() async {}
  @override
  Future<T> usingModel<T>(
    String id,
    Future<T> Function(ModelArtifact, Directory) action,
  ) => action(model, directory);
}

class _Engine implements TranslationInference {
  _Engine(
    this.gpu,
    this.delay, {
    this.invalid = false,
    this.onGenerate,
    this.missingBracket = false,
    this.truncated = false,
  });
  final bool gpu, invalid;
  final bool missingBracket, truncated;
  final Duration delay;
  final void Function()? onGenerate;
  bool disposed = false, cancelled = false;
  @override
  String get backend => gpu ? 'TestGPU' : 'CPU';
  @override
  int get gpuLayers => gpu ? 32 : 0;
  @override
  Future<TranslationGeneration> generate(
    String prompt, {
    String? grammar,
    bool structured = false,
    bool reusePromptPrefix = true,
    void Function(String)? onDelta,
  }) async {
    onGenerate?.call();
    await Future<void>.delayed(delay);
    if (cancelled) throw StateError('cancelled');
    final rows = <String>[];
    for (final line in const LineSplitter().convert(prompt)) {
      if (!RegExp(r'^\[\d+,').hasMatch(line)) continue;
      final row = jsonDecode(line) as List;
      rows.add(jsonEncode([row[0], '译文：${row[1]}']));
    }
    var text = invalid
        ? '[0,"wrong"]'
        : rows.isEmpty
        ? '你好。'
        : rows.join('\n');
    if (missingBracket && rows.isNotEmpty) {
      text = text.replaceFirst(RegExp(r'\]$'), '');
    }
    onDelta?.call(text);
    return TranslationGeneration(
      text: text,
      truncated: truncated && rows.isNotEmpty,
      generatedTokens: 20,
      promptTokens: 40,
    );
  }

  @override
  void cancel() => cancelled = true;
  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

InferenceScheduler testScheduler() => InferenceScheduler(
  openResources: () async => InferenceResourceSession(
    InferenceResourceGovernor(
      DeviceResourceSnapshot(
        platform: 'windows',
        processors: 8,
        memoryBytes: 32 * 1073741824,
        availableMemoryBytes: 24 * 1073741824,
        capturedAt: DateTime.now(),
      ),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late AppStorageService storage;
  late ModelArtifact model;
  late _Center center;
  late ModelJobSpec spec;
  const inputs = ['Hello there.', 'Please save the file.', 'See you tomorrow.'];
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('translation-acceleration-');
    storage = AppStorageService(
      locations: () async => StorageLocations(
        platform: StoragePlatform.linux,
        support: Directory(p.join(temp.path, 'support')),
        documents: Directory(p.join(temp.path, 'documents')),
        defaultData: Directory(p.join(temp.path, 'data')),
        executable: Directory(p.join(temp.path, 'executable')),
      ),
    );
    await storage.initialize();
    model = (await loadModelCatalog()).firstWhere(
      (m) => m.purpose == ModelPurpose.translation,
    );
    center = _Center(model, temp, storage: storage);
    spec = ModelJobSpec(
      profile: ModelServiceProfile(
        id: 'test',
        name: model.name,
        kind: TranscriptionServiceKind.local,
        model: model.id,
      ),
      artifactIdentity: model.identity,
    );
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });

  Future<List<String>> translate(
    LocalSubtitleTranslator translator, {
    ModelJobSpec? job,
    Future<void>? cancel,
    List<String> texts = inputs,
    void Function(LocalTranslationMetrics)? metrics,
  }) => translator.translate(
    texts: texts,
    sourceLanguage: 'en',
    targetLanguage: 'zh-CN',
    targetLabel: '简体中文',
    specification: job ?? spec,
    onProgress: (_) {},
    cancelSignal: cancel,
    resume: false,
    calibrate: true,
    onMetrics: metrics,
  );

  test(
    'auto measures both backends once, retains valid output and caches faster GPU',
    () async {
      final loaded = <bool>[];
      final engines = <_Engine>[];
      final translator = LocalSubtitleTranslator(
        center: center,
        scheduler: testScheduler(),
        loadInference: (_, params, gpu, cancel) async {
          loaded.add(gpu);
          final engine = _Engine(gpu, Duration(milliseconds: gpu ? 2 : 100));
          engines.add(engine);
          return engine;
        },
      );
      expect(await translate(translator), inputs.map((s) => '译文：$s'));
      expect(loaded, [false, true]);
      expect(center.translationPerformance[model.id]!.useGpu, isTrue);
      LocalTranslationMetrics? metrics;
      expect(
        await translate(translator, metrics: (m) => metrics = m),
        inputs.map((s) => '译文：$s'),
      );
      expect(loaded, [false, true, true]);
      expect(metrics!.calibrationMs, 0);
      expect(engines.every((e) => e.disposed), isTrue);
    },
  );

  test(
    'streaming batches retain one model lease and release it at session end',
    () async {
      final engines = <_Engine>[];
      final scheduler = testScheduler();
      final translator = LocalSubtitleTranslator(
        center: center,
        scheduler: scheduler,
        loadInference: (_, _, gpu, _) async {
          final engine = _Engine(gpu, Duration.zero);
          engines.add(engine);
          return engine;
        },
      );
      final session = LocalTranslationSession();
      final job = ModelJobSpec(
        profile: spec.profile,
        artifactIdentity: spec.artifactIdentity,
        translation: const LocalTranslationOptions(
          acceleration: TranslationAcceleration.cpu,
        ),
      );
      try {
        for (var i = 0; i < 2; i++) {
          await scheduler.run(
            () => translator.translate(
              texts: inputs.take(2).toList(),
              sourceLanguage: 'en',
              targetLanguage: 'zh-CN',
              targetLabel: '简体中文',
              specification: job,
              onProgress: (_) {},
              resume: false,
              session: session,
              reservation: scheduler.currentReservation,
            ),
          );
        }
        expect(engines, hasLength(1));
        expect(engines.single.disposed, isFalse);
        expect(center.inUse(model.id), isTrue);
      } finally {
        await session.release();
      }
      expect(engines.single.disposed, isTrue);
      expect(center.inUse(model.id), isFalse);
      expect(scheduler.busy, isFalse);
    },
  );

  test('auto chooses CPU when GPU is slower', () async {
    final loaded = <bool>[];
    final translator = LocalSubtitleTranslator(
      center: center,
      scheduler: testScheduler(),
      loadInference: (_, params, gpu, cancel) async {
        loaded.add(gpu);
        return _Engine(gpu, Duration(milliseconds: gpu ? 120 : 5));
      },
    );
    expect(await translate(translator), inputs.map((s) => '译文：$s'));
    expect(loaded, [false, true, false]);
    expect(center.translationPerformance[model.id]!.useGpu, isFalse);
    await translate(translator);
    expect(loaded.last, isFalse);
  });

  test(
    'short auto tasks skip initial GPU calibration to avoid startup overhead',
    () async {
      final loaded = <bool>[];
      final translator = LocalSubtitleTranslator(
        center: center,
        scheduler: testScheduler(),
        loadInference: (_, params, gpu, cancel) async {
          loaded.add(gpu);
          return _Engine(gpu, Duration.zero);
        },
      );
      await translator.translate(
        texts: inputs,
        sourceLanguage: 'en',
        targetLanguage: 'zh-CN',
        targetLabel: '简体中文',
        specification: spec,
        onProgress: (_) {},
        resume: false,
      );
      expect(loaded, [false]);
      expect(center.translationPerformance, isEmpty);
    },
  );

  for (final invalid in [false, true]) {
    test(
      'GPU ${invalid ? 'invalid text' : 'process failure'} retains CPU output and stops repeated probes',
      () async {
        final loaded = <bool>[];
        final translator = LocalSubtitleTranslator(
          center: center,
          scheduler: testScheduler(),
          loadInference: (_, params, gpu, cancel) async {
            loaded.add(gpu);
            if (gpu && !invalid) throw StateError('native child exited');
            return _Engine(gpu, Duration.zero, invalid: gpu && invalid);
          },
        );
        expect(await translate(translator), inputs.map((s) => '译文：$s'));
        expect(loaded, [false, true, false]);
        expect(center.translationPerformance[model.id]!.gpuFailed, isTrue);
        await translate(translator);
        expect(loaded, [false, true, false, false]);
      },
    );
  }

  test(
    'explicit CPU skips calibration; explicit GPU can retry and safely fall back',
    () async {
      final loaded = <bool>[];
      final translator = LocalSubtitleTranslator(
        center: center,
        scheduler: testScheduler(),
        loadInference: (_, params, gpu, cancel) async {
          loaded.add(gpu);
          if (gpu) throw StateError('no GPU device');
          expect(params.device, ComputeDevice.cpu);
          return _Engine(false, Duration.zero);
        },
      );
      ModelJobSpec job(TranslationAcceleration acceleration) => ModelJobSpec(
        profile: spec.profile,
        artifactIdentity: model.identity,
        translation: LocalTranslationOptions(acceleration: acceleration),
      );
      await translate(translator, job: job(TranslationAcceleration.cpu));
      expect(loaded, [false]);
      await translate(translator, job: job(TranslationAcceleration.gpu));
      expect(loaded, [false, true, false]);
    },
  );

  test(
    'cancelling a GPU comparison releases engines without marking the GPU unsafe',
    () async {
      final cancel = Completer<void>();
      final engines = <_Engine>[];
      final scheduler = testScheduler();
      final translator = LocalSubtitleTranslator(
        center: center,
        scheduler: scheduler,
        loadInference: (_, params, gpu, signal) async {
          final engine = _Engine(
            gpu,
            const Duration(milliseconds: 5),
            onGenerate: gpu ? () => cancel.complete() : null,
          );
          engines.add(engine);
          return engine;
        },
      );
      await expectLater(
        translate(translator, cancel: cancel.future),
        throwsStateError,
      );
      expect(center.translationPerformance, isEmpty);
      expect(engines.every((e) => e.disposed), isTrue);
      expect(await scheduler.run(() async => 'released'), 'released');
    },
  );

  test(
    'identical text and context share inference while preserving every cue',
    () async {
      var inferred = 0;
      LocalTranslationMetrics? metrics;
      final translator = LocalSubtitleTranslator(
        center: center,
        scheduler: testScheduler(),
        completeBatch: (texts, context, target, glossary, cancel) async {
          inferred += texts.length;
          return texts.entries
              .map((e) => jsonEncode([e.key, '你好。']))
              .join('\n');
        },
      );
      expect(
        await translate(
          translator,
          texts: List.filled(8, 'Hello there.'),
          metrics: (m) => metrics = m,
        ),
        List.filled(8, '你好。'),
      );
      expect(inferred, 3);
      expect(metrics!.reusedPieces, 5);
    },
  );

  test('model settings persist independently', () async {
    final catalog = await loadModelCatalog();
    final service = ModelCenterService(
      storage: storage,
      catalogLoader: () async => catalog,
    );
    await service.initialize();
    service.translationModelId = 'hy-mt2-1.8b-q4';
    service.translationOptions = const LocalTranslationOptions(
      acceleration: TranslationAcceleration.cpu,
      threads: 3,
      gpuLayers: 16,
    );
    service.translationModelId = 'qwen3-4b-q4';
    expect(
      service.translationOptions.acceleration,
      TranslationAcceleration.auto,
    );
    service.translationOptions = const LocalTranslationOptions(
      acceleration: TranslationAcceleration.gpu,
      threads: 6,
      batchSize: 4,
    );
    await service.save();
    final restored = ModelCenterService(
      storage: storage,
      catalogLoader: () async => catalog,
    );
    await restored.initialize();
    expect(
      restored.translationOptions.acceleration,
      TranslationAcceleration.gpu,
    );
    restored.translationModelId = 'hy-mt2-1.8b-q4';
    expect(restored.translationOptions.threads, 3);
    expect(restored.translationOptions.gpuLayers, 16);
    expect(
      restored.translationOptions.acceleration,
      TranslationAcceleration.cpu,
    );
  });

  test(
    '1900 cues continue past a malformed middle cue and repair it last',
    () async {
      final texts = List.generate(1900, (n) => 'Please check item $n.');
      final visited = <int>[];
      final progress = <double>[];
      var sawLast = false;
      LocalTranslationMetrics? metrics;
      final translator = LocalSubtitleTranslator(
        center: center,
        scheduler: testScheduler(),
        completeBatch: (rows, context, target, glossary, cancel) async {
          visited.addAll(rows.keys);
          if (rows.containsKey(1899)) sawLast = true;
          return rows.entries
              .where((e) => e.key != 900 || sawLast)
              .map((e) => jsonEncode([e.key, '请检查项目 ${e.key}。']))
              .join('\n');
        },
      );
      final output = await translator.translate(
        texts: texts,
        sourceLanguage: 'en',
        targetLanguage: 'zh-CN',
        targetLabel: '简体中文',
        specification: spec,
        onProgress: progress.add,
        onMetrics: (value) => metrics = value,
      );
      expect(output, List.generate(1900, (n) => '请检查项目 $n。'));
      expect(visited.last, 900);
      expect(visited.indexOf(1899), lessThan(visited.lastIndexOf(900)));
      expect(metrics!.deferredPieces, 1);
      expect(metrics!.recoveredPieces, 1);
      expect(progress.last, 1);
      expect(progress, orderedEquals([...progress]..sort()));
      final jobs = await storage.featureDirectory('model_jobs');
      final diagnostic = jobs.listSync().whereType<File>().singleWhere(
        (file) => file.path.endsWith('.diagnostic.json'),
      );
      final report = jsonDecode(await diagnostic.readAsString()) as Map;
      expect(report['status'], 'complete');
      expect(report['completedCues'], 1900);
      expect(await diagnostic.readAsString(), isNot(contains('Please check')));
    },
  );

  test(
    'persistent invalid cues retain later work and resume only missing cues',
    () async {
      const texts = [
        '<i>First cue.</i>',
        'Second cue.',
        '<b>Third cue.</b>',
        'Last cue.',
      ];
      final scheduler = testScheduler();
      final first = LocalSubtitleTranslator(
        center: center,
        scheduler: scheduler,
        completeBatch: (rows, context, target, glossary, cancel) async => rows
            .entries
            .map(
              (e) =>
                  jsonEncode([e.key, e.key.isEven ? '标签丢失' : '正确译文 ${e.key}']),
            )
            .join('\n'),
      );
      await expectLater(
        first.translate(
          texts: texts,
          sourceLanguage: 'en',
          targetLanguage: 'zh-CN',
          targetLabel: '简体中文',
          specification: spec,
          onProgress: (_) {},
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'saved work',
            contains('已完成 2/4 条'),
          ),
        ),
      );
      expect(scheduler.busy, isFalse);
      final jobs = await storage.featureDirectory('model_jobs');
      final diagnostic = jobs.listSync().whereType<File>().singleWhere(
        (file) => file.path.endsWith('.diagnostic.json'),
      );
      final report = jsonDecode(await diagnostic.readAsString()) as Map;
      expect(report['failureCode'], 'invalid_translation');
      expect(report['cueNumbers'], [1, 3]);
      expect(report['completedCues'], 2);
      final retried = <int>[];
      final output =
          await LocalSubtitleTranslator(
            center: center,
            scheduler: scheduler,
            completeBatch: (rows, context, target, glossary, cancel) async {
              retried.addAll(rows.keys);
              return rows.entries
                  .map((e) => jsonEncode([e.key, '译文 ${e.value}']))
                  .join('\n');
            },
          ).translate(
            texts: texts,
            sourceLanguage: 'en',
            targetLanguage: 'zh-CN',
            targetLabel: '简体中文',
            specification: spec,
            onProgress: (_) {},
          );
      // Piece IDs are regenerated after restoring completed cues.
      expect(retried, [0, 1]);
      expect(output, [
        '译文 <i>First cue.</i>',
        '正确译文 1',
        '译文 <b>Third cue.</b>',
        '正确译文 3',
      ]);
    },
  );

  test('systemic invalid output stops after three empty groups', () async {
    final visited = <int>{};
    final translator = LocalSubtitleTranslator(
      center: center,
      scheduler: testScheduler(),
      completeBatch: (rows, context, target, glossary, cancel) async {
        visited.addAll(rows.keys);
        return '';
      },
    );
    await expectLater(
      translate(
        translator,
        texts: List.generate(1900, (n) => 'Subtitle number $n.'),
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'circuit breaker',
          contains('连续 3 批'),
        ),
      ),
    );
    expect(visited.length, 24);
    expect(visited.contains(24), isFalse);
  });

  test(
    'a transient CPU inference failure reloads once and completes',
    () async {
      final loaded = <_Engine>[];
      LocalTranslationMetrics? metrics;
      final translator = LocalSubtitleTranslator(
        center: center,
        scheduler: testScheduler(),
        loadInference: (path, params, gpu, cancel) async {
          final first = loaded.isEmpty;
          final engine = _Engine(
            false,
            Duration.zero,
            onGenerate: first
                ? () => throw StateError('transient allocation')
                : null,
          );
          loaded.add(engine);
          return engine;
        },
      );
      final job = ModelJobSpec(
        profile: spec.profile,
        artifactIdentity: spec.artifactIdentity,
        translation: const LocalTranslationOptions(
          acceleration: TranslationAcceleration.cpu,
        ),
      );
      expect(
        await translate(translator, job: job, metrics: (m) => metrics = m),
        hasLength(3),
      );
      expect(loaded, hasLength(2));
      expect(loaded.every((e) => e.disposed), isTrue);
      expect(metrics!.cpuRestarts, 1);
      final jobs = await storage.featureDirectory('model_jobs');
      final diagnostic = jobs.listSync().whereType<File>().singleWhere(
        (file) => file.path.endsWith('.diagnostic.json'),
      );
      final report = jsonDecode(await diagnostic.readAsString()) as Map;
      expect((report['recoveries'] as List).single['code'], 'runtime');
      expect(report['status'], 'complete');
    },
  );

  test(
    'repeated CPU faults stop after one restart and release resources',
    () async {
      final loaded = <_Engine>[];
      final scheduler = testScheduler();
      final translator = LocalSubtitleTranslator(
        center: center,
        scheduler: scheduler,
        loadInference: (path, params, gpu, cancel) async {
          final engine = _Engine(
            false,
            Duration.zero,
            onGenerate: () => throw StateError('runtime fault'),
          );
          loaded.add(engine);
          return engine;
        },
      );
      final job = ModelJobSpec(
        profile: spec.profile,
        artifactIdentity: spec.artifactIdentity,
        translation: const LocalTranslationOptions(
          acceleration: TranslationAcceleration.cpu,
        ),
      );
      await expectLater(translate(translator, job: job), throwsStateError);
      expect(loaded, hasLength(2));
      expect(loaded.every((e) => e.disposed), isTrue);
      expect(scheduler.busy, isFalse);
    },
  );

  for (final truncated in [false, true]) {
    test(
      'complete JSON string with missing row bracket ${truncated ? 'must retry on token cutoff' : 'does not need translation again'}',
      () async {
        LocalTranslationMetrics? metrics;
        final translator = LocalSubtitleTranslator(
          center: center,
          scheduler: testScheduler(),
          loadInference: (_, _, _, _) async => _Engine(
            false,
            Duration.zero,
            missingBracket: true,
            truncated: truncated,
          ),
        );
        final output = await translator.translate(
          texts: inputs,
          sourceLanguage: 'en',
          targetLanguage: 'zh-CN',
          targetLabel: '简体中文',
          specification: spec,
          resume: false,
          onProgress: (_) {},
          onMetrics: (value) => metrics = value,
        );
        expect(output.length, 3);
        expect(output.last, truncated ? '你好。' : '译文：See you tomorrow.');
        expect(metrics!.requests, truncated ? 2 : 1);
        expect(metrics!.fallbackRequests, truncated ? 1 : 0);
      },
    );
  }

  test(
    'single-cue format exceptions are retried instead of aborting a task',
    () async {
      var attempts = 0;
      final translator = LocalSubtitleTranslator(
        center: center,
        scheduler: testScheduler(),
        complete: (text, context, target, glossary, cancel) async {
          if (++attempts == 1) throw const FormatException('token limit');
          return '正确译文';
        },
      );
      expect(await translate(translator, texts: ['Hello there.']), ['正确译文']);
      expect(attempts, 2);
    },
  );

  test(
    'runtime failures stop safely and save diagnosis without subtitle content',
    () async {
      final translator = LocalSubtitleTranslator(
        center: center,
        scheduler: testScheduler(),
        complete: (text, context, target, glossary, cancel) async =>
            throw StateError(text),
      );
      await expectLater(translate(translator), throwsStateError);
      final jobs = await storage.featureDirectory('model_jobs');
      final diagnostic = jobs.listSync().whereType<File>().singleWhere(
        (file) => file.path.endsWith('.diagnostic.json'),
      );
      final content = await diagnostic.readAsString();
      final report = jsonDecode(content) as Map;
      expect(report['status'], 'failed');
      expect(report['failureCode'], 'runtime');
      expect(report['cueNumbers'], [1]);
      for (final text in inputs) {
        expect(content, isNot(contains(text)));
      }
    },
  );

  test(
    'near ties prefer CPU and stale or changed device profiles are ignored',
    () {
      final now = DateTime.utc(2026, 10, 20);
      final profile = TranslationPerformanceProfile(
        signature: 'device',
        testedAt: now,
        cpuMs: 1000,
        gpuMs: 950,
      );
      expect(profile.useGpu, isFalse);
      expect(
        profile.matches('device', now.add(const Duration(days: 1))),
        isTrue,
      );
      expect(
        profile.matches('device', now.add(const Duration(days: 15))),
        isFalse,
      );
      expect(profile.matches('changed-model-or-settings', now), isFalse);
      final startup = TranslationPerformanceProfile(
        signature: 'device',
        testedAt: now,
        cpuMs: 1000,
        gpuMs: 500,
        cpuStartupMs: 500,
        gpuStartupMs: 4000,
      );
      expect(startup.useGpuFor(1), isFalse);
      expect(startup.useGpuFor(24), isTrue);
      expect(
        TranslationPerformanceProfile.fromJson(profile.toJson())!.cpuMs,
        1000,
      );
      expect(
        TranslationPerformanceProfile.fromJson({'signature': 'bad'}),
        isNull,
      );
    },
  );
}
