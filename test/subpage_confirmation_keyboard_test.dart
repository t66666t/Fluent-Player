import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/screens/storage_management_screen.dart';
import 'package:video_player_app/screens/subtitle_preview_screen.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/storage_audit_models.dart';
import 'package:video_player_app/services/storage_audit_service.dart';
import 'package:video_player_app/widgets/recycle_bin_deletion_dialog.dart';

final _snapshot = StorageSnapshot(
  scannedAt: DateTime(2026),
  roots: const [],
  warnings: const [],
  files: const [
    StorageFileEntry(
      path: '/data/movie.srt',
      rootPath: '/data',
      rootLabel: 'data',
      category: StorageCategory.subtitles,
      bytes: 100,
      modifiedMicros: 1,
      changedMicros: 1,
      ownerIds: [],
      ownerTitles: [],
      canDelete: true,
      explicitDelete: true,
      cleanupPolicy: StorageCleanupPolicy.savedContent,
    ),
  ],
);

class _StorageProbe extends StorageAuditService {
  _StorageProbe()
    : super(
        initialSnapshot: _snapshot,
        buildInput: () async => const StorageScanInput(roots: []),
        deletionBlockedReason: () => null,
      );

  int deletions = 0;

  @override
  Future<StorageDeletionResult> delete(
    StorageDeletionPlan plan, {
    void Function(StorageDeletionProgress)? onProgress,
  }) async {
    deletions++;
    return const StorageDeletionResult(
      deletedPaths: [],
      releasedBytes: 0,
      skipped: {},
      failed: {},
    );
  }
}

class _RecycleProbe extends ChangeNotifier implements LibraryService {
  int calls = 0;
  final pending = Completer<RecycleBinDeleteResult>();

  @override
  VideoItem? getVideo(String id) => null;

  @override
  VideoCollection? getCollection(String id) => null;

  @override
  bool get hasPersistenceFailure => false;

  @override
  Future<RecycleBinDeleteResult> deleteFromRecycleBin(
    List<String> ids, {
    void Function(int processed, int total)? onProgress,
  }) {
    calls++;
    return pending.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'storage details search, cancel deletion and return by keyboard',
    (tester) async {
      final service = _StorageProbe();
      await tester.pumpWidget(
        MaterialApp(home: StorageManagementScreen(service: service)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(StorageCategory.subtitles.title));
      await tester.pumpAndSettle();
      final input = find.byType(TextField);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pump();
      expect(tester.widget<TextField>(input).focusNode!.hasFocus, isTrue);
      await tester.enterText(input, 'movie');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(tester.widget<TextField>(input).focusNode!.hasFocus, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.slash);
      await tester.pump();
      expect(tester.widget<TextField>(input).focusNode!.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      await tester.tap(find.text('删除已保存字幕'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('删除 1 个文件？'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(service.deletions, 0);
      expect(find.byType(TextField), findsOneWidget);

      await tester.tap(find.text('删除已保存字幕'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(service.deletions, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('存储空间管理'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    },
  );

  testWidgets('subtitle preview returns to the previous page with Escape', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) => const SubtitlePreviewScreen(
                    subtitlePath: '/missing-test-subtitle.srt',
                  ),
                ),
              ),
              child: const Text('打开预览'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开预览'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('字幕预览'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('打开预览'), findsOneWidget);
    expect(find.text('字幕预览'), findsNothing);
  });

  testWidgets('recycle deletion cannot repeat or close while busy', (
    tester,
  ) async {
    final library = _RecycleProbe();
    addTearDown(library.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<RecycleBinDeleteResult>(
                context: context,
                barrierDismissible: false,
                builder: (_) => RecycleBinDeletionDialog(
                  library: library,
                  ids: const ['one'],
                ),
              ),
              child: const Text('打开回收站删除'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开回收站删除'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(library.calls, 1);
    expect(find.text('正在处理'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(library.calls, 1);
    expect(find.byType(RecycleBinDeletionDialog), findsOneWidget);
    library.pending.complete(
      const RecycleBinDeleteResult(
        deletedIds: [],
        failedIds: {'one': '失败'},
        saved: true,
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    expect(library.calls, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(RecycleBinDeletionDialog), findsNothing);
  });
}
