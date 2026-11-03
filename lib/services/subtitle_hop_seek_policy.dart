/// libmpv seek/cache tuning tiers for split Bilibili streams.
enum StreamingSeekStyle { precise, scrub, hop }

/// Rules for previous/next-sentence (and equivalent left/right hop) seeks.
///
/// Offline file seeks are already cheap. Online Bilibili split streams pay for
/// two Range requests plus libmpv's conservative `cache-pause-wait`, so the
/// same Dart hop must coalesce native work and use a keyframe-fast path.
class SubtitleHopSeekPolicy {
  const SubtitleHopSeekPolicy._();

  /// libmpv waits this long for cache after a split-stream open or precise seek.
  /// Kept conservative so a DASH underrun cannot loop a few decoded packets.
  static const String streamingCachePauseWaitSeconds = '2';

  /// Progress-bar / notification scrubs use keyframe seeks and a short pause.
  /// Two seconds here made 480p scrubbing feel broken even on fast networks.
  static const String streamingScrubCachePauseWaitSeconds = '0.35';

  /// After a sentence hop the demuxer usually already holds nearby packets.
  /// A short wait keeps the underrun guard without a two-second stall.
  static const String hopCachePauseWaitSeconds = '0.08';

  /// Split Bilibili video/audio are independent fMP4s. Keyframe-only seeks
  /// (`hr-seek=no`) land video on the previous IDR while the external audio
  /// clock stays at the requested timestamp — silent video for one sentence,
  /// then audio starts. Precise seeks keep both tracks on the same clock.
  static const String hopHrSeek = 'yes';

  /// Progress-bar seeks use the same precise clock. Speed comes from a short
  /// cache-pause-wait, not from snapping to a previous keyframe.
  static const String scrubHrSeek = 'yes';

  /// Restore libmpv's default so saved-position / resync seeks stay accurate.
  static const String preciseHrSeek = 'default';

  static const Duration onlineNativeDispatchDelay = Duration(milliseconds: 70);
  static const Duration offlineNativeDispatchDelay = Duration(milliseconds: 16);
  static const Duration hopZeroResyncSuppression = Duration(milliseconds: 1500);
  static const Duration overlayHopDebounce = Duration(milliseconds: 16);

  /// Native samples this close to the hop target are treated as landed.
  /// Wider than this is usually the pre-hop clock on a split Bilibili stream.
  static const int hopSubtitleNativeSettleMs = 450;

  static bool isHopSeekSource(String source) {
    switch (source) {
      case 'external_double_tap':
      case 'subtitle_navigation':
      case 'subtitle_hop':
        return true;
      default:
        return source.startsWith('subtitle_hop');
    }
  }

  /// Only split Bilibili streams need the keyframe + short cache-pause path.
  static bool shouldUseStreamingHopTuning({
    required bool isOnlineBilibiliStream,
    required String source,
  }) {
    return streamingSeekStyleFor(
          isOnlineBilibiliStream: isOnlineBilibiliStream,
          source: source,
        ) ==
        StreamingSeekStyle.hop;
  }

  /// Chooses the libmpv cache/seek profile for an online Bilibili seek.
  static StreamingSeekStyle streamingSeekStyleFor({
    required bool isOnlineBilibiliStream,
    required String source,
  }) {
    if (!isOnlineBilibiliStream) return StreamingSeekStyle.precise;
    if (isHopSeekSource(source)) return StreamingSeekStyle.hop;
    if (source == 'ui' || source == 'system_media') {
      return StreamingSeekStyle.scrub;
    }
    return StreamingSeekStyle.precise;
  }

  static String hrSeekFor(StreamingSeekStyle style) {
    switch (style) {
      case StreamingSeekStyle.hop:
        return hopHrSeek;
      case StreamingSeekStyle.scrub:
        return scrubHrSeek;
      case StreamingSeekStyle.precise:
        return preciseHrSeek;
    }
  }

  static String cachePauseWaitSecondsFor(StreamingSeekStyle style) {
    switch (style) {
      case StreamingSeekStyle.hop:
        return hopCachePauseWaitSeconds;
      case StreamingSeekStyle.scrub:
        return streamingScrubCachePauseWaitSeconds;
      case StreamingSeekStyle.precise:
        return streamingCachePauseWaitSeconds;
    }
  }

  /// Rapid left/right hops must issue one native seek (latest target wins).
  static Duration nativeDispatchDelay({
    required bool isOnlineBilibiliStream,
    required String source,
  }) {
    if (!isHopSeekSource(source)) return Duration.zero;
    return isOnlineBilibiliStream
        ? onlineNativeDispatchDelay
        : offlineNativeDispatchDelay;
  }

  /// Awaiting a 2s controller Future serializes stacked hops on a slow CDN.
  static bool shouldAwaitNativeSeekAck({
    required bool isOnlineBilibiliStream,
    required String source,
  }) {
    if (!isHopSeekSource(source)) return true;
    return !isOnlineBilibiliStream;
  }

  /// Keyframe landing can sit hundreds of ms before the subtitle timestamp.
  /// Snapping the service clock to that sample makes the highlight bounce.
  static bool shouldRewritePositionOnSeekDrift(String source) {
    return !isHopSeekSource(source);
  }

  /// Overlay/sidebar subtitles must not follow a lagging native clock during
  /// left/right hops. Online Bilibili reports the pre-hop timestamp for a
  /// few hundred ms; that makes the highlight flash backward then forward.
  static bool shouldHoldSubtitleClockOnHop({
    required String? lastSeekSource,
    required DateTime now,
    required DateTime? lastHopSeekAt,
    required Duration nativePosition,
    required Duration hopTarget,
    required bool hopSeekInFlight,
  }) {
    if (!isHopSeekSource(lastSeekSource ?? '')) return false;
    if (hopSeekInFlight) return true;
    if (lastHopSeekAt == null) return false;
    if (now.difference(lastHopSeekAt) > hopZeroResyncSuppression) {
      return false;
    }
    return (nativePosition - hopTarget).inMilliseconds.abs() >
        hopSubtitleNativeSettleMs;
  }

  static bool shouldSuppressZeroClockResync({
    required bool hopSeekInFlight,
    required String? lastSeekSource,
    required DateTime now,
    DateTime? lastHopSeekAt,
  }) {
    if (hopSeekInFlight) return true;
    if (lastSeekSource != null && isHopSeekSource(lastSeekSource)) {
      if (lastHopSeekAt != null &&
          now.difference(lastHopSeekAt) < hopZeroResyncSuppression) {
        return true;
      }
    }
    return false;
  }
}
