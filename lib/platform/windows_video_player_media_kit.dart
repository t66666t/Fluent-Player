import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
// Native regression probe exercises the pinned Android output implementation.
// ignore: implementation_imports
import 'package:media_kit_video/src/video_controller/android_video_controller/android_video_controller.dart';
import 'package:universal_platform/universal_platform.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart'
    hide VideoTrack;

import 'pitch_preserving_audio_pipeline.dart';
import 'native_audio_pause_repair.dart';
import 'temporary_playback_properties.dart';
import 'local_playback_backend_policy.dart';
import 'video_display_geometry.dart';
import 'linux_media_runtime.dart';
import 'ambient_frame_thumbnail.dart';
import '../services/settings_service.dart';
import '../services/bilibili/bilibili_startup.dart';
import '../services/playback_startup.dart';
import '../services/subtitle_hop_seek_policy.dart';
import '../features/podcasts/podcast_playback_policy.dart';
import '../features/cloud_drive/services/baidu_hls_timeline.dart';
export 'package:media_kit_video/src/video_controller/video_output_state.dart';

class NativeVideoPlayerMediaKit {
  @visibleForTesting
  static ValueListenable<VideoOutputState>? Function(int)? debugOutputStateFor;
  @visibleForTesting
  static Future<bool> Function(int)? debugAttachVideoOutput;

  static ValueListenable<VideoOutputState>? outputStateFor(int playerId) =>
      debugOutputStateFor?.call(playerId) ??
      _NativeMediaKitVideoPlayer.registeredInstance?._outputStates[playerId];

  static bool? transportUsableFor(int playerId) {
    final adapter = _NativeMediaKitVideoPlayer.registeredInstance;
    if (adapter == null || !adapter._players.containsKey(playerId)) return null;
    return !adapter._retiringPlayers.contains(playerId) &&
        !adapter._invalidNativeCommands.contains(playerId);
  }

  static ValueListenable<int>? healthHintsFor(int playerId) =>
      _NativeMediaKitVideoPlayer.registeredInstance?._healthHints[playerId];

  /// Native regression probe: exercise actual vo/wid rebinding with the same
  /// Android Surface. Real OS reclamation remains a separate device scenario.
  @visibleForTesting
  static Future<bool> debugCycleAndroidSurface(
    int playerId,
    Future<void> Function() whileDetached,
  ) async {
    final controller = _NativeMediaKitVideoPlayer
        .registeredInstance
        ?._videoControllers[playerId];
    final output = await controller?.platform.future;
    if (output is! AndroidVideoController) return false;
    final original = output.wid.value;
    if (original == null || original == 0) return false;
    output.wid.value = 0;
    await output.recoverOutput();
    try {
      await whileDetached();
    } finally {
      output.wid.value = original;
    }
    return true;
  }

  static bool? hasRegisteredVideoOutputFor(int playerId) {
    if (debugOutputStateFor?.call(playerId) != null) return true;
    final adapter = _NativeMediaKitVideoPlayer.registeredInstance;
    if (adapter == null) return null;
    return adapter._delegatedTextureIds.containsKey(playerId) ||
        adapter._videoControllers.containsKey(playerId);
  }

  static ValueListenable<Size?>? displaySizeFor(int playerId) =>
      _NativeMediaKitVideoPlayer
          .registeredInstance
          ?._displayVideoSizes[playerId];

  static const Set<String> _audioOnlyExtensions = <String>{
    '.aac',
    '.ac3',
    '.aif',
    '.aifc',
    '.aiff',
    '.alac',
    '.amr',
    '.ape',
    '.au',
    '.caf',
    '.dff',
    '.dsf',
    '.dts',
    '.eac3',
    '.flac',
    '.m4a',
    '.m4b',
    '.mka',
    '.mp2',
    '.mp3',
    '.oga',
    '.ogg',
    '.opus',
    '.ra',
    '.snd',
    '.tta',
    '.wav',
    '.wma',
    '.wv',
  };

  /// Private transport metadata understood only by this native video_player
  /// adapter. It is stripped before any HTTP request is sent.
  static const String externalAudioSourceHeader =
      'x-fluent-player-external-audio-source';

  /// Quality hand-off creates a second Player that immediately seeks away from
  /// t=0. Skip the conservative 2s cache-pause-initial so the warm decoder
  /// does not sit idle while the visible stream keeps playing.
  static const String fastStreamStartHeader =
      'x-fluent-player-fast-stream-start';

  /// Mini card / notification: the loopback audio URL is the primary media.
  /// Skip video-track discovery so audio can start without waiting on video.
  static const String audioPrimaryStreamHeader =
      'x-fluent-player-audio-primary';

  /// Same split stream as the playback page, but start with [VideoTrack.no]
  /// so Mini/notification does not decode video. Re-enabling the track later
  /// keeps the Player and clock — no recreate+seek on page entry.
  static const String deferVideoStreamHeader = 'x-fluent-player-defer-video';

  /// Open libmpv already parked at this timestamp (milliseconds). Avoids an
  /// extra Range seek after initialize when resuming or handing off quality.
  static const String startPositionMsHeader = 'x-fluent-player-start-ms';

  /// Ordinary cloud progressive or HLS. Distinct from Bilibili's external-audio
  /// fast start, which also forces seekable and a tiny probe.
  static const String cloudDriveProfileHeader =
      'x-fluent-player-cloud-drive-profile';

  /// Last options applied for a cloud profile, including values read back from
  /// libmpv when that read succeeded. Tests assert the map without a display.
  static Map<String, String>? debugLastCloudDriveProfile;

  /// Low-latency start for a cloud file whose container is already known.
  ///
  /// HLS may use a short probe. Progressive files keep the demuxer's own
  /// probe so a short read cannot drop an audio track. `force-seekable` is
  /// intentionally absent: a file that ignores Range must stay unseekable.
  static Map<String, String> cloudDriveNativeOptions({
    required bool hls,
    required bool fastStart,
    String? existingLavfOptions,
  }) {
    final options = <String, String>{
      'cache': 'yes',
      'cache-pause': 'yes',
      'cache-pause-initial': fastStart ? 'no' : 'yes',
      'cache-pause-wait': fastStart
          ? SubtitleHopSeekPolicy.streamingScrubCachePauseWaitSeconds
          : SubtitleHopSeekPolicy.streamingCachePauseWaitSeconds,
      'demuxer-readahead-secs': hls ? '6' : '8',
      'demuxer-max-bytes': '${8 * 1024 * 1024}',
      'demuxer-max-back-bytes': '${4 * 1024 * 1024}',
      // media_kit's default is 5s, which can expire while the gateway is
      // still inside its own header budget.
      'network-timeout': '12',
    };
    if (hls) {
      options['demuxer-lavf-analyzeduration'] = '0.5';
      options['demuxer-lavf-probesize'] = '262144';
      // Keep media_kit's original lavf dictionary. mpv's string readback
      // drops escaping around comma-valued options (protocol_whitelist).
      // Setting that readback again treats "rtp", "tcp", etc. as options
      // without values and emits an initialization error. The gateway and
      // controller deadline already bound retries.
    }
    return options;
  }

  static Map<String, String> cloudDrivePlayerHeaders({
    required bool hls,
    Duration start = Duration.zero,
  }) {
    return <String, String>{
      cloudDriveProfileHeader: hls ? 'hls' : 'progressive',
      fastStreamStartHeader: '1',
      if (start > Duration.zero)
        startPositionMsHeader: '${start.inMilliseconds}',
    };
  }

  static bool get supportsHardwareVideoDecodingControl =>
      UniversalPlatform.isAndroid ||
      UniversalPlatform.isIOS ||
      UniversalPlatform.isMacOS ||
      UniversalPlatform.isWindows ||
      UniversalPlatform.isLinux;

  @visibleForTesting
  static VideoTrack? firstUsableVideoTrack(Tracks tracks) {
    for (final track in tracks.video) {
      if (track.id != 'auto' && track.id != 'no') return track;
    }
    return null;
  }

  static void ensureInitialized() {
    if (!supportsHardwareVideoDecodingControl) {
      return;
    }
    initializeLinuxMediaRuntime();
    MediaKit.ensureInitialized();
    _NativeMediaKitVideoPlayer.registerWith();
  }

  /// Returns media_kit's native presentation-position samples for the
  /// controller identified by [playerId]. The samples are intentionally kept
  /// separate from video_player's comparatively coarse ValueNotifier updates:
  /// frame-driven overlays use them to detect drift, never as animation ticks.
  static Stream<Duration>? positionStreamFor(int playerId) {
    return _NativeMediaKitVideoPlayer.registeredInstance?._positionStreamFor(
      playerId,
    );
  }

  /// libmpv `time-pos`, not video_player's Dart cache. The cache can echo a
  /// `start=` header after the post-open video-track select has reset decode.
  static Duration? timePosFor(int playerId) {
    return _NativeMediaKitVideoPlayer.registeredInstance?._timePosFor(playerId);
  }

  /// JPEG of the frame libmpv has already decoded, for the letterbox matte.
  ///
  /// Android local files delegated to ExoPlayer have no frame API. Returning
  /// null keeps the black scaffold and does not open a second decoder.
  static Future<Uint8List?> ambientFrameFor(int playerId) {
    final instance = _NativeMediaKitVideoPlayer.registeredInstance;
    if (instance == null || playerId < 0) return Future<Uint8List?>.value();
    return instance._ambientFrameFor(playerId);
  }

  /// A small JPEG for the blurred letterbox matte. [ambientFrameFor] retains
  /// its full-resolution contract for persisted cloud-drive cover images.
  static Future<Uint8List?> ambientThumbnailFrameFor(int playerId) {
    final instance = _NativeMediaKitVideoPlayer.registeredInstance;
    if (instance == null || playerId < 0) return Future<Uint8List?>.value();
    return instance._ambientThumbnailFrameFor(playerId);
  }

  /// Explicit capture diagnostics. Regular playback never calls this probe.
  /// [captureRaw] reports only the public raw buffer's length. The optional
  /// [softwareCapture] temporarily sets screenshot-sw for this probe and
  /// restores its known original value, without changing normal capture.
  static Future<Map<String, Object?>> ambientThumbnailDiagnosticsFor(
    int playerId, {
    bool captureRaw = false,
    bool softwareCapture = false,
  }) async {
    final instance = _NativeMediaKitVideoPlayer.registeredInstance;
    if (instance == null || playerId < 0) {
      return const {'available': false, 'reason': 'player_unavailable'};
    }
    return instance._ambientThumbnailDiagnosticsFor(
      playerId,
      captureRaw: captureRaw,
      softwareCapture: softwareCapture,
    );
  }

  /// Drops a captured frame when the texture belongs to the platform player.
  @visibleForTesting
  static Uint8List? selectAmbientFrame({
    required bool delegatedToPlatformPlayer,
    Uint8List? captured,
  }) {
    if (delegatedToPlatformPlayer) return null;
    return captured;
  }

  /// Read mpv's actual clock at a transport boundary. The regular position
  /// stream/state is cached and may still precede a just-completed pause.
  static Future<Duration?> transportPositionFor(int playerId) async {
    return _NativeMediaKitVideoPlayer.registeredInstance?._transportPositionFor(
      playerId,
    );
  }

  static Future<Map<String, String>> transportStateFor(int playerId) async =>
      await _NativeMediaKitVideoPlayer.registeredInstance?._transportStateFor(
        playerId,
      ) ??
      const {};

  /// Returns each rate after libmpv has accepted it. Frame-driven overlays use
  /// this to share the player's exact media-time slope.
  static Stream<double>? rateStreamFor(int playerId) {
    return _NativeMediaKitVideoPlayer.registeredInstance?._rateStreamFor(
      playerId,
    );
  }

  /// Completes when the native texture has received its first decoded frame.
  /// This is used by online quality hand-off to avoid swapping a fully visible
  /// player for a replacement whose texture is still empty.
  static Future<void>? firstFrameRenderedFor(int playerId) {
    return _NativeMediaKitVideoPlayer.registeredInstance
        ?._firstFrameRenderedFor(playerId);
  }

  /// Length prefixes escape EDL separators, including non-ASCII URL bytes.
  /// Only gateway URLs reach this path; routing and CDN headers stay in Dart.
  static String dualTrackEdl(String video, String audio) {
    for (final source in [video, audio]) {
      final uri = Uri.tryParse(source);
      if (uri == null ||
          !uri.hasAuthority ||
          (uri.scheme != 'http' && uri.scheme != 'https')) {
        throw ArgumentError.value(source, 'source', 'Invalid media URI');
      }
    }
    String entry(String uri) => '%${utf8.encode(uri).length}%$uri';
    return 'edl://${entry(video)};!new_stream;${entry(audio)}';
  }

  static bool positionHasSettled({
    required Duration actual,
    required Duration target,
    required bool seeking,
  }) =>
      !seeking &&
      (actual - target).abs() <= BilibiliStartupContext.positionTolerance;

  /// Null means this is a platform/fake controller outside this adapter.
  static Future<bool>? positionSettledFor(int playerId, Duration target) =>
      _NativeMediaKitVideoPlayer.registeredInstance?._positionSettledFor(
        playerId,
        target,
      );

  static bool managesPlayer(int playerId) =>
      _NativeMediaKitVideoPlayer.registeredInstance?._players.containsKey(
        playerId,
      ) ??
      false;

  /// Decoder parameters from the active native audio stream. A missing decoder
  /// must not turn a failed audio selection into a successful silent handoff.
  static Future<Map<String, String>?> audioStateFor(int playerId) async {
    final platform = _NativeMediaKitVideoPlayer
        .registeredInstance
        ?._players[playerId]
        ?.platform;
    if (platform is! NativePlayer) return null;
    final result = <String, String>{};
    for (final key in [
      'aid',
      'audio-codec-name',
      'audio-params/samplerate',
      'audio-params/channel-count',
      'audio-params/format',
      'audio-out-params/samplerate',
      'audio-out-params/channel-count',
    ]) {
      try {
        result[key] = await platform
            .getProperty(key, waitForInitialization: false)
            .timeout(const Duration(milliseconds: 500));
      } catch (_) {
        result[key] = '';
      }
    }
    return result;
  }

