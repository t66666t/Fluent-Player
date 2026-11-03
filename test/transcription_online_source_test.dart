import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/media_cache/media_cache_hooks.dart';
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
import 'package:video_player_app/models/subtitle_punctuation.dart';
import 'package:video_player_app/models/transcription_status.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/ai_subtitle_api_settings.dart';
import 'package:video_player_app/services/ai_subtitle_translator.dart';
import 'package:video_player_app/services/gongyi_asr_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_materialization_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/utils/ffmpeg_utils.dart';
import 'package:video_player_app/widgets/ai_transcription_panel.dart';

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

class _LegacyCenter extends ModelCenterService {
  _LegacyCenter() {
    loaded = true;
  }
  @override
  Future<void> initialize() async {}
}

class _Asr extends GongyiAsrService {
  int calls = 0;
  @override
  Future<List<SubtitleItem>> transcribeAudio(
    String audioPath, {
    bool needWordTimestamp = false,
    bool includeWordTimings = false,
    Function(double progress, String status)? onProgress,
    CancelToken? cancelToken,
    GongyiAsrTaskCheckpoint? checkpoint,
    Future<String> Function()? prepareAudio,
  }) async {
    calls++;
    final input = prepareAudio == null ? audioPath : await prepareAudio();
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
    return [
      SubtitleItem(
        index: 1,
        startTime: Duration.zero,
        endTime: const Duration(milliseconds: 800),
        text: 'An audible episode',
      ),
    ];
  }
}

