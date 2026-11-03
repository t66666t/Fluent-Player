// Isolated native regression. Uses only a temporary library/preferences tree.
// flutter build windows --release -t scripts/windows_compose_preview_smoke.dart
// --dart-define=SMOKE_MEDIA=<video> --dart-define=SMOKE_REPORT=<report>
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:window_manager/window_manager.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';
import 'package:video_player_app/screens/portrait_video_screen.dart';
import 'package:video_player_app/screens/simple_video_player_screen.dart';
import 'package:video_player_app/screens/video_player_screen.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/embedded_subtitle_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_materialization_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/ocr_subtitle_manager.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/progress_tracker.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/widgets/video_controls_overlay.dart';

const _media = String.fromEnvironment('SMOKE_MEDIA');
const _report = String.fromEnvironment('SMOKE_REPORT');
final _navigator = GlobalKey<NavigatorState>();
final _surface = GlobalKey();
final _playback = MediaPlaybackService();

void _record(String message) => File(_report).writeAsStringSync(
  '${DateTime.now().toIso8601String()} $message\n',
  mode: FileMode.append,
  flush: true,
);

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isWindows || _media.isEmpty || _report.isEmpty) exit(2);
  File(_report).writeAsStringSync('START compose preview native regression\n');
  FlutterError.onError = (details) {
    _record('FAIL Flutter: ${details.exceptionAsString()}\n${details.stack}');
    exit(1);
  };
  final isolated = await Directory.systemTemp.createTemp(
    'compose_preview_native_',
  );
  PathProviderPlatform.instance = _Paths(isolated.path);
  // Native harness deliberately bypasses the user's persisted preferences.
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsService();
  await settings.init();
  settings.autoPlayOnCompletion = false;
  settings.playlistWrapToFirst = false;
  settings.autoPauseOnExit = false;
  await AppStorageService.instance.initialize(configuredRoot: isolated.path);
  NativeVideoPlayerMediaKit.ensureInitialized();
  await windowManager.ensureInitialized();
  final library = LibraryService();
  final playlist = PlaylistManager();
  await _playback.initialize(
    playlistManager: playlist,
    progressTracker: ProgressTracker(),
  );
  await _playback.setVolume(0);
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsService>.value(value: settings),
        ChangeNotifierProvider<LibraryService>.value(value: library),
        ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
        ChangeNotifierProvider<MediaPlaybackService>.value(value: _playback),
        ChangeNotifierProvider<TranscriptionManager>(
          create: (_) => TranscriptionManager(),
        ),
        ChangeNotifierProvider<EmbeddedSubtitleService>(
          create: (_) => EmbeddedSubtitleService(),
        ),
        ChangeNotifierProvider<OcrSubtitleManager>(
          create: (_) => OcrSubtitleManager(library: library),
        ),
        ChangeNotifierProvider<MediaMaterializationService>(
          create: (_) => MediaMaterializationService(BilibiliApiService()),
        ),
      ],
      child: RepaintBoundary(
        key: _surface,
        child: MaterialApp(
          navigatorKey: _navigator,
          navigatorObservers: [AppToast.routeObserver],
          theme: ThemeData.dark().copyWith(
            pageTransitionsTheme: appPageTransitionsTheme,
          ),
          home: const Scaffold(
            body: Center(child: Text('Compose preview regression')),
          ),
        ),
      ),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_exercise()));
}

