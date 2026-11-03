import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';

/// 切页（横屏 ↔ 竖屏）时的字幕文稿定位修复。
///
/// 这些用例覆盖的是「修复定位被静默丢弃 → 文稿停在空白/旧位置」的成因：
/// 1. post-frame 回调只有在有帧被调度时才执行，播放暂停/界面静止时没有任何
///    东西会调度帧，只注册回调会让修复永远悬空；
/// 2. 切页瞬间面板被压缩为 0 高，列表没有几何信息，此时落地的跳转会被丢弃，
///    请求必须保留到视口恢复后重新驱动。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'explicit viewport repair lands even when nothing schedules a frame',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'autoScrollSubtitles': false,
        'subtitleViewMode': 0,
      });
      final settings = SettingsService();
      settings.resetForTest();
      await settings.init();

      final subtitles = _buildSubtitles(count: 30);
      final controller = VideoPlayerController.networkUrl(
        Uri.parse('https://example.invalid/idle-repair.mp4'),
      );
      // 暂停播放：没有任何东西会持续调度帧，正是切页后可能遇到的静止状态。
      controller.value = VideoPlayerValue(
        duration: const Duration(minutes: 2),
        position: subtitles[20].startTime,
        isInitialized: true,
        isPlaying: false,
      );
      final sidebarKey = GlobalKey<SubtitleSidebarState>();

      await _pumpSidebar(tester, sidebarKey, controller, subtitles);
      await _pumpFrames(tester, 6);

      // 人为滚到文稿开头，模拟“切页后文稿停在旧位置”。
      sidebarKey.currentState!.jumpToFirstSubtitleTop();
      await _pumpFrames(tester, 6);
      expect(_paintedSubtitleIndices(tester), contains(0));

      // 切页修复：不依赖播放状态与自动跟随开关。
      sidebarKey.currentState!.locateToCurrentSubtitle(ignorePointer: true);
      await _pumpFrames(tester, 6);

      final painted = _paintedSubtitleIndices(tester);
      expect(
        painted,
        isNotEmpty,
        reason: '修复定位后文稿不能是空白',
      );
      expect(
        painted,
        contains(20),
        reason: '修复定位必须把当前字幕滚回可见区域，实际可见：$painted',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await controller.dispose();
    },
  );

  for (final articleMode in <bool>[false, true]) {
    testWidgets(
      '${articleMode ? 'article' : 'list'} repair survives a collapsed panel '
      'and painting resumes without another request',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'autoScrollSubtitles': true,
          'subtitleViewMode': articleMode ? 1 : 0,
          'subtitleArticleSentencesPerParagraph': 1,
        });
        final settings = SettingsService();
        settings.resetForTest();
        await settings.init();

        final subtitles = _buildSubtitles(count: 120);
        final controller = VideoPlayerController.networkUrl(
          Uri.parse('https://example.invalid/collapsed-repair.mp4'),
        );
        controller.value = VideoPlayerValue(
          duration: const Duration(minutes: 8),
          position: subtitles[80].startTime,
          isInitialized: true,
          isPlaying: true,
        );
        final sidebarKey = GlobalKey<SubtitleSidebarState>();

        await _pumpSidebar(tester, sidebarKey, controller, subtitles);
        await _pumpFrames(tester, 8);
        sidebarKey.currentState!.locateToCurrentSubtitle(ignorePointer: true);
        await _pumpFrames(tester, 8);
        expect(_paintedSubtitleIndices(tester), contains(80));

        // 切页瞬间面板被压缩为 0 高（横屏尺寸下的竖屏页），列表失去几何信息。
        await _pumpSidebar(
          tester,
          sidebarKey,
          controller,
          subtitles,
          height: 0,
        );
        await _pumpFrames(tester, 3);
        sidebarKey.currentState!.locateToCurrentSubtitle(ignorePointer: true);
        await _pumpFrames(tester, 6);
        expect(_paintedSubtitleIndices(tester), isEmpty);

        // 面板恢复高度：即使页面不再补发修复请求，请求也必须自动落地。
        controller.value = controller.value.copyWith(
          position: subtitles[100].startTime,
        );
        await _pumpSidebar(tester, sidebarKey, controller, subtitles);
        await _pumpFrames(tester, 25);

        final painted = _paintedSubtitleIndices(tester);
        expect(painted, isNotEmpty, reason: '面板恢复后文稿不能停留在空白');
        expect(
          painted,
          contains(100),
          reason: '面板恢复后必须重新定位到当前字幕，实际可见：$painted',
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await controller.dispose();
      },
    );
  }

  testWidgets(
    'covered portrait transcript repaints and follows playback after the '
    'landscape route pops',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'autoScrollSubtitles': true,
        'subtitleViewMode': 0,
      });
      final settings = SettingsService();
      settings.resetForTest();
      await settings.init();

      final subtitles = _buildSubtitles(count: 300);
      final controller = VideoPlayerController.networkUrl(
        Uri.parse('https://example.invalid/route-repair.mp4'),
      );
      controller.value = VideoPlayerValue(
        duration: const Duration(minutes: 15),
        position: subtitles[20].startTime,
        isInitialized: true,
        isPlaying: true,
      );
      final sidebarKey = GlobalKey<SubtitleSidebarState>();
      final navigatorKey = GlobalKey<NavigatorState>();

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          home: Scaffold(body: _SidebarHost(sidebarKey, controller, subtitles)),
        ),
      );
      await _pumpFrames(tester, 8);
      sidebarKey.currentState!.locateToCurrentSubtitle(ignorePointer: true);
      await _pumpFrames(tester, 8);
      expect(_paintedSubtitleIndices(tester), contains(20));

      // 打开不透明的横屏播放路由：竖屏侧栏被覆盖，期间列表不再布局。
      final navigator = navigatorKey.currentState!;
      unawaited(
        navigator.push(
          PageRouteBuilder<void>(
            pageBuilder: (context, animation, secondaryAnimation) =>
                const SizedBox.expand(child: ColoredBox(color: Colors.black)),
            opaque: true,
          ),
        ),
      );
      await _pumpFrames(tester, 20);

      // 横屏播放期间播放进度前进，自动跟随不应在被覆盖的页面上启动滚动动画。
      for (int i = 1; i <= 4; i++) {
        controller.value = controller.value.copyWith(
          position: subtitles[20 + i * 50].startTime,
        );
        await _pumpFrames(tester, 6);
      }

      // 退出横屏：回到竖屏页后文稿必须重新可见并跟上当前字幕。
      navigator.pop();
      await _pumpFrames(tester, 30);

      final painted = _paintedSubtitleIndices(tester);
      expect(painted, isNotEmpty, reason: '切回竖屏后文稿不能是空白');
      expect(
        painted,
        contains(220),
        reason: '切回竖屏后必须定位到当前字幕，实际可见：$painted',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await controller.dispose();
    },
  );
}

