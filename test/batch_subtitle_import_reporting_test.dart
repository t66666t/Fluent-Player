import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/subtitle_output_path_strategy.dart';
import 'package:video_player_app/models/batch_subtitle_task_view.dart';
import 'package:video_player_app/models/transcription_status.dart';
import 'package:video_player_app/screens/batch_subtitle_screen.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/widgets/operation_status.dart';

class _Picker extends FilePicker {
  final List<PlatformFile> files;
  _Picker(this.files);
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => FilePickerResult(files);
}

class _Manager extends TranscriptionManager {
  List<BatchSubtitleTaskView> rows = const [];
  final calls = <String>[];
  bool fail = true;
  @override
  List<BatchSubtitleTaskView> getQueueSnapshot() => rows;
  void changed() => notifyListeners();
  @override
  Future<TranscriptionEnqueueResult> startExternalTranscription(
    String path, {
    required SubtitleOutputPathStrategy outputPathStrategy,
    String? customOutputDir,
  }) async {
    calls.add(path);
    if (fail && path.endsWith('failed.mp4')) {
      throw const FileSystemException('access denied');
    }
    if (path.endsWith('existing.mp4')) {
      return TranscriptionEnqueueResult.alreadyQueued;
    }
    rows = [
      ...rows,
      BatchSubtitleTaskView(
        mediaKey: path,
        videoPath: path,
        videoName: path.split('/').last,
        videoDuration: '',
        isExternal: true,
        status: TranscriptionStatus.idle,
        progress: 0,
        createdAt: rows.length,
      ),
    ];
    notifyListeners();
    return TranscriptionEnqueueResult.added;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final scenario in ['partial', 'all', 'success']) {
    final allFailed = scenario == 'all';
    final success = scenario == 'success';
    testWidgets(
      '$scenario import uses the original status area without scrolling',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final settings = SettingsService()..resetForTest();
        await settings.init();
        final manager = _Manager();
        if (!allFailed) {
          manager.rows = [
            for (var i = 0; i < 60; i++)
              BatchSubtitleTaskView(
                mediaKey: 'queued-$i',
                videoPath: '/queued-$i.mp4',
                videoName: 'Queued $i',
                videoDuration: '10:00',
                isExternal: true,
                status: TranscriptionStatus.idle,
                progress: 0,
                createdAt: i,
              ),
          ];
        }
        addTearDown(manager.dispose);
        FilePicker? original;
        try {
          original = FilePicker.platform;
        } catch (_) {}
        FilePicker.platform = _Picker([
          if (!allFailed)
            PlatformFile(name: 'new.mp4', size: 1, path: '/new.mp4'),
          if (!allFailed)
            PlatformFile(name: 'existing.mp4', size: 1, path: '/existing.mp4'),
          if (!success)
            PlatformFile(name: 'failed.mp4', size: 1, path: '/failed.mp4'),
        ]);
        addTearDown(() {
          if (original != null) FilePicker.platform = original;
        });
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1280, 900);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<TranscriptionManager>.value(
                value: manager,
              ),
              ChangeNotifierProvider<SettingsService>.value(value: settings),
              ChangeNotifierProvider<LibraryService>.value(
                value: LibraryService(),
              ),
            ],
            child: const MaterialApp(home: BatchSubtitleScreen()),
          ),
        );
        if (!allFailed) {
          await tester.drag(
            find.byType(ReorderableListView),
            const Offset(0, -1600),
          );
          await tester.pumpAndSettle();
          expect(find.text('Queued 0').hitTestable(), findsNothing);
        }
        await tester.tap(find.text('选择外部文件'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('导入文件'));
        await tester.pumpAndSettle();
        expect(find.byType(OperationStatus), findsNothing);
        expect(find.byType(AlertDialog), findsNothing);
        final expected = allFailed
            ? '新增 0 项，已存在 0 项，添加失败 1 项'
            : '新增 1 项，已存在 1 项，添加失败 1 项';
        if (success) {
          expect(find.textContaining('添加失败'), findsNothing);
          expect(find.textContaining('新增 '), findsNothing);
          expect(manager.rows.any((row) => row.videoName == 'new.mp4'), isTrue);
        } else {
          expect(find.text(expected).hitTestable(), findsOneWidget);
          await tester.pump(const Duration(seconds: 10));
          expect(find.text(expected).hitTestable(), findsOneWidget);
          expect(find.text('诊断详情'), findsOneWidget);
          expect(find.text('重试').hitTestable(), findsOneWidget);
        }
        if (!allFailed) {
          final list = find.byType(ReorderableListView);
          final controller = tester
              .widget<ReorderableListView>(list)
              .scrollController!;
          final beforeProgress = controller.offset;
          expect(
            beforeProgress,
            greaterThan(0),
            reason: 'import must not pull the reader to the first task',
          );
          manager.changed();
          await tester.pumpAndSettle();
          expect(controller.offset, beforeProgress);
        }
        if (!success) {
          final beforeRetry = manager.calls.length;
          manager.fail = false;
          await tester.tap(find.text('重试'));
          await tester.pumpAndSettle();
          expect(manager.calls.skip(beforeRetry), ['/failed.mp4']);
          expect(find.textContaining('添加失败'), findsNothing);
          expect(find.byType(AlertDialog), findsNothing);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
