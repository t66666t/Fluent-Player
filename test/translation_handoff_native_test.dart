import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/device_resource_snapshot.dart';
import 'package:video_player_app/features/model_center/device_resource_monitor.dart';
import 'package:video_player_app/features/model_center/inference_resource_governor.dart';
import 'package:video_player_app/features/model_center/inference_scheduler.dart';
import 'package:video_player_app/features/model_center/local_subtitle_translator.dart';
import 'package:video_player_app/features/model_center/local_translation_handoff.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/streaming_subtitle_store.dart';

import 'local_translation_benchmark_test.dart' show translationBenchmarkTexts;
import 'support/prepared_local_models.dart';

class _Center extends ModelCenterService with PreparedLocalModels {
  _Center(this.model, this.directory, {required super.storage});
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const weights = String.fromEnvironment('TRANSLATION_RUNTIME_ROOT');
  for (final modelId in ['hy-mt2-1.8b-q4', 'qwen3-4b-q4']) {
    test(
      '$modelId compares small and coalesced CPU streaming handoffs',
      () async {
        SharedPreferences.setMockInitialValues({});
        await LlamaLogging.configure(level: LlamaLogLevel.warn);
        final model = (await loadModelCatalog()).singleWhere(
          (m) => m.id == modelId,
        );
        final temp = await Directory.systemTemp.createTemp('handoff-native-');
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
        final center = _Center(
          model,
          Directory(p.join(weights, modelId)),
          storage: storage,
        );
        final spec = ModelJobSpec(
          profile: ModelServiceProfile(
            id: modelId,
            name: model.name,
            kind: TranscriptionServiceKind.local,
            model: modelId,
          ),
          artifactIdentity: model.identity,
          translation: const LocalTranslationOptions(
            acceleration: TranslationAcceleration.cpu,
            threads: 4,
          ),
        );
        final scheduler = InferenceScheduler.instance;
        final records = <Map<String, Object?>>[];
        // ABBA limits cold-cache and run-order bias. Both strategies retain one
        // identical CPU model; only the production handoff batching differs.
        try {
          for (var run = 0; run < 4; run++) {
            final coalesced = run == 1 || run == 2;
            final memory = await DeviceResourceMonitor.instance.readOnce();
            final captured = DateTime.now();
            final resources = InferenceResourceSession(
              InferenceResourceGovernor(
                DeviceResourceSnapshot(
                  platform: 'windows',
                  processors: 8,
                  memoryBytes: memory.memoryBytes,
                  availableMemoryBytes: memory.availableMemoryBytes,
                  capturedAt: captured,
                ),
                now: () => captured,
              ),
            );
            final stats = <LocalTranslationMetrics>[];
            final responses = <Map<String, Object?>>[];
            final buffer = LocalTranslationHandoffBuffer();
            final watch = Stopwatch()..start();
            var firstPair = 0;
            final store = await StreamingSubtitleStore.create(
              File(p.join(temp.path, '$run.jsonl')),
              {
                'generationId': '$run',
                'primaryPath': p.join(temp.path, '$run.srt'),
                'secondaryPath': p.join(temp.path, '$run.translated.srt'),
              },
            );
            final session = LocalTranslationSession();
            try {
              await scheduler.run(() async {
                final reservation = scheduler.currentReservation;
                Future<void> consume(StableAsrBatch batch) async {
                  final previous = store.precedingSource.join('\n');
                  final source = batch.cues.map((c) => c.text).toList();
                  final replies = <String>[];
                  final output = await LocalSubtitleTranslator(center: center)
                      .translate(
                        texts: source,
                        sourceLanguage: 'en',
                        targetLanguage: 'zh-CN',
                        targetLabel: '简体中文',
                        specification: spec,
                        resume: false,
                        session: session,
                        reservation: reservation,
                        precedingContext: previous,
                        onProgress: (_) {},
                        onMetrics: stats.add,
                        onBatchResponse: replies.add,
                      );
                  responses.add({
                    'source': source,
                    'translations': output,
                    'replies': replies,
                  });
                  for (var i = 0; i < source.length; i++) {
                    validateLocalTranslation(
                      source[i],
                      output[i],
                      targetLanguage: 'zh-CN',
                    );
                  }
                  await store.append(
                    batch.cues,
                    [
                      for (var i = 0; i < output.length; i++)
                        batch.cues[i].copyWith(text: output[i]),
                    ],
                    batch.processedThrough,
                    sourceContext: [
                      ...store.precedingSource,
                      ...source,
                    ].reversed.take(2).toList().reversed.toList(),
                  );
                  if (firstPair == 0) firstPair = watch.elapsedMilliseconds;
                }

                for (
                  var at = 0;
                  at < translationBenchmarkTexts.length;
                  at += 2
                ) {
                  final batch = StableAsrBatch(
                    [
                      for (var i = at; i < at + 2; i++)
                        SubtitleItem(
                          index: i + 1,
                          startTime: Duration(seconds: i * 2),
                          endTime: Duration(seconds: i * 2 + 1),
                          text: translationBenchmarkTexts[i],
                        ),
                    ],
                    Duration(seconds: (at + 2) * 2),
                    reservation,
                    retainConsumerModels: true,
                  );
                  if (!coalesced) {
                    await consume(batch);
                  } else {
                    if (buffer.wouldOverflow(batch)) {
                      await consume(buffer.drain(retainConsumerModels: true));
                    }
                    buffer.add(batch);
                    if (buffer.ready(
                      keepResident: true,
                      endOfInput: at + 2 == translationBenchmarkTexts.length,
                    )) {
                      await consume(buffer.drain(retainConsumerModels: true));
                    }
                  }
                }
                await session.release();
              }, resources: resources);
              final loads = stats.fold<int>(0, (n, m) => n + m.modelLoads);
              final requests = stats.fold<int>(0, (n, m) => n + m.requests);
              expect(loads, 1);
              expect(
                store.primary.snapshot.map((c) => c.text),
                translationBenchmarkTexts,
              );
              expect(
                store.secondary.snapshot.length,
                translationBenchmarkTexts.length,
              );
              records.add({
                'coalesced': coalesced,
                'elapsedMs': watch.elapsedMilliseconds,
                'firstPairMs': firstPair,
                'loads': loads,
                'requests': requests,
                'promptMs': stats.fold<double>(0, (n, m) => n + m.promptMs),
                'decodeMs': stats.fold<double>(0, (n, m) => n + m.decodeMs),
                'generatedTokens': stats.fold<int>(
                  0,
                  (n, m) => n + m.generatedTokens,
                ),
                'metrics': stats.map((m) => m.toJson()).toList(),
                'responses': responses,
              });
              expect(stats.length, coalesced ? 4 : 12);
            } finally {
              await session.release();
            }
          }
          final smallRequests = records
              .where((r) => r['coalesced'] == false)
              .fold<int>(0, (n, r) => n + (r['requests'] as int));
          final combinedRequests = records
              .where((r) => r['coalesced'] == true)
              .fold<int>(0, (n, r) => n + (r['requests'] as int));
          expect(combinedRequests, lessThan(smallRequests));
        } finally {
          await File(
            '.artifacts/model-center/translation-handoff-$modelId.json',
          ).writeAsString(
            const JsonEncoder.withIndent(
              '  ',
            ).convert({'model': modelId, 'records': records}),
          );
          await temp.delete(recursive: true);
        }
      },
      skip: weights.isEmpty,
      timeout: const Timeout(Duration(minutes: 10)),
    );
  }
}
