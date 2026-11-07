import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/batch_subtitle_task_view.dart';
import 'package:video_player_app/models/transcription_status.dart';
import 'package:video_player_app/screens/batch_subtitle_screen.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/widgets/media_library_selection_bottom_bar.dart';

class _Queue extends TranscriptionManager {
  final tasks = [
    const BatchSubtitleTaskView(
      mediaKey: 'task-one',
      videoPath: 'local.mp4',
      videoName: '测试转录',
      videoDuration: '12:30',
      isExternal: true,
      status: TranscriptionStatus.idle,
      progress: 0,
      createdAt: 1,
    ),
  ];
  final removed = <String>[];

  @override
  List<BatchSubtitleTaskView> getQueueSnapshot() => List.of(tasks);

  @override
  bool removeFromQueue(String mediaKey) {
    removed.add(mediaKey);
    tasks.removeWhere((task) => task.mediaKey == mediaKey);
    notifyListeners();
    return true;
  }
}

void main() {
  for (final key in [LogicalKeyboardKey.enter, LogicalKeyboardKey.keyR]) {
    testWidgets('selected task removal honors Esc and $key', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 900);
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService()..resetForTest();
      await settings.init();
      final playback = MediaPlaybackService();
      await playback.stop();
      final queue = _Queue();
      addTearDown(() async {
        await playback.stop();
        queue.dispose();
        settings.resetForTest();
      });
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<TranscriptionManager>.value(value: queue),
            ChangeNotifierProvider.value(value: settings),
            ChangeNotifierProvider.value(value: LibraryService()),
            ChangeNotifierProvider.value(value: playback),
          ],
          child: const MaterialApp(home: BatchSubtitleScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.longPress(find.text('测试转录'));
      await tester.pumpAndSettle();
      final remove = find.descendant(
        of: find.byType(MediaLibrarySelectionBottomBar),
        matching: find.widgetWithText(TextButton, '移除'),
      );
      await tester.tap(remove);
      await tester.pumpAndSettle();
      expect(find.text('移除 1 个任务？'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(queue.removed, isEmpty);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
      expect(queue.removed, ['task-one']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
