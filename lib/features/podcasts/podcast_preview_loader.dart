import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';

import '../../services/network/network_recovery.dart';
import 'podcast_client.dart';
import 'podcast_models.dart';

class PodcastPreviewOffline implements Exception {
  const PodcastPreviewOffline();
}

/// Preview-only recovery. Other podcast reads keep their existing policy.
class PodcastPreviewLoader {
  PodcastPreviewLoader({
    required this.client,
    this.readConnectivity,
    this.retryDelay = const Duration(milliseconds: 500),
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  final PodcastClient client;
  final Future<List<ConnectivityResult>> Function()? readConnectivity;
  final Duration retryDelay;
  final DateTime Function() now;
  final _cache = <String, (DateTime, String)>{};
  int _cacheCharacters = 0;
  static const _maxCharacters = 4 * 1024 * 1024;
  static const _maxEntries = 6;
  static const _cacheLifetime = Duration(hours: 6);

  /// Copies isolate the cache from pagination and subscription mutations.
  PodcastResolution? cached(String input) {
    final key = input.trim();
    final entry = _cache.remove(key);
    if (entry == null) return null;
    if (now().difference(entry.$1) > _cacheLifetime) {
      _cacheCharacters -= entry.$2.length;
      return null;
    }
    _cache[key] = entry;
    final data = jsonDecode(entry.$2) as Map<String, dynamic>;
    return PodcastResolution(
      PodcastFeed(
        PodcastChannel.fromJson(data['channel'] as Map<String, dynamic>),
        (data['episodes'] as List)
            .map((row) => PodcastEpisode.fromJson(row as Map<String, dynamic>))
            .toList(),
      ),
      singleEpisode: data['singleEpisode'] == true,
      focusEpisodeId: data['focusEpisodeId'] as String?,
      message: data['message'] as String?,
    );
  }

  void _remember(String input, PodcastResolution result) {
    final key = input.trim();
    final snapshot = jsonEncode({
      'channel': result.feed.channel.toJson(),
      'episodes': result.feed.episodes
          .map((episode) => episode.toJson())
          .toList(),
      'singleEpisode': result.singleEpisode,
      'focusEpisodeId': result.focusEpisodeId,
      'message': result.message,
    });
    final previous = _cache.remove(key);
    if (previous != null) _cacheCharacters -= previous.$2.length;
    if (snapshot.length > _maxCharacters) return;
    _cache[key] = (now(), snapshot);
    _cacheCharacters += snapshot.length;
    while (_cache.length > _maxEntries || _cacheCharacters > _maxCharacters) {
      _cacheCharacters -= _cache.remove(_cache.keys.first)!.$2.length;
    }
  }

  Future<bool> _offline(PodcastResolveRequest request) async {
    final reader = readConnectivity;
    if (reader == null) return false;
    final unknown = Completer<List<ConnectivityResult>>();
    final timer = Timer(
      const Duration(seconds: 1),
      () => unknown.complete(<ConnectivityResult>[]),
    );
    try {
      final values = await request.wait(
        Future.any([Future.sync(reader), unknown.future]),
      );
      return values.isNotEmpty &&
          values.every((value) => value == ConnectivityResult.none);
    } catch (_) {
      request.check();
      // A missing, failed or slow detector is not proof that we are offline.
      return false;
    } finally {
      timer.cancel();
    }
  }

  Future<PodcastResolution> load(
    String input, {
    required PodcastResolveRequest request,
    void Function()? onRetry,
  }) async {
    request.check();
    if (await _offline(request)) throw const PodcastPreviewOffline();
    for (var attempt = 0; ; attempt++) {
      request.check();
      try {
        final result = await request.wait(
          client.resolve(input, request: request),
        );
        request.check();
        _remember(input, result);
        return result;
      } catch (error) {
        request.check();
        if (attempt >= 2 || !NetworkRecovery.isTransient(error)) rethrow;
        if (await _offline(request)) throw const PodcastPreviewOffline();
        final delay = _retryAfter(error) ?? retryDelay * (attempt + 1);
        // Never ignore a server cooldown or turn a preview into a long wait.
        if (delay >= request.remaining) rethrow;
        onRetry?.call();
        await request.delay(delay);
      }
    }
  }

  Duration? _retryAfter(Object error) {
    if (error is! PodcastHttpStatusException || error.retryAfter == null) {
      return null;
    }
    final value = error.retryAfter!.trim();
    final seconds = int.tryParse(value);
    if (seconds != null) return Duration(seconds: seconds < 0 ? 0 : seconds);
    try {
      final delay = HttpDate.parse(value).difference(now());
      return delay.isNegative ? Duration.zero : delay;
    } catch (_) {
      return null;
    }
  }
}

String podcastPreviewErrorMessage(Object error) {
  if (error is PodcastPreviewOffline) return '当前未连接网络，请连接后重新加载。';
  if (error is TimeoutException) return '加载超时，请检查网络后重新加载。';
  if (error is PodcastHttpStatusException) {
    if (error.status == 429) return '播客来源暂时限制访问，请稍后重新加载。';
    if (error.status == 401 || error.status == 403) {
      return '播客来源暂时拒绝访问，请稍后再试。';
    }
    if (error.status == 404 || error.status == 410) {
      return '这个播客的订阅源已不存在或暂不可用。';
    }
    return '播客来源暂时无法响应，请稍后重新加载。';
  }
  if (error is HandshakeException) return '无法建立安全连接，请检查网络或来源地址。';
  if (error is FormatException) return error.message;
  return '连接暂时中断，请检查网络后重新加载。';
}
