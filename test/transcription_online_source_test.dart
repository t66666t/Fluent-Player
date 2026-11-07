import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/media_cache/media_cache_hooks.dart';
import 'package:video_player_app/features/model_center/inference_resource_governor.dart';
import 'package:video_player_app/features/model_center/model_transcription.dart';
import 'package:video_player_app/features/model_center/asr_enhancement_options.dart';
import 'package:video_player_app/features/model_center/inference_scheduler.dart';
import 'package:video_player_app/features/model_center/local_subtitle_translator.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_controller.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_models.dart';
import 'package:video_player_app/features/podcasts/podcast_playback_hooks.dart';
import 'package:video_player_app/features/podcasts/podcast_runtime.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/models/cloud_drive_source_ref.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/transcription_status.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/ai_subtitle_api_settings.dart';
import 'package:video_player_app/services/ai_subtitle_translator.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/services/transcription_probe_output.dart';
import 'package:video_player_app/utils/ffmpeg_utils.dart';

class _ProbeProcess implements Process {
  _ProbeProcess() {
    stdoutEvents = StreamController<List<int>>(
      onCancel: () => stdoutCancelled = true,
    );
    stderrEvents = StreamController<List<int>>(
      onCancel: () => stderrCancelled = true,
    );
  }
  late final StreamController<List<int>> stdoutEvents, stderrEvents;
  final exited = Completer<int>();
  bool killed = false, stdoutCancelled = false, stderrCancelled = false;

