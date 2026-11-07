import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_compose_models.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_materialization_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/video_compose_manager.dart';
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/widgets/video_compose_panel.dart';

import 'support/compose_queue_fakes.dart';

class _Manager extends ChangeNotifier implements VideoComposeManager {
  _Manager(this.task);
  final VideoComposeTaskState task;
  @override
  List<VideoComposeTaskState> get allTasks => [task];
  @override
  VideoComposeTaskState? latestTaskForVideo(String id) => task;
  @override
  VideoComposeTaskState? get runningTask => null;
  @override
  MediaMaterializationProgress? materializationProgressForTask(String id) =>
      null;
  @override
  Future<String?> getSourceResolutionLabel(String path) async => '1920×1080';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'mobile result saves the completed video through its system channel',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('compose_save_panel_');
      final video = File(p.join(root.path, '成片.mp4'))
        ..writeAsStringSync('video');
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService()..resetForTest();
      await settings.init();
      final manager = _Manager(composeRecord('video', outputPath: video.path));
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      const channel = MethodChannel(
        'com.example.video_player_app/compose_video_save',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final pending = Completer<bool>();
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) {
        calls.add(call);
        return pending.future;
      });
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = null;
        await AppToast.dismiss(immediate: true);
        await tester.pumpWidget(const SizedBox.shrink());
        tester.view.reset();
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
            navigatorKey: AppToast.navigatorKey,
            home: Scaffold(
              body: VideoComposePanel(
                videoItem: VideoItem(
                  id: 'video',
                  path: 'input.mp4',
                  title: 'video',
                  durationMs: 1000,
                  lastUpdated: 0,
                ),
                currentSelectedPaths: const [],
                availableSubtitleMap: const {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final button = find.byTooltip('保存到设备');
      await tester.ensureVisible(button);
      await tester.pump();
      await tester.runAsync(() => tester.tap(button));
      for (var i = 0; i < 100 && calls.isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(calls.single.method, 'save');
      expect(calls.single.arguments, {'path': video.path});
      expect(find.byTooltip('正在保存'), findsOneWidget);
      pending.complete(true);
      await tester.pump();
      await tester.pump();
      expect(video.readAsStringSync(), 'video');
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
