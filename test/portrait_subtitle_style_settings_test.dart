import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/screens/portrait_video_screen.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_streaming_service.dart';
import 'package:video_player_app/services/embedded_subtitle_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/ocr_subtitle_manager.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/progress_tracker.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_debug_session.dart';
import 'package:video_player_app/services/subtitle_font_service.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';
import 'package:video_player_app/widgets/subtitle_settings_sheet.dart';
import 'package:video_player_app/widgets/bilibili_cover_image.dart';

class _Paths extends PathProviderPlatform {
  final String path;
  _Paths(this.path);
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getApplicationCachePath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

class _WaitingStream extends BilibiliStreamingService {
  _WaitingStream() : super(BilibiliApiService());
  @override
  Future<BilibiliPreparedPlayback> prepare(
    VideoItem item, {
    int? qualityId,
    int? audioQualityId,
    bool allowWarmReuse = true,
    bool forceRefresh = false,
  }) => Completer<BilibiliPreparedPlayback>().future;
}

void main() {
  final capture = GlobalKey();
  late Directory directory;
  late PathProviderPlatform originalPaths;
  final valueCheck = Provider.debugCheckInvalidValueType;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('portrait_font_ui_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    Provider.debugCheckInvalidValueType = null;
    SharedPreferences.setMockInitialValues({});
    await SubtitleFontService.instance.ready;
    await SubtitleFontService.instance.catalog();
    final font = FontLoader('Noto Sans SC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Variable.ttf'));
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await Future.wait([font.load(), icons.load()]);
  });
  tearDownAll(() async {
    Provider.debugCheckInvalidValueType = valueCheck;
    PathProviderPlatform.instance = originalPaths;
    await directory.delete(recursive: true);
  });
  for (final scenario in [
    (const Size(320, 568), 1.0, 16 / 9),
    (const Size(390, 844), 1.0, 4 / 3),
    (const Size(430, 932), 2.0, 9 / 16),
  ]) {
    Future<void> verifyStyle(WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = scenario.$1;
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 20);
      tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 20);
      addTearDown(tester.view.reset);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 30));
      });
      SharedPreferences.setMockInitialValues({});
      SubtitleDebugSession.instance.resetForTest();
      final settings = SettingsService()..resetForTest();
      await tester.runAsync(settings.init);
      settings.bilibiliPortraitShowsSubtitles = true;
      final library = LibraryService()..resetLibraryForTesting();
      final playback = MediaPlaybackService();
      final playlist = PlaylistManager();
      await tester.runAsync(
        () => playback.initialize(
          playlistManager: playlist,
          progressTracker: ProgressTracker(),
          bilibiliStreamingService: _WaitingStream(),
        ),
      );
      final scale = ValueNotifier(1.0);
      addTearDown(scale.dispose);
      final item = VideoItem(
        id: 'portrait-font-test',
        path: 'bilibili://stream/BV1xx411c7mD?cid=101',
        title: '字幕样式',
        durationMs: 600000,
        lastUpdated: 0,
        isTransient: true,
        isBilibiliExported: true,
        sourceRef: const MediaSourceRef(
          value: 'BV1xx411c7mD',
          kind: MediaSourceKind.bilibiliStream,
          bvid: 'BV1xx411c7mD',
          cid: 101,
          page: 1,
        ),
      )..portraitDisplayAspectRatio = 16 / 9;
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsService>.value(value: settings),
            ChangeNotifierProvider<LibraryService>.value(value: library),
            ChangeNotifierProvider<TranscriptionManager>.value(
              value: TranscriptionManager(),
            ),
            ChangeNotifierProvider<EmbeddedSubtitleService>.value(
              value: EmbeddedSubtitleService(),
            ),
            ChangeNotifierProvider<OcrSubtitleManager>.value(
              value: OcrSubtitleManager(library: library),
            ),
            ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
            Provider<MediaPlaybackService>.value(value: playback),
          ],
          child: MaterialApp(
            theme: ThemeData(brightness: Brightness.dark, fontFamily: 'Noto Sans SC'),
            builder: (context, child) => ValueListenableBuilder<double>(
              valueListenable: scale,
              builder: (context, factor, _) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(factor)),
                child: child!,
              ),
            ),
            home: RepaintBoundary(
              key: capture,
              child: PortraitVideoScreen(
                videoItem: item,
                autoPlayOnEntry: false,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final sidebar = tester.widget<SubtitleSidebar>(
        find.byType(SubtitleSidebar, skipOffstage: false),
      );
      sidebar.onOpenSubtitleStyle!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      item.portraitDisplayAspectRatio = scenario.$3;
      scale.value = scenario.$2;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final sheet = find.byType(SubtitleSettingsSheet);
      final bounds = tester.getRect(sheet);
      expect(bounds.height, greaterThan(150));
      expect(find.text('整体大小'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('subtitle-font-settings')).hitTestable(),
        100,
        scrollable: find
            .descendant(of: sheet, matching: find.byType(Scrollable))
            .first,
      );
      await tester.tap(find.byKey(const ValueKey('subtitle-font-settings')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.getRect(sheet), bounds);
      await tester.tap(find.text('通用字体'));
      await tester.pump();
      await tester.runAsync(() => SubtitleFontService.instance.catalog());
      await tester.pump(const Duration(milliseconds: 200));
      final search = find.byType(TextField);
      await tester.showKeyboard(search);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final keyboardBounds = tester.getRect(sheet);
      expect(
        keyboardBounds.bottom,
        lessThanOrEqualTo(scenario.$1.height - 300 + .1),
      );
      expect(keyboardBounds.height, greaterThan(120));
      final video = tester.getRect(find.byType(AspectRatio).first);
      expect(video.height, greaterThan(24));
      expect(video.bottom, lessThanOrEqualTo(keyboardBounds.top + .1));
      expect(tester.takeException(), isNull);
      if (scenario.$1.width == 320) {
        final useFont = find.byKey(
          const ValueKey('subtitle-font-use-系统字体'),
        );
        await tester.scrollUntilVisible(
          useFont,
          48,
          scrollable: find
              .descendant(of: sheet, matching: find.byType(Scrollable))
              .first,
        );
        await tester.pump(const Duration(milliseconds: 300));
        final buttonBounds = tester.getRect(useFont);
        expect(buttonBounds.top, greaterThanOrEqualTo(keyboardBounds.top));
        expect(buttonBounds.bottom, lessThanOrEqualTo(keyboardBounds.bottom));
        expect(useFont.hitTestable(), findsOneWidget);
        await tester.runAsync(() async {
          await tester.tap(useFont);
          await SubtitleFontService.instance.verifyFiles(['System']);
        });
        await tester.pump();
        expect(find.text('字体设置'), findsOneWidget);
        // Return to the picker so the existing IME and Back checks keep
        // exercising the same path after selecting a font successfully.
        await tester.tap(find.text('通用字体'));
        await tester.pump();
        await tester.showKeyboard(find.byType(TextField));
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
      if (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS) {
        final videoFinder = find.byType(BilibiliVideoAspectRatio).first;
        final controlsFinder = find.byKey(
          const ValueKey('portrait-external-controls'),
        );
        final videoWidget = tester.widget(videoFinder);
        final controlsWidget = tester.widget(controlsFinder);
        for (final inset in [120.0, 200.0, 300.0, 299.5, 240.0, 180.0]) {
          tester.view.viewInsets = FakeViewPadding(bottom: inset);
          tester.view.padding = const FakeViewPadding(top: 24);
          await tester.pump(const Duration(milliseconds: 8));
          expect(tester.widget(videoFinder), same(videoWidget));
          expect(tester.widget(controlsFinder), same(controlsWidget));
          expect(
            tester.getRect(sheet).bottom,
            lessThanOrEqualTo(scenario.$1.height - inset + .1),
          );
          expect(tester.takeException(), isNull);
        }
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pump();
      }
      if (scenario.$1.width == 390) {
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(capture),
          );
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final output = Directory('build/subtitle-style-review');
          await output.create(recursive: true);
          await File(
            '${output.path}/portrait-keyboard.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      tester.testTextInput.hide();
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.text('字体设置'), findsOneWidget);
      expect(find.byType(SubtitleSettingsSheet), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byKey(const ValueKey('subtitle-font-settings')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 30));
      settings.resetForTest();
      library.resetLibraryForTesting();
    }

    testWidgets(
      'portrait style, fonts and keyboard fit $scenario',
      verifyStyle,
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.windows,
      }),
    );
  }
}
