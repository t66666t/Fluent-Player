import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/batch_subtitle_task_view.dart';
import 'package:video_player_app/models/transcription_status.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/screens/batch_subtitle_screen.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/widgets/media_library_selection_bottom_bar.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';
import 'package:video_player_app/widgets/mini_playback_card.dart';
import 'package:video_player_app/widgets/task_queue_table.dart';
import 'package:video_player_app/widgets/transcript_translate_settings_sheet.dart';

BatchSubtitleTaskView _task(int i) => BatchSubtitleTaskView(
  mediaKey: 'task-$i',
  videoPath: 'local-$i.mp4',
  videoName: '本地课程 ${i + 1} · 听力练习',
  videoDuration: '12:30',
  isExternal: true,
  status: TranscriptionStatus.idle,
  progress: 0,
  createdAt: i,
);

class _Queue extends TranscriptionManager {
  _Queue(this.tasks);

  final List<BatchSubtitleTaskView> tasks;
  final List<String> started = [], paused = [], retried = [], removed = [];
  final Map<String, bool> expiring = {};

  @override
  Map<String, bool> get pendingCompletedRemovals => expiring;

  void expire(String key) {
    expiring[key] = true;
    notifyListeners();
  }

  @override
  List<BatchSubtitleTaskView> getQueueSnapshot() => List.of(tasks);

  @override
  void startTask(
    String mediaKey, {
    TranscriptTranslateChoice? translateIfUnfrozen,
  }) {
    started.add(mediaKey);
  }

  @override
  bool pauseTask(String mediaKey) {
    paused.add(mediaKey);
    return true;
  }

  @override
  bool retryTask(String mediaKey, {TranscriptTranslateChoice? translate}) {
    retried.add(mediaKey);
    return true;
  }

