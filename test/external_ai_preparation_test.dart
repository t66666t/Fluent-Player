import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/external_ai/external_ai_action_store.dart';
import 'package:video_player_app/features/external_ai/external_ai_actions.dart';
import 'package:video_player_app/features/external_ai/external_ai_approvals.dart';
import 'package:video_player_app/features/external_ai/external_ai_document_backend.dart';
import 'package:video_player_app/features/external_ai/external_ai_library_source.dart';
import 'package:video_player_app/features/external_ai/external_ai_preferences.dart';
import 'package:video_player_app/features/external_ai/external_ai_preparation.dart';
import 'package:video_player_app/features/external_ai/external_ai_processing_backend.dart';
import 'package:video_player_app/models/managed_subtitle_asset.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/task_subtitle_storage_service.dart';

class _Processing implements ExternalAiProcessingBackend {
  int downloads = 0, changes = 0;
  @override
  Future<Map<String, dynamic>> modelStatus(List<String> ids) async => {
    'models': [
      for (final id in ids) {'id': id, 'installed': false},
    ],
  };
  @override
  Future<Map<String, dynamic>> modelPreview(List<String> ids) async => {
    'modelIds': ids,
    'downloadBytes': 1234,
  };
  @override
  Future<void> prepareModels(List<String> ids, void Function() guard) async {
    guard();
    downloads++;
  }

  @override
  Future<Map<String, dynamic>> defaultsPreview(Map<String, dynamic> v) async =>
      {'changes': v};
  @override
  Future<void> updateDefaults(
    Map<String, dynamic> v,
    void Function() guard,
  ) async {
    guard();
    changes++;
  }
}

