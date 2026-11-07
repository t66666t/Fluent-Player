import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/features/subtitle_article/continuous_article_view.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';
import 'package:video_player_app/widgets/subtitle_toolbar.dart';

final _toolbar = find.byKey(const ValueKey('subtitle-toolbar'));
final _reserved = find.byKey(const ValueKey('subtitle-toolbar-reserved-space'));
final _toggle = find.byKey(const ValueKey('subtitle-toolbar-toggle'));

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'autoScrollSubtitles': false,
      'portraitSidebarShowTimestamps': false,
      'landscapeSidebarShowTimestamps': false,
    });
    final settings = SettingsService()..resetForTest();
    await settings.init();
  });

  for (final left in [false, true]) {
    testWidgets('collapsed toolbar occupies only its corner: left=$left', (
      tester,
    ) async {
      var bodyTaps = 0;
      var toggleTaps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 390,
                height: 200,
                child: SubtitleToolbar(
                  expanded: false,
                  isLeftHanded: left,
                  actions: const [],
                  onOpenSettings: () {},
                  onToggleExpanded: () => toggleTaps++,
                  content: GestureDetector(
                    key: const ValueKey('reading-body'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => bodyTaps++,
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final body = tester.getRect(find.byKey(const ValueKey('reading-body')));
      expect(body.top, tester.getTopLeft(_toolbar).dy);
      expect(body.height, 200);
      expect(tester.getSize(_reserved).height, 0);
      expect(tester.getSize(_toggle), const Size(28, 28));
      await tester.tapAt(body.topLeft + Offset(left ? 378 : 12, 8));
      expect(bodyTaps, 1);
      expect(toggleTaps, 0);
      await tester.tap(_toggle);
      expect(toggleTaps, 1);
      expect(bodyTaps, 1);
    });
  }

  testWidgets('page preferences survive media changes and settings reload', (
    tester,
  ) async {
    final settings = SettingsService();
    expect(settings.portraitSidebarToolbarExpanded, isTrue);
    expect(settings.landscapeSidebarToolbarExpanded, isTrue);
    await _pumpPage(tester, portrait: true, media: 'first');
    await tester.tap(_toggle);
    await tester.pumpAndSettle();
    expect(settings.portraitSidebarToolbarExpanded, isFalse);
    expect(settings.landscapeSidebarToolbarExpanded, isTrue);

    await _pumpPage(tester, portrait: false, media: 'first');
    expect(find.byTooltip('收起字幕工具栏'), findsOneWidget);
    await tester.tap(_toggle);
    await tester.pumpAndSettle();
    await _pumpPage(tester, portrait: true, media: 'second');
    expect(find.byTooltip('展开字幕工具栏'), findsOneWidget);
    await tester.tap(_toggle);
    await tester.pumpAndSettle();
    await _pumpPage(tester, portrait: false, media: 'second');
    expect(find.byTooltip('展开字幕工具栏'), findsOneWidget);
    final layout = settings.exportSettingsSnapshot()['layout'];
    expect(layout['portraitSidebarToolbarExpanded'], isTrue);
    expect(layout['landscapeSidebarToolbarExpanded'], isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    settings.resetForTest();
    await settings.init();
    expect(settings.portraitSidebarToolbarExpanded, isTrue);
    expect(settings.landscapeSidebarToolbarExpanded, isFalse);
    await _pumpPage(tester, portrait: true, media: 'third');
    expect(find.byTooltip('收起字幕工具栏'), findsOneWidget);
    await _pumpPage(tester, portrait: false, media: 'third');
    expect(find.byTooltip('展开字幕工具栏'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final portrait in [false, true]) {
    for (final leftHanded in [false, true]) {
      testWidgets('persistent handle stays reachable: portrait=$portrait, '
          'leftHanded=$leftHanded', (tester) async {
        await SettingsService().saveLeftHandedMode(leftHanded);
        for (final width in [80.0, 240.0, 390.0, 768.0]) {
          await _pumpPage(tester, portrait: portrait, width: width);
          final openHeight = tester.getSize(_toolbar).height;
          final openHandleWidth = tester.getSize(_toggle).width;
          for (var tap = 0; tap < 2; tap++) {
            final bounds = tester.getRect(_toolbar);
            final handle = tester.getRect(_toggle);
            expect(
              handle.width,
              closeTo(tap == 0 ? openHandleWidth : 28, .001),
            );
            expect(handle.left, greaterThanOrEqualTo(bounds.left));
            expect(handle.right, lessThanOrEqualTo(bounds.right));
            expect(
              leftHanded ? handle.left : handle.right,
              leftHanded ? bounds.left : bounds.right,
            );
            final list = find.byType(ScrollablePositionedList).first;
            expect(
              tester.getTopLeft(list).dy,
              closeTo(bounds.top + (tap == 0 ? openHeight : 0), .001),
            );
            await tester.tap(_toggle);
            await tester.pumpAndSettle();
            if (tap == 0) {
              expect(
                tester.getSize(_toolbar).height,
                SubtitleToolbar.collapsedHeight,
              );
              expect(
                find.descendant(of: _toolbar, matching: find.byType(InkWell)),
                findsOneWidget,
              );
              expect(find.byTooltip('设置'), findsNothing);
            }
          }
          expect(tester.getSize(_toolbar).height, openHeight);
          expect(tester.takeException(), isNull);
        }
      });
    }

    for (final mode in ['list', 'paragraph', 'continuous']) {
      for (final following in [false, true]) {
        testWidgets('$mode document and locate anchor move continuously: '
            'portrait=$portrait, following=$following', (tester) async {
          final host = await _MotionHost.create(
            tester,
            mode: mode,
            portrait: portrait,
            following: following,
          );
          final listState = tester.state(host.list);
          for (final collapsing in [true, false]) {
            var previousHeight = tester.getSize(_reserved).height;
            var previousY = host.anchorY;
            final startY = previousY;
            await tester.tap(_toggle);
            await tester.pump();
            expect(host.anchorY, closeTo(previousY, .01));
            var intermediateFrames = 0;
            for (var frame = 0; frame < 22; frame++) {
              await tester.pump(const Duration(milliseconds: 16));
              final height = tester.getSize(_reserved).height;
              final y = host.anchorY;
              final direction = collapsing ? -1 : 1;
              expect(
                (height - previousHeight) * direction,
                greaterThanOrEqualTo(-.01),
              );
              expect((y - previousY) * direction, greaterThanOrEqualTo(-.1));
              expect((y - previousY).abs(), lessThan(8));
              if (height > SubtitleToolbar.collapsedReservedHeight &&
                  height < SubtitleToolbar.expandedHeight) {
                intermediateFrames++;
              }
              expect(tester.state(host.list), same(listState));
              expect(
                tester
                    .widget<FadeTransition>(
                      find.byKey(const ValueKey('transcript-location-opacity')),
                    )
                    .opacity
                    .value,
                1,
              );
              expect(find.byType(RawImage), findsNothing);
              previousHeight = height;
              previousY = y;
            }
            expect(intermediateFrames, greaterThan(4));
            expect((host.anchorY - startY).abs(), greaterThan(5));
            expect(
              tester.getSize(_reserved).height,
              collapsing
                  ? SubtitleToolbar.collapsedReservedHeight
                  : SubtitleToolbar.expandedHeight,
            );
            final viewport = tester.getRect(host.list);
            expect(
              (host.anchorY - viewport.top) / viewport.height,
              closeTo(.3, .01),
            );
          }
          expect(tester.takeException(), isNull);
          await host.dispose();
        });
      }
    }
  }

  testWidgets('wrapped toolbar keeps the reading surface continuous', (
    tester,
  ) async {
    final host = await _MotionHost.create(
      tester,
      mode: 'list',
      portrait: true,
      following: false,
      width: 160,
    );
    expect(tester.getSize(_reserved).height, greaterThan(44));
    final listState = tester.state(host.list);
    for (final collapsing in [true, false]) {
      var previous = host.anchorY;
      await tester.tap(_toggle);
      await tester.pump();
      expect(host.anchorY, closeTo(previous, .01));
      for (var frame = 0; frame < 22; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        final next = host.anchorY;
        expect((next - previous).abs(), lessThan(18));
        expect(
          (next - previous) * (collapsing ? -1 : 1),
          greaterThanOrEqualTo(-.1),
        );
        expect(tester.state(host.list), same(listState));
        previous = next;
      }
    }
    expect(tester.takeException(), isNull);
    await host.dispose();
  });

  testWidgets(
    'rapid reversal starts from current geometry and saves last tap',
    (tester) async {
      await _pumpPage(tester, portrait: true);
      await tester.tap(_toggle);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final middle = tester.getSize(_reserved).height;
      expect(
        middle,
        inExclusiveRange(
          SubtitleToolbar.collapsedReservedHeight,
          SubtitleToolbar.expandedHeight,
        ),
      );
      await tester.tap(_toggle);
      await tester.pump();
      expect(tester.getSize(_reserved).height, closeTo(middle, .01));
      await tester.pumpAndSettle();
      expect(tester.getSize(_reserved).height, SubtitleToolbar.expandedHeight);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('portraitSidebarToolbarExpanded'), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  for (final mode in ['paragraph', 'continuous']) {
    testWidgets('$mode stays continuous when the enlarged viewport fits text', (
      tester,
    ) async {
      final host = await _MotionHost.create(
        tester,
        mode: mode,
        portrait: true,
        following: false,
        cueCount: 8,
        anchorIndex: 4,
        shortText: true,
      );
      Finder item(int index) => find.descendant(
        of: host.list,
        matching: find.byWidgetPredicate(
          (widget) => widget is IndexedSemantics && widget.index == index,
          skipOffstage: false,
        ),
        skipOffstage: false,
      );
      final first = tester.getRect(item(0));
      final lastIndex = mode == 'paragraph'
          ? 7
          : tester
                    .widget<ContinuousArticleView>(
                      find.byType(ContinuousArticleView),
                    )
                    .layout
                    .lines
                    .length -
                1;
      final last = tester.getRect(item(lastIndex));
      final padding = mode == 'continuous'
          ? tester
                .widget<ContinuousArticleView>(
                  find.byType(ContinuousArticleView),
                )
                .padding
                .vertical
          : 0.0;
      host.update(
        () => host.height =
            last.bottom -
            first.top +
            padding +
            SubtitleToolbar.expandedHeight -
            8,
      );
      await tester.pumpAndSettle();
      host.key.currentState!.locateToTime(
        const Duration(seconds: 21),
        animated: false,
      );
      await tester.pumpAndSettle();
      var previous = tester.getTopLeft(item(lastIndex)).dy;
      await tester.tap(_toggle);
      await tester.pump();
      for (var frame = 0; frame < 22; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        final next = tester.getTopLeft(item(lastIndex)).dy;
        expect((next - previous).abs(), lessThan(8));
        previous = next;
      }
      expect(tester.takeException(), isNull);
      await host.dispose();
    });
  }

  testWidgets(
    'reduced motion and font-settings collapse leave text accessible',
    (tester) async {
      await _pumpPage(tester, portrait: true, reducedMotion: true);
      await tester.tap(find.byTooltip('文稿显示设置'));
      await tester.pumpAndSettle();
      expect(find.text('字体'), findsOneWidget);
      await tester.tap(_toggle);
      await tester.pumpAndSettle();
      expect(tester.getSize(_toolbar).height, SubtitleToolbar.collapsedHeight);
      expect(find.text('字体'), findsNothing);
      expect(find.text('文稿正文'), findsOneWidget);
      await tester.tap(_toggle);
      await tester.pumpAndSettle();
      expect(find.byTooltip('文稿显示设置'), findsOneWidget);
      expect(find.text('字体'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required bool portrait,
  String media = 'sample',
  double width = 390,
  bool reducedMotion = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reducedMotion),
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              height: 420,
              child: SubtitleSidebar(
                key: ValueKey('$portrait-$media'),
                isPortrait: portrait,
                subtitles: [
                  SubtitleItem(
                    index: 0,
                    startTime: Duration.zero,
                    endTime: const Duration(seconds: 3),
                    text: '文稿正文',
                  ),
                ],
                onOpenSettings: () {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _MotionHost {
  _MotionHost(this.tester, this.player, this.mode);
  final WidgetTester tester;
  final VideoPlayerController player;
  final String mode;
  final key = GlobalKey<SubtitleSidebarState>();
  late StateSetter update;
  double height = 420;
  Finder get list => find.byType(ScrollablePositionedList).first;

  double get anchorY {
    final index = mode == 'continuous'
        ? tester
              .widget<ContinuousArticleView>(find.byType(ContinuousArticleView))
              .layout
              .lineForSentence(30)
        : 30;
    return tester
        .getTopLeft(
          find.descendant(
            of: list,
            matching: find.byWidgetPredicate(
              (widget) => widget is IndexedSemantics && widget.index == index,
              skipOffstage: false,
            ),
            skipOffstage: false,
          ),
        )
        .dy;
  }

  static Future<_MotionHost> create(
    WidgetTester tester, {
    required String mode,
    required bool portrait,
    required bool following,
    int cueCount = 100,
    int anchorIndex = 30,
    bool shortText = false,
    double width = 390,
  }) async {
    final settings = SettingsService();
    await settings.updateSetting('subtitleViewMode', mode == 'list' ? 0 : 1);
    await settings.updateSetting('subtitleArticleSentencesPerParagraph', 1);
    await settings.updateSetting(
      'subtitleArticleParagraphModeEnabled',
      mode != 'continuous',
    );
    await settings.updateSetting('autoScrollSubtitles', following);
    final player = VideoPlayerController.networkUrl(
      Uri.parse('https://example.invalid/toolbar-motion.mp4'),
    );
    player.value = VideoPlayerValue(
      duration: const Duration(minutes: 10),
      position: Duration(seconds: anchorIndex * 3),
      isInitialized: true,
      isPlaying: following,
    );
    final host = _MotionHost(tester, player, mode);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: StatefulBuilder(
              builder: (context, setState) {
                host.update = setState;
                return SizedBox(
                  width: width,
                  height: host.height,
                  child: SubtitleSidebar(
                    key: host.key,
                    isPortrait: portrait,
                    controller: player,
                    // Exercise the ordinary resize-repair path as well as the retained
                    // reading mode used by both playback pages.
                    preserveReadingPositionWhenNotFollowing: !following,
                    subtitles: List.generate(
                      cueCount,
                      (i) => SubtitleItem(
                        index: i,
                        startTime: Duration(seconds: i * 3),
                        endTime: Duration(seconds: i * 3 + 3),
                        text: shortText
                            ? 'Sentence $i.'
                            : 'Sentence $i, a readable subtitle. 字幕正文。',
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    host.key.currentState!.locateToTime(
      Duration(seconds: anchorIndex * 3),
      animated: false,
    );
    await tester.pumpAndSettle();
    return host;
  }

  Future<void> dispose() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  }
}
