import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/landscape_sidebar_layout.dart';

void main() {
  group('LandscapeSidebarLayout functional widths', () {
    test('preserves player space on a small landscape phone', () {
      const screen = Size(568, 320);
      final width = LandscapeSidebarLayout.functionalWidthFor(screen);

      expect(width, greaterThanOrEqualTo(248));
      expect(width, lessThanOrEqualTo(screen.width * 0.48));
      expect(width, lessThanOrEqualTo(310));
    });

    test('scales progressively across phones tablets and desktops', () {
      final phone = LandscapeSidebarLayout.functionalWidthFor(
        const Size(844, 390),
      );
      final tablet = LandscapeSidebarLayout.functionalWidthFor(
        const Size(1194, 834),
      );
      final desktop = LandscapeSidebarLayout.functionalWidthFor(
        const Size(1920, 1080),
      );

      expect(phone, 310);
      expect(tablet, closeTo(382.08, 0.01));
      expect(desktop, 460);
      expect(phone, lessThan(tablet));
      expect(tablet, lessThan(desktop));
    });

    test('covers common landscape device classes without wasting space', () {
      const screens = <String, Size>{
        'small phone': Size(568, 320),
        'large phone': Size(932, 430),
        'small tablet': Size(1024, 600),
        'large tablet': Size(1366, 1024),
        'desktop': Size(1920, 1080),
        'large desktop': Size(3840, 2160),
      };

      for (final entry in screens.entries) {
        final width = LandscapeSidebarLayout.functionalWidthFor(entry.value);
        expect(width, inInclusiveRange(248, 460), reason: entry.key);
        expect(
          width,
          lessThanOrEqualTo(entry.value.width * 0.48),
          reason: '${entry.key} must preserve the playback surface',
        );
      }
    });

    test('caps width by height for short desktop windows', () {
      final width = LandscapeSidebarLayout.functionalWidthFor(
        const Size(1600, 400),
      );

      expect(width, 310);
    });
  });

  group('LandscapeSidebarLayout density', () {
    test('uses compact vertical metrics on short landscape phones', () {
      final layout = LandscapeSidebarLayout.fromSize(const Size(280, 360));

      expect(layout.isCompactHeight, isTrue);
      expect(layout.isNarrow, isTrue);
      expect(layout.headerHeight, 38);
      expect(layout.bodySize, 11);
      expect(layout.sectionGap, 8);
    });

    test('allows comfortable spacing on large tablets and desktops', () {
      final layout = LandscapeSidebarLayout.fromSize(const Size(460, 900));

      expect(layout.isCompactHeight, isFalse);
      expect(layout.isNarrow, isFalse);
      expect(layout.headerHeight, 50);
      expect(layout.bodySize, 12);
      expect(layout.sectionGap, 14);
    });
  });
}
