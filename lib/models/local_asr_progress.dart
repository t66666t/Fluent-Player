/// Actual audio coverage and current work, independent of the workflow's
/// allocated overall percentage. Neither percentage is a time estimate.
class LocalAsrLaneProgress {
  const LocalAsrLaneProgress({
    this.phase = '等待',
    this.phaseFraction = 0,
    this.piece = 0,
    this.active = false,
  });
  final String phase;
  final double phaseFraction;
  final int piece;
  final bool active;
  String get label => piece == 0
      ? phase
      : '第 $piece 块 · $phase${active && !const ['加载模型', '选择计算设备', '准备增强'].contains(phase) ? ' ${(phaseFraction * 100).floor()}%' : ''}';
}

class LocalAsrProgress {
  const LocalAsrProgress({
    required this.model,
    required this.pipeline,
    required this.reuseModels,
    required this.reason,
    required this.total,
    required this.recognized,
    required this.enhanced,
    required this.elapsed,
    required this.capturedAt,
    required this.recognition,
    required this.enhancement,
    required this.pieces,
    required this.completedPieces,
    required this.asrThreads,
    required this.enhancementThreads,
    this.reusedPieces = 0,
    this.backend = 'CPU',
    this.audioPreparation = '',
    this.preprocessAhead = false,
    this.prepared = Duration.zero,
    this.preparation = const LocalAsrLaneProgress(),
    this.manualMemorySaver = false,
    this.pipelineRequested = true,
    this.limitReason = '',
    this.activity = '',
  });
  final String model, reason, backend, audioPreparation;
  final bool pipeline, reuseModels;
  final bool manualMemorySaver, pipelineRequested;
  final String limitReason;
  final String activity;
  final bool preprocessAhead;
  final Duration prepared;
  final LocalAsrLaneProgress preparation;
  final Duration total, recognized, enhanced, elapsed;
  final DateTime capturedAt;
  final LocalAsrLaneProgress recognition, enhancement;
  final int pieces,
      completedPieces,
      reusedPieces,
      asrThreads,
      enhancementThreads;
  double get recognitionFraction => _fraction(recognized);
  double get enhancementFraction => _fraction(enhanced);
  double get preparationFraction => _fraction(prepared);
  double _fraction(Duration value) => total.inMilliseconds <= 0
      ? 0
      : (value.inMilliseconds / total.inMilliseconds).clamp(0, 1);
  String get mode => activity.isNotEmpty
      ? activity
      : manualMemorySaver
      ? '省内存模式'
      : pipeline
      ? '流水线运行'
      : pipelineRequested
      ? '暂时顺序处理'
      : '正在识别';
  String get summary =>
      '$model · $mode\n$reason\n'
      '${preprocessAhead ? '降噪 ${clock(prepared)} / ${clock(total)} · ${preparation.label}\n' : ''}'
      '识别 ${clock(recognized)} / ${clock(total)} · ${recognition.label}\n'
      '增强 ${clock(enhanced)} / ${clock(total)} · ${enhancement.label}\n'
      '已完成 $completedPieces/$pieces 块${reusedPieces > 0 ? ' · 复用 $reusedPieces 块' : ''}';
  static String clock(Duration value) {
    final seconds = value.inSeconds.clamp(0, 1 << 40);
    final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
    return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}
