import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../../models/subtitle_model.dart';
import '../../models/local_asr_progress.dart';
import '../../services/app_storage_service.dart';
import '../../services/network/network_http.dart';
import '../../services/transcription_reliability.dart';
import '../../services/cloud_translation_batches.dart';
import '../../utils/subtitle_parser.dart';
import 'asr_enhancement_options.dart';
import 'asr_language_options.dart';
import 'asr_enhancement_processing.dart';
import 'asr_text_processing.dart';
import 'asr_execution_plan.dart';
import 'asr_progress_tracker.dart';
import 'audio_chunk_prefetcher.dart';
import 'asr_acceleration.dart';
import 'cohere_asr_runtime.dart';
import 'asr_accelerator_transport.dart';
import 'bounded_model_pipeline.dart';
import 'inference_scheduler.dart';
import 'inference_resource_governor.dart';
import 'inference_tuning.dart';
import 'device_resource_snapshot.dart';
import 'local_asr_worker.dart';
import 'local_translation_handoff.dart';
import 'translation_memory.dart';
import 'model_catalog.dart';
import 'model_device_info.dart';
import 'model_center_service.dart';
import 'model_token_timing.dart';
import 'subtitle_segmentation.dart';
import 'streaming_subtitle_assembler.dart';
import 'asr_append_checkpoint.dart';
import 'asr_window_ownership.dart';
import 'cloud_asr_adapters.dart';
import 'cloud_asr_pipeline.dart';
export 'cloud_asr_pipeline.dart' show CloudAsrAudio, PrepareCloudAsrAudio;

export 'local_translation_handoff.dart' show StableAsrBatch;

enum ModelProcessingStage {
  preparing,
  downloading,
  loading,
  uploading,
  waiting,
  recognizing,
  denoising,
  detectingSpeech,
  aligning,
  punctuating,
  refining,
  segmenting,
  saving,
}

class ModelProcessingProgress {
  const ModelProcessingProgress(
    this.stage,
    this.message,
    this.fraction, {
    this.local,
  });
  final ModelProcessingStage stage;
  final String message;
  final double fraction;
  final LocalAsrProgress? local;
}

ModelProcessingStage _nativeStage(String phase) => switch (phase) {
  'loading' => ModelProcessingStage.loading,
  'denoising' => ModelProcessingStage.denoising,
  'vad' => ModelProcessingStage.detectingSpeech,
  'aligning' => ModelProcessingStage.aligning,
  'punctuating' => ModelProcessingStage.punctuating,
  'refining' => ModelProcessingStage.refining,
  _ => ModelProcessingStage.recognizing,
};
String _phaseLabel(String phase) => switch (phase) {
  'loading' => '加载模型',
  'preparing' => '准备音频',
  'denoising' => '降噪',
  'vad' => '检测语音',
  'aligning' => '时间精校',
  'punctuating' => '补标点',
  'refining' => '边界修整',
  'acceleration' => '选择计算设备',
  _ => '识别语音',
};

/// Audio preparation is supplied by the existing media pipeline, so all media
/// origins keep their leases, cancellation and decoding implementations.
typedef PrepareModelAudio =
    Future<String> Function(
      Duration start,
      Duration length,
      bool pcm,
      void Function(double) onProgress,
    );

class _PreparedAsrPiece {
  _PreparedAsrPiece({this.path, this.raw, this.audio, this.completed});
  final String? path;
  final List<SubtitleItem>? raw, completed;
  final TransferableTypedData? audio;
}

class ModelTranscriptionRunner {
  ModelTranscriptionRunner({
    ModelCenterService? center,
    Dio Function()? createDio,
    Dio Function()? createCloudDio,
    LocalAsrWorker Function()? createLocalWorker,
    Future<ModelDeviceInfo> Function()? loadDeviceInfo,
  }) : _createCloudDio = createCloudDio ?? createDio ??
           (() => NetworkHttp.instance.createDio(scope: NetworkScope.cloudTranscription)),
       center = center ?? ModelCenterService.instance,
       _createLocalWorker = createLocalWorker ?? LocalAsrWorker.new,
       _loadDeviceInfo = loadDeviceInfo ?? ModelDeviceInfo.load,
       _customDeviceInfo = loadDeviceInfo != null,
       _createDio =
           createDio ??
           (() => NetworkHttp.instance.createDio(
             scope: NetworkScope.speechRecognition,
           ));
  final ModelCenterService center;
  final Dio Function() _createDio;
  final Dio Function() _createCloudDio;
  final LocalAsrWorker Function() _createLocalWorker;
  final Future<ModelDeviceInfo> Function() _loadDeviceInfo;
  final bool _customDeviceInfo;

