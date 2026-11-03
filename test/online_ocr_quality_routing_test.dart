import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/providers/cloud_drive_provider.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_account_repository.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_materialization.dart';
import 'package:video_player_app/features/media_cache/media_cache_hooks.dart';
import 'package:video_player_app/features/podcasts/podcast_playback_hooks.dart';
import 'package:video_player_app/models/cloud_drive_source_ref.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/podcast_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_materialization_service.dart';

class _Accounts extends Fake implements CloudDriveAccountRepository {
  @override
  CloudDriveAccount? findRemote(String providerId, String remoteAccountId) =>
      CloudDriveAccount(
        localId: 'local',
        providerId: providerId,
        remoteAccountId: remoteAccountId,
        displayName: 'Account',
        credentialKey: 'test',
        authState: CloudDriveAuthState.signedIn,
      );
  @override
  Future<CloudDriveCredential?> credentialFor(
    CloudDriveAccount account,
  ) async => const CloudDriveCredential(cookies: []);
}

class _Provider extends Fake implements CloudDriveProvider {
  _Provider(this.id, this.origin);
  @override
  final String id;
  final Uri origin;
  final resolved = <String?>[];
  bool wrongQuality = false;
  @override
  Future<List<CloudDriveQualityChoice>> discoverQualities(
    CloudDrivePlaybackRequest request, {
    Object? cancelToken,
  }) async => const [
    CloudDriveQualityChoice(
      id: 'original',
      label: '原画',
      transcoded: false,
      complete: true,
    ),
    CloudDriveQualityChoice(
      id: 'normal',
      label: '480P',
      transcoded: true,
      complete: true,
    ),
    CloudDriveQualityChoice(
      id: 'super',
      label: '1080P',
      transcoded: true,
      complete: true,
      availability: CloudDriveQualityAvailability.unavailable,
    ),
    CloudDriveQualityChoice(
      id: 'preview',
      label: '试看',
      transcoded: true,
      complete: false,
    ),
  ];
  @override
  Future<CloudDrivePlaybackDescriptor> resolvePlayback(
    CloudDrivePlaybackRequest request, {
    Object? cancelToken,
  }) async {
    resolved.add(request.preferredQualityId);
    final quality = wrongQuality ? 'original' : request.preferredQualityId!;
    return CloudDrivePlaybackDescriptor(
      upstreamUri: origin.resolve('/$quality.mp4'),
      transport: CloudDriveTransport.progressive,
      quality: CloudDriveQualityChoice(
        id: quality,
        label: quality,
        transcoded: quality != 'original',
        complete: true,
      ),
      fileId: request.fileId,
      revision: 'rev',
      complete: true,
      seekable: true,
      userAgent: '',
      referer: '',
      cookies: const [],
      providerId: id,
      remoteAccountId: request.remoteAccountId,
      driveId: request.driveId,
      sizeBytes: 1024,
    );
  }
}

