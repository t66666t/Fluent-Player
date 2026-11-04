import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/transcription_status.dart';
import 'package:video_player_app/models/transcription_progress.dart';
import 'package:video_player_app/models/batch_subtitle_task_view.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/widgets/ai_transcription_panel.dart';
import 'package:video_player_app/widgets/task_queue_table.dart';

class _ActiveTranscription extends TranscriptionManager {
  @override
  String get currentVideoPath => 'lesson.mp4';
  @override
  TranscriptionStatus get status => TranscriptionStatus.transcribing;
  @override
  double get progress => 0.55;
  @override
  String get statusMessage => '第 2/3 段 · 59:58–119:58 · 等待识别结果 · 已等待 00:32';
  @override
  bool isVideoRunning(String videoPath, {String? videoId}) => true;
}

class _DownloadingPodcast extends _ActiveTranscription {
  @override
  TranscriptionStatus get status => TranscriptionStatus.downloading;
  @override
  double get progress => 0.5;
  @override
  String get statusMessage =>
      '正在下载播客音频 50% · 60 MB / 120 MB · 2 MB/s · 剩余约 30s · 已复用 20 MB';
}

class _QueryRestricted extends _ActiveTranscription {
  @override
  String get statusMessage =>
      '第 1/2 段 · 查询结果时触发访问限制，不会重新上传 · 15 秒后继续查询 · 已等待 00:12';
}

class _Translating extends _ActiveTranscription {
  double fraction = 0;
  @override
  TranscriptionStatus get status => TranscriptionStatus.translating;
  @override
  double get progress => 0.6 + 0.3 * fraction;
  @override
  double? get translationProgress => fraction;
  @override
  String get statusMessage => '已处理 ${(fraction * 20).round()}/20 条';

  void update(double value) {
    fraction = value;
    notifyListeners();
  }
}

