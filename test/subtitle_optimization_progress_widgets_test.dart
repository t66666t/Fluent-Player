import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/batch_subtitle_task_view.dart';
import 'package:video_player_app/models/transcription_progress.dart';
import 'package:video_player_app/models/transcription_status.dart';
import 'package:video_player_app/services/ai_subtitle_api_settings.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/widgets/ai_transcription_panel.dart';
import 'package:video_player_app/widgets/subtitle_optimization_control.dart';
import 'package:video_player_app/widgets/subtitle_optimization_progress_view.dart';
import 'package:video_player_app/widgets/task_queue_table.dart';

class _Optimizing extends TranscriptionManager {
  @override
  String get currentVideoPath => 'lesson.mp4';
  @override
  TranscriptionStatus get status => TranscriptionStatus.optimizing;
  @override
  double get progress => .7;
  @override
  String get statusMessage => '正在优化当前字幕批次';
  @override
  SubtitleOptimizationProgress get optimizationProgress =>
      const SubtitleOptimizationProgress(processed: 20, total: 60);
  @override
  bool isVideoRunning(String videoPath, {String? videoId}) => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final preview = Platform.environment['SUBTITLE_OPTIMIZATION_PREVIEW'] == '1';
  const boundary = ValueKey('optimization-preview');
  setUpAll(() async {
    if (!preview) return;
    await (FontLoader('Noto Sans SC')
          ..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf')))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({
      SubtitleAiConnectionStore.preferencesKey: '[]',
    });
  });
  Widget frame(Widget child) => RepaintBoundary(
    key: boundary,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Noto Sans SC'),
      ),
      home: Scaffold(body: child),
    ),
  );
  Future<void> capture(WidgetTester tester, String name) async {
    if (!preview) return;
    await tester.runAsync(() async {
      final image = await tester
          .renderObject<RenderRepaintBoundary>(find.byKey(boundary))
          .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File(
        '.artifacts/subtitle-optimization-design/previews/$name.png',
      );
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final width in [320.0, 900.0]) {
    testWidgets(
      'queue retains optimization item counts during optimization and translation at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 740);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        for (final translating in [false, true]) {
          await tester.pumpWidget(
            frame(
              TaskQueueTable(
                tasks: [
                  BatchSubtitleTaskView(
                    mediaKey: 'lesson',
                    videoPath: 'lesson.mp4',
                    videoName: '字幕优化示例',
                    videoDuration: '10:00',
                    isExternal: true,
                    status: translating
                        ? TranscriptionStatus.translating
                        : TranscriptionStatus.optimizing,
                    progress: .72,
                    translationProgress: translating ? .4 : null,
                    optimizationProgress: const SubtitleOptimizationProgress(
                      processed: 20,
                      total: 60,
                    ),
                    processingStages: '转录 → 优化 → 翻译',
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
          );
          await tester.pumpAndSettle();
          expect(find.text('优化 20/60 条').hitTestable(), findsOneWidget);
          final view = find.byType(SubtitleOptimizationProgressView);
          final bar = find.descendant(
            of: view,
            matching: find.byType(LinearProgressIndicator),
          );
          expect(
            tester.widget<LinearProgressIndicator>(bar).value,
            closeTo(1 / 3, .001),
          );
          expect(tester.takeException(), isNull);
          await capture(
            tester,
            'queue-${width.toInt()}-${translating ? 'translation' : 'optimization'}',
          );
        }
      },
    );
  }
  testWidgets('AI panel shows optimization item counts without translation', (
    tester,
  ) async {
    final manager = _Optimizing();
    addTearDown(manager.dispose);
    await tester.pumpWidget(
      frame(
        SizedBox(
          width: 240,
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
    );
    await tester.pump();
    expect(find.text('优化 20/60 条'), findsOneWidget);
    expect(find.byType(SubtitleOptimizationProgressView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final size in [const Size(320, 568), const Size(568, 320)]) {
    testWidgets(
      'prompt opens expanded and stays editable above the keyboard at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          frame(
            const Align(
              alignment: Alignment.topCenter,
              child: SubtitleOptimizationControl(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find
              .byKey(const ValueKey('subtitle-optimization-prompt-button'))
              .hitTestable(),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const ValueKey('subtitle-optimization-prompt-button')),
        );
        await tester.pumpAndSettle();
        final prompt = find.byKey(
          const ValueKey('subtitle-optimization-prompt'),
        );
        expect(prompt, findsOneWidget);
        expect(
          find.text('保存').hitTestable(),
          findsOneWidget,
          reason: 'Long prompts keep the save action visible.',
        );
        await capture(tester, 'settings-${size.width.toInt()}');
        tester.view.viewInsets = const FakeViewPadding(bottom: 180);
        await tester.pumpAndSettle();
        await tester.ensureVisible(prompt);
        await tester.enterText(prompt, '只纠正有把握的错字。');
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(prompt).controller!.text, '只纠正有把握的错字。');
        await tester.ensureVisible(find.text('保存'));
        await tester.pumpAndSettle();
        expect(find.text('保存').hitTestable(), findsOneWidget);
        expect(
          tester.getRect(find.text('保存')).bottom,
          lessThanOrEqualTo(size.height - 180),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
