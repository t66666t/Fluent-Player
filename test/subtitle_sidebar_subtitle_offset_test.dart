import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';

/// 画面字幕用「播放位置 - subtitleOffset」判定当前句，侧边栏的高亮与点击
/// 跳转必须使用同一条字幕时间轴，否则设置「字幕同步」后高亮会整体提前/滞后。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SettingsService> prepareSettings(int offsetMs) async {
    SharedPreferences.setMockInitialValues({
      'autoScrollSubtitles': false,
      'subtitleViewMode': 0,
      'portraitSidebarShowTimestamps': true,
      'landscapeSidebarShowTimestamps': true,
    });
    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();
    await settings.saveSubtitleOffsetMilliseconds(offsetMs);
    return settings;
  }

  List<SubtitleItem> buildSubtitles() => <SubtitleItem>[
    SubtitleItem(
      index: 0,
      startTime: Duration.zero,
      endTime: const Duration(seconds: 4),
      text: 'subtitle 0',
    ),
    SubtitleItem(
      index: 1,
      startTime: const Duration(seconds: 6),
      endTime: const Duration(seconds: 10),
      text: 'subtitle 1',
    ),
    SubtitleItem(
      index: 2,
      startTime: const Duration(seconds: 12),
      endTime: const Duration(seconds: 16),
      text: 'subtitle 2',
    ),
  ];

  VideoPlayerController buildController() {
    final controller = VideoPlayerController.networkUrl(
      Uri.parse('https://example.invalid/offset.mp4'),
    );
    controller.value = const VideoPlayerValue(
      duration: Duration(minutes: 1),
      isInitialized: true,
      isPlaying: false,
    );
    return controller;
  }

  Future<void> pumpSidebar(
    WidgetTester tester,
    VideoPlayerController controller,
    List<SubtitleItem> subtitles, {
    ValueChanged<Duration>? onItemTap,
    ValueListenable<Duration>? positionListenable,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 380,
            height: 460,
            child: SubtitleSidebar(
              subtitles: subtitles,
              controller: controller,
              positionListenable: positionListenable,
              isCompact: true,
              isPortrait: true,
              onItemTap: onItemTap,
            ),
          ),
        ),
      ),
    );
  }

  Color? timestampColor(WidgetTester tester, int index) {
    final finder = find.byKey(ValueKey('subtitle-time-$index'));
    expect(finder, findsOneWidget);
    return tester.widget<Text>(finder).style?.color;
  }

  testWidgets('设置字幕延迟后高亮跟随字幕时间轴', (tester) async {
    await prepareSettings(3000);
    final controller = buildController();
    final subtitles = buildSubtitles();
    await pumpSidebar(tester, controller, subtitles);
    await tester.pump();

    // 视频时间 6.5s，字幕时间轴为 3.5s：仍应高亮第 0 条。
    // 未做换算时会把 6.5s 直接当作字幕时间，错误高亮第 1 条。
    controller.value = controller.value.copyWith(
      position: const Duration(milliseconds: 6500),
    );
    await tester.pump();
    expect(timestampColor(tester, 0), Colors.blueAccent);
    expect(timestampColor(tester, 1), isNot(Colors.blueAccent));

    // 视频时间 12.5s，字幕时间轴为 9.5s：应高亮第 1 条而不是第 2 条。
    controller.value = controller.value.copyWith(
      position: const Duration(milliseconds: 12500),
    );
    await tester.pump();
    expect(timestampColor(tester, 1), Colors.blueAccent);
    expect(timestampColor(tester, 2), isNot(Colors.blueAccent));

    await tester.pumpWidget(const SizedBox.shrink());
    await controller.dispose();
  });

  testWidgets('暂停时调整字幕延迟立即刷新高亮', (tester) async {
    final settings = await prepareSettings(0);
    final controller = buildController();
    final subtitles = buildSubtitles();
    await pumpSidebar(tester, controller, subtitles);
    await tester.pump();

    // 暂停在 6.5s，此时按原始时间轴高亮第 1 条。
    controller.value = controller.value.copyWith(
      position: const Duration(milliseconds: 6500),
    );
    await tester.pump();
    expect(timestampColor(tester, 1), Colors.blueAccent);

    // 暂停中把字幕整体延后 3s：播放位置不再变化，但高亮应立即回落到第 0 条。
    settings.setSubtitleDelay(3.0);
    await tester.pump();
    expect(timestampColor(tester, 0), Colors.blueAccent);
    expect(timestampColor(tester, 1), isNot(Colors.blueAccent));

    await tester.pumpWidget(const SizedBox.shrink());
    await controller.dispose();
  });

  testWidgets('高亮跟随播放器真实位置，不被插值时钟超前', (tester) async {
    await prepareSettings(0);
    final controller = buildController();
    final subtitles = buildSubtitles();
    // 插值时钟比 controller 超前约 6s，若误用它判定当前句会高亮第 2 条。
    final positionNotifier = ValueNotifier<Duration>(
      const Duration(milliseconds: 12500),
    );
    await pumpSidebar(
      tester,
      controller,
      subtitles,
      positionListenable: positionNotifier,
    );
    await tester.pump();
    // controller 在 6.5s，插值时钟在 12.5s；高亮必须跟随 controller。
    controller.value = controller.value.copyWith(
      position: const Duration(milliseconds: 6500),
      isPlaying: true,
    );
    await tester.pump();

    expect(timestampColor(tester, 1), Colors.blueAccent);
    expect(timestampColor(tester, 2), isNot(Colors.blueAccent));

    await tester.pumpWidget(const SizedBox.shrink());
    positionNotifier.dispose();
    await controller.dispose();
  });

  testWidgets('点击字幕跳转时补偿字幕延迟', (tester) async {
    await prepareSettings(3000);
    final controller = buildController();
    final subtitles = buildSubtitles();
    Duration? tapped;
    await pumpSidebar(
      tester,
      controller,
      subtitles,
      onItemTap: (target) => tapped = target,
    );
    await tester.pump();

    await tester.tap(find.text('subtitle 1', findRichText: true));
    await tester.pumpAndSettle();

    // 点击方按视频时间 seek：6s 的字幕应跳到 9s。
    expect(tapped, const Duration(seconds: 9));

    await tester.pumpWidget(const SizedBox.shrink());
    await controller.dispose();
  });

  testWidgets('句间空隙仍高亮上一句，直到下一句开始', (tester) async {
    await prepareSettings(0);
    final controller = buildController();
    final subtitles = buildSubtitles();
    await pumpSidebar(tester, controller, subtitles);
    await tester.pump();

    // 4s 结束、6s 才开始：空隙里的阅读光标应停在第 0 条。
    controller.value = controller.value.copyWith(
      position: const Duration(milliseconds: 5000),
    );
    await tester.pump();
    expect(timestampColor(tester, 0), Colors.blueAccent);
    expect(timestampColor(tester, 1), isNot(Colors.blueAccent));

    controller.value = controller.value.copyWith(
      position: const Duration(seconds: 6),
    );
    await tester.pump();
    expect(timestampColor(tester, 1), Colors.blueAccent);
    expect(timestampColor(tester, 0), isNot(Colors.blueAccent));

    await tester.pumpWidget(const SizedBox.shrink());
    await controller.dispose();
  });

  testWidgets('越过句界时高亮立即切换，不被 80ms 节流拖住', (tester) async {
    await prepareSettings(0);
    final controller = buildController();
    final subtitles = buildSubtitles();
    await pumpSidebar(tester, controller, subtitles);
    await tester.pump();

    controller.value = controller.value.copyWith(
      position: const Duration(milliseconds: 5940),
    );
    await tester.pump();
    expect(timestampColor(tester, 0), Colors.blueAccent);

    // 下一帧只前进 80ms 以内，旧节流会跳过这次计算，画面字幕却已经切句。
    controller.value = controller.value.copyWith(
      position: const Duration(milliseconds: 6010),
    );
    await tester.pump();
    expect(timestampColor(tester, 1), Colors.blueAccent);
    expect(timestampColor(tester, 0), isNot(Colors.blueAccent));

    await tester.pumpWidget(const SizedBox.shrink());
    await controller.dispose();
  });
}
