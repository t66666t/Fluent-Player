import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/cloud_drive/auth/cloud_drive_credential_store.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/providers/cloud_drive_provider.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_account_repository.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_playback_service.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_stream_gateway.dart';

import 'baidu_auto_subtitle_test.dart' show cloudItem;
import 'cloud_drive_gateway_test.dart' show FakeUpstream;
import 'support/cloud_drive_fixture.dart';

class _ChangingProvider extends FixtureCloudProvider {
  _ChangingProvider() : super('baidu', {});

  int resolves = 0;
  String revision = 'v1';

  @override
  Future<CloudDrivePlaybackDescriptor> resolvePlayback(
    CloudDrivePlaybackRequest request, {
    Object? cancelToken,
  }) async {
    resolves++;
    return CloudDrivePlaybackDescriptor(
      upstreamUri: Uri.parse('https://d.pcs.baidu.com/file.mp4?sign=$revision'),
      transport: CloudDriveTransport.progressive,
      quality: const CloudDriveQualityChoice(
        id: 'original',
        label: '原画',
        transcoded: false,
        complete: true,
      ),
      fileId: request.fileId,
      revision: revision,
      complete: true,
      seekable: true,
      userAgent: 'pan.baidu.com',
      referer: 'https://pan.baidu.com/',
      cookies: request.credential.cookies,
      providerId: id,
      accountLocalId: request.accountLocalId,
      remoteAccountId: request.remoteAccountId,
    );
  }
}

void main() {
  test(
    'changed content cannot reopen the expired quality descriptor',
    () async {
      final provider = _ChangingProvider();
      final accounts = CloudDriveAccountRepository(
        credentials: CloudDriveCredentialStore(storage: CloudFixtureSecrets()),
        metadata: MemoryCloudDriveAccountMetadataStore(),
      );
      await accounts.commitVerified(
        providerId: 'baidu',
        remoteAccountId: '42',
        displayName: 'test',
        credential: const CloudDriveCredential(cookies: []),
      );
      final gateway = CloudDriveStreamGateway(
        upstream: FakeUpstream([403, 200]),
      );
      final service = CloudDrivePlaybackService(
        providers: CloudDriveProviderRegistry([provider]),
        accounts: accounts,
        gateway: gateway,
      );
      final leases = <CloudDrivePlaybackLease>[];
      final client = HttpClient();
      try {
        final first = await service.open(cloudItem(), qualityId: 'original');
        leases.add(first.lease);
        final cached = await service.open(cloudItem(), qualityId: 'original');
        leases.add(cached.lease);
        expect(provider.resolves, 1);
        expect(cached.lease.descriptor.revision, 'v1');

        provider.revision = 'v2';
        final expired = await (await client.getUrl(
          first.lease.loopbackUri,
        )).close();
        await expired.drain<void>();
        expect(expired.statusCode, 409);
        expect(first.lease.needsReopen, isTrue);
        expect(provider.resolves, 2);

        final reopened = await service.open(cloudItem(), qualityId: 'original');
        leases.add(reopened.lease);
        expect(provider.resolves, 3);
        expect(reopened.lease.descriptor.revision, 'v2');
        final response = await (await client.getUrl(
          reopened.lease.loopbackUri,
        )).close();
        await response.drain<void>();
        expect(response.statusCode, 200);
        expect(reopened.lease.needsReopen, isFalse);
      } finally {
        client.close(force: true);
        for (final lease in leases) {
          await lease.release();
        }
        await gateway.close();
      }
    },
  );
}
