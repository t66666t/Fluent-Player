import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/player_control_metrics.dart';

void main() {
  group('PlayerControlMetrics', () {
    test(
      'landscape phone controls are smaller and denser than tablet controls',
      () {
        final phone = PlayerControlMetrics.fromSize(const Size(800, 360));
        final tablet = PlayerControlMetrics.fromSize(const Size(1280, 800));

        expect(phone.isCompact, isTrue);
        expect(phone.primaryIconSize, lessThan(tablet.primaryIconSize));
        expect(
          phone.sideControlButtonExtent,
          lessThan(tablet.sideControlButtonExtent),
        );
        expect(phone.sideControlIconSize, lessThan(tablet.sideControlIconSize));
        expect(phone.bottomButtonExtent, lessThan(tablet.bottomButtonExtent));
        expect(phone.bottomButtonExtent, greaterThanOrEqualTo(40));
        expect(phone.sideControlButtonExtent, greaterThanOrEqualTo(36));
        expect(phone.controlGap, lessThan(tablet.controlGap));
        expect(
          phone.bottomControlsHeight(hasChapterButton: false),
          lessThan(tablet.bottomControlsHeight(hasChapterButton: false)),
        );
        expect(
          phone.progressAreaHeight(
            hasChapterButton: false,
            hasQualityButton: true,
          ),
          phone.progressAreaHeight(hasChapterButton: true),
        );
        expect(
          phone.measureProgressPillWidth(
            labels: const ['360P', '1080P 高码率'],
            textStyle: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
            textDirection: TextDirection.ltr,
            textScaler: TextScaler.noScaling,
            maxWidth: 200,
          ),
          phone.measureProgressPillWidth(
            labels: const ['1080P 高码率'],
            textStyle: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
            textDirection: TextDirection.ltr,
            textScaler: TextScaler.noScaling,
            maxWidth: 200,
          ),
        );
      },
    );

    test('sizing is continuous around the old 600 pixel breakpoint', () {
      final below = PlayerControlMetrics.fromSize(const Size(599, 360));
      final above = PlayerControlMetrics.fromSize(const Size(601, 360));

      expect(
        (below.primaryIconSize - above.primaryIconSize).abs(),
        lessThan(.2),
      );
      expect((below.controlGap - above.controlGap).abs(), lessThan(.2));
      expect(
        (below.sideControlButtonExtent - above.sideControlButtonExtent).abs(),
        lessThan(.2),
      );
    });

    test('non-safe bottom padding stays close to the player edge', () {
      final metrics = PlayerControlMetrics.fromSize(const Size(1280, 720));

      expect(metrics.bottomPadding, lessThanOrEqualTo(4));
      expect(metrics.progressHitHeight, inInclusiveRange(40, 44));
    });

    test('system safe area is preserved when it is larger', () {
      final metrics = PlayerControlMetrics.fromSize(
        const Size(844, 390),
        safeBottom: 21,
      );

      expect(metrics.bottomPadding, 21);
    });
  });
}
