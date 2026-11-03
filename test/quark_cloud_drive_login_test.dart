import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/providers/cloud_drive_http.dart';
import 'package:video_player_app/features/cloud_drive/providers/quark_cloud_drive_provider.dart';

class _QuarkHttp implements CloudDriveHttp {
  _QuarkHttp(this.respond);

  final CloudDriveHttpResponse Function(CloudDriveHttpRequest) respond;
  final requests = <CloudDriveHttpRequest>[];

  @override
  Future<CloudDriveHttpResponse> send(
    CloudDriveHttpRequest request, {
    Object? cancelToken,
  }) async {
    requests.add(request);
    return respond(request);
  }
}

CloudDriveHttpResponse _json(
  CloudDriveHttpRequest request,
  Object body, {
  int status = 200,
}) => CloudDriveHttpResponse(
  statusCode: status,
  headers: const {'content-type': 'application/json'},
  body: utf8.encode(jsonEncode(body)),
  finalUri: request.uri,
);

const _credential = CloudDriveCredential(
  cookies: [
    CloudDriveCookie(
      name: '__pus',
      value: 'web-session',
      domain: 'pan.quark.cn',
    ),
    CloudDriveCookie(
      name: '__puus',
      value: 'drive-session',
      domain: '.quark.cn',
    ),
    CloudDriveCookie(
      name: 'api-only',
      value: 'api-session',
      domain: 'drive-pc.quark.cn',
    ),
  ],
);

const _account = {
  'success': true,
  'code': 'OK',
  'data': {
    'uid': 'quark-user-42',
    'nickname': '测试账号',
    'avatarUri': 'https://pan.quark.cn/avatar/test.png',
  },
};

const _root = {
  'status': 200,
  'code': 0,
  'data': {'list': <Object>[]},
  'metadata': {'_total': 0},
};

// The real official web response does not contain uid/user_id/ucid.
const _webAccount = {
  'success': true,
  'code': 'OK',
  'data': {
    'nickname': '网页账号',
    'avatarUri': 'https://pan.quark.cn/avatar/web.png',
    'mobilekps': 'not-an-account-id',
    'config': <String, Object>{},
  },
};

CloudDriveCredential _webCredential({String session = 'session'}) =>
    CloudDriveCredential(
      cookies: [
        CloudDriveCookie(
          name: '__uid',
          value: 'stable-user',
          domain: '.quark.cn',
        ),
        CloudDriveCookie(name: '__puus', value: session, domain: '.quark.cn'),
      ],
    );

Matcher _failure(CloudDriveFailureKind kind) =>
    isA<CloudDriveFailure>().having((error) => error.kind, 'kind', kind);