  @override
  bool removeFromQueue(String mediaKey) {
    removed.add(mediaKey);
    tasks.removeWhere((task) => task.mediaKey == mediaKey);
    notifyListeners();
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SettingsService settings;
  late MediaPlaybackService playback;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService()..resetForTest();
    await settings.init();
    playback = MediaPlaybackService();
    await playback.stop();
  });

  tearDown(() async {
    await playback.stop();
    settings.resetForTest();
  });

  Future<void> pumpQueue(
    WidgetTester tester,
    _Queue manager, {
    bool inShell = false,
    GlobalKey? screenshotKey,
    double scale = 1,
  }) async {
    addTearDown(manager.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<TranscriptionManager>.value(value: manager),
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider.value(value: LibraryService()),
          ChangeNotifierProvider.value(value: playback),
        ],
        child: RepaintBoundary(
          key: screenshotKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              brightness: Brightness.dark,
              useMaterial3: true,
              fontFamily: 'Noto Sans SC',
              scaffoldBackgroundColor: const Color(0xFF121212),
              colorScheme: const ColorScheme.dark(
                primary: Colors.blue,
                surface: Color(0xFF121212),
              ),
              appBarTheme: const AppBarTheme(
                backgroundColor: Color(0xFF1E1E1E),
                elevation: 0,
              ),
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: inShell
                ? const MediaLibraryShell(home: BatchSubtitleScreen())
                : const BatchSubtitleScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder action(String label) => find.descendant(
    of: find.byType(MediaLibrarySelectionBottomBar),
    matching: find.widgetWithText(TextButton, label),
  );

  for (final width in [320.0, 768.0, 1280.0]) {
    testWidgets('selection controls only selected tasks at width $width', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final manager = _Queue([
        _task(0),
        _task(
          1,
        ).copyWith(status: TranscriptionStatus.transcribing, isStarted: true),
        _task(2).copyWith(status: TranscriptionStatus.error),
        _task(3).copyWith(status: TranscriptionStatus.completed),
        _task(4),
      ]);
      await pumpQueue(tester, manager);
      expect(tester.widget<AppBar>(find.byType(AppBar)).centerTitle, isFalse);
      expect(find.byKey(const ValueKey('task-drag-task-0')), findsNothing);
      final titlePosition = tester.getTopLeft(find.text(_task(0).videoName));
      await tester.longPress(find.text(_task(0).videoName));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 项'), findsOneWidget);
      expect(tester.getTopLeft(find.text(_task(0).videoName)), titlePosition);
      expect(find.byKey(const ValueKey('task-drag-task-0')), findsOneWidget);
      expect(manager.started, isEmpty);

      for (final i in [1, 2, 3]) {
        // Row contents ignore their individual actions in selection mode.
        await tester.tap(find.byKey(ValueKey('task-$i')));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.text('已选 4 项'), findsOneWidget);
      expect(find.byKey(const ValueKey('task-drag-task-1')), findsNothing);
      expect(find.byKey(const ValueKey('task-drag-task-2')), findsNothing);
      await tester.tap(action('开始'));
      await tester.pumpAndSettle();
      await tester.tap(action('暂停'));
      await tester.pumpAndSettle();
      await tester.tap(action('重试'));
      await tester.pumpAndSettle();
      expect(manager.started, ['task-0']);
      expect(manager.paused, ['task-1']);
      expect(manager.retried, ['task-2']);

      await tester.tap(action('移除'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '取消').last);
      await tester.pumpAndSettle();
      expect(manager.removed, isEmpty);
      await tester.tap(action('移除'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '移除').last);
      await tester.pumpAndSettle();
      expect(manager.removed.toSet(), {'task-0', 'task-1', 'task-2', 'task-3'});
      expect(manager.tasks.single.mediaKey, 'task-4');
      expect(find.byType(MediaLibrarySelectionBottomBar), findsNothing);

      await tester.longPress(find.text(_task(4).videoName));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('task-queue-select-all')));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 项'), findsOneWidget);
      await Navigator.of(
        tester.element(find.byType(TaskQueueTable)),
      ).maybePop();
      await tester.pumpAndSettle();
      expect(find.byType(BatchSubtitleScreen), findsOneWidget);
      expect(find.byType(MediaLibrarySelectionBottomBar), findsNothing);
      await tester.longPress(find.text(_task(4).videoName));
      await tester.pumpAndSettle();
      manager.expire('task-4');
      await tester.pumpAndSettle();
      expect(find.byType(MediaLibrarySelectionBottomBar), findsNothing);
      expect(find.byKey(const ValueKey('task-drag-task-4')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final width in [360.0, 1280.0]) {
    for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
      testWidgets(
        '$kind $width range scroll respects the player and selection bar',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 900);
          tester.view.viewPadding = const FakeViewPadding(bottom: 24);
          tester.view.padding = const FakeViewPadding(bottom: 24);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetViewPadding);
          addTearDown(tester.view.resetPadding);
          playback.publishRestoredSessionPreview(
            VideoItem(
              id: 'playing',
              path: 'local.mp4',
              title: '听力',
              durationMs: 750000,
              lastUpdated: 0,
            ),
            Duration.zero,
          );
          final manager = _Queue(List.generate(100, _task));
          await pumpQueue(tester, manager, inShell: true);
          final tableState = tester.state(find.byType(TaskQueueTable));
          final generation = playback.sessionGeneration;
          final gesture = await tester.startGesture(
            tester.getCenter(find.byKey(const ValueKey('task-select-task-0'))),
            kind: kind,
          );
          await tester.pumpAndSettle();
          final player = find.byType(MiniPlaybackCard);
          final list = tester.widget<ReorderableListView>(
            find.byType(ReorderableListView),
          );
          final bounds = tester.getRect(find.byType(ReorderableListView));
          expect(
            bounds.bottom,
            lessThanOrEqualTo(tester.getRect(player).top + .01),
          );
          await gesture.moveTo(Offset(20, tester.getRect(player).center.dy));
          await tester.pump();
          expect(
            tester
                .widget<TaskQueueTable>(find.byType(TaskQueueTable))
                .selectedKeys
                .length,
            lessThan(20),
          );
          for (var i = 0; i < 65; i++) {
            await tester.pump(const Duration(milliseconds: 16));
          }
          final selected = tester
              .widget<TaskQueueTable>(find.byType(TaskQueueTable))
              .selectedKeys;
          expect(selected.length, greaterThan(20));
          expect(selected.length, lessThan(60));
          expect(
            find.byKey(const ValueKey('task-select-task-0')),
            findsNothing,
          );
          await gesture.up();
          await tester.pumpAndSettle();
          final stopped = list.scrollController!.offset;
          await tester.pump(const Duration(milliseconds: 200));
          expect(list.scrollController!.offset, stopped);
          expect(tester.state(find.byType(TaskQueueTable)), same(tableState));
          expect(playback.sessionGeneration, generation);
          expect(manager.started, isEmpty);
          expect(manager.removed, isEmpty);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets('queue menus and settings sheets cover the mini player', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    playback.publishRestoredSessionPreview(
      VideoItem(
        id: 'playing',
        path: 'local.mp4',
        title: '听力',
        durationMs: 750000,
        lastUpdated: 0,
      ),
      Duration.zero,
    );
    await pumpQueue(tester, _Queue([_task(0)]), inShell: true);
    final root = Navigator.of(
      tester.element(find.byType(BatchSubtitleScreen)),
      rootNavigator: true,
    );
    await tester.tap(find.byKey(const ValueKey('batch-translation-settings')));
    await tester.pumpAndSettle();
    final sheetContext = tester.element(
      find.byType(TranscriptTranslateSettingsSheet),
    );
    expect(Navigator.of(sheetContext), same(root));
    expect(find.byType(MiniPlaybackCard).hitTestable(), findsNothing);
    root.pop();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('batch-toolbar-more')));
    await tester.pumpAndSettle();
    final option = find.text('外部视频设置');
    expect(Navigator.of(tester.element(option)), same(root));
    await tester.tap(option);
    await tester.pumpAndSettle();
    expect(Navigator.of(tester.element(find.text('外部视频设置'))), same(root));
    expect(find.byType(MiniPlaybackCard).hitTestable(), findsNothing);
    root.pop();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final size in [
    const Size(360, 900),
    const Size(800, 360),
    const Size(1280, 900),
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'last row clears player and animated selection bar at $size / $scale',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          tester.view.viewPadding = const FakeViewPadding(bottom: 24);
          tester.view.padding = const FakeViewPadding(bottom: 24);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetViewPadding);
          addTearDown(tester.view.resetPadding);
          playback.publishRestoredSessionPreview(
            VideoItem(
              id: 'playing',
              path: 'listening.mp4',
              title: '听力练习',
              durationMs: 750000,
              lastUpdated: 0,
            ),
            const Duration(minutes: 3, seconds: 42),
          );
          final manager = _Queue(List.generate(30, _task));
          final screenshotKey = GlobalKey();
          final output = Platform.environment['QUEUE_SCREENSHOT_DIR'];
          if (output != null) {
            await tester.runAsync(() async {
              final font = FontLoader('Noto Sans SC')
                ..addFont(
                  rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'),
                );
              await font.load();
              final icons = FontLoader('MaterialIcons')
                ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
              await icons.load();
            });
          }
          await pumpQueue(
            tester,
            manager,
            inShell: true,
            screenshotKey: screenshotKey,
            scale: scale,
          );
          final list = tester.widget<ReorderableListView>(
            find.byType(ReorderableListView),
          );
          Future<void> bottom() async {
            for (var i = 0; i < 3; i++) {
              list.scrollController!.jumpTo(
                list.scrollController!.position.maxScrollExtent,
              );
              await tester.pumpAndSettle();
            }
          }

          await bottom();
          final last = find.byKey(const ValueKey('task-29'));
          final player = find.byType(MiniPlaybackCard);
          final playerState = tester.state(player);
          final restingBottom = tester.getRect(player).bottom;
          expect(
            tester.getRect(last).bottom,
            lessThanOrEqualTo(tester.getRect(player).top + .001),
          );
          await tester.longPress(find.text(_task(29).videoName));
          await tester.pumpAndSettle();
          await bottom();
          expect(
            tester.getRect(last).bottom,
            lessThanOrEqualTo(tester.getRect(player).top + .001),
          );
          final bar = find.byType(MediaLibrarySelectionBottomBar);
          expect(
            tester.getRect(player).bottom,
            lessThanOrEqualTo(tester.getRect(bar).top),
          );
          expect(tester.getRect(player).bottom, lessThan(restingBottom));
          expect(action('移除').hitTestable(), findsOneWidget);

          // The screenshot renders the production widgets with local example tasks.
          if (output != null && scale == 1 && size.height >= 900) {
            list.scrollController!.jumpTo(0);
            await tester.pumpAndSettle();
            await tester.longPress(find.byKey(const ValueKey('task-0')));
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(const ValueKey('task-1')));
            await tester.pumpAndSettle();
            await tester.runAsync(() async {
              final boundary =
                  screenshotKey.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final frame = await boundary.toImage(pixelRatio: 1.5);
              final png = (await frame.toByteData(
                format: ui.ImageByteFormat.png,
              ))!;
              await Directory(output).create(recursive: true);
              await File(
                '$output/queue-${size.width.toInt()}.png',
              ).writeAsBytes(png.buffer.asUint8List());
              frame.dispose();
            });
          }
          final raisedBottom = tester.getRect(player).bottom;
          if (size.height < 600) {
            await Navigator.of(
              tester.element(find.byType(TaskQueueTable)),
            ).maybePop();
          } else {
            await tester.tap(
              find.byKey(const ValueKey('task-queue-cancel-selection')),
            );
          }
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 80));
          expect(
            tester.getRect(player).bottom,
            inExclusiveRange(raisedBottom, restingBottom),
          );
          await tester.pumpAndSettle();
          expect(tester.getRect(player).bottom, restingBottom);
          expect(tester.state(player), same(playerState));
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}
