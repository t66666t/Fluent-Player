import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Which saved position a drag commits to.
///
/// Ghost is shared by original captions and presets. A preset override never
/// writes the original-style alignment, and a video override never writes the
/// audio one.
enum SubtitlePositionChannel { video, audio, ghost }

/// Identity of the position being edited. [presetId] is null for original style.
@immutable
class SubtitlePositionTarget {
  final SubtitlePositionChannel channel;
  final String? presetId;

  const SubtitlePositionTarget({required this.channel, this.presetId});

  const SubtitlePositionTarget.video()
    : channel = SubtitlePositionChannel.video,
      presetId = null;

  const SubtitlePositionTarget.audio()
    : channel = SubtitlePositionChannel.audio,
      presetId = null;

  const SubtitlePositionTarget.ghost()
    : channel = SubtitlePositionChannel.ghost,
      presetId = null;

  const SubtitlePositionTarget.preset({
    required this.channel,
    required String id,
  }) : presetId = id;

  bool get isGhost => channel == SubtitlePositionChannel.ghost;
  bool get isPreset => !isGhost && presetId != null && presetId!.isNotEmpty;
  bool get isAudio => channel == SubtitlePositionChannel.audio;

  /// Ghost wins over the preset so a ghost session cannot land in a preset key.
  static SubtitlePositionTarget resolve({
    required bool ghost,
    required bool audio,
    required String? presetId,
  }) {
    if (ghost) return const SubtitlePositionTarget.ghost();
    final String? id = (presetId == null || presetId.isEmpty) ? null : presetId;
    if (id != null) {
      return SubtitlePositionTarget.preset(
        channel: audio
            ? SubtitlePositionChannel.audio
            : SubtitlePositionChannel.video,
        id: id,
      );
    }
    return audio
        ? const SubtitlePositionTarget.audio()
        : const SubtitlePositionTarget.video();
  }

  @override
  bool operator ==(Object other) =>
      other is SubtitlePositionTarget &&
      other.channel == channel &&
      other.presetId == presetId;

  @override
  int get hashCode => Object.hash(channel, presetId);
}

/// A missing override is [PresetDefaultPlacement], never a fake bottom alignment.
@immutable
sealed class SubtitlePlacement {
  const SubtitlePlacement();

  bool get isCustom => this is CustomAlignmentPlacement;

  Alignment? get alignment => switch (this) {
    CustomAlignmentPlacement(:final alignment) => alignment,
    PresetDefaultPlacement() => null,
  };
}

class PresetDefaultPlacement extends SubtitlePlacement {
  const PresetDefaultPlacement();
}

class CustomAlignmentPlacement extends SubtitlePlacement {
  @override
  final Alignment alignment;

  CustomAlignmentPlacement(this.alignment)
    : assert(alignment.x.isFinite && alignment.y.isFinite);

  CustomAlignmentPlacement.clamped(Alignment value)
    : alignment = clampSubtitleAlignment(value);
}

/// Alignment stored for original, audio, ghost and preset overrides.
Alignment clampSubtitleAlignment(Alignment value) {
  if (!value.x.isFinite || !value.y.isFinite) {
    return Alignment.bottomCenter;
  }
  return Alignment(
    value.x.clamp(-1.0, 1.0).toDouble(),
    value.y.clamp(-1.0, 1.0).toDouble(),
  );
}

bool isFiniteAlignment(Alignment value) => value.x.isFinite && value.y.isFinite;

/// Versioned placement frozen into a compose job.
///
/// Absent on an old job: a preset keeps its default bottom inset, and a job
/// without a preset keeps [VideoComposeRequest.subtitleAlignment].
@immutable
class SubtitlePlacementSnapshot {
  static const int currentVersion = 1;

  final int version;
  final SubtitlePlacement placement;

  const SubtitlePlacementSnapshot({
    required this.version,
    required this.placement,
  });

  const SubtitlePlacementSnapshot.presetDefault()
    : version = currentVersion,
      placement = const PresetDefaultPlacement();

  SubtitlePlacementSnapshot.custom(Alignment alignment)
    : version = currentVersion,
      placement = CustomAlignmentPlacement.clamped(alignment);

