import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_models.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_screen.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_service.dart';
import 'package:video_player_app/features/progress_sync/folder_transfer_models.dart';
import 'package:video_player_app/features/progress_sync/folder_transfer_widgets.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_models.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_service.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_store.dart';
import 'package:video_player_app/services/library_service.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

class _Sync extends ProgressSyncService {
  _Sync(LibraryService library)
    : super(
        library: library,
        store: MemoryProgressSyncStore(),
        enableNetwork: false,
      );
  final tasks = <FolderTransferTask>[];
  String? accepted;
  String? linkedCollection;
  String? destinationParent;
  @override
  List<FolderTransferTask> get folderTransfers => tasks;
  @override
  Future<void> acceptFolderTransfer(
    String id, {
    String? destinationParentId,
  }) async {
    accepted = id;
    destinationParent = destinationParentId;
  }

  @override
  Future<void> acceptFolderSync(
    String proposalId, {
    required FolderSyncAcceptChoice choice,
    String? existingCollectionId,
    String? destinationParentId,
  }) async {
    expect(choice, FolderSyncAcceptChoice.linkExisting);
    accepted = proposalId;
    linkedCollection = existingCollectionId;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PathProviderPlatform originalPaths;
  late LibraryService library;
  late _Sync sync;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('folder_transfer_page_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    await PortableTransferService.instance.initialize();
  });
  tearDownAll(() async {
    PathProviderPlatform.instance = originalPaths;
    await directory.delete(recursive: true);
  });
  setUp(() {
    library = LibraryService()..resetLibraryForTesting();
    sync = _Sync(library);
  });
  tearDown(() {
    sync.dispose();
    library.resetLibraryForTesting();
  });

  Future<void> mount(WidgetTester tester, {bool withSync = true}) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      builder: (_, child) => MediaQuery(
        data: const MediaQueryData(
          size: Size(390, 844),
          textScaler: TextScaler.linear(1.3),
        ),
        child: child!,
      ),
      home: const PortableTransferScreen(
        initialTab: PortableTransferKind.import,
      ),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<LibraryService>.value(
        value: library,
        child: withSync
            ? ChangeNotifierProvider<ProgressSyncService>.value(
                value: sync,
                child: app,
              )
            : app,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'import page reuses incoming device cards and accepts in one tap',
    (tester) async {
      sync.tasks.add(
        FolderTransferTask(
          id: 'incoming',
          direction: FolderTransferDirection.receive,
          peerId: 'desktop',
          peerName: '书房电脑',
          sourceCollectionId: 'course',
          folderName: '课程 A',
          createdAt: DateTime(2026),
          phase: FolderTransferPhase.offered,
          mediaCount: 30,
          estimatedBytes: 1024,
        ),
      );
      sync.tasks.add(
        FolderTransferTask(
          id: 'outgoing',
          direction: FolderTransferDirection.send,
          peerId: 'phone',
          peerName: '手机',
          sourceCollectionId: 'music',
          folderName: '仅导出页可见的发送任务',
          createdAt: DateTime(2026),
          phase: FolderTransferPhase.waiting,
        ),
      );
      await mount(tester);
      expect(find.byType(FolderTransferCard), findsOneWidget);
      expect(find.text('课程 A'), findsOneWidget);
      expect(find.text('仅导出页可见的发送任务'), findsNothing);
      await tester.tap(find.text('接收'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('接收新文件夹'));
      await tester.pumpAndSettle();
      expect(sync.accepted, 'incoming');
      await tester.tap(find.text('导出 (E)'));
      await tester.pumpAndSettle();
      expect(find.text('仅导出页可见的发送任务'), findsOneWidget);
      expect(find.text('课程 A'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('standalone import page still works without a sync provider', (
    tester,
  ) async {
    await mount(tester, withSync: false);
    expect(find.byType(FolderTransferCard), findsNothing);
    expect(find.text('选择文件 (N)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new received folder can choose a nested destination', (
    tester,
  ) async {
    library.writeLibrarySnapshotOverrideForTesting = () async {};
    addTearDown(() => library.writeLibrarySnapshotOverrideForTesting = null);
    await tester.runAsync(() async {
      await library.createCollection('课程保存处', null, id: 'destination');
    });
    sync.tasks.add(
      FolderTransferTask(
        id: 'incoming-destination',
        direction: FolderTransferDirection.receive,
        peerId: 'desktop',
        peerName: '电脑',
        sourceCollectionId: 'course',
        folderName: '课程',
        createdAt: DateTime(2026),
        phase: FolderTransferPhase.offered,
      ),
    );
    await mount(tester);
    await tester.tap(find.text('接收'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存到：媒体库根目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('课程保存处'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('folder-picker-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('保存到：课程保存处'), findsOneWidget);
    expect(sync.accepted, isNull);
    await tester.tap(find.text('接收新文件夹'));
    await tester.pumpAndSettle();
    expect(sync.accepted, 'incoming-destination');
    expect(sync.destinationParent, 'destination');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'incoming sync links a nested local folder only after confirmation',
    (tester) async {
      library.writeLibrarySnapshotOverrideForTesting = () async {};
      addTearDown(() => library.writeLibrarySnapshotOverrideForTesting = null);
      await tester.runAsync(() async {
        await library.createCollection('本机课程', null, id: 'courses');
        await library.createCollection('数学', 'courses', id: 'math');
      });
      sync.tasks.add(
        FolderTransferTask(
          id: 'incoming-link',
          direction: FolderTransferDirection.receive,
          peerId: 'desktop',
          peerName: '书房电脑',
          sourceCollectionId: 'course',
          folderName: '电脑上的课程',
          createdAt: DateTime(2026),
          phase: FolderTransferPhase.offered,
        ),
      );
      await mount(tester);
      await tester.tap(find.text('接收'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关联本地文件夹'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('folder-picker-folder-math')),
        findsNothing,
      );
      await tester.tap(find.text('本机课程'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('folder-picker-select-math')));
      await tester.pumpAndSettle();
      expect(sync.accepted, isNull);
      await tester.tap(find.byKey(const ValueKey('folder-picker-confirm')));
      await tester.pumpAndSettle();
      expect(sync.accepted, 'incoming-link');
      expect(sync.linkedCollection, 'math');
      expect(tester.takeException(), isNull);
    },
  );
}
