import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/transcription_status.dart';
import 'package:video_player_app/services/gongyi_asr_service.dart';
import 'package:video_player_app/services/public_asr_quota.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/services/transcription_reliability.dart';
import 'package:video_player_app/utils/ffmpeg_utils.dart';
import 'package:video_player_app/utils/subtitle_parser.dart';

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

class _Center extends ModelCenterService {
  _Center() {
    asrProfileId = ModelCenterService.legacyProfile.id;
  }
  @override
  Future<ModelJobSpec> captureTranscription() async => const ModelJobSpec(
    profile: ModelServiceProfile(
      id: 'gongyi',
      name: '公益接口',
      kind: TranscriptionServiceKind.gongyi,
    ),
  );
}

class _Asr extends GongyiAsrService {
  _Asr(Dio dio)
    : super(
        dio: dio,
        maxPollRiskWaits: 0,
        minimumResultQueryInterval: Duration.zero,
        resultQueryDelay: (_) async {},
      );
  int preparations = 0;
  @override
  Future<List<SubtitleItem>> transcribeAudio(
    String path, {
    bool needWordTimestamp = false,
    bool includeWordTimings = false,
    Function(double progress, String status)? onProgress,
    CancelToken? cancelToken,
    GongyiAsrTaskCheckpoint? checkpoint,
    Future<String> Function()? prepareAudio,
  }) => super.transcribeAudio(
    path,
    needWordTimestamp: needWordTimestamp,
    includeWordTimings: includeWordTimings,
    onProgress: onProgress,
    cancelToken: cancelToken,
    checkpoint: checkpoint,
    prepareAudio: prepareAudio == null
        ? null
        : () async {
            preparations++;
            return prepareAudio();
          },
  );
}

