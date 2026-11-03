import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_streaming_service.dart';

Map<String, dynamic> _track(int id, String codec, int bandwidth, Uri origin) =>
    {
      'id': id,
      'baseUrl': origin.resolve('/$id').toString(),
      'bandwidth': bandwidth,
      'codecs': codec,
      'mimeType': 'audio/mp4',
      'SegmentBase': {'Initialization': '0-3', 'indexRange': '4-7'},
    };

BilibiliStreamInfo _info(
  Uri origin, {
  bool specials = true,
  bool hiRes = true,
}) => BilibiliStreamInfo.fromJson({
  'data': {
    'timelength': 120000,
    'dash': {
      'video': [
        {
          ..._track(80, 'avc1.640028', 800000, origin),
          'codecid': 7,
          'width': 1920,
          'height': 1080,
        },
        {
          ..._track(64, 'avc1.64001f', 400000, origin),
          'codecid': 7,
          'width': 1280,
          'height': 720,
        },
      ],
      'audio': [
        _track(30280, 'mp4a.40.2', 192000, origin),
        _track(30216, 'mp4a.40.5', 64000, origin),
        // Duplicate CDN representations must not duplicate menu entries.
        _track(30280, 'mp4a.40.2', 192000, origin),
      ],
      'dolby': {
        'type': specials ? 1 : 0,
        'audio': specials ? [_track(30250, 'ec-3', 1024000, origin)] : null,
      },
      'flac': {
        'display': specials && hiRes,
        'audio': specials && hiRes
            ? _track(30251, 'fLaC', 1689800, origin)
            : null,
      },
    },
  },
});

class _Api extends BilibiliApiService {
  _Api(this.info);
  BilibiliStreamInfo info;
  @override
  Future<BilibiliStreamInfo> fetchPlayUrl(String bvid, int cid) async => info;
  @override
  Future<Map<String, dynamic>?> fetchVideoShot(String bvid, int cid) async =>
      null;
}

