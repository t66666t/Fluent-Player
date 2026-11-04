import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart' as audio_service;
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart'
    show VideoPlayerPlatform;

import '../models/subtitle_model.dart';
import '../models/video_item.dart';
import 'media_playback_service.dart';
import 'playlist_manager.dart';
import 'settings_service.dart';
import 'desktop_media_session_service.dart';

@visibleForTesting
Future<Uri?> resolveExistingMediaArtworkUri(VideoItem item) async {
  final thumbnailPath = item.thumbnailPath?.trim();
  if (thumbnailPath == null || thumbnailPath.isEmpty) {
    return null;
  }
  final file = File(thumbnailPath);
  return await file.exists() ? file.uri : null;
}

@visibleForTesting
class SystemMediaControlLayout {
  const SystemMediaControlLayout({
    required this.controls,
    required this.androidCompactActionIndices,
  });

  final List<audio_service.MediaControl> controls;
  final List<int> androidCompactActionIndices;
}

/// Builds a stable system-control layout for an active media item.
///
/// Previous/next stay registered at queue boundaries. Android therefore keeps
/// the same compact slots instead of shifting the play button when an item is
/// first or last, while iOS receives real previousTrack/nextTrack commands.
/// A boundary command is harmless because MediaPlaybackService already
/// clamps previous/next navigation to the playable queue.
@visibleForTesting
SystemMediaControlLayout buildSystemMediaControlLayout({
  required bool enabled,
  required bool hasMedia,
  required bool playing,
  required bool canStepWithinMedia,
  required bool isIOS,
}) {
  if (!enabled || !hasMedia) {
    return const SystemMediaControlLayout(
      controls: <audio_service.MediaControl>[],
      androidCompactActionIndices: <int>[],
    );
  }

  final centerControl = playing
      ? audio_service.MediaControl.pause
      : audio_service.MediaControl.play;
  if (isIOS) {
    return SystemMediaControlLayout(
      controls: <audio_service.MediaControl>[
        audio_service.MediaControl.skipToPrevious,
        centerControl,
        audio_service.MediaControl.skipToNext,
      ],
      androidCompactActionIndices: const <int>[0, 1, 2],
    );
  }

  final controls = <audio_service.MediaControl>[
    audio_service.MediaControl.skipToPrevious,
    if (canStepWithinMedia) audio_service.MediaControl.rewind,
    centerControl,
    if (canStepWithinMedia) audio_service.MediaControl.fastForward,
    audio_service.MediaControl.skipToNext,
  ];
  return SystemMediaControlLayout(
    controls: controls,
    androidCompactActionIndices: <int>[
      0,
      controls.length ~/ 2,
      controls.length - 1,
    ],
  );
}

@visibleForTesting
Duration calculateSubtitleBoundaryDelay({
  required Duration position,
  required Duration boundary,
  required double playbackSpeed,
  required Duration padding,
  required Duration minimumDelay,
}) {
  final mediaDeltaUs = boundary.inMicroseconds - position.inMicroseconds;
  final speed = playbackSpeed.isFinite && playbackSpeed > 0
      ? playbackSpeed
      : 1.0;
  final wallDeltaUs = mediaDeltaUs <= 0 ? 0 : (mediaDeltaUs / speed).round();
  final delay = Duration(microseconds: wallDeltaUs) + padding;
  return delay < minimumDelay ? minimumDelay : delay;
}

/// Matches 网易云 / VLC / 哔哩哔哩 "允许与其他应用同时播放":
/// mix on iOS via [AVAudioSessionCategoryOptions.mixWithOthers], keep Android
/// as a music session, and never request exclusive focus while mixing.
///
/// Ducking stays a duck. Mapping LOSS_TRANSIENT_CAN_DUCK onto pause made
/// notification sounds, Dolby reroutes, and a late ExoPlayer AudioTrack start
/// indistinguishable from a phone call.
@visibleForTesting
AudioSessionConfiguration buildConcurrentPlaybackAudioSessionConfiguration({
  required bool allowConcurrentPlayback,
}) {
  return AudioSessionConfiguration.music().copyWith(
    avAudioSessionCategoryOptions: allowConcurrentPlayback
        ? AVAudioSessionCategoryOptions.mixWithOthers
        : AVAudioSessionCategoryOptions.none,
    androidWillPauseWhenDucked: false,
  );
}

/// Window after we request exclusive focus during which OEM/player-layer
/// AUDIOFOCUS_LOSS and speaker reroutes are treated as our own AudioTrack
/// starting, not as a real interruption.
@visibleForTesting
const Duration selfAudioFocusGrace = Duration(milliseconds: 1200);

@visibleForTesting
bool isWithinSelfAudioFocusGrace({
  required DateTime? exclusiveFocusGrantedAt,
  required DateTime now,
}) {
  if (exclusiveFocusGrantedAt == null) return false;
  final elapsed = now.difference(exclusiveFocusGrantedAt);
  return elapsed >= Duration.zero && elapsed < selfAudioFocusGrace;
}

/// Other media apps must not pause us when the user asked to mix. Phone-call
/// routing is still handled by the OS even if this callback is ignored.
/// Permanent LOSS that arrives while we are still taking focus is the
/// ExoPlayer/media_kit AudioTrack requesting GAIN against this same session.
@visibleForTesting
bool shouldPauseForAudioInterruption({
  required bool allowConcurrentPlayback,
  required bool interruptionBegan,
  required AudioInterruptionType type,
  bool withinSelfFocusGrace = false,
}) {
  if (!interruptionBegan || allowConcurrentPlayback) return false;
  if (type == AudioInterruptionType.duck) return false;
  if (withinSelfFocusGrace && type == AudioInterruptionType.unknown) {
    return false;
  }
  return true;
}

@visibleForTesting
bool shouldReclaimExclusiveFocusAfterInterruption({
  required bool allowConcurrentPlayback,
  required bool interruptionBegan,
  required AudioInterruptionType type,
  required bool desiredPlaying,
  required bool withinSelfFocusGrace,
}) {
  return desiredPlaying &&
      !allowConcurrentPlayback &&
      interruptionBegan &&
      withinSelfFocusGrace &&
      type == AudioInterruptionType.unknown;
}

@visibleForTesting
bool shouldPauseForBecomingNoisy({
  required bool isTransportPlaying,
  required bool withinSelfFocusGrace,
}) {
  return isTransportPlaying && !withinSelfFocusGrace;
}

/// One physical headset click is often delivered twice (Bluetooth AVRCP and
/// the media session). The second event toggles back and the press looks dead.
@visibleForTesting
const Duration headsetPlayPauseDebounce = Duration(milliseconds: 320);

enum HeadsetPlayPauseResolution { play, pause, ignore }

/// Toggle from the live transport, not the last notification snapshot.
///
/// Headset keys are all reported as play/pause. If that snapshot is still
/// "not playing" after a successful play, every later click calls play()
/// again and the button does nothing.
@visibleForTesting
HeadsetPlayPauseResolution resolveHeadsetPlayPause({
  required bool transportPlaying,
  required DateTime? lastAcceptedAt,
  required DateTime now,
  Duration debounce = headsetPlayPauseDebounce,
}) {
  if (lastAcceptedAt != null) {
    final Duration elapsed = now.difference(lastAcceptedAt);
    if (!elapsed.isNegative && elapsed < debounce) {
      return HeadsetPlayPauseResolution.ignore;
    }
  }
  return transportPlaying
      ? HeadsetPlayPauseResolution.pause
      : HeadsetPlayPauseResolution.play;
}

@visibleForTesting
bool shouldResumeAfterAudioInterruption({
  required bool allowConcurrentPlayback,
  required bool interruptionBegan,
  required AudioInterruptionType type,
  required bool isPaused,
  required bool pausedByInterruption,
  bool isIOS = false,
}) {
  if (allowConcurrentPlayback ||
      interruptionBegan ||
      !isPaused ||
      !pausedByInterruption) {
    return false;
  }
  // Android gain can be tagged duck after an overlapping duck event. It may
  // resume an owned temporary pause, but a duck alone never owns such a pause.
  return type == AudioInterruptionType.pause ||
      (!isIOS && type == AudioInterruptionType.duck);
}

/// What to do with the system media notification for one commit.
///
/// Playback is never stopped here. [suppress] removes the notification and
/// releases the session, used only when headset controls are also off.
/// [publishConcealed] keeps the session alive for headphone buttons and
/// hides the shade notification afterwards. [drop] ignores a stale toggle
/// or a repeat hide for an epoch already hidden.
enum SystemMediaNotificationCommit { publish, publishConcealed, suppress, drop }

/// Latest epoch wins. A hide that already ran for this epoch is not repeated,
/// and a publish captured before a newer toggle is discarded.
@visibleForTesting
SystemMediaNotificationCommit resolveSystemMediaNotificationCommit({
  required int epoch,
  required int capturedEpoch,
  required bool enabled,
  required int suppressedEpoch,
  required int suppressQueuedEpoch,
  bool headsetControlsEnabled = false,
}) {
  if (capturedEpoch != epoch) {
    return SystemMediaNotificationCommit.drop;
  }
  if (!enabled) {
    // Headphone play/pause is a toggle against the session's playing flag.
    // Dropping updates after the notification is hidden freezes that flag,
    // so the first press can start playback and every press after it is a
    // no-op. Keep publishing while headset controls are on.
    if (headsetControlsEnabled) {
      return SystemMediaNotificationCommit.publishConcealed;
    }
    if (suppressedEpoch == epoch || suppressQueuedEpoch == epoch) {
      return SystemMediaNotificationCommit.drop;
    }
    return SystemMediaNotificationCommit.suppress;
  }
  return SystemMediaNotificationCommit.publish;
}

/// iOS clears Now Playing by wiping the center, then refuses to write it back
/// when every field is unchanged. One millisecond forces that rewrite; the
/// truthful position is published immediately afterwards.
@visibleForTesting
Duration nudgedSystemMediaNotificationPosition(Duration position) {
  return position + const Duration(milliseconds: 1);
}

@visibleForTesting
bool shouldNudgeSystemMediaNotification({
  required bool isIOS,
  required bool nativeSuppressed,
  required bool hasMedia,
}) {
  return isIOS && nativeSuppressed && hasMedia;
}

/// Removes the Android/iOS media notification without stopping playback.
///
/// Publishing [AudioProcessingState.idle] would make audio_service destroy its
/// service, and the next show could fail to bring the notification back.
/// [suppress] also deactivates the session, and only when headset controls
/// are off. While headset controls stay on, [conceal] hides the shade
/// notification and leaves the session active so headphone buttons still
/// arrive. The player keeps running.
@immutable
class SystemMediaNotificationAvailability {
  const SystemMediaNotificationAvailability({
    required this.isKnown,
    this.channelBlocked = false,
    this.ordinaryNotificationsAllowed,
    this.canOpenSystemSettings = false,
  });

