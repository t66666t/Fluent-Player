import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/asr_enhancement_options.dart';
import 'package:video_player_app/features/model_center/asr_enhancement_processing.dart';
import 'package:video_player_app/features/model_center/asr_acceleration.dart';
import 'package:video_player_app/features/model_center/local_asr_worker.dart';
import 'package:video_player_app/features/model_center/local_subtitle_translator.dart';
import 'package:video_player_app/features/model_center/inference_scheduler.dart';
import 'package:video_player_app/features/model_center/inference_resource_governor.dart';
import 'package:video_player_app/features/model_center/device_resource_snapshot.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/features/model_center/model_device_info.dart';
import 'package:video_player_app/features/model_center/model_transcription.dart';
import 'package:video_player_app/features/model_center/subtitle_segmentation.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/ai_subtitle_translator.dart';
import 'package:video_player_app/services/ai_subtitle_api_settings.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/local_transcription_stream.dart';
import 'package:video_player_app/services/streaming_subtitle_store.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';
import 'support/prepared_local_models.dart';

class _Center extends ModelCenterService with PreparedLocalModels {
  _Center({required super.storage});
  @override
  Future<void> initialize() async {}
  @override
  Future<void> prepareAsrEnhancements(
    ModelJobSpec spec, {
    Future<void>? cancelSignal,
    void Function(String)? onProgress,
  }) async {}
  @override
  Future<T> usingModel<T>(
    String id,
    Future<T> Function(ModelArtifact, Directory) action,
  ) => action(
    artifact(id)!,
    Directory(p.absolute('.artifacts/model-center/native/$id')),
  );
  @override
  Future<T> usingAsrModels<T>(
    ModelJobSpec spec,
    Future<T> Function(ModelArtifact, Directory, Map<String, String>) action,
  ) => action(
    artifact(spec.profile.model)!,
    Directory(
      p.absolute('.artifacts/model-center/native/${spec.profile.model}'),
    ),
    {
      for (final id in spec.enhancementModels.keys)
        id: p.absolute('.artifacts/model-center/enhancements/$id'),
    },
  );
}

class _MeasuredTranslation extends SubtitleTranslationService {
  final runs = <LocalTranslationMetrics>[];
  @override
  Future<List<String>> translateCueBatch({
    required List<SubtitleItem> items,
    required String sourceLanguage,
    required String targetLanguage,
    required SubtitleTranslateProvider provider,
    required void Function(double) onProgress,
    void Function(String?)? onActivity,
    void Function(int, String)? onTranslated,
    AiSubtitleTranslationSettings? aiOptions,
    AiSubtitleApiSettings? aiEndpoint,
    ModelJobSpec? localSpecification,
    ModelCenterService? modelCenter,
    LocalTranslationSession? localSession,
    InferenceReservation? reservation,
    String precedingContext = '',
    String checkpointScope = '',
    Future<void>? cancelSignal,
    SmartTranslationPolicy? smartPolicy,
  }) => LocalSubtitleTranslator(center: modelCenter).translate(
    texts: items.map((c) => c.text).toList(),
    sourceLanguage: sourceLanguage,
    targetLanguage: targetLanguage,
    targetLabel: '简体中文',
    onProgress: onProgress,
    onActivity: onActivity,
    onTranslated: onTranslated,
    specification: localSpecification,
    session: localSession,
    reservation: reservation,
    precedingContext: precedingContext,
    checkpointScope: checkpointScope,
    cancelSignal: cancelSignal,
    onMetrics: runs.add,
  );
}

Uint8List wave(Float32List samples) {
  final bytes = Uint8List(44 + samples.length * 2);
  final data = ByteData.sublistView(bytes);
  void tag(int at, String value) =>
      bytes.setRange(at, at + value.length, value.codeUnits);
  tag(0, 'RIFF');
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  tag(36, 'data');
  data.setUint32(4, bytes.length - 8, Endian.little);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  data.setUint32(40, samples.length * 2, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(
      44 + i * 2,
      (samples[i] * 32768).round().clamp(-32768, 32767),
      Endian.little,
    );
  }
  return bytes;
}

