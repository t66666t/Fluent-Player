import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_device_identity.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';

const favoriteFoldersPath = '/x/v3/fav/folder/created/list';
const favoriteVideosPath = '/x/v3/fav/resource/list';
const favoriteTestBvid = 'BV1GJ411x7h7';

Map<String, dynamic> favoriteFolderJson({
  int id = 41,
  int mid = 7,
  String title = '学习收藏夹',
  int count = 2,
  int attr = 0,
}) => {
  'id': id,
  'mid': mid,
  'title': title,
  'media_count': count,
  'attr': attr,
  'cover': '//i0.hdslb.com/bfs/archive/folder.jpg',
  'upper': {'mid': mid},
};

Map<String, dynamic> favoriteVideoJson({
  int id = 91,
  String bvid = favoriteTestBvid,
  String title = '收藏的视频',
  int attr = 0,
  int type = 2,
}) => {
  'id': id,
  'bvid': bvid,
  'type': type,
  'title': title,
  'attr': attr,
  'cover': 'http://i0.hdslb.com/bfs/archive/video.jpg@672w_378h_1c.webp',
  'upper': {'mid': 17, 'name': '视频作者'},
  'duration': 125,
  'fav_time': 1700000000,
};

Map<String, dynamic> favoriteFoldersAnswer({
  List<Map<String, dynamic>>? folders,
  int count = 1,
  bool more = false,
}) => {
  'code': 0,
  'data': {
    'list': folders ?? [favoriteFolderJson()],
    'count': count,
    'has_more': more,
  },
};

Map<String, dynamic> favoriteVideosAnswer({
  Map<String, dynamic>? folder,
  List<Map<String, dynamic>>? videos,
  bool more = false,
}) => {
  'code': 0,
  'data': {
    'info': folder ?? favoriteFolderJson(),
    'medias':
        videos ??
        [
          favoriteVideoJson(),
          favoriteVideoJson(id: 92, title: '已失效视频', attr: 9),
        ],
    'has_more': more,
  },
};

ResponseBody favoriteJson(Object? payload, {int status = 200}) =>
    ResponseBody.fromString(
      jsonEncode(payload),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

class FavoriteTestAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final Map<String, FutureOr<ResponseBody> Function(RequestOptions)> routes = {
    favoriteFoldersPath: (_) => favoriteJson(favoriteFoldersAnswer()),
    favoriteVideosPath: (_) => favoriteJson(favoriteVideosAnswer()),
    '/x/web-interface/nav': (_) => favoriteJson({
      'code': -101,
      'data': {
        'wbi_img': {
          'img_url':
              'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
          'sub_url':
              'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
        },
      },
    }),
  };

  List<RequestOptions> to(String path) =>
      requests.where((r) => r.uri.path == path).toList();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final route = routes[options.uri.path];
    if (route == null) {
      throw StateError('Unexpected request: ${options.uri.path}');
    }
    return route(options);
  }

  @override
  void close({bool force = false}) {}
}

BilibiliPublicApiService favoriteTestApi(
  FavoriteTestAdapter adapter, {
  BilibiliLoginCookieSource? cookies,
}) => BilibiliPublicApiService(
  httpClientAdapter: adapter,
  loginCookies: cookies ?? () async => {'SESSDATA': 'test-session'},
  identitySource: BilibiliDeviceIdentitySource(
    fetchFingerprint: () async => (b3: 'NEW-DEVICE', b4: 'NEW-DEVICE-4'),
    store: MemoryBilibiliDeviceIdentityStore(
      const BilibiliDeviceIdentity(
        buvid3: 'DEVICE',
        buvid4: 'DEVICE-4',
        bNut: '1700000000',
        uuid: 'DEVICE-ID',
      ),
    ),
  ),
);

class FavoriteTestAccountApi extends BilibiliApiService {
  FavoriteTestAccountApi() {
    cachedLoginState = state;
  }

  BilibiliLoginState state = const BilibiliLoginState(
    BilibiliLoginStatus.loggedIn,
    account: BilibiliAccountInfo(mid: 7, name: '收藏用户', avatarUrl: ''),
  );
  final changes = ValueNotifier<int>(0);
  Completer<BilibiliLoginState>? pendingLogin;

  @override
  ValueListenable<int> get loginChanges => changes;
  @override
  Future<void> init() async {}
  @override
  Future<BilibiliLoginState> fetchLoginState() async =>
      pendingLogin?.future ?? state;
  @override
  Future<Map<String, String>> readLoginCookies() async => state.account == null
      ? {}
      : {'SESSDATA': 'session-${state.account!.mid}'};

  void switchTo(int? mid) {
    state = mid == null
        ? const BilibiliLoginState(BilibiliLoginStatus.loggedOut)
        : BilibiliLoginState(
            BilibiliLoginStatus.loggedIn,
            account: BilibiliAccountInfo(
              mid: mid,
              name: '用户$mid',
              avatarUrl: '',
            ),
          );
    cachedLoginState = state;
    changes.value++;
  }
}