  Future<List<SubtitleItem>> run({
    required ModelJobSpec spec,
    required String sourceIdentity,
    String checkpointScope = '',
    required Duration duration,
    required PrepareModelAudio prepareAudio,
    PrepareCloudAsrAudio? prepareCloudAudio,
    Future<String> Function(
      Duration,
      Duration,
      AsrAudioChannel,
      void Function(double),
    )?
    prepareAudioChannel,
    required void Function(ModelProcessingProgress) onProgress,
    Future<void>? cancelSignal,
    Future<void> Function(StableAsrBatch)? onStableBatch,
    bool serializeConsumer = false,
    int consumerModelBytes = 0,
    int? consumerWorkingSetBytes,
    int consumerBatchSize = 8,
    int streamAssemblyVersion = 3,
    Future<void> Function()? onSessionClose,
    Future<void> Function()? onConsumerIdle,
    bool Function()? consumerHasResidentModel,
    InferenceResourceSession? resourceSession,
  }) async {
    final listener = onProgress;
    AsrProgressTracker? tracking;
    var reported = 0.0, workFinished = false;
    InferenceTuner? cpuTuner;
    Future<void> tune(LocalAsrWorker worker, Duration through) async {
      final tuner = cpuTuner, resources = InferenceResourceSession.current;
      if (tuner == null ||
          resources == null ||
          !resources.decision.allowTuning ||
          through <= Duration.zero ||
          through >= duration ||
          tracking?.backend != 'CPU') {
        return;
      }
      final usedMs = resources.productiveTime.inMilliseconds;
      final remaining =
          (usedMs * (duration.inMilliseconds / through.inMilliseconds - 1))
              .round();
      try {
        final selected = await tuner.explore(
          baseline: tracking?.actualAsrThreads ?? resources.decision.asrThreads,
          maximum:
              resources.decision.totalThreads -
              (resources.decision.pipeline ? 1 : 0),
          estimatedCostMs: worker.probeEstimateMs,
          remainingProductiveMs: remaining,
          probe: (candidate) async {
            onProgress(
              ModelProcessingProgress(
                ModelProcessingStage.loading,
                '本机调优 · 对照当前设备的线程配置',
                reported,
              ),
            );
            return worker.probeCpu(candidate, cancelSignal: cancelSignal);
          },
        );
        if (selected != null) resources.preferredAsrThreads = selected;
      } catch (_) {
        /* Optional probes never invalidate completed subtitles. */
      }
    }

    onProgress = (event) {
      final value = event.fraction.isFinite ? event.fraction : 0.0;
      reported = math.max(reported, value.clamp(0, workFinished ? 1 : .995));
      listener(
        ModelProcessingProgress(
          event.stage,
          event.message,
          spec.profile.local ? reported : event.fraction,
          local: tracking?.snapshot,
        ),
      );
    };
    var cancelled = false;
    final boundaryAudio = prepareAudio;
    final boundaryChannel = prepareAudioChannel;
    AudioChunkPrefetcher<String>? audioPrefetch;
    final pipelineAbort = Completer<void>();
    final workerCancellation = Future.any<void>([
      pipelineAbort.future,
      ?cancelSignal,
    ]);
    var finished = false;
    cancelSignal?.then((_) {
      if (!finished) cancelled = true;
    });
    void check() {
      if (cancelled) throw StateError('转录已取消');
    }

    final root = await center.storage.featureDirectory('model_jobs');
    File checkpointFor(String fingerprint) {
      final key = sha256
          .convert(
            utf8.encode(
              '$sourceIdentity${checkpointScope.isEmpty ? '' : '\nrun:$checkpointScope'}\n$fingerprint',
            ),
          )
          .toString();
      return File(p.join(root.path, 'asr-$key.json'));
    }

    final checkpoint = checkpointFor(spec.recognitionFingerprint);
    final pieces = AsrChunkMap();
    final enhanced = AsrChunkMap();
    final remote = <String, dynamic>{};
    int? savedChunkMs;
    var chunkDuration = spec.profile.local
        ? const Duration(minutes: 2)
        : const Duration(minutes: 10);
    final assembler = onStableBatch != null && spec.profile.local
        ? StreamingSubtitleAssembler(
            spec.subtitleSegmentation,
            version: streamAssemblyVersion,
          )
        : null;
    final streamed = <SubtitleItem>[];
    var retainConsumerModels = false;
    var nativePipeline = false;
    Future<void> Function()? releaseAsrForConsumer;
    Future<void> Function(Future<void> Function())? consumerBoundary;
    Future<void> Function(Future<void> Function())? residentConsumerBoundary;
    final pendingConsumer = LocalTranslationHandoffBuffer();
    final consumerQueue = BoundedModelConsumer(
      onFailure: () {
        cancelled = true;
        if (!pipelineAbort.isCompleted) pipelineAbort.complete();
      },
    );
    Future<void> deliverConsumer(
      StableAsrBatch batch, {
      required bool keepResident,
    }) async {
      check();
      if (!keepResident) await releaseAsrForConsumer?.call();
      tracking?.activity = keepResident ? '正在翻译' : '正在集中翻译';
      // One call lets the translator fill its bounded native batches instead
      // of repeatedly prefilling a prompt for every small recognition window.
      onProgress(
        ModelProcessingProgress(
          ModelProcessingStage.recognizing,
          '${tracking?.activity ?? '正在翻译'} · ${batch.cues.length} 条字幕',
          reported,
        ),
      );
      try {
        await onStableBatch!(batch);
      } finally {
        tracking?.activity = '';
        if (!keepResident) await onConsumerIdle?.call();
      }
    }

    Future<void> flushConsumer() async {
      consumerQueue.checkFailure();
      if (pendingConsumer.isEmpty) return;
      final resources = InferenceResourceSession.current;
      await resources?.refreshSnapshot?.call();
      final decision = resources?.decision;
      final keepResident =
          retainConsumerModels && (decision?.retainModels ?? true);
      final fits =
          consumerHasResidentModel?.call() == true ||
          resources?.admitsAdditional(
                consumerWorkingSetBytes ??
                    translationAllocationBytes(consumerModelBytes),
              ) ==
              true;
      final batch = pendingConsumer.drain(
        retainConsumerModels: true,
        pipelineAllowed: decision?.pipeline ?? true,
      );
      if (keepResident &&
          fits &&
          decision?.pipeline == true &&
          residentConsumerBoundary != null) {
        // Keep text preparation/publication off the exclusive native barrier.
        // The shared reservation still gives each LLM request exclusive CPU
        // time, allowing ASR to progress between bounded translation requests.
        await consumerQueue.submit(() async {
          if (!retainConsumerModels ||
              resources?.decision.retainModels == false) {
            await consumerBoundary!(
              () => deliverConsumer(batch, keepResident: false),
            );
            return;
          }
          try {
            await residentConsumerBoundary!(
              () => deliverConsumer(batch, keepResident: true),
            );
          } catch (error) {
            if (!isTransientInferencePressure(error)) rethrow;
            check();
            // Headroom can change after enqueueing. Leave the shared scope
            // before requesting the exclusive boundary, then retry from saved
            // cue checkpoints with only one large model resident at a time.
            retainConsumerModels = false;
            onProgress(
              ModelProcessingProgress(
                ModelProcessingStage.loading,
                '内存余量不足，已自动改为转录与翻译交替加载，正在继续',
                reported,
              ),
            );
            await consumerBoundary!(
              () => deliverConsumer(batch, keepResident: false),
            );
          }
        });
      } else {
        await consumerQueue.drain();
        Future<void> deliver() => deliverConsumer(
          batch,
          keepResident:
              keepResident &&
              (fits || consumerHasResidentModel?.call() == true),
        );
        await (consumerBoundary?.call(deliver) ?? deliver());
      }
    }

    bool consumerReady(Duration through) {
      final decision = InferenceResourceSession.current?.decision;
      return pendingConsumer.ready(
        keepResident: retainConsumerModels && (decision?.retainModels ?? true),
        batchLimit: math.min(
          consumerBatchSize.clamp(1, 8),
          decision?.translationBatchLimit ?? 8,
        ),
        protective: decision?.level == InferencePressureLevel.protective,
        endOfInput: through >= duration,
        processedThrough: through,
      );
    }

    Future<void> publish(
      List<SubtitleItem> cues,
      Duration start,
      Duration end, {
      RecognizeAsrBoundary? recognizeBoundary,
      bool windowOpen = false,
      bool overlapSpeech = false,
      Duration? pendingAudioStart,
    }) async {
      if (assembler == null) return;
      check();
      final stable = await assembler.add(
        cues,
        stableBefore: end - const Duration(seconds: 2),
        endOfInput: end >= duration,
        windowStart: start,
        windowEnd: end,
        recognizeBoundary: recognizeBoundary,
        windowOpen: windowOpen,
        overlapSpeech: overlapSpeech,
        pendingAudioStart: pendingAudioStart,
      );
      check();
      if (stable.isEmpty) {
        if (serializeConsumer && consumerReady(end)) await flushConsumer();
        return;
      }
      final batch = StableAsrBatch(
        stable,
        end,
        InferenceScheduler.instance.currentReservation,
        retainConsumerModels:
            retainConsumerModels &&
            (InferenceResourceSession.current?.decision.retainModels ?? true),
        nativePipeline:
            nativePipeline &&
            (InferenceResourceSession.current?.decision.pipeline ?? true),
      );
      if (serializeConsumer) {
        if (pendingConsumer.wouldOverflow(batch)) await flushConsumer();
        pendingConsumer.add(batch);
        if (consumerReady(end)) {
          await flushConsumer();
        }
      } else {
        await onStableBatch!(batch);
      }
      check();
      streamed.addAll(stable);
    }

    for (final fingerprint in spec.recognitionCacheFingerprints) {
      final legacy = await readStorageJson(checkpointFor(fingerprint));
      final journal = assembler == null
          ? null
          : await readAsrAppendCheckpoint(
              File('${checkpointFor(fingerprint).path}.appendlog'),
            );
      final candidate = journal == null
          ? legacy
          : {
              ...?legacy is Map ? Map<String, dynamic>.from(legacy) : null,
              'pieces': {
                ...?legacy is Map && legacy['pieces'] is Map
                    ? Map<String, dynamic>.from(legacy['pieces'] as Map)
                    : null,
                ...journal['pieces'] as Map,
              },
              'enhanced': {
                ...?legacy is Map && legacy['enhanced'] is Map
                    ? Map<String, dynamic>.from(legacy['enhanced'] as Map)
                    : null,
                ...journal['enhanced'] as Map,
              },
              'chunkDurationMs': journal['chunkDurationMs'],
            };
      if (candidate is! Map) continue;
      savedChunkMs ??= (candidate['chunkDurationMs'] as num?)?.toInt();
      if (candidate['pieces'] is Map) {
        for (final entry in (candidate['pieces'] as Map).entries) {
          pieces.putIfAbsent(entry.key as String, () => entry.value);
        }
      }
      if (candidate['enhanced'] is Map) {
        for (final entry in (candidate['enhanced'] as Map).entries) {
          enhanced.putIfAbsent(entry.key as String, () => entry.value);
        }
      }
      if (candidate['remote'] is Map) {
        for (final entry in (candidate['remote'] as Map).entries) {
          final current = remote[entry.key];
          final state = entry.value;
          if (state is! Map) continue;
          // A previous-generation backup may only say "submitting". A known
          // task ID in another supported checkpoint format takes precedence;
          // otherwise retain the uncertain-submit guard and never resubmit.
          // An explicit invalidation in the current format supersedes backups.
          if (current is! Map ||
              current['remoteReset'] != true &&
                  current['taskId'] == null &&
                  (state['taskId'] != null || current['submitting'] != true)) {
            remote[entry.key as String] = Map<String, dynamic>.from(state);
          }
        }
      }
    }
    pieces.changed.clear();
    enhanced.changed.clear();
    if (spec.profile.local && savedChunkMs == null) {
      for (final key in pieces.keys) {
        final first = RegExp(r'^0:(\d+)$').firstMatch(key);
        if (first != null) {
          final count = int.tryParse(first[1]!);
          if (count != null && count >= 30000) {
            savedChunkMs = count;
            break;
          }
        }
      }
    }
    if (spec.profile.local && savedChunkMs != null) {
      // Always longer than the two-second overlap, including old/bad metadata.
      chunkDuration = Duration(milliseconds: savedChunkMs.clamp(5000, 120000));
    }
    var saving = Future<void>.value();
    Future<void> save() {
      if (assembler != null) {
        final record = jsonEncode({
          'chunkDurationMs': chunkDuration.inMilliseconds,
          'pieces': pieces.takeChanges(),
          'enhanced': enhanced.takeChanges(),
        });
        return saving = saving.then((_) async {
          final file = File('${checkpoint.path}.appendlog');
          await file.parent.create(recursive: true);
          await file.writeAsString(
            '$record\n',
            mode: FileMode.append,
            flush: true,
          );
        });
      }
      final value = {
        'version': 2,
        'spec': spec.toJson(),
        'pieces': Map<String, dynamic>.of(pieces),
        'enhanced': Map<String, dynamic>.of(enhanced),
        'remote': remote,
        'chunkDurationMs': chunkDuration.inMilliseconds,
      };
      // Local cue payloads are replaced, never edited in place. Avoid a second
      // full JSON encode/decode of an ever-growing transcript on every stage.
      // Cloud task state can mutate while a write is queued, so snapshot it.
      final snapshot = spec.profile.local
          ? value
          : jsonDecode(jsonEncode(value));
      return saving = saving.then(
        (_) => writeStorageJson(checkpoint, snapshot),
      );
    }

    Future<List<SubtitleItem>> finish(List<SubtitleItem> output) async {
      check();
      await flushConsumer();
      await consumerQueue.drain();
      check();
      if (assembler != null) {
        workFinished = true;
        return streamed;
      }
      final merged = TranscriptionSubtitleMerger.finish(output);
      final grouping = spec.subtitleSegmentation;
      if (!spec.profile.local || grouping == null || !grouping.enabled) {
        workFinished = true;
        onProgress(
          const ModelProcessingProgress(
            ModelProcessingStage.saving,
            '识别与增强完成',
            1,
          ),
        );
        return merged;
      }
      onProgress(
        const ModelProcessingProgress(
          ModelProcessingStage.segmenting,
          '正在按时间轴与长度整理字幕分句',
          .995,
        ),
      );
      final result = await segmentAsrSubtitlesAsync(merged, grouping);
      check();
      workFinished = true;
      onProgress(
        const ModelProcessingProgress(
          ModelProcessingStage.segmenting,
          '字幕分句整理完成',
          1,
        ),
      );
      return result;
    }

    Future<List<SubtitleItem>> repairBoundary(
      LocalAsrWorker worker,
      LocalAsrWorker? enhancer,
      Duration start,
      Duration end,
    ) async {
      check();
      final key = 'boundary-3:${start.inMilliseconds}:${end.inMilliseconds}';
      final postKey = 'pipeline-2:${spec.enhancementFingerprint}';
      final complete = enhanced[key];
      if (complete is Map &&
          complete['fingerprint'] == postKey &&
          complete['cues'] is List &&
          (complete['cues'] as List).isNotEmpty) {
        return (complete['cues'] as List)
            .map((c) => SubtitleItem.fromTimingJson(c as Map))
            .toList();
      }
      final raw = pieces[key] is List && (pieces[key] as List).isNotEmpty
          ? (pieces[key] as List)
                .map((c) => SubtitleItem.fromTimingJson(c as Map))
                .toList()
          : null;
      final options = spec.asrEnhancements ?? AsrEnhancementOptions.disabled;
      final channel = options.enabled ? options.channel : AsrAudioChannel.mix;
      void progress(double value) {
        if (cancelled) return;
        onProgress(
          ModelProcessingProgress(
            ModelProcessingStage.refining,
            '正在重新识别音频交界，避免残词重复',
            reported,
          ),
        );
      }

      progress(0);
      final path = channel == AsrAudioChannel.mix
          ? await boundaryAudio(start, end - start, true, progress)
          : await boundaryChannel!(start, end - start, channel, progress);
      try {
        check();
        var cues = await worker.recognize(
          path,
          recognizedCues: raw,
          cancelSignal: workerCancellation,
          onProgress: progress,
          onRecognized: (value) async {
            if (value.isEmpty) return;
            pieces[key] = value.map((c) => c.toTimingJson()).toList();
            await save();
          },
        );
        if (enhancer != null) {
          final audio = worker.takePreparedAudio();
          if (audio == null) throw StateError('交界识别未交付增强音频');
          cues = await enhancer.recognize(
            path,
            recognizedCues: cues,
            preparedAudio: audio,
            cancelSignal: workerCancellation,
            onProgress: progress,
          );
        }
        check();
        final absolute = TranscriptionSubtitleMerger.placeSlice(
          relative: cues,
          sliceStart: start,
          sliceLength: end - start,
          overlap: Duration.zero,
        );
        if (absolute.isEmpty) {
          throw StateError('交界识别未返回字幕，已保留进度，可继续生成重试');
        }
        enhanced[key] = {
          'fingerprint': postKey,
          'cues': absolute.map((c) => c.toTimingJson()).toList(),
        };
        await save();
        return absolute;
      } finally {
        final file = File(path);
        if (await file.exists()) await file.delete();
      }
    }

    bool windowOpen(String key, Duration count) {
      final raw = pieces[key];
      if (raw is! List || raw.isEmpty) return false;
      // Use the original VAD/audio range, before alignment or silence trimming
      // can move the displayed cue end away from the forced audio cut.
      return (raw.last['e'] as num).toInt() >= count.inMilliseconds - 200;
    }

    bool overlapSpeech(String key) {
      final raw = pieces[key];
      return raw is List && raw.isNotEmpty && (raw.first['s'] as num) < 2000;
    }

    Duration? pendingAudioStart(String key, Duration start, Duration count) {
      final raw = pieces[key];
      if (raw is! List) return null;
      for (final cue in raw) {
        if ((cue['e'] as num) >= count.inMilliseconds - 2400) {
          return start + Duration(milliseconds: (cue['s'] as num).toInt());
        }
      }
      return null;
    }

    Future<List<SubtitleItem>> processPipeline(
      LocalAsrWorker recognizer,
      LocalAsrWorker enhancer, {
      required bool preprocessAhead,
      Map<String, String> directories = const {},
    }) async {
      final options = spec.asrEnhancements ?? AsrEnhancementOptions.disabled;
      final postKey = 'pipeline-2:${spec.enhancementFingerprint}';
      const overlap = Duration(seconds: 2);
      final slices =
          <({Duration start, Duration count, String key, int index})>[];
      for (var start = Duration.zero; start < duration;) {
        final count = Duration(
          microseconds: math.min(
            chunkDuration.inMicroseconds,
            (duration - start).inMicroseconds,
          ),
        );
        slices.add((
          start: start,
          count: count,
          key: '${start.inMilliseconds}:${count.inMilliseconds}',
          index: slices.length + 1,
        ));
        if (start + count >= duration) break;
        start += count - overlap;
      }
      var preparedMs = 0.0,
          recognizedMs = 0.0,
          enhancedMs = 0.0,
          reported = 0.0;
      void report(
        ModelProcessingStage stage,
        String message, {
        double? recognition,
        double? enhancement,
        double? preparation,
      }) {
        preparedMs = math.max(preparedMs, preparation ?? 0);
        recognizedMs = math.max(recognizedMs, recognition ?? 0);
        enhancedMs = math.max(enhancedMs, enhancement ?? 0);
        reported = math.max(
          reported,
          ((recognizedMs + enhancedMs + (preprocessAhead ? preparedMs : 0)) /
                  ((preprocessAhead ? 3 : 2) * duration.inMilliseconds))
              .clamp(0, .995),
        );
        onProgress(ModelProcessingProgress(stage, '流水线 · $message', reported));
      }

      final sideStage = ModelStageQueue();
      final handoff = ModelStageBarrier();
      consumerBoundary = (action) => handoff.exclusive(action);
      residentConsumerBoundary = (action) => handoff.shared(action);
      Future<T> native<T>(Future<T> Function() action) =>
          handoff.shared(action);
      Future<T> recognizeNative<T>(Future<T> Function() action) async {
        final resources = InferenceResourceSession.current;
        if (resources == null || recognizer.hasResidentPrimary) {
          return native(action);
        }
        // A cold load cannot race an auxiliary model's first allocation. This
        // boundary does not serialize subsequent decoding with cached weights.
        return handoff.exclusive(() async {
          await resources.refreshSnapshot?.call();
          if (!resources.admitsAdditional(recognizer.primaryAllocationBytes)) {
            resources.limitPipelineForMemory();
            tracking?.budget = resources.decision;
            await enhancer.releaseIdle();
          }
          return action();
        });
      }

      Future<T> enhanceNative<T>(
        List<SubtitleItem>? cues,
        Future<T> Function() action,
      ) async {
        final options = spec.asrEnhancements ?? AsrEnhancementOptions.disabled;
        final input = cues ?? const <SubtitleItem>[];
        List<String> alignmentIds(SubtitleItem cue) =>
            asrAlignmentModelCandidates(
              cue,
              spec.profile.language,
              availableModels: directories.keys,
              recognitionEngine:
                  center.artifact(spec.profile.model)?.engine ?? '',
              textProcessingVersion: spec.asrTextProcessingVersion,
            );
        bool align(SubtitleItem cue) =>
            options.enabled &&
            options.alignment &&
            (options.alwaysAlign || !hasUsableAsrTiming(cue)) &&
            alignmentIds(cue).any(directories.containsKey);
        final alignment = input
            .where(align)
            .expand(alignmentIds)
            .where(directories.containsKey)
            .where((id) => id != enhancer.residentAlignmentId)
            .fold<int>(
              0,
              (n, id) => math.max(
                n,
                asrAlignmentWorkingSetBytes(
                  id,
                  center.artifact(id)?.bytes ?? 0,
                  textProcessingVersion: spec.asrTextProcessingVersion,
                  recognitionEngine:
                      center.artifact(spec.profile.model)?.engine ?? '',
                  gpu:
                      (spec.asrAcceleration ?? AsrAcceleration.cpu) !=
                      AsrAcceleration.cpu,
                ),
              ),
            );
        final punctuationInput = spec.naturalPunctuationContext
            ? joinAsrContinuations(
                input,
                SubtitleSegmentationOptions.natural,
              ).toList()
            : input;
        final punctuation =
            options.enabled &&
                options.punctuation &&
                enhancer.residentPunctuationBytes == 0 &&
                directories.containsKey(AsrEnhancementOptions.punctuationId) &&
                punctuationInput.any(
                  (cue) =>
                      !RegExp(r'[。！？.!?]').hasMatch(cue.text) &&
                      (canRestoreAsrPunctuation(
                            cue,
                            spec.profile.language,
                            center.artifact(spec.profile.model)?.engine ?? '',
                            textProcessingVersion:
                                spec.asrTextProcessingVersion,
                          ) ||
                          usesAsrTextProcessing(
                                spec.asrTextProcessingVersion,
                              ) &&
                              asrAlignmentLanguage(
                                cue,
                                spec.profile.language,
                                textProcessingVersion: 1,
                              ).isEmpty ||
                          align(cue)),
                )
            ? (center.artifact(AsrEnhancementOptions.punctuationId)?.bytes ??
                      0) *
                  3
            : 0;
        final resources = InferenceResourceSession.current;
        final text =
            usesAsrTextProcessing(spec.asrTextProcessingVersion) &&
                options.enabled
            ? AsrTextProcessor.textWorkingSetBytes +
                  (center.artifact(AsrEnhancementOptions.languageId)?.bytes ??
                          0) *
                      3
            : 0;
        if (alignment + punctuation + text > 0) {
          await resources?.refreshSnapshot?.call();
        }
        final additional =
            alignment +
            punctuation +
            text +
            (recognizer.hasResidentPrimary
                ? 0
                : recognizer.primaryAllocationBytes);
        if (alignment + punctuation + text > 0 &&
            resources != null &&
            !resources.admitsAdditional(additional)) {
          // Wait for the current recognition to finish, then evict only idle
          // weights. Never free a native instance in use or wait on ourselves.
          try {
            return await handoff.exclusive(
              () => resources.memoryHandoff(() async {
                tracking?.budget = resources.decision;
                report(ModelProcessingStage.loading, '正在为字幕增强腾出内存');
                await recognizer.releaseIdle();
                return action();
              }),
            );
          } finally {
            tracking?.budget = resources.decision;
          }
        }
        return native(action);
      }

      Future<void> disposePiece(_PreparedAsrPiece prepared) async {
        if (prepared.path != null) {
          final file = File(prepared.path!);
          if (await file.exists()) await file.delete();
        }
      }

      Future<_PreparedAsrPiece> preparePiece(
        ({Duration start, Duration count, String key, int index}) slice,
      ) async {
        check();
        void preparation(String phase, double value) {
          if (preprocessAhead) {
            tracking?.preparing(slice.index, phase, value);
          } else {
            tracking?.front(slice.index, phase, value);
          }
        }

        preparation('准备音频', 0);
        final derived = enhanced[slice.key];
        final raw = pieces[slice.key] is List
            ? (pieces[slice.key] as List)
                  .map((e) => SubtitleItem.fromTimingJson(e as Map))
                  .toList()
            : null;
        if (options.enabled &&
            derived is Map &&
            derived['fingerprint'] == postKey &&
            derived['cues'] is List) {
          preparation('复用断点', 1);
          if (preprocessAhead) tracking?.preparedTo(slice.start + slice.count);
          report(
            ModelProcessingStage.loading,
            '复用片段断点',
            preparation: (slice.start + slice.count).inMilliseconds.toDouble(),
          );
          return _PreparedAsrPiece(
            completed: (derived['cues'] as List)
                .map((e) => SubtitleItem.fromTimingJson(e as Map))
                .toList(),
          );
        }
        if (!options.enabled && raw != null) {
          preparation('复用断点', 1);
          if (preprocessAhead) tracking?.preparedTo(slice.start + slice.count);
          report(
            ModelProcessingStage.loading,
            '复用片段断点',
            preparation: (slice.start + slice.count).inMilliseconds.toDouble(),
          );
          return _PreparedAsrPiece(completed: raw);
        }
        final channel = options.enabled ? options.channel : AsrAudioChannel.mix;
        if (channel != AsrAudioChannel.mix && prepareAudioChannel == null) {
          throw StateError('音频入口未提供声道选择');
        }
        void preparing(double value) {
          preparation('准备音频', value);
          report(
            ModelProcessingStage.preparing,
            '正在准备第 ${slice.index}/${slices.length} 块音频',
          );
        }

        final path = channel == AsrAudioChannel.mix
            ? await prepareAudio(slice.start, slice.count, true, preparing)
            : await prepareAudioChannel!(
                slice.start,
                slice.count,
                channel,
                preparing,
              );
        try {
          check();
          TransferableTypedData? audio;
          if (preprocessAhead) {
            audio = await sideStage.run(
              () => native(() async {
                check();
                await enhancer.recognize(
                  path,
                  prepareOnly: true,
                  cancelSignal: workerCancellation,
                  onPhase: (phase, value, message) {
                    preparation(_phaseLabel(phase), value);
                    final position = slice.start + slice.count * value;
                    if (phase == 'denoising') tracking?.preparedPart(position);
                    report(
                      _nativeStage(phase),
                      message,
                      preparation: phase == 'denoising'
                          ? position.inMilliseconds.toDouble()
                          : null,
                    );
                  },
                );
                final prepared = enhancer.takePreparedAudio();
                if (prepared == null) throw StateError('降噪阶段未交付音频');
                return prepared;
              }),
            );
            tracking?.preparedTo(slice.start + slice.count);
            report(
              ModelProcessingStage.denoising,
              '当前片段降噪完成',
              preparation: (slice.start + slice.count).inMilliseconds
                  .toDouble(),
            );
          }
          return _PreparedAsrPiece(path: path, raw: raw, audio: audio);
        } catch (_) {
          await disposePiece(_PreparedAsrPiece(path: path));
          rethrow;
        }
      }

      final prefetch = preprocessAhead
          ? ModelStagePrefetcher(
              inputs: slices,
              allowAhead: () =>
                  InferenceResourceSession.current?.decision.pipeline ?? true,
              prepare: preparePiece,
              dispose: disposePiece,
            )
          : null;
      Object? processingFailure;
      try {
        final results = await runBoundedModelPipeline(
          inputs: slices,
          currentCapacity: () =>
              InferenceResourceSession.current?.decision.pipeline == false
              ? 1
              : 2,
          abort: () {
            cancelled = true;
            if (!pipelineAbort.isCompleted) pipelineAbort.complete();
          },
          produce: (slice) async {
            final prepared = prefetch != null
                ? await prefetch.take(slice)
                : await preparePiece(slice);
            try {
              check();
              if (prepared.completed != null ||
                  prepared.raw != null && prepared.audio != null) {
                tracking?.front(slice.index, '复用断点', 1);
                tracking?.recognizedTo(slice.start + slice.count);
                return prepared;
              }
              tracking?.front(slice.index, '识别语音', 0);
              final decoded = await recognizeNative(() async {
                final cues = await recognizer.recognize(
                  prepared.path!,
                  recognizedCues: prepared.raw,
                  preparedAudio: prepared.audio,
                  cancelSignal: workerCancellation,
                  onRecognized: (value) async {
                    pieces[slice.key] = value
                        .map((c) => c.toTimingJson())
                        .toList();
                    await save();
                  },
                  onProgress: (v) {
                    if (v > .1) {
                      tracking?.front(slice.index, '识别语音', (v - .1) / .9);
                      tracking?.recognizedPart(
                        slice.start + slice.count * ((v - .1) / .9),
                      );
                    }
                    report(
                      ModelProcessingStage.recognizing,
                      preprocessAhead
                          ? '正在识别 · 下一块音频可同时降噪'
                          : '正在识别 · 上一片段可同时增强',
                      recognition:
                          slice.start.inMilliseconds +
                          slice.count.inMilliseconds * v,
                    );
                  },
                  onPhase: (phase, value, message) {
                    tracking?.front(slice.index, _phaseLabel(phase), value);
                    report(_nativeStage(phase), message);
                  },
                );
                await tune(recognizer, slice.start + slice.count);
                final audio = recognizer.takePreparedAudio();
                if (audio == null) throw StateError('识别阶段未交付增强所需音频');
                return (cues: cues, audio: audio);
              });
              tracking?.recognizedTo(slice.start + slice.count);
              report(
                ModelProcessingStage.recognizing,
                '当前片段识别完成',
                recognition: (slice.start + slice.count).inMilliseconds
                    .toDouble(),
              );
              return _PreparedAsrPiece(
                path: prepared.path,
                raw: decoded.cues,
                audio: decoded.audio,
              );
            } catch (_) {
              await disposePiece(prepared);
              rethrow;
            }
          },
          consume: (slice, prepared) async {
            check();
            tracking?.back(
              slice.index,
              prepared.completed != null ? '复用断点' : '准备增强',
              0,
            );
            final cues =
                prepared.completed ??
                await sideStage.run<List<SubtitleItem>>(
                  () => enhanceNative(prepared.raw, () async {
                    check();
                    return enhancer.recognize(
                      prepared.path!,
                      recognizedCues: prepared.raw,
                      preparedAudio: prepared.audio,
                      cancelSignal: workerCancellation,
                      onPhase: (phase, value, message) {
                        tracking?.back(slice.index, _phaseLabel(phase), value);
                        report(
                          switch (phase) {
                            'aligning' => ModelProcessingStage.aligning,
                            'punctuating' => ModelProcessingStage.punctuating,
                            _ => ModelProcessingStage.refining,
                          },
                          message,
                          enhancement:
                              slice.start.inMilliseconds +
                              slice.count.inMilliseconds *
                                  switch (phase) {
                                    'aligning' => value * .8,
                                    'punctuating' => .8 + value * .16,
                                    _ => .96 + value * .04,
                                  },
                        );
                      },
                    );
                  }),
                );
            if (prepared.completed == null) {
              enhanced[slice.key] = {
                'fingerprint': postKey,
                'cues': cues.map((c) => c.toTimingJson()).toList(),
              };
              await save();
            }
            tracking?.completed(
              slice.start + slice.count,
              reused: prepared.completed != null,
            );
            report(
              ModelProcessingStage.recognizing,
              '已保存片段断点',
              recognition: (slice.start + slice.count).inMilliseconds
                  .toDouble(),
              enhancement: (slice.start + slice.count).inMilliseconds
                  .toDouble(),
            );
            final placed = TranscriptionSubtitleMerger.placeSlice(
              relative: cues,
              sliceStart: slice.start,
              overlap: assembler != null && streamAssemblyVersion >= 2
                  ? Duration.zero
                  : slice.start == Duration.zero
                  ? Duration.zero
                  : overlap,
              sliceLength: slice.count,
            );
            Future<void> deliver() => publish(
              placed,
              slice.start,
              slice.start + slice.count,
              recognizeBoundary: (start, end) {
                Future<List<SubtitleItem>> repair() =>
                    repairBoundary(recognizer, enhancer, start, end);
                return handoff.exclusive(repair);
              },
              windowOpen: windowOpen(slice.key, slice.count),
              overlapSpeech: overlapSpeech(slice.key),
              pendingAudioStart: pendingAudioStart(
                slice.key,
                slice.start,
                slice.count,
              ),
            );
            // A buffered local batch performs no inference. Drain native work
            // only for actual seam repair or the eventual LLM handoff, so the
            // next denoise block can still overlap ongoing recognition.
            await deliver();
            return assembler == null ? placed : <SubtitleItem>[];
          },
          dispose: (slice, prepared) => disposePiece(prepared),
        );
        return await finish(results.expand((c) => c).toList());
      } catch (error) {
        processingFailure = error;
        rethrow;
      } finally {
        await prefetch?.close();
        await sideStage.drained;
        try {
          await consumerQueue.drain();
        } catch (_) {
          // A recognition/storage failure can cancel a queued consumer before
          // it starts. Keep that concrete failure instead of replacing it with
          // the consumer's resulting "cancelled" error. If the consumer itself
          // caused the abort, surface its original failure after native drains.
          if (processingFailure == null ||
              processingFailure is StateError &&
                  const {
                    '转录已取消',
                    '任务已取消',
                  }.contains(processingFailure.message)) {
            rethrow;
          }
        }
      }
    }

    Future<List<SubtitleItem>> process(LocalAsrWorker? worker) async {
      final output = <SubtitleItem>[];
      final options = spec.asrEnhancements ?? AsrEnhancementOptions.disabled;
      final postKey = 'pipeline-2:${spec.enhancementFingerprint}';
      final length = chunkDuration;
      const overlap = Duration(seconds: 2);
      var index = 0;
      for (var start = Duration.zero; start < duration;) {
        check();
        index++;
        tracking?.front(index, '准备音频', 0);
        var reused = false;
        final count = Duration(
          microseconds: math.min(
            length.inMicroseconds,
            (duration - start).inMicroseconds,
          ),
        );
        final pieceKey = '${start.inMilliseconds}:${count.inMilliseconds}';
        final derived = enhanced[pieceKey];
        final raw = pieces[pieceKey] is List
            ? (pieces[pieceKey] as List)
                  .map((e) => SubtitleItem.fromTimingJson(e as Map))
                  .toList()
            : null;
        List<SubtitleItem> cues;
        if (worker != null &&
            options.enabled &&
            derived is Map &&
            derived['fingerprint'] == postKey &&
            derived['cues'] is List) {
          cues = (derived['cues'] as List)
              .map((e) => SubtitleItem.fromTimingJson(e as Map))
              .toList();
          reused = true;
        } else if (raw != null && (worker == null || !options.enabled)) {
          cues = raw;
          reused = true;
        } else {
          onProgress(
            ModelProcessingProgress(
              ModelProcessingStage.preparing,
              '正在准备 ${start.inMinutes} 分钟处的音频',
              start.inMilliseconds / duration.inMilliseconds,
            ),
          );
          void preparing(double value) {
            tracking?.front(index, '准备音频', value);
            onProgress(
              ModelProcessingProgress(
                ModelProcessingStage.preparing,
                '正在准备音频 ${(value * 100).round()}%',
                start.inMilliseconds / duration.inMilliseconds,
              ),
            );
          }

          final channel = options.enabled
              ? options.channel
              : AsrAudioChannel.mix;
          if (worker != null &&
              channel != AsrAudioChannel.mix &&
              prepareAudioChannel == null) {
            throw StateError('音频入口未提供声道选择');
          }
          final path = worker != null && channel != AsrAudioChannel.mix
              ? await prepareAudioChannel!(start, count, channel, preparing)
              : await prepareAudio(start, count, spec.profile.local, preparing);
          try {
            check();
            if (worker != null) {
              cues = await worker.recognize(
                path,
                cancelSignal: cancelSignal,
                recognizedCues: raw,
                onRecognized: (recognized) async {
                  tracking?.recognizedTo(start + count);
                  pieces[pieceKey] = recognized
                      .map((e) => e.toTimingJson())
                      .toList();
                  await save();
                },
                onPhase: (phase, value, message) {
                  if (const [
                    'aligning',
                    'punctuating',
                    'refining',
                  ].contains(phase)) {
                    tracking?.back(index, _phaseLabel(phase), value);
                  } else {
                    tracking?.front(index, _phaseLabel(phase), value);
                  }
                  final (stage, from, width) = switch (phase) {
                    'acceleration' => (
                      ModelProcessingStage.recognizing,
                      options.enabled ? .08 : 0.0,
                      options.enabled ? .44 : 1.0,
                    ),
                    'denoising' => (ModelProcessingStage.denoising, 0.0, .08),
                    'loading' => (ModelProcessingStage.loading, .08, 0.0),
                    'vad' => (ModelProcessingStage.detectingSpeech, .08, .04),
                    'recognizing' => (
                      ModelProcessingStage.recognizing,
                      .12,
                      .4,
                    ),
                    'aligning' => (ModelProcessingStage.aligning, .52, .28),
                    'punctuating' => (
                      ModelProcessingStage.punctuating,
                      .8,
                      .18,
                    ),
                    _ => (ModelProcessingStage.refining, .98, .02),
                  };
                  onProgress(
                    ModelProcessingProgress(
                      stage,
                      message,
                      ((start.inMilliseconds +
                                  count.inMilliseconds *
                                      (from + value * width)) /
                              duration.inMilliseconds)
                          .clamp(0, 1),
                    ),
                  );
                },
                onProgress: (value) {
                  if (value > .1) {
                    tracking?.front(index, '识别语音', (value - .1) / .9);
                    tracking?.recognizedPart(
                      start + count * ((value - .1) / .9),
                    );
                  }
                  final fraction = options.enabled ? .08 + value * .44 : value;
                  onProgress(
                    ModelProcessingProgress(
                      ModelProcessingStage.recognizing,
                      '${spec.profile.name} · 已处理 ${((start.inSeconds + count.inSeconds * value) / 60).toStringAsFixed(1)} / ${(duration.inSeconds / 60).toStringAsFixed(1)} 分钟',
                      ((start.inMilliseconds +
                                  count.inMilliseconds * fraction) /
                              duration.inMilliseconds)
                          .clamp(0, 1),
                    ),
                  );
                },
              );
              await tune(worker, start + count);
              // Keep native recognition and derived timing/text separately.
              // Changing punctuation/alignment can reuse raw ASR.
              if (!pieces.containsKey(pieceKey)) {
                pieces[pieceKey] = cues.map((e) => e.toTimingJson()).toList();
              }
              enhanced[pieceKey] = {
                'fingerprint': postKey,
                'cues': cues.map((e) => e.toTimingJson()).toList(),
              };
            } else {
              final token = CancelToken();
              var requestFinished = false;
              cancelSignal?.then((_) {
                if (!requestFinished) token.cancel('任务已取消');
              });
              try {
                cues = await _cloud(spec, path, token, remote, pieceKey, save, (
                  stage,
                  message,
                ) {
                  onProgress(
                    ModelProcessingProgress(
                      stage,
                      message,
                      start.inMilliseconds / duration.inMilliseconds,
                    ),
                  );
                });
              } finally {
                requestFinished = true;
              }
            }
            check();
            if (worker == null) {
              pieces[pieceKey] = cues.map((e) => e.toTimingJson()).toList();
            }
            await save();
          } finally {
            final file = File(path);
            if (await file.exists()) await file.delete();
          }
        }
        final placed = TranscriptionSubtitleMerger.placeSlice(
          relative: cues,
          sliceStart: start,
          overlap: assembler != null && streamAssemblyVersion >= 2
              ? Duration.zero
              : start == Duration.zero
              ? Duration.zero
              : overlap,
          sliceLength: count,
        );
        if (assembler == null) output.addAll(placed);
        await publish(
          placed,
          start,
          start + count,
          recognizeBoundary: worker == null
              ? null
              : (from, to) => repairBoundary(worker, null, from, to),
          windowOpen: worker != null && windowOpen(pieceKey, count),
          overlapSpeech: worker != null && overlapSpeech(pieceKey),
          pendingAudioStart: worker == null
              ? null
              : pendingAudioStart(pieceKey, start, count),
        );
        tracking?.back(index, reused ? '复用断点' : '已完成', 1);
        tracking?.completed(start + count, reused: reused);
        onProgress(
          ModelProcessingProgress(
            ModelProcessingStage.recognizing,
            '已保存当前片段断点',
            ((start + count).inMilliseconds / duration.inMilliseconds).clamp(
              0,
              1,
            ),
          ),
        );
        if (start + count >= duration) break;
        start += count - overlap;
      }
      return finish(output);
    }

    void enableAudioPrefetch() {
      final directPrepare = prepareAudio;
      final directChannel = prepareAudioChannel;
      final options = spec.asrEnhancements ?? AsrEnhancementOptions.disabled;
      final channel = spec.profile.local && options.enabled
          ? options.channel
          : AsrAudioChannel.mix;
      final windows = <String, ({Duration start, Duration count, int index})>{};
      var index = 0;
      for (var start = Duration.zero; start < duration;) {
        final count = Duration(
          microseconds: math.min(
            chunkDuration.inMicroseconds,
            (duration - start).inMicroseconds,
          ),
        );
        final key = '${start.inMilliseconds}:${count.inMilliseconds}';
        index++;
        final derived = enhanced[key];
        final complete = spec.profile.local && options.enabled
            ? derived is Map &&
                  derived['fingerprint'] ==
                      'pipeline-2:${spec.enhancementFingerprint}' &&
                  derived['cues'] is List
            : pieces[key] is List;
        if (!complete) {
          windows[key] = (start: start, count: count, index: index);
        }
        if (start + count >= duration) break;
        start += count - const Duration(seconds: 2);
      }
      if (windows.length < 2) return;
      if (channel != AsrAudioChannel.mix && directChannel == null) return;
      audioPrefetch = AudioChunkPrefetcher(
        inputs: windows.keys,
        allowAhead: () =>
            InferenceResourceSession.current?.decision.allowAudioPrefetch ??
            true,
        prepare: (key, progress) {
          check();
          final slice = windows[key]!;
          return channel == AsrAudioChannel.mix
              ? directPrepare(
                  slice.start,
                  slice.count,
                  spec.profile.local,
                  progress,
                )
              : directChannel!(slice.start, slice.count, channel, progress);
        },
        onState: (key, value, ready) {
          if (cancelled) return;
          if (key == null) {
            tracking?.audioPreparation = '';
            return;
          }
          tracking?.audioPreparation =
              '音频预读 · 第 ${windows[key]!.index} 块 · '
              '${ready ? '已就绪' : '${(value * 100).floor()}%'}';
        },
      );
      prepareAudio = (start, count, pcm, progress) => audioPrefetch!.take(
        '${start.inMilliseconds}:${count.inMilliseconds}',
        progress,
      );
      prepareAudioChannel = (start, count, channel, progress) => audioPrefetch!
          .take('${start.inMilliseconds}:${count.inMilliseconds}', progress);
    }

    try {
      if (spec.profile.cloudProvider case final provider?) {
        final profile = spec.profile;
        final adapter = CloudAsrAdapter.create(CloudAsrConnection(
          provider: provider, endpoint: profile.endpoint.isEmpty ? provider.endpoint : profile.endpoint,
          model: profile.model, apiKey: await center.readSecret(profile.id), language: profile.language,
          options: profile.cloudOptions ?? const CloudAsrOptions(),
          capabilities: profile.cloudCapabilities ?? cloudAsrCapabilities(provider, profile.model)),
          dio: _createCloudDio());
        final token = CancelToken();
        cancelSignal?.then((_) { if (!finished) token.cancel('转录已取消'); });
        try {
          final pipeline = CloudAsrPipeline(adapter: adapter,
            prepare: prepareCloudAudio ?? (start, length, force, progress) async =>
              CloudAsrAudio(await prepareAudio(start, length, false, progress)),
            pieces: pieces, remote: remote, save: save, token: token,
            progress: (phase, message, fraction) => onProgress(ModelProcessingProgress(
              switch (phase) {
                'preparing' => ModelProcessingStage.preparing,
                'uploading' => ModelProcessingStage.uploading,
                'waiting' => ModelProcessingStage.waiting,
                _ => ModelProcessingStage.recognizing,
              }, message, fraction ?? reported)));
          final result = await pipeline.run(duration, onStable: onStableBatch == null ? null :
            (cues, through) async {
              final windows = cloudTranslationBatches(cues).toList();
              for (var i = 0; i < windows.length; i++) {
                final window = windows[i];
                await onStableBatch(StableAsrBatch(window.cues,
                  i + 1 == windows.length ? through : window.processedThrough,
                  null, retainConsumerModels: true));
              }
            });
          return await finish(result);
        } finally { adapter.close(); }
      }
      if (!spec.profile.local) {
        enableAudioPrefetch();
        return await process(null);
      }
      final vad = await center.prepareAsrModels(
        spec,
        cancelSignal: cancelSignal,
        onProgress: (message) => onProgress(
          ModelProcessingProgress(ModelProcessingStage.downloading, message, 0),
        ),
      );
      check();
      onProgress(
        const ModelProcessingProgress(
          ModelProcessingStage.loading,
          '等待本地推理资源',
          0,
        ),
      );
      final initialDevice = await _loadDeviceInfo();
      return await InferenceScheduler.instance.run(
        () => center.usingAsrModels(spec, (model, dir, directories) async {
          if (model.identity != spec.artifactIdentity) {
            throw StateError('任务要求的模型版本已变更，请重新创建任务');
          }
          check();
          final resources = InferenceResourceSession.current!;
          final snapshot = resources.governor.snapshot;
          final device = _customDeviceInfo
              ? initialDevice
              : ModelDeviceInfo(
                  processors: snapshot.effectiveProcessors,
                  memoryBytes:
                      snapshot.memoryBytes ?? initialDevice.memoryBytes,
                  availableMemoryBytes: snapshot.availableMemoryBytes,
                );
          resources.asrMaximum = spec.requestedAsrThreads;
          final enhancementBytes = directories.keys
              .where(
                (id) =>
                    center.artifact(id)?.purpose == ModelPurpose.enhancement,
              )
              .fold<int>(0, (n, id) => n + (center.artifact(id)?.bytes ?? 0));
          final chosenPlan = AsrExecutionPlan.choose(
            device: device,
            platform: Platform.operatingSystem,
            requestedThreads: spec.requestedAsrThreads,
            hasDenoising:
                spec.asrEnhancements?.enabled == true &&
                spec.asrEnhancements!.denoise,
            hasPostProcessing:
                spec.asrEnhancements?.enabled == true &&
                (spec.asrEnhancements!.alignment ||
                    spec.asrEnhancements!.punctuation ||
                    spec.asrEnhancements!.trimSilence),
            modelBytes: model.bytes,
            enhancementBytes: enhancementBytes,
            alignmentBytes: directories.keys
                .where((id) => AsrEnhancementOptions.isAlignmentModel(id))
                .fold<int>(
                  0,
                  (n, id) => math.max(n, center.artifact(id)?.bytes ?? 0),
                ),
            lightweightEnhancementBytes: directories.keys
                .where(
                  (id) =>
                      center.artifact(id)?.purpose ==
                          ModelPurpose.enhancement &&
                      !AsrEnhancementOptions.isAlignmentModel(id),
                )
                .fold<int>(0, (n, id) => n + (center.artifact(id)?.bytes ?? 0)),
            mode: spec.asrExecution,
          );
          final plan = serializeConsumer
              ? chosenPlan.withLocalTranslation(
                  device: device,
                  platform: Platform.operatingSystem,
                  modelBytes: model.bytes,
                  translationBytes: consumerModelBytes,
                  translationWorkingSetBytes: consumerWorkingSetBytes,
                  alignmentBytes: directories.keys
                      .where((id) => AsrEnhancementOptions.isAlignmentModel(id))
                      .fold<int>(
                        0,
                        (size, id) =>
                            math.max(size, center.artifact(id)?.bytes ?? 0),
                      ),
                  lightweightBytes: directories.keys
                      .where(
                        (id) =>
                            center.artifact(id)?.purpose ==
                                ModelPurpose.enhancement &&
                            !AsrEnhancementOptions.isAlignmentModel(id),
                      )
                      .fold<int>(
                        0,
                        (size, id) => size + (center.artifact(id)?.bytes ?? 0),
                      ),
                  mode: spec.asrExecution,
                )
              : chosenPlan;
          resources.pipelineRequested = plan.pipeline;
          retainConsumerModels = serializeConsumer && plan.retainTranslation;
          nativePipeline = plan.pipeline;
          check();
          if (savedChunkMs == null) {
            chunkDuration = assembler != null
                ? const Duration(seconds: 30)
                : plan.chunkDuration;
          }
          tracking = AsrProgressTracker(
            model: model.name,
            total: duration,
            plan: plan,
            pieces: duration <= chunkDuration
                ? (duration > Duration.zero ? 1 : 0)
                : 1 +
                      ((duration.inMilliseconds -
                                  chunkDuration.inMilliseconds) /
                              (chunkDuration.inMilliseconds - 2000))
                          .ceil(),
          );
          tracking!.budget = resources.decision;
          if (plan.reuseModels && device.processors >= 4) enableAudioPrefetch();
          final accelerationEnvironment =
              spec.asrAcceleration != null &&
                  spec.asrAcceleration != AsrAcceleration.cpu
              ? await AsrAcceleratorTransport.environment()
              : null;
          check();
          if (spec.requestedAsrThreads == 0) {
            cpuTuner = InferenceTuner(
              session: resources,
              records: center.inferenceTuning,
              modelId: model.id,
              signature: inferenceTuningSignature(
                resources,
                model.identity,
                model.engine == 'parakeet-ja'
                    ? 'parakeet-ja-native-q8-v1'
                    : model.engine == 'cohere-asr'
                    ? 'cohere-transcribe-0.4.1-q8-v1'
                    : model.engine == 'qwen3-asr'
                    ? 'qwen3-asr-fp16-v1'
                    : 'sherpa-onnx-1.12.12',
                environment: accelerationEnvironment,
                configuration: spec.recognitionFingerprint,
              ),
              save: center.save,
            );
            resources.preferredAsrThreads = cpuTuner!.preferredThreads;
          }
          final worker = _createLocalWorker();
          worker.configureResources(
            resources,
            modelBytes: model.bytes,
            modelLabel: model.name,
            workingSetBytes: model.engine == 'cohere-asr'
                ? cohereAudioWorkingSetBytes(model.bytes)
                : model.engine == 'parakeet-ja'
                ? parakeetJapaneseWorkingSetBytes(model.bytes)
                : null,
          );
          worker.onBudget = (lane, threads, budget) =>
              tracking?.configure(lane, threads, budget);
          {
            final packId = asrAccelerationPackId(model.id);
            worker.configureAcceleration(
              {
                'automaticTuningAllowed': false,
                'mode': (spec.asrAcceleration ?? AsrAcceleration.cpu).name,
                'legacy': spec.asrAcceleration == null,
                'accelerationEnvironment': ?accelerationEnvironment,
                'modelId': model.id,
                'identity': model.identity,
                'durationSeconds': duration.inMilliseconds / 1000,
                'pipeline': plan.pipeline,
                'reuseModels':
                    plan.reuseModels &&
                    (spec.asrEnhancements?.alwaysAlign != true) &&
                    model.engine != 'dolphin',
                'chunkSeconds': chunkDuration.inMilliseconds / 1000,
                'audioConfiguration':
                    (spec.asrEnhancements ?? AsrEnhancementOptions.disabled)
                        .audioJson,
                'availableMemoryBytes': device.availableMemoryBytes,
                'gpuAllowed':
                    device.availableMemoryBytes != null ||
                    (!Platform.isAndroid &&
                        !Platform.isIOS &&
                        (device.memoryGb ?? 0) >= 16),
                'gpuAvailableMemoryBytes': device.availableMemoryBytes == null
                    ? null
                    : math.max(
                        0,
                        device.availableMemoryBytes! -
                            enhancementBytes * 3 -
                            1073741824,
                      ),
                'modelBytes': model.bytes,
                'decoding': spec.asrEnhancements?.enabled == true
                    ? spec.asrEnhancements!.hotwords.trim()
                    : '',
                if (directories[packId] != null) ...{
                  'gpuDirectory': directories[packId],
                  'gpuIdentity': spec.asrAccelerationModels[packId],
                  'gpuModelBytes': center.artifact(packId)?.bytes,
                },
                'profiles': [
                  for (final entry in center.asrPerformance.entries)
                    if (entry.key.startsWith('${model.id}:'))
                      entry.value.toJson(),
                ],
              },
              onState: (state) {
                tracking?.backend = state['backend'] as String? ?? 'CPU';
                unawaited(
                  center
                      .recordAsrState(model.id, state)
                      .catchError((Object _) {}),
                );
              },
            );
          }
          LocalAsrWorker? postWorker;
          releaseAsrForConsumer = () async {
            await worker.releaseIdle();
            await postWorker?.releaseIdle();
          };
          onProgress(
            ModelProcessingProgress(
              ModelProcessingStage.loading,
              '正在加载 ${model.name}',
              0,
            ),
          );
          try {
            await worker.start(
              engine: model.engine,
              directory: dir.path,
              vadPath: vad.path,
              language: spec.profile.language,
              threads: plan.asrThreads,
              stage: plan.pipeline
                  ? LocalAsrStage.recognition
                  : LocalAsrStage.complete,
              retainModels: plan.reuseModels,
              enhancements:
                  spec.asrEnhancements ?? AsrEnhancementOptions.disabled,
              enhancementDirectories: directories,
              naturalPunctuationContext: spec.naturalPunctuationContext,
              textProcessingVersion: spec.asrTextProcessingVersion,
              qwenAcceleration:
                  (spec.asrAcceleration ?? AsrAcceleration.cpu).name,
              runtimeDirectory: root.path,
            );
            check();
            if (plan.pipeline) {
              postWorker = _createLocalWorker();
              postWorker.configureResources(resources);
              postWorker.onBudget = (lane, threads, budget) =>
                  tracking?.configure(lane, threads, budget);
              await postWorker.start(
                engine: model.engine,
                directory: dir.path,
                vadPath: vad.path,
                language: spec.profile.language,
                threads: plan.enhancementThreads,
                stage: LocalAsrStage.enhancement,
                retainModels: true,
                enhancements:
                    spec.asrEnhancements ?? AsrEnhancementOptions.disabled,
                enhancementDirectories: directories,
                naturalPunctuationContext: spec.naturalPunctuationContext,
                textProcessingVersion: spec.asrTextProcessingVersion,
                qwenAcceleration:
                    (spec.asrAcceleration ?? AsrAcceleration.cpu).name,
                runtimeDirectory: root.path,
              );
              onProgress(
                ModelProcessingProgress(
                  ModelProcessingStage.loading,
                  plan.reason,
                  0,
                ),
              );
              return await processPipeline(
                worker,
                postWorker,
                preprocessAhead: plan.preprocessAhead,
                directories: directories,
              );
            }
            onProgress(
              ModelProcessingProgress(
                ModelProcessingStage.loading,
                plan.reason,
                0,
              ),
            );
            return await process(worker);
          } finally {
            if (!pipelineAbort.isCompleted) pipelineAbort.complete();
            try {
              await postWorker?.close();
            } finally {
              try {
                await worker.close();
              } finally {
                await onSessionClose?.call();
              }
            }
          }
        }),
        cancelSignal: cancelSignal,
        resources:
            resourceSession ??
            (_customDeviceInfo
                ? InferenceResourceSession(
                    InferenceResourceGovernor(
                      DeviceResourceSnapshot(
                        platform: Platform.operatingSystem,
                        processors: initialDevice.processors,
                        memoryBytes: initialDevice.memoryBytes,
                        availableMemoryBytes:
                            initialDevice.availableMemoryBytes,
                        capturedAt: DateTime.now(),
                      ),
                    ),
                  )
                : null),
      );
    } finally {
      await audioPrefetch?.close();
      finished = true;
    }
  }

