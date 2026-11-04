import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:video_player_app/features/external_ai/external_ai_action_backend.dart';
import 'package:video_player_app/features/external_ai/external_ai_action_store.dart';
import 'package:video_player_app/features/external_ai/external_ai_actions.dart';
import 'package:video_player_app/features/external_ai/external_ai_library_source.dart';
import 'package:video_player_app/features/external_ai/external_ai_preferences.dart';
import 'package:video_player_app/features/external_ai/external_ai_server.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/features/model_center/model_transcription.dart';
import 'package:video_player_app/features/model_center/local_asr_worker.dart';
import 'package:video_player_app/features/model_center/model_adapters.dart';
import 'package:video_player_app/features/model_center/asr_enhancement_options.dart';
import 'package:video_player_app/features/model_center/asr_acceleration.dart';
import 'package:video_player_app/models/managed_subtitle_asset.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/utils/subtitle_parser.dart';
import 'package:video_player_app/utils/app_data_paths.dart';

class _RealHttp extends HttpOverrides {}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

class _PreparedCenter extends ModelCenterService {
  _PreparedCenter({this.weightsRoot = ''});
  final String weightsRoot;
  @override
  Future<Directory> modelDirectory(ModelArtifact model) => weightsRoot.isEmpty
      ? super.modelDirectory(model)
      : Future.value(Directory(p.join(weightsRoot, model.id)));
  int downloadAttempts = 0;
  @override
  Future<String> readSecret(String profileId) async => 'test-fixture-key';
  @override
  Future<void> initialize() async {}
  @override
  Future<ModelJobSpec> captureTranscription() async =>
      throw StateError('stop user restart before inference');
  @override
  Future<void> enqueue(String id) async {
    downloadAttempts++;
    throw StateError('downloads forbidden');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File source, mediaFile;
  late AppStorageService storage, previousStorage;
  late LibraryService library;
  late TranscriptionManager manager;
  late _PreparedCenter center;
  late ExternalAiPreferences prefs;
  late ExternalAiActions actions;
  late ExternalAiLibrarySource reader;
  late ExternalAiServer server;
  late MediaPlaybackService playback;
  late HttpClient client;
  late PathProviderPlatform previousPaths;
  HttpOverrides? previousHttp;
  final settings = SettingsService();
  const id = 'mcp-real-card';
  const nativeRoot = String.fromEnvironment('MCP_NATIVE_MODEL_ROOT');
  final nativeEnabled = Platform.isWindows && nativeRoot.isNotEmpty;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mcp-real-player-');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    SharedPreferences.setMockInitialValues({});
    settings.resetForTest();
    previousStorage = AppStorageService.instance;
    storage = AppStorageService(
      locations: () async => StorageLocations(
        platform: StoragePlatform.windows,
        support: Directory(p.join(root.path, 'support')),
        documents: Directory(p.join(root.path, 'documents')),
        defaultData: Directory(p.join(root.path, 'data')),
        executable: Directory(p.join(root.path, 'program')),
      ),
    );
    AppStorageService.instance = storage;
    await storage.initialize();
    settings.largeDataRootPath = p.join(root.path, 'data');
    library = LibraryService()..resetLibraryForTesting();
    await library.init(deferMaintenance: true);
    mediaFile = await File(
      p.join(root.path, 'private.mp4'),
    ).writeAsString('private media sentinel; not decoded or transferred');
    source = await File(p.join(root.path, 'original.srt')).writeAsString(
      '1\n00:00:01,234 --> 00:00:02,345\nHello world\n\n2\n00:00:03,456 --> 00:00:04,567\nSecond line\n\n',
    );
    library.seedVideoForTesting(
      VideoItem(
        id: id,
        path: mediaFile.path,
        title: '测试课程',
        durationMs: 6000,
        lastUpdated: 0,
        subtitlePath: source.path,
        hasProbedChapters: true,
      ),
    );
    center = _PreparedCenter(weightsRoot: nativeRoot);
    center.catalog = await loadModelCatalog();
    for (final model in center.catalog) {
      center.downloads[model.id] = ModelDownload(artifactId: model.id)
        ..phase = ModelDownloadPhase.installed;
    }
    ModelTranscriptionRunner? runner;
    if (nativeEnabled) {
      final config =
          jsonDecode(
                await File('.dart_tool/package_config.json').readAsString(),
              )
              as Map;
      final package = (config['packages'] as List).cast<Map>().singleWhere(
        (p) => p['name'] == 'sherpa_onnx_windows',
      );
      final directory = p.join(
        File(
          '.dart_tool/package_config.json',
        ).absolute.uri.resolve(package['rootUri'] as String).toFilePath(),
        'windows',
      );
      runner = ModelTranscriptionRunner(
        center: center,
        createLocalWorker: () => LocalAsrWorker(
          libraryDirectory: directory,
          nativeWorkerExecutable: p.absolute(
            'native/asr/prebuilt/windows-x64/asr_worker.exe',
          ),
        ),
      );
    }
    manager = TranscriptionManager(
      modelCenter: center,
      settings: settings,
      modelRunner: runner,
    );
    await manager.initialize();
    playback = MediaPlaybackService.forTesting();
    reader = ExternalAiLibrarySource.fromLibrary(library);
    prefs = ExternalAiPreferences(
      token: ExternalAiPreferences.generateToken(),
      enabled: true,
      allowTaskControl: true,
      allowSubtitleWrite: true,
    );
    actions = ExternalAiActions(
      library: reader,
      backend: ExternalAiPlayerBackend(
        library: library,
        manager: manager,
        playback: playback,
      ),
      store: ExternalAiActionStore(root),
      preferences: () => prefs,
    );
    server = ExternalAiServer(
      dataSource: ExternalAiApplicationSource(reader, actions),
      token: prefs.token,
    );
    await server.start();
    previousHttp = HttpOverrides.current;
    HttpOverrides.global = _RealHttp();
    client = HttpClient();
  });
  tearDown(() async {
    client.close(force: true);
    HttpOverrides.global = previousHttp;
    await server.stop();
    await actions.shutdown();
    await manager.shutdown();
    manager.dispose();
    center.dispose();
    playback.dispose();
    library.resetLibraryForTesting();
    await storage.releaseForegroundLease();
    AppStorageService.instance = previousStorage;
    settings.resetForTest();
    PathProviderPlatform.instance = previousPaths;
    await root.delete(recursive: true);
  });
  Future<Map<String, dynamic>> rpc(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    final request = await client.postUrl(server.endpoint!);
    request.headers.contentType = ContentType.json;
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${prefs.token}',
    );
    request.write(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': method,
        'params': ?params,
      }),
    );
    final response = await request.close();
    expect(response.statusCode, 200);
    return Map<String, dynamic>.from(
      jsonDecode(await utf8.decoder.bind(response).join()) as Map,
    );
  }

  Future<Map<String, dynamic>> tool(String name, Map<String, dynamic> a) async {
    final response = await rpc('tools/call', {'name': name, 'arguments': a});
    expect(response['error'], isNull, reason: jsonEncode(response));
    expect(response['result']['isError'], false, reason: jsonEncode(response));
    return Map<String, dynamic>.from(
      response['result']['structuredContent'] as Map,
    );
  }

  Future<String> documentId() async =>
      ((await tool('documents_list', {'mediaId': id}))['documents'] as List)
              .first['id']
          as String;

  test(
    'real HTTP lists truthful write annotations and native queue keeps its frozen local configuration',
    () async {
      final listed = (await rpc('tools/list'))['result']['tools'] as List;
      expect(
        listed.firstWhere(
          (t) => t['name'] == 'transcription_submit',
        )['annotations']['readOnlyHint'],
        false,
      );
      expect(
        listed.firstWhere(
          (t) => t['name'] == 'tasks_read',
        )['annotations']['readOnlyHint'],
        true,
      );
      final defaults = center.transcriptionConfiguration.toJson();
      final options = await tool('processing_options', {});
      final model = (options['models'] as List).firstWhere(
        (m) => m['purpose'] == 'transcription' && m['ready'] == true,
      );
      final languages = model['languages'] as List;
      final language = languages.last['code'] as String;
      final plan = await tool('transcription_prepare', {
        'mediaIds': [id],
        'modelId': model['id'],
        'sourceLanguage': language,
        'mode': 'transcribe',
      });
      expect(manager.getQueueSnapshot(), isEmpty);
      final submitted = await tool('transcription_submit', {
        'planId': plan['planId'],
        'requestId': 'native-submit',
      });
      final task = manager.getQueueSnapshot().single;
      final config = manager.configurationForVideo(
        mediaFile.path,
        videoId: id,
      )!;
      expect(config.transcription!.profile.model, model['id']);
      expect(config.transcription!.profile.language, language);
      expect(config.transcription!.allowModelDownload, false);
      expect(config.translation.enabled, false);
      expect(center.transcriptionConfiguration.toJson(), defaults);
      expect(center.downloadAttempts, 0);
      expect(
        manager.externalTaskIdFor(task.mediaKey),
        (submitted['taskIds'] as List).single,
      );
      final restored = TranscriptionManager(
        modelCenter: center,
        settings: settings,
      );
      await restored.initialize();
      expect(
        restored.externalTaskIdFor(task.mediaKey),
        (submitted['taskIds'] as List).single,
      );
      expect(restored.externalTaskIsLocal(task.mediaKey), true);
      expect(
        restored
            .configurationForVideo(mediaFile.path, videoId: id)!
            .transcription!
            .toJson(),
        config.transcription!.toJson(),
      );
      await restored.shutdown();
      restored.dispose();
      final read = await tool('tasks_read', {'batchId': submitted['batchId']});
      expect((read['tasks'] as List).single['status'], 'paused');
      expect(
        jsonEncode([options, plan, submitted, read]),
        isNot(contains(mediaFile.path)),
      );
      // An explicit restart in the app releases the old external generation.
      expect(manager.restartTask(task.mediaKey), true);
      expect(manager.externalTaskIdFor(task.mediaKey), null);
      final control = await tool('tasks_control', {
        'taskIds': submitted['taskIds'],
        'action': 'pause',
        'requestId': 'native-pause',
      });
      expect((control['results'] as List).single['applied'], false);
    },
  );

  test(
    'Agent translation round trip creates one real managed SRT and loads only the correct media secondary track',
    () async {
      final mediaBefore = await mediaFile.readAsBytes(),
          originalBefore = await source.readAsBytes();
      final begin = await tool('translation_begin', {
        'mediaId': id,
        'documentId': await documentId(),
        'targetLanguage': 'zh-CN',
        'requestId': 'real-begin',
      });
      final draftId = begin['draftId'];
      final read = await tool('translation_read', {'draftId': draftId});
      expect(read['entries'], hasLength(2));
      await tool('translation_write', {
        'draftId': draftId,
        'expectedRevision': 0,
        'requestId': 'real-write',
        'entries': [
          {'cueId': 'cue-1', 'text': '你好，世界 🌍'},
          {'cueId': 'cue-2', 'text': '第二行'},
        ],
      });
      playback.debugSeedCurrentItem(library.getVideo(id));
      final saved = await tool('translation_commit', {
        'draftId': draftId,
        'expectedRevision': 1,
        'requestId': 'real-commit',
        'loadAsSecondary': true,
      });
      expect(saved['loadedForCurrentMedia'], true);
      final item = library.getVideo(id)!;
      expect(item.managedSubtitleAssets, hasLength(1));
      final asset = item.managedSubtitleAssets.single;
      expect(asset.kind, ManagedSubtitleAssetKind.translated);
      expect(asset.machineGenerated, true);
      expect(asset.language, 'zh-CN');
      expect(asset.assetId, saved['assetId']);
      expect(await library.subtitleFileBelongsToCard(id, asset.path), true);
      final cues = SubtitleParser.parseSrt(
        await File(asset.path).readAsString(),
      );
      expect(cues.map((c) => c.text), ['你好，世界 🌍', '第二行']);
      expect(cues.map((c) => c.startTime.inMilliseconds), [1234, 3456]);
      expect(cues.map((c) => c.endTime.inMilliseconds), [2345, 4567]);
      expect(item.subtitlePath, source.path);
      expect(item.secondarySubtitlePath, asset.path);
      expect(playback.currentItem!.secondarySubtitlePath, asset.path);
      expect(await mediaFile.readAsBytes(), mediaBefore);
      expect(await source.readAsBytes(), originalBefore);
      await tool('translation_commit', {
        'draftId': draftId,
        'expectedRevision': 1,
        'requestId': 'another-commit',
      });
      expect(item.managedSubtitleAssets, hasLength(1));
      playback.debugSeedCurrentItem(
        VideoItem(
          id: 'different',
          title: '其他视频',
          path: mediaFile.path,
          durationMs: 0,
          lastUpdated: 0,
        ),
      );
      final selection = await tool('subtitle_select', {
        'mediaId': id,
        'assetId': asset.assetId,
        'requestId': 'select-again',
      });
      expect(selection['loadedForCurrentMedia'], false);
      expect(playback.currentItem!.secondarySubtitlePath, null);
      final docs = await tool('documents_list', {'mediaId': id});
      expect(
        (docs['documents'] as List).any((d) => d['assetId'] == asset.assetId),
        true,
      );
      expect(jsonEncode([saved, docs]), isNot(contains(root.path)));
    },
  );

  test(
    'restricted model preparation rejects missing weights without scheduling a download',
    () async {
      final spec = await center.capturePreparedLocalTranscription(
        'sensevoice-small-int8',
        'auto',
      );
      center.downloads.remove(spec.profile.model);
      await expectLater(center.prepareModel(spec), throwsStateError);
      expect(center.downloadAttempts, 0);
      await expectLater(
        center.capturePreparedLocalTranscription('dolphin-base-int8', 'en'),
        throwsArgumentError,
      );
    },
  );

  test(
    'transcribe and translate freezes the selected local model and target without changing defaults',
    () async {
      final selected = center.translationModelId;
      final translation = center.catalog.firstWhere(
        (m) => m.purpose == ModelPurpose.translation,
      );
      final plan = await tool('transcription_prepare', {
        'mediaIds': [id],
        'modelId': 'sensevoice-small-int8',
        'sourceLanguage': 'en',
        'mode': 'transcribe_translate',
        'translationModelId': translation.id,
        'targetLanguage': 'zh-CN',
      });
      await tool('transcription_submit', {
        'planId': plan['planId'],
        'requestId': 'translate-submit',
      });
      final captured = manager
          .configurationForVideo(mediaFile.path, videoId: id)!
          .translation;
      expect(captured.enabled, true);
      expect(captured.provider.name, 'local');
      expect(captured.targetLanguage, 'zh-CN');
      expect(captured.sourceLanguage, 'en');
      expect(captured.localSpecification!.profile.model, translation.id);
      expect(captured.localSpecification!.allowModelDownload, false);
      expect(center.translationModelId, selected);
      expect(center.downloadAttempts, 0);
    },
  );

  test(
    'failed native persistence is not acknowledged and the same request recovers without a duplicate task',
    () async {
      final plan = await tool('transcription_prepare', {
        'mediaIds': [id],
        'modelId': 'sensevoice-small-int8',
        'sourceLanguage': 'auto',
        'mode': 'transcribe',
      });
      final directory = await resolveAppDataDirectory();
      expect(p.isWithin(root.path, directory.path), true);
      final file = File(
        p.join(directory.path, 'transcription_queue_cache.json'),
      );
      // Drain the normal debounce writer before creating the deliberate failure.
      await manager.flushExternalTasks();
      if (await file.exists()) await file.delete();
      final obstruction = await Directory(file.path).create();
      try {
        final failed = await rpc('tools/call', {
          'name': 'transcription_submit',
          'arguments': {
            'planId': plan['planId'],
            'requestId': 'durable-submit',
          },
        });
        expect(failed['result']['isError'], true);
        expect(jsonEncode(failed), isNot(contains(root.path)));
        expect(manager.getQueueSnapshot(), hasLength(1));
      } finally {
        // Even a failed assertion cannot leave the fixture's queue obstructed.
        await obstruction.delete();
      }
      final recovered = await tool('transcription_submit', {
        'planId': plan['planId'],
        'requestId': 'durable-submit',
      });
      expect(recovered['taskIds'], hasLength(1));
      expect(manager.getQueueSnapshot(), hasLength(1));
      await manager.flushExternalTasks();
      expect(await file.exists(), true);
      final persisted = jsonDecode(await file.readAsString()) as Map;
      expect(persisted['queue'], hasLength(1));
    },
  );

  test(
    'commit can use the selected original document as primary when none is loaded',
    () async {
      final item = library.getVideo(id)!;
      item.additionalSubtitles = {'原文': source.path};
      item.subtitlePath = null;
      final begin = await tool('translation_begin', {
        'mediaId': id,
        'documentId': await documentId(),
        'targetLanguage': 'zh-CN',
        'requestId': 'fallback-begin',
      });
      await tool('translation_write', {
        'draftId': begin['draftId'],
        'expectedRevision': 0,
        'requestId': 'fallback-write',
        'entries': [
          {'cueId': 'cue-1', 'text': '你好'},
          {'cueId': 'cue-2', 'text': '第二行'},
        ],
      });
      playback.debugSeedCurrentItem(item);
      final result = await tool('translation_commit', {
        'draftId': begin['draftId'],
        'expectedRevision': 1,
        'requestId': 'fallback-commit',
        'loadAsSecondary': true,
      });
      expect(result['loadedForCurrentMedia'], true);
      expect(item.subtitlePath, source.path);
      expect(
        item.secondarySubtitlePath,
        item.managedSubtitleAssets.single.path,
      );
    },
  );

  test(
    'current public and other configured cloud services do not require local models or disclose keys',
    () async {
      final backend = ExternalAiPlayerBackend(
        library: library,
        manager: manager,
        playback: playback,
      );
      center.downloads.clear();
      center.asrProfileId = ModelCenterService.legacyProfile.id;
      final options = await backend.options();
      expect(options['current']['kind'], 'gongyi');
      expect(options['current']['requiresLocalModel'], false);
      final publicConfig = await backend.captureConfiguration({
        'mode': 'transcribe',
      });
      expect(publicConfig['missingModelIds'], isEmpty);
      expect(publicConfig['usesRemote'], true);
      await backend.validateConfiguration(publicConfig);
      for (final kind in TranscriptionServiceKind.values.where(
        (k) =>
            k != TranscriptionServiceKind.local &&
            k != TranscriptionServiceKind.gongyi,
      )) {
        final provider = CloudAsrProvider.values
            .where((p) => p.name == kind.name)
            .firstOrNull;
        final profile = ModelServiceProfile(
          id: 'configured-${kind.name}',
          name: 'Cloud ${kind.name}',
          kind: kind,
          endpoint: 'https://private-provider.invalid',
          model: provider?.defaultModel ?? 'configured-model',
        );
        center.profiles[profile.id] = profile;
        center.asrProfileId = profile.id;
        final config = await backend.captureConfiguration({
          'mode': 'transcribe',
        });
        expect(config['missingModelIds'], isEmpty);
        expect(config['usesRemote'], true);
        await backend.validateConfiguration(config);
        expect((await backend.options())['current']['kind'], kind.name);
        center.profiles[profile.id] = ModelServiceProfile(
          id: profile.id,
          name: profile.name,
          kind: kind,
          endpoint: 'https://changed.invalid',
          model: profile.model,
        );
        await expectLater(
          backend.validateConfiguration(config),
          throwsA(isA<ExternalAiActionError>()),
        );
      }
      expect(center.downloadAttempts, 0);
      expect(jsonEncode(options), isNot(contains('test-fixture-key')));
      expect(jsonEncode(options), isNot(contains(root.path)));
    },
  );

  test(
    'missing current weights are disclosed but never downloaded by configuration capture',
    () async {
      center.asrEnhancements = AsrEnhancementOptions.disabled;
      center.asrProfileId = 'local:sensevoice-small-int8';
      center.profiles[center.asrProfileId] = ModelServiceProfile(
        id: center.asrProfileId,
        name: 'Local fixture',
        kind: TranscriptionServiceKind.local,
        model: 'sensevoice-small-int8',
      );
      center.downloads.clear();
      final backend = ExternalAiPlayerBackend(
        library: library,
        manager: manager,
        playback: playback,
      );
      final config = await backend.captureConfiguration({'mode': 'transcribe'});
      expect(config['missingModelIds'], contains('sensevoice-small-int8'));
      expect(config['downloadBytes'], greaterThan(0));
      expect(center.downloadAttempts, 0);
      await expectLater(
        backend.validateConfiguration(config),
        throwsStateError,
      );
      config['downloadAuthorized'] = true;
      await backend.validateConfiguration(config);
      expect(center.downloadAttempts, 0);
    },
  );

  test(
    'daily local translation preserves current smart rules and explicit language settings take effect',
    () async {
      final shared = SubtitleTranslateSettings(modelCenter: center);
      try {
        await shared.ensureLoaded();
        await shared.setProviderEnZh(SubtitleTranslateProvider.local);
        expect(shared.mode, SubtitleTranslationMode.smart);
        final backend = ExternalAiPlayerBackend(
          library: library,
          manager: manager,
          playback: playback,
          translationSettings: shared,
        );
        final config = await backend.captureConfiguration({
          'modelId': 'sensevoice-small-int8',
          'mode': 'transcribe_translate',
        });
        expect(
          config['localTranslationPolicy']['smart'],
          shared.smartPolicy.toJson(),
        );
        expect(config['targetLanguage'], 'mul');
        expect(
          await backend.enqueue(
            library.getVideo(id)!,
            'smart-local-owned',
            config,
            () {},
          ),
          'queued',
        );
        final choice = manager
            .configurationForVideo(mediaFile.path, videoId: id)!
            .translation;
        expect(choice.smartPolicy!.toJson(), shared.smartPolicy.toJson());
        expect(choice.targetLanguage, 'mul');
        await backend.updateDefaults({'targetLanguage': 'en'}, () {});
        expect(shared.mode, SubtitleTranslationMode.fixed);
        expect(shared.targetLanguage, 'en');
        final fixed = await backend.captureConfiguration({
          'modelId': 'sensevoice-small-int8',
          'mode': 'transcribe_translate',
        });
        expect(fixed['targetLanguage'], 'en');
        expect(fixed['localTranslationPolicy']['smart'], null);
      } finally {
        shared.dispose();
      }
    },
  );

  test(
    'Windows native MCP task transcribes the prepared short sample and exposes text only',
    () async {
      center.asrEnhancements = AsrEnhancementOptions.disabled;
      center.asrCpuThreads = 2;
      center.asrAccelerationOptions['sensevoice-small-int8'] =
          AsrAcceleration.cpu;
      final model = center.artifact('sensevoice-small-int8')!;
      final sample = File(
        localAsrProbeAsset(model.engine, model.languages, language: 'en'),
      );
      final input = await sample.copy(p.join(root.path, 'short.wav'));
      final durationMs =
          decodeModelWave(await input.readAsBytes()).length * 1000 ~/ 16000;
      library.seedVideoForTesting(
        VideoItem(
          id: id,
          path: input.path,
          title: 'MCP native fixture',
          type: MediaType.audio,
          durationMs: durationMs,
          lastUpdated: 0,
          hasProbedChapters: true,
        ),
      );
      final plan = await tool('transcription_prepare', {
        'mediaIds': [id],
        'modelId': model.id,
        'sourceLanguage': 'en',
        'mode': 'transcribe',
      });
      final batch = await tool('transcription_submit', {
        'planId': plan['planId'],
        'requestId': 'native-real-submit',
        'start': true,
      });
      final clock = Stopwatch()..start();
      final phases = <String>{};
      while (true) {
        final response = await tool('tasks_read', {
          'batchId': batch['batchId'],
        });
        final status = (response['tasks'] as List).single['status'] as String;
        phases.add(status);
        expect(
          status,
          isNot('error'),
          reason: manager
              .getQueueSnapshot()
              .map((t) => t.statusMessage)
              .join('; '),
        );
        if (status == 'completed') break;
        if (clock.elapsed > const Duration(minutes: 2)) {
          fail('Native MCP task timed out: $status');
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      expect(phases.length, greaterThan(1));
      expect(center.downloadAttempts, 0);
      final documents = await tool('documents_read_batch', {
        'mediaIds': [id],
      });
      expect(documents['complete'], true);
      expect(documents['errors'], isEmpty);
      expect((documents['items'] as List).single['text'], isNotEmpty);
      expect(jsonEncode([plan, batch, documents]), isNot(contains(input.path)));
      expect(jsonEncode(documents), isNot(contains('RIFF')));
    },
    skip: !nativeEnabled,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
