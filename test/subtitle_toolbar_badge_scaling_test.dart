import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/subtitle_toolbar.dart';

void main() {
  for (final textScale in [1.0, 2.0, 3.0]) {
    testWidgets('follow badge scales with icon at text scale $textScale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1920, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      double? previousIconHeight;
      double? previousBadgeHeight;
      for (final width in [
        80.0,
        160.0,
        240.0,
        280.0,
        320.0,
        390.0,
        600.0,
        1920.0,
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
              child: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: width,
                    child: SubtitleToolbar(
                      onOpenSettings: () {},
                      actions: [
                        // Match the production toolbar's maximum action count and
                        // group sizes so narrow-screen compression is exercised.
                        for (var i = 0; i < 2; i++)
                          SubtitleToolbarAction(
                            icon: i == 0 ? Icons.list : Icons.article,
                            group: SubtitleToolbarGroup.view,
                            tooltip: 'View $i',
                            onTap: () {},
                            selected: i == 0,
                          ),
                        for (var i = 0; i < 3; i++)
                          SubtitleToolbarAction(
                            label: ['双', '1', '2'][i],
                            group: SubtitleToolbarGroup.language,
                            tooltip: 'Language $i',
                            onTap: () {},
                            selected: i == 0,
                          ),
                        for (var i = 0; i < 8; i++)
                          SubtitleToolbarAction(
                            icon: Icons.style_outlined,
                            tooltip: 'Action $i',
                            onTap: () {},
                          ),
                        SubtitleToolbarAction(
                          icon: Icons.gps_fixed,
                          tooltip: '自动跟随字幕',
                          selected: true,
                          selectedBadge: 'A',
                          onTap: () {},
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final icon = tester.renderObject<RenderBox>(
          find.byIcon(Icons.gps_fixed),
        );
        final badge = tester.renderObject<RenderBox>(find.text('A'));
        final iconMatrix = icon.getTransformTo(null);
        final badgeMatrix = badge.getTransformTo(null);
        final iconRect = MatrixUtils.transformRect(
          iconMatrix,
          Offset.zero & icon.size,
        );
        final badgeRect = MatrixUtils.transformRect(
          badgeMatrix,
          Offset.zero & badge.size,
        );
        final iconScale = iconRect.width / icon.size.width;
        final badgeScale = badgeRect.width / badge.size.width;
        expect(badgeScale, closeTo(iconScale, 0.000001));
        expect(iconScale, lessThanOrEqualTo(1.000001));
        if (width <= 280) expect(iconScale, lessThan(1));
        if (previousIconHeight != null) {
          expect(
            badgeRect.height / previousBadgeHeight!,
            closeTo(iconRect.height / previousIconHeight, 0.000001),
          );
        }
        previousIconHeight = iconRect.height;
        previousBadgeHeight = badgeRect.height;
        final target = tester.getRect(find.byTooltip('自动跟随字幕'));
        expect(target.contains(badgeRect.topLeft), isTrue);
        expect(target.contains(badgeRect.bottomRight), isTrue);
        expect(tester.takeException(), isNull);
      }
    });
  }
}
