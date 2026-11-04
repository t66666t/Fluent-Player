import '../../models/local_asr_progress.dart';
import 'asr_execution_plan.dart';
import 'inference_resource_governor.dart';

class AsrProgressTracker {
  String activity = '';
  AsrProgressTracker({
    required this.model,
    required this.total,
    required this.plan,
    required this.pieces,
  }) : _watch = Stopwatch()..start();
  final String model;
  final Duration total;
  final AsrExecutionPlan plan;
  final int pieces;
  final Stopwatch _watch;
  String backend = 'CPU';
  InferenceBudgetDecision? budget;
  int? actualAsrThreads;
  int? actualEnhancementThreads;
  void configure(
    InferenceLane lane,
    int threads,
    InferenceBudgetDecision value,
  ) {
    budget = value;
    if (lane == InferenceLane.recognition ||
        lane == InferenceLane.compilation) {
      actualAsrThreads = threads;
    }
    if (lane == InferenceLane.alignment || lane == InferenceLane.auxiliary) {
      actualEnhancementThreads = threads;
    }
  }

  String audioPreparation = '';
  int completedPieces = 0, reusedPieces = 0;
  Duration recognized = Duration.zero, enhanced = Duration.zero;
  Duration prepared = Duration.zero;
  LocalAsrLaneProgress preparation = const LocalAsrLaneProgress(phase: '等待音频');
  LocalAsrLaneProgress recognition = const LocalAsrLaneProgress(phase: '准备模型'),
      enhancement = const LocalAsrLaneProgress(phase: '等待原文');
  void front(int piece, String phase, double value) {
    recognition = LocalAsrLaneProgress(
      piece: piece,
      phase: phase,
      phaseFraction: value.clamp(0, 1),
      active: true,
    );
  }

  void back(int piece, String phase, double value) {
    enhancement = LocalAsrLaneProgress(
      piece: piece,
      phase: phase,
      phaseFraction: value.clamp(0, 1),
      active: true,
    );
  }

  void preparing(int piece, String phase, double value) {
    preparation = LocalAsrLaneProgress(
      piece: piece,
      phase: phase,
      phaseFraction: value.clamp(0, 1),
      active: true,
    );
  }

  void preparedTo(Duration end) {
    preparedPart(end);
    preparation = LocalAsrLaneProgress(
      piece: preparation.piece,
      phase: preparation.phase == '复用断点' ? '复用断点' : '已降噪',
      phaseFraction: 1,
    );
  }

  void preparedPart(Duration position) {
    if (position > prepared) prepared = position > total ? total : position;
  }

  void recognizedTo(Duration end) {
    if (end > recognized) recognized = end > total ? total : end;
    recognition = LocalAsrLaneProgress(
      piece: recognition.piece,
      phase: '已识别',
      phaseFraction: 1,
    );
  }

  void recognizedPart(Duration position) {
    if (position > recognized) recognized = position > total ? total : position;
  }

  void completed(Duration end, {bool reused = false}) {
    recognizedPart(end);
    if (end > enhanced) enhanced = end > total ? total : end;
    completedPieces++;
    if (reused) reusedPieces++;
    enhancement = LocalAsrLaneProgress(
      piece: enhancement.piece,
      phase: reused ? '复用断点' : '已完成',
      phaseFraction: 1,
    );
  }

  LocalAsrProgress get snapshot => LocalAsrProgress(
    model: model,
    backend: backend,
    pipeline: plan.pipeline && (budget?.pipeline ?? true),
    reuseModels: plan.reuseModels,
    manualMemorySaver: plan.manualMemorySaver,
    pipelineRequested: plan.pipeline,
    activity: activity,
    limitReason: budget?.reasonCode.name ?? '',
    reason: budget == null
        ? plan.reason
        : budget!.throttled || plan.pipeline && !budget!.pipeline
        ? budget!.reason
        : '${budget!.reason} · ${plan.reason}',
    total: total,
    recognized: recognized,
    enhanced: enhanced,
    elapsed: _watch.elapsed,
    capturedAt: DateTime.now(),
    recognition: recognition,
    enhancement: enhancement,
    pieces: pieces,
    completedPieces: completedPieces,
    reusedPieces: reusedPieces,
    asrThreads: actualAsrThreads ?? plan.asrThreads,
    enhancementThreads: actualEnhancementThreads ?? plan.enhancementThreads,
    audioPreparation: audioPreparation,
    preprocessAhead: plan.preprocessAhead && (budget?.pipeline ?? true),
    prepared: prepared,
    preparation: preparation,
  );
}
