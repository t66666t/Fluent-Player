import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:xml/xml.dart';
import '../../services/network/network_http.dart';
import '../../utils/app_branding.dart';

/// Credentials are stored by the sync service, never in a progress document.
class ProgressSyncWebDavConfig {
  const ProgressSyncWebDavConfig({
    required this.url,
    this.username = '',
    this.password = '',
  });

  final String url;
  final String username;
  final String password;

  Map<String, dynamic> toJson({bool includePassword = true}) => {
    'url': url,
    'username': username,
    if (includePassword) 'password': password,
  };

  factory ProgressSyncWebDavConfig.fromJson(Map<String, dynamic> json) =>
      ProgressSyncWebDavConfig(
        url: json['url'] as String? ?? '',
        username: json['username'] as String? ?? '',
        password: json['password'] as String? ?? '',
      );
}

class ProgressSyncWebDavException implements Exception {
  const ProgressSyncWebDavException(
    this.message, {
    this.statusCode,
    this.corruptDocument = false,
  });

  final String message;
  final int? statusCode;
  final bool corruptDocument;

  @override
  String toString() => message;
}

/// An append-only WebDAV transport for *already encrypted* change envelopes.
///
/// Each envelope needs an opaque `eventId`. Its digest is the filename, and
/// If-None-Match makes retries safe without letting devices overwrite each
/// other's changes. Encryption and merging belong to the calling sync service.
class ProgressSyncWebDav {
  ProgressSyncWebDav({
    required this.config,
    HttpClient? httpClient,
    NetworkHttp? network,
    this.timeout = const Duration(seconds: 15),
  }) : _base = _validateUrl(config.url),
       _client = httpClient ?? _defaultClient(config, network) {
    if (config.username.contains(':') ||
        config.username.contains(RegExp(r'[\r\n]')) ||
        config.password.contains(RegExp(r'[\r\n]'))) {
      throw const ProgressSyncWebDavException('WebDAV 账号或密码格式不正确。');
    }
    _client.connectionTimeout = timeout;
  }

  final ProgressSyncWebDavConfig config;
  final Duration timeout;
  final HttpClient _client;
  final Uri _base;
  bool _ready = false;
  bool _closed = false;
  final Set<String> _readWarnings = {};

  /// Bad remote files are retained for repair, but do not block unrelated data.
  List<String> takeReadWarnings() {
    final warnings = _readWarnings.toList(growable: false);
    _readWarnings.clear();
    return warnings;
  }

  static HttpClient _defaultClient(
    ProgressSyncWebDavConfig config,
    NetworkHttp? network,
  ) {
    final uri = _validateUrl(config.url);
    // Home NAS addresses keep their local route. Public servers follow shared
    // settings, with submitted sync writes protected from policy changes.
    if (_isLocalHost(uri.host)) {
      return HttpClient()..findProxy = (_) => 'DIRECT';
    }
    return (network ?? NetworkHttp.instance).createClient(
      scope: NetworkScope.other,
      source: uri,
      cancelOnChange: false,
    );
  }

  static const _namespace = [
    'FluentPlayerProgress',
    'v2',
    kApplicationId,
    'events',
  ];
  static const _maxEnvelopeBytes = 256 * 1024;
  static const _maxListingBytes = 8 * 1024 * 1024;
  static const _maxEntries = 50000;
  static final _fileName = RegExp(r'^[a-f0-9]{64}\.json$');
  static const _propfindBody = '''<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>''';

  Uri get _directory => _base.replace(
    pathSegments: [
      ..._base.pathSegments.where((s) => s.isNotEmpty),
      ..._namespace,
      '',
    ],
  );

  /// Checks reading and writing; removes its temporary, empty test file.
  Future<void> testConnection() async {
    await _ensureReady();
    await _listFiles();
    final random = Random.secure();
    final nonce = List.generate(16, (_) => random.nextInt(256));
    final probe = _child(
      '.connection-${base64Url.encode(nonce).replaceAll('=', '')}',
    );
    var written = false;
    try {
      final put = await _request(
        'PUT',
        probe,
        body: utf8.encode('{}'),
        createOnly: true,
      );
      _expect(put, {200, 201, 204}, '无法写入同步目录');
      written = true;
      final get = await _request('GET', probe, maxBytes: 32);
      _expect(get, {200}, '无法读取同步目录');
      if (utf8.decode(get.body) != '{}') {
        throw const ProgressSyncWebDavException('WebDAV 返回的测试文件不完整。');
      }
    } finally {
      if (written) {
        // Some read/write mounts disallow deletion. A leftover empty probe has
        // no private data and is ignored by change discovery.
        try {
          await _request('DELETE', probe, maxBytes: 64 * 1024);
        } on ProgressSyncWebDavException {
          // The useful read/write result takes precedence over probe cleanup.
        }
      }
    }
  }

