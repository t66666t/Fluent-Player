import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/media_library_view_mode.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_folder_route.dart';
import 'package:video_player_app/widgets/media_library_folder_tree.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';
import 'package:video_player_app/widgets/media_library_view_defaults.dart';

class _ProbePage extends StatelessWidget {
  const _ProbePage(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: Center(child: Text(label)));
  }
}

Future<void> _seedFoldersViaCreate(LibraryService library) async {
  library.resetLibraryForTesting();
  library.writeLibrarySnapshotOverrideForTesting = () async {};
  await library.createCollection('Alpha', null, id: 'alpha');
  await library.createCollection('Beta', 'alpha', id: 'beta');
  await library.createCollection('Gamma', null, id: 'gamma');
}

Future<void> pumpTreeShell(
  WidgetTester tester, {
  required SettingsService settings,
  required LibraryService library,
  required Size size,
  Widget home = const _ProbePage('home'),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final playback = MediaPlaybackService();
  await playback.stop();
  addTearDown(() async => playback.stop());
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: library),
        ChangeNotifierProvider.value(value: playback),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: MediaLibraryShell(
          home: home,
          folderPageBuilder: (id) => _ProbePage('folder $id'),
        ),
      ),
    ),
  );
  await tester.pump();
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LibraryService().resetLibraryForTesting();
    SettingsService().resetForTest();
  });

  tearDown(() {
    LibraryService().resetLibraryForTesting();
    SettingsService().resetForTest();
  });

  test('MediaLibraryFolderTreeController expands ancestors on sync', () {
    final library = LibraryService()..resetLibraryForTesting();
    library.seedCollectionForTesting(
      VideoCollection(id: 'a', name: 'A', createTime: 1, parentId: null),
    );
    library.seedCollectionForTesting(
      VideoCollection(
        id: 'b',
        name: 'B',
        createTime: 2,
        parentId: 'a',
        childrenIds: const [],
      ),
    );
    final controller = MediaLibraryFolderTreeController();
    controller.syncSelection('b', library);
    expect(controller.selectedFolderId, 'b');
    expect(controller.isExpanded('a'), isTrue);
    controller.dispose();
  });

  testWidgets('tree style on wide layout shows docked folder pane', (
    tester,
  ) async {
    final settings = SettingsService()..resetForTest();
    await settings.init();
    await settings.setMediaLibraryViewStyle(MediaLibraryViewMode.tree);
    final library = LibraryService();
    await tester.runAsync(() => _seedFoldersViaCreate(library));

    await pumpTreeShell(
      tester,
      settings: settings,
      library: library,
      size: const Size(
        MediaLibraryViewDefaults.treeDockMinWidth + 80,
        800,
      ),
    );

    expect(find.byKey(MediaLibraryFolderTreePane.paneKey), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Gamma'), findsOneWidget);
    final shell = MediaLibraryShell.maybeOf(tester.element(find.text('home')));
    expect(shell, isNotNull);
    expect(shell!.folderTreeDocked, isTrue);
  });

  testWidgets('tree style on narrow layout uses drawer API', (tester) async {
    final settings = SettingsService()..resetForTest();
    await settings.init();
    await settings.setMediaLibraryViewStyle(MediaLibraryViewMode.tree);
    final library = LibraryService();
    await tester.runAsync(() => _seedFoldersViaCreate(library));

    await pumpTreeShell(
      tester,
      settings: settings,
      library: library,
      size: const Size(400, 800),
    );

    expect(find.text('Alpha'), findsNothing);
    final shell = MediaLibraryShell.maybeOf(tester.element(find.text('home')));
    expect(shell, isNotNull);
    expect(shell!.folderTreeDocked, isFalse);
    shell.openFolderTree();
    await tester.pump();
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(find.text('Alpha'), findsOneWidget);
  });

  testWidgets('empty library wide tree shows only root row', (tester) async {
    final settings = SettingsService()..resetForTest();
    await settings.init();
    await settings.setMediaLibraryViewStyle(MediaLibraryViewMode.tree);
    final library = LibraryService()..resetLibraryForTesting();

    await pumpTreeShell(
      tester,
      settings: settings,
      library: library,
      size: const Size(
        MediaLibraryViewDefaults.treeDockMinWidth + 80,
        800,
      ),
    );

    expect(find.byKey(MediaLibraryFolderTreePane.paneKey), findsOneWidget);
    expect(find.text('媒体库'), findsOneWidget);
    expect(find.text('文件夹'), findsOneWidget);
    expect(find.text('Alpha'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('non-tree styles do not mount the folder tree pane', (
    tester,
  ) async {
    final settings = SettingsService()..resetForTest();
    await settings.init();
    settings.mediaLibraryViewMode = MediaLibraryViewMode.grid.storageValue;
    final library = LibraryService();
    await tester.runAsync(() => _seedFoldersViaCreate(library));

    await pumpTreeShell(
      tester,
      settings: settings,
      library: library,
      size: const Size(1200, 800),
    );

    expect(find.byKey(MediaLibraryFolderTreePane.paneKey), findsNothing);
  });

  testWidgets('tree selection follows nested folder routes', (tester) async {
    final settings = SettingsService()..resetForTest();
    await settings.init();
    await settings.setMediaLibraryViewStyle(MediaLibraryViewMode.tree);
    final library = LibraryService();
    await tester.runAsync(() => _seedFoldersViaCreate(library));

    await pumpTreeShell(
      tester,
      settings: settings,
      library: library,
      size: const Size(1200, 800),
    );

    final homeContext = tester.element(find.text('home'));
    Navigator.of(homeContext).push(
      buildMediaLibraryFolderRoute<void>(
        folderId: 'beta',
        restored: true,
        builder: (_) => const _ProbePage('folder beta'),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(find.text('folder beta'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
  });
}
