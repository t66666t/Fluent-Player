import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_components.dart';
import 'package:video_player_app/features/progress_sync/folder_transfer_models.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_models.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_screen.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_service.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_store.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_webdav.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/widgets/library_folder_picker.dart';

class _ScreenService extends ProgressSyncService {
  _ScreenService()
    : super(
        library: LibraryService(),
        store: MemoryProgressSyncStore(),
        enableNetwork: false,
      );

  bool on = true;
  final folders = <SyncLocalFolder>[
    const SyncLocalFolder(id: 'course', name: '课程 A', mediaCount: 30),
    const SyncLocalFolder(id: 'travel', name: '旅行记录 / 夏天', mediaCount: 12),
  ];
  final linked = <SyncFolderBinding>[];
  final incoming = <SyncFolderInvitation>[];
  final transfers = <FolderTransferTask>[];
  final peers = <String, String>{};
  ProgressSyncWebDavConfig? config;
  int storageSaves = 0;
  int syncCalls = 0;
  bool remoteBusy = false;
  String? acceptedFolder;
  String? acceptedGroup;
  String? sentCollection;
  String? sentPeer;

  @override
  bool get initialized => true;
  @override
  bool get enabled => on;
  @override
  bool get busy => remoteBusy;
  @override
  String get deviceName => '我的电脑';
  @override
  String get status => '等待已关联设备上线';
  @override
  String? get error => null;
  @override
  String? get connectionAddress => '192.168.1.10:47791';
  @override
  List<SyncLocalFolder> get localFolders => folders;
  @override
  List<SyncFolderBinding> get bindings => linked;
  @override
  List<SyncFolderInvitation> get invitations => incoming;
  @override
  List<SyncProgressConflict> get conflicts => [];
  @override
  List<FolderTransferTask> get folderTransfers => transfers;
  @override
  Map<String, String> get pairedDevices => peers;
  @override
  ProgressSyncWebDavConfig? get webDavConfig => config;
  @override
  String? get webDavStatus => config == null ? null : '已同步';
  @override
  Future<void> init() async {}
  @override
  Future<void> syncNow() async {
    syncCalls++;
  }

  @override
  Future<void> setEnabled(bool value) async {
    on = value;
    notifyListeners();
  }

  @override
  Future<void> configureWebDav(ProgressSyncWebDavConfig value) async {
    storageSaves++;
    config = value;
    notifyListeners();
  }

  @override
  Future<void> acceptInvitation(String groupId, String collectionId) async {
    acceptedGroup = groupId;
    acceptedFolder = collectionId;
    incoming.clear();
    notifyListeners();
  }

