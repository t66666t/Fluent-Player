import '../../models/subtitle_model.dart';
import 'inference_scheduler.dart';

class StableAsrBatch {
  const StableAsrBatch(
    this.cues,
    this.processedThrough,
    this.reservation, {
    this.retainConsumerModels = false,
    this.nativePipeline = false,
  });
  final List<SubtitleItem> cues;
  final Duration processedThrough;
  final InferenceReservation? reservation;
  final bool retainConsumerModels;
  final bool nativePipeline;
}

/// Coalesce ASR windows before invoking the translator. Its native requests
/// still obey the independent row, text-length and resource-pressure limits.
class LocalTranslationHandoffBuffer {
  final _pending = <StableAsrBatch>[];
  int _cueCount = 0;
  bool _published = false;
  bool get isEmpty => _pending.isEmpty;
  int get cueCount => _cueCount;

  Duration _span(Duration through) =>
      through - _pending.first.cues.first.startTime;

  bool wouldOverflow(StableAsrBatch next) =>
      !isEmpty &&
      (_cueCount + next.cues.length > 32 ||
          _span(next.processedThrough) > const Duration(seconds: 90));

  void add(StableAsrBatch batch) {
    if (batch.cues.isEmpty) return;
    if (!isEmpty &&
        (!identical(batch.reservation, _pending.first.reservation) ||
            batch.processedThrough < _pending.last.processedThrough ||
            batch.cues.first.index <= _pending.last.cues.last.index)) {
      throw StateError('翻译批次顺序或推理预约不匹配');
    }
    _pending.add(batch);
    _cueCount += batch.cues.length;
  }

  bool ready({
    required bool keepResident,
    int batchLimit = 8,
    bool endOfInput = false,
    bool protective = false,
    Duration? processedThrough,
  }) {
    if (isEmpty) return false;
    if (endOfInput || protective || keepResident && !_published) return true;
    return _cueCount >= (keepResident ? batchLimit.clamp(1, 8) : 32) ||
        _span(processedThrough ?? _pending.last.processedThrough) >=
            Duration(seconds: keepResident ? 45 : 90);
  }

  StableAsrBatch drain({
    required bool retainConsumerModels,
    bool pipelineAllowed = true,
  }) {
    if (isEmpty) throw StateError('没有待翻译的字幕');
    final batch = StableAsrBatch(
      List<SubtitleItem>.unmodifiable(_pending.expand((part) => part.cues)),
      _pending.last.processedThrough,
      _pending.first.reservation,
      retainConsumerModels: retainConsumerModels,
      nativePipeline:
          pipelineAllowed && _pending.every((part) => part.nativePipeline),
    );
    _pending.clear();
    _cueCount = 0;
    _published = true;
    return batch;
  }
}
