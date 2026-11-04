import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/models/cloud_drive_source_ref.dart';
import 'package:video_player_app/features/cloud_drive/providers/baidu_cloud_drive_provider.dart';
import 'package:video_player_app/features/cloud_drive/providers/cloud_drive_http.dart';
import 'package:video_player_app/features/cloud_drive/providers/cloud_drive_provider.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_subtitle_text.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_subtitle_tracks.dart';
import 'package:video_player_app/models/managed_subtitle_asset.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/widgets/cloud_drive_subtitle_tracks_section.dart';

class RecordingHttp implements CloudDriveHttp {
  RecordingHttp(this.pages);

  final List<CloudDriveHttpResponse> pages;
  final List<CloudDriveHttpRequest> requests = [];

  @override
  Future<CloudDriveHttpResponse> send(
    CloudDriveHttpRequest request, {
    Object? cancelToken,
  }) async {
    requests.add(request);
    if (pages.isEmpty) {
      throw StateError('no scripted response for ${request.uri}');
    }
    return pages.removeAt(0);
  }
}

CloudDriveHttpResponse page(
  String body, {
  int status = 200,
  String type = 'text/html',
}) {
  return CloudDriveHttpResponse(
    statusCode: status,
    headers: {'content-type': type},
    body: utf8.encode(body),
    finalUri: Uri.parse(
      'https://pan.baidu.com${Uri.parse('https://pan.baidu.com/api/streaming').path}',
    ),
  );
}

CloudDriveCredential jar(String value) => CloudDriveCredential(
  cookies: [
    CloudDriveCookie(name: 'BDUSS', value: value, domain: '.baidu.com'),
  ],
);

CloudDrivePlaybackRequest playback({String account = '42', String file = '9'}) {
  return CloudDrivePlaybackRequest(
    credential: jar('secret-$account'),
    accountLocalId: 'local-$account',
    remoteAccountId: account,
    driveId: '0',
    fileId: file,
    pathHint: '/课程/a.mp4',
    name: '显示标题',
    revision: 'rev-card',
  );
}

const String srtBody = '1\n00:00:00,000 --> 00:00:01,000\n你好\n';