  /// Returns a bounded batch. Pass previously merged event IDs to avoid
  /// downloading old records. Continue with another batch when this is full.
  Future<List<Map<String, dynamic>>> readChanges({
    Set<String> knownEventIds = const {},
    int maxChanges = 250,
  }) async {
    if (maxChanges < 1 || maxChanges > 2000) {
      throw ArgumentError.value(maxChanges, 'maxChanges', '必须在 1 到 2000 之间');
    }
    await _ensureReady();
    final knownFiles = knownEventIds.map(_nameForId).toSet();
    final files = await _listFiles();
    final results = <Map<String, dynamic>>[];
    for (final file in files) {
      if (knownFiles.contains(file.pathSegments.last)) continue;
      final _DavResponse response;
      try {
        response = await _request('GET', file);
      } on ProgressSyncWebDavException catch (error) {
        if (!error.corruptDocument) rethrow;
        _readWarnings.add(file.pathSegments.last);
        continue;
      }
      // Another client may have cleaned an old event between listing and GET.
      if (response.status == 404) continue;
      _expect(response, {200}, '无法读取同步记录');
      try {
        final value = jsonDecode(utf8.decode(response.body));
        if (value is! Map<String, dynamic>) throw const FormatException();
        final id = _eventId(value);
        if (_nameForId(id) != file.pathSegments.last) {
          throw const FormatException();
        }
        results.add(value);
      } on FormatException {
        _readWarnings.add(file.pathSegments.last);
        continue;
      }
      if (results.length >= maxChanges) break;
    }
    return results;
  }

  Future<void> writeChanges(List<Map<String, dynamic>> changes) async {
    if (changes.isEmpty) return;
    if (changes.length > 5000) {
      throw const ProgressSyncWebDavException('单次同步记录过多，请分批同步。');
    }
    // Validate the entire batch before the first network write.
    final pending = <({String name, List<int> bytes})>[];
    for (final change in changes) {
      final name = _nameForId(_eventId(change));
      final bytes = utf8.encode(jsonEncode(change));
      if (bytes.length > _maxEnvelopeBytes) {
        throw const ProgressSyncWebDavException('单条同步记录过大。');
      }
      pending.add((name: name, bytes: bytes));
    }
    await _ensureReady();
    for (final change in pending) {
      final response = await _request(
        'PUT',
        _child(change.name),
        body: change.bytes,
        createOnly: true,
      );
      // A retry of an immutable event has already succeeded.
      _expect(response, {200, 201, 204, 412}, '无法保存同步记录');
    }
  }

  /// Removes only explicitly superseded events after their replacement has
  /// been durably uploaded. The caller owns causal history and pruning policy.
  Future<void> deleteChanges(Set<String> eventIds) async {
    if (eventIds.isEmpty) return;
    if (eventIds.length > 5000) {
      throw const ProgressSyncWebDavException('单次清理记录过多，请分批同步。');
    }
    final names = <String>[];
    for (final id in eventIds) {
      if (id.isEmpty || id.length > 256) {
        throw const FormatException('同步记录缺少有效的 eventId');
      }
      names.add(_nameForId(id));
    }
    await _ensureReady();
    for (final name in names) {
      final response = await _request('DELETE', _child(name));
      _expect(response, {200, 204, 404}, '无法清理已合并的同步记录');
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _client.close(force: true);
  }

  Future<void> _ensureReady() async {
    if (_closed) throw const ProgressSyncWebDavException('同步连接已关闭。');
    if (_ready) return;
    await _ensureCollection(_directory);
    _ready = true;
  }

  Future<void> _ensureCollection(Uri uri) async {
    final response = await _request(
      'PROPFIND',
      uri,
      body: utf8.encode(_propfindBody),
      depth: '0',
      maxBytes: _maxListingBytes,
    );
    if (response.status == 207 || response.status == 200) {
      final entries = _parseResponses(response.body);
      final isDirectory = entries.any((element) {
        final resource = _responseUri(element, uri);
        return resource != null &&
            _samePath(resource, uri) &&
            _isCollection(element);
      });
      if (!isDirectory) {
        throw const ProgressSyncWebDavException('WebDAV 地址必须指向可访问的文件夹。');
      }
      return;
    }
    if (response.status != 404) {
      _expect(response, {207}, '无法访问 WebDAV 文件夹');
    }
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) {
      throw const ProgressSyncWebDavException('找不到 WebDAV 根目录，请检查地址。');
    }
    final parent = uri.replace(
      pathSegments: [...segments.take(segments.length - 1), ''],
    );
    await _ensureCollection(parent);
    final created = await _request('MKCOL', uri);
    if (created.status == 405) {
      // Another device may have created the directory concurrently. Verify it
      // rather than accepting a method-not-supported response as success.
      final check = await _request(
        'PROPFIND',
        uri,
        body: utf8.encode(_propfindBody),
        depth: '0',
        maxBytes: _maxListingBytes,
      );
      if (check.status == 207 &&
          _parseResponses(check.body).any((element) {
            final resource = _responseUri(element, uri);
            return resource != null &&
                _samePath(resource, uri) &&
                _isCollection(element);
          })) {
        return;
      }
    }
    _expect(created, {200, 201, 204}, '无法创建同步文件夹');
  }

