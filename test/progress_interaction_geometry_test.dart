import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/progress_interaction_geometry.dart';

void main() {
  group('progress interaction geometry', () {
    test('maps pointer positions against the visible slider track', () {
      expect(
        progressValueFromLocalDx(
          localDx: 10,
          width: 110,
          maxValue: 1000,
          trackInset: 10,
        ),
        0,
      );
      expect(
        progressValueFromLocalDx(
          localDx: 55,
          width: 110,
          maxValue: 1000,
          trackInset: 10,
        ),
        closeTo(500, 0.001),
      );
      expect(
        progressValueFromLocalDx(
          localDx: 100,
          width: 110,
          maxValue: 1000,
          trackInset: 10,
        ),
        1000,
      );
    });

    test('value and position conversions round-trip in both directions', () {
      for (final direction in TextDirection.values) {
        final dx = progressLocalDxFromValue(
          value: 375,
          width: 320,
          maxValue: 1000,
          trackInset: 12,
          textDirection: direction,
        );
        final value = progressValueFromLocalDx(
          localDx: dx,
          width: 320,
          maxValue: 1000,
          trackInset: 12,
          textDirection: direction,
        );
        expect(value, closeTo(375, 0.001));
      }
    });
  });
}
