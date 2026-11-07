import 'dart:async';
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
import 'package:video_player_app/services/app_storage_service.dart';

class _RuntimeCenter extends ModelCenterService {
  _RuntimeCenter(this.model, this.directory, {required super.storage}) {
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

class _TuningSession extends InferenceResourceSession {
  _TuningSession(super.governor);
  @override
  Duration get productiveTime => const Duration(hours: 1);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const root = String.fromEnvironment('TRANSLATION_RUNTIME_ROOT');
  const worker = String.fromEnvironment('TRANSLATION_RUNTIME_WORKER');
  test(
    'private GPU worker survives child death and cancels active decoding',
    () async {
      final model = (await loadModelCatalog()).singleWhere(
        (m) => m.id == 'hy-mt2-1.8b-q4',
      );
      final modelPath = p.absolute(root, model.id, model.files.first.name);
      final registry = InferenceProcessRegistry.instance;
      final originalPids = registry.pids.toSet();
      Future<ProcessTranslationInference> load() =>
          ProcessTranslationInference.load(
            executable: worker,
            modelPath: modelPath,
            threads: 2,
            backend: 'vulkan',
          );
      var inference = await load();
      try {
        final pid = registry.pids.singleWhere(
          (pid) => !originalPids.contains(pid),
        );
        expect(Process.killPid(pid), isTrue);
        await expectLater(
          inference.generate('Translate Hello into Chinese.'),
          throwsStateError,
        );
      } finally {
        await inference.dispose();
      }
      expect(registry.pids.toSet(), originalPids);
      inference = await load();
      try {
        expect(inference.gpuLayers, greaterThan(0));
        final stopped = Stopwatch();
        var cancelled = false;
        await expectLater(
          inference.generate(
            'Translate the following into Simplified Chinese. Keep all numbered lines.\n'
            '${List.generate(100, (i) => '${i + 1}. Please save your work and close the window.').join('\n')}',
            onDelta: (_) {
              if (cancelled) return;
              cancelled = true;
              stopped.start();
              inference.cancel();
            },
          ),
          throwsStateError,
        );
        expect(cancelled, isTrue);
        expect(stopped.elapsed, lessThan(const Duration(seconds: 10)));
      } finally {
        await inference.dispose();
      }
      expect(registry.pids.toSet(), originalPids);
    },
    skip: root.isEmpty || worker.isEmpty,
    timeout: const Timeout(Duration(minutes: 4)),
  );
  for (final modelId in ['hy-mt2-1.8b-q4', 'qwen3-4b-q4']) {
    test(
      '$modelId preserves markup, translates both ways and cancels native decoding',
      () async {
        SharedPreferences.setMockInitialValues({});
        await LlamaLogging.configure(level: LlamaLogLevel.warn);
        final model = (await loadModelCatalog()).singleWhere(
          (m) => m.id == modelId,
        );
        final temp = await Directory.systemTemp.createTemp(
          'translation-runtime-',
        );
        final storage = AppStorageService(
          locations: () async => StorageLocations(
            platform: StoragePlatform.linux,
            support: Directory(p.join(temp.path, 'support')),
            documents: Directory(p.join(temp.path, 'documents')),
            defaultData: Directory(p.join(temp.path, 'data')),
            executable: Directory(p.join(temp.path, 'executable')),
          ),
        );
        await storage.initialize();
        final center = _RuntimeCenter(
          model,
          Directory(p.join(root, modelId)),
          storage: storage,
        );
        final scheduler = InferenceScheduler();
        final translator = LocalSubtitleTranslator(
          center: center,
          scheduler: scheduler,
          gpuWorkerExecutable: worker.isEmpty ? null : worker,
        );
        final spec = ModelJobSpec(
          profile: ModelServiceProfile(
            id: 'native-check',
            name: model.name,
            kind: TranscriptionServiceKind.local,
            model: model.id,
          ),
          artifactIdentity: model.identity,
          translation: LocalTranslationOptions(
            acceleration: worker.isEmpty
                ? TranslationAcceleration.cpu
                : TranslationAcceleration.gpu,
          ),
        );
        const texts = [
          '<i>Hello, welcome.</i>',
          'Please press <b>Save</b> to continue.',
          'The next train leaves at seven.\nDo not be late.',
          'Hello, {{name}}! You have %d messages.',
          r'{\an8}This is the first subtitle.',
          '😀 I am happy to see you.',
          'Use the code %s to sign in.',
          'This is a test of subtitle translation.',
        ];
        final evidence = StringBuffer('$modelId\n');
        void recordMetrics(LocalTranslationMetrics metrics) {
          evidence.writeln(
            'Backend: ${metrics.backend}; GPU layers: ${metrics.gpuLayers}',
          );
          if (worker.isNotEmpty) {
            expect(metrics.gpuLayers, greaterThan(0));
            expect(
              metrics.backend.toLowerCase(),
              anyOf(
                contains('vulkan'),
                contains('cuda'),
                contains('metal'),
                contains('opencl'),
              ),
            );
          }
        }

        try {
          final chinese = await translator.translate(
            texts: texts,
            sourceLanguage: 'en',
            targetLanguage: 'zh-CN',
            targetLabel: '简体中文',
            glossary: 'Save 翻译成 保存',
            specification: spec,
            resume: false,
            onProgress: (_) {},
            onMetrics: recordMetrics,
            onBatchResponse: (value) => evidence.writeln('Batch: $value'),
          );
          expect(chinese, hasLength(texts.length));
          for (var i = 0; i < texts.length; i++) {
            validateLocalTranslation(texts[i], chinese[i]);
            expect(chinese[i], matches(RegExp(r'[\u4e00-\u9fff]')));
            evidence.writeln('${texts[i]} => ${chinese[i]}');
          }
          expect(chinese[1], contains('保存'));
          const reverse = [
            '你好，欢迎使用。',
            '火车七点半出发，请不要迟到。',
            '今天我们来学习这台机器的工作原理。',
            '请保存设置，然后关闭窗口。',
            '谢谢你的帮助，明天见。',
          ];
          final english = await translator.translate(
            texts: reverse,
            sourceLanguage: 'zh-CN',
            targetLanguage: 'en',
            targetLabel: '英语',
            specification: spec,
            resume: false,
            onProgress: (_) {},
            onMetrics: recordMetrics,
            onBatchResponse: (value) =>
                evidence.writeln('Reverse batch: $value'),
          );
          for (var i = 0; i < reverse.length; i++) {
            expect(english[i], matches(RegExp(r'[a-zA-Z]')));
            expect(english[i], isNot(matches(RegExp(r'[\u4e00-\u9fff]'))));
            evidence.writeln('${reverse[i]} => ${english[i]}');
          }
          final cancel = Completer<void>();
          final stopping = Stopwatch()..start();
          await expectLater(
            translator.translate(
              texts: texts,
              sourceLanguage: 'en',
              targetLanguage: 'zh-CN',
              targetLabel: '中文',
              specification: spec,
              resume: false,
              onProgress: (_) {},
              cancelSignal: cancel.future,
              onActivity: (value) {
                if (value != null &&
                    (value.contains('正在生成') || value.contains('本批已生成')) &&
                    !cancel.isCompleted) {
                  stopping.reset();
                  cancel.complete();
                }
              },
            ),
            throwsStateError,
          );
          expect(cancel.isCompleted, isTrue);
          expect(stopping.elapsed, lessThan(const Duration(seconds: 10)));
          expect(scheduler.busy, isFalse);
          evidence.writeln(
            'Native cancellation released the scheduler in ${stopping.elapsedMilliseconds} ms.',
          );
          await File(
            '.artifacts/model-center/translation-runtime-$modelId.txt',
          ).writeAsString(evidence.toString());
        } finally {
          await File(
            '.artifacts/model-center/translation-runtime-$modelId.txt',
          ).writeAsString(evidence.toString());
          await temp.delete(recursive: true);
        }
      },
      skip: root.isEmpty,
      timeout: const Timeout(Duration(minutes: 8)),
    );
  }
  test(
    'native CPU exploration restores translation and accounts all probe costs',
    () async {
      SharedPreferences.setMockInitialValues({});
      await LlamaLogging.configure(level: LlamaLogLevel.warn);
      final model = (await loadModelCatalog()).singleWhere(
        (m) => m.id == 'hy-mt2-1.8b-q4',
      );
      final temp = await Directory.systemTemp.createTemp('translation-tuning-');
      final storage = AppStorageService(
        locations: () async => StorageLocations(
          platform: StoragePlatform.linux,
          support: Directory(p.join(temp.path, 'support')),
          documents: Directory(p.join(temp.path, 'documents')),
          defaultData: Directory(p.join(temp.path, 'data')),
          executable: Directory(p.join(temp.path, 'bin')),
        ),
      );
      await storage.initialize();
      final center = _RuntimeCenter(
        model,
        Directory(p.join(root, model.id)),
        storage: storage,
      );
      final captured = DateTime.now();
      final resources = _TuningSession(
        InferenceResourceGovernor(
          DeviceResourceSnapshot(
            platform: 'android',
            processors: 8,
            memoryBytes: 16 * 1073741824,
            availableMemoryBytes: 12 * 1073741824,
            capturedAt: captured,
          ),
          now: () => captured,
        ),
      );
      final scheduler = InferenceScheduler(
        openResources: () async => resources,
      );
      final translator = LocalSubtitleTranslator(
        center: center,
        scheduler: scheduler,
      );
      LocalTranslationMetrics? metrics;
      final texts = [
        for (var i = 0; i < 24; i++)
          'This is sentence number ${i + 1}. Please save your work.',
      ];
      try {
        final output = await translator.translate(
          texts: texts,
          sourceLanguage: 'en',
          targetLanguage: 'zh-CN',
          targetLabel: '简体中文',
          specification: ModelJobSpec(
            profile: ModelServiceProfile(
              id: 'cpu-probe',
              name: model.name,
              kind: TranscriptionServiceKind.local,
              model: model.id,
            ),
            artifactIdentity: model.identity,
            translation: const LocalTranslationOptions(
              acceleration: TranslationAcceleration.cpu,
            ),
          ),
          resume: false,
          onProgress: (_) {},
          onMetrics: (value) => metrics = value,
        );
        expect(output.length, texts.length);
        for (var i = 0; i < output.length; i++) {
          validateLocalTranslation(
            texts[i],
            output[i],
            targetLanguage: 'zh-CN',
          );
        }
        expect(
          center.inferenceTuning.values.any(
            (v) => (v['lastCostMs'] as num? ?? 0) > 0,
          ),
          isTrue,
        );
        expect(metrics!.calibrationMs, greaterThan(0));
        expect(metrics!.modelLoads, greaterThanOrEqualTo(4));
        expect(resources.activeThreads, 0);
      } finally {
        await temp.delete(recursive: true);
      }
    },
    skip:
        root.isEmpty ||
        !const bool.fromEnvironment('TRANSLATION_CPU_TUNING_NATIVE'),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
