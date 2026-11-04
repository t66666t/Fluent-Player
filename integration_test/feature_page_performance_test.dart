import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/model_center/model_center_screen.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_screen.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_screen.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_service.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_store.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/screens/recycle_bin_screen.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';

import 'support/legacy_zoom_page_route.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => '$root/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$root/documents';
  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';
  @override
  Future<String?> getTemporaryPath() async => root;
}

class _Secrets implements AiChatSecretStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

typedef _Visit = ({
  String page,
  String transition,
  String direction,
  int round,
  int fromUs,
  int toUs,
});

/// Actual feature screens on the native renderer. Every persistent path and
/// credential store is isolated from the user's app. The legacy comparison
/// changes only rendering; each screen retains its current business behavior.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('native feature page entry and return frame comparison', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('feature_routes_');
    final previousPaths = PathProviderPlatform.instance;
    final previousStorage = AppStorageService.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    final storage = AppStorageService(
      locations: () async => StorageLocations(
        platform: StoragePlatform.windows,
        support: Directory('${root.path}/support'),
        documents: Directory('${root.path}/documents'),
        defaultData: Directory('${root.path}/data'),
        executable: Directory('${root.path}/executable'),
      ),
    );
    AppStorageService.instance = storage;
    await storage.initialize();
    final settings = SettingsService()..resetForTest();
    await settings.init();
    settings.largeDataRootPath = storage.dataDirectory.path;
    final library = LibraryService()..resetLibraryForTesting();
    await library.init();
    for (var i = 0; i < 1000; i++) {
      library.seedVideoForTesting(
        VideoItem(
          id: 'feature-fixture-$i',
          path: '${storage.dataDirectory.path}/fixture-$i.mp4',
          title: 'Recycled media item $i',
          durationMs: 120000,
          lastUpdated: i,
          isRecycled: true,
          recycleTime: i,
          hasProbedChapters: true,
        ),
      );
    }
    final center = ModelCenterService(storage: storage, secrets: _Secrets());
    final translation = SubtitleTranslateSettings();
    await translation.ensureLoaded();
    final sync = ProgressSyncService(
      library: library,
      store: MemoryProgressSyncStore(),
      enableNetwork: false,
    );
    final navigator = GlobalKey<NavigatorState>();
    final timings = <ui.FrameTiming>[];
    final visits = <_Visit>[];
    final liveFirst = Platform.environment['FEATURE_PROFILE_LIVE_FIRST'] == '1';
    void collect(List<ui.FrameTiming> frames) => timings.addAll(frames);
    final pages = <String, WidgetBuilder>{
      'importExport': (_) => const PortableTransferScreen(),
      'recycleBin': (_) => const RecycleBinScreen(),
      'modelCenter': (_) =>
          ModelCenterScreen(service: center, translateSettings: translation),
      'deviceSync': (_) => ProgressSyncScreen(service: sync),
    };
    try {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: library),
            ChangeNotifierProvider.value(value: settings),
            ChangeNotifierProvider.value(value: sync),
          ],
          child: MaterialApp(
            navigatorKey: navigator,
            theme: ThemeData.dark().copyWith(
              pageTransitionsTheme: appPageTransitionsTheme,
            ),
            home: Scaffold(
              body: GridView.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 220,
                  mainAxisExtent: 170,
                ),
                itemCount: 1000,
                itemBuilder: (_, i) => Card(
                  child: Column(
                    children: [
                      Expanded(
                        child: ColoredBox(
                          color: Colors.primaries[i % Colors.primaries.length],
                          child: const Center(
                            child: Icon(Icons.video_library, size: 40),
                          ),
                        ),
                      ),
                      Text('Home library item $i'),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      binding.addTimingsCallback(collect);
      for (var round = 0; round < 2; round++) {
        for (final page in pages.entries) {
          for (final improved
              in round.isEven
                  ? [liveFirst, !liveFirst]
                  : [!liveFirst, liveFirst]) {
            final route = improved
                ? AppMaterialPageRoute<void>(builder: page.value)
                : LegacyZoomPageRoute<void>(builder: page.value);
            final fromUs = await _onFrame(
              binding,
              () => navigator.currentState!.push(route),
            );
            await binding.endOfFrame; // let Hero's offstage measurement finish
            await _settled(route.animation!);
            visits.add((
              page: page.key,
              transition: improved ? 'live' : 'previousZoom',
              direction: 'enter',
              round: round,
              fromUs: fromUs,
              toUs: binding.currentSystemFrameTimeStamp.inMicroseconds,
            ));
            await Future<void>.delayed(const Duration(milliseconds: 220));
            final exitUs = await _onFrame(
              binding,
              () => navigator.currentState!.pop(),
            );
            await route.completed;
            visits.add((
              page: page.key,
              transition: improved ? 'live' : 'previousZoom',
              direction: 'exit',
              round: round,
              fromUs: exitUs,
              toUs: binding.currentSystemFrameTimeStamp.inMicroseconds,
            ));
            await Future<void>.delayed(const Duration(milliseconds: 150));
            expect(tester.takeException(), isNull);
          }
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 800));
      final displayHz = tester.view.display.refreshRate;
      final budget = 1000000 / (displayHz > 0 ? displayHz : 60);
      final reports = <Map<String, Object>>[];
      for (final visit in visits) {
        final frames = timings.where((frame) {
          final at = frame.timestampInMicroseconds(ui.FramePhase.vsyncStart);
          return at >= visit.fromUs && at <= visit.toUs;
        }).toList();
        expect(frames, isNotEmpty, reason: '$visit');
        final vsyncs =
            frames
                .map((f) => f.timestampInMicroseconds(ui.FramePhase.vsyncStart))
                .toList()
              ..sort();
        var missed = 0;
        for (var i = 1; i < vsyncs.length; i++) {
          final periods = (vsyncs[i] - vsyncs[i - 1]) / budget;
          if (periods > 1.5) missed += periods.round() - 1;
        }
        reports.add({
          'page': visit.page,
          'transition': visit.transition,
          'direction': visit.direction,
          'round': visit.round,
          'frames': frames.length,
          'durationUs': visit.toUs - visit.fromUs,
          'build': _stats(frames.map((f) => f.buildDuration.inMicroseconds)),
          'raster': _stats(frames.map((f) => f.rasterDuration.inMicroseconds)),
          'vsyncOverhead': _stats(
            frames.map((f) => f.vsyncOverhead.inMicroseconds),
          ),
          'overBudgetFrames': frames
              .where(
                (f) =>
                    f.buildDuration.inMicroseconds > budget ||
                    f.rasterDuration.inMicroseconds > budget,
              )
              .length,
          'missedVsyncs': missed,
        });
      }
      binding.reportData = {
        'platform': Platform.operatingSystem,
        'displayHz': displayHz,
        'realFeatureScreens': true,
        'liveFirst': liveFirst,
        'recycledItemCount': 1000,
        'comparisonScope':
            'transition renderer on current feature implementations',
        'visits': reports,
      };
      debugPrint('FEATURE_ROUTE_PROFILE ${jsonEncode(binding.reportData)}');
    } finally {
      binding.removeTimingsCallback(collect);
      await tester.pumpWidget(const SizedBox.shrink());
      sync.dispose();
      await center.save().catchError((Object _) {});
      center.dispose();
      translation.dispose();
      library.resetLibraryForTesting();
      settings.resetForTest();
      PathProviderPlatform.instance = previousPaths;
      AppStorageService.instance = previousStorage;
      if (root.absolute.parent.path == Directory.systemTemp.absolute.path &&
          root.path
              .split(Platform.pathSeparator)
              .last
              .startsWith('feature_routes_')) {
        await root.delete(recursive: true);
      }
    }
  });
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

Future<void> _settled(Animation<double> animation) async {
  if (animation.isCompleted) return;
  final done = Completer<void>();
  void onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && !done.isCompleted) {
      done.complete();
    }
  }

  animation.addStatusListener(onStatus);
  try {
    await done.future.timeout(const Duration(seconds: 20));
  } finally {
    animation.removeStatusListener(onStatus);
  }
}

Map<String, int> _stats(Iterable<int> samples) {
  final sorted = samples.toList()..sort();
  int at(double q) => sorted[((sorted.length - 1) * q).round()];
  return {'p50Us': at(.5), 'p95Us': at(.95), 'maxUs': sorted.last};
}