  final bool isKnown;
  final bool channelBlocked;

  /// Informational only: Android MediaSession notifications are exempt from
  /// the ordinary notification runtime permission.
  final bool? ordinaryNotificationsAllowed;
  final bool canOpenSystemSettings;
}

class SystemMediaNotificationGate {
  SystemMediaNotificationGate._();

  static const MethodChannel channel = MethodChannel(
    'com.example.video_player_app/media_notification',
  );
  static const MethodChannel _audioServiceHandlerChannel = MethodChannel(
    'com.ryanheise.audio_service.handler.methods',
  );

  @visibleForTesting
  static TargetPlatform? debugTargetPlatform;

  static bool get _isIOS =>
      !kIsWeb &&
      (debugTargetPlatform == TargetPlatform.iOS ||
          (debugTargetPlatform == null && Platform.isIOS));

  static bool get _isAndroid =>
      !kIsWeb &&
      (debugTargetPlatform == TargetPlatform.android ||
          (debugTargetPlatform == null && Platform.isAndroid));

  @visibleForTesting
  static Future<bool> Function()? debugSuppress;

  @visibleForTesting
  static Future<bool> Function()? debugConceal;

  @visibleForTesting
  static Future<bool> Function()? debugArmShow;

  @visibleForTesting
  static Future<bool> Function()? debugHoldPlaying;

  static Future<SystemMediaNotificationAvailability> readAvailability() async {
    if (_isIOS) {
      // Now Playing is not a user-notification authorization request.
      return const SystemMediaNotificationAvailability(isKnown: true);
    }
    if (!_isAndroid) {
      return const SystemMediaNotificationAvailability(isKnown: false);
    }
    try {
      final data = await channel
          .invokeMapMethod<String, dynamic>('readAvailability')
          .timeout(const Duration(seconds: 2));
      if (data == null || data['channelBlocked'] is! bool) {
        return const SystemMediaNotificationAvailability(isKnown: false);
      }
      return SystemMediaNotificationAvailability(
        isKnown: true,
        channelBlocked: data['channelBlocked'] as bool,
        ordinaryNotificationsAllowed:
            data['ordinaryNotificationsAllowed'] is bool
            ? data['ordinaryNotificationsAllowed'] as bool
            : null,
        canOpenSystemSettings: true,
      );
    } on MissingPluginException {
      return const SystemMediaNotificationAvailability(isKnown: false);
    } on PlatformException {
      return const SystemMediaNotificationAvailability(isKnown: false);
    } on TimeoutException {
      return const SystemMediaNotificationAvailability(isKnown: false);
    }
  }

  static Future<bool> openSystemSettings() async {
    if (!_isAndroid) return false;
    try {
      return await channel
              .invokeMethod<bool>('openSystemSettings')
              .timeout(const Duration(seconds: 2)) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } on TimeoutException {
      return false;
    }
  }

  static Future<bool> suppress() async {
    final override = debugSuppress;
    if (override != null) {
      return override();
    }
    if (_isIOS) {
      final hidden = await _setNowPlayingVisible(false);
      // Keep the existing full-suppression policy for remote commands. Conceal
      // deliberately does not make this AppDelegate call.
      final suppressed = await _invoke('suppress');
      return hidden && suppressed;
    }
    return _invoke('suppress');
  }

  /// Hides system metadata without releasing the media session.
  ///
  /// Deactivating the session is what made headset buttons stop arriving, and
  /// what let some devices pause playback when the activity came back.
  static Future<bool> conceal() async {
    final override = debugConceal;
    if (override != null) {
      return override();
    }
    if (_isIOS) {
      return _setNowPlayingVisible(false);
    }
    if (!_isAndroid) {
      return true;
    }
    return _invoke('conceal');
  }

  /// Stops the next playback update from starting a foreground notification.
  ///
  /// audio_service shows that notification on a not-playing to playing
  /// transition. Headset control has to publish the real state anyway, or
  /// the toggle sticks. Marking the service already-playing skips the
  /// transition; the update that follows still writes play or pause.
  static Future<bool> holdPlaying() async {
    final override = debugHoldPlaying;
    if (override != null) {
      return override();
    }
    if (_isIOS) {
      // Install a persistent native policy before audio_service consumes its
      // asynchronous state/metadata streams; a one-time clear can be overwritten.
      return _setNowPlayingVisible(false);
    }
    if (!_isAndroid) {
      return true;
    }
    return _invoke('holdPlaying');
  }

  /// Forces the next playing update to look like a transition into playback,
  /// so audio_service will create the foreground notification again.
  static Future<bool> armShow() async {
    final override = debugArmShow;
    if (override != null) {
      return override();
    }
    if (_isIOS) {
      return _setNowPlayingVisible(true);
    }
    if (!_isAndroid) {
      return true;
    }
    return _invoke('armShow');
  }

