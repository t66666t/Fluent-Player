import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_view_options.dart';
import 'package:video_player_app/features/cloud_drive/presentation/cloud_drive_navigation.dart';
import 'package:video_player_app/features/cloud_drive/presentation/cloud_drive_screen.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_runtime.dart';
import 'package:video_player_app/features/media_cache/media_cache_service.dart';
import 'package:video_player_app/models/import_card_placement.dart';
import 'package:video_player_app/models/media_library_root_entry.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/screens/home_screen.dart';
import 'package:video_player_app/services/batch_import_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/screens/batch_subtitle_screen.dart';
import 'package:video_player_app/widgets/library_folder_picker.dart';
import 'package:video_player_app/widgets/media_library_entry_switcher.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';

import 'support/cloud_drive_fixture.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final settings = SettingsService();
  late Directory root;
  late PathProviderPlatform previousPaths;
  late MediaCacheService? previousCache;
  late FixtureCloudProvider provider;
  late CloudDriveRuntime runtime;
  late LibraryService library;
  final video = cloudEntry('video', name: '课程视频.mp4');
  final audio = cloudEntry(
    'audio',
    name: '课程音频.mp3',
    kind: CloudDriveEntryKind.audio,
  );
  final folder = cloudEntry(
    '/course',
    name: '课程',
    kind: CloudDriveEntryKind.folder,
  );
  final inside = cloudEntry('inside', name: '第一课.mp4', parent: '/course');

  setUpAll(() async {
    await (FontLoader(
      'MiSans',
    )..addFont(rootBundle.load('assets/fonts/MiSans-Regular.otf'))).load();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({'onboarding.handled.v1': true});
    settings.resetForTest();
    await settings.init();
    root = await Directory.systemTemp.createTemp('cloud-library-actions-');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    previousCache = MediaCacheService.instance;
    MediaCacheService.instance = null;
    settings.largeDataRootPath = root.path;
    provider = FixtureCloudProvider('baidu', {
      '/': [folder, video, audio],
      '/course': [inside],
    }, pageSize: 100);
    runtime = await cloudRuntime([provider]);
    library = runtime.launch.library;
    library.writeLibrarySnapshotOverrideForTesting = () async {};
  });

  tearDown(() async {
    CloudDriveNavigation.request.value = null;
    await runtime.shutdown();
    library.resetLibraryForTesting();
    settings.resetForTest();
    PathProviderPlatform.instance = previousPaths;
    MediaCacheService.instance = previousCache;
    await root.delete(recursive: true);
  });

  Future<void> pumpBrowser(
    WidgetTester tester, {
    String? openedFrom,
    Size size = const Size(1000, 800),
    double textScale = 1,
    TranscriptionManager? transcription,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LibraryService>.value(value: library),
          if (transcription != null)
            ChangeNotifierProvider<TranscriptionManager>.value(
              value: transcription,
            ),
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          ChangeNotifierProvider<MediaPlaybackService>.value(
            value: runtime.launch.playback,
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(
            brightness: Brightness.dark,
            useMaterial3: true,
            fontFamily: 'MiSans',
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: CloudDriveScreen(runtime: runtime, targetFolderId: openedFrom),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder card(CloudDriveEntry entry) =>
      find.byKey(ValueKey('cloud-drive-entry-${cloudDriveEntryKey(entry)}'));

  Future<void> openMenu(WidgetTester tester, CloudDriveEntry entry) async {
    await tester.tap(
      find.descendant(
        of: card(entry),
        matching: find.byKey(const ValueKey('cloud-entry-cache-menu')),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<VideoItem> imported(String sourceKey) => library.storageVideos
      .where((item) => item.sourceRef?.cloudDrive?.sourceKey == sourceKey)
      .toList();

  Future<VideoCollection> createFolder(WidgetTester tester, String name) async {
    final created = library.createCollection(name, null);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
    return created;
  }

  Future<void> finishImport(WidgetTester tester) async {
    await tester.pump();
    for (
      var attempt = 0;
      attempt < 20 &&
          find.byType(LinearProgressIndicator).evaluate().isNotEmpty;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();
  }

  Future<void> selectMedia(WidgetTester tester) async {
    await tester.longPress(card(video));
    await tester.pumpAndSettle();
    await tester.tap(card(audio));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 项'), findsOneWidget);
  }

  final scenarios =
      <({String name, Future<void> Function(WidgetTester) run})>[];
  void scenario(String name, Future<void> Function(WidgetTester) run) {
    scenarios.add((name: name, run: run));
  }

  for (final entry in [
    'selection',
    'folder-menu',
    'video-menu',
    'audio-menu',
  ]) {
    scenario('cloud $entry opens the queue with playable media sources', (
      tester,
    ) async {
      final manager = TranscriptionManager(settings: settings);
      try {
        await pumpBrowser(
          tester,
          transcription: manager,
          size: const Size(320, 640),
        );
        if (entry == 'selection') {
          await selectMedia(tester);
          await tester.tap(
            find.byKey(const ValueKey('cloud-selection-transcribe')),
          );
        } else {
          await openMenu(
            tester,
            entry == 'folder-menu'
                ? folder
                : entry == 'audio-menu'
                ? audio
                : video,
          );
          await tester.tap(find.byKey(const ValueKey('cloud-transcribe')));
        }
        await finishImport(tester);
        for (
          var attempt = 0;
          attempt < 20 && manager.getQueueSnapshot().isEmpty;
          attempt++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
        expect(find.byType(BatchSubtitleScreen), findsOneWidget);
        final tasks = manager.getQueueSnapshot();
        expect(
          tasks,
          hasLength(entry == 'selection' ? 2 : 1),
          reason: tester
              .widgetList<Text>(find.byType(Text))
              .map((t) => t.data)
              .join(' / '),
        );
        expect(
          tasks.every((t) => t.videoPath.startsWith('cloud-drive:')),
          isTrue,
        );
        expect(tasks.every((t) => !t.isStarted), isTrue);
        expect(library.storageVideos, hasLength(tasks.length));
        expect(
          tasks.every((t) => library.getVideo(t.videoId!) != null),
          isTrue,
        );
        expect(runtime.launch.playlist.playlist, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      } finally {
        manager.dispose();
      }
    });
  }

  for (final list in [false, true]) {
    for (final placement in [
      ImportCardPlacement.libraryRoot,
      ImportCardPlacement.currentFolder,
      ImportCardPlacement.sourceFolder,
      ImportCardPlacement.fixedFolder,
    ]) {
      scenario(
        'single ${list ? 'list' : 'grid'} card obeys $placement without asking',
        (tester) async {
          settings.mediaLibraryViewMode = list ? 1 : 0;
          final origin = await createFolder(tester, '发起位置');
          final inbox = await createFolder(tester, '收件箱');
          await settings.saveImportPlacement(
            placement,
            ImportPlacementRules(fixedFolderId: inbox.id),
          );
          await pumpBrowser(tester, openedFrom: origin.id);
          await openMenu(tester, video);
          expect(find.text('加入媒体库'), findsOneWidget);
          expect(find.text('选择入库位置…'), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('cloud-add-to-library')));
          await finishImport(tester);

          expect(find.byType(LibraryFolderPicker), findsNothing);
          final item = imported(cloudDriveEntryKey(video)).single;
          final expected = switch (placement) {
            ImportCardPlacement.currentFolder => origin.id,
            ImportCardPlacement.fixedFolder => inbox.id,
            ImportCardPlacement.sourceFolder => settings.importSourceFolderId(
              ImportCardFeature.cloudDrive,
            ),
            _ => null,
          };
          expect(item.parentId, expected);
          if (placement == ImportCardPlacement.sourceFolder) {
            expect(expected, isNotNull);
            expect(library.getCollection(expected!)!.name, '网盘');
          }
          expect(provider.calls, hasLength(1));
          expect(runtime.launch.playlist.playlist, isEmpty);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        },
      );
    }
  }

  scenario('cloud override applies to the entire selected batch', (
    tester,
  ) async {
    final origin = await createFolder(tester, '发起位置');
    final inbox = await createFolder(tester, '网盘收件箱');
    await settings.saveImportPlacement(
      ImportCardPlacement.libraryRoot,
      ImportPlacementRules(
        overrides: {
          ImportCardFeature.cloudDrive.storageValue: ImportPlacementRule(
            ImportCardPlacement.fixedFolder,
            folderId: inbox.id,
          ),
        },
      ),
    );
    await pumpBrowser(tester, openedFrom: origin.id);
    await selectMedia(tester);
    await tester.tap(
      find.byKey(const ValueKey('cloud-selection-add-to-library')),
    );
    await finishImport(tester);
    expect(find.byType(LibraryFolderPicker), findsNothing);
    expect(imported(cloudDriveEntryKey(video)).single.parentId, inbox.id);
    expect(imported(cloudDriveEntryKey(audio)).single.parentId, inbox.id);
    expect(imported(cloudDriveEntryKey(audio)).single.type, MediaType.audio);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  scenario(
    'ask every time asks once for the batch and cancellation keeps selection',
    (tester) async {
      final target = await createFolder(tester, '本次目标');
      await settings.saveImportPlacement(
        ImportCardPlacement.libraryRoot,
        ImportPlacementRules(
          overrides: {
            ImportCardFeature.cloudDrive.storageValue:
                const ImportPlacementRule(ImportCardPlacement.askEveryTime),
          },
        ),
      );
      await pumpBrowser(tester, openedFrom: target.id);
      await selectMedia(tester);
      final add = find.byKey(const ValueKey('cloud-selection-add-to-library'));
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.byType(LibraryFolderPicker), findsOneWidget);
      Navigator.of(tester.element(find.byType(LibraryFolderPicker))).pop();
      await tester.pumpAndSettle();
      expect(find.text('已选 2 项'), findsOneWidget);
      expect(imported(cloudDriveEntryKey(video)), isEmpty);
      await tester.tap(add);
      await tester.pumpAndSettle();
      await tester.tap(find.text('加入到这里'));
      await finishImport(tester);
      expect(find.byType(LibraryFolderPicker), findsNothing);
      expect(imported(cloudDriveEntryKey(video)).single.parentId, target.id);
      expect(imported(cloudDriveEntryKey(audio)).single.parentId, target.id);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  scenario(
    'manual root placement beats source folders without changing settings',
    (tester) async {
      await settings.saveImportPlacement(
        ImportCardPlacement.sourceFolder,
        ImportPlacementRules(),
      );
      await pumpBrowser(tester);
      await openMenu(tester, video);
      await tester.tap(
        find.byKey(const ValueKey('cloud-choose-library-location')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(LibraryFolderPicker), findsOneWidget);
      Navigator.of(tester.element(find.byType(LibraryFolderPicker))).pop();
      await tester.pumpAndSettle();
      expect(
        settings.importSourceFolderId(ImportCardFeature.cloudDrive),
        isNull,
      );
      expect(
        library.storageCollections.where((folder) => folder.name == '网盘'),
        isEmpty,
      );
      await openMenu(tester, video);
      await tester.tap(
        find.byKey(const ValueKey('cloud-choose-library-location')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('加入到这里'));
      await finishImport(tester);
      expect(imported(cloudDriveEntryKey(video)).single.parentId, isNull);
      expect(
        settings.importCardPlacementMode,
        ImportCardPlacement.sourceFolder,
      );
      expect(
        settings.importSourceFolderId(ImportCardFeature.cloudDrive),
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  scenario(
    'folder keeps hierarchy and the captured target while settings change',
    (tester) async {
      final target = await createFolder(tester, '原目标');
      final gate = provider.gates['/course|'] = Completer<void>();
      await settings.saveImportPlacement(
        ImportCardPlacement.currentFolder,
        ImportPlacementRules(),
      );
      await pumpBrowser(tester, openedFrom: target.id);
      await openMenu(tester, folder);
      await tester.tap(find.byKey(const ValueKey('cloud-add-to-library')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(provider.calls.any((call) => call.parent == '/course'), isTrue);
      await settings.saveImportPlacement(
        ImportCardPlacement.libraryRoot,
        ImportPlacementRules(),
      );
      gate.complete();
      await finishImport(tester);
      final importedFolder = library.storageCollections.singleWhere(
        (candidate) =>
            candidate.sourceRef?.cloudDrive?.sourceKey ==
            cloudDriveEntryKey(folder),
      );
      expect(importedFolder.parentId, target.id);
      expect(
        imported(cloudDriveEntryKey(inside)).single.parentId,
        importedFolder.id,
      );
      await openMenu(tester, folder);
      await tester.tap(find.byKey(const ValueKey('cloud-view-in-library')));
      await tester.pumpAndSettle();
      expect(
        CloudDriveNavigation.request.value!.targetFolderId,
        importedFolder.id,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  scenario(
    'repeated addition reuses the card and can locate it in the library',
    (tester) async {
      await pumpBrowser(tester);
      await openMenu(tester, video);
      await tester.tap(find.byKey(const ValueKey('cloud-add-to-library')));
      await finishImport(tester);
      final item = imported(cloudDriveEntryKey(video)).single;
      item.title = '我的学习标题';
      item.lastPositionMs = 42000;
      await openMenu(tester, video);
      expect(find.text('在媒体库中查看'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('cloud-add-to-library')));
      await finishImport(tester);
      expect(imported(cloudDriveEntryKey(video)).single.id, item.id);
      expect(item.title, '我的学习标题');
      expect(item.lastPositionMs, 42000);
      await openMenu(tester, video);
      await tester.tap(find.byKey(const ValueKey('cloud-view-in-library')));
      await tester.pumpAndSettle();
      expect(CloudDriveNavigation.request.value!.showImportedFolder, isTrue);
      expect(CloudDriveNavigation.request.value!.targetFolderId, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  scenario('direct cloud tab entry clears an earlier library folder context', (
    tester,
  ) async {
    final target = await createFolder(tester, '原文件夹');
    final previousRuntime = CloudDriveRuntime.instance;
    CloudDriveRuntime.instance = runtime;
    try {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: settings),
            ChangeNotifierProvider.value(value: library),
            ChangeNotifierProvider.value(value: runtime.launch.playback),
            ChangeNotifierProvider.value(value: BatchImportService()),
          ],
          child: const MaterialApp(home: MediaLibraryShell(home: HomeScreen())),
        ),
      );
      await tester.pumpAndSettle();
      CloudDriveNavigation.open(targetFolderId: target.id);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CloudDriveScreen>(find.byType(CloudDriveScreen))
            .targetFolderId,
        target.id,
      );
      final switcher = tester.widget<MediaLibraryEntrySwitcher>(
        find.byType(MediaLibraryEntrySwitcher),
      );
      switcher.onSelected(MediaLibraryRootEntry.folders);
      await tester.pumpAndSettle();
      tester
          .widget<MediaLibraryEntrySwitcher>(
            find.byType(MediaLibraryEntrySwitcher),
          )
          .onSelected(MediaLibraryRootEntry.cloudDrive);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CloudDriveScreen>(find.byType(CloudDriveScreen))
            .targetFolderId,
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    } finally {
      CloudDriveRuntime.instance = previousRuntime;
    }
  });

  testWidgets(
    'cloud library actions share placement rules across single and batch entry',
    (tester) async {
      // LibraryService owns a process-wide serial save queue. Keep its mutation
      // scenarios in one fake-async zone so completed futures remain drainable.
      for (final scenario in scenarios) {
        debugPrint('Scenario: ${scenario.name}');
        provider.calls.clear();
        library.resetLibraryForTesting();
        library.writeLibrarySnapshotOverrideForTesting = () async {};
        settings.mediaLibraryViewMode = 0;
        await settings.updateSetting(ImportSourceFolders.idsKey, '{}');
        await settings.saveImportPlacement(
          ImportCardPlacement.libraryRoot,
          ImportPlacementRules(),
        );
        await scenario.run(tester);
        await tester.pumpAndSettle();
      }
    },
  );

  for (final size in [
    const Size(320, 640),
    const Size(640, 320),
    const Size(1280, 800),
  ]) {
    testWidgets(
      'selection keeps a labelled library action at $size with large text',
      (tester) async {
        settings.mediaLibraryViewMode = 1;
        await pumpBrowser(tester, size: size, textScale: 1.5);
        await selectMedia(tester);
        final add = find.byKey(
          const ValueKey('cloud-selection-add-to-library'),
        );
        expect(add.hitTestable(), findsOneWidget);
        expect(find.text('加入媒体库'), findsOneWidget);
        expect(tester.getRect(add).right, lessThanOrEqualTo(size.width));
        await tester.tap(find.byKey(const ValueKey('cloud-selection-more')));
        await tester.pumpAndSettle();
        expect(find.text('选择入库位置…'), findsOneWidget);
        await tester.tap(find.text('选择入库位置…'));
        await tester.pumpAndSettle();
        expect(find.byType(LibraryFolderPicker), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
}
