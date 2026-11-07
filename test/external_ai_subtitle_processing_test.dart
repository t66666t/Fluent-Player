import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/external_ai/external_ai_action_store.dart';
import 'package:video_player_app/features/external_ai/external_ai_actions.dart';
import 'package:video_player_app/features/external_ai/external_ai_approvals.dart';
import 'package:video_player_app/features/external_ai/external_ai_library_source.dart';
import 'package:video_player_app/features/external_ai/external_ai_preferences.dart';
import 'package:video_player_app/features/external_ai/external_ai_subtitle_backend.dart';
import 'package:video_player_app/features/external_ai/external_ai_subtitle_processing.dart';
import 'package:video_player_app/features/external_ai/external_ai_server.dart';
import 'package:video_player_app/models/managed_subtitle_asset.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/task_subtitle_storage_service.dart';

String srt(List<String> lines) => [
  for (var i = 0; i < lines.length; i++)
    '${i + 1}\n00:${(i ~/ 30).toString().padLeft(2, '0')}:${(i * 2 % 60).toString().padLeft(2, '0')},123 --> 00:${(i ~/ 30).toString().padLeft(2, '0')}:${(i * 2 % 60 + 1).toString().padLeft(2, '0')},456\n${lines[i]}\n',
].join('\n');

class _FailingStore extends ExternalAiActionStore {
  _FailingStore(super.root) : super(name: 'subtitle-tests');
  bool failNext = false;
  int jobSaves = 0;
  bool failAfterJobReceipt = false;
  void Function(Map<String, dynamic>)? onSave;
  Future<void> Function(Map<String, dynamic>)? beforeSave;
  @override
  Future<void> save(Map<String, dynamic> state) async {
    await beforeSave?.call(state);
    onSave?.call(state);
    if ((state['jobs'] as Map? ?? {}).isNotEmpty) jobSaves++;
    if (failNext || failAfterJobReceipt && jobSaves == 2) {
      failNext = false;
      throw const FileSystemException('simulated journal failure');
    }
    await super.save(state);
  }
}

class _Backend implements ExternalAiSubtitleBackend {
  _Backend(this.root);
  final Directory root;
  final publications = <String, Map<String, dynamic>>{};
  final calls = <Map<String, dynamic>>[];
  final softwareResults = <String, ExternalAiSubtitleOutput>{};
  final rows = <ExternalAiNativeTask>[];
  final pauseOnRecognitionFor = <String>{};
  final holdRecognitionFor = <String>{};
  final recognizedAssetsByTask = <String, String>{};
  final pausedRecognitionTasks = <String>{};
  void Function()? afterRecognitionAdmission;
  final listeners = <void Function()>[];
  int recognitionStarts = 0, selections = 0, publishAttempts = 0;
  bool remote = false,
      fail = false,
      useAgentRouting = false,
      failRecognitionRead = false;
  int configurationVersion = 1;
  SmartTranslationPolicy? smartPolicy;
  final capturedRequests = <Map<String, dynamic>>[];
  Completer<void>? hold;
  void Function()? afterPublish;
  Future<void> Function()? beforePublishReturn;
  String? recognizedAsset;
  @override
  String mediaIdentity(VideoItem media) => '${media.id}:${media.path}';
  @override
  void addTaskListener(void Function() listener) => listeners.add(listener);
  @override
  void removeTaskListener(void Function() listener) =>
      listeners.remove(listener);
  @override
  List<ExternalAiNativeTask> tasks() => rows;
  @override
  Future<Map<String, dynamic>> subtitleOptions() async => {
    'services': [],
    'mediaFilesProvided': false,
  };
  @override
  Future<Map<String, dynamic>> captureSubtitlePlan(
    Map<String, dynamic> request,
  ) async {
    capturedRequests.add({...request});
    return {
      'usesRemote': remote,
      'missingModelIds': [],
      'sourceLanguage': 'zh-CN',
      'targetLanguage': smartPolicy == null
          ? request['targetLanguage'] ?? 'en'
          : 'mul',
      'optimization': {'version': configurationVersion},
      'recognition': request['_requiresRecognition'] == true
          ? {'service': 'gongyi'}
          : null,
      if (useAgentRouting) 'agentTranslationContract': 2,
      if (smartPolicy != null) 'agentTranslationPolicy': smartPolicy!.toJson(),
      'optimizationPrompt': '保持原语言，轻度纠错，不补写',
      'backgrounds': {},
      'summary': {'uploadsText': remote},
    };
  }

  @override
  Future<void> startSubtitleRecognition(
    VideoItem media,
    String taskId,
    Map<String, dynamic> plan,
    void Function() guard,
  ) async {
    guard();
    recognitionStarts++;
    if (holdRecognitionFor.contains(media.id)) {
      rows.add(
        ExternalAiNativeTask(
          mediaId: media.id,
          taskId: taskId,
          status: 'running',
          progress: .1,
        ),
      );
      for (final listener in [...listeners]) {
        listener();
      }
      afterRecognitionAdmission?.call();
      return;
    }
    if (pauseOnRecognitionFor.contains(media.id)) {
      rows.add(
        ExternalAiNativeTask(
          mediaId: media.id,
          taskId: taskId,
          status: 'paused',
          progress: .2,
        ),
      );
      for (final listener in [...listeners]) {
        listener();
      }
      afterRecognitionAdmission?.call();
      return;
    }
    final source = ExternalAiSubtitleDocument(
      media: media,
      documentId: 'unused',
      path: media.subtitlePath ?? '${root.path}/not-selected.srt',
      revision: '',
      cues: [],
    );
    final asset = await publishProcessedSubtitle(
      source,
      workId: 'recognized-${media.id}',
      operation: 'optimization',
      executor: 'app',
      language: 'zh-CN',
      texts: ['新识别的人工职能课程'],
      guard: guard,
    );
    recognizedAsset = asset['assetId'] as String;
    recognizedAssetsByTask[taskId] = recognizedAsset!;
    rows.add(
      ExternalAiNativeTask(
        mediaId: media.id,
        taskId: taskId,
        status: 'completed',
        progress: 1,
      ),
    );
    for (final listener in [...listeners]) {
      listener();
    }
    afterRecognitionAdmission?.call();
  }

  @override
  Future<void> pauseSubtitleRecognition(VideoItem media, String taskId) async {
    pausedRecognitionTasks.add(taskId);
    final index = rows.indexWhere((r) => r.taskId == taskId);
    if (index >= 0 && rows[index].status != 'completed') {
      rows[index] = ExternalAiNativeTask(
        mediaId: media.id,
        taskId: taskId,
        status: 'paused',
        progress: rows[index].progress,
      );
      for (final listener in [...listeners]) {
        listener();
      }
    }
  }

  @override
  Future<void> cancelSubtitleRecognition(
    VideoItem media,
    String taskId,
  ) async {}
  @override
  Future<String?> recognitionAssetId(VideoItem media, String taskId) async {
    if (failRecognitionRead) {
      throw StateError('simulated late result read failure');
    }
    return recognizedAssetsByTask[taskId] ?? recognizedAsset;
  }

  @override
  Future<ExternalAiSubtitleOutput> runSubtitleWorkflow(
    ExternalAiSubtitleDocument source, {
    required String workId,
    required bool optimize,
    required bool translate,
    bool completedOnly = false,
    required Map<String, dynamic> plan,
    required Future<void> cancelSignal,
    required void Function(double, Map<String, dynamic>) onProgress,
    required void Function() guard,
  }) async {
    if (softwareResults.containsKey(workId)) return softwareResults[workId]!;
    if (completedOnly) {
      throw StateError('Completed software result unavailable');
    }
    calls.add({
      'optimize': optimize,
      'translate': translate,
      'input': source.cues.map((c) => c.text).join('\n'),
    });
    onProgress(.37, {'futureApplicationStep': 'a renamed internal step'});
    if (hold != null) await Future.any([hold!.future, cancelSignal]);
    guard();
    if (fail) throw StateError('C:/private/media.mp4?token=NEVER-RETURN-THIS');
    final optimized = [
      for (final cue in source.cues) cue.text.replaceAll('人工职能', '人工智能'),
    ];
    return softwareResults[workId] = ExternalAiSubtitleOutput(
      optimized: optimize ? optimized : null,
      translated: translate
          ? [
              for (final text
                  in optimize ? optimized : source.cues.map((c) => c.text))
                'Translation: $text',
            ]
          : null,
    );
  }

