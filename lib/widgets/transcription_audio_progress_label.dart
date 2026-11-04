import 'package:flutter/material.dart';

import '../models/transcription_progress.dart';
import 'stable_width_label.dart';

/// One line with fixed numeric slots; only the committed audio time changes.
class TranscriptionAudioProgressLabel extends StatelessWidget {
  const TranscriptionAudioProgressLabel({
    super.key,
    required this.progress,
    this.style,
  });

  final TranscriptionAudioProgress progress;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.scaleDown,
    alignment: AlignmentDirectional.centerStart,
    child: StableWidthLabel(
      progress.label,
      variants: progress.widthVariants,
      alignment: AlignmentDirectional.centerStart,
      style: (style ?? const TextStyle()).copyWith(
        fontFeatures: [
          ...?style?.fontFeatures,
          const FontFeature.tabularFigures(),
        ],
      ),
    ),
  );
}
