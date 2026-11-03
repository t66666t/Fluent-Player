import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/screens/video_player_screen.dart';

void main() {
  group('landscape subtitle viewport readiness', () {
    test('desktop and web-sized windows do not wait for orientation', () {
      expect(
        isLandscapeSubtitleViewportReady(
          size: const Size(700, 1000),
          isMobilePlatform: false,
        ),
        isTrue,
      );
    });

    test('phones wait for landscape metrics before restoring', () {
      expect(
        isLandscapeSubtitleViewportReady(
          size: const Size(390, 844),
          isMobilePlatform: true,
        ),
        isFalse,
      );
      expect(
        isLandscapeSubtitleViewportReady(
          size: const Size(844, 390),
          isMobilePlatform: true,
        ),
        isTrue,
      );
    });

    test('tablets support portrait-shaped split-screen viewports', () {
      expect(
        isLandscapeSubtitleViewportReady(
          size: const Size(700, 1000),
          isMobilePlatform: true,
        ),
        isTrue,
      );
    });
  });
}