InferenceResourceSession _fixedResources({
  int totalGb = 32,
  int availableGb = 24,
}) {
  final captured = DateTime.now();
  // Admission is deliberately fixed in this native fixture. Without a live
  // platform monitor its snapshot would expire after eight seconds and test
  // stale-resource fallback instead of the requested execution plan.
  return InferenceResourceSession(
    InferenceResourceGovernor(
      DeviceResourceSnapshot(
        platform: 'windows',
        processors: 8,
        memoryBytes: totalGb * 1073741824,
        availableMemoryBytes: availableGb * 1073741824,
        capturedAt: captured,
      ),
      now: () => captured,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('STREAMING_NATIVE');
  final report = <String, dynamic>{};
  late Directory root;
  late _Center center;
  late String library;
  setUp(() async {
    if (!enabled) return;
    SharedPreferences.setMockInitialValues({});
    if (Platform.isWindows) {
      DynamicLibrary.open(p.absolute('windows/runtime/onnxruntime.dll'));
    }
    final configPath = p.absolute('.dart_tool/package_config.json');
    final config = jsonDecode(await File(configPath).readAsString()) as Map;
    final package = (config['packages'] as List).cast<Map>().firstWhere(
      (entry) => entry['name'] == 'sherpa_onnx_windows',
    );
    library = p.join(
      p.fromUri(Uri.file(configPath).resolve(package['rootUri'] as String)),
      'windows',
    );
    root = await Directory.systemTemp.createTemp('stream-native-');
    final storage = AppStorageService(
      locations: () async => StorageLocations(
        platform: StoragePlatform.linux,
        support: Directory(p.join(root.path, 'support')),
        documents: Directory(p.join(root.path, 'docs')),
        defaultData: Directory(p.join(root.path, 'data')),
        executable: Directory(p.join(root.path, 'exe')),
      ),
    );
    await storage.initialize();
    center = _Center(storage: storage)
      ..catalog = await loadModelCatalog(includeRetired: true);
  });
  tearDown(() async {
    if (!enabled) return;
    await center.shutdown();
    await root.delete(recursive: true);
    await File(
      '.artifacts/model-center/streaming-native-results.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  });

  for (final id in [
    'sensevoice-small-int8',
    'dolphin-base-int8',
    'parakeet-v3-int8',
    'zipformer-zh-en-tiny-int8',
  ]) {
    test(
      '$id publishes real enhanced batches and resumes them without decoding again',
      () async {
        final model = center.artifact(id)!;
        final zh = model.engine == 'dolphin';
        final language = zh ? 'zh' : 'en';
        final probe = decodeModelWave(
          await File(
            'assets/models/asr/speech_probe${zh ? '_zh' : ''}.wav',
          ).readAsBytes(),
        );
        final audio = Float32List(65 * 16000);
        for (final second in [0, 31, 60]) {
          audio.setRange(
            second * 16000,
            second * 16000 + probe.length.clamp(0, 5 * 16000),
            probe,
          );
        }
        const options = AsrEnhancementOptions();
        final spec = ModelJobSpec(
          profile: ModelServiceProfile(
            id: id,
            name: id,
            kind: TranscriptionServiceKind.local,
            model: id,
            language: language,
          ),
          artifactIdentity: model.identity,
          asrEnhancements: options,
          asrAcceleration: AsrAcceleration.cpu,
          subtitleSegmentation: SubtitleSegmentationOptions.natural,
          enhancementModels: {
            for (final key in options.requiredModels([language], language))
              key: center.artifact(key)!.identity,
          },
        );
        final workers = <LocalAsrWorker>[];
        final runner = ModelTranscriptionRunner(
          center: center,
          loadDeviceInfo: () async => const ModelDeviceInfo(
            memoryBytes: 32 * 1073741824,
            availableMemoryBytes: 24 * 1073741824,
            processors: 16,
          ),
          createLocalWorker: () {
            final worker = LocalAsrWorker(libraryDirectory: library);
            workers.add(worker);
            return worker;
          },
        );
        var prepared = 0, firstMs = 0, batches = 0;
        final watch = Stopwatch()..start();
        final published = <SubtitleItem>[];
        Future<List<SubtitleItem>> run() => runner.run(
          spec: spec,
          sourceIdentity: id,
          duration: const Duration(seconds: 65),
          prepareAudio: (start, length, _, _) async {
            prepared++;
            final path = File(p.join(root.path, 'audio-$prepared.wav'));
            await path.writeAsBytes(
              wave(
                Float32List.sublistView(
                  audio,
                  start.inMilliseconds * 16,
                  (start + length).inMilliseconds * 16,
                ),
              ),
            );
            return path.path;
          },
          onProgress: (_) {},
          onStableBatch: (batch) async {
            if (firstMs == 0) firstMs = watch.elapsedMilliseconds;
            batches++;
            published.addAll(batch.cues);
          },
        );
        final result = await run();
        expect(result, isNotEmpty);
        expect(batches, greaterThanOrEqualTo(2));
        expect(
          published.map((cue) => cue.toTimingJson()),
          result.map((cue) => cue.toTimingJson()),
        );
        final previousPreparations = prepared;
        published.clear();
        final resumed = await run();
        expect(prepared, previousPreparations);
        expect(
          resumed.map((cue) => cue.toTimingJson()),
          result.map((cue) => cue.toTimingJson()),
        );
        report[id] = {
          'elapsedMs': watch.elapsedMilliseconds,
          'firstBatchMs': firstMs,
          'cues': result.length,
          'preparedChunks': prepared,
          'asrModelLoadsIncludingReplay': workers.fold<int>(
            0,
            (count, worker) => count + worker.modelLoads,
          ),
          'rssBytes': ProcessInfo.currentRss,
        };
      },
      skip: !enabled || !Platform.isWindows,
      timeout: const Timeout(Duration(minutes: 4)),
    );
  }

  for (final id in [
    'sensevoice-small-int8',
    'dolphin-base-int8',
    'parakeet-v3-int8',
    'zipformer-zh-en-tiny-int8',
  ]) {
    test(
      '$id repairs continuous speech crossing a 30-second audio cut',
      () async {
        final model = center.artifact(id)!;
        final language = model.engine == 'parakeet' ? 'en' : 'zh';
        final probe = decodeModelWave(
          await File(
            'assets/models/asr/speech_probe${language == 'zh' ? '_zh' : ''}.wav',
          ).readAsBytes(),
        );
        // Put the audio cut in a strong voiced frame, not in a pause between
        // phrases (the JFK sample has a pause near the original three seconds).
        var cut = 0, peak = -1.0;
        for (
          var at = (probe.length ~/ 4 ~/ 320) * 320;
          at + 320 < probe.length * 3 ~/ 4;
          at += 320
        ) {
          var energy = 0.0;
          for (var i = at; i < at + 320; i++) {
            energy += probe[i] * probe[i];
          }
          if (energy > peak) {
            peak = energy;
            cut = at + 160;
          }
        }
        final speechStart = 30 * 16000 - cut;
        final duration = Duration(
          milliseconds: (speechStart + probe.length) * 1000 ~/ 16000 + 500,
        );
        final audio = Float32List(duration.inMilliseconds * 16);
        audio.setRange(speechStart, speechStart + probe.length, probe);
        const options = AsrEnhancementOptions();
        final spec = ModelJobSpec(
          profile: ModelServiceProfile(
            id: id,
            name: id,
            model: id,
            language: language,
            kind: TranscriptionServiceKind.local,
          ),
          artifactIdentity: model.identity,
          asrEnhancements: options,
          subtitleSegmentation: SubtitleSegmentationOptions.natural,
          asrAcceleration: AsrAcceleration.cpu,
          enhancementModels: {
            for (final key in options.requiredModels([language], language))
              key: center.artifact(key)!.identity,
          },
        );
        final runner = ModelTranscriptionRunner(
          center: center,
          createLocalWorker: () => LocalAsrWorker(libraryDirectory: library),
          loadDeviceInfo: () async => const ModelDeviceInfo(
            memoryBytes: 32 * 1073741824,
            availableMemoryBytes: 24 * 1073741824,
            processors: 8,
          ),
        );
        var preparation = 0, repairs = 0;
        final delivered = <SubtitleItem>[];
        Future<List<SubtitleItem>> run({required bool streaming}) => runner.run(
          spec: spec,
          sourceIdentity: 'continuous-$id-${streaming ? 'stream' : 'whole'}',
          duration: duration,
          resourceSession: _fixedResources(),
          onProgress: (event) {
            if (event.message == '正在重新识别音频交界，避免残词重复') repairs++;
          },
          onStableBatch: streaming
              ? (batch) async {
                  delivered.addAll(batch.cues);
                }
              : null,
          prepareAudio: (start, count, _, _) async {
            final path = File(
              p.join(root.path, 'continuous-${preparation++}.wav'),
            );
            await path.writeAsBytes(
              wave(
                Float32List.sublistView(
                  audio,
                  start.inMilliseconds * 16,
                  (start + count).inMilliseconds * 16,
                ),
              ),
            );
            return path.path;
          },
        );
        final whole = await run(streaming: false);
        final watch = Stopwatch()..start();
        final streamed = await run(streaming: true);
        final firstPreparations = preparation;
        final firstRepairs = repairs;
        final replayed = await run(streaming: true);
        String text(List<SubtitleItem> cues) => cues
            .map((c) => c.text)
            .join()
            .toLowerCase()
            .replaceAll(RegExp(r'[\p{P}\s]', unicode: true), '');
        expect(streamed, isNotEmpty);
        if (model.engine == 'zipformer') {
          // The tiny bilingual model changes some words when the VAD/denoising
          // input context changes. This is not a quality/WER test: require the
          // same utterance without concatenating two alternative hypotheses.
          expect(
            asrTextAgreement(text(streamed), text(whole)),
            greaterThan(.8),
          );
          expect(
            text(streamed).length,
            lessThanOrEqualTo((text(whole).length * 1.25).ceil()),
          );
        } else {
          expect(text(streamed), text(whole));
        }
        expect(
          repairs,
          greaterThan(0),
          reason: 'the sample must exercise audio re-decoding',
        );
        expect(
          preparation,
          firstPreparations,
          reason: 'resume reuses the boundary checkpoint',
        );
        expect(repairs, firstRepairs);
        expect(
          replayed.map((c) => c.toTimingJson()),
          streamed.map((c) => c.toTimingJson()),
        );
        for (var i = 1; i < streamed.length; i++) {
          expect(streamed[i - 1].endTime <= streamed[i].startTime, isTrue);
        }
        report['continuous-boundary-$id'] = {
          'elapsedMsIncludingReplay': watch.elapsedMilliseconds,
          'preparedFilesIncludingWholeBaseline': preparation,
          'cues': streamed.length,
          'wholeText': text(whole),
          'streamedText': text(streamed),
        };
      },
      skip: !enabled || !Platform.isWindows,
      timeout: const Timeout(Duration(minutes: 5)),
    );
  }

  for (final translationId in ['hy-mt2-1.8b-q4', 'qwen3-4b-q4']) {
    test(
      'real ASR and $translationId share one reservation and commit paired growing files',
      () async {
        final asr = center.artifact('sensevoice-small-int8')!;
        final translation = center.artifact(translationId)!;
        final probe = decodeModelWave(
          await File('assets/models/asr/speech_probe.wav').readAsBytes(),
        );
        final audio = Float32List(34 * 16000);
        for (final second in [0, 29]) {
          audio.setRange(
            second * 16000,
            second * 16000 + probe.length.clamp(0, 4 * 16000),
            probe,
          );
        }
        final spec = ModelJobSpec(
          profile: ModelServiceProfile(
            id: asr.id,
            name: asr.name,
            kind: TranscriptionServiceKind.local,
            model: asr.id,
            language: 'en',
          ),
          artifactIdentity: asr.identity,
          asrEnhancements: const AsrEnhancementOptions(),
          enhancementModels: {
            for (final id in const AsrEnhancementOptions().requiredModels([
              'en',
            ], 'en'))
              id: center.artifact(id)!.identity,
          },
          subtitleSegmentation: SubtitleSegmentationOptions.natural,
        );
        final translationSpec = ModelJobSpec(
          profile: ModelServiceProfile(
            id: translation.id,
            name: translation.name,
            kind: TranscriptionServiceKind.local,
            model: translation.id,
          ),
          artifactIdentity: translation.identity,
          translation: const LocalTranslationOptions(
            acceleration: TranslationAcceleration.cpu,
            threads: 2,
          ),
        );
        final store = await StreamingSubtitleStore.create(
          File(p.join(root.path, 'session.jsonl')),
          {
            'generationId': translationId,
            'primaryPath': p.join(root.path, 'source.srt'),
            'secondaryPath': p.join(root.path, 'translated.srt'),
          },
        );
        var commits = 0, previousBytes = 0, firstPairMs = 0;
        final watch = Stopwatch()..start();
        final stop = Completer<void>();
        final stream = LocalTranscriptionStream(
          openStore: () async => store,
          choice: TranscriptTranslateChoice(
            enabled: true,
            direction: TranscriptTranslateDirection.toChinese,
            provider: SubtitleTranslateProvider.local,
            aiOptions: AiSubtitleTranslationSettings.defaults,
            localSpecification: translationSpec,
          ),
          center: center,
          translator: SubtitleTranslationService(),
          cancelSignal: stop.future,
          checkCancelled: () {},
          onActivity: (_, _) {},
          onFailure: () {},
          onCommitted: (state, primary, secondary) async {
            expect(primary.length, secondary.length);
            expect(state.primaryBytes, greaterThan(previousBytes));
            previousBytes = state.primaryBytes;
            commits++;
            if (firstPairMs == 0) firstPairMs = watch.elapsedMilliseconds;
          },
        );
        try {
          await ModelTranscriptionRunner(
            center: center,
            createLocalWorker: () => LocalAsrWorker(libraryDirectory: library),
            loadDeviceInfo: () async => const ModelDeviceInfo(
              memoryBytes: 32 * 1073741824,
              availableMemoryBytes: 24 * 1073741824,
              processors: 16,
            ),
          ).run(
            spec: spec,
            sourceIdentity: translationId,
            duration: const Duration(seconds: 34),
            serializeConsumer: true,
            consumerModelBytes: translation.bytes,
            prepareAudio: (start, count, _, _) async {
              final file = File(
                p.join(root.path, 'chunk-${start.inMilliseconds}.wav'),
              );
              await file.writeAsBytes(
                wave(
                  Float32List.sublistView(
                    audio,
                    start.inMilliseconds * 16,
                    (start + count).inMilliseconds * 16,
                  ),
                ),
              );
              return file.path;
            },
            onProgress: (_) {},
            onStableBatch: stream.accept,
            onSessionClose: stream.close,
            onConsumerIdle: stream.releaseLocalModels,
          );
          await stream.drain();
          expect(commits, greaterThanOrEqualTo(2));
          expect(
            store.primary.snapshot.length,
            store.secondary.snapshot.length,
          );
          expect(
            store.secondary.snapshot.every((cue) => cue.text.trim().isNotEmpty),
            isTrue,
          );
          expect(
            store.secondary.snapshot.any(
              (cue) => RegExp(r'[\u3400-\u9fff]').hasMatch(cue.text),
            ),
            isTrue,
          );
          report[translationId] = {
            'elapsedMs': watch.elapsedMilliseconds,
            'commits': commits,
            'cues': store.primary.snapshot.length,
            'firstPairMs': firstPairMs,
            'audioSecondsPerSecond': 34000 / watch.elapsedMilliseconds,
            'rssBytes': ProcessInfo.currentRss,
          };
        } finally {
          await stream.close();
        }
      },
      skip: !enabled || !Platform.isWindows,
      timeout: const Timeout(Duration(minutes: 5)),
    );
  }

  test(
    'mobile residency benchmark compares forced reload with stage-aware model reuse',
    () async {
      final model = center.artifact('sensevoice-small-int8')!;
      final translation = center.artifact('hy-mt2-1.8b-q4')!;
      const enhancements = AsrEnhancementOptions();
      final spec = ModelJobSpec(
        profile: ModelServiceProfile(
          id: model.id,
          name: model.name,
          kind: TranscriptionServiceKind.local,
          model: model.id,
          language: 'en',
        ),
        artifactIdentity: model.identity,
        asrEnhancements: enhancements,
        subtitleSegmentation: SubtitleSegmentationOptions.natural,
        enhancementModels: {
          for (final id in enhancements.requiredModels(['en'], 'en'))
            id: center.artifact(id)!.identity,
        },
      );
      final translationSpec = ModelJobSpec(
        profile: ModelServiceProfile(
          id: translation.id,
          name: translation.name,
          kind: TranscriptionServiceKind.local,
          model: translation.id,
        ),
        artifactIdentity: translation.identity,
        translation: const LocalTranslationOptions(
          acceleration: TranslationAcceleration.cpu,
          threads: 2,
        ),
      );
      final probe = decodeModelWave(
        await File('assets/models/asr/speech_probe.wav').readAsBytes(),
      );
      final audio = Float32List(65 * 16000);
      for (final second in [0, 29, 58]) {
        audio.setRange(
          second * 16000,
          second * 16000 + probe.length.clamp(0, 4 * 16000),
          probe,
        );
      }
      final results = <String, dynamic>{};
      List<Map<String, Object?>>? original;
      for (final reuse in [false, true]) {
        final id = reuse ? 'autoResidency' : 'forcedReload';
        final measured = _MeasuredTranslation();
        final store = await StreamingSubtitleStore.create(
          File(p.join(root.path, '$id.jsonl')),
          {
            'generationId': id,
            'primaryPath': p.join(root.path, '$id.srt'),
            'secondaryPath': p.join(root.path, '$id.translated.srt'),
          },
        );
        var commits = 0, firstPairMs = 0;
        final watch = Stopwatch()..start();
        final stream = LocalTranscriptionStream(
          openStore: () async => store,
          choice: TranscriptTranslateChoice(
            enabled: true,
            provider: SubtitleTranslateProvider.local,
            direction: TranscriptTranslateDirection.toChinese,
            localSpecification: translationSpec,
            aiOptions: AiSubtitleTranslationSettings.defaults,
          ),
          center: center,
          translator: measured,
          cancelSignal: Completer<void>().future,
          checkCancelled: () {},
          onActivity: (_, _) {},
          onFailure: () {},
          onCommitted: (_, _, _) async {
            commits++;
            if (firstPairMs == 0) firstPairMs = watch.elapsedMilliseconds;
          },
        );
        try {
          await ModelTranscriptionRunner(
            center: center,
            createLocalWorker: () => LocalAsrWorker(libraryDirectory: library),
            // Windows executes real native calls; only admission simulates an
            // 8 GiB device with 4 GiB free. This is not an Android speed result.
            loadDeviceInfo: () async => const ModelDeviceInfo(
              memoryBytes: 8 * 1073741824,
              availableMemoryBytes: 4 * 1073741824,
              processors: 8,
            ),
          ).run(
            spec: spec,
            sourceIdentity: id,
            duration: const Duration(seconds: 65),
            serializeConsumer: true,
            consumerModelBytes: reuse ? translation.bytes : 1 << 40,
            resourceSession: _fixedResources(totalGb: 8, availableGb: 4),
            onProgress: (_) {},
            onStableBatch: (batch) async {
              if (reuse) {
                await stream.accept(batch);
              } else {
                // Reproduce the previous small-window consumer, independently
                // of the production runner's new coalesced handoff size.
                for (var at = 0; at < batch.cues.length; at += 2) {
                  final part = batch.cues.skip(at).take(2).toList();
                  await stream.accept(
                    StableAsrBatch(
                      part,
                      at + 2 < batch.cues.length
                          ? part.last.endTime
                          : batch.processedThrough,
                      batch.reservation,
                      nativePipeline: batch.nativePipeline,
                    ),
                  );
                }
              }
            },
            onSessionClose: stream.close,
            onConsumerIdle: stream.releaseLocalModels,
            prepareAudio: (start, count, _, _) async {
              final file = File(
                p.join(root.path, '$id-${start.inMilliseconds}.wav'),
              );
              await file.writeAsBytes(
                wave(
                  Float32List.sublistView(
                    audio,
                    start.inMilliseconds * 16,
                    (start + count).inMilliseconds * 16,
                  ),
                ),
              );
              return file.path;
            },
          );
          await stream.drain();
          final loads = measured.runs.fold<int>(0, (n, m) => n + m.modelLoads);
          final reuses = measured.runs.fold<int>(
            0,
            (n, m) => n + m.modelReuses,
          );
          if (reuse) {
            expect(loads, 1);
            expect(
              measured.runs.fold<int>(0, (n, m) => n + m.requests),
              lessThan(results['forcedReload']['translationRequests'] as int),
            );
            expect(
              store.primary.snapshot.map((c) => c.toTimingJson()).toList(),
              original,
            );
          } else {
            expect(loads, greaterThan(1));
            original = store.primary.snapshot
                .map((c) => c.toTimingJson())
                .toList();
          }
          results[id] = {
            'elapsedMs': watch.elapsedMilliseconds,
            'firstPairMs': firstPairMs,
            'translationModelLoads': loads,
            'translationModelReuses': reuses,
            'translationRequests': measured.runs.fold<int>(
              0,
              (n, m) => n + m.requests,
            ),
            'commits': commits,
            'cues': store.primary.snapshot.length,
          };
        } finally {
          await stream.close();
        }
      }
      report['mobileAdmissionComparisonOnWindows'] = results;
    },
    skip: !enabled || !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
