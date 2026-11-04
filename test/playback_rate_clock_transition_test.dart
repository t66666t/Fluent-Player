import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/platform/pitch_preserving_audio_pipeline.dart';

void main() {
  group('audio-master rate-boundary clock', () {
    test('the old defaults reproduce the reported freeze then catch-up', () {
      const oldAudioBuffer = 0.2;

      final entry = _firstFrameTimingError(
        oldRate: 1,
        newRate: 2,
        outputDelaySeconds: oldAudioBuffer,
        autosync: 0,
      );
      final exit = _firstFrameTimingError(
        oldRate: 2,
        newRate: 1,
        outputDelaySeconds: oldAudioBuffer,
        autosync: 0,
      );

      // Positive time makes mpv hold the next frame; negative time makes it
      // late and eligible for catch-up dropping. These values come directly
      // from mpv 0.36's update_avsync_before_frame equations.
      expect(entry, closeTo(0.1, 0.000001));
      expect(exit, closeTo(-0.2, 0.000001));
    });

    test('autosync distributes a 200 ms driver step below one 60 Hz frame', () {
      const outputDelaySeconds = 0.2;
      const frameAt60Hz = 1 / 60;

      final entry = _firstFrameTimingError(
        oldRate: 1,
        newRate: 2,
        outputDelaySeconds: outputDelaySeconds,
        autosync: PitchPreservingAudioPipeline.avClockSmoothing,
      );
      final exit = _firstFrameTimingError(
        oldRate: 2,
        newRate: 1,
        outputDelaySeconds: outputDelaySeconds,
        autosync: PitchPreservingAudioPipeline.avClockSmoothing,
      );

      expect(entry.abs(), lessThan(frameAt60Hz));
      expect(exit.abs(), lessThan(frameAt60Hz));
    });

    test('the configured queue keeps even a 1x-8x edge sub-frame', () {
      const frameAt120Hz = 1 / 120;

      for (final transition in <(double, double)>[(1, 8), (8, 1)]) {
        final error = _firstFrameTimingError(
          oldRate: transition.$1,
          newRate: transition.$2,
          outputDelaySeconds:
              PitchPreservingAudioPipeline.responsiveAudioBufferSeconds,
          autosync: PitchPreservingAudioPipeline.avClockSmoothing,
        );
        expect(error.abs(), lessThan(frameAt120Hz));
      }
    });
  });
}

/// Models mpv v0.36 player/video.c:update_avsync_before_frame.
///
/// Immediately before a rate edge, mpctx->delay is stable at the output delay
/// multiplied by the old media rate. mpv then divides that old delay by the
/// new video rate. autosync=0 applies the complete difference to one frame;
/// autosync=N applies one Nth, preserving direction while removing the step.
double _firstFrameTimingError({
  required double oldRate,
  required double newRate,
  required double outputDelaySeconds,
  required int autosync,
}) {
  final stableMediaDelay = outputDelaySeconds * oldRate;
  final predictedOutputDelay = stableMediaDelay / newRate;
  final difference = outputDelaySeconds - predictedOutputDelay;
  return autosync == 0 ? difference : difference / autosync;
}
