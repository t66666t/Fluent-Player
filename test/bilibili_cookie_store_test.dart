import 'dart:convert';
import 'dart:io' show Directory;
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/debug/log_redaction.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_cookie_store.dart';

class _MemorySecretStorage implements BilibiliSecretStorage {
  final Map<String, String> values = <String, String>{};
  bool failWrites = false;
  bool failReads = false;

  @override
  Future<String?> read(String key) async {
    if (failReads) throw StateError('keychain locked');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('keychain locked');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// Answers every request with [handler]; never touches the network.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final ResponseBody Function(RequestOptions options) handler;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, {int status = 200, List<String>? setCookie}) {
  return ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
      'set-cookie': ?setCookie,
    },
  );
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('bili_cookie_store_test');
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  Future<void> writeLegacyJar(Map<String, String> cookies) async {
    final jar = PersistCookieJar(
      storage: FileStorage(
        '${temp.path}/${BilibiliCookieStore.legacyFolderName}',
      ),
    );
    await jar.saveFromResponse(Uri.parse('https://api.bilibili.com'), [
      for (final e in cookies.entries)
        Cookie(e.key, e.value)
          ..domain = '.bilibili.com'
          ..path = '/'
          ..expires = DateTime.now().add(const Duration(days: 30)),
    ]);
  }

  Directory legacyDir() =>
      Directory('${temp.path}/${BilibiliCookieStore.legacyFolderName}');

  group('legacy cookie migration', () {
    test(
      'moves legacy login into secure storage and deletes the folder',
      () async {
        await writeLegacyJar({
          'SESSDATA': 'abc%2C123',
          'bili_jct': 'csrf',
          'buvid3': 'x',
        });
        final secrets = _MemorySecretStorage();
        final store = BilibiliCookieStore(
          storage: secrets,
          dataDirectory: () async => temp,
        );

        final result = await store.migrateLegacyIfPresent();

        expect(result.outcome, BilibiliLegacyCookieMigration.migrated);
        expect(await store.readCookies(), {
          'SESSDATA': 'abc%2C123',
          'bili_jct': 'csrf',
          'buvid3': 'x',
        });
        expect(legacyDir().existsSync(), isFalse);
      },
    );

    test('keeps the legacy folder when secure storage fails', () async {
      await writeLegacyJar({'SESSDATA': 'abc'});
      final secrets = _MemorySecretStorage()..failWrites = true;
      final store = BilibiliCookieStore(
        storage: secrets,
        dataDirectory: () async => temp,
      );

      final result = await store.migrateLegacyIfPresent();

      expect(result.outcome, BilibiliLegacyCookieMigration.failedKeptLegacy);
      expect(result.legacyCookies['SESSDATA'], 'abc');
      expect(legacyDir().existsSync(), isTrue);
    });

    test('does not overwrite a newer secure session', () async {
      await writeLegacyJar({'SESSDATA': 'old'});
      final secrets = _MemorySecretStorage();
      final store = BilibiliCookieStore(
        storage: secrets,
        dataDirectory: () async => temp,
      );
      await store.replaceCookies({'SESSDATA': 'new'});

      await store.migrateLegacyIfPresent();

      expect((await store.readCookies())['SESSDATA'], 'new');
      expect(legacyDir().existsSync(), isFalse);
    });

    test('no legacy folder is a no-op', () async {
      final store = BilibiliCookieStore(
        storage: _MemorySecretStorage(),
        dataDirectory: () async => temp,
      );
      final result = await store.migrateLegacyIfPresent();
      expect(result.outcome, BilibiliLegacyCookieMigration.none);
    });
  });

  group('cookie input parsing', () {
    test('accepts a bare SESSDATA value', () {
      expect(parseBilibiliCookieInput(' abc%2C1*x '), {
        'SESSDATA': 'abc%2C1*x',
      });
    });

    test('accepts a full cookie header', () {
      expect(parseBilibiliCookieInput('SESSDATA=a; bili_jct=b; buvid3=c'), {
        'SESSDATA': 'a',
        'bili_jct': 'b',
        'buvid3': 'c',
      });
    });
  });

  test(
    'QR merges missing csrf from a trusted redirect even with SESSDATA header',
    () {
      final cookies = BilibiliApiService.extractQrLoginCookies(
        setCookieHeaders: ['SESSDATA=header-session; Path=/; HttpOnly'],
        redirectUrl:
            'https://passport.bilibili.com/crossDomain?SESSDATA=other&bili_jct=redirect-csrf&DedeUserID=42',
      );
      expect(cookies, {
        'SESSDATA': 'header-session',
        'bili_jct': 'redirect-csrf',
        'DedeUserID': '42',
      });
      for (final url in [
        'https://bilibili.com.evil.example/?bili_jct=x',
        'http://passport.bilibili.com/?bili_jct=x',
      ]) {
        expect(
          BilibiliApiService.extractQrLoginCookies(
            setCookieHeaders: [],
            redirectUrl: url,
          ),
          isEmpty,
        );
      }
    },
  );

  group('login verification', () {
    BilibiliApiService buildService(
      _FakeAdapter adapter,
      _MemorySecretStorage secrets,
    ) {
      return BilibiliApiService(
        cookieStore: BilibiliCookieStore(
          storage: secrets,
          dataDirectory: () async => temp,
        ),
        httpClientAdapter: adapter,
      );
    }

    test('saves cookies only after nav confirms the login', () async {
      final adapter = _FakeAdapter(
        (_) => _json({
          'code': 0,
          'data': {'isLogin': true, 'mid': 1, 'uname': 'me', 'face': ''},
        }),
      );
      final secrets = _MemorySecretStorage();
      final api = buildService(adapter, secrets);
      await api.init();

      final account = await api.loginWithCookieInput('SESSDATA=s; bili_jct=j');

      expect(account.name, 'me');
      expect(
        adapter.requests.single.headers['Cookie'],
        'SESSDATA=s; bili_jct=j',
      );
      expect(
        secrets.values[BilibiliCookieStore.storageKey],
        contains('"SESSDATA":"s"'),
      );
      expect(await api.hasCookie(), isTrue);
    });

    test('browser identity survives verification and an app restart', () async {
      final adapter = _FakeAdapter(
        (_) => _json({
          'code': 0,
          'data': {'isLogin': true, 'mid': 1, 'uname': 'me', 'face': ''},
        }),
      );
      final secrets = _MemorySecretStorage();
      final api = buildService(adapter, secrets);
      await api.init();
      await api.loginWithCookieInput(
        'SESSDATA=s; bili_jct=j; buvid3=BROWSER-B3; buvid4=BROWSER-B4; '
        'buvid_fp=BROWSER-FP; b_nut=1700000000; _uuid=BROWSER-UUID; '
        'bili_ticket=SIGNED-TICKET; bili_ticket_expires=1800000000; '
        'unrelated=discard',
      );
      final restarted = buildService(adapter, secrets);
      await restarted.init();
      final cookies = await restarted.readLoginCookies();
      expect(cookies['buvid3'], 'BROWSER-B3');
      expect(cookies['buvid4'], 'BROWSER-B4');
      expect(cookies['buvid_fp'], 'BROWSER-FP');
      expect(cookies['bili_ticket'], 'SIGNED-TICKET');
      expect(cookies['bili_ticket_expires'], '1800000000');
      expect(cookies['b_nut'], '1700000000');
      expect(cookies['_uuid'], 'BROWSER-UUID');
      expect(cookies['unrelated'], isNull);
      expect(
        adapter.requests.single.headers['Cookie'],
        contains('buvid3=BROWSER-B3'),
      );
    });

    test('rejected cookies are not saved', () async {
      final adapter = _FakeAdapter(
        (_) => _json({
          'code': -101,
          'data': {'isLogin': false},
        }),
      );
      final secrets = _MemorySecretStorage();
      final api = buildService(adapter, secrets);
      await api.init();

      await expectLater(
        api.loginWithCookieInput('bad'),
        throwsA(
          isA<BilibiliAuthException>().having(
            (e) => e.status,
            'status',
            BilibiliLoginStatus.expired,
          ),
        ),
      );
      expect(secrets.values, isEmpty);
      expect(await api.hasCookie(), isFalse);
    });

    test('network errors keep the stored login', () async {
      final secrets = _MemorySecretStorage()
        ..values[BilibiliCookieStore.storageKey] = '{"SESSDATA":"kept"}';
      final adapter = _FakeAdapter(
        (o) => throw DioException.connectionError(
          requestOptions: o,
          reason: 'offline',
        ),
      );
      final api = buildService(adapter, secrets);
      await api.init();

      expect(
        await api.checkLoginStatusDetailed(),
        BilibiliLoginStatus.networkError,
      );
      await expectLater(
        api.loginWithCookieInput('SESSDATA=other'),
        throwsA(isA<BilibiliAuthException>()),
      );
      expect(
        secrets.values[BilibiliCookieStore.storageKey],
        '{"SESSDATA":"kept"}',
      );
      expect(await api.hasCookie(), isTrue);
    });

    test('no stored cookie reports logged out without a request', () async {
      final adapter = _FakeAdapter((_) => _json({'code': 0}));
      final api = buildService(adapter, _MemorySecretStorage());
      await api.init();

      expect(
        await api.checkLoginStatusDetailed(),
        BilibiliLoginStatus.loggedOut,
      );
      expect(adapter.requests, isEmpty);
    });

    test(
      'login state initializes the saved session without caller init',
      () async {
        final secrets = _MemorySecretStorage()
          ..values[BilibiliCookieStore.storageKey] =
              '{"SESSDATA":"saved","bili_jct":"csrf"}';
        final adapter = _FakeAdapter(
          (_) => _json({
            'code': 0,
            'data': {'isLogin': true, 'mid': 42, 'uname': 'saved account'},
          }),
        );
        final api = buildService(adapter, secrets);
        expect(
          (await api.fetchLoginState()).status,
          BilibiliLoginStatus.loggedIn,
        );
        expect(
          adapter.requests.single.headers['Cookie'],
          contains('SESSDATA=saved'),
        );
      },
    );

    test(
      'verified login cannot be overwritten by delayed initialization',
      () async {
        final secrets = _MemorySecretStorage()
          ..values[BilibiliCookieStore.storageKey] = '{"SESSDATA":"old"}';
        final adapter = _FakeAdapter(
          (_) => _json({
            'code': 0,
            'data': {'isLogin': true, 'mid': 42, 'uname': 'new account'},
          }),
        );
        final api = buildService(adapter, secrets);
        await api.verifyAndSaveCookies({
          'SESSDATA': 'new',
          'bili_jct': 'new-csrf',
        });
        await api.init();
        expect((await api.readLoginCookies())['SESSDATA'], 'new');
      },
    );

    test(
      'QR partial headers produce a saved session usable after restart',
      () async {
        final secrets = _MemorySecretStorage();
        final adapter = _FakeAdapter((o) {
          if (o.path.contains('qrcode/poll')) {
            return _json(
              {
                'code': 0,
                'data': {
                  'code': 0,
                  'url':
                      'https://passport.bilibili.com/crossDomain?bili_jct=qr-csrf&DedeUserID=42',
                },
              },
              setCookie: [
                'SESSDATA=qr%2Csession; Path=/; Domain=bilibili.com; HttpOnly',
              ],
            );
          }
          if (o.path.endsWith('/nav')) {
            return _json({
              'code': 0,
              'data': {'isLogin': true, 'mid': 42, 'uname': 'qr account'},
            });
          }
          fail('Unexpected endpoint: ${o.path}');
        });
        final api = buildService(adapter, secrets);
        expect((await api.pollQrCode('key'))['success'], isTrue);
        final restarted = buildService(adapter, secrets);
        expect(
          (await restarted.fetchLoginState()).status,
          BilibiliLoginStatus.loggedIn,
        );
        expect((await restarted.readLoginCookies())['bili_jct'], 'qr-csrf');
        expect(adapter.requests.every((r) => r.method == 'GET'), isTrue);
        expect(
          adapter.requests.last.headers['Cookie'],
          contains('SESSDATA=qr%2Csession'),
        );
        expect(
          adapter.requests.any((r) => r.path.contains('/finger/')),
          isFalse,
        );
      },
    );

    for (final accepted in [false, true]) {
      test(
        'QR without csrf verifies before replacing the login ($accepted)',
        () async {
          final secrets = _MemorySecretStorage()
            ..values[BilibiliCookieStore.storageKey] =
                '{"SESSDATA":"old","bili_jct":"old-csrf"}';
          final adapter = _FakeAdapter((o) {
            if (o.path.contains('qrcode/poll')) {
              return _json(
                {
                  'code': 0,
                  'data': {'code': 0, 'url': ''},
                },
                setCookie: ['SESSDATA=read-session; Path=/; HttpOnly'],
              );
            }
            expect(o.path, endsWith('/nav'));
            return _json({
              'code': accepted ? 0 : -101,
              'data': {'isLogin': accepted, 'mid': 42, 'uname': 'reader'},
            });
          });
          final api = buildService(adapter, secrets);
          final result = await api.pollQrCode('key');
          expect(result['success'], accepted);
          final restarted = buildService(adapter, secrets);
          final saved = await restarted.readLoginCookies();
          expect(saved['SESSDATA'], accepted ? 'read-session' : 'old');
          expect(saved['bili_jct'], accepted ? isNull : 'old-csrf');
          expect(adapter.requests, hasLength(2));
          expect(adapter.requests.every((r) => r.method == 'GET'), isTrue);
        },
      );
    }

    test('QR success verifies Set-Cookie before saving', () async {
      final secrets = _MemorySecretStorage();
      final adapter = _FakeAdapter((o) {
        if (o.path.contains('qrcode/poll')) {
          return _json(
            {
              'code': 0,
              'data': {'code': 0, 'url': '', 'message': ''},
            },
            setCookie: [
              'SESSDATA=qr%2Cs; Path=/; Domain=bilibili.com; HttpOnly',
              'bili_jct=qrj; Path=/; Domain=bilibili.com',
            ],
          );
        }
        return _json({
          'code': 0,
          'data': {'isLogin': true, 'uname': 'qr'},
        });
      });
      final api = buildService(adapter, secrets);
      await api.init();

      final result = await api.pollQrCode('key');

      expect(result['success'], isTrue);
      expect(
        adapter.requests.last.headers['Cookie'],
        contains('SESSDATA=qr%2Cs'),
      );
      expect(
        secrets.values[BilibiliCookieStore.storageKey],
        contains('qr%2Cs'),
      );
    });

    test('QR success without SESSDATA is not saved', () async {
      final secrets = _MemorySecretStorage();
      final adapter = _FakeAdapter(
        (_) => _json({
          'code': 0,
          'data': {'code': 0, 'url': ''},
        }),
      );
      final api = buildService(adapter, secrets);
      await api.init();

      final result = await api.pollQrCode('key');

      expect(result['success'], isFalse);
      expect(result['code'], -2);
      expect(adapter.requests, hasLength(1));
      expect(secrets.values, isEmpty);
    });
  });

  test('log redaction masks cookie values', () {
    final text = redactSensitiveLogText(
      'Cookie: SESSDATA=abc%2C1; bili_jct=xyz url?DedeUserID=5&x=1 {"SESSDATA":"q"}',
    );
    expect(text, isNot(contains('abc')));
    expect(text, isNot(contains('xyz')));
    expect(text, isNot(contains('"q"')));
    expect(text, contains('SESSDATA=***'));
    expect(text, contains('DedeUserID=***'));
    expect(
      redactSensitiveLogText('bili_ticket=secret-ticket; buvid_fp=secret-fp'),
      'bili_ticket=***; buvid_fp=***',
    );
  });
}
