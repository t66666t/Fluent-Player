import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_card_scale.dart';
import 'support/default_trial_features.dart';

void main() {
  testWidgets(
    'whole card scales text, fixed icons and hit tests without pixel caps',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'mediaLibraryReadableCardDefaults': true,
      });
      final settings = SettingsService()..resetForTest();
      settings.featureSettingsForTrial = MemoryTrialFeatures();
      await settings.init();
      tester.view.physicalSize = const Size(1800, 1500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var taps = 0;
      for (final width in [12.0, 30.0, 75.0, 150.0, 300.0, 1500.0]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                height: width * .8,
                child: MediaLibraryCardScale(
                  builder: (context) => GestureDetector(
                    onTap: () => taps++,
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Colors.grey,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Column(
                        children: [
                          Text('Title', style: TextStyle(fontSize: 12.5)),
                          Icon(Icons.folder, size: 24),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final paragraph = tester.renderObject<RenderParagraph>(
          find.text('Title'),
        );
        final transform = paragraph.getTransformTo(null);
        expect(transform.entry(0, 0), closeTo(width / 150, 1e-10));
        expect(transform.entry(1, 1), closeTo(width / 150, 1e-10));
        final font = paragraph.text.style!.fontSize! * transform.entry(0, 0);
        expect(font, closeTo(width / 12, 1e-10));
        final icon = tester.renderObject<RenderBox>(find.byType(Icon));
        expect(
          icon.size.width * icon.getTransformTo(null).entry(0, 0),
          closeTo(24 * width / 150, 1e-10),
        );
        final before = taps;
        await tester.tap(find.text('Title'));
        expect(taps, before + 1);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