  Future<List<SubtitleItem>> _cloud(
    ModelJobSpec spec,
    String path,
    CancelToken token,
    Map<String, dynamic> remote,
    String pieceKey,
    Future<void> Function() save,
    void Function(ModelProcessingStage, String) progress,
  ) async {
    final profile = spec.profile;
    final secret = await center.readSecret(profile.id);
    if (secret.isEmpty && profile.kind != TranscriptionServiceKind.openai) {
      throw StateError('请在模型中心填写服务密钥');
    }
    final dio = _createDio();
    dio.options.connectTimeout = const Duration(seconds: 30);
    dio.options.receiveTimeout = const Duration(minutes: 15);
    try {
      if (profile.kind == TranscriptionServiceKind.openai) {
        final endpoint = Uri.parse(profile.endpoint);
        if (!endpoint.hasAuthority ||
            !{'http', 'https'}.contains(endpoint.scheme)) {
          throw StateError('转录接口地址无效');
        }
        final form = FormData.fromMap({
          'model': profile.model,
          'response_format': 'verbose_json',
          if (profile.language != 'auto') 'language': profile.language,
          'file': await MultipartFile.fromFile(
            path,
            filename: p.basename(path),
          ),
        });
        progress(ModelProcessingStage.uploading, '正在上传至 ${profile.name}');
        final response = await dio.post<dynamic>(
          endpoint.toString(),
          data: form,
          options: Options(
            headers: {if (secret.isNotEmpty) 'Authorization': 'Bearer $secret'},
          ),
          cancelToken: token,
          onSendProgress: (done, total) => progress(
            done == total
                ? ModelProcessingStage.waiting
                : ModelProcessingStage.uploading,
            done == total
                ? '服务正在识别音频'
                : '正在上传 ${(done / math.max(total, 1) * 100).floor()}%',
          ),
        );
        if (response.data is String) {
          final text = (response.data as String).trim();
          if (text.startsWith('{')) {
            return parseCloudCues(
              jsonDecode(text),
              TranscriptionServiceKind.openai,
            );
          }
          final cues = SubtitleParser.parse(text);
          if (cues.isEmpty && text.isNotEmpty) {
            throw const FormatException('接口没有返回带时间轴的字幕');
          }
          return cues;
        }
        return parseCloudCues(response.data, TranscriptionServiceKind.openai);
      }
      if (profile.kind == TranscriptionServiceKind.tencent) {
        final keys = jsonDecode(secret) as Map;
        final parameters = <String, String>{
          'engine_type': profile.model,
          'first_channel_only': '1',
          'secretid': keys['secretId'] as String,
          'timestamp': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
          'voice_format': p.extension(path).toLowerCase() == '.wav'
              ? 'wav'
              : 'm4a',
          'word_info': '2',
        };
        final query = tencentSignatureQuery(parameters);
        final signature = base64Encode(
          Hmac(sha1, utf8.encode(keys['secretKey'] as String))
              .convert(
                utf8.encode(
                  'POSTasr.cloud.tencent.com/asr/flash/v1/${profile.appId}?$query',
                ),
              )
              .bytes,
        );
        final file = File(path);
        progress(ModelProcessingStage.uploading, '正在上传至腾讯云');
        final response = await dio.post<dynamic>(
          'https://asr.cloud.tencent.com/asr/flash/v1/${profile.appId}?$query',
          data: file.openRead(),
          cancelToken: token,
          options: Options(
            headers: {
              'Authorization': signature,
              'Content-Type': 'application/octet-stream',
              'Content-Length': await file.length(),
            },
          ),
          onSendProgress: (done, total) => progress(
            done == total
                ? ModelProcessingStage.waiting
                : ModelProcessingStage.uploading,
            done == total
                ? '腾讯云正在识别音频'
                : '正在上传 ${(done / math.max(total, 1) * 100).floor()}%',
          ),
        );
        return parseCloudCues(response.data, TranscriptionServiceKind.tencent);
      }
      if (profile.kind == TranscriptionServiceKind.aliyun) {
        final base = Uri.parse(profile.endpoint);
        if (base.scheme != 'https' || !base.hasAuthority) {
          throw StateError('百炼地址必须是 HTTPS 服务根地址');
        }
        final authorization = Options(
          headers: {'Authorization': 'Bearer $secret'},
        );
        final state = Map<String, dynamic>.from(remote[pieceKey] as Map? ?? {});
        Future<void> invalidateTask() async {
          state.remove('taskId');
          state.remove('submitting');
          state['remoteReset'] = true;
          remote[pieceKey] = state;
          await save();
        }
        var taskId = state['taskId'] as String?;
        if (taskId == null) {
          if (state['submitting'] == true) {
            throw StateError('上次提交结果未知，请先在平台查询任务，避免重复计费');
          }
          progress(ModelProcessingStage.uploading, '正在申请百炼临时上传凭证');
          final policyResponse = await dio.get<dynamic>(
            base.resolve('/api/v1/uploads').toString(),
            queryParameters: {'action': 'getPolicy', 'model': profile.model},
            options: authorization,
            cancelToken: token,
          );
          final policy = (policyResponse.data as Map)['data'] as Map;
          final objectKey =
              '${policy['upload_dir']}/${DateTime.now().microsecondsSinceEpoch}${p.extension(path)}';
          final form = FormData.fromMap({
            'OSSAccessKeyId': policy['oss_access_key_id'],
            'Signature': policy['signature'],
            'policy': policy['policy'],
            'key': objectKey,
            'x-oss-object-acl': policy['x_oss_object_acl'] ?? 'private',
            'x-oss-forbid-overwrite':
                policy['x_oss_forbid_overwrite'] ?? 'true',
            'success_action_status': '200',
            'file': await MultipartFile.fromFile(
              path,
              filename: p.basename(objectKey),
            ),
          });
          await dio.post<dynamic>(
            policy['upload_host'] as String,
            data: form,
            cancelToken: token,
            onSendProgress: (done, total) => progress(
              ModelProcessingStage.uploading,
              '正在上传 ${(done / math.max(total, 1) * 100).floor()}%',
            ),
          );
          state['submitting'] = true;
          remote[pieceKey] = state;
          await save();
          Response<dynamic> submitted;
          try {
            submitted = await dio.post<dynamic>(
              base.resolve('/api/v1/services/audio/asr/transcription').toString(),
              data: {
                'model': profile.model,
                'input': {
                  'file_urls': ['oss://$objectKey'],
                },
                'parameters': {
                  'channel_id': [0],
                  'language_hints': ?aliyunAsrLanguageHints(profile),
                },
              },
              cancelToken: token,
              options: Options(
                headers: {
                  'Authorization': 'Bearer $secret',
                  'X-DashScope-Async': 'enable',
                  'X-DashScope-OssResourceResolve': 'enable',
                },
              ),
            );
          } on DioException catch (error) {
            final status = error.response?.statusCode;
            // A definite rejection must not become a permanent uncertain-
            // submission guard. Timeouts/5xx still retain that protection.
            if (status != null && status >= 400 && status < 500 && status != 408) {
              await invalidateTask();
            }
            rethrow;
          }
          final output = (submitted.data as Map)['output'] as Map?;
          taskId = output?['task_id'] as String?;
          if (taskId == null) throw StateError('平台未返回任务 ID，请检查服务配置');
          state['taskId'] = taskId;
          state.remove('submitting');
          await save();
        }
        final deadline = DateTime.now().add(const Duration(hours: 3));
        while (true) {
          token.throwIfCancellationRequested();
          if (DateTime.now().isAfter(deadline)) {
            throw StateError('远端任务等待超时，重试将继续查询原任务');
          }
          progress(ModelProcessingStage.waiting, '百炼正在处理，任务 ID 已保存，可稍后继续查询');
          Response<dynamic> query;
          try {
            query = await dio.get<dynamic>(
              base.resolve('/api/v1/tasks/$taskId').toString(),
              options: authorization,
              cancelToken: token,
            );
          } on DioException catch (error) {
            if (error.response?.statusCode == 404 ||
                error.response?.statusCode == 410) {
              await invalidateTask();
            }
            rethrow;
          }
          final output = (query.data as Map)['output'] as Map;
          final status = output['task_status'];
          if (status == 'FAILED' || status == 'CANCELED') {
            await invalidateTask();
            throw StateError(
              '百炼任务失败：${output['message'] ?? output['code'] ?? status}',
            );
          }
          if (status == 'SUCCEEDED') {
            final results = output['results'] as List? ?? [];
            final result = results.whereType<Map>().firstOrNull;
            if (result == null || result['subtask_status'] != 'SUCCEEDED') {
              await invalidateTask();
              throw StateError('百炼子任务失败：${result?['message'] ?? '没有结果'}');
            }
            Response<dynamic> resultResponse;
            try {
              resultResponse = await dio.get<dynamic>(
                result['transcription_url'] as String,
                cancelToken: token,
              );
            } on DioException catch (error) {
              if (error.response?.statusCode == 404 ||
                  error.response?.statusCode == 410) {
                await invalidateTask();
              }
              rethrow;
            }
            return parseCloudCues(
              resultResponse.data,
              TranscriptionServiceKind.aliyun,
            );
          }
          await Future.any<void>([
            Future<void>.delayed(const Duration(seconds: 3)),
            token.whenCancel.then<void>((_) {}),
          ]);
        }
      }
      throw StateError('该服务尚未接入');
    } on DioException catch (error) {
      if (token.isCancelled) rethrow;
      throw StateError(
        '转录服务请求失败（${error.response?.statusCode ?? error.type.name}），已保留可恢复进度',
      );
    } finally {
      dio.close(force: true);
    }
  }
}

