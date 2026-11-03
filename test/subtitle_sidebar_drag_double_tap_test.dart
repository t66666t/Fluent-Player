import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';

/// 「拖拽会话中副指针双击跳转」的回归测试。
///
/// 覆盖三类关键行为：
///   1. 拖着不松手时，副指针单击不 seek、不滚动，双击才 seek 且仍不滚动；
///   2. 常规单指点击必须保持原样（点一下就 seek + 定位），不被新机制吃掉；
///   3. 各种应当被拒绝的近似动作（超时、跨行、锚点中途松手）不会误触发。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 构造一个带 40 条字幕的侧边栏，并回传 seek 记录与目标 Finder 工具。
  Future<_Harness> pumpSidebar(
    WidgetTester tester, {
    bool autoScrollSubtitles = true,
    bool followSeek = false,
  }) async {
    SharedPreferences.setMockInitialValues({
      'autoScrollSubtitles': autoScrollSubtitles,
      'subtitleViewMode': 0,
    });
    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();

    final controller = VideoPlayerController.networkUrl(
      Uri.parse('https://example.invalid/double-tap.mp4'),
    );
    controller.value = const VideoPlayerValue(
      duration: Duration(minutes: 10),
      position: Duration(seconds: 3),
      isInitialized: true,
      isPlaying: true,
    );
    final subtitles = List<SubtitleItem>.generate(40, (index) {
      final start = Duration(seconds: index * 3);
      return SubtitleItem(
        index: index,
        startTime: start,
        endTime: start + const Duration(seconds: 2),
        text: 'subtitle $index',
      );
    });
    final seeks = <Duration>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            height: 420,
            child: SubtitleSidebar(
              subtitles: subtitles,
              controller: controller,
              isCompact: true,
              onItemTap: (position) {
                seeks.add(position);
                // 模拟真实播放器：seek 后播放位置立即跟到目标时间。
                if (followSeek) {
                  controller.value = controller.value.copyWith(
                    position: position,
                  );
                }
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    return _Harness(controller: controller, subtitles: subtitles, seeks: seeks);
  }

  /// 发出一次干净的轻点（原地按下、短时抬起），用独立的 pointer id 模拟
  /// 一根新手指。
  Future<void> tapWithNewFinger(
    WidgetTester tester,
    Offset spot, {
    required int downMs,
    required int upMs,
    int pointer = 0,
  }) async {
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.touch,
      pointer: pointer,
    );
    await gesture.down(spot, timeStamp: Duration(milliseconds: downMs));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.up(timeStamp: Duration(milliseconds: upMs));
    await tester.pump(const Duration(milliseconds: 16));
  }

  testWidgets('拖拽中副指针单击不跳转，双击才跳转且文稿保持不动', (tester) async {
    final harness = await pumpSidebar(tester);

    // 一根手指按住列表并拖动：这是「按住不放浏览上下文」的场景。
    final anchor = await tester.startGesture(
      const Offset(180, 240),
      pointer: 10,
    );
    await tester.pump(const Duration(milliseconds: 16));
    await anchor.moveBy(const Offset(0, -80));
    await tester.pump(const Duration(milliseconds: 16));

    final target = find.text('subtitle 6');
    expect(target, findsOneWidget);
    final Offset spot = tester.getCenter(target);
    final double dyBefore = tester.getTopLeft(target).dy;

    // 第一次轻点：只登记候选，不得产生任何 seek。
    await tapWithNewFinger(tester, spot, downMs: 100, upMs: 160, pointer: 11);
    expect(harness.seeks, isEmpty, reason: '拖拽中的单击不应跳转');
    expect(tester.getTopLeft(target).dy, closeTo(dyBefore, 0.5));

    // 第二次轻点：构成双击，应立即 seek 到该句，但文稿不能滚动。
    await tapWithNewFinger(tester, spot, downMs: 300, upMs: 360, pointer: 12);
    expect(harness.seeks, hasLength(1));
    expect(harness.seeks.single, harness.subtitles[6].startTime);
    expect(
      tester.getTopLeft(target).dy,
      closeTo(dyBefore, 0.5),
      reason: '双击只跳转媒体时间，不应触发文稿定位',
    );

    await anchor.up();
    await tester.pump();
    await harness.dispose(tester);
  });

  testWidgets('单指点击保持原有的「跳转并定位」行为', (tester) async {
    final harness = await pumpSidebar(tester);

    final target = find.text('subtitle 5');
    expect(target, findsOneWidget);
    await tapWithNewFinger(
      tester,
      tester.getCenter(target),
      downMs: 100,
      upMs: 150,
      pointer: 20,
    );

    expect(harness.seeks, hasLength(1));
    expect(harness.seeks.single, harness.subtitles[5].startTime);

    await harness.dispose(tester);
  });

  testWidgets('两次轻点间隔过久不算双击', (tester) async {
    final harness = await pumpSidebar(tester);

    final anchor = await tester.startGesture(
      const Offset(180, 240),
      pointer: 30,
    );
    await tester.pump(const Duration(milliseconds: 16));
    await anchor.moveBy(const Offset(0, -80));
    await tester.pump(const Duration(milliseconds: 16));

    final Offset spot = tester.getCenter(find.text('subtitle 6'));
    await tapWithNewFinger(tester, spot, downMs: 100, upMs: 150, pointer: 31);
    // 第二次按下距第一次抬起 500ms > kDoubleTapTimeout(300ms)。
    await tapWithNewFinger(tester, spot, downMs: 650, upMs: 700, pointer: 32);

    expect(harness.seeks, isEmpty);

    await anchor.up();
    await tester.pump();
    await harness.dispose(tester);
  });

  testWidgets('两次轻点落在不同字幕行不算双击', (tester) async {
    final harness = await pumpSidebar(tester);

    final anchor = await tester.startGesture(
      const Offset(180, 240),
      pointer: 40,
    );
    await tester.pump(const Duration(milliseconds: 16));
    await anchor.moveBy(const Offset(0, -80));
    await tester.pump(const Duration(milliseconds: 16));

    final Offset first = tester.getCenter(find.text('subtitle 6'));
    final Offset second = tester.getCenter(find.text('subtitle 5'));
    await tapWithNewFinger(tester, first, downMs: 100, upMs: 150, pointer: 41);
    await tapWithNewFinger(tester, second, downMs: 260, upMs: 310, pointer: 42);

    expect(harness.seeks, isEmpty);

    await anchor.up();
    await tester.pump();
    await harness.dispose(tester);
  });

  testWidgets('锚定手指中途松手后重新落指，不会被拼成双击', (tester) async {
    final harness = await pumpSidebar(tester);

    final firstAnchor = await tester.startGesture(
      const Offset(180, 240),
      pointer: 50,
    );
    await tester.pump(const Duration(milliseconds: 16));
    await firstAnchor.moveBy(const Offset(0, -80));
    await tester.pump(const Duration(milliseconds: 16));

    final Offset spot = tester.getCenter(find.text('subtitle 6'));
    await tapWithNewFinger(tester, spot, downMs: 100, upMs: 150, pointer: 51);
    expect(harness.seeks, isEmpty);

    // 锚定手指抬起 → 会话结束，候选必须作废。
    await firstAnchor.up();
    await tester.pump(const Duration(milliseconds: 16));

    // 立刻换一根手指按住，再点一次：这是新会话的第一次轻点，不能算双击。
    final secondAnchor = await tester.startGesture(
      const Offset(180, 240),
      pointer: 52,
    );
    await tester.pump(const Duration(milliseconds: 16));
    await secondAnchor.moveBy(const Offset(0, -20));
    await tester.pump(const Duration(milliseconds: 16));
    await tapWithNewFinger(
      tester,
      tester.getCenter(find.text('subtitle 6')),
      downMs: 200,
      upMs: 250,
      pointer: 53,
    );

    expect(harness.seeks, isEmpty);

    await secondAnchor.up();
    await tester.pump();
    await harness.dispose(tester);
  });

  testWidgets('鼠标在拖拽会话中的连点不触发本机制', (tester) async {
    final harness = await pumpSidebar(tester);

    final anchor = await tester.startGesture(
      const Offset(180, 240),
      pointer: 60,
    );
    await tester.pump(const Duration(milliseconds: 16));
    await anchor.moveBy(const Offset(0, -80));
    await tester.pump(const Duration(milliseconds: 16));

    final Offset spot = tester.getCenter(find.text('subtitle 6'));
    for (final int pointer in <int>[61, 62]) {
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        pointer: pointer,
      );
      await gesture.down(spot, timeStamp: Duration(milliseconds: pointer * 2));
      await tester.pump(const Duration(milliseconds: 16));
      await gesture.up(timeStamp: Duration(milliseconds: pointer * 2 + 40));
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(harness.seeks, isEmpty, reason: '本机制只面向触屏');

    await anchor.up();
    await tester.pump();
    await harness.dispose(tester);
  });

  testWidgets('落在顶部工具栏的连点不算双击', (tester) async {
    final harness = await pumpSidebar(tester);

    final anchor = await tester.startGesture(
      const Offset(180, 240),
      pointer: 70,
    );
    await tester.pump(const Duration(milliseconds: 16));
    await anchor.moveBy(const Offset(0, -80));
    await tester.pump(const Duration(milliseconds: 16));

    // 工具栏在列表区之外：既不会被登记为候选轻点，也不能充当锚点。
    const Offset toolbarSpot = Offset(180, 8);
    await tapWithNewFinger(
      tester,
      toolbarSpot,
      downMs: 100,
      upMs: 150,
      pointer: 71,
    );
    await tapWithNewFinger(
      tester,
      toolbarSpot,
      downMs: 260,
      upMs: 310,
      pointer: 72,
    );

    expect(harness.seeks, isEmpty);

    await anchor.up();
    await tester.pump();
    await harness.dispose(tester);
  });

  testWidgets('双击松手时旧原生时钟不能把文稿拉回跳转前', (tester) async {
    final harness = await pumpSidebar(tester);
    final anchor = await tester.startGesture(
      const Offset(180, 240),
      pointer: 90,
    );
    await tester.pump(const Duration(milliseconds: 16));
    await anchor.moveBy(const Offset(0, -80));
    await tester.pump(const Duration(milliseconds: 16));
    final target = find.text('subtitle 6');
    final spot = tester.getCenter(target);
    await tapWithNewFinger(tester, spot, downMs: 100, upMs: 160, pointer: 91);
    await tapWithNewFinger(tester, spot, downMs: 300, upMs: 360, pointer: 92);
    expect(harness.seeks, hasLength(1));
    // The player has not acknowledged the seek yet when the anchor is lifted.
    expect(harness.controller.value.position, const Duration(seconds: 3));
    await anchor.up();
    await tester.pumpAndSettle();
    final list = tester.widget<ScrollablePositionedList>(
      find.byType(ScrollablePositionedList),
    );
    ItemPosition position() => list.itemPositionsNotifier!.itemPositions.value
        .singleWhere((item) => item.index == 6);
    expect(position().itemLeadingEdge, closeTo(.3, .01));
    harness.controller.value = harness.controller.value.copyWith(
      position: harness.subtitles[6].startTime,
    );
    await tester.pumpAndSettle();
    expect(position().itemLeadingEdge, closeTo(.3, .01));
    expect(harness.controller.value.isPlaying, isTrue);
    expect(harness.seeks, hasLength(1));
    await harness.dispose(tester);
  });

  testWidgets('双击只 seek，松手后才定位到当前字幕', (tester) async {
    // seek 会推进播放位置，松手时的「当前句」由实时位置解析得到。
    final harness = await pumpSidebar(tester, followSeek: true);

    final anchor = await tester.startGesture(
      const Offset(180, 240),
      pointer: 80,
    );
    await tester.pump(const Duration(milliseconds: 16));
    await anchor.moveBy(const Offset(0, -80));
    await tester.pump(const Duration(milliseconds: 16));

    final Offset spot = tester.getCenter(find.text('subtitle 6'));
    final double dyBeforeRelease = tester
        .getTopLeft(find.text('subtitle 6'))
        .dy;

    await tapWithNewFinger(tester, spot, downMs: 100, upMs: 160, pointer: 81);
    await tapWithNewFinger(tester, spot, downMs: 300, upMs: 360, pointer: 82);
    expect(harness.seeks, hasLength(1));
    // 按住期间文稿绝不能动。
    expect(
      tester.getTopLeft(find.text('subtitle 6')).dy,
      closeTo(dyBeforeRelease, 0.5),
    );

    await anchor.up();
    await tester.pumpAndSettle();

    // 松手后 subtitle 6 成为当前句，应被定位到 30% 的对齐位置。
    final Rect listRect = tester.getRect(
      find.byType(ScrollablePositionedList).first,
    );
    expect(
      tester.getTopLeft(find.text('subtitle 6')).dy - listRect.top,
      closeTo(listRect.height * 0.3, 28),
    );

    await harness.dispose(tester);
  });
}

class _Harness {
  _Harness({
    required this.controller,
    required this.subtitles,
    required this.seeks,
  });

  final VideoPlayerController controller;
  final List<SubtitleItem> subtitles;
  final List<Duration> seeks;

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await controller.dispose();
  }
}