  Future<List<Uri>> _listFiles() async {
    final response = await _request(
      'PROPFIND',
      _directory,
      body: utf8.encode(_propfindBody),
      depth: '1',
      maxBytes: _maxListingBytes,
    );
    _expect(response, {207}, '无法查看同步目录');
    final entries = _parseResponses(response.body);
    final files = <String, Uri>{};
    final directorySegments = _directory.pathSegments
        .where((s) => s.isNotEmpty)
        .toList();
    for (final entry in entries) {
      if (_isCollection(entry)) continue;
      final uri = _responseUri(entry, _directory);
      if (uri == null) continue;
      final segments = uri.pathSegments;
      if (segments.length != directorySegments.length + 1 ||
          !List.generate(
            directorySegments.length,
            (i) => segments[i] == directorySegments[i],
          ).every((v) => v) ||
          !_fileName.hasMatch(segments.last)) {
        continue;
      }
      files[segments.last] = uri;
    }
    final names = files.keys.toList()..sort();
    return names.map((name) => files[name]!).toList();
  }

  List<XmlElement> _parseResponses(List<int> bytes) {
    try {
      final source = utf8.decode(bytes);
      if (source.toUpperCase().contains('<!DOCTYPE')) {
        throw const FormatException();
      }
      final document = XmlDocument.parse(source);
      if (document.rootElement.name.local != 'multistatus') {
        throw const FormatException();
      }
      final entries = document.rootElement.childElements
          .where((element) => element.name.local == 'response')
          .toList();
      if (entries.length > _maxEntries) {
        throw const ProgressSyncWebDavException('同步记录较多，已超出当前目录的处理上限。');
      }
      return entries;
    } on ProgressSyncWebDavException {
      rethrow;
    } catch (_) {
      throw const ProgressSyncWebDavException('服务器没有返回有效的 WebDAV 文件列表。');
    }
  }

  Uri? _responseUri(XmlElement response, Uri requested) {
    final directStatus = response.childElements.where(
      (e) => e.name.local == 'status',
    );
    if (directStatus.isNotEmpty &&
        !directStatus.first.innerText.contains(RegExp(r'\s2\d\d\s'))) {
      return null;
    }
    final propertyStatuses = response.childElements
        .where((e) => e.name.local == 'propstat')
        .expand((e) => e.childElements.where((p) => p.name.local == 'status'));
    if (directStatus.isEmpty &&
        !propertyStatuses.any(
          (e) => e.innerText.contains(RegExp(r'\s200\s')),
        )) {
      return null;
    }
    final hrefs = response.childElements.where((e) => e.name.local == 'href');
    if (hrefs.length != 1) return null;
    final href = Uri.tryParse(hrefs.single.innerText.trim());
    if (href == null ||
        href.hasQuery ||
        href.hasFragment ||
        href.userInfo.isNotEmpty) {
      return null;
    }
    final uri = requested.resolveUri(href);
    if (!_sameOrigin(uri, _base)) return null;
    return uri;
  }

  bool _isCollection(XmlElement response) {
    for (final propstat in response.childElements.where(
      (e) => e.name.local == 'propstat',
    )) {
      final status = propstat.childElements.where(
        (e) => e.name.local == 'status',
      );
      if (status.isEmpty ||
          !status.first.innerText.contains(RegExp(r'\s200\s'))) {
        continue;
      }
      if (propstat.descendants.whereType<XmlElement>().any(
        (e) => e.name.local == 'collection',
      )) {
        return true;
      }
    }
    return false;
  }

