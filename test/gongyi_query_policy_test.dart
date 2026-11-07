import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/gongyi_asr_service.dart';

void main() {
  late Directory root;
  late File audio;
  late Dio dio;
  late void Function(RequestOptions, RequestInterceptorHandler) respond;
  final queries = <String>[];
  final waits = <Duration>[];
  Map<String, Object> ready({Object state = 4}) => {
    'code': 0,
    'data': {
      'state': state,
      'result': jsonEncode({
        'utterances': [
          {'start_time': 0, 'end_time': 1000, 'transcript': '字幕'},
        ],
      }),
    },
  };
  void resolve(
    RequestOptions options,
    RequestInterceptorHandler handler,
    Object body,
  ) => handler.resolve(
    Response(requestOptions: options, statusCode: 200, data: body),
  );
  GongyiAsrService service() => GongyiAsrService(
    dio: dio,
    minimumResultQueryInterval: Duration.zero,
    resultQueryDelay: (delay) async => waits.add(delay),
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('query-policy-');
    audio = await File('${root.path}/audio.mp3').writeAsBytes([1, 2, 3]);
    queries.clear();
    waits.clear();
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
    respond = (options, handler) => resolve(options, handler, ready());
  });
  tearDown(() async {
    dio.close(force: true);
    await root.delete(recursive: true);
  });

  for (final state in [3, '3', 5, '5']) {
    test(
      'terminal state $state stops immediately with the server explanation',
      () async {
        respond = (options, handler) => resolve(options, handler, {
          'code': 0,
          'data': {'state': state, 'remark': '音频解码失败'},
        });
        final checkpoint = GongyiAsrTaskCheckpoint(taskId: 'saved');
        await expectLater(
          service().transcribeAudio(audio.path, checkpoint: checkpoint),
          throwsA(
            isA<GongyiAsrException>()
                .having((e) => e.taskFinished, 'terminal', isTrue)
                .having((e) => e.message, 'server reason', contains('音频解码失败')),
          ),
        );
        expect(queries, ['saved']);
        expect(waits, isEmpty);
        expect(checkpoint.taskId, isNull);
      },
    );
  }

  test(
    'a numeric-string success state returns the existing task result',
    () async {
      respond = (options, handler) =>
          resolve(options, handler, ready(state: '4'));
      final result = await service().transcribeAudio(
        audio.path,
        checkpoint: GongyiAsrTaskCheckpoint(taskId: 'saved'),
      );
      expect(result.single.text, '字幕');
      expect(queries, ['saved']);
      expect(waits, isEmpty);
    },
  );

  for (final state in [null, 9, 'unknown']) {
    test(
      'unknown state $state pauses instead of polling the same payload repeatedly',
      () async {
        respond = (options, handler) => resolve(options, handler, {
          'code': 0,
          'data': state == null ? <String, Object?>{} : {'state': state},
        });
        final checkpoint = GongyiAsrTaskCheckpoint(taskId: 'saved');
        await expectLater(
          service().transcribeAudio(audio.path, checkpoint: checkpoint),
          throwsA(
            isA<GongyiAsrException>().having(
              (e) => e.queryRetryExhausted,
              'paused',
              isTrue,
            ),
          ),
        );
        expect(queries, ['saved']);
        expect(checkpoint.taskId, 'saved');
        expect(waits, isEmpty);
      },
    );
  }

  test(
    'running tasks back off and retain only major progress messages',
    () async {
      respond = (options, handler) => resolve(
        options,
        handler,
        queries.length < 16
            ? {
                'code': 0,
                'data': {'state': '1'},
              }
            : ready(),
      );
      final messages = <String>[];
      await service().transcribeAudio(
        audio.path,
        checkpoint: GongyiAsrTaskCheckpoint(taskId: 'saved'),
        onProgress: (_, message) => messages.add(message),
      );
      expect(waits.first, const Duration(seconds: 3));
      expect(waits, contains(const Duration(seconds: 5)));
      expect(waits, contains(const Duration(seconds: 10)));
      expect(
        waits.every((delay) => delay >= const Duration(seconds: 3)),
        isTrue,
      );
      expect(
        messages.every(
          (message) => !message.contains('秒后') && !message.contains('已等待'),
        ),
        isTrue,
      );
    },
  );

  test(
    'a healthy queued response honors and persists the server query minimum',
    () async {
      respond = (options, handler) {
        if (queries.length == 1) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'code': 0,
                'data': {'state': 0},
              },
              headers: Headers.fromMap({
                'retry-after': ['20'],
              }),
            ),
          );
        } else {
          resolve(options, handler, ready());
        }
      };
      final snapshots = <Map<String, dynamic>>[];
      final checkpoint = GongyiAsrTaskCheckpoint(taskId: 'saved');
      checkpoint.onChanged = () async => snapshots.add(checkpoint.toJson());
      await service().transcribeAudio(audio.path, checkpoint: checkpoint);
      expect(waits, [const Duration(seconds: 20)]);
      expect(snapshots.first['queryNotBefore'], isNotNull);
      expect(snapshots.last['queryNotBefore'], isNull);
      expect(queries, ['saved', 'saved']);
    },
  );

  test('concurrent tasks share one spaced result-query lane', () async {
    final starts = <DateTime>[];
    var active = 0, peak = 0;
    respond = (options, handler) {
      active++;
      if (active > peak) peak = active;
      starts.add(DateTime.now());
      Future<void>.delayed(const Duration(milliseconds: 4), () {
        active--;
        resolve(options, handler, ready());
      });
    };
    final client = GongyiAsrService(
      dio: dio,
      minimumResultQueryInterval: const Duration(milliseconds: 25),
    );
    await Future.wait([
      for (var i = 0; i < 3; i++)
        client.transcribeAudio(
          audio.path,
          checkpoint: GongyiAsrTaskCheckpoint(taskId: 'task-$i'),
        ),
    ]);
    expect(peak, 1);
    expect(starts, hasLength(3));
    for (var i = 1; i < starts.length; i++) {
      expect(
        starts[i].difference(starts[i - 1]),
        greaterThanOrEqualTo(const Duration(milliseconds: 20)),
      );
    }
  });

  test(
    'a restriction closes the shared lane before queued peers can query',
    () async {
      respond = (options, handler) => handler.reject(
        DioException(
          requestOptions: options,
          type: DioExceptionType.badResponse,
          response: Response(requestOptions: options, statusCode: 429),
        ),
      );
      final client = GongyiAsrService(
        dio: dio,
        minimumResultQueryInterval: Duration.zero,
        resultQueryTimeout: const Duration(milliseconds: 70),
        resultQueryDelay: (_) => Completer<void>().future,
      );
      Future<Object?> attempt(String id) async {
        try {
          await client.transcribeAudio(
            audio.path,
            checkpoint: GongyiAsrTaskCheckpoint(taskId: id),
          );
          return null;
        } catch (error) {
          return error;
        }
      }

      final results = await Future.wait([attempt('first'), attempt('second')]);
      expect(results, everyElement(isA<GongyiAsrException>()));
      expect(queries, ['first']);
    },
  );
}
