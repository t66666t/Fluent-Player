import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/screens/storage_management_screen.dart';
import 'package:video_player_app/services/storage_audit_models.dart';
import 'package:video_player_app/services/storage_audit_service.dart';
import 'package:video_player_app/services/storage_presentation.dart';

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
    expect(find.text('网盘'), findsNothing);
    expect(find.text('存储记录已变化'), findsOneWidget);
    await tester.tap(find.text('播客'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('存储空间管理'), findsOneWidget);
  });

  testWidgets(
    'source cleanup uses the displayed scope and preserves offline media',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = _ScopedCleanupService();
      await tester.pumpWidget(
        MaterialApp(home: StorageManagementScreen(service: service)),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('网盘'),
        storageSourceFilters.contains(StorageSourceFilter.cloudDrive)
            ? findsOneWidget
            : findsNothing,
      );
      expect(
        find.text('历史来源文件'),
        storageSourceFilters.contains(StorageSourceFilter.legacy)
            ? findsOneWidget
            : findsNothing,
      );
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('storageTotal'))).data,
        '10.00 KB',
      );
      await tester.tap(find.text('播客'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('storageTotal'))).data,
        '5.00 KB',
      );
      expect(find.text('4.88 KiB · 2 个文件'), findsOneWidget);
      expect(find.text('可清理缓存 2.00 KB'), findsOneWidget);
      expect(find.text('需确认删除 3.00 KB'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('storageClearCache')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(service.plans.single.action, StorageCleanupAction.clearCache);
      expect(service.plans.single.files.map((file) => file.path), [
        '/data/podcast.seg',
      ]);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('storageTotal'))).data,
        '3.00 KB',
      );
      expect(find.text('可清理缓存 0 B'), findsOneWidget);
      expect(find.text('2.93 KiB · 1 个文件'), findsOneWidget);
      expect(find.byKey(const ValueKey('storageClearCache')), findsNothing);
      await tester.scrollUntilVisible(
        find.text(StorageCategory.offlineDownloads.title),
        150,
      );
      await tester.tap(find.text(StorageCategory.offlineDownloads.title));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除离线下载'));
      await tester.pumpAndSettle();
      expect(find.text('删除 1 个文件？'), findsOneWidget);
      expect(find.textContaining('3.00 KB · 离线下载'), findsOneWidget);
      await tester.tap(find.text('删除这些文件'));
      await tester.pumpAndSettle();
      expect(service.plans.last.action, StorageCleanupAction.deleteOffline);
      expect(service.lastSnapshot!.appBytes, 5000);
      expect(find.text('0 B · 0 个文件，按大小排列'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('storageTotal'))).data,
        '0 B',
      );
      expect(find.text('此来源暂无应用文件。'), findsOneWidget);
    },
  );

  testWidgets(
    'detail cleanup retains the source filter when updating its files',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = _ScopedCleanupService();
      await tester.pumpWidget(
        MaterialApp(home: StorageManagementScreen(service: service)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('播客'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text(StorageCategory.streaming.title),
        180,
      );
      await tester.tap(find.text(StorageCategory.streaming.title));
      await tester.pumpAndSettle();
      expect(find.textContaining('/data/cloud.bin'), findsNothing);
      await tester.enterText(find.byType(TextField), 'no-match');
      await tester.pumpAndSettle(const Duration(milliseconds: 250));
      expect(find.text('清理缓存'), findsNothing);
      expect(find.textContaining('当前匹配 0 个文件'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'podcast');
      await tester.pumpAndSettle(const Duration(milliseconds: 250));
      await tester.tap(find.text('清理缓存'));
      await tester.pumpAndSettle();
      expect(find.text('0 B · 0 个文件，按大小排列'), findsOneWidget);
      expect(find.textContaining('/data/cloud.bin'), findsNothing);
      expect(
        service.lastSnapshot!.files.any(
          (file) => file.path == '/data/cloud.bin',
        ),
        isTrue,
      );
    },
  );

  testWidgets('detail header scrolls with large text and an open keyboard', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 520);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final service = StorageAuditService(
      buildInput: () async => const StorageScanInput(roots: []),
      deletionBlockedReason: () => null,
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(1.6)),
          child: child!,
        ),
        home: StorageManagementScreen(
          service: service,
          initialSnapshot: snapshot(),
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.text(StorageCategory.picker.title),
      180,
    );
    await tester.tap(find.text(StorageCategory.picker.title));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    tester.view.viewInsets = const FakeViewPadding(bottom: 220);
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byType(TextField),
      120,
      scrollable: find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.enterText(find.byType(TextField), 'video');
    await tester.pumpAndSettle(const Duration(milliseconds: 250));
    expect(tester.takeException(), isNull);
    expect(find.textContaining('当前匹配 1 个文件'), findsOneWidget);
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
          await tester.scrollUntilVisible(
            find.text(StorageCategory.picker.title),
            150,
          );
          await tester.tap(find.text(StorageCategory.picker.title));
          await tester.pumpAndSettle();
          await tester.tap(find.text('清理当前列表可删除文件'));
        } else {
          await tester.scrollUntilVisible(find.text('删除 3.00 KB'), 150);
          await tester.pumpAndSettle();
          await tester.tap(find.text('删除 3.00 KB'));
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

class _ScopedCleanupService extends StorageAuditService {
  _ScopedCleanupService()
    : super(
        buildInput: () async => throw StateError('unexpected scan'),
        deletionBlockedReason: () => null,
        initialSnapshot: StorageSnapshot(
          scannedAt: DateTime(2026),
          roots: const [],
          warnings: const [],
          files: [
            for (final (name, bytes, origin, category, policy, direct, explicit)
                in [
                  (
                    'local.mp4',
                    1000,
                    StorageOrigin.localMedia,
                    StorageCategory.libraryMedia,
                    StorageCleanupPolicy.protected,
                    false,
                    false,
                  ),
                  (
                    'podcast.seg',
                    2000,
                    StorageOrigin.podcast,
                    StorageCategory.streaming,
                    StorageCleanupPolicy.regenerableCache,
                    true,
                    false,
                  ),
                  (
                    'offline.mp3',
                    3000,
                    StorageOrigin.podcast,
                    StorageCategory.offlineDownloads,
                    StorageCleanupPolicy.savedContent,
                    false,
                    true,
                  ),
                  (
                    'cloud.bin',
                    4000,
                    StorageOrigin.cloudDrive,
                    StorageCategory.streaming,
                    StorageCleanupPolicy.regenerableCache,
                    true,
                    false,
                  ),
                ])
              StorageFileEntry(
                path: '/data/$name',
                rootPath: '/data',
                rootLabel: 'data',
                category: category,
                bytes: bytes,
                modifiedMicros: 1,
                changedMicros: 1,
                ownerIds: const [],
                ownerTitles: const [],
                origin: origin,
                cleanupPolicy: policy,
                canDelete: direct,
                explicitDelete: explicit,
              ),
          ],
        ),
      );

  final plans = <StorageDeletionPlan>[];
  @override
  Future<StorageDeletionResult> delete(
    StorageDeletionPlan plan, {
    void Function(StorageDeletionProgress progress)? onProgress,
  }) async {
    plans.add(plan);
    final paths = plan.files.map((file) => file.path).toList();
    lastSnapshot = storageSnapshotWithoutFiles(lastSnapshot!, paths);
    return StorageDeletionResult(
      deletedPaths: paths,
      releasedBytes: plan.bytes,
      skipped: const {},
      failed: const {},
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
