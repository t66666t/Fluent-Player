import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/danmaku_model.dart';
import 'package:video_player_app/models/danmaku_style.dart';
import 'package:video_player_app/models/recommended_app_defaults.dart';
import 'package:video_player_app/widgets/danmaku_overlay.dart';

void main() {
  final comment = DanmakuItem(
    text: '有时间读完的弹幕',
    startTime: Duration.zero,
    duration: const Duration(seconds: 8),
    type: DanmakuType.scroll,
    colorValue: 0xFFFFFFFF,
    index: 0,
    sourceY: 0,
  );

  for (final screen in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(430, 932),
    const Size(768, 1024),
    const Size(1200, 750), // 2880 x 1800 at 2.4 device pixel ratio.
    const Size(1280, 800),
    const Size(1920, 1080),
    const Size(2560, 1440),
    const Size(3840, 2160),
  ]) {
    test(
      'default font is bounded, rotation stable and manually scalable at $screen',
      () {
        final normal = resolveDanmakuFontSize(
          playerHeight: screen.height,
          fontScale: 1,
          screenSize: screen,
        );
        expect(normal, inInclusiveRange(14, 22));
        if (screen.shortestSide >= 1080) {
          expect(normal, inInclusiveRange(19.9, 22));
          expect(
            normal,
            lessThan(
              resolveDanmakuFontSize(
                playerHeight: screen.height,
                fontScale: .8,
              ),
            ),
          );
        }
        for (final viewport in [screen, screen.flipped]) {
          // The same window may contain a short video band, full-height stage,
          // or sidebar. None of those should alter this default font size.
          for (final stageHeight in [viewport.height, viewport.height / 3]) {
            for (final scale in [.2, .5, 1.0, 1.5, 4.0]) {
              final size = resolveDanmakuFontSize(
                playerHeight: stageHeight,
                fontScale: scale,
                screenSize: viewport,
              );
              expect(size, closeTo(normal * scale, 1e-8));
            }
          }
        }
      },
    );
    test('default has equal pixel velocity in both orientations at $screen', () {
      final speed = RecommendedAppDefaults.danmakuSpeed(
        DefaultSettingsDevice(TargetPlatform.android, screen),
      );
      expect(speed, 1.0);
      for (final viewport in [screen, screen.flipped]) {
        final anchor = resolveDanmakuScreenMotionAnchor(viewport);
        for (final sidebarWidth in [0.0, viewport.width * .3]) {
          for (final lockedRate in [1.0, 2.0, 3.0]) {
            final effective = resolveDanmakuSpeedWithLockedPlaybackBaseline(
              sliderSpeed: speed,
              useLockedPlaybackAsBaseline: true,
              isPlaybackSpeedLocked: true,
              lockedPlaybackSpeed: lockedRate,
            );
            final duration = resolveDanmakuDurationUs(
              comment,
              speed: effective,
              viewportWidth: viewport.width - sidebarWidth,
              referenceWidth: 1920,
              motionAnchorWidth: anchor,
            );
            final wallSeconds = duration / 1000000 / lockedRate;
            expect(
              wallSeconds,
              closeTo((viewport.width - sidebarWidth) / 60, 0.000002),
            );
          }
        }
      }
    });
  }
  test(
    'invalid window dimensions fall back to the original safe font rule',
    () {
      for (final screen in [
        Size.zero,
        const Size(double.nan, 800),
        const Size(800, double.infinity),
      ]) {
        expect(
          resolveDanmakuFontSize(
            playerHeight: 1080,
            fontScale: .8,
            screenSize: screen,
          ),
          32,
        );
      }
    },
  );
}
