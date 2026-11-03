import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/model_center/cloud_asr_adapters.dart';
import 'package:video_player_app/features/model_center/cloud_asr_parser.dart';
import 'package:video_player_app/features/model_center/cloud_asr_transport.dart';
import 'package:video_player_app/features/model_center/cloud_asr_types.dart';

import 'cloud_asr_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File audio;
  setUp(() async {
    HttpOverrides.global = null;
    root = await Directory.systemTemp.createTemp('cloud-asr-contract-');
    audio = await File(
      '${root.path}/segment.mp3',
    ).writeAsBytes([73, 68, 51, 0, 1, 2, 3]);
  });
  tearDown(() async => root.delete(recursive: true));

  for (final provider in CloudAsrProvider.values) {
    test(
      '${provider.name}: real wire upload, authentication, options, result and cleanup',
      () async {
        final server = await CloudWireServer.start();
        addTearDown(server.close);
        final options = CloudAsrOptions(
          hotwords: provider == CloudAsrProvider.gemini ? [] : ['Codex', '字幕'],
        );
        final adapter = CloudAsrAdapter.create(
          cloudConnection(
            provider,
            endpoint: server.endpoint,
            options: options,
          ),
          dio: cloudTestDio(),
        );
        addTearDown(adapter.close);
        final state = <String, dynamic>{},
            checkpoints = <Map<String, dynamic>>[];
        Future<void> save() async => checkpoints.add(
          jsonDecode(jsonEncode(state)) as Map<String, dynamic>,
        );
        server.handler = (request, response) {
          final auth = switch (provider) {
            CloudAsrProvider.elevenlabs => request.headers['xi-api-key'],
            CloudAsrProvider.gemini => request.headers['x-goog-api-key'],
            _ => request.headers['authorization'],
          };
          expect(auth, switch (provider) {
            CloudAsrProvider.soniox => 'Bearer test-secret',
            CloudAsrProvider.deepgram => 'Token test-secret',
            _ => 'test-secret',
          });
          expect(request.uri.queryParameters.containsKey('key'), isFalse);
          if (request.method == 'DELETE') {
            expect(
              state['response'],
              isNotNull,
              reason: 'Retain paid response until caller persists subtitles',
            );
            response.write('{}');
            return;
          }
          final path = request.uri.path;
          if (path == '/v1/speech-to-text') {
            expect(
              request.headers['content-type'],
              startsWith('multipart/form-data;'),
            );
            expect(request.text, contains('name="model_id"\r\n\r\nscribe_v2'));
            expect(
              request.text,
              contains('name="timestamps_granularity"\r\n\r\nword'),
            );
            expect(request.text, isNot(contains('name="language_code"')));
            expect('name="keyterms"'.allMatches(request.text).length, 2);
            expect(request.text, isNot(contains('keyterms[]')));
            expect(request.text, contains('filename="segment.mp3"'));
            expect(request.text, contains('content-type: audio/mpeg'));
            expect(state['submitting'], isTrue);
            response.write(jsonEncode(cloudReply(provider)));
          } else if (path == '/v1/files' &&
              provider == CloudAsrProvider.soniox) {
            expect(request.text, contains('filename="segment.mp3"'));
            response.write('{"id":"file-1"}');
          } else if (path == '/v1/transcriptions' && request.method == 'POST') {
            expect(request.json['model'], 'stt-async-v5');
            expect(request.json['file_id'], 'file-1');
            expect(request.json['context'], {
              'terms': ['Codex', '字幕'],
            });
            expect(request.json['language_hints'], isNull);
            expect(state['submitting'], isTrue);
            response.write('{"id":"job-1","status":"queued"}');
          } else if (path == '/v1/transcriptions/job-1') {
            response.write('{"id":"job-1","status":"completed"}');
          } else if (path == '/v1/transcriptions/job-1/transcript') {
            response.write(jsonEncode(cloudReply(provider)));
          } else if (path == '/v2/upload') {
            expect(request.headers['content-type'], 'application/octet-stream');
            expect(request.bytes, awaitBytes);
            response.write(
              '{"upload_url":"https://cdn.assemblyai.com/upload/file-1"}',
            );
          } else if (path == '/v2/transcript' && request.method == 'POST') {
            expect(request.json['speech_models'], ['universal-3-5-pro']);
            expect(request.json.containsKey('speech_model'), isFalse);
            expect(request.json['language_detection'], true);
            expect(request.json['keyterms_prompt'], ['Codex', '字幕']);
            expect(state['uploadUrl'], isNotNull);
            expect(state['submitting'], isTrue);
            response.write('{"id":"job-1","status":"queued"}');
          } else if (path == '/v2/transcript/job-1') {
            response.write(jsonEncode(cloudReply(provider)));
          } else if (path == '/v1/listen') {
            expect(request.bytes, awaitBytes);
            expect(request.headers['content-type'], 'audio/mpeg');
            expect(request.uri.queryParameters['model'], 'nova-3');
            expect(request.uri.queryParameters['language'], 'multi');
            expect(request.uri.queryParametersAll['keyterm'], ['Codex', '字幕']);
            expect(
              request.uri.queryParameters.containsKey('keyterm[]'),
              isFalse,
            );
            expect(state['submitting'], isTrue);
            response.write(jsonEncode(cloudReply(provider)));
          } else if (path == '/upload/v1beta/files') {
            expect(request.headers['x-goog-upload-protocol'], 'resumable');
            expect(request.headers['x-goog-upload-command'], 'start');
            expect(request.headers['x-goog-upload-header-content-length'], '7');
            expect(
              request.headers['x-goog-upload-header-content-type'],
              'audio/mpeg',
            );
            response.headers.set(
              'x-goog-upload-url',
              '${server.endpoint}/upload/session',
            );
            response.write('{}');
          } else if (path == '/upload/session') {
            expect(request.bytes, awaitBytes);
            expect(request.headers['x-goog-upload-offset'], '0');
            expect(
              request.headers['x-goog-upload-command'],
              'upload, finalize',
            );
            response.write(
              '{"file":{"name":"files/file-1","uri":"https://generativelanguage.googleapis.com/v1beta/files/file-1","state":"ACTIVE"}}',
            );
          } else if (path == '/v1beta/interactions') {
            final config =
                request.json['generation_config']['transcription_config'];
            expect(config['mode'], {
              'type': 'verbatim',
              'timestamp_granularities': ['word'],
            });
            expect(config.containsKey('custom_vocabulary'), isFalse);
            expect(config.containsKey('language_codes'), isFalse);
            expect(request.json['model'], 'gemini-3.5-transcribe');
            expect(request.json['input'][0]['type'], 'audio');
            expect(state['submitting'], isTrue);
            response.write(jsonEncode(cloudReply(provider)));
          } else {
            fail('Unexpected request ${request.method} $path');
          }
        };
        final result = await adapter.transcribe(
          filePath: audio.path,
          duration: const Duration(seconds: 1),
          state: state,
          save: save,
          token: CancelToken(),
          progress: (_, _, _) {},
        );
        expect(result.cues.single.text, 'Hello world');
        if (provider == CloudAsrProvider.deepgram) {
          expect(result.languages, ['en']);
        }
        expect(result.cues.single.startTime, const Duration(milliseconds: 100));
        expect(result.cues.single.endTime, const Duration(milliseconds: 800));
        expect(result.cues.single.timedSpans, isNotEmpty);
        expect(checkpoints.any((s) => s['submitting'] == true), isTrue);
        expect(state['response'], isNotNull);
        expect(jsonEncode(state), isNot(contains('test-secret')));
        final calls = server.requests.length;
        // A saved paid response is usable after a process restart without the source file.
        await adapter.transcribe(
          filePath: null,
          duration: const Duration(seconds: 1),
          state: state,
          save: save,
          token: CancelToken(),
          progress: (_, _, _) {},
        );
        expect(server.requests.length, calls);
        await adapter.cleanup(state, save, CancelToken());
        expect(state['cleaned'], true);
        expect(state.containsKey('response'), false);
        final cleanupPaths = server.requests
            .where((r) => r.method == 'DELETE')
            .map((r) => r.uri.path);
        expect(cleanupPaths, switch (provider) {
          CloudAsrProvider.elevenlabs => [
            '/v1/speech-to-text/transcripts/transcript-1',
          ],
          CloudAsrProvider.soniox => [
            '/v1/transcriptions/job-1',
            '/v1/files/file-1',
          ],
          CloudAsrProvider.assemblyai => ['/v2/transcript/job-1'],
          CloudAsrProvider.gemini => [
            '/v1beta/interactions/example',
            '/v1beta/files/file-1',
          ],
          _ => <String>[],
        });
      },
    );
  }

  test(
    'async resume queries the original paid task, with no upload or POST',
    () async {
      for (final provider in [
        CloudAsrProvider.soniox,
        CloudAsrProvider.assemblyai,
      ]) {
        final server = await CloudWireServer.start();
        final adapter = CloudAsrAdapter.create(
          cloudConnection(provider, endpoint: server.endpoint),
          dio: cloudTestDio(),
        );
        try {
          server.handler = (request, response) {
            expect(request.method, 'GET');
            response.write(
              jsonEncode(
                request.uri.path.endsWith('/transcript') ||
                        provider == CloudAsrProvider.assemblyai
                    ? cloudReply(provider)
                    : {'id': 'job-1', 'status': 'completed'},
              ),
            );
          };
          final state = <String, dynamic>{
            'taskId': 'job-1',
            'submitting': true,
          };
          await adapter.transcribe(
            filePath: null,
            duration: const Duration(seconds: 1),
            state: state,
            save: () async {},
            token: CancelToken(),
            progress: (_, _, _) {},
          );
          expect(server.requests, isNotEmpty);
        } finally {
          adapter.close();
          await server.close();
        }
      }
    },
  );

  test(
    'unknown paid submission never retries, including after reload',
    () async {
      final server = await CloudWireServer.start();
      addTearDown(server.close);
      server.handler = (_, response) {
        response.statusCode = 503;
        response.write('{"error":"do not echo test-secret"}');
      };
      final adapter = CloudAsrAdapter.create(
        cloudConnection(CloudAsrProvider.elevenlabs, endpoint: server.endpoint),
        dio: cloudTestDio(),
      );
      addTearDown(adapter.close);
      var state = <String, dynamic>{};
      Future<void> invoke() => adapter.transcribe(
        filePath: audio.path,
        duration: const Duration(seconds: 1),
        state: state,
        save: () async {},
        token: CancelToken(),
        progress: (_, _, _) {},
      );
      await expectLater(
        invoke(),
        throwsA(
          isA<CloudAsrException>().having(
            (e) => '$e',
            'safe message',
            isNot(contains('test-secret')),
          ),
        ),
      );
      expect(state['submitting'], true);
      state = jsonDecode(jsonEncode(state)) as Map<String, dynamic>;
      await expectLater(
        invoke(),
        throwsA(
          isA<CloudAsrException>().having(
            (e) => '$e',
            'message',
            contains('结果未知'),
          ),
        ),
      );
      expect(server.requests.length, 1);
    },
  );

  test(
    'explicit rejection permits safe correction; rate limit reduces concurrency',
    () async {
      final server = await CloudWireServer.start();
      addTearDown(server.close);
      server.handler = (_, response) {
        if (server.requests.length == 1) {
          response.statusCode = 429;
          response.headers.set('retry-after', '1');
          response.write('{}');
        } else {
          response.write(jsonEncode(cloudReply(CloudAsrProvider.deepgram)));
        }
      };
      final adapter = CloudAsrAdapter.create(
        cloudConnection(CloudAsrProvider.deepgram, endpoint: server.endpoint),
        dio: cloudTestDio(),
      );
      addTearDown(adapter.close);
      final state = <String, dynamic>{};
      final watch = Stopwatch()..start();
      await adapter.transcribe(
        filePath: audio.path,
        duration: const Duration(seconds: 1),
        state: state,
        save: () async {},
        token: CancelToken(),
        progress: (_, _, _) {},
      );
      expect(state['submitting'], false);
      expect(adapter.transport.budget.segments.limit, 1);
      expect(server.requests.length, 2);
      expect(watch.elapsed, greaterThanOrEqualTo(const Duration(seconds: 1)));
      expect(CloudAsrTransport.retryAfter('2'), const Duration(seconds: 2));
      expect(CloudAsrTransport.retryAfter('bad'), isNull);
    },
  );

  test(
    'upload reference to another host is rejected before sending a key',
    () async {
      final server = await CloudWireServer.start();
      addTearDown(server.close);
      server.handler = (_, response) {
        response.headers.set(
          'x-goog-upload-url',
          'https://untrusted.invalid/upload',
        );
        response.write('{}');
      };
      final adapter = CloudAsrAdapter.create(
        cloudConnection(CloudAsrProvider.gemini, endpoint: server.endpoint),
        dio: cloudTestDio(),
      );
      addTearDown(adapter.close);
      await expectLater(
        adapter.transcribe(
          filePath: audio.path,
          duration: const Duration(seconds: 1),
          state: {},
          save: () async {},
          token: CancelToken(),
          progress: (_, _, _) {},
        ),
        throwsA(isA<CloudAsrException>()),
      );
      expect(server.requests.length, 1);
    },
  );

  for (final provider in CloudAsrProvider.values) {
    test(
      '${provider.name}: incompatible shape and text without timestamps fail',
      () {
        expect(
          () => parseCloudAsrResult(provider, {}),
          throwsA(isA<CloudAsrException>()),
        );
        final data = cloudReply(provider);
        switch (provider) {
          case CloudAsrProvider.elevenlabs || CloudAsrProvider.assemblyai:
            data['words'] = [];
          case CloudAsrProvider.soniox:
            data['tokens'][0].remove('start_ms');
          case CloudAsrProvider.deepgram:
            data['results']['channels'][0]['alternatives'][0]['words'] = [];
          case CloudAsrProvider.gemini:
            data['steps'][0]['content'][0]['annotations'] = [];
        }
        expect(
          () => parseCloudAsrResult(provider, data),
          throwsA(isA<CloudAsrException>()),
        );
      },
    );
  }

  test(
    'Unicode graphemes retain exact spans; Soniox subwords do not insert spaces',
    () {
      final result = parseCloudAsrResult(CloudAsrProvider.soniox, {
        'tokens': [
          {'text': '你', 'start_ms': 1200, 'end_ms': 1400},
          {'text': '好', 'start_ms': 1400, 'end_ms': 1500},
          {'text': ' e', 'start_ms': 1600, 'end_ms': 1700},
          {'text': '\u0301', 'start_ms': 1700, 'end_ms': 1750},
          {'text': ' 👩‍💻', 'start_ms': 1800, 'end_ms': 2000},
        ],
      });
      final cue = result.cues.single;
      expect(cue.text, '你好 e\u0301 👩‍💻');
      expect(
        cue.timedSpans.any((s) => s.textEnd == 4),
        false,
        reason: 'No split inside e + combining accent',
      );
      expect(cue.startTime.inMilliseconds, 1200);
      expect(cue.endTime.inMilliseconds, 2000);
    },
  );

  test(
    'ElevenLabs character timings use the service values, ignoring spacing/events',
    () {
      final result = parseCloudAsrResult(CloudAsrProvider.elevenlabs, {
        'words': [
          {
            'text': '你好',
            'type': 'word',
            'start': 1,
            'end': 2,
            'characters': [
              {'text': '你', 'start': 1.1, 'end': 1.3},
              {'text': '好', 'start': 1.5, 'end': 1.9},
            ],
          },
        ],
      });
      expect(
        result.cues.single.timedSpans.map((s) => s.startTime.inMilliseconds),
        [1100, 1500],
      );
    },
  );

  test(
    'silence with an explicit empty words array is valid; empty files are not uploaded',
    () async {
      expect(
        parseCloudAsrResult(CloudAsrProvider.elevenlabs, {
          'text': '',
          'words': [],
        }).cues,
        isEmpty,
      );
      final adapter = CloudAsrAdapter.create(
        cloudConnection(CloudAsrProvider.elevenlabs),
        dio: cloudTestDio(),
      );
      addTearDown(adapter.close);
      await audio.writeAsBytes([]);
      await expectLater(
        adapter.transcribe(
          filePath: audio.path,
          duration: const Duration(seconds: 1),
          state: {},
          save: () async {},
          token: CancelToken(),
          progress: (_, _, _) {},
        ),
        throwsA(isA<CloudAsrException>()),
      );
    },
  );

  test(
    'Google word timing excludes hotwords and unsafe capabilities are disabled',
    () {
      final caps = cloudAsrCapabilities(
        CloudAsrProvider.gemini,
        'gemini-3.5-transcribe',
      );
      expect(caps.maxSeconds, 1800);
      expect(
        () => const CloudAsrOptions(
          hotwords: ['term'],
        ).validate(CloudAsrProvider.gemini, caps),
        throwsStateError,
      );
      final unknown = cloudAsrCapabilities(
        CloudAsrProvider.soniox,
        'future-v99',
      );
      expect(unknown.documented, false);
      expect(unknown.languages, isEmpty);
      expect(
        () => const CloudAsrOptions(
          diarize: true,
        ).validate(CloudAsrProvider.soniox, unknown),
        throwsStateError,
      );
    },
  );

  test(
    'Google time unit changes and unsupported language fail instead of guessing',
    () async {
      final google =
          jsonDecode(jsonEncode(cloudReply(CloudAsrProvider.gemini)))
              as Map<String, dynamic>;
      google['steps'][0]['content'][0]['annotations'][0]['start_offset'] = 100;
      expect(
        () => parseCloudAsrResult(CloudAsrProvider.gemini, google),
        throwsA(isA<CloudAsrException>()),
      );
      final adapter = CloudAsrAdapter.create(
        cloudConnection(CloudAsrProvider.assemblyai, language: 'ko'),
        dio: cloudTestDio(),
      );
      addTearDown(adapter.close);
      await expectLater(
        adapter.transcribe(
          filePath: audio.path,
          duration: const Duration(seconds: 1),
          state: {},
          save: () async {},
          token: CancelToken(),
          progress: (_, _, _) {},
        ),
        throwsA(
          isA<CloudAsrException>().having(
            (e) => '$e',
            'message',
            contains('不支持'),
          ),
        ),
      );
    },
  );

  test(
    'new Deepgram models do not assume multilingual support or enable model fallback',
    () async {
      final server = await CloudWireServer.start();
      addTearDown(server.close);
      for (final languages in [
        <String>[],
        ['en'],
      ]) {
        server.handler = (request, response) {
          expect(request.uri.queryParameters['model'], 'future-file-model');
          expect(
            request.uri.queryParameters['language'],
            languages.isEmpty ? isNull : 'en',
          );
          expect(
            request.uri.queryParameters.containsKey('detect_language'),
            false,
          );
          response.write(jsonEncode(cloudReply(CloudAsrProvider.deepgram)));
        };
        final adapter = CloudAsrAdapter.create(
          cloudConnection(
            CloudAsrProvider.deepgram,
            endpoint: server.endpoint,
            model: 'future-file-model',
            capabilities: CloudAsrCapabilities(languages: languages),
          ),
          dio: cloudTestDio(),
        );
        try {
          final result = await adapter.transcribe(
            filePath: audio.path,
            duration: const Duration(seconds: 1),
            state: {},
            save: () async {},
            token: CancelToken(),
            progress: (_, _, _) {},
          );
          expect(result.cues.single.text, 'Hello world');
        } finally {
          adapter.close();
        }
      }
    },
  );

  test(
    'long optional vocabulary is checked cheaply before sending a paid request',
    () {
      expect(
        () =>
            CloudAsrOptions(hotwords: [List.filled(500, '字').join()]).validate(
              CloudAsrProvider.deepgram,
              cloudAsrCapabilities(CloudAsrProvider.deepgram, 'nova-3'),
            ),
        throwsStateError,
      );
      expect(
        () =>
            CloudAsrOptions(hotwords: [List.filled(8000, '字').join()]).validate(
              CloudAsrProvider.soniox,
              cloudAsrCapabilities(CloudAsrProvider.soniox, 'stt-async-v5'),
            ),
        throwsStateError,
      );
    },
  );
}

const awaitBytes = [73, 68, 51, 0, 1, 2, 3];