  @override
  Stream<List<int>> get stdout => stdoutEvents.stream;
  @override
  Stream<List<int>> get stderr => stderrEvents.stream;
  @override
  Future<int> get exitCode => exited.future;
  @override
  int get pid => 17;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!exited.isCompleted) exited.complete(-1);
    return true;
  }

  Future<void> close() async {
    await stdoutEvents.close();
    await stderrEvents.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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

class _LocalCenter extends ModelCenterService {
  _LocalCenter() {
    loaded = true;
  }
  @override
  Future<void> initialize() async {}
  @override
  Future<ModelJobSpec> captureTranscription() async =>
      transcriptionConfiguration;
  @override
  ModelJobSpec get transcriptionConfiguration => const ModelJobSpec(
    profile: ModelCenterService.communityDefaultProfile,
    asrEnhancements: AsrEnhancementOptions.disabled,
  );
}

class _Asr extends ModelTranscriptionRunner {
  int calls = 0;
  @override
  Future<List<SubtitleItem>> run({
    required ModelJobSpec spec,
    required String sourceIdentity,
    String checkpointScope = '',
    required Duration duration,
    required PrepareModelAudio prepareAudio,
    PrepareCloudAsrAudio? prepareCloudAudio,
    Future<String> Function(
      Duration,
      Duration,
      AsrAudioChannel,
      void Function(double),
    )?
    prepareAudioChannel,
    required void Function(ModelProcessingProgress) onProgress,
    Future<void>? cancelSignal,
    Future<void> Function(StableAsrBatch)? onStableBatch,
    bool serializeConsumer = false,
    int consumerModelBytes = 0,
    int? consumerWorkingSetBytes,
    int consumerBatchSize = 8,
    int streamAssemblyVersion = 3,
    Future<void> Function()? onSessionClose,
    Future<void> Function()? onConsumerIdle,
    bool Function()? consumerHasResidentModel,
    InferenceResourceSession? resourceSession,
  }) async {
    calls++;
    final input = await prepareAudio(Duration.zero, duration, false, (_) {});
    final probed = await Process.run(await FFmpegUtils.ffprobePath, [
      '-v',
      'error',
      '-show_streams',
      '-of',
      'json',
      input,
    ]);
    expect(probed.exitCode, 0, reason: '${probed.stderr}');
    final streams =
        (jsonDecode(probed.stdout as String) as Map)['streams'] as List;
    expect(streams.any((s) => s['codec_type'] == 'audio'), isTrue);
    final cues = [
      SubtitleItem(
        index: 1,
        startTime: Duration.zero,
        endTime: const Duration(milliseconds: 800),
        text: 'An audible episode',
      ),
    ];
    await onStableBatch?.call(StableAsrBatch(cues, duration, null));
    return cues;
  }
}

class _Translation extends SubtitleTranslationService {
  int calls = 0;
  @override
  Future<List<String>> translateCueBatch({
    required List<SubtitleItem> items,
    required String sourceLanguage,
    required String targetLanguage,
    required SubtitleTranslateProvider provider,
    required void Function(double) onProgress,
    void Function(String?)? onActivity,
    void Function(int, String)? onTranslated,
    AiSubtitleTranslationSettings? aiOptions,
    AiSubtitleApiSettings? aiEndpoint,
    ModelJobSpec? localSpecification,
    ModelCenterService? modelCenter,
    LocalTranslationSession? localSession,
    InferenceReservation? reservation,
    String precedingContext = '',
    String checkpointScope = '',
    Future<void>? cancelSignal,
    SmartTranslationPolicy? smartPolicy,
  }) async {
    calls++;
    return List.filled(items.length, '能听见的节目');
  }
}

Uint8List _wav() {
  final bytes = ByteData(32044);
  void text(int at, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes.setUint8(at + i, value.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  bytes.setUint32(4, 32036, Endian.little);
  text(8, 'WAVEfmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, 16000, Endian.little);
  bytes.setUint32(28, 32000, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  text(36, 'data');
  bytes.setUint32(40, 32000, Endian.little);
  for (var i = 0; i < 16000; i++) {
    bytes.setInt16(
      44 + 2 * i,
      (sin(i * 2 * pi * 440 / 16000) * 8000).round(),
      Endian.little,
    );
  }
  return bytes.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform oldPaths;
  late HttpServer origin;
  late PodcastStore store;
  late PodcastController controller;
  late PodcastRuntime runtime;
  late VideoItem selected, next;
  late TranscriptionManager manager;
  late _Asr asr;
  late _Translation translation;
  late File audio;
  final library = LibraryService(), settings = SettingsService();
  var requests = 0;

  TranscriptionManager create({
    Future<Map<String, dynamic>?> Function(String)? probe,
    ModelCenterService? modelCenter,
  }) => TranscriptionManager(
    settings: settings,
    modelRunner: asr,
    translationService: translation,
    mediaProbe: probe,
    modelCenter: modelCenter ?? _LocalCenter(),
  );

  setUp(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({'batchSubtitleAutoDelete': false});
    settings.resetForTest();
    library.resetLibraryForTesting();
    root = await Directory.systemTemp.createTemp(
      'transcription-online-source-',
    );
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    await settings.init();
    settings.largeDataRootPath = root.path;
    // This fixture exercises source/queue recovery, not delayed card artwork.
    // Startup backfills can otherwise outlive the task and recreate thumbnails
    // while Windows recursively removes the temporary data root.
    await library.init(deferMaintenance: true);
    final payload = _wav();
    audio = await File(p.join(root.path, 'source.wav')).writeAsBytes(payload);
    requests = 0;
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((request) async {
      requests++;
      final match = RegExp(
        r'bytes=(\d+)-(\d*)',
      ).firstMatch(request.headers.value('range') ?? '');
      final start = int.tryParse(match?[1] ?? '') ?? 0;
      final end = min(
        payload.length - 1,
        int.tryParse(match?[2] ?? '') ?? payload.length - 1,
      );
      request.response.statusCode = 206;
      request.response.headers.set('content-type', 'audio/wav');
      request.response.headers.set('etag', '"episode"');
      request.response.headers.set(
        'content-range',
        'bytes $start-$end/${payload.length}',
      );
      request.response.contentLength = end - start + 1;
      request.response.add(payload.sublist(start, end + 1));
      await request.response.close();
    });
    store = PodcastStore(sqlite3.openInMemory());
    final channel = PodcastChannel(
      id: 'channel',
      feedUrl: 'https://feed.test/rss',
      title: 'Channel',
    );
    store.write('channel', channel.id, channel.toJson());
    final episodes = [
      for (final id in ['auto-b', 'next-c'])
        PodcastEpisode(
          id: id,
          channelId: channel.id,
          sourceFeedUrl: channel.feedUrl,
          title: id,
          durationMs: 1000,
          media: [
            PodcastMedia(
              url: 'http://127.0.0.1:${origin.port}/$id.audio',
              mimeType: 'audio/wav',
              length: payload.length,
            ),
          ],
        ),
    ];
    for (final episode in episodes) {
      store.write('episode', episode.id, episode.toJson(), channel: channel.id);
    }
    final client = PodcastClient(
      http: PodcastHttp(clientFactory: HttpClient.new),
    );
    controller = PodcastController(
      store: store,
      client: client,
      mediaStore: PodcastMediaStore(
        root: Directory(p.join(root.path, 'media')),
        store: store,
        http: client.http,
      ),
    );
    runtime = PodcastRuntime.forTesting(controller, library: library)
      ..persistAdaptersOverride = () async {};
    selected = await runtime.itemFor(episodes[0], persist: false);
    next = await runtime.itemFor(episodes[1], persist: false);
    PodcastPlaybackHooks.materialize = runtime.materialize;
    PodcastPlaybackHooks.releaseMaterialized = runtime.releaseMaterialized;
    PodcastPlaybackHooks.restoreSource = null;
    asr = _Asr();
    translation = _Translation();
    manager = create();
    await manager.initialize();
  });
  tearDown(() async {
    await manager.shutdown();
    manager.dispose();
    translation.dispose();
    PodcastPlaybackHooks.materialize = null;
    PodcastPlaybackHooks.releaseMaterialized = null;
    PodcastPlaybackHooks.restoreSource = null;
    PodcastPlaybackHooks.sourceIdentity = null;
    MediaCacheHooks.acquireMaterial = null;
    runtime.dispose();
    await controller.close();
    await origin.close(force: true);
    store.close();
    // Quiesce library work and drain its serialized writes before resetting the
    // singleton or removing the directory that those writes still reference.
    await library.prepareStorageMigration();
    library.resetLibraryForTesting();
    settings.resetForTest();
    PathProviderPlatform.instance = oldPaths;
    await root.delete(recursive: true);
  });

  Future<void> finish() async {
    final elapsed = Stopwatch()..start();
    while (manager.isQueueRunning) {
      if (elapsed.elapsed > const Duration(seconds: 20)) {
        fail('transcription did not finish');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> start(
    VideoItem item, {
    bool capture = true,
    bool run = true,
    bool translate = false,
  }) => manager.startTranscription(
    item.path,
    videoId: item.id,
    sourceItem: capture ? item : null,
    libraryService: library,
    autoStart: run,
    translateChoice: translate
        ? const TranscriptTranslateChoice.automatic()
        : const TranscriptTranslateChoice.off(),
  );
  Future<void> restoreUnresolvedTask(VideoItem item) async {
    await manager.shutdown();
    manager.dispose();
    await File(
      p.join(root.path, 'transcription_queue_cache.json'),
    ).writeAsString(
      jsonEncode({
        'version': 2,
        'queue': [
          {
            'videoPath': item.path,
            'videoId': item.id,
            'mediaKey': 'id:${item.id}',
            'checkpointScope': 'legacy-unresolved',
            'createdAt': 1,
          },
        ],
        'completed': [],
        'failed': [],
        'active': null,
      }),
    );
    manager = create();
    await manager.initialize();
  }

  void expectSuccess() {
    expect(
      manager.getQueueSnapshot().single.status,
      TranscriptionStatus.completed,
      reason: manager.getQueueSnapshot().single.statusMessage,
    );
    expect(asr.calls, 1);
  }

  test(
    'downloaded podcast files transcribe without reactivating remote media hooks',
    () async {
      final local = VideoItem.fromJson(
        selected.toJson()..['path'] = audio.path,
      );
      final provenance = local.sourceRef;
      var materializations = 0;
      PodcastPlaybackHooks
          .materialize = (item, {isCancelled, cancelSignal, onProgress}) async {
        materializations++;
        throw StateError('Local files must not enter the podcast downloader');
      };
      await start(local);
      await finish();
      expectSuccess();
      expect(materializations, 0);
      expect(requests, 0);
      expect(local.sourceRef, same(provenance));
      expect(await audio.exists(), isTrue);
    },
  );

  test(
    'RSS queue projections materialize before transcription and translation',
    () async {
      await start(selected, translate: true);
      await finish();
      expectSuccess();
      expect(translation.calls, 1);
      expect(requests, greaterThan(0));
      expect(controller.mediaStore.isComplete(
        selected.sourceRef!.podcast!.episodeId,
        selected.sourceRef!.podcast!.mediaUrl,
      ), isTrue);
    },
  );

  test(
    'local queued source is frozen when the player mutates its historical-source item',
    () async {
      selected.path = audio.path;
      next.path = (await audio.copy(p.join(root.path, 'next.wav'))).path;
      final path = selected.path, id = selected.id;
      await start(selected, run: false);
      selected
        ..path = next.path
        ..sourceRef = next.sourceRef
        ..title = next.title;
      manager.startAllTasks();
      await finish();
      expectSuccess();
      expect(requests, 0);
      expect(manager.getGeneratedSrtPathForVideo(path, videoId: id), isNotNull);
    },
  );

  test(
    'local source survives task persistence without a library row or catalog recovery hook',
    () async {
      selected.path = audio.path;
      await start(selected, run: false, translate: true);
      await manager.shutdown();
      manager.dispose();
      PodcastPlaybackHooks.restoreSource = null;
      manager = create();
      await manager.initialize();
      expect(library.getVideo(selected.id), isNull);
      manager.startAllTasks();
      await finish();
      expectSuccess();
      expect(translation.calls, 1);
    },
  );

  test(
    'legacy RSS jobs recover their matching source from the catalog',
    () async {
      var recovered = 0;
      PodcastPlaybackHooks.restoreSource = (path, id) {
        recovered++;
        return runtime.restoreSource(path, id);
      };
      await restoreUnresolvedTask(selected);
      manager.startAllTasks();
      await finish();
      expectSuccess();
      expect(recovered, greaterThan(0));
      expect(requests, greaterThan(0));
    },
  );

  test(
    'an incomplete source recovers only its matching RSS catalog identity',
    () async {
      var recovered = 0;
      PodcastPlaybackHooks.restoreSource = (path, id) {
        recovered++;
        return runtime.restoreSource(path, id);
      };
      selected.sourceRef = null;
      await start(selected);
      await finish();
      expectSuccess();
      expect(recovered, greaterThan(0));
      expect(requests, greaterThan(0));
    },
  );

  test('an unknown podcast identity is refused before media acquisition', () async {
    PodcastPlaybackHooks.restoreSource = runtime.restoreSource;
    selected.path = 'podcast:unknown';
    selected.sourceRef = null;
    await expectLater(start(selected), throwsUnsupportedError);
    expect(requests, 0);
    expect(asr.calls, 0);
    expect(manager.getQueueSnapshot(), isEmpty);
  });

  test(
    'a local library-backed queued source survives removal of its library row',
    () async {
      selected.path = audio.path;
      library.seedVideoForTesting(selected);
      await start(selected, capture: false, run: false);
      library.resetLibraryForTesting();
      await library.init(deferMaintenance: true);
      expect(library.getVideo(selected.id), isNull);
      manager.startAllTasks();
      await finish();
      expectSuccess();
    },
  );

  test(
    'attaching the matching RSS source lets a legacy task retry',
    () async {
      await restoreUnresolvedTask(selected);
      expect(manager.getQueueSnapshot().single.status, TranscriptionStatus.error);
      manager.updateSourceForVideo(
        selected.path,
        videoId: selected.id,
        sourceItem: selected,
      );
      expect(manager.retryVideo(selected.path, videoId: selected.id), isTrue);
      await finish();
      expectSuccess();
      expect(requests, greaterThan(0));
    },
  );

  test(
    'a late callback cannot attach the next episode to an older job',
    () async {
      PodcastPlaybackHooks.restoreSource = null;
      await restoreUnresolvedTask(selected);
      manager.updateSourceForVideo(
        selected.path,
        videoId: selected.id,
        sourceItem: next,
      );
      manager.startAllTasks();
      await finish();
      expect(
        manager.getQueueSnapshot().single.status,
        TranscriptionStatus.error,
      );
      expect(requests, 0);
      expect(asr.calls, 0);
    },
  );

  test(
    'reusing an item id cannot retarget a queued job to a different path',
    () async {
      await restoreUnresolvedTask(selected);
      final replacement = VideoItem.fromJson(
        next.toJson()..['id'] = selected.id,
      );
      manager.updateSourceForVideo(
        replacement.path,
        videoId: replacement.id,
        sourceItem: replacement,
      );
      manager.startAllTasks();
      await finish();
      expect(
        manager.getQueueSnapshot().single.status,
        TranscriptionStatus.error,
      );
      expect(requests, 0);
      expect(asr.calls, 0);
    },
  );

  test(
    'retired source cleanup hooks cannot intercept the local transcription queue',
    () async {
      selected.path = audio.path;
      next.path = (await audio.copy(p.join(root.path, 'next.wav'))).path;
      final release = runtime.releaseMaterialized;
      var released = 0;
      PodcastPlaybackHooks.releaseMaterialized = (item) {
        release(item);
        released++;
        throw StateError('test cleanup failure');
      };
      await start(selected, run: false);
      await start(next, run: false);
      manager.startAllTasks();
      await finish();
      expect(asr.calls, 2);
      expect(released, 0);
      expect(requests, 0);
      expect(manager.getQueueSnapshot().map((task) => task.status), [
        TranscriptionStatus.completed,
        TranscriptionStatus.completed,
      ]);
    },
  );

  for (final cloud in [false, true]) {
    test(
      'unregistered ${cloud ? 'cloud' : 'Bilibili'} media is denied before acquiring a lease',
      () async {
        const ref = CloudDriveSourceRef(
          providerId: 'aliyun',
          remoteAccountId: 'account',
          driveId: 'drive',
          fileId: 'file',
        );
        final path = cloud
            ? ref.logicalUri
            : 'bilibili://stream/BV1xx411c7mD?cid=456';
        final item = VideoItem(
          id: cloud ? ref.itemId : 'bili',
          path: path,
          title: 'Online',
          durationMs: 1000,
          lastUpdated: 0,
          sourceRef: MediaSourceRef(
            value: path,
            kind: cloud
                ? MediaSourceKind.cloudDrive
                : MediaSourceKind.bilibiliStream,
            cloudDrive: cloud ? ref : null,
            bvid: cloud ? null : 'BV1xx411c7mD',
            cid: cloud ? null : 456,
          ),
        );
        var acquired = 0;
        MediaCacheHooks.acquireMaterial =
            (
              source,
              requirement, {
              targetHeight,
              qualityId,
              codec,
              isolatedTrack = false,
            }) async {
              acquired++;
              throw StateError(
                'Forbidden online media must not reach materialization',
              );
            };
        await expectLater(start(item), throwsUnsupportedError);
        expect(acquired, 0);
        expect(asr.calls, 0);
        expect(manager.getQueueSnapshot(), isEmpty);
      },
    );
  }

  for (final translate in [false, true]) {
    test(
      'Bilibili parts cannot enter a processing queue (translate=$translate)',
      () async {
        VideoItem part(int page) => VideoItem(
          id: 'bili-p$page',
          path: 'bilibili://stream/BV1xx411c7mD?cid=${1000 + page}',
          title: 'Part $page',
          durationMs: 1000,
          lastUpdated: 0,
          isTransient: true,
          sourceRef: MediaSourceRef(
            value: 'BV1xx411c7mD',
            kind: MediaSourceKind.bilibiliStream,
            bvid: 'BV1xx411c7mD',
            cid: 1000 + page,
            page: page,
          ),
        );
        final p1 = part(1), otherParts = [part(2), part(3)];
        await expectLater(
          start(p1, translate: translate),
          throwsUnsupportedError,
        );
        expect(manager.getQueueSnapshot(), isEmpty);
        expect(
          otherParts.every(
            (item) => item.isTransient && item.subtitlePath == null,
          ),
          isTrue,
        );
        expect(asr.calls, 0);
        expect(translation.calls, 0);
      },
    );
  }

  for (final empty in [false, true]) {
    test(
      '${empty ? 'empty' : 'missing'} inputs are never reported as having no audio track',
      () async {
        final file = File(p.join(root.path, 'unavailable.wav'));
        if (empty) await file.writeAsBytes([]);
        final item = VideoItem(
          id: 'missing',
          path: file.path,
          title: 'Missing',
          durationMs: 0,
          lastUpdated: 0,
        );
        await start(item);
        await finish();
        expect(
          manager.getQueueSnapshot().single.status,
          TranscriptionStatus.error,
        );
        expect(
          manager.getQueueSnapshot().single.statusMessage,
          contains(empty ? '文件为空' : '文件不存在'),
        );
        expect(
          manager.getQueueSnapshot().single.statusMessage,
          isNot(contains('没有音轨')),
        );
        expect(asr.calls, 0);
      },
    );
  }

  for (final streams in <List<dynamic>>[
    [],
    [{}],
    [
      {'codec_type': 'unknown'},
    ],
    [
      {
        'codec_type': 'video',
        'disposition': {'attached_pic': 1},
      },
    ],
  ]) {
    test(
      'inconclusive stream metadata $streams still allows actual audio decoding',
      () async {
        await manager.shutdown();
        manager.dispose();
        manager = create(
          probe: (_) async => {
            'streams': streams,
            'format': {'duration': '1'},
          },
        );
        await manager.initialize();
        final opaqueInput = await audio.copy(
          p.join(root.path, 'opaque-media.bin'),
        );
        final item = VideoItem(
          id: 'metadata',
          path: opaqueInput.path,
          title: 'Audible',
          durationMs: 1000,
          lastUpdated: 0,
        );
        await start(item);
        await finish();
        expectSuccess();
      },
    );
  }

  test('a real video-only source still reports that it has no audio', () async {
    final video = File(p.join(root.path, 'silent.mp4'));
    final generated = await Process.run(await FFmpegUtils.ffmpegPath, [
      '-y',
      '-v',
      'error',
      '-f',
      'lavfi',
      '-i',
      'color=s=32x32:r=1',
      '-t',
      '1',
      '-an',
      '-c:v',
      'mpeg4',
      video.path,
    ]);
    expect(generated.exitCode, 0, reason: '${generated.stderr}');
    await start(
      VideoItem(
        id: 'video',
        path: video.path,
        title: 'Video',
        durationMs: 1000,
        lastUpdated: 0,
      ),
    );
    await finish();
    expect(manager.getQueueSnapshot().single.statusMessage, contains('没有音轨'));
    expect(asr.calls, 0);
  });

  test(
    'arbitrary HTTP audio is rejected before downloading processing input',
    () async {
      final path = 'http://127.0.0.1:${origin.port}/audio-without-extension';
      final item = VideoItem(
        id: 'http',
        path: path,
        title: 'HTTP audio',
        durationMs: 1000,
        lastUpdated: 0,
        type: MediaType.audio,
        sourceRef: MediaSourceRef(value: path, kind: MediaSourceKind.url),
      );
      await expectLater(start(item), throwsUnsupportedError);
      expect(requests, 0);
      expect(asr.calls, 0);
      expect(manager.getQueueSnapshot(), isEmpty);
    },
  );

  test(
    'a failed probe requires duration before starting the local model',
    () async {
      await manager.shutdown();
      manager.dispose();
      manager = create(
        probe: (path) async {
          if (path == audio.path) {
            throw const FormatException('incomplete metadata');
          }
          return {
            'streams': [
              {'codec_type': 'audio', 'codec_name': 'aac'},
            ],
            'format': {'duration': '1'},
          };
        },
      );
      await manager.initialize();
      await start(
        VideoItem(
          id: 'probe-failure',
          path: audio.path,
          title: 'Audible',
          durationMs: 1000,
          lastUpdated: 0,
          type: MediaType.audio,
        ),
      );
      await finish();
      expect(
        manager.getQueueSnapshot().single.status,
        TranscriptionStatus.error,
      );
      expect(
        manager.getQueueSnapshot().single.statusMessage,
        contains('无法确定音频时长'),
      );
      expect(
        manager.getQueueSnapshot().single.statusMessage,
        isNot(contains('没有音轨')),
      );
      expect(asr.calls, 0);
    },
  );

  test(
    'probe output waits for trailing stdout and stderr after process exit',
    () async {
      final process = _ProbeProcess();
      addTearDown(process.close);
      final collected = collectTranscriptionProbeOutput(process);
      var completed = false;
      unawaited(collected.then((_) => completed = true));
      process.stdoutEvents.add(utf8.encode('{"format":{"duration":"1"},'));
      process.stderrEvents.add(utf8.encode('probe diagnostic'));
      process.exited.complete(0);
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      process.stdoutEvents.add(
        utf8.encode('"streams":[{"codec_type":"audio"}]}'),
      );
      process.stderrEvents.add(utf8.encode(' complete'));
      await process.close();

      final output = await collected;
      expect(output.exitCode, 0);
      final metadata = jsonDecode(output.stdout as String) as Map;
      expect((metadata['format'] as Map)['duration'], '1');
      expect((metadata['streams'] as List).single['codec_type'], 'audio');
      expect(output.stderr, 'probe diagnostic complete');
      expect(process.killed, isFalse);
    },
  );

  test(
    'a probe pipe retained after exit fails with a bounded drain timeout',
    () async {
      final process = _ProbeProcess();
      addTearDown(process.close);
      final collected = collectTranscriptionProbeOutput(
        process,
        drainTimeout: const Duration(milliseconds: 20),
      );
      final failed = expectLater(collected, throwsA(isA<TimeoutException>()));
      process.stdoutEvents.add(utf8.encode('{"format":'));
      process.exited.complete(0);
      await failed;
      expect(process.killed, isTrue);
      expect(process.stdoutCancelled, isTrue);
      expect(process.stderrCancelled, isTrue);
    },
  );

  test(
    'a probe output error before exit is caught and stops its process',
    () async {
      final process = _ProbeProcess();
      addTearDown(process.close);
      final collected = collectTranscriptionProbeOutput(process);
      final failed = expectLater(collected, throwsStateError);
      process.stdoutEvents.addError(StateError('probe pipe failed'));
      await failed;
      expect(process.killed, isTrue);
      expect(process.stdoutCancelled, isTrue);
      expect(process.stderrCancelled, isTrue);
    },
  );

  test(
    'external probe cancellation still drains output and preserves the exit code',
    () async {
      final process = _ProbeProcess();
      addTearDown(process.close);
      final collected = collectTranscriptionProbeOutput(process);
      process.kill();
      process.stderrEvents.add(utf8.encode('cancelled'));
      await process.close();
      final output = await collected;
      expect(output.exitCode, -1);
      expect(output.stderr, 'cancelled');
    },
  );
}
