import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/gongyi_asr_service.dart';

void main() {
  Future<File> audioFile() async {
    final dir = await Directory.systemTemp.createTemp('gongyi_pipeline_');
    addTearDown(() => dir.delete(recursive: true));
    return File('${dir.path}/audio.m4a')
      ..writeAsBytesSync(List<int>.generate(10, (i) => i));
  }

  Dio fakeService({
    required void Function(RequestOptions, RequestInterceptorHandler) upload,
    required void Function(String etags) committed,
  }) {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.method == 'PUT') {
            upload(options, handler);
            return;
          }
          Object data;
          if (options.path.endsWith('/resource/create')) {
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
            committed((options.data as Map)['Etags'] as String);
            data = {
              'code': 0,
              'data': {'download_url': 'https://storage.test/audio'},
            };
          } else if (options.path.endsWith('/task/result')) {
            data = {
              'data': {
                'state': 4,
                'result': jsonEncode({
                  'utterances': [
                    {'start_time': 0, 'end_time': 1000, 'transcript': '字幕'},
                  ],
                }),
              },
            };
          } else {
            data = {
              'code': 0,
              'data': {'task_id': 'task'},
            };
          }
          handler.resolve(
            Response(requestOptions: options, data: data, statusCode: 200),
          );
        },
      ),
    );
    return dio;
  }

  test(
    'uploads two chunks at a time and commits ETags in file order',
    () async {
      final audio = await audioFile();
      final pending = <int, (RequestOptions, RequestInterceptorHandler)>{};
      final firstTwo = Completer<void>();
      final third = Completer<void>();
      final bytes = <int, List<int>>{};
      final progress = <double>[];
      var peak = 0;
      String? etags;
      final dio = fakeService(
        committed: (value) => etags = value,
        upload: (options, handler) {
          final i = int.parse(Uri.parse(options.path).pathSegments.last);
          bytes[i] = List<int>.of(options.data as Uint8List);
          pending[i] = (options, handler);
          if (pending.length > peak) peak = pending.length;
          if (pending.containsKey(0) && pending.containsKey(1)) {
            firstTwo.complete();
          }
          if (i == 2) third.complete();
        },
      );
      addTearDown(() => dio.close(force: true));
      final result = GongyiAsrService(dio: dio).transcribeAudio(
        audio.path,
        onProgress: (value, _) => progress.add(value),
      );
      void complete(int index) {
        final (options, handler) = pending.remove(index)!;
        options.onSendProgress?.call(
          bytes[index]!.length,
          bytes[index]!.length,
        );
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: <String, Object?>{},
            headers: Headers.fromMap({
              'etag': ['"etag-$index"'],
            }),
          ),
        );
      }

      await firstTwo.future.timeout(const Duration(seconds: 3));
      expect(bytes.keys, unorderedEquals([0, 1]));
      complete(1);
      await third.future.timeout(const Duration(seconds: 3));
      expect(peak, 2);
      complete(2);
      complete(0);
      expect((await result).single.text, '字幕');
      expect(etags, 'etag-0,etag-1,etag-2');
      expect(bytes[0], [0, 1, 2, 3]);
      expect(bytes[1], [4, 5, 6, 7]);
      expect(bytes[2], [8, 9]);
      expect(progress, orderedEquals([...progress]..sort()));
    },
  );

  test(
    'frequent upload callbacks are bounded and still report completion',
    () async {
      final audio = await audioFile();
      final messages = <String>[];
      final dio = fakeService(
        committed: (_) {},
        upload: (options, handler) {
          final chunk = options.data as Uint8List;
          for (var sent = 0; sent <= chunk.length; sent++) {
            options.onSendProgress?.call(sent, chunk.length);
          }
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: '',
              headers: Headers.fromMap({
                'etag': ['"part"'],
              }),
            ),
          );
        },
      );
      addTearDown(() => dio.close(force: true));
      await GongyiAsrService(dio: dio).transcribeAudio(
        audio.path,
        onProgress: (_, message) {
          if (message.startsWith('上传音频 ')) messages.add(message);
        },
      );
      expect(messages.length, lessThanOrEqualTo(3));
      expect(messages.last, startsWith('上传音频 100%'));
    },
  );

  test(
    'failed uploads settle their peers and never commit partial data',
    () async {
      final audio = await audioFile();
      var committed = false;
      final settled = Completer<void>();
      final started = <int>[];
      final dio = fakeService(
        committed: (_) => committed = true,
        upload: (options, handler) {
          final i = int.parse(Uri.parse(options.path).pathSegments.last);
          started.add(i);
          if (i == 0) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
              ),
            );
          } else {
            Future<void>.delayed(const Duration(milliseconds: 30), () {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: <String, Object?>{},
                  headers: Headers.fromMap({
                    'etag': ['"etag-$i"'],
                  }),
                ),
              );
              settled.complete();
            });
          }
        },
      );
      addTearDown(() => dio.close(force: true));
      await expectLater(
        GongyiAsrService(
          dio: dio,
          uploadRetryDelays: const [],
        ).transcribeAudio(audio.path),
        throwsA(isA<GongyiAsrException>()),
      );
      expect(committed, isFalse);
      expect(started, isNot(contains(2)));
      if (started.contains(1)) expect(settled.isCompleted, isTrue);
      // File handles have closed before the failed attempt returns.
      await audio.delete();
    },
  );

  test(
    'cancelling parallel uploads releases both readers without committing',
    () async {
      final audio = await audioFile();
      final token = CancelToken();
      final bothStarted = Completer<void>();
      var started = 0;
      var committed = false;
      final dio = fakeService(
        committed: (_) => committed = true,
        upload: (options, handler) {
          started++;
          if (started == 2) bothStarted.complete();
          options.cancelToken!.whenCancel.then(
            (error) => handler.reject(error),
          );
        },
      );
      addTearDown(() => dio.close(force: true));
      final result = expectLater(
        GongyiAsrService(
          dio: dio,
        ).transcribeAudio(audio.path, cancelToken: token),
        throwsA(
          isA<DioException>().having(CancelToken.isCancel, 'cancelled', isTrue),
        ),
      );
      await bothStarted.future.timeout(const Duration(seconds: 3));
      token.cancel('Pause transcription');
      await result;
      expect(started, 2);
      expect(committed, isFalse);
      await audio.delete();
    },
  );
}
