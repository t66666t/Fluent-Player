import '../features/model_center/model_catalog.dart';
import '../services/subtitle_translate_settings.dart';
import 'subtitle_punctuation.dart';
import '../services/subtitle_optimization.dart';

/// The configuration saved with a task, independent of editable app settings.
class TranscriptionTaskConfiguration {
  const TranscriptionTaskConfiguration({
    required this.transcription,
    required this.translation,
    required this.punctuation,
    this.optimization = const SubtitleOptimizationChoice.off(),
  });

  final ModelJobSpec? transcription;
  final TranscriptTranslateChoice translation;
  final SubtitlePunctuation? punctuation;
  final SubtitleOptimizationChoice optimization;
}