  @override
  Future<Map<String, dynamic>> publishProcessedSubtitle(
    ExternalAiSubtitleDocument source, {
    required String workId,
    required String operation,
    required String executor,
    required String language,
    required List<String> texts,
    required void Function() guard,
  }) async {
    guard();
    publishAttempts++;
    final existing = publications[workId];
    if (existing != null) return existing;
    final file = await File(
      '${root.path}/$workId.srt',
    ).writeAsString(srt(texts));
    final original = source.media.managedSubtitleAssets
        .where((a) => p.normalize(a.path) == p.normalize(source.path))
        .firstOrNull;
    final asset = ManagedSubtitleAsset(
      assetId: workId,
      path: file.path,
      kind: operation == 'optimization'
          ? ManagedSubtitleAssetKind.ai
          : ManagedSubtitleAssetKind.translated,
      displayName: '$executor $operation',
      language: language,
      sourceAssetId: original?.assetId,
      createdAt: 1,
    );
    source.media.managedSubtitleAssets = [
      ...source.media.managedSubtitleAssets,
      asset,
    ];
    final result = <String, dynamic>{
      'assetId': workId,
      'mediaId': source.media.id,
      'displayName': asset.displayName,
      'kind': asset.kind.name,
      'language': language,
    };
    publications[workId] = result;
    afterPublish?.call();
    if (beforePublishReturn != null) await beforePublishReturn!();
    return result;
  }

  @override
  Future<Map<String, dynamic>> selectProcessedSubtitles(
    ExternalAiSubtitleDocument source, {
    String? primaryAssetId,
    String? secondaryAssetId,
    required Map<String, dynamic> plan,
    required void Function() guard,
  }) async {
    guard();
    selections++;
    return {
      'applied': true,
      'selectionSaved': true,
      'status': 'selected',
      'loadedForCurrentMedia': true,
      'primary': {'assetId': primaryAssetId, 'documentId': source.documentId},
      'secondary': secondaryAssetId == null
          ? null
          : {'assetId': secondaryAssetId},
    };
  }
}

class _RealHttp extends HttpOverrides {}

class _Documents implements ExternalAiDataSource {
  _Documents({this.states = const {}});
  final Map<String, String> states;
  int starts = 0;
  List<String> ids = [];
  @override
  List<Map<String, dynamic>> get tools => [];
  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    if (name == 'documents_prepare') {
      starts++;
      ids = (args['mediaIds'] as List).cast<String>();
    }
    return {
      'jobId': 'prepared-batch',
      'status': 'completed',
      'items': [
        for (final id in ids)
          {'mediaId': id, 'state': states[id] ?? 'confirmed_none'},
      ],
    };
  }
}

/// Returns a frozen source read only after the test releases one exact IO
/// boundary. Foreground reads remain free to complete while the runner waits.
class _GatedLibrary extends ExternalAiLibrarySource {
  _GatedLibrary(ExternalAiLibrarySource source)
    : super(
        videos: source.videos,
        folders: source.folders,
        children: source.children,
        currentMedia: source.currentMedia,
        playback: source.playback,
        catalog: source.catalog,
        scopeFolder: source.scopeFolder,
        conversationsAllowed: source.conversationsAllowed,
        conversationStore: source.conversationStore,
        ready: source.ready,
        taskStorage: source.taskStorage,
      );
  final entered = Completer<void>(), release = Completer<void>();
  int? blockRead;
  int reads = 0;
  void arm() {
    blockRead = 2;
    reads = 0;
  }

