import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';

import 'network/network_http.dart';

class BingTranslationException implements Exception {
  const BingTranslationException(this.message, {this.retryAt, this.statusCode});
  final String message;
  final DateTime? retryAt;
  final int? statusCode;
  @override
  String toString() => message;
}

/// Shared by file translation and successive local-ASR translation batches.
/// Dio owns routing: this client never selects a proxy or a direct connection.
class BingSubtitleTranslator {
  BingSubtitleTranslator({
    required Dio dio,
    this.concurrency = 4,
    this.batchSize = 30,
    this.requestInterval = const Duration(milliseconds: 150),
    Future<void> Function(Duration)? delay,
    DateTime Function()? now,
  }) : _dio = dio,
       _delay = delay ?? Future<void>.delayed,
       _now = now ?? DateTime.now;

  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
  final Dio _dio;
  final int concurrency, batchSize;
  final Duration requestInterval;
  final Future<void> Function(Duration) _delay;
  final DateTime Function() _now;
  final _cache = <String, String>{};
  int _cacheCharacters = 0;
  final Queue<Completer<void>> _waiters = Queue();
  int _active = 0, _sequence = 0;
  DateTime? _nextRequest, _blockedUntil;
  String? _blockReason;
  _BingSession? _session;
  Future<_BingSession>? _loadingSession;

  void _check(CancelToken token) {
    if (token.isCancelled) throw token.cancelError!;
    if (_blockedUntil?.isAfter(_now()) == true) {
      throw BingTranslationException(_blockReason!, retryAt: _blockedUntil);
    }
  }

  Future<T> _cancellable<T>(Future<T> work, CancelToken token) =>
      Future.any([work, token.whenCancel.then<T>((error) => throw error)]);

  Future<void> _acquire(CancelToken token) async {
    _check(token);
    if (_active < concurrency.clamp(1, 4)) {
      _active++;
      return;
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    try {
      await _cancellable(waiter.future, token);
    } catch (_) {
      if (!waiter.isCompleted) {
        _waiters.remove(waiter);
      } else {
        _release();
      }
      rethrow;
    }
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    } else {
      _active--;
    }
  }

  DateTime _retryAt(Headers headers, Duration fallback) {
    final value = headers.value('retry-after');
    final seconds = int.tryParse(value ?? '');
    if (seconds != null && seconds >= 0) {
      return _now().add(Duration(seconds: seconds));
    }
    if (value != null) {
      try {
        final date = HttpDate.parse(value);
        if (date.isAfter(_now())) return date;
      } on FormatException {
        /* Use a conservative cooldown. */
      }
    }
    return _now().add(fallback);
  }

  Never _restricted(Response<dynamic> response, {bool captcha = false}) {
    final until = _retryAt(
      response.headers,
      captcha ? const Duration(minutes: 15) : const Duration(minutes: 1),
    );
    if (_blockedUntil == null || until.isAfter(_blockedUntil!)) {
      _blockedUntil = until;
    }
    _blockReason = captcha
        ? '必应要求验证码，翻译已暂停，请稍后继续。'
        : '必应暂时限制翻译请求，已按服务端等待时间暂停。请稍后继续。';
    throw BingTranslationException(_blockReason!, retryAt: _blockedUntil);
  }

  Future<Response<dynamic>> _request(
    String method,
    Uri uri,
    CancelToken token, {
    Object? data,
    Map<String, String>? headers,
  }) async {
    const waits = [Duration(seconds: 1), Duration(seconds: 3)];
    for (var attempt = 0; ; attempt++) {
      try {
        return await _requestOnce(
          method,
          uri,
          token,
          data: data,
          headers: headers,
        );
      } catch (error) {
        // User cancellation and service cooldowns always win over retries.
        _check(token);
        if (attempt >= waits.length || !_isTransientRequestFailure(error)) {
          rethrow;
        }
        // Release the request slot before waiting, and keep backoff cancellable.
        await _cancellable(_delay(waits[attempt]), token);
      }
    }
  }

