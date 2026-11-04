import 'package:media_kit/media_kit.dart';
import 'package:universal_platform/universal_platform.dart';

/// Establishes a low-latency, pitch-neutral playback clock for a whole
/// session, including while the effective speed is exactly 1.0x.
abstract final class PitchPreservingAudioPipeline {
  /// mpv defaults to 200 ms and explicitly documents that larger audio output
  /// buffers cause problems on playback-speed changes. More importantly,
  /// audio-master video timing reinterprets the *whole* already-queued output
  /// delay using the newly selected rate. With mpv's old 200 ms default, a
  /// 1x -> 2x edge can hold the next video frame for about 100 ms, while the
  /// inverse edge can make video about 200 ms late and trigger catch-up drops.
  ///
  /// 20 ms keeps those raw errors near one 60 Hz frame even before autosync
  /// divides them across frames, while retaining more underrun headroom than
  /// a 10 ms device period. The WSOLA
  /// search/window latency is internal to scaletempo2 and does not require an
  /// equally large audio-device queue.
  static const double responsiveAudioBufferSeconds = 0.02;

  /// Device queues must stop on pause/EOF. Queue-loss recovery belongs to the
  /// transport boundary, not a permanently active silent audio stream. Keep
  /// each driver's existing device-buffer headroom (including OpenSL ES).
  static Map<String, String> pauseOptionsFor(String operatingSystem) => {
    'audio-stream-silence': 'no',
  };

  /// Windows renders through a shared texture protected by a native mutex.
  /// mpv_render_context_render blocks for the target presentation time by
  /// default while that mutex is held. Render-ahead therefore blocks Flutter's
  /// raster thread in ANGLESurfaceManager::Read, even for unrelated animation.
  /// Preserve media_kit's zero-offset policy on this backend. Other platforms
  /// retain their existing clock behavior until measured on native hardware.
  static double videoTimingOffsetFor(String operatingSystem) =>
      operatingSystem == 'windows' ? 0.0 : 0.05;

  static double get videoTimingOffsetSeconds =>
      videoTimingOffsetFor(UniversalPlatform.operatingSystem);

  /// In audio-master mode a rate change temporarily makes the audio driver's
  /// queued delay look as if it was all produced at the new rate. With the mpv
  /// default (0), that entire clock error is applied to one video scheduling
  /// decision: the exact freeze/catch-up pair seen at long-press boundaries.
  /// autosync blends the measured audio delay over consecutive frames. It does
  /// not resample audio, alter pitch, seek, pause, or rebuild either decoder.
  static const int avClockSmoothing = 30;

  static const String filter =
      'scaletempo2=min-speed=0.25:max-speed=8.0:'
      'search-interval=40:window-size=12';

  static Future<void> configure(Player player) async {
    final platform = player.platform;
    if (platform is! NativePlayer) {
      throw StateError('Pitch-preserving playback requires NativePlayer');
    }

    // Waiting for the native handle (rather than a VideoController frame)
    // lets callers establish the final audio graph before opening the media.
    await platform.handle;

    // Relying on mpv's automatic pitch-correction filter would insert
    // scaletempo2 when a long press leaves 1.0x and remove it on release.
    // Keeping this explicit filter alive avoids rebuilding the audio graph at
    // either boundary. PlayerConfiguration.pitch remains false, so media_kit
    // changes only mpv's speed and never enters its pitch-shifting path.
    // These properties are independent. Dispatch them as one batch so native
    // player creation does not pay fourteen serialized Dart/native round trips
    // before it can open the media.
    final pauseOptions = pauseOptionsFor(UniversalPlatform.operatingSystem);
    await Future.wait<void>(<Future<void>>[
      for (final option in pauseOptions.entries)
        platform.setProperty(
          option.key,
          option.value,
          waitForInitialization: false,
        ),
      platform.setProperty(
        'audio-buffer',
        responsiveAudioBufferSeconds.toStringAsFixed(2),
        waitForInitialization: false,
      ),
      platform.setProperty(
        'audio-pitch-correction',
        'yes',
        waitForInitialization: false,
      ),
      platform.setProperty('af', filter, waitForInitialization: false),
      // Keep the robust audio-master mode required by media_kit's Flutter
      // texture renderer, but smooth step-changing audio delay measurements.
      platform.setProperty('video-sync', 'audio', waitForInitialization: false),
      platform.setProperty(
        'autosync',
        '$avClockSmoothing',
        waitForInitialization: false,
      ),
      platform.setProperty(
        'video-timing-offset',
        videoTimingOffsetSeconds.toStringAsFixed(2),
        waitForInitialization: false,
      ),
      platform.setProperty('framedrop', 'vo', waitForInitialization: false),
      // WASAPI exclusive (and OEM Android AudioTrack exclusive paths) would
      // request a second AUDIOFOCUS_GAIN against AudioSession.
      platform.setProperty(
        'audio-exclusive',
        'no',
        waitForInitialization: false,
      ),
    ]);

    final configuredValues = await Future.wait<String>(<Future<String>>[
      platform.getProperty('audio-buffer', waitForInitialization: false),
      platform.getProperty(
        'audio-pitch-correction',
        waitForInitialization: false,
      ),
      platform.getProperty('af', waitForInitialization: false),
      platform.getProperty('video-sync', waitForInitialization: false),
      platform.getProperty('autosync', waitForInitialization: false),
      platform.getProperty('video-timing-offset', waitForInitialization: false),
      platform.getProperty('framedrop', waitForInitialization: false),
    ]);
    final [
      audioBuffer,
      correction,
      filters,
      videoSync,
      autosync,
      videoTimingOffset,
      frameDrop,
    ] = configuredValues;
    final configuredAudioBuffer = double.tryParse(audioBuffer);
    final configuredAutosync = int.tryParse(autosync);
    final configuredVideoTimingOffset = double.tryParse(videoTimingOffset);
    final correctionEnabled = correction == 'yes' || correction == 'true';
    final configuredPauseValues = await Future.wait<String>([
      for (final key in pauseOptions.keys)
        platform.getProperty(key, waitForInitialization: false),
    ]);
    final pauseValuesMatch = List.generate(pauseOptions.length, (index) {
      final expected = pauseOptions.values.elementAt(index);
      final actual = configuredPauseValues[index];
      return actual == expected || expected == 'yes' && actual == 'true';
    }).every((matches) => matches);
    if (configuredAudioBuffer == null ||
        (configuredAudioBuffer - responsiveAudioBufferSeconds).abs() > 0.005 ||
        !correctionEnabled ||
        !filters.contains('scaletempo2') ||
        videoSync != 'audio' ||
        configuredAutosync != avClockSmoothing ||
        configuredVideoTimingOffset == null ||
        (configuredVideoTimingOffset - videoTimingOffsetSeconds).abs() >
            0.005 ||
        frameDrop != 'vo' ||
        !pauseValuesMatch) {
      throw StateError(
        'Unable to establish seamless pitch-preserving playback '
        '(audio-buffer=$audioBuffer, correction=$correction, af=$filters, '
        'video-sync=$videoSync, autosync=$autosync, '
        'video-timing-offset=$videoTimingOffset, framedrop=$frameDrop, '
        'pause-output=$configuredPauseValues)',
      );
    }
  }
}
