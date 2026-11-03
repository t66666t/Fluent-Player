import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/cloud_drive/auth/cloud_drive_credential_store.dart';
import 'package:video_player_app/features/cloud_drive/auth/cloud_drive_login_browser.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/presentation/cloud_drive_login_screen.dart';
import 'package:video_player_app/features/cloud_drive/providers/cloud_drive_http.dart';
import 'package:video_player_app/features/cloud_drive/providers/quark_cloud_drive_provider.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_account_repository.dart';

class _Secrets implements CloudDriveSecretStorage {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _LoginBrowser implements CloudDriveLoginClient {
  var signedIn = false;
  var disposed = false;

  @override
  WebViewEnvironment? get environment => null;
  @override
  Future<void> prepare() async {}
  @override
  Future<void> reload() async {}
  @override
  Future<void> dispose() async => disposed = true;
  @override
  Future<List<CloudDriveCookie>> readCookies({
    InAppWebViewController? webView,
  }) async => signedIn
      ? const [
          CloudDriveCookie(
            name: '__uid',
            value: 'user-42',
            domain: '.quark.cn',
          ),
          CloudDriveCookie(
            name: '__puus',
            value: 'session',
            domain: '.quark.cn',
          ),
        ]
      : const [];
  @override
  CloudDriveCredential? credentialFrom(List<CloudDriveCookie> cookies) =>
      CloudDriveLoginBrowser(QuarkCloudDriveProvider()).credentialFrom(cookies);
}

class _Http implements CloudDriveHttp {
  final requests = <CloudDriveHttpRequest>[];

  @override
  Future<CloudDriveHttpResponse> send(
    CloudDriveHttpRequest request, {
    Object? cancelToken,
  }) async {
    requests.add(request);
    return CloudDriveHttpResponse(
      statusCode: 200,
      headers: const {'content-type': 'application/json'},
      finalUri: request.uri,
      body: utf8.encode(
        jsonEncode(
          request.uri.path == '/account/info'
              ? {
                  'success': true,
                  'code': 'OK',
                  'data': {
                    'nickname': '测试账号',
                    'avatarUri': '',
                    'mobilekps': 'not-an-account-id',
                    'config': <String, Object>{},
                  },
                }
              : {
                  'status': 200,
                  'code': 0,
                  'data': {'list': <Object>[]},
                },
        ),
      ),
    );
  }
}

void main() {
  test(
    'page cookies include Quark API session even when Storage is nonempty',
    () async {
      final calls = <String>[];
      final cookies = await readCloudDrivePageCookies(
        cookieUrls: const [
          'https://pan.quark.cn/account/info',
          'https://drive-pc.quark.cn/1/clouddrive/',
        ],
        callDevTools: (method, parameters) async {
          calls.add(method);
          if (method == 'Storage.getCookies') {
            return {
              'cookies': [
                {
                  'name': 'tracker',
                  'value': 'tracking',
                  'domain': '.other.test',
                },
                {'name': '__puus', 'value': 'old', 'domain': '.quark.cn'},
              ],
            };
          }
          expect(
            parameters['urls'],
            contains('https://drive-pc.quark.cn/1/clouddrive/'),
          );
          return {
            'cookies': [
              {'name': '__puus', 'value': 'current', 'domain': 'quark.cn'},
              {
                'name': '__pus',
                'value': 'current-web',
                'domain': 'pan.quark.cn',
              },
            ],
          };
        },
      );
      final credential = CloudDriveLoginBrowser(
        QuarkCloudDriveProvider(),
      ).credentialFrom(cookies)!;
      expect(calls, containsAll(['Storage.getCookies', 'Network.getCookies']));
      expect(credential.cookies, hasLength(2));
      expect(
        credential.headerFor(
          Uri.https('drive-pc.quark.cn', '/1/clouddrive/file/sort'),
        ),
        '__puus=current',
      );
      expect(
        credential.cookies.any((cookie) => cookie.name == 'tracker'),
        isFalse,
      );
    },
  );

  test(
    'one unavailable page cookie API does not discard a valid session',
    () async {
      final cookies = await readCloudDrivePageCookies(
        cookieUrls: const ['https://pan.quark.cn/'],
        callDevTools: (method, _) async {
          if (method == 'Network.getCookies') throw StateError('unsupported');
          return {
            'cookies': [
              {'name': '__puus', 'value': 'session', 'domain': '.quark.cn'},
            ],
          };
        },
      );
      expect(
        CloudDriveLoginBrowser(QuarkCloudDriveProvider())
            .credentialFrom(cookies)!
            .headerFor(Uri.https('drive-pc.quark.cn', '/')),
        '__puus=session',
      );
    },
  );

  test('Network cookies work when Storage is unavailable', () async {
    final cookies = await readCloudDrivePageCookies(
      cookieUrls: const ['https://pan.quark.cn/'],
      callDevTools: (method, _) async {
        if (method == 'Storage.getCookies') throw StateError('unsupported');
        return {
          'cookies': [
            {'name': '__puus', 'value': 'session', 'domain': '.quark.cn'},
          ],
        };
      },
    );
    expect(cookies.single.name, '__puus');
    expect(cookies.single.value, 'session');
  });

  test('Quark cookie filtering rejects other drives and lookalike domains', () {
    final credential = CloudDriveLoginBrowser(QuarkCloudDriveProvider())
        .credentialFrom(const [
          CloudDriveCookie(name: 'BDUSS', value: 'baidu', domain: '.baidu.com'),
          CloudDriveCookie(
            name: '__puus',
            value: 'fake',
            domain: '.notquark.cn',
          ),
          CloudDriveCookie(
            name: '__puus',
            value: 'fake',
            domain: '.quark.cn.evil.test',
          ),
        ]);
    expect(credential, isNull);
  });

  for (final automatic in [false, true]) {
    testWidgets(
      'completed Quark login verifies root, saves and exits (${automatic ? 'poll' : 'button'})',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        final browser = _LoginBrowser();
        final http = _Http();
        final accounts = CloudDriveAccountRepository(
          credentials: CloudDriveCredentialStore(storage: _Secrets()),
          metadata: MemoryCloudDriveAccountMetadataStore(),
        );
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: Builder(
                builder: (context) => TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => CloudDriveLoginScreen(
                        provider: QuarkCloudDriveProvider(http: http),
                        accounts: accounts,
                        browser: browser,
                      ),
                    ),
                  ),
                  child: const Text('添加夸克'),
                ),
              ),
            ),
          );
          await tester.tap(find.text('添加夸克'));
          await tester.pumpAndSettle();
          expect(accounts.accounts, isEmpty);
          expect(http.requests, isEmpty);

          browser.signedIn = true;
          if (automatic) {
            await tester.pump(const Duration(seconds: 3));
          } else {
            await tester.tap(find.text('检测登录状态'));
          }
          await tester.pumpAndSettle();

          expect(find.text('添加夸克'), findsOneWidget);
          expect(find.text('检测登录状态'), findsNothing);
          expect(accounts.accounts.single.remoteAccountId, 'user-42');
          expect(accounts.accounts.single.credentialPersisted, isTrue);
          expect(http.requests, hasLength(2));
          expect(browser.disposed, isTrue);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }
}
