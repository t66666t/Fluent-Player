import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/batch_subtitle_task_view.dart';
import 'package:video_player_app/models/local_asr_progress.dart';
import 'package:video_player_app/models/transcription_progress.dart';
import 'package:video_player_app/models/transcription_status.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/widgets/ai_transcription_panel.dart';
import 'package:video_player_app/widgets/task_queue_table.dart';
import 'package:video_player_app/widgets/transcription_audio_progress_label.dart';

class _LocalManager extends TranscriptionManager {
  _LocalManager(this.total);
  final Duration total;
  Duration committed = Duration.zero;
  bool translating = false;
  @override
  bool get isProcessing => true;
  @override
  String get currentVideoPath => 'media.mp4';
  @override
  bool isVideoRunning(String path, {String? videoId}) => true;
  @override
  TranscriptionStatus get status => translating
      ? TranscriptionStatus.translating
      : TranscriptionStatus.transcribing;
  @override
  String get statusMessage => translating ? '正在翻译当前字幕批次' : '正在恢复标点';
  @override
  double get progress => .85;
  @override
  TranscriptionAudioProgress get localAudioProgress =>
      TranscriptionAudioProgress(completed: committed, total: total);
  @override
  LocalAsrProgress get localAsrProgress => LocalAsrProgress(
    model: 'SenseVoice',
    pipeline: true,
    reuseModels: true,
    reason: '识别与增强并行',
    total: total,
    recognized: total,
    enhanced: total,
    elapsed: Duration.zero,
    capturedAt: DateTime.now(),
    recognition: const LocalAsrLaneProgress(phase: '已识别'),
    enhancement: const LocalAsrLaneProgress(phase: '时间精校'),
    pieces: 3,
    completedPieces: 2,
    asrThreads: 2,
    enhancementThreads: 1,
  );

  void update(Duration value) {
    committed = value;
    translating = !translating;
    notifyListeners();
  }
}

void main() {
  test('time fields use one format for the entire media duration', () {
    String label(Duration done, Duration total) =>
        TranscriptionAudioProgress(completed: done, total: total).label;
    expect(
      label(
        const Duration(minutes: 3, seconds: 24),
        const Duration(minutes: 12),
      ),
      '已完成 03:24 / 12:00',
    );
    for (final entry in {
      Duration.zero: '00:00:00',
      const Duration(minutes: 59, seconds: 59): '00:59:59',
      const Duration(hours: 1): '01:00:00',
    }.entries) {
      expect(
        label(entry.key, const Duration(hours: 1, minutes: 12)),
        '已完成 ${entry.value} / 01:12:00',
      );
    }
    expect(
      label(const Duration(hours: 99), const Duration(hours: 100)),
      '已完成 099:00:00 / 100:00:00',
    );
    expect(label(Duration.zero, Duration.zero), '已完成 00:00 / --:--');
    expect(
      label(const Duration(seconds: -1), const Duration(seconds: 30)),
      '已完成 00:00 / 00:30',
    );
    expect(
      label(const Duration(minutes: 2), const Duration(seconds: 30)),
      '已完成 00:30 / 00:30',
    );
  });

  for (final width in [240.0, 360.0, 1280.0]) {
    for (final total in [
      const Duration(minutes: 12),
      const Duration(hours: 1, minutes: 12),
    ]) {
      testWidgets('one fixed header across pipeline updates at $width/$total', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 1000);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final manager = _LocalManager(total);
        addTearDown(manager.dispose);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!,
            ),
            home: Scaffold(
              body: ChangeNotifierProvider<TranscriptionManager>.value(
                value: manager,
                child: AiTranscriptionPanel(
                  videoPath: 'media.mp4',
                  onCompleted: (_) {},
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final header = find.byType(TranscriptionAudioProgressLabel);
        expect(header, findsOneWidget);
        final initial = tester.getRect(header);
        for (final done in [
          const Duration(seconds: 11),
          const Duration(minutes: 3, seconds: 24),
          if (total.inHours > 0) const Duration(hours: 1),
        ]) {
          manager.update(done);
          await tester.pump();
          expect(find.text(manager.localAudioProgress.label), findsOneWidget);
          expect(tester.getRect(header), initial);
          expect(
            tester
                .widgetList<LinearProgressIndicator>(
                  find.byType(LinearProgressIndicator),
                )
                .first
                .value,
            manager.localAudioProgress.fraction,
          );
          final text = tester.widget<Text>(
            find.descendant(
              of: header,
              matching: find.text(manager.localAudioProgress.label),
            ),
          );
          expect(text.maxLines, 1);
          expect(text.softWrap, isFalse);
          expect(find.textContaining(RegExp(r'^总进度 \d+%$')), findsNothing);
          expect(tester.takeException(), isNull);
        }
        // The detailed pipeline still exposes both processing lanes.
        expect(find.textContaining('识别 '), findsWidgets);
        expect(find.textContaining('增强 '), findsWidgets);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  for (final width in [320.0, 1280.0]) {
    testWidgets('task row progress keeps its width at $width', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      Future<void> show(Duration done) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TaskQueueTable(
              tasks: [
                BatchSubtitleTaskView(
                  mediaKey: 'media',
                  videoPath: 'media.mp4',
                  videoName: 'Media',
                  videoDuration: '01:12:00',
                  isExternal: true,
                  status: TranscriptionStatus.transcribing,
                  progress: .85,
                  audioProgress: TranscriptionAudioProgress(
                    completed: done,
                    total: const Duration(hours: 1, minutes: 12),
                  ),
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
      await show(Duration.zero);
      final header = find.byType(TranscriptionAudioProgressLabel);
      final initial = tester.getRect(header);
      await show(const Duration(hours: 1));
      expect(find.text('已完成 01:00:00 / 01:12:00'), findsOneWidget);
      expect(tester.getRect(header), initial);
      expect(tester.takeException(), isNull);
    });
  }
}
