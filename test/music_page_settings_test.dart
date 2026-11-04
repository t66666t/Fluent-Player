import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart' show CupertinoSwitch;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/music_lyric_anchor.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/screens/music_player_screen.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/music_lyric_view.dart';
import 'package:video_player_app/widgets/music_lyric_anchor_guide.dart';

Finder get _panel => find.byKey(const ValueKey('music-page-settings-panel'));
Finder get _autoHideRow =>
    find.byKey(const ValueKey('music-portrait-auto-hide-switch'));
Finder get _autoHideSwitch => _autoHideRow;
Finder get _fontSlider => find.byKey(const ValueKey('music-font-size-slider'));
Finder get _spacingSlider =>
    find.byKey(const ValueKey('music-lyric-spacing-slider'));
Finder get _anchorSlider =>
    find.byKey(const ValueKey('music-lyric-anchor-slider'));
Finder get _anchorGuide =>
    find.byKey(const ValueKey('music-lyric-anchor-guide'));

MusicLyricView _lyrics(WidgetTester tester) =>
    tester.widget<MusicLyricView>(find.byType(MusicLyricView));

double _settingsBackgroundAlpha(WidgetTester tester) =>
    (tester
                .widget<AnimatedContainer>(
                  find.byKey(const ValueKey('music-page-settings-surface')),
                )
                .decoration!
            as BoxDecoration)
        .color!
        .a;

void _expectControls(WidgetTester tester, bool visible) {
  final controls = find.byKey(
    const ValueKey('music-portrait-controls-overlay'),
  );
  expect(
    tester
        .widget<IgnorePointer>(
          find
              .descendant(of: controls, matching: find.byType(IgnorePointer))
              .first,
        )
        .ignoring,
    !visible,
  );
  expect(
    tester
        .widget<FadeTransition>(
          find
              .descendant(of: controls, matching: find.byType(FadeTransition))
              .first,
        )
        .opacity
        .value,
    visible ? 1 : 0,
  );
}

Future<void> _idle(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 6));
  await tester.pumpAndSettle();
}

Future<SettingsService> _mount(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double textScale = 1,
  bool autoHide = false,
  Map<String, Object> preferences = const {},
  TargetPlatform platform = TargetPlatform.windows,
  List<SubtitleItem>? subtitles,
  ValueChanged<Duration>? onSeek,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({
    'musicPortraitControlsAutoHide': autoHide,
    ...preferences,
  });
  final settings = SettingsService()..resetForTest();
  await settings.init();
  final playback = MediaPlaybackService.forTesting();
  addTearDown(playback.dispose);
  playback.setSubtitleState(
    paths: [],
    primary:
        subtitles ??
        List.generate(
          12,
          (i) => SubtitleItem(
            index: i,
            startTime: Duration(seconds: i * 10),
            endTime: Duration(seconds: (i + 1) * 10),
            text: 'Transcript $i',
          ),
        ),
    secondary: [],
  );
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsService>.value(value: settings),
        ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
      ],
      child: MaterialApp(
        theme: ThemeData(fontFamily: 'Noto Sans SC', platform: platform),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: RepaintBoundary(
            key: const ValueKey('music-settings-capture'),
            child: child!,
          ),
        ),
        home: MusicPlayerScreen(title: 'Music track', onSeek: onSeek),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return settings;
}

