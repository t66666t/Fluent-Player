import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/douyin_download/douyin_download_controller.dart';
import 'package:video_player_app/features/web_media/web_media_download_queue.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_download_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/community_media_input.dart';
import 'package:video_player_app/main.dart' as app;
import 'package:video_player_app/models/subtitle_font.dart';
import 'package:video_player_app/services/video_compose/video_compose_font_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'processing accepts local media and refuses network or virtual media sources',
    () {
      for (final path in [
        'C:\\Media\\lesson.mp4',
        '/tmp/lesson.mp4',
        'lesson.mp4',
        'file:///tmp/lesson.mp4',
      ]) {
        expect(() => requireCommunityLocalMedia(path), returnsNormally);
      }
      for (final path in [
        'https://example.com/video.mp4',
        'http://example.com/playlist.m3u8',
        'cloud_drive://account/video',
        'bilibili://BV-test',
      ]) {
        expect(() => requireCommunityLocalMedia(path), throwsUnsupportedError);
      }
    },
  );

  test(
    'Bilibili public and course media URL APIs reject before a request',
    () async {
      final api = BilibiliApiService();
      await expectLater(api.fetchPlayUrl('BV-test', 1), throwsUnsupportedError);
      await expectLater(api.fetchCoursePlayUrl(1), throwsUnsupportedError);
      await expectLater(
        api.fetchMediaPlayUrl('BV-test', 1),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'yt-dlp resolving and download actions have no executable backend',
    () async {
      final service = YtDlpDownloadService();
      await service.init();
      await expectLater(
        service.resolveUrl('https://example.com/watch'),
        throwsUnsupportedError,
      );
      await expectLater(service.startSelected(), throwsUnsupportedError);
      service.dispose();
    },
  );

  test(
    'compatibility services construct and stop without starting transfers',
    () async {
      expect(
        app.main,
        isA<Function>(),
      ); // Compile the actual application dependency graph.
      final bili = BilibiliDownloadService();
      expect(bili.streamingService, isNotNull);
      expect(bili.materializationService, isNotNull);
      await bili.init();
      await bili.shutdown();
      bili.dispose();
      final douyin = DouyinDownloadController();
      await douyin.init();
      expect(douyin.tasks, isEmpty);
      await douyin.prepareStorageMigration();
      douyin.dispose();
    },
  );

  test(
    'old large-font choices resolve to the bundled OFL CJK font for rendering',
    () {
      final fonts = VideoComposeFontService();
      for (final family in [
        'MiSans',
        'Noto Serif CJK SC',
      ]) {
        expect(normalizeBundledFontFamily(family), 'Noto Sans SC');
        expect(fonts.resolveSystemFont(family), 'Noto Sans CJK SC');
      }
      expect(
        normalizeBundledFontFamily('Swei Gothic CJK SC'),
        'Swei Gothic CJK SC',
      );
      expect(
        fonts.resolveSystemFont('Swei Gothic CJK SC'),
        '獅尾圓體SC-Bold',
      );
      expect(
        normalizeBundledFontFamily('subtitle_font_custom'),
        'subtitle_font_custom',
      );
    },
  );

  test(
    'web queue lifecycle remains safe but starting transfers is rejected',
    () async {
      final library = LibraryService();
      final queue = WebMediaDownloadQueue.forLibrary(library);
      expect(
        identical(queue, WebMediaDownloadQueue.forLibrary(library)),
        isTrue,
      );
      await queue.pauseAll();
      await expectLater(queue.startWaiting(), throwsUnsupportedError);
      await queue.shutdown();
      queue.dispose();
    },
  );
}
