import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/media_library_root_entry.dart';
import 'package:video_player_app/models/media_library_root_entry_order.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/app_web_navigation.dart';
import 'package:video_player_app/services/bilibili/bilibili_video_links.dart';
import 'package:video_player_app/services/clipboard_detection_routes.dart';
import 'package:video_player_app/services/media_library_navigation.dart';
import 'package:video_player_app/services/playback_navigation_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/app_clipboard_listener.dart';
import 'package:video_player_app/widgets/clipboard_detection_scope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService()..resetForTest();
    await settings.init();
  });
  tearDown(() {
    SettingsService().resetForTest();
    AppWebNavigation.rootOpenerForTesting = null;
  });

  VideoItem item(String path, {MediaSourceKind? kind}) => VideoItem(
    id: 'saved',
    path: path,
    title: 'Local lesson',
    durationMs: 60000,
    lastUpdated: 0,
    sourceRef: kind == null
        ? null
        : MediaSourceRef(kind: kind, value: 'historical-source'),
  );

  for (final path in [
    'https://www.youtube.com/watch?v=example',
    'https://example.test/media.mp4',
    'bilibili://stream/BV1xx411c7mD?cid=1',
    'cloud-drive:legacy',
    'podcast:legacy',
  ]) {
    test('old remote entry cannot create a player or browser: $path', () async {
      var opened = 0;
      AppWebNavigation.rootOpenerForTesting = (_, {title}) async {
        opened++;
        return true;
      };
      final video = item(path);
      final navigation = PlaybackNavigationService.instance;
      expect(
        () => navigation.buildPortraitRoute(video),
        throwsUnsupportedError,
      );
      expect(
        () => navigation.buildNotificationPlaybackRoute(video),
        throwsUnsupportedError,
      );
      expect(
        () => PlaybackNavigationService.buildPlaybackEntryRoute(video),
        throwsUnsupportedError,
      );
      expect(
        () => AppWebNavigation.route(Uri.https('example.test', '/')),
        throwsUnsupportedError,
      );
      expect(
        await BilibiliVideoLinks.tryParse('BV1xx411c7mD')!.open(),
        BilibiliVideoOpenResult.failed,
      );
      expect(opened, 0);
    });
  }

  for (final kind in MediaSourceKind.values) {
    test('local file with $kind history uses the native entry route', () {
      final route = PlaybackNavigationService.buildPlaybackEntryRoute(
        item('lesson.mp4', kind: kind),
      );
      expect(
        route.settings.name,
        isIn([
          PlaybackNavigationService.portraitRouteName,
          PlaybackNavigationService.landscapeRouteName,
        ]),
      );
      expect(route.settings.arguments, 'saved');
    });
  }

  for (final retired in MediaLibraryRootEntry.values.where(
    (e) => !e.isAvailable,
  )) {
    test('saved $retired selection and startup preference stay local', () {
      for (final restoreLastPage in [true, false]) {
        final plan = MediaLibraryNavigation.plan(
          libraryInitialized: true,
          hasExistingLibraryContent: true,
          storedEntry: retired.storageValue,
          userChosen: true,
          lastFolderId: '',
          availableEntries: MediaLibraryRootEntry.values.toSet(),
          revealItemId: null,
          returnToSearchResults: false,
          isActiveFolder: (_) => false,
          parentIdOf: (_) => null,
          restoreLastPage: restoreLastPage,
          startupEntry: retired.storageValue,
        );
        expect(plan.preferredEntry, MediaLibraryRootEntry.folders);
        expect(plan.displayedEntry, MediaLibraryRootEntry.folders);
      }
    });
  }

  test('podcast startup and saved root selection remain reachable', () {
    for (final restoreLastPage in [true, false]) {
      final plan = MediaLibraryNavigation.plan(
        libraryInitialized: true,
        hasExistingLibraryContent: true,
        storedEntry: MediaLibraryRootEntry.podcasts.storageValue,
        userChosen: true,
        lastFolderId: '',
        availableEntries: MediaLibraryRootEntryOrder.defaults.toSet(),
        revealItemId: null,
        returnToSearchResults: false,
        isActiveFolder: (_) => false,
        parentIdOf: (_) => null,
        restoreLastPage: restoreLastPage,
        startupEntry: MediaLibraryRootEntry.podcasts.storageValue,
      );
      expect(plan.preferredEntry, MediaLibraryRootEntry.podcasts);
      expect(plan.displayedEntry, MediaLibraryRootEntry.podcasts);
    }
  });

  testWidgets('startup, focus and URL drops never inspect website clipboard', (
    tester,
  ) async {
    var clipboardReads = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          clipboardReads++;
          return {'text': 'https://www.youtube.com/watch?v=example'};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final routes = ClipboardDetectionRoutes();
    final navigator = GlobalKey<NavigatorState>();
    ClipboardDetectionScope? scope;
    await tester.pumpWidget(
      AppClipboardListener(
        navigatorKey: navigator,
        routes: routes,
        child: MaterialApp(
          navigatorKey: navigator,
          navigatorObservers: [routes.rootObserver],
          home: Builder(
            builder: (context) {
              scope = ClipboardDetectionScope.maybeOf(context);
              return const Scaffold(body: Text('Local library'));
            },
          ),
        ),
      ),
    );
    await scope!.completeStartup();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(scope!.acceptDroppedLinks!('https://example.test/', []), isFalse);
    expect(scope!.inspectClipboard, isNull);
    await tester.pumpAndSettle();
    expect(clipboardReads, 0);
    expect(find.text('Local library'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    routes.dispose();
  });
}
