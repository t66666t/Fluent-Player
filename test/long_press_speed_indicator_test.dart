import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/video_controls_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsService settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    settings = SettingsService()..resetForTest();
    await settings.init();
  });

  test('倍速提示默认开启、即时更新并持久化', () async {
    expect(settings.showLongPressSpeedIndicator, isTrue);

    var notifications = 0;
    settings.addListener(() => notifications++);
    final saving = settings.saveShowLongPressSpeedIndicator(false);

    expect(settings.showLongPressSpeedIndicator, isFalse);
    expect(notifications, 1);
    await saving;

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('showLongPressSpeedIndicator'), isFalse);

    settings.resetForTest();
    await settings.init();
    expect(settings.showLongPressSpeedIndicator, isFalse);
  });

  testWidgets('松手可靠隐藏提示，开关即时生效且字号随播放器缩放', (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(360, 240));

    final controller = VideoPlayerController.networkUrl(
      Uri.parse('https://example.invalid/video.mp4'),
    );
    addTearDown(controller.dispose);
    final playbackService = MediaPlaybackService();
    addTearDown(playbackService.dispose);
    final harnessKey = GlobalKey<_LongPressHarnessState>();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          ChangeNotifierProvider<MediaPlaybackService>.value(
            value: playbackService,
          ),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: _LongPressHarness(key: harnessKey, controller: controller),
        ),
      ),
    );

    final gesture = await tester.startGesture(const Offset(280, 120));
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.byKey(const ValueKey('long-press-speed-feedback')),
      findsOneWidget,
    );
    final compactText = tester.widget<Text>(
      find.byKey(const ValueKey('long-press-speed-feedback-text')),
    );
    final compactFontSize = compactText.style!.fontSize!;
    expect(compactText.textScaler, TextScaler.noScaling);

    // Rebuild the parent while its playback flag is true. The visual must
    // still disappear on release instead of being kept alive by that old prop.
    harnessKey.currentState!.rebuild();
    await tester.pump();

    final hiding = settings.saveShowLongPressSpeedIndicator(false);
    expect(settings.showLongPressSpeedIndicator, isFalse);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('long-press-speed-feedback')),
      findsNothing,
    );
    await hiding;

    await settings.saveShowLongPressSpeedIndicator(true);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('long-press-speed-feedback')),
      findsOneWidget,
    );

    await gesture.up();
    await tester.pump();
    // The visual intentionally remains for the short switch-out animation.
    expect(
      find.byKey(const ValueKey('long-press-speed-feedback')),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 160));
    expect(
      find.byKey(const ValueKey('long-press-speed-feedback')),
      findsNothing,
    );

    await tester.binding.setSurfaceSize(const Size(900, 600));
    await tester.pump();
    final largeGesture = await tester.startGesture(const Offset(700, 300));
    await tester.pump(const Duration(milliseconds: 400));
    final largeText = tester.widget<Text>(
      find.byKey(const ValueKey('long-press-speed-feedback-text')),
    );
    expect(largeText.style!.fontSize!, greaterThan(compactFontSize));
    await largeGesture.up();
    await tester.pump();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 20));
  });
}

class _LongPressHarness extends StatefulWidget {
  const _LongPressHarness({super.key, required this.controller});

  final VideoPlayerController controller;

  @override
  State<_LongPressHarness> createState() => _LongPressHarnessState();
}

class _LongPressHarnessState extends State<_LongPressHarness> {
  bool _isLongPressing = false;

  void rebuild() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: VideoControlsOverlay(
        controller: widget.controller,
        isLocked: false,
        isPreviewMode: true,
        onTogglePlay: () {},
        onBackPressed: () {},
        onToggleLock: () {},
        onSpeedUpdate: (_) async {},
        longPressSpeed: 2,
        showSubtitles: false,
        onToggleSubtitles: () {},
        onMoveSubtitles: () {},
        isLongPressing: _isLongPressing,
        longPressFeedbackText: '2.0x',
        onLongPressStart: () {
          _isLongPressing = true;
          return true;
        },
        onLongPressEnd: () => _isLongPressing = false,
        subtitleEntries: const [],
        subtitleStyle: const SubtitleStyle(),
        subtitleAlignment: Alignment.bottomCenter,
        onEnterSubtitleDragMode: () {},
      ),
    );
  }
}
