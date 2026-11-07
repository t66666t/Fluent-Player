import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/external_ai/external_ai_action_backend.dart';
import 'package:video_player_app/features/external_ai/external_ai_player_subtitle_backend.dart';
import 'package:video_player_app/features/external_ai/external_ai_library_source.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/ai_subtitle_api_settings.dart';
import 'package:video_player_app/services/ai_subtitle_translator.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_optimization.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/utils/subtitle_parser.dart';

class _Secrets implements AiChatSecretStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _Models extends ModelCenterService {
  @override
  Future<void> initialize() async {}
}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform previousPaths;
  late File original;
  late LibraryService library;
  late AppStorageService storage, previousStorage;
  late _Models center;
  late TranscriptionManager manager;
  late MediaPlaybackService playback;
  late SubtitleTranslateSettings settings;
  late SubtitleTranslationService translator;
  late SubtitleAiConnectionStore connections;
  late ExternalAiPlayerSubtitleBackend backend;
  late ExternalAiLibrarySource reader;
  late ExternalAiSubtitleDocument source;
  int optimizerCalls = 0;
  final translatedInputs = <String>[];
  const originalContent =
      '1\n00:00:01,234 --> 00:00:02,345\n学习人工职能。\n\n2\n00:00:03,456 --> 00:00:04,567\n这是第二课。\n\n';
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('mcp-application-subtitles-');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
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
    SettingsService().resetForTest();
    SettingsService().largeDataRootPath = p.join(root.path, 'data');
    library = LibraryService()..resetLibraryForTesting();
    await library.init(deferMaintenance: true);
    original = await File(
      p.join(root.path, 'original.srt'),
    ).writeAsString(originalContent);
    library.seedVideoForTesting(
      VideoItem(
        id: 'lesson',
        title: 'AI 课程',
        path: p.join(root.path, 'private.mp4'),
        subtitlePath: original.path,
        durationMs: 6000,
        lastUpdated: 0,
      ),
    );
    center = _Models();
    center.catalog = await loadModelCatalog();
    manager = TranscriptionManager(
      modelCenter: center,
      settings: SettingsService(),
    );
    playback = MediaPlaybackService.forTesting();
    final secrets = _Secrets();
    connections = SubtitleAiConnectionStore(secretStorage: secrets);
    await connections.save(
      const SubtitleAiConnection(
        'opt',
        '优化专用',
        AiSubtitleApiSettings(
          baseUrl: 'https://opt.example.test/v1',
          model: 'opt-model',
          apiKey: 'OPT-KEY-PRIVATE',
        ),
      ),
    );
    await connections.save(
      const SubtitleAiConnection(
        'trans',
        '翻译专用',
        AiSubtitleApiSettings(
          baseUrl: 'https://translate.example.test/v1',
          model: 'translation-model',
          apiKey: 'TRANS-KEY-PRIVATE',
        ),
      ),
    );
    settings = SubtitleTranslateSettings(
      modelCenter: center,
      readApiSettings: () => connections.endpoint('trans', withKey: false),
    );
    await settings.ensureLoaded();
    await settings.setProviderEnZh(SubtitleTranslateProvider.ai);
    await settings.setMode(SubtitleTranslationMode.fixed);
    await settings.setLanguages(source: 'zh-CN', target: 'en');
    optimizerCalls = 0;
    translatedInputs.clear();
    final optimizer = SubtitleOptimizer(
      client: AiSubtitleTranslator(
        complete: (config, messages) async {
          expect(config.model, 'opt-model');
          expect(config.apiKey, 'OPT-KEY-PRIVATE');
          optimizerCalls++;
          final object =
              jsonDecode(
                    messages.firstWhere((m) => m['role'] == 'user')['content']!,
                  )
                  as Map;
          final lines = object['字幕'] as Map;
          return jsonEncode({
            for (final e in lines.entries)
              '${e.key}': (e.value as String).replaceAll('人工职能', '人工智能'),
          });
        },
      ),
    );
    translator = SubtitleTranslationService(
      aiTranslator: AiSubtitleTranslator(
        complete: (config, messages) async {
          expect(config.model, 'translation-model');
          expect(config.apiKey, 'TRANS-KEY-PRIVATE');
          final lines =
              jsonDecode(
                    messages.firstWhere((m) => m['role'] == 'user')['content']!,
                  )
                  as Map;
          translatedInputs.addAll(lines.values.cast<String>());
          return jsonEncode({
            for (final e in lines.entries)
              '${e.key}': 'Translation: ${e.value}',
          });
        },
      ),
    );
    backend = ExternalAiPlayerSubtitleBackend(
      ExternalAiPlayerBackend(
        library: library,
        manager: manager,
        playback: playback,
        translationSettings: settings,
      ),
      service: translator,
      optimizer: optimizer,
      connections: connections,
      apiSettings: AiSubtitleApiSettingsStore(secretStorage: secrets),
    );
    reader = ExternalAiLibrarySource.fromLibrary(library);
    final listed = await reader.callTool('documents_list', {
      'mediaId': 'lesson',
    });
    source = await reader.authorizedSubtitle(
      'lesson',
      listed['documents'][0]['id'] as String,
    );
  });
  tearDown(() async {
    await manager.shutdown();
    manager.dispose();
    settings.dispose();
    center.dispose();
    playback.dispose();
    translator.dispose();
    await library.prepareStorageMigration();
    library.resetLibraryForTesting();
    await storage.releaseForegroundLease();
    AppStorageService.instance = previousStorage;
    SettingsService().resetForTest();
    PathProviderPlatform.instance = previousPaths;
    await root.delete(recursive: true);
  });
  Future<Map<String, dynamic>> plan({
    String opt = 'app',
    String trans = 'app',
  }) async => {
    ...await backend.captureSubtitlePlan({
      'optimize': opt,
      'translate': trans,
      'source': 'existing',
      'optimizationConnectionId': 'opt',
      'targetLanguage': 'en',
      '_authorizedMedia': [source.media],
    }),
    'remoteAuthorized': true,
    'downloadAuthorized': true,
  };

  test(
    'real application workflow uses independent saved APIs, optimized translation input and checkpoints',
    () async {
      final captured = await plan();
      expect(jsonEncode(captured), isNot(contains('OPT-KEY-PRIVATE')));
      expect(jsonEncode(captured), isNot(contains('TRANS-KEY-PRIVATE')));
      Future<dynamic> run() => backend.runSubtitleWorkflow(
        source,
        workId: 'application-work',
        optimize: true,
        translate: true,
        plan: captured,
        cancelSignal: Completer<void>().future,
        onProgress: (_, _) {},
        guard: () {},
      );
      final result = await run();
      expect(result.optimized, ['学习人工智能。', '这是第二课。']);
      expect(translatedInputs.first, contains('人工智能'));
      expect(translatedInputs.join(), isNot(contains('人工职能')));
      expect(optimizerCalls, 1);
      await run();
      expect(optimizerCalls, 1);
      expect(await original.readAsString(), originalContent);
      for (final file
          in root
              .listSync(recursive: true)
              .whereType<File>()
              .where(
                (f) =>
                    ['.json', '.jsonl', '.srt'].contains(p.extension(f.path)),
              )) {
        final content = await file.readAsString();
        expect(content, isNot(contains('OPT-KEY-PRIVATE')));
        expect(content, isNot(contains('TRANS-KEY-PRIVATE')));
      }
    },
  );

  test(
    'a completed software translation is reused after restart without another API request',
    () async {
      final captured = await plan(opt: 'off');
      Future<dynamic> run() => backend.runSubtitleWorkflow(
        source,
        workId: 'translation-only-work',
        optimize: false,
        translate: true,
        plan: captured,
        cancelSignal: Completer<void>().future,
        onProgress: (_, _) {},
        guard: () {},
      );
      await run();
      final calls = translatedInputs.length;
      expect(calls, greaterThan(0));
      await run();
      expect(translatedInputs.length, calls);
    },
  );

  test(
    'published optimized/translated assets retain source lineage and exact sentence timing',
    () async {
      final captured = await plan();
      final result = await backend.runSubtitleWorkflow(
        source,
        workId: 'workflow-publish',
        optimize: true,
        translate: true,
        plan: captured,
        cancelSignal: Completer<void>().future,
        onProgress: (_, _) {},
        guard: () {},
      );
      final opt = await backend.publishProcessedSubtitle(
        source,
        workId: 'optimized-result',
        operation: 'optimization',
        executor: 'app',
        language: 'zh-CN',
        texts: result.optimized!,
        guard: () {},
      );
      final list = await reader.callTool('documents_list', {
        'mediaId': 'lesson',
      });
      final id =
          (list['documents'] as List).cast<Map>().singleWhere(
                (d) => d['assetId'] == opt['assetId'],
              )['id']
              as String;
      final optimized = await reader.authorizedSubtitle('lesson', id);
      final translation = await backend.publishProcessedSubtitle(
        optimized,
        workId: 'translation-result',
        operation: 'translation',
        executor: 'app',
        language: 'en',
        texts: result.translated!,
        guard: () {},
      );
      final item = library.getVideo('lesson')!;
      final translatedAsset = item.managedSubtitleAssets.singleWhere(
        (a) => a.assetId == translation['assetId'],
      );
      expect(translatedAsset.sourceAssetId, opt['assetId']);
      final cues = SubtitleParser.parse(
        await File(translatedAsset.path).readAsString(),
      );
      expect(cues.map((c) => c.startTime), source.cues.map((c) => c.startTime));
      expect(cues.map((c) => c.endTime), source.cues.map((c) => c.endTime));
      expect(jsonEncode(translation), isNot(contains(root.path)));
      expect(await original.readAsString(), originalContent);
    },
  );

  test(
    'changed endpoint cannot receive the old saved credential from a frozen task',
    () async {
      final captured = await plan();
      await connections.save(
        const SubtitleAiConnection(
          'opt',
          'changed',
          AiSubtitleApiSettings(
            baseUrl: 'https://other.example.test/v1',
            model: 'opt-model',
            apiKey: 'OTHER-KEY',
          ),
        ),
      );
      await expectLater(
        backend.runSubtitleWorkflow(
          source,
          workId: 'changed-endpoint',
          optimize: true,
          translate: true,
          plan: captured,
          cancelSignal: Completer<void>().future,
          onProgress: (_, _) {},
          guard: () {},
        ),
        throwsStateError,
      );
      expect(optimizerCalls, 0);
    },
  );

  test(
    'requested subtitle loading updates only this media and preserves a later user choice',
    () async {
      final captured = await plan();
      final opt = await backend.publishProcessedSubtitle(
        source,
        workId: 'load-optimized',
        operation: 'optimization',
        executor: 'agent',
        language: 'zh-CN',
        texts: ['学习人工智能。', '这是第二课。'],
        guard: () {},
      );
      final trans = await backend.publishProcessedSubtitle(
        source,
        workId: 'load-translated',
        operation: 'translation',
        executor: 'agent',
        language: 'en',
        texts: ['A lesson about AI.', 'This is the second lesson.'],
        guard: () {},
      );
      final item = library.getVideo('lesson')!;
      final userChoice = await File(
        p.join(root.path, 'user-selected.srt'),
      ).writeAsString(originalContent);
      item.subtitlePath = userChoice.path;
      expect(
        await backend.selectProcessedSubtitles(
          source,
          primaryAssetId: opt['assetId'] as String,
          secondaryAssetId: trans['assetId'] as String,
          plan: captured,
          guard: () {},
        ),
        containsPair('status', 'preserved_user_selection'),
      );
      expect(item.subtitlePath, userChoice.path);
      item.subtitlePath = source.path;
      final loaded = await backend.selectProcessedSubtitles(
        source,
        primaryAssetId: opt['assetId'] as String,
        secondaryAssetId: trans['assetId'] as String,
        plan: captured,
        guard: () {},
      );
      expect(
        loaded['loadedForCurrentMedia'],
        false,
        reason: 'No current player is opened by an MCP subtitle selection',
      );
      expect(loaded['applied'], true);
      expect(
        item.subtitlePath,
        item.managedSubtitleAssets
            .singleWhere((a) => a.assetId == opt['assetId'])
            .path,
      );
      expect(
        item.secondarySubtitlePath,
        item.managedSubtitleAssets
            .singleWhere((a) => a.assetId == trans['assetId'])
            .path,
      );
    },
  );

  test(
    'optimizing only keeps the existing secondary and reports saved selection for an unopened media',
    () async {
      final translated = await backend.publishProcessedSubtitle(
        source,
        workId: 'old-secondary',
        operation: 'translation',
        executor: 'app',
        language: 'en',
        texts: ['An AI course.', 'Lesson two.'],
        guard: () {},
      );
      final item = library.getVideo('lesson')!;
      final secondaryPath = item.managedSubtitleAssets.single.path;
      item.secondarySubtitlePath = secondaryPath;
      final captured = await plan();
      final optimized = await backend.publishProcessedSubtitle(
        source,
        workId: 'new-main',
        operation: 'optimization',
        executor: 'agent',
        language: 'zh-CN',
        texts: ['学习人工智能。', '这是第二课。'],
        guard: () {},
      );
      final selection = await backend.selectProcessedSubtitles(
        source,
        primaryAssetId: optimized['assetId'] as String,
        plan: captured,
        guard: () {},
      );
      expect(selection['applied'], true);
      expect(selection['loadedForCurrentMedia'], false);
      expect(selection['primary']['name'], '［优化］AI 课程');
      expect(selection['secondary']['assetId'], translated['assetId']);
      expect(item.secondarySubtitlePath, secondaryPath);
      expect(playback.currentItem, null);
    },
  );

  test(
    'concurrent generated publications reserve distinct visible editions and replay the same asset',
    () async {
      Future<Map<String, dynamic>> publish(String id) =>
          backend.publishProcessedSubtitle(
            source,
            workId: id,
            operation: 'optimization',
            executor: 'agent',
            language: 'zh-CN',
            texts: ['学习人工智能。', '这是第二课。'],
            guard: () {},
          );
      final both = await Future.wait([
        publish('edition-one'),
        publish('edition-two'),
      ]);
      expect(both.map((a) => a['displayName']).toSet(), {
        '［优化］AI 课程',
        '［优化］AI 课程 v2',
      });
      final again = await publish('edition-one');
      expect(again['assetId'], both.first['assetId']);
      expect(again['displayName'], both.first['displayName']);
      expect(library.getVideo('lesson')!.managedSubtitleAssets, hasLength(2));
    },
  );

  test(
    'Agent stages require neither installed models nor configured optimizer API',
    () async {
      center.catalog = [];
      final captured = await plan(opt: 'agent', trans: 'agent');
      expect(captured['missingModelIds'], isEmpty);
      expect(captured['usesRemote'], false);
      expect(jsonEncode(captured), isNot(contains('KEY-PRIVATE')));
    },
  );
}
