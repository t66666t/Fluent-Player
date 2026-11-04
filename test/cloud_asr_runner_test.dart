import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/model_center/cloud_asr_transport.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/features/model_center/model_transcription.dart';
import 'package:video_player_app/models/subtitle_model.dart';

import 'cloud_asr_test_support.dart';

class _Secrets implements AiChatSecretStorage {
  @override
  Future<String?> read(String key) async => 'test-secret';
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'production runner resumes the paid task, persists cues, feeds translation, and cleans resources in that order',
    () async {
      SharedPreferences.setMockInitialValues({});
      HttpOverrides.global = null;
      final root = await Directory.systemTemp.createTemp('cloud-asr-runner-');
      final storage = await cloudTestStorage(root);
      final center = ModelCenterService(storage: storage, secrets: _Secrets())
        ..loaded = true;
      final server = await CloudWireServer.start();
      final source = await File(
        '${root.path}/original.mp3',
      ).writeAsBytes([73, 68, 51, 0]);
      addTearDown(() async {
        center.dispose();
        await server.close();
        await root.delete(recursive: true);
      });
      var pollingFailed = true, uploads = 0, submissions = 0, prepared = 0;
      final phases = <ModelProcessingProgress>[],
          batches = <List<SubtitleItem>>[];
      final runner = ModelTranscriptionRunner(
        center: center,
        createCloudDio: cloudTestDio,
        createLocalWorker: () =>
            throw StateError('Cloud task must not create a local model'),
        loadDeviceInfo: () =>
            throw StateError('Cloud task must not wait for hardware probing'),
      );
      server.handler = (request, response) {
        switch ((request.method, request.uri.path)) {
          case ('POST', '/v1/files'):
            uploads++;
            response.write('{"id":"file-1"}');
          case ('POST', '/v1/transcriptions'):
            submissions++;
            expect(request.json['model'], 'stt-async-v5');
            expect(request.json['language_hints'], ['en']);
            response.write('{"id":"job-1"}');
          case ('GET', '/v1/transcriptions/job-1'):
            if (pollingFailed) {
              response.statusCode = 401;
              response.write('{}');
            } else {
              response.write('{"status":"completed"}');
            }
          case ('GET', '/v1/transcriptions/job-1/transcript'):
            response.write(jsonEncode(cloudReply(CloudAsrProvider.soniox)));
          case ('DELETE', _):
            final files = Directory('${root.path}/data/model_jobs').existsSync()
                ? Directory(
                    '${root.path}/data/model_jobs',
                  ).listSync().whereType<File>()
                : <File>[];
            // The normalized cue checkpoint must precede every remote deletion.
            expect(
              files.any(
                (f) =>
                    f.path.contains('asr-') &&
                    f.readAsStringSync().contains('Hello world'),
              ),
              true,
            );
            response.write('{}');
          default:
            fail(
              'Unexpected wire request ${request.method} ${request.uri.path}',
            );
        }
      };
      final connection = cloudConnection(
        CloudAsrProvider.soniox,
        endpoint: server.endpoint,
      );
      final spec = ModelJobSpec(
        profile: ModelServiceProfile(
          id: 'mine',
          name: 'Soniox',
          kind: TranscriptionServiceKind.soniox,
          endpoint: server.endpoint,
          model: connection.model,
          language: 'en',
          cloudOptions: connection.options,
          cloudCapabilities: connection.capabilities,
        ),
        artifactIdentity: '',
        threads: 2,
      );
      Future<List<SubtitleItem>> run() => runner.run(
        spec: ModelJobSpec.fromJson(
          jsonDecode(jsonEncode(spec.toJson())) as Map<String, dynamic>,
        ),
        sourceIdentity: 'same media revision',
        checkpointScope: 'existing queue task',
        duration: const Duration(seconds: 1),
        prepareAudio: (_, _, _, _) => throw StateError(
          'Cloud task must use lazy cloud audio preparation',
        ),
        prepareCloudAudio: (_, _, _, _) async {
          prepared++;
          return CloudAsrAudio(source.path, temporary: false);
        },
        onProgress: phases.add,
        onStableBatch: (batch) async {
          batches.add(batch.cues);
        },
      );
      await expectLater(run(), throwsA(isA<CloudAsrException>()));
      expect(uploads, 1);
      expect(submissions, 1);
      expect(prepared, 1);
      expect(batches, isEmpty);
      pollingFailed = false;
      // Changing the next-task settings cannot replace the frozen interrupted task.
      center.profiles['mine'] = const ModelServiceProfile(
        id: 'mine',
        name: 'new settings',
        kind: TranscriptionServiceKind.deepgram,
        model: 'future-model',
      );
      final result = await run();
      expect(result.single.text, 'Hello world');
      expect(result.single.startTime.inMilliseconds, 100);
      expect(batches.single.single.text, 'Hello world');
      expect(batches.single.single.index, 1);
      expect(uploads, 1);
      expect(submissions, 1);
      expect(prepared, 1);
      expect(phases.last.stage, ModelProcessingStage.saving);
      expect(phases.last.fraction, 1);
      expect(server.requests.where((r) => r.method == 'DELETE').length, 2);
      final jobs = (await storage.featureDirectory(
        'model_jobs',
      )).listSync().whereType<File>().toList();
      expect(
        jobs.every((f) => !f.readAsStringSync().contains('test-secret')),
        true,
      );
      final wireCount = server.requests.length;
      batches.clear();
      await run();
      expect(server.requests.length, wireCount);
      expect(prepared, 1);
      expect(await source.exists(), true);
    },
  );

  test(
    'polling advances 1/2/3 seconds, slows a queued minute, and respects server minimum',
    () {
      Duration delay(String status, int queries, int age, [String? retry]) =>
          cloudPollingDelay(
            status: status,
            unchangedQueries: queries,
            age: Duration(seconds: age),
            retryAfter: retry,
          );
      expect(delay('queued', 1, 0), const Duration(seconds: 1));
      expect(delay('queued', 2, 2), const Duration(seconds: 2));
      expect(delay('queued', 9, 20), const Duration(seconds: 3));
      expect(delay('queued', 9, 61), const Duration(seconds: 5));
      expect(delay('processing', 1, 100), const Duration(seconds: 1));
      expect(delay('processing', 1, 0, '8'), const Duration(seconds: 8));
    },
  );
}