  bool get isCustom => placement.isCustom;

  Alignment? get alignment => placement.alignment;

  Map<String, dynamic> toJson() {
    final Alignment? align = alignment;
    if (align == null) {
      return <String, dynamic>{'version': version, 'mode': 'presetDefault'};
    }
    return <String, dynamic>{
      'version': version,
      'mode': 'customAlignment',
      'x': align.x,
      'y': align.y,
    };
  }

  /// Returns null when [json] is absent. A newer version is returned as
  /// [unrecognized] so callers do not treat it as "no override".
  static SubtitlePlacementParse parse(Object? json) {
    if (json == null) return const SubtitlePlacementParse.absent();
    if (json is! Map) return const SubtitlePlacementParse.invalid();
    final int? version = (json['version'] as num?)?.toInt();
    if (version == null) return const SubtitlePlacementParse.invalid();
    if (version > currentVersion) {
      return SubtitlePlacementParse.unrecognized(version);
    }
    final String? mode = json['mode'] as String?;
    if (mode == 'presetDefault') {
      return SubtitlePlacementParse.parsed(
        const SubtitlePlacementSnapshot(
          version: currentVersion,
          placement: PresetDefaultPlacement(),
        ),
      );
    }
    if (mode == 'customAlignment') {
      final double? x = (json['x'] as num?)?.toDouble();
      final double? y = (json['y'] as num?)?.toDouble();
      if (x == null || y == null || !x.isFinite || !y.isFinite) {
        return const SubtitlePlacementParse.invalid();
      }
      return SubtitlePlacementParse.parsed(
        SubtitlePlacementSnapshot.custom(Alignment(x, y)),
      );
    }
    return const SubtitlePlacementParse.invalid();
  }
}

enum SubtitlePlacementParseKind { absent, parsed, invalid, unrecognized }

@immutable
class SubtitlePlacementParse {
  final SubtitlePlacementParseKind kind;
  final SubtitlePlacementSnapshot? snapshot;
  final int? version;

  const SubtitlePlacementParse.absent()
    : kind = SubtitlePlacementParseKind.absent,
      snapshot = null,
      version = null;

  SubtitlePlacementParse.parsed(SubtitlePlacementSnapshot value)
    : kind = SubtitlePlacementParseKind.parsed,
      snapshot = value,
      version = value.version;

  const SubtitlePlacementParse.invalid()
    : kind = SubtitlePlacementParseKind.invalid,
      snapshot = null,
      version = null;

  const SubtitlePlacementParse.unrecognized(int value)
    : kind = SubtitlePlacementParseKind.unrecognized,
      snapshot = null,
      version = value;
}

/// How a preset lays out before a custom override exists.
///
/// Custom placement drops the default bottom inset so it is not applied twice.
/// Ghost mode always uses the shared alignment and no preset inset.
@immutable
class PresetLayoutDecision {
  final Alignment alignment;
  final double bottomInset;
  final bool custom;

  const PresetLayoutDecision({
    required this.alignment,
    required this.bottomInset,
    required this.custom,
  });
}

PresetLayoutDecision resolvePresetSubtitleLayout({
  required bool hasPreset,
  required bool ghost,
  required bool hasPositionOverride,
  required Alignment requestedAlignment,
  required double presetBottomInset,
}) {
  if (!hasPreset || ghost || hasPositionOverride) {
    return PresetLayoutDecision(
      alignment: requestedAlignment,
      bottomInset: 0,
      custom: hasPreset && !ghost && hasPositionOverride,
    );
  }
  return PresetLayoutDecision(
    alignment: Alignment.bottomCenter,
    bottomInset: math.max(0, presetBottomInset),
    custom: false,
  );
}

/// Result of a position write. A failure does not roll the in-memory value back.
@immutable
class PositionCommitResult {
  final bool ok;
  final int revision;
  final String? message;

  const PositionCommitResult({
    required this.ok,
    required this.revision,
    this.message,
  });

  const PositionCommitResult.success(this.revision)
    : ok = true,
      message = null;

  const PositionCommitResult.failure({
    required this.revision,
    required this.message,
  }) : ok = false;
}
