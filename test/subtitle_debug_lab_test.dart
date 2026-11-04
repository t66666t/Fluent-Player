import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_debug_preset.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/subtitle_debug_session.dart';
import 'package:video_player_app/widgets/subtitle_debug_panel.dart';
import 'package:video_player_app/widgets/subtitle_debug_speed_gateway.dart';
import 'package:video_player_app/widgets/subtitle_overlay.dart';

void main() {
  final session = SubtitleDebugSession.instance;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    session.resetForTest();
    await session.initialize();
  });
  tearDown(() async {
    session.resetForTest();
  });

  testWidgets('preview restores actual rendered style and export opts out', (
    tester,
  ) async {
    const original = SubtitleStyle();
    Future<void> mount({bool export = false}) => tester.pumpWidget(
      MaterialApp(
        home: SubtitleOverlayGroup(
          enableDebugPreview: !export,
          entries: const [
            SubtitleOverlayEntry(text: '中文', secondaryText: 'English'),
          ],
          style: original,
          alignment: Alignment.bottomCenter,
        ),
      ),
    );
    session.toggle();
    session.select(subtitleDebugPresets[24]);
    await mount();
    expect(find.byType(SubtitleOverlay), findsNWidgets(2));
    await mount(export: true);
    expect(find.byType(SubtitleOverlay), findsOneWidget);
    expect(
      tester.widget<SubtitleOverlay>(find.byType(SubtitleOverlay)).style,
      same(original),
    );
    await mount();
    session.close();
    await tester.pump();
    expect(find.byType(SubtitleOverlay), findsOneWidget);
    expect(
      tester.widget<SubtitleOverlay>(find.byType(SubtitleOverlay)).style,
      same(original),
    );
  });

  testWidgets(
    'long bilingual text scales into a small viewport without overflow',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 180);
      addTearDown(tester.view.reset);
      session.toggle();
      session.select(subtitleDebugPresets[44]);
      await tester.pumpWidget(
        MaterialApp(
          home: SubtitleOverlayGroup(
            entries: [
              SubtitleOverlayEntry(
                text: List.filled(8, '这是一句用于检查自动折行的较长中文字幕。').join(),
                secondaryText: List.filled(
                  8,
                  'A longer subtitle used to check wrapping and safe boundaries.',
                ).join(),
              ),
            ],
            style: const SubtitleStyle(),
            alignment: Alignment.bottomCenter,
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final pair = tester.getRect(find.byType(FittedBox));
      expect(pair.top, greaterThanOrEqualTo(0));
      expect(pair.bottom, lessThanOrEqualTo(180));
    },
  );

  Future<void> speedButton(WidgetTester tester, VoidCallback onSpeed) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SubtitleDebugSpeedGateway(
              builder: (context, onLongPress) => TextButton(
                onPressed: onSpeed,
                onLongPress: onLongPress,
                child: const Text('倍速'),
              ),
            ),
          ),
        ),
      );

  testWidgets('long press toggles both ways without opening speed popup', (
    tester,
  ) async {
    int opened = 0;
    await speedButton(tester, () => opened++);
    for (int cycle = 0; cycle < 2; cycle++) {
      await tester.longPress(find.text('倍速'));
      await tester.pump();
      expect(session.enabled, cycle == 0);
      if (cycle == 0) session.select(subtitleDebugPresets.first);
      expect(opened, 0);
    }
    expect(session.preset, isNull);
  });

  testWidgets('taps open immediately and do not toggle the preset entry', (
    tester,
  ) async {
    int opened = 0;
    await speedButton(tester, () => opened++);
    await tester.tap(find.text('倍速'));
    expect(opened, 1);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('倍速'));
    expect(opened, 2);
    await tester.pump(const Duration(milliseconds: 500));
    for (int i = 0; i < 3; i++) {
      await tester.tap(find.text('倍速'));
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(session.enabled, isFalse);
    expect(opened, 5);
  });

  testWidgets('removing the speed button after a tap does not open again', (
    tester,
  ) async {
    int opened = 0;
    await speedButton(tester, () => opened++);
    await tester.tap(find.text('倍速'));
    expect(opened, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(opened, 1);
    expect(tester.takeException(), isNull);
  });

  test(
    'new process session defaults to off and selection never alters source',
    () {
      final fresh = SubtitleDebugSession();
      expect(fresh.enabled, isFalse);
      expect(fresh.preset, isNull);
      const original = SubtitleStyle();
      final json = original.toJson();
      session.toggle();
      session.select(subtitleDebugPresets.first);
      session.close();
      expect(original.toJson(), json);
      expect(session.preset, isNull);
      fresh.dispose();
    },
  );

  test(
    '48 distinct presets use bundled licensed families and actual weights',
    () {
      expect(subtitleDebugPresets.length, 48);
      expect(subtitleDebugPresets.map((p) => p.id).toSet().length, 48);
      const weights = {
        'Noto Sans SC': [100, 200, 300, 400, 500, 700, 900],
        'Noto Serif CJK SC': [400, 700],
        'Inter': [100, 200, 300, 400, 500, 600, 700, 800, 900],
        'Roboto': [100, 200, 300, 400, 500, 600, 700, 800, 900],
        'Comic Relief': [400, 700],
        'Brawler': [400, 700],
      };
      for (final p in subtitleDebugPresets) {
        expect(weights[p.primaryFont], contains(p.primaryWeight));
        expect(weights[p.secondaryFont], contains(p.secondaryWeight));
        expect(
          p.styleFor(secondary: true).fontSize,
          closeTo(p.size * p.ratio, .001),
        );
      }
    },
  );

  testWidgets('panel stays hidden until enabled and can restore immediately', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 240,
            child: SingleChildScrollView(child: SubtitleDebugPanel()),
          ),
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey('subtitle-preset-full-height-scroll')),
      findsNothing,
    );
    session.toggle();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('subtitle-preset-full-height-scroll')),
      findsOneWidget,
    );
    await tester.tap(find.text('清幕标准'));
    await tester.pump();
    expect(session.preset?.name, '清幕标准');
    await tester.tap(find.text('使用原样式'));
    await tester.pump();
    expect(session.preset, isNull);
    session.close();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('subtitle-preset-full-height-scroll')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'all presets render both tracks inside wide, square and portrait viewports',
    (tester) async {
      session.toggle();
      for (final size in [
        const Size(1280, 720),
        const Size(1280, 536),
        const Size(800, 600),
        const Size(600, 600),
        const Size(360, 640),
      ]) {
        tester.view.reset();
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        for (final p in subtitleDebugPresets) {
          session.select(p);
          await tester.pumpWidget(
            MaterialApp(
              home: SizedBox.expand(
                child: SubtitleOverlayGroup(
                  entries: const [
                    SubtitleOverlayEntry(
                      text: '风起时，我们再次相遇。',
                      secondaryText: 'When the wind rises, we meet again.',
                    ),
                  ],
                  style: const SubtitleStyle(),
                  alignment: Alignment.bottomCenter,
                ),
              ),
            ),
          );
          await tester.pump();
          final blocks = find.byType(SubtitleOverlay);
          expect(blocks, findsNWidgets(2));
          final first = tester.getRect(blocks.at(0));
          final last = tester.getRect(blocks.at(1));
          expect(first.top, greaterThanOrEqualTo(0), reason: '${p.name} $size');
          expect(
            last.bottom,
            lessThanOrEqualTo(size.height - p.bottomInset(size) + 1),
          );
          expect(first.left, greaterThanOrEqualTo(0));
          expect(last.right, lessThanOrEqualTo(size.width));
          expect(tester.takeException(), isNull, reason: '${p.name} $size');
        }
      }
      tester.view.reset();
    },
  );
}
