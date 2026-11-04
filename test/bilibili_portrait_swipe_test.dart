import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/bilibili/bilibili_player_panel_policy.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/bilibili_portrait_tabs.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';

void main() {
  testWidgets('touch follows the finger and retains both reading positions', (
    tester,
  ) async {
    final host = _Host();
    await host.mount(tester);
    host.detailsScroll.jumpTo(240);
    host.subtitleScroll.jumpTo(400);
    await tester.pump();
    final details = tester.element(find.byKey(_detailsList));
    final subtitles = tester.element(
      find.byKey(_subtitleList, skipOffstage: false),
    );
    final left = tester.getTopLeft(find.byKey(_detailsList)).dx;
    final gesture = await tester.startGesture(const Offset(280, 420));
    await gesture.moveBy(const Offset(-80, 0));
    await tester.pump();
    expect(
      tester.getTopLeft(find.byKey(_detailsList)).dx,
      closeTo(left - 80, .1),
    );
    expect(host.selections, isEmpty);
    await gesture.moveBy(const Offset(-80, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(host.tab, PortraitBilibiliTab.subtitles);
    expect(host.selections, [PortraitBilibiliTab.subtitles]);
    expect(tester.element(find.byKey(_subtitleList)), same(subtitles));
    expect(host.subtitleScroll.offset, 400);
    await host.swipe(
      tester,
      const Offset(200, 0),
      start: const Offset(80, 420),
    );
    expect(host.tab, PortraitBilibiliTab.details);
    expect(tester.element(find.byKey(_detailsList)), same(details));
    expect(host.detailsScroll.offset, 240);
    expect(host.rowTaps, 0);
  });

  testWidgets('a short slow drag returns; a short quick flick switches', (
    tester,
  ) async {
    final host = _Host();
    await host.mount(tester);
    await host.swipe(tester, const Offset(-60, 0));
    expect(host.selections, isEmpty);
    expect(tester.getTopLeft(find.byKey(_detailsList)).dx, 0);
    await host.swipe(
      tester,
      const Offset(-90, 0),
      duration: const Duration(milliseconds: 60),
    );
    expect(host.tab, PortraitBilibiliTab.subtitles);
  });

  testWidgets('outward swipes stop at the first and last tabs', (tester) async {
    final host = _Host();
    await host.mount(tester);
    await host.swipe(
      tester,
      const Offset(200, 0),
      start: const Offset(80, 420),
    );
    expect(host.selections, isEmpty);
    await host.swipe(tester, const Offset(-200, 0));
    await host.swipe(tester, const Offset(-200, 0));
    expect(host.selections, [PortraitBilibiliTab.subtitles]);
  });

  for (final delta in [const Offset(0, -180), const Offset(-200, -180)]) {
    testWidgets('$delta keeps vertical reading gestures', (tester) async {
      final host = _Host();
      await host.mount(tester);
      await host.swipe(tester, delta);
      expect(host.selections, isEmpty);
      expect(host.detailsScroll.offset, greaterThan(0));
      expect(host.rowTaps, 0);
    });
  }

  testWidgets('row taps, long presses, sliders and horizontal lists win', (
    tester,
  ) async {
    final host = _Host();
    await host.mount(tester);
    await tester.tapAt(const Offset(180, 420));
    await tester.pumpAndSettle();
    expect(host.rowTaps, 1);
    final hold = await tester.startGesture(const Offset(180, 420));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await hold.moveBy(const Offset(-150, 0));
    await hold.up();
    await tester.pumpAndSettle();
    expect(host.longPresses, 1);
    await tester.drag(find.byKey(_panelSlider), const Offset(130, 0));
    await tester.pumpAndSettle();
    expect(host.sliderValue, greaterThan(.5));
    await tester.drag(find.byKey(_horizontalList), const Offset(-180, 0));
    await tester.pumpAndSettle();
    expect(host.carouselScroll.offset, greaterThan(0));
    expect(host.selections, isEmpty);
  });

  for (final beginSwipe in [false, true]) {
    testWidgets('multiple fingers cancel paging, started=$beginSwipe', (
      tester,
    ) async {
      final host = _Host();
      await host.mount(tester);
      final first = await tester.startGesture(
        const Offset(280, 420),
        pointer: 1,
      );
      if (beginSwipe) await first.moveBy(const Offset(-80, 0));
      final second = await tester.startGesture(
        const Offset(180, 460),
        pointer: 2,
      );
      await first.moveBy(const Offset(-150, 0));
      await first.up();
      await second.moveBy(const Offset(-150, 0));
      await second.up();
      await tester.pumpAndSettle();
      expect(host.selections, isEmpty);
      await host.swipe(tester, const Offset(-200, 0));
      expect(host.tab, PortraitBilibiliTab.subtitles);
    });
  }

  testWidgets('cancelled and reversed gestures do not commit', (tester) async {
    final host = _Host();
    await host.mount(tester);
    final cancelled = await tester.startGesture(const Offset(280, 420));
    await cancelled.moveBy(const Offset(-200, 0));
    await cancelled.cancel();
    await tester.pumpAndSettle();
    expect(host.selections, isEmpty);
    final reversed = await tester.startGesture(const Offset(280, 420));
    await reversed.moveBy(const Offset(-180, 0));
    await reversed.moveBy(const Offset(170, 0));
    await reversed.up();
    await tester.pumpAndSettle();
    expect(host.selections, isEmpty);
    expect(host.rowTaps, 0);
  });

  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.stylus]) {
    testWidgets('$kind dragging does not page', (tester) async {
      final host = _Host();
      await host.mount(tester);
      await tester.dragFrom(
        const Offset(280, 420),
        const Offset(-200, 0),
        kind: kind,
      );
      await tester.pumpAndSettle();
      expect(host.selections, isEmpty);
    });
  }

  for (final x in [8.0, 352.0]) {
    testWidgets('system edge at $x does not start paging', (tester) async {
      final host = _Host();
      await host.mount(tester);
      await host.swipe(
        tester,
        Offset(x < 180 ? 200 : -200, 0),
        start: Offset(x, 420),
      );
      expect(host.selections, isEmpty);
    });
  }

  testWidgets('platform gesture insets can reserve a wider edge', (
    tester,
  ) async {
    final host = _Host()..edges = const EdgeInsets.symmetric(horizontal: 90);
    await host.mount(tester);
    await host.swipe(
      tester,
      const Offset(-200, 0),
      start: const Offset(285, 420),
    );
    expect(host.selections, isEmpty);
  });

  testWidgets('a reading selection blocks swipes but labels still work', (
    tester,
  ) async {
    final host = _Host()..allowSwipe = false;
    await host.mount(tester);
    await host.swipe(tester, const Offset(-200, 0));
    expect(host.selections, isEmpty);
    await tester.tap(
      find.byKey(const ValueKey('bilibili-portrait-tab-subtitles')),
    );
    await tester.pumpAndSettle();
    expect(host.tab, PortraitBilibiliTab.subtitles);
  });

  testWidgets('plain videos and disabled tabs do not accept swipes', (
    tester,
  ) async {
    final host = _Host()..hasDetails = false;
    await host.mount(tester);
    final subtitles = tester.element(find.byKey(_subtitleList));
    await host.swipe(
      tester,
      const Offset(200, 0),
      start: const Offset(80, 420),
    );
    expect(host.selections, isEmpty);
    host.change(() {
      host.hasDetails = true;
      host.enabled = false;
    });
    await tester.pumpAndSettle();
    await host.swipe(tester, const Offset(-200, 0));
    expect(host.selections, isEmpty);
    expect(
      tester.element(find.byKey(_subtitleList, skipOffstage: false)),
      same(subtitles),
    );
  });

  testWidgets('label navigation can interrupt a settling swipe', (
    tester,
  ) async {
    final host = _Host();
    await host.mount(tester);
    await tester.dragFrom(const Offset(280, 420), const Offset(-200, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.tap(
      find.byKey(const ValueKey('bilibili-portrait-tab-details')),
    );
    await tester.pumpAndSettle();
    expect(host.tab, PortraitBilibiliTab.details);
    expect(tester.getTopLeft(find.byKey(_detailsList)).dx, 0);
  });

  testWidgets('resize cancels an in-flight swipe', (tester) async {
    final host = _Host();
    await host.mount(tester);
    final gesture = await tester.startGesture(const Offset(280, 420));
    await gesture.moveBy(const Offset(-80, 0));
    await tester.pump();
    host.change(() => host.width = 320);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(host.selections, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('video gestures and progress slider remain outside paging', (
    tester,
  ) async {
    final host = _Host();
    await host.mount(tester);
    await tester.drag(find.byKey(_video), const Offset(-150, 0));
    await tester.drag(find.byKey(_progress), const Offset(130, 0));
    await tester.pumpAndSettle();
    expect(host.videoDrags, greaterThan(0));
    expect(host.progress, greaterThan(.5));
    expect(host.selections, isEmpty);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final article in [false, true]) {
      testWidgets(
        '${platform.name} ${article ? 'article' : 'list'} swipes do not seek; taps do',
        (tester) async {
          final host = await _mountTranscript(tester, article: article);
          await host.swipe(
            tester,
            const Offset(200, 0),
            start: const Offset(80, 420),
          );
          expect(host.tab, PortraitBilibiliTab.details);
          expect(host.seeks, isEmpty);
          await host.swipe(tester, const Offset(-200, 0));
          final line = find
              .textContaining('subtitle 4', findRichText: true)
              .first;
          final rect = tester.getRect(line);
          await tester.tapAt(Offset(rect.left + 16, rect.center.dy));
          await tester.pumpAndSettle();
          expect(host.seeks, [const Duration(seconds: 12)]);
        },
        variant: TargetPlatformVariant({platform}),
      );
    }
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      'selection beginning after pointer down keeps priority on ${platform.name}',
      (tester) async {
        final host = await _mountTranscript(tester);
        final line = find.text('subtitle 4');
        final rect = tester.getRect(line);
        final touch = await tester.startGesture(rect.center);
        tester
            .state<SelectionAreaState>(find.byType(SelectionArea))
            .selectableRegion
            .selectAll(SelectionChangedCause.keyboard);
        await tester.pump();
        expect(host.subtitleKey.currentState!.hasTextSelection, isTrue);
        await touch.moveBy(const Offset(180, 0));
        await touch.up();
        await tester.pumpAndSettle();
        expect(host.selections, isEmpty);
        expect(host.subtitleKey.currentState!.hasTextSelection, isTrue);
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      '${platform.name} transcript long press and selected-text drag do not page',
      (tester) async {
        final host = await _mountTranscript(tester);
        final line = find
            .textContaining('subtitle 4', findRichText: true)
            .first;
        final hold = await tester.startGesture(tester.getCenter(line));
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 80));
        await hold.up(timeStamp: const Duration(milliseconds: 580));
        await tester.pumpAndSettle();
        expect(host.subtitleKey.currentState!.hasTextSelection, isTrue);
        await host.swipe(
          tester,
          const Offset(200, 0),
          start: const Offset(80, 420),
        );
        expect(host.selections, isEmpty);
        expect(host.seeks, isEmpty);
        expect(host.subtitleKey.currentState!.hasTextSelection, isTrue);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  for (final started in [false, true]) {
    testWidgets(
      'transcript multi-touch cancels across regions, started=$started',
      (tester) async {
        final host = await _mountTranscript(tester);
        // One finger may begin on the tab bar, outside the inner reading region.
        final first = await tester.startGesture(
          Offset(80, started ? 420 : 150),
          pointer: 1,
        );
        if (started) await first.moveBy(const Offset(80, 0));
        await tester.pump();
        final second = await tester.startGesture(
          const Offset(100, 460),
          pointer: 2,
        );
        await second.moveBy(const Offset(180, 0));
        await first.moveBy(const Offset(150, 0));
        await first.up();
        await second.up();
        await tester.pumpAndSettle();
        expect(host.selections, isEmpty);
        expect(host.seeks, isEmpty);
      },
    );
  }

  testWidgets(
    'a second-finger double tap still seeks during transcript scrolling',
    (tester) async {
      final host = await _mountTranscript(tester, autoFollow: true);
      final anchor = await tester.startGesture(
        const Offset(180, 420),
        pointer: 10,
      );
      await anchor.moveBy(const Offset(0, -80));
      await tester.pump();
      final line = find.text('subtitle 6');
      final spot = tester.getCenter(line);
      final before = tester.getTopLeft(line).dy;
      for (final (pointer, down, up) in [(11, 100, 160), (12, 300, 360)]) {
        final tap = await tester.createGesture(pointer: pointer);
        await tap.down(spot, timeStamp: Duration(milliseconds: down));
        await tap.up(timeStamp: Duration(milliseconds: up));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(host.seeks, [const Duration(seconds: 18)]);
      expect(tester.getTopLeft(line).dy, closeTo(before, .5));
      expect(host.selections, isEmpty);
      await anchor.up();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('disposing during a swipe does not leave callbacks or tickers', (
    tester,
  ) async {
    final host = _Host();
    await host.mount(tester);
    final gesture = await tester.startGesture(const Offset(280, 420));
    await gesture.moveBy(const Offset(-100, 0));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await gesture.cancel();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

const _detailsList = ValueKey('details-list');
const _subtitleList = ValueKey('subtitle-list');
const _panelSlider = ValueKey('panel-slider');
const _horizontalList = ValueKey('horizontal-list');
const _video = ValueKey('video-gestures');
const _progress = ValueKey('progress-slider');

class _Host {
  PortraitBilibiliTab tab = PortraitBilibiliTab.details;
  bool hasDetails = true;
  bool enabled = true;
  bool allowSwipe = true;
  double width = 360;
  EdgeInsets edges = EdgeInsets.zero;
  int rowTaps = 0;
  int longPresses = 0;
  int videoDrags = 0;
  double sliderValue = .5;
  double progress = .5;
  final detailsScroll = ScrollController();
  final subtitleScroll = ScrollController();
  final carouselScroll = ScrollController();
  final subtitleKey = GlobalKey<SubtitleSidebarState>();
  final selections = <PortraitBilibiliTab>[];
  final seeks = <Duration>[];
  Widget Function(bool visible)? transcript;
  late StateSetter change;

  Widget _list({required bool details}) => ListView.builder(
    key: details ? _detailsList : _subtitleList,
    controller: details ? detailsScroll : subtitleScroll,
    itemExtent: 40,
    itemCount: 80,
    itemBuilder: (_, index) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => rowTaps++,
      onLongPress: () => longPresses++,
      child: Text('${details ? 'details' : 'subtitles'} $index'),
    ),
  );

  Future<void> mount(WidgetTester tester) async {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      detailsScroll.dispose();
      subtitleScroll.dispose();
      carouselScroll.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              change = setState;
              return MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(systemGestureInsets: edges),
                child: SizedBox(
                  width: width,
                  height: 600,
                  child: Column(
                    children: [
                      GestureDetector(
                        key: _video,
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragUpdate: (_) => videoDrags++,
                        child: const SizedBox(
                          height: 80,
                          width: double.infinity,
                        ),
                      ),
                      Slider(
                        key: _progress,
                        value: progress,
                        onChanged: (v) => change(() => progress = v),
                      ),
                      Expanded(
                        child: BilibiliPortraitTabs(
                          tab: tab,
                          onSelect: !enabled
                              ? null
                              : (value) => change(() {
                                  tab = value;
                                  selections.add(value);
                                }),
                          canStartSwipe: () =>
                              allowSwipe &&
                              (tab != PortraitBilibiliTab.subtitles ||
                                  !(subtitleKey
                                          .currentState
                                          ?.hasTextSelection ??
                                      false)),
                          details: !hasDetails
                              ? null
                              : Column(
                                  children: [
                                    Slider(
                                      key: _panelSlider,
                                      value: sliderValue,
                                      onChanged: (v) =>
                                          change(() => sliderValue = v),
                                    ),
                                    SizedBox(
                                      height: 50,
                                      child: ListView.builder(
                                        key: _horizontalList,
                                        controller: carouselScroll,
                                        scrollDirection: Axis.horizontal,
                                        itemExtent: 100,
                                        itemCount: 20,
                                        itemBuilder: (_, i) => Text('part $i'),
                                      ),
                                    ),
                                    Expanded(child: _list(details: true)),
                                  ],
                                ),
                          subtitles:
                              transcript?.call(
                                tab == PortraitBilibiliTab.subtitles,
                              ) ??
                              _list(details: false),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> swipe(
    WidgetTester tester,
    Offset delta, {
    Offset start = const Offset(280, 420),
    Duration duration = const Duration(milliseconds: 350),
  }) async {
    await tester.timedDragFrom(start, delta, duration);
    await tester.pumpAndSettle();
  }
}

Future<_Host> _mountTranscript(
  WidgetTester tester, {
  bool article = false,
  bool autoFollow = false,
}) async {
  SharedPreferences.setMockInitialValues({
    'autoScrollSubtitles': autoFollow,
    'subtitleViewMode': article ? 1 : 0,
    'subtitleArticleSentencesPerParagraph': 1,
  });
  final settings = SettingsService();
  settings.resetForTest();
  await settings.init();
  addTearDown(settings.resetForTest);
  final host = _Host()..tab = PortraitBilibiliTab.subtitles;
  host.transcript = (visible) => SubtitleSidebar(
    key: host.subtitleKey,
    subtitles: List.generate(
      40,
      (index) => SubtitleItem(
        index: index,
        startTime: Duration(seconds: index * 3),
        endTime: Duration(seconds: index * 3 + 2),
        text: 'subtitle $index',
      ),
    ),
    isCompact: true,
    isPortrait: true,
    isVisible: visible,
    onItemTap: host.seeks.add,
  );
  await host.mount(tester);
  return host;
}