Future<void> _until(bool Function() done) async {
  final timeout = DateTime.now().add(const Duration(seconds: 20));
  while (!done()) {
    if (DateTime.now().isAfter(timeout)) {
      throw StateError('Timed out waiting for preview/source');
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
}

List<Widget> _visibleWidgets() {
  final widgets = <Widget>[];
  void visit(Element element) {
    if (element.widget is Offstage && (element.widget as Offstage).offstage) {
      return;
    }
    widgets.add(element.widget);
    element.visitChildren(visit);
  }

  _surface.currentContext!.visitChildElements(visit);
  return widgets;
}

Future<void> _exercise() async {
  final framePump = Timer.periodic(
    const Duration(milliseconds: 16),
    (_) => WidgetsBinding.instance.scheduleFrame(),
  );
  try {
    var visits = 0;
    for (final portrait in [false, true]) {
      await windowManager.setSize(
        portrait ? const Size(720, 1000) : const Size(1280, 800),
      );
      final item = VideoItem(
        id: 'smoke-$portrait',
        path: _media,
        title: 'Compose source $portrait',
        durationMs: 12000,
        lastUpdated: 0,
      );
      final playing = _playback.play(item);
      final sourceRoute = AppMaterialPageRoute<void>(
        allowSnapshotting: false,
        builder: (_) => portrait
            ? PortraitVideoScreen(videoItem: item)
            : VideoPlayerScreen(videoItem: item),
      );
      unawaited(_navigator.currentState!.push(sourceRoute));
      await playing.timeout(const Duration(seconds: 30));
      await Future<void>.delayed(const Duration(milliseconds: 650));
      final source = _playback.controller!;
      // ignore: invalid_use_of_visible_for_testing_member
      final sourceId = source.playerId;
      await NativeVideoPlayerMediaKit.firstFrameRenderedFor(
        sourceId,
      )!.timeout(const Duration(seconds: 15));
      await _playback.seekTo(const Duration(seconds: 3));
      for (final queue in [false, true]) {
        for (final wasPlaying in [false, true]) {
          if (wasPlaying) {
            await _playback.resume();
          } else {
            await _playback.pause();
          }
          final position = _playback.position;
          if (queue) {
            unawaited(
              showDialog<void>(
                context: _navigator.currentContext!,
                builder: (_) => const AlertDialog(title: Text('Compose queue')),
              ),
            );
            await Future<void>.delayed(const Duration(milliseconds: 400));
          }
          final route = AppMaterialPageRoute<void>(
            allowSnapshotting: false,
            builder: (_) => SimpleVideoPlayerScreen(
              videoPath: _media,
              title: 'Composed preview',
            ),
          );
          unawaited(_navigator.currentState!.push(route));
          await _until(
            () => _visibleWidgets().whereType<VideoControlsOverlay>().any(
              (w) => w.isPreviewMode,
            ),
          );
          final preview = _visibleWidgets()
              .whereType<VideoControlsOverlay>()
              .singleWhere((w) => w.isPreviewMode);
          // ignore: invalid_use_of_visible_for_testing_member
          final previewId = preview.controller!.playerId;
          await NativeVideoPlayerMediaKit.firstFrameRenderedFor(
            previewId,
          )!.timeout(const Duration(seconds: 15));
          await Future<void>.delayed(const Duration(milliseconds: 400));
          preview.onBackPressed();
          await route.completed;
          await _until(
            () =>
                !NativeVideoPlayerMediaKit.managesPlayer(previewId) &&
                _playback.isPlaying == wasPlaying,
          );
          if (queue) {
            _navigator.currentState!.pop();
            await Future<void>.delayed(const Duration(milliseconds: 450));
          }
          if (!identical(_playback.controller, source)) {
            throw StateError('Source controller replaced');
          }
          if ((_playback.position - position).abs() >
              const Duration(seconds: 2)) {
            throw StateError('Source clock lost');
          }
          final visible = _visibleWidgets();
          if (!visible.whereType<VideoPlayer>().any(
                (w) => identical(w.controller, source),
              ) ||
              !visible.whereType<VideoControlsOverlay>().any(
                (w) => identical(w.controller, source) && !w.isPreparing,
              )) {
            throw StateError('Source video view missing/loading on return');
          }
          final frame = await NativeVideoPlayerMediaKit.ambientFrameFor(
            sourceId,
          );
          if (frame == null || frame.length < 1000) {
            throw StateError('Source decoded frame unavailable');
          }
          await File('$_report.$visits.jpg').writeAsBytes(frame);
          await WidgetsBinding.instance.endOfFrame;
          final image =
              await (_surface.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '$_report.$visits.png',
          ).writeAsBytes(png!.buffer.asUint8List());
          image.dispose();
          if (wasPlaying) {
            final before = await source.position;
            await Future<void>.delayed(const Duration(milliseconds: 350));
            if (await source.position == before) {
              throw StateError('Source clock stopped');
            }
          }
          _record(
            'PASS visit ${visits++}: portrait=$portrait queue=$queue playing=$wasPlaying; source mounted, frame captured, clock/intent preserved, preview released',
          );
        }
      }
      await _playback.pause();
      _navigator.currentState!.pop();
      await sourceRoute.completed;
      await _playback.stop();
      await _until(() => !NativeVideoPlayerMediaKit.managesPlayer(sourceId));
    }
    _record('PASS $visits native compose preview round trips');
    framePump.cancel();
    // This entry omits the production application's shutdown coordinator.
    // Its host runner reads PASS/FAIL then terminates only the probe process;
    // tearing down the Flutter engine here races Windows native FFI callbacks.
    await windowManager.hide();
  } catch (error, stack) {
    framePump.cancel();
    _record('FAIL $error\n$stack');
    exit(1);
  }
}
