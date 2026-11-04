import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/video_compose_manager.dart';
import 'package:video_player_app/widgets/video_compose_queue_dialog.dart';

import 'support/compose_queue_fakes.dart';

void main() {
  final settings = SettingsService();
  late VideoComposeManager manager;
  late RecordingComposeCleaner cleaner;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings.resetForTest();
    await settings.init();
    cleaner = RecordingComposeCleaner();
    manager = VideoComposeManager(
      taskStore: MemoryComposeStore([
        for (var i = 1; i <= 3; i++) composeRecord('$i'),
      ]),
      artifactCleaner: cleaner,
    );
    await manager.ready;
  });

  tearDown(() {
    manager.dispose();
    settings.resetForTest();
  });

  Future<void> showQueue(
    WidgetTester tester, {
    Future<bool> Function()? permission,
  }) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          ChangeNotifierProvider<VideoComposeManager>.value(value: manager),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                child: const Text('打开队列'),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => VideoComposeQueueDialog(
                    onPreview: (_) async {},
                    onOpenOutput: (_) async {},
                    openOutputLabel: '打开文件夹',
                    requestDeleteOutputPermission: permission == null
                        ? null
                        : (_) => permission(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开队列'));
    await tester.pumpAndSettle();
  }

  Future<void> finishDeletion(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }
    await tester.pumpAndSettle();
  }

  for (final key in [
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
  ]) {
    testWidgets('${key.keyLabel} confirms the default delete choice once', (
      tester,
    ) async {
      await showQueue(tester);
      await tester.tap(find.byKey(const ValueKey('compose-delete-1')));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(key);
      await finishDeletion(tester);
      expect(manager.allTasks.map((t) => t.taskId), ['2', '3']);
      expect(cleaner.deletions, [
        (id: '1', output: settings.videoComposeDeleteOutputOnTaskDelete),
      ]);
      expect(find.text('确认删除'), findsNothing);
    });
  }

  testWidgets('Escape cancels and preserves records and files', (tester) async {
    await showQueue(tester);
    await tester.tap(find.byKey(const ValueKey('compose-delete-1')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(manager.allTasks, hasLength(3));
    expect(cleaner.deletions, isEmpty);
  });

  testWidgets(
    'batch delete targets only selected records and remembers keep-files',
    (tester) async {
      await showQueue(tester);
      await tester.tap(find.text('批量选择'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('compose-select-1')));
      await tester.tap(find.byKey(const ValueKey('compose-select-2')));
      await tester.pump();
      await tester.tap(find.text('删除已选（2）'));
      await tester.pumpAndSettle();
      if (tester
              .widget<CheckboxListTile>(find.byType(CheckboxListTile))
              .value ==
          true) {
        await tester.tap(find.byType(CheckboxListTile));
        await tester.pump();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await finishDeletion(tester);
      expect(manager.allTasks.single.taskId, '3');
      expect(cleaner.deletions, [
        (id: '1', output: false),
        (id: '2', output: false),
      ]);
      expect(settings.videoComposeDeleteOutputOnTaskDelete, isFalse);
    },
  );

  testWidgets('clear all confirms the count and removes all records', (
    tester,
  ) async {
    await showQueue(tester);
    await tester.tap(find.text('清空队列'));
    await tester.pumpAndSettle();
    expect(find.text('确定要清空这 3 条合成记录吗？'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
    await finishDeletion(tester);
    expect(manager.allTasks, isEmpty);
    expect(find.text('当前没有合成任务'), findsOneWidget);
  });

  testWidgets('file permission refusal leaves the entire batch intact', (
    tester,
  ) async {
    await settings.updateSetting('videoComposeDeleteOutputOnTaskDelete', true);
    await showQueue(tester, permission: () async => false);
    await tester.tap(find.text('清空队列'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await finishDeletion(tester);
    expect(cleaner.deletions, isEmpty);
    expect(manager.allTasks, hasLength(3));
  });

  testWidgets('failed file deletion keeps its record visible for retry', (
    tester,
  ) async {
    cleaner.failedIds.add('2');
    await showQueue(tester);
    await tester.tap(find.text('清空队列'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await finishDeletion(tester);
    expect(manager.allTasks.single.taskId, '2');
    expect(find.text('视频 2'), findsOneWidget);
  });

  testWidgets('queue and confirmation fit a narrow window with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 520);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.7;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await showQueue(tester);
    await tester.tap(find.text('清空队列'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await finishDeletion(tester);
    expect(manager.allTasks, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
