import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/cloud_drive/auth/cloud_drive_login_browser.dart';
import 'package:video_player_app/features/cloud_drive/providers/cloud_drive_http.dart';
import 'package:video_player_app/features/cloud_drive/providers/quark_cloud_drive_provider.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_stream_gateway.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/features/podcasts/podcast_playback_hooks.dart';
import 'package:video_player_app/models/podcast_source_ref.dart';
import 'package:video_player_app/models/subtitle_output_path_strategy.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_streaming_service.dart';
import 'package:video_player_app/services/community_media_input.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/gongyi_asr_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_materialization_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/transcription_manager.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

class _LoadedCenter extends ModelCenterService {
  @override
  Future<void> initialize() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'processing allows RSS podcast identities and keeps other remote inputs blocked',
    () {
      const ref = MediaSourceRef(
        value: 'https://publisher.test/audio.mp3',
        kind: MediaSourceKind.podcastEpisode,
        podcast: PodcastEpisodeRef(
          channelId: 'c',
          episodeId: 'e',
          feedUrl: 'https://publisher.test/feed.xml',
          mediaUrl: 'https://publisher.test/audio.mp3',
        ),
      );
      expect(
        () => requireCommunityProcessingSource('podcast:e', source: ref),
        returnsNormally,
      );
      for (final path in [
        'https://www.youtube.com/watch?v=abcdefghijk',
        'https://www.bilibili.com/video/BV1234567890',
        'bilibili://stream/1',
        'cloud-drive://account/file',
        'https://publisher.test/audio.mp3',
      ]) {
        expect(
          () => requireCommunityProcessingSource(path),
          throwsUnsupportedError,
        );
      }
      expect(
        () => requireCommunityProcessingSource(
          r'C:\lessons\owned.mp4',
          source: ref,
        ),
        returnsNormally,
      );
    },
  );

  test(
    'public ASR rejects remote input before preparation or requests',
    () async {
      final dio = Dio();
      var requests = 0, preparations = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests++;
            handler.reject(DioException(requestOptions: request));
          },
        ),
      );
      try {
        for (final path in [
          'https://example.test/audio.mp3',
          'podcast:episode',
        ]) {
          await expectLater(
            GongyiAsrService(dio: dio).transcribeAudio(
              path,
              checkpoint: GongyiAsrTaskCheckpoint(taskId: 'saved-task'),
              prepareAudio: () async {
                preparations++;
                return 'owned.wav';
              },
            ),
            throwsUnsupportedError,
          );
        }
        expect(requests, 0);
        expect(preparations, 0);
      } finally {
        dio.close(force: true);
      }
    },
  );

  test('public preset is the default for new transcription tasks', () async {
    final center = _LoadedCenter();
    expect(center.asrProfileId, ModelCenterService.legacyProfile.id);
    expect(
      (await center.captureTranscription()).profile.kind,
      TranscriptionServiceKind.gongyi,
    );
    center.asrProfileId = ModelCenterService.communityDefaultProfile.id;
    expect(center.asrProfile.kind, TranscriptionServiceKind.local);
    expect(center.asrProfile.model, 'sensevoice-small-int8');
    center.dispose();
  });

  for (final selected in [
    ModelCenterService.legacyProfile,
    ModelCenterService.communityDefaultProfile,
  ]) {
    test('${selected.id} selection survives a model-center restart', () async {
      final root = await Directory.systemTemp.createTemp(
        'community-asr-selection-',
      );
      addTearDown(() => root.delete(recursive: true));
      final storage = AppStorageService(
        locations: () async => StorageLocations(
          platform: StoragePlatform.linux,
          support: Directory(p.join(root.path, 'support')),
          documents: Directory(p.join(root.path, 'documents')),
          defaultData: Directory(p.join(root.path, 'data')),
          executable: Directory(p.join(root.path, 'executable')),
        ),
      );
      await storage.initialize();
      final first = ModelCenterService(
        storage: storage,
        catalogLoader: () async => [],
      );
      await first.initialize();
      expect(first.asrProfile.kind, TranscriptionServiceKind.gongyi);
      first.asrProfileId = selected.id;
      await first.save();
      first.dispose();
      final restored = ModelCenterService(
        storage: storage,
        catalogLoader: () async => [],
      );
      addTearDown(restored.dispose);
      await restored.initialize();
      expect(restored.asrProfileId, selected.id);
      expect(restored.asrProfile.kind, selected.kind);
      expect(restored.asrProfile.model, selected.model);
      if (!selected.local) {
        expect(
          (await restored.captureTranscription()).profile.kind,
          selected.kind,
        );
      }
      expect(restored.downloads, isEmpty);
    });
  }

  test(
    'cloud network transports and cookie capture reject direct calls',
    () async {
      final request = CloudDriveHttpRequest(
        method: 'GET',
        uri: Uri.parse('https://pan.quark.cn/api'),
      );
      await expectLater(
        NetworkCloudDriveHttp().send(request),
        throwsUnsupportedError,
      );
      await expectLater(
        NetworkCloudDriveUpstreamClient().open(
          CloudDriveUpstreamRequest(method: 'GET', uri: request.uri),
        ),
        throwsUnsupportedError,
      );
      final browser = CloudDriveLoginBrowser(QuarkCloudDriveProvider());
      await expectLater(browser.prepare(), throwsUnsupportedError);
      await expectLater(browser.readCookies(), throwsUnsupportedError);
      expect(() => browser.credentialFrom([]), throwsUnsupportedError);
      await browser.dispose();
    },
  );

  test(
    'native Bilibili playback and direct materialization cannot bypass local-only policy',
    () async {
      final api = BilibiliApiService();
      final item = VideoItem(
        id: 'b',
        path: 'bilibili://stream/BV1234567890/1',
        title: 'Online',
        durationMs: 0,
        lastUpdated: 0,
      );
      final materialization = MediaMaterializationService(api);
      for (final requirement in MediaMaterializationRequirement.values) {
        await expectLater(
          materialization.acquire(item, requirement),
          throwsUnsupportedError,
        );
        await expectLater(
          materialization.estimate(item, requirement),
          throwsUnsupportedError,
        );
      }
      final streaming = BilibiliStreamingService(api);
      await expectLater(streaming.prepare(item), throwsUnsupportedError);
      await expectLater(
        streaming.prepareForStartup(item),
        throwsUnsupportedError,
      );
      expect(
        () => streaming.downloadAudioForTranscription(item),
        throwsUnsupportedError,
      );
      await streaming.shutdown();
      streaming.dispose();
      materialization.dispose();
    },
  );

  test(
    'restored RSS jobs remain queued while official online jobs stay blocked',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'community-processing-',
      );
      final oldPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(root.path);
      final settings = SettingsService()..resetForTest();
      await settings.init();
      settings.largeDataRootPath = root.path;
      final library = LibraryService()..resetLibraryForTesting();
      await library.init();
      final manager = TranscriptionManager(settings: settings);
      final previousRestore = PodcastPlaybackHooks.restoreSource;
      PodcastPlaybackHooks.restoreSource = (path, id) =>
          path == 'podcast:e' && id == 'podcast-old'
          ? VideoItem(
              id: 'podcast-old',
              path: 'podcast:e',
              title: 'RSS episode',
              durationMs: 0,
              lastUpdated: 0,
              sourceRef: const MediaSourceRef(
                value: 'https://publisher.test/audio.mp3',
                kind: MediaSourceKind.podcastEpisode,
                podcast: PodcastEpisodeRef(
                  channelId: 'c',
                  episodeId: 'e',
                  feedUrl: 'https://publisher.test/rss',
                  mediaUrl: 'https://publisher.test/audio.mp3',
                ),
              ),
            )
          : null;
      try {
        await expectLater(
          manager.startTranscription(
            'https://www.youtube.com/watch?v=abcdefghijk',
          ),
          throwsUnsupportedError,
        );
        await expectLater(
          manager.startExternalTranscription(
            'bilibili://stream/1',
            outputPathStrategy: SubtitleOutputPathStrategy.sameAsVideo,
          ),
          throwsUnsupportedError,
        );
        await File(
          p.join(root.path, 'transcription_queue_cache.json'),
        ).writeAsString(
          jsonEncode({
            'queue': [
              {
                'videoPath': 'bilibili://stream/1',
                'videoId': 'legacy',
                'mediaKey': 'id:legacy',
                'checkpointScope': 'keep-checkpoint',
              },
              {
                'videoPath': 'podcast:e',
                'videoId': 'podcast-old',
                'mediaKey': 'id:podcast-old',
              },
            ],
          }),
        );
        await manager.initialize();
        expect(
          manager.isVideoQueued('bilibili://stream/1', videoId: 'legacy'),
          isFalse,
        );
        expect(
          manager.isVideoFailed('bilibili://stream/1', videoId: 'legacy'),
          isTrue,
        );
        expect(manager.isProcessing, isFalse);
        expect(
          manager.isVideoQueued('podcast:e', videoId: 'podcast-old'),
          isTrue,
        );
        expect(
          manager.isVideoFailed('podcast:e', videoId: 'podcast-old'),
          isFalse,
        );
        expect(
          manager.getQueueSnapshot().map((task) => task.mediaKey).toSet(),
          {'id:legacy', 'id:podcast-old'},
        );
        final checkpoint = File(
          p.join(root.path, 'transcription_slice_checkpoints.json'),
        );
        const savedCheckpoint = '{"legacy-checkpoint":"keep-exactly"}';
        await checkpoint.writeAsString(savedCheckpoint);
        expect(
          manager.retryVideo('podcast:e', videoId: 'podcast-old'),
          isFalse,
        );
        expect(
          manager.restartVideo('bilibili://stream/1', videoId: 'legacy'),
          isFalse,
        );
        manager.startTask('id:legacy');
        await manager.shutdown();
        expect(await checkpoint.readAsString(), savedCheckpoint);
        final saved =
            jsonDecode(
                  await File(
                    p.join(root.path, 'transcription_queue_cache.json'),
                  ).readAsString(),
                )
                as Map;
        expect(jsonEncode(saved), contains('keep-checkpoint'));
      } finally {
        await manager.shutdown();
        manager.dispose();
        PodcastPlaybackHooks.restoreSource = previousRestore;
        library.resetLibraryForTesting();
        settings.resetForTest();
        PathProviderPlatform.instance = oldPaths;
        await root.delete(recursive: true);
      }
    },
  );
}
