import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/models/ocr_subtitle_models.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_materialization_service.dart';
import 'package:video_player_app/services/ocr_subtitle_manager.dart';
import 'package:video_player_app/widgets/ocr_subtitle_panel.dart';

/// 不跑真实 OCR：任务状态由测试直接设定。
class _FakeOcrManager extends OcrSubtitleManager {
  _FakeOcrManager() : super(library: LibraryService());

  OcrSubtitleJob? fakeJob;

  void setJob(OcrSubtitleJob? job) {
    fakeJob = job;
    notifyListeners();
  }

  @override
  OcrSubtitleJob? get job => fakeJob;
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> isModelInstalled(OcrSubtitleLanguage language) async => true;
  @override
  Future<Duration> estimateDuration({
    required Duration mediaDuration,
    required Duration start,
    required Duration end,
    int trackCount = 1,
    List<OcrSubtitleTrack>? tracks,
    String? videoId,
  }) async => const Duration(minutes: 1);
  @override
  int get totalBundledOnnxModelCount => 4;
}

const _videoId = 'ocr-width-test';

OcrSubtitleJob _job(OcrSubtitleJobStatus status) => OcrSubtitleJob(
  videoId: _videoId,
  videoPath: 'ocr-width-test.mp4',
  tracks: const [],
  start: Duration.zero,
  end: const Duration(minutes: 1),
  status: status,
  progress: 0.4,
  error: status == OcrSubtitleJobStatus.failed ? '假失败' : null,
);

Finder _action() => find.byWidgetPredicate(
  (w) =>
      w.key == const ValueKey('ocr-pinned-start') ||
      w.key == const ValueKey('ocr-pinned-cancel'),
);

void main() {
  for (final (width, scale) in [
    (261.0, 1.0),
    (261.0, 1.5),
    (261.0, 2.0),
    (360.0, 1.0),
  ]) {
    testWidgets('开始 / 取消任务 / 重试 OCR 按钮宽度和左边位置不变（宽 $width × $scale）', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(800, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final manager = _FakeOcrManager();
      final materialization = MediaMaterializationService(BilibiliApiService());
      addTearDown(manager.dispose);
      addTearDown(materialization.dispose);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<OcrSubtitleManager>.value(value: manager),
            ChangeNotifierProvider<MediaMaterializationService>.value(
              value: materialization,
            ),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  width: width,
                  child: OcrSubtitlePanel(
                    videoItem: VideoItem(
                      id: _videoId,
                      path: 'ocr-width-test.mp4',
                      title: 'OCR width test',
                      durationMs: 600000,
                      lastUpdated: 0,
                    ),
                    duration: const Duration(minutes: 10),
                    currentPosition: () => Duration.zero,
                    pauseForRegionSelection: () async => false,
                    restorePlayback: (_) async {},
                    onBack: () {},
                    onCompleted: (_) async {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('开始 OCR 识别'), findsOneWidget);
      final idle = tester.getRect(_action());

      for (final status in [
        OcrSubtitleJobStatus.recognizing,
        OcrSubtitleJobStatus.failed,
      ]) {
        manager.setJob(_job(status));
        await tester.pump();
        final r = tester.getRect(_action());
        expect((r.left, r.width), (idle.left, idle.width), reason: '$status');
      }
      expect(find.text('重试 OCR 识别'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
