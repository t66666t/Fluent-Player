import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/progress_sync/folder_sync_conflict_sheet.dart';
import 'package:video_player_app/features/progress_sync/folder_sync_models.dart';
import 'package:video_player_app/features/progress_sync/folder_sync_settings_sheet.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_models.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_screen.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_service.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_store.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:video_player_app/widgets/media_library_action_dock.dart';
import 'package:video_player_app/widgets/media_library_activity_menu.dart';
import 'package:video_player_app/widgets/media_library_browse_grid_cards.dart';
import 'package:video_player_app/widgets/media_library_folder_sync_button.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';
import 'package:video_player_app/widgets/mini_playback_card.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';

class _Sync extends ProgressSyncService {
  _Sync()
    : super(
        library: LibraryService(),
        store: MemoryProgressSyncStore(),
        enableNetwork: false,
      );
  FolderSyncSettings settings = const FolderSyncSettings();
  bool linked = true;
  int syncCalls = 0;
  Map<String, String> devices = {'local': '我的电脑', 'phone': '我的手机'};
  final issues = <FolderSyncIssue>[];
  ({String groupId, String nodeId, String eventId, bool keepBoth})? resolution;
  ({String groupId, String nodeId, String path})? relink;
  String? relinkFailure;
  @override
  bool get initialized => true;
  @override
  bool get enabled => true;
  @override
  Future<void> init() async {}
  @override
  Future<void> relinkSyncedMedia(
    String groupId,
    String nodeId,
    String path,
  ) async {
    relink = (groupId: groupId, nodeId: nodeId, path: path);
    if (relinkFailure != null) throw FormatException(relinkFailure!);
    issues.clear();
    notifyListeners();
  }

  @override
  List<FolderSyncIssue> get folderSyncIssues => issues;
  @override
  Future<void> resolveFolderSyncConflict(
    String groupId,
    String nodeId,
    String eventId, {
    bool keepBoth = false,
  }) async {
    resolution = (
      groupId: groupId,
      nodeId: nodeId,
      eventId: eventId,
      keepBoth: keepBoth,
    );
    issues.clear();
    notifyListeners();
  }

  @override
  String get deviceId => 'local';
  @override
  List<SyncFolderBinding> get bindings => linked
      ? [
          const SyncFolderBinding(
            groupId: 'group',
            collectionId: 'folder',
            name: '课程 A',
          ),
        ]
      : [];
  @override
  FolderSyncSettings folderSettings(String id) => settings;
  @override
  Map<String, String> folderDevices(String id) => devices;
  @override
  Future<void> updateFolderSettings(String id, FolderSyncSettings value) async {
    settings = value;
  }

  @override
  Future<void> syncFolderNow(String id) async {
    syncCalls++;
  }
}

