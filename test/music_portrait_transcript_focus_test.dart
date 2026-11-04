import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/screens/music_player_screen.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/music_playback_controls.dart';

Finder get _controls =>
    find.byKey(const ValueKey('music-portrait-controls-overlay'));

Future<void> _capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('CAPTURE_MUSIC_FOCUS')) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('music-focus-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('.artifacts/music-portrait-focus/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void _expectControls(WidgetTester tester, bool visible) {
  final fade = tester.widget<FadeTransition>(
    find.descendant(of: _controls, matching: find.byType(FadeTransition)).first,
  );
  expect(fade.opacity.value, visible ? 1 : 0);
  expect(
    tester
        .widget<IgnorePointer>(
          find
              .descendant(of: _controls, matching: find.byType(IgnorePointer))
              .first,
        )
        .ignoring,
    !visible,
  );
}

Future<void> _mount(
  WidgetTester tester, {
  TargetPlatform platform = TargetPlatform.android,
  Size size = const Size(390, 844),
  double textScale = 1,
  EdgeInsets padding = EdgeInsets.zero,
  bool podcast = false,
  bool autoHideControls = false,
  ValueChanged<Duration>? onSeek,
  List<SubtitleItem>? subtitles,
  ValueNotifier<double>? textScaleNotifier,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final playback = MediaPlaybackService.forTesting();
  final settings = SettingsService()..resetForTest();
  settings.musicPortraitControlsAutoHide = autoHideControls;
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
  addTearDown(playback.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsService>.value(value: settings),
        ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
      ],
      child: MaterialApp(
        theme: ThemeData(platform: platform),
        builder: (context, child) => ValueListenableBuilder<double>(
          valueListenable:
              textScaleNotifier ?? AlwaysStoppedAnimation(textScale),
          builder: (context, scale, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              padding: padding,
              viewPadding: padding,
            ),
            child: RepaintBoundary(
              key: const ValueKey('music-focus-capture'),
              child: child!,
            ),
          ),
          child: child,
        ),
        home: MusicPlayerScreen(
          title: podcast
              ? 'A long podcast episode title that wraps onto two lines'
              : 'Music track',
          artist: podcast ? 'Podcast channel' : '',
          detailsAction: podcast
              ? IconButton(onPressed: () {}, icon: const Icon(Icons.notes))
              : null,
          onSeek: onSeek,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
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
    )..addFont(rootBundle.load('assets/fonts/Inter-Regular.otf'))).load();
  });
  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.windows,
  ]) {
    for (final podcast in [false, true]) {
      testWidgets(
        '$platform podcast=$podcast subtitle taps preserve controls',
        (tester) async {
          final seeks = <Duration>[];
          await _mount(
            tester,
            platform: platform,
            podcast: podcast,
            onSeek: seeks.add,
            autoHideControls: true,
          );
          _expectControls(tester, true);
          await tester.tap(find.text('Transcript 1'));
          await tester.pumpAndSettle();
          expect(seeks, [const Duration(seconds: 10)]);
          _expectControls(tester, true);

          await tester.pump(const Duration(seconds: 6));
          await tester.pumpAndSettle();
          _expectControls(tester, false);
          for (final index in [2, 3]) {
            await tester.tap(find.text('Transcript $index'));
            await tester.pump();
            _expectControls(tester, false);
            await tester.pumpAndSettle();
            _expectControls(tester, false);
          }
          expect(seeks, [
            const Duration(seconds: 10),
            const Duration(seconds: 20),
            const Duration(seconds: 30),
          ]);
          // A later background tap must still wake the controls.
          await tester.tapAt(const Offset(8, 350));
          await tester.pumpAndSettle();
          _expectControls(tester, true);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  for (final layout in [
    (const Size(390, 844), 1.0, const EdgeInsets.only(top: 47, bottom: 34)),
    (const Size(320, 640), 1.7, const EdgeInsets.only(top: 24, bottom: 24)),
    (const Size(430, 932), 2.0, const EdgeInsets.only(top: 59, bottom: 34)),
  ]) {
    testWidgets('portrait focus clears header and controls at $layout', (
      tester,
    ) async {
      final seeks = <Duration>[];
      await _mount(
        tester,
        size: layout.$1,
        textScale: layout.$2,
        padding: layout.$3,
        podcast: true,
        onSeek: seeks.add,
        autoHideControls: true,
      );
      void expectFocusClear(String text) {
        final header = tester.getRect(
          find.byKey(const ValueKey('music-portrait-header')),
        );
        final controls = tester.getRect(find.byType(MusicPlaybackControls));
        final line = tester.getRect(find.text(text));
        expect(line.top, greaterThan(header.bottom + 32));
        expect(line.bottom, lessThan(controls.top - 24));
      }

      expectFocusClear('Transcript 0');
      await _capture(tester, 'portrait-${layout.$1.width.toInt()}-visible');
      final beforeHide = tester.getTopLeft(find.text('Transcript 0'));
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('Transcript 0')), beforeHide);
      await tester.tap(find.text('Transcript 1'));
      await tester.pumpAndSettle();
      expect(seeks, [const Duration(seconds: 10)]);
      _expectControls(tester, false);
      expectFocusClear('Transcript 1');
      await _capture(tester, 'portrait-${layout.$1.width.toInt()}-hidden-seek');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.windows,
  ]) {
    for (final index in [0, 1]) {
      testWidgets(
        '$platform bilingual podcast paragraph $index clears both fades',
        (tester) async {
          const paragraph =
              'We walk through the city, taking time to listen. '
              'Every street tells a story.';
          const translation = '慢慢走过这座城市，听听街道里的故事，重新认识身边的世界。';
          await _mount(
            tester,
            podcast: true,
            platform: platform,
            onSeek: (_) {},
            padding: const EdgeInsets.only(top: 47, bottom: 34),
            subtitles: [
              if (index == 1)
                SubtitleItem(
                  index: 0,
                  startTime: Duration.zero,
                  endTime: const Duration(seconds: 10),
                  text: 'Opening line',
                ),
              SubtitleItem(
                index: index,
                startTime: Duration(seconds: index * 10),
                endTime: const Duration(minutes: 1),
                text: paragraph,
                lyricTranslation: translation,
              ),
            ],
          );
          if (index == 1) {
            await tester.tapAt(
              tester.getTopLeft(find.text(paragraph)) + const Offset(40, 24),
            );
            await tester.pumpAndSettle();
          }
          final header = tester.getRect(
            find.byKey(const ValueKey('music-portrait-header')),
          );
          final controls = tester.getRect(find.byType(MusicPlaybackControls));
          final main = tester.getRect(find.text(paragraph));
          final secondary = tester.getRect(find.text(translation));
          expect(main.top, greaterThan(header.bottom + 28));
          expect(
            secondary.bottom,
            lessThan(controls.top - 85),
            reason:
                'main=$main secondary=$secondary header=$header controls=$controls',
          );
          expect(tester.takeException(), isNull);
          await _capture(tester, '${platform.name}-bilingual-$index');
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets('changing system text size relocates the current paragraph', (
    tester,
  ) async {
    final scale = ValueNotifier(1.0);
    addTearDown(scale.dispose);
    await _mount(tester, podcast: true, textScaleNotifier: scale);
    final before = tester.getTopLeft(find.text('Transcript 0')).dy;
    scale.value = 1.8;
    await tester.pumpAndSettle();
    final header = tester.getRect(
      find.byKey(const ValueKey('music-portrait-header')),
    );
    final line = tester.getRect(find.text('Transcript 0'));
    expect(line.top, greaterThan(header.bottom + 40));
    expect(line.top, greaterThan(before));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
