import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_webdav.dart';

class _RealHttpOverrides extends HttpOverrides {}

HttpClient _client() => HttpOverrides.runWithHttpOverrides(
  () => HttpClient()..findProxy = (_) => 'DIRECT',
  _RealHttpOverrides(),
);

String _name(String id) => '${sha256.convert(utf8.encode(id))}.json';

Map<String, dynamic> _event(String id, {String cipherText = 'encrypted'}) => {
  'version': 1,
  'eventId': id,
  'groupId': 'opaque-group',
  'nonce': 'nonce',
  'cipherText': cipherText,
  'mac': 'mac',
};

String _xmlEscape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

String _entry(String href, {bool collection = false, int status = 200}) =>
    '''
<d:response><d:href>${_xmlEscape(href)}</d:href><d:propstat>
<d:prop><d:resourcetype>${collection ? '<d:collection/>' : ''}</d:resourcetype></d:prop>
<d:status>HTTP/1.1 $status Status</d:status></d:propstat></d:response>''';

String _listing(Iterable<String> entries) =>
    '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">${entries.join()}</d:multistatus>';

class _DavServer {
  _DavServer(this.server);

  final HttpServer server;
  final directories = <String>{'/', '/dav/'};
  final files = <String, List<int>>{};
  final calls =
      <({String method, String path, String? auth, String? condition})>[];
  String? extraListing;
  String? listingOverride;
  String? redirect;
  int? forceStatus;
  String? expectedAuth;

