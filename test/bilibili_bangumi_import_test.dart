import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Selected fields from the six user-supplied links, captured 2026-10-23.
  final seasons =
      jsonDecode(
            File(
              'test/fixtures/bilibili_bangumi_reference.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  const expectedTitles = {
    '273401': ['第1集 玩具大赛', '第2集 冰淇淋大战', '第3集 牙膏促销战'],
    '5528791': ['原版', '中文版'],
    '341309': ['第1集 两面宿傩', '第2集 为了自己', '第3集 铁娘子'],
    '4280680': ['第1期 实力歌手组队竞演', '第1期舞台纯享 张靓颖陈楚生神级合作', '第1期加更 黄子弘凡杨丞琳唱街角的晚风'],
    '6084344': ['正片'],
    '673044': ['原版', '中文'],
  };

  late BilibiliDownloadService service;
  late _SeasonAdapter adapter;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    adapter = _SeasonAdapter(seasons);
    service = BilibiliDownloadService(
      apiService: BilibiliApiService(httpClientAdapter: adapter),
      publicApi: BilibiliPublicApiService(httpClientAdapter: adapter),
    );
  });

  tearDown(() {
    service.dispose();
    SettingsService().resetForTest();
  });

  for (final entry in expectedTitles.entries) {
    test(
      'ep${entry.key}: short and full links produce the same season',
      () async {
        final short = (await service.parseSingleLine(
          '【APP分享】 https://b23.tv/ep${entry.key}',
        ))!;
        final full = (await service.parseSingleLine(
          'https://www.bilibili.com/bangumi/play/ep${entry.key}',
        ))!;
        expect(short.collectionInfo?.title, seasons[entry.key]['title']);
        expect(short.videos, hasLength(seasons[entry.key]['episodes'].length));
        expect(
          short.videos.take(entry.value.length).map((v) => v.videoInfo.title),
          entry.value,
        );
        expect(_identity(short), _identity(full));
        for (final video in short.videos) {
          expect(video.episodes.single.page.part, video.videoInfo.title);
          expect(video.videoInfo.pages.single.part, video.videoInfo.title);
          expect(video.episodes.single.isSelected, isTrue);
        }
        // Explicit EP addresses must not depend on the short-link server.
        expect(adapter.requests, hasLength(2));
        expect(
          adapter.requests.every((r) => r.uri.host == 'api.bilibili.com'),
          isTrue,
        );
      },
    );
  }

  test('SS aliases resolve the complete season by season_id', () async {
    final id = seasons['273401']['season_id'];
    final task = (await service.parseSingleLine('https://b23.tv/ss$id'))!;
    expect(task.videos, hasLength(15));
    expect(task.videos.first.videoInfo.title, '第1集 玩具大赛');
    expect(adapter.requests.single.queryParameters, {'season_id': '$id'});
  });

  test(
    'episode labels come from metadata, including gaps and specials',
    () async {
      seasons['test'] = {
        'title': '编号边界',
        'episodes': [
          {'title': '7', 'long_title': '故事'},
          {'title': '12.5', 'long_title': '间章'},
          {'title': 'SP', 'long_title': '幕后'},
          {'title': '第8集', 'long_title': '第8集 已有编号'},
          {'title': '9', 'long_title': ''},
          {'title': ' 原版 ', 'long_title': '原版'},
          {'title': '', 'long_title': '特别篇'},
          {'title': '', 'long_title': ''},
        ],
      };
      // An unused numeric EP id points at the synthetic edge-case payload.
      seasons['999999'] = seasons['test'];
      final task = (await service.parseSingleLine('ep999999'))!;
      expect(task.videos.map((v) => v.videoInfo.title), [
        '第7集 故事',
        '第12.5集 间章',
        'SP 幕后',
        '第8集 已有编号',
        '第9集',
        '原版',
        '特别篇',
        'EP8',
      ]);
    },
  );
}

List<Object> _identity(BilibiliDownloadTask task) => [
  task.collectionInfo!.title,
  for (final video in task.videos)
    [
      video.videoInfo.title,
      video.videoInfo.bvid,
      video.episodes.single.page.cid,
    ],
];

class _SeasonAdapter implements HttpClientAdapter {
  _SeasonAdapter(this.seasons);

  final Map<String, dynamic> seasons;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.uri.host != 'api.bilibili.com' ||
        options.uri.path != '/pgc/view/web/season') {
      throw StateError('Unexpected request: ${options.uri}');
    }
    final epId = options.queryParameters['ep_id'];
    final data = epId != null
        ? seasons[epId]
        : seasons.values.firstWhere(
            (s) => '${s['season_id']}' == options.queryParameters['season_id'],
          );
    return ResponseBody.fromString(
      jsonEncode({'code': 0, 'result': data}),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
