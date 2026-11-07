import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_screen.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_service.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_store.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_activity_menu.dart';
import 'package:video_player_app/widgets/media_library_settings_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LibraryService library;
  late ProgressSyncService sync;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    library = LibraryService()..resetLibraryForTesting();
    library.writeLibrarySnapshotOverrideForTesting = () async {};
  });
  Future<void> createSync() async {
    sync = ProgressSyncService(
      library: library,
      store: MemoryProgressSyncStore(),
      enableNetwork: false,
    );
    await sync.init();
  }

  tearDown(() {
    sync.dispose();
    library.resetLibraryForTesting();
  });

  Future<void> mountSettings(
    WidgetTester tester, {
    bool includeSync = true,
  }) async {
    await createSync();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      builder: (_, child) => MediaQuery(
        data: const MediaQueryData(size: Size(390, 844)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showMediaLibrarySettingsBottomSheet(
              context,
              SettingsService(),
              showSystemMediaNotificationSetting: false,
            ),
            child: const Text('打开设置'),
          ),
        ),
      ),
    );
    await tester.pumpWidget(
      includeSync
          ? ChangeNotifierProvider<ProgressSyncService>.value(
              value: sync,
              child: app,
            )
          : app,
    );
    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
    expect(find.text('媒体库设置'), findsOneWidget);

    await tester.pumpAndSettle();
  }

  testWidgets(
    'library settings opens the real sync screen without an account',
    (tester) async {
      await mountSettings(tester);
      expect(find.text('设备同步'), findsOneWidget);
      expect(find.text('进度同步'), findsNothing);
      await tester.ensureVisible(
        find.byKey(const ValueKey('progressSyncSettings')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('progressSyncSettings')));
      await tester.pumpAndSettle();
      expect(find.byType(ProgressSyncScreen), findsOneWidget);
      expect(find.text('媒体库设置'), findsNothing);
      expect(find.textContaining('已暂停，本机仍会记录进度'), findsOneWidget);
      expect(find.text('选择想要接着看的文件夹'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('progress-sync-enabled')));
      await tester.pumpAndSettle();
      expect(sync.enabled, isTrue);
      expect(find.text('在另一台设备打开此页，并连接同一 Wi-Fi。'), findsOneWidget);
      await tester.ensureVisible(find.text('添加'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();
      expect(find.textContaining('媒体库里还没有文件夹'), findsOneWidget);
      expect(find.textContaining('先在媒体库添加'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await sync.setEnabled(false);
    },
  );

  testWidgets(
    'settings remains usable when the optional sync provider is absent',
    (tester) async {
      await mountSettings(tester, includeSync: false);
      expect(find.byKey(const ValueKey('progressSyncSettings')), findsNothing);
      expect(find.text('网络设置'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'folder menu proposes sync for that folder and guides nearby pairing',
    (tester) async {
      await createSync();
      library.seedCollectionForTesting(
        VideoCollection(id: 'course', name: '我的课程', createTime: 1),
      );
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<LibraryService>.value(value: library),
            ChangeNotifierProvider<ProgressSyncService>.value(value: sync),
          ],
          child: MaterialApp(
            theme: ThemeData.dark(useMaterial3: true),
            builder: (_, child) => MediaQuery(
              data: const MediaQueryData(size: Size(390, 844)),
              child: child!,
            ),
            home: const Scaffold(
              body: Center(
                child: MediaLibraryActivityMenuButton(
                  targetId: 'course',
                  isCollection: true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('media-library-activity-menu')),
      );
      await tester.pumpAndSettle();
      expect(find.text('同步此文件夹'), findsNothing);
      expect(find.text('发送到设备'), findsNothing);
      await tester.tap(find.text('同步到设备'));
      await tester.pumpAndSettle();
      expect(find.byType(ProgressSyncScreen), findsOneWidget);
      expect(sync.bindings, isEmpty);
      expect(find.text('同步到设备'), findsOneWidget);
      expect(find.text('先连接另一台设备'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('选择想要接着看的文件夹'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await sync.setEnabled(false);
    },
  );
}
