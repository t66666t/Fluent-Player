import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/screens/collection_screen.dart';
import 'package:video_player_app/services/batch_import_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:video_player_app/widgets/media_library_folder_route.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';
import 'package:video_player_app/widgets/route_keyboard_viewport.dart';

typedef _Visit = ({
  String transition,
  int mode,
  int depth,
  String direction,
  int fromUs,
  int toUs,
});

// Freeze the previous folder animation so unrelated changes to the app-wide
// transition cannot silently change the comparison's baseline.
class _PreviousFolderRoute extends AppMaterialPageRoute<void> {
  _PreviousFolderRoute({required super.builder});

  static const _zoom = ZoomPageTransitionsBuilder(
    allowEnterRouteSnapshotting: false,
  );

  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 300);

  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      _zoom.delegatedTransition;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => RouteKeyboardViewport(
    child: _zoom.buildTransitions(
      this,
      context,
      animation,
      secondaryAnimation,
      child,
    ),
  );
}

/// Real CollectionScreen grids/lists inside the real library shell, with
/// already-loaded covers. The initial route represents the outermost level;
/// every measured child uses the same folder route factory as HomeScreen.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'native root and nested folder frame comparison with cached covers',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService()..resetForTest();
      await settings.init();
      final library = LibraryService()..resetLibraryForTesting();
      library.writeLibrarySnapshotOverrideForTesting = () async {};
      final playback = MediaPlaybackService();
      await playback.stop();
      final directory = await Directory.systemTemp.createTemp(
        'folder_route_profile_',
      );
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 400, 300),
        Paint()
          ..shader = const LinearGradient(
            colors: [Colors.indigo, Colors.teal, Colors.orange],
          ).createShader(const Rect.fromLTWH(0, 0, 400, 300)),
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(400, 300);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final cover = File('${directory.path}/cover.png');
      await cover.writeAsBytes(bytes!.buffer.asUint8List());
      picture.dispose();
      image.dispose();
      for (var level = 0; level < 3; level++) {
        final ids = <String>[];
        if (level < 2) ids.add('level-${level + 1}');
        for (var i = 0; i < 400; i++) {
          final id = 'level-$level-item-$i';
          ids.add(id);
          library.seedCollectionForTesting(
            VideoCollection(
              id: id,
              name: 'Cached folder $i',
              createTime: 1,
              parentId: 'level-$level',
              thumbnailPath: cover.path,
            ),
          );
        }
        library.seedCollectionForTesting(
          VideoCollection(
            id: 'level-$level',
            name: 'Level $level',
            createTime: 1,
            parentId: level == 0 ? null : 'level-${level - 1}',
            childrenIds: ids,
            thumbnailPath: cover.path,
          ),
        );
      }
      final root = GlobalKey();
      final timings = <ui.FrameTiming>[];
      final visits = <_Visit>[];
      var restoreNotifications = 0;
      void settingsChanged() => restoreNotifications++;
      void collect(List<ui.FrameTiming> batch) => timings.addAll(batch);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: settings),
            ChangeNotifierProvider.value(value: library),
            ChangeNotifierProvider.value(value: playback),
            ChangeNotifierProvider.value(value: BatchImportService()),
          ],
          child: MaterialApp(
            theme: ThemeData.dark().copyWith(
              pageTransitionsTheme: appPageTransitionsTheme,
            ),
            home: MediaLibraryShell(
              home: CollectionScreen(key: root, collectionId: 'level-0'),
            ),
          ),
        ),
      );
      final navigator = MediaLibraryShell.maybeOf(
        root.currentContext!,
      )!.libraryNavigator!;
      try {
        for (final mode in [0, 1]) {
          await settings.updateSetting('mediaLibraryViewMode', mode);
          // Prime the visible artwork and text for both child levels. No cover
          // requests, decodes or reveal-policy changes are part of the comparison.
          for (final depth in [1, 2]) {
            navigator.push(
              MediaLibraryFolderRoute<void>(
                restored: true,
                settings: RouteSettings(
                  name: mediaLibraryFolderRouteName('level-$depth'),
                ),
                builder: (_) => CollectionScreen(collectionId: 'level-$depth'),
              ),
            );
            await Future<void>.delayed(const Duration(milliseconds: 900));
          }
          for (var depth = 2; depth > 0; depth--) {
            // The initial page is retained; capture the top route through the
            // navigator rather than relying on an offstage page's context.
            PageRoute<dynamic>? top;
            navigator.popUntil((candidate) {
              top = candidate as PageRoute;
              return true;
            });
            navigator.pop();
            await top!.completed;
          }
          await Future<void>.delayed(const Duration(milliseconds: 150));
          settings.addListener(settingsChanged);
          binding.addTimingsCallback(collect);
          for (var round = 0; round < 2; round++) {
            for (final improved
                in round.isEven ? [false, true] : [true, false]) {
              final routes = <PageRoute<void>>[];
              for (final depth in [1, 2]) {
                Widget page(BuildContext context) =>
                    CollectionScreen(collectionId: 'level-$depth');
                final route = improved
                    ? MediaLibraryFolderRoute<void>(builder: page)
                    : _PreviousFolderRoute(builder: page);
                routes.add(route);
                final fromUs = await _onFrame(
                  binding,
                  () => navigator.push(route),
                );
                await _entryFinished(route);
                visits.add((
                  transition: improved ? 'folder' : 'previousZoom',
                  mode: mode,
                  depth: depth,
                  direction: 'enter',
                  fromUs: fromUs,
                  toUs: binding.currentSystemFrameTimeStamp.inMicroseconds,
                ));
                await Future<void>.delayed(const Duration(milliseconds: 80));
              }
              for (var depth = 2; depth > 0; depth--) {
                final fromUs = await _onFrame(binding, () => navigator.pop());
                await routes[depth - 1].completed;
                visits.add((
                  transition: improved ? 'folder' : 'previousZoom',
                  mode: mode,
                  depth: depth,
                  direction: 'exit',
                  fromUs: fromUs,
                  toUs: binding.currentSystemFrameTimeStamp.inMicroseconds,
                ));
                await Future<void>.delayed(const Duration(milliseconds: 80));
              }
            }
          }
          await Future<void>.delayed(const Duration(milliseconds: 750));
          binding.removeTimingsCallback(collect);
          settings.removeListener(settingsChanged);
        }
        expect(restoreNotifications, 0);
      } finally {
        binding.removeTimingsCallback(collect);
        settings.removeListener(settingsChanged);
        await tester.pumpWidget(const SizedBox());
        await playback.stop();
        library.resetLibraryForTesting();
        settings.resetForTest();
        if (directory.absolute.parent.path ==
                Directory.systemTemp.absolute.path &&
            directory.path.contains('folder_route_profile_')) {
          await directory.delete(recursive: true);
        }
      }
      final hz = tester.view.display.refreshRate;
      final budgetUs = 1000000 / (hz > 0 ? hz : 60);
      final reports = <Map<String, Object>>[];
      for (final visit in visits) {
        final frames = timings.where((t) {
          final at = t.timestampInMicroseconds(ui.FramePhase.vsyncStart);
          return at >= visit.fromUs && at <= visit.toUs;
        }).toList();
        expect(frames, isNotEmpty, reason: '$visit');
        final vsyncs =
            frames
                .map((t) => t.timestampInMicroseconds(ui.FramePhase.vsyncStart))
                .toList()
              ..sort();
        var missedVsyncs = 0;
        for (var i = 1; i < vsyncs.length; i++) {
          final periods = (vsyncs[i] - vsyncs[i - 1]) / budgetUs;
          if (periods > 1.5) missedVsyncs += periods.round() - 1;
        }
        reports.add({
          'transition': visit.transition,
          'mode': visit.mode,
          'depth': visit.depth,
          'direction': visit.direction,
          'durationUs': visit.toUs - visit.fromUs,
          'frames': frames.length,
          'missedVsyncs': missedVsyncs,
          'build': _summary(frames.map((t) => t.buildDuration.inMicroseconds)),
          'raster': _summary(
            frames.map((t) => t.rasterDuration.inMicroseconds),
          ),
          'overBudgetFrames': frames
              .where(
                (t) =>
                    t.buildDuration.inMicroseconds > budgetUs ||
                    t.rasterDuration.inMicroseconds > budgetUs,
              )
              .length,
        });
      }
      binding.reportData = {
        'platform': Platform.operatingSystem,
        'displayHz': hz,
        'realFolderScreens': true,
        'cachedCovers': true,
        'itemsPerLevel': 400,
        'restoreNotifications': restoreNotifications,
        'visits': reports,
      };
      debugPrint('FOLDER_ROUTE_PROFILE ${jsonEncode(binding.reportData)}');
      expect(tester.takeException(), isNull);
    },
  );
}

Future<int> _onFrame(WidgetsBinding binding, VoidCallback action) {
  final done = Completer<int>();
  binding.scheduleFrameCallback((_) {
    final at = binding.currentSystemFrameTimeStamp.inMicroseconds;
    action();
    done.complete(at);
  });
  return done.future;
}

Future<void> _entryFinished(PageRoute<void> route) async {
  await WidgetsBinding.instance.endOfFrame;
  if (route.animation!.isCompleted) return;
  final done = Completer<void>();
  void changed(AnimationStatus status) {
    if (status == AnimationStatus.completed && !done.isCompleted) {
      done.complete();
    }
  }

  route.animation!.addStatusListener(changed);
  try {
    await done.future.timeout(const Duration(seconds: 20));
  } finally {
    route.animation!.removeStatusListener(changed);
  }
}

Map<String, int> _summary(Iterable<int> samples) {
  final values = samples.toList()..sort();
  int at(double quantile) => values[((values.length - 1) * quantile).round()];
  return {'p50Us': at(.5), 'p95Us': at(.95), 'maxUs': values.last};
}
