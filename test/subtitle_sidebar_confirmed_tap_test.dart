import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';

/// 常规「点某一句字幕才跳转」必须等确认的短单击。
///
/// 回归三类误触：
///   1. 按住超过 kPressTimeout(100ms) 还没松手，不能已经 seek；
///   2. 长按后松开（选字/犹豫）不能被当成单击；
///   3. 按住再滑（触屏浏览、鼠标拖选用字）不能 seek。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final bool articleMode in <bool>[false, true]) {
    final String view = articleMode ? 'article' : 'list';

    testWidgets('$view 短单击仍会在抬起后跳转', (tester) async {
      final harness = await _pumpSidebar(tester, articleMode: articleMode);
      final Offset spot = _tapSpot(tester, _subtitleFinder(4, articleMode));

      final TestGesture gesture = await tester.startGesture(spot);
      await tester.pump();
      expect(harness.seeks, isEmpty, reason: '按下时还不能跳转');

      await gesture.up();
      await tester.pump();

      expect(harness.seeks, hasLength(1));
      expect(harness.seeks.single, harness.subtitles[4].startTime);

      await harness.dispose(tester);
    });

    testWidgets('$view 按住超过 100ms 仍未松手时不跳转', (tester) async {
      final harness = await _pumpSidebar(tester, articleMode: articleMode);
      final Offset spot = _tapSpot(tester, _subtitleFinder(4, articleMode));

      final TestGesture gesture = await tester.startGesture(spot);
      // 旧逻辑会在 kPressTimeout 后的 onTapDown 里立刻 seek。
      await tester.pump(const Duration(milliseconds: 120));
      expect(harness.seeks, isEmpty);

      await gesture.up();
      await tester.pump();
      expect(harness.seeks, hasLength(1));

      await harness.dispose(tester);
    });

    testWidgets('$view 长按松手不跳转', (tester) async {
      final harness = await _pumpSidebar(tester, articleMode: articleMode);
      final Offset spot = _tapSpot(tester, _subtitleFinder(4, articleMode));

      final TestGesture gesture = await tester.startGesture(spot);
      await tester.pump(kLongPressTimeout);
      await tester.pump(const Duration(milliseconds: 50));
      // 必须写 pointer 时间戳：测试手势默认 stamp 为 0，否则无法表达「按住了 550ms」。
      await gesture.up(timeStamp: const Duration(milliseconds: 550));
      await tester.pump();

      expect(harness.seeks, isEmpty, reason: '长按应留给选字，不能当成单击');

      await harness.dispose(tester);
    });

    testWidgets('$view 按住再滑浏览不跳转', (tester) async {
      final harness = await _pumpSidebar(tester, articleMode: articleMode);
      final Offset spot = _tapSpot(tester, _subtitleFinder(4, articleMode));

      final TestGesture gesture = await tester.startGesture(spot);
      await tester.pump(const Duration(milliseconds: 120));
      expect(harness.seeks, isEmpty);

      await gesture.moveBy(const Offset(0, -80));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(harness.seeks, isEmpty, reason: '滑动浏览文稿不应 seek');

      await harness.dispose(tester);
    });

    testWidgets('$view 鼠标拖动选字不跳转', (tester) async {
      final harness = await _pumpSidebar(tester, articleMode: articleMode);
      final Offset spot = _tapSpot(tester, _subtitleFinder(4, articleMode));

      final TestGesture gesture = await tester.startGesture(
        spot,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 120));
      expect(harness.seeks, isEmpty);

      // 水平拖一段，模拟鼠标选中文字；即使垂直滚动没接手，位移也必须挡住 seek。
      await gesture.moveBy(const Offset(36, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(harness.seeks, isEmpty, reason: '拖选用字不应 seek');

      await harness.dispose(tester);
    });
  }
}

Finder _subtitleFinder(int index, bool articleMode) {
  return find.text('subtitle $index', findRichText: articleMode);
}

/// 文章模式的句子左对齐，段落盒子很宽；点几何中心会落到空白处，
/// span 上的 [TapGestureRecognizer] 收不到事件。往左偏一点才能点中文字。
Offset _tapSpot(WidgetTester tester, Finder target) {
  final Rect rect = tester.getRect(target);
  return Offset(rect.left + 16, rect.center.dy);
}

Future<_Harness> _pumpSidebar(
  WidgetTester tester, {
  required bool articleMode,
}) async {
  SharedPreferences.setMockInitialValues({
    'autoScrollSubtitles': true,
    'subtitleViewMode': articleMode ? 1 : 0,
    'subtitleArticleSentencesPerParagraph': 1,
  });
  final settings = SettingsService();
  settings.resetForTest();
  await settings.init();

  final controller = VideoPlayerController.networkUrl(
    Uri.parse('https://example.invalid/confirmed-tap.mp4'),
  );
  controller.value = const VideoPlayerValue(
    duration: Duration(minutes: 10),
    isInitialized: true,
    isPlaying: true,
  );
  final subtitles = List<SubtitleItem>.generate(30, (index) {
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
          width: 320,
          height: 360,
          child: SubtitleSidebar(
            subtitles: subtitles,
            controller: controller,
            isCompact: true,
            onItemTap: (position) {
              seeks.add(position);
              controller.value = controller.value.copyWith(position: position);
            },
          ),
        ),
      ),
    ),
  );
  await tester.pump();

  return _Harness(controller: controller, subtitles: subtitles, seeks: seeks);
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
