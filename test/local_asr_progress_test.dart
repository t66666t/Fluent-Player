import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/model_center/asr_execution_plan.dart';
import 'package:video_player_app/features/model_center/asr_progress_tracker.dart';
import 'package:video_player_app/models/batch_subtitle_task_view.dart';
import 'package:video_player_app/models/local_asr_progress.dart';
import 'package:video_player_app/models/transcription_progress.dart';
import 'package:video_player_app/models/transcription_status.dart';
import 'package:video_player_app/widgets/local_asr_progress_view.dart';
import 'package:video_player_app/widgets/task_queue_table.dart';

LocalAsrProgress sample({int recognizedMinutes = 5}) => LocalAsrProgress(
  model: 'Parakeet TDT v3',
  pipeline: true,
  reuseModels: true,
  backend: 'CPU',
  reason: '识别与增强同时工作',
  total: const Duration(minutes: 10),
  recognized: Duration(minutes: recognizedMinutes),
  enhanced: const Duration(minutes: 4),
  elapsed: const Duration(seconds: 30),
  capturedAt: DateTime.now(),
  recognition: const LocalAsrLaneProgress(
    piece: 11,
    phase: '检测语音',
    phaseFraction: .6,
    active: true,
  ),
  enhancement: const LocalAsrLaneProgress(
    piece: 10,
    phase: '时间精校',
    phaseFraction: .4,
    active: true,
  ),
  pieces: 22,
  completedPieces: 9,
  asrThreads: 2,
  enhancementThreads: 1,
  preprocessAhead: true,
  prepared: const Duration(minutes: 6),
  preparation: const LocalAsrLaneProgress(
    piece: 12,
    phase: '降噪',
    phaseFraction: .3,
    active: true,
  ),
);

void main() {
  test('finishing enhancement never overwrites a running recognition lane', () {
    final tracker = AsrProgressTracker(
      model: 'model',
      total: const Duration(minutes: 1),
      pieces: 3,
      plan: const AsrExecutionPlan(
        pipeline: true,
        reuseModels: true,
        asrThreads: 2,
        enhancementThreads: 1,
        reason: 'parallel',
        preprocessAhead: true,
      ),
    );
    tracker.front(2, '识别语音', .5);
    tracker.preparing(3, '降噪', .4);
    tracker.preparedTo(const Duration(seconds: 55));
    tracker.recognizedPart(const Duration(seconds: 40));
    tracker.back(1, '补标点', 1);
    tracker.completed(const Duration(seconds: 30));
    final progress = tracker.snapshot;
    expect(progress.recognition.phase, '识别语音');
    expect(progress.recognition.piece, 2);
    expect(progress.recognition.active, isTrue);
    expect(progress.recognized, const Duration(seconds: 40));
    expect(progress.enhanced, const Duration(seconds: 30));
    expect(progress.preparation.piece, 3);
    expect(progress.prepared, const Duration(seconds: 55));
  });
  test('stage labels distinguish native work from recognition', () {
    for (final entry in {
      '正在进行轻量降噪': '音频降噪',
      '正在检测语音区间': '检测语音',
      '正在加载主识别模型': '加载模型',
      '正在恢复标点': '恢复标点',
      '正在修整字幕静音边界': '修整边界',
      '正在按时间轴整理字幕分句': '整理分句',
    }.entries) {
      expect(
        TranscriptionProgress.stage(
          TranscriptionStatus.transcribing,
          entry.key,
        ),
        entry.value,
      );
    }
  });
  for (final width in [240.0, 360.0, 600.0, 1280.0]) {
    testWidgets('local processing shows both lanes at $width', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: width,
                child: LocalAsrProgressView(progress: sample()),
              ),
            ),
          ),
        ),
      );
      expect(find.text('识别 05:00 / 10:00'), findsOneWidget);
      expect(find.text('增强 04:00 / 10:00'), findsOneWidget);
      expect(find.text('降噪 06:00 / 10:00'), findsOneWidget);
      expect(find.textContaining('第 11 块 · 检测语音'), findsOneWidget);
      expect(find.textContaining('第 10 块 · 时间精校'), findsOneWidget);
      expect(
        tester
            .widgetList<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .map((p) => p.value),
        containsAll([.5, .4]),
      );
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  for (final width in [360.0, 1280.0]) {
    testWidgets('task queue exposes both lanes and opens details at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TaskQueueTable(
              tasks: [
                BatchSubtitleTaskView(
                  mediaKey: 'audio',
                  videoPath: 'audio.wav',
                  videoName: 'audio',
                  videoDuration: '10:00',
                  isExternal: true,
                  status: TranscriptionStatus.transcribing,
                  progress: .5,
                  createdAt: 1,
                  localAsrProgress: sample(),
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
      expect(find.text('识别 50%'), findsOneWidget);
      expect(find.text('增强 40%'), findsOneWidget);
      await tester.tap(find.text('增强 40%'));
      await tester.pumpAndSettle();
      expect(find.text('本地转录进度'), findsOneWidget);
      expect(find.textContaining('第 11 块 · 检测语音'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('an open progress dialog continues receiving live task updates', (
    tester,
  ) async {
    Widget show(LocalAsrProgress p) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 100,
          child: LocalAsrProgressView(progress: p, compact: true),
        ),
      ),
    );
    await tester.pumpWidget(show(sample()));
    await tester.tap(find.text('增强 40%'));
    await tester.pumpAndSettle();
    expect(find.text('识别 05:00 / 10:00'), findsOneWidget);
    await tester.pumpWidget(show(sample(recognizedMinutes: 6)));
    await tester.pump();
    expect(find.text('识别 06:00 / 10:00'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
