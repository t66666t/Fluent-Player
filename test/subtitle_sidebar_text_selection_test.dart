import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final ({String name, bool article, bool paragraph}) mode
      in <({String name, bool article, bool paragraph})>[
        (name: 'list', article: false, paragraph: true),
        (name: 'paragraph article', article: true, paragraph: true),
        (name: 'continuous article', article: true, paragraph: false),
      ]) {
    testWidgets('${mode.name} select-all uses canonical transcript text', (
      tester,
    ) async {
      final harness = await _pumpSidebar(
        tester,
        articleMode: mode.article,
        paragraphMode: mode.paragraph,
      );

      final selectionArea = find.byType(SelectionArea);
      expect(selectionArea, findsOneWidget);
      tester
          .state<SelectionAreaState>(selectionArea)
          .selectableRegion
          .selectAll(SelectionChangedCause.keyboard);
      await tester.pump();

      expect(
        harness.key.currentState!.selectedTranscriptText,
        'main one translated one second sentence third sentence',
      );
      expect(
        harness.key.currentState!.selectedTranscriptText,
        isNot(contains('00:')),
      );

      await harness.dispose(tester);
    });
  }

  testWidgets('select-all shortcut covers every virtualized transcript cue', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall methodCall) async {
        if (methodCall.method == 'Clipboard.setData') {
          copied =
              (methodCall.arguments as Map<dynamic, dynamic>)['text']
                  as String?;
        }
        return null;
      },
    );
    try {
      final harness = await _pumpSelectionList(
        tester,
        articleMode: false,
        paragraphMode: true,
      );
      final String expected = List<String>.generate(
        60,
        (int index) => 'touch line $index',
      ).join(' ');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      try {
        final KeyEventResult result = harness.key.currentState!
            .handleTranscriptShortcut(
              const KeyDownEvent(
                logicalKey: LogicalKeyboardKey.keyA,
                physicalKey: PhysicalKeyboardKey.keyA,
                timeStamp: Duration.zero,
              ),
            );
        expect(result, KeyEventResult.handled);
        expect(harness.key.currentState!.isFullTranscriptSelected, isTrue);
        expect(harness.key.currentState!.selectedTranscriptText, expected);

        final KeyEventResult copyResult = harness.key.currentState!
            .handleTranscriptShortcut(
              const KeyDownEvent(
                logicalKey: LogicalKeyboardKey.keyC,
                physicalKey: PhysicalKeyboardKey.keyC,
                timeStamp: Duration.zero,
              ),
            );
        expect(copyResult, KeyEventResult.handled);
        expect(copied, expected);
        // Dispose before Control-up pumps a frame: that frame would run the
        // deferred visual selectAll across 60 virtualized rows.
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      }
    } finally {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('empty right-click still opens copy-format settings', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final harness = await _pumpSelectionList(
        tester,
        articleMode: false,
        paragraphMode: true,
      );
      final Finder first = find
          .textContaining('touch line 0', findRichText: true)
          .first;
      final Rect firstRect = tester.getRect(first);
      final secondaryClick = await tester.startGesture(
        Offset(firstRect.left + 8, firstRect.center.dy),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await secondaryClick.up();
      await tester.pump();
      await tester.pump();
      final AdaptiveTextSelectionToolbar toolbar = tester.widget(
        find.byType(AdaptiveTextSelectionToolbar),
      );
      final ContextMenuButtonItem format = toolbar.buttonItems!.firstWhere(
        (ContextMenuButtonItem item) => item.label == '格式',
      );
      format.onPressed!();
      await tester.pump();
      expect(find.text('复制格式'), findsOneWidget);
      expect(find.text('复制'), findsNothing);
      expect(harness.key.currentState!.hasTextSelection, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('menu select-all uses the canonical full transcript', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final harness = await _pumpSelectionList(
        tester,
        articleMode: false,
        paragraphMode: true,
      );
      final Finder first = find
          .textContaining('touch line 0', findRichText: true)
          .first;
      final Rect firstRect = tester.getRect(first);
      final secondaryClick = await tester.startGesture(
        Offset(firstRect.left + 8, firstRect.center.dy),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await secondaryClick.up();
      await tester.pump();
      await tester.pump();
      expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
      final AdaptiveTextSelectionToolbar toolbar = tester.widget(
        find.byType(AdaptiveTextSelectionToolbar),
      );
      expect(
        toolbar.buttonItems!.map((ContextMenuButtonItem item) => item.type),
        containsAll(<ContextMenuButtonType>[
          ContextMenuButtonType.selectAll,
          ContextMenuButtonType.custom,
        ]),
      );
      expect(
        toolbar.buttonItems!
            .firstWhere(
              (ContextMenuButtonItem item) =>
                  item.type == ContextMenuButtonType.custom,
            )
            .label,
        '格式',
      );
      final ContextMenuButtonItem selectAll = toolbar.buttonItems!.firstWhere(
        (ContextMenuButtonItem item) =>
            item.type == ContextMenuButtonType.selectAll,
      );
      selectAll.onPressed!();
      expect(harness.key.currentState!.isFullTranscriptSelected, isTrue);
      expect(
        harness.key.currentState!.selectedTranscriptText,
        List<String>.generate(60, (int index) => 'touch line $index').join(' '),
      );
      expect(harness.key.currentState!.hasOwnedSelectionToolbar, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('touch long press selects article text without seeking', (
    tester,
  ) async {
    final harness = await _pumpSidebar(
      tester,
      articleMode: true,
      paragraphMode: true,
    );
    final target = find.text('main one translated one', findRichText: true);
    final Rect rect = tester.getRect(target);
    final gesture = await tester.startGesture(
      Offset(rect.left + 18, rect.center.dy),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 80));

    expect(harness.key.currentState!.hasTextSelection, isTrue);
    expect(harness.seeks, isEmpty);

    await gesture.up();
    await tester.pump();
    expect(harness.seeks, isEmpty);
    await harness.dispose(tester);
  });

  testWidgets(
    'mouse drag selects list text and first later click only clears',
    (tester) async {
      final harness = await _pumpSidebar(
        tester,
        articleMode: false,
        paragraphMode: true,
      );
      final first = find.text('main one translated one');
      final second = find.text('second sentence');
      final Rect firstRect = tester.getRect(first);
      final Rect secondRect = tester.getRect(second);
      final gesture = await tester.startGesture(
        Offset(firstRect.left + 4, firstRect.center.dy),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(Offset(secondRect.center.dx, secondRect.center.dy));
      await gesture.up();
      await tester.pump();

      expect(harness.key.currentState!.hasTextSelection, isTrue);
      expect(harness.seeks, isEmpty);

      await tester.tapAt(secondRect.center);
      await tester.pump();
      expect(harness.key.currentState!.hasTextSelection, isFalse);
      expect(harness.seeks, isEmpty);

      await tester.tap(second);
      await tester.pump();
      expect(harness.seeks, hasLength(1));

      await harness.dispose(tester);
    },
  );

  testWidgets(
    'windows right click keeps a non-empty selection and always offers copy',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final harness = await _pumpSidebar(
          tester,
          articleMode: false,
          paragraphMode: true,
          wrapInOuterSelectionArea: true,
        );
        final first = find.text('main one translated one');
        final second = find.text('second sentence');
        final third = find.text('third sentence');
        final Rect firstRect = tester.getRect(first);
        final Rect secondRect = tester.getRect(second);
        final Rect thirdRect = tester.getRect(third);
        final gesture = await tester.startGesture(
          Offset(firstRect.left + 4, firstRect.center.dy),
          kind: PointerDeviceKind.mouse,
        );
        await gesture.moveTo(
          Offset(secondRect.center.dx, secondRect.center.dy),
        );
        await gesture.up();
        await tester.pump();
        final String selectedBefore =
            harness.key.currentState!.selectedTranscriptText;
        expect(selectedBefore, isNotEmpty);

        final secondaryClick = await tester.startGesture(
          thirdRect.center,
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await secondaryClick.up();
        await tester.pump();
        await tester.pump();

        expect(
          harness.key.currentState!.selectedTranscriptText,
          selectedBefore,
          reason: 'right click must not collapse an existing selection',
        );
        expect(
          find.byType(AdaptiveTextSelectionToolbar),
          findsOneWidget,
          reason: 'the outer page selection menu must be suppressed',
        );
        final AdaptiveTextSelectionToolbar toolbar = tester.widget(
          find.byType(AdaptiveTextSelectionToolbar),
        );
        expect(
          toolbar.buttonItems!.map((item) => item.type).toList(),
          <ContextMenuButtonType>[
            ContextMenuButtonType.copy,
            ContextMenuButtonType.selectAll,
            ContextMenuButtonType.custom,
          ],
        );
        expect(toolbar.buttonItems![2].label, '格式');
        expect(
          harness.key.currentState!.formattedSelectedTranscriptText,
          selectedBefore,
        );

        toolbar.buttonItems![2].onPressed!();
        await tester.pump();
        await tester.pump();
        expect(find.text('复制格式'), findsOneWidget);
        await harness.dispose(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets('small touch jitter does not dismiss an active selection', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final harness = await _pumpSelectionList(
        tester,
        articleMode: false,
        paragraphMode: true,
      );
      final first = find
          .textContaining('touch line 0', findRichText: true)
          .first;
      final Rect firstRect = tester.getRect(first);
      final longPress = await tester.startGesture(
        Offset(firstRect.left + 18, firstRect.center.dy),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 80));
      await longPress.up();
      await tester.pump();
      final String selectedBefore =
          harness.key.currentState!.selectedTranscriptText;

      final Rect shieldRect = tester.getRect(
        find.byKey(const ValueKey('subtitle-selection-scroll-shield')),
      );
      final jitter = await tester.startGesture(
        Offset(shieldRect.center.dx, shieldRect.bottom - 24),
        kind: PointerDeviceKind.touch,
      );
      await jitter.moveBy(const Offset(8, 0));
      await jitter.up();
      await tester.pump();

      expect(harness.key.currentState!.hasTextSelection, isTrue);
      expect(harness.key.currentState!.selectedTranscriptText, selectedBefore);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('active selection suspends auto-follow and clearing resumes it', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'autoScrollSubtitles': true,
      'subtitleViewMode': 0,
    });
    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();
    final controller = VideoPlayerController.networkUrl(
      Uri.parse('https://example.invalid/text-selection.mp4'),
    );
    controller.value = const VideoPlayerValue(
      duration: Duration(minutes: 10),
      isInitialized: true,
      isPlaying: true,
    );
    final position = ValueNotifier<Duration>(Duration.zero);
    final key = GlobalKey<SubtitleSidebarState>();
    final subtitles = List<SubtitleItem>.generate(40, (int index) {
      return SubtitleItem(
        index: index,
        startTime: Duration(seconds: index * 3),
        endTime: Duration(seconds: index * 3 + 2),
        text: 'line $index',
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            height: 360,
            child: SubtitleSidebar(
              key: key,
              subtitles: subtitles,
              controller: controller,
              positionListenable: position,
              isCompact: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final area = find.byType(SelectionArea);
    tester
        .state<SelectionAreaState>(area)
        .selectableRegion
        .selectAll(SelectionChangedCause.keyboard);
    await tester.pump();
    expect(key.currentState!.hasTextSelection, isTrue);

    controller.value = controller.value.copyWith(
      position: const Duration(seconds: 60),
    );
    position.value = const Duration(seconds: 60);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('line 0'), findsOneWidget);
    expect(find.text('line 20'), findsNothing);

    key.currentState!.clearTextSelection();
    for (int frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('line 20'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    position.dispose();
    await controller.dispose();
  });

  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.windows,
  ]) {
    testWidgets(
      '${platform.name} touch selection dragged downward inside viewport does not teleport',
      (tester) => _verifyTouchSelectionDragInsideViewportDoesNotTeleport(
        tester,
        platform: platform,
      ),
    );
    testWidgets(
      '${platform.name} released selection still lets the transcript be dragged',
      (tester) => _verifyReleasedSelectionAllowsManualScroll(
        tester,
        platform: platform,
      ),
    );
    testWidgets(
      '${platform.name} stationary tap dismisses a released touch selection',
      (tester) => _verifyStationaryTapDismissesTouchSelection(
        tester,
        platform: platform,
      ),
    );
    testWidgets(
      '${platform.name} touch selection dragged to top keeps scrolling in list',
      (tester) => _verifyTouchSelectionScrollsUp(tester, platform: platform),
    );
  }

  for (final ({String name, bool article, bool paragraph}) mode
      in <({String name, bool article, bool paragraph})>[
        (name: 'list', article: false, paragraph: true),
        (name: 'paragraph article', article: true, paragraph: true),
        (name: 'continuous article', article: true, paragraph: false),
      ]) {
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.iOS,
    ]) {
      testWidgets(
        '${platform.name} touch selection dragged to bottom keeps scrolling in ${mode.name}',
        (tester) => _verifyTouchSelectionScrollsDown(
          tester,
          articleMode: mode.article,
          paragraphMode: mode.paragraph,
          platform: platform,
        ),
      );
    }
  }

  testWidgets(
    'android reversing an upward selection past its anchor scrolls down safely',
    _verifyReversedSelectionScrollsDownSafely,
  );

  testWidgets('android edge selection keeps a stable persistent toolbar', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final harness = await _pumpSelectionList(
        tester,
        articleMode: false,
        paragraphMode: true,
      );
      final SelectionArea area = tester.widget<SelectionArea>(
        find.byType(SelectionArea),
      );
      expect(area.magnifierConfiguration, isNull);

      final first = find
          .textContaining('touch line 0', findRichText: true)
          .first;
      final Rect firstRect = tester.getRect(first);
      final longPress = await tester.startGesture(
        Offset(firstRect.left + 18, firstRect.center.dy),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 80));
      expect(harness.key.currentState!.hasTextSelection, isTrue);
      await tester.pump();
      expect(
        find.byType(AdaptiveTextSelectionToolbar),
        findsOneWidget,
        reason: 'selection feedback must appear before the finger is lifted',
      );
      final AdaptiveTextSelectionToolbar initialToolbar = tester.widget(
        find.byType(AdaptiveTextSelectionToolbar),
      );
      expect(
        initialToolbar.buttonItems!.map((item) => item.type).toList(),
        <ContextMenuButtonType>[
          ContextMenuButtonType.copy,
          ContextMenuButtonType.selectAll,
          ContextMenuButtonType.custom,
          ContextMenuButtonType.share,
        ],
      );
      expect(initialToolbar.buttonItems![2].label, '格式');
      expect(initialToolbar.anchors.primaryAnchor.dy, lessThan(firstRect.top));
      expect(
        initialToolbar.anchors.secondaryAnchor!.dy,
        greaterThan(firstRect.bottom),
      );
      await longPress.up();
      await tester.pump();
      expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);

      final Offset handlePosition = _selectionEndHandlePosition(tester);
      final gesture = await tester.startGesture(
        handlePosition,
        kind: PointerDeviceKind.touch,
      );
      final Rect selectionRect = tester.getRect(find.byType(SelectionArea));
      await gesture.moveTo(
        Offset(selectionRect.center.dx, selectionRect.bottom - 20),
      );
      await tester.pump();

      expect(harness.key.currentState!.isTouchSelectionEdgeScrolling, isTrue);
      expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
      expect(tester.takeException(), isNull);

      await gesture.up();
      await tester.pump();
      expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    testWidgets(
      '${platform.name} right-click menu survives scrolling selected text off-screen',
      (tester) async {
        await _verifyDesktopContextMenuSurvivesOffscreenScroll(
          tester,
          platform: platform,
        );
      },
    );
  }

  testWidgets(
    'iOS selection toolbar survives scrolling selected text off-screen',
    (tester) async {
      await _verifyTouchContextMenuSurvivesOffscreenScroll(
        tester,
        platform: TargetPlatform.iOS,
      );
    },
  );

  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.iOS,
    TargetPlatform.windows,
  ]) {
    testWidgets('${platform.name} touch long press selects before pointer up', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        final harness = await _pumpSelectionList(
          tester,
          articleMode: false,
          paragraphMode: true,
        );
        final target = find
            .textContaining('touch line 0', findRichText: true)
            .first;
        final Rect rect = tester.getRect(target);
        final gesture = await tester.startGesture(
          Offset(rect.left + 18, rect.center.dy),
          kind: PointerDeviceKind.touch,
        );
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 80));
        expect(harness.key.currentState!.hasTextSelection, isTrue);
        await tester.pump();
        expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);

        await gesture.up();
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('cross-cue spacer is selectable but paints no edge highlight', (
    tester,
  ) async {
    final listHarness = await _pumpSidebar(
      tester,
      articleMode: false,
      paragraphMode: true,
    );
    final Text listSeparator = tester.widget<Text>(
      find.byKey(const ValueKey('subtitle-separator-0')),
    );
    expect(listSeparator.data, ' ');
    expect(listSeparator.selectionColor, Colors.transparent);
    await listHarness.dispose(tester);

    final articleHarness = await _pumpSidebar(
      tester,
      articleMode: true,
      paragraphMode: true,
    );
    final Text articleSeparator = tester.widget<Text>(
      find.byKey(const ValueKey('subtitle-article-separator-0')),
    );
    expect(articleSeparator.data, ' ');
    expect(articleSeparator.selectionColor, Colors.transparent);

    final selectionArea = find.byType(SelectionArea);
    tester
        .state<SelectionAreaState>(selectionArea)
        .selectableRegion
        .selectAll(SelectionChangedCause.keyboard);
    await tester.pump();
    expect(
      articleHarness.key.currentState!.selectedTranscriptText,
      'main one translated one second sentence third sentence',
    );
    await articleHarness.dispose(tester);
  });
}

Future<void> _verifyReversedSelectionScrollsDownSafely(
  WidgetTester tester,
) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  try {
    final _SelectionListHarness harness = await _pumpSelectionList(
      tester,
      articleMode: false,
      paragraphMode: true,
    );
    await tester.drag(
      find.byType(ScrollablePositionedList).first,
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();

    final target = find
        .textContaining('touch line 9', findRichText: true)
        .first;
    final Rect targetRect = tester.getRect(target);
    final longPress = await tester.startGesture(
      Offset(targetRect.left + 18, targetRect.center.dy),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 80));
    expect(harness.key.currentState!.hasTextSelection, isTrue);
    await longPress.up();
    await tester.pump();

    final Offset handlePosition = _selectionEndHandlePosition(tester);
    final gesture = await tester.startGesture(
      handlePosition,
      kind: PointerDeviceKind.touch,
    );

    final Rect selectionRect = tester.getRect(find.byType(SelectionArea));
    await gesture.moveTo(
      Offset(selectionRect.center.dx, selectionRect.top - 24),
    );
    await tester.pump();
    expect(
      harness.key.currentState!.isSelectionGestureActive,
      isTrue,
      reason: 'a second gesture on the Android selection handle must rebind',
    );
    for (int frame = 0; frame < 18; frame++) {
      await tester.pump(const Duration(milliseconds: 32));
      expect(tester.takeException(), isNull);
    }

    // Keep the same handle down, reverse direction, cross its original anchor,
    // and enter the lower edge. This used to race private ScrollPositions and
    // could surface Flutter's full-screen ErrorWidget on Android.
    // The phone's system gesture area can make positions below the physical
    // bottom unreachable. Scrolling must start while the finger is still
    // visibly inside the transcript.
    await gesture.moveTo(
      Offset(selectionRect.center.dx, selectionRect.bottom - 20),
    );
    expect(harness.key.currentState!.isTouchSelectionEdgeScrolling, isTrue);
    for (int frame = 0; frame < 36; frame++) {
      await tester.pump(const Duration(milliseconds: 32));
      expect(tester.takeException(), isNull);
    }

    expect(harness.key.currentState!.hasTextSelection, isTrue);
    await gesture.up();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(harness.key.currentState!.isTouchSelectionEdgeScrolling, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

Future<void> _verifyTouchSelectionDragInsideViewportDoesNotTeleport(
  WidgetTester tester, {
  required TargetPlatform platform,
}) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    final _SelectionListHarness harness = await _pumpSelectionList(
      tester,
      articleMode: false,
      paragraphMode: true,
    );
    final first = find.textContaining('touch line 0', findRichText: true).first;
    final Rect firstRect = tester.getRect(first);
    final gesture = await tester.startGesture(
      Offset(firstRect.left + 18, firstRect.center.dy),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 80));
    expect(harness.key.currentState!.hasTextSelection, isTrue);
    expect(
      harness.key.currentState!.isSelectionGestureActive,
      isTrue,
      reason: 'long-press drag must bind the extending pointer',
    );
    final double topBefore = tester.getTopLeft(first).dy;

    // Stay well inside the viewport. This must not be mistaken for an edge
    // drag or jump whole items to the top on every move.
    await gesture.moveBy(const Offset(0, 40));
    for (int frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 32));
    }

    expect(harness.key.currentState!.isTouchSelectionEdgeScrolling, isFalse);
    expect(
      find.textContaining('touch line 0', findRichText: true),
      findsWidgets,
    );
    expect(tester.getTopLeft(first).dy, closeTo(topBefore, 8));
    await gesture.up();
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

Future<void> _verifyTouchSelectionScrollsDown(
  WidgetTester tester, {
  required bool articleMode,
  required bool paragraphMode,
  required TargetPlatform platform,
}) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    final _SelectionListHarness harness = await _pumpSelectionList(
      tester,
      articleMode: articleMode,
      paragraphMode: paragraphMode,
    );
    final key = harness.key;

    final first = find.textContaining('touch line 0', findRichText: true).first;
    final Rect firstRect = tester.getRect(first);
    final longPress = await tester.startGesture(
      Offset(firstRect.left + 18, firstRect.center.dy),
      kind: PointerDeviceKind.touch,
    );
    // Cooperative layout and selectable registration can schedule another
    // frame. Keep native frame cadence while holding: one 580 ms fake-clock
    // jump fires the long-press timer before those queued frames can run.
    for (
      var elapsed = Duration.zero;
      elapsed < kLongPressTimeout + const Duration(milliseconds: 80);
      elapsed += const Duration(milliseconds: 16)
    ) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(key.currentState!.hasTextSelection, isTrue);
    await longPress.up();
    await tester.pump();

    final Offset handlePosition = _selectionEndHandlePosition(tester);
    final gesture = await tester.startGesture(
      handlePosition,
      kind: PointerDeviceKind.touch,
    );

    final Rect selectionRect = tester.getRect(find.byType(SelectionArea));
    // Exercise the real phone constraint: the finger remains above the
    // physical bottom edge, but inside the early activation band.
    await gesture.moveTo(
      Offset(selectionRect.center.dx, selectionRect.bottom - 20),
    );
    await tester.pump();
    expect(
      key.currentState!.isSelectionGestureActive,
      isTrue,
      reason: 'the lifted long-press followed by a handle drag must be tracked',
    );
    expect(key.currentState!.isTouchSelectionEdgeScrolling, isTrue);
    // One tick must follow the finger, not skip a whole viewport of items.
    await tester.pump(const Duration(milliseconds: 48));
    expect(
      find.textContaining('touch line 0', findRichText: true),
      findsWidgets,
    );
    for (int frame = 0; frame < 36; frame++) {
      await tester.pump(const Duration(milliseconds: 32));
    }
    for (
      int frame = 0;
      frame < 64 &&
          !key.currentState!.selectedTranscriptText.contains('touch line 4');
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 32));
    }
    expect(
      find.textContaining('touch line 0', findRichText: true),
      findsNothing,
    );
    expect(
      find.textContaining(
        'touch line 0',
        findRichText: true,
        skipOffstage: false,
      ),
      findsOneWidget,
      reason:
          'a selected off-screen node must stay alive until selection clears',
    );
    expect(key.currentState!.selectedTranscriptText, contains('touch line 0'));
    expect(key.currentState!.selectedTranscriptText, contains('touch line 4'));
    await gesture.up();
    await tester.pump();
    expect(key.currentState!.isTouchSelectionEdgeScrolling, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

Offset _selectionEndHandlePosition(WidgetTester tester) {
  final Finder handleOverlays = find.byWidgetPredicate(
    (Widget widget) => '${widget.runtimeType}' == '_SelectionHandleOverlay',
  );
  final Finder handleTargets = find.descendant(
    of: handleOverlays,
    matching: find.byType(RawGestureDetector),
  );
  final List<Rect> hitTargets = handleTargets
      .evaluate()
      .map(
        (element) => tester.getRect(
          find.byElementPredicate((candidate) => identical(candidate, element)),
        ),
      )
      .where((rect) => rect.width >= 40)
      .toList();
  expect(hitTargets, hasLength(2));
  hitTargets.sort((a, b) => a.center.dx.compareTo(b.center.dx));
  return hitTargets.last.center;
}

Future<void> _verifyReleasedSelectionAllowsManualScroll(
  WidgetTester tester, {
  required TargetPlatform platform,
}) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    final _SelectionListHarness harness = await _pumpSelectionList(
      tester,
      articleMode: false,
      paragraphMode: true,
    );
    final first = find.textContaining('touch line 0', findRichText: true).first;
    final Rect firstRect = tester.getRect(first);
    final gesture = await tester.startGesture(
      Offset(firstRect.left + 18, firstRect.center.dy),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 80));
    expect(harness.key.currentState!.hasTextSelection, isTrue);
    await gesture.up();
    await tester.pump();
    final String selectionBefore =
        harness.key.currentState!.selectedTranscriptText;
    expect(selectionBefore, isNotEmpty);
    expect(
      find.byKey(const ValueKey('subtitle-selection-scroll-shield')),
      findsOneWidget,
    );

    final double topBefore = tester.getTopLeft(first).dy;
    final Rect shieldRect = tester.getRect(
      find.byKey(const ValueKey('subtitle-selection-scroll-shield')),
    );
    await tester.dragFrom(
      Offset(shieldRect.center.dx, shieldRect.bottom - 24),
      const Offset(0, -180),
      kind: PointerDeviceKind.touch,
    );
    await tester.pumpAndSettle();
    final Finder after = find.textContaining(
      'touch line 0',
      findRichText: true,
    );
    if (after.evaluate().isEmpty) {
      // Scrolled off-screen: the pan was accepted.
    } else {
      expect(
        tester.getTopLeft(after.first).dy,
        lessThan(topBefore - 24),
        reason:
            'after the selection finger lifts, a pan must move the transcript',
      );
    }
    expect(harness.key.currentState!.hasTextSelection, isTrue);
    expect(
      harness.key.currentState!.selectedTranscriptText,
      selectionBefore,
      reason: 'scrolling the transcript must not discard or mutate selection',
    );
    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

