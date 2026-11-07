import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/models/batch_subtitle_task_view.dart';
import 'package:video_player_app/models/transcription_status.dart';
import 'package:video_player_app/models/transcription_progress.dart';
import 'package:video_player_app/screens/batch_subtitle_screen.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/widgets/task_queue_table.dart';
import 'package:video_player_app/widgets/operation_status.dart';
import 'package:video_player_app/utils/transcription_failure_summary.dart';
import 'package:video_player_app/widgets/model_center_button.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final tasks = <BatchSubtitleTaskView>[
    const BatchSubtitleTaskView(
      mediaKey: 'internal:1',
      videoPath: 'first.mp4',
      videoId: '1',
      videoName: '这是一个用于测试窄屏省略显示的超长内部视频名称.mp4',
      videoDuration: '01:23:45',
      isExternal: false,
      status: TranscriptionStatus.transcribing,
      progress: 0.68,
      statusMessage: '正在生成字幕，请稍候',
      createdAt: 1,
      isStarted: true,
    ),
    const BatchSubtitleTaskView(
      mediaKey: 'external:2',
      videoPath: 'second.mkv',
      videoName: '外部视频.mkv',
      videoDuration: '08:12',
      isExternal: true,
      status: TranscriptionStatus.completed,
      progress: 1,
      statusMessage: '转录完成',
      createdAt: 2,
      isStarted: true,
    ),
  ];

  testWidgets('start all remains actionable when every task failed', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final manager = _FailedQueueManager(
      tasks.last.copyWith(status: TranscriptionStatus.error),
    );
    addTearDown(manager.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<TranscriptionManager>.value(value: manager),
          ChangeNotifierProvider<SettingsService>.value(
            value: SettingsService(),
          ),
          ChangeNotifierProvider<LibraryService>.value(value: LibraryService()),
        ],
        child: const MaterialApp(home: BatchSubtitleScreen()),
      ),
    );
    await tester.tap(find.text('全部开始'));
    expect(manager.startAllCalls, 1);
    expect(tester.takeException(), isNull);
  });

  for (final width in [360.0, 1280.0]) {
    testWidgets(
      'restart is available for stopped and completed rows at width $width',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 800);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final restarted = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TaskQueueTable(
                tasks: [
                  tasks.first,
                  tasks.last,
                  tasks.last.copyWith(
                    mediaKey: 'paused',
                    status: TranscriptionStatus.idle,
                    isStarted: false,
                  ),
                ],
                autoDeletedKeys: const {},
                onStart: (_) {},
                onRetry: (_) {},
                onDelete: (_) {},
                onReorder: (_, _) {},
                onRestart: restarted.add,
              ),
            ),
          ),
        );
        final buttons = find.byTooltip('从头开始');
        expect(buttons, findsNWidgets(3));
        expect(find.byTooltip('任务操作'), findsNothing);
        await tester.tap(buttons.at(0));
        expect(restarted, isEmpty);
        await tester.tap(buttons.at(1));
        await tester.tap(buttons.at(2));
        expect(restarted, [tasks.last.mediaKey, 'paused']);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('running and queued rows can pause at width $width', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final paused = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TaskQueueTable(
              tasks: [
                tasks.first,
                tasks.last.copyWith(
                  status: TranscriptionStatus.idle,
                  isStarted: true,
                ),
              ],
              autoDeletedKeys: const {},
              onStart: (_) {},
              onRetry: (_) {},
              onDelete: (_) {},
              onReorder: (_, _) {},
              onPause: paused.add,
            ),
          ),
        ),
      );
      expect(find.byTooltip('暂停'), findsNWidgets(2));
      await tester.tap(find.byTooltip('暂停').first);
      await tester.tap(find.byTooltip('暂停').last);
      expect(paused, [tasks.first.mediaKey, tasks.last.mediaKey]);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'mobile failures expose a readable reason, actions, and diagnostic details',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 780);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      var retries = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TaskQueueTable(
              tasks: [
                tasks.first.copyWith(
                  status: TranscriptionStatus.error,
                  statusMessage:
                      'SocketException: connection interrupted; token=private',
                ),
              ],
              autoDeletedKeys: const {},
              onStart: (_) {},
              onRetry: (_) => retries++,
              onDelete: (_) {},
              onReorder: (_, _) {},
            ),
          ),
        ),
      );
      expect(find.byTooltip('重试'), findsOneWidget);
      expect(
        find
            .text(
              transcriptionFailureSummary(
                'SocketException: connection interrupted; token=private',
              ),
            )
            .hitTestable(),
        findsOneWidget,
      );
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.text('失败'));
      await tester.pumpAndSettle();
      expect(find.text('转录任务详情'), findsOneWidget);
      expect(find.text('诊断详情'), findsOneWidget);
      expect(find.byType(OperationStatus), findsNothing);
      await tester.tap(find.text('诊断详情'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('重试').last);
      await tester.pumpAndSettle();
      expect(retries, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'display direction remains available and unselected rows cannot reorder',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TaskQueueTable(
              tasks: [
                tasks.first,
                tasks.last,
                tasks.last.copyWith(
                  mediaKey: 'waiting',
                  status: TranscriptionStatus.idle,
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
      expect(find.byKey(const ValueKey('task-drag-waiting')), findsNothing);
      expect(
        find.byKey(ValueKey('task-drag-${tasks.first.mediaKey}')),
        findsNothing,
      );
      expect(find.text('进行中置顶 · 等待任务从上到下'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('task-queue-display-order')));
      await tester.pumpAndSettle();
      expect(find.text('进行中置顶 · 等待任务从下到上'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final scale in [1.6, 2.0]) {
    testWidgets(
      'desktop status remains readable without overflow at text scale $scale',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1440, 900);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: TaskQueueTable(
                tasks: [
                  tasks.first.copyWith(
                    audioProgress: const TranscriptionAudioProgress(
                      completed: Duration(hours: 1, minutes: 23),
                      total: Duration(hours: 12),
                    ),
                  ),
                  tasks.last,
                  tasks.last.copyWith(
                    mediaKey: 'failure',
                    status: TranscriptionStatus.error,
                    statusMessage: 'SocketException: connection timed out',
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
        expect(
          tester.widget<Text>(find.text('已完成')).style!.fontSize,
          greaterThanOrEqualTo(13),
        );
        expect(
          tester.widget<Text>(find.text('失败')).style!.fontSize,
          greaterThanOrEqualTo(13),
        );
        final time = find.text('已完成 01:23:00 / 12:00:00');
        expect(time, findsOneWidget);
        expect(
          tester.widget<Text>(time).style!.fontSize,
          greaterThanOrEqualTo(13),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final size in <Size>[
    const Size(320, 568),
    const Size(360, 800),
    const Size(800, 360),
    const Size(600, 960),
    const Size(768, 1024),
    const Size(1024, 768),
    const Size(1120, 650),
    const Size(1280, 720),
    const Size(1440, 900),
  ]) {
    testWidgets(
      'task queue is tabular without overflow at ${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(useMaterial3: true),
            home: Scaffold(
              body: TaskQueueTable(
                tasks: tasks,
                autoDeletedKeys: const {},
                onStart: (_) {},
                onRetry: (_) {},
                onRestart: (_) {},
                onDelete: (_) {},
                onReorder: (_, _) {},
                onTapCompleted: (_) {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('超长内部视频名称'), findsOneWidget);
        final completedText = tester.widget<Text>(find.text('外部视频.mkv'));
        final completedContext = tester.element(find.text('外部视频.mkv'));
        expect(completedText.style?.decoration, TextDecoration.underline);
        expect(
          completedText.style?.color,
          Theme.of(completedContext).colorScheme.onSurface,
        );
        if (size.width == 320) {
          expect(find.text('进行中置顶 · 等待任务从上到下'), findsNothing);
          expect(find.byTooltip('暂停'), findsOneWidget);
          expect(find.byIcon(Icons.drag_handle), findsNothing);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final size in <Size>[
    const Size(320, 568),
    const Size(360, 800),
    const Size(800, 360),
    const Size(600, 960),
    const Size(768, 1024),
    const Size(1024, 768),
    const Size(1120, 650),
    const Size(1280, 720),
    const Size(1440, 900),
  ]) {
    testWidgets(
      'batch screen toolbar has no overflow at ${size.width.toInt()}px',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);

        final manager = TranscriptionManager();
        addTearDown(manager.dispose);
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<TranscriptionManager>.value(
                value: manager,
              ),
              ChangeNotifierProvider<SettingsService>.value(
                value: SettingsService(),
              ),
              ChangeNotifierProvider<LibraryService>.value(
                value: LibraryService(),
              ),
            ],
            child: MaterialApp(
              theme: ThemeData(
                useMaterial3: true,
                brightness: Brightness.dark,
                fontFamily: 'Test App Font',
              ),
              home: const BatchSubtitleScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        if (find.byTooltip('展开配置详情').evaluate().isNotEmpty) {
          await tester.tap(find.byTooltip('展开配置详情'));
          await tester.pumpAndSettle();
        }
        expect(find.text('语音转录队列'), findsOneWidget);
        expect(find.byType(ModelCenterButton), findsOneWidget);
        final titleContext = tester.element(find.text('语音转录队列'));
        // 批量字幕页统一强制使用思源黑体，不随应用默认字体变化。
        expect(
          Theme.of(titleContext).textTheme.bodyMedium?.fontFamily,
          'Noto Sans SC',
        );
        expect(find.byType(Switch), findsNWidgets(2));
        expect(find.text('翻译设置'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('batch-current-mode')),
          findsOneWidget,
        );
        expect(
          find
              .byKey(const ValueKey('batch-translation-settings'))
              .hitTestable(),
          findsOneWidget,
        );
        expect(
          find.textContaining('智能互译：中→英 / 其他→中', findRichText: true),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('batch-transcription-settings')),
          findsOneWidget,
        );
        if (size.width == 320) {
          expect(find.text('添加媒体'), findsOneWidget);
          expect(find.text('开始全部'), findsOneWidget);
          expect(find.byTooltip('更多操作'), findsOneWidget);
        }
        if (size.shortestSide >= 600 && size.width < 1100) {
          // All responsive modes use the same action name. Tablet toolbars
          // retain a visible label, an enabled button and the full tooltip.
          final label = find.text('开始全部');
          expect(label.hitTestable(), findsOneWidget);
          final button = find.ancestor(
            of: label,
            matching: find.byWidgetPredicate(
              (widget) => widget is ElevatedButton,
            ),
          );
          expect(button, findsOneWidget);
          expect(tester.widget<ElevatedButton>(button).onPressed, isNotNull);
          expect(
            find.byWidgetPredicate(
              (widget) =>
                  widget is Tooltip &&
                  widget.message?.startsWith('开始全部') == true,
            ),
            findsOneWidget,
          );
        }
        if (size.width >= 1120) {
          expect(find.text('完成后移除'), findsOneWidget);
          expect(find.text('外部视频软字幕内嵌'), findsOneWidget);
          expect(find.text('字幕输出位置'), findsOneWidget);
          expect(find.text('清理队列'), findsOneWidget);
        }
        if (size.shortestSide < 600) {
          final more = find.byKey(const ValueKey('batch-toolbar-more'));
          final inset = (size.shortestSide * .026).clamp(8.0, 18.0);
          expect(tester.getRect(more).right, closeTo(size.width - inset, .1));
          await tester.tap(more);
          await tester.pumpAndSettle();
          final divider = find.byType(PopupMenuDivider);
          expect(divider, findsOneWidget);
          expect(tester.getSize(divider).height, 8);
          expect(find.text('完成后自动移除'), findsOneWidget);
          expect(find.text('清除已完成'), findsOneWidget);
          expect(find.text('清除全部'), findsOneWidget);
          expect(tester.takeException(), isNull);
          Navigator.of(tester.element(find.text('清除全部'))).pop();
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class _FailedQueueManager extends TranscriptionManager {
  _FailedQueueManager(this.task);
  final BatchSubtitleTaskView task;
  int startAllCalls = 0;

  @override
  List<BatchSubtitleTaskView> getQueueSnapshot() => [task];

  @override
  void startAllTasks({TranscriptTranslateChoice? translateIfUnfrozen}) {
    startAllCalls++;
  }
}
