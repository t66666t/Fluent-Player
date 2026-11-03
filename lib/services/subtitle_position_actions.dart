import 'package:flutter/widgets.dart';

import '../models/subtitle_position.dart';
import 'settings_service.dart';

/// Commits one settled drag or sidebar nudge to the position that owns it.
///
/// Memory is updated inside the settings call before the disk queue, so the
/// returned future is only the persistence result.
Future<PositionCommitResult> commitPlayerSubtitlePosition({
  required SettingsService settings,
  required SubtitlePositionTarget target,
  required SubtitlePlacement placement,
}) {
  final Alignment? alignment = placement.alignment;
  if (target.isGhost) {
    if (alignment == null) {
      return Future<PositionCommitResult>.value(
        const PositionCommitResult.success(0),
      );
    }
    return settings.saveGhostModeAlignment(alignment);
  }
  if (target.isPreset) {
    final String id = target.presetId!;
    if (target.isAudio) {
      return settings.commitPresetAudioPosition(id, alignment);
    }
    return settings.commitPresetVideoPosition(id, alignment);
  }
  if (alignment == null) {
    return Future<PositionCommitResult>.value(
      const PositionCommitResult.success(0),
    );
  }
  if (target.isAudio) return settings.saveAudioSubtitleAlignment(alignment);
  return settings.saveSubtitleAlignment(alignment);
}

Alignment displayedSubtitleAlignment({
  required SettingsService settings,
  required SubtitlePositionTarget target,
}) {
  if (target.isGhost) return settings.ghostModeAlignment;
  if (target.isPreset) {
    final Alignment? override = target.isAudio
        ? settings.presetAudioPosition(target.presetId!)
        : settings.presetVideoPosition(target.presetId!);
    return override ?? Alignment.bottomCenter;
  }
  return target.isAudio
      ? settings.audioSubtitleAlignment
      : settings.subtitleAlignment;
}

bool targetHasPresetOverride(
  SettingsService settings,
  SubtitlePositionTarget target,
) {
  if (!target.isPreset) return false;
  return settings.presetHasPositionOverride(
    target.presetId!,
    audio: target.isAudio,
  );
}
