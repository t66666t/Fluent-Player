import 'dart:async';

import '../features/model_center/local_subtitle_translator.dart';
import '../features/model_center/model_center_service.dart';
import '../features/model_center/model_transcription.dart';
import '../features/model_center/asr_enhancement_processing.dart';
import '../models/subtitle_model.dart';
import '../models/subtitle_punctuation.dart';
import 'ai_subtitle_api_settings.dart';
import 'streaming_subtitle_store.dart';
import 'subtitle_translate_settings.dart';
import 'subtitle_translation_service.dart';

typedef _PreparedSubtitleCommit = ({
  Future<void> Function()? commit,
  Object? error,
  StackTrace? stack,
});

/// Ordered publication, with at most two network-translation blocks in flight.
/// Local translation borrows ASR's reservation; its runner bounds text batches
/// and drains native stages before changing model residency.
class LocalTranscriptionStream {
  LocalTranscriptionStream({
    required this.openStore,
    required this.choice,
    required this.center,
    required this.translator,
    required this.cancelSignal,
    required this.checkCancelled,
    required this.onCommitted,
    required this.onActivity,
    required this.onFailure,
    this.endpoint,
    this.recognitionLanguage = 'auto',
    this.punctuation = SubtitlePunctuation.preserve,
  });
  final Future<StreamingSubtitleStore> Function() openStore;
  final TranscriptTranslateChoice choice;
  final ModelCenterService center;
  final SubtitleTranslationService translator;
  final AiSubtitleApiSettings? endpoint;
  final String recognitionLanguage;
  final SubtitlePunctuation punctuation;
  final Future<void> cancelSignal;
  final void Function() checkCancelled;
  final Future<void> Function(
    StreamingSubtitleStore,
    List<SubtitleItem>,
    List<SubtitleItem>,
  )
  onCommitted;
  final void Function(double, String?) onActivity;
  final void Function() onFailure;
  final _localSession = LocalTranslationSession();
  bool get hasLocalModel => _localSession.hasModel;
  final List<Future<void>> _pending = [];
  Future<void> _tail = Future<void>.value();
  Future<StreamingSubtitleStore>? _bingStore;
  int _bingScheduledThrough = 0;
  Object? failure;
  StackTrace? _failureStack;

  Future<void> accept(StableAsrBatch batch) async {
    checkCancelled();
    if (failure != null) Error.throwWithStackTrace(failure!, _failureStack!);
    // The native pipeline supplies backpressure for AI translation without
    // adding another queue; its runner keeps network waits outside the native
    // barrier. Bing retains its existing bounded network preparation queue.
    if ((batch.nativePipeline &&
            choice.provider != SubtitleTranslateProvider.bing) ||
        !choice.enabled ||
        choice.provider == SubtitleTranslateProvider.local) {
      await _publish(batch);
      return;
    }
    final Future<void> task;
    if (choice.provider == SubtitleTranslateProvider.bing) {
      // Prepare at most two blocks concurrently; the Bing client shares its
      // four-request budget across both. Consume preparation failures in commit
      // order so a later block cannot discard an earlier successful block.
      final prepared = _prepare(batch).then<_PreparedSubtitleCommit>(
        (commit) => (commit: commit, error: null, stack: null),
        onError: (Object error, StackTrace stack) =>
            (commit: null, error: error, stack: stack),
      );
      task = _tail.then((_) async {
        final result = await prepared;
        if (failure != null) return;
        try {
          if (result.error != null) {
            Error.throwWithStackTrace(result.error!, result.stack!);
          }
          await result.commit!();
        } catch (error, stack) {
          failure = error;
          _failureStack = stack;
          onFailure();
        }
      });
    } else {
      task = _tail.then((_) async {
        if (failure != null) return;
        try {
          await _publish(batch);
        } catch (error, stack) {
          failure = error;
          _failureStack = stack;
          onFailure();
        }
      });
    }
    _tail = task;
    _pending.add(task);
    if (_pending.length >= 2) {
      await _pending.removeAt(0);
      if (failure != null) Error.throwWithStackTrace(failure!, _failureStack!);
    }
  }

  Future<void> _publish(StableAsrBatch batch) async {
    final commit = await _prepare(batch);
    await commit();
  }

