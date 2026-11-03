import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_scroll_viewport.dart';
import 'package:video_player_app/widgets/playback_source_viewport.dart';

void main() {
  testWidgets(
    'changing library column count preserves the visible item rather than pixels',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService()..resetForTest();
      await settings.init();
      await settings.updateHomeCardStyleFor(
        const Size(400, 800),
        crossAxisCount: 2,
      );
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = PlaybackScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: PlaybackSourceViewport(
            child: AnimatedBuilder(
              animation: settings,
              builder: (context, _) {
                final size = MediaQuery.sizeOf(context);
                final columns = settings.homeCardStyleFor(size).crossAxisCount;
                return Scaffold(
                  body: MediaLibraryScrollViewport.library(
                    settings: settings,
                    screenSize: size,
                    controller: controller,
                    child: PlaybackGridView.builder(
                      controller: controller,
                      itemKey: (i) => 'media-$i',
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisExtent: 120,
                      ),
                      itemCount: 100,
                      itemBuilder: (_, i) => SizedBox(
                        key: ValueKey('media-$i'),
                        child: Text('媒体 $i'),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      controller.jumpTo(960);
      await tester.pump();
      final before = tester
          .getTopLeft(find.byKey(const ValueKey('media-16')))
          .dy;
      await settings.updateHomeCardStyleFor(
        const Size(400, 800),
        crossAxisCount: 3,
      );
      await tester.pumpAndSettle();
      expect(controller.offset, isNot(closeTo(960, 1)));
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('media-16'))).dy,
        closeTo(before, 1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
