import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_cookie_store.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/network/network_http.dart';
import 'package:video_player_app/services/network/platform_proxy_resolver.dart';
import 'package:video_player_app/services/settings_service.dart';

// --dart-define=BILIBILI_COURSE_LIVE_TEST=true
// Real network requests, using an isolated guest profile. Purchased playback
// is tested with an injected authenticated transport in bilibili_course_test.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('BILIBILI_COURSE_LIVE_TEST');
  late Directory root;
  late PathProviderPlatform originalPaths;
  late HttpOverrides? originalOverrides;
  late BilibiliDownloadService service;

  setUpAll(() async {
    if (!enabled) return;
    originalOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    root = await Directory.systemTemp.createTemp('bilibili-course-live-');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    SettingsService().largeDataRootPath = root.path;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          PlatformProxyResolver.channel,
          (_) async => ['DIRECT'],
        );
    await NetworkHttp.instance.settings.ready;
    await NetworkHttp.instance.settings.setUnifiedMode(NetworkMode.direct);
    service = BilibiliDownloadService(
      apiService: BilibiliApiService(cookieStore: _GuestCookies()),
    );
  });

  tearDownAll(() async {
    if (!enabled) return;
    await service.shutdown();
    service.dispose();
    await NetworkHttp.instance.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PlatformProxyResolver.channel, null);
    SettingsService().resetForTest();
    SettingsService().largeDataRootPath = null;
    PathProviderPlatform.instance = originalPaths;
    HttpOverrides.global = originalOverrides;
    await root.delete(recursive: true);
  });

  test(
    'user short link, full season and lesson links all resolve the same course',
    () async {
      final short = (await service.parseSingleLine('https://b23.tv/4ZO8mRe'))!;
      final season = (await service.parseSingleLine(
        'https://www.bilibili.com/cheese/play/ss15549',
      ))!;
      final lesson = (await service.parseSingleLine(
        'https://m.bilibili.com/cheese/play/ep551412',
      ))!;
      expect(short.collectionInfo!.title, '单词革命丨超神单词');
      expect(short.videos.length, greaterThanOrEqualTo(201));
      expect(short.videos.length, season.videos.length);
      expect(short.videos.length, lesson.videos.length);
      for (var i = 0; i < short.videos.length; i++) {
        final v = short.videos[i];
        expect(v.videoInfo.title, season.videos[i].videoInfo.title);
        expect(
          v.episodes.single.page.courseEpisodeId,
          lesson.videos[i].episodes.single.page.courseEpisodeId,
        );
        expect(v.videoInfo.bvid, matches(r'^BV[0-9A-Za-z]{10}$'));
        expect(v.episodes.single.page.cid, greaterThan(0));
      }
      expect(short.videos.first.videoInfo.title, '「alt」');
      // ignore: avoid_print
      print(
        '${short.collectionInfo!.title}: ${short.videos.length} lessons; first=${short.videos.first.videoInfo.title}',
      );
    },
    skip: !enabled,
  );

  test(
    'public trial lesson yields DASH and actual bytes through the playback gateway',
    () async {
      final task = (await service.parseSingleLine(
        'https://www.bilibili.com/cheese/play/ss15549',
      ))!;
      final lesson = task.videos.first;
      final page = lesson.episodes.single.page;
      final item = VideoItem(
        id: 'course-live-trial',
        title: lesson.videoInfo.title,
        path: 'bilibili://stream/${lesson.videoInfo.bvid}?cid=${page.cid}',
        durationMs: page.duration * 1000,
        lastUpdated: 0,
        sourceRef: lesson.sourceRef!.copyWith(
          kind: MediaSourceKind.bilibiliStream,
        ),
      );
      final playback = await service.streamingService.prepare(item);
      final client = HttpClient();
      try {
        final request = await client.getUrl(playback.videoUri);
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
        final response = await request.close().timeout(
          const Duration(seconds: 25),
        );
        expect(response.statusCode, HttpStatus.partialContent);
        final size = await response
            .fold<int>(0, (size, bytes) => size + bytes.length)
            .timeout(const Duration(seconds: 25));
        expect(size, 1024);
      } finally {
        client.close(force: true);
        await service.streamingService.releasePlayback(playback);
      }
    },
    skip: !enabled,
  );

  test('guest purchase denial is a clear permission error', () async {
    await expectLater(
      service.apiService.fetchCoursePlayUrl(2592321),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('购买课程的账号'),
        ),
      ),
    );
  }, skip: !enabled);
}

class _GuestCookies extends BilibiliCookieStore {
  @override
  Future<Map<String, String>> readCookies() async => {};
  @override
  Future<BilibiliLegacyCookieMigrationResult> migrateLegacyIfPresent() async =>
      const BilibiliLegacyCookieMigrationResult(
        BilibiliLegacyCookieMigration.none,
      );
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}