  static Future<bool>? transportPausedFor(int playerId) {
    final platform = _NativeMediaKitVideoPlayer
        .registeredInstance
        ?._players[playerId]
        ?.platform;
    if (platform is! NativePlayer) return null;
    return platform
        .getProperty('pause', waitForInitialization: false)
        .then((value) => value == 'yes');
  }

  static Future<void>? frameAtPositionFor(
    int playerId,
    BilibiliStartupContext startup, {
    Duration Function()? target,
  }) => _NativeMediaKitVideoPlayer.registeredInstance?._frameAtPositionFor(
    playerId,
    startup,
    target: target,
  );

  /// Preparation belongs to the transport. Background audio must never wait
  /// for a Flutter texture, including when page visibility changes mid-open.
  static Future<void>? preparedForPlayback(
    int playerId,
    PlaybackStartupContext startup, {
    required bool Function() videoRequired,
  }) => _NativeMediaKitVideoPlayer.registeredInstance?._preparedForPlayback(
    playerId,
    startup,
    videoRequired: videoRequired,
  );

  static Future<void>? clockStartedFor(
    int playerId,
    PlaybackStartupContext startup,
    Duration baseline, {
    required bool Function() shouldWait,
  }) => _NativeMediaKitVideoPlayer.registeredInstance?._clockStartedFor(
    playerId,
    startup,
    baseline,
    shouldWait: shouldWait,
  );

  /// Whether this player owns an actual Flutter video output. A background
  /// headless player deliberately returns false; an unrelated platform adapter
  /// returns null so callers do not rebuild a controller they cannot inspect.
  static bool? hasVideoOutputFor(int playerId) {
    final debug = debugOutputStateFor?.call(playerId);
    if (debug != null) return debug.value.available;
    return _NativeMediaKitVideoPlayer.registeredInstance?._hasVideoOutputFor(
      playerId,
    );
  }

  /// Adds a Flutter video texture to an already playing native player.
  ///
  /// Android notification commands may create a headless player while the app
  /// is backgrounded. Attaching the output later keeps the exact same libmpv
  /// instance, network cache, Bilibili DASH tracks, position and play state;
  /// reopening the media here would make foreground entry visibly buffer and
  /// replay the seek target.
  static Future<bool> attachVideoOutputFor(int playerId) async {
    if (debugAttachVideoOutput != null) {
      return debugAttachVideoOutput!(playerId);
    }
    return await _NativeMediaKitVideoPlayer.registeredInstance
            ?._attachVideoOutputFor(playerId) ??
        false;
  }

  /// Split Bilibili streams deselect video with [VideoTrack.no]. Re-selecting
  /// that elementary stream makes libmpv decode from the start of the file,
  /// while the Player clock and external audio keep running. Seek back unless
  /// the clock is already at zero (a genuine start).
  ///
  /// A live Mini/notification clock still needs this seek for A/V sync, but
  /// the seek itself must not use cache-pause — that is the audible hitch.
  @visibleForTesting
  static bool shouldSeekAfterExternalVideoTrackEnable({
    required String previousTrackId,
    required String nextTrackId,
    required Duration clockPosition,
  }) {
    if (previousTrackId == nextTrackId) return false;
    return clockPosition > Duration.zero;
  }

  /// A live Mini clock must not be seeked when `vid` joins in place. A cold
  /// restore can still drop `time-pos` back to the file start; only that
  /// collapse should be repaired, otherwise audio hitches on page entry.
  @visibleForTesting
  static bool shouldRepairClockAfterExternalVideoTrackEnable({
    required Duration clockBefore,
    required Duration clockAfter,
  }) {
    if (clockBefore <= Duration.zero) return false;
    return clockAfter + const Duration(milliseconds: 400) < clockBefore &&
        clockAfter <= const Duration(milliseconds: 450);
  }

  /// `setVideoTrack` can reset the reported `time-pos` toward zero while the
  /// external audio clock keeps running. Prefer wall-clock interpolation of
  /// the pre-switch sample over that stale report.
  @visibleForTesting
  static Duration liveClockAfterVideoTrackEnable({
    required Duration clockBefore,
    required Duration elapsed,
    required Duration clockAfter,
  }) {
    final predicted = clockBefore + elapsed;
    if (clockAfter + const Duration(milliseconds: 400) < clockBefore) {
      return predicted;
    }
    return clockAfter >= predicted ? clockAfter : predicted;
  }

  /// Explicit pause intent wins over a stale native playing snapshot.
  static bool shouldResumeExternalVideoTrack({
    required bool playing,
    required bool keepPlaying,
    required bool keepPaused,
  }) => !keepPaused && (playing || keepPlaying);

  /// Selects or deselects the primary video track of a split Bilibili stream.
  /// The external audio track and the Player clock remain untouched, allowing
  /// mobile background playback to stop consuming video bytes without an
  /// audible hand-off. Local Android files are delegated to video_player and
  /// therefore never enter this path.
  static Future<bool> setExternalVideoTrackEnabledFor(
    int playerId, {
    required bool enabled,
    bool keepPlaying = false,
    bool keepPaused = false,
  }) async {
    return await _NativeMediaKitVideoPlayer.registeredInstance
            ?._setExternalVideoTrackEnabledFor(
              playerId,
              enabled: enabled,
              keepPlaying: keepPlaying,
              keepPaused: keepPaused,
            ) ??
        false;
  }

  /// Completes only after the native media clock has demonstrably started or
  /// the demuxer has buffered beyond the requested position. Unlike a texture
  /// frame, this remains a valid readiness signal while no playback page is
  /// mounted (Mini card, notification, desktop background audio).
  static Future<bool>? playbackReadyFor(int playerId) {
    return _NativeMediaKitVideoPlayer.registeredInstance?._playbackReadyFor(
      playerId,
    );
  }

  /// Mini-card / notification play must not wait for `buffering` to go false.
  /// Split Bilibili streams often keep that flag true for the whole session
  /// (cache-pause, readahead). A running clock or a filled demuxer window is
  /// enough to treat audio-only playback as started. Windows often reports
  /// neither `playing` nor buffer ahead; Mini chrome then uses play intent.
  @visibleForTesting
  static bool isBackgroundPlaybackClockReady({
    required bool playing,
    required bool completed,
    required bool positionAdvanced,
    required bool bufferedAhead,
  }) {
    if (completed) return false;
    // cache-pause leaves `playing` false while packets are already in the
    // demuxer. Waiting for the Dart isPlaying flag made Mini/notification
    // skips look dead on a gigabit link.
    if (bufferedAhead) return true;
    return playing && positionAdvanced;
  }

  /// Reopens the same media on Android with software video decoding while
  /// preserving the audio/video clock. This is a last-resort recovery for a
  /// player whose audio started but whose hardware decoder never produced a
  /// Flutter texture frame.
  static Future<bool> recoverVideoOutputFor(int playerId) async {
    return await _NativeMediaKitVideoPlayer.registeredInstance
            ?._recoverVideoOutputFor(playerId) ??
        false;
  }

  /// Invalidates a queued rate request. A command already accepted by libmpv
  /// cannot be recalled, but the replacement request will run immediately
  /// after it instead of overlapping it.
  static void cancelPendingRateChange(int playerId) {
    _NativeMediaKitVideoPlayer.registeredInstance?._cancelPendingRateChange(
      playerId,
    );
  }

  /// Installs libmpv seek/cache properties for the next [VideoPlayerController.seekTo].
  ///
  /// Sentence hops on split Bilibili streams use keyframe seeks and a short
  /// cache-pause so the clock is not held for [SubtitleHopSeekPolicy.streamingCachePauseWaitSeconds].
  /// Precise seeks restore the conservative streaming defaults.
  static Future<void> prepareSeekStyleFor(
    int playerId, {
    required StreamingSeekStyle style,
  }) async {
    await _NativeMediaKitVideoPlayer.registeredInstance?._prepareSeekStyle(
      playerId,
      style: style,
    );
  }

  /// Returns the explicit libmpv decoder policy used for a new player.
  /// `auto-safe` is media_kit's supported Android default; the other native
  /// backends use libmpv's `auto` probing. These values let libmpv fall back
  /// when it can reject an unsupported decoder up front. Some Android codec
  /// implementations fail only after MediaCodec has been selected, so the
  /// platform wrapper also performs one explicit software retry in that case.
  /// Linux GPU-less / broken CUDA hosts blue-screen when media_kit keeps HW
  /// VO + Impeller GLES. Prefer software decode (`hwdec=no`) on Linux always.
  @visibleForTesting
  static String decoderOptionFor({
    required bool useHardwareDecoding,
    required String operatingSystem,
  }) {
    if (!useHardwareDecoding || operatingSystem == 'linux') return 'no';
    return operatingSystem == 'android' ? 'auto-safe' : 'auto';
  }

  /// Whether media_kit should enable GPU texture output (`enableHardwareAcceleration`).
  /// Always false on Linux; also false when `/dev/dri` is missing (injectable).
  @visibleForTesting
  static bool shouldEnableHardwareVideoOutput(
    String operatingSystem, {
    bool? hasDriDevices,
  }) {
    if (operatingSystem == 'linux') return false;
    if (hasDriDevices == false) return false;
    return true;
  }

  /// Detects DRM render nodes. Only meaningful on Linux; injectable for tests.
  @visibleForTesting
  static bool linuxHasDriDevices({bool Function()? directoryExists}) {
    final exists = directoryExists ?? () => Directory('/dev/dri').existsSync();
    try {
      return exists();
    } catch (_) {
      return false;
    }
  }

  @visibleForTesting
  static bool shouldRetryAndroidSoftwareDecoding({
    required bool useHardwareDecoding,
    required String operatingSystem,
    required bool firstFrameRendered,
    required bool fallbackAttempted,
  }) {
    return operatingSystem == 'android' &&
        useHardwareDecoding &&
        !firstFrameRendered &&
        !fallbackAttempted;
  }

  /// media_kit defers Android's VideoController creation through a post-frame
  /// callback. Hidden/paused apps may not receive another Flutter frame, so a
  /// media-notification switch must not block audio loading on that callback.
  @visibleForTesting
  static bool shouldDeferVideoOutputInitialization({
    required String operatingSystem,
    required AppLifecycleState? lifecycleState,
  }) {
    return operatingSystem == 'android' &&
        (lifecycleState == AppLifecycleState.hidden ||
            lifecycleState == AppLifecycleState.paused ||
            lifecycleState == AppLifecycleState.detached);
  }

  /// Pure audio never needs a Flutter video texture. In particular, creating a
  /// [VideoController] for M4A/ALAC leaves the Android first-frame observer
  /// pending forever. A later audio-decoder log can then be mistaken for a
  /// failed hardware *video* decoder and unnecessarily reopen the player.
  @visibleForTesting
  static bool shouldCreateVideoOutput({
    required String resource,
    required String operatingSystem,
    required AppLifecycleState? lifecycleState,
    bool knownAudioOnly = false,
  }) {
    if (knownAudioOnly || isKnownAudioOnlyResource(resource)) return false;

    final uri = Uri.tryParse(resource);
    final isNetworkSource = uri?.scheme == 'http' || uri?.scheme == 'https';
    return !isNetworkSource ||
        !shouldDeferVideoOutputInitialization(
          operatingSystem: operatingSystem,
          lifecycleState: lifecycleState,
        );
  }

  /// The pre-streaming Android implementation used the platform
  /// `video_player` backend for local files. Keep that stable path even though
  /// Bilibili DASH streams still need the MediaKit adapter for their external
  /// audio track.
  @visibleForTesting
  static bool shouldUsePlatformPlayer({
    required DataSourceType sourceType,
    required String operatingSystem,
    required String? resource,
  }) {
    return operatingSystem == 'android' &&
        sourceType == DataSourceType.file &&
        resource != null &&
        !LocalPlaybackBackendPolicy.isWideCodecBackendPreferred(resource);
  }

  /// Filters transient completion pulses from embedded album-art streams.
  ///
  /// video_player treats a forwarded completion as authoritative and moves
  /// its position to the duration. Some M4A files briefly publish completion
  /// while their still-image cover track is selected, paused, or torn down,
  /// even though the audio track is nowhere near its end.
  @visibleForTesting
  static bool shouldForwardPlaybackCompletion({
    required bool completed,
    required Duration position,
    required Duration duration,
  }) {
    if (!completed || duration <= Duration.zero || position < Duration.zero) {
      return false;
    }
    const completionTolerance = Duration(seconds: 1);
    return position + completionTolerance >= duration;
  }

  /// media_kit's error stream is synthesized from selected libmpv log lines;
  /// it is not a terminal-state stream. Once a controller has a duration and
  /// usable tracks, decoder/track-reconfiguration messages must not turn the
  /// whole VideoPlayerController into an uninitialized erroneous value.
  @visibleForTesting
  static bool shouldForwardPlayerError({
    required bool controllerInitialized,
    required Duration duration,
    required bool hasUsableMediaTrack,
  }) {
    if (!controllerInitialized) return true;
    return duration <= Duration.zero && !hasUsableMediaTrack;
  }

  /// Hosts without an ALSA/Pulse sound card make libmpv report
  /// "Could not open/initialize audio device -> no sound." That is not a
  /// fatal video failure: L3 requires silent degrade while video continues.
  @visibleForTesting
  static bool isRecoverableMissingAudioDeviceError(Object error) {
    final message = '$error'.toLowerCase();
    return message.contains('could not open/initialize audio device') ||
        message.contains('no sound');
  }

