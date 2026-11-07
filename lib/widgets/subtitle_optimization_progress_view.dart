import 'package:flutter/material.dart';

import '../models/transcription_progress.dart';

/// Uses completed, saved batches rather than an estimated percentage.
class SubtitleOptimizationProgressView extends StatelessWidget {
  const SubtitleOptimizationProgressView({
    super.key,
    required this.progress,
    this.foregroundColor,
  });

  final SubtitleOptimizationProgress progress;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        progress.label,
        style: TextStyle(
          color: foregroundColor,
          fontSize: 12,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      const SizedBox(height: 4),
      LinearProgressIndicator(
        value: progress.fraction,
        minHeight: 3,
        borderRadius: BorderRadius.circular(999),
        backgroundColor: foregroundColor?.withValues(alpha: .12),
      ),
    ],
  );
}
