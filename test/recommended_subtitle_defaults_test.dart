import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/recommended_subtitle_defaults.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/utils/subtitle_font_resolver.dart';
import 'package:video_player_app/widgets/subtitle_overlay.dart';
import 'package:video_player_app/services/subtitle_position_controller.dart';

const _primary = '风起时，我们再次相遇。';
const _secondary = 'When the wind rises, we meet again.';
final _captureKey = GlobalKey();
const _style = SubtitleStyle(
  textStyle: RecommendedSubtitleDefaults.textStyle,
  layoutStyle: RecommendedSubtitleDefaults.layout,
);

Future<void> _mount(
  WidgetTester tester, {
  required Size page,
  required bool ghost,
  double sidebar = 0,
  double aspectRatio = 16 / 9,
  double overallScale = 1,
  bool controls = false,
  Alignment? alignment,
  SubtitlePositionController? positionController,
  String primaryText = _primary,
  String secondaryText = _secondary,
  double? playerAspectRatio,
}) async {
  await tester.binding.setSurfaceSize(page);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark().copyWith(
        textTheme: ThemeData.dark().textTheme.apply(
          fontFamily: 'Swei Gothic CJK SC',
        ),
      ),
      home: RepaintBoundary(
        key: _captureKey,
        child: Scaffold(
          body: Row(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final size = constraints.biggest;
                    final playerSize = playerAspectRatio == null
                        ? size
                        : applyBoxFit(
                            BoxFit.contain,
                            Size(playerAspectRatio, 1),
                            size,
                          ).destination;
                    final videoSize = applyBoxFit(
                      BoxFit.contain,
                      Size(aspectRatio, 1),
                      playerSize,
                    ).destination;
                    final overlay = SubtitleOverlayGroup(
                      entries: [
                        SubtitleOverlayEntry(
                          text: primaryText,
                          secondaryText: secondaryText,
                        ),
                      ],
                      style: _style.copyWith(
                        layoutStyle: _style.layoutStyle.copyWith(
                          overallScale: overallScale,
                        ),
                      ),
                      alignment:
                          alignment ??
                          (ghost
                              ? RecommendedSubtitleDefaults.ghostAlignment
                              : RecommendedSubtitleDefaults.ordinaryAlignment),
                      positionController: positionController,
                      isGhostMode: ghost,
                      fullPageSize: page,
                      referenceHeight: videoSize.height,
                      enableDebugPreview: false,
                      avoidPlaybackControls: controls,
                      playbackControlsVisibility: controls
                          ? const AlwaysStoppedAnimation(true)
                          : null,
                      playbackControlsTop: controls ? size.height - 90 : null,
                    );
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        const ColoredBox(color: Color(0xff101820)),
                        Center(
                          child: SizedBox.fromSize(
                            size: videoSize,
                            child: DecoratedBox(
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    Color(0xff547e84),
                                    Color(0xff1a3449),
                                  ],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                              ),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [if (!ghost) overlay],
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          top: 18,
                          left: 18,
                          child: Text(
                            '${ghost ? '幽灵模式' : '普通模式'} | '
                            '${page.width.toInt()} × ${page.height.toInt()}',
                            style: const TextStyle(color: Colors.white70),
                          ),
                        ),
                        if (ghost) overlay,
                        if (controls)
                          Positioned(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            height: 90,
                            child: Container(color: Colors.black54),
                          ),
                      ],
                    );
                  },
                ),
              ),
              if (sidebar > 0)
                SizedBox(
                  width: sidebar,
                  child: const ColoredBox(
                    color: Color(0xff202830),
                    child: Center(child: Text('字幕侧栏')),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

List<TextStyle> _renderedStyles(WidgetTester tester, String text) {
  final styles = <TextStyle>[];
  String compact(String value) => value.replaceAll(RegExp(r'\s+'), '');
  final source = compact(text);
  void visit(InlineSpan span, [TextStyle? inherited]) {
    final style = span is TextSpan
        ? (inherited ?? const TextStyle()).merge(span.style)
        : inherited;
    if (span is TextSpan && span.text != null && style?.fontSize != null) {
      final fragment = compact(span.text!);
      if (RegExp(r'[A-Za-z\u4e00-\u9fff]').hasMatch(fragment) &&
          source.contains(fragment)) {
        styles.add(style!);
      }
    }
    span.visitDirectChildren((child) {
      visit(child, style);
      return true;
    });
  }

  for (final rich in tester.widgetList<RichText>(
    find.descendant(
      of: find.byType(SubtitleOverlayGroup),
      matching: find.byType(RichText),
    ),
  )) {
    visit(rich.text);
  }
  expect(styles, isNotEmpty, reason: 'Missing rendered styles for $text');
  return styles;
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (Platform.environment['SUBTITLE_DEFAULT_PREVIEWS'] != '1') return;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_captureKey),
    );
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('.artifacts/default-subtitle-settings');
    await directory.create(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  test('all languages use Swei and the requested effects survive JSON', () {
    final text = SubtitleTextStyle.fromJson(
      RecommendedSubtitleDefaults.textStyle.toJson(),
    );
    for (final sample in [
      ('zh', _primary),
      ('en', _secondary),
      ('ja', '風が吹くと、また会いましょう。'),
      ('ko', '바람이 불면 다시 만나요.'),
      ('ru', 'Когда поднимается ветер'),
      ('ar', 'عندما تهب الرياح'),
      ('hi', 'हवा चलने पर'),
      ('fr', 'Quand le vent se lève'),
      ('th', 'เมื่อสายลมพัด'),
    ]) {
      final runs = resolveSubtitleFontRuns(
        sample.$2,
        text,
        language: sample.$1,
      );
      expect(runs, isNotEmpty);
      for (final run in runs) {
        expect(run.font.family, 'Swei Gothic CJK SC');
        expect(run.font.weight, 700);
      }
    }
    expect(text.hasBorder, true);
    expect(text.borderColor.toARGB32(), Colors.black.toARGB32());
    expect(text.borderWidth, 4);
    expect(text.hasShadow, true);
    expect(text.shadowBlur, 3.5);
    expect(text.shadowOffset, const Offset(2.5, 2.5));
    expect(text.backgroundEnabled, true);
    expect(text.backgroundColor.toARGB32(), Colors.black.toARGB32());
    expect(text.backgroundOpacity, .9);
    expect(
      SubtitleLayoutStyle.fromJson(_style.layoutStyle.toJson()).adaptiveSizing,
      false,
    );
    expect(SubtitleLayoutStyle.fromJson({}).adaptiveSizing, false);
    expect(SubtitleLayoutStyle.fromJson({}).balancedScreenSizing, false);
    expect(
      SubtitleLayoutStyle.fromJson(
        _style.layoutStyle.toJson(),
      ).balancedScreenSizing,
      true,
    );
  });

  testWidgets(
    'ordinary captions scale with video while ghost captions use screen reading sizes',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() async {
        await (FontLoader('Swei Gothic CJK SC')..addFont(
              rootBundle.load('assets/fonts/SweiGothicCJKsc-Bold.ttf'),
            ))
            .load();
      });
      for (final device in [
        ('small-phone', const Size(320, 568), 0.0, 16.0),
        ('phone-portrait', const Size(390, 844), 0.0, 17.0),
        ('phone-landscape', const Size(844, 390), 0.0, 17.0),
        ('tablet-portrait', const Size(768, 1024), 0.0, 23.8560),
        ('tablet-2880-dpr24', const Size(1200, 750), 0.0, 23.5748),
        ('tablet-2880-dpr24-sidebar', const Size(1200, 750), 300.0, 23.5748),
        ('tablet-2880-dpr2', const Size(1440, 900), 320.0, 25.8249),
        ('tablet-landscape', const Size(1366, 1024), 320.0, 26.0),
        ('desktop', const Size(1920, 1080), 360.0, 26.0),
        ('desktop-4k-logical', const Size(3840, 2160), 480.0, 26.0),
      ]) {
        for (final ghost in [false, true]) {
          await _mount(
            tester,
            page: device.$2,
            ghost: ghost,
            sidebar: device.$3,
          );
          final primary = _renderedStyles(tester, _primary);
          final secondary = _renderedStyles(tester, _secondary);
          final viewport = tester.getRect(find.byType(SubtitleOverlayGroup));
          final expectedSize = ghost
              ? device.$4
              : device.$4 * viewport.size.shortestSide / device.$2.shortestSide;
          for (final style in primary) {
            expect(style.fontSize, closeTo(expectedSize, .01));
            expect(style.fontFamily, 'Swei Gothic CJK SC');
          }
          for (final style in secondary) {
            expect(style.fontSize, closeTo(expectedSize * .85, .01));
            expect(
              style.fontSize! / primary.first.fontSize!,
              closeTo(.85, 1e-8),
            );
          }
          final richTexts = find.descendant(
            of: find.byType(SubtitleOverlayGroup),
            matching: find.byType(RichText),
          );
          for (final element in richTexts.evaluate()) {
            final rect = tester.getRect(find.byWidget(element.widget));
            expect(viewport.inflate(.1).contains(rect.topLeft), true);
            expect(viewport.inflate(.1).contains(rect.bottomRight), true);
          }
          await _capture(
            tester,
            '${device.$1}-${ghost ? 'ghost' : 'ordinary'}',
          );
        }
      }
    },
  );

  testWidgets('ghost sizes stay stable with sidebars and video shapes', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    double? original;
    for (final aspect in [16 / 9, 4 / 3, 9 / 16, 2.4]) {
      for (final sidebar in [0.0, 320.0, 640.0]) {
        await _mount(
          tester,
          page: const Size(1280, 720),
          ghost: true,
          sidebar: sidebar,
          aspectRatio: aspect,
        );
        final size = _renderedStyles(tester, _primary).first.fontSize!;
        original ??= size;
        expect(size, closeTo(original, 1e-8));
      }
    }
    await _mount(
      tester,
      page: const Size(1280, 720),
      ghost: true,
      overallScale: 1.25,
      controls: true,
    );
    expect(
      _renderedStyles(tester, _primary).first.fontSize,
      closeTo(original! * 1.25, 1e-8),
    );
    final richTexts = find.descendant(
      of: find.byType(SubtitleOverlayGroup),
      matching: find.byType(RichText),
    );
    for (final element in richTexts.evaluate()) {
      expect(
        tester.getBottomRight(find.byWidget(element.widget)).dy,
        lessThan(630),
      );
    }
  });

  for (final screen in [
    const Size(390, 844),
    const Size(750, 1200), // 2880 x 1800 physical tablet at 2.4 DPR.
    const Size(800, 1280),
  ]) {
    testWidgets(
      'ordinary video proportions and position survive rotation on $screen',
      (tester) async {
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.runAsync(() async {
          await (FontLoader('Swei Gothic CJK SC')..addFont(
                rootBundle.load('assets/fonts/SweiGothicCJKsc-Bold.ttf'),
              ))
              .load();
        });
        final controller = SubtitlePositionController();
        addTearDown(controller.dispose);
        for (final aspect in [16 / 9, 4 / 3, 9 / 16, 2.4]) {
          for (final long in [false, true]) {
            final primary = long
                ? '这是用来验证横竖屏字幕排版的较长句子，字幕应该保持相对于视频画面相同的大小和位置。'
                : _primary;
            final secondary = long
                ? 'These longer bilingual captions must keep the same size and position relative to the video after rotation.'
                : _secondary;
            final alignment = long
                ? const Alignment(-.25, .4)
                : RecommendedSubtitleDefaults.ordinaryAlignment;
            List<double>? baseline;
            for (final scenario in [
              (screen, 0.0, 16 / 9),
              (screen.flipped, 0.0, null),
              (screen.flipped, screen.shortestSide * .3, null),
            ]) {
              await _mount(
                tester,
                page: scenario.$1,
                ghost: false,
                sidebar: scenario.$2,
                playerAspectRatio: scenario.$3,
                aspectRatio: aspect,
                positionController: controller,
                alignment: alignment,
                overallScale: long ? 1.25 : 1,
                primaryText: primary,
                secondaryText: secondary,
              );
              final geometry = controller.geometry.current!;
              final video = geometry.viewport;
              final mainSize = _renderedStyles(tester, primary).first.fontSize!;
              final secondarySize = _renderedStyles(
                tester,
                secondary,
              ).first.fontSize!;
              final rect = geometry.contentRect;
              final relative = [
                mainSize / video.shortestSide,
                secondarySize / video.shortestSide,
                rect.left / video.width,
                rect.top / video.height,
                rect.right / video.width,
                rect.bottom / video.height,
              ];
              baseline ??= relative;
              for (var index = 0; index < relative.length; index++) {
                expect(
                  relative[index],
                  closeTo(baseline[index], index < 2 ? 1e-8 : .02),
                  reason: 'aspect=$aspect, page=${scenario.$1}, metric=$index',
                );
              }
              expect(secondarySize / mainSize, closeTo(.85, 1e-8));
            }
          }
        }
      },
    );
  }
}
