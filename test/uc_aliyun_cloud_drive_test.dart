import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/cloud_drive/auth/aliyun_device_session.dart';
import 'package:video_player_app/features/cloud_drive/auth/aliyun_web_session.dart';
import 'package:video_player_app/features/cloud_drive/auth/cloud_drive_credential_store.dart';
import 'package:video_player_app/features/cloud_drive/auth/cloud_drive_login_browser.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_view_options.dart';
import 'package:video_player_app/features/cloud_drive/providers/aliyun_cloud_drive_provider.dart';
import 'package:video_player_app/features/cloud_drive/providers/cloud_drive_http.dart';
import 'package:video_player_app/features/cloud_drive/providers/cloud_drive_provider.dart';
import 'package:video_player_app/features/cloud_drive/providers/quark_cloud_drive_provider.dart';
import 'package:video_player_app/features/cloud_drive/providers/uc_cloud_drive_provider.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_account_repository.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_browser_controller.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_materialization.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_playback_service.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_thumbnails.dart';
import 'package:video_player_app/features/media_cache/media_cache_models.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_materialization_service.dart';

class _Http implements CloudDriveHttp {
  _Http(this.answer);
  final FutureOr<CloudDriveHttpResponse> Function(CloudDriveHttpRequest) answer;
  final requests = <CloudDriveHttpRequest>[];
  @override
  Future<CloudDriveHttpResponse> send(
    CloudDriveHttpRequest request, {
    Object? cancelToken,
  }) async {
    requests.add(request);
    return answer(request);
  }
}

class _Secrets implements CloudDriveSecretStorage {
  final data = <String, String>{};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async {
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    data.remove(key);
  }
}

CloudDriveHttpResponse _json(
  CloudDriveHttpRequest r,
  Object value, {
  int status = 200,
  List<CloudDriveCookie> cookies = const [],
}) => CloudDriveHttpResponse(
  statusCode: status,
  headers: const {'content-type': 'application/json'},
  body: utf8.encode(jsonEncode(value)),
  finalUri: r.uri,
  cookies: cookies,
);
Map<String, dynamic> _body(CloudDriveHttpRequest r) =>
    Map<String, dynamic>.from(jsonDecode(utf8.decode(r.body!)) as Map);

const _aliCredential = CloudDriveCredential(
  cookies: [],
  secrets: {
    'access_token': 'access-1',
    'refresh_token': 'refresh-1',
    'expire_time': '2099-01-01T00:00:00Z',
    'user_id': 'ali-user',
    'device_id': 'test-device',
    'private_key': '1',
  },
);
const _ucCredential = CloudDriveCredential(
  cookies: [
    CloudDriveCookie(name: '__uid', value: 'uc-user', domain: '.uc.cn'),
    CloudDriveCookie(name: '__puus', value: 'uc-secret', domain: '.uc.cn'),
  ],
);
const _user = {
  'user_id': 'ali-user',
  'nick_name': '阿里测试',
  'default_drive_id': 'backup',
  'resource_drive_id': 'resource',
  'backup_drive_id': 'backup',
};
const _video = {
  'file_id': 'video',
  'parent_file_id': 'folder',
  'name': 'lesson.mp4',
  'type': 'file',
  'category': 'video',
  'size': 8,
  'content_hash': 'revision',
  'video_media_metadata': {'duration': '60'},
};
CloudDrivePlaybackRequest _play(
  CloudDriveCredential credential, {
  String? quality,
  int duration = 60000,
}) => CloudDrivePlaybackRequest(
  credential: credential,
  accountLocalId: 'local',
  remoteAccountId: credential.secrets.isEmpty ? 'uc-user' : 'ali-user',
  driveId: credential.secrets.isEmpty ? '0' : 'resource',
  fileId: 'video',
  name: 'lesson.mp4',
  revision: 'revision',
  durationMs: duration,
  preferredQualityId: quality,
);
CloudDriveListRequest _list(
  CloudDriveCredential credential, {
  String parent = '@aliyun',
  String? cursor,
}) => CloudDriveListRequest(
  credential: credential,
  accountLocalId: 'local',
  remoteAccountId: credential.secrets.isEmpty ? 'uc-user' : 'ali-user',
  driveId: 'resource',
  parentFileId: parent,
  cursor: cursor,
);
CloudDriveHttpResponse _aliDefault(CloudDriveHttpRequest r) {
  if (r.uri.path == '/v2/user/get') return _json(r, _user);
  if (r.uri.path == '/adrive/v3/file/list') {
    return _json(r, {
      'items': [_video],
      'next_marker': '',
    });
  }
  if (r.uri.path == '/v2/file/get') return _json(r, _video);
  if (r.uri.path == '/v2/file/get_download_url') {
    return _json(r, {
      'url': 'https://cdn.example.test/video.mp4',
      'expiration': '2099-01-01T00:00:00Z',
    });
  }
  if (r.uri.host == 'cdn.example.test') {
    return CloudDriveHttpResponse(
      statusCode: 206,
      headers: const {
        'content-type': 'video/mp4',
        'content-range': 'bytes 0-1/8',
        'accept-ranges': 'bytes',
      },
      body: const [0, 1],
      finalUri: r.uri,
    );
  }
  throw StateError('Unexpected test route: ${r.uri.path}');
}

Matcher _failure(CloudDriveFailureKind kind) =>
    isA<CloudDriveFailure>().having((e) => e.kind, 'kind', kind);