VideoItem _item(String id) => VideoItem(
  id: id,
  path: 'bilibili://stream/BV1gHjGzyE5Z?cid=30148135059',
  title: 'audio selection',
  durationMs: 120000,
  lastUpdated: 0,
  sourceRef: const MediaSourceRef(
    kind: MediaSourceKind.bilibiliStream,
    value: 'BV1gHjGzyE5Z',
    bvid: 'BV1gHjGzyE5Z',
    cid: 30148135059,
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('recognizes FLAC, Dolby, AAC and additional audio formats', () {
    final info = _info(Uri.parse('https://upos-test.bilivideo.com'));
    final qualities = info.audioStreams.map(BilibiliAudioQuality.fromStream);
    expect(qualities.firstWhere((q) => q.id == 30251).label, 'Hi-Res无损');
    expect(qualities.firstWhere((q) => q.id == 30250).label, '杜比全景声');
    expect(qualities.firstWhere((q) => q.id == 30280).isSpecial, isFalse);
    final opus = BilibiliAudioQuality.fromStream(
      StreamItem.fromJson(
        _track(
          30300,
          'opus',
          256000,
          Uri.parse('https://upos-test.bilivideo.com'),
        ),
      ),
    );
    expect(opus.label, '普通音质');
    expect(opus.isSpecial, isFalse);
    final emptySpecials = _info(
      Uri.parse('https://upos-test.bilivideo.com'),
      specials: false,
    );
    expect(
      emptySpecials.audioStreams.map((t) => t.id),
      everyElement(isNot(30251)),
    );
  });

  late HttpServer upstream;
  late Uri origin;
  late _Api api;
  late BilibiliStreamingService streaming;
  late Directory cache;
  late HttpClient client;
  final requested = <int>[];

  Future<List<int>> read(BilibiliPreparedPlayback playback) async {
    final request = await client.getUrl(playback.audioUri);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-15');
    final response = await request.close();
    expect(response.statusCode, HttpStatus.partialContent);
    return response.fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk));
  }

  group('gateway audio identity', () {
    setUp(() async {
      cache = await Directory.systemTemp.createTemp('bili-audio-');
      requested.clear();
      upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      origin = Uri.parse('http://127.0.0.1:${upstream.port}');
      upstream.listen((request) async {
        final id = int.parse(request.uri.pathSegments.single);
        requested.add(id);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 0-15/16',
        );
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        request.response.contentLength = 16;
        if (request.method != 'HEAD') {
          request.response.add(List.filled(16, id % 251));
        }
        await request.response.close();
      });
      api = _Api(_info(origin));
      streaming = BilibiliStreamingService(
        api,
        cacheDirectory: cache,
        mediaUriValidator: (uri) => uri.host == origin.host,
        networkRetryDelays: const [],
      );
      client = HttpClient();
    });
    tearDown(() async {
      client.close(force: true);
      await streaming.shutdown();
      await upstream.close(force: true);
      await cache.delete(recursive: true);
    });

    test(
      'defaults to the best available audio and serves each format in its own cache',
      () async {
        final item = _item('multi');
        final automatic = await streaming.prepare(item);
        expect(automatic.selectedAudioQuality?.id, 30251);
        expect(automatic.selectedAudioQuality?.isSpecial, isTrue);
        expect(automatic.audioQualities.map((q) => q.id), [
          30251,
          30250,
          30280,
        ]);
        expect(await read(automatic), List.filled(16, 30251 % 251));
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.containsKey(
            BilibiliStreamingService.preferredAudioPreferenceKey,
          ),
          isFalse,
        );
        for (final id in [30280, 30251, 30250, 30216, 30280]) {
          final playback = await streaming.prepare(item, audioQualityId: id);
          expect(playback.selectedAudioQuality?.id, id);
          expect(await read(playback), List.filled(16, id % 251));
          await streaming.releasePlayback(playback);
        }
        expect(requested, containsAll([30280, 30251, 30250, 30216]));
      },
    );

    test('automatically selects Dolby when Hi-Res is unavailable', () async {
      api.info = _info(origin, hiRes: false);
      final playback = await streaming.prepare(_item('dolby-default'));
      expect(playback.selectedAudioQuality?.id, 30250);
      expect(playback.selectedAudioQuality?.isSpecial, isTrue);
      expect(await read(playback), List.filled(16, 30250 % 251));
    });

    test(
      'ordinary-only videos expose no audio menu, despite multiple AAC bitrates',
      () async {
        api.info = _info(origin, specials: false);
        final playback = await streaming.prepare(_item('ordinary-only'));
        expect(playback.audioQualities, isEmpty);
        expect(playback.selectedAudioQuality?.id, 30280);
        expect(await read(playback), List.filled(16, 30280 % 251));
        api.info = _info(origin);
        final special = await streaming.prepare(
          _item('special-after-ordinary'),
          forceRefresh: true,
        );
        expect(special.selectedAudioQuality?.id, 30251);
      },
    );

    test(
      'video quality and reconnect preserve the committed audio selection',
      () async {
        final item = _item('remember');
        await streaming.rememberAudioQuality(item.id, 30251);
        final playback = await streaming.prepare(item, qualityId: 64);
        expect(playback.selectedQuality.id, 64);
        expect(playback.selectedAudioQuality?.id, 30251);
        streaming.invalidateNetwork();
        expect(await read(playback), List.filled(16, 30251 % 251));
        expect(
          (await streaming.prepare(
            _item('another-video'),
          )).selectedAudioQuality?.id,
          30251,
        );
        streaming.clearAudioQualityPreference(item.id);
        expect(streaming.hasPreferredAudioQuality(item.id), isFalse);
        expect((await streaming.prepare(item)).selectedAudioQuality?.id, 30251);
      },
    );

    test(
      'fresh URLs keep Dolby and cannot silently splice AAC after loss of access',
      () async {
        final item = _item('refresh');
        final playback = await streaming.prepare(item, audioQualityId: 30250);
        streaming.noteFreshPlayUrl(item.id, _info(origin));
        expect(await read(playback), List.filled(16, 30250 % 251));
        streaming.noteFreshPlayUrl(item.id, _info(origin, specials: false));
        expect(await read(playback), List.filled(16, 30250 % 251));
        expect(requested, isNot(contains(30280)));
      },
    );

    test(
      'an AAC warm session cannot override a later Hi-Res preference',
      () async {
        final item = _item('warm');
        await streaming.rememberAudioQuality(item.id, 30280);
        await streaming.prefetch(item);
        await streaming.rememberAudioQuality(item.id, 30251);
        final playback = await streaming.prepare(item);
        expect(playback.selectedAudioQuality?.id, 30251);
      },
    );

    test(
      'a best-audio warm session yields to a manual ordinary choice',
      () async {
        final item = _item('warm-special');
        await streaming.prefetch(item);
        await streaming.rememberAudioQuality(item.id, 30280);
        final playback = await streaming.prepare(item);
        expect(playback.selectedAudioQuality?.id, 30280);
        expect(playback.selectedAudioQuality?.isSpecial, isFalse);
      },
    );

    for (final rememberedId in [30250, 30280]) {
      test(
        'manual audio choice $rememberedId overrides the automatic default across videos and restart',
        () async {
          final initial = await streaming.prepare(_item('first-open'));
          expect(initial.selectedAudioQuality?.id, 30251);
          await streaming.rememberAudioQuality('original', rememberedId);
          final next = await streaming.prepare(_item('next-video'));
          expect(next.selectedAudioQuality?.id, rememberedId);
          final reopened = BilibiliStreamingService(
            api,
            cacheDirectory: cache,
            mediaUriValidator: (uri) => uri.host == origin.host,
          );
          try {
            final playback = await reopened.prepare(_item('different-video'));
            expect(playback.selectedAudioQuality?.id, rememberedId);
            expect(await read(playback), List.filled(16, rememberedId % 251));
          } finally {
            await reopened.shutdown();
          }
        },
      );
    }

    test(
      'an unavailable remembered format falls back without erasing the default or discarding a warm fallback',
      () async {
        await streaming.rememberAudioQuality('original', 30251);
        api.info = _info(origin, specials: false);
        final item = _item('fallback');
        await streaming.prefetch(item);
        final count = streaming.activePlaybackSessionCount;
        final fallback = await streaming.prepare(item);
        expect(fallback.selectedAudioQuality?.id, 30280);
        expect(streaming.activePlaybackSessionCount, count);
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getInt(BilibiliStreamingService.preferredAudioPreferenceKey),
          30251,
        );
        api.info = _info(origin);
        final special = await streaming.prepare(
          _item('supported-again'),
          forceRefresh: true,
        );
        expect(special.selectedAudioQuality?.id, 30251);
      },
    );

    test(
      'uncommitted candidates never change the default and rapid committed choices persist in order',
      () async {
        await streaming.prepare(_item('candidate'), audioQualityId: 30251);
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.containsKey(
            BilibiliStreamingService.preferredAudioPreferenceKey,
          ),
          isFalse,
        );
        await Future.wait([
          streaming.rememberAudioQuality('first', 30251),
          streaming.rememberAudioQuality('second', 30250),
          streaming.rememberAudioQuality('third', 30216),
        ]);
        expect(
          prefs.getInt(BilibiliStreamingService.preferredAudioPreferenceKey),
          30216,
        );
        expect(
          (await streaming.prepare(_item('later'))).selectedAudioQuality?.id,
          30216,
        );
      },
    );
  });
}
