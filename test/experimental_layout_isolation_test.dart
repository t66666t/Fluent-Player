import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/media_library_root_entry.dart';
import 'package:video_player_app/screens/home_screen.dart';
import 'package:video_player_app/services/batch_import_service.dart';
import 'package:video_player_app/services/experimental_layout.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/experimental_home_frame.dart';
import 'package:video_player_app/widgets/media_library_root_surface_host.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';
import 'package:video_player_app/widgets/video_action_buttons.dart';

void main() {
  testWidgets('original layout survives empty pages and experiment toggles', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await ExperimentalLayout.instance.initialize();
    addTearDown(tester.view.reset);
    for (final size in [const Size(390, 844), const Size(1440, 900)]) {
      SharedPreferences.setMockInitialValues({});
      await ExperimentalLayout.instance.select(false);
      final settings = SettingsService()..resetForTest();
      await settings.init();
      final library = LibraryService()..resetLibraryForTesting();
      library.writeLibrarySnapshotOverrideForTesting = () async {};
      final playback = MediaPlaybackService();
      await playback.stop();
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: settings),
            ChangeNotifierProvider.value(value: library),
            ChangeNotifierProvider.value(value: playback),
            ChangeNotifierProvider.value(value: BatchImportService()),
          ],
          child: MaterialApp(
            theme: ThemeData.dark(useMaterial3: true),
            home: const MediaLibraryShell(home: HomeScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final host = find.byType(MediaLibraryRootSurfaceHost);
      void expectOriginal(MediaLibraryRootEntry entry) {
        expect(find.byType(ExperimentalHomeFrame), findsNothing);
        expect(find.byType(VideoActionButtons), findsOneWidget);
        expect(
          find.byKey(const ValueKey('action-button-disc-toggle')),
          findsOneWidget,
        );
        expect(
          tester.widget<MediaLibraryRootSurfaceHost>(host).displayedEntry,
          entry,
        );
        expect(tester.takeException(), isNull);
      }

      expectOriginal(MediaLibraryRootEntry.folders);
      final collapsed = settings.isActionButtonsCollapsed;
      await tester.tap(find.byKey(const ValueKey('action-button-disc-toggle')));
      await tester.pumpAndSettle();
      expect(settings.isActionButtonsCollapsed, !collapsed);
      if (!settings.isActionButtonsCollapsed) {
        await tester.tap(
          find.byKey(const ValueKey('action-button-disc-toggle')),
        );
        await tester.pumpAndSettle();
      }

      if (size.width < 600) {
        await tester.tap(find.byTooltip('更多'));
        await tester.pumpAndSettle();
        expect(find.text('导入视频或音频'), findsNothing);
        expect(find.text('新建合集').hitTestable(), findsNothing);
        await tester.tapAt(const Offset(8, 300));
        await tester.pumpAndSettle();
      }

      // Exercise gestures through the real empty folder surface, not just
      // the isolated pager: the regression removed the pager on this branch.
      await tester.fling(host, Offset(size.width * .6, 0), 1800);
      await tester.pumpAndSettle();
      expectOriginal(MediaLibraryRootEntry.continueLearning);
      await tester.fling(host, Offset(-size.width * .6, 0), 1800);
      await tester.pumpAndSettle();
      expectOriginal(MediaLibraryRootEntry.folders);
      await tester.fling(host, Offset(-size.width * .6, 0), 1800);
      await tester.pumpAndSettle();
      expectOriginal(MediaLibraryRootEntry.recent);

      await ExperimentalLayout.instance.select(true);
      await tester.pumpAndSettle();
      expect(find.byType(ExperimentalHomeFrame), findsOneWidget);
      expect(
        find.byType(VideoActionButtons),
        size.width >= 900 ? findsNothing : findsOneWidget,
      );
      await ExperimentalLayout.instance.select(false);
      await tester.pumpAndSettle();
      expectOriginal(MediaLibraryRootEntry.recent);
      await tester.pumpWidget(const SizedBox());
      await playback.stop();
      library.resetLibraryForTesting();
      settings.resetForTest();
      ExperimentalLayout.instance.value = false;
    }
  });
}
