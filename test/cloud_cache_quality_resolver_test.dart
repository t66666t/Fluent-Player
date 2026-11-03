import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/providers/cloud_drive_provider.dart';
import 'package:video_player_app/features/media_cache/cloud_cache_quality_resolver.dart';

class _Provider implements CloudDriveProvider {
  final resolved = <String?>[];
  int discoveries = 0;
  Object? originalError;
  bool wrongOriginal = false;
  @override
  Future<CloudDrivePlaybackDescriptor> resolvePlayback(
    CloudDrivePlaybackRequest request, {
    Object? cancelToken,
  }) async {
    resolved.add(request.preferredQualityId);
    if (request.preferredQualityId == 'original' && originalError != null) {
      throw originalError!;
    }
    final quality = request.preferredQualityId == 'original' && wrongOriginal
        ? '720'
        : request.preferredQualityId!;
    return CloudDrivePlaybackDescriptor(
      upstreamUri: Uri.parse('https://media.invalid/file'),
      transport: CloudDriveTransport.progressive,
      quality: CloudDriveQualityChoice(
        id: quality,
        label: quality == 'original' ? '原画' : '${quality}P',
        transcoded: quality != 'original',
        complete: true,
      ),
      fileId: request.fileId,
      revision: 'revision',
      complete: true,
      seekable: true,
      userAgent: 'test',
      referer: '',
      cookies: const [],
    );
  }

  @override
  Future<List<CloudDriveQualityChoice>> discoverQualities(
    CloudDrivePlaybackRequest request, {
    Object? cancelToken,
  }) async {
    discoveries++;
    return [
      const CloudDriveQualityChoice(
        id: 'original',
        label: '原画',
        transcoded: false,
        complete: true,
      ),
      for (final height in [480, 1080, 720])
        CloudDriveQualityChoice(
          id: '$height',
          label: '${height}P',
          transcoded: true,
          complete: true,
        ),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

CloudDrivePlaybackRequest _request([String? quality]) =>
    CloudDrivePlaybackRequest(
      credential: const CloudDriveCredential(cookies: []),
      accountLocalId: 'local',
      remoteAccountId: 'remote',
      driveId: '0',
      fileId: 'file',
      name: 'media.mp4',
      preferredQualityId: quality,
    );

void main() {
  test('explicit original rejects a lower-quality response', () async {
    final provider = _Provider()..wrongOriginal = true;
    await expectLater(
      resolveCloudCacheQuality(provider, _request('original')),
      throwsA(isA<CloudDriveFailure>()),
    );
    expect(provider.discoveries, 0);
  });
  test(
    'highest cloud cache resolves original directly without probing transcodes',
    () async {
      final provider = _Provider();
      final result = await resolveCloudCacheQuality(provider, _request());
      expect(result.quality.id, 'original');
      expect(provider.resolved, ['original']);
      expect(provider.discoveries, 0);
    },
  );
  test('finite ceiling chooses the highest allowed transcode', () async {
    final provider = _Provider();
    final result = await resolveCloudCacheQuality(
      provider,
      _request(),
      maxHeight: 720,
    );
    expect(result.quality.id, '720');
    expect(provider.resolved, ['720']);
  });
  test('explicit quality overrides the batch ceiling', () async {
    final provider = _Provider();
    final result = await resolveCloudCacheQuality(
      provider,
      _request('original'),
      maxHeight: 480,
    );
    expect(result.quality.id, 'original');
    expect(provider.discoveries, 0);
  });
  test(
    'confirmed original refusal falls back to the highest complete transcode',
    () async {
      final provider = _Provider()
        ..originalError = const CloudDriveFailure(
          CloudDriveFailureKind.entitlement,
          '原画不可用',
        );
      final result = await resolveCloudCacheQuality(provider, _request());
      expect(result.quality.id, '1080');
      expect(provider.resolved, ['original', '1080']);
    },
  );
  for (final kind in [
    CloudDriveFailureKind.network,
    CloudDriveFailureKind.notLoggedIn,
    CloudDriveFailureKind.rateLimited,
  ]) {
    test(
      '$kind preserves the recoverable error without lowering quality',
      () async {
        final provider = _Provider()
          ..originalError = CloudDriveFailure(kind, '重试');
        await expectLater(
          resolveCloudCacheQuality(provider, _request()),
          throwsA(isA<CloudDriveFailure>().having((e) => e.kind, 'kind', kind)),
        );
        expect(provider.discoveries, 0);
      },
    );
  }
}