Future<void> _verifyStationaryTapDismissesTouchSelection(
  WidgetTester tester, {
  required TargetPlatform platform,
}) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    final _SelectionListHarness harness = await _pumpSelectionList(
      tester,
      articleMode: false,
      paragraphMode: true,
    );
    final first = find.textContaining('touch line 0', findRichText: true).first;
    final Rect firstRect = tester.getRect(first);
    final gesture = await tester.startGesture(
      Offset(firstRect.left + 18, firstRect.center.dy),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 80));
    await gesture.up();
    await tester.pump();
    expect(harness.key.currentState!.hasTextSelection, isTrue);

    final Rect shieldRect = tester.getRect(
      find.byKey(const ValueKey('subtitle-selection-scroll-shield')),
    );
    await tester.tapAt(
      Offset(shieldRect.center.dx, shieldRect.bottom - 24),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump();

    expect(harness.key.currentState!.hasTextSelection, isFalse);
    expect(
      find.byKey(const ValueKey('subtitle-selection-scroll-shield')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

Future<void> _verifyTouchSelectionScrollsUp(
  WidgetTester tester, {
  required TargetPlatform platform,
}) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    final _SelectionListHarness harness = await _pumpSelectionList(
      tester,
      articleMode: false,
      paragraphMode: true,
    );
    await tester.drag(
      find.byType(ScrollablePositionedList).first,
      const Offset(0, -260),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('touch line 0', findRichText: true),
      findsNothing,
    );

    final target = find
        .textContaining('touch line 8', findRichText: true)
        .first;
    final Rect targetRect = tester.getRect(target);
    final gesture = await tester.startGesture(
      Offset(targetRect.left + 18, targetRect.center.dy),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 80));
    expect(harness.key.currentState!.hasTextSelection, isTrue);

    final Rect selectionRect = tester.getRect(find.byType(SelectionArea));
    await gesture.moveTo(
      Offset(selectionRect.center.dx, selectionRect.top - 24),
    );
    expect(harness.key.currentState!.isTouchSelectionEdgeScrolling, isTrue);
    for (int frame = 0; frame < 36; frame++) {
      await tester.pump(const Duration(milliseconds: 32));
    }
    expect(
      find.textContaining('touch line 0', findRichText: true),
      findsWidgets,
    );
    await gesture.up();
    await tester.pump();
    expect(harness.key.currentState!.isTouchSelectionEdgeScrolling, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

Future<void> _verifyDesktopContextMenuSurvivesOffscreenScroll(
  WidgetTester tester, {
  required TargetPlatform platform,
}) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    final _SelectionListHarness harness = await _pumpSelectionList(
      tester,
      articleMode: false,
      paragraphMode: true,
    );
    final Finder first = find
        .textContaining('touch line 0', findRichText: true)
        .first;
    final Finder second = find
        .textContaining('touch line 1', findRichText: true)
        .first;
    final firstRect = tester.getRect(first);
    final secondRect = tester.getRect(second);
    final gesture = await tester.startGesture(
      Offset(firstRect.left + 4, firstRect.center.dy),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(Offset(secondRect.center.dx, secondRect.center.dy));
    await gesture.up();
    await tester.pump();
    expect(harness.key.currentState!.hasTextSelection, isTrue);

    final Finder shield = find.byKey(
      const ValueKey('subtitle-selection-scroll-shield'),
    );
    expect(shield, findsOneWidget);
    final Rect shieldRect = tester.getRect(shield);
    final secondaryClick = await tester.startGesture(
      shieldRect.center,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await secondaryClick.up();
    await tester.pump();
    await tester.pump();
    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
    expect(harness.key.currentState!.hasOwnedSelectionToolbar, isTrue);

    // Scroll far enough that the originally selected rows leave the viewport.
    // Flutter's endpoint-anchored menu used to rebuild with non-finite anchors
    // here and replace the right-click menu with ErrorWidget.
    await tester.drag(shield, const Offset(0, -900));
    for (int frame = 0; frame < 24; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.takeException(), isNull);
    }

    expect(harness.key.currentState!.hasTextSelection, isTrue);
    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);
    // Desktop menus dismiss on scroll; Flutter must not resurrect a crashing
    // geometry-anchored replacement.
    expect(harness.key.currentState!.hasOwnedSelectionToolbar, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

Future<void> _verifyTouchContextMenuSurvivesOffscreenScroll(
  WidgetTester tester, {
  required TargetPlatform platform,
}) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    final _SelectionListHarness harness = await _pumpSelectionList(
      tester,
      articleMode: false,
      paragraphMode: true,
    );
    final Finder first = find
        .textContaining('touch line 0', findRichText: true)
        .first;
    final Rect firstRect = tester.getRect(first);
    final longPress = await tester.startGesture(
      Offset(firstRect.left + 18, firstRect.center.dy),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 80));
    expect(harness.key.currentState!.hasTextSelection, isTrue);
    await longPress.up();
    await tester.pump();
    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);

    final Finder shield = find.byKey(
      const ValueKey('subtitle-selection-scroll-shield'),
    );
    expect(shield, findsOneWidget);
    await tester.drag(shield, const Offset(0, -900));
    for (int frame = 0; frame < 24; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.takeException(), isNull);
    }

    expect(harness.key.currentState!.hasTextSelection, isTrue);
    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
    expect(find.byType(ErrorWidget), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

Future<_SelectionListHarness> _pumpSelectionList(
  WidgetTester tester, {
  required bool articleMode,
  required bool paragraphMode,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'autoScrollSubtitles': false,
    'subtitleViewMode': articleMode ? 1 : 0,
    'subtitleArticleParagraphModeEnabled': paragraphMode,
    'subtitleArticleSentencesPerParagraph': 1,
    'landscapeSidebarShowTimestamps': true,
  });
  final settings = SettingsService();
  settings.resetForTest();
  await settings.init();
  final key = GlobalKey<SubtitleSidebarState>();
  final subtitles = List<SubtitleItem>.generate(
    60,
    (index) => SubtitleItem(
      index: index,
      startTime: Duration(seconds: index * 2),
      endTime: Duration(seconds: index * 2 + 1),
      text: 'touch line $index',
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 360,
          height: 320,
          child: SubtitleSidebar(
            key: key,
            subtitles: subtitles,
            isCompact: true,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return _SelectionListHarness(key: key);
}

class _SelectionListHarness {
  const _SelectionListHarness({required this.key});

  final GlobalKey<SubtitleSidebarState> key;
}

Future<_Harness> _pumpSidebar(
  WidgetTester tester, {
  required bool articleMode,
  required bool paragraphMode,
  bool wrapInOuterSelectionArea = false,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'autoScrollSubtitles': true,
    'subtitleViewMode': articleMode ? 1 : 0,
    'subtitleArticleParagraphModeEnabled': paragraphMode,
    'subtitleArticleSentencesPerParagraph': 1,
    'landscapeSidebarShowTimestamps': true,
  });
  final settings = SettingsService();
  settings.resetForTest();
  await settings.init();

  final subtitles = <SubtitleItem>[
    SubtitleItem(
      index: 0,
      startTime: Duration(seconds: 1),
      endTime: Duration(seconds: 2),
      text: 'main\none',
    ),
    SubtitleItem(
      index: 1,
      startTime: Duration(seconds: 3),
      endTime: Duration(seconds: 4),
      text: 'second\t sentence',
    ),
    SubtitleItem(
      index: 2,
      startTime: Duration(seconds: 5),
      endTime: Duration(seconds: 6),
      text: 'third   sentence',
    ),
  ];
  final secondary = <SubtitleItem>[
    SubtitleItem(
      index: 0,
      startTime: Duration(seconds: 1),
      endTime: Duration(seconds: 2),
      text: 'translated\n one',
    ),
  ];
  final seeks = <Duration>[];
  final key = GlobalKey<SubtitleSidebarState>();

  final Widget sidebar = SizedBox(
    width: 360,
    height: 420,
    child: SubtitleSidebar(
      key: key,
      subtitles: subtitles,
      secondarySubtitles: secondary,
      isCompact: true,
      onItemTap: seeks.add,
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: wrapInOuterSelectionArea
            ? SelectionArea(child: sidebar)
            : sidebar,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return _Harness(key: key, seeks: seeks);
}

class _Harness {
  const _Harness({required this.key, required this.seeks});

  final GlobalKey<SubtitleSidebarState> key;
  final List<Duration> seeks;

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
  }
}
