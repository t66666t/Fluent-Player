import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/screens/video_player_screen.dart';
import 'package:video_player_app/widgets/video_controls_overlay.dart';

void main() {
  test('hidden portrait overlay keeps landscape chrome hidden', () {
    expect(
      landscapePlaybackChromeFromPortrait(
        overlayControlsVisible: false,
        lastIntent: true,
      ),
      isFalse,
    );
  });

  test('visible portrait overlay keeps landscape chrome visible', () {
    expect(
      landscapePlaybackChromeFromPortrait(
        overlayControlsVisible: true,
        lastIntent: false,
      ),
      isTrue,
    );
  });

  test('unmounted overlay falls back to the last chrome intent', () {
    expect(
      landscapePlaybackChromeFromPortrait(
        overlayControlsVisible: null,
        lastIntent: false,
      ),
      isFalse,
    );
    expect(
      landscapePlaybackChromeFromPortrait(
        overlayControlsVisible: null,
        lastIntent: true,
      ),
      isTrue,
    );
  });

  test('landscape screen stores the handed-off chrome intent', () {
    const hidden = VideoPlayerScreen(initialShowControls: false);
    const shown = VideoPlayerScreen(initialShowControls: true);
    expect(hidden.initialShowControls, isFalse);
    expect(shown.initialShowControls, isTrue);
  });

  test('direct landscape entry starts with hidden chrome', () {
    expect(const VideoPlayerScreen().initialShowControls, isFalse);
  });

  test('preparation chrome intent is taken only by its destination, once', () {
    VideoControlsOverlay.handOffEntryVisibility('prepared-video', true);
    expect(VideoControlsOverlay.takeEntryVisibility('another-video'), isNull);
    expect(VideoControlsOverlay.takeEntryVisibility('prepared-video'), isTrue);
    expect(VideoControlsOverlay.takeEntryVisibility('prepared-video'), isNull);
    VideoControlsOverlay.handOffEntryVisibility('prepared-video', false);
    expect(VideoControlsOverlay.takeEntryVisibility('prepared-video'), isFalse);
  });
}
