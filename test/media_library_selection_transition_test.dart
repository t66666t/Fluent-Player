import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/library_activity.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/screens/collection_screen.dart';
import 'package:video_player_app/screens/home_screen.dart';
import 'package:video_player_app/services/batch_import_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_selection_bottom_bar.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';
import 'package:video_player_app/widgets/mini_playback_card.dart';
import 'package:video_player_app/widgets/playback_card_layout.dart';

void main() {
  for (final (platform, size, inset) in [
    (TargetPlatform.android, const Size(390, 844), 24.0),
    (TargetPlatform.windows, const Size(1200, 800), 0.0),
  ]) {
    for (final entry in ['folders', 'recent', 'continueLearning', 'folder']) {
      for (final viewMode in [0, 1]) {
        testWidgets(
          '$entry closes selection smoothly on $platform, view $viewMode',
          (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = size;
            tester.view.padding = FakeViewPadding(bottom: inset);
            tester.view.viewPadding = FakeViewPadding(bottom: inset);
            addTearDown(tester.view.reset);
            SharedPreferences.setMockInitialValues(<String, Object>{});
            final settings = SettingsService()..resetForTest();
            await settings.init();
            settings.mediaLibraryViewMode = viewMode;
            settings.mediaLibraryRootEntry = entry;
            settings.mediaLibraryRootEntryUserChosen = true;
            final library = LibraryService()..resetLibraryForTesting();
            library.writeLibrarySnapshotOverrideForTesting = () async {};
            library.seedCollectionForTesting(
              VideoCollection(
                id: 'course',
                name: 'Course',
                createTime: 1,
                childrenIds: ['clip'],
              ),
            );
            library.seedVideoForTesting(
              VideoItem(
                id: 'clip',
                path: '/missing/clip.mp4',
                title: 'Selection clip',
                parentId: 'course',
                durationMs: 120000,
                lastPositionMs: 15000,
                lastUpdated: 1,
                hasProbedChapters: true,
              ),
            );
            if (entry != 'folder') {
              await tester.runAsync(
                () => library.moveItemsToCollection(['clip'], null),
              );
            }
            library.seedMediaActivityForTesting(
              MediaActivityRecord(
                mediaId: 'clip',
                addedAtMs: 50,
                lastPlayedAtMs: 9,
                accumulatedWatchMs: 40000,
              ),
            );
            final playback = MediaPlaybackService();
            await playback.stop();
            playback.publishRestoredSessionPreview(
              VideoItem(
                id: 'playing',
                path: '/missing/playing.mp4',
                title: 'Playback preview',
                durationMs: 120000,
                lastUpdated: 1,
              ),
              const Duration(seconds: 10),
            );
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
                  home: MediaLibraryShell(
                    home: entry == 'folder'
                        ? const CollectionScreen(collectionId: 'course')
                        : const HomeScreen(),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final player = find.byType(MiniPlaybackCard);
            final playerState = tester.state(player);
            final generation = playback.sessionGeneration;
            final restingBottom = tester.getRect(player).bottom;

            await tester.longPress(find.text('Selection clip').hitTestable());
            await tester.pumpAndSettle();
            final bar = find.byType(MediaLibrarySelectionBottomBar);
            final transition = find.byType(MediaLibrarySelectionBarTransition);
            expect(bar, findsOneWidget);
            final selectedBottom = tester.getRect(player).bottom;
            expect(selectedBottom, lessThan(restingBottom));

            final queueHintCount = find.text('加入播放列表').evaluate().length;
            await tester.longPress(
              find.byKey(const ValueKey('selection-add-to-playlist')),
            );
            await tester.pump(const Duration(milliseconds: 200));
            expect(
              find.text('加入播放列表'),
              findsNWidgets(queueHintCount + 1),
            );
            final pageOverlay = Navigator.of(
              tester.element(bar),
            ).overlay!.context.findRenderObject();
            RenderObject? hint = tester.renderObject(
              find.text('加入播放列表').last,
            );
            while (hint != null) {
              expect(hint, isNot(same(pageOverlay)));
              hint = hint.parent;
            }
            expect(tester.state(player), same(playerState));
            expect(playback.sessionGeneration, generation);
            Tooltip.dismissAllToolTips();
            await tester.pump(const Duration(milliseconds: 250));

            await tester.tap(find.byTooltip(RegExp('退出选择')));
            await tester.pump();
            expect(tester.getRect(player).bottom, selectedBottom);
            expect(bar, findsOneWidget);
            await tester.pump(const Duration(milliseconds: 80));
            expect(
              tester.getRect(player).bottom,
              inExclusiveRange(selectedBottom, restingBottom),
            );
            expect(
              tester.getRect(player).bottom,
              closeTo(
                size.height -
                    PlaybackCardOverlayLayout.cardBottomAbove(
                      stableBottomInset: inset,
                      selectionBarHeight: tester.getSize(transition).height,
                    ),
                1,
              ),
            );
            await tester.pumpAndSettle();
            expect(bar, findsNothing);
            expect(tester.getRect(player).bottom, restingBottom);
            expect(tester.state(player), same(playerState));
            expect(playback.sessionGeneration, generation);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
          },
          variant: TargetPlatformVariant({platform}),
        );
      }
    }
  }
}
