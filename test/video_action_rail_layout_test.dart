import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/video_action_rail_layout.dart';

void main() {
  VideoActionRailLayout layout(
    Size size,
    double height, {
    double textScale = 1,
    bool labels = true,
  }) => VideoActionRailLayout.resolve(
    screenSize: size,
    availableWidth: size.width - 32,
    availableHeight: height,
    textScaler: TextScaler.linear(textScale),
    showLabels: labels,
  );

  test(
    'short phones and landscape tablets fit all actions in two narrow columns',
    () {
      for (final entry in {
        const Size(320, 568): 480.0,
        const Size(360, 640): 552.0,
        const Size(1024, 768): 480.0,
        const Size(600, 640): 426.0,
      }.entries) {
        final result = layout(entry.key, entry.value);
        expect(result.columns, 2);
        expect(result.width, 108);
        expect(result.buttonSize, 44);
        expect(result.needsScroll, isFalse);
      }
    },
  );

  test('phones keep two columns even with ample vertical space', () {
    for (final size in [
      const Size(280, 1000),
      const Size(320, 568),
      const Size(360, 800),
      const Size(390, 844),
      const Size(430, 932),
      const Size(599, 1000),
    ]) {
      final result = layout(size, size.height - 88);
      expect(result.columns, 2);
      expect(result.width, 108);
      expect(result.buttonSize, 44);
      expect(result.needsScroll, isFalse);
      expect(result.expandedHeight, lessThan(340));
    }
  });

  test(
    'portrait tablets and wide desktops keep a single column when it fits',
    () {
      for (final entry in {
        const Size(600, 1000): 900.0,
        const Size(768, 1024): 800.0,
        const Size(1440, 900): 760.0,
      }.entries) {
        final result = layout(entry.key, entry.value);
        expect(result.columns, 1);
        expect(result.width, lessThanOrEqualTo(52));
        expect(result.needsScroll, isFalse);
      }
    },
  );

  test('a player consuming vertical space keeps the phone layout stable', () {
    final tall = layout(const Size(390, 844), 756);
    final playing = layout(const Size(390, 844), 540);
    expect(tall.columns, 2);
    expect(playing.columns, 2);
    expect(playing.width, tall.width);
    expect(playing.buttonSize, tall.buttonSize);
    expect(playing.labelFontSize, tall.labelFontSize);
    expect(playing.needsScroll, isFalse);
  });

  test(
    'landscape phones use a small reduction only after switching columns',
    () {
      final result = layout(const Size(844, 390), 300);
      expect(result.columns, 2);
      expect(result.buttonSize, 40);
      expect(result.labelFontSize, 10.5);
      expect(result.width, 100);
      expect(result.needsScroll, isFalse);
    },
  );

  test(
    'large accessibility text does not create an over-wide two-column panel',
    () {
      final result = layout(const Size(320, 568), 428, textScale: 2);
      expect(result.columns, 1);
      expect(result.width, 90);
      expect(result.labelFontSize, 10.5);
      expect(result.needsScroll, isTrue);
    },
  );

  test('icon-only phones keep two columns while roomy desktops use one', () {
    final result = layout(const Size(320, 568), 480, labels: false);
    expect(result.columns, 2);
    expect(result.width, 92);
    expect(result.needsScroll, isFalse);
    final desktop = layout(const Size(1440, 900), 760, labels: false);
    expect(desktop.columns, 1);
    expect(desktop.width, 40);
  });

  test(
    'screen/font matrix preserves readable sizes and bounds two-column width',
    () {
      for (final size in [
        const Size(240, 320),
        const Size(280, 653),
        const Size(320, 568),
        const Size(360, 640),
        const Size(390, 844),
        const Size(844, 390),
        const Size(600, 640),
        const Size(768, 1024),
        const Size(1024, 600),
        const Size(1024, 768),
        const Size(1280, 800),
        const Size(1920, 1080),
        const Size(3840, 2160),
      ]) {
        for (final scale in [1.0, 1.3, 2.0, 3.0]) {
          for (final labels in [true, false]) {
            for (final reservedHeight in [88.0, 220.0]) {
              final result = layout(
                size,
                math.max(0, size.height - reservedHeight),
                textScale: scale,
                labels: labels,
              );
              expect(result.columns, inInclusiveRange(1, 2));
              expect(result.buttonSize, greaterThanOrEqualTo(36));
              expect(result.labelFontSize, greaterThanOrEqualTo(10.5));
              expect(result.width, lessThanOrEqualTo(size.width - 32));
              if (labels) {
                expect(
                  result.cellWidth,
                  greaterThanOrEqualTo(result.labelFontSize * scale * 4),
                );
              }
              if (result.columns == 2) {
                expect(
                  result.width,
                  lessThanOrEqualTo(math.min(144, size.width * 0.40)),
                );
              }
            }
          }
        }
      }
    },
  );
}
