import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

import '../../services/network/network_http.dart';
import 'subtitle_archive_service.dart';
import 'subtitle_search_models.dart';
import 'subtitle_release_info.dart';
import 'subtitle_subhd.dart';

/// Public subtitle search/catalogs work without configuration. Optional API
/// credentials are scoped to API calls and never forwarded to file URLs.
class SubtitleSearchService {
  SubtitleSearchService({Dio? dio})
    : _dio =
          dio ??
          NetworkHttp.instance.createDio(
            options: BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              sendTimeout: const Duration(seconds: 15),
              headers: {
                'User-Agent': 'FluentPlayer v1.0',
                'Accept': 'application/json',
              },
            ),
          ),
      _ownsDio = dio == null {
    _dio.interceptors.add(CookieManager(CookieJar()));
  }
  final Dio _dio;
  final bool _ownsDio;
  final Map<String, (String, String)> _tokens = {};
  Future<List<Map<String, dynamic>>>? _jimakuCatalog;
  DateTime? _catalogAt;
  final _works = <String, (DateTime, Future<List<SubtitleSearchWork>>)>{};
  final _animeWorks = <String, Future<Set<int>?>>{};
  static const maxDownloadBytes = 64 * 1024 * 1024;

  void dispose() {
    if (_ownsDio) _dio.close(force: true);
  }

  Future<Object?> _get(
    String url,
    Map<String, dynamic> query,
    Map<String, String> headers,
    CancelToken? token,
  ) async => _json(
    (await _dio.get<Object?>(
      url,
      queryParameters: query,
      options: Options(headers: headers),
      cancelToken: token,
    )).data,
  );

  Map<String, String> _headers(
    SubtitleSearchSource source,
    SubtitleSearchCredentials c,
  ) => switch (source) {
    SubtitleSearchSource.subhd => {},
    SubtitleSearchSource.xunlei => {},
    SubtitleSearchSource.opensubtitles => {'Api-Key': c.apiKey},
    SubtitleSearchSource.jimaku => {'Authorization': c.apiKey},
    _ => {'Authorization': 'Bearer ${c.apiKey}'},
  };

  Future<SubtitleSearchPage> search(
    SubtitleSearchSource source,
    SubtitleSearchQuery query,
    SubtitleSearchCredentials credentials, {
    CancelToken? cancelToken,
  }) async {
    if (source.requiresKey && !credentials.configured) {
      throw const SubtitleSearchException('请先连接这个字幕来源');
    }
    final headers = _headers(source, credentials);
    switch (source) {
      case SubtitleSearchSource.subhd:
        final work = query.work;
        if (work != null && !RegExp(r'^\d+$').hasMatch(work.id)) {
          throw const SubtitleSearchException('作品信息已失效，请重新选择作品');
        }
        final path = work == null
            ? '/search/${Uri.encodeComponent(query.text)}'
            : '/d/${Uri.encodeComponent(work.id)}';
        final body = await _html(
          'https://subhd.tv$path${query.page > 1 ? '/${query.page}' : ''}',
          cancelToken: cancelToken,
        );
        return compute(parseSubhdPage, (body, query));
      case SubtitleSearchSource.xunlei:
        if (query.page > 1) return const SubtitleSearchPage([]);
        final episodeTag = query.season != null
            ? ' S${query.season.toString().padLeft(2, '0')}${query.episode == null ? '' : 'E${query.episode.toString().padLeft(2, '0')}'}'
            : query.episode != null
            ? ' E${query.episode.toString().padLeft(2, '0')}'
            : '';
        final data = _map(
          await _get(
            'https://api-shoulei-ssl.xunlei.com/oracle/subtitle',
            {'name': '${query.text}$episodeTag'},
            {},
            cancelToken,
          ),
        );
        if (data['code'] != 0) {
          throw const SubtitleSearchException('迅雷字幕暂时不可用，请稍后重试');
        }
        final hits = <SubtitleSearchHit>[];
        for (final row in _rows(data['data'])) {
          final languages = (row['languages'] as List? ?? [])
              .map((e) => e.toString())
              .toList();
          if (query.language.isNotEmpty &&
              languages.isNotEmpty &&
              !languages.any(
                (lang) => _matchesLanguage(lang, query.language),
              )) {
            continue;
          }
          final name = _text(row['name'], '字幕.${_text(row['ext'], 'srt')}');
          final url = _text(row['url']);
          if (url.isEmpty) continue;
          final hit = SubtitleSearchHit(
            source: source,
            id: _text(row['cid'], url),
            title: _text(row['simple_name'], query.text),
            release: name,
            language: languages.join(' / '),
            format: _text(row['ext']).toUpperCase(),
            files: [SubtitleSearchFile(id: url, name: name, url: url)],
          );
          if (hit.releaseInfo.accepts(query.season, query.episode)) {
            hits.add(hit);
          }
        }
        return SubtitleSearchPage(hits);
      case SubtitleSearchSource.opensubtitles:
        final data = _map(
          await _get(
            'https://api.opensubtitles.com/api/v1/subtitles',
            {
              if (query.episode != null) 'episode_number': query.episode,
              if (query.language.isNotEmpty) 'languages': query.language,
              'page': query.page,
              'query': query.text.toLowerCase(),
              if (query.season != null) 'season_number': query.season,
            },
            headers,
            cancelToken,
          ),
        );
        final hits = <SubtitleSearchHit>[];
        for (final row in _rows(data['data'])) {
          final a = _map(row['attributes']);
          final feature = _map(a['feature_details']);
          final files = [
            for (final f in _rows(a['files']))
              if (f['file_id'] != null)
                SubtitleSearchFile(
                  id: '${f['file_id']}',
                  name: _text(f['file_name'], '字幕.srt'),
                  language: _text(a['language']),
                ),
          ];
          if (files.isEmpty) continue;
          hits.add(
            SubtitleSearchHit(
              source: source,
              id: '${row['id']}',
              title: _text(
                feature['movie_name'] ?? feature['title'],
                query.text,
              ),
              release: _text(a['release'], files.first.name),
              language: _text(a['language']),
              downloads: _int(a['download_count']),
              hearingImpaired: a['hearing_impaired'] == true,
              format: 'SRT',
              files: files,
              websiteUrl: a['url'] as String?,
              season: int.tryParse('${feature['season_number']}'),
              episode: int.tryParse('${feature['episode_number']}'),
            ),
          );
        }
        return SubtitleSearchPage(
          hits,
          hasMore: query.page < _int(data['total_pages']),
        );
      case SubtitleSearchSource.jimaku:
        // The website's public catalog and file links do not require an API
        // key. Cache the catalog, then search all three published title forms.
        if (query.page > 1 ||
            query.language.isNotEmpty && query.language != 'ja') {
          return const SubtitleSearchPage([]);
        }
        final rows = await _catalog();
        if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
        final wanted = [query.text, ...?query.work?.aliases]
            .map(SubtitleSearchQuery.cleanTitle)
            .map(_normalizeTitle)
            .where((s) => s.isNotEmpty)
            .toList();
        var matches = rows
            .where(
              (row) => ['name', 'english_name', 'japanese_name'].any((key) {
                final title = _normalizeTitle(_text(row[key]));
                return title.isNotEmpty &&
                    wanted.any((w) => title.contains(w) || w.contains(title));
              }),
            )
            .toList();
        Set<int>? animeIds;
        if (query.work != null &&
            (matches.any((r) => _int(r['anilist_id']) > 0) ||
                RegExp(
                  r'[\u3040-\u30ff]',
                ).hasMatch(query.work!.originalTitle))) {
          animeIds = await _animeWorkIds(query.work!);
          if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
          if (animeIds != null && animeIds.isNotEmpty) {
            matches = rows
                .where((r) => animeIds!.contains(_int(r['anilist_id'])))
                .toList();
          }
        }
        return SubtitleSearchPage([
          for (final row in matches)
            if (SubtitleReleaseInfo.parse(
              '${row['name']} ${row['japanese_name']}',
            ).accepts(query.season, null))
              SubtitleSearchHit(
                source: source,
                id: '${row['id']}',
                title: _text(
                  row['japanese_name'] ?? row['english_name'] ?? row['name'],
                  query.text,
                ),
                release: _text(row['name']),
                language: 'ja',
                websiteUrl: 'https://jimaku.cc/entry/${row['id']}',
                catalogId: 'jimaku:${row['id']}',
                season: animeIds != null && animeIds.isNotEmpty
                    ? query.work?.season
                    : null,
              ),
        ]);
      case SubtitleSearchSource.assrt:
        if (query.text.runes.length < 3) {
          throw const SubtitleSearchException('ASSRT 搜索词至少需要 3 个字');
        }
        final data = _map(
          await _get(
            'https://api.assrt.net/v1/sub/search',
            {'q': query.text, 'cnt': 15, 'pos': (query.page - 1) * 15},
            headers,
            cancelToken,
          ),
        );
        _checkAssrt(data);
        final rows = _rows(_map(data['sub'])['subs']);
        final hits = [
          for (final row in rows)
            SubtitleSearchHit(
              source: source,
              id: '${row['id']}',
              title: _text(row['native_name'], query.text),
              release: _text(row['videoname']),
              language: _text(_map(row['lang'])['desc']),
              format: _text(row['subtype']),
              websiteUrl: 'https://assrt.net/xml/sub/${row['id']}.xml',
            ),
        ];
        // ASSRT has no server language/episode filters; retain the labels so
        // users can choose accurately instead of guessing from a description.
        return SubtitleSearchPage(hits, hasMore: rows.length == 15);
      case SubtitleSearchSource.subdl:
        final data = _map(
          await _get(
            'https://api.subdl.com/api/v2/subtitles/search',
            {
              'film_name': query.text,
              if (query.language.isNotEmpty) 'languages': query.language,
              if (query.season != null) 'season': query.season,
              if (query.episode != null) 'episode': query.episode,
              'unpack': 1,
            },
            headers,
            cancelToken,
          ),
        );
        if (data['status'] == false || data['error'] != null) {
          throw const SubtitleSearchException('SubDL 无法完成这次搜索，请调整片名或检查来源连接');
        }
        if (query.page > 1) return const SubtitleSearchPage([]);
        final titles = _rows(data['results']);
        return SubtitleSearchPage([
          for (final row in _rows(data['subtitles']))
            SubtitleSearchHit(
              source: source,
              id: _text(row['n_id'] ?? row['url'] ?? row['name']),
              title: titles.isEmpty
                  ? query.text
                  : _text(titles.first['name'], query.text),
              release: _text(row['release_name'] ?? row['name']),
              language: _text(row['language'] ?? row['lang']),
              hearingImpaired: row['hi'] == true,
              files: _subdlFiles(row),
            ),
        ]);
    }
  }

  static bool _matchesLanguage(String label, String code) {
    return subtitleMatchesLanguage(label, code);
  }

  static String _normalizeTitle(String text) => text.toLowerCase().replaceAll(
    RegExp(r'[^\p{L}\p{N}]', unicode: true),
    '',
  );

  Future<String> _html(String url, {CancelToken? cancelToken}) async {
    final response = await _dio.get<String>(
      url,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.plain,
        headers: {'Accept': 'text/html'},
      ),
    );
    final text = response.data ?? '';
    if (text.length > 8 * 1024 * 1024) {
      throw const SubtitleSearchException('来源目录过大，请稍后重试');
    }
    return text;
  }

  Future<List<SubtitleSearchWork>> findWorks(
    String text, {
    CancelToken? cancelToken,
  }) async {
    final query = SubtitleSearchQuery.cleanTitle(text).trim();
    if (query.runes.length < 2) return [];
    final key = _normalizeTitle(query);
    final cached = _works[key];
    if (cached != null &&
        DateTime.now().difference(cached.$1) < const Duration(minutes: 15)) {
      return cached.$2;
    }
    final future = () async {
      // Shared catalog requests survive a single route closing. Session
      // generations prevent a late catalog response from replacing new input.
      final data = _map(
        await _get(
          'https://subhd.tv/searchD/${Uri.encodeComponent(query)}',
          {},
          {'Accept': 'application/json'},
          null,
        ),
      );
      if (data['success'] != true) {
        throw const SubtitleSearchException('作品目录暂时不可用，仍可直接搜索字幕');
      }
      return _rows(data['items'])
          .where((v) => RegExp(r'^\d+$').hasMatch('${v['id']}'))
          .map(SubtitleSearchWork.fromJson)
          .where((w) => w.title.isNotEmpty)
          .take(30)
          .toList();
    }();
    _works[key] = (DateTime.now(), future);
    while (_works.length > 24) {
      _works.remove(_works.keys.first);
    }
    try {
      return await future;
    } catch (_) {
      if (_works[key]?.$2 == future) _works.remove(key);
      rethrow;
    }
  }

  Future<Set<int>?> _animeWorkIds(SubtitleSearchWork work) async {
    final existing = _animeWorks[work.id];
    if (existing != null) {
      try {
        return await existing;
      } catch (_) {
        return null;
      }
    }
    final future = () async {
      final data = _map(
        _json(
          (await _dio.post<Object?>(
            'https://graphql.anilist.co',
            data: {
              'query':
                  r'query($search: String!) { Page(perPage: 8) { media(search: $search, type: ANIME) { id title { native romaji english } synonyms seasonYear } } }',
              'variables': {
                'search': work.originalTitle.isNotEmpty
                    ? work.originalTitle
                    : work.title,
              },
            },
            options: Options(headers: {'Accept': 'application/json'}),
          )).data,
        ),
      );
      final wanted = work.aliases.map(_normalizeTitle).toSet();
      final found = <int>{};
      for (final media in _rows(_map(_map(data['data'])['Page'])['media'])) {
        final names = [
          ..._map(media['title']).values,
          if (media['synonyms'] is List) ...media['synonyms'] as List,
        ];
        if (names.any(
          (name) => wanted.contains(_normalizeTitle(_text(name))),
        )) {
          final year = _text(media['seasonYear']);
          if (year.isEmpty || work.year.isEmpty || year == work.year) {
            found.add(_int(media['id']));
          }
        }
      }
      found.remove(0);
      return found.isEmpty ? null : found;
    }();
    _animeWorks[work.id] = future;
    while (_animeWorks.length > 24) {
      _animeWorks.remove(_animeWorks.keys.first);
    }
    try {
      return await future;
    } catch (_) {
      _animeWorks.remove(work.id);
      // Optional identity refinement never prevents the public name search.
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> _catalog() {
    if (_jimakuCatalog == null ||
        _catalogAt == null ||
        DateTime.now().difference(_catalogAt!) > const Duration(hours: 1)) {
      _catalogAt = DateTime.now();
      _jimakuCatalog = () async {
        try {
          final pages = await Future.wait([
            _html('https://jimaku.cc/'),
            _html('https://jimaku.cc/dramas'),
          ]);
          return await compute(parseJimakuCatalog, pages.join('\n'));
        } catch (_) {
          _jimakuCatalog = null;
          rethrow;
        }
      }();
    }
    return _jimakuCatalog!;
  }

  List<SubtitleSearchFile> _subdlFiles(Map<String, dynamic> row) {
    final unpacked = _rows(row['unpack_files']);
    return unpacked.isNotEmpty
        ? [
            for (final f in unpacked)
              if (f['url'] is String)
                SubtitleSearchFile(
                  id: _text(f['file_n_id'] ?? f['url']),
                  name: _text(f['name'], '字幕.srt'),
                  url: _subdlUrl(f['url']),
                  size: _int(f['size']),
                  language: _text(f['language']),
                ),
          ]
        : [
            if (row['url'] is String)
              SubtitleSearchFile(
                id: _text(row['url']),
                name: _text(row['name'], '字幕.zip'),
                url: _subdlUrl(row['url']),
              ),
          ];
  }

  String _subdlUrl(Object? url) =>
      Uri.parse('https://dl.subdl.com/').resolve(_text(url)).toString();

  Future<List<SubtitleSearchFile>> files(
    SubtitleSearchHit hit,
    SubtitleSearchQuery query,
    SubtitleSearchCredentials credentials, {
    CancelToken? cancelToken,
  }) async {
    if (hit.files.isNotEmpty) return hit.files;
    if (hit.source == SubtitleSearchSource.subhd) {
      final body = await _html(
        'https://subhd.tv/a/${Uri.encodeComponent(hit.id)}',
        cancelToken: cancelToken,
      );
      final entries = await compute(parseSubhdEntries, body);
      return [
        SubtitleSearchFile(
          id: hit.id,
          name: subtitleResourceLabel(hit),
          archiveEntries: entries,
          declaredOnly: true,
        ),
      ];
    }
    final headers = _headers(hit.source, credentials);
    if (hit.source == SubtitleSearchSource.jimaku) {
      final html = await _html(
        'https://jimaku.cc/entry/${Uri.encodeComponent(hit.id)}',
        cancelToken: cancelToken,
      );
      return compute(parseJimakuFiles, (html, hit.id, query.episode));
    }
    if (hit.source == SubtitleSearchSource.assrt) {
      final data = _map(
        await _get(
          'https://api.assrt.net/v1/sub/detail',
          {'id': hit.id},
          headers,
          cancelToken,
        ),
      );
      _checkAssrt(data);
      final rows = _rows(_map(data['sub'])['subs']);
      if (rows.isEmpty) return [];
      final row = rows.first;
      final files = _rows(row['filelist']);
      return files.isEmpty
          ? [
              if (row['url'] is String)
                SubtitleSearchFile(
                  id: hit.id,
                  name: _text(row['filename'], '字幕.zip'),
                  url: _text(row['url']),
                ),
            ]
          : [
              for (final file in files)
                if (file['url'] is String)
                  SubtitleSearchFile(
                    id: _text(file['url']),
                    name: _text(file['f'], '字幕.srt'),
                    url: _text(file['url']),
                  ),
            ];
    }
    return [];
  }

  Future<List<SubtitleSearchDocument>> download(
    SubtitleSearchHit hit,
    SubtitleSearchFile file,
    SubtitleSearchCredentials credentials, {
    CancelToken? cancelToken,
    void Function(double)? onProgress,
  }) async {
    String? url = file.url;
    var name = file.name;
    if (hit.source == SubtitleSearchSource.subhd) {
      url = await _subhdDownload(hit.id, cancelToken);
    }
    if (hit.source == SubtitleSearchSource.opensubtitles) {
      final headers = _headers(hit.source, credentials);
      var host = 'api.opensubtitles.com';
      if (credentials.username.isNotEmpty && credentials.password.isNotEmpty) {
        final identity =
            '${credentials.apiKey}\u0000${credentials.username}\u0000${credentials.password}';
        var auth = _tokens[identity];
        if (auth == null) {
          final login = _map(
            _json(
              (await _dio.post<Object?>(
                'https://api.opensubtitles.com/api/v1/login',
                data: {
                  'username': credentials.username,
                  'password': credentials.password,
                },
                options: Options(headers: headers),
                cancelToken: cancelToken,
              )).data,
            ),
          );
          final base = _text(login['base_url'], host);
          if (base != host && base != 'vip-api.opensubtitles.com') {
            throw const SubtitleSearchException('来源返回了无法使用的下载地址');
          }
          auth = (_text(login['token']), base);
          if (auth.$1.isEmpty) {
            throw const SubtitleSearchException('OpenSubtitles 登录失败，请检查账号');
          }
          _tokens[identity] = auth;
        }
        headers['Authorization'] = 'Bearer ${auth.$1}';
        host = auth.$2;
      }
      try {
        final data = _map(
          _json(
            (await _dio.post<Object?>(
              'https://$host/api/v1/download',
              data: {'file_id': int.parse(file.id), 'sub_format': 'srt'},
              options: Options(headers: headers),
              cancelToken: cancelToken,
            )).data,
          ),
        );
        url = data['link'] as String?;
        name = _text(data['file_name'], file.name);
      } on DioException catch (e) {
        if (e.response?.statusCode == 401) _tokens.clear();
        rethrow;
      }
    }
    if (url == null) throw const SubtitleSearchException('这个结果没有可下载的字幕文件');
    var uri = checkedDownloadUri(hit.source, url);
    // Handle each redirect explicitly so its host is validated before any
    // connection is made. Files never receive API/login headers.
    final bytes = BytesBuilder(copy: false);
    var response = await _fileResponse(uri, cancelToken);
    for (
      var redirects = 0;
      response.statusCode! >= 300 && response.statusCode! < 400;
      redirects++
    ) {
      await response.data?.stream.listen((_) {}).cancel();
      if (redirects >= 4) throw const SubtitleSearchException('下载重定向次数过多');
      final location = response.headers.value('location');
      if (location == null) {
        throw const SubtitleSearchException('来源没有返回有效的下载地址');
      }
      uri = checkedDownloadUri(hit.source, uri.resolve(location).toString());
      response = await _fileResponse(uri, cancelToken);
    }
    final length =
        int.tryParse(response.headers.value('content-length') ?? '') ?? 0;
    if (length > maxDownloadBytes) {
      await response.data?.stream.listen((_) {}).cancel();
      throw const SubtitleSearchException('字幕文件超过 64 MiB，请在来源网站选择较小的文件');
    }
    final body = response.data;
    if (body == null) throw const SubtitleSearchException('下载内容为空');
    await for (final chunk in body.stream) {
      if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
      if (bytes.length + chunk.length > maxDownloadBytes) {
        throw const SubtitleSearchException('字幕文件超过 64 MiB，请选择较小的文件');
      }
      bytes.add(chunk);
      if (length > 0) onProgress?.call((bytes.length / length).clamp(0, 1));
    }
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
    final payload = bytes.takeBytes();
    if (hit.source == SubtitleSearchSource.subhd &&
        file.archiveEntries.length == 1 &&
        !(payload.length >= 4 && payload[0] == 0x50 && payload[1] == 0x4b)) {
      name = file.archiveEntries.single;
    }
    return compute(decodeSubtitleSearchPayload, (payload, name));
  }

  Future<String> _subhdDownload(String id, CancelToken? token) async {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)) {
      throw const SubtitleSearchException('字幕标识无效');
    }
    final detail = 'https://subhd.tv/a/$id';
    await _html(detail, cancelToken: token);
    Future<Map<String, dynamic>> post(String endpoint, String referer) async {
      try {
        return _map(
          _json(
            (await _dio.post<Object?>(
              'https://subhd.tv/api/sub/$endpoint',
              data: {'sid': id},
              options: Options(
                headers: {'Referer': referer, 'Accept': 'application/json'},
                followRedirects: false,
              ),
              cancelToken: token,
            )).data,
          ),
        );
      } on DioException catch (e) {
        if (e.response?.statusCode == 403) {
          throw const SubtitleSearchException('SubHD 需要网页验证，请打开这条字幕的详情页下载后导入');
        }
        rethrow;
      }
    }

    final prepared = await post('prepare-download', detail);
    final temporary = Uri.parse(
      'https://subhd.tv',
    ).resolve(_text(prepared['url']));
    if (prepared['success'] != true ||
        temporary.scheme != 'https' ||
        temporary.host != 'subhd.tv' ||
        temporary.userInfo.isNotEmpty ||
        temporary.hasPort ||
        temporary.hasQuery ||
        temporary.hasFragment ||
        !RegExp(r'^/down/[A-Za-z0-9_-]+$').hasMatch(temporary.path)) {
      throw const SubtitleSearchException('SubHD 暂时无法准备下载，可打开字幕详情页继续');
    }
    await _html(temporary.toString(), cancelToken: token);
    final data = await post('down', temporary.toString());
    if (data['pass'] != true || _text(data['url']).isEmpty) {
      throw const SubtitleSearchException('SubHD 需要网页验证或暂时无法下载，请打开字幕详情页继续');
    }
    return checkedDownloadUri(
      SubtitleSearchSource.subhd,
      _text(data['url']),
    ).toString();
  }

  Future<Response<ResponseBody>> _fileResponse(Uri uri, CancelToken? token) =>
      openCancellableDioStream(
        (child) => _dio.get<ResponseBody>(
          uri.toString(),
          options: Options(
            responseType: ResponseType.stream,
            followRedirects: false,
            validateStatus: (s) => s != null && s >= 200 && s < 400,
          ),
          cancelToken: child,
        ),
        cancelToken: token,
      );

  static Uri checkedDownloadUri(SubtitleSearchSource source, String value) {
    final uri = Uri.tryParse(value);
    final domain = switch (source) {
      SubtitleSearchSource.subhd => 'dl.subhd.me',
      SubtitleSearchSource.xunlei => 'geilijiasu.com',
      SubtitleSearchSource.opensubtitles => 'opensubtitles.com',
      SubtitleSearchSource.jimaku => 'jimaku.cc',
      SubtitleSearchSource.assrt => 'assrt.net',
      SubtitleSearchSource.subdl => 'subdl.com',
    };
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort && uri.port != 80 && uri.port != 443 ||
        !(uri.host == domain || uri.host.endsWith('.$domain'))) {
      throw const SubtitleSearchException('来源返回了无法验证的下载地址，可前往网站查看');
    }
    // ASSRT's older API still emits HTTP file links; its file hosts serve TLS.
    return uri.replace(scheme: 'https');
  }

  static String errorMessage(Object error) {
    if (error is SubtitleSearchException) return error.message;
    if (error is FormatException) return error.message;
    if (error is DioException) {
      if (CancelToken.isCancel(error)) return '已取消';
      return switch (error.response?.statusCode) {
        401 => '来源连接未通过，请检查访问密钥或账号',
        403 => '来源要求网页验证或暂时限制访问，可打开字幕详情页继续',
        402 || 406 => '下载额度不足，请稍后重试或查看来源账户',
        429 => '请求太频繁或额度已用完，请稍后重试',
        404 => '这个字幕已失效，可以换一个结果',
        _ => '暂时无法连接字幕来源，请检查网络后重试',
      };
    }
    return '字幕读取失败，请重试或选择其他文件';
  }

  static Object? _json(Object? value) =>
      value is String ? jsonDecode(value) : value;
  static Map<String, dynamic> _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : {};
  static List<Map<String, dynamic>> _rows(Object? value) =>
      value is List ? value.whereType<Map>().map(_map).toList() : [];
  static String _text(Object? value, [String fallback = '']) =>
      value == null || value.toString().isEmpty ? fallback : value.toString();
  static int _int(Object? value) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? 0;
  static void _checkAssrt(Map<String, dynamic> data) {
    if (data['status'] == 0) return;
    throw SubtitleSearchException(
      data['status'] == 30900
          ? 'ASSRT 请求额度已用完，请稍后重试'
          : 'ASSRT 暂时无法返回字幕，请检查密钥或换个搜索词',
    );
  }
}

