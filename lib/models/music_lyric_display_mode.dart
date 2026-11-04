/// Music-player lyric track choice. These names are subtitle roles, not
/// languages: both tracks may be the same language.
enum MusicLyricTrackDisplayMode {
  both,
  primary,
  secondary;

  static const String preferenceKey = 'musicLyricTrackDisplayMode';

  String get storageValue => name;

  String get label => switch (this) {
    MusicLyricTrackDisplayMode.both => '双语',
    MusicLyricTrackDisplayMode.primary => '主字幕',
    MusicLyricTrackDisplayMode.secondary => '副字幕',
  };
}

/// Unknown or damaged persisted values stay on the bilingual default.
MusicLyricTrackDisplayMode musicLyricTrackDisplayModeFromStorage(String? raw) {
  switch (raw) {
    case 'primary':
      return MusicLyricTrackDisplayMode.primary;
    case 'secondary':
      return MusicLyricTrackDisplayMode.secondary;
    case 'both':
    default:
      return MusicLyricTrackDisplayMode.both;
  }
}

String normalizeMusicLyricTrackDisplayMode(String raw) =>
    musicLyricTrackDisplayModeFromStorage(raw).storageValue;

/// Whether a song currently has readable text on each role.
class MusicLyricTrackAvailability {
  final bool hasPrimaryText;
  final bool hasSecondaryText;

  /// Cues exist, but none of them contain selectable characters.
  final bool imageOnly;

  const MusicLyricTrackAvailability({
    required this.hasPrimaryText,
    required this.hasSecondaryText,
    required this.imageOnly,
  });

  static const empty = MusicLyricTrackAvailability(
    hasPrimaryText: false,
    hasSecondaryText: false,
    imageOnly: false,
  );

  bool get hasSelectableText => hasPrimaryText || hasSecondaryText;
}

/// User preference is kept even when this song cannot honour it.
class MusicLyricEffectiveDisplay {
  final MusicLyricTrackDisplayMode preference;
  final MusicLyricTrackDisplayMode effective;
  final bool primaryEnabled;
  final bool secondaryEnabled;

  /// Shown once when the saved preference is temporarily downgraded.
  final String? notice;

  const MusicLyricEffectiveDisplay({
    required this.preference,
    required this.effective,
    required this.primaryEnabled,
    required this.secondaryEnabled,
    this.notice,
  });

  bool allows(MusicLyricTrackDisplayMode mode) => switch (mode) {
    MusicLyricTrackDisplayMode.both => true,
    MusicLyricTrackDisplayMode.primary => primaryEnabled,
    MusicLyricTrackDisplayMode.secondary => secondaryEnabled,
  };
}

MusicLyricEffectiveDisplay resolveMusicLyricEffectiveDisplay({
  required MusicLyricTrackDisplayMode preference,
  required MusicLyricTrackAvailability availability,
}) {
  final hasPrimary = availability.hasPrimaryText;
  final hasSecondary = availability.hasSecondaryText;
  var effective = preference;
  String? notice;
  if (preference == MusicLyricTrackDisplayMode.secondary &&
      !hasSecondary &&
      hasPrimary) {
    effective = MusicLyricTrackDisplayMode.primary;
    notice = '当前无副字幕，已显示主字幕';
  } else if (preference == MusicLyricTrackDisplayMode.primary &&
      !hasPrimary &&
      hasSecondary) {
    effective = MusicLyricTrackDisplayMode.secondary;
    notice = '当前无主字幕，已显示副字幕';
  } else if (!hasPrimary && !hasSecondary) {
    effective = MusicLyricTrackDisplayMode.both;
  }
  return MusicLyricEffectiveDisplay(
    preference: preference,
    effective: effective,
    primaryEnabled: hasPrimary,
    secondaryEnabled: hasSecondary,
    notice: notice,
  );
}
