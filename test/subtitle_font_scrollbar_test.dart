import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/subtitle_font_service.dart';
import 'package:video_player_app/widgets/subtitle_font_settings_page.dart';

void main() {
  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.windows,
  ]) {
    testWidgets('${platform.name}: online fonts can be dragged by the thumb', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await tester.binding.setSurfaceSize(const Size(390, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() async {
        await SubtitleFontService.instance.ready;
        await SubtitleFontService.instance.catalog();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform, brightness: Brightness.dark),
          home: Scaffold(
            body: SubtitleFontSettingsPage(
              style: const SubtitleTextStyle(),
              onChanged: (_) {},
              onBack: () {},
              onClose: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('通用字体'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('在线'));
      await tester.pump();
      await tester.runAsync(() => SubtitleFontService.instance.catalog());
      await tester.pumpAndSettle();
      // The thumb must remain available after the usual fade-out interval.
      await tester.pump(const Duration(seconds: 3));
      final scrollbar = find.byType(RawScrollbar);
      expect(scrollbar, findsOneWidget);
      final controller = tester.widget<RawScrollbar>(scrollbar).controller!;
      final paint = find.descendant(
        of: scrollbar,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is CustomPaint &&
              widget.foregroundPainter is ScrollbarPainter,
        ),
      );
      final painter =
          tester.widget<CustomPaint>(paint).foregroundPainter!
              as ScrollbarPainter;
      final bounds = tester.getRect(paint);
      final thumbHits = <double>[];
      for (var y = 0.0; y < bounds.height; y++) {
        if (painter.hitTestOnlyThumbInteractive(
          Offset(bounds.width - 7, y),
          PointerDeviceKind.mouse,
        )) {
          thumbHits.add(y);
        }
      }
      expect(thumbHits.length, greaterThanOrEqualTo(55));
      final start =
          bounds.topLeft +
          Offset(bounds.width - 7, (thumbHits.first + thumbHits.last) / 2);
      final gesture = await tester.startGesture(
        start,
        kind: platform == TargetPlatform.windows
            ? PointerDeviceKind.mouse
            : PointerDeviceKind.touch,
      );
      await gesture.moveTo(Offset(start.dx, bounds.bottom - 40));
      await tester.pump();
      expect(controller.offset, greaterThan(bounds.height * 10));
      await gesture.moveTo(start);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(0, 1));
      expect(tester.takeException(), isNull);
    });
  }
}
