import 'dart:async';

import '../features/model_center/local_subtitle_translator.dart';
import '../features/model_center/model_center_service.dart';
import '../features/model_center/model_transcription.dart';
import '../features/model_center/asr_enhancement_processing.dart';
import '../models/subtitle_model.dart';
import '../models/subtitle_punctuation.dart';
import '../models/transcription_progress.dart';
import 'ai_subtitle_api_settings.dart';
import 'streaming_subtitle_store.dart';
import 'subtitle_translate_settings.dart';
import 'subtitle_translation_service.dart';
import 'subtitle_optimization.dart';

typedef _PreparedSubtitleCommit = ({
  Future<void> Function()? commit,
  Object? error,
  StackTrace? stack,
});

typedef _OptimizedSubtitleBatch = ({
  StableAsrBatch? batch,
  Object? error,
  StackTrace? stack,
});

/// Ordered publication, with at most two subtitle blocks in flight. When both
/// stages are enabled, optimization runs ahead of ordered translation/commit.
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
    this.optimization = const SubtitleOptimizationChoice.off(),
    this.optimizationEndpoint,
    this.optimizer,
    this.onOptimizing,
    this.onOptimizationProgress,
    this.sourceTotal,
    this.recognitionLanguage = 'auto',
    this.punctuation = SubtitlePunctuation.preserve,
  });
  final Future<StreamingSubtitleStore> Function() openStore;
  final TranscriptTranslateChoice choice;
  final ModelCenterService center;
  final SubtitleTranslationService translator;
  final AiSubtitleApiSettings? endpoint;
  final SubtitleOptimizationChoice optimization;
  final AiSubtitleApiSettings? optimizationEndpoint;
  final SubtitleOptimizer? optimizer;
  final void Function()? onOptimizing;
  final void Function(SubtitleOptimizationProgress)? onOptimizationProgress;
  final int? sourceTotal;
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
  Future<void> _optimizationTail = Future<void>.value();
  Object? _optimizationFailure;
  StackTrace? _optimizationFailureStack;
  List<String>? _optimizationContext;
  Future<StreamingSubtitleStore>? _bingStore;
  int _bingScheduledThrough = 0;
  int _recognizedThrough = 0;

  void _reportOptimization(
    StreamingSubtitleStore store, {
    bool finalTotal = false,
  }) {
    if (!optimization.enabled) return;
    final committed = store.primary.snapshot.length;
    final pending = store.pendingOptimizations.keys
        .where((id) => id > committed)
        .length;
    final processed = committed + pending;
    final total =
        sourceTotal ??
        (_recognizedThrough > processed ? _recognizedThrough : processed);
    onOptimizationProgress?.call(
      SubtitleOptimizationProgress(
        processed: processed,
        total: total,
        totalIsFinal: sourceTotal != null || finalTotal,
      ),
    );
  }

  Object? failure;
  StackTrace? _failureStack;

  Future<void> accept(StableAsrBatch batch) async {
    checkCancelled();
    if (failure != null) Error.throwWithStackTrace(failure!, _failureStack!);
    if (optimization.enabled) {
      await _acceptOptimizedBatch(batch);
      return;
    }
    // The native pipeline supplies backpressure for AI translation without
    // adding another queue; its runner keeps network waits outside the native
    // barrier. Bing retains its existing bounded network preparation queue.
    if ((batch.nativePipeline &&
            choice.provider != SubtitleTranslateProvider.bing) ||
        (!choice.enabled && !optimization.enabled) ||
        choice.provider == SubtitleTranslateProvider.local) {
      await _publish(batch);
      return;
    }
    final Future<void> task;
    if (choice.provider == SubtitleTranslateProvider.bing ||
        optimization.enabled) {
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

  Future<void> _acceptOptimizedBatch(StableAsrBatch batch) async {
    if (batch.cues.isNotEmpty && batch.cues.last.index > _recognizedThrough) {
      _recognizedThrough = batch.cues.last.index;
    }
    var at = 0;
    while (at < batch.cues.length) {
      checkCancelled();
      if (failure != null) Error.throwWithStackTrace(failure!, _failureStack!);
      var end = at, chars = 0;
      while (end < batch.cues.length &&
          end - at < SubtitleOptimizer.batchSize) {
        final next = batch.cues[end].text.length;
        if (end > at && chars + next > SubtitleOptimizer.characterBudget) break;
        chars += next;
        end++;
      }
      final block = StableAsrBatch(
        batch.cues.sublist(at, end),
        end == batch.cues.length
            ? batch.processedThrough
            : batch.cues[end - 1].endTime,
        batch.reservation,
        retainConsumerModels: batch.retainConsumerModels,
        nativePipeline: batch.nativePipeline,
      );
      // Each stage is ordered independently: translating this block never
      // delays optimizing the next one. Keep only one block of lookahead.
      final optimized = _optimizationTail
          .then((_) async {
            checkCancelled();
            if (failure != null) {
              Error.throwWithStackTrace(failure!, _failureStack!);
            }
            if (_optimizationFailure != null) {
              Error.throwWithStackTrace(
                _optimizationFailure!,
                _optimizationFailureStack!,
              );
            }
            return _optimizeBatch(block);
          })
          .then<_OptimizedSubtitleBatch>(
            (value) => (batch: value, error: null, stack: null),
            onError: (Object error, StackTrace stack) {
              _optimizationFailure ??= error;
              _optimizationFailureStack ??= stack;
              return (batch: null, error: error, stack: stack);
            },
          );
      _optimizationTail = optimized.then((_) {});
      final task = _tail.then((_) async {
        final result = await optimized;
        if (failure != null) return;
        try {
          if (result.error != null) {
            Error.throwWithStackTrace(result.error!, result.stack!);
          }
          await _publish(result.batch!, alreadyOptimized: true);
        } catch (error, stack) {
          failure = error;
          _failureStack = stack;
          onFailure();
        }
      });
      _tail = task;
      _pending.add(task);
      if (_pending.length >= 2) {
        await _pending.removeAt(0);
        if (failure != null) {
          Error.throwWithStackTrace(failure!, _failureStack!);
        }
      }
      at = end;
    }
    // A native consumer cannot let work escape the reservation/residency
    // boundary. Its sub-batches still overlap network optimization with the
    // preceding translation, and its caller retains the existing backlog.
    if (choice.enabled &&
        (batch.nativePipeline ||
            choice.provider == SubtitleTranslateProvider.local &&
                batch.reservation != null)) {
      await _tail;
      if (failure != null) Error.throwWithStackTrace(failure!, _failureStack!);
    }
  }

  Future<StableAsrBatch> _optimizeBatch(StableAsrBatch batch) async {
    final store = await (_bingStore ??= openStore());
    final count = store.primaryComplete
        ? store.secondary.snapshot.length
        : store.primary.snapshot.length;
    final scheduled = _bingScheduledThrough > count
        ? _bingScheduledThrough
        : count;
    final cues = batch.cues.where((cue) => cue.index > scheduled).toList();
    _reportOptimization(store);
    if (cues.isEmpty) {
      return StableAsrBatch(const [], batch.processedThrough, null);
    }
    _bingScheduledThrough = cues.last.index;
    _optimizationContext ??= List.of(store.precedingSource);
    final corrected = await _optimizeCues(
      store,
      cues,
      precedingContext: _optimizationContext!.join('\n'),
    );
    checkCancelled();
    final context = [
      ..._optimizationContext!,
      ...corrected.map((cue) => cue.text),
    ];
    _optimizationContext = context
        .skip((context.length - 2).clamp(0, context.length))
        .toList();
    return StableAsrBatch(
      corrected,
      batch.processedThrough,
      batch.reservation,
      retainConsumerModels: batch.retainConsumerModels,
      nativePipeline: batch.nativePipeline,
    );
  }

  Future<List<SubtitleItem>> _optimizeCues(
    StreamingSubtitleStore store,
    List<SubtitleItem> cues, {
    required String precedingContext,
  }) async {
    onOptimizing?.call();
    final missing = cues
        .where((cue) => !store.pendingOptimizations.containsKey(cue.index))
        .toList();
    if (missing.isNotEmpty) {
      if (optimizationEndpoint == null) throw StateError('字幕优化接口未配置');
      await (optimizer ?? SubtitleOptimizer()).optimize(
        cues: missing,
        choice: optimization,
        endpoint: optimizationEndpoint!,
        cancelSignal: cancelSignal,
        precedingContext: precedingContext,
        onOptimized: (output, warning) async {
          await store.rememberOptimizations({
            for (final cue in output) cue.index: cue.text,
          }, warning: warning);
          _reportOptimization(store);
        },
      );
      checkCancelled();
    }
    return [
      for (final cue in cues)
        if (store.pendingOptimizations[cue.index] == cue.text)
          cue
        else
          cue.copyWith(
            text: store.pendingOptimizations[cue.index]!,
            timedSpans: const [],
          ),
    ];
  }

  Future<void> _publish(
    StableAsrBatch batch, {
    bool alreadyOptimized = false,
  }) async {
    final commit = await _prepare(batch, alreadyOptimized: alreadyOptimized);
    await commit();
  }

  Future<Future<void> Function()> _prepare(
    StableAsrBatch batch, {
    bool alreadyOptimized = false,
  }) async {
    checkCancelled();
    final store =
        await (choice.provider == SubtitleTranslateProvider.bing ||
                optimization.enabled
            ? _bingStore ??= openStore()
            : openStore());
    final count = store.primaryComplete
        ? store.secondary.snapshot.length
        : store.primary.snapshot.length;
    if (batch.cues.isNotEmpty && batch.cues.last.index > _recognizedThrough) {
      _recognizedThrough = batch.cues.last.index;
    }
    _reportOptimization(store);
    final scheduled =
        !alreadyOptimized &&
            (choice.provider == SubtitleTranslateProvider.bing ||
                optimization.enabled) &&
            _bingScheduledThrough > count
        ? _bingScheduledThrough
        : count;
    var cues = batch.cues.where((cue) => cue.index > scheduled).toList();
    if (cues.isEmpty) return () async {};
    if (!alreadyOptimized &&
        (choice.provider == SubtitleTranslateProvider.bing ||
            optimization.enabled)) {
      _bingScheduledThrough = cues.last.index;
    }
    if (optimization.enabled && !alreadyOptimized) {
      cues = await _optimizeCues(
        store,
        cues,
        precedingContext: store.precedingSource.join('\n'),
      );
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
    await _optimizationTail;
    if (failure != null) Error.throwWithStackTrace(failure!, _failureStack!);
    if (optimization.enabled && _bingStore != null) {
      _reportOptimization(await _bingStore!, finalTotal: true);
    }
  }

  /// Called at a drained ASR handoff, before recognition starts again.
  Future<void> releaseLocalModels() => _localSession.release();

  Future<void> close() async {
    await _tail;
    await _optimizationTail;
    await _localSession.release();
  }
}