  @override
  Future<void> discover() async {}
  @override
  Future<void> sendFolder(String collectionId, String peerId) async {
    sentCollection = collectionId;
    sentPeer = peerId;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _ScreenService service;

  setUp(() async {
    final library = LibraryService()..resetLibraryForTesting();
    library.writeLibrarySnapshotOverrideForTesting = () async {};
    await library.createCollection('课程 A', null, id: 'course');
    await library.createCollection('旅行记录', null, id: 'trips');
    await library.createCollection('夏天', 'trips', id: 'travel');
    service = _ScreenService();
  });
  tearDown(() {
    service.dispose();
    LibraryService()
      ..resetLibraryForTesting()
      ..writeLibrarySnapshotOverrideForTesting = null;
  });

  Future<void> show(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    double textScale = 1,
    GlobalKey? boundaryKey,
    String? initialCollectionId,
    bool sendFolder = false,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'MiSans'),
        ),
        builder: (_, child) => MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        home: RepaintBoundary(
          key: boundaryKey,
          child: ProgressSyncScreen(
            service: service,
            initialCollectionId: initialCollectionId,
            sendFolder: sendFolder,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('sync keys preserve disabled states and modal ownership', (
    tester,
  ) async {
    await show(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyR);
    await tester.pumpAndSettle();
    expect(service.syncCalls, 1);
    service.remoteBusy = true;
    service.notifyListeners();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    expect(service.syncCalls, 1);
    service.remoteBusy = false;
    service.on = false;
    service.notifyListeners();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    expect(service.syncCalls, 1);
    service.on = true;
    service.notifyListeners();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.pumpAndSettle();
    expect(find.byType(LibraryFolderPicker), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    expect(service.syncCalls, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('phone keeps setup concise and storage settings optional', (
    tester,
  ) async {
    await show(tester);
    expect(find.text('换一台设备，接着看。'), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);
    expect(tester.takeException(), isNull);

    final storage = find.byKey(const ValueKey('progress-sync-storage'));
    await tester.scrollUntilVisible(
      storage,
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(storage);
    await tester.pumpAndSettle();
    expect(find.byType(TextFormField), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'storage validates the address and retains an existing password',
    (tester) async {
      service.config = const ProgressSyncWebDavConfig(
        url: 'https://nas.example/dav/',
        username: 'existing',
        password: 'saved-password',
      );
      await show(tester);
      final storage = find.byKey(const ValueKey('progress-sync-storage'));
      await tester.scrollUntilVisible(
        storage,
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(storage);
      await tester.pumpAndSettle();
      final address = find.widgetWithText(TextFormField, '存储地址');
      await tester.enterText(address, 'nas.example');
      final connect = find.text('测试并连接');
      await tester.ensureVisible(connect);
      await tester.pumpAndSettle();
      await tester.tap(connect);
      await tester.pumpAndSettle();
      expect(find.text('请输入完整的 http 或 https 地址'), findsOneWidget);
      expect(service.storageSaves, 0);

      await tester.enterText(address, 'https://nas.example/new-path/');
      await tester.ensureVisible(connect);
      await tester.pumpAndSettle();
      await tester.tap(connect);
      await tester.pumpAndSettle();
      expect(service.storageSaves, 1);
      expect(service.config!.password, 'saved-password');
      expect(service.config!.url, 'https://nas.example/new-path/');
      await tester.enterText(address, 'https://different.example/dav/');
      await tester.ensureVisible(connect);
      await tester.pumpAndSettle();
      await tester.tap(connect);
      await tester.pumpAndSettle();
      expect(service.config!.password, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('incoming folder only binds after choosing an existing folder', (
    tester,
  ) async {
    service.incoming.add(
      const SyncFolderInvitation(
        groupId: 'shared-course',
        name: '电脑上的课程',
        fromDevice: '书房电脑',
        mediaCount: 30,
      ),
    );
    await show(tester);
    await tester.tap(find.text('关联').first);
    await tester.pumpAndSettle();
    expect(service.acceptedFolder, isNull);
    await tester.tap(find.text('课程 A'));
    await tester.pumpAndSettle();
    expect(service.acceptedFolder, isNull);
    await tester.tap(
      find.byKey(const ValueKey('folder-picker-select-current')),
    );
    await tester.pumpAndSettle();
    expect(service.acceptedFolder, isNull);
    await tester.tap(find.byKey(const ValueKey('folder-picker-confirm')));
    await tester.pumpAndSettle();
    expect(service.acceptedGroup, 'shared-course');
    expect(service.acceptedFolder, 'course');
    expect(tester.takeException(), isNull);
  });

  testWidgets('sending chooses one nested folder before selecting its device', (
    tester,
  ) async {
    service.peers['phone'] = '我的手机';
    await show(tester);
    await tester.tap(find.byKey(const ValueKey('send-folder-primary')));
    await tester.pumpAndSettle();
    expect(find.byType(LibraryFolderPicker), findsOneWidget);
    expect(
      find.byKey(const ValueKey('folder-picker-folder-travel')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('folder-picker-select-course')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('旅行记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('folder-picker-select-travel')));
    await tester.pumpAndSettle();
    expect(service.sentCollection, isNull);
    await tester.tap(find.byKey(const ValueKey('folder-picker-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('同步到设备'), findsOneWidget);
    expect(find.text('「旅行记录 / 夏天」· 12 个媒体文件'), findsOneWidget);
    await tester.tap(find.text('我的手机').last);
    await tester.pumpAndSettle();
    expect(service.sentCollection, 'travel');
    expect(service.sentPeer, 'phone');
    expect(tester.takeException(), isNull);
  });

  testWidgets('pairing requires an explicit comparison confirmation', (
    tester,
  ) async {
    bool? allowed;
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        builder: (_, child) => MediaQuery(
          data: const MediaQueryData(size: Size(390, 844)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                allowed = await showProgressSyncPairingConfirmation(
                  context: context,
                  deviceName: '我的手机',
                  code: '412903',
                );
              },
              child: const Text('pair'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('pair'));
    await tester.pumpAndSettle();
    expect(find.text('412903'), findsOneWidget);
    expect(allowed, isNull);
    await tester.tap(find.text('相同，允许连接'));
    await tester.pumpAndSettle();
    expect(allowed, true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long names and larger phone text remain scrollable', (
    tester,
  ) async {
    service.linked.add(
      const SyncFolderBinding(
        groupId: 'long',
        collectionId: 'long',
        name: '这是一个非常长的文件夹名称，用于核对手机和桌面显示是否会超出边界',
        matchedCount: 12345,
      ),
    );
    await show(tester, textScale: 1.3);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('progress-sync-storage')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('progress-sync-storage')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('测试并连接'));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'send action chooses a paired device without creating an empty binding',
    (tester) async {
      service.peers['phone'] = '我的手机';
      await show(tester, initialCollectionId: 'course', sendFolder: true);
      expect(find.text('同步到设备'), findsOneWidget);
      expect(find.text('我的手机'), findsNWidgets(2));
      expect(service.bindings, isEmpty);
      await tester.tap(find.text('我的手机').last);
      await tester.pumpAndSettle();
      expect(service.sentCollection, 'course');
      expect(service.sentPeer, 'phone');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('sending without paired devices offers nearby connection first', (
    tester,
  ) async {
    await show(tester, initialCollectionId: 'course', sendFolder: true);
    expect(find.text('先连接另一台设备'), findsOneWidget);
    expect(find.text('连接附近设备'), findsOneWidget);
    expect(service.sentCollection, isNull);
    expect(service.bindings, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'sending resumes the device choice after nearby pairing completes',
    (tester) async {
      await show(tester, initialCollectionId: 'course', sendFolder: true);
      await tester.tap(find.text('连接附近设备'));
      await tester.pumpAndSettle();
      service.peers['phone'] = '新连接的手机';
      service.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('同步到设备'), findsOneWidget);
      await tester.tap(find.text('新连接的手机').last);
      await tester.pumpAndSettle();
      expect(service.sentPeer, 'phone');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('render phone and desktop previews', (tester) async {
    if (!Platform.environment.containsKey('PROGRESS_SYNC_PREVIEW')) return;
    final loader = FontLoader('MiSans')
      ..addFont(rootBundle.load('assets/fonts/MiSans-Regular.otf'));
    await loader.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    service.linked.add(
      const SyncFolderBinding(
        groupId: 'course',
        collectionId: 'course',
        name: '课程 A',
        matchedCount: 30,
      ),
    );
    final directory = Directory('.artifacts/progress-sync');
    await tester.runAsync(() => directory.create(recursive: true));
    for (final size in [const Size(390, 1000), const Size(1120, 1000)]) {
      final boundaryKey = GlobalKey();
      await show(tester, size: size, boundaryKey: boundaryKey);
      await tester.pump();
      final boundary =
          boundaryKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '${directory.path}/${size.width.toInt()}.png',
        ).writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
    final pairingBoundary = GlobalKey();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(
      RepaintBoundary(
        key: pairingBoundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark(useMaterial3: true).copyWith(
            textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'MiSans'),
            colorScheme: const ColorScheme.dark(primary: Color(0xFF4B8EF0)),
          ),
          builder: (_, child) => MediaQuery(
            data: const MediaQueryData(size: Size(390, 844)),
            child: child!,
          ),
          home: ProgressSyncScreen(service: service),
        ),
      ),
    );
    await tester.pumpAndSettle();
    unawaited(
      showProgressSyncPairingConfirmation(
        context: tester.element(find.byType(ProgressSyncScreen)),
        deviceName: '我的手机',
        code: '412903',
      ),
    );
    await tester.pumpAndSettle();
    final pairingRender =
        pairingBoundary.currentContext!.findRenderObject()
            as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await pairingRender.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '${directory.path}/390-pairing.png',
      ).writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
