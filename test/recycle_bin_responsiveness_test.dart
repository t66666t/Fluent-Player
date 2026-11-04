import 'dart:async';

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
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/widgets/media_library_selection_bottom_bar.dart';
import 'package:video_player_app/widgets/media_library_selection_drop_targets.dart';

void main() {
  for (final size in [const Size(400, 800), const Size(1200, 800)]) {
    for (final viewMode in [0, 1]) {
      testWidgets('selection exits before saving at $size, mode $viewMode', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final settings = SettingsService()..resetForTest();
        await settings.init();
        settings.mediaLibraryViewMode = viewMode;
        final library = LibraryService()..resetLibraryForTesting();
        final release = Completer<void>();
        var writes = 0;
        library.writeLibrarySnapshotOverrideForTesting = () {
          writes++;
          return release.future;
        };
        library.seedCollectionForTesting(
          VideoCollection(
            id: 'course',
            name: 'Course',
            createTime: 1,
            childrenIds: ['first', 'second'],
          ),
        );
        for (final id in ['first', 'second']) {
          library.seedVideoForTesting(
            VideoItem(
              id: id,
              path: '/missing/$id.mp4',
              title: id,
              parentId: 'course',
              durationMs: 120000,
              lastUpdated: 1,
              hasProbedChapters: true,
            ),
          );
        }
        final playback = MediaPlaybackService();
        await playback.stop();
        addTearDown(() async {
          if (!release.isCompleted) release.complete();
          await AppToast.dismiss(immediate: true);
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
              home: const CollectionScreen(collectionId: 'course'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.longPress(find.text('first'));
        await tester.pumpAndSettle();
        expect(find.byType(MediaLibrarySelectionBottomBar), findsOneWidget);

        // Keep the singleton save queue in the real async zone across tests.
        await tester.runAsync(
          () => tester.tap(find.byKey(mediaLibraryMoveToRecycleDropKey)),
        );
        await tester.pump();

        expect(release.isCompleted, isFalse);
        expect(writes, 1);
        expect(library.getVideo('first')!.isRecycled, isTrue);
        expect(find.text('first'), findsNothing);
        expect(find.text('second'), findsOneWidget);
        final bar = find.byType(MediaLibrarySelectionBottomBar);
        expect(bar, findsOneWidget);
        expect(
          find.ancestor(
            of: bar,
            matching: find.byWidgetPredicate(
              (widget) => widget is IgnorePointer && widget.ignoring,
            ),
          ),
          findsWidgets,
        );
        expect(find.byKey(mediaLibraryMoveToRecycleDropKey), findsNothing);
        expect(tester.takeException(), isNull);

        await tester.pump(MediaLibrarySelectionBarTransition.duration);
        await tester.pump(const Duration(milliseconds: 16));
        expect(find.byType(MediaLibrarySelectionBottomBar), findsNothing);
        expect(release.isCompleted, isFalse);

        await tester.runAsync(() async {
          release.complete();
          await library.saveLibraryForTesting();
        });
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