class _SidebarHost extends StatelessWidget {
  const _SidebarHost(this.sidebarKey, this.controller, this.subtitles);

  final GlobalKey<SubtitleSidebarState> sidebarKey;
  final VideoPlayerController controller;
  final List<SubtitleItem> subtitles;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 380,
        height: 460,
        child: SubtitleSidebar(
          key: sidebarKey,
          subtitles: subtitles,
          controller: controller,
          isCompact: true,
          isPortrait: true,
        ),
      ),
    );
  }
}

List<int> _paintedSubtitleIndices(WidgetTester tester) {
  final sidebarFinder = find.byType(SubtitleSidebar);
  if (sidebarFinder.evaluate().isEmpty) return const <int>[];
  final sidebarRect = tester.getRect(sidebarFinder);
  final indices = <int>{};
  void collect(Finder finder) {
    for (final element in finder.evaluate()) {
      final String plain = element.widget is Text
          ? (element.widget as Text).data ?? ''
          : (element.widget as RichText).text.toPlainText();
      for (final match in RegExp('subtitle (\\d+)').allMatches(plain)) {
        final index = int.tryParse(match.group(1)!);
        if (index == null) continue;
        final rect = tester.getRect(find.byWidget(element.widget));
        if (rect.bottom > sidebarRect.top && rect.top < sidebarRect.bottom) {
          indices.add(index);
        }
      }
    }
  }

  collect(find.byType(Text));
  collect(find.byType(RichText));
  final sorted = indices.toList()..sort();
  return sorted;
}

List<SubtitleItem> _buildSubtitles({required int count}) {
  return List<SubtitleItem>.generate(count, (index) {
    final start = Duration(seconds: index * 3);
    return SubtitleItem(
      index: index,
      startTime: start,
      endTime: start + const Duration(seconds: 2),
      text: 'subtitle $index',
    );
  });
}

Future<void> _pumpSidebar(
  WidgetTester tester,
  GlobalKey<SubtitleSidebarState> key,
  VideoPlayerController controller,
  List<SubtitleItem> subtitles, {
  double height = 460,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 380,
            height: height,
            child: SubtitleSidebar(
              key: key,
              subtitles: subtitles,
              controller: controller,
              isCompact: true,
              isPortrait: true,
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _pumpFrames(WidgetTester tester, int count) async {
  for (int i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}
