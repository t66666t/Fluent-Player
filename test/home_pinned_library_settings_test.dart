import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/screens/home_screen.dart';
import 'package:video_player_app/services/batch_import_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_compact_app_bar.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpHome(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = SettingsService()..resetForTest();
    await settings.init();
    addTearDown(settings.resetForTest);
    final library = LibraryService()..resetLibraryForTesting();
    library.writeLibrarySnapshotOverrideForTesting = () async {};
    final playback = MediaPlaybackService();
    await playback.stop();
    addTearDown(() async {
      await playback.stop();
      library.resetLibraryForTesting();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider.value(value: library),
          ChangeNotifierProvider.value(value: playback),
          ChangeNotifierProvider.value(value: BatchImportService()),
        ],
        child: const MaterialApp(home: MediaLibraryShell(home: HomeScreen())),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder appBarIcon(IconData icon) =>
      find.descendant(of: find.byType(AppBar), matching: find.byIcon(icon));

  Rect buttonRect(WidgetTester tester, IconData icon) {
    expect(appBarIcon(icon), findsOneWidget);
    return tester.getRect(
      find.ancestor(
        of: appBarIcon(icon),
        matching: find.byType(MediaLibraryCompactIconButton),
      ),
    );
  }

  for (final size in const [Size(320, 640), Size(390, 844)]) {
    testWidgets('竖屏首页把媒体库设置固定在搜索和更多之间 $size', (tester) async {
      await pumpHome(tester, size);

      final search = buttonRect(tester, Icons.search_rounded);
      final settings = buttonRect(tester, Icons.settings_outlined);
      final more = tester.getRect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byType(MediaLibraryCompactMoreButton),
        ),
      );

      expect(search.width, mediaLibraryHomePinnedActionWidth);
      expect(settings.width, mediaLibraryHomePinnedActionWidth);
      expect(more.width, mediaLibraryHomePinnedActionWidth);
      expect(settings.left, closeTo(search.right, 0.5));
      expect(more.left, closeTo(settings.right, 0.5));
      expect(more.right - search.left, closeTo(34 * 3, 0.5));

      final searchIcon = tester.getRect(appBarIcon(Icons.search_rounded));
      final settingsIcon = tester.getRect(appBarIcon(Icons.settings_outlined));
      final moreIcon = tester.getRect(appBarIcon(Icons.more_horiz_rounded));
      expect(settingsIcon.left - searchIcon.right, closeTo(14, 1.5));
      expect(moreIcon.left - settingsIcon.right, closeTo(14, 1.5));
      expect(searchIcon.center.dx, lessThan(settingsIcon.center.dx));
      expect(settingsIcon.center.dx, lessThan(moreIcon.center.dx));

      await tester.tap(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byTooltip('更多'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('媒体库设置'), findsNothing);
      expect(find.textContaining('回收站'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
