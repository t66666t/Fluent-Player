import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/inference_scheduler.dart';
import 'package:video_player_app/features/model_center/local_subtitle_translator.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/services/app_storage_service.dart';

// Opt-in, uncached production-pipeline benchmark. Model weights stay outside
// the test storage; only disposable checkpoints are written to that storage.
class _BenchmarkCenter extends ModelCenterService {
  _BenchmarkCenter(this.model, this.directory, {required super.storage});
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

const translationBenchmarkTexts = [
  'Good morning, everyone.',
  'Today we are going to explore how this machine works.',
  'First, make sure the power is turned off.',
  'Do not touch the red wire.',
  'Can you pass me the small screwdriver?',
  'There should be three screws on the back.',
  'Be careful. This part is very fragile.',
  'I think we found the problem.',
  'The connection was loose the whole time.',
  'Let us try it again.',
  'It works! I cannot believe it.',
  'Thank you for your help.',
  'How long will the battery last?',
  'About six hours under normal conditions.',
  'You can change the brightness in the settings.',
  'The next train leaves at half past seven.',
  'We need to leave now if we want to catch it.',
  'Wait, I forgot my keys.',
  'They are on the table next to the window.',
  'Would you like some tea before we go?',
  'No, thanks. I have already had two cups.',
  'All right, see you tomorrow.',
  'Take care and have a safe journey.',
  'Good night.',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const root = String.fromEnvironment('TRANSLATION_BENCHMARK_ROOT');
  const label = String.fromEnvironment(
    'BENCHMARK_LABEL',
    defaultValue: 'latest',
  );
  const modelId = String.fromEnvironment(
    'BENCHMARK_MODEL',
    defaultValue: 'hy-mt2-1.8b-q4',
  );
  const threads = int.fromEnvironment('BENCHMARK_THREADS', defaultValue: 2);
  const batchSize = int.fromEnvironment(
    'BENCHMARK_BATCH_SIZE',
    defaultValue: 8,
  );
  const acceleration = String.fromEnvironment(
    'BENCHMARK_ACCELERATION',
    defaultValue: 'cpu',
  );
  const worker = String.fromEnvironment('BENCHMARK_WORKER');
  test(
    'real uncached subtitle translation throughput',
    () async {
      SharedPreferences.setMockInitialValues({});
      await LlamaLogging.configure(level: LlamaLogLevel.warn);
      final catalog = await loadModelCatalog();
      final model = catalog.singleWhere((m) => m.id == modelId);
      final directory = Directory(p.join(root, model.id));
      expect(
        await File(p.join(directory.path, model.files.first.name)).length(),
        model.files.first.bytes,
      );
      final temp = await Directory.systemTemp.createTemp(
        'translation-benchmark-',
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
      final center = _BenchmarkCenter(model, directory, storage: storage);
      final watch = Stopwatch()..start();
      final progress = <Map<String, Object>>[];
      Map<String, Object>? metrics;
      final batchReplies = <String>[];
      try {
        final output =
            await LocalSubtitleTranslator(
              center: center,
              scheduler: InferenceScheduler(),
              gpuWorkerExecutable: worker.isEmpty ? null : worker,
            ).translate(
              texts: translationBenchmarkTexts,
              sourceLanguage: 'en',
              targetLanguage: 'zh-CN',
              targetLabel: '简体中文',
              specification: ModelJobSpec(
                profile: ModelServiceProfile(
                  id: 'benchmark',
                  name: model.name,
                  kind: TranscriptionServiceKind.local,
                  model: model.id,
                ),
                artifactIdentity: model.identity,
                threads: threads,
                translation: LocalTranslationOptions(
                  threads: threads,
                  batchSize: batchSize,
                  acceleration: TranslationAcceleration.values.byName(
                    acceleration,
                  ),
                ),
              ),
              resume: false,
              onProgress: (value) => progress.add({
                'fraction': value,
                'ms': watch.elapsedMilliseconds,
              }),
              onMetrics: (value) => metrics = value.toJson(),
              onBatchResponse: batchReplies.add,
              onActivity: (value) {
                // ignore: avoid_print
                print('${watch.elapsedMilliseconds} ms: $value');
              },
            );
        final elapsed = watch.elapsedMilliseconds;
        expect(output, hasLength(translationBenchmarkTexts.length));
        for (var i = 0; i < output.length; i++) {
          validateLocalTranslation(translationBenchmarkTexts[i], output[i]);
          expect(output[i], matches(RegExp(r'[\u4e00-\u9fff]')));
        }
        final result = {
          'model': model.id,
          'identity': model.identity,
          'platform': Platform.operatingSystem,
          'threads': threads,
          'logicalProcessors': Platform.numberOfProcessors,
          'elapsedMs': elapsed,
          'cues': output.length,
          'cuesPerMinute': output.length * 60000 / elapsed,
          'peakRssBytes': ProcessInfo.maxRss,
          'metrics': metrics,
          'batchReplies': batchReplies,
          'progress': progress,
          'source': translationBenchmarkTexts,
          'translations': output,
        };
        final json = const JsonEncoder.withIndent('  ').convert(result);
        // Labels are developer-provided filenames, never paths.
        expect(label, matches(RegExp(r'^[a-zA-Z0-9_-]+$')));
        await Directory('.artifacts/model-center').create(recursive: true);
        await File(
          '.artifacts/model-center/translation-$label.json',
        ).writeAsString(json);
        // ignore: avoid_print
        print(
          'Translation benchmark $label: $elapsed ms, ${output.length} cues',
        );
      } finally {
        await temp.delete(recursive: true);
      }
    },
    skip: root.isEmpty,
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
