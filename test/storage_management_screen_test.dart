import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/screens/storage_management_screen.dart';
import 'package:video_player_app/services/storage_audit_models.dart';
import 'package:video_player_app/services/storage_audit_service.dart';

void main() {
  StorageSnapshot snapshot() => StorageSnapshot(
    scannedAt: DateTime(2026, 10, 10),
    roots: const [],
    warnings: const [],
    files: [
      for (final category in StorageCategory.values)
        StorageFileEntry(
          path: '/test/${category.name}/video.mp4',
          rootPath: '/test',
          rootLabel: 'data',
          category: category,
          bytes: (category.index + 1) * 1000,
          modifiedMicros: 1,
          changedMicros: 1,
          ownerIds: const [],
          ownerTitles: const [],
          canDelete: category == StorageCategory.picker,
        ),
    ],
  );
  testWidgets('reopening displays a retained snapshot without scanning', (
    tester,
  ) async {
    var scans = 0;
    final retained = snapshot();
    for (var i = 0; i < 2; i++) {
      final service = StorageAuditService(
        initialSnapshot: retained,
        buildInput: () async {
          scans++;
          return const StorageScanInput(roots: []);
        },
        deletionBlockedReason: () => null,
      );
      await tester.pumpWidget(
        MaterialApp(home: StorageManagementScreen(service: service)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('storageTotal')), findsOneWidget);
      expect(scans, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
  for (final size in [
    const Size(360, 800),
    const Size(900, 650),
    const Size(1280, 800),
  ]) {
    testWidgets('storage overview and details fit ${size.width}px viewport', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = StorageAuditService(
        buildInput: () async => const StorageScanInput(roots: []),
        deletionBlockedReason: () => null,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: StorageManagementScreen(
            service: service,
            initialSnapshot: snapshot(),
          ),
        ),
      );
      expect(find.text('存储空间管理'), findsOneWidget);
      expect(find.byKey(const ValueKey('storageTotal')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text(StorageCategory.other.title),
        200,
      );
      await tester.ensureVisible(find.text(StorageCategory.other.title));
      await tester.pumpAndSettle();
      await tester.tap(find.text(StorageCategory.other.title));
      await tester.pumpAndSettle();
      expect(find.text('搜索文件路径或关联卡片'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byType(TextField), 'no_matching_media');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(find.textContaining('/test/other'), findsNothing);
      await tester.enterText(find.byType(TextField), 'video.mp4');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(find.textContaining('/test/other'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('source filter and large text stay on screen', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = StorageAuditService(
      buildInput: () async => const StorageScanInput(roots: []),
      deletionBlockedReason: () => null,
      resourcesChanged: () => true,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
          child: StorageManagementScreen(
            service: service,
            initialSnapshot: snapshot(),
          ),
        ),
      ),
    );
    expect(find.text('播客'), findsOneWidget);
    expect(find.text('网盘'), findsOneWidget);
    expect(find.text('存储记录已变化'), findsOneWidget);
    await tester.tap(find.text('播客'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('存储空间管理'), findsOneWidget);
  });

  for (final details in [false, true]) {
    testWidgets(
      '${details ? 'detail' : 'overview'} cleanup displays progress and updates totals',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(360, 800);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final service = _CleanupService();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: StorageManagementScreen(service: service),
          ),
        );
        await tester.pumpAndSettle();
        if (details) {
          await tester.tap(find.text(StorageCategory.picker.title));
          await tester.pumpAndSettle();
          await tester.tap(find.text('清理当前列表可删除文件'));
        } else {
          await tester.ensureVisible(find.text('清理 3.00 KB'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('清理 3.00 KB'));
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('删除 2 个文件？'), findsOneWidget);
        await tester.tap(find.text('删除这些文件'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        if (!details) {
          await tester.drag(find.byType(ListView).first, const Offset(0, 1000));
          await tester.pumpAndSettle();
        }
        expect(find.text('正在清理文件…'), findsOneWidget);
        expect(find.text('已处理 1 / 2 个文件 · 已释放 1.00 KB'), findsOneWidget);
        expect(find.text('正在核对并清理文件…'), findsNothing);
        expect(
          find.byWidgetPredicate(
            (widget) => widget is LinearProgressIndicator && widget.value == .5,
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        service.complete.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('清理结果'), findsNothing);
        expect(find.byType(AlertDialog), findsNothing);
        await tester.pumpAndSettle();
        expect(find.text('正在清理文件…'), findsNothing);
        expect(service.lastSnapshot!.appBytes, 0);
        if (details) {
          expect(find.text('0 B · 0 个文件，按大小排列'), findsOneWidget);
        } else {
          expect(find.text('0 B'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );
  }
}

class _CleanupService extends StorageAuditService {
  _CleanupService()
    : super(
        buildInput: () async => throw StateError('unexpected full scan'),
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
              ),
          ],
        ),
      );

  final complete = Completer<void>();

  @override
  Future<StorageDeletionResult> delete(
    StorageDeletionPlan plan, {
    void Function(StorageDeletionProgress progress)? onProgress,
  }) async {
    onProgress?.call(
      const StorageDeletionProgress(
        completedFiles: 1,
        totalFiles: 2,
        releasedBytes: 1000,
      ),
    );
    await complete.future;
    final deleted = plan.files.map((file) => file.path).toList();
    lastSnapshot = storageSnapshotWithoutFiles(lastSnapshot!, deleted);
    return StorageDeletionResult(
      deletedPaths: deleted,
      releasedBytes: plan.bytes,
      skipped: const {},
      failed: const {},
    );
  }
}
