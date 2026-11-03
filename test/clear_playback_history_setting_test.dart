import 'package:video_player_app/widgets/operation_status.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/library_activity.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/widgets/clear_playback_history_setting.dart';

void main() {
  // The singleton persistence queue must live outside a widget fake clock.
  final library = LibraryService();
  testWidgets(
    'clearing history retains settings, media, pins and hidden marks',
    (tester) async {
      library.resetLibraryForTesting();
      library.writeLibrarySnapshotOverrideForTesting = () async {};
      library.seedVideoForTesting(
        VideoItem(
          id: 'keep',
          path: '/external/video.mp4',
          title: 'keep',
          durationMs: 1000,
          lastUpdated: 1,
        ),
      );
      library.seedMediaActivityForTesting(
        MediaActivityRecord(
          mediaId: 'keep',
          addedAtMs: 11,
          lastPlayedAtMs: 99,
          accumulatedWatchMs: 5000,
          continueEnrolled: true,
          completed: true,
          hidden: true,
        ),
      );
      library.seedPinnedIdsForTesting(['keep']);
      addTearDown(library.resetLibraryForTesting);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(title: const Text('设置页面')),
            body: SingleChildScrollView(
              child: ClearPlaybackHistorySetting(library: library),
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => tester.tap(find.byKey(const ValueKey('clearPlaybackHistory'))),
      );
      await tester.pumpAndSettle();
      expect(find.text('观看记录和完成状态将被清除，媒体文件保留。'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(library.mediaActivity('keep')!.lastPlayedAtMs, 99);
      await tester.runAsync(
        () => tester.tap(find.byKey(const ValueKey('clearPlaybackHistory'))),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => tester.tap(find.widgetWithText(FilledButton, '清除')),
      );
      await tester.pumpAndSettle();
      expect(find.text('设置页面'), findsOneWidget);
      expect(find.byType(OperationStatus), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      final record = library.mediaActivity('keep')!;
      expect(record.lastPlayedAtMs, isNull);
      expect(record.addedAtMs, 11);
      expect(record.hidden, isTrue);
      expect(record.completed, isFalse);
      expect(record.continueEnrolled, isFalse);
      expect(library.getVideo('keep')!.path, '/external/video.mp4');
      expect(library.pinnedItemIds, ['keep']);
      expect(find.byType(SnackBar), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('unsaved clear stays visible and offers a persistence retry', (
    tester,
  ) async {
    library.resetLibraryForTesting();
    library.saveRetryDelaysForTesting = [];
    library.writeLibrarySnapshotOverrideForTesting = () async =>
        throw const FileSystemException('injected failure');
    library.seedMediaActivityForTesting(
      MediaActivityRecord(mediaId: 'keep', lastPlayedAtMs: 99),
    );
    addTearDown(library.resetLibraryForTesting);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ClearPlaybackHistorySetting(library: library),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => tester.tap(find.byKey(const ValueKey('clearPlaybackHistory'))),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => tester.tap(find.widgetWithText(FilledButton, '清除')),
    );
    await tester.pumpAndSettle();
    expect(find.text('记录已清除，保存尚未完成'), findsOneWidget);
    expect(find.text('播放记录已清除'), findsNothing);
    library.writeLibrarySnapshotOverrideForTesting = () async {};
    await tester.runAsync(() => tester.tap(find.text('重试保存')));
    await tester.pumpAndSettle();
    expect(find.byType(OperationStatus), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(library.hasPersistenceFailure, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