  static Future<_DavServer> start() async {
    final fixture = _DavServer(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    fixture.server.listen(fixture._handle);
    addTearDown(() => fixture.server.close(force: true));
    return fixture;
  }

  String get url => 'http://127.0.0.1:${server.port}/dav/';
  String get eventDirectory => '/dav/FluentPlayerProgress/v1/events/';

  ProgressSyncWebDav transport({
    String? url,
    String username = '',
    String password = '',
  }) {
    final transport = ProgressSyncWebDav(
      config: ProgressSyncWebDavConfig(
        url: url ?? this.url,
        username: username,
        password: password,
      ),
      httpClient: _client(),
    );
    addTearDown(transport.close);
    return transport;
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final auth = request.headers.value(HttpHeaders.authorizationHeader);
    calls.add((
      method: request.method,
      path: path,
      auth: auth,
      condition: request.headers.value(HttpHeaders.ifNoneMatchHeader),
    ));
    final bytes = await request.fold<List<int>>(
      [],
      (result, part) => result..addAll(part),
    );
    final response = request.response;
    try {
      if (redirect != null) {
        response.statusCode = 307;
        response.headers.set(HttpHeaders.locationHeader, redirect!);
      } else if (forceStatus != null) {
        response.statusCode = forceStatus!;
      } else if (expectedAuth != null && auth != expectedAuth) {
        response.statusCode = 401;
      } else {
        switch (request.method) {
          case 'PROPFIND':
            if (!directories.contains(path)) {
              response.statusCode = 404;
              break;
            }
            response.statusCode = 207;
            response.headers.contentType = ContentType('application', 'xml');
            if (listingOverride != null) {
              response.write(listingOverride);
              break;
            }
            final entries = <String>[_entry(path, collection: true)];
            if (request.headers.value('Depth') == '1') {
              entries.addAll(
                files.keys
                    .where((p) {
                      return p.startsWith(path) &&
                          !p.substring(path.length).contains('/');
                    })
                    .map((p) => _entry(p)),
              );
              if (extraListing != null) entries.add(extraListing!);
            }
            response.write(_listing(entries));
          case 'MKCOL':
            final parent = Uri(path: path).resolve('..').path;
            if (directories.contains(path)) {
              response.statusCode = 405;
            } else if (!directories.contains(parent)) {
              response.statusCode = 409;
            } else {
              directories.add(path);
              response.statusCode = 201;
            }
          case 'PUT':
            final parent = Uri(path: path).resolve('.').path;
            if (!directories.contains(parent)) {
              response.statusCode = 409;
            } else if (files.containsKey(path) &&
                request.headers.value(HttpHeaders.ifNoneMatchHeader) == '*') {
              response.statusCode = 412;
            } else {
              files[path] = bytes;
              response.statusCode = 201;
            }
          case 'GET':
            if (files.containsKey(path)) {
              response.add(files[path]!);
            } else {
              response.statusCode = 404;
            }
          case 'DELETE':
            response.statusCode = files.remove(path) == null ? 404 : 204;
          default:
            response.statusCode = 405;
        }
      }
    } finally {
      await response.close();
    }
  }
}

void main() {
  test(
    'creates missing hierarchy, verifies read/write and removes probe',
    () async {
      final dav = await _DavServer.start();
      final transport = dav.transport(url: '${dav.url}player/backups/');
      await transport.testConnection();

      expect(
        dav.directories,
        contains('/dav/player/backups/FluentPlayerProgress/v1/events/'),
      );
      expect(dav.files, isEmpty);
      expect(dav.calls.where((c) => c.method == 'MKCOL').map((c) => c.path), [
        '/dav/player/',
        '/dav/player/backups/',
        '/dav/player/backups/FluentPlayerProgress/',
        '/dav/player/backups/FluentPlayerProgress/v1/',
        '/dav/player/backups/FluentPlayerProgress/v1/events/',
      ]);
      expect(dav.calls.where((c) => c.method == 'DELETE'), hasLength(1));
    },
  );

  test(
    'UTF-8 credentials stay in Authorization and config can omit password',
    () async {
      final dav = await _DavServer.start();
      const username = '我的用户';
      const password = 'p:a ss@密';
      dav.expectedAuth =
          'Basic ${base64Encode(utf8.encode('$username:$password'))}';
      final transport = dav.transport(username: username, password: password);
      await transport.writeChanges([_event('phone-1')]);

      expect(dav.calls.every((c) => c.auth == dav.expectedAuth), isTrue);
      expect(dav.files.keys.single, '${dav.eventDirectory}${_name('phone-1')}');
      expect(utf8.decode(dav.files.values.single), isNot(contains(password)));
      final config = ProgressSyncWebDavConfig(
        url: dav.url,
        username: username,
        password: password,
      );
      expect(config.toJson(includePassword: false), {
        'url': dav.url,
        'username': username,
      });
      expect(
        ProgressSyncWebDavConfig.fromJson(config.toJson()).password,
        password,
      );
    },
  );

  test(
    'different devices append immutable events and retries cannot overwrite',
    () async {
      final dav = await _DavServer.start();
      final first = dav.transport();
      final second = dav.transport();
      final firstEvent = _event('desktop/opaque:1');
      final secondEvent = _event('phone/opaque:1');
      await Future.wait([
        first.writeChanges([firstEvent]),
        second.writeChanges([secondEvent]),
      ]);
      await first.writeChanges([
        _event('desktop/opaque:1', cipherText: 'changed'),
      ]);
      final events = await second.readChanges();

      expect(events, unorderedEquals([firstEvent, secondEvent]));
      expect(dav.files, hasLength(2));
      expect(
        dav.calls
            .where((c) => c.method == 'PUT')
            .every((c) => c.condition == '*'),
        isTrue,
      );
    },
  );

  test(
    'known events are not downloaded and bounded batches reach remaining changes',
    () async {
      final dav = await _DavServer.start();
      final transport = dav.transport();
      await transport.writeChanges(List.generate(5, (i) => _event('event-$i')));
      final known = <String>{};
      final received = <Map<String, dynamic>>[];
      for (var i = 0; i < 3; i++) {
        final batch = await transport.readChanges(
          knownEventIds: known,
          maxChanges: 2,
        );
        expect(batch.length, lessThanOrEqualTo(2));
        received.addAll(batch);
        known.addAll(batch.map((event) => event['eventId'] as String));
      }
      expect(received, hasLength(5));
      expect(await transport.readChanges(knownEventIds: known), isEmpty);
      expect(dav.calls.where((c) => c.method == 'GET'), hasLength(5));
    },
  );

  test(
    'prunes only named immutable events and tolerates already removed events',
    () async {
      final dav = await _DavServer.start();
      final transport = dav.transport();
      await transport.writeChanges([_event('old'), _event('current')]);
      await transport.deleteChanges({'old', '../../outside'});
      await transport.deleteChanges({'old'});
      expect(await transport.readChanges(), [_event('current')]);
      expect(dav.calls.where((c) => c.method == 'DELETE').map((c) => c.path), [
        '${dav.eventDirectory}${_name('old')}',
        '${dav.eventDirectory}${_name('../../outside')}',
        '${dav.eventDirectory}${_name('old')}',
      ]);
    },
  );

  test('only direct, same-origin change paths are fetched', () async {
    final dav = await _DavServer.start();
    final transport = dav.transport();
    await transport.writeChanges([_event('safe')]);
    final name = _name('outside');
    dav.extraListing = [
      _entry('http://example.com/${dav.eventDirectory}$name'),
      _entry('/private/$name'),
      _entry('${dav.eventDirectory}nested/$name'),
      _entry('${dav.eventDirectory}$name?token=x'),
      _entry('${dav.eventDirectory}$name', status: 404),
      _entry('${dav.eventDirectory}../../$name'),
    ].join();
    expect(await transport.readChanges(), [_event('safe')]);
    expect(dav.calls.where((c) => c.method == 'GET').map((c) => c.path), [
      '${dav.eventDirectory}${_name('safe')}',
    ]);
  });

  test('malformed XML and document types fail clearly', () async {
    final dav = await _DavServer.start();
    final transport = dav.transport();
    await transport.writeChanges([_event('safe')]);
    for (final body in [
      '<broken',
      '<html>sign in</html>',
      '<!DOCTYPE x>${_listing([])}',
    ]) {
      dav.listingOverride = body;
      await expectLater(
        transport.readChanges(),
        throwsA(isA<ProgressSyncWebDavException>()),
      );
    }
  });

  test(
    'corrupt documents are isolated and repaired records are retried',
    () async {
      final dav = await _DavServer.start();
      final transport = dav.transport();
      await transport.writeChanges([_event('safe'), _event('other')]);
      final path = '${dav.eventDirectory}${_name('safe')}';
      for (final body in [
        'not json',
        jsonEncode(_event('different')),
        'x' * (256 * 1024 + 1),
      ]) {
        dav.files[path] = utf8.encode(body);
        expect(await transport.readChanges(), [_event('other')]);
        expect(transport.takeReadWarnings(), [_name('safe')]);
        expect(dav.files[path], utf8.encode(body));
      }
      dav.files[path] = utf8.encode(jsonEncode(_event('safe')));
      expect(await transport.readChanges(knownEventIds: {'other'}), [
        _event('safe'),
      ]);
      expect(transport.takeReadWarnings(), isEmpty);
    },
  );

  test(
    'authentication errors expose a useful status without credentials',
    () async {
      final dav = await _DavServer.start();
      dav.forceStatus = 401;
      final transport = dav.transport(
        username: 'private-user',
        password: 'private-password',
      );
      await expectLater(
        transport.testConnection(),
        throwsA(
          isA<ProgressSyncWebDavException>()
              .having((e) => e.statusCode, 'status', 401)
              .having(
                (e) => e.toString(),
                'message',
                isNot(contains('private-')),
              ),
        ),
      );
    },
  );

  test('redirects never receive the WebDAV credentials', () async {
    final dav = await _DavServer.start();
    final target = await _DavServer.start();
    dav.redirect = target.url;
    await expectLater(
      dav.transport(username: 'name', password: 'secret').testConnection(),
      throwsA(isA<ProgressSyncWebDavException>()),
    );
    expect(target.calls, isEmpty);
  });

  test('public plain HTTP and embedded credentials are rejected', () {
    for (final url in [
      'http://example.com/dav/',
      'ftp://192.168.1.5/dav/',
      'https://name:secret@example.com/dav/',
      'https://example.com/dav/?token=secret',
      'https://example.com/dav/#fragment',
      'https://example.com/dav/%2Fsecret/',
    ]) {
      final client = _client();
      addTearDown(() => client.close(force: true));
      expect(
        () => ProgressSyncWebDav(
          config: ProgressSyncWebDavConfig(url: url),
          httpClient: client,
        ),
        throwsA(isA<ProgressSyncWebDavException>()),
        reason: url,
      );
    }
    for (final url in [
      'http://192.168.1.2/dav/',
      'http://10.0.0.1/dav/',
      'http://[fd00::1]/dav/',
    ]) {
      final transport = ProgressSyncWebDav(
        config: ProgressSyncWebDavConfig(url: url),
        httpClient: _client(),
      );
      transport.close();
    }
  });
}
