import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/transcription_progress.dart';
import 'package:video_player_app/models/transcription_status.dart';
import 'package:video_player_app/services/gongyi_asr_service.dart';
import 'package:video_player_app/services/transcription_reliability.dart';

void main() {
  late File audio;
  late Dio dio;
  late GongyiAsrTaskCheckpoint checkpoint;
  late void Function(RequestOptions, RequestInterceptorHandler) respond;
  final queries = <String>[];

  Map<String, Object> success() => {
    'code': 0,
    'data': {
      'state': 4,
      'result': jsonEncode({
        'utterances': [
          {'start_time': 0, 'end_time': 1000, 'transcript': '完成'},
        ],
      }),
    },
  };

  void resolve(
    RequestOptions options,
    RequestInterceptorHandler handler,
    Object? data,
  ) => handler.resolve(
    Response(requestOptions: options, statusCode: 200, data: data),
  );

  setUp(() async {
    final root = await Directory.systemTemp.createTemp(
      'gongyi-result-polling-',
    );
    addTearDown(() => root.delete(recursive: true));
    audio = File('${root.path}/audio.m4a')..writeAsBytesSync([1, 2, 3]);
    checkpoint = GongyiAsrTaskCheckpoint(taskId: 'submitted-task');
    queries.clear();
    dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(options.path, endsWith('/task/result'));
            queries.add(options.queryParameters['task_id'].toString());
            respond(options, handler);
          },
        ),
      );
    addTearDown(() => dio.close(force: true));
    respond = (options, handler) => resolve(options, handler, success());
  });

  for (final responseKind in ['http412', 'http429', 'api412', 'api429']) {
    test(
      '$responseKind stops immediately and resumes the saved task after cooldown',
      () async {
        final unexplained = responseKind == 'http412';
        respond = (options, handler) {
          final code = responseKind.endsWith('412') ? 412 : 429;
          if (responseKind.startsWith('http')) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.badResponse,
                response: Response(requestOptions: options, statusCode: code),
              ),
            );
          } else {
            resolve(options, handler, {'code': -code, 'message': '访问频繁'});
          }
        };
        final waits = <Duration>[];
        final outerWaits = <Duration>[];
        final messages = <String>[];
        final service = GongyiAsrService(
          minimumResultQueryInterval: Duration.zero,
          dio: dio,
          resultQueryDelay: (delay) async => waits.add(delay),
        );
        await expectLater(
          TranscriptionAttemptRunner.run(
            attempt: () => service.transcribeAudio(
              audio.path,
              checkpoint: checkpoint,
              onProgress: (_, message) => messages.add(message),
            ),
            delay: (delay) async => outerWaits.add(delay),
            onWaiting: (_) {},
          ),
          throwsA(
            isA<GongyiAsrException>()
                .having(
                  (e) => e.kind,
                  'kind',
                  unexplained
                      ? GongyiAsrFailureKind.requestRejected
                      : GongyiAsrFailureKind.riskControl,
                )
                .having(
                  (e) => e.queryRetryExhausted,
                  'budget exhausted',
                  isTrue,
                )
                .having(
                  (e) => TranscriptionUserMessage.describe(e),
                  'user message',
                  contains('识别任务已保留'),
                ),
          ),
        );
        expect(queries, ['submitted-task']);
        expect(outerWaits, isEmpty);
        expect(waits, isEmpty);
        expect(
          checkpoint.queryNotBefore!.difference(DateTime.now()),
          greaterThan(const Duration(seconds: 59)),
        );
        if (unexplained) {
          expect(messages.any((m) => m.contains('访问限制')), isFalse);
          expect(checkpoint.lastQueryFailure?['httpStatus'], 412);
        }
        expect(checkpoint.taskId, 'submitted-task');

        // Queue retries resume this checkpoint after its retained cooldown.
        respond = (options, handler) => resolve(options, handler, success());
        final resumed = await service.transcribeAudio(
          audio.path,
          checkpoint: checkpoint,
        );
        expect(resumed.single.text, '完成');
        expect(queries.last, 'submitted-task');
        expect(
          waits.fold(Duration.zero, (total, d) => total + d),
          greaterThan(const Duration(seconds: 59)),
        );
      },
    );
  }

  test(
    'a brief query restriction recovers without delaying the healthy path',
    () async {
      final waits = <Duration>[];
      final messages = <String>[];
      respond = (options, handler) {
        resolve(
          options,
          handler,
          queries.length == 1 ? {'code': 429, 'message': '访问频繁'} : success(),
        );
      };
      final result =
          await GongyiAsrService(
            minimumResultQueryInterval: Duration.zero,
            dio: dio,
            maxPollRiskWaits: 1,
            resultQueryDelay: (delay) async => waits.add(delay),
          ).transcribeAudio(
            audio.path,
            checkpoint: checkpoint,
            onProgress: (_, message) => messages.add(message),
          );
      expect(result.single.text, '完成');
      expect(queries, hasLength(2));
      expect(waits, [const Duration(seconds: 60)]);
      expect(messages.any((m) => m.contains('不会重新上传')), isTrue);
    },
  );

  test(
    'queue and recognition use paced polling without per-second progress messages',
    () async {
      final messages = <String>[];
      final waits = <Duration>[];
      respond = (options, handler) => resolve(
        options,
        handler,
        queries.length < 3
            ? {
                'data': {'state': queries.length == 1 ? 0 : 1},
              }
            : success(),
      );
      await GongyiAsrService(
        minimumResultQueryInterval: Duration.zero,
        dio: dio,
        resultQueryDelay: (delay) async => waits.add(delay),
      ).transcribeAudio(
        audio.path,
        checkpoint: checkpoint,
        onProgress: (_, message) => messages.add(message),
      );
      expect(queries, hasLength(3));
      expect(waits, hasLength(2));
      expect(waits, [const Duration(seconds: 10), const Duration(seconds: 3)]);
      for (final state in ['服务器正在排队', '等待识别结果']) {
        final message = messages.firstWhere((m) => m.contains(state));
        expect(message, isNot(contains('已等待')));
        expect(
          TranscriptionProgress.isWaiting(
            TranscriptionStatus.transcribing,
            message,
          ),
          isTrue,
        );
      }
    },
  );

  for (final responseKind in [
    'offline',
    'http500',
    'invalidBody',
    'invalidData',
  ]) {
    test(
      '$responseKind stops after query retries without an outer reset',
      () async {
        respond = (options, handler) {
          if (responseKind == 'invalidBody' || responseKind == 'invalidData') {
            resolve(
              options,
              handler,
              responseKind == 'invalidBody' ? 'invalid' : {'code': 0},
            );
            return;
          }
          handler.reject(
            DioException(
              requestOptions: options,
              type: responseKind == 'offline'
                  ? DioExceptionType.connectionError
                  : DioExceptionType.badResponse,
              response: responseKind == 'offline'
                  ? null
                  : Response(requestOptions: options, statusCode: 500),
            ),
          );
        };
        final outerWaits = <Duration>[];
        final service = GongyiAsrService(
          minimumResultQueryInterval: Duration.zero,
          dio: dio,
          resultQueryDelay: (_) async {},
        );
        await expectLater(
          TranscriptionAttemptRunner.run(
            attempt: () =>
                service.transcribeAudio(audio.path, checkpoint: checkpoint),
            delay: (delay) async => outerWaits.add(delay),
            onWaiting: (_) {},
          ),
          throwsA(
            isA<GongyiAsrException>().having(
              (e) => e.queryRetryExhausted,
              'budget exhausted',
              isTrue,
            ),
          ),
        );
        expect(queries, hasLength(4));
        expect(outerWaits, isEmpty);
        expect(checkpoint.taskId, 'submitted-task');
      },
    );
  }

  test(
    'the query deadline aborts a stalled request and retains the task',
    () async {
      CancelToken? requestCancellation;
      respond = (options, handler) {
        requestCancellation = options.cancelToken;
        options.cancelToken!.whenCancel.then(handler.reject);
      };
      await expectLater(
        GongyiAsrService(
          minimumResultQueryInterval: Duration.zero,
          dio: dio,
          resultQueryTimeout: const Duration(milliseconds: 50),
        ).transcribeAudio(audio.path, checkpoint: checkpoint),
        throwsA(
          isA<GongyiAsrException>().having(
            (e) => e.queryRetryExhausted,
            'deadline exhausted',
            isTrue,
          ),
        ),
      );
      expect(requestCancellation!.isCancelled, isTrue);
      expect(queries, hasLength(1));
      expect(checkpoint.taskId, 'submitted-task');
    },
  );

  test(
    'an unexplained business -412 retains both HTTP and API evidence',
    () async {
      respond = (options, handler) =>
          resolve(options, handler, {'code': -412, 'message': '请求校验失败'});
      await expectLater(
        GongyiAsrService(
          minimumResultQueryInterval: Duration.zero,
          dio: dio,
          resultQueryDelay: (_) async {},
        ).transcribeAudio(audio.path, checkpoint: checkpoint),
        throwsA(
          isA<GongyiAsrException>()
              .having(
                (e) => e.kind,
                'unconfirmed',
                GongyiAsrFailureKind.requestRejected,
              )
              .having(
                (e) => e.diagnosticSummary,
                'evidence',
                contains('接口码 -412'),
              ),
        ),
      );
      expect(queries, hasLength(1));
      expect(checkpoint.lastQueryFailure?['httpStatus'], 200);
      expect(checkpoint.lastQueryFailure?['apiCode'], -412);
      expect(checkpoint.taskId, 'submitted-task');
    },
  );

  for (final apiResponse in [false, true]) {
    test(
      'Retry-After is respected for ${apiResponse ? 'API' : 'HTTP'} frequency limits',
      () async {
        final waits = <Duration>[];
        respond = (options, handler) {
          if (queries.length > 1) {
            resolve(options, handler, success());
            return;
          }
          final response = Response(
            requestOptions: options,
            statusCode: apiResponse ? 200 : 429,
            data: {'code': 429, 'message': 'Too Many Requests'},
            headers: Headers.fromMap({
              'retry-after': ['90'],
            }),
          );
          if (apiResponse) {
            handler.resolve(response);
          } else {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.badResponse,
                response: response,
              ),
            );
          }
        };
        await GongyiAsrService(
          minimumResultQueryInterval: Duration.zero,
          dio: dio,
          maxPollRiskWaits: 1,
          resultQueryDelay: (delay) async => waits.add(delay),
        ).transcribeAudio(audio.path, checkpoint: checkpoint);
        expect(
          waits.fold(Duration.zero, (total, delay) => total + delay),
          const Duration(seconds: 90),
        );
        expect(queries, hasLength(2));
      },
    );
  }

  test(
    'a long Retry-After stops at the deadline without making an early request',
    () async {
      respond = (options, handler) => handler.reject(
        DioException(
          requestOptions: options,
          type: DioExceptionType.badResponse,
          response: Response(
            requestOptions: options,
            statusCode: 429,
            headers: Headers.fromMap({
              'retry-after': ['600'],
            }),
          ),
        ),
      );
      await expectLater(
        GongyiAsrService(
          minimumResultQueryInterval: Duration.zero,
          dio: dio,
          resultQueryTimeout: const Duration(milliseconds: 50),
        ).transcribeAudio(audio.path, checkpoint: checkpoint),
        throwsA(
          isA<GongyiAsrException>()
              .having((e) => e.queryRetryExhausted, 'exhausted', isTrue)
              .having((e) => e.statusCode, 'HTTP status', 429),
        ),
      );
      expect(queries, hasLength(1));
      expect(checkpoint.taskId, 'submitted-task');
      final restored = GongyiAsrTaskCheckpoint.fromJson(checkpoint.toJson());
      expect(
        restored.queryNotBefore!.difference(DateTime.now()),
        greaterThan(const Duration(minutes: 9)),
      );
      respond = (options, handler) => resolve(options, handler, success());
      await expectLater(
        GongyiAsrService(
          minimumResultQueryInterval: Duration.zero,
          dio: dio,
          resultQueryTimeout: const Duration(milliseconds: 50),
        ).transcribeAudio(audio.path, checkpoint: restored),
        throwsA(isA<GongyiAsrException>()),
      );
      expect(queries, hasLength(1));
    },
  );

  test(
    'result requests ask for fresh JSON without altering task parameters',
    () async {
      respond = (options, handler) {
        expect(options.headers['Cache-Control'], 'no-cache');
        expect(options.headers['Accept'], contains('application/json'));
        expect(
          options.headers['User-Agent'],
          'Bilibili/1.0.0 (https://www.bilibili.com)',
        );
        expect(options.method, 'GET');
        expect(options.queryParameters, {
          'model_id': 7,
          'task_id': 'submitted-task',
        });
        resolve(options, handler, success());
      };
      await GongyiAsrService(
        minimumResultQueryInterval: Duration.zero,
        dio: dio,
      ).transcribeAudio(audio.path, checkpoint: checkpoint);
    },
  );

  test(
    'saved tasks use the current result protocol without recreating the task',
    () async {
      checkpoint = GongyiAsrTaskCheckpoint.fromJson({
        'taskId': 'submitted-task',
      });
      respond = (options, handler) {
        expect(options.queryParameters, {
          'model_id': 7,
          'task_id': 'submitted-task',
        });
        resolve(options, handler, success());
      };
      await GongyiAsrService(
        minimumResultQueryInterval: Duration.zero,
        dio: dio,
      ).transcribeAudio(audio.path, checkpoint: checkpoint);
      expect(queries, ['submitted-task']);
    },
  );

  test(
    'the query deadline also includes waiting between normal polls',
    () async {
      respond = (options, handler) => resolve(options, handler, {
        'data': {'state': 1},
      });
      await expectLater(
        GongyiAsrService(
          minimumResultQueryInterval: Duration.zero,
          dio: dio,
          resultQueryTimeout: const Duration(milliseconds: 50),
        ).transcribeAudio(audio.path, checkpoint: checkpoint),
        throwsA(
          isA<GongyiAsrException>().having(
            (e) => e.queryRetryExhausted,
            'deadline exhausted',
            isTrue,
          ),
        ),
      );
      expect(queries, hasLength(1));
      expect(checkpoint.taskId, 'submitted-task');
    },
  );

  test(
    'cancelling an explicitly enabled restriction wait stops and can resume',
    () async {
      final cancellation = CancelToken();
      respond = (options, handler) =>
          resolve(options, handler, {'code': 429, 'message': '访问频繁'});
      await expectLater(
        GongyiAsrService(
          minimumResultQueryInterval: Duration.zero,
          dio: dio,
          maxPollRiskWaits: 1,
        ).transcribeAudio(
          audio.path,
          checkpoint: checkpoint,
          cancelToken: cancellation,
          onProgress: (_, message) {
            if (message.contains('等待后重查')) cancellation.cancel('pause');
          },
        ),
        throwsA(
          isA<DioException>().having(CancelToken.isCancel, 'cancelled', isTrue),
        ),
      );
      expect(queries, hasLength(1));
      expect(checkpoint.taskId, 'submitted-task');
      respond = (options, handler) => resolve(options, handler, success());
      expect(
        (await GongyiAsrService(
          minimumResultQueryInterval: Duration.zero,
          dio: dio,
          resultQueryDelay: (_) async {},
        ).transcribeAudio(audio.path, checkpoint: checkpoint)).single.text,
        '完成',
      );
    },
  );
}