class _Translation extends SubtitleTranslationService {
  int calls = 0;
  @override
  Future<SubtitleTranslationResult> translateSubtitleFile({
    required String inputPath,
    String? sourceText,
    SubtitlePunctuation outputPunctuation = SubtitlePunctuation.preserve,
    required String sourceLanguage,
    required String targetLanguage,
    required SubtitleTranslateProvider provider,
    required void Function(double) onProgress,
    void Function(String?)? onActivity,
    String? outputDirectory,
    String? outputFilePrefix,
    String? videoPath,
    AiSubtitleTranslationSettings? aiOptions,
    AiSubtitleApiSettings? aiEndpoint,
    Future<void>? cancelSignal,
    ModelJobSpec? localSpecification,
    String checkpointScope = '',
    SmartTranslationPolicy? smartPolicy,
  }) async {
    calls++;
    final file = File(
      p.join(outputDirectory!, '$outputFilePrefix.translated.srt'),
    );
    await file.writeAsString('1\n00:00:00,000 --> 00:00:00,800\n能听见的节目\n');
    return SubtitleTranslationResult(outputPath: file.path, totalCount: 1);
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
    asrService: asr,
    translationService: translation,
    mediaProbe: probe,
    modelCenter: modelCenter,
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
    await library.init();
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
  void expectSuccess() {
    expect(
      manager.getQueueSnapshot().single.status,
      TranscriptionStatus.completed,
      reason: manager.getQueueSnapshot().single.statusMessage,
    );
    expect(asr.calls, 1);
  }

  test(
    'auto-advanced queue projection transcribes and translates without switching episodes',
    () async {
      expect(library.getVideo(selected.id), isNull);
      await start(selected, translate: true);
      await finish();
      expectSuccess();
      expect(translation.calls, 1);
      expect(requests, 1);
      expect(runtime.persistedEpisodeIds, [selected.id]);
      expect(library.getVideo(next.id), isNull);
      final saved = library.getVideo(selected.id)!;
      expect(saved.subtitlePath, isNotNull);
      expect(saved.secondarySubtitlePath, isNotNull);
      expect(
        await File(saved.secondarySubtitlePath!).readAsString(),
        contains('能听见'),
      );
    },
  );

  test(
    'queued source is frozen when the player advances and mutates its item',
    () async {
      final path = selected.path, id = selected.id;
      await start(selected, run: false);
      selected
        ..path = next.path
        ..sourceRef = next.sourceRef
        ..title = next.title;
      manager.startAllTasks();
      await finish();
      expectSuccess();
      expect(
        controller.mediaStore.isDownloaded(
          id,
          store.episode(id)!.media.first.url,
        ),
        isTrue,
      );
      expect(
        controller.mediaStore.isDownloaded(
          next.id,
          store.episode(next.id)!.media.first.url,
        ),
        isFalse,
      );
      expect(manager.getGeneratedSrtPathForVideo(path, videoId: id), isNotNull);
    },
  );

  test(
    'source survives task persistence without a library row or catalog recovery hook',
    () async {
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

  test('legacy jobs recover their podcast source from the catalog', () async {
    PodcastPlaybackHooks.restoreSource = runtime.restoreSource;
    await start(selected, capture: false, run: false);
    await manager.shutdown();
    manager.dispose();
    manager = create();
    await manager.initialize();
    manager.startAllTasks();
    await finish();
    expectSuccess();
    expect(requests, 1);
  });

  test('an incomplete podcast source is repaired from the catalog', () async {
    PodcastPlaybackHooks.restoreSource = runtime.restoreSource;
    selected.sourceRef = null;
    await start(selected);
    await finish();
    expectSuccess();
    expect(requests, 1);
  });

  test(
    'a library-backed queued source survives removal of its library row',
    () async {
      library.seedVideoForTesting(selected);
      await start(selected, capture: false, run: false);
      library.resetLibraryForTesting();
      await library.init();
      expect(library.getVideo(selected.id), isNull);
      manager.startAllTasks();
      await finish();
      expectSuccess();
    },
  );

  test(
    'an old failed task can attach the current source and retry without switching',
    () async {
      PodcastPlaybackHooks.restoreSource = null;
      await start(selected, capture: false);
      await finish();
      expect(
        manager.getQueueSnapshot().single.status,
        TranscriptionStatus.error,
      );
      expect(
        manager.getQueueSnapshot().single.statusMessage,
        contains('来源尚未准备'),
      );
      expect(
        manager.getQueueSnapshot().single.statusMessage,
        isNot(contains('没有音轨')),
      );
      expect(asr.calls, 0);
      manager.updateSourceForVideo(
        selected.path,
        videoId: selected.id,
        sourceItem: selected,
      );
      manager.retryVideo(selected.path, videoId: selected.id);
      await finish();
      expectSuccess();
    },
  );

  test(
    'a late callback cannot attach the next episode to an older job',
    () async {
      PodcastPlaybackHooks.restoreSource = null;
      await start(selected, capture: false, run: false);
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
      await start(selected, capture: false, run: false);
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

  test('a source cleanup failure cannot stop the remaining transcription queue', () async {
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
    expect(released, 2);
    expect(manager.getQueueSnapshot().map((task) => task.status), [
      TranscriptionStatus.completed,
      TranscriptionStatus.completed,
    ]);
  });

  for (final cloud in [false, true]) {
    test(
      'unregistered ${cloud ? 'cloud' : 'Bilibili'} media uses its captured source and releases its lease',
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
        var acquired = 0, released = 0;
        MediaCacheHooks.acquireMaterial =
            (
              source,
              requirement, {
              targetHeight,
              qualityId,
              codec,
              isolatedTrack = false,
            }) async {
              expect(source.sourceRef?.kind, item.sourceRef?.kind);
              acquired++;
              return MaterializedMediaLease(
                videoId: source.id,
                audioPath: audio.path,
                videoPath: null,
                completePath: null,
                qualityId: null,
                width: null,
                height: null,
                onRelease: () async {
                  released++;
                },
              );
            };
        expect(library.getVideo(item.id), isNull);
        await start(item);
        await finish();
        expectSuccess();
        expect(acquired, 1);
        expect(released, 1);
      },
    );
  }

  for (final translate in [false, true]) {
    testWidgets(
      'transcribing P1 keeps other playback parts out of the task queue '
      '(translate=$translate)',
      (tester) async {
        VideoItem part(int page, {required bool transient}) => VideoItem(
          id: 'bili-p$page',
          path: 'bilibili://stream/BV1xx411c7mD?cid=${1000 + page}',
          title: 'Video · P$page Part $page',
          durationMs: 1000,
          lastUpdated: 0,
          isTransient: transient,
          sourceRef: MediaSourceRef(
            value: 'BV1xx411c7mD',
            kind: MediaSourceKind.bilibiliStream,
            bvid: 'BV1xx411c7mD',
            cid: 1000 + page,
            page: page,
          ),
        );
        final p1 = part(1, transient: false);
        final otherParts = [part(2, transient: true), part(3, transient: true)];
        final center = _LegacyCenter();
        addTearDown(center.dispose);
        await tester.runAsync(() async {
          await manager.shutdown();
          manager.dispose();
          manager = create(modelCenter: center);
          await manager.initialize();
          await library.addSingleVideo(p1, reuseExistingItem: false);
          await library.addTransientVideos(otherParts);
        });
        var acquired = 0, released = 0;
        MediaCacheHooks.acquireMaterial =
            (
              source,
              requirement, {
              targetHeight,
              qualityId,
              codec,
              isolatedTrack = false,
            }) async {
              expect(source.id, p1.id);
              expect(source.sourceRef?.cid, 1001);
              expect(source.sourceRef?.page, 1);
              expect(requirement, MediaMaterializationRequirement.audioOnly);
              acquired++;
              return MaterializedMediaLease(
                videoId: source.id,
                audioPath: audio.path,
                videoPath: null,
                completePath: null,
                qualityId: null,
                width: null,
                height: null,
                onRelease: () async {
                  released++;
                },
              );
            };
        final seenTaskIds = <String?>{};
        void recordTasks() {
          seenTaskIds.addAll(
            manager.getQueueSnapshot().map((task) => task.videoId),
          );
        }

        manager.addListener(recordTasks);
        try {
          await tester.pumpWidget(
            MultiProvider(
              providers: [
                ChangeNotifierProvider<LibraryService>.value(value: library),
                ChangeNotifierProvider<SettingsService>.value(value: settings),
                ChangeNotifierProvider<TranscriptionManager>.value(
                  value: manager,
                ),
              ],
              child: MaterialApp(
                home: Scaffold(
                  body: AiTranscriptionPanel(
                    videoPath: p1.path,
                    videoId: p1.id,
                    sourceItem: p1,
                    onCompleted: (_) {},
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          final action = find.byKey(
            ValueKey(
              translate
                  ? 'ai-transcription-translate-action'
                  : 'ai-transcription-action',
            ),
          );
          await tester.ensureVisible(action);
          await tester.runAsync(() async {
            await tester.tap(action);
            await finish();
          });
          await tester.pump();
          expectSuccess();
          expect(seenTaskIds, {p1.id});
          expect(manager.getQueueSnapshot().single.videoId, p1.id);
          expect(acquired, 1);
          expect(released, 1);
          expect(translation.calls, translate ? 1 : 0);
          expect(library.bilibiliStreamItems.map((item) => item.id), [p1.id]);
          expect(otherParts.every((item) => item.isTransient), isTrue);
          expect(otherParts.every((item) => item.subtitlePath == null), isTrue);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          manager.removeListener(recordTasks);
        }
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
    'HTTP audio is decoded as a remote input rather than a missing local file',
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
      await start(item);
      await finish();
      expectSuccess();
      expect(requests, greaterThanOrEqualTo(1));
    },
  );

  test(
    'a failed probe still allows full decoding of an audible input',
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
      expectSuccess();
    },
  );
}
