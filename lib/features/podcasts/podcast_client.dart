import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:html/parser.dart' as html;
import '../../services/network/network_http.dart';
import 'podcast_feed_parser.dart';
import 'podcast_connection_policy.dart';
import 'podcast_models.dart';
import 'podcast_resolve_request.dart';

export 'podcast_resolve_request.dart';

typedef PodcastClientFactory = HttpClient Function();

class PodcastHttpStatusException extends HttpException {
  PodcastHttpStatusException(this.status, {Uri? uri, this.retryAfter})
    : super('播客来源返回 $status', uri: uri);

  final int status;
  final String? retryAfter;
}

class PodcastResponse {
  const PodcastResponse(this.bytes, this.status, this.url, this.headers);
  final List<int> bytes;
  final int status;
  final String url;
  final Map<String, String> headers;
}

class PodcastHttp {
  PodcastHttp({
    PodcastClientFactory? clientFactory,
    PodcastClientFactory? downloadClientFactory,
    PodcastConnectionPolicy? routes,
  }) : routes = routes ?? PodcastConnectionPolicy() {
    this.clientFactory = clientFactory ?? _automaticClient;
    this.downloadClientFactory =
        downloadClientFactory ?? clientFactory ?? _automaticClient;
  }
  late final PodcastClientFactory clientFactory;
  late final PodcastClientFactory downloadClientFactory;
  final PodcastConnectionPolicy routes;
  HttpClient _automaticClient() =>
      NetworkHttp.instance.createPodcastClient(routeFor: routes.modeFor);

  int _retiredClients = 0;
  int sharedEpoch() => Object.hash(
    _retiredClients,
    routes.generation,
    NetworkSettingsService.instance.deviceGeneration,
    NetworkSettingsService.instance.configuration.unifiedMode,
    NetworkSettingsService.instance.configuration.unifiedMode ==
            NetworkMode.custom
        ? NetworkSettingsService.instance.configuration.revision
        : 0,
  );

  bool connectionFailed(Uri uri, Object error) =>
      NetworkSettingsService.instance.configuration.unifiedMode == null &&
      routes.connectionFailed(
        uri,
        error is HttpException &&
                error.message.startsWith('Proxy failed to establish tunnel')
            ? const SocketException('设备代理连接失败')
            : error,
      );

  bool isConnectionFailure(HttpClientResponse response) =>
      NetworkHttp.instance.isPodcastConnectionFailure(response);

  void retireSharedClients() => _retiredClients++;

  Future<PodcastResponse> get(
    String url, {
    Map<String, String> headers = const {},
    int maxBytes = 32 * 1024 * 1024,
    void Function(HttpClient)? onClient,
    bool Function()? isCancelled,
  }) async {
    try {
      return await _getOnce(
        url,
        headers: headers,
        maxBytes: maxBytes,
        onClient: onClient,
      );
    } catch (error) {
      if (isCancelled?.call() == true) rethrow;
      if (!connectionFailed(Uri.parse(url), error)) rethrow;
      return _getOnce(
        url,
        headers: headers,
        maxBytes: maxBytes,
        onClient: onClient,
      );
    }
  }

  Future<PodcastResponse> _getOnce(
    String url, {
    Map<String, String> headers = const {},
    int maxBytes = 32 * 1024 * 1024,
    void Function(HttpClient)? onClient,
  }) async {
    final uri = Uri.parse(url);
    if (!['http', 'https'].contains(uri.scheme)) {
      throw const FormatException('仅支持 HTTP 或 HTTPS 播客链接');
    }
    final client = clientFactory()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      onClient?.call(client);
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 20));
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'FluentPlayer/1.0 Podcast',
      );
      headers.forEach(request.headers.set);
      final response = await request.close().timeout(
        const Duration(seconds: 25),
      );
      if (isConnectionFailure(response)) {
        throw const SocketException('设备代理连接失败');
      }
      final resultHeaders = <String, String>{};
      response.headers.forEach(
        (name, values) => resultHeaders[name] = values.join(', '),
      );
      if (response.statusCode != 200 && response.statusCode != 304) {
        throw PodcastHttpStatusException(
          response.statusCode,
          uri: uri,
          retryAfter: response.headers.value(HttpHeaders.retryAfterHeader),
        );
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 25))) {
        if (bytes.length + chunk.length > maxBytes) {
          throw const FormatException('播客来源内容超过读取上限');
        }
        bytes.addAll(chunk);
      }
      var finalUri = uri;
      for (final redirect in response.redirects) {
        finalUri = finalUri.resolveUri(redirect.location);
      }
      return PodcastResponse(
        bytes,
        response.statusCode,
        finalUri.toString(),
        resultHeaders,
      );
    } finally {
      client.close(force: true);
    }
  }
}

