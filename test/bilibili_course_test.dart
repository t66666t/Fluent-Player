import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_cookie_store.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_streaming_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/bilibili_url_parser.dart';

const _short = 'https://b23.tv/4ZO8mRe';
const _season = 'https://www.bilibili.com/cheese/play/ss15549';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform originalPaths;
  late _CourseAdapter adapter;
  late BilibiliApiService api;
  late BilibiliDownloadService service;
  LibraryService? library;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    root = await Directory.systemTemp.createTemp('bilibili-course-');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    SettingsService().largeDataRootPath = root.path;
    adapter = _CourseAdapter();
    api = BilibiliApiService(
      httpClientAdapter: adapter,
      cookieStore: _Cookies({'SESSDATA': 'TEST-PURCHASED-SESSION'}),
    );
    service = BilibiliDownloadService(
      apiService: api,
      publicApi: BilibiliPublicApiService(httpClientAdapter: adapter),
    );
  });

  tearDown(() async {
    await service.waitForPendingStreamCardData();
    await service.shutdown();
    service.dispose();
    library?.resetLibraryForTesting();
    library = null;
    SettingsService().resetForTest();
    SettingsService().largeDataRootPath = null;
    PathProviderPlatform.instance = originalPaths;
    await root.delete(recursive: true);
  });

  for (final input in [
    _short,
    _season,
    'https://m.bilibili.com/cheese/play/ep551412',
  ]) {
    test('$input imports every lesson with its course identity', () async {
      final task = (await service.parseSingleLine(input))!;
      expect(task.collectionInfo!.title, '单词革命丨超神单词');
      expect(task.videos, hasLength(201));
      expect(task.videos.first.videoInfo.title, '「alt」');
      expect(task.videos.last.videoInfo.title, '「cook」');
      final info = task.videos.first.videoInfo;
      expect(info.bvid, bvidFromAid(1902144348));
      expect(info.ownerName, '单词革命');
      expect(info.pages.single.duration, 492);
      expect(info.pages.single.courseEpisodeId, 551412);
      expect(
        task.videos.first.sourceRef!.value,
        'https://www.bilibili.com/cheese/play/ep551412',
      );
      expect(task.videos.last.episodes.single.page.courseEpisodeId, 2592321);
      expect(
        task.videos.every((v) => v.isSelected && v.episodes.single.isSelected),
        isTrue,
      );
      // Permission-dependent catalogue flags never hide a purchased lesson.
      expect(task.videos.last.episodes.single.page.cid, 38766054586);
      final catalogueRequest = adapter.requests.last;
      expect(catalogueRequest.uri.path, '/pugv/view/web/season');
      expect(_hasSession(catalogueRequest), isTrue);
      for (final r in adapter.requests.where((r) => r.uri.host == 'b23.tv')) {
        expect(_hasSession(r), isFalse);
      }
    });
  }

  test(
    'restored download task requests the paid course endpoint with login',
    () async {
      final parsed = (await service.parseSingleLine(_season))!;
      final restored = BilibiliDownloadTask.fromJson(
        jsonDecode(jsonEncode(parsed.toJson())),
      );
      service.tasks.add(restored);
      final lesson = restored.videos.last.episodes.single;
      await service.fetchEpisodeInfo(lesson);
      expect(lesson.error, isNull);
      expect(lesson.availableVideoQualities.single.id, 80);
      final request = adapter.requests.singleWhere(
        (r) => r.uri.path.endsWith('/playurl'),
      );
      expect(request.uri.path, '/pugv/player/web/playurl');
      expect(request.queryParameters['ep_id'], 2592321);
      expect(request.queryParameters.containsKey('try_look'), isFalse);
      expect(_hasSession(request), isTrue);
      expect(restored.videos.last.sourceRef!.bilibiliCourseEpisodeId, 2592321);
    },
  );

  test(
    'online library card survives restart and still uses course playback',
    () async {
      final parsed = (await service.parseSingleLine(_season))!;
      library = LibraryService()..resetLibraryForTesting();
      await library!.init();
      final video = parsed.videos.last;
      final result = await service.obtainStreamCard(
        library!,
        videoInfo: video.videoInfo,
        page: video.episodes.single.page,
        originalSourceValue: video.sourceRef!.value,
        reuseExisting: false,
        deferPlayerData: true,
      );
      expect(result.item.sourceRef!.bilibiliCourseEpisodeId, 2592321);
      expect(
        result.item.sourceRef!.originalValue,
        'https://www.bilibili.com/cheese/play/ep2592321',
      );
      await service.waitForPendingStreamCardData();
      final id = result.item.id;
      library!.resetLibraryForTesting();
      await library!.init();
      final restored = library!.bilibiliStreamItems.singleWhere(
        (v) => v.id == id,
      );
      expect(restored.sourceRef!.bilibiliCourseEpisodeId, 2592321);
      final freshApi = BilibiliApiService(
        httpClientAdapter: adapter,
        cookieStore: _Cookies({'SESSDATA': 'TEST-PURCHASED-SESSION'}),
      );
      final streaming = BilibiliStreamingService(freshApi);
      try {
        final qualities = await streaming.listQualities(restored);
        expect(qualities.single.id, 80);
        final playback = await streaming.prepare(restored);
        expect(playback.selectedQuality.id, 80);
        await streaming.releasePlayback(playback);
      } finally {
        await streaming.shutdown();
      }
      final requests = adapter.requests.where(
        (r) => r.uri.path.endsWith('/playurl'),
      );
      expect(requests, isNotEmpty);
      expect(
        requests.every(
          (r) => r.uri.path == '/pugv/player/web/playurl' && _hasSession(r),
        ),
        isTrue,
      );
    },
  );

  test('source copies and legacy sources retain compatible JSON', () {
    const source = MediaSourceRef(
      value: 'BV1xx411c7mD',
      kind: MediaSourceKind.bilibiliStream,
      bilibiliCourseEpisodeId: 551412,
    );
    expect(
      MediaSourceRef.fromJson(
        source.toJson(),
      ).copyWith(cid: 42).bilibiliCourseEpisodeId,
      551412,
    );
    expect(
      source.copyWith(bilibiliCourseEpisodeId: null).bilibiliCourseEpisodeId,
      isNull,
    );
    expect(
      MediaSourceRef.fromJson({
        'value': 'BV1xx411c7mD',
        'kind': 'bilibiliStream',
      }).bilibiliCourseEpisodeId,
      isNull,
    );
  });

  test(
    'paginated courses load all pages rather than a partial window',
    () async {
      adapter.partial = true;
      final task = (await service.parseSingleLine(_season))!;
      expect(task.videos, hasLength(201));
      expect(task.videos.first.videoInfo.title, '「alt」');
      expect(task.videos.last.videoInfo.title, '「cook」');
      expect(
        adapter.requests
            .where((r) => r.uri.path.endsWith('/ep/list'))
            .map((r) => r.queryParameters['pn']),
        [1, 2, 3],
      );
    },
  );

  for (final repeat in [false, true]) {
    test('incomplete course pages fail clearly (repeat=$repeat)', () async {
      adapter.partial = true;
      adapter.repeatPage = repeat;
      adapter.truncate = !repeat;
      await expectLater(
        service.parseSingleLine(_season),
        throwsA(isA<StateError>()),
      );
    });
  }

  test(
    'missing purchase rights report the active account instead of falling back',
    () async {
      final loggedOut = BilibiliApiService(
        httpClientAdapter: adapter,
        cookieStore: _Cookies({}),
      );
      await expectLater(
        loggedOut.fetchCoursePlayUrl(2592321),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('购买课程的账号'),
          ),
        ),
      );
      expect(adapter.requests.single.uri.path, '/pugv/player/web/playurl');
    },
  );

  test(
    'server preview marker remains visible to complete-media validation',
    () async {
      adapter.preview = true;
      final info = await api.fetchCoursePlayUrl(2592321);
      expect(info.isPreview, isTrue);
    },
  );

  test(
    'download parsing reports a trial instead of marking it as the full lesson',
    () async {
      final task = (await service.parseSingleLine(_season))!;
      service.tasks.add(task);
      adapter.preview = true;
      final episode = task.videos.last.episodes.single;
      await service.fetchEpisodeInfo(episode);
      expect(episode.status, DownloadStatus.failed);
      expect(episode.error, contains('试看片段'));
      expect(episode.selectedVideoQuality, isNull);
    },
  );

  test('expired course login has an actionable account message', () async {
    adapter.errorCode = -101;
    await expectLater(
      api.fetchCoursePlayUrl(2592321),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', contains('请先登录')),
      ),
    );
  });

  test(
    'classroom errors cannot become an empty successful play result',
    () async {
      adapter.errorCode = -404;
      await expectLater(
        api.fetchCoursePlayUrl(2592321),
        throwsA(isA<StateError>()),
      );
    },
  );

  test(
    'malformed course success cannot become an empty imported task',
    () async {
      adapter.noLessons = true;
      await expectLater(
        service.parseSingleLine(_season),
        throwsA(isA<StateError>()),
      );
    },
  );
}

