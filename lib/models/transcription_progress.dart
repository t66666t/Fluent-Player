import 'transcription_status.dart';

/// Completed correction batches, including restored checkpoints.
class SubtitleOptimizationProgress {
  const SubtitleOptimizationProgress({
    required this.processed,
    required this.total,
    this.totalIsFinal = true,
  });

  final int processed, total;
  final bool totalIsFinal;

  double get fraction => total <= 0 ? 0 : (processed / total).clamp(0, 1);
  String get label => '优化 $processed/$total 条${totalIsFinal ? '' : '（已识别）'}';
}

/// Audio coverage already committed to the generated subtitle file(s).
class TranscriptionAudioProgress {
  const TranscriptionAudioProgress({
    required this.completed,
    required this.total,
  });

  final Duration completed, total;

  double get fraction => total.inMilliseconds <= 0
      ? 0
      : (completed.inMilliseconds / total.inMilliseconds).clamp(0, 1);

  String get label => '已完成 $timeLabel';

  String get timeLabel {
    final end = total.inSeconds;
    final done = completed.inSeconds.clamp(0, end > 0 ? end : 0);
    final hours = end >= 3600;
    final hourDigits = hours ? (end ~/ 3600).toString().length.clamp(2, 20) : 0;
    String clock(int seconds) {
      final minutes = (seconds ~/ 60 % 60).toString().padLeft(2, '0');
      final tail = (seconds % 60).toString().padLeft(2, '0');
      return hours
          ? '${(seconds ~/ 3600).toString().padLeft(hourDigits, '0')}:$minutes:$tail'
          : '$minutes:$tail';
    }

    return '${clock(done)} / ${end > 0 ? clock(end) : '--:--'}';
  }

  // Reserve the entire numeric field, including fonts without tabular figures.
  List<String> get widthVariants {
    final text = label;
    final digits = RegExp(r'[0-9]');
    return [
      for (var digit = 0; digit <= 9; digit++)
        text.replaceAll(digits, '$digit'),
    ];
  }
}

/// Overall work allocation, not an estimate of elapsed or remaining time.
/// Recognition includes slice preparation, upload and result polling.
class TranscriptionProgressPlan {
  const TranscriptionProgressPlan({
    required this.translate,
    this.optimize = false,
  });

  final bool translate, optimize;

  double download(double fraction) => _range(0, 0.10, fraction);
  double preparation(double fraction) => _range(0.10, 0.15, fraction);
  double recognition(double fraction) =>
      _range(0.15, optimize ? 0.55 : (translate ? 0.60 : 0.90), fraction);
  double optimization(double fraction) =>
      _range(0.55, translate ? 0.72 : 0.90, fraction);
  double translation(double fraction) =>
      _range(optimize ? 0.72 : 0.60, 0.90, fraction);
  double embedding(double fraction) => _range(0.90, 0.98, fraction);

  static double _range(double start, double end, double fraction) =>
      start +
      (end - start) * (fraction.isFinite ? fraction.clamp(0.0, 1.0) : 0);

  /// Retries may repeat earlier work. Only successful completion can reach 1.
  static double advance(
    double previous,
    double next,
    TranscriptionStatus status,
  ) {
    if (status == TranscriptionStatus.completed) return 1;
    final normalized = next.isFinite ? next.clamp(0.0, 0.99) : 0.0;
    if (status == TranscriptionStatus.error) return normalized;
    return previous.clamp(0.0, 0.99) > normalized
        ? previous.clamp(0.0, 0.99)
        : normalized;
  }
}

/// Presentation shared by the player panel and the task queue.
class TranscriptionProgress {
  static String stage(TranscriptionStatus status, String message) {
    if (message.contains('保存字幕')) return '保存字幕';
    if (message.contains('准备增强模型')) return '下载模型组件';
    if (message.contains('等待本地推理资源')) return '等待推理资源';
    if (message.contains('降噪')) return '音频降噪';
    if (message.contains('检测语音') || message.contains('语音区间')) return '检测语音';
    if (message.contains('精校') || message.contains('声学复核')) return '时间精校';
    if (message.contains('标点')) return '恢复标点';
    if (message.contains('静音边界') || message.contains('边界修整')) return '修整边界';
    if (message.contains('分句')) return '整理分句';
    if (message.contains('正在加载')) return '加载模型';
    if (message.contains('访问限制') ||
        message.contains('频率限制') ||
        message.contains('安全策略拦截') ||
        message.contains('查询请求被拒绝') ||
        message.contains('重试') ||
        message.contains('稍等') ||
        message.contains('请求间隔')) {
      return '等待重试';
    }
    return switch (status) {
      TranscriptionStatus.downloading => '下载音频',
      TranscriptionStatus.extracting => '准备音频',
      TranscriptionStatus.uploading => '上传音频',
      TranscriptionStatus.transcribing => '识别语音',
      TranscriptionStatus.optimizing => '优化字幕',
      TranscriptionStatus.translating => '翻译字幕',
      TranscriptionStatus.embedding => '内嵌字幕',
      TranscriptionStatus.completed => '转录完成',
      TranscriptionStatus.error => '转录失败',
      TranscriptionStatus.idle => '等待开始',
    };
  }

  static bool isWaiting(TranscriptionStatus status, String message) =>
      status == TranscriptionStatus.transcribing &&
      (message.contains('等待识别结果') ||
          message.contains('等待转录结果') ||
          message.startsWith('正在识别 · 已完成') ||
          message.contains('转录处理中') ||
          message.contains('查询结果时') ||
          message.contains('查询结果受到') ||
          message.contains('查询结果被服务端') ||
          message.contains('查询请求被拒绝') ||
          message.contains('继续查询上次') ||
          message.contains('结果查询被网络') ||
          message.contains('结果查询暂时异常') ||
          message.contains('服务器正在排队') ||
          message.contains('服务器正在识别'));
}
