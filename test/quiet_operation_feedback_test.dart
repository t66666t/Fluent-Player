import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/screens/storage_management_screen.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/storage_audit_models.dart';
import 'package:video_player_app/services/storage_audit_service.dart';
import 'package:video_player_app/widgets/video_action_buttons.dart';

class _MixedCleanup extends StorageAuditService {
  _MixedCleanup()
    : super(
        buildInput: () async => throw StateError('unexpected scan'),
        deletionBlockedReason: () => null,
        initialSnapshot: StorageSnapshot(
          scannedAt: DateTime(2026),
          roots: const [],
          warnings: const [],
          files: [
            for (var i = 1; i <= 2; i++)
              StorageFileEntry(
                path: '/cache/$i.mp4',
                rootPath: '/cache',
                rootLabel: 'cache',
                category: StorageCategory.picker,
                bytes: i * 1000,
                modifiedMicros: 1,
                changedMicros: 1,
                ownerIds: const [],
                ownerTitles: const [],
                canDelete: true,
                cleanupPolicy: StorageCleanupPolicy.regenerableCache,
              ),
          ],
        ),
      );

  final requests = <List<String>>[];
  @override
  Future<StorageDeletionResult> delete(
    StorageDeletionPlan plan, {
    void Function(StorageDeletionProgress progress)? onProgress,
  }) async {
    final paths = plan.files.map((file) => file.path).toList();
    requests.add(paths);
    final deleted = requests.length == 1 ? ['/cache/1.mp4'] : paths;
    lastSnapshot = storageSnapshotWithoutFiles(lastSnapshot!, deleted);
    return StorageDeletionResult(
      deletedPaths: deleted,
      releasedBytes: 1000,
      skipped: const {},
      failed: requests.length == 1 ? {'/cache/2.mp4': 'file in use'} : const {},
    );
  }
}

void main() {
  testWidgets(
    'cache partial failure stays on page and retries only remaining files',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      final service = _MixedCleanup();
      await tester.pumpWidget(
        MaterialApp(home: StorageManagementScreen(service: service)),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('清理 3.00 KB'));
      await tester.tap(find.text('清理 3.00 KB'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('1 个文件未清理，可稍后重试。'), findsOneWidget);
      expect(service.lastSnapshot!.files.single.path, '/cache/2.mp4');
      await tester.ensureVisible(find.text('重试'));
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(service.requests, [
        ['/cache/1.mp4', '/cache/2.mp4'],
        ['/cache/2.mp4'],
      ]);
      expect(service.lastSnapshot!.files, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('部分文件未清理'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'invalid import stays at the existing import control without an alert',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService()..resetForTest();
      await settings.init();
      settings.isActionButtonsCollapsed = false;
      late BuildContext host;
      await tester.pumpWidget(
        MultiProvider(
          providers: [ChangeNotifierProvider.value(value: settings)],
          child: MaterialApp(
            home: Builder(
              builder: (context) {
                host = context;
                return const Scaffold(
                  body: Align(
                    alignment: Alignment.bottomRight,
                    child: VideoActionButtons(
                      collectionId: 'quiet-import',
                      maxExpandedHeight: 500,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await VideoActionButtons.processImportedFiles(host, [
        '/notes.txt',
      ], 'quiet-import');
      await tester.pumpAndSettle();
      expect(find.text('导入失败'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      await tester.tap(find.byIcon(Icons.error_outline));
      await tester.pumpAndSettle();
      expect(find.text('未找到可用的媒体文件'), findsOneWidget);
      expect(find.widgetWithIcon(ListTile, Icons.folder_open), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      settings.resetForTest();
    },
  );
}