void main() {
  test('official web profile uses __uid after verifying the drive', () async {
    final http = _QuarkHttp(
      (request) => _json(
        request,
        request.uri.path == '/account/info' ? _webAccount : _root,
      ),
    );
    final provider = QuarkCloudDriveProvider(http: http);
    final first = await provider.verifySession(_webCredential());
    final refreshed = await provider.verifySession(
      _webCredential(session: 'new-session'),
    );
    expect(first.remoteAccountId, 'stable-user');
    expect(first.displayName, '网页账号');
    expect(first.avatar, 'https://pan.quark.cn/avatar/web.png');
    expect(refreshed.remoteAccountId, first.remoteAccountId);
    expect(
      http.requests.where((request) => request.uri.path.endsWith('/file/sort')),
      hasLength(2),
    );
  });

  test('a uid cookie cannot turn a guest web response into a login', () async {
    final http = _QuarkHttp(
      (request) => _json(request, {
        'success': true,
        'code': 'OK',
        'data': <String, Object>{},
      }),
    );
    await expectLater(
      QuarkCloudDriveProvider(http: http).verifySession(_webCredential()),
      throwsA(_failure(CloudDriveFailureKind.notLoggedIn)),
    );
    expect(http.requests, hasLength(1));
  });

  test('cookie identity still requires real drive access', () async {
    final http = _QuarkHttp((request) {
      if (request.uri.path == '/account/info') {
        return _json(request, _webAccount);
      }
      return _json(request, {'status': 401, 'code': 31001}, status: 401);
    });
    await expectLater(
      QuarkCloudDriveProvider(http: http).verifySession(_webCredential()),
      throwsA(_failure(CloudDriveFailureKind.notLoggedIn)),
    );
    expect(http.requests, hasLength(2));
  });

  for (final cookie in const [
    CloudDriveCookie(
      name: '__uid',
      value: 'wrong-user',
      domain: '.quark.cn.evil.test',
    ),
    CloudDriveCookie(
      name: '__uid',
      value: 'wrong-user',
      domain: 'drive-pc.quark.cn',
    ),
    CloudDriveCookie(
      name: '__uid',
      value: 'wrong-user',
      domain: '.quark.cn',
      path: '/other',
    ),
    CloudDriveCookie(name: '__uid', value: 'wrong;user', domain: '.quark.cn'),
  ]) {
    test(
      'identity cookie must apply to the account request (${cookie.domain}, ${cookie.path}, ${cookie.value})',
      () async {
        final http = _QuarkHttp((request) => _json(request, _webAccount));
        await expectLater(
          QuarkCloudDriveProvider(
            http: http,
          ).verifySession(CloudDriveCredential(cookies: [cookie])),
          throwsA(_failure(CloudDriveFailureKind.notLoggedIn)),
        );
        expect(http.requests, hasLength(1));
      },
    );
  }

  test(
    'official account identity verifies login without a member uid',
    () async {
      final http = _QuarkHttp((request) {
        if (request.uri.path == '/account/info') {
          return _json(request, _account);
        }
        if (request.uri.path.endsWith('/file/sort')) {
          return _json(request, _root);
        }
        // /member describes entitlements, not the identity of a web login.
        return _json(request, {
          'status': 200,
          'code': 0,
          'data': {'member_type': 'NORMAL', 'total_capacity': 1024},
        });
      });

      final session = await QuarkCloudDriveProvider(
        http: http,
      ).verifySession(_credential);

      expect(session.remoteAccountId, 'quark-user-42');
      expect(session.displayName, '测试账号');
      expect(session.avatar, 'https://pan.quark.cn/avatar/test.png');
      expect(http.requests, hasLength(2));
      final identity = http.requests.first;
      expect(identity.uri.host, 'pan.quark.cn');
      expect(identity.uri.path, '/account/info');
      expect(identity.uri.queryParameters, containsPair('fr', 'pc'));
      expect(identity.uri.queryParameters, containsPair('platform', 'pc'));
      expect(identity.headers['Cookie'], contains('__pus=web-session'));
      expect(identity.headers['Cookie'], isNot(contains('api-only')));
      final root = http.requests.last;
      expect(root.uri.host, 'drive-pc.quark.cn');
      expect(root.uri.path, '/1/clouddrive/file/sort');
      expect(root.headers['Cookie'], contains('__puus=drive-session'));
      expect(root.headers['Cookie'], contains('api-only=api-session'));
      expect(root.headers['Cookie'], isNot(contains('__pus=web-session')));
    },
  );

  test('guest account response is not a verified login', () async {
    final http = _QuarkHttp(
      (request) => _json(request, {
        'success': true,
        'code': 'OK',
        'data': <String, Object>{},
      }),
    );
    await expectLater(
      QuarkCloudDriveProvider(http: http).verifySession(_credential),
      throwsA(_failure(CloudDriveFailureKind.notLoggedIn)),
    );
    expect(http.requests, hasLength(1));
  });

  test(
    'account identity alone cannot bypass a rejected drive session',
    () async {
      final http = _QuarkHttp((request) {
        if (request.uri.path == '/account/info') {
          return _json(request, _account);
        }
        return _json(request, {
          'status': 401,
          'code': 31001,
          'message': 'require login [guest]',
        }, status: 401);
      });
      await expectLater(
        QuarkCloudDriveProvider(http: http).verifySession(_credential),
        throwsA(_failure(CloudDriveFailureKind.notLoggedIn)),
      );
      expect(http.requests, hasLength(2));
    },
  );

  test('failed account response is not accepted despite a uid', () async {
    final http = _QuarkHttp(
      (request) => _json(request, {
        'success': false,
        'code': 'SERVICE_UNAVAILABLE',
        'data': {'uid': 'must-not-be-saved'},
      }),
    );
    await expectLater(
      QuarkCloudDriveProvider(http: http).verifySession(_credential),
      throwsA(_failure(CloudDriveFailureKind.unavailable)),
    );
    expect(http.requests, hasLength(1));
  });

  test('HTTP unauthorized remains a login error without JSON', () async {
    final http = _QuarkHttp(
      (request) => CloudDriveHttpResponse(
        statusCode: 401,
        headers: const {'content-type': 'text/html'},
        body: utf8.encode('<html>Unauthorized</html>'),
        finalUri: request.uri,
      ),
    );
    await expectLater(
      QuarkCloudDriveProvider(http: http).verifySession(_credential),
      throwsA(_failure(CloudDriveFailureKind.notLoggedIn)),
    );
  });
}