bool _hasSession(RequestOptions r) =>
    '${r.headers['cookie'] ?? r.headers['Cookie'] ?? ''}'.contains(
      'TEST-PURCHASED-SESSION',
    );

class _Cookies extends BilibiliCookieStore {
  _Cookies(this.cookies);
  final Map<String, String> cookies;
  @override
  Future<Map<String, String>> readCookies() async => cookies;
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

class _CourseAdapter implements HttpClientAdapter {
  final Map<String, dynamic> fixture = jsonDecode(
    File('test/fixtures/bilibili_course_reference.json').readAsStringSync(),
  );
  final List<RequestOptions> requests = [];
  bool partial = false;
  bool repeatPage = false;
  bool truncate = false;
  bool preview = false;
  bool noLessons = false;
  int? errorCode;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.uri.host == 'b23.tv') {
      return ResponseBody.fromString(
        '',
        302,
        headers: {
          'location': [
            'https://m.bilibili.com/cheese/play/ss15549?share_source=COPY',
          ],
        },
      );
    }
    final data = fixture['data'] as Map<String, dynamic>;
    final episodes = data['episodes'] as List;
    if (options.uri.path.endsWith('/pugv/view/web/season')) {
      return _json({
        'code': 0,
        'data': {
          ...data,
          if (partial) 'episodes': episodes.sublist(100, 120),
          if (partial) 'episode_page': {'next': true},
          if (noLessons) 'episodes': [],
          if (noLessons) 'ep_count': 0,
        },
      });
    }
    if (options.uri.path.endsWith('/pugv/view/web/ep/list')) {
      final pn = repeatPage ? 1 : options.queryParameters['pn'] as int;
      final start = (pn - 1) * 100;
      final end = (start + 100).clamp(0, episodes.length);
      return _json({
        'code': 0,
        'data': {
          'items': episodes.sublist(start, end),
          'page': {'next': repeatPage || !truncate && end < episodes.length},
        },
      });
    }
    if (options.uri.path.endsWith('/pugv/player/web/playurl')) {
      if (errorCode != null) return _json({'code': errorCode});
      if (!_hasSession(options)) {
        return _json({'code': -403, 'message': '访问权限不足'});
      }
      return _json({
        'code': 0,
        'data': {
          'is_preview': preview ? 1 : 0,
          'timelength': 66000,
          'dash': {
            'duration': 66,
            'video': [
              {
                'id': 80,
                'baseUrl': 'https://cn.example.bilivideo.com/video.m4s',
                'bandwidth': 100000,
                'codecs': 'avc1.640028',
                'codecid': 7,
                'width': 1920,
                'height': 1080,
                'frameRate': '30',
                'SegmentBase': {
                  'Initialization': '0-999',
                  'indexRange': '1000-1999',
                },
              },
            ],
            'audio': [
              {
                'id': 30280,
                'baseUrl': 'https://cn.example.bilivideo.com/audio.m4s',
                'bandwidth': 10000,
                'codecs': 'mp4a.40.2',
                'SegmentBase': {
                  'Initialization': '0-899',
                  'indexRange': '900-1799',
                },
              },
            ],
          },
        },
      });
    }
    // Optional subtitles, sprites and covers do not block a course card.
    return _json({'code': -404});
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body) => ResponseBody.fromString(
  jsonEncode(body),
  200,
  headers: {
    Headers.contentTypeHeader: ['application/json; charset=utf-8'],
  },
);
