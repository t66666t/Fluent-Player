import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/library_activity.dart';
import 'package:video_player_app/models/media_library_root_entry.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/screens/collection_screen.dart';
import 'package:video_player_app/screens/home_screen.dart';
import 'package:video_player_app/services/batch_import_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:video_player_app/widgets/media_library_entry_switcher.dart';
import 'package:video_player_app/widgets/media_library_scroll_viewport.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';

void main() {
  setUpAll(() async {
    for (final name in ['MiSans', 'Noto Sans SC']) {
      final font = FontLoader(name)
        ..addFont(rootBundle.load('assets/fonts/MiSans-Regular.otf'));
      await font.load();
    }
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  testWidgets(
    'real library pages scroll in phone and desktop grids and lists',
    (tester) async {
      for (final size in [
        const Size(320, 568),
        const Size(390, 844),
        const Size(844, 390),
        const Size(1440, 900),
      ]) {
        for (final list in [false, true]) {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          addTearDown(tester.view.reset);
          SharedPreferences.setMockInitialValues({
            'onboarding.handled.v1': true,
          });
          final settings = SettingsService()..resetForTest();
          await settings.init();
          settings.mediaLibraryViewMode = list ? 1 : 0;
          settings.isActionButtonsCollapsed = true;
          final library = LibraryService()..resetLibraryForTesting();
          library.writeLibrarySnapshotOverrideForTesting = () async {};
          final ids = <String>[];
          final folder = VideoCollection(
            id: 'course',
            name: '我的课程',
            createTime: 1,
          );
          for (var i = 0; i < 160; i++) {
            final id = 'lesson-$i';
            ids.add(id);
            library.seedVideoForTesting(
              VideoItem(
                id: id,
                parentId: 'seed',
                path: '/missing/$id.mp4',
                title: '第 ${i + 1} 课 · 观察与思考',
                durationMs: 600000,
                lastPositionMs: 120000,
                lastUpdated: i + 1,
                hasProbedChapters: true,
              ),
            );
            library.seedMediaActivityForTesting(
              MediaActivityRecord(
                mediaId: id,
                addedAtMs: i + 1,
                lastPlayedAtMs: i + 1,
                accumulatedWatchMs: 120000,
              ),
            );
          }
          library.seedPinnedIdsForTesting(ids);
          library.seedCollectionForTesting(folder);
          await library.moveItemsToCollection(ids, null);
          final playback = MediaPlaybackService();
          await playback.stop();
          final capture = GlobalKey();
          Widget app(Widget page) => MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: settings),
              ChangeNotifierProvider.value(value: library),
              ChangeNotifierProvider.value(value: playback),
              ChangeNotifierProvider.value(value: BatchImportService()),
            ],
            child: MaterialApp(
              theme: ThemeData(
                brightness: Brightness.dark,
                fontFamily: 'MiSans',
                scaffoldBackgroundColor: AppTokens.bgBase,
              ),
              builder: (_, child) =>
                  RepaintBoundary(key: capture, child: child!),
              home: MediaLibraryShell(home: page),
            ),
          );
          await tester.pumpWidget(app(const HomeScreen()));
          await tester.pumpAndSettle();
          for (final entry in [
            MediaLibraryRootEntry.folders,
            MediaLibraryRootEntry.recent,
            MediaLibraryRootEntry.continueLearning,
          ]) {
            tester
                .widget<MediaLibraryEntrySwitcher>(
                  find.byType(MediaLibraryEntrySwitcher),
                )
                .onSelected(entry);
            await tester.pumpAndSettle();
            final thumb = find
                .byKey(MediaLibraryScrollViewport.thumbKey)
                .hitTestable();
            expect(thumb, findsOneWidget);
            final viewport = tester.widget<MediaLibraryScrollViewport>(
              find.ancestor(
                of: thumb,
                matching: find.byType(MediaLibraryScrollViewport),
              ),
            );
            final frame = find.ancestor(
              of: thumb,
              matching: find.byType(MediaLibraryScrollViewport),
            );
            final grid = tester.renderObject<RenderSliverGrid>(
              find
                  .descendant(of: frame, matching: find.byType(SliverGrid))
                  .first,
            );
            final cardLeft = grid.firstChild!.localToGlobal(Offset.zero).dx;
            final frameLeft = tester.getTopLeft(frame).dx;
            final edge = cardLeft - frameLeft;
            expect(
              tester.getBottomRight(frame).dx -
                  (cardLeft + grid.constraints.crossAxisExtent),
              closeTo(edge, .01),
            );
            expect(
              edge,
              closeTo(
                size.width < 600
                    ? 12
                    : size.width < 1024
                    ? 16
                    : 20,
                .01,
              ),
            );
            expect(
              tester.getCenter(thumb).dx - frameLeft,
              closeTo(edge / 2, .01),
            );
            expect(
              tester.getTopLeft(find.byType(MediaLibraryEntrySwitcher)).dx,
              closeTo(cardLeft, .01),
            );
            final trailingIcon = find.descendant(
              of: find.byType(AppBar),
              matching: find.byType(Icon),
            ).last;
            expect(
              tester.getBottomRight(trailingIcon).dx,
              closeTo(cardLeft + grid.constraints.crossAxisExtent, .01),
            );
            // The first label has no extra inner padding of its own.
            if (entry == MediaLibraryRootEntry.continueLearning) {
              final label = find.descendant(
                of: find.byType(MediaLibraryEntrySwitcher),
                matching: find.text(
                  MediaLibraryRootEntry.continueLearning.label,
                ),
              );
              expect(tester.getTopLeft(label).dx, closeTo(cardLeft, .01));
            }
            final before = viewport.controller.offset;
            await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
            await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
            await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
            await tester.pumpAndSettle();
            expect(viewport.controller.offset, greaterThan(before));
            final after = viewport.controller.offset;
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
            await tester.pumpAndSettle();
            expect(viewport.controller.offset, lessThan(after));
            final drag = await tester.startGesture(
              tester.getCenter(thumb),
              kind: PointerDeviceKind.mouse,
            );
            await drag.moveBy(const Offset(0, 80));
            await tester.pump();
            await drag.up();
            await tester.pumpAndSettle();
            expect(viewport.controller.offset, greaterThan(after));
            expect(tester.takeException(), isNull);
            await _capture(
              tester,
              capture,
              '${entry.name}-${size.width.toInt()}-${list ? 'list' : 'grid'}',
            );
          }
          // The nested folder uses the same frame and reduced content width.
          await library.moveItemsToCollection(ids, folder.id);
          await tester.pumpWidget(
            app(const CollectionScreen(collectionId: 'course')),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(MediaLibraryScrollViewport.thumbKey).hitTestable(),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await playback.stop();
          await library.saveLibraryForTesting();
          await tester.pumpAndSettle();
          library.resetLibraryForTesting();
          settings.resetForTest();
        }
      }
    },
  );
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  const directory = String.fromEnvironment('LIBRARY_SCROLL_PREVIEW_DIR');
  if (directory.isEmpty) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = boundary.toImageSync();
  await tester.runAsync(() async {
    await Directory(directory).create(recursive: true);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$directory/$name.png').writeAsBytes(png!.buffer.asUint8List());
  });
  image.dispose();
}