class SubtitleSearchException implements Exception {
  const SubtitleSearchException(this.message);
  final String message;
  @override
  String toString() => message;
}

String _htmlEntities(String value) => value.replaceAllMapped(
  RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|quot|amp|lt|gt|apos);'),
  (m) {
    final entity = m[1]!;
    if (entity.startsWith('#')) {
      final number = entity.startsWith('#x')
          ? int.tryParse(entity.substring(2), radix: 16)
          : int.tryParse(entity.substring(1));
      return number != null && number <= 0x10ffff
          ? String.fromCharCode(number)
          : m[0]!;
    }
    return const {
      'quot': '"',
      'amp': '&',
      'lt': '<',
      'gt': '>',
      'apos': "'",
    }[entity]!;
  },
);

List<Map<String, dynamic>> parseJimakuCatalog(String html) {
  final rows = <Map<String, dynamic>>[];
  final pattern = RegExp(
    r'<div\b[^>]*class="entry"[^>]*data-extra="([^"]+)"[^>]*>([\s\S]*?)</div>',
  );
  for (final match in pattern.allMatches(html)) {
    final id = RegExp(r'href="/entry/(\d+)"').firstMatch(match[2]!)?.group(1);
    if (id == null) continue;
    try {
      final row = jsonDecode(_htmlEntities(match[1]!)) as Map<String, dynamic>;
      rows.add({...row, 'id': id});
    } catch (_) {
      /* An individual malformed entry does not hide the catalog. */
    }
  }
  if (rows.isEmpty) {
    throw const SubtitleSearchException('Jimaku 目录暂时无法读取，请稍后重试');
  }
  return rows;
}

