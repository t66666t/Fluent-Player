import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/cloud_asr_catalog.dart';
import 'package:video_player_app/features/model_center/asr_language_options.dart';
import 'package:video_player_app/features/model_center/cloud_asr_parser.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/services/app_storage_service.dart';

import 'cloud_asr_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStorageService storage;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    HttpOverrides.global = null;
    root = await Directory.systemTemp.createTemp('cloud-asr-catalog-');
    storage = await cloudTestStorage(root);
  });
  tearDown(() async => root.delete(recursive: true));

  for (final provider in [CloudAsrProvider.soniox, CloudAsrProvider.deepgram]) {
    test(
      '${provider.name}: discover only file models, retain missing selected models and cache across restarts',
      () async {
        final server = await CloudWireServer.start();
        addTearDown(server.close);
        final connection = cloudConnection(provider, endpoint: server.endpoint);
        final store = CloudAsrCatalogStore(storage, createDio: cloudTestDio);
        final initial = await store.load(connection);
        expect(initial.stale, true);
        expect(
          server.requests,
          isEmpty,
          reason: 'Reading cached metadata never needs network',
        );
        final entries = [
          if (provider == CloudAsrProvider.soniox) ...[
            {
              'id': 'future-async',
              'name': 'New file model',
              'transcription_mode': 'async',
              'languages': [
                {'code': 'zh', 'name': 'Chinese'},
                {'code': 'en', 'name': 'English'},
              ],
              'future_flag': true,
            },
            {
              'id': 'future-realtime',
              'transcription_mode': 'real_time',
              'languages': ['en'],
            },
            {'id': 'future-no-metadata', 'transcription_mode': 'async'},
          ] else ...[
            {
              'canonical_name': 'nova-future',
              'name': 'different display',
              'batch': true,
              'languages': ['zh', 'en'],
              'version': 'new',
              'future_flag': true,
            },
            {
              'canonical_name': 'flux-realtime',
              'batch': false,
              'languages': ['en'],
            },
            {'canonical_name': 'future-no-metadata', 'batch': true},
          ],
        ];
        server.handler = (_, response) => response.write(
          jsonEncode({
            provider == CloudAsrProvider.soniox ? 'models' : 'stt': entries,
          }),
        );
        final refreshed = await store.refresh(connection, CancelToken());
        final id = provider == CloudAsrProvider.soniox
            ? 'future-async'
            : 'nova-future';
        final model = refreshed.models.singleWhere((m) => m.id == id);
        expect(model.capabilities.languages, ['zh', 'en']);
        expect(model.capabilities.documented, false);
        expect(model.capabilities.speakers, false);
        expect(model.capabilities.maxHotwords, 0);
        expect(model.capabilities.wordTimestamps, false);
        expect(refreshed.models.any((m) => m.id.contains('realtime')), false);
        expect(
          refreshed.models
              .singleWhere((m) => m.id == 'future-no-metadata')
              .capabilities
              .languages,
          isEmpty,
        );
        expect(refreshed.models.any((m) => m.id == connection.model), true);
        expect(connection.model, provider.defaultModel);
        final cached = await CloudAsrCatalogStore(storage).load(connection);
        expect(cached.stale, false);
        expect(
          cached.models.map((m) => m.id),
          refreshed.models.map((m) => m.id),
        );
        expect(server.requests.length, 1);
        // A vendor's removal is not permission to switch a user's model.
        server.handler = (_, response) => response.write(
          jsonEncode({
            provider == CloudAsrProvider.soniox ? 'models' : 'stt': [],
          }),
        );
        expect(
          (await store.refresh(
            connection,
            CancelToken(),
          )).models.any((m) => m.id == id),
          true,
        );
        expect(
          parseCloudAsrResult(
            provider,
            cloudReply(provider),
            requestedModel: id,
          ).cues,
          isNotEmpty,
        );
        // Another account must not inherit this account's private model metadata.
        final other = await store.load(
          cloudConnection(
            provider,
            endpoint: server.endpoint,
            key: 'other-secret',
          ),
        );
        expect(other.models.any((m) => m.id == id), false);
      },
    );
  }

  test(
    'Google pagination filters live/general models; incomplete listing retains builtin and manual selection',
    () async {
      final server = await CloudWireServer.start();
      addTearDown(server.close);
      server.handler = (request, response) {
        expect(request.uri.queryParameters['pageSize'], '200');
        response.write(
          jsonEncode(
            request.uri.queryParameters['pageToken'] == null
                ? {
                    'models': [
                      {'name': 'models/gemini-future-transcribe'},
                      {'name': 'models/gemini-future-transcribe-live'},
                      {'name': 'models/general-model'},
                    ],
                    'nextPageToken': 'next',
                  }
                : {
                    'models': [
                      {
                        'name': 'models/gemini-next-transcribe',
                        'new_field': true,
                      },
                    ],
                  },
          ),
        );
      };
      final connection = cloudConnection(
        CloudAsrProvider.gemini,
        endpoint: server.endpoint,
        model: 'manual-unlisted-model',
      );
      final store = CloudAsrCatalogStore(storage, createDio: cloudTestDio);
      final list = await store.refresh(connection, CancelToken());
      expect(server.requests.length, 2);
      expect(list.models.map((m) => m.id), [
        'gemini-3.5-transcribe',
        'gemini-future-transcribe',
        'gemini-next-transcribe',
      ]);
      expect(connection.model, 'manual-unlisted-model');
      expect(
        parseCloudAsrResult(
          connection.provider,
          cloudReply(connection.provider),
          requestedModel: connection.model,
        ).model,
        'manual-unlisted-model',
      );
    },
  );

  test(
    'list failure and expired metadata preserve the last valid cache',
    () async {
      final server = await CloudWireServer.start();
      addTearDown(server.close);
      final connection = cloudConnection(
        CloudAsrProvider.soniox,
        endpoint: server.endpoint,
      );
      final store = CloudAsrCatalogStore(storage, createDio: cloudTestDio);
      server.handler = (_, response) => response.write(
        '{"models":[{"id":"saved-model","transcription_mode":"async"}]}',
      );
      await store.refresh(connection, CancelToken());
      final files = (await storage.featureDirectory(
        'model_jobs',
      )).listSync().whereType<File>();
      final file = files.singleWhere((f) => f.path.endsWith('.json'));
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      json['fetchedAt'] = DateTime.now()
          .subtract(const Duration(hours: 25))
          .toUtc()
          .toIso8601String();
      await writeStorageJson(file, json);
      expect((await store.load(connection)).stale, true);
      server.handler = (_, response) {
        response.statusCode = 401;
        response.write('{"error":"secret must not be echoed"}');
      };
      await expectLater(
        store.refresh(connection, CancelToken()),
        throwsA(anything),
      );
      final restored = await store.load(connection);
      expect(restored.models.any((m) => m.id == 'saved-model'), true);
      expect(restored.stale, true);
    },
  );

  test(
    'undocumented enumeration uses builtins without any paid probe',
    () async {
      var created = 0;
      final store = CloudAsrCatalogStore(
        storage,
        createDio: () {
          created++;
          return cloudTestDio();
        },
      );
      final list = await store.refresh(
        cloudConnection(CloudAsrProvider.assemblyai),
        CancelToken(),
      );
      expect(list.remote, false);
      expect(list.models.single.id, 'universal-3-5-pro');
      expect(list.stale, false);
      expect(created, 1);
    },
  );

  test(
    'captured cloud tasks freeze options, model, capabilities and protocol without a secret',
    () async {
      final center = ModelCenterService(storage: storage)..loaded = true;
      addTearDown(center.dispose);
      final hotwords = ['old term'];
      final caps = cloudAsrCapabilities(
        CloudAsrProvider.soniox,
        'stt-async-v5',
      );
      final languages = [...caps.languages];
      center.profiles['mine'] = ModelServiceProfile(
        id: 'mine',
        name: 'Soniox',
        kind: TranscriptionServiceKind.soniox,
        model: 'stt-async-v5',
        cloudOptions: CloudAsrOptions(hotwords: hotwords),
        cloudCapabilities: CloudAsrCapabilities(
          languages: languages,
          maxHotwords: 1000,
        ),
      );
      center.asrProfileId = 'mine';
      final frozen = center.transcriptionConfiguration;
      final before = jsonEncode(frozen.toJson()),
          fingerprint = frozen.recognitionFingerprint;
      hotwords.add('later term');
      languages.add('new');
      center.profiles['mine'] = const ModelServiceProfile(
        id: 'mine',
        name: 'Soniox',
        kind: TranscriptionServiceKind.soniox,
        model: 'future-model',
      );
      expect(jsonEncode(frozen.toJson()), before);
      expect(frozen.recognitionFingerprint, fingerprint);
      expect(frozen.profile.cloudOptions!.contractVersion, 1);
      expect(frozen.profile.cloudOptions!.hotwords, ['old term']);
      expect(
        frozen.profile.cloudCapabilities!.languages,
        isNot(contains('new')),
      );
      expect(center.transcriptionConfiguration.profile.model, 'future-model');
      expect(
        ModelJobSpec.fromJson(frozen.toJson()).recognitionFingerprint,
        fingerprint,
      );
    },
  );

  test(
    'legacy profile serialization never gains cloud fields; retired menus do not retire tasks',
    () {
      for (final kind in [
        TranscriptionServiceKind.local,
        TranscriptionServiceKind.gongyi,
        TranscriptionServiceKind.openai,
        TranscriptionServiceKind.tencent,
        TranscriptionServiceKind.aliyun,
      ]) {
        final profile = ModelServiceProfile(
          id: kind == TranscriptionServiceKind.gongyi ? 'gongyi' : 'legacy',
          name: kind == TranscriptionServiceKind.gongyi ? '公益接口' : 'old',
          kind: kind,
          model: 'original',
        );
        expect(profile.toJson().containsKey('cloudOptions'), false);
        expect(profile.toJson().containsKey('cloudCapabilities'), false);
        expect(
          ModelServiceProfile.fromJson(profile.toJson()).toJson(),
          profile.toJson(),
        );
      }
    },
  );

  test(
    'language catalogs stay model-specific and reject unconfirmed old languages',
    () {
      final eleven = cloudAsrCapabilities(
        CloudAsrProvider.elevenlabs,
        'scribe_v2',
      );
      expect(cloudAsrLanguageLabel('zh-HK'), '粤语（zh-HK）');
      expect(
        eleven.languages,
        containsAll(['zh', 'yue', 'en', 'ko', 'kea', 'wo', 'xh', 'zu']),
      );
      expect(eleven.languages, isNot(contains('haw')));
      final assembly = cloudAsrCapabilities(
        CloudAsrProvider.assemblyai,
        'universal-3-5-pro',
      );
      expect(assembly.languages.length, 18);
      expect(assembly.languages, isNot(contains('ko')));
      expect(
        cloudAsrCapabilities(
          CloudAsrProvider.gemini,
          'gemini-3.5-transcribe',
        ).languages,
        containsAll(['cmn-Hans-CN', 'yue-Hant-HK', 'en-US']),
      );
      expect(
        cloudAsrCapabilities(CloudAsrProvider.deepgram, 'nova-3').languages,
        containsAll(['zh', 'zh-HK', 'ko']),
      );
    },
  );
}
