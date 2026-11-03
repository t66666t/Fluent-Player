import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/controllers/music_volume_controller.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/screens/music_player_screen.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/music_lyric_region.dart';

const _method = MethodChannel('com.kurenai7968.volume_controller.method');
const _events = MethodChannel(
  'com.kurenai7968.volume_controller.volume_listener_event',
);
Finder get _panel => find.byKey(const ValueKey('music-volume-panel'));
Finder get _slider => find.byKey(const ValueKey('music-volume-slider'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var systemVolume = 0.62;
  final writes = <double>[];
  Completer<void>? writeGate;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    systemVolume = 0.62;
    writes.clear();
    writeGate = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_events, (_) async => null);
    messenger.setMockMethodCallHandler(_method, (call) async {
      if (call.method == 'getVolume') return systemVolume;
      if (call.method == 'setVolume') {
        final value = (call.arguments as Map)['volume'] as double;
        writes.add(value);
        await writeGate?.future;
        systemVolume = value;
      }
      return null;
    });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_events, null);
    messenger.setMockMethodCallHandler(_method, null);
  });
  setUpAll(() async {
    if (!const bool.fromEnvironment('CAPTURE_MUSIC_VOLUME')) return;
    for (final font in {
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
      'packages/cupertino_icons/CupertinoIcons':
          'packages/cupertino_icons/assets/CupertinoIcons.ttf',
      'Noto Sans SC': 'assets/fonts/NotoSansCJKsc-Regular.otf',
      'Inter': 'assets/fonts/Inter-ExtraBold.otf',
    }.entries) {
      await (FontLoader(font.key)..addFont(rootBundle.load(font.value))).load();
    }
  });

  testWidgets('native writes coalesce and never quantize the dragging thumb', (
    tester,
  ) async {
    final playback = MediaPlaybackService.forTesting();
    final controller = MusicVolumeController(playback, useSystemVolume: true);
    await tester.pump();
    expect(controller.volume, 0.62);
    writeGate = Completer<void>();
    controller.beginDrag();
    for (var i = 0; i < 100; i++) {
      controller.setVolume(0.321 + i * 0.00123);
    }
    await tester.pump();
    expect(writes, hasLength(1));
    expect(controller.volume, closeTo(0.44277, 0.0000001));
    expect(
      playback.volume,
      1,
      reason: 'mobile must not compound system volume with software gain',
    );
    // An older, quantized hardware echo must not move the active thumb.
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      _events.name,
      const StandardMethodCodec().encodeSuccessEnvelope(0.3125),
      (_) {},
    );
    await tester.pump();
    expect(controller.volume, closeTo(0.44277, 0.0000001));
    writeGate!.complete();
    await tester.pump();
    await tester.pump();
    expect(writes, hasLength(2));
    expect(writes.last, controller.volume);
    controller.endDrag();
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      _events.name,
      const StandardMethodCodec().encodeSuccessEnvelope(0.75),
      (_) {},
    );
    await tester.pump();
    expect(controller.volume, 0.75);
    controller.dispose();
    playback.dispose();
  });

  testWidgets(
    'desktop precision, mute restoration, external volume and auto unmute',
    (tester) async {
      final playback = MediaPlaybackService.forTesting();
      final controller = MusicVolumeController(
        playback,
        useSystemVolume: false,
      );
      controller.setVolume(0.417389);
      await tester.pump();
      expect(playback.volume, 0.417389);
      await controller.toggleMute();
      expect(controller.isMuted, isTrue);
      expect(controller.volume, 0.417389);
      await controller.toggleMute();
      expect(controller.isMuted, isFalse);
      expect(controller.volume, 0.417389);
      await playback.setVolume(0.71);
      expect(controller.volume, 0.71);
      await controller.toggleMute();
      controller.setVolume(0.63321);
      await tester.pump();
      expect(controller.isMuted, isFalse);
      expect(playback.volume, 0.63321);
      expect(writes, isEmpty);
      controller.dispose();
      playback.dispose();
    },
  );

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    testWidgets('$platform panel stays usable across sizes and rotation', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final playback = MediaPlaybackService.forTesting();
      await playback.setVolume(0.62);
      const lines = [
        'The evening light is fading',
        'We keep on moving through the night',
        'A little closer to the morning',
        'Let every moment find its way',
        'The melody will stay with you',
      ];
      playback.setSubtitleState(
        paths: [],
        primary: [
          for (var i = 0; i < lines.length; i++)
            SubtitleItem(
              index: i,
              startTime: Duration(seconds: i * 30),
              endTime: Duration(seconds: (i + 1) * 30),
              text: lines[i],
            ),
        ],
        secondary: [],
      );
      final settings = SettingsService()..resetForTest();
      addTearDown(playback.dispose);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.devicePixelRatio = 1;
      for (final size in [
        const Size(320, 568),
        const Size(390, 844),
        const Size(480, 320),
        const Size(568, 280),
        const Size(844, 390),
        const Size(768, 1024),
        const Size(1366, 900),
        const Size(1920, 1080),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(_player(playback, settings));
        await tester.pumpAndSettle();
        if (_panel.evaluate().isEmpty) await tester.tap(find.byTooltip('音量'));
        await tester.pumpAndSettle();
        final rect = tester.getRect(_panel);
        expect(rect.left, greaterThanOrEqualTo(12));
        expect(rect.right, lessThanOrEqualTo(size.width - 12));
        expect(rect.top, greaterThanOrEqualTo(8));
        expect(rect.bottom, lessThanOrEqualTo(size.height - 8));
        expect(rect.width, 296);
        expect(rect.height, 52);
        expect(tester.getSize(_slider).width, greaterThanOrEqualTo(190));
        expect(tester.getSize(_slider).height, greaterThanOrEqualTo(44));
        expect(tester.widget<Slider>(_slider).divisions, isNull);
        expect(tester.takeException(), isNull);
        if ((platform == TargetPlatform.android &&
                size == const Size(390, 844)) ||
            (platform == TargetPlatform.windows &&
                size == const Size(1366, 900)) ||
            (platform == TargetPlatform.iOS && size == const Size(844, 390))) {
          await _capture(
            tester,
            '${platform.name}-${size.width.toInt()}x${size.height.toInt()}',
          );
        }
      }
      // Rotation and window resizing keep the open panel anchored to the new control row.
      await tester.tapAt(Offset(tester.view.physicalSize.width - 12, 12));
      await tester.pumpAndSettle();
      expect(_panel, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets(
    'touch and mouse fine drag, mute, dismissal and idle control pinning',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final playback = MediaPlaybackService.forTesting();
      addTearDown(playback.dispose);
      final settings = SettingsService()..resetForTest();
      settings.musicPortraitControlsAutoHide = true;
      playback.setSubtitleState(
        paths: [],
        primary: [
          SubtitleItem(
            index: 0,
            startTime: Duration.zero,
            endTime: const Duration(minutes: 3),
            text: 'A little closer to the morning',
          ),
        ],
        secondary: [],
      );
      await tester.pumpWidget(_player(playback, settings));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('音量'));
      await tester.pumpAndSettle();
      final initial = playback.volume;
      final lyricWidget = tester.widget(find.byType(MusicLyricRegion));
      for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
        final rect = tester.getRect(_slider);
        final gesture = await tester.startGesture(rect.center, kind: kind);
        await gesture.moveBy(const Offset(21.37, 0));
        await tester.pump();
        final first = tester.widget<Slider>(_slider).value;
        await gesture.moveBy(const Offset(0.6, 0));
        await tester.pump();
        final second = tester.widget<Slider>(_slider).value;
        expect(second, greaterThan(first));
        expect(second - first, lessThan(0.01));
        await gesture.up();
        await tester.pump();
      }
      expect(playback.volume, isNot(initial));
      expect(
        identical(tester.widget(find.byType(MusicLyricRegion)), lyricWidget),
        isTrue,
        reason: 'continuous volume changes must not rebuild the lyric subtree',
      );
      final volume = playback.volume;
      await tester.tap(find.byKey(const ValueKey('music-volume-mute')));
      await tester.pumpAndSettle();
      expect(playback.isMuted, isTrue);
      expect(playback.volume, volume);
      await tester.tap(find.byKey(const ValueKey('music-volume-mute')));
      await tester.pumpAndSettle();
      expect(playback.isMuted, isFalse);
      expect(playback.volume, volume);
      await tester.pump(const Duration(seconds: 8));
      await tester.pumpAndSettle();
      expect(_slider.hitTestable(), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(playback.volume, closeTo(volume - 0.01, 0.000001));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(_panel, findsNothing);
      await tester.tap(find.byTooltip('音量'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(380, 120));
      await tester.pumpAndSettle();
      expect(_panel, findsNothing);
      await tester.tap(find.byTooltip('页面设置 (S)'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('music-page-settings-panel')),
        findsOneWidget,
      );
      expect(_panel, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    },
  );
}

Widget _player(MediaPlaybackService playback, SettingsService settings) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
        ChangeNotifierProvider<SettingsService>.value(value: settings),
      ],
      child: MaterialApp(
        theme: ThemeData(fontFamily: 'Noto Sans SC'),
        builder: (context, child) => RepaintBoundary(
          key: const ValueKey('volume-preview'),
          child: child!,
        ),
        home: const MusicPlayerScreen(
          title: '夜航 · Nightfall',
          artist: 'Evening sessions',
          totalDuration: Duration(minutes: 3, seconds: 48),
        ),
      ),
    );

Future<void> _capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('CAPTURE_MUSIC_VOLUME')) return;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('volume-preview')),
    );
    final image = await boundary.toImage(pixelRatio: 1.5);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('.artifacts/music-volume/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}
