import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';

import '../../models/subtitle_model.dart';
import '../../services/network/network_http.dart';
import '../../utils/lyric_file_codec.dart';
import '../../utils/timed_subtitle_parser.dart';
import 'lyric_search_models.dart';

// Provider request shapes adapted from WXRIW/Lyricify-Lyrics-Helper.
// See third_party/lyricify/NOTICE and LICENSE (Apache-2.0).
class LyricSearchService {
  LyricSearchService({Dio? dio, List<Duration>? retryDelays})
    : _dio =
          dio ??
          NetworkHttp.instance.createDio(
            options: BaseOptions(
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 18),
              sendTimeout: const Duration(seconds: 12),
              headers: {'User-Agent': 'FluentPlayer/1.0 (lyrics search)'},
            ),
          ),
      _ownsDio = dio == null,
      _retryDelays =
          retryDelays ??
          const [Duration(milliseconds: 350), Duration(milliseconds: 800)];

  final Dio _dio;
  final bool _ownsDio;

  /// Waits inserted after each transient failure. Attempt count is one more
  /// than this list, so the default is three tries.
  final List<Duration> _retryDelays;
  int get _maxAttempts => _retryDelays.length + 1;
  void dispose() {
    if (_ownsDio) _dio.close(force: true);
  }

  Future<LyricSearchResults> search(
    String query, {
    Set<LyricSource> sources = const {
      LyricSource.netease,
      LyricSource.qqMusic,
      LyricSource.lrclib,
    },
    Duration mediaDuration = Duration.zero,
    String artist = '',
    CancelToken? cancelToken,
    void Function(LyricSearchResults snapshot)? onUpdate,
  }) async {
    if (query.trim().isEmpty) return const LyricSearchResults([]);
    // Title first, then title+artist. Sequential on purpose: two parallel
    // calls to the same host are a common reason a provider rejects one of them.
    final keywords = <String>[
      query.trim(),
      if (artist.trim().isNotEmpty &&
          !_normalize(query).contains(_normalize(artist)))
        '${query.trim()} ${artist.trim()}',
    ];
    final collected = <String, LyricSearchTrack>{};
    final errors = <LyricSource, String>{};
    final statuses = <LyricSource, LyricSourceStatus>{
      for (final source in sources)
        source: LyricSourceStatus(
          source: source,
          phase: LyricSourcePhase.pending,
          maxAttempts: _maxAttempts,
        ),
    };

    LyricSearchResults snapshot() => LyricSearchResults(
      _rank(
        collected.values,
        query: query,
        artist: artist,
        mediaDuration: mediaDuration,
      ),
      errors: Map.unmodifiable({...errors}),
      statuses: Map.unmodifiable({...statuses}),
    );

    void publish() => onUpdate?.call(snapshot());

    publish();
    try {
      await Future.wait(
        sources.map(
          (source) => _loadSource(
            source: source,
            keywords: keywords,
            cancelToken: cancelToken,
            collected: collected,
            errors: errors,
            statuses: statuses,
            publish: publish,
          ),
        ),
      );
    } catch (error) {
      // Only the caller's token aborts the whole search. A provider that
      // fails on its own is recorded in [_loadSource] and must not drop
      // tracks the other providers already published.
      if (cancelToken?.isCancelled == true) rethrow;
    }
    return snapshot();
  }

  Future<void> _loadSource({
    required LyricSource source,
    required List<String> keywords,
    required CancelToken? cancelToken,
    required Map<String, LyricSearchTrack> collected,
    required Map<LyricSource, String> errors,
    required Map<LyricSource, LyricSourceStatus> statuses,
    required void Function() publish,
  }) async {
    try {
      _ensureNotCancelled(cancelToken);
      final found = <LyricSearchTrack>[];
      Object? lastError;
      for (final keyword in keywords) {
        _ensureNotCancelled(cancelToken);
        try {
          final matches = await _withRetry(source, keyword, cancelToken, (
            nextAttempt,
            error,
          ) {
            statuses[source] = LyricSourceStatus(
              source: source,
              phase: LyricSourcePhase.retrying,
              attempt: nextAttempt,
              maxAttempts: _maxAttempts,
              message: errorMessage(error),
            );
            publish();
          });
          _ensureNotCancelled(cancelToken);
          found.addAll(matches);
          for (final track in matches) {
            collected.putIfAbsent(track.key, () => track);
          }
          // Start preparing these lyrics while the next keyword is searching.
          statuses[source] = LyricSourceStatus(
            source: source,
            phase: LyricSourcePhase.pending,
            maxAttempts: _maxAttempts,
            trackCount: found.length,
          );
          publish();
        } catch (error) {
          if (cancelToken?.isCancelled == true) rethrow;
          lastError = error;
        }
      }
      if (found.isEmpty && lastError != null) {
        _failSource(source, lastError, errors, statuses);
      } else {
        errors.remove(source);
        statuses[source] = LyricSourceStatus(
          source: source,
          phase: LyricSourcePhase.ready,
          maxAttempts: _maxAttempts,
          trackCount: collected.values
              .where((track) => track.source == source)
              .length,
        );
      }
      publish();
    } catch (error) {
      if (cancelToken?.isCancelled == true) rethrow;
      _failSource(source, error, errors, statuses);
      publish();
    }
  }

  void _failSource(
    LyricSource source,
    Object error,
    Map<LyricSource, String> errors,
    Map<LyricSource, LyricSourceStatus> statuses,
  ) {
    final message = errorMessage(error);
    errors[source] = message;
    statuses[source] = LyricSourceStatus(
      source: source,
      phase: LyricSourcePhase.failed,
      maxAttempts: _maxAttempts,
      message: message,
    );
  }

  /// Retries timeouts, connection failures, rate limits and empty provider
  /// payloads. A cancel only stops the search when [token] itself was cancelled;
  /// the network layer also reports cancel when the route changes under us.
  Future<List<LyricSearchTrack>> _withRetry(
    LyricSource source,
    String query,
    CancelToken? token,
    void Function(int nextAttempt, Object error) onRetry,
  ) async {
    var attempt = 1;
    while (true) {
      _ensureNotCancelled(token);
      try {
        return await _searchSource(source, query, token);
      } catch (error) {
        if (token?.isCancelled == true) {
          _ensureNotCancelled(token);
        }
        final canRetry = attempt < _maxAttempts && _isTransient(error);
        if (!canRetry) rethrow;
        attempt++;
        onRetry(attempt, error);
        await _pause(_retryDelays[attempt - 2], token);
      }
    }
  }

  Future<void> _pause(Duration delay, CancelToken? token) {
    _ensureNotCancelled(token);
    if (delay <= Duration.zero) return Future<void>.value();
    final cancel = token?.whenCancel;
    if (cancel == null) return Future<void>.delayed(delay);
    final done = Completer<void>();
    final timer = Timer(delay, () {
      if (!done.isCompleted) done.complete();
    });
    cancel.then((_) {
      timer.cancel();
      if (!done.isCompleted) {
        done.completeError(
          DioException(
            requestOptions: RequestOptions(path: ''),
            type: DioExceptionType.cancel,
          ),
        );
      }
    });
    return done.future;
  }

  void _ensureNotCancelled(CancelToken? token) {
    if (token?.isCancelled == true) {
      throw DioException(
        requestOptions: RequestOptions(path: ''),
        type: DioExceptionType.cancel,
      );
    }
  }

  static bool _isTransient(Object error) {
    if (error is LyricUnavailableException) return false;
    if (error is FormatException) return true;
    if (error is! DioException) return false;
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.connectionError ||
      DioExceptionType.unknown ||
      DioExceptionType.cancel => true,
      DioExceptionType.badResponse => _retryableStatus(
        error.response?.statusCode,
      ),
      _ => false,
    };
  }

  static bool _retryableStatus(int? code) =>
      code == 429 || (code != null && code >= 500 && code <= 599);

  List<LyricSearchTrack> _rank(
    Iterable<LyricSearchTrack> tracks, {
    required String query,
    required String artist,
    required Duration mediaDuration,
  }) {
    final ranked = tracks.toList();
    double score(LyricSearchTrack t) {
      final name = _normalize(t.title);
      final q = _normalize(query);
      var result = name == q
          ? 80.0
          : q.contains(name) || name.contains(q)
          ? 45.0
          : 0.0;
      if (artist.isNotEmpty &&
          _normalize(t.artist).contains(_normalize(artist))) {
        result += 35;
      }
      return result;
    }

    ranked.sort((a, b) {
      if (mediaDuration > Duration.zero) {
        final aKnown = a.duration > Duration.zero;
        final bKnown = b.duration > Duration.zero;
        if (aKnown != bKnown) return aKnown ? -1 : 1;
        if (aKnown && bKnown) {
          final difference = (a.duration - mediaDuration).inMilliseconds
              .abs()
              .compareTo((b.duration - mediaDuration).inMilliseconds.abs());
          if (difference != 0) return difference;
        }
      }
      final scored = score(b).compareTo(score(a));
      return scored != 0 ? scored : a.key.compareTo(b.key);
    });
    return ranked;
  }

  Future<List<LyricSearchTrack>> _searchSource(
    LyricSource source,
    String query,
    CancelToken? token,
  ) async {
    switch (source) {
      case LyricSource.netease:
        final data = _map(
          await _get(
            'https://music.163.com/api/search/get/web',
            {'s': query, 'type': 1, 'offset': 0, 'total': 'true', 'limit': 20},
            token,
            referer: 'https://music.163.com/',
          ),
        );
        _check(data, 200);
        return [
          for (final song in _rows(_map(data['result'])['songs']))
            if (song['id'] != null && _string(song['name']).isNotEmpty)
              LyricSearchTrack(
                source: source,
                id: song['id'].toString(),
                title: _string(song['name']),
                artist: _rows(
                  song['artists'] ?? song['ar'],
                ).map((a) => _string(a['name'])).join(' / '),
                album: _string(_map(song['album'] ?? song['al'])['name']),
                duration: Duration(
                  milliseconds: _number(song['duration'] ?? song['dt']).round(),
                ),
              ),
        ];
      case LyricSource.qqMusic:
        final response = await _dio.post(
          'https://u.y.qq.com/cgi-bin/musicu.fcg',
          data: {
            'req_1': {
              'method': 'DoSearchForQQMusicDesktop',
              'module': 'music.search.SearchCgiService',
              'param': {
                'num_per_page': 20,
                'page_num': 1,
                'query': query,
                'search_type': 0,
              },
            },
          },
          options: Options(headers: {'Referer': 'https://c.y.qq.com/'}),
          cancelToken: token,
        );
        final data = _map(_json(response.data));
        _check(data, 0);
        final request = _map(data['req_1']);
        _check(request, 0);
        return [
          for (final song in _rows(
            _map(_map(_map(request['data'])['body'])['song'])['list'],
          ))
            if (song['id'] != null &&
                _string(song['title'] ?? song['name']).isNotEmpty)
              LyricSearchTrack(
                source: source,
                id: song['id'].toString(),
                secondaryId: _string(song['mid']),
                title: _string(song['title'] ?? song['name']),
                artist: _rows(
                  song['singer'],
                ).map((a) => _string(a['name'])).join(' / '),
                album: _string(_map(song['album'])['name']),
                duration: Duration(seconds: _number(song['interval']).round()),
              ),
        ];
      case LyricSource.lrclib:
        final data = await _get('https://lrclib.net/api/search', {
          'q': query,
        }, token);
        return [
          for (final song in _rows(data).take(50))
            if (song['id'] != null && _string(song['syncedLyrics']).isNotEmpty)
              LyricSearchTrack(
                source: source,
                id: song['id'].toString(),
                title: _string(song['trackName']),
                artist: _string(song['artistName']),
                album: _string(song['albumName']),
                duration: Duration(
                  milliseconds: (_number(song['duration']) * 1000).round(),
                ),
                syncedLyrics: _string(song['syncedLyrics']),
              ),
        ];
    }
  }

  Future<DownloadedLyrics> fetch(
    LyricSearchTrack track, {
    CancelToken? cancelToken,
  }) async {
    for (var attempt = 0; ; attempt++) {
      _ensureNotCancelled(cancelToken);
      try {
        return await _fetch(track, cancelToken: cancelToken);
      } catch (error) {
        _ensureNotCancelled(cancelToken);
        if (attempt >= _retryDelays.length || !_isTransient(error)) rethrow;
        await _pause(_retryDelays[attempt], cancelToken);
      }
    }
  }

  Future<DownloadedLyrics> _fetch(
    LyricSearchTrack track, {
    CancelToken? cancelToken,
  }) async {
    List<SubtitleItem> original = const [];
    List<SubtitleItem> translation = const [];
    switch (track.source) {
      case LyricSource.netease:
        final data = _map(
          await _get(
            'https://music.163.com/api/song/lyric/v1',
            {
              'id': track.id,
              'lv': -1,
              'kv': -1,
              'tv': -1,
              'rv': -1,
              'yv': -1,
              'ytv': -1,
              'yrv': -1,
            },
            cancelToken,
            referer: 'https://music.163.com/',
          ),
        );
        _check(data, 200);
        if (data['nolyric'] == true || data['uncollected'] == true) {
          throw const LyricUnavailableException();
        }
        original = _platform(_string(_map(data['yrc'])['lyric']));
        final usingYrc = original.isNotEmpty;
        if (!usingYrc) {
          original = _lrc(_string(_map(data['lrc'])['lyric']), track.duration);
        }
        // YRC and LRC can use different sentence boundaries. Use the translation
        // for the chosen timeline, never pair the two formats by row index.
        translation = _lrc(
          _string(_map(data[usingYrc ? 'ytlrc' : 'tlyric'])['lyric']),
          track.duration,
        );
        if (translation.isEmpty) {
          translation = _lrc(
            _string(_map(data['tlyric'])['lyric']),
            track.duration,
          );
        }
      case LyricSource.qqMusic:
        try {
          final response = await _dio.post(
            'https://c.y.qq.com/qqmusic/fcgi-bin/lyric_download.fcg',
            data: {
              'version': '15',
              'miniversion': '82',
              'lrctype': '4',
              'musicid': track.id,
            },
            options: Options(
              contentType: Headers.formUrlEncodedContentType,
              responseType: ResponseType.plain,
              headers: {'Referer': 'https://c.y.qq.com/'},
            ),
            cancelToken: cancelToken,
          );
          final decoded = await compute(_decodeQqXml, response.data.toString());
          original = _platform(decoded['original'] ?? '');
          if (original.isEmpty) {
            original = _lrc(decoded['original'] ?? '', track.duration);
          }
          translation = _lrc(decoded['translation'] ?? '', track.duration);
          if (translation.isEmpty) {
            translation = _platform(decoded['translation'] ?? '');
          }
        } catch (error) {
          if (error is DioException && CancelToken.isCancel(error)) rethrow;
          // QRC is optional. The ordinary lyric endpoint provides a fallback.
        }
        if (original.isEmpty || translation.isEmpty) {
          try {
            final data = _map(
              await _get(
                'https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg',
                {
                  'songmid': track.secondaryId,
                  'format': 'json',
                  'nobase64': 1,
                  'g_tk': 5381,
                },
                cancelToken,
                referer: 'https://c.y.qq.com/',
              ),
            );
            _check(data, 0);
            if (original.isEmpty) {
              original = _lrc(
                _decodeMaybeBase64(_string(data['lyric'])),
                track.duration,
              );
            }
            if (translation.isEmpty) {
              translation = _lrc(
                _decodeMaybeBase64(_string(data['trans'])),
                track.duration,
              );
            }
          } catch (error) {
            if (error is DioException && CancelToken.isCancel(error)) rethrow;
            if (original.isEmpty) rethrow;
          }
        }
      case LyricSource.lrclib:
        var raw = track.syncedLyrics;
        raw ??= _string(
          _map(
            await _get(
              'https://lrclib.net/api/get/${Uri.encodeComponent(track.id)}',
              {},
              cancelToken,
            ),
          )['syncedLyrics'],
        );
        original = _lrc(raw, track.duration);
    }
    original = _valid(original);
    if (original.isEmpty) {
      throw const LyricUnavailableException();
    }
    translation = _valid(translation);
    // Only offer a Chinese translation when the provider actually supplied it.
    if (!translation.any(
      (cue) => RegExp(r'[\u3400-\u9fff]').hasMatch(cue.text),
    )) {
      translation = [];
    }
    return DownloadedLyrics(
      track: track,
      original: original,
      translation: translation,
    );
  }

  Future<Object?> _get(
    String url,
    Map<String, Object?> params,
    CancelToken? token, {
    String? referer,
  }) async {
    final result = await _dio.get(
      url,
      queryParameters: params,
      cancelToken: token,
      options: Options(headers: {'Referer': ?referer}),
    );
    return _json(result.data);
  }

  static String errorMessage(Object error) {
    if (error is FormatException) return error.message;
    if (error is DioException) {
      return switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.receiveTimeout ||
        DioExceptionType.sendTimeout => '连接超时，请重试',
        DioExceptionType.badResponse =>
          '服务暂时不可用（${error.response?.statusCode ?? "未知状态"}）',
        DioExceptionType.cancel => '请求已取消',
        _ => '连接失败，请检查网络或代理设置',
      };
    }
    return '无法读取歌词数据，请尝试其他来源';
  }

  static Object? _json(Object? raw) => raw is String ? jsonDecode(raw) : raw;
  static Map _map(Object? raw) => raw is Map ? raw : const {};
  static Iterable<Map> _rows(Object? raw) =>
      raw is List ? raw.whereType<Map>() : const [];
  static String _string(Object? raw) => raw is String ? raw : '';
  static num _number(Object? raw) =>
      raw is num ? raw : num.tryParse('$raw') ?? 0;
  static String _normalize(String text) => text.toLowerCase().replaceAll(
    RegExp(r'[^\p{L}\p{N}]', unicode: true),
    '',
  );
  static void _check(Map data, int expected) {
    if (data['code'] != expected) {
      throw const FormatException('来源未返回有效数据，请稍后重试');
    }
  }

  static List<SubtitleItem> _platform(String raw) {
    try {
      return raw.isEmpty ? [] : TimedSubtitleParser.parsePlatform(raw);
    } catch (_) {
      return [];
    }
  }

  static List<SubtitleItem> _lrc(String raw, Duration duration) {
    try {
      return TimedSubtitleParser.parseLrc(
        raw,
        mediaDuration: duration > Duration.zero ? duration : null,
      );
    } catch (_) {
      return [];
    }
  }

  static List<SubtitleItem> _valid(List<SubtitleItem> cues) {
    final sorted =
        cues
            .where(
              (cue) =>
                  cue.text.trim().isNotEmpty &&
                  cue.startTime >= Duration.zero &&
                  cue.endTime > cue.startTime,
            )
            .toList()
          ..sort((a, b) => a.startTime.compareTo(b.startTime));
    return [
      for (var i = 0; i < sorted.length; i++) sorted[i].copyWith(index: i + 1),
    ];
  }
}