class PodcastResolution {
  const PodcastResolution(
    this.feed, {
    this.singleEpisode = false,
    this.focusEpisodeId,
    this.message,
  });
  final PodcastFeed feed;
  final bool singleEpisode;
  final String? focusEpisodeId;
  final String? message;
}

class PodcastClient {
  PodcastClient({PodcastHttp? http}) : http = http ?? PodcastHttp();
  final PodcastHttp http;
  final parser = const PodcastFeedParser();
  final _searchCache = <String, (DateTime, List<PodcastSearchResult>)>{};
  final _searchTimes = <DateTime>[];
  int _generation = 0;
  HttpClient? _activeSearch;
  void cancelSearch() {
    _generation++;
    _activeSearch?.close(force: true);
    _activeSearch = null;
  }

  Future<List<PodcastSearchResult>> search(
    String query, {
    String region = 'CN',
    String provider = 'apple',
  }) async {
    _activeSearch?.close(force: true);
    _activeSearch = null;
    final generation = ++_generation;
    if (query.trim().isEmpty) return [];
    final key = '$provider|$region|${query.trim()}';
    final cached = _searchCache[key];
    if (cached != null && DateTime.now().difference(cached.$1).inMinutes < 10) {
      return cached.$2;
    }
    _searchTimes.removeWhere(
      (t) => DateTime.now().difference(t).inMinutes >= 1,
    );
    if (_searchTimes.length >= 18) throw const FormatException('搜索较频繁，请稍后再试');
    _searchTimes.add(DateTime.now());
    final Map<String, dynamic> json;
    if (provider == 'index') {
      const storage = FlutterSecureStorage(
        aOptions: AndroidOptions(resetOnError: false),
      );
      final key = await storage.read(key: 'podcastIndexKey'),
          secret = await storage.read(key: 'podcastIndexSecret');
      if (key == null || secret == null || key.isEmpty || secret.isEmpty) {
        throw const FormatException(
          '请先在“播客设置 → 搜索与备份 → Podcast Index 搜索凭据”中配置凭据',
        );
      }
      final time = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
      final response = await http.get(
        Uri.https('api.podcastindex.org', '/api/1.0/search/byterm', {
          'q': query.trim(),
          'max': '50',
        }).toString(),
        headers: {
          'X-Auth-Key': key,
          'X-Auth-Date': time,
          'Authorization': sha1
              .convert(utf8.encode('$key$secret$time'))
              .toString(),
        },
        onClient: (client) => _activeSearch = client,
        isCancelled: () => generation != _generation,
      );
      json = Map<String, dynamic>.from(jsonDecode(utf8.decode(response.bytes)));
    } else {
      final response = await http.get(
        Uri.https('itunes.apple.com', '/search', {
          'term': query.trim(),
          'media': 'podcast',
          'entity': 'podcast',
          'country': region,
          'limit': '50',
        }).toString(),
        onClient: (client) => _activeSearch = client,
        isCancelled: () => generation != _generation,
      );
      json = Map<String, dynamic>.from(jsonDecode(utf8.decode(response.bytes)));
    }
    if (generation != _generation) return [];
    final rows = json[provider == 'index' ? 'feeds' : 'results'] as List? ?? [];
    final values = rows
        .whereType<Map>()
        .map(
          (r) => PodcastSearchResult(
            title: (r['collectionName'] ?? r['title'] ?? '').toString(),
            author: (r['artistName'] ?? r['author'] ?? '').toString(),
            feedUrl: (r['feedUrl'] ?? r['url'] ?? '').toString(),
            imageUrl:
                (r['artworkUrl600'] ?? r['artworkUrl100'] ?? r['image'] ?? '')
                    .toString(),
            appleId: (r['collectionId'] ?? r['itunesId'])?.toString(),
            website: (r['collectionViewUrl'] ?? r['link'] ?? '').toString(),
          ),
        )
        .where((r) => r.feedUrl.isNotEmpty)
        .toList();
    _searchCache[key] = (DateTime.now(), values);
    return values;
  }

