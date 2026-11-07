import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:video_player_app/features/external_ai/external_ai_action_backend.dart';
import 'package:video_player_app/features/external_ai/external_ai_action_store.dart';
import 'package:video_player_app/features/external_ai/external_ai_actions.dart';
import 'package:video_player_app/features/external_ai/external_ai_approvals.dart';
import 'package:video_player_app/features/external_ai/external_ai_document_backend.dart';
import 'package:video_player_app/features/external_ai/external_ai_guide.dart';
import 'package:video_player_app/features/external_ai/external_ai_library_source.dart';
import 'package:video_player_app/features/external_ai/external_ai_player_subtitle_backend.dart';
import 'package:video_player_app/features/external_ai/external_ai_preparation.dart';
import 'package:video_player_app/features/external_ai/external_ai_preferences.dart';
import 'package:video_player_app/features/external_ai/external_ai_queue.dart';
import 'package:video_player_app/features/external_ai/external_ai_server.dart';
import 'package:video_player_app/features/external_ai/external_ai_subtitle_processing.dart';
import 'package:video_player_app/features/external_ai/external_ai_workspace_context.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/features/model_center/model_transcription.dart';
import 'package:video_player_app/features/model_center/local_asr_worker.dart';
import 'package:video_player_app/features/model_center/model_adapters.dart';
import 'package:video_player_app/features/model_center/asr_enhancement_options.dart';
import 'package:video_player_app/features/model_center/asr_acceleration.dart';
import 'package:video_player_app/models/managed_subtitle_asset.dart';
import 'package:video_player_app/models/video_collection.dart';
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
  int captureAttempts = 0;
  Future<void> Function()? beforeCapture;
  @override
  Future<String> readSecret(String profileId) async => 'test-fixture-key';
  @override
  Future<void> initialize() async {}
  @override
  Future<ModelJobSpec> captureTranscription() async {
    captureAttempts++;
    await beforeCapture?.call();
    throw StateError('stop user restart before inference');
  }

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
  late ExternalAiPlayerBackend backend;
  late ExternalAiApprovals approvals;
  late ExternalAiPreparation preparation;
  late ExternalAiSubtitleProcessing subtitles;
  late ExternalAiQueueSource queue;
  late SubtitleTranslateSettings translationSettings;
  late ExternalAiLibrarySource reader;
  late ExternalAiServer server;
  late MediaPlaybackService playback;
  late HttpClient client;
  late PathProviderPlatform previousPaths;
  HttpOverrides? previousHttp;
  var accessGeneration = 0;
  final settings = SettingsService();
  const id = 'mcp-real-card';
  const nativeRoot = String.fromEnvironment('MCP_NATIVE_MODEL_ROOT');
  final nativeEnabled = Platform.isWindows && nativeRoot.isNotEmpty;

  setUp(() async {
    accessGeneration = 0;
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
    prefs = ExternalAiPreferences(
      token: ExternalAiPreferences.generateToken(),
      enabled: true,
      allowTaskControl: true,
      allowSubtitleWrite: true,
    );
    reader = ExternalAiLibrarySource.fromLibrary(
      library,
      scopeFolder: () => prefs.scopeFolderId,
    );
    translationSettings = SubtitleTranslateSettings(modelCenter: center);
    backend = ExternalAiPlayerBackend(
      library: library,
      manager: manager,
      playback: playback,
      translationSettings: translationSettings,
    );
    actions = ExternalAiActions(
      library: reader,
      backend: backend,
      store: ExternalAiActionStore(root),
      preferences: () => prefs,
    );
    approvals = ExternalAiApprovals(
      store: ExternalAiActionStore(root, name: 'approvals-fixture'),
      preferences: () => prefs,
    );
    await approvals.initialize();
    preparation = ExternalAiPreparation(
      library: reader,
      documents: ExternalAiDocumentBackend(library: library),
      processing: backend,
      approvals: approvals,
      store: ExternalAiActionStore(root, name: 'preparation-fixture'),
      preferences: () => prefs,
      generation: () => accessGeneration,
    );
    await preparation.initialize();
    final subtitleBackend = ExternalAiPlayerSubtitleBackend(backend);
    subtitles = ExternalAiSubtitleProcessing(
      library: reader,
      backend: subtitleBackend,
      store: ExternalAiActionStore(root, name: 'subtitles-fixture'),
      approvals: approvals,
      preferences: () => prefs,
      generation: () => accessGeneration,
      documents: preparation,
    );
    await subtitles.initialize();
    queue = ExternalAiQueueSource(
      library: reader,
      backend: backend,
      store: ExternalAiActionStore(root, name: 'queue-fixture'),
      approvals: approvals,
      preferences: () => prefs,
      generation: () => accessGeneration,
    );
    await queue.initialize();
    final guide = ExternalAiGuide(
      preferences: () => prefs,
      processingOptions: backend.options,
      subtitleOptions: subtitleBackend.subtitleOptions,
    );
    server = ExternalAiServer(
      dataSource: ExternalAiApplicationSource(
        reader,
        actions,
        preparation,
        subtitles,
        queue,
        guide,
      ),
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
    await queue.shutdown();
    await subtitles.shutdown();
    subtitles.dispose();
    await preparation.shutdown();
    await actions.shutdown();
    await manager.shutdown();
    manager.dispose();
    center.dispose();
    translationSettings.dispose();
    approvals.dispose();
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
    expect(
      response['result']['isError'],
      false,
      reason: jsonEncode({
        'tool': name,
        'requestId': a['requestId'],
        'response': response,
      }),
    );
    return Map<String, dynamic>.from(
      response['result']['structuredContent'] as Map,
    );
  }

  Future<String> documentId() async =>
      ((await tool('documents_list', {'mediaId': id}))['documents'] as List)
              .first['id']
          as String;

  Future<void> enqueueManual(VideoItem item) async {
    await manager.startTranscription(
      item.path,
      videoId: item.id,
      videoTitle: item.title,
      libraryService: library,
      sourceItem: item,
      autoStart: false,
    );
  }

  Future<Map<String, dynamic>> queueTask(
    String mediaId, {
    String? status,
  }) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (true) {
      final snapshot = await tool('transcription_queue', {
        'mediaIds': [mediaId],
      });
      final tasks = (snapshot['tasks'] as List).cast<Map>();
      if (tasks.length == 1 &&
          (status == null || tasks.single['status'] == status)) {
        return Map<String, dynamic>.from(tasks.single);
      }
      if (DateTime.now().isAfter(deadline)) {
        fail(
          'Native queue did not reach expected state $status: ${jsonEncode(snapshot)}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<Map<String, dynamic>> awaitSubtitleJob(
    String jobId,
    String status,
  ) async {
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    while (true) {
      final snapshot = await tool('subtitle_jobs', {
        'jobId': jobId,
        'limit': 100,
      });
      expect(snapshot['status'], isNot('failed'), reason: jsonEncode(snapshot));
      expect(
        (snapshot['items'] as List).any((row) => row['status'] == 'failed'),
        false,
        reason: jsonEncode(snapshot),
      );
      if (snapshot['status'] == status) return snapshot;
      if (DateTime.now().isAfter(deadline)) {
        fail('Subtitle job did not reach $status: ${jsonEncode(snapshot)}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  }

  Future<Map<String, List<String>>> finishAgentStages(
    String jobId,
    List<String> mediaIds,
  ) async {
    final optimized = <String, List<String>>{};
    for (final stage in ['optimization', 'translation']) {
      for (final mediaId in mediaIds) {
        final deadline = DateTime.now().add(const Duration(minutes: 2));
        while (true) {
          final snapshot = await tool('subtitle_jobs', {
            'jobId': jobId,
            'limit': 100,
          });
          final row = (snapshot['items'] as List).cast<Map>().singleWhere(
            (row) => row['mediaId'] == mediaId,
          );
          expect(row['status'], isNot('failed'), reason: jsonEncode(snapshot));
          if (row['stages'][stage]['status'] == 'awaiting_agent') break;
          if (DateTime.now().isAfter(deadline)) {
            fail(
              'Subtitle stage did not become ready: $stage ${jsonEncode(snapshot)}',
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
        final read = await tool('subtitle_work_read', {
          'jobId': jobId,
          'mediaId': mediaId,
          'stage': stage,
          'limit': 100,
        });
        expect(read['nextOffset'], isNull, reason: 'Fixture must remain short');
        final entries = (read['entries'] as List).cast<Map>();
        final writes = <Map<String, dynamic>>[];
        if (stage == 'optimization') {
          optimized[mediaId] = [
            for (final entry in entries)
              (entry['text'] as String).endsWith('.')
                  ? entry['text'] as String
                  : '${entry['text']}.',
          ];
          for (var i = 0; i < entries.length; i++) {
            writes.add({
              'cueId': entries[i]['cueId'],
              'text': optimized[mediaId]![i],
            });
          }
        } else {
          expect(entries.map((entry) => entry['text']), optimized[mediaId]);
          final parts = (read['translationParts'] as List).cast<Map>();
          final preserve = (read['preserveCueIds'] as List).cast<String>();
          expect({
            ...parts.map((part) => part['cueId']),
            ...preserve,
          }, entries.map((entry) => entry['cueId']).toSet());
          if (parts.isNotEmpty) {
            final invalid = await rpc('tools/call', {
              'name': 'subtitle_work_write',
              'arguments': {
                'jobId': jobId,
                'mediaId': mediaId,
                'stage': stage,
                'expectedRevision': read['revision'],
                'requestId': 'wrong-target-$mediaId',
                'parts': [
                  {
                    'cueId': parts.first['cueId'],
                    'partId': parts.first['partId'],
                    'targetLanguage': 'wrong-language',
                    'text': 'Rejected fixture',
                  },
                ],
              },
            });
            expect(invalid['result']['isError'], true);
            expect(jsonEncode(invalid), isNot(contains(root.path)));
          }
          for (var i = 0; i < parts.length; i++) {
            expect(parts[i]['targetLanguage'], 'zh-CN');
            writes.add({
              'cueId': parts[i]['cueId'],
              'partId': parts[i]['partId'],
              'targetLanguage': parts[i]['targetLanguage'],
              'text': '测试译文 ${i + 1}',
            });
          }
        }
        final committed = await tool('subtitle_work_write', {
          'jobId': jobId,
          'mediaId': mediaId,
          'stage': stage,
          'expectedRevision': read['revision'],
          'requestId': 'finish-$stage-$mediaId',
          if (stage == 'translation') 'parts': writes else 'entries': writes,
          if (stage == 'translation') 'preserveCueIds': read['preserveCueIds'],
          'complete': true,
        });
        expect(
          committed['committed'],
          true,
          reason: jsonEncode({
            'stage': stage,
            'mediaId': mediaId,
            'read': read,
            'commit': committed,
          }),
        );
      }
    }
    await awaitSubtitleJob(jobId, 'completed');
    return optimized;
  }

  // BEGIN MCP_OPERATOR_AUDIT_FIXTURE
  const operatorAuditDir = String.fromEnvironment('MCP_OPERATOR_AUDIT_DIR');
  if (operatorAuditDir.isNotEmpty) {
    test(
      'MCP external Agent operator fixture',
      () async {
        final audit = await Directory(
          operatorAuditDir,
        ).absolute.create(recursive: true);
        final descriptor = File(p.join(audit.path, 'descriptor.private.json'));
        final stop = File(p.join(audit.path, 'stop'));
        if (await stop.exists()) await stop.delete();
        final resultFile = File(p.join(audit.path, 'result.json'));
        if (await resultFile.exists()) await resultFile.delete();
        final startedAt = DateTime.now().toUtc();
        prefs = prefs.copyWith(
          autoTaskDecisions: true,
          autoRemoteProcessing: false,
          autoModelDownloads: false,
        );
        await translationSettings.ensureLoaded();
        await translationSettings.setMode(SubtitleTranslationMode.smart);
        await translationSettings.setSmartPolicy(
          const SmartTranslationPolicy(),
        );
        await source.writeAsString(
          '1\n00:00:01,234 --> 00:00:02,345\n大家好。 Please sit down.\n\n'
          '2\n00:00:03,456 --> 00:00:04,567\n<i>谢谢。</i> Bonjour tout le monde.\n\n',
        );
        const folderId = 'operator-library';
        const missingId = 'operator-missing';
        const ambiguousId = 'operator-versions';
        library.seedCollectionForTesting(
          VideoCollection(
            id: folderId,
            name: 'Agent 验收样例',
            createTime: 0,
            childrenIds: [id, missingId, ambiguousId],
          ),
        );
        library.getVideo(id)!.parentId = folderId;
        final emptyDirectory = await Directory(
          p.join(root.path, 'missing-only'),
        ).create();
        final wave = File(p.join(emptyDirectory.path, 'synthetic.wav'));
        List<int> le32(int value) => [
          for (var shift = 0; shift < 32; shift += 8) (value >> shift) & 255,
        ];
        const payloadBytes = 32000;
        await wave.writeAsBytes([
          ...ascii.encode('RIFF'),
          ...le32(36 + payloadBytes),
          ...ascii.encode('WAVEfmt '),
          ...le32(16),
          1,
          0,
          1,
          0,
          ...le32(16000),
          ...le32(32000),
          2,
          0,
          16,
          0,
          ...ascii.encode('data'),
          ...le32(payloadBytes),
          ...List<int>.filled(payloadBytes, 0),
        ]);
        library.seedVideoForTesting(
          VideoItem(
            id: missingId,
            parentId: folderId,
            path: wave.path,
            title: '缺字幕的合成静音样例（仅规划）',
            type: MediaType.audio,
            durationMs: 1000,
            lastUpdated: 0,
            hasProbedChapters: true,
          ),
        );
        final versions = await Directory(
          p.join(root.path, 'versions'),
        ).create();
        final versionA = await source.copy(
          p.join(versions.path, 'variant-A.srt'),
        );
        final versionB = await File(
          p.join(versions.path, 'variant-B.srt'),
        ).writeAsString('1\n00:00:01,234 --> 00:00:02,345\n这是另一个字幕版本。\n\n');
        final versionMedia = await mediaFile.copy(
          p.join(versions.path, 'private.mp4'),
        );
        library.seedVideoForTesting(
          VideoItem(
            id: ambiguousId,
            parentId: folderId,
            path: versionMedia.path,
            title: '双版本未选择的样例',
            durationMs: 6000,
            lastUpdated: 0,
            additionalSubtitles: {'版本 A': versionA.path, '版本 B': versionB.path},
            hasProbedChapters: true,
          ),
        );
        await enqueueManual(library.getVideo(id)!);
        final workspaceOwner = Object();
        ExternalAiWorkspaceContext.instance.publish(
          owner: workspaceOwner,
          viewType: ExternalAiWorkspaceView.libraryFolder,
          folderId: folderId,
        );
        addTearDown(
          () => ExternalAiWorkspaceContext.instance.clear(workspaceOwner),
        );
        final endpoint = server.endpoint!;
        expect(endpoint.scheme, 'http');
        expect(InternetAddress(endpoint.host).isLoopback, true);
        var timedOut = false;
        try {
          await descriptor.writeAsString(
            const JsonEncoder.withIndent('  ').convert({
              'version': 1,
              'endpoint': endpoint.toString(),
              'token': prefs.token,
              'startedAt': startedAt.toIso8601String(),
              'expiresAt': startedAt
                  .add(const Duration(minutes: 8))
                  .toIso8601String(),
              'stopMarker': 'stop',
              'fixture': {
                'folderId': folderId,
                'existingMediaId': id,
                'missingMediaId': missingId,
                'ambiguousMediaId': ambiguousId,
                'manualQueueMediaId': id,
              },
              'boundary':
                  '合成隔离fixture；可处理已有字幕并管理手工队列。缺字幕仅规划，不启动转录。优化/翻译选择Agent，无真实云端调用或模型下载。',
            }),
            flush: true,
          );
          while (!await stop.exists()) {
            if (DateTime.now().toUtc().difference(startedAt) >=
                const Duration(minutes: 8)) {
              timedOut = true;
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }
          await resultFile.writeAsString(
            const JsonEncoder.withIndent('  ').convert({
              'version': 1,
              'timedOut': timedOut,
              'externalToolCallCount': server.externalToolCallCount,
              'downloadAttempts': center.downloadAttempts,
              'captureAttempts': center.captureAttempts,
              'existingMediaAssets': [
                for (final asset in library.getVideo(id)!.managedSubtitleAssets)
                  {
                    'assetId': asset.assetId,
                    'kind': asset.kind.name,
                    'language': asset.language,
                  },
              ],
              'missingMediaAssetCount': library
                  .getVideo(missingId)!
                  .managedSubtitleAssets
                  .length,
              'ambiguousMediaAssetCount': library
                  .getVideo(ambiguousId)!
                  .managedSubtitleAssets
                  .length,
              'queue': await tool('transcription_queue', {}),
              'jobs': await tool('subtitle_jobs', {}),
            }),
            flush: true,
          );
          expect(center.downloadAttempts, 0);
          expect(center.captureAttempts, 0);
          expect(library.getVideo(missingId)!.managedSubtitleAssets, isEmpty);
          expect(library.getVideo(ambiguousId)!.managedSubtitleAssets, isEmpty);
        } finally {
          if (await descriptor.exists()) await descriptor.delete();
        }
      },
      timeout: const Timeout(Duration(minutes: 9)),
    );
    return;
  }
  // END MCP_OPERATOR_AUDIT_FIXTURE

  test(
    'HTTP guide exposes actual defaults and unified tool routes without private configuration',
    () async {
      center.profiles[ModelCenterService.legacyProfile.id] = ModelCenterService.legacyProfile;
      center.asrProfileId = ModelCenterService.legacyProfile.id;
      final listed = (await rpc('tools/list'))['result']['tools'] as List;
      for (final name in [
        'player_guide',
        'subtitle_plan',
        'subtitle_process',
        'transcription_queue',
        'transcription_queue_control',
      ]) {
        expect(listed.any((tool) => tool['name'] == name), true, reason: name);
      }
      final guide = await tool('player_guide', {});
      expect(guide['currentSettings']['transcription']['kind'], 'gongyi');
      expect(
        guide['currentSettings']['transcription']['requiresLocalModel'],
        false,
      );
      expect(guide['optimization']['meaning'], contains('字幕文字'));
      expect(
        guide['queue']['applicationQueue'],
        contains('transcription_queue'),
      );
      final overview = await tool('player_overview', {});
      expect(overview['currentSettings']['transcription']['kind'], 'gongyi');
      expect(overview['applicationQueueTool'], 'transcription_queue');
      expect(jsonEncode([guide, overview]), isNot(contains(root.path)));
      expect(
        jsonEncode([guide, overview]),
        isNot(contains('test-fixture-key')),
      );
      expect(center.captureAttempts, 0);
      expect(center.downloadAttempts, 0);
    },
  );

  test(
    'HTTP native queue requires approval for manual cancel and preserves published subtitles',
    () async {
      final item = library.getVideo(id)!;
      final published = await source.copy(p.join(root.path, 'published.srt'));
      item.managedSubtitleAssets = [
        ManagedSubtitleAsset(
          assetId: 'already-published',
          path: published.path,
          kind: ManagedSubtitleAssetKind.ai,
          displayName: '已生成字幕',
          createdAt: 1,
        ),
      ];
      final originalBytes = await source.readAsBytes();
      final publishedBytes = await published.readAsBytes();
      await enqueueManual(item);
      expect((await tool('tasks_read', {}))['tasks'], isEmpty);
      final row = await queueTask(id, status: 'paused');
      expect(row['createdBy'], 'app');
      expect(row['taskId'], startsWith('queue_'));
      expect(row['availableActions'], contains('cancel'));
      final arguments = {
        'taskIds': [row['taskId']],
        'action': 'cancel',
        'requestId': 'manual-cancel-approved',
      };
      final pending = await tool('transcription_queue_control', arguments);
      expect(pending['status'], 'approval_required');
      expect(manager.getQueueSnapshot(), hasLength(1));
      await approvals.resolve(pending['approvalId'] as String, approve: true);
      final result = await tool('transcription_queue_control', arguments);
      expect(result['status'], 'completed');
      expect(manager.getQueueSnapshot(), isEmpty);
      expect((await tool('transcription_queue', {}))['tasks'], isEmpty);
      expect(await source.readAsBytes(), originalBytes);
      expect(await published.readAsBytes(), publishedBytes);
      expect(item.managedSubtitleAssets.single.assetId, 'already-published');
      expect(await mediaFile.exists(), true);
      expect(jsonEncode([row, pending, result]), isNot(contains(root.path)));
      expect(
        jsonEncode([row, pending, result]),
        isNot(contains('test-fixture-key')),
      );
      expect(center.captureAttempts, 0);
      // Queue another manual task before revoking access, so the rejection
      // proves that the transport cannot mutate a real remaining task.
      await enqueueManual(item);
      final remaining = await queueTask(id);
      final remainingGeneration = manager.generationForVideo(
        item.path,
        videoId: id,
      );
      prefs = prefs.copyWith(allowTaskControl: false);
      accessGeneration++;
      final tools = (await rpc('tools/list'))['result']['tools'] as List;
      expect(tools.any((tool) => tool['name'] == 'transcription_queue'), false);
      final rejected = await rpc('tools/call', {
        'name': 'transcription_queue_control',
        'arguments': {
          'taskIds': [remaining['taskId']],
          'action': 'cancel',
          'requestId': 'revoked-manual-cancel',
        },
      });
      expect(rejected['result'], isNull);
      expect(rejected['error']['code'], -32602);
      expect(manager.getQueueSnapshot(), hasLength(1));
      expect(
        manager.generationForVideo(item.path, videoId: id),
        remainingGeneration,
      );
      expect(await source.readAsBytes(), originalBytes);
      expect(await published.readAsBytes(), publishedBytes);
      expect(item.managedSubtitleAssets.single.assetId, 'already-published');
      expect(center.captureAttempts, 0);
      expect(jsonEncode(rejected), isNot(contains(root.path)));
    },
  );

  test(
    'HTTP manual queue pauses a running task and retries failure before any inference',
    () async {
      prefs = prefs.copyWith(
        autoTaskDecisions: true,
        autoRemoteProcessing: true,
      );
      final entered = Completer<void>(), release = Completer<void>();
      center.beforeCapture = () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      await enqueueManual(library.getVideo(id)!);
      final initial = await queueTask(id);
      await tool('transcription_queue_control', {
        'taskIds': [initial['taskId']],
        'action': 'start',
        'requestId': 'manual-start-gated',
      });
      await entered.future.timeout(const Duration(seconds: 5));
      final running = await queueTask(id, status: 'running');
      final paused = await tool('transcription_queue_control', {
        'taskIds': [running['taskId']],
        'action': 'pause',
        'requestId': 'manual-running-pause',
      });
      expect(paused['status'], 'completed');
      release.complete();
      final restored = await queueTask(id, status: 'paused');
      expect(restored['taskId'], initial['taskId']);
      center.beforeCapture = null;
      await tool('transcription_queue_control', {
        'taskIds': [restored['taskId']],
        'action': 'resume',
        'requestId': 'manual-resume-fails',
      });
      final failed = await queueTask(id, status: 'failed');
      expect(failed['availableActions'], contains('retry'));
      final attempts = center.captureAttempts;
      final retryArguments = {
        'taskIds': [failed['taskId']],
        'action': 'retry',
        'requestId': 'manual-retry-fails',
      };
      final retried = await tool('transcription_queue_control', retryArguments);
      expect(retried['status'], 'completed');
      await queueTask(id, status: 'failed');
      expect(center.captureAttempts, attempts + 1);
      await tool('transcription_queue_control', retryArguments);
      expect(center.captureAttempts, attempts + 1);
      expect(manager.getQueueSnapshot(), hasLength(1));
      expect(center.downloadAttempts, 0);
      expect(await source.exists(), true);
      expect(
        jsonEncode([running, paused, failed, retried]),
        isNot(contains(root.path)),
      );
    },
  );

  test(
    'HTTP native queue rejects expired generation handles and excludes tasks outside scope',
    () async {
      prefs = prefs.copyWith(autoTaskDecisions: true);
      final item = library.getVideo(id)!;
      await enqueueManual(item);
      final first = await queueTask(id);
      await tool('transcription_queue_control', {
        'taskIds': [first['taskId']],
        'action': 'cancel',
        'requestId': 'expire-old-generation',
      });
      await enqueueManual(item);
      final second = await queueTask(id);
      expect(second['taskId'], isNot(first['taskId']));
      final stale = await rpc('tools/call', {
        'name': 'transcription_queue_control',
        'arguments': {
          'taskIds': [first['taskId']],
          'action': 'cancel',
          'requestId': 'reject-old-generation',
        },
      });
      expect(stale['result']['isError'], true);
      expect(manager.getQueueSnapshot(), hasLength(1));
      library.seedCollectionForTesting(
        VideoCollection(
          id: 'allowed-folder',
          name: 'Allowed',
          createTime: 0,
          childrenIds: [id],
        ),
      );
      item.parentId = 'allowed-folder';
      final outside = VideoItem(
        id: 'outside-scope',
        path: p.join(root.path, 'outside-private.mp4'),
        title: 'Outside scope private title',
        durationMs: 1000,
        lastUpdated: 0,
      );
      library.seedVideoForTesting(outside);
      await enqueueManual(outside);
      prefs = prefs.copyWith(scopeFolderId: 'allowed-folder');
      accessGeneration++;
      final scoped = await tool('transcription_queue', {});
      expect((scoped['tasks'] as List).map((row) => row['mediaId']), [id]);
      expect(scoped['totalAuthorizedTasks'], 1);
      expect(manager.getQueueSnapshot(), hasLength(2));
      expect(jsonEncode([stale, scoped]), isNot(contains(root.path)));
      expect(jsonEncode(scoped), isNot(contains(outside.title)));
    },
  );

  test(
    'HTTP auto subtitle plan reuses existing SRT and publishes Agent optimization before routed translation',
    () async {
      prefs = prefs.copyWith(
        autoTaskDecisions: true,
        autoRemoteProcessing: true,
      );
      final mediaBytes = await mediaFile.readAsBytes(),
          sourceBytes = await source.readAsBytes();
      final plan = await tool('subtitle_plan', {
        'targets': [
          {'mediaId': id},
        ],
        'source': 'auto',
        'optimize': 'agent',
        'translate': 'agent',
        'targetLanguage': 'zh-CN',
        'requestId': 'http-existing-plan',
      });
      expect(plan['status'], 'ready');
      expect(plan['existingSubtitleMedia'], 1);
      expect(plan['needsTranscriptionMedia'], 0);
      expect(plan['costBoundary']['generationStarted'], false);
      expect(manager.getQueueSnapshot(), isEmpty);
      final started = await tool('subtitle_process', {
        'planId': plan['planId'],
        'requestId': 'http-existing-start',
      });
      await finishAgentStages(started['jobId'] as String, [id]);
      final item = library.getVideo(id)!;
      expect(item.managedSubtitleAssets, hasLength(2));
      final optimized = item.managedSubtitleAssets.singleWhere(
        (asset) => asset.kind == ManagedSubtitleAssetKind.ai,
      );
      final translated = item.managedSubtitleAssets.singleWhere(
        (asset) => asset.kind == ManagedSubtitleAssetKind.translated,
      );
      expect(
        SubtitleParser.parseSrt(
          await File(optimized.path).readAsString(),
        ).map((cue) => cue.text),
        ['Hello world.', 'Second line.'],
      );
      final cues = SubtitleParser.parseSrt(
        await File(translated.path).readAsString(),
      );
      expect(cues.map((cue) => cue.text), ['测试译文 1', '测试译文 2']);
      expect(cues.map((cue) => cue.startTime.inMilliseconds), [1234, 3456]);
      expect(cues.map((cue) => cue.endTime.inMilliseconds), [2345, 4567]);
      expect(await source.readAsBytes(), sourceBytes);
      expect(await mediaFile.readAsBytes(), mediaBytes);
      expect(manager.getQueueSnapshot(), isEmpty);
      expect(center.captureAttempts, 0);
      expect(center.downloadAttempts, 0);
      expect(jsonEncode([plan, started]), isNot(contains(root.path)));
    },
  );

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
    'HTTP selects, swaps and clears main and secondary text documents without opening media',
    () async {
      final beforeMedia = await mediaFile.readAsBytes();
      final beforeSource = await source.readAsBytes();
      final originalId = await documentId();
      final document = await reader.authorizedSubtitle(id, originalId);
      final optimized = await backend.publishProcessedSubtitle(
        document,
        workId: 'pair-optimized',
        operation: 'optimization',
        executor: 'agent',
        language: 'en',
        texts: ['Hello, world.', 'Second line.'],
        guard: () {},
      );
      final optimizedDoc = await reader.authorizedSubtitle(
        id,
        optimized['documentId'] as String,
      );
      final translated = await backend.publishProcessedSubtitle(
        optimizedDoc,
        workId: 'pair-translated',
        operation: 'translation',
        executor: 'agent',
        language: 'en',
        texts: ['Hello!', 'Second line.'],
        guard: () {},
      );
      final picked = await tool('subtitle_select', {
        'mediaId': id,
        'primaryDocumentId': optimized['documentId'],
        'secondaryDocumentId': translated['documentId'],
        'requestId': 'pair-both',
      });
      expect(translated['sourceAssetId'], optimized['assetId']);
      expect(picked['applied'], true);
      expect(picked['selectionSaved'], true);
      expect(picked['loadedForCurrentMedia'], false);
      expect(playback.currentItem, null);
      expect(picked['primary']['name'], '［优化］测试课程');
      expect(picked['secondary']['name'], '［英文］测试课程');
      final listing = await tool('documents_list', {'mediaId': id});
      final docs = (listing['documents'] as List).cast<Map>();
      expect(
        docs.singleWhere((d) => d['selected'] == true)['label'],
        '［优化］测试课程',
      );
      expect(
        docs.singleWhere((d) => d['selectedAsSecondary'] == true)['label'],
        '［英文］测试课程',
      );
      final swapped = await tool('subtitle_select', {
        'mediaId': id,
        'primaryDocumentId': translated['documentId'],
        'secondaryDocumentId': optimized['documentId'],
        'requestId': 'pair-swap',
      });
      expect(swapped['primary']['assetId'], translated['assetId']);
      expect(swapped['secondary']['assetId'], optimized['assetId']);
      final cleared = await tool('subtitle_select', {
        'mediaId': id,
        'primaryDocumentId': originalId,
        'clearSecondary': true,
        'requestId': 'pair-original',
      });
      expect(cleared['primary']['documentId'], originalId);
      expect(cleared['secondary'], null);
      expect(library.getVideo(id)!.subtitlePath, source.path);
      expect(library.getVideo(id)!.secondarySubtitlePath, null);
      final invalid = await rpc('tools/call', {
        'name': 'subtitle_select',
        'arguments': {
          'mediaId': id,
          'primaryDocumentId': originalId,
          'secondaryDocumentId': originalId,
          'requestId': 'pair-duplicate',
        },
      });
      expect(invalid['result']['isError'], true);
      expect(library.getVideo(id)!.subtitlePath, source.path);
      expect(library.getVideo(id)!.secondarySubtitlePath, null);
      playback.debugSeedCurrentItem(library.getVideo(id));
      final live = await tool('subtitle_select', {
        'mediaId': id,
        'primaryDocumentId': optimized['documentId'],
        'secondaryDocumentId': translated['documentId'],
        'requestId': 'pair-current',
      });
      expect(live['loadedForCurrentMedia'], true);
      expect(live['applied'], true);
      expect(playback.currentItem!.id, id);
      expect(await mediaFile.readAsBytes(), beforeMedia);
      expect(await source.readAsBytes(), beforeSource);
      expect(
        jsonEncode([picked, swapped, cleared, listing, invalid]),
        isNot(contains(root.path)),
      );
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
    'Windows native unified auto plan mixes existing and missing subtitles with Agent stages',
    () async {
      prefs = prefs.copyWith(
        autoTaskDecisions: true,
        autoRemoteProcessing: true,
      );
      center.asrEnhancements = AsrEnhancementOptions.disabled;
      center.asrCpuThreads = 2;
      center.asrAccelerationOptions['sensevoice-small-int8'] =
          AsrAcceleration.cpu;
      center.asrProfileId = 'local:sensevoice-small-int8';
      center.profiles[center.asrProfileId] = ModelServiceProfile(
        id: center.asrProfileId,
        name: 'Prepared native fixture',
        kind: TranscriptionServiceKind.local,
        model: 'sensevoice-small-int8',
        language: 'en',
      );
      final model = center.artifact('sensevoice-small-int8')!;
      final sample = File(
        localAsrProbeAsset(model.engine, model.languages, language: 'en'),
      );
      final clean = await Directory(p.join(root.path, 'native-clean')).create();
      final input = await sample.copy(p.join(clean.path, 'short.wav'));
      final durationMs =
          decodeModelWave(await input.readAsBytes()).length * 1000 ~/ 16000;
      const missingId = 'native-missing';
      library.seedVideoForTesting(
        VideoItem(
          id: id,
          path: input.path,
          title: 'Already subtitled sample',
          type: MediaType.audio,
          durationMs: durationMs,
          lastUpdated: 0,
          subtitlePath: source.path,
          hasProbedChapters: true,
        ),
      );
      library.seedVideoForTesting(
        VideoItem(
          id: missingId,
          path: input.path,
          title: 'Missing subtitle sample',
          type: MediaType.audio,
          durationMs: durationMs,
          lastUpdated: 0,
          hasProbedChapters: true,
        ),
      );
      final sourceBytes = await source.readAsBytes();
      var plan = await tool('subtitle_plan', {
        'targets': [
          {'mediaId': id},
          {'mediaId': missingId},
        ],
        'source': 'auto',
        'optimize': 'agent',
        'translate': 'agent',
        'targetLanguage': 'zh-CN',
        'requestId': 'native-unified-plan',
      });
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (plan['status'] == 'preparing_documents') {
        expect(
          DateTime.now().isBefore(deadline),
          true,
          reason: jsonEncode(plan),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        plan = await tool('subtitle_plan', {'planId': plan['planId']});
      }
      expect(plan['status'], 'ready', reason: jsonEncode(plan));
      expect(plan['existingSubtitleMedia'], 1);
      expect(plan['needsTranscriptionMedia'], 1);
      expect(manager.getQueueSnapshot(), isEmpty);
      final started = await tool('subtitle_process', {
        'planId': plan['planId'],
        'requestId': 'native-unified-start',
      });
      await finishAgentStages(started['jobId'] as String, [id, missingId]);
      final native = manager.getQueueSnapshot();
      expect(native, hasLength(1));
      expect(native.single.videoId, missingId);
      expect(library.getVideo(id)!.managedSubtitleAssets, hasLength(2));
      expect(library.getVideo(missingId)!.managedSubtitleAssets, hasLength(3));
      final generated = manager.getGeneratedSrtPathForVideo(
        input.path,
        videoId: missingId,
      )!;
      expect(
        SubtitleParser.parseSrt(await File(generated).readAsString()),
        isNotEmpty,
      );
      expect(await source.readAsBytes(), sourceBytes);
      expect(center.downloadAttempts, 0);
      expect(center.captureAttempts, 0);
      expect(jsonEncode([plan, started]), isNot(contains(root.path)));
    },
    skip: !nativeEnabled,
    timeout: const Timeout(Duration(minutes: 3)),
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
