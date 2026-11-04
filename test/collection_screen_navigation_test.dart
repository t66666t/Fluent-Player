import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/screens/collection_screen.dart';
import 'package:video_player_app/services/batch_import_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/media_library_folder_walk.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final size in [
    const Size(400, 800),
    const Size(800, 1200),
    const Size(1200, 800),
  ]) {
    for (final viewMode in [0, 1]) {
      for (final proportional in (viewMode == 0 ? [false, true] : [false])) {
        testWidgets(
          'folder opens and refreshes at $size, mode $viewMode, proportional $proportional',
          (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = size;
            addTearDown(tester.view.reset);
            SharedPreferences.setMockInitialValues(<String, Object>{
              'mediaLibraryReadableCardDefaults': proportional,
            });
            final settings = SettingsService()..resetForTest();
            await settings.init();
            settings.mediaLibraryViewMode = viewMode;
            final library = LibraryService()..resetLibraryForTesting();
            library.writeLibrarySnapshotOverrideForTesting = () async {};
            final folder = VideoCollection(
              id: 'course',
              name: 'Course',
              createTime: 1,
              childrenIds: ['episode one'],
            );
            library.seedCollectionForTesting(folder);
            VideoItem clip(String id) => VideoItem(
              id: id,
              path: '/missing/$id.mp4',
              title: id,
              parentId: 'course',
              durationMs: 120000,
              lastUpdated: 1,
              hasProbedChapters: true,
            );
            library.seedVideoForTesting(clip('episode one'));
            final playback = MediaPlaybackService();
            await playback.stop();
            addTearDown(() async {
              await playback.stop();
              library.resetLibraryForTesting();
              settings.resetForTest();
            });

            await tester.pumpWidget(
              MultiProvider(
                providers: [
                  ChangeNotifierProvider.value(value: settings),
                  ChangeNotifierProvider.value(value: library),
                  ChangeNotifierProvider.value(value: playback),
                  ChangeNotifierProvider.value(value: BatchImportService()),
                ],
                child: MaterialApp(
                  theme: ThemeData.dark(),
                  home: const CollectionScreen(collectionId: 'course'),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(find.text('episode one'), findsOneWidget);

            library.seedVideoForTesting(clip('episode two'));
            folder.childrenIds.add('episode two');
            library.notifyListeners();
            playback.publishRestoredSessionPreview(
              clip('episode one'),
              const Duration(seconds: 10),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(find.text('episode two'), findsOneWidget);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }

  testWidgets(
    'remembering a folder still applies the persisted descendant view locally',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'mediaLibraryLastFolderId': 'previous-folder',
        'mediaLibraryLastFolderIncludeDescendants': true,
      });
      MediaLibraryFolderBrowseMemory.resetForTest();
      final settings = SettingsService()..resetForTest();
      await settings.init();
      final library = LibraryService()..resetLibraryForTesting();
      library.writeLibrarySnapshotOverrideForTesting = () async {};
      library.seedCollectionForTesting(
        VideoCollection(
          id: 'parent',
          name: 'Parent',
          createTime: 1,
          childrenIds: ['child'],
        ),
      );
      library.seedCollectionForTesting(
        VideoCollection(
          id: 'child',
          name: 'Child',
          parentId: 'parent',
          createTime: 1,
          childrenIds: ['nested-video'],
        ),
      );
      library.seedVideoForTesting(
        VideoItem(
          id: 'nested-video',
          path: '/missing/nested.mp4',
          title: 'Nested video',
          parentId: 'child',
          durationMs: 120000,
          lastUpdated: 1,
          hasProbedChapters: true,
        ),
      );
      final playback = MediaPlaybackService();
      await playback.stop();
      var notifications = 0;
      void changed() => notifications++;
      settings.addListener(changed);
      addTearDown(() async {
        settings.removeListener(changed);
        await playback.stop();
        library.resetLibraryForTesting();
        settings.resetForTest();
        MediaLibraryFolderBrowseMemory.resetForTest();
      });
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: settings),
            ChangeNotifierProvider.value(value: library),
            ChangeNotifierProvider.value(value: playback),
            ChangeNotifierProvider.value(value: BatchImportService()),
          ],
          child: const MaterialApp(
            home: CollectionScreen(collectionId: 'parent'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(settings.mediaLibraryLastFolderId, 'parent');
      expect(find.text('Nested video'), findsOneWidget);
      expect(notifications, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
