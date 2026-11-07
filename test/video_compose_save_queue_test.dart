import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/video_compose_manager.dart';
import 'package:video_player_app/widgets/video_compose_queue_dialog.dart';

import 'support/compose_queue_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'queue saves the selected output once and disables deletion while saving',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('compose_save_queue_');
      final video = File(p.join(root.path, '完成的视频.mp4'))
        ..writeAsStringSync('completed');
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService()..resetForTest();
      await settings.init();
      final manager = VideoComposeManager(
        taskStore: MemoryComposeStore([
          composeRecord('1', outputPath: video.path),
        ]),
        artifactCleaner: RecordingComposeCleaner(),
      );
      await manager.ready;
      final saving = Completer<void>();
      final paths = <String>[];
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        manager.dispose();
        settings.resetForTest();
        root.deleteSync(recursive: true);
      });
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsService>.value(value: settings),
            ChangeNotifierProvider<VideoComposeManager>.value(value: manager),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: VideoComposeQueueDialog(
                onPreview: (_) async {},
                onOpenOutput: (_) async {},
                openOutputLabel: '打开',
                onSaveOutput: (path) {
                  paths.add(path);
                  return saving.future;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存到设备'));
      await tester.pump();
      expect(paths, [video.path]);
      expect(find.text('正在保存…'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('compose-delete-1')))
            .onPressed,
        isNull,
      );
      expect(video.readAsStringSync(), 'completed');
      saving.complete();
      await tester.pump();
      expect(find.text('保存到设备'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('compose-delete-1')))
            .onPressed,
        isNotNull,
      );
    },
  );
}
