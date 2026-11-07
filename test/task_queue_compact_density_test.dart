import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/batch_subtitle_task_view.dart';
import 'package:video_player_app/models/transcription_status.dart';
import 'package:video_player_app/widgets/task_queue_table.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader('Queue CJK')
          ..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf')))
        .load();
  });
  for (final (width, scale) in [
    (320.0, 1.0),
    (390.0, 1.0),
    (390.0, 2.0),
    (320.0, 2.0),
    (1440.0, 1.0),
  ]) {
    testWidgets(
      'stage fits one line and order row stays compact at $width / $scale',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark().copyWith(
              textTheme: ThemeData.dark().textTheme.apply(
                fontFamily: 'Queue CJK',
              ),
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: TaskQueueTable(
                tasks: const [
                  BatchSubtitleTaskView(
                    mediaKey: 'stage-test',
                    videoPath: 'clip.mp4',
                    videoName: '测试视频',
                    videoDuration: '12:00',
                    isExternal: true,
                    status: TranscriptionStatus.transcribing,
                    progress: .38,
                    statusMessage: '正在识别语音',
                    createdAt: 1,
                    isStarted: true,
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
        await tester.pumpAndSettle();
        final label = find.text('识别语音');
        expect(label, findsOneWidget);
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: label, matching: find.byType(RichText)),
        );
        expect(paragraph.didExceedMaxLines, isFalse);
        final boxes = paragraph.getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 4),
        );
        expect(boxes.map((b) => b.top).toSet(), hasLength(1));
        if (scale == 1 && width >= 390 && width < 720) {
          expect(
            tester
                .getSize(find.byKey(const ValueKey('task-queue-order-row')))
                .height,
            lessThanOrEqualTo(36),
          );
        }
        if (width >= 720) {
          expect(
            find.byKey(const ValueKey('task-queue-order-row')),
            findsNothing,
          );
          expect(find.text('倒序显示'), findsNothing);
        }
        await tester.tap(
          find.byKey(const ValueKey('task-queue-display-order')),
        );
        await tester.pumpAndSettle();
        if (width < 720) {
          expect(find.text('正序显示'), findsOneWidget);
        } else {
          expect(find.byIcon(Icons.arrow_downward), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