Future<void> _until(bool Function() condition) async {
  final clock = Stopwatch()..start();
  while (!condition()) {
    if (clock.elapsed > const Duration(seconds: 30)) {
      fail('Timed out waiting for transcription');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform oldPaths;
  late TranscriptionManager manager;
  late _Asr service;
  late Dio dio;
  final settings = SettingsService();
  final library = LibraryService();
  final uploads = <int, Uint8List>{};
  final types = <String>[];
  var refuseFirst = false, restrictQueries = false;
  var expireOldTask = false;
  var cueStartMs = 0;
  final queries = <String>[];
  Future<void> Function()? onFirstQuery;

  Future<File> media(String name, List<String> arguments) async {
    final file = File(p.join(root.path, name));
    final result = await Process.run(await FFmpegUtils.ffmpegPath, [
      '-y',
      '-hide_banner',
      '-loglevel',
      'error',
      ...arguments,
      file.path,
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return file;
  }

  Future<Map> probe(Uint8List bytes, String extension) async {
    final file = File(p.join(root.path, 'uploaded.$extension'));
    await file.writeAsBytes(bytes);
    final result = await Process.run(await FFmpegUtils.ffprobePath, [
      '-v',
      'error',
      '-show_streams',
      '-show_format',
      '-of',
      'json',
      file.path,
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return jsonDecode(result.stdout as String) as Map;
  }

  Future<void> run(File source) async {
    await manager.startTranscription(
      source.path,
      videoId: 'case',
      autoStart: true,
    );
    await _until(() => !manager.isQueueRunning);
  }

  void expectTemporaryAudioClean() {
    final dir = Directory(p.join(root.path, 'ai_transcription_temp_audio'));
    if (dir.existsSync()) expect(dir.listSync(), isEmpty);
  }

  String digest(List<int> bytes) => sha256.convert(bytes).toString();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings.resetForTest();
    root = await Directory.systemTemp.createTemp('gongyi-fast-audio-');
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    settings.largeDataRootPath = root.path;
    library.resetLibraryForTesting();
    await library.init();
    uploads.clear();
    types.clear();
    queries.clear();
    refuseFirst = restrictQueries = false;
    expireOldTask = false;
    cueStartMs = 0;
    onFirstQuery = null;
    dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            Object data;
            Headers? headers;
            if (options.method == 'PUT') {
              final index = int.parse(options.uri.pathSegments.last);
              uploads[index] = Uint8List.fromList(options.data as Uint8List);
              data = '';
              headers = Headers.fromMap({
                'etag': ['"uploaded"'],
              });
            } else if (options.path.endsWith('/resource/create')) {
              final body = jsonDecode(options.data as String) as Map;
              final index = types.length;
              types.add(body['ResourceFileType'] as String);
              data = {
                'code': 0,
                'data': {
                  'upload_urls': ['https://storage.test/$index'],
                  'per_size': body['size'],
                  'in_boss_key': 'boss',
                  'resource_id': '$index',
                  'upload_id': 'upload-$index',
                },
              };
            } else if (options.path.endsWith('/resource/create/complete')) {
              final index = (options.data as Map)['ResourceId'];
              data = {
                'code': 0,
                'data': {'download_url': 'https://storage.test/$index'},
              };
            } else if (options.path.endsWith('/task/result')) {
              final id = options.queryParameters['task_id'] as String;
              queries.add(id);
              if (queries.length == 1) await onFirstQuery?.call();
              if (expireOldTask && id == 'old-task') {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    type: DioExceptionType.badResponse,
                    response: Response(
                      requestOptions: options,
                      statusCode: 404,
                    ),
                  ),
                );
                return;
              }
              if (restrictQueries) {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    type: DioExceptionType.badResponse,
                    response: Response(
                      requestOptions: options,
                      statusCode: 412,
                    ),
                  ),
                );
                return;
              }
              data = refuseFirst && id == 'task-0'
                  ? {
                      'data': {'state': 5, 'remark': '不支持此音频格式'},
                    }
                  : {
                      'data': {
                        'state': 4,
                        'result': jsonEncode({
                          'utterances': [
                            {
                              'start_time': cueStartMs,
                              'end_time': cueStartMs + 1000,
                              'transcript': '音频测试成功',
                            },
                          ],
                        }),
                      },
                    };
            } else if (options.path.endsWith('/task')) {
              final uri = Uri.parse(
                (options.data as Map)['resource'] as String,
              );
              data = {
                'code': 0,
                'data': {'task_id': 'task-${uri.pathSegments.last}'},
              };
            } else {
              handler.reject(
                DioException(
                  requestOptions: options,
                  error: StateError('Unexpected request ${options.path}'),
                ),
              );
              return;
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
    service = _Asr(dio);
    manager = TranscriptionManager(
      settings: settings,
      asrService: service,
      modelCenter: _Center(),
    );
    await manager.initialize();
  });
  tearDown(() async {
    await manager.shutdown();
    manager.dispose();
    dio.close(force: true);
    library.resetLibraryForTesting();
    settings.resetForTest();
    PathProviderPlatform.instance = oldPaths;
    await root.delete(recursive: true);
  });

  test(
    'quota stops new uploads, pauses following public jobs and preserves retry',
    () async {
      final source = await media('quota.mp3', [
        '-f',
        'lavfi',
        '-i',
        'sine=sample_rate=16000',
        '-t',
        '3',
        '-c:a',
        'libmp3lame',
      ]);
      final second = await source.copy(p.join(root.path, 'quota-second.mp3'));
      final third = await source.copy(p.join(root.path, 'quota-third.mp3'));
      var clock = DateTime.utc(2026, 11, 6);
      final quota = PublicAsrQuota(
        directory: () async => root,
        now: () => clock,
        allowance: const Duration(seconds: 5),
      );
      await manager.shutdown();
      manager.dispose();
      manager = TranscriptionManager(
        settings: settings,
        asrService: service,
        modelCenter: _Center(),
        publicAsrQuota: quota,
      );
      await manager.initialize();
      for (final item in [
        ('first', source),
        ('second', second),
        ('third', third),
      ]) {
        await manager.startTranscription(item.$2.path, videoId: item.$1);
      }
      manager.startAllTasks();
      await _until(() => !manager.isQueueRunning);
      final states = {
        for (final task in manager.getQueueSnapshot()) task.mediaKey: task,
      };
      expect(states['id:first']!.status, TranscriptionStatus.completed);
      expect(states['id:second']!.status, TranscriptionStatus.error);
      expect(states['id:second']!.statusMessage, contains('额度不足'));
      expect(states['id:third']!.isStarted, isFalse);
      expect(types, ['mp3']);
      clock = clock.add(const Duration(hours: 5));
      expect(manager.retryTask('id:second'), isTrue);
      await _until(() => !manager.isQueueRunning);
      expect(
        manager
            .getQueueSnapshot()
            .firstWhere((t) => t.mediaKey == 'id:second')
            .status,
        TranscriptionStatus.completed,
      );
      expect(types, ['mp3', 'mp3']);
      expectTemporaryAudioClean();
    },
    skip: !FFmpegUtils.preferSystemFfmpeg,
  );

  test(
    'quota stops new uploads but drains a submitted slice before returning the limit',
    () async {
      cueStartMs = 13000;
      final seed = await media('quota-resume-seed.mp3', [
        '-f',
        'lavfi',
        '-i',
        'sine=sample_rate=16000',
        '-t',
        '1',
        '-c:a',
        'libmp3lame',
        '-b:a',
        '32k',
      ]);
      final source = await media('quota-resume.mp3', [
        '-stream_loop',
        '-1',
        '-i',
        seed.path,
        '-t',
        '661',
        '-c:a',
        'copy',
      ]);
      var clock = DateTime.utc(2026, 11, 6);
      final quota = PublicAsrQuota(
        directory: () async => root,
        now: () => clock,
        allowance: const Duration(seconds: 610),
      );
      await manager.shutdown();
      manager.dispose();
      manager = TranscriptionManager(
        settings: settings,
        asrService: service,
        modelCenter: _Center(),
        publicAsrQuota: quota,
      );
      await manager.initialize();
      final checkpoints = File(
        p.join(root.path, 'transcription_slice_checkpoints.json'),
      );
      onFirstQuery = () async {
        await _until(() {
          try {
            final saved = TranscriptionCheckpointBook.decode(
              checkpoints.readAsStringSync(),
            );
            return saved.tasks.values.single.remoteTasks.values.any(
              (task) => task.taskId == null && task.usageReservationId != null,
            );
          } on FileSystemException {
            return false;
          }
        });
        await Future<void>.delayed(const Duration(milliseconds: 30));
      };
      await run(source);
      expect(
        manager.getQueueSnapshot().single.status,
        TranscriptionStatus.error,
      );
      expect(manager.getQueueSnapshot().single.statusMessage, contains('额度不足'));
      final saved = TranscriptionCheckpointBook.decode(
        await checkpoints.readAsString(),
      );
      expect(saved.tasks.values.single.pieces.single.startMs, 0);
      expect(types, ['mp3']);
      expectTemporaryAudioClean();
      clock = clock.add(const Duration(hours: 5));
      expect(manager.retryTask('id:case'), isTrue);
      await _until(() => !manager.isQueueRunning);
      expect(
        manager.getQueueSnapshot().single.status,
        TranscriptionStatus.completed,
        reason: manager.statusMessage,
      );
      expect(types, ['mp3', 'mp3']);
      expect(queries, ['task-0', 'task-1']);
      expectTemporaryAudioClean();
    },
    skip: !FFmpegUtils.preferSystemFfmpeg,
  );

  test(
    'AAC is prepared as bounded MP3 slices and its source stays intact',
    () async {
      final seed = await media('seed.m4a', [
        '-f',
        'lavfi',
        '-i',
        'sine=sample_rate=44100',
        '-t',
        '1',
        '-ac',
        '2',
        '-c:a',
        'aac',
        '-b:a',
        '96k',
      ]);
      final source = await media('long.m4a', [
        '-stream_loop',
        '-1',
        '-i',
        seed.path,
        '-t',
        '661',
        '-c:a',
        'copy',
      ]);
      final original = digest(await source.readAsBytes());
      await run(source);
      expect(
        manager.getQueueSnapshot().single.status,
        TranscriptionStatus.completed,
        reason: manager.statusMessage,
      );
      expect(digest(uploads[0]!), isNot(original));
      expect(digest(await source.readAsBytes()), original);
      expect(types, ['mp3', 'mp3']);
      final first = await probe(uploads[0]!, 'mp3');
      final second = await probe(uploads[1]!, 'mp3');
      expect(
        double.parse((first['format'] as Map)['duration'] as String),
        closeTo(600, .2),
      );
      expect(
        double.parse((second['format'] as Map)['duration'] as String),
        closeTo(71, .2),
      );
      expectTemporaryAudioClean();
    },
    skip: !FFmpegUtils.preferSystemFfmpeg,
  );

  test(
    'MP3 uploads unchanged and declares its real container',
    () async {
      final source = await media('original.mp3', [
        '-f',
        'lavfi',
        '-i',
        'sine=sample_rate=44100',
        '-t',
        '3',
        '-ac',
        '2',
        '-c:a',
        'libmp3lame',
        '-b:a',
        '128k',
      ]);
      await run(source);
      expect(
        manager.getQueueSnapshot().single.status,
        TranscriptionStatus.completed,
        reason: manager.statusMessage,
      );
      expect(digest(uploads[0]!), digest(await source.readAsBytes()));
      expect(types, ['mp3']);
      expectTemporaryAudioClean();
    },
    skip: !FFmpegUtils.preferSystemFfmpeg,
  );

  test(
    'video prepares speech MP3 while leaving source media intact',
    () async {
      final source = await media('video.mp4', [
        '-f',
        'lavfi',
        '-i',
        'color=size=16x16:rate=1',
        '-f',
        'lavfi',
        '-i',
        'sine=sample_rate=44100',
        '-t',
        '3',
        '-c:v',
        'mpeg4',
        '-c:a',
        'aac',
        '-ac',
        '2',
        '-b:a',
        '96k',
      ]);
      final original = digest(await source.readAsBytes());
      await run(source);
      expect(
        manager.getQueueSnapshot().single.status,
        TranscriptionStatus.completed,
        reason: manager.statusMessage,
      );
      final result = await probe(uploads[0]!, 'mp3');
      final stream = (result['streams'] as List).single as Map;
      expect(stream['codec_name'], 'mp3');
      expect(stream['sample_rate'], '16000');
      expect(stream['channels'], 1);
      expect(
        double.parse((result['format'] as Map)['duration'] as String),
        closeTo(3, .1),
      );
      expect(digest(await source.readAsBytes()), original);
      expectTemporaryAudioClean();
    },
    skip: !FFmpegUtils.preferSystemFfmpeg,
  );

  test(
    'unsupported audio uses speech MP3 encoding',
    () async {
      final source = await media('lossless.flac', [
        '-f',
        'lavfi',
        '-i',
        'sine=sample_rate=48000',
        '-t',
        '3',
        '-ac',
        '2',
      ]);
      final original = digest(await source.readAsBytes());
      await run(source);
      expect(
        manager.getQueueSnapshot().single.status,
        TranscriptionStatus.completed,
        reason: manager.statusMessage,
      );
      final result = await probe(uploads[0]!, 'mp3');
      final stream = (result['streams'] as List).single as Map;
      expect(stream['codec_name'], 'mp3');
      expect(stream['sample_rate'], '16000');
      expect(stream['channels'], 1);
      expect(digest(await source.readAsBytes()), original);
      expectTemporaryAudioClean();
    },
    skip: !FFmpegUtils.preferSystemFfmpeg,
  );

  test(
    'a terminal format rejection falls back once and cleans both attempts',
    () async {
      refuseFirst = true;
      final source = await media('fallback.mp3', [
        '-f',
        'lavfi',
        '-i',
        'sine=sample_rate=44100',
        '-t',
        '3',
        '-ac',
        '2',
        '-c:a',
        'libmp3lame',
        '-b:a',
        '128k',
      ]);
      await run(source);
      expect(
        manager.getQueueSnapshot().single.status,
        TranscriptionStatus.completed,
        reason: manager.statusMessage,
      );
      expect(types, ['mp3', 'mp3']);
      expect(digest(uploads[0]!), digest(await source.readAsBytes()));
      final result = await probe(uploads[1]!, 'mp3');
      final stream = (result['streams'] as List).single as Map;
      expect(stream['sample_rate'], '16000');
      expect(stream['channels'], 1);
      expect(service.preparations, 2);
      expectTemporaryAudioClean();
    },
    skip: !FFmpegUtils.preferSystemFfmpeg,
  );

  test(
    'query restriction and queue restart never prepare or upload again',
    () async {
      PublicAsrQuota quota() => PublicAsrQuota(
        directory: () async => Directory(p.join(root.path, 'public_asr_usage')),
        allowance: const Duration(seconds: 3),
      );
      await manager.shutdown();
      manager.dispose();
      manager = TranscriptionManager(
        settings: settings,
        asrService: service,
        modelCenter: _Center(),
        publicAsrQuota: quota(),
      );
      await manager.initialize();
      restrictQueries = true;
      final source = await media('resume.flac', [
        '-f',
        'lavfi',
        '-i',
        'sine=sample_rate=48000',
        '-t',
        '3',
        '-ac',
        '2',
      ]);
      await run(source);
      expect(
        manager.getQueueSnapshot().single.status,
        TranscriptionStatus.error,
      );
      expect(service.preparations, 1);
      expect(types, ['mp3']);
      expectTemporaryAudioClean();
      await expectLater(
        quota().check(duration: const Duration(seconds: 1)),
        throwsA(isA<PublicAsrQuotaException>()),
      );
      await manager.shutdown();
      manager.dispose();
      restrictQueries = false;
      manager = TranscriptionManager(
        settings: settings,
        asrService: service,
        modelCenter: _Center(),
        publicAsrQuota: quota(),
      );
      await manager.initialize();
      manager.retryTask('id:case');
      await _until(() => !manager.isQueueRunning);
      expect(
        manager.getQueueSnapshot().single.status,
        TranscriptionStatus.completed,
        reason: manager.statusMessage,
      );
      expect(queries, ['task-0', 'task-0']);
      expect(service.preparations, 1);
      expect(types, ['mp3']);
      expectTemporaryAudioClean();
    },
    skip: !FFmpegUtils.preferSystemFfmpeg,
  );

  test(
    'resumed fast audio can still fall back after its file was cleaned',
    () async {
      restrictQueries = true;
      final source = await media('resumed.mp3', [
        '-f',
        'lavfi',
        '-i',
        'sine=sample_rate=44100',
        '-t',
        '3',
        '-ac',
        '2',
        '-c:a',
        'libmp3lame',
        '-b:a',
        '128k',
      ]);
      await run(source);
      expect(
        manager.getQueueSnapshot().single.status,
        TranscriptionStatus.error,
      );
      expect(types, ['mp3']);
      expect(service.preparations, 1);
      await manager.shutdown();
      manager.dispose();
      restrictQueries = false;
      refuseFirst = true;
      manager = TranscriptionManager(
        settings: settings,
        asrService: service,
        modelCenter: _Center(),
      );
      await manager.initialize();
      manager.retryTask('id:case');
      await _until(() => !manager.isQueueRunning);
      expect(
        manager.getQueueSnapshot().single.status,
        TranscriptionStatus.completed,
        reason: manager.getQueueSnapshot().single.statusMessage,
      );
      expect(types, ['mp3', 'mp3']);
      expect(service.preparations, 2);
      expectTemporaryAudioClean();
    },
    skip: !FFmpegUtils.preferSystemFfmpeg,
  );

  test(
    'long MP3 uploads ten-minute windows with context and preserves its timeline',
    () async {
      cueStartMs = 13000;
      final seed = await media('seed.mp3', [
        '-f',
        'lavfi',
        '-i',
        'sine=sample_rate=32000',
        '-t',
        '1',
        '-ac',
        '1',
        '-c:a',
        'libmp3lame',
        '-b:a',
        '64k',
      ]);
      final source = await media('long.mp3', [
        '-stream_loop',
        '-1',
        '-i',
        seed.path,
        '-t',
        '4260',
        '-c:a',
        'copy',
      ]);
      var sawParallel = false;
      onFirstQuery = () async {
        await _until(() => types.length == 3);
        expect(types, List.filled(3, 'mp3'));
        sawParallel = true;
      };
      await run(source);
      expect(
        manager.getQueueSnapshot().single.status,
        TranscriptionStatus.completed,
        reason: manager.getQueueSnapshot().single.statusMessage,
      );
      expect(sawParallel, isTrue);
      expect(types, List.filled(8, 'mp3'));
      expect(service.preparations, 8);
      final first = await probe(uploads[0]!, 'mp3');
      final stream = (first['streams'] as List).single as Map;
      expect(stream['codec_name'], 'mp3');
      expect(stream['sample_rate'], '32000');
      expect(stream['channels'], 1);
      expect(
        double.parse((first['format'] as Map)['duration'] as String),
        closeTo(600, .1),
      );
      final second = await probe(uploads[1]!, 'mp3');
      expect(
        double.parse((second['format'] as Map)['duration'] as String),
        closeTo(600, .2),
      );
      final third = await probe(uploads[7]!, 'mp3');
      expect(
        double.parse((third['format'] as Map)['duration'] as String),
        closeTo(130, .2),
      );
      final output = manager.getGeneratedSrtPathForVideo(
        source.path,
        videoId: 'case',
      );
      final cues = SubtitleParser.parse(await File(output!).readAsString());
      expect(cues, hasLength(8));
      for (var i = 0; i < cues.length; i++) {
        expect(cues[i].startTime, Duration(seconds: i * 590 + 13));
      }
      expectTemporaryAudioClean();
    },
    skip: !FFmpegUtils.preferSystemFfmpeg,
  );

  test(
    'a concurrent restriction preserves every submitted ID and restarts without uploads',
    () async {
      cueStartMs = 13000;
      final seed = await media('resume-seed.mp3', [
        '-f',
        'lavfi',
        '-i',
        'sine=sample_rate=16000',
        '-t',
        '1',
        '-c:a',
        'libmp3lame',
        '-b:a',
        '32k',
      ]);
      final source = await media('parallel-resume.mp3', [
        '-stream_loop',
        '-1',
        '-i',
        seed.path,
        '-t',
        '1260',
        '-c:a',
        'copy',
      ]);
      final checkpointFile = File(
        p.join(root.path, 'transcription_slice_checkpoints.json'),
      );
      bool allSubmitted() {
        try {
          final book = TranscriptionCheckpointBook.decode(
            checkpointFile.readAsStringSync(),
          );
          final remotes = book.tasks.values.single.remoteTasks.values;
          return remotes.length == 3 &&
              remotes.every((task) => task.taskId != null);
        } on FileSystemException {
          return false;
        }
      }

      restrictQueries = true;
      onFirstQuery = () => _until(allSubmitted);
      await run(source);
      expect(
        manager.getQueueSnapshot().single.status,
        TranscriptionStatus.error,
      );
      expect(types, List.filled(3, 'mp3'));
      final firstQueries = queries.length;
      expect(firstQueries, inInclusiveRange(1, 3));
      final book = TranscriptionCheckpointBook.decode(
        await checkpointFile.readAsString(),
      );
      final remotes = book.tasks.values.single.remoteTasks.values.toList();
      expect(remotes, hasLength(3));
      expect(remotes.every((task) => task.taskId != null), isTrue);
      expect(
        remotes.every(
          (task) =>
              task.queryNotBefore!.difference(DateTime.now()) >
              const Duration(seconds: 58),
        ),
        isTrue,
      );
      expectTemporaryAudioClean();
      await manager.shutdown();
      manager.dispose();
      restrictQueries = false;
      manager = TranscriptionManager(
        settings: settings,
        asrService: service,
        modelCenter: _Center(),
      );
      await manager.initialize();
      expect(manager.retryTask('id:case'), isTrue);
      await _until(() => !manager.isQueueRunning);
      expect(
        manager.getQueueSnapshot().single.status,
        TranscriptionStatus.completed,
        reason: manager.statusMessage,
      );
      expect(types, List.filled(3, 'mp3'));
      expect(service.preparations, 3);
      expect(
        queries.skip(firstQueries),
        unorderedEquals(remotes.map((task) => task.taskId)),
      );
      expectTemporaryAudioClean();
    },
    skip: !FFmpegUtils.preferSystemFfmpeg,
  );

  test(
    'missing duration metadata never truncates a low bitrate source',
    () async {
      final source = await media('unknown-duration.webm', [
        '-f',
        'lavfi',
        '-i',
        'sine=sample_rate=48000',
        '-t',
        '8',
        '-c:a',
        'libopus',
        '-b:a',
        '12k',
        '-f',
        'webm',
        '-live',
        '1',
      ]);
      final metadata = await Process.run(await FFmpegUtils.ffprobePath, [
        '-v',
        'error',
        '-show_format',
        '-of',
        'json',
        source.path,
      ]);
      expect(
        (jsonDecode(metadata.stdout as String) as Map)['format']['duration'],
        isNull,
        reason: 'This fixture must exercise genuinely missing duration.',
      );
      final original = digest(await source.readAsBytes());
      await run(source);
      expect(
        manager.getQueueSnapshot().single.status,
        TranscriptionStatus.completed,
        reason: manager.getQueueSnapshot().single.statusMessage,
      );
      expect(types, ['mp3']);
      final result = await probe(uploads[0]!, 'mp3');
      expect(
        double.parse((result['format'] as Map)['duration'] as String),
        closeTo(8, .1),
      );
      expect((result['streams'] as List).single['sample_rate'], '16000');
      expect(digest(await source.readAsBytes()), original);
      expectTemporaryAudioClean();
    },
    skip: !FFmpegUtils.preferSystemFfmpeg,
  );

  for (final expired in [false, true]) {
    test(
      expired
          ? 'expired hour-long tasks are replaced by ten-minute uploads'
          : 'saved hour-long tasks resume without any local preparation or upload',
      () async {
        cueStartMs = 3000;
        final source = await media('legacy.m4a', [
          '-f',
          'lavfi',
          '-i',
          'anullsrc=r=8000:cl=mono',
          '-t',
          '3600',
          '-c:a',
          'aac',
          '-b:a',
          '24k',
        ]);
        await manager.startTranscription(
          source.path,
          videoId: 'case',
          autoStart: false,
        );
        await manager.shutdown();
        manager.dispose();
        final queue =
            jsonDecode(
                  await File(
                    p.join(root.path, 'transcription_queue_cache.json'),
                  ).readAsString(),
                )
                as Map;
        final job = (queue['queue'] as List).single as Map;
        final key = 'id:case\nrun:${job['checkpointScope']}';
        final stat = await source.stat();
        final checkpoint = TranscriptionTaskCheckpoint.empty(
          stat.size,
          stat.modified.millisecondsSinceEpoch,
        );
        checkpoint.remoteTasks['0:3600000:words'] = GongyiAsrTaskCheckpoint(
          taskId: 'old-task',
        );
        await File(
          p.join(root.path, 'transcription_slice_checkpoints.json'),
        ).writeAsString(
          TranscriptionCheckpointBook(tasks: {key: checkpoint}).encode(),
        );
        expireOldTask = expired;
        manager = TranscriptionManager(
          settings: settings,
          asrService: service,
          modelCenter: _Center(),
        );
        await manager.initialize();
        manager.startTask('id:case');
        await _until(() => !manager.isQueueRunning);
        expect(
          manager.getQueueSnapshot().single.status,
          TranscriptionStatus.completed,
          reason: manager.getQueueSnapshot().single.statusMessage,
        );
        expect(queries.first, 'old-task');
        expect(types, expired ? List.filled(7, 'mp3') : isEmpty);
        expect(service.preparations, expired ? 8 : 0);
        for (final bytes in uploads.values) {
          final metadata = await probe(bytes, 'mp3');
          expect(
            double.parse((metadata['format'] as Map)['duration'] as String),
            lessThanOrEqualTo(600.2),
          );
        }
        expectTemporaryAudioClean();
      },
      skip: !FFmpegUtils.preferSystemFfmpeg,
    );
  }

  test(
    'pausing result polling drains concurrent slices and cleans temporary audio',
    () async {
      final source = await media('pause-prefetch.m4a', [
        '-f',
        'lavfi',
        '-i',
        'anullsrc=r=8000:cl=mono',
        '-t',
        '3600',
        '-c:a',
        'aac',
        '-b:a',
        '24k',
      ]);
      var paused = false;
      onFirstQuery = () async {
        final temp = Directory(
          p.join(root.path, 'ai_transcription_temp_audio'),
        );
        await _until(() => temp.listSync().whereType<File>().length >= 2);
        paused = manager.pauseTask('id:case');
      };
      await run(source);
      expect(paused, isTrue);
      expect(types.length, inInclusiveRange(1, 3));
      expect(uploads.length, inInclusiveRange(1, 3));
      expect(
        manager.getQueueSnapshot().single.status,
        TranscriptionStatus.idle,
      );
      expectTemporaryAudioClean();
    },
    skip: !FFmpegUtils.preferSystemFfmpeg,
  );

  test(
    'stopping preparation leaves no upload or temporary audio',
    () async {
      final source = await media('cancel.flac', [
        '-f',
        'lavfi',
        '-i',
        'sine=sample_rate=48000',
        '-t',
        '3',
        '-ac',
        '2',
      ]);
      var paused = false;
      manager.addListener(() {
        if (!paused && manager.statusMessage.contains('准备音频')) {
          paused = true;
          manager.pauseTask('id:case');
        }
      });
      await run(source);
      expect(paused, isTrue);
      expect(types, isEmpty);
      expect(uploads, isEmpty);
      expect(source.existsSync(), isTrue);
      expectTemporaryAudioClean();
    },
    skip: !FFmpegUtils.preferSystemFfmpeg,
  );
}