  @override
  Future<ExternalAiSubtitleDocument> authorizedSubtitle(
    String mediaId,
    String documentId,
  ) async {
    final source = await super.authorizedSubtitle(mediaId, documentId);
    if (blockRead != null && ++reads == blockRead) {
      entered.complete();
      await release.future;
    }
    return source;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File original;
  late VideoItem media;
  late List<VideoItem> videos;
  late List<VideoCollection> folders;
  late ExternalAiPreferences prefs;
  late ExternalAiApprovals approvals;
  late ExternalAiLibrarySource reader;
  late _Backend backend;
  late _FailingStore store;
  late ExternalAiSubtitleProcessing processing;
  final instances = <ExternalAiSubtitleProcessing>[];
  int sequence = 0, epoch = 0;
  ExternalAiSubtitleProcessing create({ExternalAiDataSource? documents}) {
    final p = ExternalAiSubtitleProcessing(
      library: reader,
      backend: backend,
      store: store,
      approvals: approvals,
      preferences: () => prefs,
      generation: () => epoch,
      documents: documents,
    );
    instances.add(p);
    return p;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mcp-subtitle-workflows-');
    original = await File(
      '${root.path}/original.srt',
    ).writeAsString(srt(['这是人工职能课程。', '我们学习人工职能。']));
    await File(
      '${root.path}/private.mp4',
    ).writeAsString('PRIVATE-MEDIA-BYTES-NOT-FOR-MCP');
    media = VideoItem(
      id: 'lesson',
      title: '课程',
      path: '${root.path}/private.mp4',
      subtitlePath: original.path,
      durationMs: 6000,
      lastUpdated: 0,
    );
    videos = [media];
    folders = [];
    prefs = ExternalAiPreferences(
      token: ExternalAiPreferences.generateToken(),
      enabled: true,
      allowTaskControl: true,
      allowSubtitleWrite: true,
      autoTaskDecisions: true,
      autoRemoteProcessing: true,
      autoModelDownloads: true,
    );
    reader = ExternalAiLibrarySource(
      videos: () => videos,
      folders: () => folders,
      children: (_) => videos,
      scopeFolder: () => prefs.scopeFolderId,
      taskStorage: TaskSubtitleStorageService(dataRootOverride: root),
    );
    store = _FailingStore(root);
    backend = _Backend(root);
    approvals = ExternalAiApprovals(
      store: ExternalAiActionStore(root, name: 'approvals'),
      preferences: () => prefs,
    );
    sequence = 0;
    epoch = 0;
    instances.clear();
    processing = create();
    await processing.initialize();
  });
  tearDown(() async {
    for (final p in instances.reversed) {
      await p.shutdown();
    }
    approvals.dispose();
    await root.delete(recursive: true);
  });
  String request() => 'request-${++sequence}';
  Future<Map<String, dynamic>> start(
    String opt,
    String trans, {
    bool load = false,
    String source = 'existing',
    String? requestId,
  }) => processing.callTool('subtitle_process', {
    'targets': [
      {'mediaId': media.id},
    ],
    'optimize': opt,
    'translate': trans,
    'source': source,
    'loadSubtitles': load,
    'requestId': requestId ?? request(),
  });
  Future<Map<String, dynamic>> wait(String id) async {
    final elapsed = Stopwatch()..start();
    while (true) {
      final result = await processing.callTool('subtitle_jobs', {'jobId': id});
      if (!['queued', 'running'].contains(result['status'])) return result;
      if (elapsed.elapsed > const Duration(seconds: 8)) {
        fail('job did not yield: $result');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<Map<String, dynamic>> read(String id, [String? stage]) =>
      processing.callTool('subtitle_work_read', {
        'jobId': id,
        'mediaId': media.id,
        'stage': ?stage,
      });
  Future<Map<String, dynamic>> complete(String id) async {
    final work = await read(id);
    return processing.callTool('subtitle_work_write', {
      'jobId': id,
      'mediaId': media.id,
      'stage': work['stage'],
      'expectedRevision': work['revision'],
      'requestId': request(),
      'complete': true,
      'entries': [
        for (final e in work['entries'] as List)
          {
            'cueId': e['cueId'],
            'text': work['stage'] == 'optimization'
                ? (e['text'] as String).replaceAll('人工职能', '人工智能')
                : 'Translation: ${e['text']}',
          },
      ],
    });
  }

  test(
    'omitting loadSubtitles applies and reports the recommended pair by default',
    () async {
      final created = await processing.callTool('subtitle_process', {
        'targets': [
          {'mediaId': media.id},
        ],
        'source': 'existing',
        'optimize': 'app',
        'translate': 'app',
        'requestId': request(),
      });
      expect(created['subtitlePresentation']['mode'], 'apply_when_complete');
      expect(created['subtitlePresentation']['primary'], 'optimized');
      expect(created['subtitlePresentation']['secondary'], 'translation');
      final result = await wait(created['jobId'] as String);
      expect(result['status'], 'completed');
      expect(backend.selections, 1);
      expect(result['items'][0]['subtitleSelection']['applied'], true);
    },
  );

  test(
    'explicit save-only preserves selection and explains how to apply later',
    () async {
      final created = await start('app', 'app', load: false);
      final result = await wait(created['jobId'] as String);
      expect(result['status'], 'completed');
      expect(backend.selections, 0);
      expect(result['subtitlePresentation']['mode'], 'save_only');
      expect(result['items'][0]['subtitleSelection']['status'], 'saved_only');
    },
  );

  for (final opt in ['off', 'app', 'agent']) {
    for (final trans in ['off', 'app', 'agent']) {
      if (opt == 'off' && trans == 'off') continue;
      test(
        'existing subtitles optimize=$opt translate=$trans use ordered version and preserve original',
        () async {
          final bytes = await original.readAsBytes();
          final created = await start(opt, trans, load: true);
          final id = created['jobId'] as String;
          var status = await wait(id);
          while (status['status'] == 'awaiting_agent') {
            await complete(id);
            status = await wait(id);
          }
          expect(status['status'], 'completed', reason: '$status');
          expect(await original.readAsBytes(), bytes);
          expect(backend.recognitionStarts, 0);
          expect(backend.selections, 1);
          expect(
            backend.calls.length,
            opt == 'app' && trans == 'app'
                ? 1
                : [opt, trans].where((x) => x == 'app').length,
          );
          if (trans != 'off') {
            final asset = media.managedSubtitleAssets.last;
            final output = await File(asset.path).readAsString();
            expect(output, contains(opt == 'off' ? '人工职能' : '人工智能'));
            if (opt != 'off') {
              expect(
                asset.sourceAssetId,
                media.managedSubtitleAssets.first.assetId,
              );
            }
          }
        },
      );
    }
  }

  test(
    'asks once for the batch and saved local preferences can choose executors',
    () async {
      await processing.setExecutorPreference('optimization', 'ask');
      expect((await start('ask', 'off'))['status'], 'needs_execution_choice');
      expect(backend.calls, isEmpty);
      await processing.setExecutorPreference('optimization', 'app');
      final p = await start('ask', 'off');
      expect((await wait(p['jobId'] as String))['status'], 'completed');
      await processing.shutdown();
      final restored = create();
      await restored.initialize();
      expect(restored.executorPreference['optimization'], 'app');
    },
  );

  test(
    'translation is unavailable until optimization has been committed',
    () async {
      final job = await start('agent', 'agent');
      final id = job['jobId'] as String;
      await wait(id);
      await expectLater(read(id, 'translation'), throwsStateError);
      final work = await read(id);
      expect(work['stage'], 'optimization');
      expect(work['untrustedSourceData'], true);
      await complete(id);
      await wait(id);
      final translatedInput = await read(id, 'translation');
      expect(jsonEncode(translatedInput['entries']), contains('人工智能'));
      expect(jsonEncode(translatedInput['entries']), isNot(contains('人工职能')));
    },
  );

  test(
    'partial writes are durable, revisioned and idempotent across reopen',
    () async {
      final job = await start('agent', 'off');
      final id = job['jobId'] as String;
      await wait(id);
      final work = await read(id);
      final args = <String, dynamic>{
        'jobId': id,
        'mediaId': media.id,
        'stage': 'optimization',
        'expectedRevision': work['revision'],
        'requestId': 'same-write-request',
        'entries': [
          {'cueId': 'cue-1', 'text': '这是人工智能课程。'},
        ],
      };
      final result = await processing.callTool('subtitle_work_write', args);
      expect(await processing.callTool('subtitle_work_write', args), result);
      await processing.shutdown();
      processing = create();
      await processing.initialize();
      expect(await processing.callTool('subtitle_work_write', args), result);
      expect((await read(id))['completedCues'], 1);
      await expectLater(
        processing.callTool('subtitle_work_write', {
          ...args,
          'requestId': request(),
        }),
        throwsStateError,
      );
    },
  );

  test(
    'rejects rewritten optimization, timestamps, unknown IDs, duplicates and missing cues',
    () async {
      final job = await start('agent', 'off');
      final id = job['jobId'] as String;
      await wait(id);
      final work = await read(id);
      for (final entries in [
        [
          {'cueId': 'cue-1', 'text': 'A translation in another language'},
        ],
        [
          {'cueId': 'cue-99', 'text': '原文'},
        ],
        [
          {'cueId': 'cue-1', 'text': '原文', 'startMs': 0},
        ],
        [
          {'cueId': 'cue-1', 'text': '00:00:00,000 --> 00:00:01,000'},
        ],
        [
          {'cueId': 'cue-1', 'text': '这是人工智能课程。'},
          {'cueId': 'cue-1', 'text': '这是人工智能课程。'},
        ],
      ]) {
        await expectLater(
          processing.callTool('subtitle_work_write', {
            'jobId': id,
            'mediaId': media.id,
            'stage': 'optimization',
            'expectedRevision': work['revision'],
            'entries': entries,
            'requestId': request(),
          }),
          throwsStateError,
        );
      }
      await expectLater(
        processing.callTool('subtitle_work_write', {
          'jobId': id,
          'mediaId': media.id,
          'stage': 'optimization',
          'expectedRevision': work['revision'],
          'entries': [],
          'complete': true,
          'requestId': request(),
        }),
        throwsStateError,
      );
      expect(backend.publications, isEmpty);
    },
  );

  test(
    'editing the original invalidates a draft without publishing or losing the original',
    () async {
      final job = await start('agent', 'app');
      final id = job['jobId'] as String;
      await wait(id);
      await original.writeAsString(srt(['用户改过的字幕']));
      await expectLater(read(id), throwsStateError);
      expect(backend.publications, isEmpty);
      expect(await original.readAsString(), contains('用户改过'));
    },
  );

  test(
    'software workflow step changes do not affect stable status or expose provider errors',
    () async {
      backend.fail = true;
      final job = await start('app', 'app');
      final status = await wait(job['jobId'] as String);
      expect(status['status'], 'failed');
      expect(jsonEncode(status), isNot(contains('NEVER-RETURN')));
      expect(jsonEncode(status), isNot(contains('private.mp4')));
      backend.fail = false;
      await processing.callTool('subtitle_job_control', {
        'jobId': job['jobId'],
        'action': 'resume',
        'requestId': request(),
      });
      expect((await wait(job['jobId'] as String))['status'], 'completed');
    },
  );

  test(
    'revocation cancels owned work, and cannot publish after permissions change',
    () async {
      backend.hold = Completer<void>();
      final job = await start('app', 'off');
      while (backend.calls.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      prefs = prefs.copyWith(allowSubtitleWrite: false);
      epoch++;
      await processing.suspend();
      expect(backend.publications, isEmpty);
      await expectLater(
        processing.callTool('subtitle_jobs', {'jobId': job['jobId']}),
        throwsStateError,
      );
    },
  );

  test(
    'default confirmation includes independent online authorization and freezes plan',
    () async {
      prefs = prefs.copyWith(
        autoTaskDecisions: false,
        autoRemoteProcessing: false,
      );
      backend.remote = true;
      final args = <String, dynamic>{
        'targets': [
          {'mediaId': media.id},
        ],
        'optimize': 'app',
        'translate': 'off',
        'requestId': request(),
      };
      final pending = await processing.callTool('subtitle_process', args);
      expect(pending['status'], 'approval_required');
      expect(backend.calls, isEmpty);
      expect(pending['categories'], containsAll(['tasks', 'remote']));
      await approvals.resolve(pending['approvalId'] as String, approve: true);
      final job = await processing.callTool('subtitle_process', args);
      expect((await wait(job['jobId'] as String))['status'], 'completed');
    },
  );

  test('a lost start acknowledgement cannot create a second job', () async {
    store.failAfterJobReceipt = true;
    final args = <String, dynamic>{
      'targets': [
        {'mediaId': media.id},
      ],
      'optimize': 'agent',
      'translate': 'off',
      'requestId': request(),
    };
    await expectLater(
      processing.callTool('subtitle_process', args),
      throwsA(anything),
    );
    final retried = await processing.callTool('subtitle_process', args);
    expect(
      (await processing.callTool('subtitle_jobs', {}))['jobs'],
      hasLength(1),
    );
    expect(retried['jobId'], isNotNull);
  });

  test(
    'a crash after publication resumes the same commit without duplicating assets',
    () async {
      final job = await start('agent', 'off');
      final id = job['jobId'] as String;
      await wait(id);
      final work = await read(id);
      final args = <String, dynamic>{
        'jobId': id,
        'mediaId': media.id,
        'stage': 'optimization',
        'expectedRevision': work['revision'],
        'requestId': 'durable-commit-request',
        'complete': true,
        'entries': [
          for (final e in work['entries'] as List)
            {
              'cueId': e['cueId'],
              'text': (e['text'] as String).replaceAll('人工职能', '人工智能'),
            },
        ],
      };
      backend.afterPublish = () {
        store.failNext = true;
      };
      await expectLater(
        processing.callTool('subtitle_work_write', args),
        throwsA(anything),
      );
      backend.afterPublish = null;
      await processing.shutdown();
      processing = create();
      await processing.initialize();
      final result = await processing.callTool('subtitle_work_write', args);
      expect(result['committed'], true);
      expect(backend.publications, hasLength(1));
      expect((await wait(id))['status'], 'completed');
    },
  );

  test(
    'source=transcribe uses its new transcript rather than an old selected subtitle',
    () async {
      final job = await start('agent', 'off', source: 'transcribe');
      await wait(job['jobId'] as String);
      final input = await read(job['jobId'] as String);
      expect(backend.recognitionStarts, 1);
      expect(jsonEncode(input['entries']), contains('新识别'));
      expect(media.subtitlePath, original.path);
    },
  );

  test(
    'service configuration accepts metadata only and secrets never enter journals',
    () async {
      final base = <String, dynamic>{
        'name': '自选接口',
        'baseUrl': 'https://example.test/v1',
        'model': 'instruction-model',
        'requestId': request(),
      };
      await expectLater(
        processing.callTool('subtitle_service_configure', {
          ...base,
          'apiKey': 'DO-NOT-SAVE',
        }),
        throwsStateError,
      );
      await expectLater(
        processing.callTool('subtitle_service_configure', {
          ...base,
          'baseUrl': 'https://example.test/v1?apiKey=DO-NOT-SAVE',
        }),
        throwsStateError,
      );
      final requestResult = await processing.callTool(
        'subtitle_service_configure',
        base,
      );
      expect(requestResult['status'], 'awaiting_user');
      await processing.resolveConnection(
        requestResult['configurationId'] as String,
        connectionId: 'saved-in-app',
      );
      final result = await processing.callTool(
        'subtitle_service_configure',
        base,
      );
      expect(result['connectionId'], 'saved-in-app');
      final state = await store.load();
      expect(jsonEncode(state), isNot(contains('DO-NOT-SAVE')));
      expect(jsonEncode(result), isNot(contains('apiKey')));
    },
  );

  test(
    'existing subtitle discovery is one batch, not one Agent request per media',
    () async {
      final discovery = _Documents();
      await processing.shutdown();
      processing = create(documents: discovery);
      await processing.initialize();
      videos.add(
        VideoItem(
          id: 'lesson-2',
          title: '第二课',
          path: '${root.path}/second.mp4',
          subtitlePath: original.path,
          durationMs: 6000,
          lastUpdated: 0,
        ),
      );
      final job = await processing.callTool('subtitle_process', {
        'targets': [
          for (final v in videos) {'mediaId': v.id},
        ],
        'optimize': 'agent',
        'translate': 'off',
        'requestId': request(),
      });
      final result = await wait(job['jobId'] as String);
      expect(result['status'], 'awaiting_agent');
      expect(
        discovery.starts,
        0,
        reason: 'Already available selected captions need no extraction',
      );
      expect(discovery.ids, isEmpty);
      expect(backend.recognitionStarts, 0);
    },
  );

  test(
    'long subtitles are bounded and can finish in resumable pages',
    () async {
      await original.writeAsString(
        srt(List.generate(80, (i) => '第${i + 1}条人工职能字幕。')),
      );
      final job = await start('agent', 'off');
      final id = job['jobId'] as String;
      await wait(id);
      var work = await read(id);
      expect(work['entries'], hasLength(20));
      expect(work['nextOffset'], 20);
      var offset = 0;
      while (true) {
        work = await processing.callTool('subtitle_work_read', {
          'jobId': id,
          'mediaId': media.id,
          'offset': offset,
        });
        final last = work['nextOffset'] == null;
        await processing.callTool('subtitle_work_write', {
          'jobId': id,
          'mediaId': media.id,
          'stage': 'optimization',
          'expectedRevision': work['revision'],
          'complete': last,
          'requestId': request(),
          'entries': [
            for (final e in work['entries'] as List)
              {
                'cueId': e['cueId'],
                'text': (e['text'] as String).replaceAll('人工职能', '人工智能'),
              },
          ],
        });
        if (last) break;
        offset = work['nextOffset'] as int;
      }
      expect((await wait(id))['status'], 'completed');
      expect(media.managedSubtitleAssets, hasLength(1));
    },
  );

  test(
    'many partial receipts do not block a long job or replay its start',
    () async {
      final started = await start('agent', 'off', requestId: 'long-job-start');
      final id = started['jobId'] as String;
      await wait(id);
      await processing.shutdown();
      final state = await store.load();
      final receipts = state['requests'] as Map;
      for (var i = 0; i < 5000; i++) {
        receipts['${approvals.grant}:old-chunk-$i'] = {
          'signature': 'old-$i',
          'result': {
            'jobId': id,
            'stage': 'optimization',
            'committed': false,
            'revision': i,
          },
        };
      }
      await store.save(state);
      processing = create();
      await processing.initialize();
      await complete(id);
      expect((await wait(id))['status'], 'completed');
      final retried = await start('agent', 'off', requestId: 'long-job-start');
      expect(retried['jobId'], id);
      expect((await store.load())['requests'].length, lessThan(5000));
      expect(backend.publications, hasLength(1));
    },
  );

  test(
    'auto plan mixes existing subtitles with confirmed missing media, and starts once',
    () async {
      await processing.shutdown();
      final discovery = _Documents();
      processing = create(documents: discovery);
      await processing.initialize();
      videos.add(
        VideoItem(
          id: 'missing',
          title: '无字幕课',
          path: '${root.path}/missing.mp4',
          durationMs: 6000,
          lastUpdated: 0,
        ),
      );
      final args = {
        'targets': [
          for (final v in videos) {'mediaId': v.id},
        ],
        'source': 'auto',
        'optimize': 'app',
        'translate': 'off',
        'requestId': 'auto-plan-start',
      };
      final preview = await processing.callTool('subtitle_plan', args);
      expect(preview['status'], 'preparing_documents');
      expect(backend.recognitionStarts, 0);
      final ready = await processing.callTool('subtitle_plan', {
        'planId': preview['planId'],
      });
      expect(ready['status'], 'ready');
      expect(ready['existingSubtitleMedia'], 1);
      expect(ready['needsTranscriptionMedia'], 1);
      final started = await processing.callTool('subtitle_process', {
        'planId': ready['planId'],
        'requestId': 'start-reviewed-plan',
      });
      final result = await wait(started['jobId'] as String);
      expect(result['status'], 'completed', reason: '$result');
      expect(backend.recognitionStarts, 1);
      expect(backend.calls, hasLength(2));
      final repeated = await processing.callTool('subtitle_process', {
        'planId': ready['planId'],
        'requestId': 'repeat-reviewed-plan',
      });
      expect(repeated['jobId'], started['jobId']);
      expect(backend.recognitionStarts, 1);
    },
  );

  test(
    'multiple unselected subtitles require a version choice before any generation',
    () async {
      media.subtitlePath = null;
      final second = await File(
        '${root.path}/second.srt',
      ).writeAsString(srt(['第二种字幕']));
      media.additionalSubtitles = {'第一版': original.path, '第二版': second.path};
      final preview = await processing.callTool('subtitle_plan', {
        'targets': [
          {'mediaId': media.id},
        ],
        'optimize': 'app',
        'requestId': request(),
      });
      expect(preview['status'], 'needs_subtitle_choice');
      expect(backend.calls, isEmpty);
      expect(backend.recognitionStarts, 0);
      final candidates =
          (preview['items'] as List).single['candidates'] as List;
      final ready = await processing.callTool('subtitle_plan', {
        'planId': preview['planId'],
        'targets': [
          {'mediaId': media.id, 'documentId': candidates.last['documentId']},
        ],
      });
      expect(ready['status'], 'ready');
      final started = await processing.callTool('subtitle_process', {
        'planId': ready['planId'],
        'requestId': request(),
      });
      expect((await wait(started['jobId'] as String))['status'], 'completed');
      expect(backend.calls.single['input'], '第二种字幕');
    },
  );

  test('failed discovery never becomes permission to transcribe', () async {
    await processing.shutdown();
    media.subtitlePath = null;
    await original.delete();
    processing = create(documents: _Documents(states: {media.id: 'failed'}));
    await processing.initialize();
    final first = await processing.callTool('subtitle_plan', {
      'targets': [
        {'mediaId': media.id},
      ],
      'source': 'auto',
      'requestId': request(),
    });
    final second = await processing.callTool('subtitle_plan', {
      'planId': first['planId'],
    });
    expect(second['status'], 'needs_subtitle_preparation');
    expect(backend.recognitionStarts, 0);
    expect(
      (await processing.callTool('subtitle_process', {
        'planId': first['planId'],
        'requestId': request(),
      }))['status'],
      'needs_subtitle_preparation',
    );
  });

  test(
    'plan checks all folder rows, paginates preview only and rejects changed defaults',
    () async {
      folders.add(VideoCollection(id: 'course', name: '课程', createTime: 0));
      media.parentId = 'course';
      for (var i = 0; i < 25; i++) {
        videos.add(
          VideoItem(
            id: 'extra-$i',
            title: '课$i',
            path: '${root.path}/extra-$i.mp4',
            parentId: 'course',
            subtitlePath: original.path,
            durationMs: 6000,
            lastUpdated: 0,
          ),
        );
      }
      final plan = await processing.callTool('subtitle_plan', {
        'folderId': 'course',
        'optimize': 'app',
        'requestId': request(),
        'limit': 5,
      });
      expect(plan['status'], 'ready');
      expect(plan['totalMedia'], 26);
      expect(plan['existingSubtitleMedia'], 26);
      expect(plan['items'], hasLength(5));
      expect(plan['nextOffset'], 5);
      backend.configurationVersion++;
      await expectLater(
        processing.callTool('subtitle_process', {
          'planId': plan['planId'],
          'requestId': request(),
        }),
        throwsStateError,
      );
      expect(backend.calls, isEmpty);
    },
  );

  test(
    'plan rejects changed source subtitle revision before starting',
    () async {
      final plan = await processing.callTool('subtitle_plan', {
        'targets': [
          {'mediaId': media.id},
        ],
        'requestId': request(),
      });
      await original.writeAsString(srt(['规划后用户改了字幕']));
      await expectLater(
        processing.callTool('subtitle_process', {
          'planId': plan['planId'],
          'requestId': request(),
        }),
        throwsStateError,
      );
      expect(backend.calls, isEmpty);
    },
  );

  test(
    'unspecified current folder is never interpreted as the entire library',
    () async {
      final result = await processing.callTool('subtitle_plan', {
        'requestId': request(),
      });
      expect(result['status'], 'needs_folder_choice');
      expect(backend.calls, isEmpty);
    },
  );

  test(
    'smart Agent writes validate each part target and preserve literal cues',
    () async {
      backend.useAgentRouting = true;
      backend.smartPolicy = const SmartTranslationPolicy(
        rules: [
          SmartTranslationRule(source: 'zh-CN', target: 'en'),
          SmartTranslationRule(source: 'en', target: 'original'),
        ],
        otherTarget: 'original',
      );
      await original.writeAsString(
        srt([
          '这是足够长的中文人工智能课程。',
          'This English sentence should remain unchanged.',
        ]),
      );
      final created = await start('off', 'agent');
      final id = created['jobId'] as String;
      await wait(id);
      final work = await read(id);
      final parts = work['translationParts'] as List;
      expect(parts, isNotEmpty);
      expect(parts.every((p) => p['targetLanguage'] == 'en'), true);
      expect(work['preserveCueIds'], contains('cue-2'));
      final bad = [
        for (final part in parts)
          {
            'cueId': part['cueId'],
            'partId': part['partId'],
            'targetLanguage': 'ja',
            'text': 'wrong direction',
          },
      ];
      await expectLater(
        processing.callTool('subtitle_work_write', {
          'jobId': id,
          'mediaId': media.id,
          'stage': 'translation',
          'expectedRevision': work['revision'],
          'parts': bad,
          'requestId': request(),
        }),
        throwsStateError,
      );
      final written = await processing.callTool('subtitle_work_write', {
        'jobId': id,
        'mediaId': media.id,
        'stage': 'translation',
        'expectedRevision': work['revision'],
        'parts': [
          for (final part in parts)
            {
              'cueId': part['cueId'],
              'partId': part['partId'],
              'targetLanguage': part['targetLanguage'],
              'text': 'An artificial intelligence lesson.',
            },
        ],
        'preserveCueIds': work['preserveCueIds'],
        'complete': true,
        'requestId': request(),
      });
      expect(written['committed'], true);
      expect((await wait(id))['status'], 'completed');
      final output = await File(
        media.managedSubtitleAssets.last.path,
      ).readAsString();
      expect(
        output,
        contains('This English sentence should remain unchanged.'),
      );
      expect(output, contains('An artificial intelligence lesson.'));
    },
  );

  test('per-media pause and retry leave other Agent work available', () async {
    videos.add(
      VideoItem(
        id: 'other',
        title: '另一个',
        path: '${root.path}/other.mp4',
        subtitlePath: original.path,
        durationMs: 6000,
        lastUpdated: 0,
      ),
    );
    final created = await processing.callTool('subtitle_process', {
      'targets': [
        for (final v in videos) {'mediaId': v.id},
      ],
      'optimize': 'agent',
      'translate': 'off',
      'requestId': request(),
    });
    final id = created['jobId'] as String;
    await wait(id);
    await processing.callTool('subtitle_job_control', {
      'jobId': id,
      'mediaIds': [media.id],
      'action': 'pause',
      'requestId': request(),
    });
    await expectLater(read(id), throwsStateError);
    final other = await processing.callTool('subtitle_work_read', {
      'jobId': id,
      'mediaId': 'other',
    });
    expect(other['stage'], 'optimization');
    await processing.callTool('subtitle_job_control', {
      'jobId': id,
      'mediaIds': [media.id],
      'action': 'retry',
      'requestId': request(),
    });
    await wait(id);
    expect((await read(id))['stage'], 'optimization');
  });

  test(
    'pending plan configuration changes cannot reuse original approval request',
    () async {
      prefs = prefs.copyWith(
        autoTaskDecisions: false,
        autoRemoteProcessing: false,
      );
      final plan = await processing.callTool('subtitle_plan', {
        'targets': [
          {'mediaId': media.id},
        ],
        'optimize': 'app',
        'translate': 'off',
        'requestId': request(),
      });
      final startArgs = {
        'planId': plan['planId'],
        'requestId': 'pending-original-request',
      };
      final pending = await processing.callTool('subtitle_process', startArgs);
      expect(pending['status'], 'approval_required');
      await approvals.resolve(pending['approvalId'] as String, approve: true);
      await processing.callTool('subtitle_plan', {
        'planId': plan['planId'],
        'targetLanguage': 'ja',
      });
      await expectLater(
        processing.callTool('subtitle_process', startArgs),
        throwsStateError,
      );
      expect(backend.calls, isEmpty);
    },
  );

  test(
    'Agent read rechecks authorization after asynchronous route persistence',
    () async {
      backend.useAgentRouting = true;
      final created = await start('off', 'agent');
      final id = created['jobId'] as String;
      await wait(id);
      var revoked = false;
      store.onSave = (state) {
        final jobs = state['jobs'] as Map? ?? {};
        if (jobs.values.any(
          (j) => (j['items'] as List).any(
            (r) => (r['stages']['translation']['routingPages'] as Map? ?? {})
                .isNotEmpty,
          ),
        )) {
          store.onSave = null;
          revoked = true;
          epoch++;
          prefs = prefs.copyWith(enabled: false);
        }
      };
      await expectLater(read(id), throwsStateError);
      expect(revoked, true);
    },
  );

  test(
    'explicit initial subtitle revision cannot be ignored by planning',
    () async {
      final document = (await reader.callTool('documents_list', {
        'mediaId': media.id,
      }))['documents'][0]['id'];
      await expectLater(
        processing.callTool('subtitle_plan', {
          'targets': [
            {
              'mediaId': media.id,
              'documentId': document,
              'documentRevision': 'not-the-current-revision',
            },
          ],
          'requestId': request(),
        }),
        throwsStateError,
      );
      expect(backend.calls, isEmpty);
    },
  );

  test(
    'resume reuses a completed recognition whose native queue row was removed',
    () async {
      backend.failRecognitionRead = true;
      final created = await start('agent', 'off', source: 'transcribe');
      final id = created['jobId'] as String;
      expect((await wait(id))['status'], 'failed');
      expect(backend.recognitionStarts, 1);
      backend.rows.clear();
      backend.failRecognitionRead = false;
      await processing.callTool('subtitle_job_control', {
        'jobId': id,
        'action': 'resume',
        'requestId': request(),
      });
      expect((await wait(id))['status'], 'awaiting_agent');
      expect(backend.recognitionStarts, 1);
      expect(jsonEncode((await read(id))['entries']), contains('新识别'));
    },
  );

  test(
    'routing caches are globally bounded and optional-cache save failure stays recoverable',
    () async {
      backend.useAgentRouting = true;
      await original.writeAsString(srt(List.filled(201, 'A' * 11999 + '.')));
      final ids = <String>[];
      for (var i = 0; i < 2; i++) {
        final created = await start('off', 'agent');
        final id = created['jobId'] as String;
        ids.add(id);
        await wait(id);
        for (final offset in [0, 100]) {
          await processing.callTool('subtitle_work_read', {
            'jobId': id,
            'mediaId': media.id,
            'offset': offset,
            'limit': 1,
          });
        }
      }
      var state = await store.load();
      final pages = <Map>[];
      for (final job in (state['jobs'] as Map).values) {
        for (final row in job['items']) {
          for (final page
              in (row['stages']['translation']['routingPages'] as Map? ?? {})
                  .values) {
            pages.add(page as Map);
          }
        }
      }
      expect(pages.length, lessThanOrEqualTo(8));
      expect(
        pages.fold<int>(0, (n, p) => n + utf8.encode(jsonEncode(p)).length),
        lessThanOrEqualTo(4 * 1024 * 1024),
      );
      store.failNext = true;
      await processing.callTool('subtitle_work_read', {
        'jobId': ids.last,
        'mediaId': media.id,
        'offset': 200,
        'limit': 1,
      });
      await processing.callTool('subtitle_job_control', {
        'jobId': ids.last,
        'mediaIds': [media.id],
        'action': 'pause',
        'requestId': request(),
      });
      state = await store.load();
      expect(state['jobs'][ids.last]['items'][0]['status'], 'paused');
    },
  );

  test(
    'combined app result publication retry does not call the translation provider twice',
    () async {
      var publications = 0;
      backend.afterPublish = () {
        publications++;
        if (publications == 2) {
          throw StateError(
            'simulated translation publication acknowledgement failure',
          );
        }
      };
      final started = await start('app', 'app');
      final id = started['jobId'] as String;
      expect((await wait(id))['status'], 'failed');
      expect(backend.calls, hasLength(1));
      backend.afterPublish = null;
      await processing.callTool('subtitle_job_control', {
        'jobId': id,
        'action': 'resume',
        'requestId': request(),
      });
      final result = await wait(id);
      expect(result['status'], 'completed', reason: '$result');
      expect(backend.calls, hasLength(1));
      expect(media.managedSubtitleAssets, hasLength(2));
    },
  );

  test(
    'missing completed software cache never silently recomputes paid translation',
    () async {
      var publications = 0;
      backend.afterPublish = () {
        publications++;
        if (publications == 2) throw StateError('publication interrupted');
      };
      final started = await start('app', 'app');
      final id = started['jobId'] as String;
      expect((await wait(id))['status'], 'failed');
      expect(backend.calls, hasLength(1));
      backend.afterPublish = null;
      backend.softwareResults.clear();
      await processing.callTool('subtitle_job_control', {
        'jobId': id,
        'action': 'resume',
        'requestId': request(),
      });
      expect((await wait(id))['status'], 'failed');
      expect(backend.calls, hasLength(1));
    },
  );

  test(
    'legacy combined app jobs recover the original completed calculation after restart',
    () async {
      var publications = 0;
      backend.afterPublish = () {
        publications++;
        if (publications == 2) throw StateError('legacy publication failure');
      };
      final created = await start('app', 'app');
      final id = created['jobId'] as String;
      expect((await wait(id))['status'], 'failed');
      await processing.shutdown();
      final old = await store.load();
      final stages = old['jobs'][id]['items'][0]['stages'];
      stages['translation'].remove('combinedWorkId');
      stages['translation'].remove('applicationCompleted');
      stages['optimization'].remove('applicationCompleted');
      await store.save(old);
      backend.afterPublish = null;
      processing = create();
      await processing.initialize();
      await processing.callTool('subtitle_job_control', {
        'jobId': id,
        'action': 'resume',
        'requestId': request(),
      });
      expect((await wait(id))['status'], 'completed');
      expect(backend.calls, hasLength(1));
    },
  );

  test('legacy Agent drafts retain their entries write protocol', () async {
    final created = await start('off', 'agent');
    final id = created['jobId'] as String;
    await wait(id);
    final work = await read(id);
    expect(work['agentTranslationContract'], 1);
    expect(work['writeFormat'], contains('entries'));
    expect(work['rules'], isNot(contains('translationParts')));
    await complete(id);
    expect((await wait(id))['status'], 'completed');
  });

  test(
    'translation-only planning never silently enables optimization',
    () async {
      final plan = await processing.callTool('subtitle_plan', {
        'targets': [
          {'mediaId': media.id},
        ],
        'translate': 'agent',
        'requestId': request(),
      });
      expect(plan['status'], 'ready');
      expect(backend.capturedRequests.last['optimize'], 'off');
      expect(backend.capturedRequests.last['translate'], 'agent');
    },
  );

  test(
    'a revised explicit subtitle choice updates the pinned document revision',
    () async {
      final listed = await reader.callTool('documents_list', {
        'mediaId': media.id,
      });
      final docId = listed['documents'][0]['id'] as String;
      final before = await reader.authorizedSubtitle(media.id, docId);
      final plan = await processing.callTool('subtitle_plan', {
        'targets': [
          {
            'mediaId': media.id,
            'documentId': docId,
            'documentRevision': before.revision,
          },
        ],
        'requestId': request(),
      });
      await original.writeAsString(srt(['用户选择改后的字幕']));
      final after = await reader.authorizedSubtitle(media.id, docId);
      final updated = await processing.callTool('subtitle_plan', {
        'planId': plan['planId'],
        'targets': [
          {
            'mediaId': media.id,
            'documentId': docId,
            'documentRevision': after.revision,
          },
        ],
      });
      expect(updated['status'], 'ready');
      expect(updated['items'][0]['documentRevision'], after.revision);
    },
  );

  test(
    'v1.4 raw JSON request receipts replay exactly and migrate without allowing changed payloads',
    () async {
      final args = <String, dynamic>{
        'requestId': 'old-raw-request-0001',
        'translate': 'off',
        'targets': [
          {'mediaId': media.id},
        ],
        'optimize': 'agent',
        'source': 'existing',
      };
      final first = await processing.callTool('subtitle_process', args);
      await wait(first['jobId'] as String);
      await processing.shutdown();
      final state = await store.load();
      final key = '${approvals.grant}:${args['requestId']}';
      final raw = sha256
          .convert(utf8.encode(jsonEncode(['subtitle_process', args])))
          .toString();
      expect(
        state['requests'][key]['signature'],
        isNot(raw),
        reason:
            'Fixture must exercise the actual old key-order hash, not the canonical hash',
      );
      state['requests'][key]['signature'] = raw;
      await store.save(state);
      processing = create();
      await processing.initialize();
      final replay = await processing.callTool('subtitle_process', args);
      expect(replay['jobId'], first['jobId']);
      expect((await store.load())['requests'][key]['signature'], isNot(raw));
      await expectLater(
        processing.callTool('subtitle_process', {...args, 'optimize': 'app'}),
        throwsStateError,
      );
      expect(
        (await processing.callTool('subtitle_jobs', {}))['jobs'],
        hasLength(1),
      );
      expect(backend.calls, isEmpty);
    },
  );

  test(
    'pausing one native recognition row does not stop later media in the workflow',
    () async {
      videos.add(
        VideoItem(
          id: 'second',
          title: '第二课',
          path: '${root.path}/second.mp4',
          subtitlePath: original.path,
          durationMs: 6000,
          lastUpdated: 0,
        ),
      );
      backend.pauseOnRecognitionFor.add(media.id);
      final started = await processing.callTool('subtitle_process', {
        'targets': [
          for (final video in videos) {'mediaId': video.id},
        ],
        'source': 'transcribe',
        'optimize': 'agent',
        'translate': 'off',
        'requestId': request(),
      });
      final id = started['jobId'] as String;
      final status = await wait(id);
      expect(
        status['status'],
        'awaiting_agent',
        reason: 'The second media must still reach its Agent stage',
      );
      expect(backend.recognitionStarts, 2);
      final first = (status['items'] as List).firstWhere(
        (r) => r['mediaId'] == media.id,
      );
      expect(first['status'], 'paused');
      expect(first['failure']['code'], 'native_task_paused');
      final second = await processing.callTool('subtitle_work_read', {
        'jobId': id,
        'mediaId': 'second',
      });
      expect(second['stage'], 'optimization');
    },
  );

  test(
    'an Agent commit wins over a background stage input suspended before its completion',
    () async {
      await processing.shutdown();
      final gate = _GatedLibrary(reader);
      reader = gate;
      processing = create();
      await processing.initialize();
      final created = await start('agent', 'off');
      final id = created['jobId'] as String;
      await wait(id);
      gate.arm();
      try {
        await processing.callTool('subtitle_job_control', {
          'jobId': id,
          'action': 'resume',
          'requestId': request(),
        });
        await gate.entered.future.timeout(const Duration(seconds: 5));
        final write = await complete(id);
        expect(write['committed'], true);
        expect(backend.publishAttempts, 1);
        gate.release.complete();
        final status = await wait(id);
        expect(
          status['status'],
          'completed',
          reason: 'A late source read must not reset a committed Agent stage',
        );
        expect(
          status['items'][0]['stages']['optimization']['status'],
          'completed',
        );
        expect(backend.publishAttempts, 1);
        expect(media.managedSubtitleAssets, hasLength(1));
      } finally {
        if (!gate.release.isCompleted) gate.release.complete();
      }
    },
  );

  test(
    'a publishing Agent stage stays busy while a stale runner input resumes, then advances',
    () async {
      await processing.shutdown();
      final gate = _GatedLibrary(reader);
      reader = gate;
      processing = create();
      await processing.initialize();
      final created = await start('agent', 'agent');
      final id = created['jobId'] as String;
      await wait(id);
      final publicationEntered = Completer<void>(),
          publicationRelease = Completer<void>(),
          runnerSaved = Completer<void>();
      var observeRunner = false;
      Future<Map<String, dynamic>>? writing;
      gate.arm();
      try {
        await processing.callTool('subtitle_job_control', {
          'jobId': id,
          'action': 'resume',
          'requestId': request(),
        });
        await gate.entered.future.timeout(const Duration(seconds: 5));
        backend.beforePublishReturn = () async {
          if (!publicationEntered.isCompleted) publicationEntered.complete();
          await publicationRelease.future;
        };
        writing = complete(id);
        await publicationEntered.future.timeout(const Duration(seconds: 5));
        store.onSave = (state) {
          final job = (state['jobs'] as Map)[id];
          if (observeRunner &&
              job['activeMediaId'] == null &&
              job['items'][0]['stages']['optimization']['status'] ==
                  'publishing' &&
              !runnerSaved.isCompleted) {
            runnerSaved.complete();
          }
        };
        observeRunner = true;
        gate.release.complete();
        await runnerSaved.future.timeout(const Duration(seconds: 5));
        final busy = processing.jobSummaries.single;
        expect(busy['status'], 'running');
        expect(
          busy['items'][0]['stages']['optimization']['status'],
          'publishing',
        );
        expect(busy['items'][0]['status'], isNot('failed'));
        publicationRelease.complete();
        expect((await writing)['committed'], true);
        final ready = await wait(id);
        expect(ready['status'], 'awaiting_agent');
        final next = await read(id);
        expect(next['stage'], 'translation');
        expect(backend.publishAttempts, 1);
        await complete(id);
        expect((await wait(id))['status'], 'completed');
        expect(backend.publishAttempts, 2);
      } finally {
        store.onSave = null;
        if (!gate.release.isCompleted) gate.release.complete();
        if (!publicationRelease.isCompleted) publicationRelease.complete();
        if (writing != null) {
          await writing.catchError((Object _) => <String, dynamic>{});
        }
      }
    },
  );

  test(
    'retry recovers durable Agent publication even while the background runner still awaits its input',
    () async {
      await processing.shutdown();
      final gate = _GatedLibrary(reader);
      reader = gate;
      processing = create();
      await processing.initialize();
      final created = await start('agent', 'off');
      final id = created['jobId'] as String;
      await wait(id);
      gate.arm();
      try {
        await processing.callTool('subtitle_job_control', {
          'jobId': id,
          'action': 'resume',
          'requestId': request(),
        });
        await gate.entered.future.timeout(const Duration(seconds: 5));
        backend.afterPublish = () {
          throw StateError('publication acknowledgement failed');
        };
        await expectLater(complete(id), throwsStateError);
        expect(media.managedSubtitleAssets, hasLength(1));
        backend.afterPublish = null;
        await processing.callTool('subtitle_job_control', {
          'jobId': id,
          'action': 'retry',
          'requestId': request(),
        });
        gate.release.complete();
        expect((await wait(id))['status'], 'completed');
        expect(media.managedSubtitleAssets, hasLength(1));
        expect(backend.calls, isEmpty);
      } finally {
        if (!gate.release.isCompleted) gate.release.complete();
      }
    },
  );

  for (final translationExecutor in ['agent', 'app']) {
    test(
      'held first ASR does not block existing captions with Agent optimization and $translationExecutor translation',
      () async {
        final slow = VideoItem(
          id: 'slow-asr',
          title: '长转录',
          path: '${root.path}/slow/slow.mp4',
          durationMs: 600000,
          lastUpdated: 0,
        );
        videos.insert(0, slow);
        backend.holdRecognitionFor.add(slow.id);
        final admitted = Completer<void>(),
            existingReady = Completer<void>(),
            existingCompleted = Completer<void>();
        backend.afterRecognitionAdmission = () {
          if (!admitted.isCompleted) admitted.complete();
        };
        store.onSave = (state) {
          for (final job in (state['jobs'] as Map? ?? {}).values) {
            for (final row in job['items']) {
              if (row['mediaId'] != media.id) continue;
              if (row['stages']['optimization']['status'] == 'awaiting_agent' &&
                  !existingReady.isCompleted) {
                existingReady.complete();
              }
              if (row['status'] == 'completed' &&
                  !existingCompleted.isCompleted) {
                existingCompleted.complete();
              }
            }
          }
        };
        try {
          final started = await processing.callTool('subtitle_process', {
            'targets': [
              {'mediaId': slow.id, 'source': 'transcribe'},
              {'mediaId': media.id, 'source': 'existing'},
            ],
            'source': 'auto',
            'optimize': 'agent',
            'translate': translationExecutor,
            'requestId': request(),
          });
          final id = started['jobId'] as String;
          await admitted.future.timeout(const Duration(seconds: 5));
          await existingReady.future.timeout(const Duration(seconds: 5));
          final ready = await processing.callTool('subtitle_jobs', {
            'jobId': id,
          });
          expect(
            ready['items'][0]['mediaId'],
            slow.id,
            reason: 'Displayed item order stays unchanged',
          );
          expect(ready['nextTool'], 'subtitle_work_read');
          expect(
            (ready['readyAgentSteps'] as List).any(
              (s) => s['mediaId'] == media.id,
            ),
            true,
          );
          expect((await complete(id))['committed'], true);
          if (translationExecutor == 'agent') {
            expect(
              (await read(id))['stage'],
              'translation',
              reason:
                  'No ASR completion or worker availability is needed to prime Agent translation',
            );
            expect((await complete(id))['committed'], true);
          }
          await existingCompleted.future.timeout(const Duration(seconds: 5));
          final status = await processing.callTool('subtitle_jobs', {
            'jobId': id,
          });
          final existing = (status['items'] as List).firstWhere(
            (r) => r['mediaId'] == media.id,
          );
          expect(existing['status'], 'completed');
          expect(existing['stages']['translation']['status'], 'completed');
          expect((status['items'] as List).first['sourceRevision'], isNull);
          expect(
            backend.recognitionStarts,
            1,
            reason: 'Pending ASR is admitted only once',
          );
          expect(backend.rows.single.status, 'running');
          await processing.callTool('subtitle_job_control', {
            'jobId': id,
            'action': 'cancel',
            'requestId': request(),
          });
        } finally {
          store.onSave = null;
        }
      },
    );
  }

  test(
    'all missing sources join the real ASR queue before any one source completes',
    () async {
      for (var i = 0; i < 2; i++) {
        videos.add(
          VideoItem(
            id: 'queued-$i',
            title: '待识别$i',
            path: '${root.path}/queued-$i.mp4',
            subtitlePath: original.path,
            durationMs: 6000,
            lastUpdated: 0,
          ),
        );
      }
      backend.holdRecognitionFor.addAll(videos.map((v) => v.id));
      final allAdmitted = Completer<void>();
      backend.afterRecognitionAdmission = () {
        if (backend.rows.length == 3 && !allAdmitted.isCompleted) {
          allAdmitted.complete();
        }
      };
      final started = await processing.callTool('subtitle_process', {
        'targets': [
          for (final v in videos) {'mediaId': v.id},
        ],
        'source': 'transcribe',
        'optimize': 'agent',
        'translate': 'off',
        'requestId': request(),
      });
      await allAdmitted.future.timeout(const Duration(seconds: 5));
      expect(backend.recognitionStarts, 3);
      expect(
        backend.rows.map((r) => r.mediaId).toList(),
        videos.map((v) => v.id).toList(),
      );
      await processing.callTool('subtitle_job_control', {
        'jobId': started['jobId'],
        'action': 'pause',
        'requestId': request(),
      });
      expect(
        backend.pausedRecognitionTasks,
        containsAll(backend.rows.map((r) => r.taskId)),
      );
      expect(backend.rows.every((r) => r.status == 'paused'), true);
    },
  );

  test(
    'suspending MCP stops an owned ASR after its media is recycled and worker yields',
    () async {
      backend.holdRecognitionFor.add(media.id);
      final yielded = Completer<void>();
      store.onSave = (state) {
        for (final job in (state['jobs'] as Map? ?? {}).values) {
          if (job['status'] == 'running' &&
              job['activeMediaId'] == null &&
              job['items'][0]['status'] == 'recognizing' &&
              !yielded.isCompleted) {
            yielded.complete();
          }
        }
      };
      await start('agent', 'off', source: 'transcribe');
      await yielded.future.timeout(const Duration(seconds: 5));
      store.onSave = null;
      media.isRecycled = true;
      await processing.suspend();
      expect(backend.rows.single.status, 'paused');
      expect(
        backend.pausedRecognitionTasks,
        contains(backend.rows.single.taskId),
      );
    },
  );

  test(
    'pausing one media during its admission save prevents enqueue and allows resume',
    () async {
      backend.holdRecognitionFor.add(media.id);
      final admissionSave = Completer<void>();
      final releaseAdmission = Completer<void>();
      store.beforeSave = (state) async {
        final jobs = (state['jobs'] as Map? ?? {}).values;
        if (jobs.any((job) => job['items'][0]['recognitionStarted'] == true) &&
            backend.recognitionStarts == 0 &&
            !admissionSave.isCompleted) {
          admissionSave.complete();
          await releaseAdmission.future;
        }
      };
      try {
        final created = await start('agent', 'off', source: 'transcribe');
        final id = created['jobId'] as String;
        await admissionSave.future.timeout(const Duration(seconds: 5));
        final paused = processing.callTool('subtitle_job_control', {
          'jobId': id,
          'mediaIds': [media.id],
          'action': 'pause',
          'requestId': request(),
        });
        // The stop intent is synchronous before its durable save. Do not wait
        // for that save while blocking the earlier admission save.
        final elapsed = Stopwatch()..start();
        while (processing.jobSummaries.single['items'][0]['status'] !=
            'paused') {
          if (elapsed.elapsed > const Duration(seconds: 5)) {
            fail('single-media pause did not reach the admission barrier');
          }
          await Future<void>.value();
        }
        releaseAdmission.complete();
        await paused;
        expect(backend.recognitionStarts, 0);
        expect(backend.rows, isEmpty);
        final stopped = await processing.callTool('subtitle_jobs', {
          'jobId': id,
        });
        expect(stopped['items'][0]['status'], 'paused');
        expect(stopped['items'][0]['failure'], isNull);

        final admitted = Completer<void>();
        backend.afterRecognitionAdmission = () {
          if (!admitted.isCompleted) {
            admitted.complete();
          }
        };
        await processing.callTool('subtitle_job_control', {
          'jobId': id,
          'mediaIds': [media.id],
          'action': 'resume',
          'requestId': request(),
        });
        await admitted.future.timeout(const Duration(seconds: 5));
        expect(backend.recognitionStarts, 1);
      } finally {
        store.beforeSave = null;
        if (!releaseAdmission.isCompleted) {
          releaseAdmission.complete();
        }
      }
    },
  );

  test(
    'HTTP tools expose only text jobs and reject arbitrary media paths or secrets',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final server = ExternalAiServer(
          dataSource: processing,
          token: prefs.token,
        );
        final endpoint = await server.start();
        final client = HttpClient();
        try {
          final request = await client.postUrl(endpoint);
          request.headers.set(
            HttpHeaders.authorizationHeader,
            'Bearer ${prefs.token}',
          );
          request.headers.contentType = ContentType.json;
          request.write(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': 1,
              'method': 'tools/call',
              'params': {
                'name': 'subtitle_process',
                'arguments': {
                  'targets': [
                    {'mediaId': media.id},
                  ],
                  'optimize': 'agent',
                  'translate': 'off',
                  'requestId': 'http-start-request',
                },
              },
            }),
          );
          final response = await request.close();
          final text = await utf8.decoder.bind(response).join();
          expect(response.statusCode, 200);
          expect(text, contains('jobId'));
          expect(text, isNot(contains('PRIVATE-MEDIA-BYTES')));
          expect(text, isNot(contains(root.path)));
        } finally {
          client.close(force: true);
          await server.stop();
        }
      }, _RealHttp());
    },
  );
}
