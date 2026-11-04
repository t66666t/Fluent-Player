import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/cloud_drive/auth/cloud_drive_credential_store.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/providers/baidu_cloud_drive_provider.dart';
import 'package:video_player_app/features/cloud_drive/providers/cloud_drive_http.dart';
import 'package:video_player_app/features/cloud_drive/providers/cloud_drive_provider.dart';
import 'package:video_player_app/features/cloud_drive/providers/quark_cloud_drive_provider.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_account_repository.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_thumbnails.dart';
import 'package:video_player_app/models/cloud_drive_source_ref.dart';

import 'cloud_drive_accounts_test.dart' show MemorySecret;

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1cAAAAASUVORK5CYII=',
);

class _ThumbnailHttp implements CloudDriveHttp {
  final requests = <CloudDriveHttpRequest>[];
  bool html = false;
  @override
  Future<CloudDriveHttpResponse> send(
    CloudDriveHttpRequest request, {
    Object? cancelToken,
  }) async {
    requests.add(request);
    return CloudDriveHttpResponse(
      statusCode: request.uri.path == '/expired' ? 403 : 200,
      headers: {},
      body: html ? utf8.encode('<html>login</html>') : _png,
      finalUri: request.uri,
    );
  }
}

class _ThumbnailProvider extends CloudDriveProvider {
  _ThumbnailProvider(this.http);
  final _ThumbnailHttp http;
  var metadataCalls = 0;
  Completer<void>? metadataGate;
  String? revision;
  bool failMetadata = false;
  @override
  String get id => 'baidu';
  @override
  Uri get loginUri => Uri.parse('https://pan.baidu.com/');
  @override
  CloudDriveHttp get thumbnailHttp => http;
  @override
  Future<CloudDriveEntry> getFile(
    CloudDriveFileRequest request, {
    Object? cancelToken,
  }) async {
    metadataCalls++;
    await metadataGate?.future;
    if (failMetadata) throw StateError('network unavailable');
    return CloudDriveEntry(
      providerId: id,
      accountLocalId: request.accountLocalId,
      remoteAccountId: request.remoteAccountId,
      driveId: request.driveId,
      fileId: request.fileId,
      parentFileId: '0',
      name: 'video.mp4',
      kind: CloudDriveEntryKind.video,
      durationMs: 4533000,
      revision: revision,
      thumbnailRef: 'https://pan.baidu.com/fresh',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

CloudDriveSourceRef _source({String account = '42', String revision = 'r1'}) =>
    CloudDriveSourceRef(
      providerId: 'baidu',
      remoteAccountId: account,
      driveId: '0',
      fileId: '9',
      revision: revision,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _ThumbnailHttp http;
  late _ThumbnailProvider provider;
  late CloudDriveAccountRepository accounts;
  late CloudDriveThumbnails covers;
  late CloudDriveProviderRegistry registry;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cloud_covers');
    http = _ThumbnailHttp();
    provider = _ThumbnailProvider(http);
    accounts = CloudDriveAccountRepository(
      credentials: CloudDriveCredentialStore(storage: MemorySecret()),
      metadata: MemoryCloudDriveAccountMetadataStore(),
    );
    for (final id in ['42', '43']) {
      await accounts.commitVerified(
        providerId: 'baidu',
        remoteAccountId: id,
        displayName: id,
        credential: CloudDriveCredential(
          cookies: [
            CloudDriveCookie(
              name: 'BDUSS',
              value: 'secret',
              domain: '.baidu.com',
            ),
          ],
        ),
      );
    }
    registry = CloudDriveProviderRegistry([provider]);
    covers = CloudDriveThumbnails(
      providers: registry,
      accounts: accounts,
      root: root,
    );
  });
  tearDown(() async {
    covers.close();
    await root.delete(recursive: true);
  });

  test(
    'list cover is downloaded once and restored locally after restart',
    () async {
      covers.remember(_source(), 'https://pan.baidu.com/cover');
      final paths = await Future.wait([
        covers.ensure(_source()),
        covers.ensure(_source()),
      ]);
      expect(paths.first, isNotNull);
      expect(paths.first, paths.last);
      expect(await File(paths.first!).readAsBytes(), _png);
      expect(provider.metadataCalls, 0);
      expect(http.requests, hasLength(1));
      covers.close();
      covers = CloudDriveThumbnails(
        providers: registry,
        accounts: accounts,
        root: root,
      );
      expect(await covers.ensure(_source()), paths.first);
      expect(http.requests, hasLength(1));
    },
  );

  test(
    'an older card fetches metadata and isolates accounts and revisions',
    () async {
      final paths = await Future.wait([
        covers.ensure(_source()),
        covers.ensure(_source(account: '43')),
        covers.ensure(_source(revision: 'r2')),
      ]);
      expect(paths.toSet(), hasLength(3));
      expect(paths, everyElement(isNotNull));
      expect(provider.metadataCalls, 3);
      expect(http.requests, hasLength(3));
    },
  );

  test(
    'queue details share cover lookup and cache duration without playback',
    () async {
      final results = await Future.wait<Object?>([
        covers.ensure(_source()),
        covers.metadata(_source()),
        covers.metadata(_source()),
      ]);
      expect(results.first, isNotNull);
      expect((results[1] as CloudDriveEntry).durationMs, 4533000);
      expect(provider.metadataCalls, 1);
      expect((await covers.metadata(_source()))!.durationMs, 4533000);
      expect(provider.metadataCalls, 1);
    },
  );

  test(
    'cached pixels do not prevent an unknown queue duration being read',
    () async {
      covers.remember(_source(), 'https://pan.baidu.com/cover');
      expect(await covers.ensure(_source()), isNotNull);
      expect(provider.metadataCalls, 0);
      expect((await covers.metadata(_source()))!.durationMs, 4533000);
      expect(provider.metadataCalls, 1);
      expect(http.requests, hasLength(1));
    },
  );

  test(
    'metadata failures are throttled and replaced revisions are rejected',
    () async {
      provider.failMetadata = true;
      expect(await covers.metadata(_source()), isNull);
      expect(await covers.metadata(_source()), isNull);
      expect(provider.metadataCalls, 1);
      provider.failMetadata = false;
      provider.revision = 'replacement';
      expect(await covers.metadata(_source(revision: 'r2')), isNull);
      expect(await covers.ensure(_source(revision: 'r2')), isNull);
      expect(provider.metadataCalls, 2);
      expect(http.requests, isEmpty);
    },
  );

  test(
    'only two file-detail requests run at once and shutdown drains waiters',
    () async {
      provider.metadataGate = Completer<void>();
      final loads = [
        for (var i = 0; i < 5; i++) covers.metadata(_source(revision: 'v$i')),
      ];
      await Future<void>.delayed(Duration.zero);
      expect(provider.metadataCalls, 2);
      covers.close();
      provider.metadataGate!.complete();
      expect(await Future.wait(loads), everyElement(isNull));
      expect(provider.metadataCalls, 2);
    },
  );

  test(
    'expired list address refreshes metadata once and saves the real image',
    () async {
      covers.remember(_source(), 'https://pan.baidu.com/expired');
      expect(await covers.ensure(_source()), isNotNull);
      expect(http.requests.map((r) => r.uri.path), ['/expired', '/fresh']);
      expect(provider.metadataCalls, 1);
    },
  );

  test(
    'login HTML cannot become a cover and failed rebuilds are throttled',
    () async {
      http.html = true;
      expect(await covers.ensure(_source()), isNull);
      expect(await root.list().toList(), isEmpty);
      expect(await covers.ensure(_source()), isNull);
      expect(provider.metadataCalls, 1);
      expect(http.requests, hasLength(1));
    },
  );

  test('thumbnail cookies follow their domain at every redirect', () async {
    final account = accounts.accounts.first;
    final credential = (await accounts.credentialFor(account))!;
    final baidu = BaiduCloudDriveProvider(http: http);
    await baidu.readThumbnail(
      CloudDriveFileRequest(
        credential: credential,
        accountLocalId: account.localId,
        remoteAccountId: '42',
        driveId: '0',
        fileId: '9',
      ),
      Uri.parse('https://pan.baidu.com/cover'),
    );
    final request = http.requests.single;
    expect(
      request.headersFor!(Uri.parse('https://pan.baidu.com/cover'))['Cookie'],
      contains('BDUSS='),
    );
    expect(
      request.headersFor!(Uri.parse('https://unrelated.test/cover'))['Cookie'],
      isNull,
    );
    expect(request.maxBytes, 8 * 1024 * 1024);
  });

  test(
    'a decoded frame supplies and persists a cover without a provider URL',
    () async {
      final path = await covers.rememberFrame(_source(), _png);
      expect(path, isNotNull);
      expect(await covers.ensure(_source()), path);
      expect(http.requests, isEmpty);
      expect(provider.metadataCalls, 0);
      expect(
        await covers.rememberFrame(
          _source(),
          utf8.encode('<html>error</html>'),
        ),
        isNull,
      );
      expect(await File(path!).readAsBytes(), _png);
    },
  );

  test('Quark preview objects produce an image URI, never a map string', () {
    expect(
      quarkThumbnailUrl({
        'thumbnail': {'url': '//cdn.quark.cn/a.jpg'},
      }),
      'https://cdn.quark.cn/a.jpg',
    );
    expect(
      quarkThumbnailUrl({
        'thumbnail': {},
        'preview_url': 'https://cdn.quark.cn/b.jpg',
      }),
      'https://cdn.quark.cn/b.jpg',
    );
    expect(
      quarkThumbnailUrl({
        'thumbnail': {'icon': 'video'},
      }),
      isNull,
    );
  });
}