class _Picker extends FilePicker {
  FilePickerResult? result;
  int calls = 0;
  FileType? requestedType;
  bool? requestedMultiple;

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
  }) async {
    calls++;
    requestedType = type;
    requestedMultiple = allowMultiple;
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Sync sync;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LibraryService().resetLibraryForTesting();
    sync = _Sync();
  });
  tearDown(() {
    sync.dispose();
    LibraryService().resetLibraryForTesting();
  });

  Future<void> mount(
    WidgetTester tester,
    Widget Function(BuildContext) body, {
    Size size = const Size(390, 844),
    double scale = 1.3,
    GlobalKey? capture,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ProgressSyncService>.value(value: sync),
          ChangeNotifierProvider<LibraryService>.value(value: LibraryService()),
        ],
        child: RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData.dark(useMaterial3: true).copyWith(
              scaffoldBackgroundColor: AppTokens.bgBase,
              textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'MiSans'),
              colorScheme: const ColorScheme.dark(
                primary: AppTokens.accent,
                surface: AppTokens.bgRaised,
              ),
            ),
            builder: (_, child) => MediaQuery(
              data: MediaQueryData(
                size: size,
                textScaler: TextScaler.linear(scale),
              ),
              child: child!,
            ),
            home: Builder(builder: (context) => Scaffold(body: body(context))),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openSettings(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    GlobalKey? capture,
  }) async {
    await mount(
      tester,
      (context) => Center(
        child: TextButton(
          onPressed: () =>
              showFolderSyncSettings(context, sync, 'folder', name: '课程 A'),
          child: const Text('打开'),
        ),
      ),
      size: size,
      capture: capture,
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets('folder sync sheets cover the library mini player', (
    tester,
  ) async {
    final settings = SettingsService()..resetForTest();
    await settings.init();
    final playback = MediaPlaybackService();
    await playback.stop();
    playback.publishRestoredSessionPreview(
      VideoItem(
        id: 'sync-sheet-clip',
        path: 'clip.mp4',
        title: 'clip',
        durationMs: 120000,
        lastUpdated: 0,
      ),
      Duration.zero,
    );
    addTearDown(() async {
      await playback.stop();
      settings.resetForTest();
    });
    bool? removal;
    await mount(
      tester,
      (_) => MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
        ],
        child: MediaLibraryShell(
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  const MediaLibraryFolderSyncButton(collectionId: 'folder'),
                  TextButton(
                    onPressed: () async {
                      removal = await showSyncedItemRemoval(
                        context,
                        name: '课程 A',
                        isRoot: false,
                      );
                    },
                    child: const Text('移除项目'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final rootNavigator = Navigator.of(
      tester.element(find.byType(MediaLibraryShell)),
      rootNavigator: true,
    );
    void expectSheetCoversPlayer() {
      expect(
        tester.getSize(find.byType(MiniPlaybackCard)).height,
        greaterThan(0),
      );
      expect(
        ModalRoute.of(tester.element(find.byType(BottomSheet)))!.navigator,
        same(rootNavigator),
      );
    }

    await tester.tap(find.byKey(const ValueKey('folder-sync-button-folder')));
    await tester.pumpAndSettle();
    expectSheetCoversPlayer();
    expect(find.text('同步设置').hitTestable(), findsOneWidget);
    await tester.tap(find.text('同步设置'));
    await tester.pumpAndSettle();
    expectSheetCoversPlayer();
    await tester.ensureVisible(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('保存').hitTestable(), findsOneWidget);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(rootNavigator.canPop(), isFalse);

    await tester.tap(find.text('移除项目'));
    await tester.pumpAndSettle();
    expectSheetCoversPlayer();
    expect(find.text('仅从本机移除').hitTestable(), findsOneWidget);
    await tester.tap(find.text('仅从本机移除'));
    await tester.pumpAndSettle();
    expect(removal, isFalse);
    expect(rootNavigator.canPop(), isFalse);
    expect(find.byType(MediaLibraryFolderSyncButton), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('defaults to smart two-way and keeps advanced controls folded', (
    tester,
  ) async {
    await openSettings(tester);
    expect(find.text('智能双向'), findsOneWidget);
    expect(find.text('同步删除'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('folder-sync-advanced')));
    await tester.pumpAndSettle();
    final deletion = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey('folder-sync-deletes')),
    );
    expect(deletion.value, false);
    await tester.ensureVisible(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(sync.settings.mode, FolderSyncMode.smart);
    expect(sync.settings.syncDeletes, false);
    expect(sync.settings.minFreeBytes, 512 << 20);
    expect(sync.settings.includeSidecars, true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('one-way explicitly selects its source device', (tester) async {
    await openSettings(tester);
    await tester.tap(find.byKey(const ValueKey('folder-sync-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('单向跟随').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('folder-sync-source')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的手机').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(sync.settings.mode, FolderSyncMode.oneWay);
    expect(sync.settings.sourceDeviceId, 'phone');
    expect(tester.takeException(), isNull);
  });

  testWidgets('stale source requires an explicit replacement participant', (
    tester,
  ) async {
    for (final devices in [
      {'local': '我的电脑', 'phone': '我的手机'},
      {'phone': '我的手机'},
    ]) {
      sync.devices = devices;
      sync.settings = const FolderSyncSettings(
        mode: FolderSyncMode.oneWay,
        sourceDeviceId: 'unpaired-device',
      );
      await openSettings(tester);
      final source = tester.widget<CapsuleDropdownButtonFormField<String>>(
        find.byKey(const ValueKey('folder-sync-source')),
      );
      expect(source.initialValue, isNull);
      await tester.ensureVisible(find.text('保存'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(sync.settings.sourceDeviceId, 'unpaired-device');
      expect(find.text('请选择内容来源设备'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('folder-sync-source')),
      );
      await tester.tap(find.byKey(const ValueKey('folder-sync-source')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.text(devices.containsKey('local') ? '我的电脑 · 本机' : '我的手机').last,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('保存'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(sync.settings.sourceDeviceId, devices.keys.first);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'advanced exclusions preserve spaces in glob names and normalize extensions',
    (tester) async {
      await openSettings(tester);
      await tester.tap(find.byKey(const ValueKey('folder-sync-advanced')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, '忽略的文件格式'),
        '.TMP, log, TMP',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '忽略的名称'),
        'My Folder/**, *.bak',
      );
      await tester.ensureVisible(find.text('保存'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(sync.settings.excludedExtensions, ['tmp', 'log']);
      expect(sync.settings.excludedPatterns, ['My Folder/**', '*.bak']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'root removal has no remote-delete choice; child removal is explicit',
    (tester) async {
      bool? everywhere;
      var root = true;
      await mount(
        tester,
        (context) => Center(
          child: TextButton(
            onPressed: () async {
              everywhere = await showSyncedItemRemoval(
                context,
                name: '课程 A',
                isRoot: root,
              );
            },
            child: const Text('移除'),
          ),
        ),
      );
      await tester.tap(find.text('移除'));
      await tester.pumpAndSettle();
      expect(find.text('从所有设备移除'), findsNothing);
      await tester.tap(find.text('仅从本机移除'));
      await tester.pumpAndSettle();
      expect(everywhere, false);
      root = false;
      await tester.tap(find.text('移除'));
      await tester.pumpAndSettle();
      expect(find.text('对应项目移到各设备回收站。'), findsOneWidget);
      await tester.tap(find.text('从所有设备移除'));
      await tester.pumpAndSettle();
      expect(everywhere, true);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'child removal only offers all devices when its mode can publish',
    (tester) async {
      LibraryService().seedCollectionForTesting(
        VideoCollection(id: 'folder', name: '课程 A', createTime: 1),
      );
      LibraryService().seedVideoForTesting(
        VideoItem(
          id: 'clip',
          path: '/tmp/clip.mp4',
          title: '第一课',
          durationMs: 1000,
          lastUpdated: 1,
          parentId: 'folder',
        ),
      );
      for (final (settings, canPublish) in [
        (const FolderSyncSettings(mode: FolderSyncMode.progressOnly), false),
        (
          const FolderSyncSettings(
            mode: FolderSyncMode.oneWay,
            sourceDeviceId: 'phone',
          ),
          false,
        ),
        (
          const FolderSyncSettings(
            mode: FolderSyncMode.oneWay,
            sourceDeviceId: 'local',
          ),
          true,
        ),
        (const FolderSyncSettings(), true),
      ]) {
        sync.settings = settings;
        await mount(
          tester,
          (_) => const Center(
            child: MediaLibraryActivityMenuButton(
              targetId: 'clip',
              isCollection: false,
            ),
          ),
        );
        await tester.tap(
          find.byKey(const ValueKey('media-library-activity-menu')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('移入回收站'));
        await tester.pumpAndSettle();
        expect(find.text('仅从本机移除'), findsOneWidget);
        expect(
          find.text('从所有设备移除'),
          canPublish ? findsOneWidget : findsNothing,
        );
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'file conflict can keep both without guessing which device is newer',
    (tester) async {
      FolderSyncResolution? result;
      final issue = FolderSyncIssue(
        groupId: 'group',
        nodeId: 'node',
        title: '第一课.mp4',
        reason: 'concurrentContent',
        choices: [
          for (final (id, name) in [('desktop', '电脑'), ('phone', '手机')])
            FolderSyncEvent(
              id: id,
              groupId: 'group',
              deviceId: id,
              deviceName: name,
              clock: {id: 1},
              node: const FolderSyncNode(
                id: 'node',
                kind: FolderSyncNodeKind.media,
                name: '第一课.mp4',
                size: 1048576,
              ),
            ),
        ],
      );
      await mount(
        tester,
        (context) => Center(
          child: TextButton(
            onPressed: () async {
              result = await showFolderSyncConflict(context, issue);
            },
            child: const Text('处理'),
          ),
        ),
      );
      await tester.tap(find.text('处理'));
      await tester.pumpAndSettle();
      expect(find.text('保留 电脑 的版本'), findsOneWidget);
      expect(find.text('保留 手机 的版本'), findsOneWidget);
      await tester.tap(find.text('保留双方'));
      await tester.pumpAndSettle();
      expect(result?.keepBoth, true);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'live descendants offer preserving the folder through the real issue action',
    (tester) async {
      sync.issues.add(
        FolderSyncIssue(
          groupId: 'group',
          nodeId: 'parent',
          title: '课程 A',
          reason: 'deleteHasLiveDescendants',
          choices: [
            FolderSyncEvent(
              id: 'parent-delete',
              groupId: 'group',
              deviceId: 'phone',
              clock: {'phone': 1},
              deleted: true,
              node: const FolderSyncNode(
                id: 'parent',
                kind: FolderSyncNodeKind.folder,
                name: '课程 A',
              ),
            ),
          ],
        ),
      );
      await mount(tester, (_) => ProgressSyncScreen(service: sync));
      await tester.tap(find.text('处理'));
      await tester.pumpAndSettle();
      expect(find.text('另一端新增的内容已保留。保留文件夹后，可继续同步。'), findsOneWidget);
      expect(find.textContaining('采用删除'), findsNothing);
      expect(find.text('保留文件夹'), findsOneWidget);
      await tester.tap(find.text('保留文件夹'));
      await tester.pumpAndSettle();
      expect(sync.resolution, (
        groupId: 'group',
        nodeId: 'parent',
        eventId: 'parent-delete',
        keepBoth: true,
      ));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('folder rename chooses one name without offering empty copies', (
    tester,
  ) async {
    FolderSyncResolution? result;
    final issue = FolderSyncIssue(
      groupId: 'group',
      nodeId: 'parent',
      title: '课程 A',
      reason: 'concurrentRename',
      choices: [
        for (final (id, name) in [('desktop', '课程 A'), ('phone', '课程 B')])
          FolderSyncEvent(
            id: id,
            groupId: 'group',
            deviceId: id,
            deviceName: id == 'phone' ? '手机' : '电脑',
            clock: {id: 1},
            node: FolderSyncNode(
              id: 'parent',
              kind: FolderSyncNodeKind.folder,
              name: name,
            ),
          ),
      ],
    );
    await mount(
      tester,
      (context) => Center(
        child: TextButton(
          onPressed: () async {
            result = await showFolderSyncConflict(context, issue);
          },
          child: const Text('处理'),
        ),
      ),
    );
    await tester.tap(find.text('处理'));
    await tester.pumpAndSettle();
    expect(find.text('选择名称'), findsOneWidget);
    expect(find.text('保留双方'), findsNothing);
    expect(find.textContaining('0 B'), findsNothing);
    await tester.tap(find.text('采用 手机 的名称'));
    await tester.pumpAndSettle();
    expect(result, (eventId: 'phone', keepBoth: false));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'missing file relinks through picker and preserves rejected issues',
    (tester) async {
      FilePicker? original;
      try {
        original = FilePicker.platform;
      } catch (_) {
        // Native plugin registration does not run in this widget test.
      }
      final picker = _Picker();
      FilePicker.platform = picker;
      addTearDown(() {
        if (original != null) FilePicker.platform = original;
      });
      sync.issues.add(
        FolderSyncIssue(
          groupId: 'group',
          nodeId: 'missing-media',
          title: '第一课.mp4',
          reason: 'missingLocalFile',
          choices: [],
        ),
      );
      await mount(tester, (_) => ProgressSyncScreen(service: sync));
      expect(find.text('本机文件暂不可用，可自动补齐或重新定位'), findsOneWidget);
      expect(find.text('处理'), findsNothing);
      await tester.tap(find.text('重新定位'));
      await tester.pumpAndSettle();
      expect(picker.calls, 1);
      expect(sync.relink, isNull);
      expect(sync.issues, hasLength(1));

      picker.result = FilePickerResult([
        PlatformFile(name: 'wrong.mp4', path: 'C:/chosen/wrong.mp4', size: 123),
      ]);
      sync.relinkFailure = '所选文件与原文件内容不同，请重新选择';
      await tester.tap(find.text('重新定位'));
      await tester.pumpAndSettle();
      expect(find.text(sync.relinkFailure!), findsOneWidget);
      expect(sync.issues, hasLength(1));

      picker.result = FilePickerResult([
        PlatformFile(name: 'video.mp4', path: 'C:/chosen/video.mp4', size: 123),
      ]);
      sync.relinkFailure = null;
      await tester.tap(find.text('重新定位'));
      await tester.pumpAndSettle();
      expect(picker.requestedType, FileType.any);
      expect(picker.requestedMultiple, false);
      expect(sync.relink, (
        groupId: 'group',
        nodeId: 'missing-media',
        path: 'C:/chosen/video.mp4',
      ));
      expect(sync.issues, isEmpty);
      expect(find.text('已重新定位，观看进度已保留'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'synced folder gets one quiet button with quick sync and settings',
    (tester) async {
      var openedFolder = 0;
      final collection = VideoCollection(
        id: 'folder',
        name: '课程 A',
        createTime: 1,
      );
      await mount(
        tester,
        (_) => Center(
          child: SizedBox(
            width: 180,
            height: 220,
            child: MediaLibraryFolderGridCard(
              collection: collection,
              titleScale: .065,
              onTap: () => openedFolder++,
              onLocate: () {},
            ),
          ),
        ),
      );
      final dock = tester.widget<MediaLibraryActionDock>(
        find.byType(MediaLibraryActionDock),
      );
      expect(dock.sync, isNotNull);
      expect(
        MediaLibraryActionDockMetrics.dockWidth(
          chipSize: 20,
          showMore: true,
          showLocate: true,
          showSync: true,
        ),
        60,
      );
      await tester.tap(find.byKey(const ValueKey('folder-sync-button-folder')));
      await tester.pumpAndSettle();
      expect(openedFolder, 0);
      expect(find.text('立即同步'), findsOneWidget);
      expect(find.text('同步设置'), findsOneWidget);
      await tester.tap(find.text('立即同步'));
      await tester.pumpAndSettle();
      expect(sync.syncCalls, 1);
      sync.linked = false;
      sync.notifyListeners();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('folder-sync-button-folder')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('render concise phone and desktop folder settings', (
    tester,
  ) async {
    if (Platform.environment['PROGRESS_SYNC_PREVIEW'] != '1') return;
    await (FontLoader(
      'MiSans',
    )..addFont(rootBundle.load('assets/fonts/MiSans-Regular.otf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    Future<void> savePreview(GlobalKey capture, String name) async {
      final boundary =
          capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('.artifacts/progress-sync/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    for (final size in [const Size(390, 844), const Size(1120, 1000)]) {
      final capture = GlobalKey();
      await openSettings(tester, size: size, capture: capture);
      await savePreview(capture, 'settings-${size.width.toInt()}');
      await tester.tap(find.byKey(const ValueKey('folder-sync-advanced')));
      await tester.pumpAndSettle();
      await savePreview(capture, 'settings-${size.width.toInt()}-advanced');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
    final capture = GlobalKey();
    await mount(
      tester,
      (_) => Center(
        child: SizedBox(
          width: 180,
          height: 220,
          child: MediaLibraryFolderGridCard(
            collection: VideoCollection(
              id: 'folder',
              name: '课程 A',
              createTime: 1,
            ),
            titleScale: .065,
            onTap: () {},
            onLocate: () {},
          ),
        ),
      ),
      capture: capture,
    );
    await savePreview(capture, 'folder-button-390');
    await tester.tap(find.byKey(const ValueKey('folder-sync-button-folder')));
    await tester.pumpAndSettle();
    await savePreview(capture, 'folder-actions-390');
    expect(tester.takeException(), isNull);
  });
}
