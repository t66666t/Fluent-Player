import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_cookie_store.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_subtitle_tracks.dart';

// The app's sources against answers shaped like Bilibili's, served by a fake
// HTTP adapter (nothing goes over the network). The player answer depends on
// whether the request carried the login, as on the real service.

const _bvid = 'BV1GJ411x7h7';
const _cid = 101;

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);

  ResponseBody Function(RequestOptions options) respond;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, {int status = 200}) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

class _Storage implements BilibiliSecretStorage {
  String? value;

  @override
  Future<String?> read(String key) async => value;
  @override
  Future<void> write(String key, String value) async => this.value = value;
  @override
  Future<void> delete(String key) async => value = null;
}

bool _withLogin(RequestOptions options) {
  final header = (options.headers['cookie'] ?? options.headers['Cookie'] ?? '')
      .toString();
  return header.contains('SESSDATA=');
}

Map<String, dynamic> _sub(
  int id,
  String lan,
  String doc, {
  String url = '',
  bool lock = false,
}) => <String, dynamic>{
  'id': id,
  'id_str': '$id',
  'lan': lan,
  'lan_doc': doc,
  'is_lock': lock,
  'subtitle_url': url,
  'type': lan.startsWith('ai-') ? 1 : 0,
};

Map<String, dynamic> _player(
  List<Map<String, dynamic>> subs, {
  required bool needLogin,
}) => <String, dynamic>{
  'code': 0,
  'message': '0',
  'data': <String, dynamic>{
    'bvid': _bvid,
    'cid': _cid,
    'need_login_subtitle': needLogin,
    'subtitle': <String, dynamic>{'subtitles': subs},
  },
};

final _nav = <String, dynamic>{
  'code': -101,
  'message': '账号未登录',
  'data': <String, dynamic>{
    'isLogin': false,
    'wbi_img': <String, dynamic>{
      'img_url':
          'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
      'sub_url':
          'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
    },
  },
};

final _view = <String, dynamic>{
  'code': 0,
  'message': '0',
  'data': <String, dynamic>{
    'bvid': _bvid,
    'cid': _cid,
    'subtitle': <String, dynamic>{
      'allow_submit': false,
      'list': <Object?>[
        _sub(1, 'zh-CN', '中文（中国）', lock: true),
        _sub(2, 'zh-Hant', '中文（繁体）', lock: true),
        _sub(3, 'ai-zh', '中文（自动生成）', lock: true),
      ],
    },
  },
};

void main() {
  late Directory dir;
  late _Storage storage;
  late _Adapter adapter;
  late BilibiliApiService api;
  late BilibiliSubtitleTracks tracks;
  late VideoItem item;
  var loginAnswerFails = false;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('bili_sub_app_source_');
    storage = _Storage();
    loginAnswerFails = false;
    adapter = _Adapter((options) {
      final path = options.uri.path;
      if (path.endsWith('/x/web-interface/nav')) return _json(_nav);
      if (path.endsWith('/x/web-interface/view')) return _json(_view);
      if (path.endsWith('/x/player/wbi/v2')) {
        if (!_withLogin(options)) {
          return _json(_player(const [], needLogin: true));
        }
        if (loginAnswerFails) return _json({'code': -500}, status: 500);
        return _json(
          _player([
            _sub(
              1,
              'zh-CN',
              '中文（中国）',
              url: '//aisubtitle.hdslb.com/bfs/subtitle/zh.json',
            ),
            _sub(
              2,
              'zh-Hant',
              '中文（繁体）',
              url: '//aisubtitle.hdslb.com/bfs/subtitle/hant.json',
            ),
            _sub(
              3,
              'ai-zh',
              '中文（自动生成）',
              url: '//aisubtitle.hdslb.com/bfs/ai_subtitle/prod/x?auth_key=k',
            ),
          ], needLogin: false),
        );
      }
      return _json({'code': -404}, status: 404);
    });
    api = BilibiliApiService(
      cookieStore: BilibiliCookieStore(
        storage: storage,
        dataDirectory: () async => dir,
      ),
      httpClientAdapter: adapter,
    );
    item = VideoItem(
      id: 'a',
      path: 'bilibili://stream/$_bvid?cid=$_cid',
      title: '测试',
      durationMs: 1000,
      lastUpdated: 0,
      sourceRef: const MediaSourceRef(
        value: _bvid,
        kind: MediaSourceKind.bilibiliStream,
        bvid: _bvid,
        cid: _cid,
      ),
    );
    tracks = BilibiliSubtitleTracks(
      source: BilibiliSubtitleTrackSource.app(
        api: api,
        publicApi: BilibiliPublicApiService(httpClientAdapter: adapter),
      ),
      store: BilibiliSubtitleTrackStore(
        itemOf: (id) => id == item.id ? item : null,
        noteChanged: (id) async {},
        writeSubtitle: (id, label, contents) async => '',
      ),
    );
  });

  tearDown(() {
    tracks.dispose();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('logged out: greyed names from the video info and the login line; '
      'the public request carries no login', () async {
    await tracks.ensureLoaded('a');
    final list = tracks.listFor('a');
    expect(list.tracks, isEmpty);
    expect(list.locked.map((t) => t.label), ['中文（中国）', '中文（繁体）', '中文（自动生成）']);
    expect(list.loginMessage, '这个视频有字幕，登录后可加载');
    expect(list.emptyMessage, isNull);
    final players = adapter.requests.where(
      (r) => r.uri.path.endsWith('/x/player/wbi/v2'),
    );
    expect(players, hasLength(1));
    expect(players.every((r) => !_withLogin(r)), isTrue);
  });

  test('logged in: CC and AI tracks from the logged-in answer', () async {
    storage.value = jsonEncode({'SESSDATA': 'test-session'});
    await tracks.ensureLoaded('a');
    final list = tracks.listFor('a');
    expect(list.tracks.map((t) => '${t.lan}/${t.isAi}'), [
      'zh-CN/false',
      'zh-Hant/false',
      'ai-zh/true',
    ]);
    expect(list.tracks.every((t) => t.url.startsWith('https://')), isTrue);
    expect(list.loginMessage, isNull);
    expect(list.locked, isEmpty);
  });

  test('logged-in answer fails: a retry line, not "no subtitles"', () async {
    storage.value = jsonEncode({'SESSDATA': 'test-session'});
    loginAnswerFails = true;
    await tracks.ensureLoaded('a');
    var list = tracks.listFor('a');
    expect(list.failed, isTrue);
    expect(list.failureMessage, '字幕列表暂时拿不到，点一下重试');
    expect(list.emptyMessage, isNull);

    loginAnswerFails = false;
    await tracks.reload('a');
    list = tracks.listFor('a');
    expect(list.tracks, hasLength(3));
  });

  test('logout drops the list; asked again it is the logged-out one', () async {
    storage.value = jsonEncode({'SESSDATA': 'test-session'});
    await tracks.ensureLoaded('a');
    expect(tracks.listFor('a').tracks, hasLength(3));
    await api.logout();
    expect(tracks.needsAsking('a'), isTrue);
    await tracks.ensureLoaded('a');
    final list = tracks.listFor('a');
    expect(list.tracks, isEmpty);
    expect(list.locked, hasLength(3));
  });
}