const _srt = '1\n00:00:00,000 --> 00:00:01,000\nA useful sentence\n\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStorageService storage, previous;
  late LibraryService library;
  late ExternalAiPreferences prefs;
  late ExternalAiApprovals approvals;
  late ExternalAiLibrarySource reader;
  late ExternalAiPreparation preparation;
  late _Processing processing;
  late ExternalAiDocumentBackend documents;
  int probes = 0, extractions = 0, epoch = 0;
  List<Map<String, dynamic>> streams = [];
  Completer<void>? hold;
  final settings = SettingsService();

  Future<Map<String, dynamic>> status(String id) =>
      preparation.callTool('documents_prepare_status', {'jobId': id});
  Future<Map<String, dynamic>> finished(String id) async {
    for (var i = 0; i < 100; i++) {
      final result = await status(id);
      if (!['running', 'queued', 'cancelling'].contains(result['status'])) {
        return result;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw StateError('preparation did not finish');
  }

  Future<VideoItem> media(String id, {bool sidecar = false}) async {
    final file = File(p.join(root.path, '$id.mkv'));
    await file.writeAsString('private media sentinel');
    if (sidecar) await File(p.join(root.path, '$id.srt')).writeAsString(_srt);
    final item = VideoItem(
      id: id,
      path: file.path,
      title: 'Lesson $id',
      durationMs: 0,
      lastUpdated: 0,
    );
    library.seedVideoForTesting(item);
    return item;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mcp-preparation-');
    SharedPreferences.setMockInitialValues({});
    settings.resetForTest();
    previous = AppStorageService.instance;
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
    prefs = ExternalAiPreferences(
      token: ExternalAiPreferences.generateToken(),
      enabled: true,
      allowTaskControl: true,
    );
    approvals = ExternalAiApprovals(
      store: ExternalAiActionStore(root, name: 'approvals-v1'),
      preferences: () => prefs,
    );
    await approvals.initialize();
    processing = _Processing();
    probes = 0;
    extractions = 0;
    hold = null;
    streams = [];
    epoch = 0;
    documents = ExternalAiDocumentBackend(
      library: library,
      command: (work, probe, args) async {
        if (probe) {
          probes++;
          return (code: 0, output: jsonEncode({'streams': streams}));
        }
        extractions++;
        await hold?.future;
        work.check();
        expect(args[args.indexOf('-map') + 1], '0:7');
        await File(args.last).writeAsString(_srt);
        return (code: 0, output: '');
      },
    );
    reader = ExternalAiLibrarySource.fromLibrary(library);
    preparation = ExternalAiPreparation(
      library: reader,
      documents: documents,
      processing: processing,
      approvals: approvals,
      store: ExternalAiActionStore(root, name: 'preparation-v1'),
      preferences: () => prefs,
      generation: () => epoch,
    );
    await preparation.initialize();
  });
  tearDown(() async {
    hold?.complete();
    hold = null;
    await preparation.shutdown();
    approvals.dispose();
    library.resetLibraryForTesting();
    await storage.releaseForegroundLease();
    AppStorageService.instance = previous;
    settings.resetForTest();
    await root.delete(recursive: true);
  });

  test(
    'downloads and default changes require app approval, with exact retry and no MCP approve endpoint',
    () async {
      final args = {
        'modelIds': ['known-model'],
        'requestId': 'download-1',
      };
      final pending = await preparation.callTool('models_prepare', args);
      expect(pending['status'], 'approval_required');
      expect(processing.downloads, 0);
      expect(await preparation.callTool('models_prepare', args), pending);
      await expectLater(
        preparation.callTool('approvals_approve', {
          'approvalId': pending['approvalId'],
        }),
        throwsA(isA<ExternalAiActionError>()),
      );
      await approvals.resolve(pending['approvalId'] as String, approve: true);
      expect(
        (await preparation.callTool('models_prepare', args))['status'],
        'queued',
      );
      await preparation.callTool('models_prepare', args);
      expect(processing.downloads, 1);
      await expectLater(
        preparation.callTool('models_prepare', {
          'modelIds': ['different'],
          'requestId': 'download-1',
        }),
        throwsA(isA<ExternalAiActionError>()),
      );
      prefs = prefs.copyWith(
        autoTaskDecisions: true,
        autoModelDownloads: true,
        autoRemoteProcessing: true,
      );
      final change = await preparation.callTool('settings_update', {
        'sourceLanguage': 'en',
        'requestId': 'settings-1',
      });
      expect(change['status'], 'approval_required');
      expect(processing.changes, 0);
      await approvals.resolve(change['approvalId'] as String, approve: false);
      expect(
        (await preparation.callTool('settings_update', {
          'sourceLanguage': 'en',
          'requestId': 'settings-1',
        }))['status'],
        'denied',
      );
      expect(processing.changes, 0);
    },
  );
  test(
    'delegation is category specific, approvals are bound to identity and scope',
    () async {
      prefs = prefs.copyWith(autoTaskDecisions: true);
      expect(
        await approvals.require(
          categories: ['tasks'],
          identity: ['x'],
          preview: {},
        ),
        null,
      );
      final remote = await approvals.require(
        categories: ['tasks', 'remote'],
        identity: ['x'],
        preview: {},
      );
      expect(remote!['status'], 'approval_required');
      await approvals.resolve(remote['approvalId'] as String, approve: true);
      expect(
        await approvals.require(
          categories: ['tasks', 'remote'],
          identity: ['x'],
          preview: {},
        ),
        null,
      );
      expect(
        (await approvals.require(
          categories: ['tasks', 'remote'],
          identity: ['different'],
          preview: {},
        ))!['status'],
        'approval_required',
      );
      prefs = prefs.copyWith(scopeFolderId: 'different-scope');
      expect(
        (await approvals.require(
          categories: ['tasks', 'remote'],
          identity: ['x'],
          preview: {},
        ))!['status'],
        'approval_required',
      );
      prefs = prefs.copyWith(autoRemoteProcessing: true);
      expect(
        await approvals.require(
          categories: ['tasks', 'remote'],
          identity: ['x'],
          preview: {},
        ),
        null,
      );
    },
  );
  test(
    'one batch discovers sidecars without playback and reads saved unselected soft subtitles without probing',
    () async {
      await media('lesson-1', sidecar: true);
      final cached = await media('lesson-2');
      final taskStorage = TaskSubtitleStorageService(
        dataRootOverride: library.dataRootDirOrNull,
      );
      final path = await taskStorage.allocatePath(
        cached.id,
        'lesson-2.stream_4.srt',
      );
      await File(path).writeAsString(_srt);
      final ticket = await preparation.callTool('documents_prepare', {
        'mediaIds': ['lesson-1', 'lesson-2'],
        'requestId': 'prepare-batch-1',
      });
      final done = await finished(ticket['jobId'] as String);
      expect((done['items'] as List).map((v) => v['state']), [
        'ready',
        'ready',
      ]);
      expect(probes, 0);
      expect(extractions, 0);
      expect(library.getVideo('lesson-1')!.subtitlePath, null);
      expect(
        (await reader.callTool('documents_list', {
          'mediaId': cached.id,
        }))['documents'],
        isNotEmpty,
      );
      expect(jsonEncode([ticket, done]), isNot(contains(root.path)));
      final again = await preparation.callTool('documents_prepare', {
        'mediaIds': ['lesson-1', 'lesson-2'],
        'requestId': 'prepare-batch-1',
      });
      expect(again['jobId'], ticket['jobId']);
    },
  );
  test(
    'only text soft tracks are extracted with absolute stream index and registered once',
    () async {
      final item = await media('embedded');
      streams = [
        {'index': 2, 'codec_name': 'hdmv_pgs_subtitle'},
        {
          'index': 7,
          'codec_name': 'subrip',
          'tags': {'language': 'eng'},
        },
      ];
      Future<Map<String, dynamic>> prepare(String request) async {
        final ticket = await preparation.callTool('documents_prepare', {
          'mediaIds': [item.id],
          'requestId': request,
        });
        return finished(ticket['jobId'] as String);
      }

      final done = await prepare('soft-first');
      expect((done['items'] as List).single['state'], 'ready');
      expect(probes, 1);
      expect(extractions, 1);
      expect(
        item.managedSubtitleAssets.single.kind,
        ManagedSubtitleAssetKind.embedded,
      );
      expect(item.subtitlePath, null);
      await prepare('soft-second');
      expect(probes, 1);
      expect(extractions, 1);
      final onlyBitmap = await media('bitmap-only');
      streams = [
        {'index': 3, 'codec_name': 'dvd_subtitle'},
      ];
      final ticket = await preparation.callTool('documents_prepare', {
        'mediaIds': [onlyBitmap.id],
        'requestId': 'bitmap-skip',
      });
      final result =
          (await finished(ticket['jobId'] as String))['items'] as List;
      expect(result.single['state'], 'confirmed_none');
      expect(extractions, 1);
    },
  );
  test(
    'cancellation and authorization changes prevent late attachment and mark remaining media',
    () async {
      final item = await media('cancelled');
      await media('after-cancel');
      streams = [
        {'index': 7, 'codec_name': 'subrip'},
      ];
      hold = Completer<void>();
      final ticket = await preparation.callTool('documents_prepare', {
        'mediaIds': [item.id, 'after-cancel'],
        'requestId': 'cancel-batch',
      });
      for (var i = 0; i < 100 && extractions == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(extractions, 1);
      await preparation.callTool('documents_prepare_cancel', {
        'jobId': ticket['jobId'],
      });
      hold!.complete();
      hold = null;
      final done = await finished(ticket['jobId'] as String);
      expect(done['status'], 'cancelled');
      expect(item.managedSubtitleAssets, isEmpty);
      expect(
        (done['items'] as List).every((r) => r['state'] == 'cancelled'),
        true,
      );
      prefs = prefs.copyWith(token: ExternalAiPreferences.generateToken());
      epoch++;
      await expectLater(
        status(ticket['jobId'] as String),
        throwsA(isA<ExternalAiActionError>()),
      );
    },
  );
  test(
    'unchecked and candidates never claim a media has no subtitles',
    () async {
      final item = await media('unchecked');
      final ticket = await preparation.callTool('documents_prepare', {
        'mediaIds': [item.id],
        'includeEmbedded': false,
        'includeOnline': false,
        'requestId': 'unchecked-batch',
      });
      final row =
          ((await finished(ticket['jobId'] as String))['items'] as List).single;
      expect(row['state'], 'unchecked');
      expect(probes, 0);
      await expectLater(
        preparation.callTool('documents_prepare', {
          'mediaIds': [item.id],
          'path': item.path,
          'requestId': 'path-inject',
        }),
        throwsA(isA<ExternalAiActionError>()),
      );
    },
  );
}