  bool _isTransientRequestFailure(Object error) {
    if (error is TimeoutException || error is SocketException) return true;
    if (error is BingTranslationException) {
      return const {408, 500, 502, 503, 504}.contains(error.statusCode);
    }
    if (error is! DioException) return false;
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.connectionError => true,
      DioExceptionType.unknown =>
        error.error is SocketException || error.error is TimeoutException,
      _ => false,
    };
  }

  Future<Response<dynamic>> _requestOnce(
    String method,
    Uri uri,
    CancelToken token, {
    Object? data,
    Map<String, String>? headers,
  }) async {
    await _acquire(token);
    try {
      _check(token);
      final now = _now();
      final start = _nextRequest?.isAfter(now) == true ? _nextRequest! : now;
      _nextRequest = start.add(requestInterval);
      final wait = start.difference(now);
      if (wait > Duration.zero) await _cancellable(_delay(wait), token);
      _check(token);
      final requestToken = CancelToken();
      var finished = false, timedOut = false;
      token.whenCancel.then((error) {
        if (!finished) requestToken.cancel(error);
      });
      final deadline = Timer(const Duration(seconds: 20), () {
        timedOut = true;
        requestToken.cancel('必应翻译请求超时');
      });
      try {
        final response = await _dio.requestUri<dynamic>(
          uri,
          data: data,
          cancelToken: requestToken,
          options: Options(
            method: method,
            contentType: method == 'POST'
                ? Headers.formUrlEncodedContentType
                : null,
            headers: {'User-Agent': _userAgent, ...?headers},
            followRedirects: method == 'GET',
            sendTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 15),
            validateStatus: (code) => code != null && code < 600,
            extra: {NetworkHttp.translationConnectionReuseKey: true},
          ),
        );
        if (response.statusCode == 429 ||
            response.statusCode == 503 &&
                response.headers.value('retry-after') != null) {
          _restricted(response);
        }
        if (response.statusCode == 403 ||
            response.headers.value('cf-mitigated') == 'challenge') {
          _restricted(response, captcha: true);
        }
        _check(token);
        if (response.statusCode != 200) {
          throw BingTranslationException(
            '必应翻译请求失败（HTTP ${response.statusCode}）',
            statusCode: response.statusCode,
          );
        }
        return response;
      } on DioException catch (_) {
        if (timedOut) throw TimeoutException('必应翻译请求超时，请检查字幕翻译的网络设置');
        rethrow;
      } finally {
        finished = true;
        deadline.cancel();
      }
    } finally {
      _release();
    }
  }

  Future<_BingSession> _loadSession() async {
    final response = await _request(
      'GET',
      Uri.parse('https://www.bing.com/translator'),
      CancelToken(),
    );
    final uri = response.realUri;
    if (uri.scheme != 'https' ||
        !(uri.host == 'bing.com' || uri.host.endsWith('.bing.com'))) {
      throw const BingTranslationException('必应翻译跳转异常，请检查字幕翻译的网络设置');
    }
    final body = response.data.toString();
    final ig = RegExp(r'IG:"([^"]+)"').firstMatch(body)?.group(1);
    final iid = RegExp(r'data-iid="([^"]+)"').firstMatch(body)?.group(1);
    final parameters = RegExp(
      r'params_AbusePreventionHelper\s*=\s*(\[[^\]]+\])',
    ).firstMatch(body)?.group(1);
    List<dynamic>? values;
    if (parameters != null) {
      try {
        values = jsonDecode(parameters) as List<dynamic>;
      } on FormatException {
        /* A changed page cannot be used as a session. */
      }
    }
    if (ig == null ||
        iid == null ||
        values == null ||
        values.length < 2 ||
        values[0] is! num ||
        values[1] is! String) {
      throw const BingTranslationException('无法取得必应网页翻译会话，请稍后重试');
    }
    final interval = values.length > 2 && values[2] is num
        ? (values[2] as num).toInt().clamp(30000, 3600000)
        : 300000;
    return _BingSession(
      uri.resolve('/ttranslatev3'),
      ig,
      iid,
      (values[0] as num).toInt().toString(),
      values[1],
      _now().add(Duration(milliseconds: interval - 10000)),
    );
  }

  Future<_BingSession> _getSession(CancelToken token) async {
    _check(token);
    if (_session != null && _session!.expires.isAfter(_now())) return _session!;
    var pending = _loadingSession;
    if (pending == null) {
      final loading = _loadSession();
      _loadingSession = loading;
      loading.then(
        (value) {
          _session = value;
          if (identical(_loadingSession, loading)) _loadingSession = null;
        },
        onError: (Object _, StackTrace _) {
          if (identical(_loadingSession, loading)) _loadingSession = null;
        },
      );
      pending = loading;
    }
    return _cancellable(pending, token);
  }

  Future<String> _send(
    List<String> texts,
    String from,
    String to,
    CancelToken token, {
    required bool tagged,
  }) async {
    final session = await _getSession(token);
    final text = tagged
        ? [
            for (var i = 0; i < texts.length; i++)
              '[${i.toString().padLeft(4, '0')}] ${texts[i]}',
          ].join('\n')
        : texts.single;
    final response = await _request(
      'POST',
      session.endpoint.replace(
        queryParameters: {
          'isVertical': '1',
          'IG': session.ig,
          'IID': '${session.iid}.${++_sequence}',
        },
      ),
      token,
      data: {
        'fromLang': from,
        'to': to,
        'text': text,
        'token': session.token,
        'key': session.key,
      },
      headers: {'Referer': session.endpoint.resolve('/translator').toString()},
    );
    var data = response.data;
    if (data is String) {
      try {
        data = jsonDecode(data);
      } on FormatException {
        throw const BingTranslationException('必应未返回有效翻译结果');
      }
    }
    if (data is Map) {
      if (data['ShowCaptcha'] == true || data['ShowCaptcha'] == 1) {
        _restricted(response, captcha: true);
      }
      final code = data['StatusCode'] ?? data['statusCode'];
      if (code == 401) _session = null;
      if (code == 429 || code == 401) _restricted(response);
      throw const BingTranslationException('必应网页翻译拒绝了请求，请稍后继续');
    }
    if (data is! List || data.isEmpty || data.first is! Map) {
      throw const BingTranslationException('必应翻译返回格式异常');
    }
    final translations = (data.first as Map)['translations'];
    if (translations is! List ||
        translations.isEmpty ||
        translations.first is! Map) {
      throw const BingTranslationException('必应没有返回译文');
    }
    final output = (translations.first as Map)['text']?.toString().trim() ?? '';
    if (output.isEmpty) throw const BingTranslationException('必应返回了空译文');
    return output;
  }

  Future<List<String>> _translateBatch(
    List<String> texts,
    String from,
    String to,
    CancelToken token, {
    bool reviewLanguage = true,
  }) async {
    if (texts.length == 1) {
      return [await _send(texts, from, to, token, tagged: false)];
    }
    final output = await _send(texts, from, to, token, tagged: true);
    final matches = RegExp(r'\[\s*(\d{4})\s*\]').allMatches(output).toList();
    final values = <int, String>{};
    for (var i = 0; i < matches.length; i++) {
      final at = int.parse(matches[i].group(1)!);
      if (at >= texts.length || values.containsKey(at)) {
        values.clear();
        break;
      }
      values[at] = output
          .substring(
            matches[i].end,
            i + 1 < matches.length ? matches[i + 1].start : output.length,
          )
          .trim();
    }
    if (values.length != texts.length || values.values.any((s) => s.isEmpty)) {
      final mid = texts.length ~/ 2;
      return [
        ...await _translateBatch(
          texts.sublist(0, mid),
          from,
          to,
          token,
          reviewLanguage: reviewLanguage,
        ),
        ...await _translateBatch(
          texts.sublist(mid),
          from,
          to,
          token,
          reviewLanguage: reviewLanguage,
        ),
      ];
    }
    final result = [for (var i = 0; i < texts.length; i++) values[i]!];
    if (reviewLanguage && to.startsWith('zh')) {
      final review = <int>[];
      for (var i = 0; i < texts.length; i++) {
        if (RegExp(r'[A-Za-z]').hasMatch(texts[i]) &&
            !RegExp(
              r'[\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]',
            ).hasMatch(texts[i]) &&
            !RegExp(r'[\u4e00-\u9fff]').hasMatch(result[i])) {
          review.add(i);
        }
      }
      if (review.length > 1) {
        final corrected = await _translateBatch(
          review.map((i) => texts[i]).toList(),
          from,
          to,
          token,
          reviewLanguage: false,
        );
        for (var i = 0; i < review.length; i++) {
          result[review[i]] = corrected[i];
        }
      }
      for (final i in review) {
        if (!RegExp(r'[\u4e00-\u9fff]').hasMatch(result[i])) {
          result[i] = await _send([texts[i]], from, to, token, tagged: false);
        }
      }
    }
    return result;
  }

  List<String> _pieces(String text) {
    final parts = <String>[];
    while (text.length > 800) {
      var end = 800;
      final space = text.lastIndexOf(RegExp(r'[\s。！？.!?]'), end);
      if (space >= 400) end = space + 1;
      final unit = text.codeUnitAt(end - 1);
      if (unit >= 0xd800 && unit <= 0xdbff) end--;
      parts.add(text.substring(0, end));
      text = text.substring(end);
    }
    if (text.isNotEmpty) parts.add(text);
    return parts;
  }

  void _remember(String key, String value) {
    if (key.length + value.length > 32000) return;
    final old = _cache.remove(key);
    if (old != null) _cacheCharacters -= key.length + old.length;
    _cache[key] = value;
    _cacheCharacters += key.length + value.length;
    while (_cache.length > 1024 || _cacheCharacters > 512000) {
      final first = _cache.keys.first;
      _cacheCharacters -= first.length + _cache.remove(first)!.length;
    }
  }

  Future<List<String>> translate({
    required List<String> texts,
    required String sourceLanguage,
    required String targetLanguage,
    required void Function(double) onProgress,
    void Function(int, String)? onTranslated,
    CancelToken? cancelToken,
  }) async {
    final token = CancelToken();
    var finished = false;
    if (cancelToken?.isCancelled == true) {
      token.cancel(cancelToken!.cancelError);
    }
    cancelToken?.whenCancel.then((error) {
      if (!finished) token.cancel(error);
    });
    final from = sourceLanguage.isEmpty || sourceLanguage == 'auto'
        ? 'auto-detect'
        : sourceLanguage;
    final output = List<String>.filled(texts.length, '');
    final jobs = <String, _CueTranslation>{};
    var done = 0;
    void publish(int index, String value) {
      _check(token);
      output[index] = value;
      onTranslated?.call(index, value);
      onProgress(++done / texts.length);
    }

    try {
      _check(token);
      for (var i = 0; i < texts.length; i++) {
        final text = texts[i].trim();
        if (text.isEmpty) {
          publish(i, '');
          continue;
        }
        final key = '$from\u0000$targetLanguage\u0000$text';
        final cached = _cache.remove(key);
        if (cached != null) {
          _cache[key] = cached;
          publish(i, cached);
          continue;
        }
        (jobs[key] ??= _CueTranslation(key, _pieces(text))).indices.add(i);
      }
      final batches = <List<_TranslationPiece>>[];
      var batch = <_TranslationPiece>[];
      var characters = 0;
      for (final job in jobs.values) {
        for (var i = 0; i < job.pieces.length; i++) {
          final piece = _TranslationPiece(job, i);
          if (batch.isNotEmpty &&
              (batch.length >= batchSize.clamp(1, 50) ||
                  characters + piece.text.length + 8 > 900)) {
            batches.add(batch);
            batch = [];
            characters = 0;
          }
          batch.add(piece);
          characters += piece.text.length + 8;
        }
      }
      if (batch.isNotEmpty) batches.add(batch);
      var next = 0;
      Object? failure;
      StackTrace? failureStack;
      Future<void> worker() async {
        while (next < batches.length && failure == null) {
          final selected = batches[next++];
          try {
            _check(token);
            final translated = await _translateBatch(
              selected.map((p) => p.text).toList(),
              from,
              targetLanguage,
              token,
            );
            for (var i = 0; i < selected.length; i++) {
              final piece = selected[i];
              piece.job.values[piece.index] = translated[i];
              if (piece.job.values.every((value) => value != null)) {
                final value = piece.job.values.join(' ');
                _remember(piece.job.key, value);
                for (final index in piece.job.indices) {
                  publish(index, value);
                }
              }
            }
          } catch (error, stack) {
            failure ??= error;
            failureStack ??= stack;
            token.cancel('必应翻译已停止');
          }
        }
      }

      await Future.wait(
        List.generate(
          math.min(concurrency.clamp(1, 4), batches.length),
          (_) => worker(),
        ),
      );
      if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
      _check(token);
      if (texts.isEmpty) onProgress(1);
      return output;
    } finally {
      finished = true;
    }
  }
}

class _BingSession {
  const _BingSession(
    this.endpoint,
    this.ig,
    this.iid,
    this.key,
    this.token,
    this.expires,
  );
  final Uri endpoint;
  final String ig, iid, key, token;
  final DateTime expires;
}

class _CueTranslation {
  _CueTranslation(this.key, this.pieces)
    : values = List.filled(pieces.length, null);
  final String key;
  final List<String> pieces;
  final List<String?> values;
  final List<int> indices = [];
}

class _TranslationPiece {
  const _TranslationPiece(this.job, this.index);
  final _CueTranslation job;
  final int index;
  String get text => job.pieces[index];
}