List<SubtitleSearchFile> parseJimakuFiles((String, String, int?) input) {
  final (html, id, episode) = input;
  final files = <SubtitleSearchFile>[];
  final pattern = RegExp(r'data-extra="([^"]+)"');
  for (final match in pattern.allMatches(html)) {
    try {
      final row = jsonDecode(_htmlEntities(match[1]!)) as Map<String, dynamic>;
      final name = row['name'] as String? ?? '';
      final url = row['url'] as String? ?? '';
      if (!url.startsWith('/entry/$id/download/') ||
          !{
            '.srt',
            '.ass',
            '.ssa',
            '.vtt',
            '.zip',
          }.contains(p.extension(name).toLowerCase())) {
        continue;
      }
      files.add(
        SubtitleSearchFile(
          id: url,
          name: name,
          url: Uri.parse('https://jimaku.cc').resolve(url).toString(),
          size: (row['size'] as num?)?.toInt() ?? 0,
          language: 'ja',
        ),
      );
    } catch (_) {}
  }
  if (episode != null) {
    // Keep the other episodes available: public filenames are not uniform.
    files.sort(
      (a, b) => (SubtitleReleaseInfo.parse(b.name).episode == episode ? 1 : 0)
          .compareTo(
            SubtitleReleaseInfo.parse(a.name).episode == episode ? 1 : 0,
          ),
    );
  }
  return files;
}

/// Parsing runs away from the UI isolate. The container is identified from
/// bytes, so a download is never labeled as ZIP just because a provider
/// used to assume that extension.
List<SubtitleSearchDocument> decodeSubtitleSearchPayload(
  (Uint8List, String) input,
) {
  final (bytes, name) = input;
  final result = const SubtitlePackageDecoder().decode(bytes, name: name);
  if (result.documents.isEmpty) {
    throw SubtitleSearchException(
      result.failure?.message ?? '没有找到可读取的 SRT、VTT、ASS 或 SSA 字幕',
    );
  }
  return result.documents;
}

String subtitleResourceLabel(SubtitleSearchHit hit) {
  final release = hit.release.trim();
  final title = hit.title.trim();
  if (release.isNotEmpty) return release;
  if (title.isNotEmpty) return title;
  return '字幕资源 ${hit.id}';
}
