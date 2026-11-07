import 'dart:async';
import 'community_media_input.dart';
import '../features/model_center/inference_resource_governor.dart';
import '../models/subtitle_stream.dart';
import 'subtitle_stream_source.dart';
import '../debug/build_identity.dart';
import '../debug/developer_log.dart' as developer;
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/platform/app_video_player_controller.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart'
    show VideoPlayerPlatform;
import '../models/video_item.dart';
import '../models/media_source_ref.dart';
import '../features/podcasts/podcast_playback_hooks.dart';
import '../features/podcasts/podcast_playback_policy.dart';
import '../features/cloud_drive/models/cloud_drive_models.dart';
import '../features/cloud_drive/models/cloud_drive_quality_order.dart';
import '../features/cloud_drive/providers/cloud_drive_http.dart';
import '../features/cloud_drive/services/cloud_drive_playback_service.dart';
import '../features/cloud_drive/services/cloud_drive_playback_budget.dart';
import '../features/cloud_drive/services/cloud_drive_runtime.dart';
import '../features/cloud_drive/services/cloud_drive_subtitle_tracks.dart';
import '../features/cloud_drive/services/cloud_drive_quality_outcome.dart';
import '../features/cloud_drive/services/cloud_drive_quality_switch.dart';
import '../features/media_cache/media_cache_hooks.dart';
import '../features/cloud_drive/services/cloud_drive_session_recovery.dart';
import '../features/cloud_drive/services/cloud_drive_startup.dart';
import '../features/cloud_drive/services/cloud_drive_stream_gateway.dart';
import '../models/managed_subtitle_asset.dart';
import '../models/playback_session.dart';
import '../models/subtitle_model.dart';
import '../platform/windows_video_player_media_kit.dart';
import '../platform/local_playback_backend_policy.dart';
import 'playlist_manager.dart';
import '../models/playback_mode.dart';
import 'playback_queue_policy.dart';
import 'progress_tracker.dart';
import 'app_wakelock_coordinator.dart';
import 'audio_playback_compatibility_service.dart';
import 'danmaku_presentation_position.dart';
import 'listener_aware_value_notifier.dart';
import 'playback_timeline_clock.dart';
import 'playback_behavior_policy.dart';
import 'library_watch_meter.dart';
import 'sleep_timer_controller.dart';
import '../services/embedded_subtitle_service.dart';
import '../services/library_service.dart';
import '../services/media_materialization_service.dart';
import '../services/settings_service.dart';
import '../services/bilibili/bilibili_streaming_service.dart';
import 'bilibili/bilibili_startup.dart';
import 'network/network_http.dart';
import '../services/task_subtitle_storage_service.dart';
import '../services/subtitle_timeline_resolver.dart';
import '../services/subtitle_discovery_service.dart';
import '../services/subtitle_hop_seek_policy.dart';
import '../utils/linux_audio_device.dart';
import '../utils/pgs_parser.dart';
import '../utils/subtitle_converter.dart';
import '../utils/subtitle_parser.dart';
import 'subtitle_word_timing_store.dart';
import '../utils/youtube_auto_caption_normalizer.dart';

// Runtime projection only: preserve the library's historical provenance while
// preventing it from selecting a remote transport for an actual local file.
VideoItem _communityPlaybackItem(VideoItem item) {
  requireCommunityPlaybackSource(item.path, source: item.sourceRef);
  if (communityMediaIsPodcast(item.path, source: item.sourceRef)) return item;
  final path = communityLocalMediaPath(item.path);
  final previousPlaybackPath = item.playbackPath;
  final playbackPath =
      previousPlaybackPath != null &&
          communityMediaIsLocal(previousPlaybackPath)
      ? communityLocalMediaPath(previousPlaybackPath)
      : null;
  if (item.sourceRef == null &&
      path == item.path &&
      playbackPath == previousPlaybackPath) {
    return item;
  }
  return VideoItem.fromJson({
    ...item.toJson(),
    'path': path,
    'playbackPath': playbackPath,
    'sourceRef': null,
  });
}

List<Map<String, Object?>> _parseTextSubtitlesToSerializable(
  Map<String, Object?> input,
) {
  final content = SubtitleParser.decodeBytes(
    input['bytes'] as List<int>,
    sourcePath: input['path'] as String,
  );
  var parsed = SubtitleParser.parse(
    content,
    sourcePath: input['path'] as String,
    mediaDuration:
        input['durationMs'] is int && (input['durationMs'] as int) > 0
        ? Duration(milliseconds: input['durationMs'] as int)
        : null,
  );
  if (input['companion'] is String) {
    parsed = SubtitleWordTimingStore.decode(
      content,
      input['companion'] as String,
      parsed,
    );
  }
  final result = <Map<String, Object?>>[];
  for (final item in parsed) {
    result.add(<String, Object?>{...item.toTimingJson()});
  }
  return result;
}

class _EpisodeNavigationCommand {
  const _EpisodeNavigationCommand({
    required this.delta,
    required this.autoPlay,
    required this.directEpoch,
  });

  final int delta;
  final bool autoPlay;

  /// Direct episode taps increment this. Relative skips queued before that
  /// tap are dropped so they cannot play instead of the tapped episode.
  final int directEpoch;
}

class _DirectSwitchSuperseded implements Exception {
  const _DirectSwitchSuperseded();
}

/// Restores only the playback session suspended by a temporary video preview.
/// Calling restore more than once joins the same restoration.
class PlaybackPreviewSuspension {
  PlaybackPreviewSuspension._(this._restore);

  final Future<void> Function() _restore;
  Future<void>? _restoration;

  Future<void> restore() => _restoration ??= _restore();
}

class _PlaybackCompletion {
  const _PlaybackCompletion({
    required this.item,
    required this.controller,
    required this.playRequestId,
    required this.seekRequestId,
    required this.directEpoch,
  });

  final VideoItem item;
  final VideoPlayerController controller;
  final int playRequestId;
  final int seekRequestId;
  final int directEpoch;
}

/// Result of [_awaitPlaybackReadiness].
///
/// `degraded` means the media was positioned correctly but the transport could
/// not be confirmed as actually running (background clock never started, or a
/// foreground decoder produced no frame). The session is then parked as paused
/// at the seek target instead of being torn down and retried, so the episode
/// switch itself stays successful and recoverable.
enum _PlaybackReadinessResult { confirmed, degraded }

class _StreamQualityHandoffInterrupted implements Exception {
  const _StreamQualityHandoffInterrupted();
}

/// One in-flight automatic official-subtitle request for one account/file/
/// revision scope. Every entry point subscribes to this instead of starting a
/// second directory and body download.
class _AutoSubtitleFlight {
  _AutoSubtitleFlight(this.scope, this.future);

  final String scope;
  final Future<CloudDriveAutoSubtitleOutcome> future;
}

class _PlaybackTransportCommands {
  _PlaybackTransportCommands(this.controller, this.generation);
  final VideoPlayerController controller;
  final int generation;
  Future<void> tail = Future<void>.value();
  int revision = 0;
  int settledRevision = 0;
  Duration? awaitingNativePosition;

  /// Accepted play/pause commands that have not finished the native call and
  /// its position sample. The clock watch that follows a resume is excluded,
  /// so the next tap does not wait for that confirmation.
  int pendingNative = 0;
}

/// 播放状态枚举
enum PlaybackState {
  idle, // 空闲状态
  loading, // 加载中
  playing, // 播放中
  paused, // 暂停
  error, // 错误
}

/// Mini playback chrome only needs item metadata (thumbnail, title, duration,
/// saved progress). Waiting for [PlaybackState.playing]/[PlaybackState.paused]
/// hides it for the entire Bilibili playurl/initialize window on launch.
///
/// [enabled] is the media-library switch. Off hides the card immediately and
/// does not stop playback.
bool isMiniPlaybackCardVisible({
  required VideoItem? currentItem,
  required PlaybackState state,
  bool enabled = true,
}) {
  if (!enabled || currentItem == null) return false;
  switch (state) {
    case PlaybackState.playing:
    case PlaybackState.paused:
    case PlaybackState.loading:
    case PlaybackState.error:
      return true;
    case PlaybackState.idle:
      return false;
  }
}

/// Detects a possible split-stream clock reset after a track toggle or CDN
/// reconnect. Cached samples require fresh transport confirmation before seek.
bool shouldResyncBilibiliClockFromZero({
  required bool isOnlineBilibiliStream,
  required Duration expectedPosition,
  required Duration nativeSample,
  required DateTime now,
  DateTime? lastResyncAt,
  bool hopSeekInFlight = false,
  String? lastSeekSource,
  DateTime? lastHopSeekAt,
  Duration duration = Duration.zero,
}) {
  if (!isOnlineBilibiliStream) return false;
  if (SubtitleHopSeekPolicy.shouldSuppressZeroClockResync(
    hopSeekInFlight: hopSeekInFlight,
    lastSeekSource: lastSeekSource,
    now: now,
    lastHopSeekAt: lastHopSeekAt,
  )) {
    return false;
  }
  // EOS on split fMP4 often reports t=0. Seeking that sample back to the
  // last clock would loop the last GOP and never fire auto-play-next.
  if (PlaybackBehaviorPolicy.hasReachedPlaybackEnd(
    position: expectedPosition,
    duration: duration,
  )) {
    return false;
  }
  if (expectedPosition < const Duration(seconds: 2)) return false;
  if (nativeSample > const Duration(milliseconds: 500)) return false;
  if (expectedPosition - nativeSample < const Duration(seconds: 2)) {
    return false;
  }
  if (lastResyncAt != null &&
      now.difference(lastResyncAt) < const Duration(seconds: 2)) {
    return false;
  }
  return true;
}

/// Fresh t=0 starts are already there. A non-zero resume cannot trust the
/// Dart sample: `start=` is wiped when the video track is selected after open.
bool shouldSkipRedundantInitialSeek({
  required Duration target,
  required Duration actual,
  int toleranceMs = 450,
}) {
  if (target.inMilliseconds > toleranceMs) return false;
  return actual.inMilliseconds.abs() <= toleranceMs;
}

/// 媒体播放服务 - 管理全局播放状态
class MediaPlaybackService extends ChangeNotifier {
  static const String _globalMutePrefsKey = 'globalMute';

  // 单例模式
  static final MediaPlaybackService _instance =
      MediaPlaybackService._internal();
  factory MediaPlaybackService() => _instance;
  MediaPlaybackService._internal({MonotonicMicroseconds? nowMicroseconds})
    : _timelineClock = PlaybackTimelineClock(nowMicroseconds: nowMicroseconds) {
    InferencePlaybackActivity.playing = () => isTransportPlaying;
  }
  @visibleForTesting
  MediaPlaybackService.forTesting({MonotonicMicroseconds? nowMicroseconds})
    : this._internal(nowMicroseconds: nowMicroseconds);

  // 依赖服务
  PlaylistManager? _playlistManager;
  ProgressTracker? _progressTracker;
  LibraryService? _libraryService;
  EmbeddedSubtitleService? _embeddedSubtitleService;
  BilibiliStreamingService? _bilibiliStreamingService;
  CloudDrivePlaybackService? _cloudDrivePlayback;
  CloudDrivePlaybackLease? _currentCloudDriveLease;
  VoidCallback? _detachCloudLease;
  CloudDrivePlaybackLease? _cloudReopenInFlight;
  List<CloudDriveQualityChoice> _cloudDriveQualities = const [];
  String? _selectedCloudDriveQualityId;
  String? cloudDriveNotice;
  CloudDriveFailureKind? cloudDriveFailureKind;
  String? cloudDriveSubtitleStatus;
  final CloudDriveQualitySwitch _cloudDriveQualitySwitch =
      CloudDriveQualitySwitch();
  bool get cloudDriveQualitySwitching => _cloudDriveQualitySwitch.switching;
  String? get cloudDriveDiagnosticReport => cloudDriveDiagnosticSummary;
  Future<List<VideoItem>> Function()? cloudDriveLoadNextPlaylistPage;
  Future<void> Function()? cloudDrivePreparePlaylist;
  bool Function()? cloudDriveQueueNeedsCompletion;
  bool get _cloudQueuePending =>
      _currentItem?.sourceRef?.cloudDrive != null &&
      (cloudDriveQueueNeedsCompletion?.call() ?? false);

  Future<bool> _prepareCloudQueue() async {
    if (!_cloudQueuePending) return true;
    final requestId = _playRequestId;
    final directEpoch = _directEpoch;
    final owner = _playlistManager?.queueOwner;
    try {
      await cloudDrivePreparePlaylist?.call();
      return !_cloudQueuePending;
    } catch (_) {
      if (requestId == _playRequestId &&
          directEpoch == _directEpoch &&
          identical(owner, _playlistManager?.queueOwner)) {
        cloudDriveNotice = '目录读取未完成，请重试上一集或下一集';
        notifyListeners();
      }
      return false;
    }
  }

  final Set<Object> _playbackPageOwners = <Object>{};
  final Set<Object> _miniPlaybackCardOwners = <Object>{};

  /// While an auxiliary surface is showing video — the landscape music cover
  /// or the floating player inside the fullscreen AI chat — playback pages
  /// must not also mount a [Video] for this controller. media_kit keeps a
  /// single output view; a second one steals the texture.
  ///
  /// Exactly one claimant is allowed. The last claim wins, and the previous
  /// holder is expected to notice via [notifyListeners] and drop its own view
  /// (the music cover snaps back to its artwork).
  Object? _videoSurfaceClaimant;
  bool _musicCoverRequestsBilibiliVideo = false;

  bool get videoSurfaceClaimed => _videoSurfaceClaimant != null;

  bool ownsVideoSurface(Object owner) =>
      identical(_videoSurfaceClaimant, owner);

  /// Pages ask whether *anything* borrowed the output, not just the cover.
  bool get musicCoverOwnsVideoSurface => videoSurfaceClaimed;
  bool _mediaNotificationVisible = false;
  final SleepTimerController sleepTimer = SleepTimerController();

  // 播放状态
  PlaybackState _state = PlaybackState.idle;
  VideoItem? _currentItem;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _bufferedPosition = Duration.zero;
  bool _isMuted = false;
  double _volume = 1.0;
  double _playbackSpeed = 1.0;
  VideoPlayerController? _controller;
  // The native controller can outlive a currentItem change during entry.
  // Keep its media identity until that controller is actually replaced.
  String? _controllerItemId;
  bool _serviceOwnsController = false;
  bool _isSourceMissing = false;
  List<BilibiliStreamQuality> _streamQualities = const [];
  BilibiliStreamQuality? _selectedStreamQuality;
  List<BilibiliAudioQuality> _streamAudioQualities = const [];
  BilibiliAudioQuality? _selectedStreamAudioQuality;
  double? _streamDisplayAspectRatio;
  String? _streamDisplayAspectRatioItemId;
  bool _isSwitchingStreamQuality = false;
  BilibiliPreparedPlayback? _currentBilibiliPlayback;
  MaterializedMediaLease? _currentMaterializedPlaybackLease;
  int _streamQualitySwitchRequestId = 0;

  /// Mini/notification opened the loopback audio URL instead of video+audio.
  bool _bilibiliAudioPrimaryPlayer = false;
  Future<bool>? _visibleVideoOutputRecovery;
  PlaybackStartupContext? _activeOpenBudget;
  final Expando<Future<void>> _controllerReleases = Expando<Future<void>>();
  PlaybackStartupContext? _visibleOutputOperation;
  VideoPlayerController? _visibleOutputController;
  int? _visibleOutputSession;
  VoidCallback? _detachOutputState;
  VoidCallback? _detachNativeHealth;
  Timer? _nativeHealthTimer;
  final Expando<bool> _nativeHealthReopened = Expando<bool>();
  VideoPlayerController? _nativeHealthChecking;
  @visibleForTesting
  Duration debugRecoveryLimit = const Duration(seconds: 30);
  @visibleForTesting
  Duration debugOutputAttachLimit = const Duration(seconds: 8);
  bool? _requestedBilibiliVideoTrackEnabled;
  int _bilibiliVideoTrackPolicyRevision = 0;
  Future<void>? _bilibiliVideoTrackPolicyFuture;
  bool _coveringUntilVisibleVideoFrame = false;
  double _bilibiliGatewayBytesPerSecond = 0;
  bool _bilibiliStreamingListenerAttached = false;
  bool _controllerIsBuffering = false;

  /// Seek's Dart Future can complete while libmpv is still cache-paused.
  /// Keep the Bilibili spinner up until the clock actually moves again.
  bool _seekHoldOverlay = false;

  /// True from the native seek until the clock ticks, including the delay
  /// before the spinner is allowed to appear.
  bool _seekHoldPending = false;
  Timer? _seekHoldOverlayTimer;

  /// Native sample used as the post-seek baseline. Overlay clears only after
  /// this clock ticks — `isPlaying && !isBuffering` is not enough.
  Duration? _seekHoldLandedNative;
  int _visibleVideoFrameEpoch = 0;

  // 字幕相关
  List<SubtitleItem> _subtitles = [];
  List<SubtitleItem> _secondarySubtitles = [];
  List<String> _subtitlePaths = [];
  int _subtitleRevision = 0;
  bool _subtitleWasAppend = false;
  bool get subtitleWasAppend => _subtitleWasAppend;
  SubtitleStreamSource? _subtitleStreamManager;
  StreamSubscription<SubtitleStreamUpdate>? _subtitleStreamSubscription;
  StreamSubscription<SubtitleGenerationStart>? _subtitleStartSubscription;
  final Map<String, int> _streamSelectionIntents = {};
  final Map<String, int> _streamManualIntents = {};
  final Map<String, String> _streamRunIds = {};
  final Set<String> _activatedStreams = {};
  Timer? _subtitleAppendTimer;
  SubtitleStreamUpdate? _pendingSubtitleAppend;
  bool Function(String)? _streamSelectionPolicy;
  Future<void> _streamSelectionWrites = Future<void>.value();
  @visibleForTesting
  Future<void> get subtitleSelectionSavedForTest => _streamSelectionWrites;

  void bindSubtitleStreams(SubtitleStreamSource manager) {
    if (identical(manager, _subtitleStreamManager)) return;
    if (identical(
      _subtitleStreamManager?.shouldSelectGeneratedSubtitles,
      _streamSelectionPolicy,
    )) {
      _subtitleStreamManager?.shouldSelectGeneratedSubtitles = null;
    }
    unawaited(_subtitleStreamSubscription?.cancel());
    unawaited(_subtitleStartSubscription?.cancel());
    _subtitleStreamManager = manager;
    _streamSelectionPolicy = (key) {
      final stream = manager.subtitleStreams
          .where((state) => state.mediaKey == key)
          .firstOrNull;
      final item = _currentItem;
      if (stream == null ||
          item == null ||
          (item.id != stream.videoId && item.path != stream.videoPath)) {
        return !manager.subtitleSelectionOverridden(key);
      }
      return listEquals(_subtitlePaths, stream.paths) ||
          (!manager.subtitleSelectionOverridden(key) &&
              (_streamSelectionIntents[key] ??
                      _streamManualIntents[key] ??
                      0) ==
                  (_streamManualIntents[key] ?? 0));
    };
    manager.shouldSelectGeneratedSubtitles = _streamSelectionPolicy;
    _subtitleStartSubscription = manager.subtitleGenerationStarts.listen((
      start,
    ) {
      if (_streamRunIds[start.mediaKey] == start.runId) return;
      _streamRunIds[start.mediaKey] = start.runId;
      _streamSelectionIntents[start.mediaKey] =
          _streamManualIntents[start.mediaKey] ?? 0;
    });
    _subtitleStreamSubscription = manager.subtitleUpdates.listen(
      _queueSubtitleAppend,
    );
  }

  void _queueSubtitleAppend(SubtitleStreamUpdate update) {
    final item = _currentItem;
    if (item == null ||
        (item.id != update.videoId && item.path != update.videoPath)) {
      return;
    }
    // An unselected OCR region must not replace a pending update for the
    // selected primary/secondary pair in the shared coalescing timer.
    if (update.autoSelectSuppressed &&
        !_subtitlePaths.any(update.paths.contains)) {
      return;
    }
    _pendingSubtitleAppend = update;
    if (update.phase != SubtitleStreamPhase.generating) {
      _subtitleAppendTimer?.cancel();
      _subtitleAppendTimer = null;
      _applySubtitleAppend();
    } else {
      _subtitleAppendTimer ??= Timer(const Duration(milliseconds: 250), () {
        _subtitleAppendTimer = null;
        _applySubtitleAppend();
      });
    }
  }

  void _applySubtitleAppend() {
    final update = _pendingSubtitleAppend;
    _pendingSubtitleAppend = null;
    final item = _currentItem;
    if (update == null ||
        item == null ||
        (update.primary.isEmpty && update.secondary.isEmpty) ||
        (item.id != update.videoId && item.path != update.videoPath)) {
      return;
    }
    final selected = _subtitlePaths.any(update.paths.contains);
    final mayActivate =
        !update.autoSelectSuppressed &&
        !(_subtitleStreamManager?.subtitleSelectionOverridden(
              update.mediaKey,
            ) ??
            false) &&
        (_streamSelectionIntents[update.mediaKey] ??
                _streamManualIntents[update.mediaKey] ??
                0) ==
            (_streamManualIntents[update.mediaKey] ?? 0);
    final activate =
        !selected &&
        !_activatedStreams.contains(update.generationId) &&
        mayActivate;
    final attachTranslation =
        update.primaryComplete &&
        update.secondary.isNotEmpty &&
        mayActivate &&
        _subtitlePaths.firstOrNull == update.primaryPath &&
        (_subtitlePaths.length < 2 ||
            _subtitlePaths[1] != update.secondaryPath);
    if (!selected && !activate) return;
    List<SubtitleItem> forPath(String path, List<SubtitleItem> previous) =>
        path == update.primaryPath
        ? update.primary
        : path == update.secondaryPath
        ? update.secondary
        : previous;
    final paths = activate || attachTranslation
        ? (update.primaryComplete && update.secondary.isEmpty
              ? [
                  update.primaryPath,
                  if (_subtitlePaths.length > 1) _subtitlePaths[1],
                ]
              : update.paths)
        : _subtitlePaths;
    final primary = forPath(paths.first, _subtitles);
    final secondary = paths.length > 1
        ? forPath(paths[1], _secondarySubtitles)
        : const <SubtitleItem>[];
    if (isSubtitleAppend(_subtitles, primary) &&
        primary.length == _subtitles.length &&
        (identical(secondary, _secondarySubtitles) ||
            isSubtitleAppend(_secondarySubtitles, secondary) &&
                secondary.length == _secondarySubtitles.length)) {
      return;
    }
    if (identical(_subtitles, primary) &&
        identical(_secondarySubtitles, secondary)) {
      return;
    }
    final append =
        (identical(_subtitles, primary) ||
            isSubtitleAppend(_subtitles, primary)) &&
        (identical(_secondarySubtitles, secondary) ||
            attachTranslation ||
            _secondarySubtitles.isEmpty && secondary is SubtitleCueSnapshot ||
            isSubtitleAppend(_secondarySubtitles, secondary));
    _activatedStreams.add(update.generationId);
    _subtitleLoadRequestId++;
    _isLoadingSubtitles = false;
    _subtitles = primary;
    _secondarySubtitles = secondary;
    _subtitlePaths = List<String>.unmodifiable(paths);
    _subtitleRevision++;
    _subtitleWasAppend = append;
    if (append) {
      _subtitleTimeline.append(primary);
    } else {
      _subtitleTimeline = SubtitleTimelineResolver(primary);
    }
    _updateCurrentSubtitle();
    item.subtitlePath = paths.first;
    item.secondarySubtitlePath = paths.length > 1 ? paths[1] : null;
    if (activate || attachTranslation) {
      final intent = _subtitleIntentGeneration;
      final write = _libraryService?.updateVideoSubtitles(
        item.id,
        paths.first,
        update.autoCache,
        secondarySubtitlePath: item.secondarySubtitlePath,
        isSecondaryCached: update.autoCache,
        shouldApply: () =>
            _subtitleIntentGeneration == intent && _currentItem?.id == item.id,
      );
      if (write != null) {
        _streamSelectionWrites = Future.wait([_streamSelectionWrites, write])
            .then<void>(
              (_) {},
              onError: (Object error, StackTrace stack) {
                debugPrint('生成字幕选择保存失败：$error');
              },
            );
      }
    }
    notifyListeners();
  }

  SubtitleItem? _currentSubtitle;
  int _lastSubtitleIndex = 0;
  SubtitleTimelineResolver _subtitleTimeline = SubtitleTimelineResolver(
    const <SubtitleItem>[],
  );
  final Map<String, List<SubtitleItem>> _subtitleCache = {};
  final Map<String, Future<List<SubtitleItem>>> _subtitleParses = {};
  int _subtitleLoadRequestId = 0;
  bool _isLoadingSubtitles = false;

  /// Bumped only by an explicit selection (player UI, subtitle sheet, clear).
  /// A layout refresh or a second playback page must not invalidate the single
  /// automatic official-subtitle task.
  int _subtitleIntentGeneration = 0;

  /// Last automatic official-subtitle attempt. `idle` means "not tried".
  CloudDriveAutoSubtitleOutcome cloudDriveSubtitleAutoOutcome =
      const CloudDriveAutoSubtitleOutcome.idle();
  _AutoSubtitleFlight? _autoSubtitleFlight;

  // 进度追踪定时器
  Timer? _progressTimer;

  // 进度更新定时器（用于实时UI更新）
  Timer? _positionUpdateTimer;
  Timer? _backgroundMediaSyncTimer;

  // 每帧更新的单一媒体时间轴，同时驱动进度 UI 和字幕。
  late final _positionNotifier = ListenerAwareValueNotifier<Duration>(
    Duration.zero,
    onListenersChanged: _onPresentationListenersChanged,
  );
  ValueNotifier<Duration> get positionNotifier => _positionNotifier;

  late final DanmakuPresentationPosition _danmakuPosition =
      DanmakuPresentationPosition(
        onListenersChanged: _onPresentationListenersChanged,
      );

  /// Shares frame time while keeping native transport calibration out of
  /// visible comment positions at the pause/resume boundary.
  ValueListenable<Duration> get danmakuPosition => _danmakuPosition;

  /// Low-frequency position updates for small progress-only widgets.
  final ValueNotifier<Duration> coarsePositionNotifier =
      ValueNotifier<Duration>(Duration.zero);

  /// 每帧只读取同一时钟；普通原生位置采样不会反向修正它。
  Ticker? _interpolationTicker;
  final PlaybackTimelineClock _timelineClock;
  bool _presentationDisposed = false;
  _PlaybackTransportCommands? _transportCommands;
  StreamSubscription<Duration>? _nativePositionSubscription;
  StreamSubscription<double>? _nativeRateSubscription;
  int? _nativePositionPlayerId;
  double? _nativePresentationPlaybackSpeed;
  int _playbackSpeedRequestId = 0;
  double? _pendingPlaybackSpeed;
  double _confirmedPlaybackSpeed = 1.0;
  double _lastDispatchedPlaybackSpeed = 1.0;
  double? _temporaryPlaybackBaseSpeed;
  Future<void> _playbackSpeedCommandTail = Future<void>.value();

  Timer? _seekPersistTimer;
  Timer? _seekVerificationTimer;
  Timer? _hopSeekDispatchTimer;
  Duration? _pendingHopSeekPosition;
  String? _pendingHopSeekSource;
  int _seekRequestId = 0;
  int? _pendingSeekRequestId;
  bool _preservePlayingStateAfterSeek = false;
  bool _initialPositionSeekInFlight = false;
  Duration? _initialPositionGuardTarget;
  DateTime? _initialPositionGuardUntil;
  BilibiliStartupContext? _bilibiliStartup;
  PlaybackStartupContext? _onlineStartup;
  Future<void>? _onlinePlayInFlight;
  String? _onlinePlayItemId;
  int? _onlinePlayEpoch;
  ({String itemId, PlaybackStartupContext context})? _pendingOnlineStartup;
  String? _bilibiliStartupItemId;
  BilibiliStartupContext? _bilibiliVisibleStartup;
  ({String itemId, BilibiliStartupContext context})? _pendingBilibiliStartup;

  BilibiliStartupContext? get bilibiliStartup =>
      _bilibiliStartupItemId == _currentItem?.id
      ? _bilibiliVisibleStartup ?? _bilibiliStartup
      : null;

  PlaybackStartupContext? get onlineStartup =>
      _currentItem == null ? null : _bilibiliVisibleStartup ?? _onlineStartup;

  Future<void> retryOnlineStartup() async {
    final item = _currentItem;
    final opening = onlineStartup;
    if (item == null || opening == null || !opening.hasFailed) return;
    if (item.sourceRef?.kind == MediaSourceKind.bilibiliStream) {
      await retryBilibiliStartup();
      return;
    }
    await play(
      item,
      startPosition: _position,
      autoPlay: opening.desiredPlaying,
      forceRecreate: true,
      cloudDriveQualityId: _selectedCloudDriveQualityId,
    );
  }

  @visibleForTesting
  Future<void> Function(VideoPlayerController, BilibiliStartupContext)?
  debugBilibiliFrameReadiness;

  @visibleForTesting
  Future<void> Function(VideoPlayerController, PlaybackStartupContext, bool)?
  debugOnlineStartupReadiness;

  @visibleForTesting
  Future<void> Function(VideoPlayerController, PlaybackStartupContext)?
  debugOnlineStartupClock;

  @visibleForTesting
  PlaybackStartupContext? get onlineStartupForTesting => _onlineStartup;

  bool _isOnlineMedia(VideoItem item) => !communityMediaIsLocal(item.path);

  Future<MaterializedMediaLease?> _acquireBilibiliPlaybackFile(
    VideoItem item, {
    int? qualityId,
  }) {
    final library = _libraryService;
    final requested = qualityId == null ? null : '$qualityId';
    if (library != null) {
      return library.acquireExistingMaterializedPlayback(
        item,
        qualityId: requested,
      );
    }
    // The cache runtime can be ready before library attachment. Its sealed
    // media is playable without a Bilibili API response in that interval too.
    return MediaCacheHooks.acquire?.call(item, qualityId: requested) ??
        Future<MaterializedMediaLease?>.value(null);
  }

  bool get _usesBilibiliGateway =>
      _currentItem?.sourceRef?.kind == MediaSourceKind.bilibiliStream &&
      _currentBilibiliPlayback != null &&
      _currentMaterializedPlaybackLease == null;

  /// Hand the tap's cover and remaining budget to play() without persisting
  /// presentation state in a media-library item.
  void prepareBilibiliStartup(String itemId, BilibiliStartupContext context) {
    if (canMountControllerFor(itemId) && _bilibiliStartup?.isPending != true) {
      context.ready();
      return;
    }
    _pendingBilibiliStartup?.context.cancel();
    _pendingBilibiliStartup = (itemId: itemId, context: context);
  }

  Future<void> retryBilibiliStartup() async {
    final item = _currentItem;
    final startup = bilibiliStartup;
    if (item == null || startup?.hasFailed != true) return;
    await play(
      item,
      startPosition: _position,
      autoPlay: startup!.desiredPlaying,
      forceRecreate: true,
      bilibiliQualityId: startup.qualityId,
    );
  }

  DateTime? _bilibiliZeroResyncAt;
  Object? _bilibiliZeroClockCheck;
  DateTime? _lastHopSeekAt;
  bool? _lastControllerIsPlaying;
  Timer? _externalSeekResetTimer;
  int _externalSubtitleSeekAccumulator = 0;
  Duration? _externalInitialSeekPosition;
  bool _isAppInForeground = true;
  AppLifecycleState? _lastAppLifecycleState;
  String _lastSeekSource = 'none';
  Duration? _lastRequestedSeekPosition;
  DateTime? _lastSeekRequestedAt;
  _PlaybackCompletion? _playbackCompletion;
  bool _hasPlaybackCompleted = false;
  int _playRequestId = 0;

  /// Incremented when the user directly picks an episode, stops, or leaves.
  /// An in-flight switch captured an older value and must not commit.
  int _directEpoch = 0;
  Completer<void> _directEpochSignal = Completer<void>();
  VideoItem? _pendingSwitchItem;

  /// The episode the user tapped and that has not finished opening.
  VideoItem? get pendingSwitchItem => _pendingSwitchItem;

  void _supersedeDirectSwitch() {
    _onlineStartup?.cancel();
    _playlistManager?.cancelPreparedNavigation();
    _directEpoch++;
    final previous = _directEpochSignal;
    _directEpochSignal = Completer<void>();
    if (!previous.isCompleted) previous.complete();
  }

  /// Lets a newer direct tap proceed without waiting out the previous
  /// initialize timeout. The native call may still finish; its controller is
  /// disposed and must not become the current session.
  Future<T> _raceDirectEpoch<T>(Future<T> work, int epoch) {
    if (epoch != _directEpoch) {
      unawaited(work.then((_) {}, onError: (Object _, StackTrace _) {}));
      return Future<T>.error(const _DirectSwitchSuperseded());
    }
    final signal = _directEpochSignal;
    final completer = Completer<T>();
    work.then(
      (value) {
        if (!completer.isCompleted) completer.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (!completer.isCompleted) completer.completeError(error, stack);
      },
    );
    signal.future.then((_) {
      if (!completer.isCompleted) {
        completer.completeError(const _DirectSwitchSuperseded());
      }
    });
    return completer.future;
  }

  int _sessionGeneration = 0;
  int _controllerGeneration = 0;
  PlaybackSessionSnapshot _session = const PlaybackSessionSnapshot.idle();
  VideoPlayerController? _sessionController;
  int? _activePlayInvocationGeneration;
  final LibraryWatchMeter _watchMeter = LibraryWatchMeter();
  final Map<String, int> _acceptedWatchFlushCycle = <String, int>{};
  bool _watchHistoryStartCommitted = false;
  final List<_EpisodeNavigationCommand> _pendingEpisodeNavigation =
      <_EpisodeNavigationCommand>[];
  bool _isDrainingEpisodeNavigation = false;
  Completer<void>? _episodeNavigationCompleter;
  Future<void>? _controllerErrorRecovery;

  // ===== 预加载下一个视频控制器 =====
  /// 预加载的控制器引用（后台 initialize，paused 状态）
  VideoPlayerController? _preloadedController;

  /// 预加载控制器对应的 item id
  String? _preloadedItemId;

  /// 预加载控制器对应的 playRequestId（防止竞态）
  int _preloadedRequestId = 0;

  /// 是否已触发预加载（避免重复触发）
  bool _preloadTriggered = false;

  /// 预加载进度阈值
  static const double _preloadThreshold = 0.8;

  // ===== 后台 dispose 追踪 =====
  /// 追踪正在后台 dispose 的旧控制器，防止泄漏
  final Set<VideoPlayerController> _disposingControllers =
      <VideoPlayerController>{};

  /// Mobile hardware decoders are a scarce resource. A new controller must
  /// not race the native disposal of the controller it replaces, otherwise
  /// the new player can intermittently fail to acquire a decoder while the
  /// app is backgrounded. Later play requests wait on the same barrier too.
  Future<void> _mobileControllerReleaseBarrier = Future<void>.value();

  /// 后台 dispose 完成后自动移除的 Future 数量上限
  static const int _maxDisposingControllers = 3;

  static const Duration _controllerSeekVerificationDelay = Duration(
    milliseconds: 180,
  );
  static const Duration _controllerSeekVerificationFollowUpDelay = Duration(
    milliseconds: 650,
  );
  static const Duration _controllerSeekTimeout = Duration(seconds: 2);
  static const Duration _controllerInitializeTimeout = Duration(seconds: 20);
  static const Duration _backgroundClockReadyTimeout = Duration(seconds: 4);
  static const Duration _mobileControllerReleaseTimeout = Duration(seconds: 8);
  static const Duration _firstVideoFrameTimeout = Duration(seconds: 12);
  // One retry is enough for genuinely transient switch failures (e.g. a
  // decoder slot still releasing). Readiness degradation keeps clock/frame
  // timeouts out of this loop, so three reopen attempts per skip were pure
  // overhead that left notification-controlled switches stuck on loading.
  static const int _mediaSwitchMaxAttempts = 2;
  static const Duration _playbackCompletionConfirmationDelay = Duration(
    milliseconds: 140,
  );
  static const int _seekVerificationToleranceMs = 450;
  static const Duration _initialPositionGuardDuration = Duration(seconds: 2);
  static const Duration _backgroundMediaSyncInterval = Duration(
    milliseconds: 900,
  );
  static const Duration _streamQualityWarmFrameDelay = Duration(
    milliseconds: 45,
  );
  static const int _streamQualityHandoffToleranceMs = 60;
  static const int _streamQualityMaxAttempts = 2;
  static const Duration _streamQualityWarmupTimeout = Duration(seconds: 8);
  static const Duration _streamQualityPositionReadTimeout = Duration(
    milliseconds: 500,
  );
  static const Duration _streamQualityPhaseLockTimeout = Duration(seconds: 5);
  static const Duration _streamQualityPhaseLockSampleDelay = Duration(
    milliseconds: 32,
  );

  void _logPlaybackEvent(String message, {Map<String, Object?>? data}) {
    if (!kDebugMode) return;
    final buffer = StringBuffer('MediaPlaybackService: $message');
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

  void _syncWakelockWithState() {
    AppWakelockCoordinator.setActive(
      AppWakelockCoordinator.mediaPlaybackReason,
      _state == PlaybackState.playing && _isAppInForeground,
    );
    _syncBilibiliCachePolicy();
  }

  void _syncBilibiliCachePolicy() {
    final streaming = _bilibiliStreamingService;
    if (streaming == null) return;
    final item = _currentItem;
    streaming.updateCachePolicy(
      itemId: item?.id,
      isOnlineItem: item?.sourceRef?.kind == MediaSourceKind.bilibiliStream,
      isPlaying: _state == PlaybackState.playing,
      playbackPageVisible: _isAppInForeground && _playbackPageOwners.isNotEmpty,
      miniPlaybackCardVisible:
          _isAppInForeground && _miniPlaybackCardOwners.isNotEmpty,
      mediaNotificationVisible: _mediaNotificationVisible,
    );
    _syncBilibiliVideoTrackPolicy();
  }

  void _syncBilibiliVideoTrackPolicy() {
    final item = _currentItem;
    final controller = _controller;
    final isActiveOnlineStream =
        !kIsWeb &&
        item?.sourceRef?.kind == MediaSourceKind.bilibiliStream &&
        _currentBilibiliPlayback != null &&
        controller != null &&
        controller.value.isInitialized;
    if (!isActiveOnlineStream) {
      _requestedBilibiliVideoTrackEnabled = null;
      _bilibiliVideoTrackPolicyRevision++;
      return;
    }
    // A platform controller outside this adapter has its own track policy.
    // Treating an unsupported command as a fresh enable repeatedly re-covered
    // a frame which was already ready.
    if (!NativeVideoPlayerMediaKit.managesPlayer(
      // ignore: invalid_use_of_visible_for_testing_member
      controller.playerId,
    )) {
      return;
    }
    // Audio-primary Mini/notification players have no video stream. Enabling
    // the track here cannot produce frames and would race page promotion.
    if (_bilibiliAudioPrimaryPlayer) {
      _requestedBilibiliVideoTrackEnabled = false;
      return;
    }

    // With audio-only enabled, only a visible foreground consumer needs video.
    // Keep the same Player, external audio track and clock everywhere else.
    final shouldEnableVideo = shouldEnableBilibiliVideoTrack(
      hasPlaybackPageOwner: _playbackPageOwners.isNotEmpty,
      backgroundAudioOnly: SettingsService().bilibiliBackgroundAudioOnly,
      coverRequestsVideo: _musicCoverRequestsBilibiliVideo,
      isAppInForeground: _isAppInForeground,
    );
    if (_requestedBilibiliVideoTrackEnabled == shouldEnableVideo) return;
    final enabling =
        shouldEnableVideo && _requestedBilibiliVideoTrackEnabled != true;
    _requestedBilibiliVideoTrackEnabled = shouldEnableVideo;
    final preparedPlayback = _currentBilibiliPlayback;
    if (preparedPlayback != null) {
      _bilibiliStreamingService?.setPlaybackVideoEnabled(
        preparedPlayback,
        shouldEnableVideo,
      );
    }
    final revision = ++_bilibiliVideoTrackPolicyRevision;
    final itemId = item!.id;
    // Re-selecting the video track can briefly report byte-zero while the
    // native decoder seeks back to the audio clock. Keep the service timeline
    // (and therefore subtitles) at the real position during that window.
    if (shouldEnableVideo && _position > Duration.zero) {
      _armInitialPositionGuard(_position);
    }
    if (enabling && _playbackPageOwners.isNotEmpty) {
      _beginCoveringUntilVisibleVideoFrame();
    }
    final command =
        NativeVideoPlayerMediaKit.setExternalVideoTrackEnabledFor(
          // ignore: invalid_use_of_visible_for_testing_member
          controller.playerId,
          enabled: shouldEnableVideo,
          keepPlaying:
              _session.desiredPlaying &&
              (_onlineStartup?.isPending != true || _onlineStartup!.isPrepared),
          keepPaused:
              (_onlineStartup?.isPending == true &&
                  !_onlineStartup!.isPrepared) ||
              !_session.desiredPlaying,
        ).then((applied) async {
          if (revision != _bilibiliVideoTrackPolicyRevision ||
              _currentItem?.id != itemId ||
              !identical(_controller, controller)) {
            return;
          }
          if (!applied) {
            _requestedBilibiliVideoTrackEnabled = null;
            _bilibiliVisibleStartup?.fail(StateError('音视频解码失败，请重试'));
            return;
          }
          if (shouldEnableVideo) {
            final visual = _bilibiliVisibleStartup;
            if (visual?.isPending == true) {
              await _completeBilibiliVisibleFrame(controller, visual!);
            }
            if (revision != _bilibiliVideoTrackPolicyRevision ||
                _currentItem?.id != itemId ||
                !identical(_controller, controller)) {
              return;
            }
            _endCoveringUntilVisibleVideoFrame(immediate: true);
          }
        });
    _bilibiliVideoTrackPolicyFuture = command;
    unawaited(command);
  }

  /// Inactive windows remain visible; hidden/paused apps do not consume video
  /// when background audio-only was explicitly enabled.
  @visibleForTesting
  static bool shouldEnableBilibiliVideoTrack({
    required bool hasPlaybackPageOwner,
    required bool backgroundAudioOnly,
    bool coverRequestsVideo = false,
    bool isAppInForeground = true,
  }) {
    return !backgroundAudioOnly ||
        isAppInForeground && (coverRequestsVideo || hasPlaybackPageOwner);
  }

  /// Mini/notification opens must not drop the video elementary stream unless
  /// background audio-only is on. Keeping video selected means a later page
  /// mount joins the live decoder instead of re-enabling `vid`.
  @visibleForTesting
  static bool shouldDeferBilibiliVideoOnOpen({
    required bool hasVisiblePlaybackPage,
    required bool backgroundAudioOnly,
  }) {
    return backgroundAudioOnly && !hasVisiblePlaybackPage;
  }

  /// A missing Flutter texture must not pause a clock that is already
  /// running. That park is the "this Bilibili card will not start; the next
  /// episode works" failure: first-frame wait times out while audio is live.
  @visibleForTesting
  static bool shouldParkWhenVisibleVideoFrameMissing({
    required bool nativeClockPlaying,
  }) {
    return !nativeClockPlaying;
  }

  bool get isCoveringUntilVisibleVideoFrame => _coveringUntilVisibleVideoFrame;

  void _beginCoveringUntilVisibleVideoFrame() {
    if (_bilibiliStartup?.isPrepared == true &&
        _usesBilibiliGateway &&
        _bilibiliVisibleStartup?.isPending != true) {
      // A live Mini clock keeps running. Only the newly joined picture has a
      // deadline; this context never owns or pauses that audio transport.
      _bilibiliVisibleStartup =
          BilibiliStartupContext(coverUrl: _bilibiliStartup?.coverUrl)
            ..target = _position
            ..geometry.copyFrom(_bilibiliStartup!.geometry)
            ..qualityId = _selectedStreamQuality?.id
            ..desiredPlaying = _session.desiredPlaying;
    }
    _coveringUntilVisibleVideoFrame = true;
    final epoch = ++_visibleVideoFrameEpoch;
    notifyListeners();
    final opening = _bilibiliVisibleStartup ?? _onlineStartup;
    if (opening?.isPending == true || opening?.hasFailed == true) {
      return;
    }
    // Safety: never leave the thumbnail glued on if a frame callback is lost.
    Future<void>.delayed(const Duration(milliseconds: 8000), () {
      if (epoch != _visibleVideoFrameEpoch) return;
      _endCoveringUntilVisibleVideoFrame(immediate: true);
    });
  }

  void _endCoveringUntilVisibleVideoFrame({bool immediate = false}) {
    final opening = _bilibiliVisibleStartup ?? _onlineStartup;
    if (opening?.hasFailed == true ||
        opening?.isPending == true && !opening!.isPrepared) {
      return;
    }
    if (!_coveringUntilVisibleVideoFrame) return;
    if (immediate) {
      _coveringUntilVisibleVideoFrame = false;
      _visibleVideoFrameEpoch++;
      notifyListeners();
      return;
    }
    final epoch = _visibleVideoFrameEpoch;
    Future<void>.delayed(const Duration(milliseconds: 80), () {
      if (epoch != _visibleVideoFrameEpoch) return;
      if (!_coveringUntilVisibleVideoFrame) return;
      _coveringUntilVisibleVideoFrame = false;
      notifyListeners();
    });
  }

  Future<void> _awaitBilibiliVideoTrackPolicy() async {
    _syncBilibiliVideoTrackPolicy();
    final pending = _bilibiliVideoTrackPolicyFuture;
    if (pending != null) {
      final budget = _onlineStartup?.isPending == true
          ? _onlineStartup
          : _visibleOutputOperation;
      await (budget?.run(pending) ?? pending.timeout(debugRecoveryLimit));
    }
  }

  Future<void> _completeBilibiliVisibleFrame(
    VideoPlayerController controller,
    BilibiliStartupContext visual,
  ) async {
    try {
      // The surface may have been released while listening in Mini. Attach
      // it to the same native Player before waiting for its replacement frame.
      // ignore: invalid_use_of_visible_for_testing_member
      final playerId = controller.playerId;
      if (NativeVideoPlayerMediaKit.hasVideoOutputFor(playerId) != true) {
        final attached = await visual.run(
          NativeVideoPlayerMediaKit.attachVideoOutputFor(playerId),
        );
        if (!attached) throw StateError('音视频解码失败，请重试');
      }
      if (!identical(_bilibiliVisibleStartup, visual) ||
          !identical(_controller, controller)) {
        return;
      }
      notifyListeners();
      final frame =
          debugBilibiliFrameReadiness?.call(controller, visual) ??
          NativeVideoPlayerMediaKit.frameAtPositionFor(
            playerId,
            visual,
            target: () => _position,
          );
      if (frame != null) {
        visual.mark(BilibiliStartupPhase.waitingForFrame);
        await visual.run(frame);
        SchedulerBinding.instance.scheduleFrame();
        await visual.run(SchedulerBinding.instance.endOfFrame);
      }
      if (!identical(_bilibiliVisibleStartup, visual) ||
          !identical(_controller, controller)) {
        return;
      }
      visual.ready();
      _endCoveringUntilVisibleVideoFrame(immediate: true);
    } catch (error) {
      if (!identical(_bilibiliVisibleStartup, visual) ||
          !identical(_controller, controller) ||
          visual.isCancelled) {
        return;
      }
      visual.fail(error);
      notifyListeners();
    }
  }

  /// Short hops (arrow keys, sentence skip) usually land inside this window.
  /// Showing a spinner on every keypress is the flash the user called noisy.
  @visibleForTesting
  static const Duration bilibiliSeekHoldOverlayDelay = Duration(
    milliseconds: 350,
  );

  void _armSeekHoldOverlay() {
    _seekHoldPending = true;
    _seekHoldLandedNative = null;
    _seekHoldOverlayTimer?.cancel();
    if (_seekHoldOverlay) {
      // Already visible from a longer stall; keep it until the new target
      // starts moving instead of hiding and flashing it again.
      _seekHoldOverlayTimer = Timer(const Duration(seconds: 15), () {
        _clearSeekHoldOverlay();
      });
      return;
    }
    _seekHoldOverlayTimer = Timer(bilibiliSeekHoldOverlayDelay, () {
      if (!_seekHoldPending || _seekHoldOverlay) return;
      _seekHoldOverlay = true;
      _seekHoldOverlayTimer = Timer(const Duration(seconds: 15), () {
        _clearSeekHoldOverlay();
      });
      notifyListeners();
    });
  }

  void _clearSeekHoldOverlay() {
    _seekHoldPending = false;
    _seekHoldOverlayTimer?.cancel();
    _seekHoldOverlayTimer = null;
    _seekHoldLandedNative = null;
    if (!_seekHoldOverlay) {
      _setPlaybackTimelineRunning(_shouldTimelineRun());
      return;
    }
    _seekHoldOverlay = false;
    final controller = _controller;
    if (controller != null) {
      try {
        if (controller.value.isInitialized) {
          _resetPlaybackTimeline(_position, running: _shouldTimelineRun());
        }
      } catch (_) {}
    }
    notifyListeners();
  }

  /// libmpv reports seekTo as complete and often keeps isPlaying=true while
  /// cache-pause / GOP decode still freeze the picture. The spinner stays
  /// until the native clock lands near the target and then actually ticks.
  /// Paused hops never tick; treat "landed on the still frame" as done.
  void _syncSeekHoldOverlayFromNative(Duration nativePosition) {
    if (!_seekHoldPending && !_seekHoldOverlay) return;
    final target = _lastRequestedSeekPosition ?? _position;
    final nearTarget = (nativePosition - target).inMilliseconds.abs() <= 450;
    if (_state == PlaybackState.paused) {
      if (nearTarget) {
        _clearSeekHoldOverlay();
        if (!_hasPresentationListeners) {
          _setPlaybackTimelineRunning(_shouldTimelineRun());
        }
      }
      return;
    }
    if (_seekHoldLandedNative == null) {
      if (nearTarget) {
        _seekHoldLandedNative = nativePosition;
      }
      return;
    }
    if ((nativePosition - _seekHoldLandedNative!).inMilliseconds.abs() >= 80) {
      _clearSeekHoldOverlay();
      if (!_hasPresentationListeners) {
        // Short seeks can release the pending hold before any overlay exists.
        // There is no next presentation frame off-page to restart this clock.
        _setPlaybackTimelineRunning(_shouldTimelineRun());
      }
    }
  }

  /// Mini-card / notification resume: the Dart isPlaying flag lags cache-pause.
  /// The native clock (or a filled demuxer window) is the real start signal.
  Future<bool> _awaitBackgroundClockStarted(
    VideoPlayerController controller, {
    required int playRequestId,
    required String itemId,
  }) async {
    final ready = NativeVideoPlayerMediaKit.playbackReadyFor(
      // ignore: invalid_use_of_visible_for_testing_member
      controller.playerId,
    );
    if (ready == null) return controller.value.isPlaying;
    try {
      final started = await ready.timeout(
        _backgroundClockReadyTimeout,
        onTimeout: () => false,
      );
      if (!_isCurrentPlayRequest(
        playRequestId,
        itemId,
        controller: controller,
      )) {
        return false;
      }
      return started || controller.value.isPlaying;
    } catch (_) {
      return controller.value.isPlaying;
    }
  }

  void _coverUntilNextVisibleVideoFrame() {
    if (_currentItem?.sourceRef?.kind != MediaSourceKind.bilibiliStream ||
        _currentItem?.type != MediaType.video) {
      return;
    }
    final controller = _controller;
    // Retained Bilibili files keep their online source identity, but Android
    // plays them through the local platform adapter. That adapter never sends
    // the gateway track-enable callback which completes this visual gate.
    if (!_usesBilibiliGateway ||
        controller == null ||
        !NativeVideoPlayerMediaKit.managesPlayer(
          // ignore: invalid_use_of_visible_for_testing_member
          controller.playerId,
        )) {
      return;
    }
    // Video is already selected and producing frames. Covering here would
    // glue the poster over a live picture on Mini/notification page entry.
    if (_requestedBilibiliVideoTrackEnabled == true &&
        _controllerHasRequiredVideoOutput(_currentItem!, controller)) {
      return;
    }
    _beginCoveringUntilVisibleVideoFrame();
  }

  /// Registers whether a full playback page is currently visible. The owner
  /// token is the State object, so portrait/landscape hand-offs can overlap
  /// without one page accidentally disabling the other page's cache policy.
  void setPlaybackPageVisible(Object owner, bool visible) {
    final hadPage = _playbackPageOwners.isNotEmpty;
    if (visible) {
      _playbackPageOwners.add(owner);
    } else {
      _playbackPageOwners.remove(owner);
    }
    if (visible && !hadPage && _playbackPageOwners.isNotEmpty) {
      _coverUntilNextVisibleVideoFrame();
    }
    if (!visible && _playbackPageOwners.isEmpty) {
      _cancelVisibleOutputRecovery();
      _bilibiliVisibleStartup?.cancel();
      _bilibiliVisibleStartup = null;
    }
    _syncBilibiliCachePolicy();
  }

  /// Enables a deferred picture for the music cover without registering the
  /// music page as a playback page. Cache policy and subtitle ownership stay
  /// with the real playback page.
  Future<bool> prepareMusicCoverVideo(String itemId) {
    _musicCoverRequestsBilibiliVideo = true;
    _syncBilibiliVideoTrackPolicy();
    return ensureVisibleVideoOutput(itemId);
  }

  /// Drops a cover request that never reached a mounted surface.
  void cancelMusicCoverVideoRequest() {
    if (_videoSurfaceClaimant != null) return;
    if (!_musicCoverRequestsBilibiliVideo) return;
    _musicCoverRequestsBilibiliVideo = false;
    _syncBilibiliVideoTrackPolicy();
  }

  /// Takes the shared video output for an auxiliary surface.
  ///
  /// The caller must mount its own [Video] only after the playback page below
  /// has rebuilt without one, i.e. at least one frame later.
  void claimVideoSurface(Object owner) {
    if (identical(_videoSurfaceClaimant, owner)) return;
    _videoSurfaceClaimant = owner;
    notifyListeners();
  }

  /// Gives the shared video output back. Releasing is idempotent for a stale
  /// owner so a widget that already lost the claim cannot clear the new one.
  void releaseVideoSurface(Object owner) {
    if (!identical(_videoSurfaceClaimant, owner)) return;
    _videoSurfaceClaimant = null;
    notifyListeners();
  }

  void setMusicCoverVideoSurfaceOwner(Object owner, bool owned) {
    if (owned) {
      if (identical(_videoSurfaceClaimant, owner)) return;
      _videoSurfaceClaimant = owner;
    } else {
      if (!identical(_videoSurfaceClaimant, owner)) return;
      _videoSurfaceClaimant = null;
      _musicCoverRequestsBilibiliVideo = false;
      _syncBilibiliVideoTrackPolicy();
    }
    notifyListeners();
  }

  @visibleForTesting
  void debugClearMusicCoverVideoSurface() {
    final notify =
        _videoSurfaceClaimant != null || _musicCoverRequestsBilibiliVideo;
    _videoSurfaceClaimant = null;
    if (_musicCoverRequestsBilibiliVideo) {
      _musicCoverRequestsBilibiliVideo = false;
      _syncBilibiliVideoTrackPolicy();
    }
    if (notify) notifyListeners();
  }

  bool get _hasVisiblePlaybackPage =>
      _isAppInForeground && _playbackPageOwners.isNotEmpty;

  @visibleForTesting
  bool get hasVisiblePlaybackPageForTest => _hasVisiblePlaybackPage;

  /// True when a real playback page, not just [owner], is currently registered.
  bool hasPlaybackPageOwnerOtherThan(Object owner) {
    for (final candidate in _playbackPageOwners) {
      if (!identical(candidate, owner)) return true;
    }
    return false;
  }

  /// Registers the mini playback card independently from the full page.
  void setMiniPlaybackCardVisible(Object owner, bool visible) {
    if (visible) {
      _miniPlaybackCardOwners.add(owner);
    } else {
      _miniPlaybackCardOwners.remove(owner);
    }
    _syncBilibiliCachePolicy();
  }

  /// The system media notification is a cache context only on phones. The
  /// system-media service supplies this flag after it has published a current
  /// item notification.
  void setMediaNotificationVisible(bool visible) {
    if (_mediaNotificationVisible == visible) return;
    _mediaNotificationVisible = visible;
    _syncBilibiliCachePolicy();
  }

  static VideoPlayerOptions buildVideoPlayerOptions({
    SettingsService? settings,
  }) {
    final resolvedSettings = settings ?? SettingsService();
    return VideoPlayerOptions(
      mixWithOthers: platformPlayerShouldMixWithOthers(
        isAndroid: !kIsWeb && Platform.isAndroid,
        allowConcurrentPlayback: resolvedSettings.allowConcurrentPlayback,
      ),
      // Keep background playback capability enabled and handle the
      // "leave app then pause" policy ourselves so toggles apply immediately.
      allowBackgroundPlayback: true,
    );
  }

  /// Android ExoPlayer must not request AUDIOFOCUS_GAIN itself.
  ///
  /// [SystemMediaSessionService] already holds exclusive focus via
  /// [AudioSession.setActive]. A second request from ExoPlayer — especially
  /// when the audio renderer starts late (moov-at-end MP4, odd AAC timescale)
  /// — looks like a focus LOSS to our session, which immediately pauses.
  /// Exclusive vs mix is therefore AudioSession-only on Android. iOS still
  /// maps the setting onto the native player's mixWithOthers flag.
  static bool platformPlayerShouldMixWithOthers({
    required bool isAndroid,
    required bool allowConcurrentPlayback,
  }) {
    if (isAndroid) return true;
    return allowConcurrentPlayback;
  }

  /// Recreate the live player only when its native mixWithOthers flag actually
  /// changes. Android ExoPlayer now always mixes at the player layer, so a
  /// concurrent-playback toggle must not rebuild it. media_kit never stored
  /// that flag on the player.
  @visibleForTesting
  static bool shouldReloadPlayerForConcurrentPlayback({
    required bool isAndroid,
    required DataSourceType sourceType,
    required String? resource,
  }) {
    if (!isAndroid || sourceType != DataSourceType.file || resource == null) {
      return false;
    }
    if (LocalPlaybackBackendPolicy.isWideCodecBackendPreferred(resource)) {
      return false;
    }
    // Android ExoPlayer mixWithOthers is always true; see
    // [platformPlayerShouldMixWithOthers]. Recreating would hitch for no
    // audio-focus change.
    return false;
  }

  /// Pushes the mix/exclusive flag to the platform player, then rebuilds an
  /// Android ExoPlayer if one is currently active.
  Future<void> applyConcurrentPlaybackSetting() async {
    final allowConcurrentPlayback = SettingsService().allowConcurrentPlayback;
    try {
      await VideoPlayerPlatform.instance.setMixWithOthers(
        platformPlayerShouldMixWithOthers(
          isAndroid: !kIsWeb && Platform.isAndroid,
          allowConcurrentPlayback: allowConcurrentPlayback,
        ),
      );
    } catch (error) {
      _logPlaybackEvent(
        'mixWithOthers apply failed',
        data: <String, Object?>{'error': error.toString()},
      );
    }

    final item = _currentItem;
    final controller = _controller;
    if (item == null || controller == null) {
      return;
    }
    if (_state == PlaybackState.loading || _state == PlaybackState.idle) {
      return;
    }
    if (!shouldReloadPlayerForConcurrentPlayback(
      isAndroid: !kIsWeb && Platform.isAndroid,
      sourceType: DataSourceType.file,
      resource: item.path,
    )) {
      return;
    }

    final position = _position;
    final autoPlay = _state == PlaybackState.playing || _session.desiredPlaying;
    await _disposePreloadedController(awaitCompletion: true);
    await play(
      item,
      startPosition: position,
      autoPlay: autoPlay,
      forceRecreate: true,
    );
  }

  bool _controllerIsReusableForItem(VideoItem item) {
    final controller = _controller;
    if (_currentItem?.id != item.id ||
        _controllerItemId != item.id ||
        controller == null) {
      return false;
    }
    if (_isOnlineMedia(item) &&
        _onlineStartup != null &&
        !_onlineStartup!.isPrepared) {
      // Initialized is only mountable. An abandoned open may still be at
      // byte zero and cannot be promoted as an already prepared live session.
      return false;
    }
    try {
      // ignore: invalid_use_of_visible_for_testing_member
      final nativePlayerId = controller.playerId;
      return NativeVideoPlayerMediaKit.transportUsableFor(nativePlayerId) !=
              false &&
          controller.value.isInitialized &&
          !controller.value.hasError &&
          _session.phase != PlaybackSessionPhase.failed;
    } catch (_) {
      return false;
    }
  }

  bool _isCurrentPlayRequest(
    int requestId,
    String itemId, {
    VideoPlayerController? controller,
  }) {
    if (requestId != _playRequestId || _currentItem?.id != itemId) {
      return false;
    }
    return controller == null || identical(_controller, controller);
  }

  bool _isCurrentControllerSession(
    VideoPlayerController controller,
    String? itemId,
  ) {
    return identical(_controller, controller) && _currentItem?.id == itemId;
  }

  void _clearInitialPositionGuard() {
    _initialPositionGuardTarget = null;
    _initialPositionGuardUntil = null;
  }

  void _armInitialPositionGuard(Duration target, {bool protectZero = false}) {
    if (target < Duration.zero || (!protectZero && target == Duration.zero)) {
      _clearInitialPositionGuard();
      return;
    }
    _initialPositionGuardTarget = target;
    _initialPositionGuardUntil = DateTime.now().add(
      _initialPositionGuardDuration,
    );
  }

  bool _shouldIgnoreInitialPositionSample(Duration sample) {
    final startup = _onlineStartup;
    if (startup?.isPending == true) {
      return true;
    }
    final target = _initialPositionGuardTarget;
    final until = _initialPositionGuardUntil;
    if (target == null || until == null) return false;
    if (DateTime.now().isAfter(until)) {
      _clearInitialPositionGuard();
      return false;
    }
    final deltaMs = sample.inMilliseconds - target.inMilliseconds;
    // When playback is running, the first confirmed sample may already be a
    // little ahead of the target. A sample far behind or far ahead is still
    // from the pre-seek clock (especially noticeable on backward seeks).
    if (deltaMs >= -_seekVerificationToleranceMs &&
        deltaMs <= const Duration(seconds: 3).inMilliseconds) {
      _clearInitialPositionGuard();
      return false;
    }
    // Keep the optimistic service position until native playback catches up or
    // the bounded guard expires. This covers both forward and backward seeks.
    return true;
  }

  // A video_player value is a cached UI snapshot. A transient zero must not
  // overwrite the watch position or flush a healthy Android decoder with a
  // corrective seek. Keep the existing real-reset recovery, but confirm it
  // against two fresh transport reads before changing the transport.
  bool _holdUnconfirmedBilibiliZero(
    VideoPlayerController controller,
    Duration sample,
  ) {
    if (!shouldResyncBilibiliClockFromZero(
      isOnlineBilibiliStream: isCurrentItemOnlineBilibiliStream,
      expectedPosition: _position,
      nativeSample: sample,
      now: DateTime.now(),
      hopSeekInFlight:
          _pendingSeekRequestId != null ||
          (_hopSeekDispatchTimer?.isActive ?? false),
      lastSeekSource: _lastSeekSource,
      lastHopSeekAt: _lastHopSeekAt,
      duration: _duration,
    )) {
      return false;
    }
    final now = DateTime.now();
    final previous = _bilibiliZeroResyncAt;
    if (_bilibiliZeroClockCheck == null &&
        _state == PlaybackState.playing &&
        _session.desiredPlaying &&
        (previous == null ||
            now.difference(previous) >= const Duration(seconds: 2))) {
      final check = Object();
      _bilibiliZeroClockCheck = check;
      unawaited(_confirmBilibiliZeroClock(controller, check));
    }
    // Holding also applies during the recovery cooldown and a paused sample.
    // Explicit user seeks already establish their own position before here.
    return true;
  }

  Future<Duration?> _readBilibiliRecoveryClock(
    VideoPlayerController controller,
  ) async {
    try {
      // ignore: invalid_use_of_visible_for_testing_member
      final id = controller.playerId;
      if (NativeVideoPlayerMediaKit.managesPlayer(id)) {
        return await NativeVideoPlayerMediaKit.transportPositionFor(
          id,
        ).timeout(_streamQualityPositionReadTimeout);
      }
      return await controller.position.timeout(
        _streamQualityPositionReadTimeout,
      );
    } catch (_) {
      // Unavailable clock data cannot authorize a seek. In particular, do not
      // fall back to the very cached sample that caused this verification.
      return null;
    }
  }

  Future<void> _confirmBilibiliZeroClock(
    VideoPlayerController controller,
    Object check,
  ) async {
    final requestId = _playRequestId;
    final seekRequestId = _seekRequestId;
    final itemId = _currentItem!.id;
    final expected = _position;
    bool isCurrent() =>
        identical(_bilibiliZeroClockCheck, check) &&
        _isCurrentPlayRequest(requestId, itemId, controller: controller) &&
        _seekRequestId == seekRequestId &&
        _pendingSeekRequestId == null &&
        !_initialPositionSeekInFlight &&
        !_isSwitchingStreamQuality &&
        _bilibiliStartup?.isPending != true &&
        !_hasPlaybackCompleted &&
        _state == PlaybackState.playing &&
        _session.desiredPlaying;
    bool confirmsReset(Duration? actual) =>
        actual != null &&
        shouldResyncBilibiliClockFromZero(
          isOnlineBilibiliStream: isCurrentItemOnlineBilibiliStream,
          expectedPosition: expected,
          nativeSample: actual,
          now: DateTime.now(),
          lastResyncAt: _bilibiliZeroResyncAt,
          hopSeekInFlight: _hopSeekDispatchTimer?.isActive ?? false,
          lastSeekSource: _lastSeekSource,
          lastHopSeekAt: _lastHopSeekAt,
          duration: _duration,
        );
    try {
      if (!isCurrent()) return;
      final first = await _readBilibiliRecoveryClock(controller);
      if (!isCurrent() || !confirmsReset(first)) return;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (!isCurrent()) return;
      final second = await _readBilibiliRecoveryClock(controller);
      if (!isCurrent() || !confirmsReset(second)) return;
      _bilibiliZeroResyncAt = DateTime.now();
      _logPlaybackEvent(
        'confirmed Bilibili transport clock reset',
        data: {
          'itemId': itemId,
          'expectedMs': _position.inMilliseconds,
          'firstMs': first!.inMilliseconds,
          'secondMs': second!.inMilliseconds,
        },
      );
      await seekTo(_position, source: 'bilibili_zero_resync');
    } catch (error) {
      _logPlaybackEvent(
        'Bilibili clock recovery failed',
        data: {'error': '$error'},
      );
    } finally {
      if (identical(_bilibiliZeroClockCheck, check)) {
        _bilibiliZeroClockCheck = null;
      }
    }
  }

  /// Establishes a deterministic starting point before playback is allowed to
  /// start. Some native backends probe a network source from byte zero during
  /// initialize and briefly report it as playing; seeking while that probe is
  /// still running can otherwise produce the visible "intro then saved
  /// position" jump.
  Future<void> _seekInitialPosition(
    VideoPlayerController controller,
    Duration requestedPosition,
  ) async {
    if (!controller.value.isInitialized) return;
    final previous = _initialPositionSeekInFlight;
    _initialPositionSeekInFlight = true;
    try {
      await _seekInitialPositionImpl(controller, requestedPosition);
    } finally {
      _initialPositionSeekInFlight = previous;
    }
  }

  Future<void> _seekInitialPositionImpl(
    VideoPlayerController controller,
    Duration requestedPosition,
  ) async {
    if (!controller.value.isInitialized) return;

    var target = requestedPosition < Duration.zero
        ? Duration.zero
        : requestedPosition;
    final duration = controller.value.duration;

    final startup = _onlineStartup;
    final opening = startup != null && !startup.isReady ? startup : null;
    final requestId = _playRequestId;
    final seekRevision = _seekRequestId;
    bool currentStartup() =>
        requestId == _playRequestId &&
        seekRevision == _seekRequestId &&
        identical(_controller, controller) &&
        (opening == null ||
            identical(_onlineStartup, opening) &&
                opening.isPending &&
                opening.target == target);
    if (!currentStartup()) return;
    if (startup?.isPending == true) {
      startup!.target = target;
      final native = NativeVideoPlayerMediaKit.positionSettledFor(
        // ignore: invalid_use_of_visible_for_testing_member
        controller.playerId,
        target,
      );
      if (native != null) {
        final settled = await startup.run(native);
        final actual = await _readNativeControllerPosition(controller);
        if (!currentStartup()) return;
        if (settled ||
            (actual - target).abs() <=
                BilibiliStartupContext.positionTolerance) {
          // An exact start= can still be decoding while seeking=yes. Wait for
          // the frame below instead of flushing that useful work with a seek.
          _position = target;
          _armInitialPositionGuard(target, protectZero: true);
          return;
        }
        if (!startup.claimPositionCorrection()) {
          throw StateError('视频未能定位到播放位置');
        }
      }
    }

    try {
      await controller.pause();
    } catch (_) {}
    if (!currentStartup()) return;

    final metadataDuration = Duration(
      milliseconds: _currentItem?.durationMs ?? 0,
    );
    final trustedDuration = PlaybackBehaviorPolicy.trustedDurationForResume(
      nativeDuration: duration,
      metadataDuration: metadataDuration,
      savedPosition: target,
    );
    if (trustedDuration > Duration.zero && target >= trustedDuration) {
      target = Duration.zero;
      if (opening != null) opening.target = target;
    }

    Duration actual = await _readNativeControllerPosition(controller);
    if (!currentStartup()) return;
    // Only a genuine t=0 start can skip. Dart `position` may echo the start=
    // header after initialize even though post-open video-track selection
    // put libmpv back at the file start.
    if (shouldSkipRedundantInitialSeek(
      target: target,
      actual: actual,
      toleranceMs: _seekVerificationToleranceMs,
    )) {
      _position = Duration.zero;
      _clearInitialPositionGuard();
      _bufferedPosition = _readBufferedPosition(controller);
      return;
    }

    try {
      await NativeVideoPlayerMediaKit.prepareSeekStyleFor(
        // ignore: invalid_use_of_visible_for_testing_member
        controller.playerId,
        style: StreamingSeekStyle.scrub,
      );
    } catch (_) {}
    if (!currentStartup()) return;

    try {
      await controller.seekTo(target).timeout(_controllerSeekTimeout);
    } catch (_) {}
    if (!currentStartup()) return;
    _position = target;
    _armInitialPositionGuard(target);
    try {
      // Seeking must finish in a paused state. autoPlay is applied explicitly
      // by the caller after this method returns.
      if (controller.value.isPlaying) {
        await controller.pause();
      }
    } catch (_) {}
    if (!currentStartup()) return;
    _bufferedPosition = _readBufferedPosition(controller);
  }

  Future<void> _recoverOnlineResumeFrame(
    VideoPlayerController controller,
    PlaybackStartupContext startup,
    Duration target,
  ) async {
    final seekRevision = _seekRequestId;
    bool current() =>
        identical(_onlineStartup, startup) &&
        identical(_controller, controller) &&
        startup.isPending &&
        !startup.hasUserTarget &&
        startup.target == target &&
        seekRevision == _seekRequestId;
    if (!current()) return;
    // Keep the decoder parked and the existing cover/timeline intact. A brief
    // play/pause preroll would leak audio and is unnecessary for an exact seek.
    await startup.run(controller.pause());
    if (!current()) return;
    await startup.run(
      NativeVideoPlayerMediaKit.prepareSeekStyleFor(
        // ignore: invalid_use_of_visible_for_testing_member
        controller.playerId,
        style: StreamingSeekStyle.scrub,
      ),
    );
    if (!current()) return;
    await startup.run(controller.seekTo(target), cap: _controllerSeekTimeout);
    if (!current()) return;
    _position = target;
    _armInitialPositionGuard(target, protectZero: true);
  }

  Future<CloudDrivePreparedPlayback> _openCloudDriveForStartup({
    required CloudDrivePlaybackService service,
    required VideoItem item,
    required String? qualityId,
    required CloudDrivePlaybackBudget budget,
    required PlaybackStartupContext? startup,
    required int directEpoch,
  }) async {
    startup?.check();
    final cancel = CloudDriveCancelToken();
    final unbind = startup?.bindAbort(cancel.cancel);
    startup?.record('cloud play address requested');
    final opening = Future<CloudDrivePreparedPlayback>.sync(
      () => service.open(
        item,
        qualityId: qualityId,
        operationDeadline: budget.deadline,
        cancelToken: cancel,
      ),
    );
    try {
      final bounded = opening.timeout(budget.remaining(cloudDriveResolveCap));
      final result = await _raceDirectEpoch(
        startup?.run(bounded) ?? bounded,
        directEpoch,
      );
      startup?.record('cloud play address ready');
      return result;
    } catch (_) {
      cancel.cancel();
      // A provider may finish after cancellation. It still owns a lease, and
      // must release it without installing it into a newer playback session.
      unawaited(
        opening.then<void>(
          (value) => value.lease.release(),
          onError: (Object _, StackTrace _) {},
        ),
      );
      rethrow;
    } finally {
      unbind?.call();
    }
  }

  Future<void> _awaitOnlineClockStarted({
    required VideoItem item,
    required VideoPlayerController controller,
    required PlaybackStartupContext startup,
    required int playRequestId,
    required Duration baseline,
  }) async {
    bool current() =>
        identical(_onlineStartup, startup) &&
        startup.isPending &&
        _isCurrentPlayRequest(playRequestId, item.id, controller: controller);
    var clockBaseline = baseline;
    Future<void> clock() async {
      var revision = _seekRequestId;
      while (current() && _session.desiredPlaying) {
        final probe =
            debugOnlineStartupClock?.call(controller, startup) ??
            NativeVideoPlayerMediaKit.clockStartedFor(
              // ignore: invalid_use_of_visible_for_testing_member
              controller.playerId,
              startup,
              clockBaseline,
              shouldWait: () =>
                  current() &&
                  _session.desiredPlaying &&
                  revision == _seekRequestId,
            );
        if (probe == null) {
          // Stock platform players also acknowledge play before decoding. A
          // jump from an unreported seek target is not a running media clock.
          clockBaseline = await startup.run(
            _readNativeControllerPosition(controller),
          );
          while (current() &&
              _session.desiredPlaying &&
              revision == _seekRequestId) {
            if (controller.value.hasError) {
              throw StateError(controller.value.errorDescription ?? '媒体播放失败');
            }
            final sample = await startup.run(
              _readNativeControllerPosition(controller),
            );
            if (!controller.value.isBuffering &&
                sample - clockBaseline >= const Duration(milliseconds: 30)) {
              return;
            }
            await startup.run(
              Future<void>.delayed(const Duration(milliseconds: 40)),
            );
          }
        } else {
          await startup.run(probe);
        }
        if (!current() || !_session.desiredPlaying) return;
        if (revision == _seekRequestId) return;
        revision = _seekRequestId;
        clockBaseline = await startup.run(
          _readNativeControllerPosition(controller),
        );
      }
    }

    final waiting = startup.waitForFrame(
      clock(),
      recheckFrame: clock,
      playbackClock: true,
      recoverResume: (target) async {
        if (!current() || !_session.desiredPlaying) return;
        // A late Dart flag/poll must not pause audio which is really running.
        final actual = await startup.run(
          _readNativeControllerPosition(controller),
        );
        if (!current() || !_session.desiredPlaying) {
          return;
        }
        if (actual - clockBaseline >= const Duration(milliseconds: 30)) {
          // It may have advanced once and then parked. Only a clock which is
          // still advancing can bypass recovery; a stale successful sample
          // must not leave a paused decoder behind an endless opening state.
          await startup.run(
            Future<void>.delayed(const Duration(milliseconds: 80)),
          );
          final fresh = await startup.run(
            _readNativeControllerPosition(controller),
          );
          if (!current() ||
              !_session.desiredPlaying ||
              fresh - actual >= const Duration(milliseconds: 30)) {
            return;
          }
        }
        await _recoverOnlineResumeFrame(controller, startup, target);
        if (!current() || !_session.desiredPlaying) return;
        clockBaseline = await startup.run(
          _readNativeControllerPosition(controller),
        );
        if (!current() || !_session.desiredPlaying) return;
        await startup.run(controller.play());
      },
    );
    await startup.run(
      waiting,
      cap: item.sourceRef?.kind == MediaSourceKind.podcastEpisode
          ? const Duration(seconds: 12)
          : startup.limit,
    );
  }

  Future<void> _composePreparedOnlineFrame(
    PlaybackStartupContext startup,
  ) async {
    if (!_hasVisiblePlaybackPage) return;
    var composed = false;
    SchedulerBinding.instance.scheduleFrame();
    unawaited(
      SchedulerBinding.instance.endOfFrame.then((_) {
        composed = true;
      }),
    );
    // Flutter can stop producing frames when an activity goes to background.
    // Readiness/cancellation must continue without a mounted presentation.
    while (_hasVisiblePlaybackPage && !composed) {
      await startup.run(Future<void>.delayed(const Duration(milliseconds: 16)));
    }
  }

  Future<void> _confirmInitialResumePosition({
    required VideoPlayerController controller,
    required Duration target,
    required bool allowPause,
  }) async {
    if (_onlineStartup?.isPrepared == true) {
      return;
    }
    if (target.inMilliseconds <= _seekVerificationToleranceMs) return;
    if (!controller.value.isInitialized) return;
    final actual = await _readNativeControllerPosition(controller);
    if ((actual - target).inMilliseconds.abs() <=
        _seekVerificationToleranceMs) {
      _position = target;
      _armInitialPositionGuard(target);
      return;
    }
    // Before the clock starts, pause+seek is fine. After play(), a service
    // seek keeps audio moving instead of repeating the paused initialize path.
    if (allowPause) {
      await _seekInitialPosition(controller, target);
      return;
    }
    await seekTo(target, source: 'play_resume_repair');
  }

  void _trackMobileControllerRelease(Future<void> release) {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    final previous = _mobileControllerReleaseBarrier;
    _mobileControllerReleaseBarrier = () async {
      await Future.wait<void>([
        _ignoreControllerReleaseError(previous),
        _ignoreControllerReleaseError(release),
      ]);
    }();
  }

  Future<void> _ignoreControllerReleaseError(Future<void> release) async {
    try {
      await release;
    } catch (error) {
      _logPlaybackEvent(
        'native controller release failed',
        data: <String, Object?>{'error': error.toString()},
      );
    }
  }

  Future<void> _disposeTrackedController(VideoPlayerController controller) {
    final existing = _controllerReleases[controller];
    if (existing != null) return existing;
    final release = () async {
      try {
        await controller.dispose();
      } catch (_) {}
    }();
    _controllerReleases[controller] = release;
    _trackMobileControllerRelease(release);
    return release;
  }

  Future<void> _detachController(
    VideoPlayerController controller, {
    required bool disposeController,
    bool pauseIfPlaying = false,
  }) async {
    _detachNativePositionStream(controller);
    try {
      controller.removeListener(_onControllerUpdate);
    } catch (_) {}

    if (pauseIfPlaying) {
      try {
        // A newly opened source must remain silent until its saved position is
        // confirmed and the latest episode-switch intent is committed. Pause
        // unconditionally because isPlaying may still be a stale Dart value.
        final pausing = controller.pause();
        if (disposeController) {
          // Register native teardown even when pause acknowledgement hangs.
          // The mobile release barrier still waits for the real disposal.
          unawaited(pausing.catchError((Object _) {}));
        } else {
          await pausing.timeout(debugRecoveryLimit);
        }
      } catch (_) {}
    }

    if (!disposeController) {
      return;
    }

    await _disposeTrackedController(controller);
  }

  void _attachNativePositionStream(VideoPlayerController controller) {
    _cancelNativePositionStream();
    _detachOutputState?.call();
    _detachOutputState = null;
    final itemId = _currentItem?.id;
    // video_player exposes this identifier for platform-adapter integration.
    // ignore: invalid_use_of_visible_for_testing_member
    final playerId = controller.playerId;
    _nativePositionPlayerId = playerId;
    _watchCloudDriveLease();
    final hints = NativeVideoPlayerMediaKit.healthHintsFor(playerId);
    if (hints != null) {
      void changed() => _scheduleNativeHealthCheck(controller);
      hints.addListener(changed);
      _detachNativeHealth = () => hints.removeListener(changed);
    }
    final output = NativeVideoPlayerMediaKit.outputStateFor(playerId);
    if (output != null) {
      void changed() {
        if (_presentationDisposed ||
            !identical(_controller, controller) ||
            _currentItem?.id != itemId) {
          return;
        }
        _transitionPlaybackSession(
          _session.generation,
          _session.phase,
          controller: controller,
        );
        if (!output.value.available &&
            _hasVisiblePlaybackPage &&
            _state != PlaybackState.error &&
            _session.phase != PlaybackSessionPhase.failed &&
            _onlineStartup?.isPending != true) {
          _beginCoveringUntilVisibleVideoFrame();
          unawaited(ensureVisibleVideoOutput(itemId!));
        }
        notifyListeners();
      }

      output.addListener(changed);
      _detachOutputState = () => output.removeListener(changed);
    }
    final positionStream = NativeVideoPlayerMediaKit.positionStreamFor(
      playerId,
    );
    final rateStream = NativeVideoPlayerMediaKit.rateStreamFor(playerId);
    if (positionStream == null && rateStream == null) return;
    _nativePositionPlayerId = playerId;
    _nativePresentationPlaybackSpeed = controller.value.playbackSpeed;
    if (positionStream != null) {
      _nativePositionSubscription = positionStream.listen((nativePosition) {
        if (!identical(_controller, controller) || _currentItem?.id != itemId) {
          return;
        }
        _syncSeekHoldOverlayFromNative(nativePosition);
        if (_pendingSeekRequestId != null) {
          return;
        }
        if (_shouldIgnoreInitialPositionSample(nativePosition)) return;
        if (_syncAwaitingTransportClock(controller, nativePosition)) return;
        _observeNativeTimelinePosition(nativePosition);
      });
    }
    if (rateStream != null) {
      _nativeRateSubscription = rateStream.listen((nativeRate) {
        if (!identical(_controller, controller) ||
            _currentItem?.id != itemId ||
            !nativeRate.isFinite ||
            nativeRate <= 0) {
          return;
        }
        _nativePresentationPlaybackSpeed = nativeRate;
        if (_timelineClock.isInitialized) {
          // Preserve the currently presented position and change only its
          // slope. Progress, subtitles and danmaku therefore follow the rate
          // accepted by libmpv without jumping at either boundary.
          _timelineClock.setRate(nativeRate);
        }
      });
    }
  }

  void _detachNativePositionStream(VideoPlayerController controller) {
    // ignore: invalid_use_of_visible_for_testing_member
    if (_nativePositionPlayerId != controller.playerId) return;
    _cancelNativePositionStream();
  }

  void _cancelNativePositionStream() {
    _nativeHealthTimer?.cancel();
    _nativeHealthTimer = null;
    _detachNativeHealth?.call();
    _detachNativeHealth = null;
    _detachOutputState?.call();
    _detachOutputState = null;
    final positionSubscription = _nativePositionSubscription;
    final rateSubscription = _nativeRateSubscription;
    _nativePositionSubscription = null;
    _nativeRateSubscription = null;
    _nativePositionPlayerId = null;
    _nativePresentationPlaybackSpeed = null;
    if (positionSubscription != null) {
      unawaited(positionSubscription.cancel());
    }
    if (rateSubscription != null) unawaited(rateSubscription.cancel());
  }

  void _watchCloudDriveLease() {
    _detachCloudLease?.call();
    _detachCloudLease = null;
    final lease = _currentCloudDriveLease;
    if (lease == null || lease.released) return;
    void changed() {
      if (lease.released ||
          !lease.needsReopen ||
          !identical(_currentCloudDriveLease, lease) ||
          identical(_cloudReopenInFlight, lease) ||
          _presentationDisposed) {
        return;
      }
      final item = _currentItem;
      if (item == null ||
          !isCloudDriveMedia(source: item.sourceRef, path: item.path)) {
        return;
      }
      _cloudReopenInFlight = lease;
      final opening = _onlineStartup;
      if (opening?.isPending == true) {
        _pendingOnlineStartup = (
          itemId: item.id,
          context: opening!.continueOnNewNetwork(),
        );
      }
      unawaited(
        play(
          item,
          startPosition: _position,
          autoPlay: _session.desiredPlaying,
          forceRecreate: true,
          cloudDriveQualityId: _selectedCloudDriveQualityId,
          userInitiatedWatch: false,
        ).whenComplete(() {
          if (identical(_cloudReopenInFlight, lease)) {
            _cloudReopenInFlight = null;
          }
        }),
      );
    }

    lease.reopenRequired.addListener(changed);
    _detachCloudLease = () => lease.reopenRequired.removeListener(changed);
    // Discovery may have signalled while the candidate was still initializing.
    if (lease.needsReopen) scheduleMicrotask(changed);
  }

  void handleAppLifecycleState(AppLifecycleState? state) {
    final AppLifecycleState? previousState = _lastAppLifecycleState;
    _lastAppLifecycleState = state;
    final controller = _controller;
    _logPlaybackEvent(
      'app lifecycle',
      data: <String, Object?>{
        'previous': previousState?.name,
        'next': state?.name,
        'itemId': _currentItem?.id,
        'state': _state.name,
        'desiredPlaying': _session.desiredPlaying,
        'positionMs': _position.inMilliseconds,
        // Native transport diagnostics need the platform handle.
        // ignore: invalid_use_of_visible_for_testing_member
        'playerId': controller?.playerId,
        'pageOwners': _playbackPageOwners.length,
      },
    );

    final bool isForeground =
        state == null ||
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    sleepTimer.checkNow();
    _setAppForegroundState(isForeground);

    final bool leftForeground = PlaybackBehaviorPolicy.isLeavingForeground(
      previousState: previousState,
      nextState: state,
    );
    final bool shouldPauseForBackground =
        leftForeground &&
        PlaybackBehaviorPolicy.shouldPauseWhenAppBackgrounded(
          enabled: SettingsService().pausePlaybackWhenAppBackgrounded,
          isMobilePlatform: !kIsWeb && (Platform.isAndroid || Platform.isIOS),
          transportPlaying: isTransportPlaying,
        );

    if (shouldPauseForBackground) {
      unawaited(pause());
    } else if (state == AppLifecycleState.resumed) {
      // A device can pause the native player when the activity returns if the
      // media session was inactive. The play intent is still authoritative.
      unawaited(_restoreTransportPausedByPlatform());
    } else if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // Even when the user has enabled background playback, persist the
      // authoritative service position before the process can be suspended or
      // killed. The playback page must not write a competing raw-controller
      // position during the same transition.
      unawaited(persistCurrentProgress());
    }
  }

  void setAppForegroundState(bool isForeground) {
    if (isForeground) sleepTimer.checkNow();
    _setAppForegroundState(isForeground);
  }

  Future<void> _restoreTransportPausedByPlatform() async {
    // EOF can still be waiting on history persistence or a paged queue.
    // Foreground recovery must not replay that completed transport.
    if (_hasPlaybackCompleted) return;
    final controller = _controller;
    if (!shouldRestoreTransportOnForeground(
      desiredPlaying: _session.desiredPlaying,
      state: _state,
      controllerReady: controller != null && controller.value.isInitialized,
      controllerPlaying: controller?.value.isPlaying ?? false,
    )) {
      if (controller != null) _scheduleNativeHealthCheck(controller);
      return;
    }
    try {
      final restoringController = controller!;
      Future<void> restoreLatestIntent() async {
        try {
          // A stalled foreground acknowledgement must not hold the command
          // queue ahead of an explicit pause. Observe its late completion and
          // enforce the current intent on that same physical controller.
          await restoringController.play();
        } finally {
          if (!_presentationDisposed &&
              identical(_controller, restoringController) &&
              !_session.desiredPlaying) {
            await _applyPlaybackTransport(restoringController, playing: false);
          }
        }
      }

      await restoreLatestIntent().timeout(debugRecoveryLimit);
    } catch (error) {
      _logPlaybackEvent(
        'foreground transport restore failed',
        data: <String, Object?>{'error': error.toString()},
      );
    } finally {
      if (controller != null) _scheduleNativeHealthCheck(controller);
    }
  }

  void _scheduleNativeHealthCheck(VideoPlayerController controller) {
    _nativeHealthTimer?.cancel();
    _nativeHealthTimer = Timer(const Duration(milliseconds: 250), () async {
      final item = _currentItem;
      if (item == null ||
          !identical(_controller, controller) ||
          _state == PlaybackState.error ||
          _session.phase == PlaybackSessionPhase.failed ||
          _onlineStartup?.isPending == true ||
          identical(_nativeHealthChecking, controller) ||
          _presentationDisposed) {
        return;
      }
      // ignore: invalid_use_of_visible_for_testing_member
      final playerId = controller.playerId;
      if (!NativeVideoPlayerMediaKit.managesPlayer(playerId)) return;
      _nativeHealthChecking = controller;
      final generation = _session.generation;
      bool current() =>
          !_presentationDisposed &&
          identical(_controller, controller) &&
          _currentItem?.id == item.id &&
          _session.generation == generation;
      final PlaybackStartupContext budget =
          item.sourceRef?.kind == MediaSourceKind.bilibiliStream
          ? BilibiliStartupContext(limit: debugRecoveryLimit)
          : PlaybackStartupContext(limit: debugRecoveryLimit);
      try {
        final native = await budget.run(
          NativeVideoPlayerMediaKit.transportStateFor(playerId),
        );
        if (!current()) return;
        var failed =
            NativeVideoPlayerMediaKit.transportUsableFor(playerId) == false ||
            native['idle-active'] == 'yes' && native['eof-reached'] != 'yes';
        if (!failed &&
            _session.desiredPlaying &&
            native['pause'] == 'no' &&
            native['paused-for-cache'] == 'no' &&
            !_controllerIsBuffering) {
          final seconds = double.tryParse(native['time-pos'] ?? '');
          if (seconds != null && seconds.isFinite) {
            final clock = NativeVideoPlayerMediaKit.clockStartedFor(
              playerId,
              budget,
              Duration(microseconds: (seconds * 1000000).round()),
              shouldWait: () => current() && _session.desiredPlaying,
            );
            if (clock != null) {
              try {
                await budget.run(clock, cap: const Duration(seconds: 6));
              } on TimeoutException {
                failed = true;
              }
            }
          }
        }
        if (!current()) return;
        if (failed && _nativeHealthReopened[controller] != true) {
          _nativeHealthReopened[controller] = true;
          final continuation = budget.continueOnNewNetwork();
          if (continuation is BilibiliStartupContext) {
            prepareBilibiliStartup(item.id, continuation);
          } else {
            _pendingOnlineStartup = (itemId: item.id, context: continuation);
          }
          await budget.run(
            play(
              item,
              startPosition: _position,
              autoPlay: _session.desiredPlaying,
              forceRecreate: true,
              bilibiliQualityId: _selectedStreamQuality?.id,
              cloudDriveQualityId: _selectedCloudDriveQualityId,
              userInitiatedWatch: false,
            ),
          );
        } else if (needsVisibleVideoOutputRecovery(item.id) &&
            _hasVisiblePlaybackPage) {
          await budget.run(ensureVisibleVideoOutput(item.id));
        }
        budget.ready();
      } catch (error) {
        budget.fail(error);
        _logPlaybackEvent(
          'native health check failed',
          data: {'itemId': item.id, 'error': '$error'},
        );
      } finally {
        if (identical(_nativeHealthChecking, controller)) {
          _nativeHealthChecking = null;
        }
      }
    });
  }

  /// Initialized and not failed. Healthy players survive network handovers.
  bool _playbackSessionHealthyForRestore() {
    final controller = _controller;
    if (controller == null) return false;
    try {
      if (!controller.value.isInitialized || controller.value.hasError) {
        return false;
      }
    } catch (_) {
      return false;
    }
    return cloudDriveSessionIsHealthy(
      controllerReady: true,
      controllerFailed: false,
      playingOrPaused:
          _state == PlaybackState.playing || _state == PlaybackState.paused,
    );
  }

  void _setAppForegroundState(bool isForeground) {
    if (_isAppInForeground == isForeground) return;
    _isAppInForeground = isForeground;
    _syncWakelockWithState();

    if (_state == PlaybackState.playing) {
      if (isForeground) {
        // The frame ticker is suspended while the app is backgrounded, while
        // the native player keeps advancing. Read that player's clock directly
        // before restarting the ticker: controller.value may still contain the
        // final background Dart sample and would make the foreground UI jump
        // backward before catching up.
        _stopRealtimeSyncLoop();
        final controller = _controller;
        final itemId = _currentItem?.id;
        if (controller != null &&
            itemId != null &&
            controller.value.isInitialized) {
          // ignore: invalid_use_of_visible_for_testing_member
          final playerId = controller.playerId;
          final nativeClock = NativeVideoPlayerMediaKit.positionStreamFor(
            playerId,
          );
          if (nativeClock == null) {
            // Other platform adapters keep controller.value authoritative.
            _updatePosition();
            _resetPlaybackTimeline(_position, running: _shouldTimelineRun());
            _startRealtimeSyncLoop();
          } else {
            unawaited(_reanchorForegroundClock(controller, itemId));
          }
        } else {
          _startRealtimeSyncLoop();
        }
      } else {
        _startRealtimeSyncLoop();
      }
    }
    if (isForeground && _playbackPageOwners.isNotEmpty) {
      final item = _currentItem;
      if (item != null) {
        _coverUntilNextVisibleVideoFrame();
        unawaited(ensureVisibleVideoOutput(item.id));
      }
    }
  }

  Future<void> _reanchorForegroundClock(
    VideoPlayerController controller,
    String itemId,
  ) async {
    final nativePosition = await _readNativeControllerPosition(controller);
    if (!_isAppInForeground ||
        _currentItem?.id != itemId ||
        !identical(_controller, controller)) {
      return;
    }

    var position = nativePosition < Duration.zero
        ? Duration.zero
        : nativePosition;
    final controllerDuration = _presentationDuration(controller.value.duration);
    if (controllerDuration > Duration.zero) {
      _duration = controllerDuration;
      if (position > controllerDuration) position = controllerDuration;
    }
    _position = position;
    _bufferedPosition = _readBufferedPosition(controller);
    _setCoarsePosition(position);
    _resetPlaybackTimeline(position, running: _shouldTimelineRun());
    _startRealtimeSyncLoop();
    notifyListeners();
  }

  // Getters
  PlaybackState get state => _state;
  VideoItem? get currentItem => _currentItem;

  /// Optional bounded local-library sync before selecting a resume position.
  Future<void> Function(String mediaId)? beforeLibraryPlayback;
  Duration get position => _position;
  Duration get duration => _duration;

  Duration _presentationDuration(Duration nativeDuration) {
    if (!isCurrentItemBilibiliStream &&
        !isCloudDriveMedia(
          source: _currentItem?.sourceRef,
          path: _currentItem?.path ?? '',
        )) {
      return nativeDuration;
    }
    final metadata = Duration(milliseconds: _currentItem?.durationMs ?? 0);
    return PlaybackBehaviorPolicy.trustedDurationForResume(
      nativeDuration: nativeDuration,
      metadataDuration: _duration > metadata ? _duration : metadata,
    );
  }

  Duration get bufferedPosition => _bufferedPosition;
  bool get isPlaying => _state == PlaybackState.playing;

  /// Mini / notification chrome follows the last play/pause intent. Windows
  /// Bilibili Mini can emit audio while `_state` is still loading and Dart
  /// `isPlaying` stays false under cache-pause.
  bool get isTransportPlaying =>
      _session.desiredPlaying &&
      _state != PlaybackState.error &&
      _state != PlaybackState.idle;

  /// Mini/notification page entry must not call [resume] just because Dart
  /// `isPlaying` is false. Windows cache-pause leaves that flag false while
  /// audio is already running; resume() used to pause+seek and hitch the AO.
  static bool shouldResumeOnPageAdopt({
    required bool desiredPlaying,
    required PlaybackState state,
  }) {
    return desiredPlaying && state == PlaybackState.paused;
  }

  /// The activity came back and the native player is stopped, but the session
  /// still wants audio. Resume that transport instead of leaving a surprise
  /// pause. Do not pause a player that is running: a stale "paused" intent
  /// used to cut off headphone playback the moment the app was opened.
  @visibleForTesting
  static bool shouldRestoreTransportOnForeground({
    required bool desiredPlaying,
    required PlaybackState state,
    required bool controllerReady,
    required bool controllerPlaying,
  }) {
    if (!desiredPlaying || !controllerReady || controllerPlaying) return false;
    return state == PlaybackState.playing || state == PlaybackState.paused;
  }

  /// Pause only a session that is actually supposed to be paused. Do not infer
  /// from Dart isPlaying alone — a live Mini clock can disagree with it.
  static bool shouldPauseOnPageAdopt({
    required bool desiredPlaying,
    required PlaybackState state,
    required bool controllerPlaying,
  }) {
    if (desiredPlaying || state == PlaybackState.loading) return false;
    return state == PlaybackState.playing || controllerPlaying;
  }

  /// Resume point for a new native session.
  ///
  /// An explicit [startPosition] always wins, including [Duration.zero]
  /// (completed-item restart). Otherwise keep a restored/live same-item
  /// clock — restart Mini chrome publishes snapshot progress before
  /// `lastPositionMs` is on disk — then library progress.
  @visibleForTesting
  static Duration resolvePlayStartPosition({
    required Duration? startPosition,
    required String? currentItemId,
    required String itemId,
    required Duration currentPosition,
    Duration? trackedProgress,
    required int lastPositionMs,
  }) {
    if (startPosition != null) return startPosition;
    if (currentItemId == itemId && currentPosition > Duration.zero) {
      return currentPosition;
    }
    if (trackedProgress != null && trackedProgress > Duration.zero) {
      return trackedProgress;
    }
    if (lastPositionMs > 0) {
      return Duration(milliseconds: lastPositionMs);
    }
    return Duration.zero;
  }

  /// Pass the live/restored clock into [play] only when it is actually a
  /// resume point. `Duration.zero` must stay null so library progress can
  /// fill in after a process restart.
  static Duration? startPositionForCurrentSession({
    required String? currentItemId,
    required String itemId,
    required Duration currentPosition,
  }) {
    if (currentItemId != itemId) return null;
    return currentPosition > Duration.zero ? currentPosition : null;
  }

  bool get desiredPlaying => _session.desiredPlaying;

  /// Includes already-paused user/timer commands; automatic recovery must not
  /// supersede a newer pause merely because the public state did not change.
  int get pauseIntentRevision => _playbackPauseRevision;

  bool get hasPlaybackCompleted => _hasPlaybackCompleted;
  PlaybackSessionSnapshot get session => _session;
  int get sessionGeneration => _session.generation;

  @visibleForTesting
  LibraryWatchMeter get libraryWatchMeterForTesting => _watchMeter;

  @visibleForTesting
  Future<void> flushLibraryWatchForTesting() {
    return _commitWatchFlush(_watchMeter.flush());
  }

  @visibleForTesting
  Future<void> commitLibraryWatchFlushForTesting(LibraryWatchFlush flush) {
    return _commitWatchFlush(flush);
  }

  /// Hide must block unhide for the current watch cycle without stopping transport.
  void noteLibraryMediaHidden(String mediaId) {
    if (_watchMeter.mediaId == mediaId) {
      _watchMeter.noteHidden();
    }
  }

  bool get isSourceMissing => _isSourceMissing;
  List<BilibiliStreamQuality> get streamQualities => _streamQualities;
  List<BilibiliStreamQuality> _withCachedBilibiliQualities(
    VideoItem item,
    List<BilibiliStreamQuality> online,
  ) {
    final cached = MediaCacheHooks.qualities?.call(item) ?? [];
    if (cached.isEmpty) return List.unmodifiable(online);
    final qualities = <int, BilibiliStreamQuality>{
      for (final q in online) q.id: q,
    };
    for (final q in cached) {
      final id =
          int.tryParse(q.id) ??
          (q.id == 'legacy' ? BilibiliStreamQuality.localMaterializedId : null);
      if (id != null) {
        qualities[id] = BilibiliStreamQuality(
          id: id,
          label: q.label,
          cached: true,
        );
      }
    }
    return List.unmodifiable(qualities.values);
  }

  BilibiliStreamQuality? get selectedStreamQuality => _selectedStreamQuality;
  List<BilibiliAudioQuality> get streamAudioQualities => _streamAudioQualities;
  BilibiliAudioQuality? get selectedStreamAudioQuality =>
      _selectedStreamAudioQuality;
  double? get streamDisplayAspectRatio =>
      _streamDisplayAspectRatioItemId == _currentItem?.id
      ? _streamDisplayAspectRatio
      : null;

  void _setStreamDisplayAspectRatio(String? itemId, double? ratio) {
    _streamDisplayAspectRatioItemId = itemId;
    _streamDisplayAspectRatio = ratio;
  }

  /// Pages may still hold the old controller while the next source resolves.
  /// Only dimensions owned by this item can determine the new video rectangle.
  double? bilibiliVideoAspectRatioFor(
    String itemId, {
    VideoPlayerController? controller,
  }) {
    if (_currentItem?.id != itemId || !isCurrentItemBilibiliStream) return null;
    final stream = streamDisplayAspectRatio;
    if (stream != null && stream.isFinite && stream > 0) return stream;
    final geometry = bilibiliStartup?.geometry;
    if (geometry?.videoAspectRatio != null) return geometry!.videoAspectRatio;
    if (controller != null &&
        identical(_controller, controller) &&
        canMountControllerFor(itemId, controller: controller)) {
      final value = controller.value;
      final size = value.size;
      // video_player returns 1:1 for an initialized audio/probe player with
      // no video dimensions. That is a fallback, not this video's geometry.
      if (size.width.isFinite &&
          size.height.isFinite &&
          size.width > 0 &&
          size.height > 0) {
        final ratio = value.aspectRatio;
        if (ratio.isFinite && ratio > 0) return ratio;
      }
    }
    // Covers may be square or cropped independently of the video. Let the
    // page keep its neutral frame until this video's dimensions are known.
    return null;
  }

  void _onBilibiliGeometryChanged() {
    if (_bilibiliStartupItemId == _currentItem?.id &&
        isCurrentItemBilibiliStream) {
      notifyListeners();
    }
  }

  bool get isSwitchingStreamQuality => _isSwitchingStreamQuality;
  bool get isCurrentItemBilibiliStream =>
      _currentItem?.sourceRef?.kind == MediaSourceKind.bilibiliStream;

  /// Test hook for the progress-bar quality capsule without a live stream.
  @visibleForTesting
  void debugOverrideStreamQualityChrome({
    VideoItem? item,
    List<BilibiliStreamQuality> qualities = const [],
    BilibiliStreamQuality? selected,
    List<BilibiliAudioQuality> audioQualities = const [],
    BilibiliAudioQuality? selectedAudio,
    bool switching = false,
  }) {
    _currentItem = item;
    _streamQualities = List.unmodifiable(qualities);
    _selectedStreamQuality =
        selected ?? (qualities.isEmpty ? null : qualities.first);
    _isSwitchingStreamQuality = switching;
    _streamAudioQualities = List.unmodifiable(audioQualities);
    _selectedStreamAudioQuality = selectedAudio;
    notifyListeners();
  }

  bool get isCurrentItemOnlineBilibiliStream =>
      isCurrentItemBilibiliStream && _currentBilibiliPlayback != null;

  /// Online Bilibili card, including the prepare window before playurl commits.
  bool get isCurrentItemStreamingBilibiliCard =>
      isCurrentItemBilibiliStream &&
      _selectedStreamQuality?.isLocalMaterialized != true;

  /// Rolling gateway throughput for the active online Bilibili item.
  double get bilibiliGatewayBytesPerSecond => _bilibiliGatewayBytesPerSecond;

  /// Human-readable transfer rate for loading / buffering overlays.
  String? get bilibiliGatewaySpeedLabel =>
      formatTransferSpeedLabel(_bilibiliGatewayBytesPerSecond);

  /// Online Bilibili playback never paints a spinner. Connecting, seek, and
  /// cache-pause all used to flash the pink ring over a still frame. Download
  /// / cache progress stays on the download screen only.
  bool get isBilibiliBufferingOverlayVisible =>
      shouldShowBilibiliBufferingOverlay(
        isStreamingCard: isCurrentItemStreamingBilibiliCard,
        state: _state,
        coveringUntilFrame: _coveringUntilVisibleVideoFrame,
        controllerBuffering: _controllerIsBuffering,
        controllerPlaying: _controller?.value.isPlaying ?? false,
        seekHold: _seekHoldOverlay,
      );

  /// Signature kept so playback tests can still describe stalls that must
  /// not paint chrome. Arguments are intentionally unused.
  @visibleForTesting
  static bool shouldShowBilibiliBufferingOverlay({
    required bool isStreamingCard,
    required PlaybackState state,
    required bool coveringUntilFrame,
    required bool controllerBuffering,
    bool controllerPlaying = true,
    bool seekHold = false,
  }) {
    return false;
  }

  /// Fallback status line when throughput has not been measured yet.
  String get bilibiliBufferingStatusText {
    if (_state == PlaybackState.loading) return '正在连接...';
    if (_seekHoldOverlay || _pendingSeekRequestId != null) return '正在跳转...';
    return '缓冲中...';
  }

  @visibleForTesting
  static String? formatTransferSpeedLabel(double bytesPerSecond) {
    if (!bytesPerSecond.isFinite || bytesPerSecond <= 0) return null;
    if (bytesPerSecond >= 1024 * 1024) {
      return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    }
    if (bytesPerSecond >= 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${bytesPerSecond.round()} B/s';
  }

  /// Clock for floating subtitles and the sidebar highlight.
  ///
  /// Use the same presented frame as music lyrics. The controller's cached
  /// position only advances on native polls and can still be before a cue's
  /// start while the audible playback has already crossed it. The shared
  /// clock also handles pause, buffering, rate changes and pending seeks.
  /// Keep the optimistic hop target until native has actually landed.
  Duration positionForSubtitleOverlay(Duration nativePosition) {
    if (_controller?.value.isInitialized == true &&
        _timelineClock.isInitialized) {
      return positionNotifier.value;
    }

    // Before the shared clock is ready, retain the native/hop fallback.
    final source = _lastSeekSource;
    if (!SubtitleHopSeekPolicy.shouldHoldSubtitleClockOnHop(
      lastSeekSource: source,
      now: DateTime.now(),
      lastHopSeekAt: _lastHopSeekAt,
      nativePosition: nativePosition,
      hopTarget: _lastRequestedSeekPosition ?? _position,
      hopSeekInFlight:
          (_hopSeekDispatchTimer?.isActive ?? false) ||
          (_pendingSeekRequestId != null &&
              SubtitleHopSeekPolicy.isHopSeekSource(source)),
    )) {
      return nativePosition;
    }
    return _position < Duration.zero ? Duration.zero : _position;
  }

  /// Position for the portrait progress bar.
  ///
  /// The page mounts the controller as soon as it is initialized, which is
  /// before the resume seek. [nativePosition] is still the open probe (zero)
  /// in that window. Returning it makes the thumb draw the bookmark, jump to
  /// the start, then jump back. Hold the service/library clock until native
  /// has actually arrived.
  Duration positionForProgressChrome(
    Duration nativePosition, {
    Duration libraryBookmark = Duration.zero,
  }) {
    final opening =
        _state == PlaybackState.loading || _initialPositionSeekInFlight;
    final held = PlaybackBehaviorPolicy.progressChromeHeldPosition(
      servicePosition: _position,
      libraryBookmark: libraryBookmark,
      allowLibraryBookmarkFallback: opening,
    );
    final followNative =
        PlaybackBehaviorPolicy.progressChromeShouldFollowNative(
          controllerReady: true,
          transportSeekPending:
              _pendingSeekRequestId != null ||
              _initialPositionSeekInFlight ||
              _progressChromeGuardHolds(nativePosition),
          sessionStillOpening: _state == PlaybackState.loading,
          nativePosition: nativePosition,
          heldPosition: held,
        );
    return PlaybackBehaviorPolicy.progressChromePosition(
      nativePosition: nativePosition,
      heldPosition: held,
      followNative: followNative,
    );
  }

  /// Same window as [_shouldIgnoreInitialPositionSample], without clearing
  /// the guard. Progress chrome reads this on every frame.
  bool _progressChromeGuardHolds(Duration sample) {
    if (_onlineStartup?.isPending == true) {
      return true;
    }
    final target = _initialPositionGuardTarget;
    final until = _initialPositionGuardUntil;
    if (target == null || until == null) return false;
    if (DateTime.now().isAfter(until)) return false;
    final deltaMs = sample.inMilliseconds - target.inMilliseconds;
    if (deltaMs >= -_seekVerificationToleranceMs &&
        deltaMs <= const Duration(seconds: 3).inMilliseconds) {
      return false;
    }
    return true;
  }

  /// Mini card can render from [currentItem] metadata without waiting for the
  /// native controller. Loading/paused restored bookmarks are visible immediately.
  /// The media-library switch hides it without changing the session.
  bool get shouldShowMiniPlaybackCard {
    _attachSettingsListener();
    if (_currentItem == null && queuedPreviewItem != null) {
      return SettingsService().showMiniPlaybackCard;
    }
    return isMiniPlaybackCardVisible(
      currentItem: _currentItem,
      state: _state,
      enabled: SettingsService().showMiniPlaybackCard,
    );
  }

  /// A user may assemble a queue before playing anything. Mini exposes that
  /// queue without selecting media, loading a controller or starting playback.
  VideoItem? get queuedPreviewItem =>
      currentItem ??
      (_playlistManager?.hasManualQueue == true
          ? _playlistManager?.currentItem ??
                _playlistManager?.playbackQueue.firstOrNull
          : null);

  /// Whether the active native controller is safe for a playback page to
  /// mount, even while the session is still waiting for its first video frame.
  ///
  /// `loading` describes playback readiness, not controller availability. A
  /// visible media_kit output may need to be mounted before its first rendered
  /// frame can arrive, so pages must not use the state alone as a mount gate.
  /// Mini/notification Bilibili is audio-first and may not have a Flutter
  /// texture yet; mounting that same Player avoids play() reopening the stream.
  bool get hasMountableController {
    final controller = _controller;
    final item = _currentItem;
    if (controller == null ||
        item == null ||
        _controllerItemId != item.id ||
        !identical(controller, _sessionController) ||
        _session.itemId != item.id ||
        !(_session.isControllerMountable ||
            _session.phase == PlaybackSessionPhase.videoOutputDeferred)) {
      return false;
    }
    try {
      return controller.value.isInitialized &&
          !controller.value.hasError &&
          (_controllerHasMountableVideoOutput(item, controller));
    } catch (_) {
      return false;
    }
  }

  bool canMountControllerFor(
    String itemId, {
    VideoPlayerController? controller,
  }) {
    final candidate = controller ?? _controller;
    if (candidate == null ||
        !identical(candidate, _controller) ||
        _controllerItemId != itemId ||
        _currentItem?.id != itemId ||
        _session.itemId != itemId ||
        !identical(candidate, _sessionController) ||
        !(_session.isControllerMountable ||
            _session.phase == PlaybackSessionPhase.videoOutputDeferred)) {
      return false;
    }
    try {
      if (!candidate.value.isInitialized || candidate.value.hasError) {
        return false;
      }
      return _controllerHasMountableVideoOutput(_currentItem!, candidate);
    } catch (_) {
      // Disposed controllers throw on .value; treat as unmountable so pages
      // detach instead of painting a white ErrorWidget in release builds.
      return false;
    }
  }

  /// True when the service already owns an initialized controller for [itemId]
  /// and only needs Bilibili video-track re-enable or visible video-output
  /// recovery before a page can mount. Calling [play] here would reopen the
  /// stream and stall on a second prepare cycle.
  bool shouldDeferPlayForActiveSession(String itemId) {
    if (_currentItem?.id != itemId || hasMountableController) return false;
    if (_state == PlaybackState.loading ||
        _state == PlaybackState.idle ||
        _state == PlaybackState.error) {
      return false;
    }
    final controller = _controller;
    if (controller == null) return false;
    try {
      return controller.value.isInitialized && !controller.value.hasError;
    } catch (_) {
      return false;
    }
  }

  bool _controllerHasMountableVideoOutput(
    VideoItem item,
    VideoPlayerController controller,
  ) {
    if (item.type == MediaType.audio || kIsWeb) return true;
    // Mounting an existing texture must not wait for its replacement Surface.
    // ignore: invalid_use_of_visible_for_testing_member
    final nativePlayerId = controller.playerId;
    return NativeVideoPlayerMediaKit.hasRegisteredVideoOutputFor(
              nativePlayerId,
            ) !=
            false ||
        item.sourceRef?.kind == MediaSourceKind.bilibiliStream;
  }

  bool _controllerHasRequiredVideoOutput(
    VideoItem item,
    VideoPlayerController controller,
  ) {
    if (item.type == MediaType.audio || kIsWeb) return true;
    // ignore: invalid_use_of_visible_for_testing_member
    return NativeVideoPlayerMediaKit.hasVideoOutputFor(controller.playerId) !=
        false;
  }

  int _beginPlaybackSession(VideoItem item, {required bool desiredPlaying}) {
    _cancelVisibleOutputRecovery();
    final generation = ++_sessionGeneration;
    _sessionController = null;
    _session = PlaybackSessionSnapshot(
      generation: generation,
      itemId: item.id,
      phase: PlaybackSessionPhase.resolving,
      desiredPlaying: desiredPlaying,
      controllerGeneration: _controllerGeneration,
      hasVideoOutput: false,
    );
    return generation;
  }

  /// Publishes thumbnail/title/duration/progress before native prepare starts.
  /// Restore uses this so Mini playback card can appear from local metadata.
  /// A live session is left untouched.
  void publishRestoredSessionPreview(VideoItem item, Duration position) {
    if (!communityMediaIsPlayable(item.path, source: item.sourceRef)) return;
    item = _communityPlaybackItem(item);
    if (_currentItem != null || _controller != null) return;
    final loadingDuration = Duration(
      milliseconds: item.durationMs > 0 ? item.durationMs : 0,
    );
    final loadingPosition =
        PlaybackBehaviorPolicy.normalizeEpisodeStartPosition(
          savedPosition: position < Duration.zero ? Duration.zero : position,
          duration: loadingDuration,
        );
    _clearSubtitleStateForMediaSwitch();
    _currentItem = item;
    _isSourceMissing = false;
    _position = loadingPosition;
    _duration = loadingDuration;
    _bufferedPosition = Duration.zero;
    _resetPlaybackTimeline(loadingPosition, running: false);
    // Paused, not loading: the Mini card is a restored bookmark. Fetching
    // playurl here would delay chrome that only needs local metadata.
    _state = PlaybackState.paused;
    _beginPlaybackSession(item, desiredPlaying: false);
    _syncWakelockWithState();
    // The bookmark's selected subtitles are local assets too. Do not wait for
    // a decoder, feed refresh, cloud login or media URL to show the saved line.
    unawaited(_refreshKnownSubtitlesForCurrentItem(item));
    notifyListeners();
  }

  /// Remote bookmarks render from local metadata. Only local files can prepare
  /// a native player during restore without depending on network availability.
  static bool shouldPrepareNativePlayerOnRestore(VideoItem item) =>
      communityMediaIsLocal(item.path);

  /// Opens a restored online item in the background, paused at [position].
  ///
  /// Mini chrome is already on screen. Doing this work at launch means opening
  /// the card does not wait on playurl, TLS and a cold decoder. Failure leaves
  /// the bookmark in place so the card can retry.
  Future<void> warmRestoredOnlinePlayback(VideoItem item, Duration position) =>
      Future<void>.value();

  /// A Mini-card open must not start a second play while restore is already
  /// preparing this item. That second call cancels the in-flight open and can
  /// drop the saved position.
  static bool shouldStartPlayWhenOpeningMiniSession({
    required bool hasController,
    required PlaybackState state,
  }) {
    if (hasController) return false;
    return state != PlaybackState.loading;
  }

  void _transitionPlaybackSession(
    int generation,
    PlaybackSessionPhase phase, {
    VideoPlayerController? controller,
    bool? desiredPlaying,
    String? error,
  }) {
    if (_session.generation != generation) return;
    var controllerGeneration = _session.controllerGeneration;
    var hasVideoOutput = _session.hasVideoOutput;
    if (controller != null) {
      if (!identical(_sessionController, controller)) {
        _sessionController = controller;
        controllerGeneration = ++_controllerGeneration;
      }
      final item = _currentItem;
      hasVideoOutput =
          item != null &&
          item.id == _session.itemId &&
          _controllerHasRequiredVideoOutput(item, controller);
    } else if (phase == PlaybackSessionPhase.missing ||
        phase == PlaybackSessionPhase.failed ||
        phase == PlaybackSessionPhase.stopped ||
        phase == PlaybackSessionPhase.idle) {
      _sessionController = null;
      hasVideoOutput = false;
    }
    _session = _session.copyWith(
      phase: phase,
      desiredPlaying: desiredPlaying,
      controllerGeneration: controllerGeneration,
      hasVideoOutput: hasVideoOutput,
      error: error,
      clearError: error == null,
    );
  }

  void _setDesiredPlaying(bool value) {
    if (_onlineStartup != null && !_onlineStartup!.isCancelled) {
      _onlineStartup!.desiredPlaying = value;
    }
    if (_bilibiliVisibleStartup != null) {
      _bilibiliVisibleStartup!.desiredPlaying = value;
    }
    _session = _session.copyWith(desiredPlaying: value);
  }

  bool _isControllerReadyForItem(VideoItem item) {
    final controller = _controller;
    if (_currentItem?.id != item.id ||
        controller == null ||
        !identical(controller, _sessionController) ||
        _session.itemId != item.id ||
        !_session.isControllerMountable ||
        !controller.value.isInitialized ||
        controller.value.hasError ||
        _state == PlaybackState.error ||
        _state == PlaybackState.loading) {
      return false;
    }
    // A background Android video intentionally has no Flutter texture, but its
    // native media clock is already a complete playback session. Requiring a
    // mountable texture here made every notification skip retry the entire
    // source up to three times, including three opens and three seeks. Only a
    // genuinely visible page requires video output before the request is done.
    if (playbackRequestNeedsVideoOutput(
          isVideo: item.type == MediaType.video,
          hasVisiblePlaybackPage: _hasVisiblePlaybackPage,
        ) &&
        !_controllerHasRequiredVideoOutput(item, controller)) {
      return false;
    }
    if (!_session.desiredPlaying) return _state == PlaybackState.paused;
    if (_state != PlaybackState.playing) return false;
    if (_onlineStartup?.isReady == true) return true;
    return !_hasVisiblePlaybackPage || controller.value.isPlaying;
  }

  /// Makes the latest session intent authoritative after any asynchronous
  /// initialize/play/readiness work. Notification and mini-player commands
  /// are allowed to change that intent while a media switch is in flight.
  Future<bool> _commitControllerPlaybackIntent({
    required int sessionGeneration,
    required int playRequestId,
    required VideoItem item,
    required VideoPlayerController controller,
  }) async {
    if (!_isCurrentPlayRequest(
      playRequestId,
      item.id,
      controller: controller,
    )) {
      return false;
    }
    final desiredPlaying = _session.generation == sessionGeneration
        ? _session.desiredPlaying
        : false;
    if (desiredPlaying && !controller.value.isPlaying) {
      await controller.play();
    } else if (!desiredPlaying) {
      // Always send pause for a pause-on-switch request. The Dart value can
      // lag the native player by one event while open/seek is completing;
      // checking isPlaying here allowed a few native packets to escape even
      // though the switch setting was off.
      await controller.pause();
    }
    if (!_isCurrentPlayRequest(
      playRequestId,
      item.id,
      controller: controller,
    )) {
      return false;
    }

    _lastControllerIsPlaying = controller.value.isPlaying;
    _state = desiredPlaying ? PlaybackState.playing : PlaybackState.paused;
    _resetPlaybackTimeline(
      _position,
      running: desiredPlaying && controller.value.isPlaying,
    );
    if (desiredPlaying) {
      _startProgressTracking();
    } else {
      _stopProgressTracking();
    }
    _transitionPlaybackSession(
      sessionGeneration,
      _controllerHasRequiredVideoOutput(item, controller)
          ? PlaybackSessionPhase.ready
          : PlaybackSessionPhase.videoOutputDeferred,
      controller: controller,
      desiredPlaying: desiredPlaying,
    );
    _syncWakelockWithState();
    notifyListeners();
    return true;
  }

  @visibleForTesting
  static bool playbackRequestNeedsVideoOutput({
    required bool isVideo,
    required bool hasVisiblePlaybackPage,
  }) {
    return isVideo && hasVisiblePlaybackPage;
  }

  /// True when an existing session needs a usable video binding or transport,
  /// including an output reclaimed after initialization and audio-primary Bilibili.
  bool needsVisibleVideoOutputRecovery(String itemId) {
    final item = _currentItem;
    final controller = _controller;
    if (item == null ||
        item.id != itemId ||
        controller == null ||
        !controller.value.isInitialized) {
      return false;
    }
    if (_bilibiliAudioPrimaryPlayer &&
        item.sourceRef?.kind == MediaSourceKind.bilibiliStream) {
      return true;
    }
    // A timed-out native command lane must never be reused as a healthy player.
    // ignore: invalid_use_of_visible_for_testing_member
    if (NativeVideoPlayerMediaKit.transportUsableFor(controller.playerId) ==
        false) {
      return true;
    }
    if (kIsWeb || item.type != MediaType.video) {
      return false;
    }
    return NativeVideoPlayerMediaKit.hasVideoOutputFor(
          // ignore: invalid_use_of_visible_for_testing_member
          controller.playerId,
        ) ==
        false;
  }

  /// Confirms playback, allowing a degraded background native clock.
  /// Podcast decoder errors and a clock that never starts remain failures.
  ///
  /// Mini/notification must not be parked paused just because Dart `isPlaying`
  /// never flipped (Windows cache-pause). An unconfirmed background clock is
  /// treated as started so the play button and AO stay in agreement.
  Future<_PlaybackReadinessResult> _awaitPlaybackReadinessResult({
    required VideoItem item,
    required VideoPlayerController controller,
    required int playRequestId,
    Duration? playbackOrigin,
  }) async {
    if (_isOnlineMedia(item) && _onlineStartup?.isReady == true) {
      return _PlaybackReadinessResult.confirmed;
    }
    if (item.sourceRef?.kind == MediaSourceKind.podcastEpisode) {
      // play() and isPlaying only acknowledge intent. A cold network decoder
      // can report both successfully without ever producing audio.
      final origin = playbackOrigin ?? controller.value.position;
      var clockStarted = false;
      for (var sample = 0; sample < 120; sample++) {
        if (!_isCurrentPlayRequest(
              playRequestId,
              item.id,
              controller: controller,
            ) ||
            !_session.desiredPlaying) {
          return _PlaybackReadinessResult.confirmed;
        }
        if (controller.value.hasError) {
          throw StateError(controller.value.errorDescription ?? '播客播放失败');
        }
        final actual = await _readNativeControllerPosition(controller);
        if (!controller.value.isBuffering &&
            actual - origin >= const Duration(milliseconds: 30)) {
          clockStarted = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (!clockStarted) {
        throw TimeoutException('播客未能开始播放，请检查网络后重试。');
      }
      if (item.type != MediaType.video) {
        return _PlaybackReadinessResult.confirmed;
      }
    }
    // Audio-primary Mini sessions have no video frames. Waiting for first-frame
    // here parked the clock for 12s when a playback page opened mid-load.
    if (!_hasVisiblePlaybackPage || _bilibiliAudioPrimaryPlayer) {
      final playbackReady = NativeVideoPlayerMediaKit.playbackReadyFor(
        // ignore: invalid_use_of_visible_for_testing_member
        controller.playerId,
      );
      if (playbackReady == null) {
        return _PlaybackReadinessResult.confirmed;
      }
      final ready = await playbackReady.timeout(
        const Duration(milliseconds: 400),
        onTimeout: () => true,
      );
      if (controller.value.hasError) {
        return _PlaybackReadinessResult.degraded;
      }
      // Windows split-stream Mini keeps Dart isPlaying false under
      // cache-pause. Timing out used to park paused over a live AO, so the
      // play button never flipped. Audio already started; treat as confirmed.
      if (!ready) {
        _logPlaybackEvent(
          'background playback clock unconfirmed; keeping play intent',
          data: <String, Object?>{
            'itemId': item.id,
            'positionMs': _position.inMilliseconds,
          },
        );
      }
      return _PlaybackReadinessResult.confirmed;
    }
    if (item.type != MediaType.video) {
      return _PlaybackReadinessResult.confirmed;
    }
    // Re-selecting a split Bilibili video track is asynchronous. Waiting for
    // a Flutter texture before that command finishes times out, then parks a
    // session whose audio is already running.
    if (item.sourceRef?.kind == MediaSourceKind.bilibiliStream) {
      await _awaitBilibiliVideoTrackPolicy();
      if (!_isCurrentPlayRequest(
        playRequestId,
        item.id,
        controller: controller,
      )) {
        return _PlaybackReadinessResult.confirmed;
      }
      // Mini→page promotion holds a visibility owner before VideoPlayer is
      // mounted. Blocking on first-frame here froze the page for 12s.
      _beginCoveringUntilVisibleVideoFrame();
      final firstFrame = NativeVideoPlayerMediaKit.firstFrameRenderedFor(
        // ignore: invalid_use_of_visible_for_testing_member
        controller.playerId,
      );
      if (firstFrame == null) {
        _endCoveringUntilVisibleVideoFrame();
      } else {
        final coverEpoch = _visibleVideoFrameEpoch;
        unawaited(() async {
          try {
            await firstFrame.timeout(_firstVideoFrameTimeout);
          } catch (_) {}
          if (coverEpoch == _visibleVideoFrameEpoch) {
            _endCoveringUntilVisibleVideoFrame(immediate: true);
          }
        }());
      }
      return _PlaybackReadinessResult.confirmed;
    }
    _beginCoveringUntilVisibleVideoFrame();
    final firstFrame = NativeVideoPlayerMediaKit.firstFrameRenderedFor(
      // ignore: invalid_use_of_visible_for_testing_member
      controller.playerId,
    );
    if (firstFrame == null) {
      _endCoveringUntilVisibleVideoFrame();
      return _PlaybackReadinessResult.confirmed;
    }

    try {
      await firstFrame.timeout(_firstVideoFrameTimeout);
      _endCoveringUntilVisibleVideoFrame(immediate: true);
      return _PlaybackReadinessResult.confirmed;
    } on TimeoutException {
      if (!_isCurrentPlayRequest(
        playRequestId,
        item.id,
        controller: controller,
      )) {
        _endCoveringUntilVisibleVideoFrame(immediate: true);
        return _PlaybackReadinessResult.confirmed;
      }
      _logPlaybackEvent(
        'first video frame timed out; recovering decoder output',
        data: <String, Object?>{'itemId': item.id},
      );
    }

    final recovered = await NativeVideoPlayerMediaKit.recoverVideoOutputFor(
      // ignore: invalid_use_of_visible_for_testing_member
      controller.playerId,
    ).timeout(_controllerInitializeTimeout, onTimeout: () => false);
    if (recovered) {
      await firstFrame.timeout(_firstVideoFrameTimeout);
      _endCoveringUntilVisibleVideoFrame(immediate: true);
      return _PlaybackReadinessResult.confirmed;
    }

    final nativeClockPlaying = controller.value.isPlaying;
    if (item.sourceRef?.kind == MediaSourceKind.bilibiliStream ||
        !shouldParkWhenVisibleVideoFrameMissing(
          nativeClockPlaying: nativeClockPlaying,
        )) {
      // Audio is already running, or this is a Mini→page promotion whose
      // VideoPlayer has not mounted yet. Parking froze the playback page.
      _logPlaybackEvent(
        'video decoder produced no frame; keeping running session',
        data: <String, Object?>{'itemId': item.id},
      );
      _endCoveringUntilVisibleVideoFrame();
      return _PlaybackReadinessResult.confirmed;
    }
    _logPlaybackEvent(
      'video decoder produced no frame; parking session as paused',
      data: <String, Object?>{'itemId': item.id},
    );
    try {
      if (controller.value.isPlaying) await controller.pause();
    } catch (_) {}
    _endCoveringUntilVisibleVideoFrame(immediate: true);
    return _PlaybackReadinessResult.degraded;
  }

  void _primeDeferredVideoOutput(
    VideoItem item,
    VideoPlayerController controller,
  ) {
    // Split Bilibili stays audio-only off-page only when the user opted into
    // background data saving. Otherwise keep decoding video so Mini/notification
    // can open the playback page on the live picture.
    if (item.sourceRef?.kind == MediaSourceKind.bilibiliStream &&
        shouldDeferBilibiliVideoOnOpen(
          hasVisiblePlaybackPage: _hasVisiblePlaybackPage,
          backgroundAudioOnly: SettingsService().bilibiliBackgroundAudioOnly,
        )) {
      return;
    }
    if (!needsVisibleVideoOutputRecovery(item.id)) return;
    // Start render-output creation while the notification-controlled session
    // is still in the background. This is intentionally non-blocking: audio
    // playback and command acknowledgement must not wait for Flutter texture
    // work, but foreground entry can join the same pending attachment.
    // ignore: invalid_use_of_visible_for_testing_member
    final playerId = controller.playerId;
    unawaited(
      NativeVideoPlayerMediaKit.attachVideoOutputFor(playerId).then((attached) {
        if (!attached ||
            _currentItem?.id != item.id ||
            !identical(_controller, controller) ||
            controller.value.hasError) {
          return;
        }
        _transitionPlaybackSession(
          _session.generation,
          _state == PlaybackState.loading
              ? PlaybackSessionPhase.controllerMountable
              : PlaybackSessionPhase.ready,
          controller: controller,
          desiredPlaying: _session.desiredPlaying,
        );
        notifyListeners();
        _logPlaybackEvent(
          'background video output primed on existing player',
          data: <String, Object?>{'itemId': item.id, 'playerId': playerId},
        );
      }),
    );
  }

  /// Restores the current output before attempting one controlled reopen.
  /// Both attempts share a deadline and preserve the latest transport intent.
  void _cancelVisibleOutputRecovery() {
    _visibleOutputOperation?.cancel();
    _visibleOutputOperation = null;
    _visibleOutputController = null;
    _visibleOutputSession = null;
    _visibleVideoOutputRecovery = null;
  }

  Future<bool> ensureVisibleVideoOutput(String itemId) {
    final item = _currentItem;
    final controller = _controller;
    if (item?.id != itemId || controller == null) return Future.value(false);
    final existing = _visibleVideoOutputRecovery;
    if (existing != null &&
        identical(_visibleOutputController, controller) &&
        _visibleOutputSession == _session.generation &&
        _visibleOutputOperation?.isPending == true) {
      return existing;
    }
    if (!needsVisibleVideoOutputRecovery(itemId)) {
      return Future.value(!controller.value.hasError);
    }
    _cancelVisibleOutputRecovery();
    final generation = _session.generation;
    final opening = _onlineStartup;
    final PlaybackStartupContext budget = opening?.isPending == true
        ? opening!.continueOnNewNetwork()
        : item!.sourceRef?.kind == MediaSourceKind.bilibiliStream
        ? BilibiliStartupContext(limit: debugRecoveryLimit)
        : PlaybackStartupContext(limit: debugRecoveryLimit);
    budget.target = _position;
    _visibleOutputOperation = budget;
    _visibleOutputController = controller;
    _visibleOutputSession = generation;
    final result = Completer<bool>();
    final recovery = result.future;
    _visibleVideoOutputRecovery = recovery;
    bool current() =>
        !_presentationDisposed &&
        _session.generation == generation &&
        _currentItem?.id == itemId &&
        identical(_controller, controller) &&
        !budget.isCancelled;
    unawaited(
      () async {
        try {
          // ignore: invalid_use_of_visible_for_testing_member
          final playerId = controller.playerId;
          var attached = false;
          if (!_bilibiliAudioPrimaryPlayer &&
              NativeVideoPlayerMediaKit.transportUsableFor(playerId) != false) {
            try {
              attached = await budget.run(
                NativeVideoPlayerMediaKit.attachVideoOutputFor(playerId),
                cap: debugOutputAttachLimit,
              );
              if (!current()) return false;
              if (attached) {
                budget.target = _position;
                final frame = NativeVideoPlayerMediaKit.preparedForPlayback(
                  playerId,
                  budget,
                  videoRequired: () => _hasVisiblePlaybackPage,
                );
                if (frame != null) {
                  await budget.run(frame, cap: debugOutputAttachLimit);
                }
                attached =
                    NativeVideoPlayerMediaKit.hasVideoOutputFor(playerId) !=
                    false;
              }
            } on TimeoutException {
              attached = false;
            }
          }
          if (!current()) return false;
          if (attached && !controller.value.hasError) {
            budget.ready();
            _endCoveringUntilVisibleVideoFrame(immediate: true);
            _transitionPlaybackSession(
              generation,
              _state == PlaybackState.loading
                  ? PlaybackSessionPhase.controllerMountable
                  : PlaybackSessionPhase.ready,
              controller: controller,
            );
            notifyListeners();
            return true;
          }
          _logPlaybackEvent(
            'visible output attachment failed',
            data: {'itemId': itemId},
          );
          if (!_isAppInForeground || isEpisodeNavigationBusy) return false;
          budget.check();
          // Detach ownership before play() begins its successor session. Both
          // attempts retain this deadline; old output callbacks retain the old Player.
          final continuation = budget.continueOnNewNetwork();
          if (continuation is BilibiliStartupContext) {
            prepareBilibiliStartup(itemId, continuation);
          } else {
            _pendingOnlineStartup = (itemId: itemId, context: continuation);
          }
          _visibleOutputOperation = null;
          _visibleOutputController = null;
          _logPlaybackEvent(
            'reopening media with preserved position',
            data: {'itemId': itemId},
          );
          await budget.run(
            play(
              item!,
              startPosition: _position,
              autoPlay: _session.desiredPlaying,
              forceRecreate: true,
              bilibiliQualityId: _selectedStreamQuality?.id,
              cloudDriveQualityId: _selectedCloudDriveQualityId,
              userInitiatedWatch: false,
            ),
          );
          budget.ready();
          return _currentItem?.id == itemId &&
              _controller != null &&
              _state != PlaybackState.error &&
              !needsVisibleVideoOutputRecovery(itemId);
        } on BilibiliStartupCancelled {
          return false;
        } catch (error) {
          budget.fail(error);
          if (current()) {
            _bilibiliVisibleStartup?.fail(error);
            _state = PlaybackState.error;
            _stopProgressTracking();
            _transitionPlaybackSession(
              generation,
              PlaybackSessionPhase.failed,
              desiredPlaying: false,
              error: '画面恢复失败，请重试：$error',
            );
            _endCoveringUntilVisibleVideoFrame(immediate: true);
            notifyListeners();
          }
          return false;
        } finally {
          if (identical(_visibleVideoOutputRecovery, recovery)) {
            _visibleVideoOutputRecovery = null;
            _visibleOutputOperation = null;
            _visibleOutputController = null;
            _visibleOutputSession = null;
          }
        }
      }().then(
        result.complete,
        onError: (Object error, StackTrace stack) {
          result.completeError(error, stack);
        },
      ),
    );
    return recovery;
  }

  /// Whether an item can be opened without first asking the user to restore
  /// its source. Online Bilibili cards are virtual sources; every other item
  /// follows the same local-file requirement used by [play].
  bool hasUsableSource(VideoItem item) {
    final manager = _playlistManager;
    if (manager != null) return manager.isQueueEligible(item);
    return PlaybackQueuePolicy().isEligible(item);
  }

  VideoItem? _findPlayableRelative({
    required bool next,
    bool wrap = false,
    bool includeCurrentAfterWrap = false,
  }) {
    return _playlistManager?.relativeItem(
      next: next,
      wrap: wrap,
      includeCurrentAfterWrap: includeCurrentAfterWrap,
    );
  }

  PlaylistManager? get playlistManager => _playlistManager;
  PlaybackMode get playbackMode =>
      _playlistManager?.playbackMode ?? PlaybackMode.sequential;
  bool get automaticQueueContinuation =>
      _currentItem?.sourceRef?.podcast != null
      ? PodcastPlaybackHooks.continuous?.call(_currentItem!) ?? false
      : SettingsService().autoPlayOnCompletion;

  String? queueItemStatus(String itemId) {
    if (itemId == _currentItem?.id) {
      return playbackMode == PlaybackMode.repeatOne ? '循环中' : '播放中';
    }
    if (itemId != nextPlayableItem?.id) return null;
    return playbackMode != PlaybackMode.repeatOne &&
            (automaticQueueContinuation || sleepTimer.tracksItemCompletion)
        ? '自动连播已开启'
        : '自动连播已关闭';
  }

  Map<String, String> get queueItemStatuses {
    final currentId = _currentItem?.id;
    final nextId = nextPlayableItem?.id;
    final statuses = <String, String>{};
    if (currentId != null) statuses[currentId] = queueItemStatus(currentId)!;
    if (nextId != null && nextId != currentId) {
      statuses[nextId] = queueItemStatus(nextId)!;
    }
    return statuses;
  }

  PlaybackMode? _lastQueueMode;
  int _playbackPauseRevision = 0;
  Future<void>? _previewPlaybackTail;

  @visibleForTesting
  bool get hasPendingPreviewForTest => _previewPlaybackTail != null;
  bool? _lastQueueWrap;
  bool? _lastAutomaticQueueContinuation;
  String? _lastQueueNextId;

  void _onPlaybackQueueChanged() {
    final mode = playbackMode;
    final nextId = nextPlayableItem?.id;
    if (_lastQueueMode != mode || _lastQueueNextId != nextId) {
      _lastQueueMode = mode;
      _lastQueueNextId = nextId;
      _preloadTriggered = false;
      unawaited(_disposePreloadedController());
      _prefetchNeighborBilibiliStreams(replaceStale: false);
    }
    notifyListeners();
  }

  bool get _playlistWrapToFirstEnabled => SettingsService().playlistWrapToFirst;

  VideoItem? get nextPlayableItem =>
      _findPlayableRelative(next: true, wrap: _playlistWrapToFirstEnabled);
  VideoItem? get previousPlayableItem =>
      _findPlayableRelative(next: false, wrap: _playlistWrapToFirstEnabled);
  bool get hasPlayableNext => _cloudQueuePending || nextPlayableItem != null;
  bool get hasPlayablePrevious =>
      _cloudQueuePending || previousPlayableItem != null;

  /// True while an episode-switch command is queued or executing. Foreground
  /// recovery (visible-output reopen) must not interleave with it.
  bool get isEpisodeNavigationBusy =>
      _isDrainingEpisodeNavigation || _pendingEpisodeNavigation.isNotEmpty;
  bool get isMuted => _isMuted;
  double get volume => _volume;
  double get playbackSpeed => _playbackSpeed;
  double get confirmedPlaybackSpeed => _confirmedPlaybackSpeed;
  bool get isTemporaryPlaybackSpeedActive =>
      _temporaryPlaybackBaseSpeed != null;
  VideoPlayerController? get controller => _controller;
  List<SubtitleItem> get subtitles => _subtitles;
  List<SubtitleItem> get secondarySubtitles => _secondarySubtitles;
  List<String> get subtitlePaths => _subtitlePaths;
  int get subtitleRevision => _subtitleRevision;
  bool get isLoadingSubtitles => _isLoadingSubtitles;
  SubtitleItem? get currentSubtitle => _currentSubtitle;

  /// Reuses the playback index for notification text and boundary scheduling.
  /// Uses the media timeline and the existing gap-filling lookup semantics.
  SubtitleItem? subtitleAtPosition(Duration position) =>
      _subtitleTimeline.subtitleAt(position);

  Duration? nextSubtitleBoundaryAfter(Duration position) =>
      _subtitleTimeline.nextBoundaryAfter(position);

  /// 初始化服务依赖
  Future<void> initialize({
    required PlaylistManager playlistManager,
    required ProgressTracker progressTracker,
    LibraryService? libraryService,
    EmbeddedSubtitleService? embeddedSubtitleService,
    BilibiliStreamingService? bilibiliStreamingService,
    NetworkSettingsService? networkSettings,
  }) async {
    _playlistManager?.removeListener(_onPlaybackQueueChanged);
    _playlistManager = playlistManager;
    // Restoring the small queue preference must not hold up opening a player.
    // The manager reconciles it with the live cursor and rejects a stale
    // restore if the user has already selected another mode.
    unawaited(playlistManager.initializePlaybackModes());
    _lastQueueMode = playlistManager.playbackMode;
    playlistManager.addListener(_onPlaybackQueueChanged);
    _progressTracker = progressTracker;
    _libraryService = libraryService;
    _embeddedSubtitleService = embeddedSubtitleService;
    _bilibiliStreamingService = bilibiliStreamingService;
    _attachBilibiliStreamingListener();
    _attachPlaybackMaterializedListener();
    _attachSettingsListener();
    await _networkSubscription?.cancel();
    _networkSubscription = (networkSettings ?? NetworkSettingsService.instance)
        .changes
        .listen((change) {
          // Platform path callbacks also report quality and capability changes.
          // Keep both pending opens and healthy players alive; gateway/network
          // failure recovery reconnects a genuinely broken upstream in place.
          if (change.deviceChanged) return;
          final bilibili = change.scopes.contains(NetworkScope.bilibili);
          final cloud = change.scopes.contains(NetworkScope.cloudDrive);
          final item = _currentItem;
          if (!communityMediaIsPlayable(item?.path ?? '', source: item?.sourceRef)) {
            return;
          }
          if (item?.sourceRef?.kind == MediaSourceKind.bilibiliStream &&
              _currentMaterializedPlaybackLease != null) {
            // An offline representation owns no API/CDN connection to
            // reconnect, even while its local decoder is still preparing.
            return;
          }
          final podcastUri = Uri.tryParse(
            item?.sourceRef?.podcast?.mediaUrl ?? '',
          );
          final podcast =
              podcastUri != null &&
              podcastUri.hasScheme &&
              change.scopes.contains(NetworkSites.forPodcast(podcastUri));
          if (!bilibili && !cloud && !podcast) return;
          final opening = _bilibiliStartup;
          if (bilibili &&
              item != null &&
              item.sourceRef?.kind == MediaSourceKind.bilibiliStream &&
              opening?.isPending == true) {
            prepareBilibiliStartup(item.id, opening!.continueOnNewNetwork());
            unawaited(
              play(
                item,
                startPosition: opening.target,
                autoPlay: opening.desiredPlaying,
                forceRecreate: true,
                bilibiliQualityId: opening.qualityId,
                userInitiatedWatch: false,
              ),
            );
            return;
          }
          final cloudItem =
              item != null &&
              isCloudDriveMedia(source: item.sourceRef, path: item.path);
          final onlineOpening = _onlineStartup;
          if (item != null &&
              onlineOpening?.isPending == true &&
              (cloud && cloudItem || podcast)) {
            _pendingOnlineStartup = (
              itemId: item.id,
              context: onlineOpening!.continueOnNewNetwork(),
            );
            unawaited(
              play(
                item,
                startPosition: onlineOpening.target,
                autoPlay: onlineOpening.desiredPlaying,
                forceRecreate: true,
                cloudDriveQualityId: cloudItem
                    ? _selectedCloudDriveQualityId
                    : null,
                userInitiatedWatch: false,
              ),
            );
            return;
          }
          final healthy = _playbackSessionHealthyForRestore();
          final configurationChanged = !identical(
            change.previous,
            change.current,
          );
          final reopenCloud =
              cloud &&
              cloudItem &&
              shouldReopenCloudDrivePlayback(
                deviceChanged: change.deviceChanged,
                configurationChanged: configurationChanged,
                sessionHealthy: healthy,
              );
          final reopenBilibili =
              bilibili &&
              item?.sourceRef?.kind == MediaSourceKind.bilibiliStream &&
              shouldReopenCloudDrivePlayback(
                deviceChanged: change.deviceChanged,
                configurationChanged: configurationChanged,
                sessionHealthy: healthy,
              );
          _logPlaybackEvent(
            'network change while playing',
            data: <String, Object?>{
              'deviceChanged': change.deviceChanged,
              'configurationChanged': configurationChanged,
              'healthy': healthy,
              'reopenCloud': reopenCloud,
              'reopenBilibili': reopenBilibili,
              'itemId': item?.id,
            },
          );
          // Keep healthy native sessions across network/policy changes.
          // Their local gateways reconnect upstream without replacing playback.
          if (!reopenCloud && !reopenBilibili) return;
          _networkRecoveryGeneration++;
          if (reopenBilibili) _streamQualitySwitchRequestId++;
          if (reopenCloud) {
            final current = item;
            final position = _position;
            final playing = _session.desiredPlaying;
            unawaited(
              play(
                current,
                startPosition: position,
                autoPlay: playing,
                forceRecreate: true,
                userInitiatedWatch: false,
              ),
            );
          }
          if (!reopenBilibili) return;
          unawaited(
            _recoverPlaybackNetwork(
              _networkRecoveryGeneration,
              _streamSwitchStopped?.future,
            ),
          );
        });
    await _restorePersistedMuteState(notify: false);
    await sleepTimer.initialize(
      playbackListenable: this,
      isPlaybackRunning: () {
        final controller = _controller;
        return _state == PlaybackState.playing &&
            controller != null &&
            controller.value.isInitialized &&
            controller.value.isPlaying &&
            !controller.value.isBuffering;
      },
      onExpired: () => pause(),
    );
    _syncBilibiliCachePolicy();
  }

  void attachCloudDrivePlayback(CloudDrivePlaybackService service) {
    _cloudDrivePlayback = service;
  }

  Future<void> _rememberCloudDrivePlaybackCover(
    VideoItem item,
    VideoPlayerController controller,
  ) async {
    final library = _libraryService;
    if (item.sourceRef?.cloudDrive == null ||
        item.type != MediaType.video ||
        item.thumbnailPath != null ||
        library?.cloudDriveThumbnails == null) {
      return;
    }
    try {
      // This is the decoder's frame, excluding subtitle/UI overlays.
      // ignore: invalid_use_of_visible_for_testing_member
      final frame = NativeVideoPlayerMediaKit.firstFrameRenderedFor(
        // ignore: invalid_use_of_visible_for_testing_member
        controller.playerId,
      );
      if (frame == null) return;
      await frame.timeout(const Duration(seconds: 10));
      if (!identical(_controller, controller) || _currentItem?.id != item.id) {
        return;
      }
      // ignore: invalid_use_of_visible_for_testing_member
      final bytes = await NativeVideoPlayerMediaKit.ambientFrameFor(
        // ignore: invalid_use_of_visible_for_testing_member
        controller.playerId,
      ).timeout(const Duration(seconds: 3));
      if (bytes == null ||
          !identical(_controller, controller) ||
          _currentItem?.id != item.id) {
        return;
      }
      await library!.rememberCloudDrivePlaybackFrame(item, bytes);
    } catch (_) {
      // Cover generation never changes the playback outcome.
    }
  }

  List<CloudDriveQualityChoice> get cloudDriveQualities => _cloudDriveQualities;

  @visibleForTesting
  Future<bool> Function(String qualityId)? debugCloudQualitySwitchOverride;

  @visibleForTesting
  void debugSeedCloudDriveQualities(
    List<CloudDriveQualityChoice> qualities, {
    String? selectedId,
  }) {
    _cloudDriveQualities = List<CloudDriveQualityChoice>.unmodifiable(
      qualities,
    );
    _selectedCloudDriveQualityId =
        selectedId ?? (qualities.isEmpty ? null : qualities.first.id);
    notifyListeners();
  }

  @visibleForTesting
  void debugSeedCurrentItem(VideoItem? item) {
    _currentItem = item;
  }

  @visibleForTesting
  void debugAttachLibrary(LibraryService? library) {
    _libraryService = library;
  }

  /// Runs the automatic official-subtitle entry point exactly as playback
  /// does, without mounting a playback page or opening the subtitle panel.
  @visibleForTesting
  Future<CloudDriveAutoSubtitleOutcome> debugEnsureAutoOfficialSubtitle(
    VideoItem item,
  ) {
    return _ensureCloudDriveAutoSubtitle(item);
  }

  @visibleForTesting
  int get subtitleIntentGenerationForTest => subtitleSelectionRevision;

  int get subtitleSelectionRevision => _subtitleIntentGeneration;

  String? get selectedCloudDriveQualityId => _selectedCloudDriveQualityId;

  bool isCloudDriveAccountActive(String localAccountId) =>
      _currentCloudDriveLease?.accountLocalId == localAccountId &&
      _currentItem != null;

  /// The most recent switch, including the stage it reached. A cancelled or
  /// superseded request is not a failure and must not be shown as one.
  CloudDriveQualitySwitchOutcome? cloudDriveQualityOutcome;
  int _cloudDriveQualityOperationSeq = 0;

  /// Copy-diagnostics text: build identity, the last switch outcome and the
  /// gateway lines. Every line is already redacted.
  String get cloudDriveDiagnosticSummary {
    final buffer = StringBuffer(BuildIdentity.label);
    final outcome = cloudDriveQualityOutcome;
    if (outcome != null) buffer.write('\n${outcome.toDiagnosticLine()}');
    final report = _cloudDrivePlayback?.diagnosticText;
    if (report != null && report.isNotEmpty) buffer.write('\n$report');
    return buffer.toString();
  }

  Future<bool> switchCloudDriveQuality(String qualityId) async {
    final outcome = await switchCloudDriveQualityOutcome(qualityId);
    return outcome.succeeded;
  }

  Future<CloudDriveQualitySwitchOutcome> switchCloudDriveQualityOutcome(
    String qualityId,
  ) async {
    final operationId =
        'q${(++_cloudDriveQualityOperationSeq).toRadixString(16)}';
    final clock = Stopwatch()..start();
    var mark = 0;
    var stage = CloudDriveQualitySwitchStage.entry;
    final phases = <String, int>{};

    CloudDriveQualitySwitchOutcome finish(
      CloudDriveQualitySwitchResult result, {
      String? reason,
      String? errorType,
      String? errorDetail,
      String? actualQualityId,
      bool retryable = false,
    }) {
      final spent = clock.elapsedMilliseconds;
      phases[stage.name] = (phases[stage.name] ?? 0) + (spent - mark);
      mark = spent;
      final outcome = CloudDriveQualitySwitchOutcome(
        operationId: operationId,
        requestedQualityId: qualityId,
        actualQualityId: actualQualityId ?? _selectedCloudDriveQualityId,
        stage: stage,
        result: result,
        reason: reason == null || reason.isEmpty
            ? null
            : sanitizeCloudDriveQualityReason(reason),
        errorType: errorType,
        errorDetail: errorDetail == null
            ? null
            : sanitizeCloudDriveQualityReason(errorDetail),
        retryable: retryable,
        elapsedMs: spent,
        phases: Map<String, int>.unmodifiable(phases),
      );
      if (operationId ==
          'q${_cloudDriveQualityOperationSeq.toRadixString(16)}') {
        cloudDriveQualityOutcome = outcome;
      }
      developer.log(
        '${outcome.toDiagnosticLine()} ${BuildIdentity.label}',
        name: 'CloudDrive',
      );
      return outcome;
    }

    void phase(CloudDriveQualitySwitchStage next) {
      final now = clock.elapsedMilliseconds;
      final spent = now - mark;
      final from = stage;
      phases[from.name] = (phases[from.name] ?? 0) + spent;
      stage = next;
      mark = now;
      _logPlaybackEvent(
        'cloud quality phase',
        data: <String, Object?>{
          'op': operationId,
          'from': from.name,
          'stage': next.name,
          'ms': spent,
          'totalMs': now,
          'qualityId': qualityId,
        },
      );
    }

    final override = debugCloudQualitySwitchOverride;
    if (override != null) {
      final ok = await override(qualityId);
      stage = CloudDriveQualitySwitchStage.done;
      return finish(
        ok
            ? CloudDriveQualitySwitchResult.committed
            : CloudDriveQualitySwitchResult.failed,
      );
    }
    final item = _currentItem;
    final service = _cloudDrivePlayback;
    final previous = _controller;
    // The rung itself is checked first: "this quality is not usable" is a
    // different answer from "the player is not ready yet", and neither is a
    // switch failure.
    final selected = _cloudDriveQualities
        .where((choice) => choice.id == qualityId)
        .firstOrNull;
    if (selected != null && !selected.selectable) {
      final detail = selected.statusDetail ?? '这个画质暂时不可用';
      cloudDriveNotice = detail;
      notifyListeners();
      return finish(
        selected.availability == CloudDriveQualityAvailability.discovering
            ? CloudDriveQualitySwitchResult.notReady
            : CloudDriveQualitySwitchResult.unavailable,
        reason: detail,
        retryable: true,
      );
    }
    if (qualityId == _selectedCloudDriveQualityId) {
      return finish(
        CloudDriveQualitySwitchResult.alreadySelected,
        actualQualityId: qualityId,
      );
    }
    if (item == null) {
      return finish(
        CloudDriveQualitySwitchResult.notReady,
        reason: '当前没有正在播放的视频',
        retryable: true,
      );
    }
    if (service == null) {
      return finish(
        CloudDriveQualitySwitchResult.notReady,
        reason: '网盘播放服务尚未就绪，请稍后再试',
        retryable: true,
      );
    }
    if (previous == null || !previous.value.isInitialized) {
      return finish(
        CloudDriveQualitySwitchResult.notReady,
        reason: '播放器还在准备，请稍后再切换画质',
        retryable: true,
      );
    }
    final ticket = _cloudDriveQualitySwitch.begin();
    final sessionGeneration = _session.generation;
    var abandoned = false;

    CloudDrivePreparedPlayback? prepared;
    VideoPlayerController? next;
    var committed = false;
    var oldSilenced = false;
    var oldHeldForHandoff = false;
    final budget = CloudDrivePlaybackBudget();
    CloudDrivePlaybackLease? retireLease;
    VideoPlayerController? retireController;
    bool stale() =>
        abandoned ||
        !_cloudDriveQualitySwitch.isLatest(ticket) ||
        _currentItem?.id != item.id ||
        _session.generation != sessionGeneration ||
        !identical(_controller, previous);
    try {
      notifyListeners();
      phase(CloudDriveQualitySwitchStage.resolve);
      budget.ensure('resolve');
      final cancel = CloudDriveCancelToken();
      final opening = service.open(
        item,
        qualityId: qualityId,
        operationDeadline: budget.deadline,
        cancelToken: cancel,
      );
      prepared = await bindCloudDriveStage<CloudDrivePreparedPlayback>(
        future: opening,
        budget: budget.remaining(cloudDriveResolveCap),
        onTimeout: cancel.cancel,
        onLate: (value) => value.lease.release(),
      );
      phase(CloudDriveQualitySwitchStage.initialize);
      if (stale()) {
        _logPlaybackEvent(
          'cloud quality superseded',
          data: <String, Object?>{'op': operationId, 'stage': 'resolve'},
        );
        await prepared.lease.release();
        prepared = null;
        return finish(CloudDriveQualitySwitchResult.superseded);
      }
      final holdPreviousClock =
          prepared.lease.descriptor.transport ==
          CloudDriveTransport.progressive;
      if (holdPreviousClock && previous.value.isPlaying) {
        oldHeldForHandoff = true;
        await previous.pause();
      }
      final startMs = (await _readNativeControllerPosition(
        previous,
      )).inMilliseconds;
      budget.ensure('initialize');
      next = AppVideoPlayerController.networkUrl(
        prepared.lease.loopbackUri,
        httpHeaders: NativeVideoPlayerMediaKit.cloudDrivePlayerHeaders(
          hls: prepared.lease.descriptor.transport == CloudDriveTransport.hls,
          start: Duration(milliseconds: startMs),
        ),
        videoPlayerOptions: buildVideoPlayerOptions(),
      );
      await next.initialize().timeout(
        budget.remaining(cloudDriveInitializeCap),
      );
      phase(CloudDriveQualitySwitchStage.handoff);
      if (stale()) {
        _logPlaybackEvent(
          'cloud quality superseded',
          data: <String, Object?>{'op': operationId, 'stage': 'initialize'},
        );
        await prepared.lease.release();
        await next.dispose();
        prepared = null;
        next = null;
        return finish(CloudDriveQualitySwitchResult.superseded);
      }
      budget.ensure('handoff');
      final candidate = next;
      Future<void> prepareHandoff() async {
        for (var pass = 0; pass < 3; pass++) {
          // A full original stream may decode only at the account's real-time
          // download rate. Hold the visible frame while it warms instead of
          // requiring that source to outrun a much lighter transcode.
          if (holdPreviousClock && previous.value.isPlaying) {
            oldHeldForHandoff = true;
            await previous.pause();
          }
          final seekGeneration = _seekRequestId;
          await _prepareStreamQualityHandoff(
            controller: candidate,
            previousController: previous,
            isCurrent: () => !stale(),
            cloudDrive: true,
            onPhase: (name, elapsed) {
              phases[name] = (phases[name] ?? 0) + elapsed;
              _logPlaybackEvent(
                'cloud quality stage',
                data: <String, Object?>{
                  'op': operationId,
                  'stage': name,
                  'ms': elapsed,
                  'qualityId': qualityId,
                },
              );
            },
          );
          if (stale()) throw const _StreamQualityHandoffInterrupted();
          if (seekGeneration != _seekRequestId) continue;
          // Once decoded, align the muted candidate by its playback clock.
          // Seeking again on each pass discards the HLS window we just fetched
          // and chases an old player which has already moved on.
          if (holdPreviousClock) {
            await _synchronizePausedStreamQualityAtCommit(
              controller: candidate,
              previousController: previous,
              isCurrent: () => !stale(),
              toleranceMs: 500,
              cloudDrive: true,
            );
          } else {
            await _synchronizeStreamQualityAtCommit(
              controller: candidate,
              previousController: previous,
              isCurrent: () => !stale(),
              cloudDrive: true,
            );
          }
          if (seekGeneration == _seekRequestId) {
            return;
          }
          // A seek or slow decode moved the visible timeline during pre-roll.
          // Re-align within the same handoff deadline before publishing it.
        }
        throw StateError(
          'replacement stream did not align with current progress',
        );
      }

      await prepareHandoff().timeout(budget.remaining(cloudDriveHandoffCap));
      phase(CloudDriveQualitySwitchStage.commit);
      if (!cloudDriveQualityCommitAllowed(
        ticket: ticket,
        latestTicket: _cloudDriveQualitySwitch.isLatest(ticket) ? ticket : -1,
        itemId: item.id,
        currentItemId: _currentItem?.id,
      )) {
        _logPlaybackEvent(
          'cloud quality superseded',
          data: <String, Object?>{'op': operationId, 'stage': 'handoff'},
        );
        await prepared.lease.release();
        await next.dispose();
        prepared = null;
        next = null;
        return finish(CloudDriveQualitySwitchResult.superseded);
      }
      // Read intent after preparation so a pause during the switch sticks.
      var shouldPlay = _session.desiredPlaying;
      try {
        await previous.setVolume(0);
        oldSilenced = true;
      } catch (_) {}
      for (var pass = 0; pass < 3; pass++) {
        if (stale()) return finish(CloudDriveQualitySwitchResult.superseded);
        shouldPlay = _session.desiredPlaying;
        final speed = _playbackSpeed;
        final volume = _isMuted ? 0.0 : _volume;
        await next.setPlaybackSpeed(speed);
        await next.setVolume(volume);
        if (shouldPlay) {
          if (!next.value.isPlaying) await next.play();
        } else if (next.value.isPlaying) {
          await next.pause();
        }
        if (shouldPlay == _session.desiredPlaying &&
            speed == _playbackSpeed &&
            volume == (_isMuted ? 0.0 : _volume)) {
          break;
        }
        if (pass == 2) throw const _StreamQualityHandoffInterrupted();
      }
      final commitPosition = await _readNativeControllerPosition(next);
      if (stale()) return finish(CloudDriveQualitySwitchResult.superseded);
      _invalidatePlaybackSpeedCommands();
      _detachNativePositionStream(previous);
      previous.removeListener(_onControllerUpdate);
      retireLease = _currentCloudDriveLease;
      retireController = previous;
      _controller = next;
      _controllerItemId = item.id;
      _serviceOwnsController = true;
      final hasVideoOutput = _controllerHasRequiredVideoOutput(item, next);
      _transitionPlaybackSession(
        _session.generation,
        hasVideoOutput
            ? PlaybackSessionPhase.ready
            : PlaybackSessionPhase.videoOutputDeferred,
        controller: next,
        desiredPlaying: shouldPlay,
      );
      _currentCloudDriveLease = prepared.lease;
      _cloudDriveQualities = _mergeCloudDriveQualities(
        _cloudDriveQualities,
        prepared.qualities,
      );
      _selectedCloudDriveQualityId = prepared.selectedQualityId;
      cloudDriveNotice = prepared.notice;
      cloudDriveFailureKind = null;
      _rememberCloudDriveQuality(item, prepared.selectedQualityId);
      _attachNativePositionStream(next);
      next.addListener(_onControllerUpdate);
      _duration = next.value.duration;
      _position = commitPosition;
      _armInitialPositionGuard(commitPosition);
      _bufferedPosition = _readBufferedPosition(next);
      _lastControllerIsPlaying = next.value.isPlaying;
      _resetPlaybackTimeline(
        _position,
        running: shouldPlay && next.value.isPlaying,
      );
      committed = true;
      final actualQualityId = prepared.selectedQualityId;
      prepared = null;
      next = null;
      phase(CloudDriveQualitySwitchStage.done);
      return finish(
        CloudDriveQualitySwitchResult.committed,
        actualQualityId: actualQualityId,
      );
    } on TimeoutException catch (error) {
      final superseded = !committed && stale();
      final reason = superseded ? null : '画质切换超时，已继续播放当前画质';
      if (!superseded) cloudDriveNotice = reason;
      _logPlaybackEvent(
        'cloud quality timeout',
        data: <String, Object?>{
          'op': operationId,
          'stage': stage.name,
          'elapsedMs': clock.elapsedMilliseconds,
          'error': sanitizeCloudDriveQualityReason(error),
        },
      );
      if (committed) return finish(CloudDriveQualitySwitchResult.committed);
      if (superseded) {
        return finish(CloudDriveQualitySwitchResult.superseded);
      }
      return finish(
        CloudDriveQualitySwitchResult.failed,
        reason: reason,
        errorType: 'TimeoutException',
        // ignore: invalid_use_of_visible_for_testing_member
        errorDetail:
            // ignore: invalid_use_of_visible_for_testing_member
            '$error native=${next == null ? const {} : await NativeVideoPlayerMediaKit.transportStateFor(next.playerId)}',
        retryable: true,
      );
    } catch (error, stackTrace) {
      final interrupted = error is _StreamQualityHandoffInterrupted;
      final superseded = !committed && stale();
      final String? reason;
      if (committed) {
        reason = '画质已经切换，但收尾时出现问题';
      } else if (superseded) {
        reason = null;
      } else if (interrupted) {
        reason = '画质切换已取消，已继续播放当前画质';
      } else if (error is CloudDriveFailure) {
        reason = sanitizeCloudDriveQualityReason(error);
      } else {
        reason = '画质切换失败，已继续播放当前画质';
      }
      if (reason != null) cloudDriveNotice = reason;
      final errorType = error is CloudDriveFailure
          ? 'CloudDriveFailure(${error.kind.name})'
          : error.runtimeType.toString();
      _logPlaybackEvent(
        'cloud quality error',
        data: <String, Object?>{
          'op': operationId,
          'stage': stage.name,
          'elapsedMs': clock.elapsedMilliseconds,
          'type': errorType,
          'reason': sanitizeCloudDriveQualityReason(error),
        },
      );
      if (kDebugMode) {
        developer.log(
          'cloud quality error ${stage.name} $errorType '
          '${sanitizeCloudDriveQualityReason(error)}',
          name: 'CloudDrive',
          error: error,
          stackTrace: stackTrace,
        );
      }
      if (committed) return finish(CloudDriveQualitySwitchResult.committed);
      if (superseded) {
        return finish(CloudDriveQualitySwitchResult.superseded);
      }
      if (interrupted) {
        return finish(CloudDriveQualitySwitchResult.cancelled, reason: reason);
      }
      return finish(
        CloudDriveQualitySwitchResult.failed,
        reason: reason,
        errorType: errorType,
        errorDetail: sanitizeCloudDriveQualityReason(error),
        retryable:
            error is! CloudDriveFailure ||
            error.kind != CloudDriveFailureKind.notLoggedIn,
      );
    } finally {
      abandoned = true;
      if (!committed && oldHeldForHandoff && identical(_controller, previous)) {
        try {
          if (_session.desiredPlaying) {
            await previous.play().timeout(const Duration(seconds: 1));
          }
        } catch (_) {}
      }
      if (!committed && oldSilenced && identical(_controller, previous)) {
        try {
          await previous
              .setVolume(_isMuted ? 0.0 : _volume)
              .timeout(const Duration(seconds: 1));
        } catch (_) {}
      }
      // The spinner ends before dispose. A stuck player must not keep the
      // quality button in a loading state.
      publishCloudDriveQualityEnd(
        gate: _cloudDriveQualitySwitch,
        ticket: ticket,
        notify: notifyListeners,
      );
      developer.log(
        'cloud quality switch ${committed ? 'committed' : 'kept previous'} '
        '${clock.elapsedMilliseconds}ms session=${prepared?.playbackSessionId ?? _currentCloudDriveLease?.descriptor.playbackSessionId ?? ''} '
        'generation=$ticket ${BuildIdentity.label}',
        name: 'CloudDrive',
      );
      if (!committed) {
        final abandoned = prepared;
        final abandonedController = next;
        prepared = null;
        next = null;
        unawaited(
          _abandonCloudDriveSwitch(
            lease:
                abandoned == null ||
                    identical(_currentCloudDriveLease, abandoned.lease)
                ? null
                : abandoned.lease,
            controller:
                abandonedController != null &&
                    !identical(_controller, abandonedController)
                ? abandonedController
                : null,
          ),
        );
      } else {
        unawaited(
          _retireCloudDriveQuality(
            lease: retireLease,
            controller: retireController,
          ),
        );
      }
    }
  }

  Future<void> _abandonCloudDriveSwitch({
    required CloudDrivePlaybackLease? lease,
    required VideoPlayerController? controller,
  }) async {
    if (lease != null) {
      try {
        await lease.release().timeout(const Duration(seconds: 8));
      } catch (error) {
        _logPlaybackEvent(
          'cloud quality abandon lease failed',
          data: <String, Object?>{'error': '$error'},
        );
      }
    }
    if (controller == null || identical(_controller, controller)) return;
    try {
      await controller.dispose().timeout(const Duration(seconds: 8));
    } catch (error) {
      _logPlaybackEvent(
        'cloud quality abandon controller failed',
        data: <String, Object?>{'error': '$error'},
      );
    }
  }

  Future<void> _retireCloudDriveQuality({
    required CloudDrivePlaybackLease? lease,
    required VideoPlayerController? controller,
  }) async {
    try {
      await lease?.release().timeout(const Duration(seconds: 8));
    } catch (error) {
      _logPlaybackEvent(
        'cloud quality lease cleanup failed',
        data: <String, Object?>{'error': '$error'},
      );
    }
    if (controller == null || identical(_controller, controller)) return;
    try {
      await _detachController(
        controller,
        disposeController: true,
        pauseIfPlaying: true,
      ).timeout(const Duration(seconds: 8));
    } catch (error) {
      _logPlaybackEvent(
        'cloud quality controller cleanup failed',
        data: <String, Object?>{'error': '$error'},
      );
    }
  }

  void _rememberCloudDriveQuality(VideoItem item, String qualityId) {
    final cloud = item.sourceRef?.cloudDrive;
    if (cloud == null) return;
    item.sourceRef = cloudDriveMediaSource(
      providerId: cloud.providerId,
      remoteAccountId: cloud.remoteAccountId,
      driveId: cloud.driveId,
      fileId: cloud.fileId,
      pathHint: cloud.pathHint,
      revision: cloud.revision,
      preferredQuality: qualityId,
    );
  }

  List<CloudDriveQualityChoice> _mergeCloudDriveQualities(
    List<CloudDriveQualityChoice> current,
    List<CloudDriveQualityChoice> incoming,
  ) {
    final merged = <CloudDriveQualityChoice>[...current];
    for (final choice in incoming) {
      final index = merged.indexWhere((item) => item.id == choice.id);
      if (index >= 0) {
        merged[index] = choice;
      } else {
        merged.add(choice);
      }
    }
    return List<CloudDriveQualityChoice>.unmodifiable(
      sortCloudDriveQualities(merged),
    );
  }

  Future<void> _adoptDiscoveredCloudDriveQualities(
    String itemId,
    int playRequestId,
    Future<List<CloudDriveQualityChoice>>? discovered,
  ) async {
    if (discovered == null) return;
    try {
      final extra = await discovered;
      if (_currentItem?.id != itemId || playRequestId != _playRequestId) return;
      _cloudDriveQualities = _mergeCloudDriveQualities(
        _cloudDriveQualities,
        extra,
      );
      notifyListeners();
    } catch (error) {
      if (_currentItem?.id != itemId) return;
      if (error is CloudDriveFailure &&
          error.kind == CloudDriveFailureKind.notLoggedIn) {
        cloudDriveNotice = error.message;
        cloudDriveFailureKind = error.kind;
        notifyListeners();
      }
    }
  }

  Future<String?> _cloudDriveFallbackQuality({
    required CloudDrivePreparedPlayback prepared,
    required Object error,
    required bool allow,
  }) async {
    if (!allow || prepared.transcoded) return null;
    if (error is CloudDriveFailure &&
        (error.kind == CloudDriveFailureKind.notLoggedIn ||
            error.kind == CloudDriveFailureKind.entitlement ||
            error.kind == CloudDriveFailureKind.previewOnly ||
            error.kind == CloudDriveFailureKind.rateLimited ||
            error.kind == CloudDriveFailureKind.fileMissing)) {
      return null;
    }
    final verified = prepared.firstVerifiedFallback;
    final deadline = prepared.operationDeadline;
    final left = deadline == null
        ? const Duration(seconds: 8)
        : deadline.difference(DateTime.now());
    if (left <= Duration.zero) return null;
    final cap = left < const Duration(seconds: 8)
        ? left
        : const Duration(seconds: 8);
    if (verified != null) {
      try {
        final descriptor = await verified.timeout(cap);
        if (descriptor != null &&
            descriptor.quality.selectable &&
            descriptor.quality.transcoded &&
            descriptor.quality.id != prepared.selectedQualityId) {
          return descriptor.quality.id;
        }
      } catch (_) {
        return null;
      }
    }
    final discovered = prepared.backgroundQualities;
    if (discovered == null) return null;
    try {
      final choices = await discovered.timeout(cap);
      return choices
          .where(
            (choice) =>
                choice.selectable &&
                choice.transcoded &&
                choice.id != prepared.selectedQualityId,
          )
          .map((choice) => choice.id)
          .firstOrNull;
    } catch (_) {
      return null;
    }
  }

  bool _playbackMaterializedListenerAttached = false;
  bool _settingsListenerAttached = false;
  StreamSubscription<NetworkSettingsChange>? _networkSubscription;
  int _networkRecoveryGeneration = 0;
  Completer<void>? _streamSwitchStopped;

  Future<void> _recoverPlaybackNetwork(
    int generation,
    Future<void>? stopped,
  ) async {
    await stopped;
    if (generation != _networkRecoveryGeneration) return;
    if (_currentBilibiliPlayback == null) {
      final item = _currentItem;
      if (_state == PlaybackState.loading &&
          item?.sourceRef?.kind == MediaSourceKind.bilibiliStream) {
        await play(
          item!,
          startPosition: _position,
          autoPlay: _session.desiredPlaying,
          forceRecreate: true,
          userInitiatedWatch: false,
        );
      }
      return;
    }
    _isSwitchingStreamQuality = false;
    final quality = _selectedStreamQuality;
    if (quality == null || quality.isLocalMaterialized) return;
    await switchBilibiliStreamQuality(quality.id, forceReconnect: true);
  }

  bool? _lastBilibiliBackgroundAudioOnly;
  bool? _lastShowMiniPlaybackCard;

  void _attachSettingsListener() {
    if (_settingsListenerAttached) return;
    _settingsListenerAttached = true;
    final settings = SettingsService();
    _lastBilibiliBackgroundAudioOnly = settings.bilibiliBackgroundAudioOnly;
    _lastShowMiniPlaybackCard = settings.showMiniPlaybackCard;
    _lastQueueWrap = settings.playlistWrapToFirst;
    _lastAutomaticQueueContinuation = automaticQueueContinuation;
    settings.addListener(_onPlaybackSettingsChanged);
  }

  void _onPlaybackSettingsChanged() {
    final settings = SettingsService();
    if (_lastQueueWrap != settings.playlistWrapToFirst ||
        _lastAutomaticQueueContinuation != automaticQueueContinuation) {
      _lastQueueWrap = settings.playlistWrapToFirst;
      _lastAutomaticQueueContinuation = automaticQueueContinuation;
      _preloadTriggered = false;
      unawaited(_disposePreloadedController());
      notifyListeners();
    }
    final showMini = settings.showMiniPlaybackCard;
    if (_lastShowMiniPlaybackCard != showMini) {
      _lastShowMiniPlaybackCard = showMini;
      // The card, its padding and the action buttons all read this service.
      // Notify in the same turn as the switch so the slide starts immediately.
      notifyListeners();
    }
    final enabled = settings.bilibiliBackgroundAudioOnly;
    if (_lastBilibiliBackgroundAudioOnly == enabled) return;
    _lastBilibiliBackgroundAudioOnly = enabled;
    // Re-apply vid now so toggling the switch does not wait for the next
    // page/Mini visibility change. Enabling video while Mini is live keeps
    // the clock; the page can then mount the already-selected track.
    _syncBilibiliVideoTrackPolicy();
    if (enabled) return;
    final item = _currentItem;
    final controller = _controller;
    if (item == null || controller == null) return;
    _primeDeferredVideoOutput(item, controller);
  }

  void _detachSettingsListener() {
    if (!_settingsListenerAttached) return;
    _settingsListenerAttached = false;
    SettingsService().removeListener(_onPlaybackSettingsChanged);
  }

  void _attachBilibiliStreamingListener() {
    if (_bilibiliStreamingListenerAttached) return;
    final streaming = _bilibiliStreamingService;
    if (streaming == null) return;
    _bilibiliStreamingListenerAttached = true;
    streaming.addListener(_onBilibiliGatewayTransferRateChanged);
  }

  void _onBilibiliGatewayTransferRateChanged() {
    final itemId = _currentItem?.id;
    if (itemId == null || !isCurrentItemStreamingBilibiliCard) return;
    _syncBilibiliGatewaySpeed(notify: true);
  }

  void _syncBilibiliGatewaySpeed({required bool notify}) {
    final itemId = _currentItem?.id;
    if (itemId == null || !isCurrentItemStreamingBilibiliCard) return;
    final speed = _bilibiliStreamingService!.gatewayBytesPerSecondFor(itemId);
    if (speed == _bilibiliGatewayBytesPerSecond) return;
    _bilibiliGatewayBytesPerSecond = speed;
    if (notify) notifyListeners();
  }

  /// Cache availability updates the menu; the gateway reuses tracks on its next
  /// request without rebuilding the active controller or changing quality.
  void _attachPlaybackMaterializedListener() {
    if (_playbackMaterializedListenerAttached) return;
    final materialization = _libraryService?.mediaMaterializationService;
    if (materialization == null) return;
    _playbackMaterializedListenerAttached = true;
    materialization.addPlaybackMaterializedListener(
      _onLocalPlaybackMaterialized,
    );
  }

  void _onLocalPlaybackMaterialized(String itemId) {
    final item = _currentItem;
    if (item == null || item.id != itemId) return;
    if (item.sourceRef?.kind != MediaSourceKind.bilibiliStream) return;
    notifyListeners();
  }

  /// Returns whether the requested quality (or Bilibili's lower fallback) was
  /// actually committed. Failed warm-up deliberately leaves the visible player
  /// untouched, so the UI can report a rollback instead of ignoring the click.
  Future<bool> switchBilibiliStreamQuality(
    int qualityId, {
    bool forceReconnect = false,
  }) => _switchBilibiliStream(qualityId, forceReconnect: forceReconnect);

  Future<bool> switchBilibiliAudioQuality(int audioQualityId) async {
    if (!_streamAudioQualities.any((quality) => quality.id == audioQualityId)) {
      return false;
    }
    return _switchBilibiliStream(
      _selectedStreamQuality?.id ?? 0,
      audioQualityId: audioQualityId,
    );
  }

  Future<bool> _switchBilibiliStream(
    int qualityId, {
    int? audioQualityId,
    bool forceReconnect = false,
  }) async {
    final item = _currentItem;
    final streaming = _bilibiliStreamingService;
    final previousController = _controller;
    if (item == null ||
        streaming == null ||
        previousController == null ||
        !previousController.value.isInitialized ||
        item.sourceRef?.kind != MediaSourceKind.bilibiliStream ||
        _isSwitchingStreamQuality ||
        (!forceReconnect &&
            _selectedStreamQuality?.id == qualityId &&
            (audioQualityId == null ||
                _selectedStreamAudioQuality?.id == audioQualityId))) {
      return _selectedStreamQuality?.id == qualityId &&
          (audioQualityId == null ||
              _selectedStreamAudioQuality?.id == audioQualityId);
    }

    // Materialized files do not record which DASH audio representation they
    // contain. An explicit audio choice must use the matching gateway track.
    final useCachedPlayback =
        audioQualityId == null &&
        (qualityId == BilibiliStreamQuality.localMaterializedId ||
            !streaming.hasPreferredAudioQuality(item.id));
    if (useCachedPlayback &&
        qualityId == BilibiliStreamQuality.localMaterializedId) {
      final legacy =
          MediaCacheHooks.qualities?.call(item).any((q) => q.id == 'legacy') ??
          false;
      final lease = await _libraryService?.acquireExistingMaterializedPlayback(
        item,
        qualityId: legacy ? 'legacy' : null,
      );
      if (lease == null) return false;
      await lease.release();
      streaming.clearAudioQualityPreference(item.id);
      await play(
        item,
        startPosition: _streamQualityHandoffPosition(),
        autoPlay: _state == PlaybackState.playing,
        forceRecreate: true,
        bilibiliQualityId: legacy ? qualityId : null,
      );
      return _selectedStreamQuality?.id == qualityId;
    }

    final switchRequestId = ++_streamQualitySwitchRequestId;
    final retained = useCachedPlayback
        ? await MediaCacheHooks.acquire?.call(item, qualityId: '$qualityId')
        : null;
    if (retained != null) {
      await retained.release();
      await play(
        item,
        startPosition: _streamQualityHandoffPosition(),
        autoPlay: _state == PlaybackState.playing,
        forceRecreate: true,
        bilibiliQualityId: qualityId,
      );
      return _selectedStreamQuality?.id == qualityId;
    }
    final previousPlayback = _currentBilibiliPlayback;
    final previousMaterializedLease = _currentMaterializedPlaybackLease;
    final previousSelectedQuality = _selectedStreamQuality;
    final previousSelectedAudio = _selectedStreamAudioQuality;
    final previousControllerOwned = _serviceOwnsController;
    BilibiliPreparedPlayback? preparedPlayback;
    VideoPlayerController? warmController;
    var committed = false;

    _isSwitchingStreamQuality = true;
    final stopped = Completer<void>();
    _streamSwitchStopped = stopped;
    notifyListeners();

    try {
      bool isCurrent() => _isCurrentStreamQualitySwitch(
        switchRequestId,
        item.id,
        previousController,
      );
      late ({Duration position, bool shouldPlay}) handoff;
      for (var attempt = 0; attempt < _streamQualityMaxAttempts; attempt++) {
        if (!isCurrent()) return false;
        var phase = 'prepare';
        try {
          // Retry with fresh signed URLs and a new session. Reusing the failed
          // candidate or a pre-warmed session can repeat the same failure.
          preparedPlayback = await streaming.prepare(
            item,
            qualityId: qualityId,
            audioQualityId: audioQualityId ?? previousSelectedAudio?.id,
            forceRefresh: forceReconnect || attempt > 0,
          );
          if (!isCurrent()) return false;
          if (audioQualityId != null &&
              preparedPlayback.selectedAudioQuality?.id != audioQualityId) {
            return false;
          }

          // The API may map an unavailable quality to the active fallback.
          if (!forceReconnect &&
              preparedPlayback.selectedQuality.id ==
                  previousSelectedQuality?.id &&
              preparedPlayback.selectedAudioQuality?.id ==
                  previousSelectedAudio?.id) {
            streaming.rememberQuality(
              item.id,
              preparedPlayback.selectedQuality.id,
            );
            return true;
          }

          phase = 'initialize';
          warmController = _createBilibiliStreamController(
            preparedPlayback,
            fastStart: true,
            startPosition: _streamQualityHandoffPosition(),
          );
          await warmController.initialize().timeout(
            _controllerInitializeTimeout,
          );
          if (!isCurrent()) return false;

          phase = 'warm frame';
          await _prepareStreamQualityHandoff(
            controller: warmController,
            previousController: previousController,
            isCurrent: isCurrent,
          );
          if (!isCurrent()) return false;

          phase = 'synchronize';
          if (audioQualityId != null) {
            final audioState = await NativeVideoPlayerMediaKit.audioStateFor(
              // ignore: invalid_use_of_visible_for_testing_member
              warmController.playerId,
            );
            if (!isCurrent()) return false;
            if (audioState != null &&
                ((audioState['audio-codec-name'] ?? '').isEmpty ||
                    (int.tryParse(
                              audioState['audio-params/samplerate'] ?? '',
                            ) ??
                            0) <=
                        0)) {
              throw StateError('所选音轨未能完成音频解码');
            }
          }
          handoff = await _synchronizeStreamQualityAtCommit(
            controller: warmController,
            previousController: previousController,
            isCurrent: isCurrent,
          );
          if (!isCurrent()) return false;
          break;
        } catch (error) {
          if (warmController != null) {
            await _detachController(
              warmController,
              disposeController: true,
              pauseIfPlaying: true,
            );
            warmController = null;
          }
          if (preparedPlayback != null) {
            await streaming.releasePlayback(preparedPlayback);
            preparedPlayback = null;
          }
          if (!isCurrent()) return false;

          // Some mobile devices cannot keep two hardware decoders alive.
          if (audioQualityId == null &&
              phase == 'initialize' &&
              _isMobileDecoderCapacityError(error)) {
            streaming.rememberQuality(item.id, qualityId);
            await play(
              item,
              startPosition: _streamQualityHandoffPosition(),
              autoPlay: _state == PlaybackState.playing,
              forceRecreate: true,
            );
            return _selectedStreamQuality?.id == qualityId;
          }
          if (attempt + 1 == _streamQualityMaxAttempts ||
              error is FormatException ||
              error is ArgumentError) {
            rethrow;
          }
          _logPlaybackEvent(
            'stream quality attempt failed; retrying with fresh URLs',
            data: <String, Object?>{
              'itemId': item.id,
              'qualityId': qualityId,
              'phase': phase,
              'attempt': attempt + 1,
              'error': error,
            },
          );
        }
      }

      _commitStreamQualityHandoff(
        item: item,
        controller: warmController!,
        preparedPlayback: preparedPlayback!,
        position: handoff.position,
        shouldPlay: handoff.shouldPlay,
      );
      committed = true;
      warmController = null;
      preparedPlayback = null;

      streaming.rememberQuality(item.id, _selectedStreamQuality!.id);
      if (audioQualityId != null) {
        streaming.rememberAudioQuality(
          item.id,
          _selectedStreamAudioQuality!.id,
        );
      }
      unawaited(_savePlaybackStateSnapshot());

      // Silence the old audio immediately, but retain its decoded texture
      // through the Flutter frame that mounts the replacement. Disposing it in
      // the same event turn can make the texture registrar publish one empty
      // frame even though both native players were otherwise ready.
      try {
        if (previousController.value.isPlaying) {
          unawaited(previousController.pause());
        }
      } catch (_) {}
      unawaited(
        _releasePreviousStreamAfterHandoffFrame(
          controller: previousController,
          disposeController: previousControllerOwned,
          streaming: streaming,
          playback: previousPlayback,
          materializedLease: previousMaterializedLease,
        ),
      );

      final activeController = _controller;
      if (activeController != null) {
        unawaited(
          activeController.setVolume(_isMuted ? 0.0 : _volume).catchError((
            Object error,
          ) {
            _logPlaybackEvent(
              'stream quality hand-off volume restore failed',
              data: <String, Object?>{'error': error},
            );
          }),
        );
      }
      return true;
    } catch (error) {
      _logPlaybackEvent(
        'stream quality hand-off failed; keeping previous stream',
        data: <String, Object?>{
          'itemId': item.id,
          'qualityId': qualityId,
          'error': error,
        },
      );
      return false;
    } finally {
      if (!committed && warmController != null) {
        await _detachController(
          warmController,
          disposeController: true,
          pauseIfPlaying: true,
        );
      }
      if (!committed && preparedPlayback != null) {
        await streaming.releasePlayback(preparedPlayback);
      }
      if (switchRequestId == _streamQualitySwitchRequestId) {
        _isSwitchingStreamQuality = false;
        notifyListeners();
      }
      stopped.complete();
      if (identical(_streamSwitchStopped, stopped)) _streamSwitchStopped = null;
    }
  }

  /// Tries to move an actively materialized Bilibili player back to its
  /// online stream before cache deletion. A false result means the caller
  /// must defer deletion until the current file lease is released.
  Future<bool> releaseMaterializedPlaybackForClear(String itemId) async {
    final item = _currentItem;
    if (item?.id != itemId || _currentMaterializedPlaybackLease == null) {
      return true;
    }
    BilibiliStreamQuality? onlineQuality;
    for (final quality in _streamQualities) {
      if (!quality.isLocalMaterialized) {
        onlineQuality = quality;
        break;
      }
    }
    if (onlineQuality == null) {
      try {
        final qualities = await _bilibiliStreamingService?.listQualities(item!);
        if (qualities != null && qualities.isNotEmpty) {
          onlineQuality = qualities.first;
        }
      } catch (_) {}
    }
    if (onlineQuality == null) return false;
    await switchBilibiliStreamQuality(onlineQuality.id);
    return _currentMaterializedPlaybackLease == null;
  }

  VideoPlayerController _createBilibiliStreamController(
    BilibiliPreparedPlayback playback, {
    bool fastStart = false,
    bool audioPrimary = false,
    bool deferVideo = false,
    Duration? startPosition,
  }) {
    if (audioPrimary) {
      return AppVideoPlayerController.networkUrl(
        playback.audioUri,
        httpHeaders: <String, String>{
          NativeVideoPlayerMediaKit.audioPrimaryStreamHeader: '1',
          NativeVideoPlayerMediaKit.fastStreamStartHeader: '1',
        },
        videoPlayerOptions: buildVideoPlayerOptions(),
      );
    }
    final startMs = startPosition?.inMilliseconds ?? 0;
    return AppVideoPlayerController.networkUrl(
      playback.videoUri,
      httpHeaders: <String, String>{
        NativeVideoPlayerMediaKit.externalAudioSourceHeader: playback.audioUri
            .toString(),
        if (fastStart) NativeVideoPlayerMediaKit.fastStreamStartHeader: '1',
        if (deferVideo) NativeVideoPlayerMediaKit.deferVideoStreamHeader: '1',
        if (startMs > 0)
          NativeVideoPlayerMediaKit.startPositionMsHeader: '$startMs',
      },
      videoPlayerOptions: buildVideoPlayerOptions(),
    );
  }

  /// Desktop Bilibili always skips the 2s cache-pause-initial. Gigabit Windows
  /// was waiting on that guard while the overlay reported a bursty false speed.
  bool _shouldFastStartBilibiliOnThisPlatform() {
    if (kIsWeb) return false;
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  }

  Future<bool> _shouldFastStartCachedBilibiliStream(VideoItem item) async {
    final streaming = _bilibiliStreamingService;
    if (streaming == null) return false;
    try {
      return await streaming.hasReusableTrackCache(item.id);
    } catch (_) {
      return false;
    }
  }

  bool _isCurrentStreamQualitySwitch(
    int requestId,
    String itemId,
    VideoPlayerController previousController,
  ) {
    return requestId == _streamQualitySwitchRequestId &&
        _currentItem?.id == itemId &&
        identical(_controller, previousController) &&
        previousController.value.isInitialized;
  }

  Duration _streamQualityHandoffPosition() {
    var position = positionNotifier.value;
    if (position < Duration.zero) position = Duration.zero;
    final effectiveDuration = _duration;
    if (effectiveDuration > Duration.zero && position > effectiveDuration) {
      position = effectiveDuration;
    }
    return position;
  }

  Future<void> _prepareStreamQualityHandoff({
    required VideoPlayerController controller,
    required VideoPlayerController previousController,
    required bool Function() isCurrent,
    bool allowNativeFirstFrame = true,
    bool cloudDrive = false,
    void Function(String stage, int elapsedMs)? onPhase,
  }) async {
    await controller.setVolume(0.0);
    final targetSpeed = _playbackSpeed;
    if ((controller.value.playbackSpeed - targetSpeed).abs() >= 0.001) {
      await controller.setPlaybackSpeed(targetSpeed);
    }

    final seekClock = Stopwatch()..start();
    // The UI timeline may not tick while the window is hidden or minimized.
    // Align to the active native clock after any slow preparation or retry.
    final target = _pendingSeekRequestId != null
        ? _streamQualityHandoffPosition()
        : await _readNativeControllerPosition(previousController);
    var sought = false;
    if (cloudDrive) {
      final actual = await _readNativeControllerPosition(controller);
      final delta = (actual.inMilliseconds - target.inMilliseconds).abs();
      // start= already parked this player. A 60ms sample gap is not a reason
      // to throw the buffered start away and seek again.
      if (_pendingSeekRequestId != null || delta > 3000) {
        await _seekWarmController(
          controller,
          target,
          attempts: 1,
          toleranceMs: 400,
          decodeWhileSeeking: true,
          isCurrent: isCurrent,
        );
        sought = true;
      }
    } else {
      await _seekWarmController(controller, target);
    }
    onPhase?.call('seek', seekClock.elapsedMilliseconds);

    final frameClock = Stopwatch()..start();
    // Pre-roll even when the visible player is paused. The candidate is muted,
    // and replaying then seeking back is the only portable way to make Android
    // SurfaceTexture, AVPlayer and desktop texture backends all decode a frame
    // before their widget is attached.
    await controller.play();
    await _waitForWarmStreamFrame(
      controller,
      isCurrent: isCurrent,
      allowNativeFirstFrame: allowNativeFirstFrame && !sought,
      allowProgressWhileBuffering: cloudDrive,
      // A non-member original may need longer than the generic 8s warm-up.
      // The enclosing cloud handoff still owns the shared deadline.
      warmupTimeout: cloudDrive ? cloudDriveHandoffCap : null,
    );
    onPhase?.call('warmFrame', frameClock.elapsedMilliseconds);

    if (_state != PlaybackState.playing) {
      // Keep the last frame produced by pre-roll. Seeking again while paused
      // can clear a desktop texture without asking the decoder for a
      // replacement frame, which presents as black video with healthy audio.
      await controller.pause();
    }
  }

  Future<({Duration position, bool shouldPlay})>
  _synchronizeStreamQualityAtCommit({
    required VideoPlayerController controller,
    required VideoPlayerController previousController,
    required bool Function() isCurrent,
    bool cloudDrive = false,
  }) async {
    for (var pass = 0; pass < 3; pass++) {
      final playRequestId = _playRequestId;
      final seekRequestId = _seekRequestId;
      final speed = _playbackSpeed;
      final shouldPlay = _state == PlaybackState.playing;
      bool isStable() =>
          isCurrent() &&
          playRequestId == _playRequestId &&
          seekRequestId == _seekRequestId &&
          speed == _playbackSpeed &&
          shouldPlay == (_state == PlaybackState.playing);
      try {
        final position = shouldPlay
            ? await _phaseLockPlayingStreamQualityAtCommit(
                controller: controller,
                previousController: previousController,
                isCurrent: isStable,
                timeout: cloudDrive ? const Duration(seconds: 8) : null,
                allowClockWhileBuffering: cloudDrive,
                toleranceMs: cloudDrive
                    ? 500
                    : _streamQualityHandoffToleranceMs,
              )
            : await _synchronizePausedStreamQualityAtCommit(
                controller: controller,
                previousController: previousController,
                isCurrent: isStable,
                toleranceMs: cloudDrive
                    ? 500
                    : _streamQualityHandoffToleranceMs,
                cloudDrive: cloudDrive,
              );
        if (!isStable()) throw const _StreamQualityHandoffInterrupted();
        return (position: position, shouldPlay: shouldPlay);
      } on _StreamQualityHandoffInterrupted {
        if (!isCurrent() || pass == 2) rethrow;
        // The user changed transport, seek or speed during synchronization.
        // Decode at the latest target before trying to commit this candidate.
        await _prepareStreamQualityHandoff(
          controller: controller,
          previousController: previousController,
          isCurrent: isCurrent,
          allowNativeFirstFrame: false,
          cloudDrive: cloudDrive,
        );
      }
    }
    throw const _StreamQualityHandoffInterrupted();
  }

  /// Phase-locks the already decoded replacement without seeking it again.
  /// A post-warm seek can invalidate a Windows texture after media_kit's
  /// one-shot first-frame signal has completed, producing black video while
  /// the external audio track continues normally.
  Future<Duration> _phaseLockPlayingStreamQualityAtCommit({
    required VideoPlayerController controller,
    required VideoPlayerController previousController,
    required bool Function() isCurrent,
    Duration? timeout,
    bool allowClockWhileBuffering = false,
    int toleranceMs = _streamQualityHandoffToleranceMs,
  }) async {
    final normalSpeed = _playbackSpeed;
    var appliedSpeed = controller.value.playbackSpeed;
    var usedCatchUpSpeed = false;
    final deadline = DateTime.now().add(
      timeout ?? _streamQualityPhaseLockTimeout,
    );

    Future<void> setCandidateSpeed(double speed) async {
      if ((appliedSpeed - speed).abs() < 0.01) return;
      await controller.setPlaybackSpeed(speed);
      appliedSpeed = speed;
    }

    try {
      if (!controller.value.isPlaying) await controller.play();
      while (DateTime.now().isBefore(deadline)) {
        if (!isCurrent()) throw const _StreamQualityHandoffInterrupted();
        if (controller.value.hasError) {
          throw StateError(
            controller.value.errorDescription ?? 'replacement stream failed',
          );
        }

        if (controller.value.isBuffering && !allowClockWhileBuffering) {
          await Future<void>.delayed(_streamQualityPhaseLockSampleDelay);
          continue;
        }

        final positions = await Future.wait<Duration>(<Future<Duration>>[
          _readNativeControllerPosition(previousController),
          _readNativeControllerPosition(controller),
        ]);
        final deltaMs =
            positions[1].inMilliseconds - positions[0].inMilliseconds;

        if (deltaMs.abs() <= toleranceMs) {
          await setCandidateSpeed(normalSpeed);
          if (!controller.value.isPlaying) await controller.play();
          // Catch-up speed can overshoot; confirm one sample after restoring
          // the user rate. An already-locked candidate does not need that extra
          // wait — it is the bulk of the "seamless but slow" quality switch.
          if (!usedCatchUpSpeed) {
            return positions[1];
          }
          usedCatchUpSpeed = false;

          await Future<void>.delayed(_streamQualityPhaseLockSampleDelay);
          if (controller.value.isBuffering && !allowClockWhileBuffering) {
            continue;
          }
          final confirmation = await Future.wait<Duration>(<Future<Duration>>[
            _readNativeControllerPosition(previousController),
            _readNativeControllerPosition(controller),
          ]);
          final confirmedDeltaMs =
              confirmation[1].inMilliseconds - confirmation[0].inMilliseconds;
          if (confirmedDeltaMs.abs() <= toleranceMs) {
            return confirmation[1];
          }
          continue;
        }

        if (deltaMs > 0) {
          // Candidate is ahead: freeze its decoded frame while the visible old
          // player catches up.
          await setCandidateSpeed(normalSpeed);
          if (controller.value.isPlaying) await controller.pause();
        } else {
          // Candidate is behind: catch up off-screen at a modest higher rate.
          // Unlike another seek, this keeps decoded frames flowing.
          if (!controller.value.isPlaying) await controller.play();
          final catchUp = ((-deltaMs) / 300).clamp(0.5, 1.5).toDouble();
          await setCandidateSpeed(normalSpeed + catchUp);
          usedCatchUpSpeed = true;
        }

        await Future<void>.delayed(_streamQualityPhaseLockSampleDelay);
      }
      throw StateError('playing stream quality hand-off did not phase-lock');
    } finally {
      await setCandidateSpeed(normalSpeed);
      if (!controller.value.hasError && !controller.value.isPlaying) {
        await controller.play();
      }
    }
  }

  Future<Duration> _synchronizePausedStreamQualityAtCommit({
    required VideoPlayerController controller,
    required VideoPlayerController previousController,
    required bool Function() isCurrent,
    int toleranceMs = _streamQualityHandoffToleranceMs,
    bool cloudDrive = false,
  }) async {
    if (controller.value.isPlaying) await controller.pause();
    final target = await _readNativeControllerPosition(previousController);
    var candidate = await _readNativeControllerPosition(controller);
    if ((candidate.inMilliseconds - target.inMilliseconds).abs() <=
        toleranceMs) {
      return candidate;
    }

    // Decode forward after the seek and pause only once native position
    // movement confirms that a replacement frame has been presented.
    await _seekWarmController(
      controller,
      target,
      toleranceMs: toleranceMs,
      decodeWhileSeeking: cloudDrive,
      attempts: cloudDrive ? 1 : null,
      isCurrent: isCurrent,
    );
    await controller.play();
    final deadline = DateTime.now().add(_streamQualityWarmupTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (!isCurrent()) throw const _StreamQualityHandoffInterrupted();
      if (controller.value.hasError) {
        throw StateError(
          controller.value.errorDescription ?? 'replacement stream failed',
        );
      }
      candidate = await _readNativeControllerPosition(controller);
      final advancedMs = candidate.inMilliseconds - target.inMilliseconds;
      if ((cloudDrive || !controller.value.isBuffering) && advancedMs >= 25) {
        await controller.pause();
        candidate = await _readNativeControllerPosition(controller);
        if ((candidate.inMilliseconds - target.inMilliseconds).abs() <=
            (cloudDrive ? toleranceMs : 120)) {
          return candidate;
        }
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }

    if (controller.value.isPlaying) await controller.pause();
    throw StateError(
      'paused stream quality hand-off did not render at target '
      'targetMs=${target.inMilliseconds} actualMs=${candidate.inMilliseconds}',
    );
  }

  Future<Duration> _readNativeControllerPosition(
    VideoPlayerController controller,
  ) async {
    try {
      // ignore: invalid_use_of_visible_for_testing_member
      final id = controller.playerId;
      final actual = await NativeVideoPlayerMediaKit.transportPositionFor(
        id,
      ).timeout(_streamQualityPositionReadTimeout);
      if (actual != null) return actual;
      final native = NativeVideoPlayerMediaKit.timePosFor(id);
      if (native != null) return native;
      return await controller.position.timeout(
            _streamQualityPositionReadTimeout,
          ) ??
          controller.value.position;
    } catch (_) {
      return controller.value.position;
    }
  }

  Future<void> _releasePreviousStreamAfterHandoffFrame({
    required VideoPlayerController controller,
    required bool disposeController,
    required BilibiliStreamingService streaming,
    required BilibiliPreparedPlayback? playback,
    MaterializedMediaLease? materializedLease,
  }) async {
    await Future.any<void>(<Future<void>>[
      SchedulerBinding.instance.endOfFrame,
      Future<void>.delayed(const Duration(milliseconds: 50)),
    ]);
    await _detachController(
      controller,
      disposeController: disposeController,
      pauseIfPlaying: true,
    );
    if (playback != null) await streaming.releasePlayback(playback);
    await materializedLease?.release();
  }

  Future<void> _seekWarmController(
    VideoPlayerController controller,
    Duration position, {
    int? attempts,
    int? toleranceMs,
    bool decodeWhileSeeking = false,
    bool Function()? isCurrent,
  }) async {
    if (controller.value.isPlaying) await controller.pause();
    var target = position < Duration.zero ? Duration.zero : position;
    final duration = controller.value.duration;
    if (duration > Duration.zero && target > duration) target = duration;
    final maxAttempts = attempts ?? 2;
    final tolerance = toleranceMs ?? _streamQualityHandoffToleranceMs;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (isCurrent?.call() == false) {
        throw const _StreamQualityHandoffInterrupted();
      }
      await controller.seekTo(target).timeout(_controllerSeekTimeout);
      // HLS demuxers can acknowledge a seek while paused but publish its clock
      // only after decoding resumes. The cloud candidate is already muted.
      if (decodeWhileSeeking) await controller.play();
      await Future<void>.delayed(const Duration(milliseconds: 35));
      final deadline = DateTime.now().add(_controllerSeekTimeout);
      while (DateTime.now().isBefore(deadline)) {
        if (isCurrent?.call() == false) {
          throw const _StreamQualityHandoffInterrupted();
        }
        if (controller.value.hasError) {
          throw StateError(
            controller.value.errorDescription ?? 'replacement stream failed',
          );
        }
        final actual = await _readNativeControllerPosition(controller);
        if ((actual.inMilliseconds - target.inMilliseconds).abs() <=
            tolerance) {
          return;
        }
        // Native seek acknowledgement may precede the next position sample.
        // Give that sample time to arrive before issuing another seek.
        await Future<void>.delayed(_streamQualityPhaseLockSampleDelay);
      }
    }
    throw StateError('replacement stream did not seek to the target');
  }

  Future<void> _waitForWarmStreamFrame(
    VideoPlayerController controller, {
    required bool Function() isCurrent,
    bool allowNativeFirstFrame = true,
    bool allowProgressWhileBuffering = false,
    Duration? warmupTimeout,
  }) async {
    final deadline = DateTime.now().add(
      warmupTimeout ?? _streamQualityWarmupTimeout,
    );
    final nativeFirstFrame = NativeVideoPlayerMediaKit.firstFrameRenderedFor(
      // ignore: invalid_use_of_visible_for_testing_member
      controller.playerId,
    );
    var nativeFrameReady = false;
    if (allowNativeFirstFrame &&
        nativeFirstFrame != null &&
        allowProgressWhileBuffering) {
      // A hidden Windows texture can render its parked first frame without
      // advancing the presentation clock until it becomes visible. Race that
      // native signal with clock progress. Serially waiting for it first can
      // let an already-running candidate overshoot and force another seek.
      unawaited(
        nativeFirstFrame.then<void>((_) {
          nativeFrameReady = true;
        }, onError: (Object _, StackTrace _) {}),
      );
    } else if (allowNativeFirstFrame && nativeFirstFrame != null) {
      try {
        await nativeFirstFrame.timeout(const Duration(seconds: 3));
        await Future<void>.delayed(_streamQualityWarmFrameDelay);
        return;
      } on TimeoutException {
        // Fall through to the portable buffering/clock readiness heuristic.
      }
    }

    // video_player has no portable first-frame callback. Every supported
    // backend does expose buffering, buffered ranges or position movement.
    // Seeing one of those signals after muted pre-roll is the closest common
    // first-frame readiness contract available across all platform adapters.
    final initialPosition = await _readNativeControllerPosition(controller);
    var observedBuffering = controller.value.isBuffering;
    while (DateTime.now().isBefore(deadline)) {
      if (!isCurrent()) throw const _StreamQualityHandoffInterrupted();
      final value = controller.value;
      if (value.hasError) {
        throw StateError(value.errorDescription ?? 'stream warm-up failed');
      }
      observedBuffering = observedBuffering || value.isBuffering;
      final position = await _readNativeControllerPosition(controller);
      final positionAdvanced =
          position - initialPosition >= const Duration(milliseconds: 30);
      final bufferedAtTarget = value.buffered.any(
        (range) =>
            range.start <= initialPosition && range.end > initialPosition,
      );
      // A throttled cloud source may keep mpv's cache-underflow flag set
      // while decoded presentation timestamps are already advancing. That
      // advancing native clock is usable evidence; a cache flag alone is not.
      if (nativeFrameReady ||
          (allowProgressWhileBuffering && positionAdvanced) ||
          (!value.isBuffering &&
              (positionAdvanced ||
                  (allowNativeFirstFrame &&
                      (observedBuffering || bufferedAtTarget))))) {
        await Future<void>.delayed(_streamQualityWarmFrameDelay);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    if (controller.value.hasError) {
      throw StateError(
        controller.value.errorDescription ?? 'stream warm-up failed',
      );
    }
    throw TimeoutException('replacement stream did not produce a warm frame');
  }

  void _commitStreamQualityHandoff({
    required VideoItem item,
    required VideoPlayerController controller,
    required BilibiliPreparedPlayback preparedPlayback,
    required Duration position,
    required bool shouldPlay,
  }) {
    final previousController = _controller!;
    BilibiliStreamQuality? localQuality;
    for (final quality in _streamQualities) {
      if (quality.isLocalMaterialized) {
        localQuality = quality;
        break;
      }
    }
    _invalidatePlaybackSpeedCommands();
    _detachNativePositionStream(previousController);
    try {
      previousController.removeListener(_onControllerUpdate);
    } catch (_) {}

    _controller = controller;
    _controllerItemId = item.id;
    _serviceOwnsController = true;
    final hasVideoOutput = _controllerHasRequiredVideoOutput(item, controller);
    _transitionPlaybackSession(
      _session.generation,
      hasVideoOutput
          ? PlaybackSessionPhase.ready
          : PlaybackSessionPhase.videoOutputDeferred,
      controller: controller,
      desiredPlaying: shouldPlay,
    );
    _currentBilibiliPlayback = preparedPlayback;
    _bilibiliAudioPrimaryPlayer = false;
    _currentMaterializedPlaybackLease = null;
    _isSourceMissing = false;
    _streamQualities = _withCachedBilibiliQualities(item, [
      ?localQuality,
      ...preparedPlayback.qualities,
    ]);
    _selectedStreamQuality = preparedPlayback.selectedQuality;
    _streamAudioQualities = preparedPlayback.audioQualities;
    _selectedStreamAudioQuality = preparedPlayback.selectedAudioQuality;
    _setStreamDisplayAspectRatio(item.id, preparedPlayback.displayAspectRatio);
    _duration = controller.value.duration;
    _position = position;
    _bufferedPosition = _readBufferedPosition(controller);
    _state = shouldPlay ? PlaybackState.playing : PlaybackState.paused;
    _lastControllerIsPlaying = controller.value.isPlaying;
    _armInitialPositionGuard(position);

    _attachNativePositionStream(controller);
    controller.addListener(_onControllerUpdate);
    _resetPlaybackTimeline(
      position,
      running: shouldPlay && controller.value.isPlaying,
    );
    if (shouldPlay) {
      _startProgressTracking();
    } else {
      _stopProgressTracking();
    }
    _syncWakelockWithState();
    notifyListeners();
    _logPlaybackEvent(
      'stream quality hand-off committed',
      data: <String, Object?>{
        'itemId': item.id,
        'qualityId': preparedPlayback.selectedQuality.id,
        'positionMs': position.inMilliseconds,
        'playing': shouldPlay,
      },
    );
  }

  bool _isMobileDecoderCapacityError(Object error) {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return false;
    final message = error.toString().toLowerCase();
    return <String>[
      'mediacodec',
      'decoder initialization',
      'decoder init',
      'insufficient resource',
      'resource busy',
      'no available decoder',
      'omx.',
      '0xfffffff4',
    ].any(message.contains);
  }

  /// 设置字幕列表
  void setSubtitles(List<SubtitleItem> subtitles) {
    setSubtitleState(paths: const [], primary: subtitles, secondary: const []);
  }

  void setSubtitleState({
    required List<String> paths,
    required List<SubtitleItem> primary,
    required List<SubtitleItem> secondary,
  }) {
    _subtitleLoadRequestId++;
    _isLoadingSubtitles = false;
    // This is an explicit selection. A late automatic official result must not
    // replace it, even while its file is still being parsed.
    _subtitleIntentGeneration++;
    _preserveManualSubtitleSelection();
    _invalidateSubtitleParseCache(paths);
    _commitSubtitleState(paths: paths, primary: primary, secondary: secondary);
  }

  void _preserveManualSubtitleSelection() {
    final item = _currentItem;
    if (item != null) {
      final path = p.normalize(item.path);
      for (final key in [
        'id:${item.id}',
        'path:${Platform.isWindows ? path.toLowerCase() : path}',
      ]) {
        _streamManualIntents[key] = (_streamManualIntents[key] ?? 0) + 1;
      }
      _subtitleStreamManager?.preserveSubtitleSelection(
        item.path,
        videoId: item.id,
      );
      _subtitleStreamManager?.preserveSubtitleSelection(item.path);
    }
  }

  void _invalidateSubtitleParseCache(Iterable<String> paths) {
    for (final path in paths) {
      _subtitleCache.remove('$path::plain');
      _subtitleCache.remove('$path::yt_auto');
      _subtitleCache.remove('$path::timeline_v2');
      _subtitleCache.removeWhere(
        (key, _) => key.startsWith('$path::timeline_v3::'),
      );
    }
  }

  void _commitSubtitleState({
    required List<String> paths,
    required List<SubtitleItem> primary,
    required List<SubtitleItem> secondary,
    bool notify = true,
  }) {
    _subtitleWasAppend = false;
    _subtitles = primary is SubtitleCueSnapshot
        ? primary
        : List<SubtitleItem>.unmodifiable(primary);
    _secondarySubtitles = secondary is SubtitleCueSnapshot
        ? secondary
        : List<SubtitleItem>.unmodifiable(secondary);
    _subtitlePaths = List<String>.unmodifiable(paths);
    _subtitleRevision++;
    _subtitleTimeline = SubtitleTimelineResolver(_subtitles);
    _lastSubtitleIndex = 0;
    _currentSubtitle = null;
    _updateCurrentSubtitle();
    if (notify) notifyListeners();
  }

  /// Loads and commits the selected primary/secondary subtitle paths for the
  /// active media item. The service owns the request generation so a slower
  /// request from a covered or disposed playback page cannot overwrite a more
  /// recent selection made on the other layout.
  Future<bool> loadSubtitlePathsForCurrentItem({
    required String itemId,
    required List<String> paths,
    bool userInitiated = true,
    bool Function()? shouldApply,
  }) async {
    if (_currentItem?.id != itemId || shouldApply?.call() == false) return false;
    final int requestId = _beginSubtitleLoad();
    // An explicit (including empty) selection wins over a pending auto task.
    if (userInitiated) {
      _subtitleIntentGeneration++;
      _preserveManualSubtitleSelection();
    }

    try {
      final selectedPaths = List<String>.unmodifiable(
        paths.where((path) => path.trim().isNotEmpty).take(2),
      );
      if (selectedPaths.isEmpty) {
        if (requestId != _subtitleLoadRequestId || _currentItem?.id != itemId || shouldApply?.call() == false) {
          return false;
        }
        _currentItem!
          ..subtitlePath = null
          ..secondarySubtitlePath = null;
        _commitSubtitleState(
          paths: const <String>[],
          primary: const <SubtitleItem>[],
          secondary: const <SubtitleItem>[],
        );
        return true;
      }

      final parsed = await Future.wait(selectedPaths.map(_parseSubtitleFile));
      final primary = parsed.first;
      final secondary = parsed.length > 1 ? parsed[1] : <SubtitleItem>[];
      if (requestId != _subtitleLoadRequestId || _currentItem?.id != itemId || shouldApply?.call() == false) {
        return false;
      }

      _currentItem!
        ..subtitlePath = selectedPaths.first
        ..secondarySubtitlePath = selectedPaths.length > 1
            ? selectedPaths[1]
            : null;
      _commitSubtitleState(
        paths: selectedPaths,
        primary: primary,
        secondary: secondary,
      );
      return true;
    } finally {
      _finishSubtitleLoad(requestId);
    }
  }

  int _beginSubtitleLoad() {
    final requestId = ++_subtitleLoadRequestId;
    if (!_isLoadingSubtitles) {
      _isLoadingSubtitles = true;
      notifyListeners();
    }
    return requestId;
  }

  void _finishSubtitleLoad(int requestId) {
    if (requestId != _subtitleLoadRequestId || !_isLoadingSubtitles) return;
    _isLoadingSubtitles = false;
    notifyListeners();
  }

  /// Makes a portrait/landscape hand-off atomic from the subtitle point of
  /// view. A playback page may be created while the initial subtitle refresh
  /// is still parsing, so merely reading [subtitlePaths] can expose a partial
  /// (primary-only) snapshot to the new page.
  Future<bool> ensureSubtitlePathsForCurrentItem({
    required String itemId,
    required List<String> paths,
  }) async {
    if (_currentItem?.id != itemId) return false;

    final expected = paths
        .where((path) => path.trim().isNotEmpty)
        .take(2)
        .map(p.normalize)
        .toList(growable: false);
    final current = _subtitlePaths.map(p.normalize).toList(growable: false);
    final bool hasCompleteParsedState =
        expected.length == current.length &&
        _sameOrderedPaths(expected, current) &&
        (expected.isEmpty || _subtitles.isNotEmpty) &&
        (expected.length < 2 || _secondarySubtitles.isNotEmpty);
    if (hasCompleteParsedState) return true;

    return loadSubtitlePathsForCurrentItem(
      itemId: itemId,
      paths: expected,
      userInitiated: false,
    );
  }

  static bool _sameOrderedPaths(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }

  void clearSubtitleState() {
    setSubtitleState(paths: const [], primary: const [], secondary: const []);
    // Clear the subtitle file cache to free memory when switching videos.
    _subtitleCache.clear();
  }

  void _clearSubtitleStateForMediaSwitch() {
    _subtitleLoadRequestId++;
    _subtitleIntentGeneration++;
    _isLoadingSubtitles = false;
    // Also invalidate an older visit to this same cloud file (A -> B -> A).
    // Its pending download may still be shared by the track store, but its
    // automatic selection must not belong to the new playback visit.
    _autoSubtitleFlight = null;
    cloudDriveSubtitleAutoOutcome = const CloudDriveAutoSubtitleOutcome.idle();
    _commitSubtitleState(
      paths: const <String>[],
      primary: const <SubtitleItem>[],
      secondary: const <SubtitleItem>[],
      notify: false,
    );
    // Keep a bounded, fingerprinted parse cache for returning to recent items.
    // The visible timeline above still belongs exclusively to the new item.
  }

  String? _resolveFirstAssociatedSubtitlePath(VideoItem item) {
    final associated = item.downloadAssociatedSubtitles;
    if (associated.isEmpty) return null;
    for (final path in associated.values) {
      if (path.isEmpty) continue;
      final normalized = p.normalize(path);
      if (File(normalized).existsSync()) {
        return normalized;
      }
    }
    return null;
  }

  Future<String?> _normalizeExistingSubtitlePath(String? path) async {
    if (path == null || path.trim().isEmpty) return null;
    final normalized = p.normalize(path);
    try {
      if (await File(normalized).exists()) {
        return normalized;
      }
    } catch (_) {}
    return null;
  }

  bool _shouldPreserveSubtitleStateOnRefreshMiss(VideoItem item) {
    if (_subtitlePaths.isEmpty ||
        (_subtitles.isEmpty && _secondarySubtitles.isEmpty)) {
      return false;
    }

    final expectedPaths = <String>{};
    final primaryPath = item.subtitlePath;
    if (primaryPath != null && primaryPath.isNotEmpty) {
      expectedPaths.add(p.normalize(primaryPath));
    }

    final secondaryPath = item.secondarySubtitlePath;
    if (secondaryPath != null && secondaryPath.isNotEmpty) {
      expectedPaths.add(p.normalize(secondaryPath));
    }

    final associated = item.downloadAssociatedSubtitles;
    if (associated.isNotEmpty) {
      for (final path in associated.values) {
        if (path.isEmpty) continue;
        expectedPaths.add(p.normalize(path));
      }
    }
    for (final path in item.localSubtitleGroups.values) {
      if (path.isEmpty) continue;
      expectedPaths.add(p.normalize(path));
    }

    if (expectedPaths.isEmpty) {
      return false;
    }

    for (final path in _subtitlePaths) {
      if (expectedPaths.contains(p.normalize(path))) {
        return true;
      }
    }
    return false;
  }

  Future<List<String>> _collectInitialSubtitlePaths(VideoItem item) async {
    final List<String> paths = <String>[];

    final primaryPath = await _normalizeExistingSubtitlePath(item.subtitlePath);
    if (primaryPath != null) {
      paths.add(primaryPath);
    }

    final secondaryPath = await _normalizeExistingSubtitlePath(
      item.secondarySubtitlePath,
    );
    if (secondaryPath != null && !paths.contains(secondaryPath)) {
      paths.add(secondaryPath);
    }

    if (paths.isNotEmpty) {
      return paths;
    }

    if (!item.blockAutoAssociatedSubtitleSelection) {
      final associatedPath = _resolveFirstAssociatedSubtitlePath(item);
      if (associatedPath != null && !paths.contains(associatedPath)) {
        paths.add(associatedPath);
      }
    }

    if (paths.isNotEmpty) {
      return paths;
    }

    // A logical cloud URI must never enter local filesystem/ffprobe discovery.
    if (isCloudDriveMedia(source: item.sourceRef, path: item.path)) {
      return paths;
    }

    if (!item.blockAutoAssociatedSubtitleSelection) {
      final scannedPaths = await _scanAutoExternalSubtitlePaths(item);
      for (final candidate in scannedPaths) {
        if (paths.length >= 2) break;
        if (!paths.contains(candidate)) {
          paths.add(candidate);
        }
      }
    }

    if (paths.isNotEmpty) {
      return paths;
    }

    final embeddedPath = await _extractEmbeddedSubtitlePath(item);
    if (embeddedPath != null) {
      paths.add(embeddedPath);
    }

    return paths;
  }

  /// Loads only subtitle files already associated with the library item.
  ///
  /// This deliberately avoids directory scans and embedded-track extraction:
  /// those operations can contend with the media decoder for the same file.
  /// Known external subtitles are small and can be parsed while the old native
  /// player is being released, making the transcript available during loading.
  Future<void> refreshAssociatedSubtitles(VideoItem item) async {
    if (_currentItem?.id != item.id) return;
    await _refreshKnownSubtitlesForCurrentItem(item);
  }

  Future<void> _refreshKnownSubtitlesForCurrentItem(VideoItem item) async {
    if (_currentItem?.id != item.id) return;
    final int requestId = _beginSubtitleLoad();
    try {
      final paths = <String>[];

      Future<void> addIfAvailable(String? candidate) async {
        if (candidate == null ||
            candidate.trim().isEmpty ||
            paths.length >= 2) {
          return;
        }
        final normalized = await _normalizeExistingSubtitlePath(candidate);
        if (normalized != null && !paths.contains(normalized)) {
          paths.add(normalized);
        }
      }

      await addIfAvailable(item.subtitlePath);
      await addIfAvailable(item.secondarySubtitlePath);
      if (paths.isEmpty && !item.blockAutoAssociatedSubtitleSelection) {
        for (final candidate in item.downloadAssociatedSubtitles.values) {
          await addIfAvailable(candidate);
          if (paths.length >= 2) break;
        }
      }

      if (paths.isEmpty ||
          requestId != _subtitleLoadRequestId ||
          _currentItem?.id != item.id) {
        return;
      }

      final parsed =
          await Future.wait<List<SubtitleItem>>(<Future<List<SubtitleItem>>>[
            _parseSubtitleFile(paths.first),
            if (paths.length > 1) _parseSubtitleFile(paths[1]),
          ]);
      if (requestId != _subtitleLoadRequestId || _currentItem?.id != item.id) {
        return;
      }
      _commitSubtitleState(
        paths: paths,
        primary: parsed.first,
        secondary: parsed.length > 1 ? parsed[1] : const <SubtitleItem>[],
      );
    } finally {
      _finishSubtitleLoad(requestId);
    }
  }

  Future<List<String>> _scanAutoExternalSubtitlePaths(VideoItem item) async {
    try {
      final entries = await const SubtitleDiscoveryService().scanVideoDirectory(
        videoPath: item.path,
        videoDurationMs: item.durationMs > 0 ? item.durationMs : null,
      );
      return entries
          .where((entry) => entry.isAuto)
          .take(2)
          .map((entry) => entry.path)
          .toList();
    } catch (e) {
      developer.log('Scan auto external subtitles failed', error: e);
      return const <String>[];
    }
  }

  bool _isImageSubtitleCodec(String codecName) {
    final codec = codecName.toLowerCase();
    return codec == 'hdmv_pgs_subtitle' ||
        codec == 'dvd_subtitle' ||
        codec == 'xsub';
  }

  Future<void> _markEmbeddedAttempted(VideoItem item) async {
    if (item.hasAttemptedAutoEmbeddedSubtitleLoad) return;
    item.hasAttemptedAutoEmbeddedSubtitleLoad = true;
    final library = _libraryService;
    if (library == null) return;
    try {
      await library.markAutoEmbeddedSubtitleLoadAttempted(item.id);
      final updated = library.getVideo(item.id);
      if (updated != null && _currentItem?.id == item.id) {
        _currentItem = updated;
      }
    } catch (e) {
      developer.log('Mark embedded subtitle attempt failed', error: e);
    }
  }

  Future<String?> _extractEmbeddedSubtitlePath(VideoItem item) async {
    if (item.blockAutoAssociatedSubtitleSelection ||
        item.prefersManagedAssociatedSubtitles ||
        item.hasAttemptedAutoEmbeddedSubtitleLoad) {
      return null;
    }

    final embeddedService = _embeddedSubtitleService;
    if (embeddedService == null) return null;

    await _markEmbeddedAttempted(item);
    if (_currentItem?.id != item.id) return null;

    try {
      final tracks = await embeddedService.getEmbeddedSubtitles(item.path);
      if (_currentItem?.id != item.id) return null;
      if (tracks.isEmpty) return null;

      final track = tracks.firstWhere(
        (candidate) => !_isImageSubtitleCodec(candidate.codecName),
        orElse: () => tracks.first,
      );
      if (_isImageSubtitleCodec(track.codecName)) {
        return null;
      }

      final subDir = await const TaskSubtitleStorageService().taskDirectory(
        item.id,
        create: true,
      );

      final extractedPath = await embeddedService.extractSubtitle(
        item.path,
        track.index,
        subDir.path,
        codecName: track.codecName,
        videoId: item.id,
      );
      if (extractedPath != null) {
        await _libraryService?.registerManagedSubtitleAsset(
          item.id,
          path: extractedPath,
          kind: ManagedSubtitleAssetKind.embedded,
          displayName: track.title,
        );
      }
      if (_currentItem?.id != item.id) return null;
      return await _normalizeExistingSubtitlePath(extractedPath);
    } catch (e) {
      developer.log('Extract embedded subtitle failed', error: e);
      return null;
    }
  }

  Future<void> _persistResolvedSubtitlePath(
    VideoItem item,
    String primaryPath, {
    String? secondaryPath,
  }) async {
    final library = _libraryService;
    if (library == null) return;
    try {
      final settings = SettingsService();
      final String? existingSecondary;
      if (secondaryPath != null) {
        existingSecondary = await _normalizeExistingSubtitlePath(secondaryPath);
      } else {
        existingSecondary = await _normalizeExistingSubtitlePath(
          item.secondarySubtitlePath,
        );
      }
      await library.updateVideoSubtitles(
        item.id,
        primaryPath,
        settings.autoCacheSubtitles,
        secondarySubtitlePath: existingSecondary,
        isSecondaryCached: settings.autoCacheSubtitles,
      );
      if (_currentItem?.id != item.id) return;
      final updated = library.getVideo(item.id);
      if (updated != null) {
        _currentItem = updated;
      }
    } catch (e) {
      developer.log('Persist resolved subtitle path failed', error: e);
    }
  }

  Future<bool> _loadCloudDriveSubtitles(VideoItem item, int requestId) async {
    if (!isCloudDriveMedia(source: item.sourceRef, path: item.path)) {
      return false;
    }
    // The user cleared subtitles. Neither a sidecar nor an official
    // track may put a selection back.
    if (item.blockAutoAssociatedSubtitleSelection) {
      _noteCloudAutoSubtitle(
        const CloudDriveAutoSubtitleOutcome(
          CloudDriveAutoSubtitleStatus.preserved,
          reason: CloudDriveAutoSubtitleSkipReason.disabled,
        ),
      );
      return false;
    }
    final service = _cloudDrivePlayback;
    cloudDriveSubtitleStatus = '正在查找网盘字幕';
    notifyListeners();
    if (CloudDriveSubtitleTracks.covers(item)) {
      final outcome = await _ensureCloudDriveAutoSubtitle(item);
      if (requestId != _subtitleLoadRequestId || _currentItem?.id != item.id) {
        return true;
      }
      _noteCloudAutoSubtitle(outcome);
      if (outcome.shouldStopRefresh) {
        notifyListeners();
        return true;
      }
      if (requestId != _subtitleLoadRequestId || _currentItem?.id != item.id) {
        return true;
      }
    }
    if (service == null) return false;
    try {
      final cached = await service.loadSubtitles(item);
      if (requestId != _subtitleLoadRequestId || _currentItem?.id != item.id) {
        return true;
      }
      final auto = cached.where((entry) => entry.autoSelect).toList();
      final chosen = auto.isNotEmpty ? auto : cached;
      if (chosen.isEmpty) {
        final transcoded =
            _currentCloudDriveLease?.descriptor.transcoded == true;
        final baidu = item.sourceRef?.cloudDrive?.providerId == 'baidu';
        // Baidu official tracks are not downloaded here. An empty sidecar
        // scan is not "this video has no subtitles".
        cloudDriveSubtitleStatus =
            service.subtitleDiscoveryNote ??
            (baidu
                ? null
                : transcoded
                ? '没有找到文本字幕。转码画质通常不含原画内嵌字幕'
                : '没有找到可用字幕');
        notifyListeners();
        return false;
      }
      final primary = await _parseSubtitleFile(chosen.first.path);
      final secondary = chosen.length > 1
          ? await _parseSubtitleFile(chosen[1].path)
          : <SubtitleItem>[];
      if (requestId != _subtitleLoadRequestId || _currentItem?.id != item.id) {
        return true;
      }
      // A subtitle chosen while this sidecar download was in flight stays.
      if (_subtitlePaths.isNotEmpty) return true;
      final sidecarPaths = <String>[
        chosen.first.path,
        if (chosen.length > 1) chosen[1].path,
      ];
      _invalidateSubtitleParseCache(sidecarPaths);
      // A sidecar scan is not a user intent: committing it must not invalidate
      // an automatic official request that is still running for another scope.
      _commitSubtitleState(
        paths: sidecarPaths,
        primary: primary,
        secondary: secondary,
      );
      cloudDriveSubtitleStatus = service.subtitleDiscoveryNote;
      return true;
    } on CloudDriveFailure catch (error) {
      if (requestId != _subtitleLoadRequestId || _currentItem?.id != item.id) {
        return true;
      }
      cloudDriveSubtitleStatus = error.kind == CloudDriveFailureKind.notLoggedIn
          ? '需要重新登录后才能读取字幕'
          : '字幕获取失败';
      notifyListeners();
      return false;
    }
  }

  void _noteCloudAutoSubtitle(CloudDriveAutoSubtitleOutcome outcome) {
    cloudDriveSubtitleAutoOutcome = outcome;
    _logPlaybackEvent(
      'cloud auto subtitle',
      data: <String, Object?>{
        'status': outcome.status.name,
        'reason': outcome.reason.name,
        if (outcome.trackId != null) 'track': outcome.trackId,
        if (outcome.detail != null) 'detail': outcome.detail,
        'itemId': _currentItem?.id,
      },
    );
  }

  /// Single entry for the automatic official subtitle of the current cloud
  /// file. Repeated calls from a layout change, a restored page or a second
  /// playback page subscribe to the same request instead of downloading again.
  Future<CloudDriveAutoSubtitleOutcome> _ensureCloudDriveAutoSubtitle(
    VideoItem item,
  ) {
    final scope = _autoSubtitleScope(item);
    final running = _autoSubtitleFlight;
    if (running != null && running.scope == scope) return running.future;
    final flight = _AutoSubtitleFlight(scope, _runCloudDriveAutoSubtitle(item));
    _autoSubtitleFlight = flight;
    return flight.future.whenComplete(() {
      if (identical(_autoSubtitleFlight, flight)) _autoSubtitleFlight = null;
    });
  }

  static String _autoSubtitleScope(VideoItem item) {
    final cloud = item.sourceRef?.cloudDrive;
    if (cloud == null) return item.id;
    return [
      item.id,
      cloud.providerId,
      cloud.remoteAccountId,
      cloud.driveId,
      cloud.fileId,
      cloud.revision ?? '',
    ].join('|');
  }

  /// Waits for the cloud runtime once. A first open can outrun the deferred
  /// install; silently returning here is why only the panel could load the
  /// official track afterwards.
  Future<CloudDriveRuntime?> _cloudRuntimeForSubtitles() async {
    final known = CloudDriveRuntime.instance;
    if (known != null) return known;
    if (CloudDriveStartup.pending == null) return null;
    try {
      return await CloudDriveRuntime.ensureInstalled().timeout(
        const Duration(seconds: 20),
      );
    } catch (error) {
      _logPlaybackEvent(
        'cloud runtime not ready for subtitles',
        data: <String, Object?>{
          'error': sanitizeCloudDriveQualityReason(error),
        },
      );
      return null;
    }
  }

  Future<CloudDriveAutoSubtitleOutcome> _runCloudDriveAutoSubtitle(
    VideoItem item,
  ) async {
    final intent = _subtitleIntentGeneration;
    final itemId = item.id;
    final scope = _autoSubtitleScope(item);
    bool stillCurrent() =>
        _currentItem?.id == itemId &&
        _autoSubtitleScope(_currentItem!) == scope &&
        _subtitleIntentGeneration == intent &&
        !_currentItem!.blockAutoAssociatedSubtitleSelection &&
        _subtitlePaths.isEmpty;

    if (item.blockAutoAssociatedSubtitleSelection) {
      return const CloudDriveAutoSubtitleOutcome(
        CloudDriveAutoSubtitleStatus.preserved,
        reason: CloudDriveAutoSubtitleSkipReason.disabled,
      );
    }
    // A persisted selection whose file is gone keeps the manual intent. It must
    // not silently become a different official track; the panel stays available.
    final persistedPrimary = item.subtitlePath;
    if (persistedPrimary != null && persistedPrimary.trim().isNotEmpty) {
      cloudDriveSubtitleStatus = '原选字幕文件缺失，可在字幕管理中重新选择';
      notifyListeners();
      return const CloudDriveAutoSubtitleOutcome(
        CloudDriveAutoSubtitleStatus.preserved,
        reason: CloudDriveAutoSubtitleSkipReason.manual,
        detail: '原选字幕文件缺失',
      );
    }
    if (!CloudDriveSubtitleTracks.covers(item)) {
      return const CloudDriveAutoSubtitleOutcome(
        CloudDriveAutoSubtitleStatus.skipped,
        reason: CloudDriveAutoSubtitleSkipReason.scope,
      );
    }
    if (_subtitlePaths.isNotEmpty) {
      return const CloudDriveAutoSubtitleOutcome(
        CloudDriveAutoSubtitleStatus.preserved,
        reason: CloudDriveAutoSubtitleSkipReason.manual,
      );
    }

    CloudDriveSubtitleTracks? service =
        CloudDriveSubtitleTracks.overrideForTesting;
    if (service == null) {
      final library = _libraryService;
      if (library == null) {
        return const CloudDriveAutoSubtitleOutcome(
          CloudDriveAutoSubtitleStatus.failed,
          reason: CloudDriveAutoSubtitleSkipReason.notReady,
          detail: '媒体库尚未就绪',
        );
      }
      final runtime = await _cloudRuntimeForSubtitles();
      if (runtime == null) {
        return const CloudDriveAutoSubtitleOutcome(
          CloudDriveAutoSubtitleStatus.failed,
          reason: CloudDriveAutoSubtitleSkipReason.notReady,
          detail: '网盘服务尚未就绪',
        );
      }
      service = CloudDriveSubtitleTracks.forApp(
        library: library,
        runtime: runtime,
      );
    }
    if (!stillCurrent()) {
      return const CloudDriveAutoSubtitleOutcome(
        CloudDriveAutoSubtitleStatus.skipped,
        reason: CloudDriveAutoSubtitleSkipReason.superseded,
      );
    }

    // 1. A saved official track is already local. Restore it without touching
    //    the directory, and without downloading the body again.
    var savedCopyUnusable = false;
    final saved = service.savedPreferred(itemId);
    if (saved != null) {
      final savedPath = saved.savedPath;
      if (savedPath != null) {
        final primary = await _parseSubtitleFile(savedPath);
        if (primary.isNotEmpty) {
          if (!stillCurrent()) return _supersededOutcome();
          _commitAutoOfficialSubtitle(savedPath, primary);
          await _persistAutoSubtitlePath(item, savedPath, intent);
          cloudDriveSubtitleStatus = null;
          return CloudDriveAutoSubtitleOutcome(
            CloudDriveAutoSubtitleStatus.applied,
            reason: CloudDriveAutoSubtitleSkipReason.cached,
            trackId: saved.id,
          );
        }
        // The row exists and the file exists, but it is not usable. Re-fetch
        // this one track once instead of returning the bad copy forever.
        savedCopyUnusable = true;
        _logPlaybackEvent(
          'cloud official subtitle cache unusable',
          data: <String, Object?>{'track': saved.id},
        );
      }
    }

    // 2. Ask the official directory once, then download exactly one track.
    try {
      await service.ensureLoaded(itemId);
      if (!stillCurrent()) return _supersededOutcome();
      final listed = service.listFor(itemId);
      if (listed.loginRequired) {
        cloudDriveSubtitleStatus = listed.loginMessage;
        notifyListeners();
        return const CloudDriveAutoSubtitleOutcome(
          CloudDriveAutoSubtitleStatus.failed,
          reason: CloudDriveAutoSubtitleSkipReason.loginRequired,
        );
      }
      final chosen = preferredCloudDriveAutoSubtitle(listed.tracks);
      if (chosen == null) {
        if (listed.failed) {
          cloudDriveSubtitleStatus = listed.failureMessage;
          notifyListeners();
          return CloudDriveAutoSubtitleOutcome(
            CloudDriveAutoSubtitleStatus.failed,
            reason: listed.restricted
                ? CloudDriveAutoSubtitleSkipReason.restricted
                : CloudDriveAutoSubtitleSkipReason.network,
            detail: listed.failureMessage,
          );
        }
        // A confirmed empty directory is a real answer; keep it short-lived and
        // do not turn it into a permanent "loaded" flag.
        cloudDriveSubtitleStatus = null;
        notifyListeners();
        return const CloudDriveAutoSubtitleOutcome(
          CloudDriveAutoSubtitleStatus.skipped,
          reason: CloudDriveAutoSubtitleSkipReason.noTracks,
        );
      }
      final path = await service.load(
        itemId,
        chosen,
        reuseSaved: !savedCopyUnusable,
      );
      if (!stillCurrent()) return _supersededOutcome();
      if (path == null) {
        cloudDriveSubtitleStatus = '字幕获取失败';
        notifyListeners();
        return CloudDriveAutoSubtitleOutcome(
          CloudDriveAutoSubtitleStatus.failed,
          reason: CloudDriveAutoSubtitleSkipReason.network,
          trackId: chosen.id,
        );
      }
      final primary = await _parseSubtitleFile(path);
      if (primary.isEmpty) {
        cloudDriveSubtitleStatus = '字幕获取失败';
        notifyListeners();
        return CloudDriveAutoSubtitleOutcome(
          CloudDriveAutoSubtitleStatus.failed,
          reason: CloudDriveAutoSubtitleSkipReason.unparsable,
          trackId: chosen.id,
        );
      }
      if (!stillCurrent()) return _supersededOutcome();
      _commitAutoOfficialSubtitle(path, primary);
      await _persistAutoSubtitlePath(item, path, intent);
      cloudDriveSubtitleStatus = null;
      return CloudDriveAutoSubtitleOutcome(
        CloudDriveAutoSubtitleStatus.applied,
        trackId: chosen.id,
      );
    } catch (error) {
      if (!stillCurrent()) return _supersededOutcome();
      cloudDriveSubtitleStatus = '字幕获取失败';
      notifyListeners();
      _logPlaybackEvent(
        'cloud auto subtitle failed',
        data: <String, Object?>{
          'type': error is CloudDriveFailure
              ? 'CloudDriveFailure(${error.kind.name})'
              : error.runtimeType.toString(),
          'reason': sanitizeCloudDriveQualityReason(error),
        },
      );
      return CloudDriveAutoSubtitleOutcome(
        CloudDriveAutoSubtitleStatus.failed,
        reason:
            error is CloudDriveFailure &&
                error.kind == CloudDriveFailureKind.notLoggedIn
            ? CloudDriveAutoSubtitleSkipReason.loginRequired
            : CloudDriveAutoSubtitleSkipReason.network,
        detail: sanitizeCloudDriveQualityReason(error),
      );
    }
  }

  static CloudDriveAutoSubtitleOutcome _supersededOutcome() {
    return const CloudDriveAutoSubtitleOutcome(
      CloudDriveAutoSubtitleStatus.skipped,
      reason: CloudDriveAutoSubtitleSkipReason.superseded,
    );
  }

  /// Commits an automatic official track. It does not bump the intent
  /// generation: the automatic choice is not a user intent.
  void _commitAutoOfficialSubtitle(String path, List<SubtitleItem> primary) {
    _invalidateSubtitleParseCache(<String>[path]);
    _commitSubtitleState(
      paths: <String>[path],
      primary: primary,
      secondary: const <SubtitleItem>[],
    );
  }

  /// Writes the automatic selection only when it is still the newest one.
  ///
  /// The previous code committed the UI state and then awaited the library
  /// write, so a manual selection made in between was overwritten by the
  /// delayed automatic path.
  Future<void> _persistAutoSubtitlePath(
    VideoItem item,
    String path,
    int intent,
  ) async {
    if (_subtitleIntentGeneration != intent) return;
    final library = _libraryService;
    if (library == null) return;
    try {
      final current = library.getVideo(item.id);
      if (current == null) return;
      if (_currentItem?.id != item.id) return;
      final existingPrimary = current.subtitlePath;
      if (existingPrimary != null &&
          existingPrimary.isNotEmpty &&
          p.normalize(existingPrimary) !=
              p.normalize(item.subtitlePath ?? '')) {
        // Someone else wrote a selection while this request was in flight.
        return;
      }
      if (current.blockAutoAssociatedSubtitleSelection &&
          (current.subtitlePath == null ||
              current.subtitlePath!.trim().isEmpty)) {
        return;
      }
      if (_subtitleIntentGeneration != intent) return;
      await library.updateVideoSubtitles(
        item.id,
        path,
        SettingsService().autoCacheSubtitles,
      );
      if (_currentItem?.id != item.id) return;
      final updated = library.getVideo(item.id);
      if (updated != null &&
          _subtitleIntentGeneration == intent &&
          _subtitlePaths.isNotEmpty) {
        _currentItem = updated;
      }
    } catch (error) {
      developer.log('Persist auto official subtitle failed', error: error);
    }
  }

  Future<void> _refreshSubtitlesForCurrentItem(VideoItem item) async {
    if (_currentItem?.id != item.id) return;
    final int requestId = _beginSubtitleLoad();
    try {
      final List<String> paths = await _collectInitialSubtitlePaths(item);
      if (requestId != _subtitleLoadRequestId) return;
      if (_currentItem?.id != item.id) return;
      if (paths.isEmpty) {
        if (await _loadCloudDriveSubtitles(item, requestId)) return;
        if (requestId != _subtitleLoadRequestId) return;
        if (_currentItem?.id != item.id) return;
        if (_shouldPreserveSubtitleStateOnRefreshMiss(item)) {
          return;
        }
        // A refresh miss is not a user intent. Using setSubtitleState here would
        // bump the intent generation of the automatic official request that just
        // started for this same refresh.
        _commitSubtitleState(
          paths: const <String>[],
          primary: const <SubtitleItem>[],
          secondary: const <SubtitleItem>[],
        );
        return;
      }

      final String? normalizedPrimary = await _normalizeExistingSubtitlePath(
        item.subtitlePath,
      );
      if (normalizedPrimary == null && paths.isNotEmpty) {
        await _persistResolvedSubtitlePath(
          item,
          paths.first,
          secondaryPath: paths.length > 1 ? paths[1] : null,
        );
        if (requestId != _subtitleLoadRequestId) return;
        if (_currentItem?.id != item.id) return;
      }

      final parsed =
          await Future.wait<List<SubtitleItem>>(<Future<List<SubtitleItem>>>[
            _parseSubtitleFile(paths[0]),
            if (paths.length > 1) _parseSubtitleFile(paths[1]),
          ]);
      final primary = parsed.first;
      final secondary = parsed.length > 1 ? parsed[1] : <SubtitleItem>[];
      if (requestId != _subtitleLoadRequestId) return;
      if (_currentItem?.id != item.id) return;

      _commitSubtitleState(
        paths: paths,
        primary: primary,
        secondary: secondary,
      );
    } finally {
      _finishSubtitleLoad(requestId);
    }
  }

  /// 设置外部控制器（用于UI创建的控制器移交给服务管理）
  Future<void> setController(VideoPlayerController controller) async {
    if (!identical(controller, _controller)) {
      requireCommunityLocalMedia(controller.dataSource);
    }
    // 如果是同一个控制器，无需处理
    if (_controller == controller) return;
    _playRequestId++;
    _seekRequestId++;
    _pendingSeekRequestId = null;
    _invalidatePlaybackSpeedCommands();

    final previousController = _controller;
    final bool shouldDisposePrevious = _serviceOwnsController;

    // 先移除旧控制器的监听器，防止状态冲突
    if (previousController != null) {
      _controller = null;
      _controllerItemId = null;
      _serviceOwnsController = false;
      await _detachController(
        previousController,
        disposeController: shouldDisposePrevious,
        pauseIfPlaying: true,
      );
    }

    _controller = controller;
    _controllerItemId = _currentItem?.id;
    // setController is a transfer, not a borrowed reference. Centralizing
    // native-player ownership lets mobile media switches await the real decoder
    // release before constructing the replacement.
    _serviceOwnsController = true;
    _isSourceMissing = false;
    _attachNativePositionStream(controller);
    _logPlaybackEvent(
      'controller attached',
      data: <String, Object?>{
        'initialized': controller.value.isInitialized,
        'isPlaying': controller.value.isPlaying,
      },
    );

    // 立即同步状态
    if (_controller!.value.isInitialized) {
      _capturePlaybackSpeedFromController(_controller!);
      _duration = _presentationDuration(_controller!.value.duration);
      _position = _controller!.value.position;
      _bufferedPosition = _readBufferedPosition(_controller!);
      _state = _controller!.value.isPlaying
          ? PlaybackState.playing
          : PlaybackState.paused;
      _hasPlaybackCompleted =
          !_controller!.value.isPlaying &&
          _hasReachedPlaybackEnd(_position, _duration);
      _resetPlaybackTimeline(_position, running: _controller!.value.isPlaying);
    }
    _lastControllerIsPlaying = _controller!.value.isPlaying;

    // 添加新监听器
    _controller!.addListener(_onControllerUpdate);
    unawaited(_applyMuteStateToController(reason: 'controller attached'));

    // 启动进度追踪
    if (_state == PlaybackState.playing) {
      _startProgressTracking();
    } else {
      _stopProgressTracking();
    }

    _syncWakelockWithState();
    notifyListeners();
  }

  Future<void> _applyConfiguredPlaybackSpeed(
    VideoPlayerController controller, {
    double? preservedSpeed,
  }) async {
    final settings = SettingsService();
    final targetSpeed =
        preservedSpeed ??
        (_currentItem?.sourceRef?.podcast != null &&
                PodcastPlaybackHooks.speed != null
            ? PodcastPlaybackHooks.speed!(_currentItem!)
            : settings.effectiveGlobalPlaybackSpeed);
    if ((controller.value.playbackSpeed - targetSpeed).abs() < 0.001) {
      _playbackSpeed = targetSpeed;
      _confirmedPlaybackSpeed = targetSpeed;
      _lastDispatchedPlaybackSpeed = targetSpeed;
      return;
    }
    _lastDispatchedPlaybackSpeed = targetSpeed;
    await controller.setPlaybackSpeed(targetSpeed);
    _playbackSpeed = targetSpeed;
    _confirmedPlaybackSpeed = targetSpeed;
  }

  Future<void> reloadPreferencesForTrial() async {
    await _playbackSpeedCommandTail;
    await _restorePersistedMuteState(notify: false);
    await _applyMuteStateToController(reason: 'default settings trial');
    final current = _controller;
    if (current != null && current.value.isInitialized) {
      await _applyConfiguredPlaybackSpeed(current);
    }
    notifyListeners();
  }

  void _capturePlaybackSpeedFromController(
    VideoPlayerController controller, {
    bool notify = false,
  }) {
    if (!controller.value.isInitialized) return;
    // Platform callbacks may briefly expose the old rate while a new rate
    // command is in flight. The requested rate owns the timeline until the
    // matching command completes.
    if (_pendingPlaybackSpeed != null) return;
    final speed = controller.value.playbackSpeed;
    if ((_confirmedPlaybackSpeed - speed).abs() < 0.001) return;
    _playbackSpeed = speed;
    _confirmedPlaybackSpeed = speed;
    _lastDispatchedPlaybackSpeed = speed;
    _nativePresentationPlaybackSpeed = speed;
    if (_timelineClock.isInitialized) {
      _timelineClock.setRate(speed);
    }
    if (notify) notifyListeners();
  }

  /// Changes the speed of the active playback session without changing the
  /// persisted speed-lock preference.
  Future<void> setPlaybackSpeed(double speed) {
    return _setPlaybackSpeed(speed, notifyStateChange: true);
  }

  Future<void> _setPlaybackSpeed(
    double speed, {
    required bool notifyStateChange,
  }) async {
    if (!speed.isFinite || speed <= 0) return;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final requestId = ++_playbackSpeedRequestId;
    // Invalidate a queued native request before serializing the replacement.
    // This is important for a quick press/release: libmpv must see at most one
    // enter command followed by one restore command, never overlapping calls.
    // ignore: invalid_use_of_visible_for_testing_member
    NativeVideoPlayerMediaKit.cancelPendingRateChange(controller.playerId);
    final changed = (_playbackSpeed - speed).abs() >= 0.001;
    _pendingPlaybackSpeed = speed;
    _playbackSpeed = speed;
    if (changed && notifyStateChange) notifyListeners();

    final previousCommand = _playbackSpeedCommandTail;
    final command = _runPlaybackSpeedCommand(
      previousCommand: previousCommand,
      controller: controller,
      requestId: requestId,
      speed: speed,
      notifyStateChange: notifyStateChange,
    );
    _playbackSpeedCommandTail = command.catchError((Object _) {});
    await command;
  }

  Future<void> _runPlaybackSpeedCommand({
    required Future<void> previousCommand,
    required VideoPlayerController controller,
    required int requestId,
    required double speed,
    required bool notifyStateChange,
  }) async {
    try {
      await previousCommand;
    } catch (_) {
      // A failed older command must not prevent the latest requested speed
      // from being applied.
    }

    if (requestId != _playbackSpeedRequestId || controller != _controller) {
      return;
    }

    try {
      if ((_lastDispatchedPlaybackSpeed - speed).abs() >= 0.001) {
        _lastDispatchedPlaybackSpeed = speed;
        await controller.setPlaybackSpeed(speed);
      }
      if (requestId != _playbackSpeedRequestId || controller != _controller) {
        return;
      }

      _pendingPlaybackSpeed = null;
      _playbackSpeed = speed;
      _confirmedPlaybackSpeed = speed;
      _nativePresentationPlaybackSpeed = speed;
      if (_timelineClock.isInitialized) {
        // A rate transition changes only the slope of the existing media
        // timeline. In particular, never re-anchor to controller.position
        // here: Android's platform player and libmpv publish that sample with
        // different delays, so using it as a new origin makes every overlay
        // jump at both the press and release boundaries.
        _timelineClock.setRate(speed);
      } else {
        _resetPlaybackTimeline(
          positionNotifier.value,
          running: _shouldTimelineRun(),
          rate: speed,
        );
      }
    } catch (_) {
      _lastDispatchedPlaybackSpeed = _confirmedPlaybackSpeed;
      if (requestId != _playbackSpeedRequestId || controller != _controller) {
        return;
      }
      _pendingPlaybackSpeed = null;
      _playbackSpeed = _confirmedPlaybackSpeed;
      _nativePresentationPlaybackSpeed = _confirmedPlaybackSpeed;
      if (_timelineClock.isInitialized) {
        _timelineClock.setRate(_confirmedPlaybackSpeed);
      }
      if (notifyStateChange) notifyListeners();
      rethrow;
    }
  }

  /// Applies a temporary rate without changing the persisted/global rate.
  /// Repeated calls retain the original base rate until [endTemporaryPlaybackSpeed].
  Future<void> beginTemporaryPlaybackSpeed(double speed) {
    if (!speed.isFinite || speed <= 0) return Future<void>.value();
    _temporaryPlaybackBaseSpeed ??= _playbackSpeed;
    // The local long-press overlay already owns the transient visual state.
    // Broadcasting this ephemeral speed through the whole application would
    // rebuild unrelated consumers in the exact frame where native rate
    // switching needs the most headroom.
    return _setPlaybackSpeed(speed, notifyStateChange: false);
  }

  /// Restores the stable rate that was active before the temporary session.
  Future<void> endTemporaryPlaybackSpeed() {
    final restoreSpeed = _temporaryPlaybackBaseSpeed;
    _temporaryPlaybackBaseSpeed = null;
    if (restoreSpeed == null) return Future<void>.value();
    return _setPlaybackSpeed(restoreSpeed, notifyStateChange: false);
  }

  void _invalidatePlaybackSpeedCommands() {
    _playbackSpeedRequestId++;
    _pendingPlaybackSpeed = null;
    _temporaryPlaybackBaseSpeed = null;
    _lastDispatchedPlaybackSpeed = _confirmedPlaybackSpeed;
    _nativePresentationPlaybackSpeed = _confirmedPlaybackSpeed;
    _playbackSpeedCommandTail = Future<void>.value();
  }

  /// 清除当前控制器引用（当UI销毁控制器时调用）
  void clearController() {
    _clearInitialPositionGuard();
    if (_controller != null) {
      _invalidatePlaybackSpeedCommands();
      _logPlaybackEvent(
        'controller cleared',
        data: <String, Object?>{
          'itemId': _currentItem?.id,
          'positionMs': _position.inMilliseconds,
        },
      );
      try {
        _controller!.removeListener(_onControllerUpdate);
      } catch (e) {
        // 忽略
      }
      _cancelNativePositionStream();
      _controller = null;
      _controllerItemId = null;
      _serviceOwnsController = false;
      _timelineClock.setRunning(false);
    }
  }

  /// 更新媒体元数据
  Future<void> updateMetadata(VideoItem item) async {
    item = _communityPlaybackItem(item);
    if (_currentItem?.id != item.id) {
      _clearSubtitleStateForMediaSwitch();
    }
    _currentItem = item;
    final generation = _beginPlaybackSession(
      item,
      desiredPlaying: _controller?.value.isPlaying ?? false,
    );
    final activeController = _controller;
    if (activeController != null &&
        activeController.value.isInitialized &&
        !activeController.value.hasError) {
      _transitionPlaybackSession(
        generation,
        _controllerHasRequiredVideoOutput(item, activeController)
            ? PlaybackSessionPhase.ready
            : PlaybackSessionPhase.videoOutputDeferred,
        controller: activeController,
      );
    }
    _logPlaybackEvent(
      'metadata updated',
      data: <String, Object?>{
        'itemId': item.id,
        'title': item.title,
        'type': item.type.name,
      },
    );

    if (_playlistManager != null) {
      _playlistManager!.anchorCurrentItem(item);
    }

    // 如果控制器已就绪，确保时长准确
    if (_controller != null && _controller!.value.isInitialized) {
      _duration = _presentationDuration(_controller!.value.duration);
    }

    notifyListeners();
  }

  /// 跳转到上一句字幕
  Future<void> seekToPreviousSubtitle({
    String source = 'subtitle_navigation',
  }) async {
    if (_subtitles.isEmpty || _controller == null) return;
    _logPlaybackEvent(
      'seek to previous subtitle requested',
      data: <String, Object?>{
        'source': source,
        'positionMs': _position.inMilliseconds,
      },
    );

    final int currentIndex = _findSubtitleIndexForCurrentPosition();
    if (currentIndex < 0 || currentIndex >= _subtitles.length) return;
    final currentStart = _subtitles[currentIndex].startTime;

    // 如果当前位置在当前字幕开始后1秒以上，跳到当前字幕开始
    if (_position > currentStart + const Duration(seconds: 1)) {
      await seekTo(currentStart, source: source);
      return;
    }

    // 否则跳到上一句字幕
    if (currentIndex > 0) {
      await seekTo(_subtitles[currentIndex - 1].startTime, source: source);
    }
  }

  /// 跳转到下一句字幕
  Future<void> seekToNextSubtitle({
    String source = 'subtitle_navigation',
  }) async {
    if (_subtitles.isEmpty || _controller == null) return;
    _logPlaybackEvent(
      'seek to next subtitle requested',
      data: <String, Object?>{
        'source': source,
        'positionMs': _position.inMilliseconds,
      },
    );

    final int currentIndex = _findSubtitleIndexForCurrentPosition();
    if (currentIndex == -1) {
      await seekTo(_subtitles.first.startTime, source: source);
      return;
    }

    // 跳到下一句字幕
    if (currentIndex < _subtitles.length - 1) {
      await seekTo(_subtitles[currentIndex + 1].startTime, source: source);
    }
  }

  int _findSubtitleIndexForCurrentPosition() {
    return _subtitleTimeline.indexAtMs(_position.inMilliseconds);
  }

  /// 播放媒体
  Future<void> play(
    VideoItem item, {
    Duration? startPosition,
    bool autoPlay = true,
    bool forceRecreate = false,
    bool userInitiatedWatch = true,
    bool keepBookmarkOnFailure = false,
    String? cloudDriveQualityId,
    int? bilibiliQualityId,
    bool allowCloudDriveFallback = true,
    int? directEpoch,
  }) {
    try {
      item = _communityPlaybackItem(item);
    } catch (error, stack) {
      return Future<void>.error(error, stack);
    }
    final epoch = directEpoch ?? _directEpoch;
    final pending = _onlinePlayInFlight;
    if (!forceRecreate &&
        pending != null &&
        _onlinePlayItemId == item.id &&
        _onlinePlayEpoch == epoch &&
        _currentItem?.id == item.id &&
        _onlineStartup?.isPending == true &&
        _onlineStartup!.remaining > Duration.zero) {
      // Route/notification ownership can announce the same media twice. Join
      // its preparation instead of replacing the request which owns the gate.
      return () async {
        if (startPosition != null && startPosition != _onlineStartup!.target) {
          await seekTo(startPosition, source: 'pending_online_startup');
        }
        if (_activePlayInvocationGeneration == _session.generation) {
          await (autoPlay ? resume() : pause());
        } else {
          _setDesiredPlaying(autoPlay);
          notifyListeners();
        }
        await pending;
      }();
    }
    final recreatePending =
        pending != null &&
        _onlinePlayItemId == item.id &&
        _onlinePlayEpoch != epoch;
    final completed = Completer<void>();
    final operation = completed.future;
    // Make reentrant route notifications joinable before _playImpl publishes.
    _onlinePlayInFlight = operation;
    _onlinePlayItemId = item.id;
    _onlinePlayEpoch = epoch;
    _activeOpenBudget?.cancel();
    final operationBudget = PlaybackStartupContext(limit: debugRecoveryLimit);
    _activeOpenBudget = operationBudget;
    unawaited(() async {
      int? generation;
      PlaybackStartupContext? sourceBudget;
      try {
        final work = _playImpl(
          item,
          startPosition: startPosition,
          autoPlay: autoPlay,
          forceRecreate: forceRecreate || recreatePending,
          userInitiatedWatch: userInitiatedWatch,
          keepBookmarkOnFailure: keepBookmarkOnFailure,
          cloudDriveQualityId: cloudDriveQualityId,
          bilibiliQualityId: bilibiliQualityId,
          allowCloudDriveFallback: allowCloudDriveFallback,
          directEpoch: directEpoch,
          operationBudget: operationBudget,
        );
        generation = _session.generation;
        sourceBudget = _onlineStartup?.isPending == true
            ? _onlineStartup
            : null;
        // Share the deadline without racing the source's normal failure
        // handler. That handler preserves bookmarks, typed provider errors
        // and the latest intent used by the existing queue retry policy.
        final sourceDeadline = sourceBudget == null
            ? null
            : PlaybackStartupContext.continuation(sourceBudget);
        await operationBudget.run(sourceDeadline?.run(work) ?? work);
        operationBudget.ready();
        completed.complete();
      } catch (error) {
        final current =
            _currentItem?.id == item.id && _session.generation == generation;
        final alreadyReady =
            current &&
            _controller?.value.isInitialized == true &&
            (_onlineStartup == null || _onlineStartup!.isReady) &&
            (_state == PlaybackState.playing || _state == PlaybackState.paused);
        if (alreadyReady) {
          // History persistence is allowed to finish after the transport is
          // ready; slow storage must not tear down healthy playback.
          operationBudget.ready();
        } else if (!operationBudget.isCancelled &&
            sourceBudget?.isCancelled != true) {
          // The operation abort releases its gateway, which cancels a pending
          // source context. Record the failure first so cleanup cannot turn a
          // timed-out, retryable source into an abandoned/cancelled attempt.
          sourceBudget?.fail(error);
          operationBudget.fail(error);
          if (current) {
            _onlineStartup?.fail(error);
            _playRequestId++;
            _activePlayInvocationGeneration = null;
            // Keep the source attempt's latest intent for the existing bounded
            // retry policy. The failed session itself is parked below.
            _state = keepBookmarkOnFailure
                ? PlaybackState.paused
                : PlaybackState.error;
            _stopProgressTracking();
            _transitionPlaybackSession(
              generation!,
              keepBookmarkOnFailure
                  ? PlaybackSessionPhase.resolving
                  : PlaybackSessionPhase.failed,
              desiredPlaying: false,
              error: keepBookmarkOnFailure ? null : '播放加载失败，请重试：$error',
            );
            unawaited(_disposeController());
            notifyListeners();
          }
        }
        completed.complete();
      } finally {
        if (identical(_activeOpenBudget, operationBudget)) {
          _activeOpenBudget = null;
        }
        if (identical(_onlinePlayInFlight, operation)) {
          _onlinePlayInFlight = null;
          _onlinePlayItemId = null;
          _onlinePlayEpoch = null;
        }
      }
    }());
    return operation;
  }

  Future<void> _playImpl(
    VideoItem item, {
    Duration? startPosition,
    bool autoPlay = true,
    bool forceRecreate = false,
    bool userInitiatedWatch = true,
    bool keepBookmarkOnFailure = false,
    String? cloudDriveQualityId,
    int? bilibiliQualityId,
    bool allowCloudDriveFallback = true,
    int? directEpoch,
    PlaybackStartupContext? operationBudget,
  }) async {
    final switchEpoch = directEpoch ?? _directEpoch;
    final needsNewTransport =
        forceRecreate || !_controllerIsReusableForItem(item);
    final preserveLiveSettings =
        needsNewTransport && _controller != null && _currentItem?.id == item.id;
    final queuedStartup = _pendingBilibiliStartup;
    _pendingBilibiliStartup = null;
    final queuedOnline = _pendingOnlineStartup;
    _pendingOnlineStartup = null;
    if (needsNewTransport) {
      _bilibiliStartup?.geometry.removeListener(_onBilibiliGeometryChanged);
      _bilibiliVisibleStartup?.cancel();
      _bilibiliVisibleStartup = null;
      _onlineStartup?.cancel();
      _bilibiliStartup = item.sourceRef?.kind == MediaSourceKind.bilibiliStream
          ? (queuedStartup?.itemId == item.id
                ? queuedStartup!.context
                : BilibiliStartupContext())
          : null;
      _onlineStartup =
          _bilibiliStartup ??
          (queuedOnline?.itemId == item.id
              ? queuedOnline!.context
              : _isOnlineMedia(item)
              ? PlaybackStartupContext()
              : null);
      _bilibiliStartupItemId = _bilibiliStartup == null ? null : item.id;
      if (_streamDisplayAspectRatioItemId != item.id) {
        _setStreamDisplayAspectRatio(null, null);
      }
      _bilibiliStartup?.geometry.reportVideo(
        _bilibiliStreamingService?.cachedDisplayAspectRatioFor(item),
      );
      _bilibiliStartup?.geometry.addListener(_onBilibiliGeometryChanged);
      // Publish the new item and its cover gate together, before any await or
      // mountable-controller notification can expose an initialize frame.
      _coveringUntilVisibleVideoFrame =
          _onlineStartup != null && item.type == MediaType.video;
      _visibleVideoFrameEpoch++;
    } else {
      queuedStartup?.context.ready();
    }
    final startup = _onlineStartup;
    Future<T> withinStartup<T>(Future<T> work) =>
        (startup ?? operationBudget)?.run(work) ?? work;
    void watchCandidate(VideoPlayerController candidate) {
      void abort() {
        if (identical(_controller, candidate)) {
          if ((_onlineStartup == null || _onlineStartup!.isReady) &&
              (_state == PlaybackState.playing ||
                  _state == PlaybackState.paused)) {
            return;
          }
          unawaited(_disposeController());
        } else {
          unawaited(_disposeTrackedController(candidate));
        }
      }

      operationBudget?.bindAbort(abort);
      startup?.bindAbort(abort);
    }

    if (needsNewTransport && startup != null) startup.desiredPlaying = autoPlay;
    // Once-per-session UX hint on silent Linux hosts (no ALSA card).
    unawaited(LinuxAudioDevice.maybeShowNoAudioDeviceHint());
    final shouldCheckSyncedProgress =
        !item.isTransient && !(_currentItem?.id == item.id && isPlaying);
    _streamQualitySwitchRequestId++;
    _isSwitchingStreamQuality = false;
    final int playRequestId = ++_playRequestId;
    final int sessionGeneration = _beginPlaybackSession(
      item,
      desiredPlaying: autoPlay,
    );
    final previousItemId = _currentItem?.id;
    if (previousItemId != item.id) {
      // The first notification already identifies the target media. Publish
      // its empty timeline in the same snapshot, before progress sync or any
      // controller work can yield and let a page adopt the previous transcript.
      _clearSubtitleStateForMediaSwitch();
      _currentItem = item;
      _streamAudioQualities = const [];
      _selectedStreamAudioQuality = null;
      _isSourceMissing = false;
      _duration = Duration(
        milliseconds: item.durationMs > 0 ? item.durationMs : 0,
      );
      _position =
          startPosition ??
          (item.lastPositionMs > 0
              ? Duration(milliseconds: item.lastPositionMs)
              : Duration.zero);
      _bufferedPosition = Duration.zero;
      _resetPlaybackTimeline(_position, running: false);
      if (isCloudDriveMedia(source: item.sourceRef, path: item.path)) {
        cloudDriveFailureKind = null;
        cloudDriveSubtitleStatus = null;
        cloudDriveNotice = item.type == MediaType.audio ? '正在连接音频' : '正在连接网盘';
      }
      _state = PlaybackState.loading;
      notifyListeners();
    }
    _activePlayInvocationGeneration = sessionGeneration;
    // Restored Bilibili Mini has no controller and stays paused until play().
    // Mark loading before the first await so the playback page does not fire a
    // second play() without startPosition and reopen at t=0.
    if (forceRecreate ||
        previousItemId != item.id ||
        !_controllerIsReusableForItem(item)) {
      _state = PlaybackState.loading;
      notifyListeners();
    } else if (autoPlay) {
      // Mini chrome follows desiredPlaying. Publish the tap immediately so the
      // play button does not sit on a triangle while playurl/initialize run.
      notifyListeners();
    }
    final checkSyncedProgress = beforeLibraryPlayback;
    if (shouldCheckSyncedProgress && checkSyncedProgress != null) {
      final savedBeforeSync = item.lastPositionMs;
      try {
        final syncing = checkSyncedProgress(item.id);
        await (startup?.run(syncing) ?? syncing);
      } catch (_) {
        // Opening local media must remain available while peers are offline.
      }
      if (_playRequestId != playRequestId ||
          _session.generation != sessionGeneration) {
        return;
      }
      if (item.lastPositionMs != savedBeforeSync &&
          (startPosition == null ||
              startPosition.inMilliseconds == savedBeforeSync)) {
        startPosition = Duration(milliseconds: item.lastPositionMs);
      }
    }
    _prepareLibraryWatchCycle(item, userInitiatedWatch: userInitiatedWatch);
    bool shouldPlayNow() => _session.generation == sessionGeneration
        ? _session.desiredPlaying
        : autoPlay;
    _seekRequestId++;
    _pendingSeekRequestId = null;
    _clearInitialPositionGuard();
    _cancelHopSeekDispatch();
    _seekVerificationTimer?.cancel();
    _seekVerificationTimer = null;
    VideoPlayerController? requestController;
    MaterializedMediaLease? requestMaterializedLease;
    BilibiliPreparedPlayback? requestBilibiliPlayback;
    CloudDrivePreparedPlayback? preparedCloud;
    CloudDrivePlaybackBudget? cloudBudget;
    Future<
      ({MaterializedMediaLease? materialized, BilibiliPreparedPlayback? online})
    >?
    earlyBilibiliSource;

    Future<void> releaseRequestBilibiliPlayback() async {
      final playback = requestBilibiliPlayback;
      requestBilibiliPlayback = null;
      if (playback != null) {
        await _bilibiliStreamingService?.releasePlayback(playback);
      }
    }

    Future<void> releaseEarlyBilibiliSource() async {
      final pending = earlyBilibiliSource;
      earlyBilibiliSource = null;
      if (pending == null) return;
      if (startup?.isCancelled == true || startup?.hasFailed == true) {
        unawaited(
          pending
              .then((source) async {
                await source.materialized?.release();
                if (source.online != null) {
                  await _bilibiliStreamingService?.releasePlayback(
                    source.online!,
                  );
                }
              }, onError: (Object _, StackTrace _) {})
              .catchError((Object _, StackTrace _) {}),
        );
        return;
      }
      try {
        final source = await pending;
        await source.materialized?.release();
        if (source.online != null) {
          await _bilibiliStreamingService?.releasePlayback(source.online!);
        }
      } catch (_) {
        // Preparation failures are handled by play()'s normal error path.
      }
    }

    try {
      startup?.check();
      _hasPlaybackCompleted = false;

      // 修复：如果startPosition为null且当前位置已在末尾（播放完成状态），
      // 则从头开始播放，避免无法跳转上一集或进入已完成的视频
      if (_currentItem?.id == item.id &&
          startPosition == null &&
          _position > Duration.zero &&
          PlaybackBehaviorPolicy.normalizeEpisodeStartPosition(
                savedPosition: _position,
                duration: _duration,
              ) ==
              Duration.zero) {
        startPosition = Duration.zero;
        _logPlaybackEvent(
          'play from beginning due to completion',
          data: <String, Object?>{
            'itemId': item.id,
            'previousPositionMs': _position.inMilliseconds,
          },
        );
      }

      _logPlaybackEvent(
        'play requested',
        data: <String, Object?>{
          'itemId': item.id,
          'title': item.title,
          'autoPlay': autoPlay,
          'startPositionMs': startPosition?.inMilliseconds,
          'forceRecreate': forceRecreate,
          if (forceRecreate &&
              isCloudDriveMedia(source: item.sourceRef, path: item.path))
            'caller': StackTrace.current
                .toString()
                .split('\n')
                .take(4)
                .join(' | ')
                .replaceAll(RegExp(r'https?://\S+'), '<url>'),
        },
      );

      if (!forceRecreate &&
          previousItemId == item.id &&
          _controllerIsReusableForItem(item) &&
          _state != PlaybackState.playing &&
          item.sourceRef?.kind == MediaSourceKind.bilibiliStream &&
          _selectedStreamQuality?.isLocalMaterialized != true &&
          _bilibiliStreamingService?.hasPreferredAudioQuality(item.id) !=
              true &&
          _libraryService != null) {
        final local = await _libraryService!
            .acquireExistingMaterializedPlayback(item);
        if (local != null) {
          await local.release();
          if (!_isCurrentPlayRequest(playRequestId, item.id)) return;
          forceRecreate = true;
        }
      }

      if (!forceRecreate &&
          previousItemId == item.id &&
          _controllerIsReusableForItem(item)) {
        final controller = _controller!;
        final authoritativePosition = _position;
        _currentItem = item;
        _transitionPlaybackSession(
          sessionGeneration,
          _controllerHasRequiredVideoOutput(item, controller)
              ? PlaybackSessionPhase.controllerMountable
              : PlaybackSessionPhase.videoOutputDeferred,
          controller: controller,
        );
        _preloadTriggered = false;
        _duration = _presentationDuration(controller.value.duration);
        // Keep the service timeline as the source of truth. The native
        // controller can briefly report byte-zero while a network stream is
        // resuming, which must not overwrite a restored position.
        _bufferedPosition = _readBufferedPosition(controller);
        _lastControllerIsPlaying = controller.value.isPlaying;

        _capturePlaybackSpeedFromController(controller);
        await _applyMuteStateToController(reason: 'reuse existing controller');
        if (!_isCurrentPlayRequest(
          playRequestId,
          item.id,
          controller: controller,
        )) {
          return;
        }

        // 修复：如果startPosition为null且视频已播放完成（位置在末尾），则从头开始播放
        if (startPosition == null &&
            _position > Duration.zero &&
            PlaybackBehaviorPolicy.normalizeEpisodeStartPosition(
                  savedPosition: _position,
                  duration: _duration,
                ) ==
                Duration.zero) {
          startPosition = Duration.zero;
          _logPlaybackEvent(
            'reuse controller: play from beginning due to completion',
            data: <String, Object?>{'itemId': item.id},
          );
        }

        if (startPosition != null &&
            startPosition >= Duration.zero &&
            (_duration <= Duration.zero || startPosition < _duration)) {
          await seekTo(startPosition, source: 'play_same_item_reuse');
          if (!_isCurrentPlayRequest(
            playRequestId,
            item.id,
            controller: controller,
          )) {
            return;
          }
        }

        // Re-opening an already restored online card must not trust a stale
        // byte-zero native sample. Re-anchor the controller before allowing
        // play so the first decoded fragment is the saved position.
        if (startPosition == null &&
            item.sourceRef?.kind == MediaSourceKind.bilibiliStream &&
            controller.value.isInitialized &&
            (controller.value.position.inMilliseconds -
                        authoritativePosition.inMilliseconds)
                    .abs() >
                _seekVerificationToleranceMs) {
          await _seekInitialPosition(controller, authoritativePosition);
          if (!_isCurrentPlayRequest(
            playRequestId,
            item.id,
            controller: controller,
          )) {
            return;
          }
        }

        _resetPlaybackTimeline(
          _position,
          running: shouldPlayNow() && controller.value.isPlaying,
        );

        if (item.sourceRef?.kind == MediaSourceKind.bilibiliStream) {
          await _awaitBilibiliVideoTrackPolicy();
          if (!_isCurrentPlayRequest(
            playRequestId,
            item.id,
            controller: controller,
          )) {
            return;
          }
        }

        if (shouldPlayNow()) {
          PlaybackStartupContext? reuseStartup;
          if (_isOnlineMedia(item)) {
            _onlineStartup?.cancel();
            if (item.sourceRef?.kind == MediaSourceKind.bilibiliStream) {
              final geometry = _bilibiliStartup?.geometry;
              _bilibiliStartup?.geometry.removeListener(
                _onBilibiliGeometryChanged,
              );
              final next = BilibiliStartupContext(
                coverUrl: _bilibiliStartup?.coverUrl,
              )..qualityId = _selectedStreamQuality?.id;
              if (geometry != null) next.geometry.copyFrom(geometry);
              _bilibiliStartup = next;
              next.geometry.addListener(_onBilibiliGeometryChanged);
              reuseStartup = next;
            } else {
              reuseStartup = PlaybackStartupContext();
            }
            reuseStartup
              ..target = _position
              ..desiredPlaying = _session.desiredPlaying;
            reuseStartup.prepared();
            _onlineStartup = reuseStartup;
          }
          final reuseOrigin = reuseStartup == null
              ? null
              : await reuseStartup.run(
                  _readNativeControllerPosition(controller),
                );
          _state = reuseStartup == null
              ? PlaybackState.playing
              : PlaybackState.loading;
          _syncWakelockWithState();
          notifyListeners();
          _startProgressTracking();
          if (!controller.value.isPlaying) {
            await (reuseStartup?.run(controller.play()) ?? controller.play());
            if (!_isCurrentPlayRequest(
              playRequestId,
              item.id,
              controller: controller,
            )) {
              return;
            }
          }
          if (reuseStartup != null) {
            await _awaitOnlineClockStarted(
              item: item,
              controller: controller,
              startup: reuseStartup,
              playRequestId: playRequestId,
              baseline: reuseOrigin ?? _position,
            );
            if (!_isCurrentPlayRequest(
              playRequestId,
              item.id,
              controller: controller,
            )) {
              return;
            }
            reuseStartup.ready();
            _state = _session.desiredPlaying
                ? PlaybackState.playing
                : PlaybackState.paused;
            _syncWakelockWithState();
            if (_session.desiredPlaying) _startProgressTracking();
          } else if (item.sourceRef?.kind == MediaSourceKind.bilibiliStream &&
              !controller.value.isPlaying) {
            final clockStarted = await _awaitBackgroundClockStarted(
              controller,
              playRequestId: playRequestId,
              itemId: item.id,
            );
            if (!_isCurrentPlayRequest(
              playRequestId,
              item.id,
              controller: controller,
            )) {
              return;
            }
            if (!clockStarted &&
                !controller.value.isPlaying &&
                shouldPlayNow()) {
              _logPlaybackEvent(
                'reused Bilibili controller did not start; recreating stream',
                data: <String, Object?>{'itemId': item.id},
              );
              await play(
                item,
                autoPlay: true,
                startPosition: _position,
                forceRecreate: true,
              );
              return;
            }
          }
        } else {
          _state = PlaybackState.paused;
          _syncWakelockWithState();
          notifyListeners();
          _stopProgressTracking();
          if (controller.value.isPlaying) {
            await controller.pause();
            if (!_isCurrentPlayRequest(
              playRequestId,
              item.id,
              controller: controller,
            )) {
              return;
            }
          }
          final nativePosition = controller.value.position;
          final positionDeltaMs =
              (nativePosition.inMilliseconds - _position.inMilliseconds).abs();
          if (positionDeltaMs <= _seekVerificationToleranceMs) {
            _position = nativePosition;
          }
          _bufferedPosition = _readBufferedPosition(controller);
          await _saveCurrentProgress(immediate: true);
          if (!_isCurrentPlayRequest(
            playRequestId,
            item.id,
            controller: controller,
          )) {
            return;
          }
        }

        if (!await _commitControllerPlaybackIntent(
          sessionGeneration: sessionGeneration,
          playRequestId: playRequestId,
          item: item,
          controller: controller,
        )) {
          return;
        }
        await _savePlaybackStateSnapshot();
        if (!_isCurrentPlayRequest(
          playRequestId,
          item.id,
          controller: controller,
        )) {
          return;
        }
        _refreshSubtitlesForCurrentItem(item);
        _prefetchNeighborBilibiliStreams();
        return;
      }

      // 如果正在播放其他媒体，或当前控制器已失效，先保存进度并停止
      final isBilibiliStream =
          item.sourceRef?.kind == MediaSourceKind.bilibiliStream;
      final isPodcast = item.sourceRef?.kind == MediaSourceKind.podcastEpisode;
      final isCloudDrive = isCloudDriveMedia(
        source: item.sourceRef,
        path: item.path,
      );
      if (isBilibiliStream) {
        // Resolve the target stream while the previous mobile controller is
        // releasing. Local-file ordering is untouched, while Bilibili switches
        // no longer wait for decoder release before beginning network setup.
        earlyBilibiliSource = () async {
          final materialized = await _acquireBilibiliPlaybackFile(
            item,
            qualityId: bilibiliQualityId,
          );
          if (materialized != null) {
            return (materialized: materialized, online: null);
          }
          final streaming = _bilibiliStreamingService;
          if (streaming == null) {
            throw StateError('Bilibili streaming service is not initialized');
          }
          final playback = await streaming.prepareForStartup(
            item,
            startup: _bilibiliStartup,
            qualityId: bilibiliQualityId,
          );
          // Handshake with the CDN while the player is still being built.
          // This does not write the track cache and does not change the
          // resume position applied later by start= / seek.
          return (materialized: null, online: playback);
        }();
      }

      if (_currentItem != null || _controller != null) {
        _transitionPlaybackSession(
          sessionGeneration,
          PlaybackSessionPhase.releasingOld,
        );
        final bool hadController = _controller != null;
        // 非阻塞保存进度：ProgressTracker 内存写入同步，落盘异步
        unawaited(_saveCurrentProgress());
        _seekPersistTimer?.cancel();
        _seekPersistTimer = null;
        if (hadController &&
            !kIsWeb &&
            (Platform.isAndroid || Platform.isIOS)) {
          final release = _disposeController(awaitCompletion: true);
          _trackMobileControllerRelease(release);
        } else if (hadController) {
          // Desktop decoders are not constrained by the mobile hardware codec
          // pool, so retain the faster overlapping hand-off there.
          unawaited(_disposeController());
        }
      }

      // Publish the target item together with its own timeline snapshot.  The
      // previous controller may remain alive while the new one initializes,
      // so leaving these fields untouched would briefly render the previous
      // item's progress on the new current-item card.
      var loadingPosition = resolvePlayStartPosition(
        startPosition: startPosition,
        currentItemId: previousItemId,
        itemId: item.id,
        currentPosition: _position,
        trackedProgress: _progressTracker?.getProgress(item.id),
        lastPositionMs: item.lastPositionMs,
      );
      final loadingDuration = Duration(
        milliseconds: item.durationMs > 0 ? item.durationMs : 0,
      );
      loadingPosition = PlaybackBehaviorPolicy.normalizeEpisodeStartPosition(
        savedPosition: loadingPosition,
        duration: loadingDuration,
      );
      if (startup?.isPending == true && startup!.hasUserTarget) {
        loadingPosition = startup.target;
      }

      _currentItem = item;
      _isSourceMissing = false;
      _position = loadingPosition;
      if (startup?.isPending == true) startup!.target = loadingPosition;
      _duration = loadingDuration;
      _bufferedPosition = Duration.zero;
      _resetPlaybackTimeline(loadingPosition, running: false);
      // A page-exit / background pause can land while playurl is still in
      // flight. Do not stomp that paused intent with loading chrome.
      if (!(_session.generation == sessionGeneration &&
          !_session.desiredPlaying)) {
        _state = PlaybackState.loading;
      }
      _transitionPlaybackSession(
        sessionGeneration,
        PlaybackSessionPhase.preparingSource,
      );
      _syncWakelockWithState();

      // Keep independent page content responsive while the native player is
      // handing off. Subtitle parsing and compatible-path resolution do not
      // require a controller, so overlap them with native disposal instead of
      // placing them behind the slowest part of media initialization.
      unawaited(
        isCloudDrive
            ? _refreshSubtitlesForCurrentItem(item)
            : _refreshKnownSubtitlesForCurrentItem(item),
      );
      notifyListeners();
      final Future<File?> playbackFileFuture = () async {
        if (isBilibiliStream || isCloudDrive || isPodcast) return null;
        final sourceFile = File(item.path);
        if (!await sourceFile.exists()) return null;
        final playbackPath = _libraryService != null
            ? await _libraryService!.ensureCompatiblePlaybackFile(item)
            : (await AudioPlaybackCompatibilityService.resolve(
                sourceFile,
                isAudio: item.type == MediaType.audio,
                existingPlaybackPath: item.playbackPath,
              )).path;
        return File(playbackPath);
      }();

      if (_playlistManager != null) {
        _playlistManager!.anchorCurrentItem(item);
      }
      // Neighbor prefetch starts after this transport is ready. A cold start
      // must not queue its media requests behind speculative CDN reads.

      // 重置预加载触发标志（新视频开始时重新计数）
      _preloadTriggered = false;

      // 尝试热替换：如果预加载控制器可用且匹配当前 item，跳过 initialize
      if (!isBilibiliStream &&
          !isCloudDrive &&
          !forceRecreate &&
          _tryUsePreloadedController(item)) {
        final controller = _controller!;
        _transitionPlaybackSession(
          sessionGeneration,
          _controllerHasRequiredVideoOutput(item, controller)
              ? PlaybackSessionPhase.controllerMountable
              : PlaybackSessionPhase.videoOutputDeferred,
          controller: controller,
        );
        if (playRequestId != _playRequestId) {
          unawaited(_disposeController());
          return;
        }

        await withinStartup(_applyConfiguredPlaybackSpeed(controller));
        if (!_isCurrentPlayRequest(
          playRequestId,
          item.id,
          controller: controller,
        )) {
          return;
        }
        await _applyMuteStateToController(
          reason: 'preloaded controller hot-swap',
        );
        if (!_isCurrentPlayRequest(
          playRequestId,
          item.id,
          controller: controller,
        )) {
          return;
        }
        _duration = _presentationDuration(controller.value.duration);
        _bufferedPosition = _readBufferedPosition(controller);
        if (_progressTracker != null && _duration > Duration.zero) {
          await _progressTracker!.saveDurationImmediately(item.id, _duration);
          if (!_isCurrentPlayRequest(
            playRequestId,
            item.id,
            controller: controller,
          )) {
            return;
          }
        }

        // 跳转到起始位置
        // Freeze the resume point at request start. A delayed controller
        // initialization must not re-read mutable progress after another
        // route's cleanup has run.
        final initialPosition =
            PlaybackBehaviorPolicy.normalizeEpisodeStartPosition(
              savedPosition: loadingPosition,
              duration: _duration,
            );
        // Always seek, including zero. A near-end resume point may have been
        // normalized to the beginning; leaving the service timeline at the
        // old near-end value while the preloaded decoder is at zero can fire a
        // false completion and start an episode-switch loop.
        if (_duration <= Duration.zero || initialPosition < _duration) {
          await controller
              .seekTo(initialPosition)
              .timeout(_controllerSeekTimeout);
          if (!_isCurrentPlayRequest(
            playRequestId,
            item.id,
            controller: controller,
          )) {
            return;
          }
          _position = initialPosition;
        }

        _resetPlaybackTimeline(
          _position,
          running: shouldPlayNow() && controller.value.isPlaying,
        );

        controller.addListener(_onControllerUpdate);
        _lastControllerIsPlaying = controller.value.isPlaying;
        if (shouldPlayNow()) {
          // The visible output may be required for the native backend to
          // produce its first frame. Publish the initialized controller while
          // readiness is still pending so the page can mount that output.
          notifyListeners();
          if (!controller.value.isPlaying) {
            await controller.play();
            if (!_isCurrentPlayRequest(
              playRequestId,
              item.id,
              controller: controller,
            )) {
              return;
            }
          }
          final readiness = await _awaitPlaybackReadinessResult(
            item: item,
            controller: controller,
            playRequestId: playRequestId,
          );
          if (!_isCurrentPlayRequest(
            playRequestId,
            item.id,
            controller: controller,
          )) {
            return;
          }
          if (readiness == _PlaybackReadinessResult.confirmed) {
            _state = PlaybackState.playing;
            _resetPlaybackTimeline(
              _position,
              running: controller.value.isPlaying,
            );
            _syncWakelockWithState();
            notifyListeners();
            _startProgressTracking();
          } else {
            // Readiness degraded: park as paused at the seek target and clear
            // the play intent so the final intent commit cannot re-play a
            // transport that was just confirmed as not running.
            _setDesiredPlaying(false);
            _state = PlaybackState.paused;
            _syncWakelockWithState();
            notifyListeners();
            _stopProgressTracking();
            _position = controller.value.position;
          }
        } else {
          _state = PlaybackState.paused;
          _syncWakelockWithState();
          notifyListeners();
          _stopProgressTracking();
          _position = controller.value.position;
        }

        if (!await _commitControllerPlaybackIntent(
          sessionGeneration: sessionGeneration,
          playRequestId: playRequestId,
          item: item,
          controller: controller,
        )) {
          return;
        }
        await _savePlaybackStateSnapshot();
        if (!_isCurrentPlayRequest(
          playRequestId,
          item.id,
          controller: controller,
        )) {
          return;
        }
        _refreshSubtitlesForCurrentItem(item);
        _prefetchNeighborBilibiliStreams();
        _logPlaybackEvent(
          'play via preloaded controller',
          data: {'itemId': item.id, 'autoPlay': autoPlay},
        );
        return;
      }

      // 预加载不匹配：释放预加载控制器（用户手动切换到非下一个视频）
      unawaited(_disposePreloadedController());

      // 创建新的控制器
      if (earlyBilibiliSource != null) {
        final source = await withinStartup(earlyBilibiliSource!);
        earlyBilibiliSource = null;
        requestMaterializedLease = source.materialized;
        requestBilibiliPlayback = source.online;
        if (!_isCurrentPlayRequest(playRequestId, item.id)) {
          await requestMaterializedLease?.release();
          requestMaterializedLease = null;
          await releaseRequestBilibiliPlayback();
          return;
        }
      }
      if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
        try {
          await withinStartup(
            _mobileControllerReleaseBarrier.timeout(
              _mobileControllerReleaseTimeout,
            ),
          );
        } on TimeoutException {
          _logPlaybackEvent(
            'previous mobile controller release timed out',
            data: <String, Object?>{'itemId': item.id},
          );
          throw TimeoutException('previous mobile decoder is still releasing');
        }
        if (!_isCurrentPlayRequest(playRequestId, item.id)) {
          await requestMaterializedLease?.release();
          requestMaterializedLease = null;
          await releaseRequestBilibiliPlayback();
          return;
        }
      }
      requestMaterializedLease ??=
          isBilibiliStream && requestBilibiliPlayback == null
          ? await _acquireBilibiliPlaybackFile(
              item,
              qualityId: bilibiliQualityId,
            )
          : null;
      requestBilibiliPlayback ??=
          isBilibiliStream && requestMaterializedLease == null
          ? (_bilibiliStreamingService == null
                ? throw StateError('Bilibili 在线播放服务尚未初始化')
                : await _bilibiliStreamingService!.prepareForStartup(
                    item,
                    startup: _bilibiliStartup,
                    qualityId: bilibiliQualityId,
                  ))
          : null;
      final preparedStream = requestBilibiliPlayback;
      final playbackFile = await playbackFileFuture;
      if (!isBilibiliStream &&
          !isCloudDrive &&
          !isPodcast &&
          playbackFile == null) {
        if (!_isCurrentPlayRequest(playRequestId, item.id)) {
          return;
        }
        // A missing source is a recoverable media-session state, not a fatal
        // playback error. Keep the item/timeline/playlist active so every
        // playback page can render its normal controls and navigate past it.
        _isSourceMissing = true;
        _state = PlaybackState.paused;
        _transitionPlaybackSession(
          sessionGeneration,
          PlaybackSessionPhase.missing,
          desiredPlaying: false,
        );
        _stopProgressTracking();
        _syncWakelockWithState();
        notifyListeners();
        unawaited(_savePlaybackStateSnapshot());
        unawaited(_refreshSubtitlesForCurrentItem(item));
        debugPrint('MediaPlaybackService: 文件不存在 ${item.path}');
        return;
      }
      if (playRequestId != _playRequestId) {
        await requestMaterializedLease?.release();
        requestMaterializedLease = null;
        await releaseRequestBilibiliPlayback();
        return;
      }

      if (!_isCurrentPlayRequest(playRequestId, item.id)) {
        await requestMaterializedLease?.release();
        requestMaterializedLease = null;
        await releaseRequestBilibiliPlayback();
        return;
      }
      if (isBilibiliStream && requestMaterializedLease != null) {
        final localLease = requestMaterializedLease;
        final localHeight = localLease.height;
        final localQuality = BilibiliStreamQuality(
          id: localLease.qualityId ?? BilibiliStreamQuality.localMaterializedId,
          cached: true,
          label:
              localLease.qualityLabel ??
              (localHeight == null || localHeight <= 0
                  ? '本地素材'
                  : '${localHeight}P'),
        );
        const onlineQualities = <BilibiliStreamQuality>[];
        final qualityLookup = _bilibiliStreamingService?.listQualities(item);
        final audioLookup = _bilibiliStreamingService?.listAudioQualities(item);
        if (audioLookup != null) {
          unawaited(
            audioLookup.then<void>((available) {
              if (!_isCurrentPlayRequest(playRequestId, item.id) ||
                  _selectedStreamQuality?.id != localQuality.id ||
                  _isSwitchingStreamQuality) {
                return;
              }
              _streamAudioQualities = available;
              notifyListeners();
            }, onError: (Object _, StackTrace _) {}),
          );
        }
        if (qualityLookup != null) {
          unawaited(
            qualityLookup.then<void>((available) {
              if (!_isCurrentPlayRequest(playRequestId, item.id) ||
                  _selectedStreamQuality?.id != localQuality.id ||
                  _isSwitchingStreamQuality) {
                return;
              }
              _streamQualities = List.unmodifiable(
                <int, BilibiliStreamQuality>{
                  for (final quality in available) quality.id: quality,
                  for (final quality in _streamQualities)
                    if (quality.cached || quality.id == localQuality.id)
                      quality.id: quality,
                }.values,
              );
              notifyListeners();
            }, onError: (Object _, StackTrace _) {}),
          );
        }
        // Verified local media can start even if the online menu is offline.
        // Cached rungs and the current local selection remain available now.
        if (!_isCurrentPlayRequest(playRequestId, item.id)) {
          await requestMaterializedLease.release();
          requestMaterializedLease = null;
          await releaseRequestBilibiliPlayback();
          return;
        }
        _streamQualities = List.unmodifiable(
          <int, BilibiliStreamQuality>{
            for (final quality in onlineQualities) quality.id: quality,
            for (final quality in MediaCacheHooks.qualities?.call(item) ?? [])
              if (int.tryParse(quality.id) != null || quality.id == 'legacy')
                (int.tryParse(quality.id) ??
                        BilibiliStreamQuality.localMaterializedId):
                    BilibiliStreamQuality(
                      id:
                          int.tryParse(quality.id) ??
                          BilibiliStreamQuality.localMaterializedId,
                      label: quality.label,
                      cached: true,
                    ),
            localQuality.id: localQuality,
          }.values,
        );
        _selectedStreamQuality = localQuality;
        _streamAudioQualities = const [];
        _selectedStreamAudioQuality = null;
        final width = localLease.width ?? 0;
        final height = localLease.height ?? 0;
        _setStreamDisplayAspectRatio(
          item.id,
          width > 0 && height > 0 ? width / height : null,
        );
        _currentBilibiliPlayback = null;
      } else if (isBilibiliStream && preparedStream != null) {
        _streamQualities = _withCachedBilibiliQualities(
          item,
          preparedStream.qualities,
        );
        _selectedStreamQuality = preparedStream.selectedQuality;
        _streamAudioQualities = preparedStream.audioQualities;
        _selectedStreamAudioQuality = preparedStream.selectedAudioQuality;
        _setStreamDisplayAspectRatio(
          item.id,
          preparedStream.displayAspectRatio,
        );
      } else {
        _streamQualities = const [];
        _selectedStreamQuality = null;
        _streamAudioQualities = const [];
        _selectedStreamAudioQuality = null;
        _setStreamDisplayAspectRatio(null, null);
        _currentBilibiliPlayback = null;
      }
      // Readable `.seg` cache means loopback can fill the demuxer immediately.
      // Skip the conservative 2s cache-pause-initial used for cold CDN opens.
      var bilibiliFastStart = false;
      var bilibiliDeferVideo = false;
      if (isBilibiliStream &&
          requestMaterializedLease == null &&
          preparedStream != null) {
        // The native dual-track open now warms the actual requested ranges.
        // Same Player as the playback page. Background audio-only deselects
        // video after open; otherwise Mini/notification keep decoding video so
        // a later page entry mounts the live picture without re-enabling vid.
        bilibiliDeferVideo = shouldDeferBilibiliVideoOnOpen(
          hasVisiblePlaybackPage: _hasVisiblePlaybackPage,
          backgroundAudioOnly: SettingsService().bilibiliBackgroundAudioOnly,
        );
        bilibiliFastStart =
            bilibiliDeferVideo ||
            _shouldFastStartBilibiliOnThisPlatform() ||
            await withinStartup(_shouldFastStartCachedBilibiliStream(item));
        if (!_isCurrentPlayRequest(playRequestId, item.id)) {
          await requestMaterializedLease?.release();
          requestMaterializedLease = null;
          await releaseRequestBilibiliPlayback();
          return;
        }
      }
      if (isCloudDrive) {
        cloudDriveNotice = _cloudDrivePlayback == null
            ? '正在读取本机网盘账号…'
            : '正在获取播放地址';
        cloudDriveFailureKind = null;
        notifyListeners();
        if (_cloudDrivePlayback == null) {
          await withinStartup(
            _raceDirectEpoch(CloudDriveStartup.waitUntilReady(), switchEpoch),
          );
        }
        final service = _cloudDrivePlayback;
        if (service == null) {
          throw const CloudDriveFailure(
            CloudDriveFailureKind.unavailable,
            '网盘播放服务尚未初始化',
          );
        }
        cloudDriveNotice = '正在获取播放地址';
        notifyListeners();
        // Opening a cloud file only refreshes a card the user already imported.
        if (_libraryService?.getVideo(item.id) != null &&
            item.sourceRef?.cloudDrive != null) {
          await _libraryService!.upsertCloudDriveCard(
            source: item.sourceRef!,
            libraryItemId: item.id,
            playbackItem: item,
            title: item.title,
            durationMs: item.durationMs,
            mediaType: item.type,
          );
        }
        cloudBudget = CloudDrivePlaybackBudget(
          total: startup?.remaining ?? const Duration(seconds: 30),
        );
        preparedCloud = await _openCloudDriveForStartup(
          service: service,
          item: item,
          qualityId: cloudDriveQualityId,
          budget: cloudBudget,
          startup: startup,
          directEpoch: switchEpoch,
        );
        if (preparedCloud.mediaKind == CloudDriveMediaKind.audio) {
          item.type = MediaType.audio;
        }
        final resolvedDuration = preparedCloud.durationMs;
        if (resolvedDuration != null && resolvedDuration > 0) {
          if (item.durationMs <= 0 || resolvedDuration > item.durationMs) {
            item.durationMs = resolvedDuration;
          }
          if (_libraryService?.getVideo(item.id) != null &&
              item.sourceRef != null) {
            await _libraryService!.upsertCloudDriveCard(
              source: item.sourceRef!,
              libraryItemId: item.id,
              playbackItem: item,
              title: item.title,
              durationMs: item.durationMs,
              mediaType: item.type,
            );
          }
        }
        if (!_isCurrentPlayRequest(playRequestId, item.id)) {
          await preparedCloud.lease.release();
          return;
        }
        _cloudDriveQualities = List.unmodifiable(
          sortCloudDriveQualities(preparedCloud.qualities),
        );
        _selectedCloudDriveQualityId = preparedCloud.selectedQualityId;
        cloudDriveNotice = preparedCloud.notice;
        unawaited(
          _adoptDiscoveredCloudDriveQualities(
            item.id,
            playRequestId,
            preparedCloud.backgroundQualities,
          ),
        );
      }
      if (isPodcast) {
        startup?.mark(PlaybackStartupPhase.connecting);
        startup?.record('podcast address requested');
      }
      final podcastUri = !isPodcast
          ? null
          : await withinStartup(
              _raceDirectEpoch(
                PodcastPlaybackHooks.resolve?.call(item) ??
                    Future<Uri>.error(StateError('播客服务尚未就绪')),
                switchEpoch,
              ),
            );
      if (isPodcast) startup?.record('podcast address ready');
      if (!_isCurrentPlayRequest(playRequestId, item.id)) return;
      var controller = isPodcast
          ? AppVideoPlayerController.networkUrl(
              podcastUri!,
              httpHeaders: {
                PodcastPlaybackPolicy.streamHeader: item.type == MediaType.audio
                    ? 'audio'
                    : 'video',
              },
              videoPlayerOptions: buildVideoPlayerOptions(),
            )
          : isCloudDrive
          ? AppVideoPlayerController.networkUrl(
              preparedCloud!.lease.loopbackUri,
              httpHeaders: NativeVideoPlayerMediaKit.cloudDrivePlayerHeaders(
                hls:
                    preparedCloud.lease.descriptor.transport ==
                    CloudDriveTransport.hls,
                start: loadingPosition,
              ),
              videoPlayerOptions: buildVideoPlayerOptions(),
            )
          : isBilibiliStream
          ? requestMaterializedLease != null
                ? AppVideoPlayerController.file(
                    File(requestMaterializedLease.requiredVideoPath),
                    videoPlayerOptions: buildVideoPlayerOptions(),
                  )
                : _createBilibiliStreamController(
                    preparedStream!,
                    fastStart: bilibiliFastStart,
                    deferVideo: bilibiliDeferVideo,
                    startPosition: loadingPosition,
                  )
          : AppVideoPlayerController.file(
              playbackFile!,
              videoPlayerOptions: buildVideoPlayerOptions(),
            );
      requestController = controller;
      watchCandidate(controller);
      _transitionPlaybackSession(
        sessionGeneration,
        PlaybackSessionPhase.initializingTransport,
      );
      if (playRequestId != _playRequestId) {
        await _detachController(
          controller,
          disposeController: true,
          pauseIfPlaying: true,
        );
        await requestMaterializedLease?.release();
        requestMaterializedLease = null;
        await releaseRequestBilibiliPlayback();
        await preparedCloud?.lease.release();
        return;
      }

      final initializeTimeout = cloudBudget == null
          ? _controllerInitializeTimeout
          : cloudBudget.remaining(cloudDriveInitializeCap);
      // 初始化控制器。原画能探测但原生打不开时，同一请求改试已确认的转码。
      try {
        startup?.record('native initialize requested');
        await _raceDirectEpoch(
          startup?.run(controller.initialize(), cap: initializeTimeout) ??
              controller.initialize().timeout(initializeTimeout),
          switchEpoch,
        );
      } on _DirectSwitchSuperseded {
        await _detachController(
          controller,
          disposeController: true,
          pauseIfPlaying: true,
        );
        await requestMaterializedLease?.release();
        requestMaterializedLease = null;
        await releaseRequestBilibiliPlayback();
        await preparedCloud?.lease.release();
        return;
      } catch (error) {
        final fallbackId = preparedCloud == null
            ? null
            : await _cloudDriveFallbackQuality(
                prepared: preparedCloud,
                error: error,
                allow: allowCloudDriveFallback && cloudDriveQualityId == null,
              );
        if (fallbackId == null || preparedCloud == null) rethrow;
        await _detachController(
          controller,
          disposeController: true,
          pauseIfPlaying: true,
        );
        await preparedCloud.lease.release();
        preparedCloud = await _openCloudDriveForStartup(
          service: _cloudDrivePlayback!,
          item: item,
          qualityId: fallbackId,
          budget: cloudBudget!,
          startup: startup,
          directEpoch: switchEpoch,
        );
        controller = AppVideoPlayerController.networkUrl(
          preparedCloud.lease.loopbackUri,
          httpHeaders: NativeVideoPlayerMediaKit.cloudDrivePlayerHeaders(
            hls:
                preparedCloud.lease.descriptor.transport ==
                CloudDriveTransport.hls,
            start: loadingPosition,
          ),
          videoPlayerOptions: buildVideoPlayerOptions(),
        );
        requestController = controller;
        watchCandidate(controller);
        _cloudDriveQualities = _mergeCloudDriveQualities(
          _cloudDriveQualities,
          preparedCloud.qualities,
        );
        _selectedCloudDriveQualityId = preparedCloud.selectedQualityId;
        cloudDriveNotice =
            '原画无法打开，已改用${preparedCloud.lease.descriptor.quality.label}';
        await _raceDirectEpoch(
          startup?.run(
                controller.initialize(),
                cap: cloudBudget.remaining(cloudDriveInitializeCap),
              ) ??
              controller.initialize().timeout(
                cloudBudget.remaining(cloudDriveInitializeCap),
              ),
          switchEpoch,
        );
      }
      startup?.record('native initialize ready');
      _transitionPlaybackSession(
        sessionGeneration,
        PlaybackSessionPhase.transportReady,
      );

      if (playRequestId != _playRequestId) {
        await _detachController(
          controller,
          disposeController: true,
          pauseIfPlaying: true,
        );
        await requestMaterializedLease?.release();
        requestMaterializedLease = null;
        await releaseRequestBilibiliPlayback();
        return;
      }

      // Network players may start their probe at byte zero while initialize()
      // completes. Stop that implicit start before the saved-position seek so
      // the user never sees the first fragment before the requested point.
      try {
        if (controller.value.isInitialized && controller.value.isPlaying) {
          await controller.pause();
        }
      } catch (_) {}

      _controller = controller;
      _controllerItemId = item.id;
      _serviceOwnsController = true;
      _bilibiliAudioPrimaryPlayer = false;
      if (preparedCloud != null) {
        _currentCloudDriveLease = preparedCloud.lease;
        preparedCloud = null;
      }
      if (preparedStream != null) {
        _currentBilibiliPlayback = preparedStream;
        requestBilibiliPlayback = null;
      }
      final hasRequiredVideoOutput = _controllerHasRequiredVideoOutput(
        item,
        controller,
      );
      _transitionPlaybackSession(
        sessionGeneration,
        hasRequiredVideoOutput
            ? PlaybackSessionPhase.controllerMountable
            : PlaybackSessionPhase.videoOutputDeferred,
        controller: controller,
      );
      if (requestMaterializedLease != null) {
        _currentMaterializedPlaybackLease = requestMaterializedLease;
        requestMaterializedLease = null;
      }
      _isSourceMissing = false;
      _attachNativePositionStream(controller);

      await withinStartup(
        _applyConfiguredPlaybackSpeed(
          controller,
          preservedSpeed: preserveLiveSettings ? _playbackSpeed : null,
        ),
      );
      if (!_isCurrentPlayRequest(
        playRequestId,
        item.id,
        controller: controller,
      )) {
        return;
      }

      _duration = PlaybackBehaviorPolicy.trustedDurationForResume(
        nativeDuration: controller.value.duration,
        metadataDuration: loadingDuration,
        savedPosition: loadingPosition,
      );
      _bufferedPosition = _readBufferedPosition(controller);
      final nativeDuration = controller.value.duration;
      if (_progressTracker != null &&
          nativeDuration > Duration.zero &&
          (item.durationMs <= 0 ||
              nativeDuration.inMilliseconds >= item.durationMs ~/ 2)) {
        await withinStartup(
          _progressTracker!.saveDurationImmediately(
            item.id,
            isBilibiliStream ? _duration : nativeDuration,
          ),
        );
        if (!_isCurrentPlayRequest(
          playRequestId,
          item.id,
          controller: controller,
        )) {
          return;
        }
      }

      // 设置音量和静音状态
      await withinStartup(controller.setVolume(_isMuted ? 0.0 : _volume));
      if (!_isCurrentPlayRequest(
        playRequestId,
        item.id,
        controller: controller,
      )) {
        return;
      }

      // 添加监听器

      // 确定起始位置
      Duration initialPosition = loadingPosition;

      // 如果没有指定起始位置，尝试从进度追踪器获取
      // 修复：如果保存的进度在末尾（表示已播放完成），则从头开始播放
      // 避免无法跳转上一集或进入已完成的视频
      // 注意：只有当_duration > 0时才检查，避免误判
      final normalizedInitialPosition =
          PlaybackBehaviorPolicy.normalizeEpisodeStartPosition(
            savedPosition: initialPosition,
            duration: PlaybackBehaviorPolicy.trustedDurationForResume(
              nativeDuration: controller.value.duration,
              metadataDuration: loadingDuration,
              savedPosition: initialPosition,
            ),
          );
      if (normalizedInitialPosition != initialPosition) {
        _logPlaybackEvent(
          'reset to beginning due to completion',
          data: <String, Object?>{
            'itemId': item.id,
            'savedProgressMs': initialPosition.inMilliseconds,
          },
        );
      }
      initialPosition = normalizedInitialPosition;

      // 跳转到起始位置
      // 注意：即使initialPosition为0，也需要seekTo，确保控制器从开头开始播放
      // 避免控制器停留在末尾导致立即触发播放完成
      startup?.mark(BilibiliStartupPhase.positioning);
      await withinStartup(
        _seekInitialPosition(
          controller,
          startup?.isPending == true ? startup!.target : initialPosition,
        ),
      );
      if (!_isCurrentPlayRequest(
        playRequestId,
        item.id,
        controller: controller,
      )) {
        return;
      }

      _primeDeferredVideoOutput(item, controller);

      _resetPlaybackTimeline(
        _position,
        running: shouldPlayNow() && controller.value.isPlaying,
      );

      controller.addListener(_onControllerUpdate);
      _lastControllerIsPlaying = controller.value.isPlaying;
      if (startup?.isPending == true) {
        if (isBilibiliStream) {
          await withinStartup(_awaitBilibiliVideoTrackPolicy());
        }
        if (!_isCurrentPlayRequest(
          playRequestId,
          item.id,
          controller: controller,
        )) {
          return;
        }
        bool videoRequired() =>
            _hasVisiblePlaybackPage && item.type == MediaType.video;
        Future<void>? targetFrame() =>
            debugOnlineStartupReadiness?.call(
              controller,
              startup!,
              videoRequired(),
            ) ??
            (videoRequired() && startup is BilibiliStartupContext
                ? debugBilibiliFrameReadiness?.call(controller, startup)
                : null) ??
            NativeVideoPlayerMediaKit.preparedForPlayback(
              // ignore: invalid_use_of_visible_for_testing_member
              controller.playerId,
              startup!,
              videoRequired: videoRequired,
            );
        final frame = targetFrame();
        if (frame != null) {
          startup!.mark(BilibiliStartupPhase.waitingForFrame);
          notifyListeners();
          await startup.waitForFrame(
            frame,
            recheckFrame: () => targetFrame() ?? Future<void>.value(),
            recoverResume: (target) =>
                _recoverOnlineResumeFrame(controller, startup, target),
          );
          // Compose the paused target texture under the cover before its fade.
          if (videoRequired() &&
              debugBilibiliFrameReadiness == null &&
              debugOnlineStartupReadiness == null) {
            await _composePreparedOnlineFrame(startup);
          }
        }
        if (!_isCurrentPlayRequest(
          playRequestId,
          item.id,
          controller: controller,
        )) {
          return;
        }
        if (controller.value.hasError) {
          throw StateError('音视频解码失败，请重试');
        }
        startup!.prepared();
        _armInitialPositionGuard(_position, protectZero: true);
        _endCoveringUntilVisibleVideoFrame(immediate: true);
        if (!shouldPlayNow()) startup.ready();
      }
      if (shouldPlayNow()) {
        // Mini / notification has no page-owned video surface. Optimistic
        // `playing` keeps the mini button in sync while media_kit reports
        // isPlaying=false. Full video pages stay in `loading` until native
        // play() returns so an initialized controller can mount first.
        if (!hasRequiredVideoOutput && !isPodcast) {
          _state = PlaybackState.playing;
          _syncWakelockWithState();
          _startProgressTracking();
          notifyListeners();
        }
        if (isPodcast) notifyListeners();
        // Mini card / notification play has no page owner. Drop the video
        // track before the clock starts so Windows does not pull video bytes.
        if (item.sourceRef?.kind == MediaSourceKind.bilibiliStream) {
          await _awaitBilibiliVideoTrackPolicy();
          if (!_isCurrentPlayRequest(
            playRequestId,
            item.id,
            controller: controller,
          )) {
            return;
          }
          await _confirmInitialResumePosition(
            controller: controller,
            target: initialPosition,
            allowPause: true,
          );
          if (!_isCurrentPlayRequest(
            playRequestId,
            item.id,
            controller: controller,
          )) {
            return;
          }
        }
        final playbackOrigin = isPodcast || startup != null
            ? await _readNativeControllerPosition(controller)
            : null;
        await withinStartup(controller.play());
        if (!_isCurrentPlayRequest(
          playRequestId,
          item.id,
          controller: controller,
        )) {
          return;
        }
        await _confirmInitialResumePosition(
          controller: controller,
          target: initialPosition,
          allowPause: false,
        );
        if (startup?.isPending == true) {
          await _awaitOnlineClockStarted(
            item: item,
            controller: controller,
            startup: startup!,
            playRequestId: playRequestId,
            baseline: playbackOrigin ?? _position,
          );
          if (!_isCurrentPlayRequest(
            playRequestId,
            item.id,
            controller: controller,
          )) {
            return;
          }
          startup.ready();
        }
        if (!_isCurrentPlayRequest(
          playRequestId,
          item.id,
          controller: controller,
        )) {
          return;
        }
        final readiness = await _awaitPlaybackReadinessResult(
          item: item,
          controller: controller,
          playRequestId: playRequestId,
          playbackOrigin: playbackOrigin,
        );
        if (!_isCurrentPlayRequest(
          playRequestId,
          item.id,
          controller: controller,
        )) {
          return;
        }
        if (readiness == _PlaybackReadinessResult.confirmed) {
          _lastControllerIsPlaying = controller.value.isPlaying;
          _state = PlaybackState.playing;
          _transitionPlaybackSession(
            sessionGeneration,
            hasRequiredVideoOutput
                ? PlaybackSessionPhase.ready
                : PlaybackSessionPhase.videoOutputDeferred,
            controller: controller,
          );
          _resetPlaybackTimeline(
            _position,
            running: controller.value.isPlaying,
          );
          _syncWakelockWithState();
          notifyListeners();
          _startProgressTracking();
        } else {
          // Readiness degraded (background clock never started / foreground
          // decoder produced no frame). Keep the episode switch successful:
          // park paused at the recorded position, clear the play intent so
          // the intent commit below cannot re-play, and leave the session
          // ready instead of erroring out.
          _setDesiredPlaying(false);
          _lastControllerIsPlaying = false;
          _state = PlaybackState.paused;
          _transitionPlaybackSession(
            sessionGeneration,
            hasRequiredVideoOutput
                ? PlaybackSessionPhase.ready
                : PlaybackSessionPhase.videoOutputDeferred,
            controller: controller,
          );
          _resetPlaybackTimeline(_position, running: false);
          _syncWakelockWithState();
          notifyListeners();
          _stopProgressTracking();
          await _saveCurrentProgress(immediate: true);
          if (!_isCurrentPlayRequest(
            playRequestId,
            item.id,
            controller: controller,
          )) {
            return;
          }
        }
      } else {
        _lastControllerIsPlaying = controller.value.isPlaying;
        // 保持暂停状态
        _state = PlaybackState.paused;
        _transitionPlaybackSession(
          sessionGeneration,
          hasRequiredVideoOutput
              ? PlaybackSessionPhase.ready
              : PlaybackSessionPhase.videoOutputDeferred,
          controller: controller,
        );
        _syncWakelockWithState();
        // 暂停时也应该保存一次初始状态
        await _saveCurrentProgress(immediate: true);
        if (!_isCurrentPlayRequest(
          playRequestId,
          item.id,
          controller: controller,
        )) {
          return;
        }
      }

      // 保存播放状态快照
      // A transport command can change play/pause intent while preparation or
      // first-frame readiness is pending. Reconcile it before committing.
      // Commit the *current* intent even when the native controller already
      // reached that state. A notification pause can arrive while the initial
      // play Future is pending: the listener correctly pauses the transport,
      // but the earlier loading branch may just have written `playing` again.
      // Leaving that mismatch makes _playPlaylistItem treat a successful
      // switch as failed and reopen/reseek the same source repeatedly.
      if (!await _commitControllerPlaybackIntent(
        sessionGeneration: sessionGeneration,
        playRequestId: playRequestId,
        item: item,
        controller: controller,
      )) {
        return;
      }

      await _savePlaybackStateSnapshot();
      if (!_isCurrentPlayRequest(
        playRequestId,
        item.id,
        controller: controller,
      )) {
        return;
      }

      notifyListeners();

      _refreshSubtitlesForCurrentItem(item);
      unawaited(_rememberCloudDrivePlaybackCover(item, controller));
      _prefetchNeighborBilibiliStreams();
    } catch (e) {
      startup?.fail(e);
      if (e is _DirectSwitchSuperseded || switchEpoch != _directEpoch) {
        final abandoned = requestController;
        if (abandoned != null && !identical(_controller, abandoned)) {
          await _detachController(
            abandoned,
            disposeController: true,
            pauseIfPlaying: true,
          );
        }
        await releaseEarlyBilibiliSource();
        await requestMaterializedLease?.release();
        requestMaterializedLease = null;
        await releaseRequestBilibiliPlayback();
        return;
      }
      await releaseEarlyBilibiliSource();
      await requestMaterializedLease?.release();
      requestMaterializedLease = null;
      await releaseRequestBilibiliPlayback();
      if (preparedCloud != null &&
          !identical(_currentCloudDriveLease, preparedCloud.lease)) {
        await preparedCloud.lease.release();
      }
      if (isCloudDriveMedia(source: item.sourceRef, path: item.path)) {
        cloudDriveFailureKind = e is CloudDriveFailure
            ? e.kind
            : CloudDriveFailureKind.unavailable;
        cloudDriveNotice = e is CloudDriveFailure
            ? e.message
            : item.type == MediaType.audio
            ? '暂时无法播放这个音频'
            : '暂时无法播放这个网盘文件';
      }
      debugPrint('MediaPlaybackService: 播放失败 $e');
      if (!_isCurrentPlayRequest(playRequestId, item.id)) {
        final controller = requestController;
        if (controller != null && !identical(_controller, controller)) {
          await _detachController(
            controller,
            disposeController: true,
            pauseIfPlaying: true,
          );
        }
        return;
      }
      // A failed candidate still owns a native player (and, for Bilibili, a
      // gateway session). Retaining it exhausts mobile decoder slots and can
      // make the next retry render only a black texture.
      final failedController = requestController;
      if (failedController != null) {
        if (identical(_controller, failedController)) {
          await _disposeController(awaitCompletion: true).timeout(
            _mobileControllerReleaseTimeout,
            onTimeout: () => _logPlaybackEvent(
              'failed controller cleanup timed out',
              data: <String, Object?>{'itemId': item.id},
            ),
          );
        } else {
          await _detachController(
            failedController,
            disposeController: true,
            pauseIfPlaying: true,
          ).timeout(
            _mobileControllerReleaseTimeout,
            onTimeout: () => _logPlaybackEvent(
              'failed candidate cleanup timed out',
              data: <String, Object?>{'itemId': item.id},
            ),
          );
        }
      }
      if (!_isCurrentPlayRequest(playRequestId, item.id)) return;
      final bool sourceMissing =
          !isCloudDriveMedia(source: item.sourceRef, path: item.path) &&
          item.sourceRef?.kind != MediaSourceKind.bilibiliStream &&
          item.sourceRef?.kind != MediaSourceKind.podcastEpisode &&
          !kIsWeb &&
          !await File(item.path).exists();
      if (!_isCurrentPlayRequest(playRequestId, item.id)) return;
      _isSourceMissing = sourceMissing;
      if (sourceMissing) _playlistManager?.reloadPlaylist();
      if (keepBookmarkOnFailure && !sourceMissing) {
        // Speculative restore failed. Leave the Mini bookmark paused at the
        // saved position so a later tap can retry, instead of hiding the card
        // behind an error or reopening the file at t=0.
        _state = PlaybackState.paused;
        _setDesiredPlaying(false);
        _transitionPlaybackSession(
          sessionGeneration,
          PlaybackSessionPhase.resolving,
          desiredPlaying: false,
        );
      } else {
        _state = sourceMissing ? PlaybackState.paused : PlaybackState.error;
        _transitionPlaybackSession(
          sessionGeneration,
          sourceMissing
              ? PlaybackSessionPhase.missing
              : PlaybackSessionPhase.failed,
          desiredPlaying: false,
          error: sourceMissing ? null : e.toString(),
        );
      }
      _syncWakelockWithState();
      notifyListeners();
      if (sourceMissing) {
        unawaited(_refreshSubtitlesForCurrentItem(item));
      }
    } finally {
      if (_activePlayInvocationGeneration == sessionGeneration) {
        _activePlayInvocationGeneration = null;
      }
    }
  }

  /// Recreates the active native player so a changed libmpv decoder policy is
  /// applied immediately. Position, pause/play state, rate, volume and media
  /// metadata are restored by the normal [play] hand-off path.
  Future<void> reloadCurrentVideoDecoder() async {
    final item = _currentItem;
    final controller = _controller;
    if (item == null || controller == null || item.type != MediaType.video) {
      return;
    }

    Duration position = _position;
    bool autoPlay = _state == PlaybackState.playing;

    // A preloaded controller was created with the previous decoder policy and
    // must never be hot-swapped into this new session.
    await _disposePreloadedController(awaitCompletion: true);
    await play(
      item,
      startPosition: position,
      autoPlay: autoPlay,
      forceRecreate: true,
    );
  }

  /// 取消仍在初始化中的播放请求，通常用于用户在加载页中主动返回。
  Future<void> cancelPendingPlay({
    String? expectedItemId,
    bool keepBookmark = false,
  }) async {
    final bool matchesExpectedItem =
        expectedItemId == null || _currentItem?.id == expectedItemId;
    if (_state != PlaybackState.loading || !matchesExpectedItem) {
      return;
    }

    _playRequestId++;
    _onlineStartup?.cancel();
    _activeOpenBudget?.cancel();
    _activeOpenBudget = null;
    _subtitleLoadRequestId++;
    _clearInitialPositionGuard();
    _hasPlaybackCompleted = false;
    _seekPersistTimer?.cancel();
    _seekPersistTimer = null;
    _cancelHopSeekDispatch();
    _seekVerificationTimer?.cancel();
    _seekVerificationTimer = null;
    _stopProgressTracking();

    final controller = _controller;
    final bool shouldDisposeController = _serviceOwnsController;
    _controller = null;
    _controllerItemId = null;
    _serviceOwnsController = false;
    _lastControllerIsPlaying = null;

    final bookmark = keepBookmark ? _currentItem : null;
    final bookmarkPosition = _position;
    final bookmarkDuration = _duration;
    _state = bookmark == null ? PlaybackState.idle : PlaybackState.paused;
    _isSourceMissing = false;
    _currentItem = bookmark;
    final cancelledGeneration = ++_sessionGeneration;
    _sessionController = null;
    _session = PlaybackSessionSnapshot(
      generation: cancelledGeneration,
      itemId: bookmark?.id ?? expectedItemId,
      phase: bookmark == null
          ? PlaybackSessionPhase.stopped
          : PlaybackSessionPhase.resolving,
      desiredPlaying: false,
      controllerGeneration: _controllerGeneration,
      hasVideoOutput: false,
    );
    _position = bookmark == null ? Duration.zero : bookmarkPosition;
    _duration = bookmark == null ? Duration.zero : bookmarkDuration;
    _bufferedPosition = Duration.zero;
    _resetPlaybackTimeline(_position, running: false, rate: 1.0);
    if (bookmark == null) clearSubtitleState();
    _syncWakelockWithState();
    notifyListeners();

    if (bookmark != null) {
      unawaited(_refreshKnownSubtitlesForCurrentItem(bookmark));
      unawaited(persistCurrentProgress(expectedItemId: bookmark.id));
    }

    if (controller != null) {
      await _detachController(
        controller,
        disposeController: shouldDisposeController,
        pauseIfPlaying: true,
      );
    }
  }

  /// Converts a late file-system failure into the same recoverable state used
  /// when [play] finds that the source was already missing.
  void markCurrentSourceMissing({String? expectedItemId}) {
    final item = _currentItem;
    if (item == null ||
        (expectedItemId != null && item.id != expectedItemId) ||
        _isSourceMissing) {
      return;
    }

    _playRequestId++;
    _seekRequestId++;
    _pendingSeekRequestId = null;
    _clearInitialPositionGuard();
    _hasPlaybackCompleted = false;
    _stopProgressTracking();
    unawaited(_disposeController());
    _isSourceMissing = true;
    _state = PlaybackState.paused;
    _playlistManager?.reloadPlaylist();
    _transitionPlaybackSession(
      _session.generation,
      PlaybackSessionPhase.missing,
      desiredPlaying: false,
    );
    _setPlaybackTimelineRunning(false);
    _syncWakelockWithState();
    notifyListeners();
    unawaited(_savePlaybackStateSnapshot());
    unawaited(_refreshSubtitlesForCurrentItem(item));
  }

  /// Reopens the current item after a local source rebind. A late callback for
  /// media A must not stop or replace whatever is now current.
  Future<void> reloadAfterSourceRelocate({required String mediaId}) async {
    _playlistManager?.reloadPlaylist();
    _playlistManager?.refreshQueueEligibility();
    if (_currentItem?.id != mediaId) return;
    final item = _libraryService?.getVideo(mediaId);
    if (item == null) return;
    final startMs = item.lastPositionMs < 0 ? 0 : item.lastPositionMs;
    await play(
      item,
      autoPlay: false,
      forceRecreate: true,
      userInitiatedWatch: false,
      startPosition: Duration(milliseconds: startMs),
    );
  }

  bool get _transportTransitionPending {
    final commands = _transportCommands;
    return commands != null &&
        identical(commands.controller, _controller) &&
        commands.generation == _session.generation &&
        (commands.revision != commands.settledRevision ||
            commands.awaitingNativePosition != null);
  }

  bool _syncAwaitingTransportClock(
    VideoPlayerController controller,
    Duration position,
  ) {
    final queue = _transportCommands;
    final baseline = queue?.awaitingNativePosition;
    if (queue == null ||
        baseline == null ||
        !identical(queue.controller, controller) ||
        !identical(_controller, controller) ||
        queue.generation != _session.generation ||
        queue.revision != queue.settledRevision ||
        !_session.desiredPlaying ||
        position <= baseline + const Duration(milliseconds: 1)) {
      return false;
    }
    queue.awaitingNativePosition = null;
    _position = position;
    _resetPlaybackTimeline(
      position,
      running: _shouldTimelineRun(),
      preserveDanmakuPosition: true,
    );
    return true;
  }

  /// Serialize user transport commands for this controller, coalescing intents
  /// that become obsolete before dispatch. video_player changes isPlaying
  /// optimistically, before the platform has completed the actual operation.
  ///
  /// When nothing is in flight the native play/pause is invoked immediately,
  /// before the caller rebuilds the player page. The resume clock watch stays
  /// off this queue so the next tap is not stuck behind it.
  Future<void> _applyPlaybackTransport(
    VideoPlayerController controller, {
    required bool playing,
  }) {
    var commands = _transportCommands;
    if (commands == null ||
        !identical(commands.controller, controller) ||
        commands.generation != _session.generation) {
      final previous = commands;
      commands = _PlaybackTransportCommands(controller, _session.generation);
      if (previous != null && identical(previous.controller, controller)) {
        commands.tail = previous.tail;
      }
      _transportCommands = commands;
    }
    final queue = commands;
    final revision = ++queue.revision;
    queue.awaitingNativePosition = null;
    bool current() =>
        identical(_controller, controller) &&
        identical(_transportCommands, queue) &&
        queue.generation == _session.generation &&
        revision == queue.revision &&
        _session.desiredPlaying == playing;
    _setPlaybackTimelineRunning(false);

    final idle = queue.pendingNative == 0;
    queue.pendingNative++;
    // Publish the tail before the native call. controller.play/pause notifies
    // listeners synchronously, and a re-entrant tap must chain behind this
    // command instead of replacing it.
    final Completer<void>? idleGate = idle ? Completer<void>() : null;
    if (idleGate != null) {
      queue.tail = idleGate.future.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
    }
    final Future<void> started = idle
        ? _runTransportCommand(
            controller: controller,
            playing: playing,
            revision: revision,
            queue: queue,
            current: current,
          )
        : queue.tail.then(
            (_) => _runTransportCommand(
              controller: controller,
              playing: playing,
              revision: revision,
              queue: queue,
              current: current,
            ),
          );
    if (idleGate != null) {
      // Listen so a failed native call is not an unhandled async error.
      // The caller's returned future still reports that failure.
      unawaited(
        started.then<void>(
          (_) {
            if (!idleGate.isCompleted) idleGate.complete();
          },
          onError: (Object _, StackTrace _) {
            if (!idleGate.isCompleted) idleGate.complete();
          },
        ),
      );
    } else {
      queue.tail = started.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
    }
    return started;
  }

  Future<void> _runTransportCommand({
    required VideoPlayerController controller,
    required bool playing,
    required int revision,
    required _PlaybackTransportCommands queue,
    required bool Function() current,
  }) async {
    try {
      if (!current()) return;
      final seekRevision = _seekRequestId;
      try {
        if (playing) {
          await controller.play();
        } else {
          await controller.pause();
        }
      } catch (_) {
        if (current() && playing) {
          _setDesiredPlaying(false);
          _state = PlaybackState.paused;
          _setPlaybackTimelineRunning(false);
          _stopProgressTracking();
          _syncWakelockWithState();
          notifyListeners();
        }
        rethrow;
      }
      if (!current()) return;
      await _captureTransportPosition(
        controller: controller,
        playing: playing,
        revision: revision,
        seekRevision: seekRevision,
        queue: queue,
        current: current,
      );
    } finally {
      queue.pendingNative--;
      if (revision == queue.revision) {
        queue.settledRevision = revision;
        if (identical(_controller, controller) &&
            queue.generation == _session.generation) {
          _setPlaybackTimelineRunning(_shouldTimelineRun());
        }
      }
    }
  }

  /// One native position sample after play/pause. A resume whose clock has not
  /// moved yet keeps watching in the background; that watch is not awaited.
  Future<void> _captureTransportPosition({
    required VideoPlayerController controller,
    required bool playing,
    required int revision,
    required int seekRevision,
    required _PlaybackTransportCommands queue,
    required bool Function() current,
  }) async {
    Duration? nativePosition;
    try {
      // ignore: invalid_use_of_visible_for_testing_member
      final playerId = controller.playerId;
      final baseline = await NativeVideoPlayerMediaKit.transportPositionFor(
        playerId,
      );
      nativePosition = baseline ?? await controller.position;
      if (playing &&
          baseline != null &&
          current() &&
          seekRevision == _seekRequestId) {
        // Hold the lyric clock without holding the command queue.
        queue.awaitingNativePosition = baseline;
        unawaited(
          _watchTransportClock(
            controller: controller,
            playerId: playerId,
            baseline: baseline,
            revision: revision,
            seekRevision: seekRevision,
            queue: queue,
            current: current,
          ),
        );
      }
    } catch (_) {
      // A missing position sample must not substitute a stale Dart value.
    }
    _applyTransportSample(
      controller: controller,
      nativePosition: nativePosition,
      seekRevision: seekRevision,
      current: current,
    );
  }

  void _applyTransportSample({
    required VideoPlayerController controller,
    required Duration? nativePosition,
    required int seekRevision,
    required bool Function() current,
  }) {
    if (!current() ||
        seekRevision != _seekRequestId ||
        _pendingSeekRequestId != null ||
        nativePosition == null ||
        !controller.value.isInitialized ||
        _shouldIgnoreInitialPositionSample(nativePosition)) {
      return;
    }
    // Some network backends briefly expose their zero-byte probe position
    // after pausing. Keep the existing nonzero position in that case.
    final transientNetworkZero =
        nativePosition == Duration.zero &&
        _position.inMilliseconds > _seekVerificationToleranceMs &&
        _currentItem?.sourceRef?.kind == MediaSourceKind.bilibiliStream;
    if (transientNetworkZero) return;
    _position = _duration > Duration.zero && nativePosition > _duration
        ? _duration
        : nativePosition < Duration.zero
        ? Duration.zero
        : nativePosition;
    _resetPlaybackTimeline(
      _position,
      running: false,
      preserveDanmakuPosition: true,
    );
  }

  /// Resume can be acknowledged before the device or cache actually starts.
  /// Keep the lyric clock still until the native position moves, but do not
  /// make the next play/pause wait out this poll.
  Future<void> _watchTransportClock({
    required VideoPlayerController controller,
    required int playerId,
    required Duration baseline,
    required int revision,
    required int seekRevision,
    required _PlaybackTransportCommands queue,
    required bool Function() current,
  }) async {
    final wait = Stopwatch()..start();
    while (current() &&
        seekRevision == _seekRequestId &&
        wait.elapsedMilliseconds < 750) {
      await Future<void>.delayed(const Duration(milliseconds: 16));
      final sample = await NativeVideoPlayerMediaKit.transportPositionFor(
        playerId,
      );
      if (sample == null ||
          sample <= baseline + const Duration(milliseconds: 1)) {
        continue;
      }
      if (!current() ||
          seekRevision != _seekRequestId ||
          queue.awaitingNativePosition != baseline) {
        return;
      }
      queue.awaitingNativePosition = null;
      _applyTransportSample(
        controller: controller,
        nativePosition: sample,
        seekRevision: seekRevision,
        current: current,
      );
      if (revision == queue.revision &&
          identical(_controller, controller) &&
          queue.generation == _session.generation) {
        _setPlaybackTimelineRunning(_shouldTimelineRun());
      }
      return;
    }
    if (!current() ||
        seekRevision != _seekRequestId ||
        queue.awaitingNativePosition != baseline) {
      return;
    }
    // A long cache pause must not block controls indefinitely. The native
    // position stream releases this hold when it moves.
    queue.awaitingNativePosition = baseline;
  }

  /// Pauses the source while a separate preview owns the native video output.
  /// The caller restores after its route has left and its player is released.
  Future<PlaybackPreviewSuspension> suspendForPreview() async {
    final previous = _previewPlaybackTail;
    final released = Completer<void>();
    _previewPlaybackTail = released.future;
    try {
      // A popped route may finish its animation before native dispose returns.
      // A second preview must capture intent after the first restores it.
      if (previous != null) await previous;
      final itemId = _currentItem?.id;
      final controller = _controller;
      final generation = sessionGeneration;
      final shouldResume = desiredPlaying || isTransportPlaying;
      final pauseRevision = _playbackPauseRevision + (shouldResume ? 1 : 0);
      if (shouldResume && itemId != null) {
        await pause(expectedItemId: itemId, expectedController: controller);
      }
      return PlaybackPreviewSuspension._(() async {
        try {
          bool isOriginalSession() =>
              itemId != null &&
              _currentItem?.id == itemId &&
              sessionGeneration == generation &&
              (controller == null || identical(_controller, controller)) &&
              _playbackPauseRevision == pauseRevision;
          if (!isOriginalSession()) return;
          if (shouldResume) await resume();
          if (!isOriginalSession()) return;
          if (_hasVisiblePlaybackPage) await ensureVisibleVideoOutput(itemId!);
          // A queue popup can sit between the playback PageRoute and preview,
          // so RouteAware alone misses return. Refresh paused sessions too.
          if (_currentItem?.id == itemId) notifyListeners();
        } finally {
          released.complete();
          if (identical(_previewPlaybackTail, released.future)) {
            _previewPlaybackTail = null;
          }
        }
      });
    } catch (_) {
      released.complete();
      if (identical(_previewPlaybackTail, released.future)) {
        _previewPlaybackTail = null;
      }
      rethrow;
    }
  }

  /// 暂停播放
  ///
  /// [notify] is false only for a playback-page exit. The native pause still
  /// happens immediately; listeners are told after the exit zoom has started.
  Future<void> pause({
    String? expectedItemId,
    VideoPlayerController? expectedController,
    bool notify = true,
  }) async {
    if (expectedItemId != null && _currentItem?.id != expectedItemId) return;
    if (expectedController != null &&
        !identical(_controller, expectedController)) {
      return;
    }
    _playbackPauseRevision++;
    final hadTransportPlayIntent = isTransportPlaying;
    // Pause remains an intent while a failed online open is between retry
    // attempts, even when no controller is currently installed.
    _setDesiredPlaying(false);
    if (_activePlayInvocationGeneration == _session.generation) {
      _setDesiredPlaying(false);
      // Bilibili Windows/cache-pause leaves Dart isPlaying false while audio
      // is running. Pause the native transport unconditionally; play() then
      // observes desiredPlaying=false and finishes paused.
      if (_state == PlaybackState.playing || _state == PlaybackState.loading) {
        _state = PlaybackState.paused;
        _setPlaybackTimelineRunning(false);
        _syncWakelockWithState();
        _stopProgressTracking();
      }
      final loadingController = _controller;
      // Send the platform pause before rebuilding listeners. The controller
      // call itself only notifies its own listeners before the message.
      final nativePause =
          _currentItem?.id == _session.itemId && loadingController != null
          ? loadingController.pause()
          : null;
      if (notify) {
        notifyListeners();
      } else {
        publishUiAfterExitTransition();
      }
      if (nativePause != null) {
        try {
          await nativePause;
        } catch (_) {}
      }
      unawaited(_saveCurrentProgress(immediate: true));
      unawaited(_commitWatchFlush(_watchMeter.flush()));
      return;
    }
    if (_state != PlaybackState.playing && !hadTransportPlayIntent) {
      unawaited(_commitWatchFlush(_watchMeter.flush()));
      return;
    }
    final controller = _controller;
    final itemId = _currentItem?.id;
    if (controller == null || itemId == null) return;
    final requestId = ++_playRequestId;
    _seekRequestId++;
    _pendingSeekRequestId = null;

    try {
      _preservePlayingStateAfterSeek = false;
      _logPlaybackEvent(
        'pause requested',
        data: <String, Object?>{
          'itemId': _currentItem?.id,
          'positionMs': _position.inMilliseconds,
        },
      );
      // 乐观更新：立即设置状态为暂停
      // Freeze the presented position during the native transition. The
      // acknowledged transport command then samples its actual stop position.
      _setPlaybackTimelineRunning(false);
      _state = PlaybackState.paused;
      _setDesiredPlaying(false);
      _syncWakelockWithState();
      _stopProgressTracking();
      // Native pause goes out before the player page rebuild. That rebuild is
      // synchronous and used to delay the platform message.
      final transport = _applyPlaybackTransport(controller, playing: false);
      if (notify) {
        notifyListeners();
      } else {
        publishUiAfterExitTransition();
      }

      await transport;
      if (!_isCurrentPlayRequest(requestId, itemId, controller: controller)) {
        return;
      }

      // Position was calibrated from a fresh native read by the transport
      // command. Do not replace it with the controller's older cached value.
      if (controller.value.isInitialized) {
        _bufferedPosition = _readBufferedPosition(controller);
      }

      // 暂停时保存进度，但不占住下一次播放/暂停命令。
      unawaited(_saveCurrentProgress(immediate: true));
      unawaited(_commitWatchFlush(_watchMeter.flush()));
      unawaited(_savePlaybackStateSnapshot());

      if (notify) {
        notifyListeners();
      } else {
        publishUiAfterExitTransition();
      }
    } catch (e) {
      debugPrint('MediaPlaybackService: 暂停失败 $e');
      if (!notify &&
          _isCurrentPlayRequest(requestId, itemId, controller: controller)) {
        publishUiAfterExitTransition();
      }
    }
  }

  void publishUiAfterExitTransition() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        notifyListeners();
      });
    });
  }

  /// 继续播放
  Future<void> resume() async {
    if (_currentItem case final current?) {
      requireCommunityPlaybackSource(current.path, source: current.sourceRef);
    }
    final currentItem = _currentItem;
    if (currentItem == null && queuedPreviewItem != null) {
      await playPlaylistItem(queuedPreviewItem!, autoPlay: true);
      return;
    }
    if (_activePlayInvocationGeneration == _session.generation) {
      _setDesiredPlaying(true);
      final loadingController = _controller;
      // Keep the notification transport state responsive while the episode
      // switch Future is still active. The play() transaction reconciles this
      // latest intent again before it commits the new controller.
      final nativePlay =
          currentItem?.id == _session.itemId &&
              loadingController != null &&
              loadingController.value.isInitialized &&
              (_onlineStartup?.isPending != true ||
                  _onlineStartup!.isPrepared) &&
              !loadingController.value.isPlaying
          ? loadingController.play()
          : null;
      notifyListeners();
      if (nativePlay != null) {
        try {
          await nativePlay;
        } catch (_) {}
      }
      return;
    }
    if (_state == PlaybackState.error && currentItem != null) {
      _logPlaybackEvent(
        'resume requested after load failure; retrying media',
        data: <String, Object?>{'itemId': currentItem.id},
      );
      await play(
        currentItem,
        autoPlay: true,
        startPosition: _position,
        forceRecreate: true,
      );
      return;
    }
    if (_isSourceMissing && currentItem != null) {
      // The play button doubles as a retry. If the user has restored the file
      // at its original path, the existing page becomes playable immediately.
      await play(currentItem, autoPlay: true, startPosition: _position);
      return;
    }
    if (currentItem != null &&
        _controller == null &&
        (_state == PlaybackState.paused || _state == PlaybackState.loading)) {
      await play(currentItem, autoPlay: true, startPosition: _position);
      return;
    }
    if (_hasPlaybackCompleted && currentItem != null) {
      _logPlaybackEvent(
        'resume requested after completion',
        data: <String, Object?>{'itemId': currentItem.id},
      );
      // 修复：使用当前位置而不是从头开始，这样用户拖拽进度条后能正确恢复播放
      final resumePosition =
          (_position < _duration && _position > Duration.zero)
          ? _position
          : Duration.zero;
      await play(currentItem, autoPlay: true, startPosition: resumePosition);
      return;
    }

    if (currentItem == null || _state == PlaybackState.idle) return;
    if (_isOnlineMedia(currentItem) && _state != PlaybackState.playing) {
      // A paused open can park the same decoder as a cold episode switch.
      // Reuse its controller through the shared clock verification/recovery
      // path, including notification/headset play and latest pause intent.
      await play(currentItem, autoPlay: true, userInitiatedWatch: false);
      return;
    }
    final controller = _controller;
    final itemId = _currentItem?.id;
    if (controller == null || itemId == null) {
      await play(currentItem, autoPlay: true, startPosition: _position);
      return;
    }
    final requestId = ++_playRequestId;
    _seekRequestId++;
    _pendingSeekRequestId = null;

    try {
      _setDesiredPlaying(true);
      _hasPlaybackCompleted = false;
      _logPlaybackEvent(
        'resume requested',
        data: <String, Object?>{
          'itemId': _currentItem?.id,
          'positionMs': _position.inMilliseconds,
        },
      );
      // Windows Mini can sit in loading while the AO is paused, or in playing
      // while Dart isPlaying stays false. Do not require `_state == paused`.
      final wasPaused = _state == PlaybackState.paused;
      final wasAlreadyPlaying = _state == PlaybackState.playing;
      _state = PlaybackState.playing;
      _syncWakelockWithState();

      // _seekInitialPosition pauses first. Only realign a session that was
      // actually paused; doing it over a live Mini/notification clock is the
      // audible hitch on page entry.
      if (wasPaused &&
          currentItem.sourceRef?.kind == MediaSourceKind.bilibiliStream &&
          controller.value.isInitialized &&
          (controller.value.position.inMilliseconds - _position.inMilliseconds)
                  .abs() >
              _seekVerificationToleranceMs) {
        await _seekInitialPosition(controller, _position);
        if (!_isCurrentPlayRequest(requestId, itemId, controller: controller)) {
          return;
        }
      }

      _startProgressTracking();

      // Mini card play is audio-only. Apply that before starting the clock so
      // a Windows resume cannot begin pulling the video track. Skip when the
      // session was already playing: a page-entry repair must not re-enable
      // and seek the video demuxer over live audio.
      if (!wasAlreadyPlaying &&
          currentItem.sourceRef?.kind == MediaSourceKind.bilibiliStream) {
        await _awaitBilibiliVideoTrackPolicy();
        if (!_isCurrentPlayRequest(requestId, itemId, controller: controller)) {
          return;
        }
      }

      // Dispatch play before the page rebuild, same as pause.
      final transport = _applyPlaybackTransport(controller, playing: true);
      notifyListeners();
      await transport;
      if (!_isCurrentPlayRequest(requestId, itemId, controller: controller)) {
        return;
      }

      if (controller.value.isInitialized) {
        // The serialized command has aligned the clock to a fresh native
        // position; the cached Dart value may still precede the pause.
        _setPlaybackTimelineRunning(_shouldTimelineRun());
      }

      // 保存播放状态快照，不挡下一次播放/暂停。
      unawaited(_savePlaybackStateSnapshot());
      notifyListeners();
    } catch (e) {
      debugPrint('MediaPlaybackService: 继续播放失败 $e');
    }
  }

  /// 从 controller 同步播放状态（用于播放页面状态同步）
  /// 这个方法不进行状态检查，直接更新状态并通知监听器
  bool updatePlaybackStateFromController({
    String? expectedItemId,
    VideoPlayerController? expectedController,
    bool notify = true,
  }) {
    if (expectedItemId != null && _currentItem?.id != expectedItemId) {
      return false;
    }
    final controller = _controller;
    if (expectedController != null &&
        !identical(controller, expectedController)) {
      return false;
    }
    if (controller == null || !controller.value.isInitialized) return false;
    if (_initialPositionSeekInFlight) return false;
    if (_transportTransitionPending) return false;

    // 直接从 controller 读取实际播放状态
    final controllerIsPlaying = controller.value.isPlaying;
    if (controllerIsPlaying) {
      _preservePlayingStateAfterSeek = false;
    } else if (_pendingSeekRequestId != null ||
        _preservePlayingStateAfterSeek) {
      return false;
    }
    final sample = controller.value.position;
    final controllerDuration = _presentationDuration(controller.value.duration);
    final controllerBufferedPosition = _readBufferedPosition(controller);
    if (_shouldIgnoreInitialPositionSample(sample)) {
      _duration = controllerDuration;
      _bufferedPosition = controllerBufferedPosition;
      return true;
    }
    final controllerPosition = _holdUnconfirmedBilibiliZero(controller, sample)
        ? _position
        : sample;
    _capturePlaybackSpeedFromController(controller);
    final reachedPlaybackEnd = _hasReachedPlaybackEnd(
      controllerPosition,
      controllerDuration,
    );

    if (!controllerIsPlaying &&
        !_hasPlaybackCompleted &&
        reachedPlaybackEnd &&
        (_state == PlaybackState.playing || _lastControllerIsPlaying == true)) {
      _position = controllerPosition;
      _duration = controllerDuration;
      _bufferedPosition = controllerBufferedPosition;
      _resetPlaybackTimeline(controllerPosition, running: false);
      _lastControllerIsPlaying = controllerIsPlaying;
      _logPlaybackEvent(
        'controller sync detected playback completion',
        data: <String, Object?>{
          'itemId': _currentItem?.id,
          'positionMs': controllerPosition.inMilliseconds,
          'durationMs': controllerDuration.inMilliseconds,
        },
      );
      _onPlaybackCompleted();
      return true;
    }

    // Keep the completed presentation at EOF despite trailing native samples.
    // Persistence separately stores a restart-at-zero bookmark for the next
    // launch; the visible timeline must remain on the last frame.
    if (_hasPlaybackCompleted) {
      if (!controllerIsPlaying) {
        _state = PlaybackState.paused;
        _setPlaybackTimelineRunning(false);
        _stopProgressTracking();
      }
      return true;
    }

    // The session intent is the play/pause authority. A transient controller
    // sample that disagrees with it — a late clock start after a degraded
    // pause, a seek-transition sample, a stale listener during a hand-off —
    // must not flip the public state (and with it the notification button);
    // only progress is taken from the sample. Page toggle buttons read the
    // controller directly, so they are unaffected by this guard.
    if (controllerIsPlaying != _session.desiredPlaying) {
      _lastControllerIsPlaying = controllerIsPlaying;
      _position = controllerPosition;
      _duration = controllerDuration;
      _bufferedPosition = controllerBufferedPosition;
      _resetPlaybackTimeline(
        controllerPosition,
        running: _session.desiredPlaying,
        preserveDanmakuPosition: true,
      );
      return true;
    }

    if (controllerIsPlaying) {
      _hasPlaybackCompleted = false;
      _state = PlaybackState.playing;
      _position = controllerPosition;
      _duration = controllerDuration;
      // Continue from the last rendered danmaku position. Re-anchoring to the
      // controller's low-frequency sample here moves every item at once.
      _setPlaybackTimelineRunning(true);
      // 重新启动进度追踪定时器
      _startProgressTracking();
    } else {
      _state = PlaybackState.paused;
      _setPlaybackTimelineRunning(false);
      // 停止进度追踪定时器
      _stopProgressTracking();

      // 更新最终位置
      _position = controllerPosition;
      _duration = controllerDuration;
      _bufferedPosition = controllerBufferedPosition;

      // 暂停时立即保存进度
      _saveCurrentProgress(immediate: true);
    }

    _syncWakelockWithState();

    // 异步保存播放状态快照（不阻塞UI）
    _savePlaybackStateSnapshot().catchError((e) {
      debugPrint('保存播放状态快照失败: $e');
    });

    // 通知监听器，触发 UI 更新
    if (notify) {
      notifyListeners();
    } else {
      publishUiAfterExitTransition();
    }
    return true;
  }

  /// 停止播放
  Future<void> stop() async {
    _activeOpenBudget?.cancel();
    _activeOpenBudget = null;
    _bilibiliStartup?.geometry.removeListener(_onBilibiliGeometryChanged);
    _bilibiliVisibleStartup?.cancel();
    _bilibiliVisibleStartup = null;
    _onlineStartup?.cancel();
    _pendingSwitchItem = null;
    _supersedeDirectSwitch();
    final stoppedItem = _currentItem;
    final stoppedPosition = _hasPlaybackCompleted ? Duration.zero : _position;
    final stoppedBilibiliStreamItemId =
        stoppedItem?.sourceRef?.kind == MediaSourceKind.bilibiliStream
        ? stoppedItem!.id
        : null;
    _streamQualitySwitchRequestId++;
    _isSwitchingStreamQuality = false;
    final stopRequestId = ++_playRequestId;
    _seekRequestId++;
    _pendingSeekRequestId = null;
    _clearSeekHoldOverlay();
    _preservePlayingStateAfterSeek = false;
    _cancelHopSeekDispatch();
    _clearInitialPositionGuard();
    _hasPlaybackCompleted = false;
    _logPlaybackEvent(
      'stop requested',
      data: <String, Object?>{
        'itemId': _currentItem?.id,
        'positionMs': _position.inMilliseconds,
      },
    );
    // 保存当前进度
    await _saveFrozenProgress(stoppedItem, stoppedPosition);
    if (stopRequestId != _playRequestId) return;

    // 保存播放状态快照（停止状态）
    if (_progressTracker != null) {
      await _progressTracker!.savePlaybackState(
        PlaybackStateSnapshot(
          currentItemId: null,
          positionMs: 0,
          wasPlaying: false,
          playlistFolderId: null,
        ),
      );
      if (stopRequestId != _playRequestId) return;
    }

    // 停止进度追踪
    _stopProgressTracking();
    _seekPersistTimer?.cancel();
    _seekPersistTimer = null;

    // 释放控制器
    await _disposeController(
      awaitCompletion: stoppedBilibiliStreamItemId != null,
    );
    if (stopRequestId != _playRequestId) return;
    if (stoppedBilibiliStreamItemId != null) {
      await _bilibiliStreamingService?.releaseItem(stoppedBilibiliStreamItemId);
      if (stopRequestId != _playRequestId) return;
    }
    unawaited(_disposePreloadedController());
    _preloadTriggered = false;

    _state = PlaybackState.idle;
    _pendingEpisodeNavigation.clear();
    _isSourceMissing = false;
    _streamQualities = const [];
    _selectedStreamQuality = null;
    _streamAudioQualities = const [];
    _selectedStreamAudioQuality = null;
    _setStreamDisplayAspectRatio(null, null);
    _currentBilibiliPlayback = null;
    _bilibiliAudioPrimaryPlayer = false;
    _syncWakelockWithState();
    clearSubtitleState();
    _currentItem = null;
    final stoppedGeneration = ++_sessionGeneration;
    _sessionController = null;
    _session = PlaybackSessionSnapshot(
      generation: stoppedGeneration,
      itemId: stoppedItem?.id,
      phase: PlaybackSessionPhase.stopped,
      desiredPlaying: false,
      controllerGeneration: _controllerGeneration,
      hasVideoOutput: false,
    );
    _position = Duration.zero;
    _duration = Duration.zero;
    _bufferedPosition = Duration.zero;
    _resetPlaybackTimeline(Duration.zero, running: false, rate: 1.0);
    _syncBilibiliCachePolicy();

    notifyListeners();
  }

  void _cancelHopSeekDispatch() {
    _hopSeekDispatchTimer?.cancel();
    _hopSeekDispatchTimer = null;
    _pendingHopSeekPosition = null;
    _pendingHopSeekSource = null;
  }

  Duration _clampSeekPosition(
    VideoPlayerController controller,
    Duration position,
  ) {
    final controllerDuration = _presentationDuration(controller.value.duration);
    if (controllerDuration > Duration.zero && controllerDuration != _duration) {
      _duration = controllerDuration;
    }
    if (_duration > Duration.zero) {
      return Duration(
        milliseconds: position.inMilliseconds
            .clamp(0, _duration.inMilliseconds)
            .toInt(),
      );
    }
    return position.inMilliseconds < 0 ? Duration.zero : position;
  }

  /// UI and subtitle highlight jump immediately; native work can lag or coalesce.
  void _applyOptimisticSeek(
    Duration clampedPosition, {
    required String source,
  }) {
    if (_onlineStartup?.isPending == true) {
      _onlineStartup!.target = clampedPosition;
      _onlineStartup!.hasUserTarget = true;
    }
    // A manual seek supersedes the bounded startup guard. Otherwise a stale
    // native sample from the previous startup could hide the user's target.
    _clearInitialPositionGuard();
    // A slow ALAC seek can publish samples from the old position before
    // libmpv reaches the new timestamp. All progress surfaces share this
    // service, so keep those stale samples from snapping every UI back.
    _armInitialPositionGuard(clampedPosition, protectZero: true);

    // Scrubbing away from the end leaves the completed session. Seeking onto
    // the last frame keeps the completed session and its restart bookmark.
    if (_duration <= Duration.zero ||
        !_hasReachedPlaybackEnd(clampedPosition, _duration)) {
      _hasPlaybackCompleted = false;
    }
    _lastSeekSource = source;
    _lastRequestedSeekPosition = clampedPosition;
    _lastSeekRequestedAt = DateTime.now();
    if (SubtitleHopSeekPolicy.isHopSeekSource(source)) {
      _lastHopSeekAt = _lastSeekRequestedAt;
    }
    _logPlaybackEvent(
      'seek requested',
      data: <String, Object?>{
        'itemId': _currentItem?.id,
        'source': source,
        'targetMs': clampedPosition.inMilliseconds,
        'durationMs': _duration.inMilliseconds,
        'online': isCurrentItemOnlineBilibiliStream,
      },
    );

    final requestId = ++_seekRequestId;
    _pendingSeekRequestId = requestId;
    final seeksToPlaybackEnd =
        _duration > Duration.zero &&
        _hasReachedPlaybackEnd(clampedPosition, _duration);
    _preservePlayingStateAfterSeek =
        !seeksToPlaybackEnd &&
        (_preservePlayingStateAfterSeek || _state == PlaybackState.playing);

    _position = clampedPosition;
    // Freeze the interpolator until the native clock actually ticks again.
    // Leaving it running made the bar crawl while the picture was still frozen.
    _resetPlaybackTimeline(_position, running: false);
    notifyListeners();
  }

  /// 跳转到指定位置
  Future<void> seekTo(Duration position, {String source = 'ui'}) async {
    final controller = _controller;
    final itemId = _currentItem?.id;
    if (itemId != null &&
        _onlineStartup?.isPending == true &&
        (controller == null ||
            !controller.value.isInitialized ||
            !identical(controller, _sessionController))) {
      final target = position < Duration.zero
          ? Duration.zero
          : _duration > Duration.zero && position > _duration
          ? _duration
          : position;
      _applyOptimisticSeek(target, source: source);
      // No native seek was dispatched; play() will pass this latest target to
      // the new controller. Do not leave a nonexistent acknowledgement pending.
      _pendingSeekRequestId = null;
      return;
    }
    if (controller == null ||
        itemId == null ||
        !controller.value.isInitialized) {
      return;
    }
    _transportCommands?.awaitingNativePosition = null;
    _watchMeter.beginSeek();

    final hop = SubtitleHopSeekPolicy.isHopSeekSource(source);
    if (!hop) {
      _cancelHopSeekDispatch();
    }

    final clampedPosition = _clampSeekPosition(controller, position);
    _applyOptimisticSeek(clampedPosition, source: source);

    final delay = SubtitleHopSeekPolicy.nativeDispatchDelay(
      isOnlineBilibiliStream: isCurrentItemOnlineBilibiliStream,
      source: source,
    );
    if (hop && delay > Duration.zero) {
      _pendingHopSeekPosition = clampedPosition;
      _pendingHopSeekSource = source;
      _hopSeekDispatchTimer?.cancel();
      _hopSeekDispatchTimer = Timer(delay, () {
        final target = _pendingHopSeekPosition;
        final hopSource = _pendingHopSeekSource ?? source;
        _pendingHopSeekPosition = null;
        _pendingHopSeekSource = null;
        _hopSeekDispatchTimer = null;
        if (target == null) return;
        unawaited(_runNativeSeek(target, source: hopSource));
      });
      return;
    }

    await _runNativeSeek(clampedPosition, source: source);
  }

  Future<void> _runNativeSeek(
    Duration clampedPosition, {
    required String source,
  }) async {
    final controller = _controller;
    final itemId = _currentItem?.id;
    final playRequestId = _playRequestId;
    if (controller == null ||
        itemId == null ||
        !controller.value.isInitialized) {
      return;
    }

    final requestId = _seekRequestId;
    _pendingSeekRequestId = requestId;
    // Seek-hold waits for the native clock to move. A paused subtitle hop
    // never does, so arming it only flashes a spinner over a still frame.
    if (isCurrentItemStreamingBilibiliCard && _state == PlaybackState.playing) {
      _armSeekHoldOverlay();
    }
    final awaitAck = SubtitleHopSeekPolicy.shouldAwaitNativeSeekAck(
      isOnlineBilibiliStream: isCurrentItemOnlineBilibiliStream,
      source: source,
    );
    final seekStyle = _bilibiliAudioPrimaryPlayer
        ? StreamingSeekStyle.hop
        : SubtitleHopSeekPolicy.streamingSeekStyleFor(
            isOnlineBilibiliStream: isCurrentItemOnlineBilibiliStream,
            source: source,
          );

    Future<void> dispatch() async {
      try {
        if (isCurrentItemStreamingBilibiliCard) {
          notifyListeners();
        }
        await NativeVideoPlayerMediaKit.prepareSeekStyleFor(
          // ignore: invalid_use_of_visible_for_testing_member
          controller.playerId,
          style: seekStyle,
        );
        if (requestId != _seekRequestId ||
            playRequestId != _playRequestId ||
            !_isCurrentControllerSession(controller, itemId)) {
          return;
        }

        if (_currentItem?.sourceRef?.podcast != null) {
          PodcastPlaybackHooks.prepareSeek?.call(_currentItem!);
        }
        await controller
            .seekTo(clampedPosition)
            .timeout(_controllerSeekTimeout);
        if (requestId != _seekRequestId ||
            playRequestId != _playRequestId ||
            !_isCurrentControllerSession(controller, itemId)) {
          return;
        }

        // VideoPlayerController has acknowledged this exact target. Its native
        // position sampler can still lag briefly, so a bounded direct verifier
        // below owns any later correction.
        final actualPosition = clampedPosition;
        _watchMeter.endSeek(positionMs: actualPosition.inMilliseconds);
        if (actualPosition != _position) {
          _position = actualPosition;
          // 校正插值基线，确保插值时钟从实际位置继续推进
          _resetPlaybackTimeline(_position, running: _shouldTimelineRun());
          notifyListeners();
        }
        if (_pendingSeekRequestId == requestId) {
          _pendingSeekRequestId = null;
        }
        // Apply the acknowledgement even with visible consumers: their
        // presentation ticker is suspended while the seek is pending.
        // Seek-hold, buffering and native-led podcast guards remain in force.
        _setPlaybackTimelineRunning(_shouldTimelineRun());
        _logPlaybackEvent(
          'seek applied',
          data: <String, Object?>{
            'source': source,
            'actualMs': actualPosition.inMilliseconds,
            'deltaMs':
                (actualPosition.inMilliseconds - clampedPosition.inMilliseconds)
                    .abs(),
            'seekStyle': seekStyle.name,
          },
        );
        _syncBilibiliGatewaySpeed(notify: isCurrentItemStreamingBilibiliCard);
        _bufferedPosition = _readBufferedPosition(controller);
        _scheduleSeekVerification(
          expectedPosition: clampedPosition,
          source: source,
          controller: controller,
          itemId: itemId,
          requestId: requestId,
        );

        _seekPersistTimer?.cancel();
        _seekPersistTimer = Timer(const Duration(milliseconds: 500), () {
          if (playRequestId != _playRequestId ||
              !_isCurrentControllerSession(controller, itemId)) {
            return;
          }
          _saveCurrentProgress(immediate: true).catchError((e) {
            debugPrint('MediaPlaybackService: 保存进度失败 $e');
          });
          _savePlaybackStateSnapshot().catchError((e) {
            debugPrint('MediaPlaybackService: 保存播放状态快照失败 $e');
          });
        });

        notifyListeners();
      } catch (e) {
        if (_pendingSeekRequestId == requestId) {
          _pendingSeekRequestId = null;
        }
        final isCurrentSession =
            playRequestId == _playRequestId &&
            _isCurrentControllerSession(controller, itemId);
        if (isCurrentSession && controller.value.isInitialized) {
          final controllerDuration = _presentationDuration(
            controller.value.duration,
          );
          if (controllerDuration > Duration.zero) {
            _duration = controllerDuration;
          }
          _bufferedPosition = _readBufferedPosition(controller);

          if (e is TimeoutException) {
            // Some native audio backends finish a precise seek after their Dart
            // completion callback stalls. Stop blocking position samples now,
            // then let the bounded verifier reconcile the eventual result.
            final expectedPosition = _lastRequestedSeekPosition ?? _position;
            _armInitialPositionGuard(expectedPosition, protectZero: true);
            _scheduleSeekVerification(
              expectedPosition: expectedPosition,
              source: '$source-timeout',
              controller: controller,
              itemId: itemId,
              requestId: requestId,
            );
            // Re-enable presentation after releasing the pending seek gate.
            // The target guard and verifier still own late native drift.
            _setPlaybackTimelineRunning(_shouldTimelineRun());
          } else {
            _clearInitialPositionGuard();
            _position = controller.value.position;
            _resetPlaybackTimeline(_position, running: _shouldTimelineRun());
          }
          notifyListeners();
        }
        debugPrint('MediaPlaybackService: 跳转失败 $e');
      } finally {
        // Always release the sampling gate owned by this request. In
        // particular, a stale controller/session return or a native Future that
        // times out must never leave all future progress updates suppressed.
        if (_pendingSeekRequestId == requestId) {
          _pendingSeekRequestId = null;
          _setPlaybackTimelineRunning(_shouldTimelineRun());
          notifyListeners();
        }
      }
    }

    if (awaitAck) {
      await dispatch();
      return;
    }
    unawaited(dispatch());
  }

  /// 设置音量
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);

    if (_controller != null && !_isMuted) {
      await _applyMuteStateToController(reason: 'volume changed');
    }

    notifyListeners();
  }

  /// 切换静音状态
  Future<void> toggleMute() async {
    _isMuted = !_isMuted;
    notifyListeners();
    await Future.wait<void>([
      _persistMuteState(),
      _applyMuteStateToController(reason: 'toggle mute'),
    ]);
  }

  /// 播放下一个媒体
  Future<void> playNext({bool? autoPlay}) {
    final bool shouldAutoPlay = autoPlay ?? SettingsService().autoPlayNextVideo;
    _logPlaybackEvent(
      'skip to next requested',
      data: <String, Object?>{
        'itemId': _currentItem?.id,
        'autoPlay': shouldAutoPlay,
      },
    );
    // 确保播放列表是最新的
    return _enqueueEpisodeNavigation(
      1,
      autoPlay: shouldAutoPlay,
      directEpoch: _directEpoch,
    );
  }

  /// 播放上一个媒体
  Future<void> playPrevious({bool? autoPlay}) {
    final bool shouldAutoPlay = autoPlay ?? SettingsService().autoPlayNextVideo;
    _logPlaybackEvent(
      'skip to previous requested',
      data: <String, Object?>{
        'itemId': _currentItem?.id,
        'autoPlay': shouldAutoPlay,
      },
    );
    // 确保播放列表是最新的
    return _enqueueEpisodeNavigation(
      -1,
      autoPlay: shouldAutoPlay,
      directEpoch: _directEpoch,
    );
  }

  Future<void> _enqueueEpisodeNavigation(
    int delta, {
    required bool autoPlay,
    required int directEpoch,
  }) {
    _pendingEpisodeNavigation.add(
      _EpisodeNavigationCommand(
        delta: delta,
        autoPlay: autoPlay,
        directEpoch: directEpoch,
      ),
    );
    final completer = _episodeNavigationCompleter ??= Completer<void>();
    if (!_isDrainingEpisodeNavigation) {
      _isDrainingEpisodeNavigation = true;
      scheduleMicrotask(_drainEpisodeNavigation);
    }
    return completer.future;
  }

  Future<void> _drainEpisodeNavigation() async {
    final completer = _episodeNavigationCompleter;
    try {
      while (_pendingEpisodeNavigation.isNotEmpty) {
        final commands = List<_EpisodeNavigationCommand>.of(
          _pendingEpisodeNavigation,
        );
        _pendingEpisodeNavigation.clear();
        await _executeEpisodeNavigation(commands);
      }
    } catch (error, stackTrace) {
      if (completer != null && !completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    } finally {
      _isDrainingEpisodeNavigation = false;
      if (identical(_episodeNavigationCompleter, completer)) {
        _episodeNavigationCompleter = null;
      }
      if (completer != null && !completer.isCompleted) {
        completer.complete();
      }
    }
  }

  Future<void> _executeEpisodeNavigation(
    List<_EpisodeNavigationCommand> commands,
  ) async {
    final manager = _playlistManager;
    if (manager == null || commands.isEmpty) return;
    final fresh = commands
        .where((command) => command.directEpoch == _directEpoch)
        .toList(growable: false);
    if (fresh.isEmpty) return;
    commands = fresh;
    if (!await _prepareCloudQueue()) return;
    if (commands.any((command) => command.directEpoch != _directEpoch)) return;
    manager.revalidatePlaylist();
    var snapshot = manager.snapshot;
    if (snapshot.currentIndex < 0 || snapshot.entries.isEmpty) return;
    final movingForward = commands.any((command) => command.delta > 0);
    final continuation = cloudDriveLoadNextPlaylistPage;
    if (movingForward &&
        continuation != null &&
        manager.relativeItem(next: true) == null) {
      await continuation();
      if (commands.any((command) => command.directEpoch != _directEpoch)) {
        return;
      }
      snapshot = manager.snapshot;
    }

    final wrap = SettingsService().playlistWrapToFirst;
    final navigation = manager.planNavigation(
      commands.map((command) => command.delta),
      wrap: wrap,
    );
    if (navigation == null) return;
    final target = navigation.item;
    if (!manager.isQueueEligible(target)) {
      manager.revalidatePlaylist();
      if (commands.every((command) => command.directEpoch == _directEpoch)) {
        await _executeEpisodeNavigation(commands);
      }
      return;
    }
    await _playPlaylistItem(
      target,
      autoPlay: commands.last.autoPlay,
      directEpoch: commands.last.directEpoch,
      navigation: navigation,
    );
  }

  /// 播放列表切换统一入口：切换前立即保存当前媒体进度，
  /// 避免新的保存请求覆盖上一媒体尚未落库的防抖进度。
  Future<void> playPlaylistItem(
    VideoItem item, {
    bool? autoPlay,
    Duration? startPosition,
    bool forceFromStart = false,
  }) async {
    item = _communityPlaybackItem(item);
    final manager = _playlistManager;
    if (manager != null && !manager.isQueueEligible(item)) return;
    // The intent exists before the switch lock, so a tap on C does not wait
    // for B's initialize timeout before B is told to stop.
    _supersedeDirectSwitch();
    final epoch = _directEpoch;
    _pendingSwitchItem = item;
    notifyListeners();
    try {
      await _playPlaylistItem(
        item,
        autoPlay: autoPlay ?? SettingsService().autoPlayNextVideo,
        startPosition: startPosition,
        forceFromStart: forceFromStart,
        directEpoch: epoch,
      );
    } finally {
      if (epoch == _directEpoch && _pendingSwitchItem?.id == item.id) {
        _pendingSwitchItem = null;
        notifyListeners();
      }
    }
  }

  /// Serializes every media-switch entry ([_playPlaylistItem]) — episode
  /// navigation, notification queue taps, completion auto-advance and errored
  /// controller recovery — so two switches can never interleave their
  /// controller dispose/initialize work. Request-id checks inside [play]
  /// remain the second line of defense.
  Future<void> _mediaSwitchLock = Future<void>.value();

  Future<void> _runInMediaSwitchLock(Future<void> Function() action) {
    final operation = _mediaSwitchLock.then((_) => action());
    _mediaSwitchLock = operation.catchError((Object error, StackTrace stack) {
      _logPlaybackEvent(
        'media switch failed',
        data: <String, Object?>{'error': error.toString()},
      );
    });
    return operation;
  }

  Future<void> _playPlaylistItem(
    VideoItem item, {
    bool autoPlay = true,
    Duration? startPosition,
    bool forceFromStart = false,
    bool userInitiatedWatch = true,
    int? directEpoch,
    PlaybackQueueNavigation? navigation,
    int? completionPauseRevision,
  }) {
    final epoch = directEpoch ?? _directEpoch;
    return _runInMediaSwitchLock(() async {
      if (epoch != _directEpoch) return;
      if (completionPauseRevision != null &&
          completionPauseRevision != _playbackPauseRevision) {
        return;
      }
      if (navigation != null) _playlistManager?.prepareNavigation(navigation);
      await _playPlaylistItemLocked(
        item,
        autoPlay: autoPlay,
        startPosition: startPosition,
        forceFromStart: forceFromStart,
        userInitiatedWatch: userInitiatedWatch,
        directEpoch: epoch,
      );
    });
  }

  Future<void> _playPlaylistItemLocked(
    VideoItem item, {
    bool autoPlay = true,
    Duration? startPosition,
    bool forceFromStart = false,
    bool userInitiatedWatch = true,
    int? directEpoch,
  }) async {
    final epoch = directEpoch ?? _directEpoch;
    if (epoch != _directEpoch) return;
    // Freeze the episode that is actually playing. The save runs after the
    // switch has published the next item, so it must not read _currentItem.
    final frozenItem = _currentItem;
    final frozenPosition = _hasPlaybackCompleted ? Duration.zero : _position;
    if (frozenItem?.sourceRef?.podcast != null) {
      PodcastPlaybackHooks.syncedProgress?.call(
        frozenItem!,
        frozenPosition.inMilliseconds,
        null,
        DateTime.now().millisecondsSinceEpoch,
      );
    }
    unawaited(_saveFrozenProgress(frozenItem, frozenPosition));
    unawaited(_commitWatchFlush(_watchMeter.flush()));

    var frozenStartPosition = resolvePlayStartPosition(
      startPosition: startPosition,
      currentItemId: _currentItem?.id,
      itemId: item.id,
      currentPosition: _position,
      trackedProgress: _progressTracker?.getProgress(item.id),
      lastPositionMs: item.lastPositionMs,
    );
    final metadataDuration = Duration(
      milliseconds: item.durationMs > 0 ? item.durationMs : 0,
    );
    frozenStartPosition = PlaybackBehaviorPolicy.normalizeEpisodeStartPosition(
      savedPosition: frozenStartPosition,
      duration: metadataDuration,
      forceFromStart: forceFromStart,
    );

    // The queue cursor moves when play() anchors the opened item. Setting it
    // here as well marked a row "current" before the switch had committed.

    // 同一视频：复用控制器而非销毁重建（seekTo + play），避免 probe 开销
    // 仅当控制器不可复用时才走销毁路径
    if (_currentItem?.id == item.id && _controller != null) {
      clearSubtitleState();
      _seekPersistTimer?.cancel();
      _seekPersistTimer = null;
      if (!_controllerIsReusableForItem(item)) {
        unawaited(_disposeController());
        _lastControllerIsPlaying = null;
      }
      // 可复用时由 play() 走 _controllerIsReusableForItem 复用路径
    }

    final int maxAttempts = _mediaSwitchMaxAttempts;
    var attemptAutoPlay = autoPlay;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (epoch != _directEpoch) return;
      await play(
        item,
        autoPlay: attemptAutoPlay,
        startPosition: frozenStartPosition,
        forceRecreate: attempt > 1,
        userInitiatedWatch: userInitiatedWatch,
        directEpoch: epoch,
      );
      if (epoch != _directEpoch) return;
      if (_isControllerReadyForItem(item) ||
          _isSourceMissing ||
          _currentItem?.id != item.id) {
        return;
      }
      if (attempt >= maxAttempts) return;
      if (!kIsWeb &&
          Platform.isAndroid &&
          item.type == MediaType.audio &&
          item.sourceRef?.kind != MediaSourceKind.bilibiliStream) {
        // The codec probe handles known formats before the first controller is
        // created. This failure-driven promotion covers device-specific gaps
        // and unusual containers: retry the exact same queue item through
        // media_kit without introducing a second playback/session state.
        LocalPlaybackBackendPolicy.preferWideCodecBackend(item.path);
      }
      _logPlaybackEvent(
        'media switch attempt failed; retrying',
        data: <String, Object?>{
          'itemId': item.id,
          'attempt': attempt,
          'resumeMs': frozenStartPosition.inMilliseconds,
        },
      );
      final previousStartup = _onlineStartup;
      final retryDelay = Duration(milliseconds: attempt == 1 ? 300 : 900);
      if (previousStartup != null) {
        final reason = previousStartup.failure ?? '';
        if (previousStartup.isCancelled ||
            previousStartup.remaining <= retryDelay ||
            reason.startsWith('当前账号') ||
            reason.startsWith('当前视频')) {
          return;
        }
      }
      await Future<void>.delayed(retryDelay);
      if (epoch != _directEpoch || _currentItem?.id != item.id) return;
      if (previousStartup != null) {
        if (!identical(_onlineStartup, previousStartup)) return;
        attemptAutoPlay = previousStartup.desiredPlaying;
        final continuation = previousStartup.continueOnNewNetwork();
        if (continuation is BilibiliStartupContext) {
          prepareBilibiliStartup(item.id, continuation);
        } else {
          _pendingOnlineStartup = (itemId: item.id, context: continuation);
        }
      }
    }
  }

  int _binarySearchFirstStartGT(int posMs) {
    return _subtitleTimeline.firstStartAfterMs(posMs);
  }

  int _findCurrentSubtitleIndexByPositionMs(int posMs) {
    return _subtitleTimeline.indexAtMs(posMs);
  }

  void handleExternalDoubleTapSeek({
    required bool isLeft,
    required int doubleTapSeekSeconds,
    required bool enableDoubleTapSubtitleSeek,
    required Duration subtitleOffset,
    String source = 'external_double_tap',
  }) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (_state == PlaybackState.idle || _state == PlaybackState.error) return;

    final currentPos = _position;
    final duration = _duration > Duration.zero
        ? _duration
        : controller.value.duration;
    Duration target = Duration.zero;
    final bool hasActiveSeekWindow = _externalSeekResetTimer?.isActive ?? false;

    if (hasActiveSeekWindow) {
      _externalSeekResetTimer?.cancel();
    } else {
      _externalSubtitleSeekAccumulator = 0;
      _externalInitialSeekPosition =
          enableDoubleTapSubtitleSeek && _subtitles.isNotEmpty
          ? currentPos - subtitleOffset
          : currentPos;
    }

    if (isLeft) {
      _externalSubtitleSeekAccumulator--;
    } else {
      _externalSubtitleSeekAccumulator++;
    }

    if (enableDoubleTapSubtitleSeek && _subtitles.isNotEmpty) {
      final int initialPosMs = _externalInitialSeekPosition!.inMilliseconds;
      int nextSubIndex = _binarySearchFirstStartGT(initialPosMs);
      if (nextSubIndex < 0) nextSubIndex = 0;
      if (nextSubIndex > _subtitles.length) nextSubIndex = _subtitles.length;

      final int currentSubIndex = _findCurrentSubtitleIndexByPositionMs(
        initialPosMs,
      );
      int pivotIndex;
      bool isAtStartOfSub = false;

      if (currentSubIndex != -1) {
        pivotIndex = currentSubIndex;
        if (initialPosMs <
            _subtitles[currentSubIndex].startTime.inMilliseconds + 500) {
          isAtStartOfSub = true;
        }
      } else {
        pivotIndex = nextSubIndex - 1;
      }

      int targetIndex;
      if (_externalSubtitleSeekAccumulator < 0) {
        int jumps = _externalSubtitleSeekAccumulator.abs();
        if (currentSubIndex != -1 && !isAtStartOfSub) {
          jumps--;
          targetIndex = currentSubIndex;
        } else {
          targetIndex = pivotIndex;
        }
        targetIndex -= jumps;
      } else {
        targetIndex = pivotIndex + _externalSubtitleSeekAccumulator;
      }

      if (targetIndex < 0) {
        target = Duration.zero;
      } else if (targetIndex >= _subtitles.length) {
        target = duration;
      } else {
        target = _subtitles[targetIndex].startTime + subtitleOffset;
      }
    } else {
      final initialPosition = _externalInitialSeekPosition ?? currentPos;
      target =
          initialPosition +
          Duration(
            seconds: doubleTapSeekSeconds * _externalSubtitleSeekAccumulator,
          );
    }

    if (target < Duration.zero) target = Duration.zero;
    if (target > duration) target = duration;
    _externalSeekResetTimer = Timer(const Duration(milliseconds: 2000), () {
      _externalSubtitleSeekAccumulator = 0;
      _externalInitialSeekPosition = null;
    });
    unawaited(seekTo(target, source: source));
  }

  /// 控制器更新监听器（用于处理播放状态变化）
  void _onControllerUpdate() {
    final controller = _controller;
    if (controller == null) return;
    if (_usesNativePodcastTimeline &&
        !identical(_sessionController, controller)) {
      return;
    }
    if (!controller.value.isInitialized) {
      if (controller.value.hasError) {
        _scheduleErroredControllerRecovery(controller);
      }
      return;
    }

    // 这个监听器主要用于处理播放状态变化（如播放完成、错误等）
    // 位置更新由 _positionUpdateTimer 定时器处理，避免过度通知

    // 检查播放完成
    final position = _controller!.value.position;
    final controllerIsPlaying = _controller!.value.isPlaying;
    final controllerIsBuffering = _controller!.value.isBuffering;
    if (controllerIsBuffering != _controllerIsBuffering) {
      _controllerIsBuffering = controllerIsBuffering;
      // Freeze on the last presented frame and suspend its ticker. A stopped
      // ticker cannot observe bufferingEnd itself, so both edges act here.
      // Native-led podcasts still require confirmed audio progress.
      _setPlaybackTimelineRunning(_shouldTimelineRun());
      if (isCurrentItemStreamingBilibiliCard) {
        _syncBilibiliGatewaySpeed(notify: false);
      }
      // Podcast transport chrome observes buffering edges, including stalls
      // where the position clock never advances enough to publish an update.
      if (isCurrentItemStreamingBilibiliCard ||
          _currentItem?.sourceRef?.podcast != null) {
        notifyListeners();
      }
    }
    _syncSeekHoldOverlayFromNative(position);
    final wasControllerPlaying =
        _lastControllerIsPlaying ?? controllerIsPlaying;
    final controllerPlaybackSpeed = _controller!.value.playbackSpeed;
    final playbackSpeedChanged =
        _pendingPlaybackSpeed == null &&
        (_playbackSpeed - controllerPlaybackSpeed).abs() >= 0.001;
    if (playbackSpeedChanged) {
      _playbackSpeed = controllerPlaybackSpeed;
      _confirmedPlaybackSpeed = controllerPlaybackSpeed;
      if (_timelineClock.isInitialized) {
        _timelineClock.setRate(controllerPlaybackSpeed);
      }
    }
    final bufferedPosition = _readBufferedPosition(_controller!);
    if (!_controllerVolumeMatchesDesired(_controller!)) {
      unawaited(
        _applyMuteStateToController(reason: 'controller drift detected'),
      );
    }
    if (bufferedPosition != _bufferedPosition) {
      _bufferedPosition = bufferedPosition;
    }

    if (_initialPositionSeekInFlight) return;

    // seek 期间 native controller 可能先发出 isPlaying=false，完成后再恢复。
    // 不记录这个过渡状态，也不触发播放完成/暂停同步，避免按钮闪成三角形。
    if (controllerIsPlaying) {
      _preservePlayingStateAfterSeek = false;
    } else if (_pendingSeekRequestId != null ||
        _preservePlayingStateAfterSeek) {
      return;
    }

    // video_player pauses before its terminal seek updates the position.
    // Keep the explicit completion signal even if the service clock or play
    // state has already stopped; the delayed confirmation still checks EOF.
    if (!_hasPlaybackCompleted &&
        (controller.value.isCompleted ||
            _hasReachedPlaybackEnd(_position, _duration)) &&
        (controller.value.isCompleted ||
            wasControllerPlaying ||
            controllerIsPlaying ||
            _state == PlaybackState.playing)) {
      _onPlaybackCompleted();
    }

    if (_lastControllerIsPlaying != controllerIsPlaying) {
      _lastControllerIsPlaying = controllerIsPlaying;
      _logPlaybackEvent(
        'controller play state changed',
        data: <String, Object?>{
          'isPlaying': controllerIsPlaying,
          'positionMs': position.inMilliseconds,
        },
      );
      // During initial loading, play-state changes are expected before the
      // first frame readiness check completes. Keep the public session state
      // as loading; the play request will commit playing (or error) after that
      // check. The controller itself has already been published for mounting.
      if (_state != PlaybackState.loading) {
        updatePlaybackStateFromController();
      }
    } else if (playbackSpeedChanged) {
      notifyListeners();
    }
    if (_usesNativePodcastTimeline &&
        _nativePositionSubscription == null &&
        _pendingSeekRequestId == null &&
        !_shouldIgnoreInitialPositionSample(position) &&
        !_syncAwaitingTransportClock(controller, position)) {
      _observeNativeTimelinePosition(position);
    }
    // A seek can be acknowledged while native playback is still paused. Its
    // later playing=true edge may match the pre-seek cached play state, so it
    // must also wake the suspended clock without waiting for a display frame.
    final shouldRun = _shouldTimelineRun();
    if (_timelineClock.isInitialized && _timelineClock.isRunning != shouldRun) {
      _setPlaybackTimelineRunning(shouldRun);
    }
  }

  void _scheduleErroredControllerRecovery(VideoPlayerController controller) {
    if (_controllerErrorRecovery != null ||
        !identical(_controller, controller)) {
      return;
    }
    final item = _currentItem;
    if (item == null || _isSourceMissing) return;

    final resumePosition = _position;
    final shouldPlay = _state == PlaybackState.playing;
    final error = controller.value.errorDescription;
    if (!kIsWeb &&
        Platform.isAndroid &&
        item.type == MediaType.audio &&
        item.sourceRef?.kind != MediaSourceKind.bilibiliStream) {
      // Some device decoders initialize successfully and report the real
      // codec/container failure only after playback starts. Promote that path
      // before the unified recovery re-enters _playPlaylistItem.
      LocalPlaybackBackendPolicy.preferWideCodecBackend(item.path);
    }
    _logPlaybackEvent(
      'controller became erroneous; rebuilding playback session',
      data: <String, Object?>{
        'itemId': item.id,
        'positionMs': resumePosition.inMilliseconds,
        'playing': shouldPlay,
        'error': error,
      },
    );

    late final Future<void> recovery;
    recovery =
        () async {
              if (!identical(_controller, controller) ||
                  _currentItem?.id != item.id) {
                return;
              }
              await _playPlaylistItem(
                item,
                autoPlay: shouldPlay,
                startPosition: resumePosition,
                userInitiatedWatch: false,
              );
            }()
            .catchError((Object recoveryError, StackTrace stackTrace) {
              _logPlaybackEvent(
                'errored controller recovery failed',
                data: <String, Object?>{
                  'itemId': item.id,
                  'error': recoveryError.toString(),
                },
              );
            })
            .whenComplete(() {
              if (identical(_controllerErrorRecovery, recovery)) {
                _controllerErrorRecovery = null;
              }
            });
    _controllerErrorRecovery = recovery;
  }

  Future<List<SubtitleItem>> _parseSubtitleFile(String path) async {
    // In-progress SRT files contain sentences only; their word timings live in
    // the stream snapshot until the final companion is written. Reuse that
    // snapshot for automatic refreshes as well as explicit track selections.
    final stream = _subtitleStreamManager?.streamForPath(path);
    if (stream != null && !stream.complete) {
      return path == stream.primaryPath ? stream.primary : stream.secondary;
    }

    try {
      final file = File(path);
      if (!await file.exists()) return [];

      final length = await file.length();
      if (length > 100 * 1024 * 1024) {
        debugPrint("Subtitle file too large ($length bytes), skipping: $path");
        return [];
      }

      // Version the cache so an update cannot reuse a pre-normalization
      // in-memory result for this subtitle path.
      final sourceStat = await file.stat();
      final boundAsset = _currentItem?.managedSubtitleAssets
          .where((asset) => asset.path == path)
          .firstOrNull;
      final companionPath =
          boundAsset?.wordTimingPath ?? SubtitleWordTimingStore.pathFor(path);
      final companionStat = await File(companionPath).stat();
      final String cacheKey = [
        path,
        'timeline_v3',
        duration.inMilliseconds,
        sourceStat.modified.microsecondsSinceEpoch,
        sourceStat.size,
        companionPath,
        companionStat.modified.microsecondsSinceEpoch,
        companionStat.size,
      ].join('::');
      final cached = _subtitleCache.remove(cacheKey);
      if (cached != null) {
        _subtitleCache[cacheKey] = cached;
        return cached;
      }
      final running = _subtitleParses[cacheKey];
      if (running != null) return await running;
      final parse = _parseSubtitleFileContents(
        path,
        companionPath,
        companionStat,
        duration.inMilliseconds,
      );
      _subtitleParses[cacheKey] = parse;
      try {
        final parsed = await parse;
        _subtitleCache.removeWhere(
          (key, _) => key.startsWith('$path::timeline_v3::'),
        );
        _subtitleCache[cacheKey] = parsed;
        // Retain recent episodes without letting long transcripts grow forever.
        while (_subtitleCache.length > 8 ||
            _subtitleCache.values.fold<int>(
                  0,
                  (sum, cues) => sum + cues.length,
                ) >
                24000) {
          _subtitleCache.remove(_subtitleCache.keys.first);
        }
        return parsed;
      } finally {
        if (identical(_subtitleParses[cacheKey], parse)) {
          _subtitleParses.remove(cacheKey);
        }
      }
    } catch (e) {
      developer.log('Load sub error', error: e);
      return [];
    }
  }

  Future<List<SubtitleItem>> _parseSubtitleFileContents(
    String path,
    String companionPath,
    FileStat companionStat,
    int durationMs,
  ) async {
    final file = File(path);
    final ext = path.toLowerCase();
    List<SubtitleItem> parsed = [];

    if (ext.endsWith('.sup')) {
      parsed = await PgsParser.parse(path);
    } else if (ext.endsWith('.idx')) {
      final converted = await SubtitleConverter.convert(
        inputPath: path,
        targetExtension: '.sup',
      );
      if (converted != null) parsed = await PgsParser.parse(converted);
    } else if (ext.endsWith('.scc')) {
      final converted = await SubtitleConverter.convert(
        inputPath: path,
        targetExtension: '.srt',
      );
      if (converted != null) return _parseSubtitleFile(converted);
    } else if (ext.endsWith('.sub')) {
      if (await SubtitleConverter.isMicroDvdSub(path)) {
        final converted = await SubtitleConverter.convert(
          inputPath: path,
          targetExtension: '.srt',
        );
        if (converted != null) return _parseSubtitleFile(converted);
      } else {
        final converted = await SubtitleConverter.convert(
          inputPath: path,
          targetExtension: '.sup',
        );
        if (converted != null) parsed = await PgsParser.parse(converted);
      }
    } else {
      List<int> bytes = await file.readAsBytes();
      if (bytes.isNotEmpty) {
        String? companion;
        if (companionStat.type == FileSystemEntityType.file &&
            companionStat.size <= 100 * 1024 * 1024) {
          try {
            companion = await File(companionPath).readAsString();
          } catch (_) {}
        }
        final serialized = await compute(
          _parseTextSubtitlesToSerializable,
          <String, Object?>{
            'bytes': bytes,
            'path': path,
            'durationMs': durationMs,
            'companion': companion,
          },
        );
        parsed = serialized.map((m) => SubtitleItem.fromTimingJson(m)).toList();
      }
    }

    if (parsed.isNotEmpty) {
      parsed.sort((a, b) => a.startTime.compareTo(b.startTime));
      if (YouTubeAutoCaptionNormalizer.shouldNormalize(parsed)) {
        parsed = YouTubeAutoCaptionNormalizer.normalize(parsed);
      }
    }
    return parsed;
  }

  /* Legacy source/path gate retained only as historical context:
  bool _shouldNormalizeYouTubeAutoCaptions(String subtitlePath) {
    final currentItem = _currentItem;
    if (currentItem == null) {
      return false;
    }
    final sourceRef = currentItem.sourceRef;
    final sourceValue = (sourceRef?.originalValue ?? sourceRef?.value ?? '')
        .toLowerCase();
    final bool isYouTubeSource =
        sourceValue.contains('youtube.com') || sourceValue.contains('youtu.be');
    if (!isYouTubeSource ||
        !currentItem.usesManagedAssociatedSubtitles ||
        currentItem.isBilibiliExported) {
      return false;
    }

    final baseName = p.basename(p.normalize(subtitlePath)).toLowerCase();
    return baseName.contains('auto') ||
        baseName.contains('asr') ||
        baseName.contains('caption') ||
        baseName.contains('srv') ||
        baseName.contains('自动') ||
        baseName.contains('.translated.');
  }
  */

  /// 更新当前字幕（支持连续字幕）
  bool _updateCurrentSubtitle() {
    if (_subtitles.isEmpty) {
      final changed = _currentSubtitle != null || _lastSubtitleIndex != -1;
      if (_currentSubtitle != null) {
        _currentSubtitle = null;
      }
      _lastSubtitleIndex = -1;
      return changed;
    }

    final int foundIndex = _subtitleTimeline.indexAtMs(
      _position.inMilliseconds,
      preferredIndex: _lastSubtitleIndex,
    );
    final SubtitleItem? foundSubtitle = foundIndex >= 0
        ? _subtitles[foundIndex]
        : null;
    _lastSubtitleIndex = foundIndex;

    if (_currentSubtitle != foundSubtitle) {
      _currentSubtitle = foundSubtitle;
      return true;
    }
    return false;
  }

  /// 播放完成处理
  void _onPlaybackCompleted() {
    if (_hasPlaybackCompleted) return;
    final pending = _playbackCompletion;
    if (pending != null && _isCurrentPlaybackCompletion(pending)) return;
    final completedItem = _currentItem;
    final completedController = _controller;
    if (completedItem == null ||
        completedController == null ||
        !completedController.value.isInitialized) {
      return;
    }
    final completion = _PlaybackCompletion(
      item: completedItem,
      controller: completedController,
      playRequestId: _playRequestId,
      seekRequestId: _seekRequestId,
      directEpoch: _directEpoch,
    );
    _playbackCompletion = completion;
    unawaited(_handlePlaybackCompleted(completion));
  }

  bool _isCurrentPlaybackCompletion(_PlaybackCompletion completion) =>
      identical(_playbackCompletion, completion) &&
      completion.playRequestId == _playRequestId &&
      completion.seekRequestId == _seekRequestId &&
      completion.directEpoch == _directEpoch &&
      _currentItem?.id == completion.item.id &&
      identical(_controller, completion.controller) &&
      completion.controller.value.isInitialized;

  Future<void> _handlePlaybackCompleted(_PlaybackCompletion completion) async {
    final completedItem = completion.item;
    final completedController = completion.controller;
    final pauseRevision = _playbackPauseRevision;
    bool isCurrent() => _isCurrentPlaybackCompletion(completion);
    try {
      await Future<void>.delayed(_playbackCompletionConfirmationDelay);
      if (!isCurrent()) return;
      if (pauseRevision != _playbackPauseRevision) return;

      final confirmedPosition = completedController.value.position;
      final confirmedDuration = completedController.value.duration;
      if (!PlaybackBehaviorPolicy.isConfirmedPlaybackCompletion(
        servicePosition: _position,
        serviceDuration: _duration,
        nativePosition: confirmedPosition,
        nativeDuration: confirmedDuration,
        nativePlaying: completedController.value.isPlaying,
        isOnlineBilibiliStream:
            completedItem.sourceRef?.kind == MediaSourceKind.bilibiliStream,
        isOnlineCloudDrive: isCloudDriveMedia(
          source: completedItem.sourceRef,
          path: completedItem.path,
        ),
      )) {
        _logPlaybackEvent(
          'ignored unconfirmed playback completion',
          data: <String, Object?>{
            'itemId': completedItem.id,
            'positionMs': confirmedPosition.inMilliseconds,
            'durationMs': confirmedDuration.inMilliseconds,
            'isPlaying': completedController.value.isPlaying,
          },
        );
        return;
      }

      // Bind both history and the restart bookmark to this completed item.
      // Neither write may read the next selection after asynchronous storage
      // or a cloud directory request has yielded.
      _hasPlaybackCompleted = true;
      _preservePlayingStateAfterSeek = false;
      _stopProgressTracking();
      final watchFlush = _watchMeter.onConfirmedComplete();
      if (completedItem.sourceRef?.podcast != null) {
        PodcastPlaybackHooks.completed?.call(completedItem);
      }
      await Future.wait<void>([
        _commitWatchFlush(watchFlush),
        _saveFrozenProgress(completedItem, Duration.zero),
      ]);
      if (!isCurrent()) return;

      // Timers that stop at this item need no remote queue at all. In
      // particular, a stalled directory must not delay an end-of-item stop.
      final timerStopsHere =
          sleepTimer.mode == SleepTimerMode.endOfCurrentItem ||
          (sleepTimer.mode == SleepTimerMode.afterItemCount &&
              !sleepTimer.awaitingCurrentItemEnd &&
              sleepTimer.remainingItemCount <= 1);
      if (timerStopsHere &&
          sleepTimer.consumeItemCompletion(hasNextItem: false)) {
        if (isCurrent()) await _parkCompletedPlayback(completedController);
        return;
      }

      final settings = SettingsService();
      bool autoAdvanceEnabled() => completedItem.sourceRef?.podcast != null
          ? PodcastPlaybackHooks.continuous?.call(completedItem) ?? false
          : settings.autoPlayOnCompletion;
      // Repeat the initialized controller through the same guarded switch
      // path. Do not enable native looping: EOF must still reach sleep timers.
      Future<bool> repeatCurrentIfSelected() async {
        if (playbackMode != PlaybackMode.repeatOne) return false;
        if (sleepTimer.consumeItemCompletion(hasNextItem: false) ||
            pauseRevision != _playbackPauseRevision) {
          if (isCurrent()) await _parkCompletedPlayback(completedController);
        } else if (isCurrent()) {
          await _playPlaylistItem(
            completedItem,
            autoPlay: true,
            forceFromStart: true,
            userInitiatedWatch: false,
            directEpoch: completion.directEpoch,
            completionPauseRevision: pauseRevision,
          );
        }
        return true;
      }

      if (await repeatCurrentIfSelected()) return;
      if (!autoAdvanceEnabled() && !sleepTimer.tracksItemCompletion) {
        await _parkCompletedPlayback(completedController);
        return;
      }

      final queueReady = await _prepareCloudQueue();
      if (!isCurrent()) return;
      if (pauseRevision != _playbackPauseRevision) return;
      if (!queueReady) {
        await _parkCompletedPlayback(completedController);
        return;
      }
      if (await repeatCurrentIfSelected()) return;
      _playlistManager?.revalidatePlaylist();

      // A paged cloud queue can have more media beyond the last loaded row.
      // Resolve that continuation before consuming an end-of-queue timer or
      // applying list wrap, just as manual next navigation does.
      final continuation = cloudDriveLoadNextPlaylistPage;
      if (completedItem.sourceRef?.cloudDrive != null &&
          continuation != null &&
          _playlistManager?.currentIndex != -1 &&
          _findPlayableRelative(next: true, wrap: false) == null) {
        try {
          await continuation();
        } catch (_) {
          if (!isCurrent()) return;
          cloudDriveNotice = '目录读取未完成，请重试上一集或下一集';
          await _parkCompletedPlayback(completedController);
          return;
        }
        if (!isCurrent()) return;
        _playlistManager?.revalidatePlaylist();
      }

      // Sleep timers take precedence over repeat/auto-play. Queue end means
      // the literal end after loading, even when list wrap is enabled.
      if (!isCurrent() || pauseRevision != _playbackPauseRevision) return;
      if (await repeatCurrentIfSelected()) return;
      final timerContinuesQueue = sleepTimer.tracksItemCompletion;
      final stopForSleepTimer = sleepTimer.consumeItemCompletion(
        hasNextItem: _findPlayableRelative(next: true, wrap: false) != null,
      );
      if (!isCurrent()) return;
      if (stopForSleepTimer) {
        await _parkCompletedPlayback(completedController);
        return;
      }

      final shouldAdvance = autoAdvanceEnabled() || timerContinuesQueue;
      if (!shouldAdvance) {
        await _parkCompletedPlayback(completedController);
        return;
      }

      final bool wrap = settings.playlistWrapToFirst;
      final navigation = _playlistManager?.planNavigation(
        [1],
        wrap: wrap,
        includeCurrentAfterWrap: wrap,
      );
      final targetItem = navigation?.item;
      if (targetItem == null) {
        // The queue ended before a count-based timer finished. Drop the
        // leftover timer and stay on this item instead of tearing the
        // session down (stop() disposed the player under the open page).
        if (timerContinuesQueue && sleepTimer.isActive) {
          await sleepTimer.cancel();
        }
        if (!isCurrent()) return;
        await _parkCompletedPlayback(completedController);
        return;
      }

      await _playPlaylistItem(
        targetItem,
        autoPlay: true,
        forceFromStart: settings.autoPlayOnCompletionFromStart,
        userInitiatedWatch: false,
        directEpoch: completion.directEpoch,
        navigation: navigation,
        completionPauseRevision: pauseRevision,
      );
    } finally {
      if (identical(_playbackCompletion, completion)) {
        _playbackCompletion = null;
      }
    }
  }

  /// Leave the finished item paused on its last frame, but persist a
  /// restart-at-zero position so the next launch does not reopen at EOF.
  Future<void> _parkCompletedPlayback(VideoPlayerController controller) async {
    final item = _currentItem;
    final requestId = _playRequestId;
    final seekRequestId = _seekRequestId;
    final directEpoch = _directEpoch;
    bool isCurrent() =>
        requestId == _playRequestId &&
        seekRequestId == _seekRequestId &&
        directEpoch == _directEpoch &&
        _currentItem?.id == item?.id &&
        identical(_controller, controller);
    if (item == null || !isCurrent()) return;
    _hasPlaybackCompleted = true;
    _state = PlaybackState.paused;
    _setDesiredPlaying(false);
    // The restart bookmark is persisted separately. Keep every live progress
    // surface at EOF until an explicit replay or seek.
    _position = _duration > Duration.zero
        ? _duration
        : controller.value.duration;
    _resetPlaybackTimeline(_position, running: false);
    _syncWakelockWithState();
    _stopProgressTracking();
    try {
      if (identical(_controller, controller) &&
          controller.value.isInitialized &&
          controller.value.isPlaying) {
        await controller.pause();
      }
    } catch (_) {}
    if (!isCurrent()) return;
    await _saveFrozenProgress(item, Duration.zero);
    if (!isCurrent()) return;
    await _savePlaybackStateSnapshot();
    if (isCurrent()) notifyListeners();
  }

  bool _hasReachedPlaybackEnd(Duration position, Duration duration) {
    return PlaybackBehaviorPolicy.hasReachedPlaybackEnd(
      position: position,
      duration: duration,
    );
  }

  /// 启动进度追踪定时器
  void _startProgressTracking() {
    _stopProgressPersistence();
    _stopRealtimeSyncLoop();

    // 每5秒保存一次进度
    _progressTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _sampleLibraryWatch(flush: true);
      _saveCurrentProgress(immediate: true);
      _savePlaybackStateSnapshot();
    });

    _startRealtimeSyncLoop();
  }

  /// 停止进度追踪定时器
  void _stopProgressTracking() {
    _stopProgressPersistence();
    _stopRealtimeSyncLoop();
  }

  void _startRealtimeSyncLoop() {
    _stopRealtimeSyncLoop();
    if (_state != PlaybackState.playing) return;
    if (_isAppInForeground) {
      _startPositionUpdates();
      return;
    }
    _backgroundMediaSyncTimer = Timer.periodic(_backgroundMediaSyncInterval, (
      _,
    ) {
      _updatePosition();
    });
  }

  void _stopRealtimeSyncLoop() {
    _stopPositionUpdates();
    _stopBackgroundMediaSync();
  }

  void _startPositionUpdates() {
    _stopPositionUpdates();
    if (!_isAppInForeground || _state != PlaybackState.playing) return;
    _positionUpdateTimer = Timer.periodic(const Duration(milliseconds: 300), (
      _,
    ) {
      _updatePosition();
    });
    _startInterpolationTicker();
  }

  void _stopPositionUpdates() {
    _positionUpdateTimer?.cancel();
    _positionUpdateTimer = null;
    _stopInterpolationTicker();
  }

  // ===== 插值时钟：每帧平滑推进 positionNotifier =====

  bool get _hasPresentationListeners =>
      _positionNotifier.hasActiveListeners ||
      _danmakuPosition.hasActiveListeners;

  void _onPresentationListenersChanged() {
    if (_presentationDisposed) return;
    if (!_hasPresentationListeners) {
      _stopInterpolationTicker();
      _timelineClock.useMonotonicTime();
    } else if (_interpolationTicker == null &&
        _isAppInForeground &&
        _state == PlaybackState.playing &&
        _positionUpdateTimer != null) {
      // A listener can be installed while a widget builds. Starting a ticker
      // schedules the first publication for the next frame, never inline.
      _startInterpolationTicker();
    }
  }

  void _startInterpolationTicker() {
    _stopInterpolationTicker();
    final speed = _effectiveInterpolationSpeed();
    if (!_timelineClock.isInitialized) {
      _resetPlaybackTimeline(
        _position,
        running: _shouldTimelineRun(),
        rate: speed,
      );
    } else {
      _timelineClock.setDuration(_duration);
      _timelineClock.setRate(speed);
      _timelineClock.setRunning(_shouldTimelineRun());
    }
    if (!_hasPresentationListeners) {
      _timelineClock.useMonotonicTime();
    }
    _syncInterpolationTicker();
  }

  /// Reconcile presentation work without resetting the clock or publishing
  /// synchronously: listeners can be attached during a widget build.
  void _syncInterpolationTicker() {
    if (_presentationDisposed ||
        !_hasPresentationListeners ||
        !_isAppInForeground ||
        _positionUpdateTimer == null ||
        !_timelineClock.isRunning ||
        !_shouldTimelineRun()) {
      _stopInterpolationTicker();
      return;
    }
    if (_interpolationTicker != null) return;
    _interpolationTicker = Ticker((_) {
      if (!_shouldTimelineRun()) {
        _setPlaybackTimelineRunning(false);
        return;
      }
      final currentSpeed = _effectiveInterpolationSpeed();
      if ((_timelineClock.rate - currentSpeed).abs() >= 0.001) {
        _timelineClock.setRate(currentSpeed);
      }
      final shouldRun = _shouldTimelineRun();
      if (_timelineClock.isRunning != shouldRun) {
        _timelineClock.setRunning(shouldRun);
      }
      // Never spread a missed frame over later frames. A frame presented two
      // VSync intervals later must sample the position two intervals later;
      // otherwise moving overlays slow down and then visibly catch up.
      // A new Ticker starts its own elapsed time at zero. The scheduler's
      // presentation timestamp stays continuous when a live controller is
      // re-adopted, so restarting tracking does not repeat the next frame.
      final timelinePosition = _timelineClock.sampleFrame(
        SchedulerBinding.instance.currentFrameTimeStamp,
      );
      _publishTimelinePosition(timelinePosition);
    });
    _interpolationTicker!.start();
  }

  double _effectiveInterpolationSpeed() {
    final nativeRate = _nativePresentationPlaybackSpeed;
    if (nativeRate != null && nativeRate.isFinite && nativeRate > 0) {
      return nativeRate;
    }
    return _confirmedPlaybackSpeed.isFinite && _confirmedPlaybackSpeed > 0
        ? _confirmedPlaybackSpeed
        : 1.0;
  }

  bool _shouldTimelineRun() {
    if (_onlineStartup?.isPending == true) {
      return false;
    }
    if (_seekHoldPending || _seekHoldOverlay || _transportTransitionPending) {
      return false;
    }
    // A playing flag can remain true while the native seek Future is pending.
    // Keep every source at the requested timestamp until that seek completes;
    // otherwise word highlighting advances once before audio has landed.
    if (_pendingSeekRequestId != null || _initialPositionSeekInFlight) {
      return false;
    }
    final controller = _controller;
    return _state == PlaybackState.playing &&
        controller != null &&
        controller.value.isInitialized &&
        controller.value.isPlaying &&
        !controller.value.isBuffering;
  }

  bool get _usesNativePodcastTimeline =>
      _currentItem?.sourceRef?.kind == MediaSourceKind.podcastEpisode;

  void _observeNativeTimelinePosition(Duration position) {
    // A native-led clock can re-anchor even while paused. Late EOF samples
    // must not move the completed presentation; replay/seek clears the flag.
    if (_hasPlaybackCompleted) return;
    _timelineClock.observeNativePosition(position);
    if (_usesNativePodcastTimeline) {
      final presentedPosition = _timelineClock.position;
      _publishTimelinePosition(presentedPosition);
    }
  }

  void _resetPlaybackTimeline(
    Duration position, {
    required bool running,
    double? rate,
    bool preserveDanmakuPosition = false,
  }) {
    running = running && _shouldTimelineRun();
    _timelineClock.reset(
      position,
      running: running,
      rate: rate ?? _effectiveInterpolationSpeed(),
      duration: _duration,
      // media_kit emits frequent time-pos samples. Leave room for slower
      // platform polling when that native stream is unavailable.
      maxNativeExtrapolation: _usesNativePodcastTimeline
          ? Duration(
              milliseconds: _nativePositionSubscription != null ? 250 : 600,
            )
          : null,
    );
    if (!_hasPresentationListeners) _timelineClock.useMonotonicTime();
    final timelinePosition = _timelineClock.position;
    if (preserveDanmakuPosition) {
      _danmakuPosition.reanchor(timelinePosition);
    } else {
      _danmakuPosition.reset(timelinePosition);
    }
    if (positionNotifier.value != timelinePosition) {
      positionNotifier.value = timelinePosition;
    }
    _setCoarsePosition(timelinePosition);
    _syncInterpolationTicker();
  }

  void _setPlaybackTimelineRunning(bool running) {
    running = running && _shouldTimelineRun();
    final speed = _effectiveInterpolationSpeed();
    if (!_timelineClock.isInitialized) {
      _resetPlaybackTimeline(_position, running: running, rate: speed);
      return;
    }
    _timelineClock.setDuration(_duration);
    _timelineClock.setRate(speed);
    _timelineClock.setRunning(running);
    final timelinePosition = _timelineClock.position;
    _publishTimelinePosition(timelinePosition);
    _setCoarsePosition(timelinePosition);
    _syncInterpolationTicker();
  }

  void _publishTimelinePosition(Duration timelinePosition) {
    _danmakuPosition.advance(timelinePosition, duration: _duration);
    if (positionNotifier.value != timelinePosition) {
      positionNotifier.value = timelinePosition;
    }
  }

  void _setCoarsePosition(Duration position) {
    if (coarsePositionNotifier.value != position) {
      coarsePositionNotifier.value = position;
    }
  }

  void _stopInterpolationTicker() {
    _interpolationTicker?.stop();
    _interpolationTicker?.dispose();
    _interpolationTicker = null;
  }

  void _stopBackgroundMediaSync() {
    _backgroundMediaSyncTimer?.cancel();
    _backgroundMediaSyncTimer = null;
  }

  void _stopProgressPersistence() {
    _progressTimer?.cancel();
    _progressTimer = null;
  }

  /// 更新播放位置（用于实时UI同步）
  void _updatePosition() {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (_state != PlaybackState.playing) return;

    // video_player can publish an optimistic seek target before mpv has
    // landed. Use actual time-pos for podcast subtitles and seek guards.
    final newPosition = _usesNativePodcastTimeline
        ? NativeVideoPlayerMediaKit.timePosFor(
                // ignore: invalid_use_of_visible_for_testing_member
                _controller!.playerId,
              ) ??
              _controller!.value.position
        : _controller!.value.position;
    final newDuration = _presentationDuration(_controller!.value.duration);
    final newBufferedPosition = _readBufferedPosition(_controller!);
    final durationChanged = newDuration != _duration;

    if (_shouldIgnoreInitialPositionSample(newPosition)) {
      _duration = newDuration;
      _bufferedPosition = newBufferedPosition;
      return;
    }

    // controller.seekTo 是异步的。播放状态下等待 native seek 完成期间，
    // controller 仍可能上报跳转前的位置；接受该样本会让进度条先到目标、
    // 再退回旧位置、最后再次到目标。此时保留上面的乐观目标位置即可。
    if (_pendingSeekRequestId != null) {
      return;
    }

    if (_usesNativePodcastTimeline && _nativePositionSubscription == null) {
      if (_syncAwaitingTransportClock(_controller!, newPosition)) return;
      _observeNativeTimelinePosition(newPosition);
    }

    if (_holdUnconfirmedBilibiliZero(_controller!, newPosition)) {
      _duration = newDuration;
      _bufferedPosition = newBufferedPosition;
      return;
    }

    if (!_hasPresentationListeners) {
      // Keep read-only progress snapshots current at the existing poll rate.
      // The music/video pages request VSync only while actually subscribed.
      _timelineClock.setDuration(newDuration);
      _timelineClock.setRate(_effectiveInterpolationSpeed());
      _timelineClock.setRunning(_shouldTimelineRun());
      _publishTimelinePosition(_timelineClock.position);
    }

    // 只有当位置或时长发生变化时才通知监听器
    if (newPosition != _position ||
        newDuration != _duration ||
        newBufferedPosition != _bufferedPosition) {
      _position = newPosition;
      _duration = newDuration;
      _bufferedPosition = newBufferedPosition;
      _setCoarsePosition(newPosition);

      // 更新插值基线（让插值时钟从真实位置继续平滑推进）
      // Native samples are often coarse or delayed, so they update metadata
      // only. Visible animation is re-anchored solely by an explicit seek,
      // media replacement, or real playback completion.
      _timelineClock.setDuration(_duration);

      if (_currentItem != null &&
          _progressTracker != null &&
          _duration > Duration.zero) {
        final durationMs = _duration.inMilliseconds;
        if (_currentItem!.durationMs == 0 ||
            _currentItem!.durationMs != durationMs) {
          _progressTracker!.saveDurationImmediately(
            _currentItem!.id,
            _duration,
          );
        }
      }

      if (durationChanged &&
          _currentItem != null &&
          _duration > Duration.zero) {
        // _lastPushedMediaDuration was removed
      }

      // 更新当前字幕
      final subtitleChanged = _updateCurrentSubtitle();

      // 检查是否播放结束
      if (_position >= _duration && _duration > Duration.zero) {
        _onPlaybackCompleted();
      }

      // 预加载下一个视频（进度达 80% 时触发一次）
      if (!_preloadTriggered &&
          _duration > Duration.zero &&
          _position.inMilliseconds >=
              (_duration.inMilliseconds * _preloadThreshold).toInt()) {
        _preloadTriggered = true;
        _maybePreloadNextVideo();
      }

      // Position and buffering change frequently. Progress-only consumers use
      // coarsePositionNotifier; rebuilding every provider consumer here was a
      // recurring source of animation-frame misses.
      if (durationChanged || subtitleChanged) {
        notifyListeners();
      }
    }
    _sampleLibraryWatch();
  }

  // _updateNotificationProgress 已移除，改用事件驱动

  /// Spotify/YouTube/Bilibili prefetch the adjacent episode's playurl so a
  /// notification skip is a player open, not an API round-trip.
  ///
  /// [replaceStale] drops warm sessions that are no longer neighbors. The
  /// call that runs before the current prepare() finishes must pass false:
  /// retaining then would release the session this switch is about to play.
  void _prefetchNeighborBilibiliStreams({bool replaceStale = true}) {
    // Retire any inherited warm handles; never request remote neighbors.
    _bilibiliStreamingService?.retainWarmPlaybacks({});
  }

  /// 预加载播放列表中的下一个视频控制器
  void _maybePreloadNextVideo() {
    // 低端设备可通过设置关闭预加载
    if (!SettingsService().enableVideoPreload) return;
    // Mobile decoder pools are commonly limited to one or two instances. A
    // speculative controller can block a background episode switch.
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) return;

    final nextCandidate = nextPlayableItem;
    if (nextCandidate == null || !communityMediaIsLocal(nextCandidate.path)) {
      return;
    }
    final nextItem = _communityPlaybackItem(nextCandidate);
    if (nextItem.sourceRef?.kind == MediaSourceKind.bilibiliStream) {
      // Online Bilibili is playurl + CDN TLS, not a second native Player.
      // A speculative Player would compete with the current stream for Range
      // bandwidth; warming playurl is the ExoPlayer / Bilibili pattern.
      final streaming = _bilibiliStreamingService;
      if (streaming != null) unawaited(streaming.prefetch(nextItem));
      return;
    }
    if (isCloudDriveMedia(source: nextItem.sourceRef, path: nextItem.path)) {
      return;
    }

    // 如果预加载的已经是目标 item，跳过
    if (_preloadedItemId == nextItem.id && _preloadedController != null) return;

    // 释放之前的预加载控制器
    unawaited(_disposePreloadedController());

    _preloadedItemId = nextItem.id;
    _preloadedRequestId = _playRequestId;

    final file = File(nextItem.path);
    unawaited(() async {
      if (!await file.exists()) return;
      // 竞态检查：播放请求已变化
      if (_preloadedRequestId != _playRequestId) return;
      // 当前播放项可能已变化
      if (_preloadedItemId != nextItem.id) return;

      VideoPlayerController? candidate;
      try {
        final playbackPath = _libraryService != null
            ? await _libraryService!.ensureCompatiblePlaybackFile(nextItem)
            : (await AudioPlaybackCompatibilityService.resolve(
                file,
                isAudio: nextItem.type == MediaType.audio,
                existingPlaybackPath: nextItem.playbackPath,
              )).path;
        final playbackFile = File(playbackPath);
        final controller = AppVideoPlayerController.file(
          playbackFile,
          videoPlayerOptions: buildVideoPlayerOptions(),
        );
        candidate = controller;
        await controller.initialize().timeout(_controllerInitializeTimeout);
        // 竞态检查：预加载期间用户可能已切换视频
        if (_preloadedItemId != nextItem.id ||
            _preloadedRequestId != _playRequestId) {
          unawaited(_disposeTrackedController(controller));
          return;
        }
        _preloadedController = controller;
        candidate = null;
        _logPlaybackEvent(
          'preload next video completed',
          data: {'itemId': nextItem.id},
        );
      } catch (e) {
        final failedCandidate = candidate;
        if (failedCandidate != null) {
          unawaited(_disposeTrackedController(failedCandidate));
        }
        _logPlaybackEvent(
          'preload next video failed',
          data: {'itemId': nextItem.id, 'error': e.toString()},
        );
      }
    }());
  }

  /// 释放预加载的控制器
  Future<void> _disposePreloadedController({
    bool awaitCompletion = false,
  }) async {
    final controller = _preloadedController;
    _preloadedController = null;
    _preloadedItemId = null;
    if (controller != null) {
      if (awaitCompletion) {
        await _disposeTrackedController(controller);
      } else {
        unawaited(_disposeTrackedController(controller));
      }
    }
  }

  /// 尝试使用预加载的控制器，返回 true 表示热替换成功
  bool _tryUsePreloadedController(VideoItem item) {
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      unawaited(_disposePreloadedController());
      return false;
    }
    if (_preloadedController == null || _preloadedItemId != item.id) {
      return false;
    }
    final controller = _preloadedController!;
    _preloadedController = null;
    _preloadedItemId = null;

    try {
      if (!controller.value.isInitialized) {
        unawaited(_disposeTrackedController(controller));
        return false;
      }
    } catch (_) {
      unawaited(_disposeTrackedController(controller));
      return false;
    }

    _controller = controller;
    _controllerItemId = item.id;
    _serviceOwnsController = true;
    _attachNativePositionStream(controller);
    _logPlaybackEvent(
      'hot-swapped preloaded controller',
      data: {'itemId': item.id},
    );
    return true;
  }

  void _prepareLibraryWatchCycle(
    VideoItem item, {
    required bool userInitiatedWatch,
  }) {
    final durationMs = item.durationMs > 0
        ? item.durationMs
        : (_duration.inMilliseconds > 0 ? _duration.inMilliseconds : null);
    if (_watchMeter.hasOpenCycle && _watchMeter.mediaId == item.id) {
      _watchMeter.setPolicy(SettingsService().continueWatchPolicy);
      _watchMeter.retainCycle(durationMs: durationMs);
      return;
    }
    unawaited(_commitWatchFlush(_watchMeter.flush()));
    final record = _libraryService?.mediaActivity(item.id);
    _watchHistoryStartCommitted = false;
    _watchMeter.setPolicy(SettingsService().continueWatchPolicy);
    _watchMeter.startCycle(
      mediaId: item.id,
      userInitiated: userInitiatedWatch,
      hidden: record?.hidden == true,
      completed: record?.completed == true,
      durationMs: durationMs,
    );
  }

  void _syncWatchMeterTransport() {
    _watchMeter.setTransport(
      playing: _state == PlaybackState.playing,
      buffering: _controllerIsBuffering,
      seeking: _pendingSeekRequestId != null || _initialPositionSeekInFlight,
      missingSource:
          _isSourceMissing ||
          _controller == null ||
          _state == PlaybackState.error,
    );
  }

  void _sampleLibraryWatch({bool flush = false}) {
    final itemId = _currentItem?.id;
    if (itemId == null || _watchMeter.mediaId != itemId) return;
    _watchMeter.setPolicy(SettingsService().continueWatchPolicy);
    _syncWatchMeterTransport();
    final crossed = _watchMeter.sample(
      mediaId: itemId,
      cycleId: _watchMeter.cycleId,
      positionMs: _position.inMilliseconds,
      durationMs: _duration.inMilliseconds,
    );
    if (flush ||
        crossed ||
        (!_watchHistoryStartCommitted && _watchMeter.hasStartedPlaying)) {
      final snapshot = _watchMeter.flush();
      if (snapshot.hasActivityWrite) {
        if (snapshot.lastPlayedAtMs != null) {
          _watchHistoryStartCommitted = true;
        }
        unawaited(_commitWatchFlush(snapshot));
      }
    }
  }

  Future<void> _commitWatchFlush(LibraryWatchFlush flush) async {
    final mediaId = flush.mediaId;
    final library = _libraryService;
    if (mediaId == null || library == null || !flush.hasActivityWrite) return;
    // Keep writes for the previous item after skip-next/mini-card changes
    // current media. Only drop a flush superseded by a newer cycle of the
    // same id (rewatch).
    final accepted = _acceptedWatchFlushCycle[mediaId] ?? 0;
    if (flush.cycleId < accepted) return;
    _acceptedWatchFlushCycle[mediaId] = flush.cycleId;
    await library.applyWatchFlush(
      mediaId: mediaId,
      deltaWatchMs: flush.deltaWatchMs,
      lastPlayedAtMs: flush.lastPlayedAtMs,
      enrolled: flush.enrolled,
      uncomplete: flush.uncomplete,
      unhide: flush.unhide,
      completed: flush.completed,
      completedAtMs: flush.completed ? flush.lastPlayedAtMs : null,
    );
  }

  /// 保存当前播放进度
  /// Persists the authoritative playback position for lifecycle and route
  /// transitions. Playback pages must use this instead of reading the native
  /// controller directly; the latter can briefly report zero during an online
  /// stream's initial probe.
  Future<void> persistCurrentProgress({
    String? expectedItemId,
    VideoPlayerController? expectedController,
  }) async {
    if (expectedItemId != null && _currentItem?.id != expectedItemId) return;
    if (expectedController != null &&
        !identical(_controller, expectedController)) {
      return;
    }
    final item = _currentItem;
    if (item == null) return;
    final itemId = item.id;
    final position = _hasPlaybackCompleted ? Duration.zero : _position;
    _rememberUnimportedCloudProgress(item, position);
    final progressTracker = _progressTracker;
    if (progressTracker == null) {
      await _libraryService?.updateVideoProgress(
        itemId,
        position.inMilliseconds,
      );
      await _commitWatchFlush(_watchMeter.flush());
      return;
    }
    await progressTracker.saveProgressImmediately(itemId, position);
    if (_currentItem?.id != itemId ||
        (expectedController != null &&
            !identical(_controller, expectedController))) {
      return;
    }
    await _savePlaybackStateSnapshot();
    await _commitWatchFlush(_watchMeter.flush());
  }

  void _rememberUnimportedCloudProgress(VideoItem item, Duration position) {
    if (item.sourceRef?.cloudDrive != null &&
        _libraryService?.getVideo(item.id) == null) {
      // Keep resume working within this queue without creating a library card.
      item.lastPositionMs = position.inMilliseconds;
    }
  }

  Future<void> _saveFrozenProgress(VideoItem? item, Duration position) async {
    if (item == null) return;
    _rememberUnimportedCloudProgress(item, position);
    if (_progressTracker == null) return;
    await _progressTracker!.saveProgressImmediately(item.id, position);
  }

  Future<void> _saveCurrentProgress({bool immediate = false}) async {
    if (_currentItem == null) return;
    final position = _hasPlaybackCompleted ? Duration.zero : _position;
    _rememberUnimportedCloudProgress(_currentItem!, position);
    if (_progressTracker == null) return;

    if (immediate) {
      await _progressTracker!.saveProgressImmediately(
        _currentItem!.id,
        position,
      );
    } else {
      await _progressTracker!.saveProgress(_currentItem!.id, position);
    }
  }

  /// 释放控制器
  ///
  /// 非阻塞释放：同步移除 listener + 摘除引用，pause 与 dispose 在后台执行，
  /// 不阻塞 play() 后续流程。仅在 service.dispose() 时需要等待完成。
  Future<void> _disposeController({bool awaitCompletion = false}) async {
    _detachCloudLease?.call();
    _detachCloudLease = null;
    _cancelVisibleOutputRecovery();
    _bilibiliVideoTrackPolicyFuture = null;
    final controller = _controller;
    final materializedLease = _currentMaterializedPlaybackLease;
    final bilibiliPlayback = _currentBilibiliPlayback;
    final cloudLease = _currentCloudDriveLease;
    _currentMaterializedPlaybackLease = null;
    _currentBilibiliPlayback = null;
    _currentCloudDriveLease = null;
    _cloudDriveQualities = const [];
    _selectedCloudDriveQualityId = null;
    _bilibiliAudioPrimaryPlayer = false;
    _requestedBilibiliVideoTrackEnabled = null;
    _bilibiliVideoTrackPolicyRevision++;
    // Drop the previous episode's CDN sockets before native dispose. Waiting
    // for libmpv to tear down left those downloads holding the connection
    // pool, so the next episode's first Range sat behind them.
    final gatewayRelease = bilibiliPlayback == null
        ? (cloudLease?.release() ?? Future<void>.value())
        : (_bilibiliStreamingService?.releasePlayback(bilibiliPlayback) ??
              Future<void>.value());
    if (controller != null) {
      _invalidatePlaybackSpeedCommands();
      _logPlaybackEvent(
        'disposing controller',
        data: <String, Object?>{
          'itemId': _currentItem?.id,
          'positionMs': _position.inMilliseconds,
        },
      );
      final bool shouldDisposeController = _serviceOwnsController;
      _detachNativePositionStream(controller);
      _controller = null;
      _controllerItemId = null;
      _serviceOwnsController = false;
      // Let mounted player pages detach VideoPlayer before the native dispose
      // finishes. Otherwise Release paints a white ErrorWidget on a disposed
      // controller (seen after sleep-timer end + re-open).
      notifyListeners();

      if (awaitCompletion) {
        await _detachController(
          controller,
          disposeController: shouldDisposeController,
          pauseIfPlaying: true,
        );
        await gatewayRelease;
        await _releasePlaybackResources(
          materializedLease: materializedLease,
          bilibiliPlayback: bilibiliPlayback,
        );
      } else {
        unawaited(gatewayRelease);
        // play() 路径：非阻塞释放，不等待 pause/dispose 完成
        // listener 移除是同步的，防止后台 dispose 触发回调
        try {
          controller.removeListener(_onControllerUpdate);
        } catch (_) {}
        // pause fire-and-forget：native 层立即生效，不等待 platform channel 确认
        if (shouldDisposeController) {
          try {
            if (controller.value.isInitialized && controller.value.isPlaying) {
              unawaited(controller.pause());
            }
          } catch (_) {}
          // dispose 后台执行，不阻塞新控制器初始化
          // 通过 _disposingControllers 追踪，防止泄漏
          _disposingControllers.add(controller);
          final release = _disposeTrackedController(controller).whenComplete(
            () {
              _disposingControllers.remove(controller);
              unawaited(
                _releasePlaybackResources(
                  materializedLease: materializedLease,
                  bilibiliPlayback: bilibiliPlayback,
                ),
              );
            },
          );
          unawaited(release);
          // 超过上限时，日志告警（所有控制器已在后台 dispose 中，无需额外操作）
          if (_disposingControllers.length > _maxDisposingControllers) {
            _logPlaybackEvent(
              'disposing controllers exceeded limit',
              data: {'count': _disposingControllers.length},
            );
          }
        } else {
          // 非自有控制器：仅 pause（如果需要），不 dispose
          try {
            if (controller.value.isInitialized && controller.value.isPlaying) {
              unawaited(controller.pause());
            }
          } catch (_) {}
          await _releasePlaybackResources(
            materializedLease: materializedLease,
            bilibiliPlayback: bilibiliPlayback,
          );
        }
      }
    } else {
      await gatewayRelease;
      await _releasePlaybackResources(
        materializedLease: materializedLease,
        bilibiliPlayback: bilibiliPlayback,
      );
    }
  }

  Future<void> _releasePlaybackResources({
    MaterializedMediaLease? materializedLease,
    BilibiliPreparedPlayback? bilibiliPlayback,
  }) async {
    await materializedLease?.release();
    if (bilibiliPlayback != null) {
      await _bilibiliStreamingService?.releasePlayback(bilibiliPlayback);
    }
  }

  @override
  void dispose() {
    _activeOpenBudget?.cancel();
    _activeOpenBudget = null;
    _presentationDisposed = true;
    _onlineStartup?.cancel();
    _bilibiliVisibleStartup?.cancel();
    _pendingOnlineStartup?.context.cancel();
    _pendingBilibiliStartup?.context.cancel();
    _playRequestId++;
    _supersedeDirectSwitch();
    _subtitleAppendTimer?.cancel();
    _subtitleAppendTimer = null;
    _pendingSubtitleAppend = null;
    unawaited(_subtitleStreamSubscription?.cancel());
    unawaited(_subtitleStartSubscription?.cancel());
    if (identical(
      _subtitleStreamManager?.shouldSelectGeneratedSubtitles,
      _streamSelectionPolicy,
    )) {
      _subtitleStreamManager?.shouldSelectGeneratedSubtitles = null;
    }
    _subtitleLoadRequestId++;
    _isLoadingSubtitles = false;
    _subtitleCache.clear();
    _networkRecoveryGeneration++;
    unawaited(_networkSubscription?.cancel());
    unawaited(persistCurrentProgress());
    _detachSettingsListener();
    _playlistManager?.removeListener(_onPlaybackQueueChanged);
    _playbackPageOwners.clear();
    _miniPlaybackCardOwners.clear();
    _mediaNotificationVisible = false;
    _syncBilibiliCachePolicy();
    _seekPersistTimer?.cancel();
    _seekPersistTimer = null;
    _cancelHopSeekDispatch();
    _seekVerificationTimer?.cancel();
    _seekVerificationTimer = null;
    _stopBackgroundMediaSync();
    _stopProgressTracking();
    _cancelNativePositionStream();
    unawaited(_disposeController(awaitCompletion: true));
    unawaited(_disposePreloadedController());
    // 等待所有后台 dispose 完成
    for (final c in _disposingControllers) {
      unawaited(_disposeTrackedController(c));
    }
    _disposingControllers.clear();
    AppWakelockCoordinator.setActive(
      AppWakelockCoordinator.mediaPlaybackReason,
      false,
    );
    sleepTimer.dispose();
    super.dispose();
  }

  Duration _readBufferedPosition(VideoPlayerController controller) {
    final ranges = controller.value.buffered;
    if (ranges.isEmpty) return Duration.zero;
    Duration maxEnd = Duration.zero;
    for (final range in ranges) {
      if (range.end > maxEnd) {
        maxEnd = range.end;
      }
    }
    return maxEnd;
  }

  /// 保存播放状态快照
  Future<void> _savePlaybackStateSnapshot() async {
    if (_progressTracker == null) return;

    try {
      final snapshot = PlaybackStateSnapshot(
        currentItemId: _currentItem?.id,
        positionMs: _hasPlaybackCompleted ? 0 : _position.inMilliseconds,
        wasPlaying: !_hasPlaybackCompleted && _state == PlaybackState.playing,
        playlistFolderId: _currentItem?.parentId,
      );

      await _progressTracker!.savePlaybackState(snapshot);
    } catch (e) {
      debugPrint('MediaPlaybackService: 保存播放状态快照失败 $e');
    }
  }

  void _scheduleSeekVerification({
    required Duration expectedPosition,
    required String source,
    required VideoPlayerController controller,
    required String itemId,
    required int requestId,
  }) {
    _seekVerificationTimer?.cancel();
    _seekVerificationTimer = Timer(_controllerSeekVerificationDelay, () {
      unawaited(
        _verifySeekResult(
          expectedPosition: expectedPosition,
          source: source,
          controller: controller,
          itemId: itemId,
          requestId: requestId,
          retryOnDrift: true,
        ).then((confirmed) {
          if (confirmed ||
              requestId != _seekRequestId ||
              !_isCurrentControllerSession(controller, itemId)) {
            return;
          }
          _seekVerificationTimer = Timer(
            _controllerSeekVerificationFollowUpDelay,
            () => unawaited(
              _verifySeekResult(
                expectedPosition: expectedPosition,
                source: source,
                controller: controller,
                itemId: itemId,
                requestId: requestId,
                retryOnDrift: false,
              ),
            ),
          );
        }),
      );
    });
  }

  Future<bool> _verifySeekResult({
    required Duration expectedPosition,
    required String source,
    required VideoPlayerController controller,
    required String itemId,
    required int requestId,
    required bool retryOnDrift,
  }) {
    return _verifySeekResultImpl(
      expectedPosition: expectedPosition,
      source: source,
      controller: controller,
      itemId: itemId,
      requestId: requestId,
      retryOnDrift: retryOnDrift,
    );
  }

  Future<bool> _verifySeekResultImpl({
    required Duration expectedPosition,
    required String source,
    required VideoPlayerController controller,
    required String itemId,
    required int requestId,
    required bool retryOnDrift,
  }) async {
    if (requestId != _seekRequestId ||
        !_isCurrentControllerSession(controller, itemId) ||
        !controller.value.isInitialized) {
      _logPlaybackEvent(
        'seek verification skipped',
        data: <String, Object?>{
          'source': source,
          'reason': 'controller_or_request_replaced',
        },
      );
      return true;
    }

    Duration actualPosition;
    try {
      actualPosition = await controller.position ?? controller.value.position;
    } catch (_) {
      actualPosition = controller.value.position;
    }
    if (requestId != _seekRequestId ||
        !_isCurrentControllerSession(controller, itemId)) {
      return true;
    }

    final deltaMs =
        (actualPosition.inMilliseconds - expectedPosition.inMilliseconds).abs();
    final seekAgeMs = _lastSeekRequestedAt == null
        ? 0
        : DateTime.now().difference(_lastSeekRequestedAt!).inMilliseconds;
    final allowedForwardMs = _state == PlaybackState.playing
        ? seekAgeMs + _seekVerificationToleranceMs
        : _seekVerificationToleranceMs;
    final signedDeltaMs =
        actualPosition.inMilliseconds - expectedPosition.inMilliseconds;
    final confirmed =
        signedDeltaMs >= -_seekVerificationToleranceMs &&
        signedDeltaMs <= allowedForwardMs;
    if (!confirmed) {
      _logPlaybackEvent(
        'seek verification drift detected',
        data: <String, Object?>{
          'source': source,
          'expectedMs': expectedPosition.inMilliseconds,
          'actualMs': actualPosition.inMilliseconds,
          'deltaMs': deltaMs,
          'lastSeekSource': _lastSeekSource,
          'lastRequestedMs': _lastRequestedSeekPosition?.inMilliseconds,
          'lastSeekAgeMs': _lastSeekRequestedAt == null
              ? null
              : DateTime.now().difference(_lastSeekRequestedAt!).inMilliseconds,
          'willRecheck': retryOnDrift,
        },
      );
      if (retryOnDrift) {
        // A local ALAC seek may acknowledge before its native position event.
        // Wait for the follow-up read instead of issuing a duplicate seek into
        // the same decoder while it is still re-anchoring its audio clock.
        return false;
      }

      // Keyframe hops are allowed to land on the previous IDR. Rewriting the
      // service clock to that sample makes subtitle highlight bounce backward.
      if (!SubtitleHopSeekPolicy.shouldRewritePositionOnSeekDrift(source)) {
        _logPlaybackEvent(
          'seek verification hop drift ignored',
          data: <String, Object?>{
            'source': source,
            'expectedMs': expectedPosition.inMilliseconds,
            'actualMs': actualPosition.inMilliseconds,
            'deltaMs': deltaMs,
          },
        );
        return true;
      }

      // The second direct read is authoritative: if the native backend still
      // rejected the seek, expose the real position instead of persisting the
      // optimistic target forever.
      _clearInitialPositionGuard();
      _position = actualPosition;
      _bufferedPosition = _readBufferedPosition(controller);
      _resetPlaybackTimeline(
        actualPosition,
        running: _state == PlaybackState.playing,
      );
      _updateCurrentSubtitle();
      notifyListeners();
      return false;
    }

    _logPlaybackEvent(
      'seek verification passed',
      data: <String, Object?>{
        'source': source,
        'expectedMs': expectedPosition.inMilliseconds,
        'actualMs': actualPosition.inMilliseconds,
        'lastRequestedMs': _lastRequestedSeekPosition?.inMilliseconds,
      },
    );
    _clearInitialPositionGuard();
    if (actualPosition != _position) {
      _position = actualPosition;
      _bufferedPosition = _readBufferedPosition(controller);
      if (_state == PlaybackState.playing) {
        // This sample confirms the seek already presented by the UI. Native
        // queries can trail the current frame, even by just a packet. Observe
        // it like ordinary progress instead of replaying the explicit seek
        // and restarting word highlighting a second time.
        _observeNativeTimelinePosition(actualPosition);
      } else {
        _resetPlaybackTimeline(actualPosition, running: false);
      }
      _updateCurrentSubtitle();
      notifyListeners();
    }
    return true;
  }

  double get _targetControllerVolume => _isMuted ? 0.0 : _volume;

  bool _controllerVolumeMatchesDesired(VideoPlayerController controller) {
    return (controller.value.volume - _targetControllerVolume).abs() < 0.001;
  }

  Future<void> _applyMuteStateToController({String? reason}) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }
    if (_controllerVolumeMatchesDesired(controller)) {
      return;
    }
    try {
      await controller.setVolume(_targetControllerVolume);
    } catch (e) {
      debugPrint(
        'MediaPlaybackService: 应用静音状态失败'
        '${reason == null ? '' : ' ($reason)'} $e',
      );
    }
  }

  Future<void> _restorePersistedMuteState({bool notify = true}) async {
    bool persistedMute = SettingsService().globalMute;
    try {
      final prefs = await SharedPreferences.getInstance();
      persistedMute = prefs.getBool(_globalMutePrefsKey) ?? persistedMute;
    } catch (e) {
      debugPrint('MediaPlaybackService: 读取静音状态失败 $e');
    }
    _isMuted = persistedMute;
    SettingsService().globalMute = persistedMute;
    if (notify) {
      notifyListeners();
    }
  }

  Future<void> _persistMuteState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_globalMutePrefsKey, _isMuted);
      SettingsService().globalMute = _isMuted;
    } catch (e) {
      debugPrint('MediaPlaybackService: 保存静音状态失败 $e');
    }
  }
}