String _decodeMaybeBase64(String raw) {
  if (raw.isEmpty || raw.trimLeft().startsWith('[')) return raw;
  try {
    return utf8.decode(base64Decode(raw));
  } catch (_) {
    return raw;
  }
}

Map<String, String> _decodeQqXml(String raw) {
  final output = <String, String>{};
  // QQ's wrapper can contain invalid XML such as <miniversion="1" />.
  // Parse only the well-formed content elements, leaving the wrapper alone.
  final elements = RegExp(
    r'<(content|contentts)\b[^>]*>[\s\S]*?</\1\s*>',
  ).allMatches(raw);
  for (final element in elements) {
    final node = XmlDocument.parse(element.group(0)!).rootElement;
    final type = switch (node.name.local) {
      'content' => 'original',
      'contentts' => 'translation',
      _ => null,
    };
    if (type == null || node.innerText.trim().isEmpty) continue;
    try {
      var text = node.innerText.trim();
      if (RegExp(r'^[\da-fA-F\s]+$').hasMatch(text)) {
        text = text.replaceAll(RegExp(r'\s'), '');
      }
      var value = text.startsWith('[') || text.startsWith('<')
          ? text
          : LyricFileCodec.decode(utf8.encode(text)) ?? '';
      if (value.contains('LyricContent=')) {
        final xml = XmlDocument.parse(value);
        value = xml.descendants
            .whereType<XmlElement>()
            .expand((e) => e.attributes)
            .firstWhere((a) => a.name.local == 'LyricContent')
            .value;
      }
      output[type] = value;
    } catch (_) {
      /* An absent translation must not discard the original. */
    }
  }
  return output;
}