VideoItem _cloudItem(String providerId) {
  final cloud = CloudDriveSourceRef(
    providerId: providerId,
    remoteAccountId: 'remote',
    driveId: '0',
    fileId: 'file',
    revision: 'rev',
    preferredQuality: 'original',
  );
  return VideoItem(
    id: 'cloud-$providerId',
    path: cloud.logicalUri,
    title: 'Video',
    durationMs: 10000,
    lastUpdated: 0,
    sourceRef: MediaSourceRef(
      kind: MediaSourceKind.cloudDrive,
      value: cloud.logicalUri,
      cloudDrive: cloud,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late HttpServer server;
  final requests = <String>[];
  setUp(() async {
    HttpOverrides.global = null;
    root = await Directory.systemTemp.createTemp('online-ocr-quality-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    requests.clear();
    unawaited(
      server.forEach((request) async {
        requests.add(request.uri.path);
        request.response.contentLength = 1024;
        request.response.add(List.filled(1024, 21));
        await request.response.close();
      }),
    );
  });
  tearDown(() async {
    LibraryService().cloudDriveMaterialization = null;
    PodcastPlaybackHooks.materializeVideo = null;
    PodcastPlaybackHooks.releaseMaterialized = null;
    MediaCacheHooks.acquireMaterial = null;
    await server.close(force: true);
    await root.delete(recursive: true);
  });

  for (final providerId in ['baidu', 'quark', 'uc', 'aliyun']) {
    test(
      '$providerId discovers allowed complete qualities and downloads the chosen low version',
      () async {
        final provider = _Provider(
          providerId,
          Uri.parse('http://127.0.0.1:${server.port}'),
        );
        final service = CloudDriveMaterialization(
          cacheRoot: root,
          providers: CloudDriveProviderRegistry([provider]),
          accounts: _Accounts(),
        );
        addTearDown(service.prepareStorageMigration);
        final library = LibraryService()..cloudDriveMaterialization = service;
        final item = _cloudItem(providerId);
        expect((await service.videoQualities(item)).map((q) => q.id), [
          'original',
          'normal',
        ]);
        final lease = await library.acquireMaterializedMedia(
          item.id,
          MediaMaterializationRequirement.videoFrames,
          qualityId: 'normal',
          sourceItem: item,
        );
        expect(item.sourceRef!.cloudDrive!.preferredQuality, 'original');
        expect(provider.resolved, ['normal']);
        expect(requests, ['/normal.mp4']);
        expect(await File(lease.requiredVideoPath).length(), 1024);
        await lease.release();
        final reused = await library.acquireMaterializedMedia(
          item.id,
          MediaMaterializationRequirement.videoFrames,
          qualityId: 'normal',
          sourceItem: item,
        );
        expect(requests, ['/normal.mp4']);
        expect(provider.resolved, ['normal']);
        await reused.release();
      },
    );
  }

  test(
    'cloud refuses a different quality returned for an explicit low choice',
    () async {
      final provider = _Provider(
        'baidu',
        Uri.parse('http://127.0.0.1:${server.port}'),
      )..wrongQuality = true;
      final service = CloudDriveMaterialization(
        cacheRoot: root,
        providers: CloudDriveProviderRegistry([provider]),
        accounts: _Accounts(),
      );
      addTearDown(service.prepareStorageMigration);
      final library = LibraryService()..cloudDriveMaterialization = service;
      final item = _cloudItem('baidu');
      await expectLater(
        library.acquireMaterializedMedia(
          item.id,
          MediaMaterializationRequirement.videoFrames,
          qualityId: 'normal',
          sourceItem: item,
        ),
        throwsA(isA<CloudDriveFailure>()),
      );
      expect(provider.resolved, ['normal']);
      expect(requests, isEmpty);
    },
  );

  test('selected quality reaches the shared video-only cache lookup', () async {
    String? requestedQuality;
    int? requestedHeight;
    MediaMaterializationRequirement? requirement;
    MediaCacheHooks.acquireMaterial =
        (
          item,
          requestedRequirement, {
          targetHeight,
          qualityId,
          codec,
          isolatedTrack = false,
        }) async {
          requestedQuality = qualityId;
          requestedHeight = targetHeight;
          requirement = requestedRequirement;
          return MaterializedMediaLease(
            videoId: item.id,
            audioPath: null,
            videoPath: '${root.path}/cached.mp4',
            completePath: null,
            qualityId: null,
            width: null,
            height: null,
            onRelease: () async {},
          );
        };
    final item = _cloudItem('quark');
    final lease = await LibraryService().acquireMaterializedMedia(
      item.id,
      MediaMaterializationRequirement.videoFrames,
      qualityId: 'normal',
      targetHeight: 1080,
      sourceItem: item,
    );
    expect(requestedQuality, 'normal');
    expect(requestedHeight, isNull);
    expect(requirement, MediaMaterializationRequirement.videoFrames);
    expect(item.sourceRef!.cloudDrive!.preferredQuality, 'original');
    await lease.release();
  });

  test(
    'video podcast uses the existing original video preparation and release hooks',
    () async {
      final item = VideoItem(
        id: 'podcast-video',
        path: 'podcast:episode',
        title: 'Video podcast',
        durationMs: 10000,
        lastUpdated: 0,
        sourceRef: const MediaSourceRef(
          value: 'episode',
          kind: MediaSourceKind.podcastEpisode,
          podcast: PodcastEpisodeRef(
            channelId: 'channel',
            episodeId: 'episode',
            feedUrl: 'https://example.org/feed',
            mediaUrl: 'https://example.org/video.mp4',
          ),
        ),
      );
      var prepared = 0, released = 0;
      PodcastPlaybackHooks.materializeVideo =
          (source, {isCancelled, cancelSignal, onProgress}) async {
            prepared++;
            expect(source, same(item));
            return '${root.path}/podcast.mp4';
          };
      PodcastPlaybackHooks.releaseMaterialized = (_) => released++;
      final library = LibraryService();
      final lease = await library.acquireMaterializedMedia(
        item.id,
        MediaMaterializationRequirement.videoFrames,
        qualityId: 'original',
        sourceItem: item,
      );
      expect(prepared, 1);
      await lease.release();
      expect(released, 1);
      await expectLater(
        library.acquireMaterializedMedia(
          item.id,
          MediaMaterializationRequirement.videoFrames,
          qualityId: '360',
          sourceItem: item,
        ),
        throwsStateError,
      );
      expect(prepared, 1);
    },
  );
}