  Future<Future<void> Function()> _prepare(StableAsrBatch batch) async {
    checkCancelled();
    final store = await (choice.provider == SubtitleTranslateProvider.bing
        ? _bingStore ??= openStore()
        : openStore());
    final count = store.primaryComplete
        ? store.secondary.snapshot.length
        : store.primary.snapshot.length;
    final scheduled =
        choice.provider == SubtitleTranslateProvider.bing &&
            _bingScheduledThrough > count
        ? _bingScheduledThrough
        : count;
    final cues = batch.cues.where((cue) => cue.index > scheduled).toList();
    if (cues.isEmpty) return () async {};
    if (choice.provider == SubtitleTranslateProvider.bing) {
      _bingScheduledThrough = cues.last.index;
    }
    final translations = <SubtitleItem>[];
    if (choice.enabled) {
      if (store.targetLanguage == null) {
        var plan = resolveTranscriptTranslation(
          direction: choice.direction,
          subtitleText: cues.map((cue) => cue.text).join('\n'),
          sourceLanguage: choice.sourceLanguage,
          targetLanguage: choice.targetLanguage,
        );
        final language = normalizeAsrLanguage(
          recognitionLanguage == 'auto'
              ? cues
                        .map((cue) => cue.asrInfo.language)
                        .where((value) => value.isNotEmpty)
                        .firstOrNull ??
                    'auto'
              : recognitionLanguage,
        );
        if (choice.targetLanguage == null &&
            choice.direction == TranscriptTranslateDirection.auto &&
            (language == 'zh' || language == 'en')) {
          plan = TranscriptTranslationPlan(
            sourceLanguage: language == 'zh' ? 'zh-CN' : 'en',
            targetLanguage: language == 'zh' ? 'en' : 'zh-CN',
            assumedSimplifiedChinese: false,
          );
        }
        await store.direction(
          choice.smartPolicy == null ? plan.sourceLanguage : 'auto',
          choice.smartPolicy == null ? plan.targetLanguage : 'mul',
        );
      }
      final missing = cues
          .where((cue) => !store.pendingTranslations.containsKey(cue.index))
          .toList();
      if (missing.isNotEmpty) {
        final accepted = <int, String>{};
        try {
          final output = await translator.translateCueBatch(
            items: missing,
            sourceLanguage: store.sourceLanguage!,
            targetLanguage: store.targetLanguage!,
            smartPolicy: choice.smartPolicy,
            provider: choice.provider,
            aiOptions: choice.aiOptions,
            aiEndpoint: endpoint,
            localSpecification: choice.localSpecification,
            modelCenter: center,
            localSession: batch.retainConsumerModels ? _localSession : null,
            reservation: batch.reservation,
            checkpointScope:
                '${store.header['generationId']}:${cues.first.index}',
            precedingContext: store.precedingSource.join('\n'),
            cancelSignal: cancelSignal,
            onProgress: (value) => onActivity(value, null),
            onActivity: (note) => onActivity(0, note),
            onTranslated: (index, value) {
              accepted[missing[index].index] = value;
            },
          );
          if (output.length != missing.length) throw StateError('译文数量不匹配');
          for (var i = 0; i < output.length; i++) {
            if (output[i].trim().isEmpty) throw StateError('部分字幕未返回译文');
            accepted[missing[i].index] = output[i];
          }
        } finally {
          await store.rememberTranslations(accepted);
        }
      }
      checkCancelled();
      for (final cue in cues) {
        final text = store.pendingTranslations[cue.index];
        if (text == null) throw StateError('部分字幕尚未翻译完成');
        translations.add(
          SubtitleItem(
            index: cue.index,
            startTime: cue.startTime,
            endTime: cue.endTime,
            text: applySubtitlePunctuationText(text, punctuation),
          ),
        );
      }
    }
    return () async {
      checkCancelled();
      // Recheck after the earlier commit, including overlapping resumed input.
      final committed = store.primaryComplete
          ? store.secondary.snapshot.length
          : store.primary.snapshot.length;
      final remaining = cues.where((cue) => cue.index > committed).toList();
      if (remaining.isEmpty) return;
      final primary = punctuation == SubtitlePunctuation.preserve
          ? remaining
          : [
              for (final cue in remaining)
                applySubtitlePunctuation(cue, punctuation),
            ];
      final secondary = translations
          .where((cue) => cue.index > committed)
          .toList();
      final context = remaining.length >= 2
          ? [remaining[remaining.length - 2].text, remaining.last.text]
          : [
              if (store.precedingSource.isNotEmpty) store.precedingSource.last,
              remaining.single.text,
            ];
      await store.append(
        store.primaryComplete ? const [] : primary,
        secondary,
        batch.processedThrough,
        sourceContext: context,
      );
      checkCancelled();
      await onCommitted(
        store,
        store.primaryComplete ? const [] : primary,
        secondary,
      );
    };
  }

  Future<void> drain() async {
    await _tail;
    if (failure != null) Error.throwWithStackTrace(failure!, _failureStack!);
  }

  /// Called at a drained ASR handoff, before recognition starts again.
  Future<void> releaseLocalModels() => _localSession.release();

  Future<void> close() async {
    await _tail;
    await _localSession.release();
  }
}