String tencentSignatureQuery(Map<String, String> values) {
  final keys = values.keys.toList()..sort();
  return keys
      .map((key) => '$key=${Uri.encodeQueryComponent(values[key]!)}')
      .join('&');
}

List<SubtitleItem> parseCloudCues(
  dynamic value,
  TranscriptionServiceKind kind,
) {
  final data = value is String ? jsonDecode(value) : value;
  if (data is! Map) throw const FormatException('转录结果不是有效对象');
  if (data['code'] != null && data['code'] != 0) {
    throw StateError('转录失败：${data['message'] ?? data['code']}');
  }
  Iterable<dynamic> segments;
  if (kind == TranscriptionServiceKind.tencent) {
    if (data['flash_result'] is! List) {
      throw const FormatException('腾讯云未返回有效识别结果');
    }
    segments = (data['flash_result'] as List? ?? []).whereType<Map>().expand(
      (e) => e['sentence_list'] as List? ?? [],
    );
  } else if (kind == TranscriptionServiceKind.aliyun) {
    if (data['transcripts'] is! List) {
      throw const FormatException('百炼未返回有效识别结果');
    }
    segments = (data['transcripts'] as List? ?? []).whereType<Map>().expand(
      (e) => e['sentences'] as List? ?? [],
    );
  } else {
    if (data['segments'] is! List) {
      throw const FormatException('接口没有返回字幕时间戳，请选择支持分段时间的模型');
    }
    segments = data['segments'] as List? ?? [];
  }
  final cues = <SubtitleItem>[];
  for (final segment in segments.whereType<Map>()) {
    final seconds = kind == TranscriptionServiceKind.openai;
    final start =
        segment[seconds
            ? 'start'
            : kind == TranscriptionServiceKind.aliyun
            ? 'begin_time'
            : 'start_time'];
    final end = segment[seconds ? 'end' : 'end_time'];
    final text = segment['text']?.toString().trim() ?? '';
    if (text.isEmpty) continue;
    if (start is! num ||
        end is! num ||
        !start.isFinite ||
        !end.isFinite ||
        start < 0 ||
        end <= start) {
      throw const FormatException('接口返回了无效的字幕时间轴');
    }
    final words =
        (segment['word_list'] as List? ?? segment['words'] as List? ?? [])
            .whereType<Map>()
            .toList();
    final validWords = words
        .where(
          (w) =>
              (w['start'] ?? w['begin_time'] ?? w['start_time']) is num &&
              (w['end'] ?? w['end_time']) is num,
        )
        .toList();
    final unit = seconds ? 1.0 : 0.001;
    cues.add(
      SubtitleItem(
        index: cues.length + 1,
        startTime: Duration(
          milliseconds: (start * (seconds ? 1000 : 1)).round(),
        ),
        endTime: Duration(milliseconds: (end * (seconds ? 1000 : 1)).round()),
        text: text,
        timedSpans: alignModelTokens(
          text: text,
          tokens: validWords
              .map((w) => (w['word'] ?? w['text'] ?? '').toString())
              .toList(),
          starts: validWords
              .map(
                (w) =>
                    (w['start'] ?? w['begin_time'] ?? w['start_time']) as num,
              )
              .map((n) => n * unit)
              .toList(),
          ends: validWords
              .map((w) => (w['end'] ?? w['end_time']) as num)
              .map((n) => n * unit)
              .toList(),
          cueEnd: end * unit,
        ),
      ),
    );
  }
  final hasText = [
    data,
    ...((data['flash_result'] as List?)?.whereType<Map>() ?? const <Map>[]),
    ...((data['transcripts'] as List?)?.whereType<Map>() ?? const <Map>[]),
  ].any((item) => item['text']?.toString().trim().isNotEmpty ?? false);
  if (cues.isEmpty && hasText) {
    throw const FormatException('接口没有返回字幕时间戳，请选择支持分段时间的模型');
  }
  return cues;
}
