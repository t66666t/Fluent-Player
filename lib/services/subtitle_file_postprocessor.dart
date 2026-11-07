import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../features/model_center/model_center_service.dart';
import '../models/subtitle_model.dart';
import '../models/subtitle_punctuation.dart';
import '../models/subtitle_stream.dart';
import '../models/transcription_progress.dart';
import 'ai_subtitle_api_settings.dart';
import 'cloud_translation_batches.dart';
import 'generated_subtitle_names.dart';
import 'local_transcription_stream.dart';
import 'streaming_subtitle_store.dart';
import 'subtitle_optimization.dart';
import 'subtitle_translate_settings.dart';
import 'subtitle_translation_service.dart';
import 'task_subtitle_storage_service.dart';

/// Reuses the streaming coordinator for an existing sentence subtitle file.
/// A content/settings fingerprint restores completed batches without new calls.
Future<StreamingSubtitleStore> processSubtitleFileBatches({
  required String inputPath,
  required List<SubtitleItem> items,
  required String outputDirectory,
  required SubtitleOptimizationChoice optimization,
  required AiSubtitleApiSettings optimizationEndpoint,
  required TranscriptTranslateChoice translation,
  AiSubtitleApiSettings? translationEndpoint,
  required SubtitleTranslationService translator,
  SubtitleOptimizer? optimizer,
  required Future<void> cancelSignal,
  required void Function() checkCancelled,
  required void Function(double) onProgress,
  required void Function(String?) onActivity,
  void Function(SubtitleOptimizationProgress)? onOptimizationProgress,
  Future<void> Function(StreamingSubtitleStore)? onOpened,
  Future<void> Function(
    StreamingSubtitleStore,
    List<SubtitleItem>,
    List<SubtitleItem>,
  )?
  onCommitted,
  SubtitlePunctuation punctuation = SubtitlePunctuation.preserve,
}) async {
  final cues = [
    for (var i = 0; i < items.length; i++) items[i].copyWith(index: i + 1),
  ];
  final fingerprint = sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'version': 1,
            'path': p.normalize(inputPath),
            'cues': [
              for (final cue in cues)
                [
                  cue.startTime.inMicroseconds,
                  cue.endTime.inMicroseconds,
                  cue.text,
                ],
            ],
            'optimization': optimization.toJson(),
            'translation': translation.configurationFingerprint,
            'punctuation': punctuation.name,
          }),
        ),
      )
      .toString();
  final directory = Directory(outputDirectory);
  await directory.create(recursive: true);
  final journal = File(
    p.join(directory.path, '.subtitle-processing', '$fingerprint.jsonl'),
  );
  StreamingSubtitleStore store;
  if (await journal.exists()) {
    store = await StreamingSubtitleStore.open(journal);
  } else {
    const storage = TaskSubtitleStorageService();
    final primary = await storage.allocateInside(
      directory,
      '${localizedSubtitleResultName(p.basenameWithoutExtension(inputPath))}.优化.srt',
    );
    final secondary = translation.enabled
        ? await storage.allocateInside(
            directory,
            '${p.basenameWithoutExtension(primary)}.翻译.srt',
          )
        : null;
    store = await StreamingSubtitleStore.create(journal, {
      'generationId': fingerprint,
      'primaryPath': primary,
      'secondaryPath': secondary,
    });
  }
  checkCancelled();
  await store.setPhase(SubtitleStreamPhase.generating);
  await onOpened?.call(store);
  final stream = LocalTranscriptionStream(
    openStore: () async => store,
    choice: translation,
    endpoint: translationEndpoint,
    optimization: optimization,
    optimizationEndpoint: optimizationEndpoint,
    optimizer: optimizer,
    sourceTotal: cues.length,
    center: ModelCenterService.instance,
    translator: translator,
    punctuation: punctuation,
    cancelSignal: cancelSignal,
    checkCancelled: checkCancelled,
    onFailure: () {},
    onOptimizing: () => onActivity('正在优化字幕'),
    onOptimizationProgress: (value) {
      onOptimizationProgress?.call(value);
      // Correction finishes before translation, so it owns half of the work
      // when both stages are enabled. Publication supplies the other half.
      final committed = store.primary.snapshot.length / cues.length;
      onProgress(
        translation.enabled ? (value.fraction + committed) / 2 : value.fraction,
      );
    },
    onActivity: (_, note) => onActivity(note ?? '正在翻译优化后的字幕'),
    onCommitted: (value, primary, secondary) async {
      final committed = value.primary.snapshot.length / cues.length;
      final optimized =
          (value.primary.snapshot.length + value.pendingOptimizations.length) /
          cues.length;
      onProgress(translation.enabled ? (optimized + committed) / 2 : committed);
      await onCommitted?.call(value, primary, secondary);
    },
  );
  try {
    for (final batch in cloudTranslationBatches(
      cues,
      maxCues: SubtitleOptimizer.batchSize,
      maxRunes: SubtitleOptimizer.characterBudget,
      maxSpan: const Duration(hours: 24),
    )) {
      await stream.accept(batch);
    }
    await stream.drain();
    checkCancelled();
    await store.setPhase(SubtitleStreamPhase.complete);
    onProgress(1);
    return store;
  } catch (_) {
    await store.setPhase(SubtitleStreamPhase.failed, '已保留原字幕及处理进度，可继续');
    rethrow;
  } finally {
    await stream.close();
  }
}
