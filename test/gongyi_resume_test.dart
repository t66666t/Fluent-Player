import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/gongyi_asr_service.dart';

void main() {
  late File audio;
  late Dio dio;
  final parts = <int, int>{};
  final queries = <String>[];
  String? missingMessage;
  var authorizations = 0,
      tasks = 0,
      failPartOnce = false,
      expireOldTask = false,
      failTask = false;
  setUp(() async {
    final root = await Directory.systemTemp.createTemp('gongyi-resume-');
    audio = File('${root.path}/audio.m4a')
      ..writeAsBytesSync(List.generate(10, (i) => i));
    addTearDown(() => root.delete(recursive: true));
    parts.clear();
    queries.clear();
    authorizations = tasks = 0;
    failPartOnce = expireOldTask = failTask = false;
    missingMessage = null;
    dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            Object data;
            Headers? headers;
            if (options.method == 'PUT') {
              final index = int.parse(
                Uri.parse(options.path).pathSegments.last,
              );
              parts.update(index, (n) => n + 1, ifAbsent: () => 1);
              if (failPartOnce && index == 1 && parts[index] == 1) {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    type: DioExceptionType.connectionError,
                  ),
                );
                return;
              }
              data = <String, Object?>{};
              headers = Headers.fromMap({
                'etag': ['"part-$index"'],
              });
            } else if (options.path.endsWith('/resource/create')) {
              authorizations++;
              data = {
                'code': 0,
                'data': {
                  'upload_urls': List.generate(
                    3,
                    (i) => 'https://storage.test/$i',
                  ),
                  'per_size': 4,
                  'in_boss_key': 'boss',
                  'resource_id': 'resource',
                  'upload_id': 'upload',
                },
              };
            } else if (options.path.endsWith('/resource/create/complete')) {
              expect((options.data as Map)['Etags'], 'part-0,part-1,part-2');
              data = {
                'code': 0,
                'data': {'download_url': 'https://storage.test/audio'},
              };
            } else if (options.path.endsWith('/task/result')) {
              final task = options.queryParameters['task_id'].toString();
              queries.add(task);
              if (expireOldTask && task == 'old-task') {
                if (missingMessage != null) {
                  handler.resolve(
                    Response(
                      requestOptions: options,
                      statusCode: 200,
                      data: {'code': 139201, 'message': missingMessage},
                    ),
                  );
                  return;
                }
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
              data = {
                'code': 0,
                'data': failTask
                    ? {'state': 5, 'message': '音频时长超过限制'}
                    : {
                        'state': 4,
                        'result': jsonEncode({
                          'utterances': [
                            {
                              'start_time': 0,
                              'end_time': 1000,
                              'transcript': '识别完成',
                            },
                          ],
                        }),
                      },
              };
            } else {
              tasks++;
              data = {
                'code': 0,
                'data': {'task_id': 'new-task'},
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
    addTearDown(() => dio.close(force: true));
  });

  test(
    'a disconnected upload retries only the failed part and preserves successful ETags',
    () async {
      failPartOnce = true;
      final messages = <String>[];
      final result =
          await GongyiAsrService(
            dio: dio,
            uploadRetryDelays: const [Duration.zero],
          ).transcribeAudio(
            audio.path,
            onProgress: (_, message) => messages.add(message),
          );
      expect(result.single.text, '识别完成');
      expect(parts, {0: 1, 1: 2, 2: 1});
      expect(authorizations, 1);
      expect(tasks, 1);
      expect(messages.any((m) => m.contains('正在重试这一块')), isTrue);
    },
  );

  test(
    'cancelling after submission and restoring its checkpoint queries without uploading again',
    () async {
      final token = CancelToken();
      String? persisted;
      final checkpoint = GongyiAsrTaskCheckpoint();
      checkpoint.onChanged = () async {
        persisted = jsonEncode(checkpoint.toJson());
        token.cancel('pause');
      };
      await expectLater(
        GongyiAsrService(dio: dio).transcribeAudio(
          audio.path,
          checkpoint: checkpoint,
          cancelToken: token,
        ),
        throwsA(
          isA<DioException>().having(CancelToken.isCancel, 'cancelled', isTrue),
        ),
      );
      expect(checkpoint.taskId, 'new-task');
      final resumed = GongyiAsrTaskCheckpoint.fromJson(
        jsonDecode(persisted!) as Map,
      );
      final result = await GongyiAsrService(
        dio: dio,
      ).transcribeAudio(audio.path, checkpoint: resumed);
      expect(result.single.text, '识别完成');
      expect(authorizations, 1);
      expect(parts, {0: 1, 1: 1, 2: 1});
      expect(tasks, 1);
      expect(queries, ['new-task']);
    },
  );

  test(
    'an expired remote task submits the local audio once and replaces its checkpoint',
    () async {
      expireOldTask = true;
      final checkpoint = GongyiAsrTaskCheckpoint(taskId: 'old-task');
      final ids = <String?>[];
      checkpoint.onChanged = () async => ids.add(checkpoint.taskId);
      await GongyiAsrService(
        dio: dio,
      ).transcribeAudio(audio.path, checkpoint: checkpoint);
      // Failure metadata is persisted before replacing the expired task ID.
      expect(ids, ['old-task', null, 'new-task']);
      expect(checkpoint.lastQueryFailure?['httpStatus'], 404);
      expect(queries, ['old-task', 'new-task']);
      expect(authorizations, 1);
      expect(tasks, 1);
    },
  );

  test(
    'resuming a submitted task does not prepare or read local audio',
    () async {
      await audio.delete();
      final checkpoint = GongyiAsrTaskCheckpoint(taskId: 'old-task');
      final result = await GongyiAsrService(dio: dio).transcribeAudio(
        audio.path,
        checkpoint: checkpoint,
        prepareAudio: () => throw StateError('preparation must stay lazy'),
      );
      expect(result.single.text, '识别完成');
      expect(queries, ['old-task']);
      expect(authorizations, 0);
      expect(tasks, 0);
      expect(parts, isEmpty);
    },
  );

  for (final message in ['任务未找到，第三方服务异常', 'task not found', '任务已失效']) {
    test(
      'missing task in business response is replaced without polling retries: $message',
      () async {
        expireOldTask = true;
        missingMessage = message;
        final checkpoint = GongyiAsrTaskCheckpoint(taskId: 'old-task');
        final waits = <Duration>[];
        final result = await GongyiAsrService(
          dio: dio,
          resultQueryDelay: (delay) async => waits.add(delay),
        ).transcribeAudio(audio.path, checkpoint: checkpoint);
        expect(result.single.text, '识别完成');
        expect(queries, ['old-task', 'new-task']);
        expect(tasks, 1);
        expect(waits, isEmpty);
      },
    );
  }

  test('an expired task resolves its replacement audio exactly once', () async {
    expireOldTask = true;
    var preparations = 0;
    final checkpoint = GongyiAsrTaskCheckpoint(
      taskId: 'old-task',
      normalizeAudio: true,
    );
    await GongyiAsrService(dio: dio).transcribeAudio(
      '${audio.path}.missing',
      checkpoint: checkpoint,
      prepareAudio: () async {
        preparations++;
        return audio.path;
      },
    );
    expect(preparations, 1);
    expect(queries, ['old-task', 'new-task']);
    expect(authorizations, 1);
    expect(tasks, 1);
    final restored = GongyiAsrTaskCheckpoint.fromJson(checkpoint.toJson());
    expect(restored.normalizeAudio, isTrue);
    expect(restored.taskId, 'new-task');
    expect(
      GongyiAsrTaskCheckpoint.fromJson({'taskId': 'legacy'}).normalizeAudio,
      isFalse,
    );
  });

  test('cancellation during preparation never starts an upload', () async {
    final token = CancelToken();
    await expectLater(
      GongyiAsrService(dio: dio).transcribeAudio(
        audio.path,
        cancelToken: token,
        prepareAudio: () async {
          token.cancel('stopped while preparing');
          return audio.path;
        },
      ),
      throwsA(
        isA<DioException>().having(CancelToken.isCancel, 'cancelled', true),
      ),
    );
    expect(authorizations, 0);
    expect(tasks, 0);
    expect(parts, isEmpty);
    expect(await audio.exists(), isTrue);
  });

  test(
    'a definitively failed remote task is cleared so shorter slices can replace it',
    () async {
      failTask = true;
      final checkpoint = GongyiAsrTaskCheckpoint(taskId: 'failed-task');
      await expectLater(
        GongyiAsrService(
          dio: dio,
        ).transcribeAudio(audio.path, checkpoint: checkpoint),
        throwsA(
          isA<GongyiAsrException>().having(
            (e) => e.suggestsSegmentation,
            'too long',
            isTrue,
          ),
        ),
      );
      expect(checkpoint.taskId, isNull);
      expect(parts, isEmpty);
    },
  );
}