  /// Identifies sources whose visual track can only be embedded cover art.
  /// Disabling that track before the controller becomes usable keeps libmpv's
  /// seek clock anchored to audio instead of a one-frame attached picture.
  @visibleForTesting
  static bool isKnownAudioOnlyResource(String resource) {
    var path = resource;
    try {
      final uri = Uri.parse(resource);
      if (uri.path.isNotEmpty) path = uri.path;
    } catch (_) {}
    final normalized = path
        .replaceFirst(RegExp(r'[?#].*$'), '')
        .replaceAll('\\', '/')
        .toLowerCase();
    if (normalized.endsWith('/audio')) return true;
    return _audioOnlyExtensions.any(normalized.endsWith);
  }

  /// Whether the application may override the backend's output allocation.
  @visibleForTesting
  static bool supportsAdaptiveTextureResizing(String operatingSystem) {
    // Windows output uses shared D3D textures. Keep their allocation under
    // media_kit's ownership; changing it from Flutter layout can terminate
    // flutter_windows.dll during presentation (native fail-fast 0xc0000409).
    // Android's Surface backend does not expose output resizing at all.
    return operatingSystem != 'windows' && operatingSystem != 'android';
  }

  /// Caps the texture while retaining the video's aspect ratio. Windows keeps
  /// the backend's source-sized output to avoid live shared-texture replacement.
  @visibleForTesting
  static Size adaptiveTextureSize({
    required Size source,
    required Size physicalViewport,
  }) {
    if (source.width <= 0 ||
        source.height <= 0 ||
        physicalViewport.width <= 0 ||
        physicalViewport.height <= 0) {
      return source;
    }
    final scale = math.min(
      1.0,
      math.min(
        physicalViewport.width / source.width,
        physicalViewport.height / source.height,
      ),
    );
    if (scale >= 1.0) return source;

    int evenFloor(double value) {
      final floored = math.max(2, value.floor());
      return floored.isEven ? floored : floored - 1;
    }

    return Size(
      evenFloor(source.width * scale).toDouble(),
      evenFloor(source.height * scale).toDouble(),
    );
  }
}

