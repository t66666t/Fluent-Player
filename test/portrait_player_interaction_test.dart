import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:video_player_app/models/cloud_drive_source_ref.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/screens/portrait_video_screen.dart';
import 'package:video_player_app/services/embedded_subtitle_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/ocr_subtitle_manager.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_font_service.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/theme/app_interaction_theme.dart';
import 'package:video_player_app/theme/playback_page_route.dart';
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/widgets/subtitle_management_sheet.dart';

import 'support/web_media_preview_video_platform.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getApplicationCachePath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

class _LoadingPlayback extends MediaPlaybackService {
  _LoadingPlayback() : super.forTesting();
  @override
  PlaybackState get state => PlaybackState.loading;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PathProviderPlatform previousPaths;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('portrait_interaction_');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    SharedPreferences.setMockInitialValues({});
    await SubtitleFontService.instance.ready;
    await (FontLoader(
      'MiSans',
    )..addFont(rootBundle.load('assets/fonts/MiSans-Regular.otf'))).load();
  });
  tearDownAll(() async {
    PathProviderPlatform.instance = previousPaths;
    if (directory.absolute.parent.path == Directory.systemTemp.absolute.path &&
        directory.path.contains('portrait_interaction_')) {
      await directory.delete(recursive: true);
    }
  });

  for (final state in ['loading', 'paused', 'playing']) {
    testWidgets(
      'cloud portrait shows, closes and reopens subtitle management: $state',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({});
        final settings = SettingsService()..resetForTest();
        await settings.init();
        final library = LibraryService()..resetLibraryForTesting();
        final originalPlatform = VideoPlayerPlatform.instance;
        VideoPlayerPlatform.instance = WebMediaPreviewVideoPlatform();
        addTearDown(() => VideoPlayerPlatform.instance = originalPlatform);
        final ready = state != 'loading';
        final playback = ready ? MediaPlaybackService() : _LoadingPlayback();
        const source = CloudDriveSourceRef(
          providerId: 'baidu',
          remoteAccountId: 'test',
          driveId: '0',
          fileId: 'video',
        );
        final item = VideoItem(
          id: source.itemId,
          path: source.logicalUri,
          title: '网盘视频',
          durationMs: 600000,
          lastUpdated: 0,
          sourceRef: MediaSourceRef(
            kind: MediaSourceKind.cloudDrive,
            value: source.logicalUri,
            cloudDrive: source,
          ),
        );
        playback.debugSeedCurrentItem(item);
        if (ready) {
          final controller = VideoPlayerController.networkUrl(
            Uri.parse('https://example.invalid/video.mp4'),
          );
          await tester.runAsync(controller.initialize);
          if (state == 'playing') await tester.runAsync(controller.play);
          await playback.setController(controller);
          await playback.updateMetadata(item);
        }
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (_) async => null,
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            null,
          ),
        );
        var cleaned = false;
        Future<void> cleanup() async {
          if (cleaned) return;
          cleaned = true;
          await tester.pumpWidget(const SizedBox.shrink());
          if (ready) {
            await tester.runAsync(playback.stop);
          } else {
            playback.dispose();
          }
          await tester.pump(const Duration(seconds: 30));
        }

        addTearDown(cleanup);
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<SettingsService>.value(value: settings),
              ChangeNotifierProvider<LibraryService>.value(value: library),
              ChangeNotifierProvider<TranscriptionManager>(
                create: (_) => TranscriptionManager(),
              ),
              ChangeNotifierProvider<EmbeddedSubtitleService>(
                create: (_) => EmbeddedSubtitleService(),
              ),
              ChangeNotifierProvider<OcrSubtitleManager>(
                create: (_) => OcrSubtitleManager(library: library),
              ),
              ChangeNotifierProvider<PlaylistManager>(
                create: (_) => PlaylistManager(),
              ),
              ChangeNotifierProvider<MediaPlaybackService>.value(
                value: playback,
              ),
            ],
            child: MaterialApp(
              navigatorKey: AppToast.navigatorKey,
              theme: appInteractionTheme(
                ThemeData(brightness: Brightness.dark, fontFamily: 'MiSans'),
              ),
              home: const Scaffold(),
            ),
          ),
        );
        AppToast.navigatorKey.currentState!.push(
          PlaybackPageRoute<void>(
            settings: const RouteSettings(name: '/playback/portrait'),
            builder: (_) =>
                PortraitVideoScreen(videoItem: item, autoPlayOnEntry: false),
          ),
        );
        for (var frame = 0; frame < 30; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(tester.takeException(), isNull);
        for (var visit = 0; visit < 2; visit++) {
          await tester.tap(find.text('查看字幕管理'));
          await tester.pump();
          final manager = find.byType(SubtitleManagementSheet);
          expect(manager, findsOneWidget);
          final managerFade = find
              .ancestor(of: manager, matching: find.byType(AnimatedOpacity))
              .first;
          final renderedFade = find
              .descendant(
                of: managerFade,
                matching: find.byType(FadeTransition),
              )
              .first;
          expect(
            tester.widget<FadeTransition>(renderedFade).opacity.value,
            1,
            reason: 'The real manager must paint when it first takes input.',
          );
          expect(find.text('查看字幕管理'), findsNothing);
          await tester.tap(
            find
                .descendant(of: manager, matching: find.byIcon(Icons.close))
                .first,
          );
          for (var frame = 0; frame < 30; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
          }
          expect(manager, findsNothing);
          expect(find.text('查看字幕管理'), findsOneWidget);
          final showedSubtitles = settings.showSubtitles;
          await tester.tap(find.byTooltip('字幕开关'));
          await tester.pump();
          expect(settings.showSubtitles, !showedSubtitles);
          if (state == 'playing') expect(playback.isPlaying, isTrue);
          expect(tester.takeException(), isNull);
        }
        await cleanup();
      },
      variant: TargetPlatformVariant.all(),
    );
  }
}
