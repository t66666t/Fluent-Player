import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_stream.dart';
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
import 'package:video_player_app/widgets/subtitle_sidebar.dart';

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
  bool appended = false;
  @override
  PlaybackState get state => PlaybackState.loading;
  @override
  bool get subtitleWasAppend => appended;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PathProviderPlatform previousPaths;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp(
      'portrait_stream_regression_',
    );
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    SharedPreferences.setMockInitialValues({});
    await SubtitleFontService.instance.ready;
  });
  tearDownAll(() async {
    PathProviderPlatform.instance = previousPaths;
    if (directory.absolute.parent.path == Directory.systemTemp.absolute.path &&
        directory.path.contains('portrait_stream_regression_')) {
      await directory.delete(recursive: true);
    }
  });

  testWidgets(
    'portrait forwards immutable stream snapshots and preserves a selection',
    (tester) async {
      SharedPreferences.setMockInitialValues({'autoScrollSubtitles': false});
      final settings = SettingsService()..resetForTest();
      await settings.init();
      final library = LibraryService()..resetLibraryForTesting();
      final playback = _LoadingPlayback();
      final item = VideoItem(
        id: 'portrait-stream',
        path: '/portrait-stream.mp4',
        title: '文稿',
        durationMs: 600000,
        lastUpdated: 0,
      );
      playback.debugSeedCurrentItem(item);
      final primary = SubtitleCueBuffer();
      final secondary = SubtitleCueBuffer();
      void append(int start, int count) {
        primary.addAll(
          List.generate(
            count,
            (i) => SubtitleItem(
              index: start + i,
              startTime: Duration(seconds: (start + i) * 3),
              endTime: Duration(seconds: (start + i) * 3 + 2),
              text: 'Streaming caption ${start + i}, readable transcript.',
            ),
          ),
        );
        secondary.addAll(
          List.generate(
            count,
            (i) => SubtitleItem(
              index: start + i,
              startTime: Duration(seconds: (start + i) * 3),
              endTime: Duration(seconds: (start + i) * 3 + 2),
              text: '字幕译文 ${start + i}',
            ),
          ),
        );
        playback.setSubtitleState(
          paths: ['/source.srt', '/translated.srt'],
          primary: primary.snapshot,
          secondary: secondary.snapshot,
        );
      }

      append(0, 100);
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
            ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
          ],
          child: MaterialApp(
            home: PortraitVideoScreen(videoItem: item, autoPlayOnEntry: false),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      SubtitleSidebar sidebar() =>
          tester.widget<SubtitleSidebar>(find.byType(SubtitleSidebar));
      expect(identical(sidebar().subtitles, playback.subtitles), isTrue);
      expect(
        identical(sidebar().secondarySubtitles, playback.secondarySubtitles),
        isTrue,
      );
      final state = tester.state<SubtitleSidebarState>(
        find.byType(SubtitleSidebar),
      );
      tester
          .state<SelectionAreaState>(
            find
                .descendant(
                  of: find.byType(SubtitleSidebar),
                  matching: find.byType(SelectionArea),
                )
                .first,
          )
          .selectableRegion
          .selectAll(SelectionChangedCause.keyboard);
      await tester.pump();
      expect(state.selectedTranscriptText, isNotEmpty);
      final before = sidebar().subtitles;
      playback.appended = true;
      append(100, 2);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      expect(isSubtitleAppend(before, sidebar().subtitles), isTrue);
      expect(identical(sidebar().subtitles, playback.subtitles), isTrue);
      expect(
        state.selectedTranscriptText,
        isNotEmpty,
        reason: 'Appending must not be mistaken for replacing the transcript.',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      playback.dispose();
    },
  );
}