class _NativeMediaKitVideoPlayer extends VideoPlayerPlatform
    with WidgetsBindingObserver {
  _NativeMediaKitVideoPlayer(this._platformFallback);

  static _NativeMediaKitVideoPlayer? registeredInstance;

  final VideoPlayerPlatform _platformFallback;
  final _delegatedTextureIds = HashMap<int, int>();
  // -1 is reserved by VideoPlayerController for an uninitialized player.
  int _nextDelegatedTextureId = -2;

  final _players = HashMap<int, Player>();
  final _completers = HashMap<int, Completer<void>>();
  final _creationReady = HashSet<int>();
  final _initializationNotifications = HashMap<int, VoidCallback>();
  final _videoControllers = HashMap<int, VideoController>();
  final _readyVideoOutputs = HashSet<int>();
  final _outputStates = HashMap<int, ValueNotifier<VideoOutputState>>();
  final _outputListeners = HashMap<int, VoidCallback>();
  final _outputWaiters = HashMap<int, Completer<bool>>();
  final _retiringPlayers = HashSet<int>();
  final _invalidNativeCommands = HashSet<int>();
  final _transportIntentRevisions = HashMap<int, int>();
  final _healthHints = HashMap<int, ValueNotifier<int>>();
  final _videoOutputAttachments = HashMap<int, Future<bool>>();
  final _ambientCaptureQueues = HashMap<int, AmbientCaptureQueue>();
  final _externalVideoTrackCommands = HashMap<int, Future<void>>();
  final _externalVideoTrackDesired = HashMap<int, bool>();
  final _suspendedExternalVideoTracks = HashMap<int, VideoTrack>();
  final _streamControllers = HashMap<int, StreamController<VideoEvent>>();
  final _rateStreamControllers = HashMap<int, StreamController<double>>();
  final _streamSubscriptions = HashMap<int, List<StreamSubscription>>();
  final _rateRequestEpochs = HashMap<int, int>();
  final _rateCommands = HashMap<int, Future<void>>();
  final _sourceVideoSizes = HashMap<int, Size>();
  final _displayVideoSizes = HashMap<int, ValueNotifier<Size?>>();
  final _outputVideoSizes = HashMap<int, Size>();
  final _resizeEpochs = HashMap<int, int>();
  final _frameDropModes = HashMap<int, String>();
  final _decoderFallbackStates = HashMap<int, _DecoderFallbackState>();
  final _streamingBufferPlayers = HashSet<int>();
  final _streamingSeekStyles = HashMap<int, StreamingSeekStyle>();
  final _temporaryVideoJoins = HashSet<int>();
  final _audioPauseRepairs = HashMap<int, NativeAudioPauseRepair>();

  static void registerWith() {
    final previous = registeredInstance;
    final currentPlatform = VideoPlayerPlatform.instance;
    final platformFallback = currentPlatform is _NativeMediaKitVideoPlayer
        ? currentPlatform._platformFallback
        : currentPlatform;
    if (previous != null) {
      WidgetsBinding.instance.removeObserver(previous);
    }
    final instance = _NativeMediaKitVideoPlayer(platformFallback);
    registeredInstance = instance;
    VideoPlayerPlatform.instance = instance;
    WidgetsBinding.instance.addObserver(instance);
  }

  @override
  void didChangeMetrics() {
    for (final entry in _sourceVideoSizes.entries) {
      _scheduleAdaptiveOutputResize(entry.key, entry.value);
    }
  }

  Stream<Duration>? _positionStreamFor(int textureId) {
    return _players[textureId]?.stream.position.map(
      (position) => _audioPauseRepairs[textureId]?.pausedPosition ?? position,
    );
  }

  Duration? _timePosFor(int textureId) {
    return _audioPauseRepairs[textureId]?.pausedPosition ??
        _players[textureId]?.state.position;
  }

  Future<Duration?> _transportPositionFor(int textureId) async {
    final paused = _audioPauseRepairs[textureId]?.pausedPosition;
    if (paused != null) return paused;
    final player = _players[textureId];
    final platform = player?.platform;
    if (platform is! NativePlayer) return null;
    try {
      final raw = await platform.getProperty(
        'time-pos',
        waitForInitialization: false,
      );
      final seconds = double.tryParse(raw);
      if (_players[textureId] != player ||
          seconds == null ||
          !seconds.isFinite ||
          seconds < 0) {
        return null;
      }
      return Duration(
        microseconds: (seconds * Duration.microsecondsPerSecond).round(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, String>> _transportStateFor(int textureId) async {
    final player = _players[textureId];
    final platform = player?.platform;
    if (platform is! NativePlayer) return const {};
    final result = <String, String>{};
    for (final key in [
      'pause',
      'paused-for-cache',
      'core-idle',
      'time-pos',
      'idle-active',
      'eof-reached',
      'path',
      'vid',
      'cache-pause',
      'hr-seek',
    ]) {
      try {
        result[key] = await platform
            .getProperty(key, waitForInitialization: false)
            .timeout(const Duration(milliseconds: 200));
      } catch (_) {
        result[key] = '?';
      }
    }
    return result;
  }

  /// Screenshot of the current mpv frame. Platform-player textures never reach
  /// libmpv, so they return null before `screenshot` can throw.
  Future<Uint8List?> _ambientFrameFor(int textureId) async {
    if (_delegatedTextureIds.containsKey(textureId)) return null;
    final player = _players[textureId];
    final state = _decoderFallbackStates[textureId];
    if (player == null || state == null) return null;
    bool current() =>
        identical(_players[textureId], player) &&
        identical(_decoderFallbackStates[textureId], state);
    final queue = _ambientCaptureQueues.putIfAbsent(
      textureId,
      AmbientCaptureQueue.new,
    );
    return queue.run<Uint8List>(
      isCurrent: current,
      capture: () async {
        try {
          final captured = await player.screenshot(
            format: 'image/jpeg',
            includeLibassSubtitles: false,
          );
          return current() ? captured : null;
        } catch (_) {
          return null;
        }
      },
    );
  }

  Future<Uint8List?> _ambientThumbnailFrameFor(int textureId) async {
    if (_delegatedTextureIds.containsKey(textureId)) return null;
    final player = _players[textureId];
    final state = _decoderFallbackStates[textureId];
    if (player == null || state == null) return null;
    // dispose() invalidates the state before awaiting the native transport
    // lock. Player-map identity alone would still accept an already retiring
    // session during that await.
    bool current() =>
        identical(_players[textureId], player) &&
        identical(_decoderFallbackStates[textureId], state);
    final queue = _ambientCaptureQueues.putIfAbsent(
      textureId,
      AmbientCaptureQueue.new,
    );
    final platform = player.platform;
    return queue.run<Uint8List>(
      isCurrent: current,
      capture: () => captureAmbientThumbnail(
        readSnapshot: () => _ambientFrameSnapshotFor(textureId, player, state),
        isCurrent: current,
        // Only Android has native evidence for the software-rendered SDR path.
        // Other platforms retain their original screenshot renderer.
        softwareForVerifiedSdr: UniversalPlatform.isAndroid,
        readSoftwareOption: platform is NativePlayer
            ? () => platform.getProperty(
                'screenshot-sw',
                waitForInitialization: false,
              )
            : null,
        writeSoftwareOption: platform is NativePlayer
            ? (value) => platform.setProperty(
                'screenshot-sw',
                value,
                waitForInitialization: false,
              )
            : null,
        onSoftwareRestoreFailure: queue.block,
        // Keep screenshot's public synchronized default. Its raw branch copies
        // the pixels and frees the mpv node before releasing the transport lock.
        captureRaw: () =>
            player.screenshot(format: null, includeLibassSubtitles: false),
        captureJpeg: () => player.screenshot(
          format: 'image/jpeg',
          includeLibassSubtitles: false,
        ),
      ),
    );
  }

  Future<AmbientFrameSnapshot?> _ambientFrameSnapshotFor(
    int textureId,
    Player player,
    _DecoderFallbackState state, {
    Map<String, Object?>? diagnostics,
  }) async {
    bool current() =>
        identical(_players[textureId], player) &&
        identical(_decoderFallbackStates[textureId], state);
    final platform = player.platform;
    if (!current() || platform is! NativePlayer) return null;
    final videoParams = player.state.videoParams;
    if (diagnostics != null) {
      diagnostics['decoderVideoParams'] = {
        'w': videoParams.w,
        'h': videoParams.h,
        'dw': videoParams.dw,
        'dh': videoParams.dh,
        'par': videoParams.par,
        'rotate': videoParams.rotate,
        'aspect': videoParams.aspect,
        'stereoIn': videoParams.stereoIn,
        'pixelformat': videoParams.pixelformat,
        'hwPixelformat': videoParams.hwPixelformat,
        'gamma': videoParams.gamma,
        'primaries': videoParams.primaries,
        'colormatrix': videoParams.colormatrix,
        'colorlevels': videoParams.colorlevels,
        'sigPeak': videoParams.sigPeak,
        'light': videoParams.light,
        'alpha': videoParams.alpha,
      };
    }
    final properties = <String, String>{};
    diagnostics?['outputProperties'] = properties;
    try {
      for (final name in AmbientFrameSnapshot.outputPropertyNames) {
        if (!current()) return null;
        properties[name] = await platform.getProperty(
          name,
          waitForInitialization: false,
        );
      }
    } catch (error) {
      diagnostics?['propertyReadError'] = '$error';
      return null;
    }
    if (!current()) return null;
    final unchanged = player.state.videoParams == videoParams;
    diagnostics?['decoderSnapshotStable'] = unchanged;
    if (!unchanged) return null;
    return AmbientFrameSnapshot(
      videoParams: videoParams,
      outputProperties: properties,
    );
  }

  Future<Map<String, Object?>> _ambientThumbnailDiagnosticsFor(
    int textureId, {
    required bool captureRaw,
    required bool softwareCapture,
  }) async {
    final player = _players[textureId];
    final state = _decoderFallbackStates[textureId];
    if (player == null || state == null) {
      return const {'available': false, 'reason': 'player_unavailable'};
    }
    bool current() =>
        identical(_players[textureId], player) &&
        identical(_decoderFallbackStates[textureId], state);
    final queue = _ambientCaptureQueues.putIfAbsent(
      textureId,
      AmbientCaptureQueue.new,
    );
    return await queue.run<Map<String, Object?>>(
          isCurrent: current,
          capture: () => _ambientThumbnailDiagnosticsUnserializedFor(
            textureId,
            captureRaw: captureRaw,
            softwareCapture: softwareCapture,
            queue: queue,
          ),
        ) ??
        const {'available': false, 'reason': 'capture_unavailable'};
  }

  Future<Map<String, Object?>> _ambientThumbnailDiagnosticsUnserializedFor(
    int textureId, {
    required bool captureRaw,
    required bool softwareCapture,
    required AmbientCaptureQueue queue,
  }) async {
    if (_delegatedTextureIds.containsKey(textureId)) {
      return const {'available': false, 'reason': 'platform_player'};
    }
    final player = _players[textureId];
    final state = _decoderFallbackStates[textureId];
    if (player == null || state == null) {
      return const {'available': false, 'reason': 'player_unavailable'};
    }
    bool current() =>
        identical(_players[textureId], player) &&
        identical(_decoderFallbackStates[textureId], state);
    const unavailable = {'available': false, 'reason': 'session_changed'};
    final result = <String, Object?>{'available': true, 'playerId': textureId};
    final before = await _ambientFrameSnapshotFor(
      textureId,
      player,
      state,
      diagnostics: result,
    );
    if (!current()) return unavailable;
    result['geometryEligible'] = before?.geometry() != null;
    if (captureRaw || softwareCapture) {
      try {
        if (softwareCapture) {
          final platform = player.platform;
          if (platform is! NativePlayer) {
            result['softwareCaptureSkipped'] = 'native_player_unavailable';
            return current() ? result : unavailable;
          }
          result.addAll(
            await probeAmbientSoftwareCapture(
              isCurrent: current,
              onRestoreFailure: queue.block,
              readOption: () => platform.getProperty(
                'screenshot-sw',
                waitForInitialization: false,
              ),
              writeOption: (value) => platform.setProperty(
                'screenshot-sw',
                value,
                waitForInitialization: false,
              ),
              captureRawByteLength: () async => (await player.screenshot(
                format: null,
                includeLibassSubtitles: false,
              ))?.length,
            ),
          );
        } else {
          final watch = Stopwatch()..start();
          result['rawAttempted'] = true;
          try {
            final raw = await player.screenshot(
              format: null,
              includeLibassSubtitles: false,
            );
            result['rawByteLength'] = raw?.length;
          } finally {
            watch.stop();
            result['rawElapsedMs'] = watch.elapsedMilliseconds;
          }
        }
        if (!current()) return unavailable;
        if (result['rawAttempted'] != true) return result;
        final afterDetails = <String, Object?>{};
        final after = await _ambientFrameSnapshotFor(
          textureId,
          player,
          state,
          diagnostics: afterDetails,
        );
        if (!current()) return unavailable;
        result['rawSnapshotStable'] = before?.matches(after) ?? false;
        result['afterRawSnapshot'] = afterDetails;
      } catch (error) {
        if (!current()) return unavailable;
        result['rawCaptureError'] = '$error';
      }
    }
    final platform = player.platform;
    if (current() && platform is NativePlayer) {
      for (final property in const {
        'screenshotSwCurrent': 'screenshot-sw',
        'mpvVersion': 'mpv-version',
      }.entries) {
        if (!current()) return unavailable;
        try {
          result[property.key] = await platform.getProperty(
            property.value,
            waitForInitialization: false,
          );
        } catch (error) {
          result['${property.key}Error'] = '$error';
        }
      }
    }
    return current() ? result : unavailable;
  }

  Stream<double>? _rateStreamFor(int textureId) {
    return _rateStreamControllers[textureId]?.stream;
  }

  Future<void>? _firstFrameRenderedFor(int textureId) {
    final controller = _videoControllers[textureId];
    if (controller == null) return null;
    return () async {
      if (!await _waitForAvailableOutput(textureId)) {
        throw const PlaybackStartupCancelled();
      }
      await controller.waitUntilFirstFrameRendered;
    }();
  }

  Future<bool>? _positionSettledFor(int textureId, Duration target) {
    final player = _players[textureId];
    final platform = player?.platform;
    if (player == null || platform is! NativePlayer) return null;
    return () async {
      final values = await Future.wait([
        platform.getProperty('time-pos', waitForInitialization: false),
        platform.getProperty('seeking', waitForInitialization: false),
      ]);
      if (_players[textureId] != player) return false;
      final seconds = double.tryParse(values[0]);
      if (seconds == null || !seconds.isFinite || values[1].isEmpty) {
        return false;
      }
      return NativeVideoPlayerMediaKit.positionHasSettled(
        actual: Duration(microseconds: (seconds * 1000000).round()),
        target: target,
        seeking: values[1] != 'no',
      );
    }();
  }

  Future<void>? _preparedForPlayback(
    int textureId,
    PlaybackStartupContext startup, {
    required bool Function() videoRequired,
  }) {
    final player = _players[textureId];
    final platform = player?.platform;
    if (player == null || platform is! NativePlayer) return null;
    return () async {
      VideoController? observed;
      var rendered = false;
      Object? frameError;
      while (_players[textureId] == player) {
        startup.check();
        final needsVideo = videoRequired();
        final output = _videoControllers[textureId];
        final outputGeneration = _outputStates[textureId]?.value.generation;
        if (output != null && !identical(output, observed)) {
          observed = output;
          rendered = false;
          frameError = null;
          unawaited(
            output.waitUntilFirstFrameRendered.then<void>(
              (_) {
                if (identical(observed, output)) rendered = true;
              },
              onError: (Object error, StackTrace _) {
                if (identical(observed, output)) frameError = error;
              },
            ),
          );
        }
        if (needsVideo && frameError != null) throw frameError!;
        final values = await startup.run(
          Future.wait([
            platform.getProperty('time-pos', waitForInitialization: false),
            platform.getProperty('seeking', waitForInitialization: false),
            platform.getProperty('aid', waitForInitialization: false),
            platform.getProperty(
              'audio-params/samplerate',
              waitForInitialization: false,
            ),
            if (needsVideo)
              platform.getProperty('vid', waitForInitialization: false),
            if (needsVideo)
              platform.getProperty(
                'video-out-params/w',
                waitForInitialization: false,
              ),
          ]),
        );
        startup.check();
        if (_players[textureId] != player) break;
        // Resample when a page appeared/disappeared during the native reads.
        if (needsVideo != videoRequired()) continue;
        final seconds = double.tryParse(values[0]);
        final expectsAudio =
            _decoderFallbackStates[textureId]?.externalAudioUri?.isNotEmpty ==
                true ||
            _decoderFallbackStates[textureId]?.knownAudioOnly == true;
        final audioReady =
            !expectsAudio ||
            values[2].isNotEmpty &&
                values[2] != 'no' &&
                (int.tryParse(values[3]) ?? 0) > 0;
        final videoReady =
            !needsVideo ||
            rendered &&
                _hasVideoOutputFor(textureId) &&
                _outputStates[textureId]?.value.generation ==
                    outputGeneration &&
                values[4].isNotEmpty &&
                values[4] != 'no' &&
                (int.tryParse(values[5]) ?? 0) > 0;
        if (seconds != null &&
            seconds.isFinite &&
            audioReady &&
            videoReady &&
            values[1].isNotEmpty &&
            NativeVideoPlayerMediaKit.positionHasSettled(
              actual: Duration(microseconds: (seconds * 1000000).round()),
              target: startup.target,
              seeking: values[1] != 'no',
            )) {
          startup.record(
            needsVideo
                ? 'native target frame prepared'
                : 'native target audio prepared',
          );
          return;
        }
        await startup.run(
          Future<void>.delayed(const Duration(milliseconds: 40)),
        );
      }
      throw const PlaybackStartupCancelled();
    }();
  }

  Future<void>? _clockStartedFor(
    int textureId,
    PlaybackStartupContext startup,
    Duration baseline, {
    required bool Function() shouldWait,
  }) {
    final player = _players[textureId];
    final platform = player?.platform;
    if (player == null || platform is! NativePlayer) return null;
    return () async {
      while (_players[textureId] == player && shouldWait()) {
        startup.check();
        final values = await startup.run(
          Future.wait([
            platform.getProperty('time-pos', waitForInitialization: false),
            platform.getProperty('pause', waitForInitialization: false),
            platform.getProperty('seeking', waitForInitialization: false),
          ]),
        );
        if (!shouldWait()) return;
        final seconds = double.tryParse(values[0]);
        if (seconds != null &&
            seconds.isFinite &&
            values[1] == 'no' &&
            values[2] == 'no' &&
            Duration(microseconds: (seconds * 1000000).round()) - baseline >=
                const Duration(milliseconds: 30)) {
          startup.record('native playback clock advanced');
          return;
        }
        await startup.run(
          Future<void>.delayed(const Duration(milliseconds: 40)),
        );
      }
      if (_players[textureId] != player) throw const PlaybackStartupCancelled();
    }();
  }

  Future<void>? _frameAtPositionFor(
    int textureId,
    BilibiliStartupContext startup, {
    Duration Function()? target,
  }) {
    final player = _players[textureId];
    final output = _videoControllers[textureId];
    if (player == null || output == null) return null;
    return () async {
      // A texture can render before the resume seek finishes. First-frame
      // alone is only a renderer prerequisite, never a positioning signal.
      await startup.run(output.waitUntilFirstFrameRendered);
      startup.record('texture first frame');
      while (_players[textureId] == player &&
          _videoControllers[textureId] == output) {
        startup.check();
        // A recovery seek can start a second readiness check. The older
        // checker must stop once that same startup has been confirmed.
        if (startup.isReady) return;
        final platform = player.platform;
        final outputGeneration = _outputStates[textureId]?.value.generation;
        final selectedVideo = platform is NativePlayer
            ? await platform.getProperty('vid', waitForInitialization: false)
            : player.state.track.video.id;
        final outputWidth = platform is NativePlayer
            ? int.tryParse(
                    await platform.getProperty(
                      'video-out-params/w',
                      waitForInitialization: false,
                    ),
                  ) ??
                  0
            : 0;
        final settled = await startup.run(
          _positionSettledFor(textureId, target?.call() ?? startup.target) ??
              Future.value(false),
        );
        if (selectedVideo.isNotEmpty &&
            selectedVideo != 'no' &&
            outputWidth > 0 &&
            _hasVideoOutputFor(textureId) &&
            _outputStates[textureId]?.value.generation == outputGeneration &&
            _players[textureId] == player &&
            _videoControllers[textureId] == output &&
            settled) {
          startup.record('native target settled');
          return;
        }
        await startup.run(
          Future<void>.delayed(const Duration(milliseconds: 40)),
        );
      }
      throw const BilibiliStartupCancelled();
    }();
  }

  bool _hasVideoOutputFor(int textureId) {
    if (_delegatedTextureIds.containsKey(textureId)) return true;
    if (_retiringPlayers.contains(textureId)) return false;
    return _outputStates[textureId]?.value.available ??
        _readyVideoOutputs.contains(textureId);
  }

  void _observeOutput(int textureId, PlatformVideoController output) {
    _outputListeners.remove(textureId)?.call();
    final state = _outputStates.putIfAbsent(
      textureId,
      () => ValueNotifier(
        const VideoOutputState(generation: 0, available: false),
      ),
    );
    final nativeState = output.outputState;
    void update() {
      if (_retiringPlayers.contains(textureId) ||
          _outputStates[textureId] != state) {
        return;
      }
      state.value =
          nativeState?.value ??
          const VideoOutputState(generation: 0, available: true);
    }

    nativeState?.addListener(update);
    _outputListeners[textureId] = () => nativeState?.removeListener(update);
    update();
  }

  Future<bool> _waitForAvailableOutput(int textureId) {
    if (_hasVideoOutputFor(textureId)) return Future.value(true);
    final state = _outputStates[textureId];
    if (state == null || _retiringPlayers.contains(textureId)) {
      return Future.value(false);
    }
    final pending = _outputWaiters[textureId];
    if (pending != null) return pending.future;
    final completer = Completer<bool>();
    void update() {
      if (state.value.available && !completer.isCompleted) {
        completer.complete(true);
      }
    }

    state.addListener(update);
    _outputWaiters[textureId] = completer;
    return completer.future.whenComplete(() {
      state.removeListener(update);
      if (_outputWaiters[textureId] == completer) {
        _outputWaiters.remove(textureId);
      }
    });
  }

  VideoController _createVideoController(Player player) {
    final operatingSystem = UniversalPlatform.operatingSystem;
    final useHardwareDecoding = SettingsService().useHardwareVideoDecoding;
    final hasDri = operatingSystem == 'linux'
        ? NativeVideoPlayerMediaKit.linuxHasDriDevices()
        : null;
    final enableHardwareOutput =
        NativeVideoPlayerMediaKit.shouldEnableHardwareVideoOutput(
          operatingSystem,
          hasDriDevices: hasDri,
        );
    final controller = VideoController(
      player,
      configuration: VideoControllerConfiguration(
        hwdec: NativeVideoPlayerMediaKit.decoderOptionFor(
          useHardwareDecoding: useHardwareDecoding && enableHardwareOutput,
          operatingSystem: operatingSystem,
        ),
        // GPU texture VO is independent of decoder choice. Force software on
        // Linux (and when /dev/dri is absent) to avoid solid/blue frames.
        enableHardwareAcceleration: enableHardwareOutput,
      ),
    );
    // media_kit creates its native output in a post-frame callback. A paused
    // desktop can otherwise await that output with no frame ever scheduled.
    WidgetsBinding.instance.ensureVisualUpdate();
    return controller;
  }

  void _observeFirstFrame(
    int textureId,
    VideoController videoController,
    _DecoderFallbackState state,
  ) {
    unawaited(() async {
      try {
        await videoController.waitUntilFirstFrameRendered;
        if (_decoderFallbackStates[textureId] == state &&
            _videoControllers[textureId] == videoController) {
          state.markFirstFrameRendered();
        }
      } catch (error) {
        debugPrint('MediaKit first-frame observer failed: $error');
      }
    }());
  }

  Future<bool> _attachVideoOutputFor(int textureId) {
    if (_delegatedTextureIds.containsKey(textureId)) {
      return Future<bool>.value(true);
    }
    if (_hasVideoOutputFor(textureId)) {
      return Future<bool>.value(true);
    }
    final pending = _videoOutputAttachments[textureId];
    if (pending != null) return pending;

    late final Future<bool> attachment;
    attachment =
        () async {
          final player = _players[textureId];
          final state = _decoderFallbackStates[textureId];
          if (player == null ||
              state == null ||
              state.knownAudioOnly ||
              _retiringPlayers.contains(textureId)) {
            return false;
          }

          VideoController? videoController;
          try {
            videoController =
                _videoControllers[textureId] ?? _createVideoController(player);
            _videoControllers[textureId] = videoController;
            state.videoOutputDeferred = false;
            _observeFirstFrame(textureId, videoController, state);
            // Do not time this out here. Android may suspend Flutter texture
            // work while the app is backgrounded. Keeping this Future alive
            // lets the exact same Player finish attaching its output as soon
            // as the engine can service textures, without reopening media.
            final output = await videoController.platform.future;
            if (_players[textureId] != player ||
                _videoControllers[textureId] != videoController ||
                _retiringPlayers.contains(textureId)) {
              return false;
            }
            _observeOutput(textureId, output);
            _readyVideoOutputs.add(textureId);
            if (!_hasVideoOutputFor(textureId)) await output.recoverOutput();
            final sourceSize = _sourceVideoSizes[textureId];
            if (sourceSize != null) {
              _scheduleAdaptiveOutputResize(textureId, sourceSize);
            }
            return await _waitForAvailableOutput(textureId);
          } catch (error) {
            if (videoController != null &&
                _videoControllers[textureId] == videoController) {
              _videoControllers.remove(textureId);
            }
            _readyVideoOutputs.remove(textureId);
            if (_decoderFallbackStates[textureId] == state) {
              state.videoOutputDeferred = true;
            }
            debugPrint('MediaKit video-output attachment failed: $error');
            return false;
          }
        }().whenComplete(() {
          if (identical(_videoOutputAttachments[textureId], attachment)) {
            _videoOutputAttachments.remove(textureId);
          }
        });
    _videoOutputAttachments[textureId] = attachment;
    return attachment;
  }

  Future<bool>? _playbackReadyFor(int textureId) {
    final player = _players[textureId];
    if (player == null) return null;
    return () async {
      final initialPosition = player.state.position;
      while (_players[textureId] == player) {
        final state = player.state;
        final positionAdvanced =
            (state.position.inMilliseconds - initialPosition.inMilliseconds)
                .abs() >=
            30;
        final bufferedAhead =
            state.buffer.inMilliseconds > state.position.inMilliseconds + 30;
        if (NativeVideoPlayerMediaKit.isBackgroundPlaybackClockReady(
          playing: state.playing,
          completed: state.completed,
          positionAdvanced: positionAdvanced,
          bufferedAhead: bufferedAhead,
        )) {
          return true;
        }
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      return false;
    }();
  }

  Future<bool> _setExternalVideoTrackEnabledFor(
    int textureId, {
    required bool enabled,
    bool keepPlaying = false,
    bool keepPaused = false,
  }) async {
    final player = _players[textureId];
    final state = _decoderFallbackStates[textureId];
    if (player == null ||
        state?.externalAudioUri?.isNotEmpty != true ||
        _retiringPlayers.contains(textureId) ||
        _invalidNativeCommands.contains(textureId)) {
      return false;
    }
    _externalVideoTrackDesired[textureId] = enabled;
    final intentRevision = _transportIntentRevisions[textureId];
    final previous = _externalVideoTrackCommands[textureId];
    bool current() =>
        _players[textureId] == player &&
        _decoderFallbackStates[textureId] == state &&
        !_retiringPlayers.contains(textureId) &&
        !_invalidNativeCommands.contains(textureId);
    bool sameIntent() =>
        current() && _transportIntentRevisions[textureId] == intentRevision;
    late final Future<void> command;
    final work = (previous ?? Future<void>.value()).catchError((_) {}).then((
      _,
    ) async {
      if (!current()) return;
      final desired = _externalVideoTrackDesired[textureId] ?? true;
      final platform = player.platform;
      final selected = platform is NativePlayer
          ? await platform.getProperty('vid', waitForInitialization: false)
          : player.state.track.video.id;
      if (!current()) return;
      if (!desired) {
        if (selected != 'no' && selected != 'auto' && selected.isNotEmpty) {
          _suspendedExternalVideoTracks[textureId] = VideoTrack(
            selected,
            null,
            null,
          );
        }
        state!.externalVideoTrackSuspended = true;
        if (selected != 'no') {
          if (platform is NativePlayer) {
            await platform.setProperty(
              'vid',
              'no',
              waitForInitialization: false,
            );
          } else {
            await player.setVideoTrack(VideoTrack.no());
          }
        }
        return;
      }
      state!.externalVideoTrackSuspended = false;
      final target =
          _suspendedExternalVideoTracks.remove(textureId) ??
          NativeVideoPlayerMediaKit.firstUsableVideoTrack(
            player.state.tracks,
          ) ??
          VideoTrack.auto();
      if (selected == target.id) return;
      final resumePosition =
          _audioPauseRepairs[textureId]?.pausedPosition ??
          player.state.position;
      final resumePlaying =
          NativeVideoPlayerMediaKit.shouldResumeExternalVideoTrack(
            playing: player.state.playing,
            keepPlaying: keepPlaying,
            keepPaused: keepPaused,
          );
      Future<void> select() async {
        if (!current() || _externalVideoTrackDesired[textureId] != true) return;
        if (platform is NativePlayer) {
          await platform.setProperty(
            'vid',
            target.id,
            waitForInitialization: false,
          );
        } else {
          await player.setVideoTrack(target);
        }
      }

      if (resumePlaying && platform is NativePlayer) {
        _temporaryVideoJoins.add(textureId);
        try {
          await TemporaryPlaybackProperties(
            read: (key) =>
                platform.getProperty(key, waitForInitialization: false),
            write: (key, value) =>
                platform.setProperty(key, value, waitForInitialization: false),
            isCurrent: current,
            latestPolicy: () {
              final style = _streamingSeekStyles[textureId];
              if (style == null) return {};
              return {
                'hr-seek': SubtitleHopSeekPolicy.hrSeekFor(style),
                'cache-pause-wait':
                    SubtitleHopSeekPolicy.cachePauseWaitSecondsFor(style),
                'cache-pause-initial': 'no',
              };
            },
          ).run(const {
            'cache-pause': 'no',
            'cache-pause-initial': 'no',
            'cache-pause-wait': '0',
            'hr-seek': 'yes',
            'hr-seek-framedrop': 'yes',
          }, select);
        } finally {
          _temporaryVideoJoins.remove(textureId);
        }
      } else {
        await select();
      }
      if (!sameIntent() || _externalVideoTrackDesired[textureId] != true) {
        return;
      }
      // The healthy audio clock never receives an extra seek. Repair only a
      // confirmed reset, and never over a newer user seek/pause command.
      final repairReset =
          NativeVideoPlayerMediaKit.shouldRepairClockAfterExternalVideoTrackEnable(
            clockBefore: resumePosition,
            clockAfter: player.state.position,
          );
      if ((!resumePlaying && resumePosition > Duration.zero) || repairReset) {
        await _seekNativePlayer(player, resumePosition);
      }
      if (sameIntent() &&
          resumePlaying &&
          !player.state.playing &&
          _externalVideoTrackDesired[textureId] == true) {
        await _audioPauseRepairFor(textureId, player).play();
      }
    });
    command = work
        .timeout(
          const Duration(seconds: 8),
          onTimeout: () {
            // Poison this command lane. A retry must retire this transport instead
            // of joining the same stuck native work again.
            _invalidNativeCommands.add(textureId);
            throw TimeoutException('视频轨恢复超时');
          },
        )
        .whenComplete(() {
          if (identical(_externalVideoTrackCommands[textureId], command)) {
            _externalVideoTrackCommands.remove(textureId);
          }
        });
    _externalVideoTrackCommands[textureId] = command;
    try {
      await command;
      return current() && _externalVideoTrackDesired[textureId] == enabled;
    } catch (error) {
      debugPrint('MediaKit external video-track switch failed: $error');
      if (_players[textureId] == player &&
          _decoderFallbackStates[textureId] == state &&
          !_retiringPlayers.contains(textureId)) {
        _invalidNativeCommands.add(textureId);
        final hint = _healthHints[textureId];
        if (hint != null) hint.value++;
      }
      return false;
    }
  }

  Future<bool> _recoverVideoOutputFor(int textureId) async {
    if (!UniversalPlatform.isAndroid) return false;
    final state = _decoderFallbackStates[textureId];
    final player = _players[textureId];
    if (state == null || player == null) return false;
    final existing = state.recovery;
    if (existing != null) return existing;

    final recovery = () async {
      final resumePosition =
          _audioPauseRepairs[player.hashCode]?.pausedPosition ??
          player.state.position;
      final resumePlaying = player.state.playing;
      try {
        final platform = player.platform;
        if (platform is! NativePlayer) return false;
        state.fallbackAttempted = true;
        await platform.setProperty('hwdec', 'no', waitForInitialization: false);
        if (_decoderFallbackStates[textureId] != state ||
            _players[textureId] != player) {
          return false;
        }
        await _openMediaWithExternalAudio(
          player,
          state.media,
          externalAudioUri: state.externalAudioUri,
          knownAudioOnly: state.knownAudioOnly,
        );
        await _disableSubtitleOutput(player);
        if (resumePosition > Duration.zero &&
            (player.state.duration <= Duration.zero ||
                resumePosition < player.state.duration)) {
          await _seekNativePlayer(player, resumePosition);
        }
        if (resumePlaying) {
          await _audioPauseRepairFor(textureId, player).play();
        }
        return true;
      } catch (error) {
        debugPrint('MediaKit video-output recovery failed: $error');
        return false;
      }
    }();
    state.recovery = recovery;
    try {
      return await recovery;
    } finally {
      if (identical(state.recovery, recovery)) state.recovery = null;
    }
  }

  void _cancelPendingRateChange(int textureId) {
    if (_delegatedTextureIds.containsKey(textureId)) return;
    _rateRequestEpochs[textureId] = (_rateRequestEpochs[textureId] ?? 0) + 1;
  }

  @override
  Future<void> init() async {
    _delegatedTextureIds.clear();
    _nextDelegatedTextureId = -2;
    if (UniversalPlatform.isAndroid) {
      await _platformFallback.init();
    }
    for (final textureId in _players.keys.toList()) {
      await dispose(textureId);
    }

    _players.clear();
    _audioPauseRepairs.clear();
    _completers.clear();
    _videoControllers.clear();
    _readyVideoOutputs.clear();
    _videoOutputAttachments.clear();
    _ambientCaptureQueues.clear();
    _externalVideoTrackCommands.clear();
    _externalVideoTrackDesired.clear();
    _suspendedExternalVideoTracks.clear();
    _streamControllers.clear();
    _rateStreamControllers.clear();
    _streamSubscriptions.clear();
    _rateRequestEpochs.clear();
    _rateCommands.clear();
    _sourceVideoSizes.clear();
    _displayVideoSizes.clear();
    _outputVideoSizes.clear();
    _resizeEpochs.clear();
    _frameDropModes.clear();
    for (final state in _decoderFallbackStates.values) {
      state.dispose();
    }
    _decoderFallbackStates.clear();
  }

  @override
  Future<void> dispose(int textureId) async {
    _retiringPlayers.add(textureId);
    _videoControllers[textureId]?.cancelPendingCreation();
    _creationReady.remove(textureId);
    _initializationNotifications.remove(textureId);
    _outputListeners.remove(textureId)?.call();
    final outputState = _outputStates.remove(textureId);
    if (outputState != null) {
      outputState.value = VideoOutputState(
        generation: outputState.value.generation + 1,
        available: false,
      );
    }
    final outputWaiter = _outputWaiters.remove(textureId);
    if (outputWaiter != null && !outputWaiter.isCompleted) {
      outputWaiter.complete(false);
    }
    scheduleMicrotask(() => outputState?.dispose());
    _videoOutputAttachments.remove(textureId);
    _healthHints.remove(textureId)?.dispose();
    _decoderFallbackStates.remove(textureId)?.dispose();
    _cancelPendingRateChange(textureId);
    final delegatedTextureId = _delegatedTextureIds.remove(textureId);
    if (delegatedTextureId != null) {
      await _platformFallback.dispose(delegatedTextureId);
      _retiringPlayers.remove(textureId);
      return;
    }
    // Keep the disposed gate registered while track/rate work drains, so a
    // late native callback cannot create another transport for this player.
    final player = _players[textureId];
    if (player != null) {
      await _audioPauseRepairFor(textureId, player).dispose();
    }
    _displayVideoSizes.remove(textureId)?.dispose();
    _cancelPendingRateChange(textureId);
    _decoderFallbackStates.remove(textureId)?.dispose();
    _ambientCaptureQueues.remove(textureId);
    _externalVideoTrackDesired.remove(textureId);
    _suspendedExternalVideoTracks.remove(textureId);
    final videoTrackCommand = _externalVideoTrackCommands.remove(textureId);
    try {
      await videoTrackCommand;
    } catch (_) {}
    try {
      await _rateCommands[textureId];
    } catch (_) {}
    await _players[textureId]?.dispose();

    await _streamControllers[textureId]?.close();
    await _rateStreamControllers[textureId]?.close();
    await Future.wait(
      _streamSubscriptions[textureId]?.map((e) => e.cancel()) ?? [],
    );

    _players.remove(textureId);
    _audioPauseRepairs.remove(textureId);
    _completers.remove(textureId);
    _videoControllers.remove(textureId);
    _readyVideoOutputs.remove(textureId);
    _videoOutputAttachments.remove(textureId);
    _streamControllers.remove(textureId);
    _rateStreamControllers.remove(textureId);
    _streamSubscriptions.remove(textureId);
    _rateRequestEpochs.remove(textureId);
    _rateCommands.remove(textureId);
    _sourceVideoSizes.remove(textureId);
    _outputVideoSizes.remove(textureId);
    _resizeEpochs.remove(textureId);
    _frameDropModes.remove(textureId);
    _streamingBufferPlayers.remove(textureId);
    _streamingSeekStyles.remove(textureId);
    _retiringPlayers.remove(textureId);
    _invalidNativeCommands.remove(textureId);
    _transportIntentRevisions.remove(textureId);
  }

  @override
  Future<int?> create(DataSource dataSource) async {
    if (NativeVideoPlayerMediaKit.shouldUsePlatformPlayer(
      sourceType: dataSource.sourceType,
      operatingSystem: UniversalPlatform.operatingSystem,
      resource: dataSource.uri,
    )) {
      // The adapter itself still implements the legacy create contract used by
      // the current video_player package, so delegation must preserve it.
      // ignore: deprecated_member_use
      final delegatedTextureId = await _platformFallback.create(dataSource);
      if (delegatedTextureId == null) return null;
      return _exposeDelegatedTextureId(delegatedTextureId);
    }

    final player = Player(
      configuration: const PlayerConfiguration(
        osc: false,
        libass: false,
        pitch: false,
      ),
    );
    final completer = Completer<void>();
    final useHardwareDecoding = SettingsService().useHardwareVideoDecoding;
    final streamController = StreamController<VideoEvent>();
    final rateStreamController = StreamController<double>.broadcast(sync: true);
    final streamSubscriptions = <StreamSubscription>[];

    final textureId = player.hashCode;

    _players[textureId] = player;
    _healthHints[textureId] = ValueNotifier(0);
    _outputStates[textureId] = ValueNotifier(
      const VideoOutputState(generation: 0, available: false),
    );
    _displayVideoSizes[textureId] = ValueNotifier<Size?>(null);
    _completers[textureId] = completer;
    _streamControllers[textureId] = streamController;
    _rateStreamControllers[textureId] = rateStreamController;
    _streamSubscriptions[textureId] = streamSubscriptions;

    // Expose the registered id before awaiting native output/media work.
    // Initialized is gated below until setup has finished; cancellation can
    // now dispose a candidate whose Surface creation never completes.
    unawaited(() async {
      try {
        final String resource;
        final Map<String, String> httpHeaders = Map<String, String>.from(
          dataSource.httpHeaders,
        );
        final podcastProfile = httpHeaders.remove(
          PodcastPlaybackPolicy.streamHeader,
        );
        final externalAudioUri = httpHeaders.remove(
          NativeVideoPlayerMediaKit.externalAudioSourceHeader,
        );
        final fastStreamStart =
            httpHeaders.remove(
              NativeVideoPlayerMediaKit.fastStreamStartHeader,
            ) ==
            '1';
        final audioPrimary =
            httpHeaders.remove(
              NativeVideoPlayerMediaKit.audioPrimaryStreamHeader,
            ) ==
            '1';
        final deferVideo =
            httpHeaders.remove(
              NativeVideoPlayerMediaKit.deferVideoStreamHeader,
            ) ==
            '1';
        final startMs = int.tryParse(
          httpHeaders.remove(NativeVideoPlayerMediaKit.startPositionMsHeader) ??
              '',
        );
        final cloudProfile = httpHeaders.remove(
          NativeVideoPlayerMediaKit.cloudDriveProfileHeader,
        );
        if (cloudProfile == 'hls') {
          httpHeaders[cloudDriveNativeTimelineHeader] = '1';
        }

        switch (dataSource.sourceType) {
          case DataSourceType.asset:
            final String? asset;
            if (dataSource.package == null) {
              asset = dataSource.asset;
            } else {
              asset = 'packages/${dataSource.package}/${dataSource.asset}';
            }
            resource = 'asset:///$asset';
            break;
          case DataSourceType.network:
          case DataSourceType.file:
          case DataSourceType.contentUri:
            if (dataSource.uri == null) {
              throw ArgumentError('uri must not be null');
            }
            resource = dataSource.uri!;
            break;
        }

        final knownAudioOnly =
            podcastProfile == 'audio' ||
            audioPrimary ||
            NativeVideoPlayerMediaKit.isKnownAudioOnlyResource(resource);
        final createVideoOutput =
            NativeVideoPlayerMediaKit.shouldCreateVideoOutput(
              resource: resource,
              operatingSystem: UniversalPlatform.operatingSystem,
              lifecycleState: WidgetsBinding.instance.lifecycleState,
              // Audio-only HLS and opaque relay URLs need not have an audio
              // extension. Honor the same explicit classification used by the
              // decoder so these sessions never allocate a video surface.
              knownAudioOnly: knownAudioOnly,
            );
        final videoOutputDeferred = !createVideoOutput;
        final VideoController? videoController = createVideoOutput
            ? _createVideoController(player)
            : null;
        if (videoController != null) {
          _videoControllers[textureId] = videoController;
        }

        final media = Media(resource, httpHeaders: httpHeaders);
        final decoderFallbackState = _DecoderFallbackState(
          media: media,
          externalAudioUri: externalAudioUri,
          knownAudioOnly: knownAudioOnly,
          enabled:
              UniversalPlatform.isAndroid &&
              useHardwareDecoding &&
              !knownAudioOnly,
          videoOutputDeferred: videoOutputDeferred,
        );
        _decoderFallbackStates[textureId] = decoderFallbackState;
        if (deferVideo) {
          decoderFallbackState.externalVideoTrackSuspended = true;
          _externalVideoTrackDesired[textureId] = false;
        }
        _initialize(textureId);

        // VideoController initialization is deliberately asynchronous and the
        // desktop media_kit plugin overwrites video-sync/video-timing-offset while
        // creating its native render context. Wait for that work before installing
        // our final clock configuration. Windows intentionally keeps the native
        // zero-lookahead policy so render-ahead cannot hold its shared texture
        // mutex while Flutter is trying to animate the surrounding interface.
        if (videoController != null) {
          final output = await videoController.platform.future;
          if (_players[textureId] != player ||
              _retiringPlayers.contains(textureId)) {
            return;
          }
          _observeOutput(textureId, output);
          _readyVideoOutputs.add(textureId);
        }

        // Linux hosts without a sound card must keep video playing (silent).
        // Prefer libmpv's null AO fallback before opening media so AO init
        // failure does not abort the graph; the error listener still ignores
        // residual "no sound" logs as non-fatal.
        if (UniversalPlatform.isLinux) {
          final platform = player.platform;
          if (platform is NativePlayer) {
            await platform.setProperty(
              'audio-fallback-to-null',
              'yes',
              waitForInitialization: false,
            );
          }
        }

        // Install the latency, clock, and pitch pipeline before opening media so
        // the first decoded frame enters the final graph. Replacing `af` after open
        // is inaudible while paused, but still needlessly rebuilds the native graph.
        await PitchPreservingAudioPipeline.configure(player);
        await _configureHighResolutionPlayback(player);
        if (podcastProfile != null && player.platform is NativePlayer) {
          final native = player.platform as NativePlayer;
          final options = PodcastPlaybackPolicy.nativeOptions(
            audioOnly: podcastProfile == 'audio',
          );
          for (final option in options.entries) {
            await native.setProperty(
              option.key,
              option.value,
              waitForInitialization: false,
            );
          }
        }
        if (externalAudioUri != null || audioPrimary) {
          await _configureStreamingBuffer(
            player,
            textureId,
            fastStart: fastStreamStart || audioPrimary || deferVideo,
            audioOnly: audioPrimary || knownAudioOnly,
          );
        } else if (cloudProfile == 'hls' || cloudProfile == 'progressive') {
          // A normal cloud file has neither external audio nor audioPrimary.
          // Those flags used to be the only way into the fast-start buffer.
          await _configureCloudDrivePlayback(
            player,
            hls: cloudProfile == 'hls',
            fastStart: fastStreamStart || cloudProfile != null,
          );
        }
        if (startMs != null && startMs > 0) {
          final platform = player.platform;
          if (platform is NativePlayer) {
            // Open already parked at the resume point so initialize does not
            // fetch t=0 and then immediately throw that work away with a seek.
            await platform.setProperty(
              'start',
              (startMs / 1000).toStringAsFixed(3),
              waitForInitialization: false,
            );
          }
        }
        await _openMediaWithExternalAudio(
          player,
          media,
          externalAudioUri: externalAudioUri,
          knownAudioOnly: knownAudioOnly,
          startWithoutVideo: audioPrimary || deferVideo,
          startPosition: startMs != null && startMs > 0
              ? Duration(milliseconds: startMs)
              : Duration.zero,
          // Selecting the video track after open restarts decode at t=0.
          // Separated Bilibili audio needs that re-park. A cloud file opened
          // with start= does not.
          reselectPrimaryVideo:
              externalAudioUri != null ||
              cloudProfile != 'hls' && cloudProfile != 'progressive',
        );
        await _disableSubtitleOutput(player);
        if (knownAudioOnly) {
          // Keep libmpv's clock explicitly audio-only even if a container exposes
          // attached artwork as a selectable image track.
          await _disableAlbumArtVideoOutput(player);
        }

        if (videoController != null) {
          _observeFirstFrame(textureId, videoController, decoderFallbackState);
        }

        if (_players[textureId] != player ||
            _retiringPlayers.contains(textureId)) {
          return;
        }
        _creationReady.add(textureId);
        _initializationNotifications[textureId]?.call();
      } catch (error, stackTrace) {
        // video_player does not complete its internal creation barrier when a
        // platform create call throws. Return the registered id and deliver a
        // buffered platform error instead, so initialize() fails normally and
        // dispose() can reclaim the native player before a retry.
        debugPrint('MediaKit player creation failed: $error\n$stackTrace');
        if (!streamController.isClosed) {
          streamController.addError(
            error is PlatformException
                ? error
                : PlatformException(
                    code: 'media_kit_create_error',
                    message: error.toString(),
                  ),
          );
        }
      }
    }());
    return textureId;
  }

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    if (NativeVideoPlayerMediaKit.shouldUsePlatformPlayer(
      sourceType: options.dataSource.sourceType,
      operatingSystem: UniversalPlatform.operatingSystem,
      resource: options.dataSource.uri,
    )) {
      final delegatedTextureId = await _platformFallback.createWithOptions(
        options,
      );
      if (delegatedTextureId == null) return null;
      return _exposeDelegatedTextureId(delegatedTextureId);
    }
    // ignore: deprecated_member_use_from_same_package
    return create(options.dataSource);
  }

  int _exposeDelegatedTextureId(int delegatedTextureId) {
    final textureId = _nextDelegatedTextureId--;
    _delegatedTextureIds[textureId] = delegatedTextureId;
    return textureId;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int textureId) {
    final delegatedTextureId = _delegatedTextureIds[textureId];
    if (delegatedTextureId != null) {
      return _platformFallback.videoEventsFor(delegatedTextureId);
    }
    if (_streamControllers[textureId] == null) {
      throw StateError(
        'VideoPlayer for textureId $textureId is not found, Check if its disposed.',
      );
    }
    return _streamControllers[textureId]!.stream;
  }

  @override
  Future<void> setLooping(int textureId, bool looping) async {
    final delegatedTextureId = _delegatedTextureIds[textureId];
    if (delegatedTextureId != null) {
      return _platformFallback.setLooping(delegatedTextureId, looping);
    }
    final playlistMode = looping ? PlaylistMode.single : PlaylistMode.none;
    return _players[textureId]?.setPlaylistMode(playlistMode);
  }

  @override
  Future<void> play(int textureId) async {
    _transportIntentRevisions[textureId] =
        (_transportIntentRevisions[textureId] ?? 0) + 1;
    final delegatedTextureId = _delegatedTextureIds[textureId];
    if (delegatedTextureId != null) {
      return _platformFallback.play(delegatedTextureId);
    }
    final player = _players[textureId];
    if (player == null) return;
    return _audioPauseRepairFor(textureId, player).play();
  }

  @override
  Future<void> pause(int textureId) async {
    _transportIntentRevisions[textureId] =
        (_transportIntentRevisions[textureId] ?? 0) + 1;
    final delegatedTextureId = _delegatedTextureIds[textureId];
    if (delegatedTextureId != null) {
      return _platformFallback.pause(delegatedTextureId);
    }
    final player = _players[textureId];
    if (player == null) return;
    return _audioPauseRepairFor(textureId, player).pause();
  }

  NativeAudioPauseRepair _audioPauseRepairFor(int textureId, Player player) =>
      _audioPauseRepairs.putIfAbsent(
        textureId,
        () => NativeAudioPauseRepair.forPlayer(
          player,
          isCurrent: () => identical(_players[textureId], player),
        ),
      );

  Future<void> _seekNativePlayer(Player player, Duration position) {
    _audioPauseRepairs[player.hashCode]?.invalidatePosition();
    return player.seek(position);
  }

  @override
  Future<void> setVolume(int textureId, double volume) async {
    final delegatedTextureId = _delegatedTextureIds[textureId];
    if (delegatedTextureId != null) {
      return _platformFallback.setVolume(delegatedTextureId, volume);
    }
    return _players[textureId]?.setVolume(volume * 100);
  }

  @override
  Future<void> seekTo(int textureId, Duration position) async {
    _transportIntentRevisions[textureId] =
        (_transportIntentRevisions[textureId] ?? 0) + 1;
    final delegatedTextureId = _delegatedTextureIds[textureId];
    if (delegatedTextureId != null) {
      return _platformFallback.seekTo(delegatedTextureId, position);
    }
    final player = _players[textureId];
    if (player == null) return;
    return _audioPauseRepairFor(
      textureId,
      player,
    ).seek(() => player.seek(position));
  }

  Future<void> _prepareSeekStyle(
    int textureId, {
    required StreamingSeekStyle style,
  }) async {
    if (!_streamingBufferPlayers.contains(textureId)) return;
    final player = _players[textureId];
    final platform = player?.platform;
    if (platform is! NativePlayer) return;
    if (_streamingSeekStyles[textureId] == style &&
        !_temporaryVideoJoins.contains(textureId)) {
      return;
    }
    _streamingSeekStyles[textureId] = style;
    await Future.wait<void>([
      platform.setProperty(
        'hr-seek',
        SubtitleHopSeekPolicy.hrSeekFor(style),
        waitForInitialization: false,
      ),
      platform.setProperty(
        'cache-pause-wait',
        SubtitleHopSeekPolicy.cachePauseWaitSecondsFor(style),
        waitForInitialization: false,
      ),
      platform.setProperty(
        'cache-pause-initial',
        'no',
        waitForInitialization: false,
      ),
    ]);
  }

  @override
  Future<void> setPlaybackSpeed(int textureId, double speed) {
    final delegatedTextureId = _delegatedTextureIds[textureId];
    if (delegatedTextureId != null) {
      return _platformFallback.setPlaybackSpeed(delegatedTextureId, speed);
    }
    final player = _players[textureId];
    if (player == null || !speed.isFinite || speed <= 0) {
      return Future<void>.value();
    }

    final epoch = (_rateRequestEpochs[textureId] ?? 0) + 1;
    _rateRequestEpochs[textureId] = epoch;
    final previous = _rateCommands[textureId] ?? Future<void>.value();
    final command = () async {
      try {
        await previous;
      } catch (_) {
        // A failed older request must not suppress the latest requested rate.
      }
      if (_rateRequestEpochs[textureId] != epoch ||
          _players[textureId] != player) {
        return;
      }

      // scaletempo2 already performs its own 12 ms WSOLA overlap/crossfade on
      // the native audio thread. Sending an application-side staircase here
      // changes the clock many times inside one output buffer and causes the
      // very discontinuity the ramp was intended to hide. Production players
      // likewise set one target and let their realtime audio processor bridge
      // the boundary.
      await player.setRate(speed);
      if (_players[textureId] != player) return;

      final controller = _rateStreamControllers[textureId];
      if (controller != null && !controller.isClosed) controller.add(speed);
    }();

    late final Future<void> trackedCommand;
    trackedCommand = command.whenComplete(() {
      if (identical(_rateCommands[textureId], trackedCommand)) {
        _rateCommands.remove(textureId);
      }
    });
    _rateCommands[textureId] = trackedCommand;
    return trackedCommand;
  }

  @override
  Future<Duration> getPosition(int textureId) async {
    final delegatedTextureId = _delegatedTextureIds[textureId];
    if (delegatedTextureId != null) {
      return _platformFallback.getPosition(delegatedTextureId);
    }
    return _audioPauseRepairs[textureId]?.pausedPosition ??
        _players[textureId]?.platform?.state.position ??
        Duration.zero;
  }

  @override
  Widget buildView(int textureId) {
    final delegatedTextureId = _delegatedTextureIds[textureId];
    if (delegatedTextureId != null) {
      // ignore: deprecated_member_use
      return _platformFallback.buildView(delegatedTextureId);
    }
    if (_videoControllers[textureId] == null ||
        _displayVideoSizes[textureId] == null ||
        _retiringPlayers.contains(textureId)) {
      // build() must not throw: a disposed id becomes a full-screen white
      // ErrorWidget in release. A black frame is the placeholder until the
      // page drops the stale controller.
      return const ColoredBox(color: Color(0xFF000000));
    }
    return ValueListenableBuilder<Size?>(
      valueListenable: _displayVideoSizes[textureId]!,
      builder: (context, size, _) => Video(
        key: ValueKey(_videoControllers[textureId]!),
        controller: _videoControllers[textureId]!,
        // Use presentation dimensions rather than rounded/padded texture sizes.
        // Containment also protects callers while their layout catches up with
        // late video metadata; filling that stale viewport stretches the image.
        aspectRatio: size?.aspectRatio,
        fit: BoxFit.contain,
        wakelock: false,
        controls: NoVideoControls,
        fill: const Color(0x00000000),
        pauseUponEnteringBackgroundMode: false,
        resumeUponEnteringForegroundMode: false,
      ),
    );
  }

  @override
  Widget buildViewWithOptions(VideoViewOptions options) {
    final delegatedTextureId = _delegatedTextureIds[options.playerId];
    if (delegatedTextureId != null) {
      return _platformFallback.buildViewWithOptions(
        VideoViewOptions(playerId: delegatedTextureId),
      );
    }
    // ignore: deprecated_member_use_from_same_package
    return buildView(options.playerId);
  }

  @override
  Future<void> setPreventsDisplaySleepDuringVideoPlayback(
    int textureId,
    bool preventsDisplaySleepDuringVideoPlayback,
  ) {
    final delegatedTextureId = _delegatedTextureIds[textureId];
    if (delegatedTextureId != null) {
      return _platformFallback.setPreventsDisplaySleepDuringVideoPlayback(
        delegatedTextureId,
        preventsDisplaySleepDuringVideoPlayback,
      );
    }
    return Future<void>.value();
  }

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) {
    // Android ExoPlayer and iOS AVAudioSession both live on the stock
    // video_player plugin. Forwarding keeps mix/exclusive in sync even when
    // the visible player is actually media_kit.
    if (UniversalPlatform.isAndroid || UniversalPlatform.isIOS) {
      return _platformFallback.setMixWithOthers(mixWithOthers);
    }
    return Future<void>.value();
  }

  @override
  Future<void> setWebOptions(int textureId, VideoPlayerWebOptions options) {
    final delegatedTextureId = _delegatedTextureIds[textureId];
    if (delegatedTextureId != null) {
      return _platformFallback.setWebOptions(delegatedTextureId, options);
    }
    return Future.value();
  }

  void _initialize(int textureId) {
    if (_streamSubscriptions[textureId]?.isNotEmpty ?? false) {
      return;
    }

    final player = _players[textureId];
    final completer = _completers[textureId];
    final streamController = _streamControllers[textureId];
    final streamSubscriptions = _streamSubscriptions[textureId];

    if (player != null &&
        completer != null &&
        streamController != null &&
        streamSubscriptions != null) {
      int? width;
      int? height;
      Duration? duration;
      Timer? audioOnlyFallbackTimer;
      final decoderFallbackState = _decoderFallbackStates[textureId];

      void emitPlayerError(Object error) {
        if (streamController.isClosed ||
            (decoderFallbackState?.fatalErrorEmitted ?? false)) {
          return;
        }
        if (decoderFallbackState != null) {
          decoderFallbackState.fatalErrorEmitted = true;
          decoderFallbackState.failureTimer?.cancel();
          decoderFallbackState.failureTimer = null;
        }
        streamController.addError(
          PlatformException(code: 'media_kit_error', message: '$error'),
        );
      }

      Future<void> retryWithSoftwareDecoder() async {
        final state = decoderFallbackState;
        if (state == null ||
            _decoderFallbackStates[textureId] != state ||
            _players[textureId] != player) {
          return;
        }

        debugPrint(
          'MediaKit Android hardware decoder failed before the first frame; '
          'retrying once with software decoding: ${state.lastError}',
        );
        final recovered = await _recoverVideoOutputFor(textureId);
        if (!recovered) {
          emitPlayerError(
            state.lastError ??
                'Hardware decoder failed and software retry could not start',
          );
        }
      }

      void notify() {
        if (!_creationReady.contains(textureId) ||
            _retiringPlayers.contains(textureId)) {
          return;
        }
        if (!completer.isCompleted && !streamController.isClosed) {
          if (duration != null &&
              ((decoderFallbackState?.knownAudioOnly ?? false) ||
                  (decoderFallbackState?.videoOutputDeferred ?? false) ||
                  (decoderFallbackState?.externalVideoTrackSuspended ??
                      false))) {
            // An explicitly disabled video track cannot publish dimensions.
            // Do not spend the 1.5s ambiguity fallback waiting for that event;
            // target/audio readiness is verified separately before playback.
            width ??= 0;
            height ??= 0;
          }
          if (width != null && height != null && duration != null) {
            audioOnlyFallbackTimer?.cancel();
            streamController.add(
              VideoEvent(
                eventType: VideoEventType.initialized,
                size: Size((width ?? 0) * 1.0, (height ?? 0) * 1.0),
                duration: player.state.duration,
              ),
            );
            decoderFallbackState?.initializationErrorTimer?.cancel();
            if (decoderFallbackState != null) {
              decoderFallbackState.initializationErrorTimer = null;
            }
            completer.complete();
          }
        }
      }

      _initializationNotifications[textureId] = notify;

      void scheduleAudioOnlyFallback() {
        if (completer.isCompleted) return;
        audioOnlyFallbackTimer ??= Timer(
          const Duration(milliseconds: 1500),
          () {
            audioOnlyFallbackTimer = null;
            if (!completer.isCompleted &&
                !streamController.isClosed &&
                duration != null &&
                VideoDisplayGeometry.canInitializeWithoutVideo(
                  knownAudioOnly: decoderFallbackState?.knownAudioOnly ?? false,
                  videoIntentionallyDisabled:
                      (decoderFallbackState?.videoOutputDeferred ?? false) ||
                      (decoderFallbackState?.externalVideoTrackSuspended ??
                          false),
                  tracks: player.state.tracks,
                )) {
              // Audio files can contain embedded cover art reported as a video
              // track. Such a still image does not always emit videoParams.
              width = 0;
              height = 0;
              notify();
            }
          },
        );
      }

      streamSubscriptions.add(
        player.stream.duration.listen((event) {
          if (event > Duration.zero) {
            duration = event;
            notify();
            scheduleAudioOnlyFallback();
          }
        }),
      );
      streamSubscriptions.add(
        player.stream.videoParams.listen((event) {
          final sourceSize = VideoDisplayGeometry.fromVideoParams(event);
          if (sourceSize != null) {
            width = sourceSize.width.toInt();
            height = sourceSize.height.toInt();
            _sourceVideoSizes[textureId] = sourceSize;
            _displayVideoSizes[textureId]?.value = sourceSize;
            _scheduleAdaptiveOutputResize(textureId, sourceSize);
            unawaited(
              _configureFrameDroppingForResolution(
                textureId,
                player,
                sourceSize,
              ),
            );
            audioOnlyFallbackTimer?.cancel();
            notify();
          }
        }),
      );
      streamSubscriptions.add(
        player.stream.tracks.listen((event) {
          // media_kit prepends the synthetic "auto" and "no" entries. Audio
          // files with embedded cover art therefore look as if they contain a
          // video stream, but that still image often never emits videoParams.
          // Classify album art from track metadata immediately instead of
          // making every such audio file pay the 1.5 s safety timeout.
          final mediaVideoTracks = event.video
              .where((track) => track.id != 'auto' && track.id != 'no')
              .toList(growable: false);
          final hasAudioTrack = event.audio.any(
            (track) => track.id != 'auto' && track.id != 'no',
          );
          final hasMotionVideo = mediaVideoTracks.any(
            (track) => track.image != true && track.albumart != true,
          );
          if (hasAudioTrack && !hasMotionVideo) {
            // An audio-first track list can be incomplete while loading video.
            // Only known audio or an explicit cover track may disable video.
            if ((decoderFallbackState?.knownAudioOnly ?? false) ||
                mediaVideoTracks.isNotEmpty) {
              width = 0;
              height = 0;
              notify();
              unawaited(_disableAlbumArtVideoOutput(player));
            } else {
              scheduleAudioOnlyFallback();
            }
          }
          if (event.subtitle.length > 2) {
            unawaited(_disableSubtitleOutput(player));
          }
        }),
      );
      streamSubscriptions.add(
        player.stream.playing.listen((event) async {
          await completer.future;
          streamController.add(
            VideoEvent(
              eventType: VideoEventType.isPlayingStateUpdate,
              isPlaying: event,
            ),
          );
        }),
      );
      streamSubscriptions.add(
        player.stream.completed.listen((event) async {
          await completer.future;
          if (NativeVideoPlayerMediaKit.shouldForwardPlaybackCompletion(
            completed: event,
            position: player.state.position,
            duration: player.state.duration,
          )) {
            streamController.add(
              VideoEvent(eventType: VideoEventType.completed),
            );
          }
        }),
      );
      streamSubscriptions.add(
        player.stream.buffering.listen((event) async {
          await completer.future;
          streamController.add(
            VideoEvent(
              eventType: event
                  ? VideoEventType.bufferingStart
                  : VideoEventType.bufferingEnd,
            ),
          );
        }),
      );
      streamSubscriptions.add(
        player.stream.buffer.listen((event) async {
          await completer.future;
          streamController.add(
            VideoEvent(
              eventType: VideoEventType.bufferingUpdate,
              buffered: [DurationRange(Duration.zero, event)],
            ),
          );
        }),
      );
      streamSubscriptions.add(
        player.stream.error.listen((event) {
          if (NativeVideoPlayerMediaKit.isRecoverableMissingAudioDeviceError(
            event,
          )) {
            debugPrint(
              'MediaKit ignored missing audio device (video continues silently): '
              '$event',
            );
            return;
          }
          final state = decoderFallbackState;
          if (state != null && state.knownAudioOnly && !completer.isCompleted) {
            state.lastError = event;
            state.initializationErrorTimer ??= Timer(
              const Duration(seconds: 3),
              () {
                if (_decoderFallbackStates[textureId] != state ||
                    _players[textureId] != player ||
                    completer.isCompleted) {
                  return;
                }
                final hasAudioTrack = player.state.tracks.audio.any(
                  (track) => track.id != 'auto' && track.id != 'no',
                );
                if (player.state.duration > Duration.zero && hasAudioTrack) {
                  // The log was emitted while ALAC/FFmpeg was configuring its
                  // decoder. The media is usable, so it is not a terminal
                  // VideoPlayerController error.
                  duration = player.state.duration;
                  width = 0;
                  height = 0;
                  notify();
                  return;
                }
                emitPlayerError(
                  state.lastError ?? 'Audio decoder failed to initialize',
                );
              },
            );
            debugPrint(
              'MediaKit deferred audio-only decoder log during '
              'initialization: $event',
            );
            return;
          }
          if (state != null &&
              state.enabled &&
              !state.videoOutputDeferred &&
              !state.externalVideoTrackSuspended &&
              !state.firstFrameRendered) {
            state.lastError = event;
            final shouldRetry =
                NativeVideoPlayerMediaKit.shouldRetryAndroidSoftwareDecoding(
                  useHardwareDecoding: true,
                  operatingSystem: UniversalPlatform.operatingSystem,
                  firstFrameRendered: state.firstFrameRendered,
                  fallbackAttempted: state.fallbackAttempted,
                );
            if (shouldRetry) {
              state.fallbackAttempted = true;
              state.failureTimer = Timer(const Duration(seconds: 12), () {
                if (!state.firstFrameRendered) {
                  emitPlayerError(
                    state.lastError ??
                        'Hardware decoder failed and software retry timed out',
                  );
                }
              });
              unawaited(retryWithSoftwareDecoder());
            }
            // media_kit emits decoder log errors even when libmpv is about to
            // recover. Do not poison VideoPlayerController before the explicit
            // one-shot software attempt has had a chance to render a frame.
            return;
          }

          final tracks = player.state.tracks;
          final hasUsableMediaTrack =
              tracks.audio.any(
                (track) => track.id != 'auto' && track.id != 'no',
              ) ||
              tracks.video.any(
                (track) => track.id != 'auto' && track.id != 'no',
              );
          if (!NativeVideoPlayerMediaKit.shouldForwardPlayerError(
            controllerInitialized: completer.isCompleted,
            duration: player.state.duration,
            hasUsableMediaTrack: hasUsableMediaTrack,
          )) {
            debugPrint(
              'MediaKit ignored recoverable post-initialization error: $event',
            );
            final hint = _healthHints[textureId];
            if (hint != null && !_retiringPlayers.contains(textureId)) {
              hint.value++;
            }
            return;
          }

          // Before initialization there is no usable controller to preserve.
          // Forwarding the failure also prevents initialize() from hanging.
          emitPlayerError(event);
        }),
      );
    }
  }

  Future<void> _disableSubtitleOutput(Player player) async {
    try {
      if (player.state.track.subtitle != SubtitleTrack.no()) {
        await player.setSubtitleTrack(SubtitleTrack.no());
      }
    } catch (_) {
      // Best effort: keep playback working even if subtitle track switching fails.
    }
  }

  Future<void> _disableAlbumArtVideoOutput(Player player) async {
    try {
      if (player.state.track.video != VideoTrack.no()) {
        await player.setVideoTrack(VideoTrack.no());
      }
    } catch (_) {
      // Album art is decorative. Failure to deselect it must not block audio.
    }
  }

  Future<void> _attachExternalAudio(Player player, String? uri) async {
    if (uri == null || uri.isEmpty) return;
    final parsed = Uri.tryParse(uri);
    if (parsed == null ||
        !parsed.isAbsolute ||
        (parsed.scheme != 'http' && parsed.scheme != 'https')) {
      throw ArgumentError.value(uri, 'externalAudioUri', 'Invalid media URI');
    }
    await player.setAudioTrack(
      AudioTrack.uri(uri, title: 'Bilibili audio', language: 'und'),
    );
  }

  Future<void> _openMediaWithExternalAudio(
    Player player,
    Media media, {
    required String? externalAudioUri,
    required bool knownAudioOnly,
    bool startWithoutVideo = false,
    Duration startPosition = Duration.zero,
    bool reselectPrimaryVideo = true,
  }) async {
    final audioOnly = knownAudioOnly || startWithoutVideo;
    if (audioOnly) {
      await player.setVideoTrack(VideoTrack.no());
    } else {
      // A Bilibili DASH video URL is video-only. Explicitly selecting video
      // before load keeps libmpv from deciding that the file has no selected
      // streams and unloading it before the external audio-add command runs.
      await player.setVideoTrack(VideoTrack.auto());
    }

    if (!knownAudioOnly && externalAudioUri != null) {
      // Load both demuxers before selecting tracks. audio-add after open
      // invalidates track selection and can reset a parked resume clock.
      await player.open(
        Media(
          NativeVideoPlayerMediaKit.dualTrackEdl(media.uri, externalAudioUri),
          httpHeaders: media.httpHeaders,
          extras: media.extras,
          start: startPosition,
        ),
        play: false,
      );
      return;
    }

    await player.open(media, play: false);
    if (!reselectPrimaryVideo) return;

    // Attach audio immediately. Waiting for the video track first made Mini
    // card / notification play sit on a silent spinner while video init
    // downloaded — audio is a fraction of that size.
    await _attachExternalAudio(player, externalAudioUri);
    if (audioOnly) {
      if (player.state.track.video.id != 'no') {
        await player.setVideoTrack(VideoTrack.no());
      }
      if (startPosition > Duration.zero) {
        await _seekNativePlayer(player, startPosition);
      }
      return;
    }

    // audio-add mutates libmpv's track list. Re-select the main video so
    // automatic selection cannot settle on `no` or album art.
    final selectedPrimaryVideoTrack = await _waitForPrimaryVideoTrack(player);
    await player.setVideoTrack(selectedPrimaryVideoTrack);
    // Selecting the elementary video stream restarts decode at t=0 and wipes
    // mpv's `start=` offset. Re-park before Flutter initialize() returns.
    if (startPosition > Duration.zero) {
      await _seekNativePlayer(player, startPosition);
    }
  }

  Future<VideoTrack> _waitForPrimaryVideoTrack(Player player) async {
    final current = NativeVideoPlayerMediaKit.firstUsableVideoTrack(
      player.state.tracks,
    );
    if (current != null) return current;

    try {
      final tracks = await player.stream.tracks
          .firstWhere(
            (tracks) =>
                NativeVideoPlayerMediaKit.firstUsableVideoTrack(tracks) != null,
          )
          .timeout(const Duration(milliseconds: 400));
      return NativeVideoPlayerMediaKit.firstUsableVideoTrack(tracks) ??
          VideoTrack.auto();
    } catch (_) {
      // Audio is already attached. Falling back to auto unblocks initialize
      // instead of sitting on a spinner for a video track list.
      return VideoTrack.auto();
    }
  }

  Future<void> _configureCloudDrivePlayback(
    Player player, {
    required bool hls,
    required bool fastStart,
  }) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    final options = NativeVideoPlayerMediaKit.cloudDriveNativeOptions(
      hls: hls,
      fastStart: fastStart,
    );
    // Some libmpv builds reject an optional property (typically a demuxer-lavf
    // key). Setting them one by one keeps such a rejection local instead of
    // aborting the native open, which surfaced as "画质切换失败".
    final rejected = <String, String>{};
    for (final option in options.entries) {
      try {
        await platform.setProperty(
          option.key,
          option.value,
          waitForInitialization: false,
        );
      } catch (error) {
        rejected[option.key] = error.runtimeType.toString();
      }
    }
    final readback = <String, String>{...options};
    for (final key in <String>[
      'network-timeout',
      'cache-pause-initial',
      'cache-pause',
    ]) {
      try {
        final value = await platform.getProperty(
          key,
          waitForInitialization: false,
        );
        if (value.isNotEmpty) readback['readback:$key'] = value;
      } catch (_) {
        // The intended value is still recorded when the build rejects a key.
      }
    }
    for (final entry in rejected.entries) {
      readback['rejected:${entry.key}'] = entry.value;
    }
    NativeVideoPlayerMediaKit.debugLastCloudDriveProfile = readback;
    debugPrint(
      'CloudDriveProfile hls=$hls fastStart=$fastStart network-timeout='
      '${readback['readback:network-timeout'] ?? options['network-timeout']} '
      'cache-pause-initial='
      '${readback['readback:cache-pause-initial'] ?? options['cache-pause-initial']}'
      '${rejected.isEmpty ? '' : ' rejected=${rejected.keys.join(',')}'}',
    );
  }

  Future<void> _configureStreamingBuffer(
    Player player,
    int textureId, {
    bool fastStart = false,
    bool audioOnly = false,
  }) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    final isMobile = UniversalPlatform.isAndroid || UniversalPlatform.isIOS;
    final isDesktop =
        UniversalPlatform.isWindows ||
        UniversalPlatform.isMacOS ||
        UniversalPlatform.isLinux;
    // Audio-only Mini/notification sessions are ~128 kbps. Huge video
    // readahead would keep buffering true and stall the play button.
    // ExoPlayer/Bilibili start with a few seconds, then refill — gigabit
    // makes a 128MB start window pure latency.
    final maxForwardBytes = audioOnly
        ? 2 * 1024 * 1024
        : (isMobile
              ? 16 * 1024 * 1024
              : (isDesktop ? 32 * 1024 * 1024 : 24 * 1024 * 1024));
    final maxBackBytes = audioOnly
        ? 1 * 1024 * 1024
        : (isMobile
              ? 8 * 1024 * 1024
              : (isDesktop ? 12 * 1024 * 1024 : 8 * 1024 * 1024));
    final cacheSecs = audioOnly ? '6' : (isDesktop ? '16' : '12');
    final readaheadSecs = audioOnly ? '4' : (isDesktop ? '12' : '8');
    final skipInitialPause = fastStart || audioOnly;
    // Local loopback fMP4 does not need a long lavf probe. Waiting here made
    // Windows report a bursty fake speed while initialize sat idle.
    final analyzeDuration = audioOnly ? '0.1' : (isDesktop ? '0.25' : '0.4');
    final probeSize = audioOnly ? '65536' : (isDesktop ? '262144' : '524288');
    await Future.wait<void>([
      platform.setProperty('cache', 'yes', waitForInitialization: false),
      platform.setProperty('cache-pause', 'yes', waitForInitialization: false),
      platform.setProperty(
        'cache-pause-initial',
        skipInitialPause ? 'no' : 'yes',
        waitForInitialization: false,
      ),
      platform.setProperty(
        'cache-pause-wait',
        skipInitialPause
            ? SubtitleHopSeekPolicy.streamingScrubCachePauseWaitSeconds
            : SubtitleHopSeekPolicy.streamingCachePauseWaitSeconds,
        waitForInitialization: false,
      ),
      platform.setProperty(
        'cache-secs',
        cacheSecs,
        waitForInitialization: false,
      ),
      platform.setProperty(
        'demuxer-readahead-secs',
        readaheadSecs,
        waitForInitialization: false,
      ),
      platform.setProperty(
        'demuxer-max-bytes',
        '$maxForwardBytes',
        waitForInitialization: false,
      ),
      platform.setProperty(
        'demuxer-max-back-bytes',
        '$maxBackBytes',
        waitForInitialization: false,
      ),
      platform.setProperty(
        'demuxer-lavf-analyzeduration',
        analyzeDuration,
        waitForInitialization: false,
      ),
      platform.setProperty(
        'demuxer-lavf-probesize',
        probeSize,
        waitForInitialization: false,
      ),
      platform.setProperty(
        'force-seekable',
        'yes',
        waitForInitialization: false,
      ),
    ]);
    _streamingBufferPlayers.add(textureId);
  }

  Future<void> _configureHighResolutionPlayback(Player player) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;

    // Automatic decoder threading is particularly important for dav1d's 4K
    // AV1 software fallback. Direct rendering avoids an avoidable decoded-frame
    // copy, while framedrop during precise seeks prevents a large GOP from
    // making the UI appear stuck after scrubbing.
    await Future.wait<void>(<Future<void>>[
      platform.setProperty(
        'vd-lavc-threads',
        '0',
        waitForInitialization: false,
      ),
      platform.setProperty('vd-lavc-dr', 'yes', waitForInitialization: false),
      platform.setProperty(
        'hr-seek-framedrop',
        'yes',
        waitForInitialization: false,
      ),
    ]);
  }

  Future<void> _configureFrameDroppingForResolution(
    int textureId,
    Player player,
    Size sourceSize,
  ) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;

    // mpv recommends VO-only dropping for normal media. Decoder dropping is
    // deliberately reserved for >1080p streams, where continuing to decode
    // every obsolete frame can otherwise leave a slow 4K software decoder
    // permanently behind the audio clock.
    final highResolution = sourceSize.width * sourceSize.height > 1920 * 1080;
    final mode = highResolution ? 'decoder+vo' : 'vo';
    if (_frameDropModes[textureId] == mode) return;
    try {
      await platform.setProperty(
        'framedrop',
        mode,
        waitForInitialization: false,
      );
      if (_players[textureId] == player) {
        _frameDropModes[textureId] = mode;
      }
    } catch (error) {
      debugPrint('MediaKit framedrop configuration failed: $error');
    }
  }

  Size? _physicalViewportSize() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return null;
    Size? largest;
    for (final view in views) {
      final size = view.physicalSize;
      if (size.width <= 0 || size.height <= 0) continue;
      if (largest == null ||
          size.width * size.height > largest.width * largest.height) {
        largest = size;
      }
    }
    return largest;
  }

  void _scheduleAdaptiveOutputResize(int textureId, Size sourceSize) {
    // media_kit intentionally does not expose output resizing on Android.
    // Its Surface/MediaCodec path remains fully GPU accelerated instead.
    if (!NativeVideoPlayerMediaKit.supportsAdaptiveTextureResizing(
      UniversalPlatform.operatingSystem,
    )) {
      return;
    }
    final epoch = (_resizeEpochs[textureId] ?? 0) + 1;
    _resizeEpochs[textureId] = epoch;

    // media_kit also reacts to videoParams and first sets the source size.
    // Reapply our display-aware cap after that native resize has completed.
    Future<void>.delayed(const Duration(milliseconds: 20), () async {
      if (_resizeEpochs[textureId] != epoch ||
          _sourceVideoSizes[textureId] != sourceSize) {
        return;
      }
      final controller = _videoControllers[textureId];
      final viewport = _physicalViewportSize();
      if (controller == null || viewport == null) return;

      final target = NativeVideoPlayerMediaKit.adaptiveTextureSize(
        source: sourceSize,
        physicalViewport: viewport,
      );
      if (_outputVideoSizes[textureId] == target) return;

      try {
        if (target == sourceSize) {
          await controller.setSize();
        } else {
          await controller.setSize(
            width: target.width.toInt(),
            height: target.height.toInt(),
          );
        }
        if (_videoControllers[textureId] == controller) {
          _outputVideoSizes[textureId] = target;
          debugPrint(
            'MediaKit texture: '
            '${sourceSize.width.toInt()}x${sourceSize.height.toInt()} -> '
            '${target.width.toInt()}x${target.height.toInt()}',
          );
        }
      } catch (error) {
        debugPrint('MediaKit adaptive texture resize failed: $error');
      }
    });
  }
}

class _DecoderFallbackState {
  _DecoderFallbackState({
    required this.media,
    required this.externalAudioUri,
    required this.knownAudioOnly,
    required this.enabled,
    required this.videoOutputDeferred,
  });

  final Media media;
  final String? externalAudioUri;
  final bool knownAudioOnly;
  final bool enabled;
  bool videoOutputDeferred;
  bool externalVideoTrackSuspended = false;
  bool fallbackAttempted = false;
  bool firstFrameRendered = false;
  bool fatalErrorEmitted = false;
  String? lastError;
  Timer? failureTimer;
  Timer? initializationErrorTimer;
  Future<bool>? recovery;

  void markFirstFrameRendered() {
    firstFrameRendered = true;
    failureTimer?.cancel();
    failureTimer = null;
  }

  void dispose() {
    failureTimer?.cancel();
    failureTimer = null;
    initializationErrorTimer?.cancel();
    initializationErrorTimer = null;
  }
}
