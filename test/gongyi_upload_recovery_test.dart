import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/gongyi_asr_service.dart';
import 'package:video_player_app/services/network/network_http.dart';
import 'package:video_player_app/services/transcription_reliability.dart';

class _Fixture {
  int authorizations = 0, uploads = 0, commits = 0, tasks = 0, queries = 0;
  final routes = <bool>[];
  final contentTypes = <String?>[];
  final urls = <String>[];
  late final Dio dio;
  final void Function(RequestOptions, RequestInterceptorHandler, _Fixture)?
  respond;

  _Fixture({this.respond}) {
    dio = Dio(BaseOptions(headers: {'Content-Type': 'application/json'}));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final direct =
              options.extra[NetworkHttp.speechRecognitionDirectRecoveryKey] ==
              true;
          routes.add(direct);
          options.extra['appNetworkContext'] = RequestNetworkContext(
            scope: NetworkScope.speechRecognition,
            configuration: NetworkConfiguration(
              unifiedMode: NetworkMode.system,
            ),
            speechRecognitionDirectRecovery: direct,
          );
          Object data;
          if (options.path.endsWith('/resource/create')) {
            authorizations++;
            data = {
              'code': 0,
              'data': {
                'upload_urls': [
                  'https://storage.test/chunk?partNumber=1&Signature=a%2Bb%2Fc%3D&uploadId=$authorizations',
                ],
                'per_size': 4,
                'in_boss_key': 'boss',
                'resource_id': 'resource-$authorizations',
                'upload_id': '$authorizations',
              },
            };
          } else if (options.method == 'PUT') {
            uploads++;
            contentTypes.add(options.contentType);
            urls.add(options.uri.toString());
            if (respond != null) {
              respond!(options, handler, this);
              return;
            }
            resolveUpload(options, handler);
            return;
          } else if (options.path.endsWith('/resource/create/complete')) {
            commits++;
            data = {
              'code': 0,
              'data': {'download_url': 'https://storage.test/audio'},
            };
          } else if (options.path.endsWith('/task/result')) {
            queries++;
            data = {
              'code': 0,
              'data': {
                'state': 4,
                'result': jsonEncode({
                  'utterances': [
                    {'start_time': 0, 'end_time': 1000, 'transcript': '恢复成功'},
                  ],
                }),
              },
            };
          } else {
            tasks++;
            data = {
              'code': 0,
              'data': {'task_id': 'created-task'},
            };
          }
          handler.resolve(
            Response(requestOptions: options, statusCode: 200, data: data),
          );
        },
      ),
    );
  }

  static void resolveUpload(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) => handler.resolve(
    Response(
      requestOptions: options,
      statusCode: 200,
      data: '',
      headers: Headers.fromMap({
        'etag': ['"etag"'],
      }),
    ),
  );

  static void rejectSignature(
    RequestOptions options,
    RequestInterceptorHandler handler, {
    String? type,
  }) => handler.reject(
    DioException(
      requestOptions: options,
      type: DioExceptionType.badResponse,
      response: Response(
        requestOptions: options,
        statusCode: 403,
        data:
            '<Error><Code>SignatureDoesNotMatch</Code>'
            '${type == null ? '' : '<StringToSign>PUT\n\n$type\n2000000000\n/bucket/object</StringToSign>'}</Error>',
      ),
    ),
  );
}

