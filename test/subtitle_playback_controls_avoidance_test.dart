import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/subtitle_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('subtitle playback controls avoidance', () {
    const viewport = Size(1280, 720);
    const subtitle = Size(520, 90);
    const alignment = Alignment(0, 0.9);

    test('keeps the normal alignment when controls are hidden', () {
      final offset = resolveSubtitleOverlayOffset(
        viewportSize: viewport,
        subtitleSize: subtitle,
        alignment: alignment,
      );

      expect(offset, const Offset(380, 598.5));
    });

    test('does not move a subtitle that already clears the controls', () {
      final normal = resolveSubtitleOverlayOffset(
        viewportSize: viewport,
        subtitleSize: subtitle,
        alignment: const Alignment(0, 0),
      );
      final avoided = resolveSubtitleOverlayOffset(
        viewportSize: viewport,
        subtitleSize: subtitle,
        alignment: const Alignment(0, 0),
        playbackControlsTop: 600,
      );

      expect(avoided, normal);
    });

    test('moves the whole subtitle group by only the overlap distance', () {
      final offset = resolveSubtitleOverlayOffset(
        viewportSize: viewport,
        subtitleSize: subtitle,
        alignment: alignment,
        playbackControlsTop: 620,
      );

      expect(offset.dx, 380);
      expect(offset.dy, 530);
      expect(offset.dy + subtitle.height, 620);
    });

    test(
      'chapter button only affects subtitles that overlap it horizontally',
      () {
        const localizedChapterButton = Rect.fromLTRB(20, 500, 250, 550);
        const bottomControls = Rect.fromLTRB(0, 570, 1000, 600);

        final centered = resolveSubtitleOverlayOffset(
          viewportSize: const Size(1000, 600),
          subtitleSize: const Size(200, 50),
          alignment: Alignment.bottomCenter,
          playbackControlRects: const [bottomControls, localizedChapterButton],
        );
        expect(centered, const Offset(400, 520));

        final leftAligned = resolveSubtitleOverlayOffset(
          viewportSize: const Size(1000, 600),
          subtitleSize: const Size(200, 50),
          alignment: Alignment.bottomLeft,
          playbackControlRects: const [bottomControls, localizedChapterButton],
        );
        expect(leftAligned, const Offset(0, 450));
      },
    );

    test('clearance follows the viewport ratio', () {
      expect(subtitlePlaybackControlsClearance(360), closeTo(2.88, 0.0001));
      expect(subtitlePlaybackControlsClearance(720), closeTo(5.76, 0.0001));
      expect(subtitlePlaybackControlsClearance(1080), closeTo(8.64, 0.0001));
    });
  });

  test('setting defaults on, updates immediately, and persists', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsService()..resetForTest();
    await settings.init();

    expect(settings.avoidPlaybackControlsWithSubtitles, isTrue);

    final saving = settings.saveAvoidPlaybackControlsWithSubtitles(false);
    expect(settings.avoidPlaybackControlsWithSubtitles, isFalse);
    await saving;

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('avoidPlaybackControlsWithSubtitles'), isFalse);

    settings.resetForTest();
    await settings.init();
    expect(settings.avoidPlaybackControlsWithSubtitles, isFalse);
  });

  testWidgets('visibility changes apply the final position without animation', (
    tester,
  ) async {
    final controlsVisible = ValueNotifier<bool>(true);
    addTearDown(controlsVisible.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 400,
              height: 300,
              child: SubtitleOverlayGroup(
                entries: const [SubtitleOverlayEntry(text: '测试字幕')],
                style: const SubtitleStyle(),
                alignment: Alignment.bottomCenter,
                playbackControlsVisibility: controlsVisible,
                playbackControlsTop: 220,
                avoidPlaybackControls: true,
              ),
            ),
          ),
        ),
      ),
    );

    final background = find.descendant(
      of: find.byType(SubtitleOverlayGroup),
      matching: find.byWidgetPredicate(
        (widget) => widget is Container && widget.decoration is BoxDecoration,
      ),
    );
    expect(background, findsOneWidget);
    expect(tester.getRect(background).bottom, closeTo(220, 0.01));

    controlsVisible.value = false;
    await tester.pump();
    expect(tester.getRect(background).bottom, greaterThan(220));

    controlsVisible.value = true;
    await tester.pump();
    final immediatelyAvoidedBottom = tester.getRect(background).bottom;
    expect(immediatelyAvoidedBottom, closeTo(220, 0.01));

    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.getRect(background).bottom, immediatelyAvoidedBottom);
  });
}
