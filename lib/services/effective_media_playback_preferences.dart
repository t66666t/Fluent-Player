import 'settings_service.dart';

/// Where an effective playback value came from.
///
/// A stored `false`, `0` or `1.0` is still an explicit override. Only a missing
/// key means "follow the layer above".
enum PlaybackPreferenceSource { software, podcastGlobal, channel, session }

class ResolvedPlaybackPreference<T> {
  const ResolvedPlaybackPreference(this.value, this.source);
  final T value;
  final PlaybackPreferenceSource source;

  String get sourceLabel => switch (source) {
    PlaybackPreferenceSource.software => '软件设置',
    PlaybackPreferenceSource.podcastGlobal => '播客全局',
    PlaybackPreferenceSource.channel => '本频道',
    PlaybackPreferenceSource.session => '本次播放',
  };
}

/// Software values that podcast playback is allowed to inherit.
class SoftwarePlaybackDefaults {
  const SoftwarePlaybackDefaults({
    required this.autoPlayOnCompletion,
    required this.effectiveSpeed,
    this.autoPlayOnCompletionFromStart = false,
    this.playlistWrapToFirst = false,
    this.speedLocked = false,
  });

  factory SoftwarePlaybackDefaults.current([SettingsService? service]) {
    final settings = service ?? SettingsService();
    return SoftwarePlaybackDefaults(
      autoPlayOnCompletion: settings.autoPlayOnCompletion,
      effectiveSpeed: settings.effectiveGlobalPlaybackSpeed,
      autoPlayOnCompletionFromStart: settings.autoPlayOnCompletionFromStart,
      playlistWrapToFirst: settings.playlistWrapToFirst,
      speedLocked: settings.isPlaybackSpeedLocked,
    );
  }

  final bool autoPlayOnCompletion;
  final double effectiveSpeed;
  final bool autoPlayOnCompletionFromStart;
  final bool playlistWrapToFirst;
  final bool speedLocked;
}

/// Resolves playback options from software, then explicit podcast overrides.
///
/// Podcast-only options (skip intro, downloads, refresh) stay in
/// [PodcastPreferences]. This type is only for values the rest of the player
/// already owns.
class EffectiveMediaPlaybackPreferences {
  const EffectiveMediaPlaybackPreferences();

  static const universalKeys = <String>{'continuous', 'speed'};

  ResolvedPlaybackPreference<bool> continuous({
    required Map<String, dynamic> globalRaw,
    Map<String, dynamic>? channelRaw,
    required SoftwarePlaybackDefaults software,
  }) {
    if (channelRaw != null && channelRaw.containsKey('continuous')) {
      return ResolvedPlaybackPreference(
        channelRaw['continuous'] == true,
        PlaybackPreferenceSource.channel,
      );
    }
    if (globalRaw.containsKey('continuous')) {
      return ResolvedPlaybackPreference(
        globalRaw['continuous'] == true,
        PlaybackPreferenceSource.podcastGlobal,
      );
    }
    return ResolvedPlaybackPreference(
      software.autoPlayOnCompletion,
      PlaybackPreferenceSource.software,
    );
  }

  ResolvedPlaybackPreference<double> speed({
    required Map<String, dynamic> globalRaw,
    Map<String, dynamic>? channelRaw,
    required SoftwarePlaybackDefaults software,
    double? sessionSpeed,
  }) {
    if (sessionSpeed != null && sessionSpeed.isFinite && sessionSpeed > 0) {
      return ResolvedPlaybackPreference(
        sessionSpeed,
        PlaybackPreferenceSource.session,
      );
    }
    if (channelRaw != null && channelRaw['speed'] is num) {
      return ResolvedPlaybackPreference(
        (channelRaw['speed'] as num).toDouble(),
        PlaybackPreferenceSource.channel,
      );
    }
    if (globalRaw['speed'] is num) {
      return ResolvedPlaybackPreference(
        (globalRaw['speed'] as num).toDouble(),
        PlaybackPreferenceSource.podcastGlobal,
      );
    }
    return ResolvedPlaybackPreference(
      software.effectiveSpeed,
      PlaybackPreferenceSource.software,
    );
  }

  /// Text for a settings row: "跟随软件（当前关闭）" or "播客独立设置".
  String caption({
    required String key,
    required bool channelScope,
    required bool explicitHere,
    required ResolvedPlaybackPreference<Object> resolved,
    required SoftwarePlaybackDefaults software,
  }) {
    if (channelScope) {
      return explicitHere ? '本频道独立设置' : '继承上层（${resolved.sourceLabel}）';
    }
    if (!universalKeys.contains(key)) return '';
    if (explicitHere) return '播客独立设置';
    if (key == 'continuous') {
      return '跟随软件（当前${software.autoPlayOnCompletion ? '开启' : '关闭'}）';
    }
    if (key == 'speed') {
      final locked = software.speedLocked ? '，已锁定' : '';
      return '跟随软件（当前 ${software.effectiveSpeed.toStringAsFixed(2)}x$locked）';
    }
    return '跟随软件';
  }
}