  Future<_DavResponse> _request(
    String method,
    Uri uri, {
    List<int>? body,
    String? depth,
    bool createOnly = false,
    int maxBytes = _maxEnvelopeBytes,
  }) async {
    if (_closed) throw const ProgressSyncWebDavException('同步连接已关闭。');
    if (!_sameOrigin(uri, _base)) {
      throw const ProgressSyncWebDavException('WebDAV 返回了不同服务器的地址。');
    }
    HttpClientRequest? request;
    try {
      request = await openNetworkRequest(
        _client,
        method,
        uri,
        timeout: timeout,
      );
      // Never forward Basic credentials to a redirected URL, including a
      // supposedly harmless canonicalization redirect.
      request.followRedirects = false;
      request.maxRedirects = 0;
      if (config.username.isNotEmpty || config.password.isNotEmpty) {
        final auth = base64Encode(
          utf8.encode('${config.username}:${config.password}'),
        );
        request.headers.set(HttpHeaders.authorizationHeader, 'Basic $auth');
      }
      if (depth != null) request.headers.set('Depth', depth);
      if (createOnly) request.headers.set(HttpHeaders.ifNoneMatchHeader, '*');
      if (body != null) {
        request.headers.contentType = ContentType(
          'application',
          method == 'PROPFIND' ? 'xml' : 'json',
          charset: 'utf-8',
        );
        request.contentLength = body.length;
        request.add(body);
      }
      final response = await request.close().timeout(timeout);
      if (response.statusCode >= 300 && response.statusCode < 400) {
        await response.listen((_) {}).cancel();
        throw const ProgressSyncWebDavException('WebDAV 地址发生跳转，请填写跳转后的完整地址。');
      }
      final List<int> result;
      try {
        result = await readNetworkResponseBytes(
          response,
          maxBytes: maxBytes,
          idleTimeout: timeout,
          totalTimeout: timeout,
        );
      } on FormatException {
        throw const ProgressSyncWebDavException(
          'WebDAV 返回的数据过大。',
          corruptDocument: true,
        );
      }
      return _DavResponse(response.statusCode, result);
    } on ProgressSyncWebDavException {
      request?.abort();
      rethrow;
    } on TimeoutException {
      request?.abort();
      throw const ProgressSyncWebDavException('连接 WebDAV 超时，请检查网络或存储地址。');
    } catch (_) {
      request?.abort();
      throw const ProgressSyncWebDavException('无法连接 WebDAV，请检查地址、网络和证书。');
    }
  }

  Uri _child(String name) => _directory.replace(
    pathSegments: [..._directory.pathSegments.where((s) => s.isNotEmpty), name],
  );

  static String _eventId(Map<String, dynamic> change) {
    final value = change['eventId'];
    if (value is! String || value.isEmpty || value.length > 256) {
      throw const FormatException('同步记录缺少有效的 eventId');
    }
    return value;
  }

  static String _nameForId(String id) =>
      '${sha256.convert(utf8.encode(id))}.json';

  static void _expect(
    _DavResponse response,
    Set<int> accepted,
    String message,
  ) {
    if (accepted.contains(response.status)) return;
    if (response.status == 401 || response.status == 403) {
      throw ProgressSyncWebDavException(
        'WebDAV 账号、密码或文件夹权限不正确。',
        statusCode: response.status,
      );
    }
    throw ProgressSyncWebDavException(
      '$message（${response.status}）。',
      statusCode: response.status,
    );
  }

  static Uri _validateUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.pathSegments.length > 64 ||
        uri.pathSegments.any(
          (s) => s == '.' || s == '..' || s.contains('/') || s.contains('\\'),
        )) {
      throw const ProgressSyncWebDavException(
        '请输入完整的 WebDAV 文件夹地址，账号和密码请单独填写。',
      );
    }
    if (uri.scheme == 'http' && !_isLocalHost(uri.host)) {
      throw const ProgressSyncWebDavException(
        '公网 WebDAV 请使用 HTTPS；家中 NAS 可填写局域网 IP 地址。',
      );
    }
    return uri.replace(
      pathSegments: [...uri.pathSegments.where((s) => s.isNotEmpty), ''],
    );
  }

  static bool _isLocalHost(String host) {
    if (host.toLowerCase() == 'localhost') return true;
    final address = InternetAddress.tryParse(NetworkSites.socketHost(host));
    if (address == null) return false;
    if (address.isLoopback) return true;
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      return bytes[0] == 10 ||
          (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
          (bytes[0] == 192 && bytes[1] == 168) ||
          (bytes[0] == 169 && bytes[1] == 254);
    }
    return (bytes[0] & 0xfe) == 0xfc ||
        (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80);
  }

  static bool _sameOrigin(Uri a, Uri b) =>
      a.scheme == b.scheme && a.host == b.host && a.port == b.port;

  static bool _samePath(Uri a, Uri b) =>
      a.path.replaceFirst(RegExp(r'/+$'), '') ==
      b.path.replaceFirst(RegExp(r'/+$'), '');
}

class _DavResponse {
  const _DavResponse(this.status, this.body);
  final int status;
  final List<int> body;
}