void main() {
  test(
    'Aliyun captures official browser tokens without accepting another origin',
    () {
      final browserToken = jsonEncode({
        'access_token': 'access',
        'refresh_token': 'refresh',
        'user_id': 'ali-user',
        'unrelated': 'ignore',
      });
      final raw = jsonEncode({
        'origin': 'https://www.alipan.com',
        'token': browserToken,
      });
      final credential = aliyunCredentialFromBrowser(jsonEncode(raw))!;
      expect(credential.secrets['refresh_token'], 'refresh');
      expect(credential.secrets, isNot(contains('unrelated')));
      expect(credential.headerFor(Uri.parse('https://evil.test/')), isEmpty);
      for (final origin in [
        'https://www.alipan.com.evil.test',
        'http://www.alipan.com',
        'https://www.alipan.com:444',
      ]) {
        expect(
          aliyunCredentialFromBrowser({
            'origin': origin,
            'token': browserToken,
          }),
          isNull,
        );
      }
      final restored = CloudDriveCredential.tryParse(
        jsonEncode(credential.toJson()),
      )!;
      expect(restored.secrets, credential.secrets);
      expect(
        cloudDriveCredentialStamp(restored),
        isNot(
          cloudDriveCredentialStamp(
            const CloudDriveCredential(
              cookies: [],
              secrets: {'refresh_token': 'another'},
            ),
          ),
        ),
      );
    },
  );

  test('UC login jar keeps only its own domains', () {
    final jar = CloudDriveLoginBrowser(UcCloudDriveProvider()).credentialFrom([
      ..._ucCredential.cookies,
      const CloudDriveCookie(
        name: '__puus',
        value: 'quark-secret',
        domain: '.quark.cn',
      ),
    ])!;
    expect(jar.cookies.length, 2);
    expect(
      jar.headerFor(Uri.parse('https://pc-api.uc.cn/1/clouddrive/file/sort')),
      contains('uc-secret'),
    );
    expect(jar.headerFor(Uri.parse('https://drive-pc.quark.cn/')), isEmpty);
  });

  test('device signing uses a random or restored secp256k1 device key', () {
    final device = AliyunDeviceSession(privateKey: '1', deviceId: 'test');
    expect(
      device.publicKey,
      '0479be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798'
      '483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8',
    );
    final digest = sha256.convert(utf8.encode('sample')).bytes;
    final signature = device.signDigest(digest);
    // Independently checked against OpenSSL's secp256k1 verifier.
    expect(
      signature,
      '58db657bcd631038bea07b4941172f0167aca98f12b55e3176bd1c35435d65013a'
      '78e73d8ff8ab554e13c10f6390d81a882f91945d6275493882676170b53a5701',
    );
    expect(signature.length, 130);
    expect(device.signDigest(digest), signature);
    expect(device.signature('a'), isNot(device.signature('b')));
    expect(
      AliyunDeviceSession().privateKey,
      isNot(AliyunDeviceSession().privateKey),
    );
  });

  test(
    'Aliyun login verifies root and exposes resource and backup drives independently',
    () async {
      final http = _Http((r) => _aliDefault(r));
      final provider = AliyunCloudDriveProvider(http: http);
      final verified = await provider.verifySession(_aliCredential);
      expect(verified.driveId, 'resource');
      expect(verified.displayName, '阿里测试');
      final root = await provider.listChildren(_list(_aliCredential));
      expect(root.entries.map((e) => e.name), ['资源库', '备份盘']);
      final backups = await provider.listChildren(
        _list(_aliCredential, parent: root.entries.last.fileId),
      );
      expect(backups.entries.single.driveId, 'backup');
      expect(backups.entries.single.parentFileId, '@aliyun:backup:folder');
      expect(
        _body(
          http.requests.where((r) => r.uri.path == '/adrive/v3/file/list').last,
        )['drive_id'],
        'backup',
      );
    },
  );

  test(
    'Aliyun list marker, folders, metadata and audio classification are preserved',
    () async {
      final http = _Http((r) {
        if (r.uri.path == '/adrive/v3/file/list') {
          return _json(r, {
            'items': [
              {'file_id': 'dir', 'name': '文件夹', 'type': 'folder'},
              {..._video, 'file_id': 'audio', 'name': 'lesson.flac'},
            ],
            'next_marker': 'next-page',
          });
        }
        return _aliDefault(r);
      });
      final p = AliyunCloudDriveProvider(http: http);
      final page = await p.listChildren(
        _list(
          _aliCredential,
          parent: '@aliyun:backup:root',
          cursor: 'previous',
        ),
      );
      expect(page.hasMore, isTrue);
      expect(page.nextCursor, 'next-page');
      expect(page.entries.first.fileId, '@aliyun:backup:dir');
      expect(page.entries.last.kind, CloudDriveEntryKind.audio);
      final body = _body(http.requests.last);
      expect(body['parent_file_id'], 'root');
      expect(body['marker'], 'previous');
    },
  );

  test(
    'rotated Aliyun refresh tokens survive a repository restart without plaintext metadata',
    () async {
      final secrets = _Secrets();
      final metadata = MemoryCloudDriveAccountMetadataStore();
      final accounts = CloudDriveAccountRepository(
        credentials: CloudDriveCredentialStore(storage: secrets),
        metadata: metadata,
      );
      const expired = CloudDriveCredential(
        cookies: [],
        secrets: {
          'refresh_token': 'refresh-1',
          'user_id': 'ali-user',
          'expire_time': '2000-01-01T00:00:00Z',
          'private_key': '1',
          'device_id': 'test-device',
        },
      );
      final account = await accounts.commitVerified(
        providerId: 'aliyun',
        remoteAccountId: 'ali-user',
        displayName: '账号',
        credential: expired,
        driveId: 'resource',
      );
      var refreshes = 0;
      final http = _Http((r) {
        if (r.uri.path == '/v2/account/token') {
          refreshes++;
          expect(r.headers, isNot(contains('Authorization')));
          expect(_body(r)['refresh_token'], 'refresh-1');
          return _json(r, {
            'access_token': 'access-2',
            'refresh_token': 'refresh-2',
            'expires_in': 7200,
            'user_id': 'ali-user',
          });
        }
        return _aliDefault(r);
      });
      final p = AliyunCloudDriveProvider(http: http)
        ..onCredentialRefreshed = accounts.refreshCredential;
      await Future.wait([p.verifySession(expired), p.verifySession(expired)]);
      expect(refreshes, 1);
      final restarted = CloudDriveAccountRepository(
        credentials: CloudDriveCredentialStore(storage: secrets),
        metadata: metadata,
      );
      await restarted.load();
      final stored = await restarted.credentialFor(restarted.accounts.single);
      expect(stored!.secrets['refresh_token'], 'refresh-2');
      expect(restarted.accounts.single.driveId, 'resource');
      expect(metadata.value, isNot(contains('refresh-')));
      expect(metadata.value, isNot(contains('private_key')));
      await accounts.signOut(account.localId);
      await accounts.refreshCredential(stored, expired);
      expect(await accounts.credentialFor(accounts.accounts.single), isNull);
    },
  );

  test('a late token refresh cannot overwrite a new login', () async {
    final store = _Secrets();
    final accounts = CloudDriveAccountRepository(
      credentials: CloudDriveCredentialStore(storage: store),
      metadata: MemoryCloudDriveAccountMetadataStore(),
    );
    final account = await accounts.commitVerified(
      providerId: 'aliyun',
      remoteAccountId: 'ali-user',
      displayName: '账号',
      credential: _aliCredential,
    );
    const fresh = CloudDriveCredential(
      cookies: [],
      secrets: {'refresh_token': 'fresh-login'},
    );
    await accounts.commitVerified(
      providerId: 'aliyun',
      remoteAccountId: 'ali-user',
      displayName: '账号',
      credential: fresh,
    );
    await accounts.refreshCredential(
      _aliCredential,
      const CloudDriveCredential(
        cookies: [],
        secrets: {'refresh_token': 'late-refresh'},
      ),
    );
    expect(
      (await accounts.credentialFor(account))!.secrets['refresh_token'],
      'fresh-login',
    );
  });

  test(
    'Aliyun invalid device session is repaired once and API credentials never reach a CDN',
    () async {
      var repaired = false;
      final http = _Http((r) {
        if (r.uri.path == '/v2/file/get_download_url' && !repaired) {
          return _json(r, {
            'code': 'DeviceSessionSignatureInvalid',
          }, status: 400);
        }
        if (r.uri.path == '/users/v1/users/device/create_session') {
          expect(_body(r)['pubKey'], startsWith('04'));
          repaired = true;
          return _json(r, {'success': true});
        }
        return _aliDefault(r);
      });
      final result = await AliyunCloudDriveProvider(
        http: http,
      ).resolvePlayback(_play(_aliCredential));
      expect(result.quality.id, 'original');
      expect(result.sizeBytes, 8);
      expect(result.cookies, isEmpty);
      expect(repaired, isTrue);
      for (final r in http.requests.where(
        (r) => r.uri.host == 'api.alipan.com',
      )) {
        final redirected = r.headersFor!(Uri.parse('https://evil.test/file'));
        expect(redirected, isNot(contains('Authorization')));
        expect(redirected, isNot(contains('X-Signature')));
      }
      expect(http.requests.last.headers, isNot(contains('Authorization')));
    },
  );

  test(
    'Aliyun access token expiry is refreshed once during an existing session',
    () async {
      var denied = false;
      var refreshes = 0;
      final http = _Http((r) {
        if (r.uri.path == '/v2/file/get_download_url' && !denied) {
          denied = true;
          return _json(r, {'code': 'AccessTokenInvalid'}, status: 401);
        }
        if (r.uri.path == '/v2/account/token') {
          refreshes++;
          return _json(r, {
            'access_token': 'new',
            'refresh_token': 'next',
            'expires_in': 7200,
          });
        }
        return _aliDefault(r);
      });
      await AliyunCloudDriveProvider(
        http: http,
      ).resolvePlayback(_play(_aliCredential));
      expect(refreshes, 1);
    },
  );

  for (final deviceStatus in [400, 401]) {
    test(
      'Aliyun plays after a day when listing works but device recovery needs a fresh token ($deviceStatus)',
      () async {
        var now = DateTime.utc(2026, 10, 23);
        final credential = CloudDriveCredential(
          cookies: [],
          secrets: {
            ..._aliCredential.secrets,
            'expire_time': now.add(const Duration(hours: 2)).toIso8601String(),
          },
        );
        final secrets = _Secrets();
        final metadata = MemoryCloudDriveAccountMetadataStore();
        final accounts = CloudDriveAccountRepository(
          credentials: CloudDriveCredentialStore(storage: secrets),
          metadata: metadata,
        );
        final account = await accounts.commitVerified(
          providerId: 'aliyun',
          remoteAccountId: 'ali-user',
          displayName: '账号',
          credential: credential,
          driveId: 'resource',
        );
        var refreshes = 0;
        var deviceCreates = 0;
        var deviceReady = false;
        final http = _Http((r) {
          if (r.uri.path == '/v2/account/token') {
            refreshes++;
            return _json(r, {
              'access_token': 'access-new-$refreshes',
              'refresh_token': 'refresh-new-$refreshes',
              'user_id': 'ali-user',
              'expires_in': 7200,
            });
          }
          if (r.uri.path == '/v2/file/get_download_url' && !deviceReady) {
            return _json(r, {
              'code': 'DeviceSessionExpired',
            }, status: deviceStatus);
          }
          if (r.uri.path == '/users/v1/users/device/create_session') {
            deviceCreates++;
            if (deviceCreates == 1) {
              return _json(r, {'code': 'AccessTokenInvalid'}, status: 401);
            }
            expect(_body(r)['refreshToken'], 'refresh-new-2');
            expect(r.headers['Authorization'], 'Bearer access-new-2');
            deviceReady = true;
            return _json(r, {'success': true});
          }
          return _aliDefault(r);
        });
        final provider = AliyunCloudDriveProvider(http: http, clock: () => now)
          ..onCredentialRefreshed = accounts.refreshCredential;
        await provider.verifySession(credential);
        now = now.add(const Duration(days: 1));
        final page = await provider.listChildren(
          _list(credential, parent: 'root'),
        );
        expect(page.entries.single.fileId, 'video');
        expect(refreshes, 1);
        expect(deviceCreates, 0);
        final current = (await accounts.credentialFor(account))!;
        final descriptors = await Future.wait([
          provider.resolvePlayback(_play(current)),
          provider.resolvePlayback(_play(current)),
        ]);
        expect(descriptors.every((d) => d.quality.id == 'original'), isTrue);
        expect(deviceCreates, 2);
        expect(refreshes, 2);
        final restarted = CloudDriveAccountRepository(
          credentials: CloudDriveCredentialStore(storage: secrets),
          metadata: metadata,
        );
        await restarted.load();
        final stored = (await restarted.credentialFor(
          restarted.accounts.single,
        ))!;
        expect(stored.secrets['refresh_token'], 'refresh-new-2');
        expect(
          BigInt.parse(stored.secrets['private_key']!, radix: 16),
          BigInt.one,
        );
        expect(stored.secrets['device_id'], 'test-device');
        final afterRestart = await AliyunCloudDriveProvider(
          http: http,
          clock: () => now,
        ).resolvePlayback(_play(stored));
        expect(afterRestart.quality.id, 'original');
        expect(refreshes, 2);
      },
    );
  }

  test(
    'a late Aliyun 401 reuses the token refreshed by concurrent playback',
    () async {
      final lateUnauthorized = Completer<CloudDriveHttpResponse>();
      CloudDriveHttpRequest? delayedRequest;
      var staleDownloads = 0;
      var refreshes = 0;
      final http = _Http((r) {
        if (r.uri.path == '/v2/file/get_download_url' &&
            r.headers['Authorization'] == 'Bearer access-1') {
          staleDownloads++;
          if (staleDownloads == 1) {
            return _json(r, {'code': 'AccessTokenInvalid'}, status: 401);
          }
          delayedRequest = r;
          return lateUnauthorized.future;
        }
        if (r.uri.path == '/v2/account/token') {
          refreshes++;
          return _json(r, {
            'access_token': 'current-access',
            'refresh_token': 'current-refresh',
            'expires_in': 7200,
          });
        }
        return _aliDefault(r);
      });
      final provider = AliyunCloudDriveProvider(http: http);
      await provider.verifySession(_aliCredential);
      final first = provider.resolvePlayback(_play(_aliCredential));
      final second = provider.resolvePlayback(_play(_aliCredential));
      await first;
      expect(delayedRequest, isNotNull);
      lateUnauthorized.complete(
        _json(delayedRequest!, {'code': 'AccessTokenInvalid'}, status: 401),
      );
      await second;
      expect(refreshes, 1);
    },
  );

  for (final code in ['Forbidden', 'AccessTokenInvalid private_key=secret']) {
    test(
      'Aliyun playback failures retain safe API diagnostics: $code',
      () async {
        final http = _Http((r) {
          if (r.uri.path == '/v2/file/get_download_url' ||
              r.uri.path == '/v2/account/token') {
            return _json(r, {'code': code}, status: 403);
          }
          return _aliDefault(r);
        });
        final provider = AliyunCloudDriveProvider(http: http);
        final accounts = CloudDriveAccountRepository(
          credentials: CloudDriveCredentialStore(storage: _Secrets()),
          metadata: MemoryCloudDriveAccountMetadataStore(),
        );
        await accounts.commitVerified(
          providerId: 'aliyun',
          remoteAccountId: 'ali-user',
          displayName: '账号',
          credential: _aliCredential,
        );
        final entry = (await provider.listChildren(
          _list(_aliCredential, parent: 'root'),
        )).entries.single;
        final ref = cloudDriveEntrySource(entry);
        final item = VideoItem(
          id: ref.cloudDrive!.itemId,
          path: ref.cloudDrive!.logicalUri,
          title: entry.name,
          durationMs: 60000,
          lastUpdated: 0,
          sourceRef: ref,
        );
        final playback = CloudDrivePlaybackService(
          providers: CloudDriveProviderRegistry([provider]),
          accounts: accounts,
        );
        addTearDown(playback.close);
        await expectLater(
          playback.open(item, qualityId: 'original'),
          throwsA(isA<CloudDriveFailure>()),
        );
        expect(playback.diagnosticText, contains('resolve failed'));
        expect(
          playback.diagnosticText,
          contains('api=/v2/file/get_download_url http=403'),
        );
        expect(
          playback.diagnosticText,
          contains('code=${code == 'Forbidden' ? 'Forbidden' : 'unknown'}'),
        );
        expect(playback.diagnosticText, isNot(contains('secret')));
        expect(playback.diagnosticText, isNot(contains('refresh-1')));
        expect(playback.diagnosticText, isNot(contains(entry.name)));
      },
    );
  }

  test(
    'Aliyun refuses wrong account, expired login and rate limiting',
    () async {
      final p = AliyunCloudDriveProvider(http: _Http(_aliDefault));
      await expectLater(
        p.listChildren(
          CloudDriveListRequest(
            credential: _aliCredential,
            accountLocalId: 'local',
            remoteAccountId: 'different-user',
            driveId: 'resource',
            parentFileId: 'root',
          ),
        ),
        throwsA(_failure(CloudDriveFailureKind.notLoggedIn)),
      );
      for (final entry in [
        (401, 'RefreshTokenExpired', CloudDriveFailureKind.notLoggedIn),
        (429, 'TooManyRequests', CloudDriveFailureKind.rateLimited),
      ]) {
        final provider = AliyunCloudDriveProvider(
          http: _Http((r) => _json(r, {'code': entry.$2}, status: entry.$1)),
        );
        await expectLater(
          provider.verifySession(
            const CloudDriveCredential(
              cookies: [],
              secrets: {'refresh_token': 'expired'},
            ),
          ),
          throwsA(_failure(entry.$3)),
        );
      }
    },
  );

  for (final previewDuration in [10, 60]) {
    test(
      'Aliyun HLS checks complete playback against duration: $previewDuration',
      () async {
        final http = _Http((r) {
          if (r.uri.path == '/v2/file/get_video_preview_play_info') {
            return _json(r, {
              'video_preview_play_info': {
                'live_transcoding_task_list': [
                  {
                    'template_id': 'FHD',
                    'status': 'finished',
                    'url': 'https://cdn.example.test/master.m3u8',
                  },
                  {'template_id': 'UHD', 'status': 'running'},
                ],
              },
            });
          }
          if (r.uri.path.endsWith('.m3u8')) {
            return CloudDriveHttpResponse(
              statusCode: 200,
              headers: const {'content-type': 'application/vnd.apple.mpegurl'},
              body: utf8.encode(
                '#EXTM3U\n#EXTINF:$previewDuration,\nsegment.ts\n#EXT-X-ENDLIST\n',
              ),
              finalUri: r.uri,
            );
          }
          return _aliDefault(r);
        });
        final p = AliyunCloudDriveProvider(http: http);
        if (previewDuration == 10) {
          await expectLater(
            p.resolvePlayback(_play(_aliCredential, quality: 'FHD')),
            throwsA(_failure(CloudDriveFailureKind.previewOnly)),
          );
        } else {
          final d = await p.resolvePlayback(
            _play(_aliCredential, quality: 'FHD'),
          );
          expect(d.transport, CloudDriveTransport.hls);
          expect(d.verifiedComplete, isTrue);
          expect(d.manifest, isNotNull);
          expect(
            d.qualities.firstWhere((q) => q.id == 'UHD').selectable,
            isFalse,
          );
        }
      },
    );
  }

  for (final referer in [
    'https://www.aliyundrive.com/',
    'https://www.alipan.com/',
  ]) {
    test(
      'Aliyun signed manifests and subtitles preserve the accepted origin: $referer',
      () async {
        final manifest = Uri.https(
          'cn-beijing-video-preview.aliyundrive.net',
          '/fixture/master.m3u8',
          {
            'x-oss-additional-headers': 'referer',
            'x-oss-expires': '4102444800',
          },
        );
        final subtitle = manifest.replace(path: '/fixture/sub.srt');
        final http = _Http((r) {
          if (r.uri.path == '/v2/file/get_video_preview_play_info') {
            return _json(r, {
              'video_preview_play_info': {
                'live_transcoding_task_list': [
                  {
                    'template_id': 'HD',
                    'status': 'finished',
                    'url': '$manifest',
                  },
                ],
              },
            });
          }
          if (r.uri.host == manifest.host) {
            expect(r.headers, isNot(contains('Authorization')));
            expect(r.headers, isNot(contains('Cookie')));
            final accepted = r.headers['Referer'] == referer;
            return CloudDriveHttpResponse(
              statusCode: accepted ? 200 : 403,
              headers: {
                'content-type': accepted ? 'text/plain' : 'application/xml',
              },
              body: utf8.encode(
                !accepted
                    ? '<Error><Code>SignatureDoesNotMatch</Code></Error>'
                    : r.uri.path.endsWith('.srt')
                    ? '1\n00:00:00,000 --> 00:00:02,000\nHello\n'
                    : '#EXTM3U\n#EXTINF:60,\nsegment.ts\n#EXT-X-ENDLIST\n',
              ),
              finalUri: r.uri,
            );
          }
          return _aliDefault(r);
        });
        final provider = AliyunCloudDriveProvider(http: http);
        final descriptor = await provider.resolvePlayback(
          _play(_aliCredential, quality: 'HD'),
        );
        expect(descriptor.referer, referer);
        expect(descriptor.expiresAt, DateTime.utc(2100));
        expect(descriptor.verifiedComplete, isTrue);
        final text = await provider.readSubtitleText(
          CloudDriveSubtitleReadRequest(
            credential: _aliCredential,
            accountLocalId: 'local',
            remoteAccountId: 'ali-user',
            driveId: 'resource',
            track: CloudDriveSubtitleTrack(
              id: 'signed-subtitle',
              label: '字幕',
              format: 'srt',
              origin: CloudDriveSubtitleOrigin.provider,
              remoteUri: subtitle,
            ),
          ),
        );
        expect(text, contains('Hello'));
        final media = http.requests
            .where((r) => r.uri.host == manifest.host)
            .toList();
        expect(media, hasLength(referer.contains('aliyundrive') ? 2 : 4));
        expect(media.first.headers['Referer'], 'https://www.aliyundrive.com/');
        expect(media.last.headers['Referer'], referer);
        expect(provider.thumbnailReferer, 'https://www.alipan.com/');
      },
    );
  }

  test(
    'Aliyun signature errors are bounded and distinguished from account entitlement',
    () async {
      var probes = 0;
      final http = _Http((r) {
        if (r.uri.path == '/v2/file/get_video_preview_play_info') {
          return _json(r, {
            'video_preview_play_info': {
              'live_transcoding_task_list': [
                {
                  'template_id': 'HD',
                  'status': 'finished',
                  'url':
                      'https://cn-beijing-video-preview.aliyundrive.net/fixture.m3u8?x-oss-additional-headers=referer',
                },
              ],
            },
          });
        }
        if (r.uri.path.endsWith('.m3u8')) {
          probes++;
          return CloudDriveHttpResponse(
            statusCode: 403,
            headers: const {'content-type': 'application/xml'},
            body: utf8.encode(
              '<Error><Code>SignatureDoesNotMatch</Code></Error>',
            ),
            finalUri: r.uri,
          );
        }
        return _aliDefault(r);
      });
      await expectLater(
        AliyunCloudDriveProvider(
          http: http,
        ).resolvePlayback(_play(_aliCredential, quality: 'HD')),
        throwsA(
          isA<CloudDriveFailure>()
              .having((e) => e.kind, 'kind', CloudDriveFailureKind.unavailable)
              .having(
                (e) => e.diagnostic,
                'diagnostic',
                'media=manifest http=403 code=SignatureDoesNotMatch',
              ),
        ),
      );
      expect(probes, 2);
    },
  );

  test(
    'Aliyun sidecar subtitle and provider subtitle text use the same account',
    () async {
      const subtitle = '1\n00:00:00,000 --> 00:00:01,000\nHello\n';
      final http = _Http((r) {
        if (r.uri.path == '/v2/file/get_video_preview_play_info') {
          return _json(r, {
            'video_preview_play_info': {
              'live_transcoding_subtitle_task_list': [
                {
                  'task_id': 'en-sub',
                  'status': 'finished',
                  'language': 'eng',
                  'url': 'https://cdn.example.test/sub.srt',
                },
              ],
            },
          });
        }
        if (r.uri.path == '/adrive/v3/file/list') {
          return _json(r, {
            'items': [
              {'file_id': 'sub', 'name': 'lesson.en.srt', 'type': 'file'},
              {'file_id': 'other', 'name': 'other.srt', 'type': 'file'},
            ],
            'next_marker': '',
          });
        }
        if (r.uri.path == '/v2/file/get_download_url') {
          return _json(r, {'url': 'https://cdn.example.test/sub.srt'});
        }
        if (r.uri.path.endsWith('.srt')) {
          return CloudDriveHttpResponse(
            statusCode: 200,
            headers: const {'content-type': 'text/plain'},
            body: utf8.encode(subtitle),
            finalUri: r.uri,
          );
        }
        return _aliDefault(r);
      });
      final p = AliyunCloudDriveProvider(http: http);
      final catalog = await p.discoverSubtitleCatalog(_play(_aliCredential));
      expect(catalog.tracks.length, 2);
      expect(catalog.tracks.first.isAi, isFalse);
      expect(catalog.tracks.last.fileId, 'sub');
      for (final track in catalog.tracks) {
        final text = await p.readSubtitleText(
          CloudDriveSubtitleReadRequest(
            credential: _aliCredential,
            accountLocalId: 'local',
            remoteAccountId: 'ali-user',
            driveId: 'resource',
            track: track,
          ),
        );
        expect(text, contains('Hello'));
      }
    },
  );

  test(
    'UC verifies an authenticated root even without an account info endpoint',
    () async {
      final http = _Http((r) {
        expect(r.uri.host, anyOf('drive.uc.cn', 'pc-api.uc.cn'));
        if (r.uri.path == '/account/info') return _json(r, {}, status: 404);
        expect(r.uri.queryParameters['pr'], 'UCBrowser');
        expect(r.headers['Cookie'], contains('uc-secret'));
        if (r.uri.path.endsWith('/file/v2/play')) {
          return _json(r, {
            'code': 0,
            'data': {
              'video_list': [
                {
                  'resolution': 'high',
                  'trans_status': 'success',
                  'accessable': true,
                  'video_info': {
                    'url': 'https://cdn.example.test/uc.m3u8',
                    'height': 720,
                  },
                },
              ],
            },
          });
        }
        return _json(r, {
          'code': 0,
          'status': 200,
          'data': {'list': []},
          'metadata': {'_total': 0},
        });
      });
      final p = UcCloudDriveProvider(http: http);
      expect((await p.verifySession(_ucCredential)).remoteAccountId, 'uc-user');
      expect(await p.discoverQualities(_play(_ucCredential)), hasLength(2));
      expect(
        (await p.discoverOfficialSubtitles(_play(_ucCredential))).status,
        CloudDriveOfficialSubtitleStatus.unsupported,
      );
      expect(
        http.requests.any((r) => r.uri.host.endsWith('quark.cn')),
        isFalse,
      );
    },
  );

  test(
    'UC automatically starts a complete accessible transcode before the throttled original',
    () async {
      final http = _Http((r) {
        expect(r.uri.path.endsWith('/file/download'), isFalse);
        if (r.uri.path.endsWith('/file/v2/play')) {
          return _json(r, {
            'code': 0,
            'data': {
              'meta': {'duration': 60},
              'video_list': [
                {
                  'resolution': 'super',
                  'trans_status': 'transcoding',
                  'accessable': false,
                },
                {
                  'resolution': 'high',
                  'trans_status': 'success',
                  'accessable': true,
                  'video_info': {
                    'url': 'https://cdn.example.test/uc.m3u8',
                    'format': 'm3u8',
                    'height': 720,
                    'duration': 60,
                  },
                },
              ],
            },
          });
        }
        return CloudDriveHttpResponse(
          statusCode: 200,
          headers: const {'content-type': 'application/vnd.apple.mpegurl'},
          body: utf8.encode(
            '#EXTM3U\n#EXTINF:60,\nsegment.ts\n#EXT-X-ENDLIST\n',
          ),
          finalUri: r.uri,
        );
      });
      final d = await UcCloudDriveProvider(
        http: http,
      ).resolvePlayback(_play(_ucCredential));
      expect(d.providerId, 'uc');
      expect(d.quality.id, 'high');
      expect(d.transport, CloudDriveTransport.hls);
      expect(d.verifiedComplete, isTrue);
      expect(d.qualities.first.id, 'original');
      expect(
        d.qualities.firstWhere((q) => q.id == 'super').selectable,
        isFalse,
      );
    },
  );

  for (final providerId in ['uc', 'quark']) {
    for (final preferred in <String?>[null, 'low']) {
      test(
        '$providerId ranks actual pixels and preserves explicit 270P: $preferred',
        () async {
          final http = _Http((r) {
            if (r.uri.path.endsWith('/file/download')) {
              expect(providerId, 'quark');
              expect(preferred, isNull);
              return _json(r, {'code': 0, 'data': []});
            }
            if (r.uri.path.endsWith('/file/v2/play')) {
              return _json(r, {
                'code': 0,
                'data': {
                  'meta': {'duration': 60},
                  'video_list': [
                    for (final (id, height) in [
                      ('low', 270),
                      ('high', 540),
                      ('normal', 720),
                    ])
                      {
                        'resolution': id,
                        'trans_status': 'success',
                        'accessable': true,
                        'video_info': {
                          'url': 'https://cdn.example.test/$id.m3u8',
                          'format': 'm3u8',
                          'height': height,
                          'duration': 60,
                        },
                      },
                    {
                      'resolution': '4k',
                      'trans_status': 'success',
                      'accessable': false,
                    },
                    {
                      'resolution': 'super',
                      'trans_status': 'transcoding',
                      'accessable': true,
                    },
                  ],
                },
              });
            }
            return CloudDriveHttpResponse(
              statusCode: 200,
              headers: const {'content-type': 'application/vnd.apple.mpegurl'},
              body: utf8.encode(
                '#EXTM3U\n#EXTINF:60,\nsegment.ts\n#EXT-X-ENDLIST\n',
              ),
              finalUri: r.uri,
            );
          });
          final CloudDriveProvider provider = providerId == 'uc'
              ? UcCloudDriveProvider(http: http)
              : QuarkCloudDriveProvider(http: http);
          final descriptor = await provider.resolvePlayback(
            _play(_ucCredential, quality: preferred),
          );
          expect(descriptor.quality.id, preferred ?? 'normal');
          expect(
            descriptor.quality.label,
            '${preferred == null ? 720 : 270}P 转码',
          );
          expect(descriptor.verifiedComplete, isTrue);
          expect(descriptor.qualities.map((q) => q.id), [
            'original',
            '4k',
            'super',
            'normal',
            'high',
            'low',
          ]);
          expect(
            descriptor.qualities
                .where((q) => q.selectable && q.transcoded)
                .first
                .id,
            'normal',
          );
        },
      );
    }
  }

  for (final explicit in [false, true]) {
    test(
      'UC preserves original playback and falls back honestly when no transcode exists: explicit=$explicit',
      () async {
        final http = _Http((r) {
          if (r.uri.path.endsWith('/file/v2/play')) {
            expect(explicit, isFalse);
            return _json(r, {
              'code': 0,
              'data': {'video_list': []},
            });
          }
          if (r.uri.path.endsWith('/file/download')) {
            return _json(r, {
              'code': 0,
              'data': [
                {'download_url': 'https://cdn.example.test/uc.mp4', 'size': 8},
              ],
            });
          }
          return _aliDefault(r);
        });
        final d = await UcCloudDriveProvider(http: http).resolvePlayback(
          _play(_ucCredential, quality: explicit ? 'original' : null),
        );
        expect(d.quality.id, 'original');
        expect(d.transport, CloudDriveTransport.progressive);
      },
    );
  }

  for (final quality in <String?>[null, 'SD']) {
    test(
      'Aliyun sorts qualities descending and selects the highest available unless explicitly chosen: $quality',
      () async {
        final http = _Http((r) {
          if (r.uri.path == '/v2/file/get_download_url') {
            return _json(r, {'code': 'ForbiddenNoPermission'}, status: 403);
          }
          if (r.uri.path == '/v2/file/get_video_preview_play_info') {
            return _json(r, {
              'video_preview_play_info': {
                'live_transcoding_task_list': [
                  {
                    'template_id': 'SD',
                    'status': 'finished',
                    'url': 'https://cdn.example.test/540.m3u8',
                  },
                  {
                    'template_id': 'HD',
                    'status': 'finished',
                    'url': 'https://cdn.example.test/720.m3u8',
                  },
                  {'template_id': 'UHD', 'status': 'running'},
                ],
              },
            });
          }
          if (r.uri.path.endsWith('.m3u8')) {
            return CloudDriveHttpResponse(
              statusCode: 200,
              headers: const {'content-type': 'application/vnd.apple.mpegurl'},
              body: utf8.encode(
                '#EXTM3U\n#EXTINF:60,\nsegment.ts\n#EXT-X-ENDLIST\n',
              ),
              finalUri: r.uri,
            );
          }
          return _aliDefault(r);
        });
        final p = AliyunCloudDriveProvider(http: http);
        final d = await p.resolvePlayback(
          _play(_aliCredential, quality: quality),
        );
        expect(d.quality.id, quality ?? 'HD');
        expect(d.qualities.map((q) => q.id), ['original', 'UHD', 'HD', 'SD']);
        expect(
          (await p.discoverQualities(_play(_aliCredential))).map((q) => q.id),
          ['original', 'UHD', 'HD', 'SD'],
        );
      },
    );
  }

  test(
    'Aliyun directory covers use the exact signed root Referer before any playback',
    () async {
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1cAAAAASUVORK5CYII=',
      );
      final root = await Directory.systemTemp.createTemp('ali-initial-covers-');
      addTearDown(() => root.delete(recursive: true));
      var images = 0;
      final http = _Http((r) {
        expect(r.uri.path == '/v2/file/get_download_url', isFalse);
        expect(r.uri.path == '/v2/file/get_video_preview_play_info', isFalse);
        if (r.uri.path == '/adrive/v3/file/list') {
          return _json(r, {
            'items': [
              {..._video, 'thumbnail': 'https://image.example.test/cover.jpg'},
            ],
            'next_marker': '',
          });
        }
        if (r.uri.host == 'image.example.test') {
          images++;
          final headers = r.headersFor!(r.uri);
          expect(headers['Referer'], 'https://www.alipan.com/');
          expect(headers['User-Agent'], AliyunCloudDriveProvider.webUserAgent);
          return CloudDriveHttpResponse(
            statusCode: headers['Referer'] == 'https://www.alipan.com/'
                ? 200
                : 403,
            headers: const {'content-type': 'image/png'},
            body: png,
            finalUri: r.uri,
          );
        }
        return _aliDefault(r);
      });
      final p = AliyunCloudDriveProvider(http: http);
      final accounts = CloudDriveAccountRepository(
        credentials: CloudDriveCredentialStore(storage: _Secrets()),
        metadata: MemoryCloudDriveAccountMetadataStore(),
      );
      await accounts.commitVerified(
        providerId: 'aliyun',
        remoteAccountId: 'ali-user',
        displayName: '账号',
        credential: _aliCredential,
      );
      final entry = (await p.listChildren(
        _list(_aliCredential, parent: '@aliyun:resource:root'),
      )).entries.single;
      final source = cloudDriveEntrySource(entry).cloudDrive!;
      final covers = CloudDriveThumbnails(
        providers: CloudDriveProviderRegistry([p]),
        accounts: accounts,
        root: root,
      );
      addTearDown(covers.close);
      covers.rememberEntry(source, entry);
      final cached = await covers.ensure(source);
      expect(cached, isNotNull);
      expect(await File(cached!).readAsBytes(), png);
      expect(images, 1);
    },
  );

  for (final providerId in ['uc', 'aliyun']) {
    test(
      '$providerId login, directory, gateway Range, cache, restart and AI audio material run together',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final uri = Uri.parse('http://127.0.0.1:${server.port}/video.mp4');
        final payload = List<int>.generate(256, (i) => i);
        var gets = 0;
        server.listen((request) async {
          gets++;
          final range = request.headers.value('range');
          final match = range == null
              ? null
              : RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
          final start = match == null ? 0 : int.parse(match[1]!);
          final end = match == null || match[2]!.isEmpty
              ? payload.length - 1
              : int.parse(match[2]!);
          request.response.headers.set('accept-ranges', 'bytes');
          request.response.headers.contentType = ContentType('video', 'mp4');
          request.response.statusCode = match == null ? 200 : 206;
          if (match != null) {
            request.response.headers.set(
              'content-range',
              'bytes $start-$end/${payload.length}',
            );
          }
          final bytes = payload.sublist(start, end + 1);
          request.response.contentLength = bytes.length;
          request.response.add(bytes);
          await request.response.close();
        });
        final root = await Directory.systemTemp.createTemp(
          'extended-cloud-workflow-',
        );
        addTearDown(() => root.delete(recursive: true));
        var autoPlaybackRequests = 0;
        final http = _Http((r) async {
          if (r.uri.host == '127.0.0.1') return NetworkCloudDriveHttp().send(r);
          if (r.uri.path.endsWith('/file/v2/play') ||
              r.uri.path == '/v2/file/get_video_preview_play_info') {
            autoPlaybackRequests++;
          }
          if (providerId == 'aliyun') {
            if (r.uri.path == '/v2/file/get_download_url') {
              return _json(r, {'url': uri.toString()});
            }
            return _aliDefault(r);
          }
          if (r.uri.path == '/account/info') {
            return _json(r, {
              'success': true,
              'code': 'OK',
              'data': {'uid': 'uc-user', 'nickname': 'UC测试'},
            });
          }
          if (r.uri.path.endsWith('/file/download')) {
            return _json(r, {
              'code': 0,
              'data': [
                {'download_url': uri.toString(), 'size': payload.length},
              ],
            });
          }
          return _json(r, {
            'code': 0,
            'data': {
              'list': [
                {
                  'fid': 'video',
                  'file_name': 'lesson.mp4',
                  'file': true,
                  'file_type': 1,
                  'category': 1,
                  'pdir_fid': '0',
                  'size': payload.length,
                  'updated_at': 'revision',
                },
              ],
            },
            'metadata': {'_total': 1},
          });
        });
        final CloudDriveProvider p = providerId == 'uc'
            ? UcCloudDriveProvider(http: http)
            : AliyunCloudDriveProvider(http: http);
        final credential = providerId == 'uc' ? _ucCredential : _aliCredential;
        final verified = await p.verifySession(credential);
        final secrets = _Secrets();
        final accounts = CloudDriveAccountRepository(
          credentials: CloudDriveCredentialStore(storage: secrets),
          metadata: MemoryCloudDriveAccountMetadataStore(),
        );
        final account = await accounts.commitVerified(
          providerId: p.id,
          remoteAccountId: verified.remoteAccountId,
          displayName: verified.displayName,
          credential: verified.refreshedCredential ?? credential,
          driveId: verified.driveId,
        );
        final registry = CloudDriveProviderRegistry([p]);
        final browser = CloudDriveBrowserController(
          providers: registry,
          accounts: accounts,
        );
        final page = await browser.openAccount(
          account,
          directoryId: providerId == 'uc' ? '0' : '@aliyun:resource:root',
        );
        expect(page.error, isNull);
        final entry = page.entries.single;
        final ref = cloudDriveEntrySource(entry);
        final item = VideoItem(
          id: ref.cloudDrive!.itemId,
          path: ref.cloudDrive!.logicalUri,
          title: entry.name,
          durationMs: 60000,
          lastUpdated: 0,
          sourceRef: ref,
        );
        expect(
          CacheSource.fromItem(item)!.providerLabel,
          cloudDriveProviderNames[providerId],
        );
        final playback = CloudDrivePlaybackService(
          providers: registry,
          accounts: accounts,
          subtitleCacheRoot: root,
        );
        addTearDown(playback.close);
        final prepared = await playback.open(item, qualityId: 'original');
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        final request = await client.getUrl(prepared.lease.loopbackUri);
        request.headers.set('range', 'bytes=20-29');
        final response = await request.close();
        expect(response.statusCode, 206);
        expect(
          await response.fold<List<int>>([], (a, b) => a..addAll(b)),
          payload.sublist(20, 30),
        );
        await prepared.lease.release();
        final material = CloudDriveMaterialization(
          providers: registry,
          accounts: accounts,
          cacheRoot: Directory('${root.path}/material'),
          parallelProgressive: false,
        );
        addTearDown(material.prepareStorageMigration);
        final media = await material.acquire(
          item,
          MediaMaterializationRequirement.completeMedia,
        );
        expect(await File(media.requiredVideoPath).readAsBytes(), payload);
        // Downloads and subtitle audio must keep the original representation
        // even when automatic playback prefers a faster transcode.
        expect(autoPlaybackRequests, 0);
        final cachedPath = media.requiredVideoPath;
        await media.release();
        final beforeReuse = gets;
        // This is the same audioOnly lease requested by TranscriptionManager.
        final audio = await material.acquire(
          item,
          MediaMaterializationRequirement.audioOnly,
        );
        expect(audio.requiredAudioPath, cachedPath);
        expect(gets, beforeReuse);
        await audio.release();
        final restarted = CloudDriveMaterialization(
          providers: registry,
          accounts: accounts,
          cacheRoot: Directory('${root.path}/material'),
          parallelProgressive: false,
        );
        addTearDown(restarted.prepareStorageMigration);
        final reloaded = await restarted.acquire(
          item,
          MediaMaterializationRequirement.audioOnly,
        );
        expect(await File(reloaded.requiredAudioPath).readAsBytes(), payload);
        expect(gets, beforeReuse);
        await reloaded.release();
        expect(jsonEncode(ref.toJson()), isNot(contains('refresh_token')));
        expect(jsonEncode(ref.toJson()), isNot(contains('uc-secret')));
      },
    );
  }
}
