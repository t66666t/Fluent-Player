import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/models/managed_subtitle_asset.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_subtitle_tracks.dart';

const _bvid = 'BV1xx411c7mD';

// ---- Answers shaped like Bilibili's (player `x/player/wbi/v2`, video info
// `x/web-interface/view`), as seen logged out and logged in.

Map<String, dynamic> _sub(
  String lan,
  String doc, {
  int id = 0,
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
  'author': <String, dynamic>{'mid': 0},
};

Map<String, dynamic> _cc(String lan, String doc, {int id = 0}) => _sub(
  lan,
  doc,
  id: id,
  url: '//aisubtitle.hdslb.com/bfs/subtitle/$lan.json',
);

Map<String, dynamic> _ai(
  String lan,
  String doc, {
  int id = 0,
  String key = 'a',
}) => _sub(
  lan,
  doc,
  id: id,
  url: '//aisubtitle.hdslb.com/bfs/ai_subtitle/prod/$lan?auth_key=$key',
);

Map<String, dynamic> _player(
  List<Map<String, dynamic>> subtitles, {
  bool needLogin = false,
  int code = 0,
}) => <String, dynamic>{
  'code': code,
  'message': code == 0 ? '0' : '错误',
  'ttl': 1,
  if (code == 0)
    'data': <String, dynamic>{
      'aid': 1,
      'bvid': _bvid,
      'cid': 101,
      'need_login_subtitle': needLogin,
      'subtitle': <String, dynamic>{
        'allow_submit': false,
        'lan': '',
        'lan_doc': '',
        'subtitles': subtitles,
      },
    },
};

/// Logged out: the player answer has no track and asks for a login.
final Map<String, dynamic> _lockedPlayer = _player(const [], needLogin: true);

Map<String, dynamic> _view(List<Map<String, dynamic>> list, {int cid = 101}) =>
    <String, dynamic>{
      'bvid': _bvid,
      'cid': cid,
      'pages': <Object?>[
        <String, dynamic>{'cid': cid, 'page': 1, 'part': 'P1'},
      ],
      'subtitle': <String, dynamic>{'allow_submit': false, 'list': list},
    };

/// Logged out, the video info lists every subtitle locked, without address.
final List<Map<String, dynamic>> _lockedList = <Map<String, dynamic>>[
  _sub('zh-CN', '中文（中国）', id: 11, lock: true),
  _sub('zh-Hans', '中文（简体）', id: 12, lock: true),
  _sub('zh-Hant', '中文（繁体）', id: 13, lock: true),
  _sub('ai-zh', '中文（自动生成）', id: 14, lock: true),
];

const _json = <String, Object?>{
  'body': <Object?>[
    <String, Object?>{'from': 0.0, 'to': 1.5, 'content': '你好'},
  ],
};

VideoItem _online(String id, {int cid = 101}) => VideoItem(
  id: id,
  path: 'bilibili://stream/$_bvid?cid=$cid',
  title: '测试',
  durationMs: 600000,
  lastUpdated: 0,
  sourceRef: MediaSourceRef(
    value: _bvid,
    kind: MediaSourceKind.bilibiliStream,
    bvid: _bvid,
    cid: cid,
    page: cid - 100,
  ),
);

class _Fake {
  _Fake(this.dir);

  final Directory dir;
  final Map<String, VideoItem> items = <String, VideoItem>{};
  final changes = ChangeNotifier();
  final login = ValueNotifier<int>(0);
  bool loggedIn = false;
  Object? loginCheckError;
  Map<int, Map<String, dynamic>> public = <int, Map<String, dynamic>>{};
  Map<int, Map<String, dynamic>> withLogin = <int, Map<String, dynamic>>{};
  Map<int, Map<String, dynamic>> view = <int, Map<String, dynamic>>{};
  Object? publicError;
  Object? loginError;
  Object? viewError;
  Future<bool> Function(String itemId)? completePending;
  final List<int> publicCalls = <int>[];
  final List<int> loginCalls = <int>[];
  final List<int> viewCalls = <int>[];
  int loginChecks = 0;
  final List<String> contentCalls = <String>[];
  int noted = 0;

  int get requests => publicCalls.length + loginCalls.length + viewCalls.length;

  BilibiliSubtitleTracks build() => BilibiliSubtitleTracks(
    source: BilibiliSubtitleTrackSource(
      fetchPublicAnswer: (bvid, cid) async {
        publicCalls.add(cid);
        final error = publicError;
        if (error != null) throw error;
        return parseBilibiliSubtitleAnswer(
          public[cid] ?? _player(const <Map<String, dynamic>>[]),
        );
      },
      fetchLoggedInAnswer: (bvid, cid) async {
        loginCalls.add(cid);
        final error = loginError;
        if (error != null) throw error;
        return parseBilibiliSubtitleAnswer(
          withLogin[cid] ?? _player(const <Map<String, dynamic>>[]),
        );
      },
      fetchLockedTracks: (bvid, cid) async {
        viewCalls.add(cid);
        final error = viewError;
        if (error != null) throw error;
        return parseBilibiliLockedSubtitleTracks(
          view[cid] ?? _view(const <Map<String, dynamic>>[], cid: cid),
          cid,
        );
      },
      isLoggedIn: () async {
        loginChecks++;
        final error = loginCheckError;
        if (error != null) throw error;
        return loggedIn;
      },
      fetchContent: (url) async {
        contentCalls.add(url);
        return _json;
      },
      completePending: (id) => completePending?.call(id) ?? Future.value(false),
      loginChanges: login,
    ),
    store: BilibiliSubtitleTrackStore(
      itemOf: (id) => items[id],
      noteChanged: (id) async => noted++,
      writeSubtitle: (id, label, contents) async {
        final file = File(p.join(dir.path, id, '$label.srt'));
        await file.create(recursive: true);
        await file.writeAsString(contents);
        return file.path;
      },
      changes: changes,
    ),
  );
}

List<BilibiliSubtitleTrack> _tracks(List<Map<String, dynamic>> raw) =>
    parseBilibiliSubtitleTracks(_player(raw)['data']);

void main() {
  late Directory dir;
  late _Fake fake;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bili_sub_tracks_');
    fake = _Fake(dir);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  group('parsing', () {
    test('CC tracks: name, code, id and https address', () {
      final tracks = _tracks([
        _cc('zh-CN', '中文（中国）', id: 7),
        _cc('en-US', '英语'),
      ]);
      expect(tracks.map((t) => t.label), ['中文（中国）', '英语']);
      expect(tracks.map((t) => t.lan), ['zh-CN', 'en-US']);
      expect(tracks.map((t) => t.id), ['7', '']);
      expect(tracks.every((t) => !t.isAi && !t.locked), isTrue);
      expect(tracks.first.url, startsWith('https://aisubtitle.hdslb.com/'));
    });

    test('AI tracks are marked by their ai- code or their name', () {
      final tracks = _tracks([
        _ai('ai-zh', '中文'),
        _cc('zh-Hans', '中文（自动生成）'),
        _cc('th', 'Thai'),
      ]);
      expect(tracks.map((t) => t.isAi), [true, true, false]);
    });

    test('a track listed twice is kept once (same id, or same address '
        'apart from its key)', () {
      final tracks = _tracks([
        _cc('zh-CN', '中文', id: 7),
        _sub('zh-CN', '中文', id: 7, url: 'http://other.hdslb.com/x.json'),
        _ai('ai-zh', '中文（自动生成）', key: 'one'),
        _ai('ai-zh', '中文（自动生成）', key: 'two'),
      ]);
      expect(tracks.map((t) => t.lan), ['zh-CN', 'ai-zh']);
    });

    test('no subtitles: missing, empty or locked without address', () {
      expect(parseBilibiliSubtitleTracks(null), isEmpty);
      expect(parseBilibiliSubtitleTracks(<String, Object?>{}), isEmpty);
      expect(_tracks(const []), isEmpty);
      expect(_tracks(_lockedList), isEmpty);
    });

    test('player answer: need_login_subtitle, -101, refusals', () {
      final locked = parseBilibiliSubtitleAnswer(_lockedPlayer);
      expect(locked.tracks, isEmpty);
      expect(locked.needsLogin, isTrue);

      final open = parseBilibiliSubtitleAnswer(_player([_cc('en', '英语')]));
      expect(open.tracks, hasLength(1));
      expect(open.needsLogin, isFalse);

      final rejected = parseBilibiliSubtitleAnswer(<String, dynamic>{
        'code': -101,
        'message': '账号未登录',
      });
      expect(rejected.needsLogin, isTrue);

      expect(
        () => parseBilibiliSubtitleAnswer(_player(const [], code: -404)),
        throwsA(isA<BilibiliSubtitleListException>()),
      );
      expect(
        () => parseBilibiliSubtitleAnswer(<String, dynamic>{
          'code': -412,
          '__http': 412,
        }),
        throwsA(isA<BilibiliSubtitleListException>()),
      );
    });

    test('video info: locked names of the part it describes only', () {
      final names = parseBilibiliLockedSubtitleTracks(_view(_lockedList), 101);
      expect(names.map((t) => t.label), [
        '中文（中国）',
        '中文（简体）',
        '中文（繁体）',
        '中文（自动生成）',
      ]);
      expect(names.every((t) => t.locked && t.url.isEmpty), isTrue);
      expect(names.map((t) => t.isAi), [false, false, false, true]);
      // It describes the first part; another part learns nothing from it.
      expect(
        parseBilibiliLockedSubtitleTracks(_view(_lockedList), 102),
        isEmpty,
      );
      expect(parseBilibiliLockedSubtitleTracks(null, 101), isEmpty);
    });
  });

  group('logged out', () {
    test('subtitles kept for logged-in users: greyed names and the login '
        'line, never "no subtitles"', () async {
      fake
        ..items['a'] = _online('a')
        ..public[101] = _lockedPlayer
        ..view[101] = _view(_lockedList);
      final tracks = fake.build();
      await tracks.ensureLoaded('a');
      final list = tracks.listFor('a');
      expect(list.tracks, isEmpty);
      expect(list.locked.map((t) => t.label), [
        '中文（中国）',
        '中文（简体）',
        '中文（繁体）',
        '中文（自动生成）',
      ]);
      expect(list.needsLogin, isTrue);
      expect(list.loginMessage, '这个视频有字幕，登录后可加载');
      expect(list.emptyMessage, isNull);
      expect(list.failureMessage, isNull);
      expect(fake.loginCalls, isEmpty);
      expect(fake.viewCalls, [101]);
    });

    test(
      'names unavailable (or another part): the login line still says '
      'the video has subtitles (Bilibili asks for a login only then)',
      () async {
        fake
          ..items['a'] = _online('a')
          ..public[101] = _lockedPlayer
          ..viewError = const BilibiliPublicApiException('x');
        final tracks = fake.build();
        await tracks.ensureLoaded('a');
        final list = tracks.listFor('a');
        expect(list.locked, isEmpty);
        expect(list.needsLogin, isTrue);
        expect(list.loginMessage, '这个视频有字幕，登录后可加载');
        expect(list.emptyMessage, isNull);
        expect(list.failureMessage, isNull);
      },
    );

    test('names unavailable with a login Bilibili no longer accepts: the '
        'same line, asking to log in again', () async {
      fake = _Fake(dir)
        ..loggedIn = true
        ..items['a'] = _online('a')
        ..public[101] = _lockedPlayer
        ..withLogin[101] = _lockedPlayer
        ..viewError = const BilibiliPublicApiException('x');
      final tracks = fake.build();
      await tracks.ensureLoaded('a');
      final list = tracks.listFor('a');
      expect(list.locked, isEmpty);
      expect(list.loginExpired, isTrue);
      expect(list.loginMessage, '这个视频有字幕，登录已过期，重新登录后可加载');
      expect(list.emptyMessage, isNull);
    });

    test('tracks given without a login are listed, AI needs a login', () async {
      fake
        ..items['a'] = _online('a')
        ..public[101] = _player([_cc('zh-CN', '中文')]);
      final tracks = fake.build();
      await tracks.ensureLoaded('a');
      final list = tracks.listFor('a');
      expect(list.tracks.map((t) => t.label), ['中文']);
      expect(list.loginMessage, '登录后可加载 AI 字幕');
      expect(fake.viewCalls, isEmpty);
    });

    test('really no subtitle: one plain line, no login line', () async {
      fake.items['a'] = _online('a');
      final tracks = fake.build();
      await tracks.ensureLoaded('a');
      final list = tracks.listFor('a');
      expect(list.loading, isFalse);
      expect(list.emptyMessage, '这个视频没有字幕');
      expect(list.loginMessage, isNull);
      expect(list.failureMessage, isNull);
    });

    test('a locked name already saved as a file shows as the file', () async {
      final zh = File(p.join(dir.path, 'a', 'zh.srt'))
        ..createSync(recursive: true);
      fake
        ..items['a'] = (_online('a')
          ..usesManagedAssociatedSubtitles = true
          ..additionalSubtitles = <String, String>{'中文（中国）': zh.path}
          ..managedSubtitleAssets = <ManagedSubtitleAsset>[
            ManagedSubtitleAsset(
              assetId: '1',
              path: zh.path,
              kind: ManagedSubtitleAssetKind.downloaded,
              displayName: '中文（中国）',
              language: 'zh-CN',
              createdAt: 0,
            ),
          ])
        ..public[101] = _lockedPlayer
        ..view[101] = _view(_lockedList);
      final tracks = fake.build();
      await tracks.ensureLoaded('a');
      final list = tracks.listFor('a');
      expect(list.tracks.single.path, zh.path);
      expect(list.locked.map((t) => t.lan), ['zh-Hans', 'zh-Hant', 'ai-zh']);
      expect(list.loginMessage, '登录后可加载更多字幕');
    });
  });

  group('logged in', () {
    test('CC and AI tracks both come from the logged-in answer, merged with '
        'the public one, each once', () async {
      fake
        ..loggedIn = true
        ..items['a'] = _online('a')
        ..public[101] = _player([
          _cc('zh-CN', '中文（中国）', id: 11),
          _ai('ai-zh', '中文（自动生成）', id: 14, key: 'public'),
        ])
        ..withLogin[101] = _player([
          _cc('zh-CN', '中文（中国）', id: 11),
          _cc('en-US', '英语（美国）', id: 15),
          _ai('ai-zh', '中文（自动生成）', id: 14, key: 'login'),
          _cc('zh-CN', '中文（中国）', id: 11),
        ]);
      final tracks = fake.build();
      await tracks.ensureLoaded('a');
      final list = tracks.listFor('a');
      expect(list.tracks.map((t) => '${t.lan}/${t.isAi}'), [
        'zh-CN/false',
        'en-US/false',
        'ai-zh/true',
      ]);
      expect(list.tracks[2].url, contains('auth_key=login'));
      expect(list.loggedIn, isTrue);
      expect(list.loginMessage, isNull);
      expect(list.locked, isEmpty);
      expect(fake.publicCalls, [101]);
      expect(fake.loginCalls, [101]);
    });

    test('a video with CC tracks only keeps them (none is dropped as '
        '"not AI")', () async {
      fake
        ..loggedIn = true
        ..items['a'] = _online('a')
        ..public[101] = _lockedPlayer
        ..withLogin[101] = _player([
          _cc('zh-CN', '中文（中国）', id: 11),
          _cc('zh-Hant', '中文（繁体）', id: 13),
        ]);
      final tracks = fake.build();
      await tracks.ensureLoaded('a');
      final list = tracks.listFor('a');
      expect(list.tracks.map((t) => t.lan), ['zh-CN', 'zh-Hant']);
      expect(list.emptyMessage, isNull);
      expect(fake.viewCalls, isEmpty);
    });

    test('no subtitle at all: one plain line', () async {
      fake
        ..loggedIn = true
        ..items['a'] = _online('a');
      final tracks = fake.build();
      await tracks.ensureLoaded('a');
      final list = tracks.listFor('a');
      expect(list.emptyMessage, '这个视频没有字幕');
      expect(list.loginMessage, isNull);
    });

    test('a login Bilibili no longer accepts counts as logged out', () async {
      for (final rejected in <Map<String, dynamic>>[
        <String, dynamic>{'code': -101, 'message': '账号未登录'},
        _lockedPlayer,
      ]) {
        fake = _Fake(dir)
          ..loggedIn = true
          ..items['a'] = _online('a')
          ..public[101] = _lockedPlayer
          ..withLogin[101] = rejected
          ..view[101] = _view(_lockedList);
        final tracks = fake.build();
        await tracks.ensureLoaded('a');
        final list = tracks.listFor('a');
        expect(list.loggedIn, isFalse);
        expect(list.loginExpired, isTrue);
        expect(list.locked, hasLength(4));
        expect(list.loginMessage, '这个视频有字幕，登录已过期，重新登录后可加载');
        expect(list.emptyMessage, isNull);
      }
    });

    test('logged-in answer failed, public one listed tracks: those plus a '
        'retry, which then lists everything', () async {
      fake
        ..loggedIn = true
        ..items['a'] = _online('a')
        ..public[101] = _player([_cc('zh-CN', '中文（中国）', id: 11)])
        ..withLogin[101] = _player([
          _cc('zh-CN', '中文（中国）', id: 11),
          _ai('ai-zh', '中文（自动生成）', id: 14),
        ])
        ..loginError = const SocketException('offline');
      final tracks = fake.build();
      await tracks.ensureLoaded('a');
      var list = tracks.listFor('a');
      expect(list.tracks.map((t) => t.lan), ['zh-CN']);
      expect(list.failureMessage, '部分字幕暂时拿不到，点一下重试');

      fake.loginError = null;
      await tracks.reload('a');
      list = tracks.listFor('a');
      expect(list.tracks.map((t) => t.lan), ['zh-CN', 'ai-zh']);
      expect(list.failureMessage, isNull);
    });

    test('logged-in answer failed and nothing else: a failure, not "no '
        'subtitles"', () async {
      fake
        ..loggedIn = true
        ..items['a'] = _online('a')
        ..public[101] = _lockedPlayer
        ..loginError = StateError('bad answer');
      final tracks = fake.build();
      await tracks.ensureLoaded('a');
      final list = tracks.listFor('a');
      expect(list.failed, isTrue);
      expect(list.emptyMessage, isNull);
      expect(list.failureMessage, '字幕列表暂时拿不到，点一下重试');
    });

    test('risk control on the logged-in answer is a failure', () async {
      fake
        ..loggedIn = true
        ..items['a'] = _online('a')
        ..withLogin[101] = _player(const [], code: -352);
      final tracks = fake.build();
      await tracks.ensureLoaded('a');
      expect(tracks.listFor('a').failed, isTrue);
      expect(tracks.listFor('a').emptyMessage, isNull);
    });
  });

  group('failures', () {
    test('the list could not be had: a retry line, no spinner; the retry '
        'then shows the list', () async {
      fake
        ..items['a'] = _online('a')
        ..publicError = const BilibiliPublicApiException('字幕列表暂时不可用（HTTP 500）')
        ..public[101] = _lockedPlayer
        ..view[101] = _view(_lockedList);
      final tracks = fake.build();
      await tracks.ensureLoaded('a');
      var list = tracks.listFor('a');
      expect(list.loading, isFalse);
      expect(list.failed, isTrue);
      expect(list.networkFailed, isFalse);
      expect(list.failureMessage, '字幕列表暂时拿不到，点一下重试');
      expect(list.emptyMessage, isNull);
      expect(list.loginMessage, isNull);

      fake.publicError = null;
      await tracks.reload('a');
      list = tracks.listFor('a');
      expect(list.failed, isFalse);
      expect(list.locked, hasLength(4));
      expect(list.loginMessage, '这个视频有字幕，登录后可加载');
      expect(fake.publicCalls, [101, 101]);
    });

    test('no network: saved files listed, the retry line says why', () async {
      final zh = File(p.join(dir.path, 'a', '中文.srt'))
        ..createSync(recursive: true);
      fake
        ..publicError = const BilibiliPublicApiException(
          'x',
          isNetworkError: true,
        )
        ..items['a'] = (_online('a')
          ..usesManagedAssociatedSubtitles = true
          ..additionalSubtitles = <String, String>{'中文': zh.path});
      final tracks = fake.build();
      await tracks.ensureLoaded('a');
      final list = tracks.listFor('a');
      expect(list.tracks.single.path, zh.path);
      expect(list.networkFailed, isTrue);
      expect(list.emptyMessage, isNull);
      expect(list.failureMessage, '网络不通，字幕列表暂时拿不到，点一下重试');
    });

    test('a failed login check is a failure with a retry, not a spinner '
        'that never ends', () async {
      fake
        ..items['a'] = _online('a')
        ..loginCheckError = StateError('storage');
      final tracks = fake.build();
      await tracks.ensureLoaded('a');
      var list = tracks.listFor('a');
      expect(list.loading, isFalse);
      expect(list.failureMessage, '字幕列表暂时拿不到，点一下重试');
      expect(fake.requests, 0);

      fake.loginCheckError = null;
      await tracks.reload('a');
      list = tracks.listFor('a');
      expect(list.emptyMessage, '这个视频没有字幕');
    });

    test('opening the area again retries a failed list', () async {
      fake
        ..items['a'] = _online('a')
        ..publicError = const BilibiliPublicApiException('x');
      final tracks = fake.build();
      await tracks.ensureLoaded('a');
      fake
        ..publicError = null
        ..public[101] = _player([_cc('en', '英语')]);
      await tracks.ensureLoaded('a');
      expect(tracks.listFor('a').tracks.single.label, '英语');
    });
  });

  group('login changes', () {
    test('logging in drops the lists; the next ask uses the login', () async {
      fake
        ..items['a'] = _online('a')
        ..public[101] = _lockedPlayer
        ..view[101] = _view(_lockedList)
        ..withLogin[101] = _player([
          _cc('zh-CN', '中文（中国）', id: 11),
          _ai('ai-zh', '中文（自动生成）', id: 14),
        ]);
      final tracks = fake.build();
      await tracks.ensureLoaded('a');
      expect(tracks.needsAsking('a'), isFalse);
      var heard = 0;
      tracks.addListener(() => heard++);

      fake.loggedIn = true;
      fake.login.value++;
      expect(heard, 1);
      expect(tracks.needsAsking('a'), isTrue);
      await tracks.ensureLoaded('a');
      final list = tracks.listFor('a');
      expect(list.tracks.map((t) => t.lan), ['zh-CN', 'ai-zh']);
      expect(list.locked, isEmpty);
      expect(list.loginMessage, isNull);
    });

    test('a login while the list is on its way asks again after', () async {
      final gate = Completer<void>();
      fake.items['a'] = _online('a');
      final tracks = BilibiliSubtitleTracks(
        source: BilibiliSubtitleTrackSource(
          fetchPublicAnswer: (bvid, cid) async {
            await gate.future;
            return const BilibiliSubtitleAnswer(needsLogin: true);
          },
          fetchLoggedInAnswer: (bvid, cid) async =>
              const BilibiliSubtitleAnswer(),
          isLoggedIn: () async => fake.loggedIn,
          fetchContent: (url) async => _json,
          loginChanges: fake.login,
        ),
        store: BilibiliSubtitleTrackStore(
          itemOf: (id) => fake.items[id],
          noteChanged: (id) async {},
          writeSubtitle: (id, label, contents) async => '',
        ),
      );
      final first = tracks.ensureLoaded('a');
      await Future<void>.delayed(Duration.zero);
      fake.loggedIn = true;
      fake.login.value++;
      gate.complete();
      await first;
      expect(tracks.needsAsking('a'), isTrue);
      await tracks.ensureLoaded('a');
      expect(tracks.listFor('a').loggedIn, isTrue);
    });

    test('a stored login appearing later asks again (no signal)', () async {
      fake
        ..items['a'] = _online('a')
        ..public[101] = _player([_cc('zh-CN', '中文')])
        ..withLogin[101] = _player([_ai('ai-zh', '中文（自动生成）')]);
      final tracks = fake.build();
      await tracks.ensureLoaded('a');
      expect(tracks.listFor('a').tracks, hasLength(1));
      fake.loggedIn = true;
      await tracks.ensureLoaded('a');
      expect(tracks.listFor('a').tracks, hasLength(2));
      expect(tracks.listFor('a').loginMessage, isNull);
    });
  });

  test('picking a track saves it with the card and returns its file', () async {
    fake
      ..items['a'] = _online('a')
      ..public[101] = _player([_cc('en-US', '英语')]);
    final tracks = fake.build();
    await tracks.ensureLoaded('a');
    final track = tracks.listFor('a').tracks.single;
    expect(track.isDownloaded, isFalse);

    final path = await tracks.load('a', track);
    expect(path, isNotNull);
    expect(File(path!).readAsStringSync(), contains('你好'));
    final item = fake.items['a']!;
    expect(item.downloadAssociatedSubtitles.values, [path]);
    expect(item.managedSubtitleAssets.single.language, 'en-US');
    expect(
      item.managedSubtitleAssets.single.kind,
      ManagedSubtitleAssetKind.downloaded,
    );
    expect(fake.noted, 1);
    expect(tracks.listFor('a').tracks.single.path, path);

    // Picked again: the saved file, nothing fetched.
    final again = await tracks.load('a', tracks.listFor('a').tracks.single);
    expect(again, path);
    expect(fake.contentCalls, hasLength(1));
  });

  test(
    'a part still waiting for its data gets it first, no second fetch',
    () async {
      fake
        ..items['a'] = _online('a')
        ..public[101] = _player([_cc('zh-CN', '中文')]);
      fake.completePending = (id) async {
        final file = File(p.join(dir.path, 'built', '中文.srt'));
        await file.create(recursive: true);
        fake.items[id]!
          ..usesManagedAssociatedSubtitles = true
          ..additionalSubtitles = <String, String>{'中文': file.path}
          ..managedSubtitleAssets = <ManagedSubtitleAsset>[
            ManagedSubtitleAsset(
              assetId: 'x',
              path: file.path,
              kind: ManagedSubtitleAssetKind.downloaded,
              displayName: '中文',
              language: 'zh-CN',
              createdAt: 0,
            ),
          ];
        return true;
      };
      final tracks = fake.build();
      await tracks.ensureLoaded('a');
      final path = await tracks.load('a', tracks.listFor('a').tracks.single);
      expect(path, endsWith(p.join('built', '中文.srt')));
      expect(fake.contentCalls, isEmpty);
    },
  );

  test(
    'a failed fetch is reported on the track and can be tried again',
    () async {
      fake.items['a'] = _online('a');
      final tracks = fake.build();
      const track = BilibiliSubtitleTrack(lan: 'zh', label: '中文', isAi: false);
      expect(await tracks.load('a', track), isNull);
      expect(tracks.hasFailed('a', track), isTrue);
      expect(tracks.isLoading('a', track), isFalse);
    },
  );

  test('switching parts lists that part\'s tracks, each asked once', () async {
    fake
      ..items['p1'] = _online('p1', cid: 101)
      ..items['p2'] = _online('p2', cid: 102)
      ..public[101] = _player([_cc('zh-CN', '中文')])
      ..public[102] = _player([_cc('ja', '日语')]);
    final tracks = fake.build();
    await tracks.ensureLoaded('p1');
    expect(tracks.listFor('p1').tracks.single.label, '中文');
    await tracks.ensureLoaded('p2');
    expect(tracks.listFor('p2').tracks.single.label, '日语');
    await tracks.ensureLoaded('p1');
    expect(tracks.listFor('p1').tracks.single.label, '中文');
    expect(fake.publicCalls, [101, 102]);
  });

  test('downloaded video: its saved files, no request at all', () async {
    final zh = File(p.join(dir.path, 'd', '中文.srt'))
      ..createSync(recursive: true);
    final ai = File(p.join(dir.path, 'd', '中文 自动.srt'))
      ..createSync(recursive: true);
    fake.items['d'] = VideoItem(
      id: 'd',
      path: p.join(dir.path, 'video.mp4'),
      title: '已下载',
      durationMs: 1000,
      lastUpdated: 0,
      isBilibiliExported: true,
      usesManagedAssociatedSubtitles: true,
      additionalSubtitles: <String, String>{'中文': zh.path, '中文2': ai.path},
      managedSubtitleAssets: <ManagedSubtitleAsset>[
        ManagedSubtitleAsset(
          assetId: '1',
          path: zh.path,
          kind: ManagedSubtitleAssetKind.downloaded,
          displayName: '中文',
          language: 'zh-CN',
          createdAt: 0,
        ),
        ManagedSubtitleAsset(
          assetId: '2',
          path: ai.path,
          kind: ManagedSubtitleAssetKind.downloaded,
          displayName: '中文',
          language: 'ai-zh',
          createdAt: 0,
        ),
      ],
      sourceRef: const MediaSourceRef(
        value: _bvid,
        kind: MediaSourceKind.bilibiliBv,
        bvid: _bvid,
      ),
    );
    final tracks = fake.build();
    expect(BilibiliSubtitleTracks.covers(fake.items['d']), isTrue);
    await tracks.ensureLoaded('d');
    final list = tracks.listFor('d');
    expect(list.savedOnly, isTrue);
    expect(list.loading, isFalse);
    expect(list.loginMessage, isNull);
    expect(list.failureMessage, isNull);
    expect(list.tracks.map((t) => '${t.path}/${t.isAi}'), [
      '${zh.path}/false',
      '${ai.path}/true',
    ]);
    expect(await tracks.load('d', list.tracks.first), zh.path);
    expect(fake.requests, 0);
    expect(fake.loginChecks, 0);
    expect(fake.contentCalls, isEmpty);
    // A login change asks nothing for it either.
    fake.login.value++;
    expect(tracks.needsAsking('d'), isFalse);
  });

  test('saved tracks are matched to the listed ones, extra files kept', () {
    final merged = mergeBilibiliSubtitleTracks(
      _tracks([_cc('zh-CN', '中文'), _cc('en', '英语')]),
      const [
        BilibiliSubtitleTrack(
          lan: '',
          label: '英语',
          isAi: false,
          path: '/s/en.srt',
        ),
        BilibiliSubtitleTrack(
          lan: 'ai-zh',
          label: '中文（自动生成）',
          isAi: true,
          path: '/s/ai.srt',
        ),
      ],
    );
    expect(merged.map((t) => t.path), [null, '/s/en.srt', '/s/ai.srt']);
  });

  test('the list is asked once while it is on its way', () async {
    final gate = Completer<BilibiliSubtitleAnswer>();
    final calls = <int>[];
    fake.items['a'] = _online('a');
    final tracks = BilibiliSubtitleTracks(
      source: BilibiliSubtitleTrackSource(
        fetchPublicAnswer: (bvid, cid) {
          calls.add(cid);
          return gate.future;
        },
        fetchLoggedInAnswer: (bvid, cid) async =>
            const BilibiliSubtitleAnswer(),
        isLoggedIn: () async => false,
        fetchContent: (url) async => _json,
      ),
      store: BilibiliSubtitleTrackStore(
        itemOf: (id) => fake.items[id],
        noteChanged: (id) async {},
        writeSubtitle: (id, label, contents) async => '',
      ),
    );
    final first = tracks.ensureLoaded('a');
    await Future<void>.delayed(Duration.zero);
    expect(tracks.listFor('a').loading, isTrue);
    expect(tracks.listFor('a').emptyMessage, isNull);
    expect(tracks.listFor('a').failureMessage, isNull);
    await tracks.ensureLoaded('a');
    await tracks.reload('a');
    gate.complete(const BilibiliSubtitleAnswer());
    await first;
    expect(calls, [101]);
  });
}
