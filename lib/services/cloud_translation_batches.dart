import '../features/model_center/local_translation_handoff.dart';
import '../models/subtitle_model.dart';

/// Publication windows for an already complete cloud transcript. The local
/// translator keeps its own native row/resource limits and shares one model
/// session across these windows, so publishing never causes a model reload.
Iterable<StableAsrBatch> cloudTranslationBatches(
  List<SubtitleItem> cues, {
  int maxCues = 8,
  int maxRunes = 800,
  Duration maxSpan = const Duration(seconds: 30),
}) sync* {
  final limit = maxCues.clamp(1, 50);
  var batch = <SubtitleItem>[];
  var runes = 0;
  for (final cue in cues) {
    final length = cue.text.runes.length;
    if (batch.isNotEmpty &&
        (batch.length >= limit ||
            runes + length > maxRunes ||
            cue.endTime - batch.first.startTime > maxSpan)) {
      yield StableAsrBatch(
        batch,
        batch.last.endTime,
        null,
        retainConsumerModels: true,
      );
      batch = [];
      runes = 0;
    }
    batch.add(cue);
    runes += length;
  }
  if (batch.isNotEmpty) {
    yield StableAsrBatch(
      batch,
      batch.last.endTime,
      null,
      retainConsumerModels: true,
    );
  }
}
