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
import 'package:video_player_app/services/thumbnail_cache_service.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:video_player_app/widgets/media_library_folder_route.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';

class _ObservedLibrary extends ChangeNotifier implements LibraryService {
  _ObservedLibrary(this.isSettled);
  final backing = LibraryService()..resetLibraryForTesting();
  final bool Function() isSettled;
  int reads = 0, settledReads = 0;
  @override
  get importProgress => backing.importProgress;
  @override
  get activityProjection => backing.activityProjection;
  final folder = VideoCollection(
    id: 'folder',
    name: '目录',
    createTime: 1,
    childrenIds: ['visible'],
  );
  final item = VideoItem(
    id: 'visible',
    path: '/missing/video.mp4',
    title: '已缓存的可见项目',
    parentId: 'folder',
    durationMs: 1000,
    lastUpdated: 1,
    hasProbedChapters: true,
  );
  @override
  VideoCollection? getCollection(String id) => id == folder.id ? folder : null;
  @override
  VideoItem? getVideo(String id) => id == item.id ? item : null;
  @override
  List<dynamic> getContents(String? parentId) {
    reads++;
    if (isSettled()) settledReads++;
    return parentId == folder.id ? [item] : [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final reverseEarly in [false, true]) {
    testWidgets(
      'folder content is immediate; extra preparation ${reverseEarly ? 'is cancelled on Back' : 'waits for entry'}',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({});
        final settings = SettingsService()..resetForTest();
        await settings.init();
        final playback = MediaPlaybackService();
        await playback.stop();
        PageRoute<void>? route;
        final library = _ObservedLibrary(
          () => route?.animation?.isCompleted == true && route!.isCurrent,
        );
        final cache = ThumbnailCacheService();
        cache.setMissingThumbnailResolver((_) async => null);
        addTearDown(() async {
          cache.setMissingThumbnailResolver(null);
          library.dispose();
          settings.resetForTest();
          await playback.stop();
        });
        final key = GlobalKey();
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<SettingsService>.value(value: settings),
              ChangeNotifierProvider<LibraryService>.value(value: library),
              ChangeNotifierProvider<MediaPlaybackService>.value(
                value: playback,
              ),
              ChangeNotifierProvider<BatchImportService>.value(
                value: BatchImportService(),
              ),
            ],
            child: MaterialApp(
              theme: ThemeData(pageTransitionsTheme: appPageTransitionsTheme),
              home: MediaLibraryShell(
                home: Scaffold(key: key, body: const Text('root')),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final navigator = Navigator.of(key.currentContext!);
        route = MediaLibraryFolderRoute<void>(
          builder: (_) => const CollectionScreen(collectionId: 'folder'),
        );
        navigator.push(route);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        expect(find.text('已缓存的可见项目'), findsOneWidget);
        expect(
          library.reads,
          1,
          reason:
              'only the visible page query runs before motion; no duplicate preload scan',
        );
        expect(library.settledReads, 0);
        if (reverseEarly) navigator.pop();
        await tester.pumpAndSettle();
        expect(
          library.settledReads > 0,
          !reverseEarly,
          reason:
              'retain optional preparation after entry and cancel it on an interrupted visit',
        );
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
    );
  }
}