void main() {
  late Directory root;
  late File audio;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('gongyi-recovery-');
    audio = File('${root.path}/audio.m4a')..writeAsBytesSync([1, 2, 3, 4]);
  });
  tearDown(() async => root.delete(recursive: true));
  GongyiAsrService service(_Fixture fixture) {
    addTearDown(() => fixture.dio.close(force: true));
    return GongyiAsrService(dio: fixture.dio, uploadRetryDelays: const []);
  }

  for (final type in ['', 'application/octet-stream']) {
    test(
      'signature header mismatch is repaired without changing the route: "$type"',
      () async {
        final fixture = _Fixture(
          respond: (options, handler, fixture) {
            if ((options.contentType ?? '') != type) {
              _Fixture.rejectSignature(options, handler, type: type);
            } else {
              _Fixture.resolveUpload(options, handler);
            }
          },
        );
        final statuses = <String>[];
        expect(
          (await service(fixture).transcribeAudio(
            audio.path,
            onProgress: (_, message) => statuses.add(message),
          )).single.text,
          '恢复成功',
        );
        expect(fixture.authorizations, 1);
        expect(fixture.uploads, 2);
        expect(fixture.routes, everyElement(isFalse));
        expect(fixture.contentTypes.last ?? '', type);
        expect(fixture.urls.toSet(), hasLength(1));
        expect(fixture.urls.last, contains('Signature=a%2Bb%2Fc%3D'));
        expect(statuses.any((s) => s.contains('校正')), isTrue);
      },
    );
  }

  test(
    'real HTTP upload repairs an unsigned Content-Type while the network stays healthy',
    () async {
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var authorizations = 0, uploads = 0;
      final receivedTypes = <String?>[];
      final query = 'partNumber=1&Signature=a%2Bb%2Fc%3D';
      final signedUrl = 'http://127.0.0.1:${server.port}/signed?$query';
      server.listen((request) async {
        final bytes = await request.fold<List<int>>(
          [],
          (all, next) => all..addAll(next),
        );
        Object data;
        if (request.uri.path == '/signed') {
          uploads++;
          receivedTypes.add(request.headers.value('content-type'));
          expect(request.uri.query, query);
          expect(bytes, [1, 2, 3, 4]);
          expect(request.headers.value('authorization'), isNull);
          expect(request.headers.value('cookie'), isNull);
          if (request.headers.value('content-type') != null) {
            request.response.statusCode = 403;
            request.response.headers.contentType = ContentType(
              'application',
              'xml',
            );
            request.response.write(
              '<Error><Code>SignatureDoesNotMatch</Code>'
              '<StringToSign>PUT\n\n\n2000000000\n/bucket/object</StringToSign></Error>',
            );
          } else {
            request.response.headers.set('etag', '"etag"');
          }
          await request.response.close();
          return;
        } else if (request.uri.path.endsWith('/resource/create')) {
          authorizations++;
          data = {
            'code': 0,
            'data': {
              'upload_urls': [signedUrl],
              'per_size': 4,
              'in_boss_key': 'boss',
              'resource_id': 'resource',
              'upload_id': 'upload',
            },
          };
        } else if (request.uri.path.endsWith('/resource/create/complete')) {
          data = {
            'code': 0,
            'data': {'download_url': signedUrl},
          };
        } else if (request.uri.path.endsWith('/task/result')) {
          data = {
            'code': 0,
            'data': {
              'state': 4,
              'result': jsonEncode({
                'utterances': [
                  {'start_time': 0, 'end_time': 1000, 'transcript': '网络正常'},
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
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(data));
        await request.response.close();
      });
      final dio = Dio(
        BaseOptions(
          headers: {
            'content-type': 'application/json',
            'authorization': 'test-api-only',
            'cookie': 'test-api-only',
          },
        ),
      );
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.uri.host == 'member.bilibili.com') {
              options.path =
                  'http://127.0.0.1:${server.port}${options.uri.path}';
            }
            expect(
              options.extra[NetworkHttp.speechRecognitionDirectRecoveryKey],
              isNull,
            );
            handler.next(options);
          },
        ),
      );
      addTearDown(() async {
        dio.close(force: true);
        await server.close(force: true);
      });
      final result = await GongyiAsrService(
        dio: dio,
      ).transcribeAudio(audio.path);
      expect(result.single.text, '网络正常');
      expect(receivedTypes, ['application/json', null]);
      expect(authorizations, 1);
      expect(uploads, 2);
    },
  );

  test(
    'refreshing authorization can fix the signature without bypassing a proxy',
    () async {
      final fixture = _Fixture(
        respond: (options, handler, fixture) {
          if (fixture.authorizations == 1) {
            _Fixture.rejectSignature(options, handler);
          } else {
            _Fixture.resolveUpload(options, handler);
          }
        },
      );
      await service(fixture).transcribeAudio(audio.path);
      expect(fixture.authorizations, 2);
      expect(fixture.routes, everyElement(isFalse));
      expect(fixture.tasks, 1);
    },
  );

  test(
    'a persistent signature failure tries fresh authorization on a temporary direct route',
    () async {
      final fixture = _Fixture(
        respond: (options, handler, fixture) {
          if (options.extra[NetworkHttp.speechRecognitionDirectRecoveryKey] !=
              true) {
            _Fixture.rejectSignature(options, handler);
          } else {
            _Fixture.resolveUpload(options, handler);
          }
        },
      );
      final client = service(fixture);
      await client.transcribeAudio(audio.path);
      expect(fixture.authorizations, 3);
      expect(fixture.uploads, 3);
      expect(fixture.tasks, 1);
      expect(
        fixture.routes.skipWhile((direct) => !direct),
        everyElement(isTrue),
      );
      // Another invocation starts with the saved route, not the previous fallback.
      final before = fixture.routes.length;
      await client.transcribeAudio(audio.path);
      expect(fixture.routes[before], isFalse);
    },
  );

  test(
    'connection failure attempts direct recovery after bounded chunk retries',
    () async {
      final fixture = _Fixture(
        respond: (options, handler, fixture) {
          if (fixture.uploads == 1) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
              ),
            );
          } else {
            _Fixture.resolveUpload(options, handler);
          }
        },
      );
      await service(fixture).transcribeAudio(audio.path);
      expect(fixture.authorizations, 2);
      expect(fixture.routes.last, isTrue);
      expect(fixture.tasks, 1);
    },
  );

  test(
    'persistent failures exhaust recovery without resetting the queue retry budget',
    () async {
      final fixture = _Fixture(
        respond: (options, handler, _) =>
            _Fixture.rejectSignature(options, handler),
      );
      final client = service(fixture);
      var queueAttempts = 0;
      await expectLater(
        TranscriptionAttemptRunner.run(
          attempt: () {
            queueAttempts++;
            return client.transcribeAudio(audio.path);
          },
          delay: (_) async {},
          onWaiting: (_) {},
        ),
        throwsA(
          isA<GongyiAsrException>()
              .having(
                (e) => e.kind,
                'kind',
                GongyiAsrFailureKind.uploadSignature,
              )
              .having(
                (e) => e.recoveryExhausted,
                'bounded recovery exhausted',
                isTrue,
              ),
        ),
      );
      expect(queueAttempts, 1);
      expect(fixture.authorizations, 3);
      expect(fixture.commits, 0);
      expect(fixture.tasks, 0);
    },
  );

  for (final status in [403, 429]) {
    test('unrelated HTTP $status does not trigger direct recovery', () async {
      final fixture = _Fixture(
        respond: (options, handler, _) => handler.reject(
          DioException(
            requestOptions: options,
            type: DioExceptionType.badResponse,
            response: Response(
              requestOptions: options,
              statusCode: status,
              data: status == 429 ? 'Too Many Requests' : 'AccessDenied',
            ),
          ),
        ),
      );
      await expectLater(
        service(fixture).transcribeAudio(audio.path),
        throwsA(isA<GongyiAsrException>()),
      );
      expect(fixture.authorizations, 1);
      expect(fixture.routes, everyElement(isFalse));
    });
  }

  test(
    'cancel during authorization recovery does not issue another upload',
    () async {
      final fixture = _Fixture(
        respond: (options, handler, _) =>
            _Fixture.rejectSignature(options, handler),
      );
      final cancel = CancelToken();
      await expectLater(
        service(fixture).transcribeAudio(
          audio.path,
          cancelToken: cancel,
          onProgress: (_, message) {
            if (message.contains('重新获取上传授权后重试')) cancel.cancel('stop');
          },
        ),
        throwsA(
          isA<DioException>().having(CancelToken.isCancel, 'cancelled', isTrue),
        ),
      );
      expect(fixture.authorizations, 1);
      expect(fixture.uploads, 1);
    },
  );

  test(
    'result-query recovery reuses the existing task ID and never uploads',
    () async {
      final fixture = _Fixture();
      var failed = false;
      fixture.dio.interceptors.insert(
        0,
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (!failed && options.path.endsWith('/task/result')) {
              failed = true;
              options.extra['appNetworkContext'] = RequestNetworkContext(
                scope: NetworkScope.speechRecognition,
                configuration: NetworkConfiguration(
                  unifiedMode: NetworkMode.system,
                ),
              );
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.connectionError,
                ),
              );
            } else {
              if (options.path.endsWith('/task/result')) {
                expect(options.queryParameters['task_id'], 'already-submitted');
              }
              handler.next(options);
            }
          },
        ),
      );
      await service(fixture).transcribeAudio(
        audio.path,
        checkpoint: GongyiAsrTaskCheckpoint(taskId: 'already-submitted'),
      );
      expect(failed, isTrue);
      expect(fixture.routes, [true]);
      expect(fixture.authorizations, 0);
      expect(fixture.tasks, 0);
      expect(fixture.uploads, 0);
    },
  );
}