  static Future<bool> _invoke(String method) async {
    if (!_isAndroid && !_isIOS) {
      return true;
    }
    try {
      final hidden = await channel.invokeMethod<bool>(method);
      return hidden ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<bool> _setNowPlayingVisible(bool visible) async {
    try {
      final applied = await _audioServiceHandlerChannel
          .invokeMethod<bool>('setNowPlayingVisible', {'visible': visible})
          .timeout(const Duration(seconds: 2));
      return applied ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error) {
      debugPrint('SystemMediaNotificationGate: iOS visibility failed: $error');
      return false;
    } on TimeoutException {
      // An old/uninitialized host must not strand every later session commit.
      return false;
    }
  }
}

typedef _AudioFocusIntent = ({
  bool desiredPlaying,
  bool concurrent,
  MediaPlaybackService? owner,
  int? generation,
  AppLifecycleState? lifecycle,
});

@immutable
class SystemMediaNotificationFailure {
  const SystemMediaNotificationFailure({
    required this.epoch,
    required this.requestedVisible,
    required this.mediaId,
    required this.sessionGeneration,
    this.diagnostic,
  });

  final int epoch, sessionGeneration;
  final bool requestedVisible;
  final String mediaId;
  final String? diagnostic;
}

class SystemMediaSessionService {
  SystemMediaSessionService._internal()
    : _unknownInterruptionMayResume = !kIsWeb && Platform.isIOS,
      _setAudioSessionActiveForTesting = null;

  @visibleForTesting
  SystemMediaSessionService.forTesting({
    required MediaPlaybackService playbackService,
    DateTime? exclusiveFocusGrantedAt,
    bool isIOS = false,
    Future<bool> Function(bool active)? setAudioSessionActive,
  }) : _unknownInterruptionMayResume = isIOS,
       _setAudioSessionActiveForTesting = setAudioSessionActive,
       _playbackService = playbackService,
       _exclusiveFocusGrantedAt = exclusiveFocusGrantedAt;

  // audio_session maps all iOS interruption begins to unknown. Its end event
  // carries shouldResume; Android unknown instead represents permanent LOSS.
  final bool _unknownInterruptionMayResume;
  final Future<bool> Function(bool active)? _setAudioSessionActiveForTesting;

  static final SystemMediaSessionService instance =
      SystemMediaSessionService._internal();

  static const Duration _progressSyncThrottle = Duration(milliseconds: 800);
  static const Duration _seekJumpThreshold = Duration(milliseconds: 1500);
  static const Duration _subtitleBoundarySyncPadding = Duration(
    milliseconds: 12,
  );
  static const Duration _minimumSubtitleBoundaryDelay = Duration(
    milliseconds: 20,
  );

  _SystemMediaAudioHandler? _handler;
  MediaPlaybackService? _playbackService;
  PlaylistManager? _playlistManager;
  final SettingsService _settingsService = SettingsService();
  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;
  StreamSubscription<void>? _becomingNoisySubscription;
  Timer? _scheduledSyncTimer;
  Timer? _scheduledSubtitleBoundaryTimer;
  bool _isPublishingQueue = false;
  bool _initialized = false;

  _PlaybackSnapshot? _lastSnapshot;
  DateTime _lastPublishedAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _audioPlaceholderArtworkPath;
  audio_service.MediaItem? _lastPublishedMediaItem;
  bool? _lastAllowConcurrentPlayback;
  bool? _lastHeadsetControlEnabled;
  bool? _audioFocusHeld;
  bool _audioFocusReleaseRequired = false;
  Future<void> _audioFocusSyncChain = Future<void>.value();
  int _audioFocusSyncRevision = 0;
  int _audioFocusIntentEpoch = 0;
  _AudioFocusIntent? _deniedAudioFocusIntent;
  _AudioFocusIntent? _latestAudioFocusIntent;
  DateTime? _exclusiveFocusGrantedAt;
  _AudioInterruptionPause? _interruptionPause;
  int _publishRevision = 0;
  int _notificationVisibilityPrimeRevision = 0;
  int _notificationEpoch = 0;
  final _notificationFailure = ValueNotifier<SystemMediaNotificationFailure?>(
    null,
  );
  int _notificationFeedbackGeneration = 0;

  /// Only a rejected native visibility operation for an owned media session
  /// sets this value. An absent/paused player is not itself a failure.
  ValueListenable<SystemMediaNotificationFailure?> get notificationFailure =>
      _notificationFailure;
  int _suppressedEpoch = -1;
  int _suppressQueuedEpoch = -1;
  bool _nativeNotificationSuppressed = false;
  bool _needsNotificationRearm = false;
  int _notificationRearmAttemptEpoch = -1;
  bool? _lastShowSystemMediaNotification;
  Future<void> _sessionCommitChain = Future<void>.value();
  String? _lastVisibleNotificationItemId;
  String? _artworkCacheKey;
  Uri? _artworkCacheValue;
  bool _artworkCacheValid = false;

  void _logMediaSessionEvent(String message, {Map<String, Object?>? data}) {
    if (!kDebugMode) return;
    final buffer = StringBuffer('SystemMediaSessionService: $message');
    if (data != null && data.isNotEmpty) {
      buffer.write(' | ');
      bool first = true;
      data.forEach((key, value) {
        if (!first) buffer.write(', ');
        first = false;
        buffer.write('$key=$value');
      });
    }
    debugPrint(buffer.toString());
  }

  bool get isSupportedPlatform {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  bool get headsetControlsEnabled =>
      _settingsService.enableHeadsetMediaControls;

  Future<void> _configureAudioSession() async {
    if (!isSupportedPlatform) {
      return;
    }
    final session = await AudioSession.instance;
    final bool allowConcurrentPlayback =
        _settingsService.allowConcurrentPlayback;
    await session.configure(
      buildConcurrentPlaybackAudioSessionConfiguration(
        allowConcurrentPlayback: allowConcurrentPlayback,
      ),
    );
    // video_player (and the media_kit adapter's platform fallback) keeps a
    // process-wide mix flag. Apply it here so a toggle takes effect before
    // the next VideoPlayerController is created. Android always mixes at the
    // ExoPlayer layer; exclusive focus stays on this AudioSession.
    try {
      await VideoPlayerPlatform.instance.setMixWithOthers(
        MediaPlaybackService.platformPlayerShouldMixWithOthers(
          isAndroid: Platform.isAndroid,
          allowConcurrentPlayback: allowConcurrentPlayback,
        ),
      );
    } catch (error) {
      _logMediaSessionEvent(
        'mixWithOthers apply failed',
        data: <String, Object?>{'error': error.toString()},
      );
    }
    _logMediaSessionEvent(
      'audio session configured',
      data: <String, Object?>{
        'platform': Platform.isIOS ? 'ios' : 'android',
        'dynamicIslandMode': Platform.isIOS ? 'system_mapped' : 'n/a',
        'allowConcurrentPlayback': allowConcurrentPlayback,
      },
    );
  }

  Future<bool> _setAudioSessionActive(bool active) async {
    final activation = _setAudioSessionActiveForTesting;
    return activation != null
        ? await activation(active)
        : await (await AudioSession.instance).setActive(active);
  }

  Future<bool> _clearFailedAudioFocusRequest() async {
    _audioFocusReleaseRequired = true;
    _audioFocusHeld = null;
    _exclusiveFocusGrantedAt = null;
    try {
      // audio_session's Android adapter retains its AudioFocusRequest even
      // when the OS denies it; another active(true) would otherwise return
      // true without asking Android again. Clear it before any later attempt.
      final released = await _setAudioSessionActive(false);
      if (released) {
        _audioFocusReleaseRequired = false;
        _audioFocusHeld = false;
        return true;
      }
    } catch (error) {
      _logMediaSessionEvent(
        'failed audio focus request cleanup failed',
        data: <String, Object?>{'error': error.toString()},
      );
    }
    return false;
  }

  /// Android retains its request during an owned temporary interruption so
  /// the OS can return focus. iOS keeps the existing activation/deactivation
  /// path; mix mode abandons exclusive focus.
  Future<void> _syncAudioFocusWithPlayback({required bool desiredPlaying}) {
    if (!isSupportedPlatform && _setAudioSessionActiveForTesting == null) {
      return Future<void>.value();
    }
    final intent = (
      desiredPlaying: desiredPlaying,
      concurrent: _settingsService.allowConcurrentPlayback,
      owner: _playbackService,
      generation: _playbackService?.session.generation,
      lifecycle: WidgetsBinding.instance.lifecycleState,
    );
    // Position publications replace queued work, but only a semantic intent
    // edge can authorize retrying a denied request. A pause/play pair must not
    // be mistaken for the old play just because its final value is equal.
    if (_latestAudioFocusIntent != intent) _audioFocusIntentEpoch++;
    final intentEpoch = _audioFocusIntentEpoch;
    _latestAudioFocusIntent = intent;
    if (!intent.desiredPlaying || intent.concurrent) {
      _deniedAudioFocusIntent = null;
    }
    final revision = ++_audioFocusSyncRevision;
    // A slow grant/release must finish before the opposite request. Publishing
    // position while it is pending only replaces the queued intent, rather
    // than allowing an older acknowledgement to become the final native state.
    final operation = _audioFocusSyncChain.then((_) async {
      if (revision != _audioFocusSyncRevision) return;
      // A temporary focus loss retains its request so Android can deliver the
      // matching gain. It does not authorize new playback or reclaim focus.
      if (!_unknownInterruptionMayResume &&
          !intent.desiredPlaying &&
          !intent.concurrent &&
          _ownsInterruptionPause(_playbackService)) {
        return;
      }
      final wantExclusiveFocus = intent.desiredPlaying && !intent.concurrent;
      if (!wantExclusiveFocus) _deniedAudioFocusIntent = null;
      if (_audioFocusHeld == wantExclusiveFocus ||
          (wantExclusiveFocus && _deniedAudioFocusIntent == intent)) {
        return;
      }
      try {
        if (wantExclusiveFocus &&
            _audioFocusReleaseRequired &&
            !await _clearFailedAudioFocusRequest()) {
          if (intentEpoch == _audioFocusIntentEpoch) {
            _deniedAudioFocusIntent = intent;
          }
          return;
        }
        final granted = await _setAudioSessionActive(wantExclusiveFocus);
        if (wantExclusiveFocus && !granted) {
          if (intentEpoch == _audioFocusIntentEpoch) {
            _deniedAudioFocusIntent = intent;
          }
          await _clearFailedAudioFocusRequest();
          _logMediaSessionEvent(
            'audio focus request denied',
            data: <String, Object?>{'desiredPlaying': intent.desiredPlaying},
          );
          return;
        }
        if (!granted) {
          _audioFocusHeld = null;
          _exclusiveFocusGrantedAt = null;
          _audioFocusReleaseRequired = true;
          return;
        }
        // Record what the native call actually did, even if superseded. The
        // latest queued operation then sees that state and compensates it.
        _audioFocusHeld = wantExclusiveFocus;
        _audioFocusReleaseRequired = false;
        _deniedAudioFocusIntent = null;
        final latest = _latestAudioFocusIntent;
        _exclusiveFocusGrantedAt =
            wantExclusiveFocus &&
                latest != null &&
                latest.desiredPlaying &&
                !latest.concurrent &&
                identical(latest.owner, intent.owner) &&
                latest.generation == intent.generation
            ? DateTime.now()
            : null;
        _logMediaSessionEvent(
          'audio focus synced',
          data: <String, Object?>{
            'held': wantExclusiveFocus,
            'allowConcurrentPlayback': intent.concurrent,
          },
        );
      } catch (error) {
        if (wantExclusiveFocus) {
          if (intentEpoch == _audioFocusIntentEpoch) {
            _deniedAudioFocusIntent = intent;
          }
          await _clearFailedAudioFocusRequest();
        } else {
          _audioFocusHeld = null;
          _audioFocusReleaseRequired = true;
        }
        _logMediaSessionEvent(
          'audio focus sync failed',
          data: <String, Object?>{'error': error.toString()},
        );
      }
    });
    _audioFocusSyncChain = operation;
    return operation;
  }

  Future<void> _applyConcurrentPlaybackSetting() async {
    await _configureAudioSession();
    await _syncAudioFocusWithPlayback(
      desiredPlaying: _playbackService?.desiredPlaying ?? false,
    );
    await _playbackService?.applyConcurrentPlaybackSetting();
  }

  void _handleSettingsChanged() {
    final bool allowConcurrentPlayback =
        _settingsService.allowConcurrentPlayback;
    final bool headsetControlsEnabled =
        _settingsService.enableHeadsetMediaControls;
    if (_lastAllowConcurrentPlayback != allowConcurrentPlayback) {
      _lastAllowConcurrentPlayback = allowConcurrentPlayback;
      _interruptionPause = null;
      _audioFocusHeld = null;
      _deniedAudioFocusIntent = null;
      unawaited(_applyConcurrentPlaybackSetting());
    }
    if (_lastHeadsetControlEnabled != headsetControlsEnabled) {
      _lastHeadsetControlEnabled = headsetControlsEnabled;
      final snapshot = _buildSnapshot();
      _schedulePublish(immediate: true, snapshot: snapshot);
    }
    final bool showNotification = _settingsService.showSystemMediaNotification;
    if (_lastShowSystemMediaNotification != showNotification) {
      _lastShowSystemMediaNotification = showNotification;
      unawaited(_applySystemMediaNotificationSetting(showNotification));
    }
  }

  /// Serializes notification show/hide so a slow hide cannot land after a
  /// newer show, and a show cannot land after a newer hide.
  Future<void> _commitSession(Future<void> Function() action) {
    final run = _sessionCommitChain.then((_) => action());
    _sessionCommitChain = run.catchError((Object error, StackTrace stack) {
      _logMediaSessionEvent(
        'session commit failed',
        data: <String, Object?>{'error': error.toString()},
      );
    });
    return run;
  }

  Future<void> _applySystemMediaNotificationSetting(bool enabled) {
    _notificationEpoch++;
    _notificationFailure.value = null;
    // Drop artwork work that already decided to publish the opposite state.
    _publishRevision++;
    _notificationVisibilityPrimeRevision++;
    _scheduledSyncTimer?.cancel();
    _scheduledSyncTimer = null;
    _scheduledSubtitleBoundaryTimer?.cancel();
    _scheduledSubtitleBoundaryTimer = null;
    final int epoch = _notificationEpoch;
    if (!enabled) {
      if (headsetControlsEnabled) {
        // The session has to stay active or the next headphone press never
        // arrives, and coming back to the app can pause an orphaned player.
        _needsNotificationRearm = false;
        _suppressQueuedEpoch = -1;
        _lastSnapshot = null;
        return _publishSnapshot(force: true);
      }
      _suppressQueuedEpoch = epoch;
      return _commitSession(() => _suppressSystemMediaNotification(epoch));
    }
    _needsNotificationRearm = true;
    _lastSnapshot = null;
    _lastVisibleNotificationItemId = null;
    return () async {
      await _publishSnapshot(force: true);
      if (epoch != _notificationEpoch) return;
      if (!_settingsService.showSystemMediaNotification) return;
      await _ensureAndroidNotificationVisible(_buildSnapshot(), epoch: epoch);
    }();
  }

  /// Resend only the current visibility intent, using the existing commit
  /// path. It does not initialize a session or change a playback preference.
  Future<void> retryNotificationVisibility() async {
    _clearOutdatedNotificationFailure();
    if (!_initialized ||
        _handler == null ||
        _notificationFailure.value == null) {
      return;
    }
    await _applySystemMediaNotificationSetting(
      _settingsService.showSystemMediaNotification,
    );
  }

  void _clearOutdatedNotificationFailure() {
    final failure = _notificationFailure.value;
    final owner = _playbackService;
    if (failure != null &&
        (owner == null ||
            owner.currentItem?.id != failure.mediaId ||
            owner.session.generation != failure.sessionGeneration ||
            owner.state == PlaybackState.idle)) {
      _notificationFailure.value = null;
    }
  }

  Future<bool> _observeNotificationVisibility(
    int epoch, {
    required bool visible,
    required Future<bool> Function() operation,
    bool clearOnSuccess = true,
  }) async {
    final owner = _playbackService;
    final mediaId = owner?.currentItem?.id;
    final sessionGeneration = owner?.session.generation;
    final feedbackGeneration = _notificationFeedbackGeneration;
    void record(bool accepted, [Object? error]) {
      if (epoch != _notificationEpoch ||
          feedbackGeneration != _notificationFeedbackGeneration ||
          !identical(owner, _playbackService) ||
          mediaId == null ||
          owner?.currentItem?.id != mediaId ||
          owner?.session.generation != sessionGeneration ||
          owner?.state == PlaybackState.idle) {
        return;
      }
      if (accepted) {
        if (clearOnSuccess) _notificationFailure.value = null;
        return;
      }
      final previous = _notificationFailure.value;
      final diagnostic = error?.toString();
      if (previous?.epoch == epoch &&
          previous?.requestedVisible == visible &&
          previous?.diagnostic == diagnostic) {
        return;
      }
      _notificationFailure.value = SystemMediaNotificationFailure(
        epoch: epoch,
        requestedVisible: visible,
        mediaId: mediaId,
        sessionGeneration: sessionGeneration!,
        diagnostic: diagnostic,
      );
    }

    try {
      final accepted = await operation();
      record(accepted);
      return accepted;
    } catch (error) {
      record(false, error);
      rethrow;
    }
  }

  Future<void> _suppressSystemMediaNotification(int epoch) async {
    if (epoch != _notificationEpoch || _suppressedEpoch == epoch) return;
    _playbackService?.setMediaNotificationVisible(false);
    _lastSnapshot = null;
    _lastPublishedMediaItem = null;
    _lastVisibleNotificationItemId = null;
    final bool hidden = await _observeNotificationVisibility(
      epoch,
      visible: false,
      operation: SystemMediaNotificationGate.suppress,
    );
    // The native clear already happened. A newer show is queued behind this
    // commit and needs to know the center was wiped, even if the epoch moved
    // on while the platform call was in flight.
    if (hidden) {
      _nativeNotificationSuppressed = true;
    }
    if (epoch != _notificationEpoch) return;
    _suppressedEpoch = epoch;
    _logMediaSessionEvent(
      'system media notification suppressed',
      data: <String, Object?>{'hidden': hidden, 'epoch': epoch},
    );
  }

  Future<void> initialize({
    required MediaPlaybackService playbackService,
    required PlaylistManager playlistManager,
  }) async {
    if (DesktopMediaSessionService.isSupportedPlatform) {
      await DesktopMediaSessionService.instance.initialize(
        playbackService: playbackService,
        playlistManager: playlistManager,
      );
      return;
    }
    if (!isSupportedPlatform) {
      return;
    }

    if (!_initialized) {
      final session = await AudioSession.instance;
      _lastAllowConcurrentPlayback = _settingsService.allowConcurrentPlayback;
      _lastHeadsetControlEnabled = _settingsService.enableHeadsetMediaControls;
      _lastShowSystemMediaNotification =
          _settingsService.showSystemMediaNotification;
      _settingsService.addListener(_handleSettingsChanged);
      await _configureAudioSession();

      _handler = await audio_service.AudioService.init(
        builder: _SystemMediaAudioHandler.new,
        config: audio_service.AudioServiceConfig(
          androidNotificationChannelId:
              'com.example.video_player_app.media_playback',
          androidNotificationChannelName: '媒体播放',
          androidNotificationIcon: 'drawable/ic_notification_icon',
          androidShowNotificationBadge: false,
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: false,
          preloadArtwork: true,
        ),
      );

      _interruptionSubscription = session.interruptionEventStream.listen((
        event,
      ) {
        unawaited(_handleAudioInterruption(event));
      });
      _becomingNoisySubscription = session.becomingNoisyEventStream.listen((_) {
        _handleBecomingNoisy();
      });

      _initialized = true;
    }

    _bindPlaybackService(playbackService);
    _bindPlaylistManager(playlistManager);
    _handler?.attach(
      playbackService: playbackService,
      playlistManager: playlistManager,
    );
    await _syncAudioFocusWithPlayback(
      desiredPlaying: playbackService.desiredPlaying,
    );
    _publishQueue();
    await _publishSnapshot(force: true);
  }

  @visibleForTesting
  Future<void> handleAudioInterruptionForTesting(
    AudioInterruptionEvent event,
  ) => _handleAudioInterruption(event);

  @visibleForTesting
  Future<void> syncAudioFocusForTesting({required bool desiredPlaying}) =>
      _syncAudioFocusWithPlayback(desiredPlaying: desiredPlaying);

  @visibleForTesting
  Future<void> flushAudioFocusForTesting() => _audioFocusSyncChain;

  /// Keeps the real settings/publication/handler path while replacing only
  /// native AudioService construction in host regression tests.
  @visibleForTesting
  audio_service.BaseAudioHandler attachPublicationHandlerForTesting({
    required PlaylistManager playlistManager,
  }) {
    final playback = _playbackService!;
    _handler = _SystemMediaAudioHandler(session: this)
      ..attach(playbackService: playback, playlistManager: playlistManager);
    _playlistManager = playlistManager;
    _initialized = true;
    _lastShowSystemMediaNotification =
        _settingsService.showSystemMediaNotification;
    _lastAllowConcurrentPlayback = _settingsService.allowConcurrentPlayback;
    _lastHeadsetControlEnabled = _settingsService.enableHeadsetMediaControls;
    _settingsService.addListener(_handleSettingsChanged);
    return _handler!;
  }

  @visibleForTesting
  Future<void> publishSnapshotForTesting({
    bool explicitRefresh = false,
    bool ensureNotificationVisible = false,
  }) async {
    if (explicitRefresh) _retryNotificationVisibility();
    await _publishSnapshot(force: true);
    await _sessionCommitChain;
    if (ensureNotificationVisible) {
      await _ensureAndroidNotificationVisible(_buildSnapshot());
    }
  }

  @visibleForTesting
  Future<void> flushPublicationsForTesting() => _sessionCommitChain;

  @visibleForTesting
  ({bool needsRearm, bool nativeSuppressed, String? visibleItemId})
  get notificationVisibilityForTesting => (
    needsRearm: _needsNotificationRearm,
    nativeSuppressed: _nativeNotificationSuppressed,
    visibleItemId: _lastVisibleNotificationItemId,
  );

  @visibleForTesting
  void handleBecomingNoisyForTesting() => _handleBecomingNoisy();

  bool _ownsInterruptionPause(MediaPlaybackService? playback) =>
      playback != null &&
      _interruptionPause?.matches(playback) == true &&
      !playback.desiredPlaying &&
      !playback.hasPlaybackCompleted &&
      playback.state != PlaybackState.error;

  Future<void> _handleAudioInterruption(AudioInterruptionEvent event) async {
    final playback = _playbackService;
    final allowConcurrentPlayback = _settingsService.allowConcurrentPlayback;
    final withinSelfFocusGrace =
        !_unknownInterruptionMayResume &&
        isWithinSelfAudioFocusGrace(
          exclusiveFocusGrantedAt: _exclusiveFocusGrantedAt,
          now: DateTime.now(),
        );
    _logMediaSessionEvent(
      'audio interruption',
      data: {
        'begin': event.begin,
        'type': event.type.name,
        'allowConcurrentPlayback': allowConcurrentPlayback,
        'withinSelfFocusGrace': withinSelfFocusGrace,
        'itemId': playback?.currentItem?.id,
        'desiredPlaying': playback?.desiredPlaying,
        'ownsPause': _ownsInterruptionPause(playback),
      },
    );
    if (allowConcurrentPlayback) {
      _interruptionPause = null;
      return;
    }
    if (shouldReclaimExclusiveFocusAfterInterruption(
      allowConcurrentPlayback: allowConcurrentPlayback,
      interruptionBegan: event.begin,
      type: event.type,
      desiredPlaying: playback?.desiredPlaying ?? false,
      withinSelfFocusGrace: withinSelfFocusGrace,
    )) {
      _audioFocusHeld = null;
      _deniedAudioFocusIntent = null;
      unawaited(_syncAudioFocusWithPlayback(desiredPlaying: true));
      return;
    }
    if (event.begin) {
      if (!shouldPauseForAudioInterruption(
        allowConcurrentPlayback: allowConcurrentPlayback,
        interruptionBegan: true,
        type: event.type,
        withinSelfFocusGrace: withinSelfFocusGrace,
      )) {
        return;
      }
      // Duplicate OEM loss events cannot replace the original playing intent
      // with the already-paused snapshot or increment its pause revision.
      final mayResume =
          event.type == AudioInterruptionType.pause ||
          (_unknownInterruptionMayResume &&
              event.type == AudioInterruptionType.unknown);
      if (mayResume && _ownsInterruptionPause(playback)) {
        return;
      }
      _interruptionPause = null;
      if (playback == null) return;
      final itemId = playback.currentItem?.id;
      if (mayResume &&
          playback.desiredPlaying &&
          !playback.hasPlaybackCompleted &&
          itemId != null) {
        // pause() records its revision and false intent synchronously, before
        // native acknowledgements. A subsequent user/timer pause supersedes it
        // even when the public state was already paused.
        _interruptionPause = _AudioInterruptionPause(
          playback,
          itemId,
          playback.session.generation,
          playback.pauseIntentRevision + 1,
        );
      }
      await playback.pause();
      return;
    }
    // Consume before resuming. Duplicate gains and gains with no matching loss
    // must never authorize playback of an arbitrary paused session.
    final paused = _interruptionPause;
    _interruptionPause = null;
    if (playback == null) return;
    playback.sleepTimer.checkNow();
    final ownsPause =
        identical(_playbackService, playback) &&
        paused?.matches(playback) == true &&
        !playback.hasPlaybackCompleted &&
        playback.state != PlaybackState.error;
    if (shouldResumeAfterAudioInterruption(
      allowConcurrentPlayback: allowConcurrentPlayback,
      interruptionBegan: false,
      type: event.type,
      isPaused: !playback.desiredPlaying,
      pausedByInterruption: ownsPause,
      isIOS: _unknownInterruptionMayResume,
    )) {
      _logMediaSessionEvent(
        'resuming owned audio interruption',
        data: {
          'itemId': playback.currentItem?.id,
          'pauseRevision': playback.pauseIntentRevision,
        },
      );
      if (_unknownInterruptionMayResume) {
        // AVAudioSession can have been deactivated by the interruption even
        // if our last asynchronous activation acknowledgement said active.
        _audioFocusHeld = null;
        _deniedAudioFocusIntent = null;
      }
      await playback.resume();
    } else {
      _logMediaSessionEvent(
        'audio interruption resume ignored',
        data: {
          'itemId': playback.currentItem?.id,
          'reason': paused == null
              ? 'no_owned_pause'
              : 'pause_or_session_changed',
        },
      );
      unawaited(
        _syncAudioFocusWithPlayback(desiredPlaying: playback.desiredPlaying),
      );
    }
  }

  void _handleBecomingNoisy() {
    // Removing headphones while already interrupted must also revoke the
    // pending resume, otherwise the later gain would play on the speaker.
    final hadInterruptionPause = _interruptionPause != null;
    _interruptionPause = null;
    if (hadInterruptionPause) {
      unawaited(
        _syncAudioFocusWithPlayback(
          desiredPlaying: _playbackService?.desiredPlaying ?? false,
        ),
      );
    }
    final withinSelfFocusGrace = isWithinSelfAudioFocusGrace(
      exclusiveFocusGrantedAt: _exclusiveFocusGrantedAt,
      now: DateTime.now(),
    );
    final isTransportPlaying = _playbackService?.isTransportPlaying ?? false;
    _logMediaSessionEvent(
      'becoming noisy received',
      data: <String, Object?>{
        'isTransportPlaying': isTransportPlaying,
        'withinSelfFocusGrace': withinSelfFocusGrace,
      },
    );
    if (shouldPauseForBecomingNoisy(
      isTransportPlaying: isTransportPlaying,
      withinSelfFocusGrace: withinSelfFocusGrace,
    )) {
      unawaited(_playbackService?.pause());
    }
  }

  void dispose() {
    _notificationFeedbackGeneration++;
    _notificationFailure.value = null;
    _interruptionPause = null;
    if (DesktopMediaSessionService.isSupportedPlatform) {
      DesktopMediaSessionService.instance.dispose();
    }
    _playbackService?.setMediaNotificationVisible(false);
    _scheduledSyncTimer?.cancel();
    _scheduledSyncTimer = null;
    _scheduledSubtitleBoundaryTimer?.cancel();
    _scheduledSubtitleBoundaryTimer = null;
    _settingsService.removeListener(_handleSettingsChanged);
    _playbackService?.removeListener(_onPlaybackServiceChanged);
    _playbackService?.coarsePositionNotifier.removeListener(
      _onPlaybackPositionChanged,
    );
    _playlistManager?.removeListener(_onPlaylistChanged);
    _playbackService = null;
    _playlistManager = null;
    _audioFocusHeld = null;
    _deniedAudioFocusIntent = null;
    _exclusiveFocusGrantedAt = null;
    unawaited(_syncAudioFocusWithPlayback(desiredPlaying: false));
    unawaited(_interruptionSubscription?.cancel());
    _interruptionSubscription = null;
    unawaited(_becomingNoisySubscription?.cancel());
    _becomingNoisySubscription = null;
  }

  void _bindPlaybackService(MediaPlaybackService playbackService) {
    if (identical(_playbackService, playbackService)) {
      return;
    }
    _notificationFailure.value = null;
    _playbackService?.removeListener(_onPlaybackServiceChanged);
    _playbackService?.coarsePositionNotifier.removeListener(
      _onPlaybackPositionChanged,
    );
    _interruptionPause = null;
    _playbackService = playbackService;
    _playbackService?.addListener(_onPlaybackServiceChanged);
    _playbackService?.coarsePositionNotifier.addListener(
      _onPlaybackPositionChanged,
    );
  }

  void _onPlaybackPositionChanged() => _onPlaybackServiceChanged();

  void _bindPlaylistManager(PlaylistManager playlistManager) {
    if (identical(_playlistManager, playlistManager)) {
      return;
    }
    _playlistManager?.removeListener(_onPlaylistChanged);
    _playlistManager = playlistManager;
    _playlistManager?.addListener(_onPlaylistChanged);
  }

  void _onPlaybackServiceChanged() {
    _clearOutdatedNotificationFailure();
    if (!_initialized || _handler == null) {
      return;
    }
    final snapshot = _buildSnapshot();
    unawaited(
      _syncAudioFocusWithPlayback(desiredPlaying: snapshot.desiredPlaying),
    );
    final shouldPublishImmediately = _shouldPublishImmediately(snapshot);
    if (shouldPublishImmediately) {
      _logMediaSessionEvent(
        'playback snapshot changed immediately',
        data: <String, Object?>{
          'itemId': snapshot.itemId,
          'state': snapshot.state.name,
          'positionMs': snapshot.position.inMilliseconds,
          'queueIndex': snapshot.queueIndex,
        },
      );
    }
    _schedulePublish(immediate: shouldPublishImmediately, snapshot: snapshot);
  }

  void _onPlaylistChanged() {
    if (!_initialized || _handler == null) {
      return;
    }
    _logMediaSessionEvent(
      'playlist changed',
      data: <String, Object?>{
        'queueLength': _playlistManager?.playlist.length,
        'queueIndex': _playlistManager?.playbackIndex,
      },
    );
    _publishQueue();
    final snapshot = _buildSnapshot();
    _schedulePublish(immediate: true, snapshot: snapshot);
  }

  void _schedulePublish({
    required bool immediate,
    required _PlaybackSnapshot snapshot,
  }) {
    if (immediate) {
      _scheduledSyncTimer?.cancel();
      _scheduledSyncTimer = null;
      unawaited(_publishSnapshot(snapshot: snapshot));
      return;
    }
    if (_scheduledSyncTimer != null) {
      return;
    }
    final elapsed = DateTime.now().difference(_lastPublishedAt);
    final wait = elapsed >= _progressSyncThrottle
        ? Duration.zero
        : (_progressSyncThrottle - elapsed);
    _scheduledSyncTimer = Timer(wait, () {
      _scheduledSyncTimer = null;
      _logMediaSessionEvent(
        'throttled publish triggered',
        data: <String, Object?>{'waitMs': wait.inMilliseconds},
      );
      unawaited(_publishSnapshot());
    });
  }

  bool _shouldPublishImmediately(_PlaybackSnapshot snapshot) {
    final previous = _lastSnapshot;
    if (previous == null) {
      return true;
    }
    if (previous.itemId != snapshot.itemId ||
        previous.state != snapshot.state ||
        previous.desiredPlaying != snapshot.desiredPlaying ||
        previous.queueIndex != snapshot.queueIndex ||
        previous.title != snapshot.title ||
        previous.subtitle != snapshot.subtitle ||
        previous.duration != snapshot.duration) {
      return true;
    }
    final int positionDelta =
        (snapshot.position.inMilliseconds - previous.position.inMilliseconds)
            .abs();
    final int bufferedDelta =
        (snapshot.bufferedPosition.inMilliseconds -
                previous.bufferedPosition.inMilliseconds)
            .abs();
    return positionDelta >= _seekJumpThreshold.inMilliseconds ||
        bufferedDelta >= _seekJumpThreshold.inMilliseconds;
  }

  Future<void> _publishSnapshot({
    _PlaybackSnapshot? snapshot,
    bool force = false,
  }) async {
    _clearOutdatedNotificationFailure();
    if (!_initialized || _handler == null) {
      return;
    }

    final int capturedEpoch = _notificationEpoch;
    final SystemMediaNotificationCommit decision =
        resolveSystemMediaNotificationCommit(
          epoch: _notificationEpoch,
          capturedEpoch: capturedEpoch,
          enabled: _settingsService.showSystemMediaNotification,
          suppressedEpoch: _suppressedEpoch,
          suppressQueuedEpoch: _suppressQueuedEpoch,
          headsetControlsEnabled: headsetControlsEnabled,
        );
    if (decision == SystemMediaNotificationCommit.drop) {
      return;
    }
    if (decision == SystemMediaNotificationCommit.suppress) {
      _suppressQueuedEpoch = capturedEpoch;
      await _commitSession(
        () => _suppressSystemMediaNotification(capturedEpoch),
      );
      return;
    }

    final resolvedSnapshot = snapshot ?? _buildSnapshot();
    if (!force && resolvedSnapshot == _lastSnapshot) {
      return;
    }
    final previous = _lastSnapshot;
    final int publishRevision = ++_publishRevision;
    _logMediaSessionEvent(
      'publishing playback state',
      data: <String, Object?>{
        'itemId': resolvedSnapshot.itemId,
        'state': resolvedSnapshot.state.name,
        'positionMs': resolvedSnapshot.position.inMilliseconds,
        'durationMs': resolvedSnapshot.duration.inMilliseconds,
        'subtitle': resolvedSnapshot.subtitle,
        'force': force,
      },
    );

    audio_service.MediaItem? mediaItem;
    if (force || _shouldRefreshMediaItem(previous, resolvedSnapshot)) {
      mediaItem = await _buildCurrentMediaItem(resolvedSnapshot);
    } else if (_lastPublishedMediaItem == null &&
        resolvedSnapshot.itemId != null) {
      mediaItem = await _buildCurrentMediaItem(resolvedSnapshot);
    }
    if (publishRevision != _publishRevision ||
        capturedEpoch != _notificationEpoch) {
      _logMediaSessionEvent(
        'stale publish skipped',
        data: <String, Object?>{
          'itemId': resolvedSnapshot.itemId,
          'revision': publishRevision,
          'latestRevision': _publishRevision,
        },
      );
      return;
    }
    final bool concealNotification =
        decision == SystemMediaNotificationCommit.publishConcealed;
    await _commitSession(() async {
      if (publishRevision != _publishRevision ||
          capturedEpoch != _notificationEpoch) {
        return;
      }
      final bool showNotification =
          _settingsService.showSystemMediaNotification;
      if (!showNotification && !headsetControlsEnabled) {
        return;
      }
      // audio_service only creates the foreground notification on a
      // not-playing → playing transition. Arm that transition once when the
      // user turns the notification back on; doing it on every update would
      // flash the shade.
      if (showNotification &&
          _needsNotificationRearm &&
          _notificationRearmAttemptEpoch != capturedEpoch) {
        // Reserve before awaiting: newer position samples may supersede this
        // metadata, but must not turn a slow failure into another native try.
        _notificationRearmAttemptEpoch = capturedEpoch;
        final armed = await _observeNotificationVisibility(
          capturedEpoch,
          visible: true,
          operation: SystemMediaNotificationGate.armShow,
        );
        if (armed &&
            capturedEpoch == _notificationEpoch &&
            _settingsService.showSystemMediaNotification) {
          // Native success applies to this visibility intent even if a newer
          // position now owns metadata. A newer hide/show epoch owns itself.
          _needsNotificationRearm = false;
          _notificationRearmAttemptEpoch = -1;
        }
        if (publishRevision != _publishRevision ||
            capturedEpoch != _notificationEpoch ||
            !_settingsService.showSystemMediaNotification) {
          return;
        }
        // Do not rewrite the reservation on failure. An explicit refresh may
        // have cleared it while this call waited; that retry must survive.
      }
      if (!showNotification && concealNotification) {
        await _observeNotificationVisibility(
          capturedEpoch,
          visible: false,
          operation: SystemMediaNotificationGate.holdPlaying,
          clearOnSuccess: false,
        );
        if (publishRevision != _publishRevision ||
            capturedEpoch != _notificationEpoch) {
          return;
        }
      }
      _emitPlaybackPublication(
        resolvedSnapshot,
        mediaItem,
        showSystemNotification: showNotification && !_needsNotificationRearm,
      );
      if (!showNotification && concealNotification) {
        final bool hidden = await _observeNotificationVisibility(
          capturedEpoch,
          visible: false,
          operation: SystemMediaNotificationGate.conceal,
        );
        _playbackService?.setMediaNotificationVisible(false);
        if (hidden) {
          _nativeNotificationSuppressed = true;
        }
        _logMediaSessionEvent(
          'system media notification concealed',
          data: <String, Object?>{
            'hidden': hidden,
            'playing': resolvedSnapshot.desiredPlaying,
          },
        );
      }
    });
  }

  void _emitPlaybackPublication(
    _PlaybackSnapshot resolvedSnapshot,
    audio_service.MediaItem? mediaItem, {
    bool showSystemNotification = true,
  }) {
    final bool nudge = shouldNudgeSystemMediaNotification(
      isIOS: !kIsWeb && Platform.isIOS,
      nativeSuppressed: _nativeNotificationSuppressed,
      hasMedia: resolvedSnapshot.itemId != null,
    );
    if (showSystemNotification) {
      _nativeNotificationSuppressed = false;
    }
    // Only a publication that survived asynchronous metadata/artwork work may
    // supersede an in-flight paused-session notification prime. Incrementing
    // earlier would let a failed/stale publication strand the forced state.
    _notificationVisibilityPrimeRevision++;
    _playbackService?.setMediaNotificationVisible(
      showSystemNotification &&
          isSupportedPlatform &&
          resolvedSnapshot.itemId != null &&
          resolvedSnapshot.state != PlaybackState.idle,
    );
    _lastSnapshot = resolvedSnapshot;
    _lastPublishedAt = DateTime.now();
    if (!showSystemNotification || resolvedSnapshot.itemId == null) {
      _lastVisibleNotificationItemId = null;
    } else if (resolvedSnapshot.isPlaying) {
      _lastVisibleNotificationItemId = resolvedSnapshot.itemId;
    }
    if (mediaItem != null) {
      _lastPublishedMediaItem = mediaItem;
      _handler!.mediaItem.add(mediaItem);
    }
    if (nudge) {
      _handler!.playbackState.add(
        _buildPlaybackState(
          resolvedSnapshot,
          positionOverride: nudgedSystemMediaNotificationPosition(
            resolvedSnapshot.position,
          ),
        ),
      );
    }
    _handler!.playbackState.add(_buildPlaybackState(resolvedSnapshot));
    _scheduleSubtitleBoundaryPublish(resolvedSnapshot);
  }

  void _publishQueue() {
    if (!_initialized || _handler == null || _isPublishingQueue) {
      return;
    }
    _isPublishingQueue = true;
    try {
      _playlistManager?.refreshQueueEligibility();
      final mediaItems = _buildQueueMediaItems();
      _handler!.queue.add(mediaItems);
      _logMediaSessionEvent(
        'queue published',
        data: <String, Object?>{
          'queueLength': mediaItems.length,
          'currentIndex': _playlistManager?.playbackIndex,
          'queueRevision': _playlistManager?.revision,
        },
      );
    } finally {
      _isPublishingQueue = false;
    }
  }

  @visibleForTesting
  List<String> buildQueueItemIdsForTesting({PlaylistManager? playlistManager}) {
    if (playlistManager != null) {
      return playlistManager.playbackQueue.map((item) => item.id).toList();
    }
    return _buildQueueMediaItems().map((item) => item.id).toList();
  }

  Future<void> refreshNow({bool ensureNotificationVisible = false}) async {
    if (DesktopMediaSessionService.isSupportedPlatform) {
      await DesktopMediaSessionService.instance.refreshNow();
      return;
    }
    if (!_initialized || _handler == null) {
      return;
    }
    _retryNotificationVisibility();
    final snapshot = _buildSnapshot();
    _logMediaSessionEvent(
      'manual refresh requested',
      data: <String, Object?>{
        'itemId': _playbackService?.currentItem?.id,
        'ensureNotificationVisible': ensureNotificationVisible,
      },
    );
    _publishQueue();
    await _publishSnapshot(snapshot: snapshot, force: true);
    if (ensureNotificationVisible) {
      await _ensureAndroidNotificationVisible(snapshot);
    }
  }

  void _retryNotificationVisibility() {
    // Foreground/lifecycle and explicit refreshes may recover a transient
    // channel failure. Ordinary publication and position updates do not.
    if (_needsNotificationRearm) _notificationRearmAttemptEpoch = -1;
  }

  Future<void> _ensureAndroidNotificationVisible(
    _PlaybackSnapshot snapshot, {
    int? epoch,
  }) async {
    if (!SystemMediaNotificationGate._isAndroid || _handler == null) {
      return;
    }
    if (epoch != null && epoch != _notificationEpoch) {
      return;
    }
    if (!_settingsService.showSystemMediaNotification) {
      return;
    }
    if (_needsNotificationRearm) return;
    if (snapshot.itemId == null ||
        snapshot.state == PlaybackState.idle ||
        snapshot.isPlaying ||
        _lastVisibleNotificationItemId == snapshot.itemId) {
      return;
    }
    final int primeRevision = ++_notificationVisibilityPrimeRevision;
    _logMediaSessionEvent(
      'priming paused notification visibility',
      data: <String, Object?>{
        'itemId': snapshot.itemId,
        'state': snapshot.state.name,
      },
    );
    // audio_service creates Android's foreground media notification only on a
    // non-playing -> playing transition. Prime a restored paused session once,
    // then immediately publish its truthful paused state. This is the same
    // lifecycle used by the stable pre-streaming implementation.
    _handler!.playbackState.add(
      _buildPlaybackState(snapshot, forcePlaying: true),
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (primeRevision != _notificationVisibilityPrimeRevision) {
      return;
    }
    if (epoch != null && epoch != _notificationEpoch) {
      return;
    }
    if (!_settingsService.showSystemMediaNotification) {
      return;
    }
    if (_needsNotificationRearm) return;
    final currentSnapshot = _buildSnapshot();
    if (currentSnapshot.itemId != snapshot.itemId ||
        currentSnapshot.state == PlaybackState.idle) {
      return;
    }
    _handler!.playbackState.add(_buildPlaybackState(currentSnapshot));
    _lastVisibleNotificationItemId = currentSnapshot.itemId;
  }

  bool _shouldRefreshMediaItem(
    _PlaybackSnapshot? previous,
    _PlaybackSnapshot current,
  ) {
    if (previous == null) {
      return true;
    }
    return previous.itemId != current.itemId ||
        previous.title != current.title ||
        previous.subtitle != current.subtitle ||
        previous.duration != current.duration;
  }

  _PlaybackSnapshot _buildSnapshot({
    Duration? positionOverride,
    Duration? bufferedPositionOverride,
  }) {
    final playbackService = _playbackService;
    final playlistManager = _playlistManager;
    final currentItem = playbackService?.currentItem;
    final currentIndex = playlistManager?.playbackIndex;
    final resolvedPosition =
        positionOverride ??
        _resolveLivePosition(playbackService) ??
        playbackService?.position ??
        Duration.zero;
    final resolvedBufferedPosition =
        bufferedPositionOverride ??
        _resolveLiveBufferedPosition(playbackService) ??
        playbackService?.bufferedPosition ??
        Duration.zero;
    final resolvedSubtitle = _resolveCurrentSubtitleText(
      playbackService: playbackService,
      position: resolvedPosition,
    );
    return _PlaybackSnapshot(
      itemId: currentItem?.id,
      title: currentItem?.title,
      subtitle: resolvedSubtitle,
      state: playbackService?.state ?? PlaybackState.idle,
      position: resolvedPosition,
      duration: playbackService?.duration ?? Duration.zero,
      bufferedPosition: resolvedBufferedPosition,
      queueIndex: currentIndex != null && currentIndex >= 0
          ? currentIndex
          : null,
      isPlaying: playbackService?.isPlaying ?? false,
      desiredPlaying: playbackService?.desiredPlaying ?? false,
      hasPrevious: playbackService?.hasPlayablePrevious ?? false,
      hasNext: playbackService?.hasPlayableNext ?? false,
      speed: _resolvePlaybackSpeed(playbackService?.controller),
    );
  }

  List<audio_service.MediaItem> _buildQueueMediaItems() {
    final playbackService = _playbackService;
    final playlist = _playlistManager?.playbackQueue ?? const <VideoItem>[];
    final queueRevision = _playlistManager?.revision ?? 0;
    final currentSubtitleText = _resolveCurrentSubtitleText(
      playbackService: playbackService,
    );
    return playlist
        .toList(growable: false)
        .asMap()
        .entries
        .map((entry) {
          final queueIndex = entry.key;
          final item = entry.value;
          final secondaryText = _resolveSecondaryText(
            playbackService: playbackService,
            item: item,
            currentSubtitleText: currentSubtitleText,
          );
          return audio_service.MediaItem(
            id: item.id,
            title: item.title,
            album: item.type == MediaType.audio ? '音频' : '视频',
            artist: secondaryText,
            duration:
                item.id == playbackService?.currentItem?.id &&
                    playbackService != null &&
                    playbackService.duration > Duration.zero
                ? playbackService.duration
                : _durationFromItem(item),
            displayTitle: item.title,
            displaySubtitle: secondaryText,
            displayDescription: secondaryText,
            extras: <String, Object?>{
              'queueRevision': queueRevision,
              'queueIndex': queueIndex,
            },
          );
        })
        .toList(growable: false);
  }

  Future<audio_service.MediaItem?> _buildCurrentMediaItem(
    _PlaybackSnapshot snapshot,
  ) async {
    final playbackService = _playbackService;
    final item = playbackService?.currentItem;
    if (item == null) {
      return null;
    }

    final currentSubtitleText = snapshot.subtitle;
    final secondaryText = currentSubtitleText?.isNotEmpty == true
        ? currentSubtitleText!
        : (item.type == MediaType.audio ? '音频' : '视频');

    return audio_service.MediaItem(
      id: item.id,
      title: item.title,
      album: item.type == MediaType.audio ? '音频' : '视频',
      artist: secondaryText,
      duration: playbackService!.duration > Duration.zero
          ? playbackService.duration
          : _durationFromItem(item),
      artUri: await _resolveArtworkUri(item),
      displayTitle: item.title,
      displaySubtitle: secondaryText,
      displayDescription: secondaryText,
      extras: <String, dynamic>{
        'mediaType': item.type.name,
        // ignore: use_null_aware_elements
        if (currentSubtitleText case final subtitleText?)
          'currentSubtitle': subtitleText,
      },
    );
  }

  audio_service.PlaybackState _buildPlaybackState(
    _PlaybackSnapshot snapshot, {
    bool forcePlaying = false,
    Duration? positionOverride,
  }) {
    final bool remoteControlsEnabled = headsetControlsEnabled;
    // The session intent is the single source of truth for the notification
    // play/pause button. Transient signals — state==loading during a switch, a
    // late controller sample, a seek transition — must never flip it. The
    // button changes only when the actual play/pause intent changes, which
    // keeps it stable across background episode switches.
    final bool effectivePlaying = forcePlaying || snapshot.desiredPlaying;
    final layout = buildSystemMediaControlLayout(
      enabled: remoteControlsEnabled,
      hasMedia: snapshot.itemId != null,
      playing: effectivePlaying,
      canStepWithinMedia: _canStepWithinMedia(snapshot),
      isIOS: !kIsWeb && Platform.isIOS,
    );

    return audio_service.PlaybackState(
      controls: layout.controls,
      systemActions: remoteControlsEnabled && snapshot.duration > Duration.zero
          ? const <audio_service.MediaAction>{audio_service.MediaAction.seek}
          : const <audio_service.MediaAction>{},
      androidCompactActionIndices: layout.androidCompactActionIndices,
      processingState: _mapProcessingState(snapshot.state),
      playing: effectivePlaying,
      updatePosition: positionOverride ?? snapshot.position,
      bufferedPosition: snapshot.bufferedPosition,
      speed: snapshot.speed,
      queueIndex: snapshot.queueIndex,
    );
  }

  bool _canStepWithinMedia(_PlaybackSnapshot snapshot) {
    return snapshot.itemId != null && snapshot.duration > Duration.zero;
  }

  audio_service.AudioProcessingState _mapProcessingState(PlaybackState state) {
    switch (state) {
      case PlaybackState.idle:
        return audio_service.AudioProcessingState.idle;
      case PlaybackState.loading:
        return audio_service.AudioProcessingState.loading;
      case PlaybackState.playing:
        return audio_service.AudioProcessingState.ready;
      case PlaybackState.paused:
        return audio_service.AudioProcessingState.ready;
      case PlaybackState.error:
        return audio_service.AudioProcessingState.error;
    }
  }

  Duration? _durationFromItem(VideoItem item) {
    if (item.durationMs <= 0) {
      return null;
    }
    return Duration(milliseconds: item.durationMs);
  }

  double _resolvePlaybackSpeed(VideoPlayerControllerLike? controller) {
    if (controller == null) {
      return 1.0;
    }
    try {
      return controller.playbackSpeed;
    } catch (_) {
      return 1.0;
    }
  }

  String? _resolveSubtitle(SubtitleItem? subtitle) {
    if (subtitle == null) {
      return null;
    }
    final text = subtitle.text.trim();
    if (text.isEmpty) {
      return null;
    }
    return text;
  }

  String _resolveSecondaryText({
    required MediaPlaybackService? playbackService,
    required VideoItem item,
    String? currentSubtitleText,
  }) {
    final bool isCurrentItem = playbackService?.currentItem?.id == item.id;
    if (isCurrentItem) {
      final currentSubtitle =
          currentSubtitleText ??
          _resolveCurrentSubtitleText(playbackService: playbackService);
      if (currentSubtitle != null && currentSubtitle.isNotEmpty) {
        return currentSubtitle;
      }
    }
    return item.type == MediaType.audio ? '音频' : '视频';
  }

  Duration? _resolveLivePosition(MediaPlaybackService? playbackService) {
    // MediaPlaybackService is the single source of truth. In particular, a
    // network controller can expose its byte-zero probe while an initial seek
    // is still being committed; reading the raw controller here would publish
    // (and later restore) that transient zero position.
    return playbackService?.position;
  }

  Duration? _resolveLiveBufferedPosition(
    MediaPlaybackService? playbackService,
  ) {
    final controller = playbackService?.controller;
    if (controller == null) {
      return null;
    }
    try {
      final value = controller.value;
      if (!value.isInitialized) {
        return null;
      }
      final buffered = value.buffered;
      if (buffered.isEmpty) {
        return null;
      }
      return buffered.last.end;
    } catch (_) {
      return null;
    }
  }

  String? _resolveCurrentSubtitleText({
    required MediaPlaybackService? playbackService,
    Duration? position,
  }) {
    final subtitles = playbackService?.subtitles ?? const <SubtitleItem>[];
    if (subtitles.isEmpty) {
      return _resolveSubtitle(playbackService?.currentSubtitle);
    }
    final resolvedPosition =
        position ??
        _resolveLivePosition(playbackService) ??
        playbackService?.position ??
        Duration.zero;
    // The playback service already indexes this immutable/streaming snapshot.
    // Rebuilding it here copied and traversed the entire transcript on every
    // position sample, including while the screen was off.
    final subtitle = playbackService?.subtitleAtPosition(resolvedPosition);
    return _resolveSubtitle(subtitle) ??
        _resolveSubtitle(playbackService?.currentSubtitle);
  }

  @visibleForTesting
  String? resolveSubtitleTextForTesting({
    required MediaPlaybackService playbackService,
    required Duration position,
  }) => _resolveCurrentSubtitleText(
    playbackService: playbackService,
    position: position,
  );

  void _scheduleSubtitleBoundaryPublish(_PlaybackSnapshot snapshot) {
    _scheduledSubtitleBoundaryTimer?.cancel();
    _scheduledSubtitleBoundaryTimer = null;

    if (!_initialized || _handler == null || !snapshot.isPlaying) {
      return;
    }

    final playbackService = _playbackService;
    final subtitles = playbackService?.subtitles ?? const <SubtitleItem>[];
    if (snapshot.itemId == null || subtitles.isEmpty) {
      return;
    }

    final livePosition =
        _resolveLivePosition(playbackService) ?? snapshot.position;
    final nextBoundary = playbackService?.nextSubtitleBoundaryAfter(
      livePosition,
    );
    if (nextBoundary == null) {
      return;
    }

    final wait = calculateSubtitleBoundaryDelay(
      position: livePosition,
      boundary: nextBoundary,
      playbackSpeed: snapshot.speed,
      padding: _subtitleBoundarySyncPadding,
      minimumDelay: _minimumSubtitleBoundaryDelay,
    );

    _scheduledSubtitleBoundaryTimer = Timer(wait, () {
      _scheduledSubtitleBoundaryTimer = null;
      if (!_initialized || _handler == null) {
        return;
      }
      final liveSnapshot = _buildSnapshot();
      if (liveSnapshot.itemId != snapshot.itemId || !liveSnapshot.isPlaying) {
        _scheduleSubtitleBoundaryPublish(liveSnapshot);
        return;
      }
      final controller = _playbackService?.controller;
      final bool clockAdvancing;
      try {
        clockAdvancing =
            controller != null &&
            controller.value.isInitialized &&
            controller.value.isPlaying &&
            !controller.value.isBuffering;
      } catch (_) {
        _scheduleSubtitleBoundaryPublish(liveSnapshot);
        return;
      }
      if (!clockAdvancing) {
        _scheduleSubtitleBoundaryPublish(liveSnapshot);
        return;
      }
      // Background controller samples arrive every ~900 ms. At the exact
      // subtitle timer callback that shared sample may still point just before
      // the boundary, so publish against the boundary we deliberately reached
      // rather than waiting for the next coarse sample.
      final boundarySnapshot = liveSnapshot.position < nextBoundary
          ? _buildSnapshot(positionOverride: nextBoundary)
          : liveSnapshot;
      _logMediaSessionEvent(
        'subtitle boundary publish triggered',
        data: <String, Object?>{
          'itemId': boundarySnapshot.itemId,
          'positionMs': boundarySnapshot.position.inMilliseconds,
          'subtitle': boundarySnapshot.subtitle,
        },
      );
      unawaited(_publishSnapshot(snapshot: boundarySnapshot));
    });
  }

  Future<Uri?> _resolveArtworkUri(VideoItem item) async {
    final cacheKey = '${item.id}|${item.type.name}|${item.thumbnailPath ?? ''}';
    if (_artworkCacheValid && _artworkCacheKey == cacheKey) {
      return _artworkCacheValue;
    }

    // Audio thumbnails contain the album artwork extracted by LibraryService.
    // They are just as suitable for system media metadata as video thumbnails,
    // so only fall back to the generated music-note image when no thumbnail is
    // available for either media type.
    Uri? resolvedUri = await resolveExistingMediaArtworkUri(item);

    if (resolvedUri == null) {
      final placeholderPath = await _ensureAudioPlaceholderArtworkPath();
      resolvedUri = placeholderPath == null ? null : File(placeholderPath).uri;
    }

    _artworkCacheKey = cacheKey;
    _artworkCacheValue = resolvedUri;
    _artworkCacheValid = true;
    return _artworkCacheValue;
  }

  Future<String?> _ensureAudioPlaceholderArtworkPath() async {
    if (_audioPlaceholderArtworkPath != null) {
      final existingFile = File(_audioPlaceholderArtworkPath!);
      if (await existingFile.exists()) {
        return _audioPlaceholderArtworkPath;
      }
    }

    try {
      final directory = await getTemporaryDirectory();
      final file = File(
        '${directory.path}${Platform.pathSeparator}media_audio_placeholder.png',
      );
      if (!await file.exists()) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        const size = Size(512, 512);
        final paint = Paint()
          ..color = const Color(0xFF1E1E1E)
          ..style = PaintingStyle.fill;
        final rect = RRect.fromRectAndRadius(
          Offset.zero & size,
          const Radius.circular(96),
        );
        canvas.drawRRect(rect, paint);

        final glowPaint = Paint()
          ..color = const Color(0xFF4F7BF5).withValues(alpha: 0.22)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 48);
        canvas.drawCircle(
          Offset(size.width / 2, size.height / 2),
          160,
          glowPaint,
        );

        final textPainter = TextPainter(
          text: TextSpan(
            text: String.fromCharCode(Icons.music_note.codePoint),
            style: TextStyle(
              fontSize: 220,
              color: Colors.white,
              fontFamily: Icons.music_note.fontFamily,
              package: Icons.music_note.fontPackage,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final offset = Offset(
          (size.width - textPainter.width) / 2,
          (size.height - textPainter.height) / 2,
        );
        textPainter.paint(canvas, offset);

        final image = await recorder.endRecording().toImage(
          size.width.toInt(),
          size.height.toInt(),
        );
        final pngBytes = await image.toByteData(format: ui.ImageByteFormat.png);
        if (pngBytes == null) {
          return null;
        }
        await file.writeAsBytes(pngBytes.buffer.asUint8List(), flush: true);
      }

      _audioPlaceholderArtworkPath = file.path;
      return _audioPlaceholderArtworkPath;
    } catch (_) {
      return null;
    }
  }
}

class _AudioInterruptionPause {
  const _AudioInterruptionPause(
    this.playback,
    this.itemId,
    this.generation,
    this.pauseRevision,
  );
  final MediaPlaybackService playback;
  final String itemId;
  final int generation;
  final int pauseRevision;

  bool matches(MediaPlaybackService current) =>
      identical(current, playback) &&
      current.currentItem?.id == itemId &&
      current.session.generation == generation &&
      current.pauseIntentRevision == pauseRevision;
}

@visibleForTesting
audio_service.BaseAudioHandler createSystemMediaHandlerForTesting({
  required MediaPlaybackService playbackService,
  required PlaylistManager playlistManager,
  SystemMediaSessionService? session,
}) => _SystemMediaAudioHandler(session: session)
  ..attach(playbackService: playbackService, playlistManager: playlistManager);

class _SystemMediaAudioHandler extends audio_service.BaseAudioHandler
    with audio_service.QueueHandler, audio_service.SeekHandler {
  _SystemMediaAudioHandler({SystemMediaSessionService? session})
    : _sessionService = session ?? SystemMediaSessionService.instance;

  final SystemMediaSessionService _sessionService;
  MediaPlaybackService? _playbackService;
  PlaylistManager? _playlistManager;
  Future<void> _remoteCommandBarrier = Future<void>.value();
  bool _episodeSkipInFlight = false;
  DateTime? _lastHeadsetPlayPauseAt;

  Future<void> _runSerialized(Future<void> Function() command) {
    final operation = _remoteCommandBarrier.then((_) => command());
    _remoteCommandBarrier = operation.catchError((
      Object error,
      StackTrace stack,
    ) {
      _sessionService._logMediaSessionEvent(
        'remote command failed',
        data: <String, Object?>{'error': error.toString()},
      );
    });
    return operation;
  }

  bool _shouldHandleRemoteCommand(String command) {
    final enabled = _sessionService.headsetControlsEnabled;
    if (!enabled) {
      _sessionService._logMediaSessionEvent(
        'remote command ignored',
        data: <String, Object?>{'command': command, 'reason': 'disabled'},
      );
    }
    return enabled;
  }

  void attach({
    required MediaPlaybackService playbackService,
    required PlaylistManager playlistManager,
  }) {
    _playbackService = playbackService;
    _playlistManager = playlistManager;
  }

  @override
  Future<void> play() async {
    if (!_shouldHandleRemoteCommand('play')) return;
    _sessionService._logMediaSessionEvent(
      'remote play command received',
      data: <String, Object?>{'itemId': _playbackService?.currentItem?.id},
    );
    // Do not queue transport intent behind a slow episode switch. The playback
    // service records this intent immediately and reconciles the new controller
    // before committing it, so the notification remains responsive while the
    // target source is loading.
    await _playbackService?.resume();
  }

  @override
  Future<void> click([
    audio_service.MediaButton button = audio_service.MediaButton.media,
  ]) async {
    if (button != audio_service.MediaButton.media) {
      await super.click(button);
      return;
    }
    if (!_shouldHandleRemoteCommand('click')) return;
    final HeadsetPlayPauseResolution resolution = resolveHeadsetPlayPause(
      transportPlaying: _playbackService?.isTransportPlaying ?? false,
      lastAcceptedAt: _lastHeadsetPlayPauseAt,
      now: DateTime.now(),
    );
    if (resolution == HeadsetPlayPauseResolution.ignore) {
      _sessionService._logMediaSessionEvent(
        'remote play/pause ignored as duplicate headset click',
        data: <String, Object?>{'itemId': _playbackService?.currentItem?.id},
      );
      return;
    }
    _lastHeadsetPlayPauseAt = DateTime.now();
    if (resolution == HeadsetPlayPauseResolution.pause) {
      await pause();
      return;
    }
    await play();
  }

  @override
  Future<void> pause() async {
    if (!_shouldHandleRemoteCommand('pause')) return;
    final session = _sessionService;
    // MediaSession pause is a transport command, including notification and
    // headset controls. A timing window cannot prove it is a focus artifact.
    // Only actual AudioSession focus callbacks use the self-focus grace rule.
    session._logMediaSessionEvent(
      'remote pause command received',
      data: <String, Object?>{'itemId': _playbackService?.currentItem?.id},
    );
    await _playbackService?.pause();
  }

  @override
  Future<void> stop() async {
    if (!_shouldHandleRemoteCommand('stop')) return;
    _sessionService._logMediaSessionEvent('remote stop command received');
    // Stop must cancel an in-flight open, not wait behind its deadline.
    await _playbackService?.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    if (!_shouldHandleRemoteCommand('seek')) return;
    _sessionService._logMediaSessionEvent(
      'remote seek command received',
      data: <String, Object?>{
        'targetMs': position.inMilliseconds,
        'itemId': _playbackService?.currentItem?.id,
      },
    );
    await _playbackService?.seekTo(position, source: 'system_media');
  }

  @override
  Future<void> rewind() async {
    if (!_shouldHandleRemoteCommand('rewind')) return;
    await _handleConfiguredStepDirection(isBackward: true);
  }

  @override
  Future<void> fastForward() async {
    if (!_shouldHandleRemoteCommand('fastForward')) return;
    await _handleConfiguredStepDirection(isBackward: false);
  }

  @override
  Future<void> skipToNext() async {
    if (!_shouldHandleRemoteCommand('skipToNext')) return;
    _sessionService._logMediaSessionEvent(
      'remote next command received',
      data: <String, Object?>{'itemId': _playbackService?.currentItem?.id},
    );
    await _handleSingleEpisodeSkip(isNext: true);
  }

  @override
  Future<void> skipToPrevious() async {
    if (!_shouldHandleRemoteCommand('skipToPrevious')) return;
    _sessionService._logMediaSessionEvent(
      'remote previous command received',
      data: <String, Object?>{'itemId': _playbackService?.currentItem?.id},
    );
    await _handleSingleEpisodeSkip(isNext: false);
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (!_shouldHandleRemoteCommand('skipToQueueItem')) return;
    final playlistManager = _playlistManager;
    final playbackService = _playbackService;
    if (playlistManager == null || playbackService == null) {
      return;
    }
    final playlist = playlistManager.playbackQueue;
    if (index < 0 || index >= playlist.length) {
      return;
    }
    _sessionService._logMediaSessionEvent(
      'remote queue item command received',
      data: <String, Object?>{'index': index, 'itemId': playlist[index].id},
    );
    await playbackService.playPlaylistItem(playlist[index]);
  }

  @override
  Future<void> playMediaItem(audio_service.MediaItem mediaItem) async {
    if (!_shouldHandleRemoteCommand('playMediaItem')) return;
    final playlistManager = _playlistManager;
    final playbackService = _playbackService;
    if (playlistManager == null || playbackService == null) {
      return;
    }
    final index = playlistManager.indexOfItem(mediaItem.id);
    if (index < 0) {
      return;
    }
    _sessionService._logMediaSessionEvent(
      'remote media item command received',
      data: <String, Object?>{'index': index, 'itemId': mediaItem.id},
    );
    await playbackService.playPlaylistItem(playlistManager.playlist[index]);
  }

  Future<void> _handleConfiguredStepDirection({
    required bool isBackward,
  }) async {
    final playbackService = _playbackService;
    if (playbackService == null) {
      return;
    }
    final settings = SettingsService();
    final bool useSubtitleStep =
        settings.enableDoubleTapSubtitleSeek &&
        playbackService.subtitles.isNotEmpty;
    final direction = isBackward ? 'backward' : 'forward';
    _sessionService._logMediaSessionEvent(
      'remote step command received',
      data: <String, Object?>{
        'direction': direction,
        'mode': useSubtitleStep ? 'subtitle' : 'seconds',
        'seconds': settings.doubleTapSeekSeconds,
        'itemId': playbackService.currentItem?.id,
      },
    );
    playbackService.handleExternalDoubleTapSeek(
      isLeft: isBackward,
      doubleTapSeekSeconds: settings.doubleTapSeekSeconds,
      enableDoubleTapSubtitleSeek: useSubtitleStep,
      subtitleOffset: settings.subtitleOffset,
      source: 'system_media',
    );
  }

  Future<void> _handleSingleEpisodeSkip({required bool isNext}) async {
    // Do not queue repeated MediaSession callbacks behind a slow Android
    // decoder switch. Some devices resend the hardware/notification action;
    // replaying those callbacks after the first load completes looks like an
    // endless previous/next loop. The old stable handler acknowledged only
    // the command currently being handled.
    if (_episodeSkipInFlight) {
      _sessionService._logMediaSessionEvent(
        'remote episode command ignored while switch is active',
        data: <String, Object?>{'direction': isNext ? 'next' : 'previous'},
      );
      return;
    }
    _episodeSkipInFlight = true;
    try {
      await _runSerialized(() => _handleQueueSkip(isNext: isNext));
    } finally {
      _episodeSkipInFlight = false;
    }
  }

  Future<void> _handleQueueSkip({required bool isNext}) async {
    final playbackService = _playbackService;
    if (playbackService == null) {
      return;
    }
    if (isNext) {
      await playbackService.playNext();
    } else {
      await playbackService.playPrevious();
    }
  }
}

class _PlaybackSnapshot {
  const _PlaybackSnapshot({
    required this.itemId,
    required this.title,
    required this.subtitle,
    required this.state,
    required this.position,
    required this.duration,
    required this.bufferedPosition,
    required this.queueIndex,
    required this.isPlaying,
    this.desiredPlaying = false,
    required this.hasPrevious,
    required this.hasNext,
    required this.speed,
  });

  final String? itemId;
  final String? title;
  final String? subtitle;
  final PlaybackState state;
  final Duration position;
  final Duration duration;
  final Duration bufferedPosition;
  final int? queueIndex;
  final bool isPlaying;

  /// The session's play intent. While a notification-triggered episode switch
  /// is still loading, the notification must keep showing the pause button
  /// (standard buffering semantics) instead of flickering to play/paused.
  final bool desiredPlaying;
  final bool hasPrevious;
  final bool hasNext;
  final double speed;

  @override
  bool operator ==(Object other) {
    return other is _PlaybackSnapshot &&
        other.itemId == itemId &&
        other.title == title &&
        other.subtitle == subtitle &&
        other.state == state &&
        other.position == position &&
        other.duration == duration &&
        other.bufferedPosition == bufferedPosition &&
        other.queueIndex == queueIndex &&
        other.isPlaying == isPlaying &&
        other.desiredPlaying == desiredPlaying &&
        other.hasPrevious == hasPrevious &&
        other.hasNext == hasNext &&
        (other.speed - speed).abs() < 0.001;
  }

  @override
  int get hashCode => Object.hash(
    itemId,
    title,
    subtitle,
    state,
    position,
    duration,
    bufferedPosition,
    queueIndex,
    isPlaying,
    desiredPlaying,
    hasPrevious,
    hasNext,
    speed.toStringAsFixed(3),
  );
}

typedef VideoPlayerControllerLike = dynamic;
