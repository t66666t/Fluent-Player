import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/bilibili/bilibili_player_panel_policy.dart';
import 'package:video_player_app/widgets/bilibili_panel_overlay.dart';

void main() {
  test('only a phone gets the panel over the video, and never by itself', () {
    expect(
      bilibiliPanelOverlaysVideo(isMobilePlatform: true, shortestSide: 360),
      isTrue,
    );
    expect(
      bilibiliPanelOverlaysVideo(isMobilePlatform: true, shortestSide: 800),
      isFalse,
    );
    expect(
      bilibiliPanelOverlaysVideo(isMobilePlatform: false, shortestSide: 360),
      isFalse,
    );
    for (final width in const <double>[640, 740, 800]) {
      expect(
        bilibiliPanelMayAutoOpen(
          windowWidth: width,
          panelWidth: width * 0.38,
          isMobilePlatform: true,
          shortestSide: 360,
        ),
        isFalse,
      );
    }
  });

  group('the overlay', () {
    const window = Size(740, 360);
    const panelWidth = 280.0;

    Future<void> pump(
      WidgetTester tester, {
      required bool open,
      bool fromLeft = false,
      VoidCallback? onDismiss,
      VoidCallback? onVideoTap,
    }) async {
      await tester.binding.setSurfaceSize(window);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  key: const ValueKey('video'),
                  onTap: onVideoTap,
                  child: const ColoredBox(color: Colors.black),
                ),
              ),
              Positioned.fill(
                child: BilibiliPanelOverlay(
                  panel: open
                      ? const ColoredBox(
                          key: ValueKey('panel'),
                          color: Colors.white,
                        )
                      : null,
                  fromLeft: fromLeft,
                  width: panelWidth,
                  onDismiss: onDismiss ?? () {},
                ),
              ),
            ],
          ),
        ),
      );
    }

    final panel = find.byKey(const ValueKey('panel'));

    testWidgets('slides in from the right over the video, which keeps its '
        'size', (tester) async {
      await pump(tester, open: false);
      expect(panel, findsNothing);
      await pump(tester, open: true);
      await tester.pump(const Duration(milliseconds: 100));
      final moving = tester.getRect(panel);
      expect(moving.left, greaterThan(window.width - panelWidth));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester.getRect(panel),
        const Rect.fromLTWH(740 - panelWidth, 0, panelWidth, 360),
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('video'))),
        Offset.zero & window,
      );

      // Closing slides it out again.
      await pump(tester, open: false);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.getRect(panel).left, greaterThan(740 - panelWidth));
      await tester.pump(const Duration(milliseconds: 300));
      expect(panel, findsNothing);
    });

    testWidgets('left-handed: from the left', (tester) async {
      await pump(tester, open: false, fromLeft: true);
      await pump(tester, open: true, fromLeft: true);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.getRect(panel).left, lessThan(0));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getRect(panel), const Rect.fromLTWH(0, 0, panelWidth, 360));
    });

    testWidgets('a tap on the video closes it; closed, taps reach the '
        'video', (tester) async {
      var dismissed = 0;
      var videoTaps = 0;
      await pump(
        tester,
        open: true,
        onDismiss: () => dismissed++,
        onVideoTap: () => videoTaps++,
      );
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(100, 180));
      expect(dismissed, 1);
      expect(videoTaps, 0);
      // Taps on the panel stay in the panel.
      await tester.tapAt(const Offset(700, 180));
      expect(dismissed, 1);

      await pump(
        tester,
        open: false,
        onDismiss: () => dismissed++,
        onVideoTap: () => videoTaps++,
      );
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(100, 180));
      expect(dismissed, 1);
      expect(videoTaps, 1);
    });
  });

  for (final fromLeft in [false, true]) {
    testWidgets('overlay reversal keeps one panel and restores scroll, '
        'left=$fromLeft', (tester) async {
      final listKey = GlobalKey();
      Widget host(bool open, {bool reduceMotion = false}) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: BilibiliPanelOverlay(
            panel: open
                ? ListView.builder(
                    key: listKey,
                    itemExtent: 40,
                    itemCount: 100,
                    itemBuilder: (_, i) => Text('详情 $i'),
                  )
                : null,
            fromLeft: fromLeft,
            width: 280,
            onDismiss: () {},
          ),
        ),
      );
      final list = find.byKey(listKey);
      ScrollPosition position() => tester
          .state<ScrollableState>(
            find.descendant(of: list, matching: find.byType(Scrollable)).first,
          )
          .position;

      await tester.pumpWidget(host(false));
      await tester.pumpWidget(host(true));
      await tester.pump(const Duration(milliseconds: 65));
      final originalElement = listKey.currentContext;
      final entering = tester.getRect(list);
      await tester.pumpWidget(host(false));
      expect(tester.getRect(list), entering);
      await tester.pump(const Duration(milliseconds: 20));
      final leaving = tester.getRect(list);
      await tester.pumpWidget(host(true));
      expect(tester.getRect(list), leaving);
      expect(listKey.currentContext, same(originalElement));
      await tester.pumpAndSettle();
      position().jumpTo(760);
      await tester.pumpAndSettle();
      await tester.pumpWidget(host(false));
      await tester.pumpAndSettle();
      expect(listKey.currentContext, isNull);
      await tester.pumpWidget(host(true));
      await tester.pumpAndSettle();
      expect(position().pixels, 760);
      await tester.pumpWidget(host(false, reduceMotion: true));
      await tester.pumpAndSettle();
      expect(listKey.currentContext, isNull);
      expect(tester.takeException(), isNull);
    });
  }

  group('the landscape page only wires the overlay', () {
    final source = File(
      'lib/screens/video_player_screen.dart',
    ).readAsStringSync();
    int count(String pattern) => RegExp(pattern).allMatches(source).length;

    test('phones put the open panel over the video instead of docking it', () {
      expect(count(r'bilibiliPanelOverlaysVideo\('), 1);
      expect(count(r'panelId: sidebarDocked'), 1);
      expect(count(r'BilibiliPanelOverlay\('), 1);
      expect(count(r'fromLeft: isLeftHandedMode'), 1);
      expect(count(r'onDismiss: _collapseBilibiliPanel'), 1);
    });

    test('back closes the overlay before it leaves the page', () {
      expect(
        count(
          r'if \(_activeSidebar == SidebarType.bilibili &&\s*'
          r'\(_bilibiliPanelOverVideo \|\| _bilibiliOpenedManually\)\) '
          r'\{\s*_collapseBilibiliPanel\(\);'
          r'\s*return;',
        ),
        1,
      );
    });
  });
}
