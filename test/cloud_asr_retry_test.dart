import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/model_center/cloud_asr_adapters.dart';
import 'package:video_player_app/features/model_center/cloud_asr_types.dart';

import 'cloud_asr_test_support.dart';

void main() {
  test(
    'an old pending task gets a fresh polling budget when resumed',
    () async {
      final state = <String, dynamic>{
        'taskId': 'old-task',
        'submittedAt': '2020-01-01T00:00:00Z',
      };
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {'status': 'queued'},
                ),
              );
            },
          ),
        );
      final adapter = CloudAsrAdapter.create(
        cloudConnection(
          CloudAsrProvider.assemblyai,
          endpoint: 'https://api.test',
        ),
        dio: dio,
      );
      addTearDown(adapter.close);
      final token = CancelToken();
      var waiting = false;
      await expectLater(
        adapter.transcribe(
          filePath: null,
          duration: const Duration(seconds: 1),
          state: state,
          save: () async {},
          token: token,
          progress: (_, _, _) {
            waiting = true;
            token.cancel('pause');
          },
        ),
        throwsA(
          isA<DioException>().having(CancelToken.isCancel, 'cancelled', true),
        ),
      );
      expect(waiting, true);
      expect(state['taskId'], 'old-task');
    },
  );

  for (final provider in [
    CloudAsrProvider.soniox,
    CloudAsrProvider.assemblyai,
    CloudAsrProvider.gemini,
  ]) {
    for (final failure in [
      'failed',
      'error',
      'cancelled',
      'incomplete',
      '404',
      '410',
      '401',
    ]) {
      test(
        '${provider.name} $failure retry never reuses a definitively invalid task',
        () async {
          final root = await Directory.systemTemp.createTemp('cloud-retry-');
          addTearDown(() => root.delete(recursive: true));
          final audio = await File(
            '${root.path}/audio.mp3',
          ).writeAsBytes([73, 68, 51, 0]);
          var fail = true, uploads = 0, submissions = 0;
          var state = <String, dynamic>{
            'taskId': 'old-task',
            'submittedAt': '2020-01-01T00:00:00Z',
            'normalized': true,
            if (provider == CloudAsrProvider.soniox) 'fileId': 'old-file',
            if (provider == CloudAsrProvider.assemblyai)
              'uploadUrl': 'https://storage.test/old',
            if (provider == CloudAsrProvider.gemini) ...{
              'fileUri': 'old-uri',
              'fileName': 'files/old',
              'fileReady': true,
            },
          };
          Map<String, dynamic>? persisted;
          final queried = <String>[];
          final dio = Dio()
            ..interceptors.add(
              InterceptorsWrapper(
                onRequest: (options, handler) {
                  final path = options.uri.path;
                  dynamic data;
                  Headers? headers;
                  if (options.method == 'GET') {
                    queried.add(path);
                    if (fail) {
                      final status = int.tryParse(failure);
                      if (status != null) {
                        handler.reject(
                          DioException(
                            requestOptions: options,
                            type: DioExceptionType.badResponse,
                            response: Response(
                              requestOptions: options,
                              statusCode: status,
                            ),
                          ),
                        );
                        return;
                      }
                      data = {'status': failure};
                    } else if (provider == CloudAsrProvider.soniox &&
                        !path.endsWith('/transcript')) {
                      data = {'status': 'completed'};
                    } else {
                      data = cloudReply(provider);
                    }
                  } else if (path == '/v1/files') {
                    uploads++;
                    data = {'id': 'new-file'};
                  } else if (path == '/v2/upload') {
                    uploads++;
                    data = {'upload_url': 'https://storage.test/new'};
                  } else if (path == '/upload/v1beta/files') {
                    uploads++;
                    headers = Headers.fromMap({
                      'x-goog-upload-url': ['https://api.test/upload'],
                    });
                    data = {};
                  } else if (path == '/upload') {
                    data = {
                      'file': {
                        'name': 'files/new',
                        'uri': 'https://storage.test/new',
                        'state': 'ACTIVE',
                      },
                    };
                  } else {
                    submissions++;
                    data = {'id': 'new-task', 'status': 'queued'};
                  }
                  handler.resolve(
                    Response(
                      requestOptions: options,
                      statusCode: 200,
                      data: data,
                      headers: headers,
                    ),
                  );
                },
              ),
            );
          final adapter = CloudAsrAdapter.create(
            cloudConnection(provider, endpoint: 'https://api.test'),
            dio: dio,
          );
          addTearDown(adapter.close);
          Future<CloudAsrResult> run() => adapter.transcribe(
            filePath: audio.path,
            duration: const Duration(seconds: 1),
            state: state,
            save: () async => persisted =
                jsonDecode(jsonEncode(state)) as Map<String, dynamic>,
            token: CancelToken(),
            progress: (_, _, _) {},
          );
          await expectLater(run(), throwsA(isA<CloudAsrException>()));
          final invalid = failure != '401';
          expect(state['taskId'], invalid ? null : 'old-task');
          expect(state['normalized'], true);
          expect(adapter.needsAudio(state), invalid);
          expect(submissions, 0);
          if (invalid) state = persisted!;
          queried.clear();
          fail = false;
          final result = await run();
          expect(result.cues.single.text, 'Hello world');
          expect(uploads, invalid ? 1 : 0);
          expect(submissions, invalid ? 1 : 0);
          expect(
            queried.every(
              (path) => path.contains(invalid ? 'new-task' : 'old-task'),
            ),
            true,
          );
        },
      );
    }
  }

  for (final failure in ['FAILED', '404', '410']) {
    test(
      'Google saved file $failure is invalidated before another submission',
      () async {
        final state = <String, dynamic>{
          'fileUri': 'old-uri',
          'fileName': 'files/old',
        };
        final dio = Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                expect(options.method, 'GET');
                if (failure == 'FAILED') {
                  handler.resolve(
                    Response(
                      requestOptions: options,
                      statusCode: 200,
                      data: {'state': 'FAILED'},
                    ),
                  );
                } else {
                  handler.reject(
                    DioException(
                      requestOptions: options,
                      type: DioExceptionType.badResponse,
                      response: Response(
                        requestOptions: options,
                        statusCode: int.parse(failure),
                      ),
                    ),
                  );
                }
              },
            ),
          );
        final adapter = CloudAsrAdapter.create(
          cloudConnection(
            CloudAsrProvider.gemini,
            endpoint: 'https://api.test',
          ),
          dio: dio,
        );
        addTearDown(adapter.close);
        await expectLater(
          adapter.transcribe(
            filePath: null,
            duration: const Duration(seconds: 1),
            state: state,
            save: () async {},
            token: CancelToken(),
            progress: (_, _, _) {},
          ),
          throwsA(isA<CloudAsrException>()),
        );
        expect(adapter.needsAudio(state), true);
        expect(state['remoteReset'], true);
      },
    );
  }
}