Future<void> _openSettings(WidgetTester tester) async {
  await tester.tap(find.byTooltip('页面设置 (S)'));
  await tester.pumpAndSettle();
  expect(_panel, findsOneWidget);
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('CAPTURE_MUSIC_SETTINGS')) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('music-settings-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('.artifacts/music-page-settings/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
          rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
        ))
        .load();
    await (FontLoader('Noto Sans SC')
          ..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf')))
        .load();
    await (FontLoader(
      'Inter',
    )..addFont(rootBundle.load('assets/fonts/Inter-ExtraBold.otf'))).load();
  });

  test('portrait auto hide defaults off and persists both choices', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService()..resetForTest();
    await settings.init();
    expect(settings.musicPortraitControlsAutoHide, isFalse);
    for (final enabled in [true, false]) {
      await settings.updateMusicPortraitControlsAutoHide(enabled);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('musicPortraitControlsAutoHide'), enabled);
      settings.resetForTest();
      await settings.init();
      expect(settings.musicPortraitControlsAutoHide, enabled);
    }
  });

  test(
    'lyric typography keeps precise values and normalizes saved limits',
    () async {
      SharedPreferences.setMockInitialValues({
        'musicLyricFontSizeScalePortrait': 0.6,
        'musicLyricFontSizeScaleLandscape': 1.4,
      });
      final settings = SettingsService()..resetForTest();
      await settings.init();
      // Existing font preferences survive, and new spacing starts at its default.
      expect(settings.musicLyricFontSizeScalePortrait, 0.6);
      expect(settings.musicLyricFontSizeScaleLandscape, 1.4);
      expect(settings.musicLyricSpacingScalePortrait, 1);
      expect(settings.musicLyricSpacingScaleLandscape, 1);
      await settings.updateMusicLyricFontSizeScalePortrait(0.4123456);
      await settings.updateMusicLyricFontSizeScaleLandscape(2.9876543);
      await settings.updateMusicLyricSpacingScalePortrait(0);
      await settings.updateMusicLyricSpacingScaleLandscape(3.9876543);
      settings.resetForTest();
      await settings.init();
      expect(settings.musicLyricFontSizeScalePortrait, 0.4123456);
      expect(settings.musicLyricFontSizeScaleLandscape, 2.9876543);
      expect(settings.musicLyricSpacingScalePortrait, 0);
      expect(settings.musicLyricSpacingScaleLandscape, 3.9876543);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('musicLyricFontSizeScalePortrait', -20);
      await prefs.setDouble('musicLyricFontSizeScaleLandscape', 20);
      await prefs.setDouble('musicLyricSpacingScalePortrait', -20);
      await prefs.setDouble('musicLyricSpacingScaleLandscape', 20);
      settings.resetForTest();
      await settings.init();
      expect(settings.musicLyricFontSizeScalePortrait, 0.4);
      expect(settings.musicLyricFontSizeScaleLandscape, 3);
      expect(settings.musicLyricSpacingScalePortrait, 0);
      expect(settings.musicLyricSpacingScaleLandscape, 4);
    },
  );

  testWidgets('continuous sliders preview precisely and save on release', (
    tester,
  ) async {
    final settings = await _mount(tester);
    await _openSettings(tester);
    final prefs = await SharedPreferences.getInstance();
    for (final sliderFinder in [_fontSlider, _spacingSlider]) {
      final key = tester.widget<Slider>(sliderFinder).key;
      final font = key == const ValueKey('music-font-size-slider');
      final preference = font
          ? 'musicLyricFontSizeScalePortrait'
          : 'musicLyricSpacingScalePortrait';
      final slider = tester.widget<Slider>(sliderFinder);
      expect(slider.divisions, isNull);
      expect(slider.min, font ? 0.4 : 0);
      expect(slider.max, font ? 3 : 4);
      final gesture = await tester.startGesture(tester.getCenter(sliderFinder));
      await gesture.moveBy(const Offset(24.25, 0));
      await tester.pump();
      final previous = tester.widget<Slider>(sliderFinder).value;
      await gesture.moveBy(const Offset(0.75, 0));
      await tester.pump();
      final value = tester.widget<Slider>(sliderFinder).value;
      expect(value, greaterThan(previous));
      expect(value - previous, lessThan(0.02));
      final lyrics = tester.widget<MusicLyricView>(find.byType(MusicLyricView));
      expect(
        font ? lyrics.lyricFontSizeScale : lyrics.lyricSpacingScale,
        value,
      );
      expect(prefs.getDouble(preference), isNull);
      expect(
        font
            ? settings.musicLyricFontSizeScalePortrait
            : settings.musicLyricSpacingScalePortrait,
        1,
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(prefs.getDouble(preference), value);
      expect(
        font
            ? settings.musicLyricFontSizeScalePortrait
            : settings.musicLyricSpacingScalePortrait,
        value,
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test(
    'lyric anchors persist independently and keep automatic defaults',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService()..resetForTest();
      await settings.init();
      expect(settings.musicLyricAnchorPortrait, MusicLyricAnchor.automatic);
      expect(settings.musicLyricAnchorLandscape, MusicLyricAnchor.automatic);
      await settings.updateMusicLyricAnchorPortrait(0.456789);
      await settings.updateMusicLyricAnchorLandscape(0.612345);
      settings.resetForTest();
      await settings.init();
      expect(settings.musicLyricAnchorPortrait, 0.456789);
      expect(settings.musicLyricAnchorLandscape, 0.612345);

      await settings.updateMusicLyricAnchorPortrait(20);
      await settings.updateMusicLyricAnchorLandscape(-20);
      expect(settings.musicLyricAnchorPortrait, MusicLyricAnchor.max);
      expect(settings.musicLyricAnchorLandscape, MusicLyricAnchor.min);
      await settings.updateMusicLyricAnchorPortrait(double.nan);
      await settings.updateMusicLyricAnchorLandscape(
        MusicLyricAnchor.automatic,
      );
      settings.resetForTest();
      await settings.init();
      expect(settings.musicLyricAnchorPortrait, MusicLyricAnchor.automatic);
      expect(settings.musicLyricAnchorLandscape, MusicLyricAnchor.automatic);
    },
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    for (final portrait in [true, false]) {
      testWidgets(
        '$platform portrait=$portrait anchor drag previews without seeking',
        (tester) async {
          final seeks = <Duration>[];
          final settings = await _mount(
            tester,
            platform: platform,
            size: portrait ? const Size(390, 844) : const Size(1440, 900),
            onSeek: seeks.add,
          );
          final defaultAnchor = _lyrics(tester).anchorFraction;
          final originalTop = tester.getTopLeft(find.text('Transcript 0')).dy;
          await _openSettings(tester);
          await tester.ensureVisible(_anchorSlider);
          await tester.pumpAndSettle();
          final prefs = await SharedPreferences.getInstance();
          final preference = portrait
              ? 'musicLyricAnchorPortrait'
              : 'musicLyricAnchorLandscape';
          expect(
            tester.widget<Slider>(_anchorSlider).value,
            portrait ? 0.28 : 0.30,
          );
          expect(
            tester.widget<MusicLyricAnchorGuide>(_anchorGuide).visible,
            isFalse,
          );
          final normalAlpha = _settingsBackgroundAlpha(tester);
          final bounds = tester.getRect(_panel);
          final gesture = await tester.startGesture(
            tester.getCenter(_anchorSlider),
          );
          await gesture.moveBy(const Offset(24, 0));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 200));
          final value = tester.widget<Slider>(_anchorSlider).value;
          expect(value, greaterThan(0.4));
          expect(_lyrics(tester).showAnchorGuide, isTrue);
          expect(
            tester.widget<MusicLyricAnchorGuide>(_anchorGuide).visible,
            isTrue,
          );
          expect(_settingsBackgroundAlpha(tester), lessThan(normalAlpha));
          expect(tester.getRect(_panel), bounds);
          expect(tester.getRect(_anchorGuide).left, 0);
          expect(tester.getRect(_anchorGuide).right, portrait ? 390 : 1440);
          expect(
            tester
                .widget<ColoredBox>(
                  find.descendant(
                    of: _anchorGuide,
                    matching: find.byType(ColoredBox),
                  ),
                )
                .color,
            const Color(0xFF42A5F5),
          );
          expect(
            tester.getTopLeft(find.text('Transcript 0')).dy,
            greaterThan(originalTop),
          );
          expect(
            tester.getTopLeft(_anchorGuide).dy,
            closeTo(tester.getTopLeft(find.text('Transcript 0')).dy, 1.5),
          );
          expect(prefs.getDouble(preference), isNull);
          expect(
            portrait
                ? settings.musicLyricAnchorPortrait
                : settings.musicLyricAnchorLandscape,
            MusicLyricAnchor.automatic,
          );
          await _capture(
            tester,
            '${platform.name}-${portrait ? 'portrait' : 'landscape'}-anchor-drag',
          );
          await gesture.up();
          await tester.pump();
          expect(prefs.getDouble(preference), value);
          expect(_settingsBackgroundAlpha(tester), normalAlpha);
          expect(
            tester.widget<MusicLyricAnchorGuide>(_anchorGuide).visible,
            isTrue,
          );
          await tester.pump(const Duration(milliseconds: 900));
          expect(
            tester.widget<MusicLyricAnchorGuide>(_anchorGuide).visible,
            isTrue,
          );
          await tester.pump(const Duration(milliseconds: 200));
          expect(
            tester.widget<MusicLyricAnchorGuide>(_anchorGuide).visible,
            isFalse,
          );
          await tester.pumpAndSettle();

          await tester.tap(
            find.byKey(const ValueKey('music-lyric-anchor-reset')),
          );
          await tester.pumpAndSettle();
          expect(_lyrics(tester).anchorFraction, defaultAnchor);
          expect(
            tester.getTopLeft(find.text('Transcript 0')).dy,
            closeTo(originalTop, 1.5),
          );
          expect(prefs.getDouble(preference), MusicLyricAnchor.automatic);
          expect(
            tester
                .widget<IconButton>(
                  find.byKey(const ValueKey('music-lyric-anchor-reset')),
                )
                .onPressed,
            isNull,
          );
          expect(seeks, isEmpty);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }

    testWidgets('$platform anchor guide follows a clamped bilingual paragraph', (
      tester,
    ) async {
      const paragraph =
          'We walk through the city, taking time to listen. Every street tells a story.';
      const translation = '慢慢走过这座城市，听听街道里的故事，重新认识身边的世界。';
      await _mount(
        tester,
        platform: platform,
        subtitles: [
          SubtitleItem(
            index: 0,
            startTime: Duration.zero,
            endTime: const Duration(minutes: 1),
            text: paragraph,
            lyricTranslation: translation,
          ),
        ],
      );
      await _openSettings(tester);
      final slider = tester.widget<Slider>(_anchorSlider);
      slider.onChangeStart!(slider.value);
      slider.onChanged!(0.7);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      final view = _lyrics(tester);
      final guideTop = tester.getTopLeft(_anchorGuide).dy;
      final viewRect = tester.getRect(find.byType(MusicLyricView));
      expect(
        guideTop,
        lessThan(viewRect.top + viewRect.height * view.anchorFraction - 10),
      );
      expect(
        guideTop,
        closeTo(tester.getTopLeft(find.text(paragraph)).dy, 1.5),
      );
      expect(
        tester.getBottomLeft(find.text(translation)).dy,
        lessThanOrEqualTo(viewRect.bottom - view.focusInsets!.bottom + 1),
      );
      await _capture(tester, '${platform.name}-paragraph-anchor-drag');
      slider.onChangeEnd!(0.7);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'anchor settings switch layouts and reset only the current layout',
    (tester) async {
      final settings = await _mount(
        tester,
        preferences: {
          'musicLyricAnchorPortrait': 0.18,
          'musicLyricAnchorLandscape': 0.62,
        },
      );
      await _openSettings(tester);
      expect(tester.widget<Slider>(_anchorSlider).value, 0.18);
      tester.view.physicalSize = const Size(1440, 900);
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(_anchorSlider).value, 0.62);
      expect(_lyrics(tester).anchorFraction, 0.62);
      final bounds = tester.getRect(_panel);
      await tester.tap(find.byKey(const ValueKey('music-lyric-anchor-reset')));
      await tester.pumpAndSettle();
      expect(tester.getRect(_panel), bounds);
      expect(settings.musicLyricAnchorLandscape, MusicLyricAnchor.automatic);
      expect(settings.musicLyricAnchorPortrait, 0.18);
      expect(_lyrics(tester).anchorFraction, 0.30);
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(_anchorSlider).value, 0.18);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('closing an anchor preview saves and clears its timer', (
    tester,
  ) async {
    await _mount(tester);
    await _openSettings(tester);
    tester.widget<Slider>(_anchorSlider).onChanged!(0.47);
    await tester.pump();
    await tester.tap(find.byTooltip('关闭页面设置'));
    await tester.pumpAndSettle();
    expect(_lyrics(tester).showAnchorGuide, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('musicLyricAnchorPortrait'), 0.47);
    await _openSettings(tester);
    expect(_settingsBackgroundAlpha(tester), greaterThan(0.9));
    tester.widget<Slider>(_anchorSlider).onChanged!(0.38);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(prefs.getDouble('musicLyricAnchorPortrait'), 0.38);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'each reset is stationary and applies only to the current layout',
    (tester) async {
      final settings = await _mount(
        tester,
        preferences: {
          'musicLyricFontSizeScalePortrait': 0.8123456,
          'musicLyricFontSizeScaleLandscape': 1.9876543,
          'musicLyricSpacingScalePortrait': 0.3456789,
          'musicLyricSpacingScaleLandscape': 2.8765432,
        },
      );
      await _openSettings(tester);
      expect(tester.widget<Slider>(_fontSlider).value, 0.8123456);
      expect(tester.widget<Slider>(_spacingSlider).value, 0.3456789);

      tester.view.physicalSize = const Size(1440, 900);
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(_fontSlider).value, 1.9876543);
      expect(tester.widget<Slider>(_spacingSlider).value, 2.8765432);
      await _capture(tester, 'desktop-custom');
      final bounds = tester.getRect(_panel);
      for (final entry in [
        ('music-font-size-reset', _fontSlider),
        ('music-lyric-spacing-reset', _spacingSlider),
      ]) {
        final reset = find.byKey(ValueKey(entry.$1));
        final resetBounds = tester.getRect(reset);
        await tester.tap(reset);
        await tester.pumpAndSettle();
        expect(tester.widget<Slider>(entry.$2).value, 1);
        expect(tester.widget<IconButton>(reset).onPressed, isNull);
        expect(tester.getRect(reset), resetBounds);
        expect(tester.getRect(_panel), bounds);
      }
      expect(settings.musicLyricFontSizeScaleLandscape, 1);
      expect(settings.musicLyricSpacingScaleLandscape, 1);
      expect(settings.musicLyricFontSizeScalePortrait, 0.8123456);
      expect(settings.musicLyricSpacingScalePortrait, 0.3456789);
      await _capture(tester, 'desktop-default');

      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(_fontSlider).value, 0.8123456);
      expect(tester.widget<Slider>(_spacingSlider).value, 0.3456789);
      await tester.tap(find.byKey(const ValueKey('music-font-size-reset')));
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(_spacingSlider).value, 0.3456789);
      await tester.tap(find.byKey(const ValueKey('music-lyric-spacing-reset')));
      await tester.pumpAndSettle();
      expect(settings.musicLyricFontSizeScalePortrait, 1);
      expect(settings.musicLyricSpacingScalePortrait, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('closing during a preview still saves the last value', (
    tester,
  ) async {
    await _mount(tester);
    await _openSettings(tester);
    tester.widget<Slider>(_spacingSlider).onChanged!(0.1234567);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('musicLyricSpacingScalePortrait'), 0.1234567);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'portrait controls stay visible while idle and scrolling by default',
    (tester) async {
      await _mount(tester);
      await _idle(tester);
      _expectControls(tester, true);
      await tester.dragFrom(const Offset(200, 440), const Offset(0, -140));
      await _idle(tester);
      _expectControls(tester, true);
      await _openSettings(tester);
      expect(tester.widget<CupertinoSwitch>(_autoHideSwitch).value, isFalse);
      expect(find.text('页面设置'), findsOneWidget);
      expect(find.text('仅竖屏 · 闲置 5 秒或滚动歌词时隐藏'), findsOneWidget);
      await _capture(tester, 'portrait');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'auto hide can be enabled and disabled without hiding the open panel',
    (tester) async {
      final settings = await _mount(tester);
      await _openSettings(tester);
      await tester.tap(_autoHideSwitch);
      await tester.pumpAndSettle();
      expect(settings.musicPortraitControlsAutoHide, isTrue);
      expect(tester.widget<CupertinoSwitch>(_autoHideSwitch).value, isTrue);
      await _idle(tester);
      expect(_panel, findsOneWidget);
      _expectControls(tester, true);

      // Closing must schedule its own frame, even with playback paused.
      await tester.tapAt(const Offset(8, 220));
      expect(tester.binding.hasScheduledFrame, isTrue);
      await tester.pump();
      expect(_panel, findsNothing);
      await _idle(tester);
      _expectControls(tester, false);

      await tester.tapAt(const Offset(8, 220));
      await tester.pumpAndSettle();
      _expectControls(tester, true);
      await _openSettings(tester);
      // Tapping the label should also toggle exactly once.
      await tester.tap(find.text('自动隐藏播放控件'));
      await tester.pumpAndSettle();
      expect(settings.musicPortraitControlsAutoHide, isFalse);
      expect(tester.widget<CupertinoSwitch>(_autoHideSwitch).value, isFalse);
      await tester.tap(find.byTooltip('关闭页面设置'));
      await tester.pump();
      expect(_panel, findsNothing);
      await _idle(tester);
      _expectControls(tester, true);
      await tester.dragFrom(const Offset(200, 440), const Offset(0, -140));
      await _idle(tester);
      _expectControls(tester, true);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'saved auto hide applies on entry and back closes settings first',
    (tester) async {
      await _mount(tester, autoHide: true);
      await _idle(tester);
      _expectControls(tester, false);
      await tester.tapAt(const Offset(8, 220));
      await tester.pumpAndSettle();
      await _openSettings(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_panel, findsNothing);
      expect(find.byType(MusicPlayerScreen), findsOneWidget);
      await _openSettings(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(_panel, findsNothing);
      expect(find.byType(MusicPlayerScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final layout in [
    (const Size(844, 390), 1.0),
    (const Size(320, 640), 1.8),
  ]) {
    testWidgets('page settings fit $layout and auto hide is portrait only', (
      tester,
    ) async {
      await _mount(
        tester,
        size: layout.$1,
        textScale: layout.$2,
        autoHide: true,
      );
      await _openSettings(tester);
      final bounds = tester.getRect(_panel);
      expect(bounds.left, greaterThanOrEqualTo(8));
      expect(bounds.top, greaterThanOrEqualTo(8));
      expect(bounds.right, lessThanOrEqualTo(layout.$1.width - 8));
      expect(bounds.bottom, lessThanOrEqualTo(layout.$1.height - 8));
      final portrait = layout.$1.width < layout.$1.height;
      expect(_autoHideRow, portrait ? findsOneWidget : findsNothing);
      if (portrait) {
        await tester.ensureVisible(_autoHideSwitch);
        await tester.pumpAndSettle();
        await tester.tap(_autoHideSwitch);
        await tester.pumpAndSettle();
        expect(tester.widget<CupertinoSwitch>(_autoHideSwitch).value, isFalse);
      }
      expect(tester.takeException(), isNull);
      await _capture(tester, portrait ? 'small-large-text' : 'landscape');
      await tester.tapAt(const Offset(8, 200));
      await tester.pump();
      expect(_panel, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
