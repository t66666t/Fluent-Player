import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/external_ai/external_ai_controller.dart';
import 'package:video_player_app/features/external_ai/external_ai_screen.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/screens/collection_screen.dart';
import 'package:video_player_app/screens/home_screen.dart';
import 'package:video_player_app/services/batch_import_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';

import 'test_dir_cleanup.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform originalPaths;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('external_ai_keyboard_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
  });

  tearDownAll(() async {
    await ExternalAiController.instance.shutdown();
    PathProviderPlatform.instance = originalPaths;
    await deleteTestTempDir(root);
  });

  for (final home in [true, false]) {
    testWidgets('${home ? 'home' : 'collection'} Q opens AI, Esc returns, '
        'and input, dialogs and selection keep their keys', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({'onboarding.handled.v1': true});
      final settings = SettingsService()..resetForTest();
      await settings.init();
      final library = LibraryService()..resetLibraryForTesting();
      library.writeLibrarySnapshotOverrideForTesting = () async {};
      library.seedCollectionForTesting(
        VideoCollection(id: 'folder', name: 'folder', createTime: 1),
      );
      final playback = MediaPlaybackService();
      await playback.stop();
      await tester.runAsync(
        () => ExternalAiController.instance.initialize(library),
      );
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: settings),
            ChangeNotifierProvider.value(value: library),
            ChangeNotifierProvider.value(value: playback),
            ChangeNotifierProvider.value(value: BatchImportService()),
          ],
          child: MaterialApp(
            navigatorKey: navigator,
            home: MediaLibraryShell(
              home: home
                  ? const HomeScreen(returnToSearchResults: true)
                  : const CollectionScreen(collectionId: 'folder'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyQ);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyQ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyQ);
      await tester.pumpAndSettle();
      expect(find.byType(ExternalAiScreen), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
      await tester.pumpAndSettle();
      expect(find.byType(ExternalAiScreen), findsOneWidget);

      unawaited(
        showDialog<void>(
          context: tester.element(find.byType(ExternalAiScreen)),
          builder: (_) =>
              const AlertDialog(content: TextField(autofocus: true)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'q');
      await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
      await tester.pump();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.byType(ExternalAiScreen, skipOffstage: false),
        findsOneWidget,
      );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byType(ExternalAiScreen), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(ExternalAiScreen), findsNothing);
      expect(find.byType(MediaLibraryShell), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
      await tester.pumpAndSettle();
      expect(find.byType(ExternalAiScreen), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
      await tester.pumpAndSettle();
      expect(find.byType(ExternalAiScreen), findsOneWidget);
        settings.isFullScreen = true;
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(ExternalAiScreen), findsNothing);
        expect(settings.isFullScreen, isTrue);
        settings.isFullScreen = false;
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await playback.stop();
      library.resetLibraryForTesting();
      settings.resetForTest();
    });
  }
}
