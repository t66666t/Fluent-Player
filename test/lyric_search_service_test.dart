import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/lyrics/lyric_search_models.dart';
import 'package:video_player_app/features/lyrics/lyric_search_service.dart';

void main() {
  LyricSearchService service(Object? Function(RequestOptions) respond) {
    final dio = Dio()..httpClientAdapter = _Adapter(respond);
    addTearDown(() => dio.close(force: true));
    return LyricSearchService(
      dio: dio,
      retryDelays: const [Duration.zero, Duration.zero],
    );
  }

  const track = LyricSearchTrack(
    source: LyricSource.netease,
    id: '42',
    title: 'Song',
    duration: Duration(seconds: 20),
  );

  test(
    'filename cleanup preserves the recording version and selectable chunks',
    () {
      expect(
        LyricSearchQuery.clean('01. Artist - Song (Live) [1080p].mp4'),
        'Artist - Song (Live)',
      );
      expect(
        LyricSearchQuery.suggestions('Artist - Song [FLAC].flac'),
        containsAll(['Artist', 'Song']),
      );
      expect(LyricSearchQuery.clean('Love.mp3 Story.mp3'), 'Love.mp3 Story');
    },
  );

  test(
    'NetEase keeps YRC word times and translation for the YRC timeline',
    () async {
      final lyrics = await service(
        (request) => {
          'code': 200,
          'yrc': {
            'lyric':
                '[1000,2000](1000,500,0)Hello (1500,1500,0)world\n[5000,2000](5000,2000,0)Again',
          },
          'lrc': {'lyric': '[00:02.00]Different line segmentation'},
          'ytlrc': {'lyric': '[00:01.00]你好世界\n[00:05.00]再一次'},
          'tlyric': {'lyric': '[00:02.00]旧时间轴'},
        },
      ).fetch(track);
      expect(lyrics.hasWordTiming, isTrue);
      expect(lyrics.original.first.text, 'Hello world');
      expect(lyrics.original.first.timedSpans.length, 2);
      expect(
        lyrics.original.first.timedSpans.last.endTime,
        const Duration(seconds: 3),
      );
      expect(lyrics.translation.first.startTime, const Duration(seconds: 1));
      expect(lyrics.translation.first.text, '你好世界');
    },
  );

  test(
    'falls back to timed LRC when YRC is malformed without inventing words',
    () async {
      final lyrics = await service(
        (_) => {
          'code': 200,
          'yrc': {'lyric': 'invalid'},
          'lrc': {'lyric': '[00:01.00]First\n[00:05.00]Second'},
          'tlyric': {'lyric': '[00:01.00]第一句\n[00:05.00]第二句'},
        },
      ).fetch(track);
      expect(lyrics.hasWordTiming, isFalse);
      expect(lyrics.original.last.endTime, track.duration);
      expect(lyrics.hasChineseTranslation, isTrue);
    },
  );

  test('plain text responses cannot be imported', () async {
    var attempts = 0;
    await expectLater(
      service((_) {
        attempts++;
        return {
          'code': 200,
          'lrc': {'lyric': 'untimed lyrics'},
        };
      }).fetch(track),
      throwsFormatException,
    );
    expect(attempts, 1, reason: 'missing timelines must not be retried');
  });

  test(
    'instrumental flags reject placeholder timelines without retrying',
    () async {
      var attempts = 0;
      final api = service((_) {
        attempts++;
        return {
          'code': 200,
          'nolyric': true,
          'lrc': {'lyric': '[00:00]纯音乐，请欣赏'},
        };
      });
      await expectLater(
        api.fetch(track),
        throwsA(isA<LyricUnavailableException>()),
      );
      expect(attempts, 1);
    },
  );

  test(
    'lyric fetching retries transient failures before rejecting a result',
    () async {
      var attempts = 0;
      final api = service((request) {
        if (++attempts == 1) {
          throw DioException(
            requestOptions: request,
            type: DioExceptionType.receiveTimeout,
          );
        }
        return {
          'code': 200,
          'lrc': {'lyric': '[00:01]Recovered lyric'},
        };
      });
      final lyrics = await api.fetch(track);
      expect(lyrics.original.single.text, 'Recovered lyric');
      expect(attempts, 2);
    },
  );

  test('cancelled lyric fetching does not retry', () async {
    final token = CancelToken();
    var attempts = 0;
    final api = service((request) {
      attempts++;
      token.cancel();
      throw DioException(
        requestOptions: request,
        type: DioExceptionType.receiveTimeout,
      );
    });
    await expectLater(
      api.fetch(track, cancelToken: token),
      throwsA(isA<DioException>()),
    );
    expect(attempts, 1);
  });

  test(
    'a translation in another language is not presented as Chinese',
    () async {
      final lyrics = await service(
        (_) => {
          'code': 200,
          'lrc': {'lyric': '[00:01]Hello'},
          'tlyric': {'lyric': '[00:01]Bonjour'},
        },
      ).fetch(track);
      expect(lyrics.hasChineseTranslation, isFalse);
    },
  );

  test(
    'multi-source search keeps successful results and excludes unsynced LRCLIB rows',
    () async {
      final api = service((request) {
        if (request.uri.host == 'music.163.com') return {'code': 403};
        if (request.uri.host == 'u.y.qq.com') {
          return {
            'code': 0,
            'req_1': {
              'code': 0,
              'data': {
                'body': {
                  'song': {
                    'list': [
                      {
                        'id': 8,
                        'mid': 'song-mid',
                        'title': 'Song Live',
                        'interval': 100,
                        'singer': [
                          {'name': 'Artist'},
                        ],
                        'album': {'name': 'Live'},
                      },
                    ],
                  },
                },
              },
            },
          };
        }
        return [
          {
            'id': 1,
            'trackName': 'Song',
            'artistName': 'Artist',
            'duration': 20,
            'syncedLyrics': '[00:01]First',
          },
          {
            'id': 2,
            'trackName': 'Song',
            'duration': 20,
            'plainLyrics': 'Plain only',
          },
          {
            'id': 3,
            'trackName': 'Song',
            'duration': 200,
            'syncedLyrics': '[00:01]Another recording',
          },
        ];
      });
      final results = await api.search(
        'Song',
        mediaDuration: const Duration(seconds: 20),
        artist: 'Artist',
      );
      expect(results.tracks.length, 3);
      expect(results.tracks.first.id, '1');
      expect(results.errors.keys, [LyricSource.netease]);
      expect(results.tracks.any((t) => t.secondaryId == 'song-mid'), isTrue);
    },
  );

  test(
    'QQ QRC is preferred and LRC endpoint supplies translation fallback',
    () async {
      final api = service((request) {
        if (request.uri.path.contains('lyric_download')) {
          return '<root><miniversion="1" /><content><![CDATA[[1000,2000]Hello(1000,500) world(1500,1500)]]></content></root>';
        }
        return {
          'code': 0,
          'lyric': base64Encode(utf8.encode('[00:01]Hello world')),
          'trans': base64Encode(utf8.encode('[00:01]你好世界')),
        };
      });
      final lyrics = await api.fetch(
        const LyricSearchTrack(
          source: LyricSource.qqMusic,
          id: '8',
          secondaryId: 'mid',
          title: 'Song',
        ),
      );
      expect(lyrics.hasWordTiming, isTrue);
      expect(lyrics.translation.single.text, '你好世界');
    },
  );

  test('QQ line fallback works if QRC endpoint is unavailable', () async {
    final api = service(
      (request) => request.uri.path.contains('lyric_download')
          ? 'bad xml'
          : {'code': 0, 'lyric': '[00:01]Hello', 'trans': '[00:01]你好'},
    );
    final lyrics = await api.fetch(
      const LyricSearchTrack(
        source: LyricSource.qqMusic,
        id: '8',
        secondaryId: 'mid',
        title: 'Song',
      ),
    );
    expect(lyrics.hasWordTiming, isFalse);
    expect(lyrics.original.single.text, 'Hello');
  });

  test(
    'offset moves sentences, words and translation together and clips negative starts',
    () async {
      final lyrics = await service(
        (_) => {
          'code': 200,
          'yrc': {'lyric': '[1000,2000](1000,500,0)Hello (1500,1500,0)world'},
          'ytlrc': {'lyric': '[00:01]你好世界'},
        },
      ).fetch(track);
      const offset = Duration(milliseconds: -1250);
      final shifted = lyrics.shifted(lyrics.original, offset).single;
      expect(shifted.startTime, Duration.zero);
      expect(shifted.endTime, const Duration(milliseconds: 1750));
      expect(shifted.timedSpans.first.startTime, Duration.zero);
      expect(
        shifted.timedSpans.last.startTime,
        const Duration(milliseconds: 250),
      );
      expect(
        lyrics.shifted(lyrics.translation, offset).single.startTime,
        Duration.zero,
      );
      expect(lyrics.original.single.startTime, const Duration(seconds: 1));
    },
  );

  test(
    'duration difference is primary, with millisecond precision and unknown durations last',
    () async {
      final api = service(
        (_) => [
          {
            'id': 1,
            'trackName': 'Song',
            'artistName': 'Artist',
            'duration': 22,
            'syncedLyrics': '[00:01]Text',
          },
          {
            'id': 2,
            'trackName': 'Different title',
            'artistName': 'Other',
            'duration': 20.020,
            'syncedLyrics': '[00:01]Text',
          },
          {
            'id': 3,
            'trackName': 'Song',
            'artistName': 'Artist',
            'duration': 20.030,
            'syncedLyrics': '[00:01]Text',
          },
          {
            'id': 4,
            'trackName': 'Song',
            'artistName': 'Artist',
            'duration': 0,
            'syncedLyrics': '[00:01]Text',
          },
        ],
      );
      final results = await api.search(
        'Song',
        sources: {LyricSource.lrclib},
        mediaDuration: const Duration(seconds: 20),
        artist: 'Artist',
      );
      expect(results.tracks.map((t) => t.id), ['2', '3', '1', '4']);
    },
  );

  test(
    'artist adds a search variant but never excludes title-only candidates',
    () async {
      final keywords = <String>[];
      final api = service((request) {
        final query = request.queryParameters['q'] as String;
        keywords.add(query);
        return [
          {
            'id': query == 'Song Wrong Author' ? 2 : 1,
            'trackName': 'Song',
            'artistName': 'Real Artist',
            'duration': 20,
            'syncedLyrics': '[00:01]Text',
          },
        ];
      });
      final results = await api.search(
        'Song',
        sources: {LyricSource.lrclib},
        artist: 'Wrong Author',
      );
      expect(keywords, containsAll(['Song', 'Song Wrong Author']));
      expect(results.tracks.length, 2);
      keywords.clear();
      await api.search('Song', sources: {LyricSource.lrclib});
      expect(keywords, ['Song']);
    },
  );

  test('unknown media duration uses title/artist relevance instead', () async {
    final api = service(
      (_) => [
        {
          'id': 1,
          'trackName': 'Other',
          'artistName': 'Other',
          'duration': 20,
          'syncedLyrics': '[00:01]Text',
        },
        {
          'id': 2,
          'trackName': 'Song',
          'artistName': 'Artist',
          'duration': 22,
          'syncedLyrics': '[00:01]Text',
        },
      ],
    );
    final results = await api.search(
      'Song',
      sources: {LyricSource.lrclib},
      artist: 'Artist',
    );
    expect(results.tracks.first.id, '2');
  });

  test('a timed out source succeeds on retry without a final error', () async {
    var attempts = 0;
    final phases = <LyricSourcePhase>[];
    final api = service((request) {
      attempts++;
      if (attempts == 1) {
        throw DioException(
          requestOptions: request,
          type: DioExceptionType.connectionTimeout,
        );
      }
      return [
        {
          'id': 1,
          'trackName': 'Song',
          'artistName': 'Artist',
          'duration': 20,
          'syncedLyrics': '[00:01]First',
        },
      ];
    });
    final results = await api.search(
      'Song',
      sources: {LyricSource.lrclib},
      onUpdate: (snapshot) {
        final phase = snapshot.statuses[LyricSource.lrclib]?.phase;
        if (phase != null) phases.add(phase);
      },
    );
    expect(attempts, 2);
    expect(results.errors, isEmpty);
    expect(results.tracks.single.id, '1');
    expect(phases, contains(LyricSourcePhase.retrying));
    expect(results.statuses[LyricSource.lrclib]?.phase, LyricSourcePhase.ready);
  });

  test('one failing source does not drop tracks from the others', () async {
    final api = service((request) {
      if (request.uri.host == 'lrclib.net') {
        throw DioException(
          requestOptions: request,
          type: DioExceptionType.connectionError,
        );
      }
      if (request.uri.host == 'music.163.com') {
        return {
          'code': 200,
          'result': {
            'songs': [
              {
                'id': 42,
                'name': 'Song',
                'duration': 20000,
                'artists': [
                  {'name': 'Artist'},
                ],
                'album': {'name': 'Album'},
              },
            ],
          },
        };
      }
      return {
        'code': 0,
        'req_1': {
          'code': 0,
          'data': {
            'body': {
              'song': {
                'list': [
                  {
                    'id': 8,
                    'mid': 'song-mid',
                    'title': 'Song',
                    'interval': 20,
                    'singer': [
                      {'name': 'Artist'},
                    ],
                    'album': {'name': 'Album'},
                  },
                ],
              },
            },
          },
        },
      };
    });
    final results = await api.search('Song');
    expect(results.errors.keys, [LyricSource.lrclib]);
    expect(results.tracks.map((track) => track.source).toSet(), {
      LyricSource.netease,
      LyricSource.qqMusic,
    });
    expect(
      results.statuses[LyricSource.lrclib]?.phase,
      LyricSourcePhase.failed,
    );
  });

  test(
    'a failed artist query does not hide title results or mark the source failed',
    () async {
      final api = service((request) {
        final query = request.queryParameters['q'] as String;
        if (query.contains('Wrong')) {
          throw DioException(
            requestOptions: request,
            type: DioExceptionType.receiveTimeout,
          );
        }
        return [
          {
            'id': 1,
            'trackName': 'Song',
            'artistName': 'Real Artist',
            'duration': 20,
            'syncedLyrics': '[00:01]Text',
          },
        ];
      });
      final results = await api.search(
        'Song',
        sources: {LyricSource.lrclib},
        artist: 'Wrong Author',
      );
      expect(results.errors, isEmpty);
      expect(results.tracks.single.id, '1');
      expect(
        results.statuses[LyricSource.lrclib]?.phase,
        LyricSourcePhase.ready,
      );
    },
  );

  test('a transport cancel does not discard other sources', () async {
    final api = service((request) {
      if (request.uri.host == 'music.163.com') {
        throw DioException(
          requestOptions: request,
          type: DioExceptionType.cancel,
          error: '网络设置已更新',
        );
      }
      return [
        {
          'id': 1,
          'trackName': 'Song',
          'artistName': 'Artist',
          'duration': 20,
          'syncedLyrics': '[00:01]First',
        },
      ];
    });
    final results = await api.search(
      'Song',
      sources: {LyricSource.netease, LyricSource.lrclib},
    );
    expect(results.errors.keys, [LyricSource.netease]);
    expect(results.tracks.single.source, LyricSource.lrclib);
  });

  test('non-transient failures are not retried', () async {
    var attempts = 0;
    final api = service((request) {
      attempts++;
      throw DioException.badResponse(
        statusCode: 400,
        requestOptions: request,
        response: Response(requestOptions: request, statusCode: 400),
      );
    });
    final results = await api.search('Song', sources: {LyricSource.lrclib});
    expect(attempts, 1);
    expect(results.errors[LyricSource.lrclib], '服务暂时不可用（400）');
  });

  test('title matches publish before the artist search finishes', () async {
    final extra = Completer<Object?>();
    final searchingArtist = Completer<void>();
    final snapshots = <LyricSearchResults>[];
    final api = service((request) {
      if (request.queryParameters['s'] == 'Song Artist') {
        searchingArtist.complete();
        return extra.future;
      }
      return {
        'code': 200,
        'result': {
          'songs': [
            {'id': 42, 'name': 'Song'},
          ],
        },
      };
    });
    final pending = api.search(
      'Song',
      artist: 'Artist',
      sources: {LyricSource.netease},
      onUpdate: snapshots.add,
    );
    await searchingArtist.future;
    expect(snapshots.last.tracks.single.id, '42');
    expect(
      snapshots.last.statuses[LyricSource.netease]?.phase,
      LyricSourcePhase.pending,
    );
    extra.complete({
      'code': 200,
      'result': {
        'songs': [
          {'id': 42, 'name': 'Song'},
          {'id': 43, 'name': 'Song Artist'},
        ],
      },
    });
    final results = await pending;
    expect(results.tracks.map((track) => track.id), containsAll(['42', '43']));
    expect(results.tracks, hasLength(2));
    expect(
      results.statuses[LyricSource.netease]?.phase,
      LyricSourcePhase.ready,
    );
  });

  test('a slow source does not block tracks from a fast source', () async {
    final gate = Completer<void>();
    final snapshots = <LyricSearchResults>[];
    final api = service((request) {
      if (request.uri.host == 'lrclib.net') {
        return gate.future.then(
          (_) => [
            {
              'id': 1,
              'trackName': 'Song',
              'artistName': 'Artist',
              'duration': 20,
              'syncedLyrics': '[00:01]First',
            },
          ],
        );
      }
      if (request.uri.host == 'music.163.com') {
        return {
          'code': 200,
          'result': {
            'songs': [
              {
                'id': 42,
                'name': 'Song',
                'duration': 20000,
                'artists': [
                  {'name': 'Artist'},
                ],
                'album': {'name': 'Album'},
              },
            ],
          },
        };
      }
      return {
        'code': 0,
        'req_1': {
          'code': 0,
          'data': {
            'body': {
              'song': {'list': <Object?>[]},
            },
          },
        },
      };
    });
    final pending = api.search('Song', onUpdate: snapshots.add);
    var sawFastTrack = false;
    for (var i = 0; i < 30 && !sawFastTrack; i++) {
      await Future<void>.delayed(Duration.zero);
      sawFastTrack = snapshots.any(
        (snapshot) =>
            snapshot.tracks.any(
              (track) => track.source == LyricSource.netease,
            ) &&
            snapshot.statuses[LyricSource.lrclib]?.phase ==
                LyricSourcePhase.pending,
      );
    }
    expect(sawFastTrack, isTrue);
    gate.complete();
    final results = await pending;
    expect(
      results.tracks.map((track) => track.source),
      containsAll([LyricSource.netease, LyricSource.lrclib]),
    );
  });

  test(
    'cancellation propagates instead of being reported as empty results',
    () async {
      final token = CancelToken()..cancel();
      await expectLater(
        service(
          (_) => [],
        ).search('Song', sources: {LyricSource.lrclib}, cancelToken: token),
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
    },
  );
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final Object? Function(RequestOptions) respond;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final produced = respond(options);
    final result = produced is Future ? await produced : produced;
    return ResponseBody.fromString(
      result is String ? result : jsonEncode(result),
      200,
      headers: {
        Headers.contentTypeHeader: [
          result is String ? 'text/plain' : Headers.jsonContentType,
        ],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