void main() {
  for (final translate in [false, true]) {
    test(
      'download completion cannot finish the workflow (translate=$translate)',
      () {
        final plan = TranscriptionProgressPlan(translate: translate);
        var overall = 0.0;
        void advance(double next, TranscriptionStatus status) {
          final previous = overall;
          overall = TranscriptionProgressPlan.advance(overall, next, status);
          expect(overall, greaterThanOrEqualTo(previous));
          expect(overall, lessThan(1));
        }

        advance(plan.download(1), TranscriptionStatus.downloading);
        expect(overall, lessThan(0.15));
        advance(plan.preparation(0), TranscriptionStatus.extracting);
        advance(plan.preparation(0.8), TranscriptionStatus.extracting);
        // A preparation retry and ASR polling must not jump or regress.
        advance(plan.preparation(0), TranscriptionStatus.extracting);
        advance(plan.recognition(0.7), TranscriptionStatus.transcribing);
        final waitingProgress = overall;
        advance(plan.recognition(0.7), TranscriptionStatus.transcribing);
        expect(overall, waitingProgress);
        advance(plan.recognition(1), TranscriptionStatus.transcribing);
        if (translate) {
          expect(overall, lessThanOrEqualTo(0.6));
          final beforeTranslation = overall;
          advance(plan.translation(0.5), TranscriptionStatus.translating);
          expect(overall - beforeTranslation, greaterThan(0.1));
          advance(plan.translation(1), TranscriptionStatus.translating);
        }
        advance(plan.embedding(1), TranscriptionStatus.embedding);
        // Even an erroneous intermediate 100% is capped until completion.
        advance(1, TranscriptionStatus.embedding);
        expect((overall * 100).floor(), 99);
        expect(
          TranscriptionProgressPlan.advance(
            overall,
            1,
            TranscriptionStatus.completed,
          ),
          1,
        );
      },
    );
  }

  for (final width in [240.0, 420.0]) {
    testWidgets(
      'translation updates separately from overall progress at $width',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final manager = _Translating();
        addTearDown(manager.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: width,
                height: 700,
                child: ChangeNotifierProvider<TranscriptionManager>.value(
                  value: manager,
                  child: AiTranscriptionPanel(
                    videoPath: 'lesson.mp4',
                    onCompleted: (_) {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('翻译字幕'), findsOneWidget);
        expect(find.text('翻译 0%'), findsOneWidget);
        expect(find.text('总进度 60%'), findsOneWidget);
        manager.update(0.5);
        await tester.pump();
        expect(find.text('翻译 50%'), findsOneWidget);
        expect(find.text('总进度 75%'), findsOneWidget);
        expect(find.text('已处理 10/20 条'), findsOneWidget);
        expect(
          tester
              .widgetList<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator),
              )
              .map((bar) => bar.value),
          containsAll([0.5, 0.75]),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final width in [360.0, 1280.0]) {
    testWidgets('batch translation shows both percentages at $width', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      Future<void> showProgress(double fraction) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TaskQueueTable(
              tasks: [
                BatchSubtitleTaskView(
                  mediaKey: 'lesson',
                  videoPath: 'lesson.mp4',
                  videoName: 'Lesson',
                  videoDuration: '00:20',
                  isExternal: true,
                  status: TranscriptionStatus.translating,
                  progress: 0.6 + 0.3 * fraction,
                  translationProgress: fraction,
                  statusMessage: '已处理 ${(fraction * 20).round()}/20 条',
                  createdAt: 1,
                ),
              ],
              autoDeletedKeys: const {},
              onStart: (_) {},
              onRetry: (_) {},
              onDelete: (_) {},
              onReorder: (_, _) {},
            ),
          ),
        ),
      );
      await showProgress(0);
      expect(find.text('0%'), findsOneWidget);
      await showProgress(0.5);
      expect(find.text('翻译'), findsOneWidget);
      expect(find.text('50%'), findsOneWidget);
      expect(find.text('总进度 75%'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  for (final width in [240.0, 420.0]) {
    testWidgets(
      'query restriction countdown fits at $width without fake progress',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final manager = _QueryRestricted();
        addTearDown(manager.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: width,
                height: 640,
                child: ChangeNotifierProvider<TranscriptionManager>.value(
                  value: manager,
                  child: AiTranscriptionPanel(
                    videoPath: 'lesson.mp4',
                    onCompleted: (_) {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('等待重试'), findsOneWidget);
        expect(find.text('等待结果'), findsOneWidget);
        expect(find.textContaining('15 秒后继续查询'), findsOneWidget);
        expect(find.textContaining('55%'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'podcast download size, speed, reuse and remaining time fit at $width',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final manager = _DownloadingPodcast();
        addTearDown(manager.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: width,
                height: 640,
                child: ChangeNotifierProvider<TranscriptionManager>.value(
                  value: manager,
                  child: AiTranscriptionPanel(
                    videoPath: 'lesson.mp4',
                    onCompleted: (_) {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('下载音频'), findsOneWidget);
        expect(find.textContaining('2 MB/s'), findsOneWidget);
        expect(find.textContaining('已复用 20 MB'), findsOneWidget);
        expect(find.text('总进度 50%'), findsOneWidget);
        expect(find.byType(SnackBar), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  for (final width in [240.0, 420.0]) {
    testWidgets(
      'shows the segment, stage and honest waiting state at $width px',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final manager = _ActiveTranscription();
        addTearDown(manager.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  height: 640,
                  child: ChangeNotifierProvider<TranscriptionManager>.value(
                    value: manager,
                    child: AiTranscriptionPanel(
                      videoPath: 'lesson.mp4',
                      onCompleted: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('识别语音'), findsOneWidget);
        expect(find.text('等待结果'), findsOneWidget);
        expect(find.textContaining('第 2/3 段'), findsOneWidget);
        expect(find.textContaining('已等待 00:32'), findsOneWidget);
        expect(find.text('55%'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
