import 'dart:async';

import '../features/model_center/model_background_tasks.dart';
import 'video_compose_manager.dart';

/// Installs the application's one foreground-task interruption owner.
void installModelTaskInterruptionHandler({
  required void Function() pauseTranscription,
  required void Function() cancelTranslation,
  required Future<void> Function() cancelOcr,
  required bool Function() modelCenterLoaded,
  required Future<void> Function() pauseModelDownloads,
  required VideoComposeManager videoComposeManager,
}) {
  ModelBackgroundTasks.onInterrupted = () {
    // Reserve the compose owner before another paused owner releases the
    // shared scheduler and allows an already queued compose to start.
    unawaited(videoComposeManager.interruptForSystem());
    pauseTranscription();
    cancelTranslation();
    unawaited(cancelOcr());
    if (modelCenterLoaded()) {
      unawaited(pauseModelDownloads());
    }
  };
}