void main() {
  test('automatic selection includes ordinary official subtitles', () {
    final human = CloudDriveListedSubtitle(
      id: 'human',
      label: '中文',
      language: 'zh',
      isAi: false,
      remote: remoteTrack('human'),
    );
    final englishAi = CloudDriveListedSubtitle(
      id: 'en-ai',
      label: '英语',
      language: 'en',
      isAi: true,
      remote: remoteTrack('en-ai', label: '英语', ai: true),
    );
    final chineseAi = CloudDriveListedSubtitle(
      id: 'zh-ai',
      label: '中文',
      language: 'zh-CN',
      isAi: true,
      remote: remoteTrack('zh-ai', ai: true),
    );
    expect(
      preferredCloudDriveAutoSubtitle([englishAi, chineseAi, human])?.id,
      'human',
    );
    expect(preferredCloudDriveAutoSubtitle([human])?.id, 'human');
    expect(preferredCloudDriveAutoSubtitle([englishAi])?.id, 'en-ai');
    expect(
      preferredCloudDriveAutoSubtitle([englishAi, chineseAi])?.id,
      'zh-ai',
    );
    expect(preferredCloudDriveAutoSubtitle([]), isNull);
  });

  test('automatic selection skips tracks without readable text', () {
    final unreadable = CloudDriveListedSubtitle(
      id: 'unreadable',
      label: '中文',
      language: 'zh',
      isAi: false,
      remote: remoteTrack('unreadable').copyWith(textAvailable: false),
    );
    final readable = CloudDriveListedSubtitle(
      id: 'readable',
      label: '英语',
      language: 'en',
      isAi: true,
      remote: remoteTrack('readable', ai: true),
    );
    expect(preferredCloudDriveAutoSubtitle([unreadable]), isNull);
    expect(
      preferredCloudDriveAutoSubtitle([unreadable, readable])?.id,
      'readable',
    );
  });

  test('baidu directory keeps quoted text, a following URI and stable ids', () {
    const first = '''
\uFEFF#EXTM3U\r
#EXT-X-MEDIA:TYPE=SUBTITLES,NAME="中文,人工=原",LANGUAGE="zh",FORMAT="srt",AI_SUB="0",VIDEO_LAN="en"\r
https://pan.baidu.com/rest/subtitle.srt?sign=one\r
#EXT-X-MEDIA:TYPE=SUBTITLES,NAME="中文,人工=原",LANGUAGE="zh",AI_SUB="1"\r
/relative.srt?sign=two\r
#EXTINF:6.0,\r
segment.ts\r
''';
    final tracks = parseBaiduSubtitleDirectory(
      first,
      base: Uri.parse('https://pan.baidu.com/api/streaming'),
      accountId: '42',
      fileId: '9',
      revision: 'rev',
    );
    expect(tracks, hasLength(2));
    expect(tracks.first.label, '中文,人工=原');
    expect(tracks.first.isAi, isFalse);
    expect(tracks[1].isAi, isTrue);
    expect(tracks.first.id, isNot(tracks[1].id));
    expect(
      tracks[1].remoteUri.toString(),
      'https://pan.baidu.com/relative.srt?sign=two',
    );
    expect(tracks.map((track) => track.format), everyElement('srt'));
    expect(tracks.every((track) => !track.autoSelect), isTrue);

    final refreshed = parseBaiduSubtitleDirectory(
      first
          .replaceAll('sign=one', 'sign=later')
          .replaceAll('sign=two', 'sign=other'),
      base: Uri.parse('https://pan.baidu.com/api/streaming'),
      accountId: '42',
      fileId: '9',
      revision: 'rev',
    );
    expect(refreshed.map((track) => track.id), tracks.map((track) => track.id));
    expect(refreshed.first.remoteUri.toString(), contains('sign=later'));
  });

  test('a URI attribute is a subtitle and a media playlist is not cues', () {
    final tracks = parseBaiduSubtitleDirectory(
      '#EXTM3U\n#EXT-X-MEDIA:TYPE=SUBTITLES,URI="https://pan.baidu.com/a.srt?sign=old",NAME="中文",LANGUAGE="zh",ID="track-7"\n',
      base: Uri.parse('https://pan.baidu.com/api/streaming'),
      accountId: '42',
      fileId: '9',
      revision: 'rev',
    );
    expect(tracks.single.id, 'baidu:42:9:track-7');
    expect(
      parseBaiduSubtitleDirectory(
        '#EXTM3U\n#EXT-X-MEDIA:TYPE=SUBTITLES,URI="https://pan.baidu.com/a.srt?sign=new",NAME="中文",LANGUAGE="zh",ID="track-7"\n',
        base: Uri.parse('https://pan.baidu.com/api/streaming'),
        accountId: '42',
        fileId: '9',
        revision: 'rev',
      ).single.id,
      tracks.single.id,
    );
    expect(
      parseBaiduSubtitleDirectory(
        '#EXTM3U\n#EXTINF:1,\nsegment.ts\n',
        base: Uri.parse('https://pan.baidu.com/api/streaming'),
        accountId: '42',
        fileId: '9',
        revision: 'rev',
      ),
      isEmpty,
    );
    expect(
      () => parseBaiduSubtitleDirectory(
        '{"errno":-6}',
        base: Uri.parse('https://pan.baidu.com/api/streaming'),
        accountId: '42',
        fileId: '9',
        revision: 'rev',
      ),
      throwsA(isA<CloudDriveFailure>()),
    );
    expect(
      () => parseBaiduSubtitleDirectory(
        '<html><body>login</body></html>',
        base: Uri.parse('https://pan.baidu.com/api/streaming'),
        accountId: '42',
        fileId: '9',
        revision: 'rev',
      ),
      throwsA(isA<CloudDriveFailure>()),
    );
  });

  test(
    'official request uses the remote path, dynamic token and account cache',
    () async {
      final http = RecordingHttp([
        jsonResponse({
          'errno': 0,
          'info': [
            {
              'path': '/课程/real.mp4',
              'md5': 'rev-real',
              'server_filename': 'real.mp4',
            },
          ],
        }),
        page('<html>{"bdstoken":"token-a"}</html>'),
        page(
          '#EXTM3U\n#EXT-X-MEDIA:TYPE=SUBTITLES,NAME="中文",LANGUAGE="zh"\nhttps://pan.baidu.com/a.srt?sign=one\n',
          type: 'application/x-mpegURL',
        ),
        jsonResponse({
          'errno': 0,
          'info': [
            {'path': '/课程/real.mp4', 'md5': 'rev-real'},
          ],
        }),
        page(
          '#EXTM3U\n#EXT-X-MEDIA:TYPE=SUBTITLES,NAME="中文",LANGUAGE="zh"\nhttps://pan.baidu.com/a.srt?sign=two\n',
          type: 'application/x-mpegURL',
        ),
        jsonResponse({
          'errno': 0,
          'info': [
            {'path': '/课程/other.mp4', 'md5': 'rev-other'},
          ],
        }),
        page('<html>{"bdstoken":"token-b"}</html>'),
        page('#EXTM3U\n', type: 'application/x-mpegURL'),
      ]);
      final provider = BaiduCloudDriveProvider(http: http);
      final first = await provider.discoverOfficialSubtitles(playback());
      expect(first.status, CloudDriveOfficialSubtitleStatus.ready);
      expect(first.tracks.single.label, '中文');
      expect(first.tracks.single.autoSelect, isFalse);
      final streaming = http.requests
          .where((item) => item.uri.path == '/api/streaming')
          .single;
      expect(streaming.uri.queryParameters['type'], 'M3U8_SUBTITLE_SRT');
      expect(streaming.uri.queryParameters['path'], '/课程/real.mp4');
      expect(streaming.uri.queryParameters['bdstoken'], 'token-a');
      expect(streaming.uri.queryParameters['isplayer'], '1');
      expect(streaming.uri.queryParameters['check_blue'], '1');
      expect(streaming.uri.query, isNot(contains('%25')));
      expect(
        streaming.headersFor?.call(streaming.uri)['User-Agent'],
        BaiduCloudDriveProvider.browserUserAgent,
      );
      expect(
        http.requests.any((item) => item.uri.path == '/api/list'),
        isFalse,
      );

      await provider.discoverOfficialSubtitles(playback());
      expect(
        http.requests.where((item) => item.uri.path == '/disk/main'),
        hasLength(1),
      );

      final other = await provider.discoverOfficialSubtitles(
        playback(account: '7', file: '8'),
      );
      expect(other.confirmedEmpty, isTrue);
      expect(
        http.requests.where((item) => item.uri.path == '/disk/main'),
        hasLength(2),
      );
      expect(
        http.requests.any((item) => item.uri.path == '/api/list'),
        isFalse,
      );
    },
  );

  test(
    'subtitle directory errors are not an empty list or a blanket login',
    () async {
      Future<CloudDriveOfficialSubtitleDiscovery> ask(
        CloudDriveHttpResponse response,
      ) {
        final http = RecordingHttp([
          jsonResponse({
            'errno': 0,
            'info': [
              {'path': '/课程/real.mp4'},
            ],
          }),
          page('<html>{"bdstoken":"token-a"}</html>'),
          response,
        ]);
        return BaiduCloudDriveProvider(
          http: http,
        ).discoverOfficialSubtitles(playback());
      }

      final login = await ask(
        page('{"errno":-6}', status: 200, type: 'application/json'),
      );
      expect(login.status, CloudDriveOfficialSubtitleStatus.loginRequired);
      expect(login.confirmedEmpty, isFalse);

      final restricted = await ask(page('', status: 403, type: 'text/plain'));
      expect(restricted.status, CloudDriveOfficialSubtitleStatus.restricted);
      expect(restricted.confirmedEmpty, isFalse);

      final html = await ask(
        page('<html><body>nope</body></html>', type: 'text/html'),
      );
      expect(html.status, CloudDriveOfficialSubtitleStatus.failed);
      expect(html.confirmedEmpty, isFalse);

      final empty = await ask(page('#EXTM3U\n', type: 'application/x-mpegURL'));
      expect(empty.confirmedEmpty, isTrue);
    },
  );

  test(
    'listing does not download a body and one tap saves that track once',
    () async {
      final root = await Directory.systemTemp.createTemp('baidu_subs');
      addTearDown(() => root.delete(recursive: true));
      final item = cloudItem();
      final sibling = cloudItem(id: 'sibling');
      final otherAccount = cloudItem(id: 'other', account: '7');
      final items = <String, VideoItem>{
        item.id: item,
        sibling.id: sibling,
        otherAccount.id: otherAccount,
      };
      final source = _FakeSource(
        tracks: [
          remoteTrack('human', label: '中文', ai: false),
          remoteTrack('machine', label: '中文', ai: true),
        ],
      );
      final tracks = CloudDriveSubtitleTracks(
        source: source,
        store: memoryStore(items, root),
      );
      await Future.wait([
        tracks.ensureLoaded(item.id),
        tracks.ensureLoaded(item.id),
      ]);
      expect(source.officialCalls, 1);
      expect(source.textCalls, 0);
      final listed = tracks.listFor(item.id);
      expect(listed.tracks, hasLength(2));
      expect(listed.tracks.last.isAi, isTrue);
      expect(listed.emptyMessage, isNull);

      final first = tracks.load(item.id, listed.tracks.first);
      final second = tracks.load(item.id, listed.tracks.first);
      final path = await first;
      expect(await second, path);
      expect(source.textCalls, 1);
      expect(path, isNotNull);
      expect(File(path!).readAsStringSync(), contains('你好'));
      expect(item.managedSubtitleAssets, hasLength(1));
      expect(
        item.managedSubtitleAssets.single.kind,
        ManagedSubtitleAssetKind.downloaded,
      );
      expect(item.managedSubtitleAssets.single.machineGenerated, isFalse);
      expect(sibling.managedSubtitleAssets, hasLength(1));
      expect(otherAccount.managedSubtitleAssets, isEmpty);

      source.textCalls = 0;
      final again = await tracks.load(
        item.id,
        tracks.listFor(item.id).tracks.first,
      );
      expect(again, path);
      expect(source.textCalls, 0);

      final edited = File(path);
      await edited.writeAsString('$srtBody\n改过\n', flush: true);
      final kept = await tracks.load(
        item.id,
        tracks.listFor(item.id).tracks.first,
      );
      expect(kept, path);
      expect(edited.readAsStringSync(), contains('改过'));
      expect(source.textCalls, 0);
    },
  );

  test(
    'a track failure ends loading and a list failure keeps a saved file',
    () async {
      final root = await Directory.systemTemp.createTemp('baidu_subs_fail');
      addTearDown(() => root.delete(recursive: true));
      final item = cloudItem();
      final saved = File(p.join(root.path, 'kept.srt'));
      await saved.writeAsString(srtBody, flush: true);
      final sourceRef = item.sourceRef!.cloudDrive!;
      item.managedSubtitleAssets = [
        ManagedSubtitleAsset(
          assetId: cloudOfficialAssetId(sourceRef, 'human'),
          path: saved.path,
          kind: ManagedSubtitleAssetKind.downloaded,
          displayName: '已保存',
          createdAt: 1,
        ),
      ];
      final source = _FakeSource(
        tracks: [remoteTrack('human'), remoteTrack('broken')],
      );
      source.textHandler = (track) async {
        if (track.id == 'broken') {
          throw const CloudDriveFailure(
            CloudDriveFailureKind.unavailable,
            '字幕地址暂时无法读取',
          );
        }
        return srtBody;
      };
      source.refreshTracks = [
        remoteTrack('broken', uri: 'https://pan.baidu.com/new.srt?sign=2'),
      ];
      final tracks = CloudDriveSubtitleTracks(
        source: source,
        store: memoryStore({item.id: item}, root),
      );
      await tracks.ensureLoaded(item.id);
      final broken = tracks
          .listFor(item.id)
          .tracks
          .singleWhere((row) => row.id == 'broken');
      expect(await tracks.load(item.id, broken), isNull);
      expect(tracks.isLoading(item.id, broken), isFalse);
      expect(tracks.hasFailed(item.id, broken), isTrue);
      expect(source.textCalls, 2);
      expect(item.managedSubtitleAssets, hasLength(1));

      source.officialError = const CloudDriveFailure(
        CloudDriveFailureKind.network,
        '网络不通',
      );
      await tracks.reload(item.id);
      final after = tracks.listFor(item.id);
      expect(after.failed, isTrue);
      expect(after.networkFailed, isTrue);
      expect(after.tracks.single.label, '已保存');
      expect(after.tracks.single.savedPath, saved.path);
      expect(after.emptyMessage, isNull);
    },
  );

  test('a late list from an old login is dropped', () async {
    final root = await Directory.systemTemp.createTemp('baidu_subs_login');
    addTearDown(() => root.delete(recursive: true));
    final item = cloudItem();
    final source = _FakeSource(tracks: [remoteTrack('human')]);
    final gate = source.holdOfficial();
    final tracks = CloudDriveSubtitleTracks(
      source: source,
      store: memoryStore({item.id: item}, root),
    );
    final pending = tracks.ensureLoaded(item.id);
    source.generation = 2;
    source.changes.notifyListeners();
    gate.complete();
    await pending;
    expect(tracks.needsAsking(item.id), isTrue);
    expect(tracks.listFor(item.id).listed, isFalse);
  });

  test(
    'empty text is not bound and a bad body leaves no success file',
    () async {
      final root = await Directory.systemTemp.createTemp('baidu_subs_empty');
      addTearDown(() => root.delete(recursive: true));
      final item = cloudItem();
      final source = _FakeSource(tracks: [remoteTrack('human')]);
      source.textHandler = (_) async => '这不是字幕';
      final tracks = CloudDriveSubtitleTracks(
        source: source,
        store: memoryStore({item.id: item}, root),
      );
      await tracks.ensureLoaded(item.id);
      final row = tracks.listFor(item.id).tracks.single;
      expect(await tracks.load(item.id, row), isNull);
      expect(item.managedSubtitleAssets, isEmpty);
      expect(Directory(root.path).listSync(recursive: true), isEmpty);
    },
  );

  testWidgets('a tap loads one official track and reports it once', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('baidu_subs_widget');
    addTearDown(() => root.deleteSync(recursive: true));
    final item = cloudItem();
    final source = _FakeSource(
      tracks: [
        remoteTrack('human', label: '中文'),
        remoteTrack('machine', label: '英语', ai: true),
      ],
    );
    final tracks = CloudDriveSubtitleTracks(
      source: source,
      store: memoryStore({item.id: item}, root),
    );
    var picks = 0;
    Future<void> show() {
      return tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              backgroundColor: Colors.black,
              body: SingleChildScrollView(
                child: CloudDriveSubtitleTracksSection(
                  itemId: item.id,
                  tracks: tracks,
                  onPick: (_) => picks++,
                  savedRow: (track) => Text('saved-${track.label}'),
                ),
              ),
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
    }

    await show();
    await tester.pump();
    expect(find.text('百度网盘字幕'), findsOneWidget);
    expect(find.text('点一下加载'), findsNWidgets(2));
    expect(find.text('AI'), findsOneWidget);
    expect(source.textCalls, 0);
    await tester.runAsync(() async {
      await tester.tap(find.text('中文'));
      for (var i = 0; i < 20 && picks == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    expect(picks, 1);
    expect(source.textCalls, 1);
    expect(find.text('saved-中文'), findsOneWidget);
    await tester.tap(find.text('saved-中文'));
    await tester.pump();
    expect(picks, 1);
    expect(source.textCalls, 1);
  });
}

CloudDriveHttpResponse jsonResponse(Object body) {
  return CloudDriveHttpResponse(
    statusCode: 200,
    headers: {'content-type': 'application/json'},
    body: utf8.encode(jsonEncode(body)),
    finalUri: Uri.parse('https://pan.baidu.com/api/filemetas'),
  );
}

CloudDriveSubtitleTrack remoteTrack(
  String id, {
  String label = '中文',
  bool ai = false,
  String uri = 'https://pan.baidu.com/a.srt?sign=1',
}) {
  return CloudDriveSubtitleTrack(
    id: id,
    label: label,
    language: 'zh',
    format: 'srt',
    origin: CloudDriveSubtitleOrigin.provider,
    remoteUri: Uri.parse(uri),
    isAi: ai,
    autoSelect: false,
  );
}

VideoItem cloudItem({
  String id = 'card',
  String account = '42',
  String file = '9',
}) {
  final source = CloudDriveSourceRef(
    providerId: 'baidu',
    remoteAccountId: account,
    driveId: '0',
    fileId: file,
    pathHint: '/课程/a.mp4',
    revision: 'rev',
  );
  return VideoItem(
    id: id,
    path: source.logicalUri,
    title: '课程',
    durationMs: 1000,
    lastUpdated: 1,
    usesManagedAssociatedSubtitles: true,
    sourceRef: MediaSourceRef(
      value: source.logicalUri,
      kind: MediaSourceKind.cloudDrive,
      cloudDrive: source,
    ),
  );
}

CloudDriveSubtitleTrackStore memoryStore(
  Map<String, VideoItem> items,
  Directory root,
) {
  return CloudDriveSubtitleTrackStore(
    itemOf: (id) => items[id],
    cardsSharing: (id) {
      final item = items[id];
      final source = item?.sourceRef?.cloudDrive;
      if (item == null || source == null) return const <VideoItem>[];
      return items.values.where((other) {
        final cloud = other.sourceRef?.cloudDrive;
        if (cloud == null) return false;
        return cloud.sourceKey == source.sourceKey &&
            (cloud.revision ?? '') == (source.revision ?? '');
      }).toList();
    },
    allocate: (id, name) async {
      final directory = Directory(p.join(root.path, id));
      await directory.create(recursive: true);
      return p.join(directory.path, name);
    },
    noteChanged: (_) async {},
  );
}

class _FakeSource implements CloudDriveSubtitleTrackSource {
  _FakeSource({required this.tracks});

  final List<CloudDriveSubtitleTrack> tracks;
  final changes = _LoginChanges();

  @override
  Listenable? get loginChanges => changes;
  @override
  int generation = 1;
  int officialCalls = 0;
  int textCalls = 0;
  CloudDriveFailure? officialError;
  List<CloudDriveSubtitleTrack>? refreshTracks;
  Future<String> Function(CloudDriveSubtitleTrack track)? textHandler;
  Completer<void>? _hold;

  Completer<void> holdOfficial() {
    final gate = Completer<void>();
    _hold = gate;
    return gate;
  }

  @override
  Future<CloudDriveOfficialSubtitleDiscovery> fetchOfficial(
    VideoItem item,
  ) async {
    officialCalls++;
    final hold = _hold;
    if (hold != null) await hold.future;
    final error = officialError;
    if (error != null) throw error;
    final listed = refreshTracks;
    if (listed != null && officialCalls > 1) {
      return CloudDriveOfficialSubtitleDiscovery(
        status: CloudDriveOfficialSubtitleStatus.ready,
        tracks: listed,
      );
    }
    return CloudDriveOfficialSubtitleDiscovery(
      status: CloudDriveOfficialSubtitleStatus.ready,
      tracks: tracks,
    );
  }

  @override
  Future<String> fetchText(
    VideoItem item,
    CloudDriveSubtitleTrack track,
  ) async {
    textCalls++;
    final handler = textHandler;
    if (handler != null) return handler(track);
    return srtBody;
  }
}

class _LoginChanges extends ChangeNotifier {}
