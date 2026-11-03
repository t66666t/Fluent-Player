import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/subtitle_debug_preset.dart';
import 'package:video_player_app/models/subtitle_display_state.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/subtitle_debug_session.dart';
import 'package:video_player_app/widgets/subtitle_display_layer.dart';
import 'package:video_player_app/widgets/subtitle_overlay.dart';

const _style = SubtitleStyle(
  layoutStyle: SubtitleLayoutStyle(
    fontSize: 40,
    secondaryFontSize: 24,
    lineSpacing: 2,
    letterSpacing: 1,
  ),
);
const _entries = [SubtitleOverlayEntry(text: '字幕', secondaryText: 'Subtitle')];

// A player surface and sidebar share one page. Ghost captions fill the player
// surface, ordinary captions are constrained to the contained video rectangle.
Future<void> _mount(
  WidgetTester tester,
  ValueNotifier<SubtitleDisplayState> notifier, {
  Size page = const Size(1280, 720),
  double sidebar = 300,
  double aspectRatio = 16 / 9,
  double keyboard = 0,
  bool ghost = true,
  bool explicitPageSize = true,
  Alignment alignment = Alignment.bottomCenter,
  double? controlsTop,
  SubtitleStyle style = _style,
}) async {
  await tester.binding.setSurfaceSize(page);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: page,
          viewInsets: EdgeInsets.only(bottom: keyboard),
          viewPadding: const EdgeInsets.only(top: 20),
        ),
        child: Scaffold(
          resizeToAvoidBottomInset: false,
          body: SafeArea(
            child: Row(
              children: [
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final videoSize = applyBoxFit(
                        BoxFit.contain,
                        Size(aspectRatio, 1),
                        constraints.biggest,
                      ).destination;
                      final layer = SubtitleDisplayLayer(
                        notifier: notifier,
                        alignment: alignment,
                        style: style,
                        isGhostMode: ghost,
                        fullPageSize: explicitPageSize ? page : null,
                        // Even an old caller's video height must not influence
                        // ghost sizing, including when presets are selected.
                        referenceHeight: videoSize.height,
                        playbackControlsVisibility: controlsTop == null
                            ? null
                            : const AlwaysStoppedAnimation(true),
                        playbackControlsTop: controlsTop,
                        avoidPlaybackControls: controlsTop != null,
                      );
                      return ghost
                          ? layer
                          : Center(
                              child: SizedBox.fromSize(
                                size: videoSize,
                                child: layer,
                              ),
                            );
                    },
                  ),
                ),
                SizedBox(width: sidebar),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

List<TextStyle> _stylesFor(WidgetTester tester, String text) {
  final styles = <TextStyle>[];
  void visit(InlineSpan span) {
    // Explicit wrapping may split one source string into several spans.
    if (span is TextSpan &&
        span.text != null &&
        span.text!.trim().isNotEmpty &&
        text.contains(span.text!) &&
        span.style != null) {
      styles.add(span.style!);
    }
    span.visitDirectChildren((child) {
      visit(child);
      return true;
    });
  }

  for (final richText in tester.widgetList<RichText>(
    find.descendant(
      of: find.byType(SubtitleOverlayGroup),
      matching: find.byType(RichText),
    ),
  )) {
    visit(richText.text);
  }
  expect(styles, isNotEmpty, reason: 'must inspect rendered glyphs for $text');
  return styles;
}

void _expectFonts(WidgetTester tester, double primary, double secondary) {
  for (final pair in [('字幕', primary), ('Subtitle', secondary)]) {
    for (final style in _stylesFor(tester, pair.$1)) {
      expect(style.fontSize, closeTo(pair.$2, 1e-8));
    }
  }
}

void main() {
  final session = SubtitleDebugSession.instance;
  late ValueNotifier<SubtitleDisplayState> notifier;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    session.resetForTest();
    await session.initialize();
    notifier = ValueNotifier(const SubtitleDisplayState(entries: _entries));
  });
  tearDown(() async {
    await session.flush();
    session.resetForTest();
    notifier.dispose();
  });

  for (final preset in [false, true]) {
    testWidgets(
      'ghost ${preset ? 'preset' : 'original'} fonts ignore video, sidebar, keyboard and placement',
      (tester) async {
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var primary = 40.0, secondary = 24.0;
        if (preset) {
          await tester.runAsync(() async {
            await session.toggle();
            await session.select(subtitleDebugPresets.first);
            await session.updatePreset(session.preset!.copyWith(textScale: .8));
            await session.updateGhostTextScale(session.preset!.id, 1.4);
          });
          primary = session.preset!.size * 1.4;
          secondary = primary * session.preset!.ratio;
        }
        for (final ratio in [16 / 9, 2.4, 4 / 3, 1.0, 9 / 16]) {
          for (final width in [260.0, 600.0, 800.0]) {
            await _mount(
              tester,
              notifier,
              aspectRatio: ratio,
              sidebar: width,
              keyboard: width == 600 ? 260 : 0,
            );
            _expectFonts(tester, primary, secondary);
          }
        }
        await _mount(
          tester,
          notifier,
          alignment: Alignment.topLeft,
          controlsTop: 550,
        );
        _expectFonts(tester, primary, secondary);
        await _mount(tester, notifier, controlsTop: 550);
        _expectFonts(tester, primary, secondary);
        // Test the window-size fallback as well as explicit page propagation.
        await _mount(tester, notifier, explicitPageSize: false, sidebar: 800);
        _expectFonts(tester, primary, secondary);
        for (final page in [
          const Size(1000, 540),
          const Size(800, 1000),
          const Size(320, 568),
          const Size(3840, 2160),
        ]) {
          // Keep a usable caption surface even on the 320-wide phone.
          await _mount(
            tester, notifier, page: page,
            sidebar: page.width < 460 ? page.width / 2 : 300,
          );
          _expectFonts(
            tester,
            primary * page.shortestSide.clamp(360, 720) / 720,
            secondary * page.shortestSide.clamp(360, 720) / 720,
          );
        }
      },
    );
  }

  testWidgets('ordinary original and preset both follow the video short side', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final preset in [false, true]) {
      if (preset) {
        await tester.runAsync(() async {
          await session.toggle();
          await session.select(subtitleDebugPresets.first);
          await session.updateGhostTextScale(session.preset!.id, 1.8);
        });
      }
      for (final ratio in [16 / 9, 2.4, 4 / 3, 1.0, 9 / 16]) {
        await _mount(tester, notifier, ghost: false, aspectRatio: ratio);
        final size = tester.getSize(find.byType(SubtitleOverlayGroup));
        final reference = size.shortestSide;
        _expectFonts(
          tester,
          (preset ? session.preset!.size : 40) * reference / 720,
          (preset ? session.preset!.size * session.preset!.ratio : 24) *
              reference /
              720,
        );
      }
    }
  });

  testWidgets(
    'ordinary proportions survive orientation, device, resolution and old adaptive settings',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (final adaptive in [false, true]) {
        for (final page in [
          const Size(320, 568),
          const Size(390, 844),
          const Size(844, 390),
          const Size(768, 1024),
          const Size(1366, 1024),
          const Size(1920, 1080),
          const Size(3840, 2160),
        ]) {
          for (final aspect in [16 / 9, 9 / 16]) {
            await _mount(
              tester,
              notifier,
              page: page,
              sidebar: 0,
              ghost: false,
              aspectRatio: aspect,
              style: _style.copyWith(
                layoutStyle: _style.layoutStyle.copyWith(
                  adaptiveSizing: adaptive,
                ),
              ),
            );
            final viewport = tester.getSize(find.byType(SubtitleOverlayGroup));
            final primary = _stylesFor(tester, '字幕').first.fontSize!;
            final secondary = _stylesFor(tester, 'Subtitle').first.fontSize!;
            expect(primary / viewport.shortestSide, closeTo(40 / 720, 1e-8));
            expect(secondary / primary, closeTo(24 / 40, 1e-8));
          }
        }
      }
    },
  );

  testWidgets('long captions leave side margins in both playback modes', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    notifier.value = SubtitleDisplayState(
      entries: [
        SubtitleOverlayEntry(
          text: List.filled(12, '风起时，我们再次相遇。').join(),
          secondaryText: List.filled(
            8,
            'When the wind rises, we meet again. ',
          ).join(),
        ),
      ],
    );
    for (final ghost in [false, true]) {
      for (final page in [const Size(390, 844), const Size(1920, 1080)]) {
        await _mount(tester, notifier, page: page, sidebar: 0, ghost: ghost);
        final viewport = tester.getRect(find.byType(SubtitleOverlayGroup));
        for (final rich in tester.widgetList<RichText>(
          find.descendant(
            of: find.byType(SubtitleOverlayGroup),
            matching: find.byType(RichText),
          ),
        )) {
          final rect = tester.getRect(find.byWidget(rich));
          expect(
            rect.left,
            greaterThanOrEqualTo(viewport.left + viewport.width * .07),
          );
          expect(
            rect.right,
            lessThanOrEqualTo(viewport.right - viewport.width * .07),
          );
          expect(rich.text.toPlainText(), contains('When the wind rises'));
        }
      }
    }
  });

  testWidgets('long bilingual ghost captions wrap without changing font size', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final preset in [false, true]) {
      if (preset) {
        await tester.runAsync(() async {
          await session.toggle();
          await session.select(subtitleDebugPresets.first);
        });
      }
      notifier.value = SubtitleDisplayState(
        entries: [
          SubtitleOverlayEntry(
            text: List.filled(18, '字幕').join(),
            secondaryText: List.filled(18, 'Subtitle ').join().trim(),
          ),
        ],
      );
      await _mount(tester, notifier, page: const Size(800, 500), sidebar: 560);
      final text = tester.widgetList<RichText>(
        find.descendant(
          of: find.byType(SubtitleOverlayGroup),
          matching: find.byType(RichText),
        ),
      );
      expect(text, isNotEmpty);
      // A line is shorter than the complete subtitle; wrapping increases height.
      for (final rich in text) {
        final box = tester.getSize(find.byWidget(rich));
        expect(box.width, lessThanOrEqualTo(240));
        expect(box.height, greaterThan(40));
        rich.text.visitChildren((span) {
          if (span is TextSpan && span.style?.fontSize != null) {
            final base = preset
                ? (span.text!.contains('字幕')
                      ? session.preset!.size
                      : session.preset!.size * session.preset!.ratio)
                : (span.text!.contains('字幕') ? 40 : 24);
            expect(span.style!.fontSize, closeTo(base * 500 / 720, 1e-8));
          }
          return true;
        });
      }
    }
  });
}