  Future<PodcastResolution> resolve(
    String input, {
    Set<String>? visited,
    PodcastResolveRequest? request,
  }) async {
    request?.check();
    Future<PodcastResponse> read(String address) => http.get(
      address,
      onClient: request?.attach,
      isCancelled: request == null ? null : () => request.isStopped,
    );
    var url = input.trim();
    final shared = RegExp(r'https?://[^\s<>"\u3000]+').firstMatch(url);
    if (shared != null) {
      url = shared.group(0)!.replaceAll(RegExp(r'[）。，、]+$'), '');
    }
    if (RegExp(r'^\d+$').hasMatch(url)) {
      url = 'https://podcasts.apple.com/podcast/id$url';
    }
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw const FormatException('请输入有效的频道、节目或 RSS 链接');
    }
    final seen = visited ?? <String>{};
    if (!seen.add(url) || seen.length > 6) {
      throw const FormatException('订阅链接重定向过多');
    }
    if (uri.host == 'podcasts.apple.com' || uri.host == 'itunes.apple.com') {
      final id =
          RegExp(r'/id(\d+)').firstMatch(uri.path)?.group(1) ??
          uri.queryParameters['id'];
      if (id == null) throw const FormatException('链接中没有 Apple 播客频道编号');
      final result = await read(
        Uri.https('itunes.apple.com', '/lookup', {
          'id': id,
          'entity': 'podcast',
        }).toString(),
      );
      final entries =
          (jsonDecode(utf8.decode(result.bytes)) as Map)['results'] as List? ??
          [];
      final feed = entries
          .whereType<Map>()
          .map((e) => e['feedUrl'])
          .whereType<String>()
          .firstOrNull;
      if (feed == null) throw const FormatException('Apple 目录没有提供这个频道的公开订阅源');
      final resolved = await resolve(feed, visited: seen, request: request);
      final episodeId = uri.queryParameters['i'];
      if (episodeId == null) return resolved;
      PodcastEpisode? focus = resolved.feed.episodes
          .where(
            (episode) =>
                Uri.tryParse(episode.link)?.queryParameters['i'] == episodeId,
          )
          .firstOrNull;
      if (focus == null) {
        try {
          final lookup = await read(
            Uri.https('itunes.apple.com', '/lookup', {
              'id': episodeId,
              'entity': 'podcastEpisode',
            }).toString(),
          );
          final metadata =
              ((jsonDecode(utf8.decode(lookup.bytes)) as Map)['results']
                          as List? ??
                      [])
                  .whereType<Map>()
                  .firstOrNull;
          if (metadata != null) {
            final guid = metadata['episodeGuid']?.toString();
            final mediaUrl = metadata['episodeUrl']?.toString();
            final title = metadata['trackName']?.toString();
            focus = resolved.feed.episodes
                .where(
                  (episode) =>
                      (guid != null &&
                          guid.isNotEmpty &&
                          episode.guid == guid) ||
                      (mediaUrl != null &&
                          episode.media.any(
                            (m) =>
                                podcastCanonicalUrl(m.url) ==
                                podcastCanonicalUrl(mediaUrl),
                          )) ||
                      (title != null &&
                          title.isNotEmpty &&
                          episode.title == title),
                )
                .firstOrNull;
          }
        } catch (_) {
          request?.check();
          /* The channel remains available if episode lookup fails. */
        }
      }
      return PodcastResolution(
        resolved.feed,
        focusEpisodeId: focus?.id,
        message: focus == null
            ? '已找到频道，但分享的这一集不在当前公开节目列表中。可订阅后加载来源提供的历史节目。'
            : null,
      );
    }
    final result = await read(url);
    request?.check();
    final source = utf8.decode(result.bytes, allowMalformed: true);
    if (source.trimLeft().startsWith('<') &&
        RegExp(
          r'<(?:\w+:)?(?:rss|feed)(?:\s|>)',
          caseSensitive: false,
        ).hasMatch(source)) {
      return PodcastResolution(parser.parse(result.bytes, result.url));
    }
    final document = html.parse(source);
    final candidates = <String>{};
    for (final element in document.querySelectorAll('link[href], a[href]')) {
      final rel = (element.attributes['rel'] ?? '').toLowerCase().split(
        RegExp(r'\s+'),
      );
      if (element.localName == 'link' && !rel.contains('alternate')) continue;
      final explicitlyNamedRss =
          element.localName == 'a' &&
          RegExp(
            r'^(?:rss|atom)(?:\s+feed)?$|^RSS\s*订阅$|^订阅\s*RSS$',
            caseSensitive: false,
          ).hasMatch(element.text.trim());
      if (explicitlyNamedRss ||
          [
            'application/rss+xml',
            'application/atom+xml',
          ].contains(element.attributes['type']?.toLowerCase())) {
        final href = element.attributes['href'];
        if (href != null) {
          candidates.add(Uri.parse(result.url).resolve(href).toString());
        }
      }
    }
    for (final candidate in candidates.take(4)) {
      try {
        return await resolve(candidate, visited: seen, request: request);
      } catch (_) {
        request?.check();
        /* Try the next advertised feed. */
      }
    }
    throw const FormatException('这个页面没有提供可确认的公开订阅源。可以搜索频道名称，或粘贴 RSS 链接。');
  }
}
