import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_controller.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_models.dart';
import 'package:video_player_app/features/podcasts/podcast_playback_hooks.dart';
import 'package:video_player_app/features/podcasts/podcast_runtime.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/podcast_source_ref.dart';
import 'package:video_player_app/models/transcription_status.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/gongyi_asr_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/transcription_manager.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real two-hour audio is fully cached before extraction/upload and remains offline after transcription',
    () async {
      HttpOverrides.global = null;
      SharedPreferences.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp(
        'podcast-asr-pipeline-',
      );
      final oldPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(directory.path);
      final settings = SettingsService()..resetForTest();
      final library = LibraryService()..resetLibraryForTesting();
      final store = PodcastStore(sqlite3.openInMemory());
      final source = File('${directory.path}/two-hours.m4a');
      final generated = await Process.run('ffmpeg', [
        '-hide_banner',
        '-loglevel',
        'error',
        '-f',
        'lavfi',
        '-i',
        'anullsrc=r=8000:cl=mono',
        '-t',
        '7200',
        '-c:a',
        'aac',
        '-b:a',
        '24k',
        source.path,
      ]);
      expect(generated.exitCode, 0, reason: generated.stderr.toString());
      final payload = await source.readAsBytes();
      var mediaRequests = 0, submissions = 0, resultQueries = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        mediaRequests++;
        final match = RegExp(
          r'bytes=(\d+)-(\d*)',
        ).firstMatch(request.headers.value('range') ?? '');
        final start = int.tryParse(match?[1] ?? '') ?? 0;
        final end = min(
          payload.length - 1,
          int.tryParse(match?[2] ?? '') ?? payload.length - 1,
        );
        request.response.statusCode = 206;
        request.response.headers.set('content-type', 'audio/mp4');
        request.response.headers.set('etag', '"two-hours"');
        request.response.headers.set(
          'content-range',
          'bytes $start-$end/${payload.length}',
        );
        request.response.contentLength = end - start + 1;
        request.response.add(payload.sublist(start, end + 1));
        await request.response.close();
      });
      final media = PodcastMedia(
        url: 'http://127.0.0.1:${server.port}/two-hours.m4a',
        mimeType: 'audio/mp4',
        length: payload.length,
      );
      final episode = PodcastEpisode(
        sourceFeedUrl: 'https://publisher.test/rss',
        id: 'two-hours',
        channelId: 'channel',
        title: '两小时播客',
        durationMs: 7200000,
        media: [media],
      );
      store.write(
        'episode',
        episode.id,
        episode.toJson(),
        channel: episode.channelId,
      );
      final client = PodcastClient(
        http: PodcastHttp(clientFactory: HttpClient.new),
      );
      final mediaStore = PodcastMediaStore(
        root: Directory('${directory.path}/media'),
        store: store,
        http: client.http,
      );
      final controller = PodcastController(
        store: store,
        client: client,
        mediaStore: mediaStore,
      )..connectivity = [ConnectivityResult.wifi];
      final runtime = PodcastRuntime.forTesting(controller);
      final item = VideoItem(
        id: 'podcast-media',
        path: 'podcast:two-hours',
        title: '两小时播客',
        type: MediaType.audio,
        durationMs: 7200000,
        lastUpdated: 1,
        sourceRef: MediaSourceRef(
          value: 'podcast:two-hours',
          kind: MediaSourceKind.podcastEpisode,
          podcast: PodcastEpisodeRef(
            channelId: 'channel',
            episodeId: episode.id,
            feedUrl: 'https://feed.test/rss',
            mediaUrl: media.url,
          ),
        ),
      );
      PodcastPlaybackHooks.materialize = runtime.materialize;
      PodcastPlaybackHooks.releaseMaterialized = runtime.releaseMaterialized;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              expect(
                mediaStore.isDownloaded(episode.id, media.url),
                isTrue,
                reason:
                    'No ASR request may run before the full source is available locally',
              );
              expect(mediaStore.protectedEpisodes, contains(episode.id));
              Object data;
              Headers? headers;
              if (options.method == 'PUT') {
                data = <String, Object?>{};
                headers = Headers.fromMap({
                  'etag': ['"audio"'],
                });
              } else if (options.path.endsWith('/resource/create')) {
                submissions++;
                final body = options.data is String
                    ? jsonDecode(options.data as String) as Map
                    : options.data as Map;
                data = {
                  'code': 0,
                  'data': {
                    'upload_urls': ['https://upload.test/audio'],
                    'per_size': body['size'],
                    'in_boss_key': 'boss',
                    'resource_id': 'resource',
                    'upload_id': 'upload',
                  },
                };
              } else if (options.path.endsWith('/resource/create/complete')) {
                data = {
                  'code': 0,
                  'data': {'download_url': 'https://upload.test/audio'},
                };
              } else if (options.path.endsWith('/task/result')) {
                resultQueries++;
                if (resultQueries == 1) {
                  handler.resolve(
                    Response(
                      requestOptions: options,
                      statusCode: 200,
                      data: {'code': 429, 'message': '访问频繁'},
                    ),
                  );
                  return;
                }
                data = {
                  'code': 0,
                  'data': {
                    'state': 4,
                    'result': jsonEncode({
                      'utterances': [
                        {
                          'start_time': 3000,
                          'end_time': 4000,
                          'transcript': '字幕片段 $submissions',
                        },
                      ],
                    }),
                  },
                };
              } else {
                data = {
                  'code': 0,
                  'data': {'task_id': 'task-$submissions'},
                };
              }
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: data,
                  statusCode: 200,
                  headers: headers,
                ),
              );
            },
          ),
        );
      final manager = TranscriptionManager(
        settings: settings,
        asrService: GongyiAsrService(dio: dio, resultQueryDelay: (_) async {}),
      );
      final restrictionStatuses = <TranscriptionStatus>[];
      manager.addListener(() {
        if (manager.statusMessage.contains('频率限制')) {
          restrictionStatuses.add(manager.status);
        }
      });
      try {
        await settings.init();
        await settings.setLargeDataRootPath(directory.path);
        await library.init();
        library.seedVideoForTesting(item);
        await manager.initialize();
        await manager.startTranscription(
          item.path,
          videoId: item.id,
          libraryService: library,
          autoStart: true,
        );
        final watch = Stopwatch()..start();
        while (manager.isQueueRunning &&
            watch.elapsed < const Duration(minutes: 2)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        final result = manager.getGeneratedSrtPathForVideo(
          item.path,
          videoId: item.id,
        );
        expect(
          result,
          isNotNull,
          reason: manager
              .getQueueSnapshot()
              .map((t) => t.statusMessage)
              .join('\n'),
        );
        expect(submissions, 4);
        expect(resultQueries, 5);
        expect(restrictionStatuses, isNotEmpty);
        expect(restrictionStatuses.toSet(), {TranscriptionStatus.transcribing});
        expect(mediaRequests, (payload.length / podcastChunkBytes).ceil());
        expect(mediaStore.downloadBytes, payload.length);
        expect(mediaStore.protectedEpisodes, isNot(contains(episode.id)));
        expect(store.list('mediaUse'), isEmpty);
        controller.connectivity = [ConnectivityResult.none];
        final before = mediaRequests;
        final file = await controller.prepareLocalMedia(episode, media);
        expect(await file.readAsBytes(), payload);
        expect(mediaRequests, before);
        expect((await File(result!).readAsString()).contains('字幕片段 4'), isTrue);
        // ignore: avoid_print
        print(
          'PODCAST_ASR_PIPELINE: sourceBytes=${payload.length}; sourceRequests=$mediaRequests; slices=$submissions; duration=2h',
        );
      } finally {
        await library.saveLibraryForTesting();
        await manager.shutdown();
        manager.dispose();
        dio.close(force: true);
        PodcastPlaybackHooks.materialize = null;
        PodcastPlaybackHooks.releaseMaterialized = null;
        await controller.close();
        await server.close(force: true);
        store.close();
        library.resetLibraryForTesting();
        settings.resetForTest();
        PathProviderPlatform.instance = oldPaths;
        await directory.delete(recursive: true);
      }
    },
    skip:
        !const bool.fromEnvironment('PODCAST_TRANSCRIPTION_INTEGRATION') ||
        !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
