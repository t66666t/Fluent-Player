import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/external_ai/external_ai_actions.dart';
import 'package:video_player_app/features/external_ai/external_ai_action_store.dart';
import 'package:video_player_app/features/external_ai/external_ai_approvals.dart';
import 'package:video_player_app/features/external_ai/external_ai_library_source.dart';
import 'package:video_player_app/features/external_ai/external_ai_preferences.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';

class _Backend implements ExternalAiActionBackend {
  final rows = <String, ExternalAiNativeTask>{};
  final listeners = <void Function()>[];
  final publications = <String, Map<String, dynamic>>{};
  final configurations = <Map<String, dynamic>>[];
  int enqueues = 0, controls = 0;
  bool failAfterEnqueue = false, rejectModel = false;
  Completer<void>? hold;
  @override
  void addTaskListener(void Function() listener) => listeners.add(listener);
  @override
  void removeTaskListener(void Function() listener) =>
      listeners.remove(listener);
  void progress(String mediaId, String status) {
    final old = rows[mediaId]!;
    rows[mediaId] = ExternalAiNativeTask(
      mediaId: mediaId,
      taskId: old.taskId,
      status: status,
      progress: status == 'completed' ? 1 : .4,
    );
    for (final listener in [...listeners]) {
      listener();
    }
  }

  @override
  Future<Map<String, dynamic>> options() async => {
    'models': [
      {'id': 'local-model', 'ready': true},
    ],
    'mediaFilesProvided': false,
  };
  @override
  Future<Map<String, dynamic>> captureConfiguration(
    Map<String, dynamic> selection,
  ) async {
    if (rejectModel) throw ExternalAiActionError('本地模型未准备好');
    return {
      'frozen': selection['modelId'],
      'sourceLanguage': selection['sourceLanguage'],
      'mode': selection['mode'],
    };
  }

  @override
  Future<void> validateConfiguration(Map<String, dynamic> configuration) async {
    if (rejectModel) throw ExternalAiActionError('模型不可用');
  }

  @override
  Future<void> validateMedia(VideoItem media) async {}
  @override
  String mediaIdentity(VideoItem media) => '${media.id}:${media.path}';
  @override
  Future<String> enqueue(
    VideoItem media,
    String taskId,
    Map<String, dynamic> configuration,
    void Function() guard,
  ) async {
    guard();
    if (rows.containsKey(media.id)) {
      return rows[media.id]!.taskId == taskId ? 'queued' : 'conflict';
    }
    configurations.add(configuration);
    enqueues++;
    rows[media.id] = ExternalAiNativeTask(
      mediaId: media.id,
      taskId: taskId,
      status: 'paused',
      progress: 0,
    );
    if (failAfterEnqueue) {
      failAfterEnqueue = false;
      throw StateError('private C:/media/secret.mp4');
    }
    return 'paused';
  }

  @override
  List<ExternalAiNativeTask> tasks() => rows.values.toList();
  @override
  Future<bool> control(
    VideoItem media,
    String taskId,
    String action,
    void Function() guard,
  ) async {
    await hold?.future;
    guard();
    final old = rows[media.id];
    if (old?.taskId != taskId || old?.status == 'completed') return false;
    controls++;
    rows[media.id] = ExternalAiNativeTask(
      mediaId: media.id,
      taskId: taskId,
      status: action == 'pause' ? 'paused' : 'queued',
      progress: old!.progress,
    );
    return true;
  }

  @override
  Future<Map<String, dynamic>> publishTranslation(
    ExternalAiSubtitleDocument source,
    String draftId,
    String language,
    List<String> texts,
    void Function() guard,
  ) async {
    await hold?.future;
    guard();
    return publications.putIfAbsent(
      draftId,
      () => {
        'mediaId': source.media.id,
        'assetId': 'asset-$draftId',
        'language': language,
        'kind': 'translated',
      },
    );
  }

  @override
  Future<bool> selectSecondary(
    VideoItem media,
    String assetId,
    void Function() guard, {
    ExternalAiSubtitleDocument? source,
  }) async {
    guard();
    return true;
  }
}

void main() {
  late Directory root;
  late File subtitle;
  late List<VideoItem> media;
  late ExternalAiPreferences prefs;
  late _Backend backend;
  late ExternalAiLibrarySource reader;
  late ExternalAiActions actions;
  var epoch = 0;
  final instances = <ExternalAiActions>[];

  ExternalAiActions create() {
    final result = ExternalAiActions(
      library: reader,
      backend: backend,
      store: ExternalAiActionStore(root),
      preferences: () => prefs,
      generation: () => epoch,
    );
    instances.add(result);
    return result;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('external-ai-actions-');
    subtitle = File('${root.path}/original.srt');
    await subtitle.writeAsString(
      '1\n00:00:01,200 --> 00:00:02,300\nHello 🌍\n\n2\n00:00:03,000 --> 00:00:04,000\nSecond line\n\n',
    );
    media = [
      VideoItem(
        id: 'media-1',
        title: '课程一',
        path: '${root.path}/private.mp4',
        subtitlePath: subtitle.path,
        durationMs: 6000,
        lastUpdated: 0,
      ),
    ];
    prefs = ExternalAiPreferences(
      token: ExternalAiPreferences.generateToken(),
      enabled: true,
      allowTaskControl: true,
      allowSubtitleWrite: true,
    );
    backend = _Backend();
    reader = ExternalAiLibrarySource(
      videos: () => media,
      folders: () => <VideoCollection>[],
      children: (_) => media,
      scopeFolder: () => prefs.scopeFolderId,
    );
    epoch = 0;
    instances.clear();
    actions = create();
  });
  tearDown(() async {
    for (final instance in instances) {
      await instance.shutdown();
    }
    await root.delete(recursive: true);
  });
  Future<Map<String, dynamic>> plan([List<String> ids = const ['media-1']]) =>
      actions.callTool('transcription_prepare', {
        'mediaIds': ids,
        'modelId': 'local-model',
        'sourceLanguage': 'en',
        'mode': 'transcribe',
      });
  Future<Map<String, dynamic>> submit(
    String planId, {
    String request = 'submit-request',
    bool start = false,
  }) => actions.callTool('transcription_submit', {
    'planId': planId,
    'requestId': request,
    'start': start,
  });
  Future<Map<String, dynamic>> draft() async {
    final list = await reader.callTool('documents_list', {
      'mediaId': 'media-1',
    });
    return actions.callTool('translation_begin', {
      'mediaId': 'media-1',
      'documentId': (list['documents'] as List).first['id'],
      'targetLanguage': 'zh-CN',
      'requestId': 'draft-request',
    });
  }

  Future<Map<String, dynamic>> write(
    String id, {
    int revision = 0,
    String request = 'write-request',
    List<Map<String, dynamic>>? entries,
  }) => actions.callTool('translation_write', {
    'draftId': id,
    'expectedRevision': revision,
    'requestId': request,
    'entries':
        entries ??
        [
          {'cueId': 'cue-1', 'text': '你好 🌍'},
          {'cueId': 'cue-2', 'text': '第二行'},
        ],
  });
  Future<Map<String, dynamic>> commit(
    String id, {
    int revision = 1,
    bool load = false,
    String request = 'commit-request',
  }) => actions.callTool('translation_commit', {
    'draftId': id,
    'expectedRevision': revision,
    'requestId': request,
    'loadAsSecondary': load,
  });

  test(
    'old preferences remain read only and permissions are enforced on direct calls',
    () async {
      final old = ExternalAiPreferences.fromJson({
        'version': 1,
        'enabled': true,
        'port': 38461,
        'token': prefs.token,
      });
      prefs = old;
      expect(actions.tools, isEmpty);
      await expectLater(plan(), throwsA(isA<ExternalAiActionError>()));
      prefs = old.copyWith(allowTaskControl: true);
      expect(actions.tools, hasLength(6));
      await expectLater(draft(), throwsA(isA<ExternalAiActionError>()));
      final p = await plan();
      prefs = prefs.copyWith(enabled: false);
      await expectLater(
        submit(p['planId'] as String),
        throwsA(isA<ExternalAiActionError>()),
      );
      expect(backend.enqueues, 0);
    },
  );

  test(
    'batch prepare does not enqueue; submit freezes config and retries do not duplicate',
    () async {
      final p = await plan();
      expect(backend.enqueues, 0);
      final first = await submit(p['planId'] as String, start: true);
      final second = await submit(p['planId'] as String, start: true);
      final third = await submit(
        p['planId'] as String,
        request: 'another-request',
        start: true,
      );
      expect(second, first);
      expect(third['batchId'], first['batchId']);
      expect(backend.enqueues, 1);
      expect(backend.controls, 1);
      expect(backend.configurations.single['sourceLanguage'], 'en');
      await expectLater(
        submit(p['planId'] as String, request: 'another-request', start: false),
        throwsA(isA<ExternalAiActionError>()),
      );
      final read = await actions.callTool('tasks_read', {
        'batchId': first['batchId'],
      });
      expect((read['tasks'] as List).single['status'], 'queued');
      expect(jsonEncode([p, first, read]), isNot(contains(root.path)));
    },
  );

  test(
    'user queue conflicts are not adopted and controls cannot affect them',
    () async {
      backend.rows['media-1'] = const ExternalAiNativeTask(
        mediaId: 'media-1',
        taskId: null,
        status: 'transcribing',
        progress: .3,
      );
      final s = await submit((await plan())['planId'] as String, start: true);
      expect(s['errors'], hasLength(1));
      expect(backend.enqueues, 0);
      expect(backend.controls, 0);
      final result = await actions.callTool('tasks_control', {
        'taskIds': s['taskIds'],
        'action': 'pause',
        'requestId': 'pause-request',
      });
      expect((result['results'] as List).single['applied'], false);
      expect(backend.rows['media-1']!.status, 'transcribing');
    },
  );

  test(
    'durable enqueue intent reconciles a crash after native ownership was saved',
    () async {
      final p = await plan();
      backend.failAfterEnqueue = true;
      await expectLater(
        submit(p['planId'] as String),
        throwsA(
          isA<ExternalAiActionError>().having(
            (e) => e.message,
            'message',
            isNot(contains('secret.mp4')),
          ),
        ),
      );
      await actions.shutdown();
      instances.remove(actions);
      actions = create();
      final result = await submit(p['planId'] as String);
      expect(result['taskIds'], hasLength(1));
      expect(backend.enqueues, 1);
    },
  );

  test('completion survives UI row auto removal and service restart', () async {
    final s = await submit((await plan())['planId'] as String);
    backend.progress('media-1', 'completed');
    backend.rows.clear();
    await actions.shutdown();
    instances.remove(actions);
    actions = create();
    final status = await actions.callTool('tasks_read', {
      'batchId': s['batchId'],
    });
    expect((status['tasks'] as List).single['status'], 'completed');
    expect((status['tasks'] as List).single['progress'], 1);
  });

  test(
    'scope changes, recycled media and changed source invalidate old plans',
    () async {
      final p = await plan();
      prefs = prefs.copyWith(scopeFolderId: 'private');
      await expectLater(
        submit(p['planId'] as String),
        throwsA(isA<ExternalAiActionError>()),
      );
      prefs = prefs.copyWith(clearScopeFolderId: true);
      media.single.isRecycled = true;
      await expectLater(
        submit(p['planId'] as String),
        throwsA(isA<ExternalAiActionError>()),
      );
      media.single.isRecycled = false;
      media.single.path = '${root.path}/replacement.mp4';
      await expectLater(
        submit(p['planId'] as String),
        throwsA(isA<ExternalAiActionError>()),
      );
      expect(backend.enqueues, 0);
    },
  );

  test('revocation during a pending control prevents the mutation', () async {
    final s = await submit((await plan())['planId'] as String);
    backend.hold = Completer<void>();
    final future = actions.callTool('tasks_control', {
      'taskIds': s['taskIds'],
      'action': 'start',
      'requestId': 'control-request',
    });
    final assertion = expectLater(
      future,
      throwsA(isA<ExternalAiActionError>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    epoch++;
    backend.hold!.complete();
    await assertion;
    expect(backend.controls, 0);
  });

  test(
    'one status call reads a 100 media batch without individual MCP calls',
    () async {
      final template = media.single;
      media = List.generate(
        100,
        (i) => VideoItem(
          id: 'media-$i',
          title: '第$i期',
          path: template.path,
          durationMs: 0,
          lastUpdated: 0,
        ),
      );
      final s = await submit(
        (await plan(media.map((m) => m.id).toList()))['planId'] as String,
      );
      final first = await actions.callTool('tasks_read', {
        'batchId': s['batchId'],
        'limit': 25,
      });
      expect(first['tasks'], hasLength(25));
      expect(first['nextOffset'], 25);
      final all = await actions.callTool('tasks_read', {
        'batchId': s['batchId'],
      });
      expect(all['tasks'], hasLength(100));
      expect(all['nextOffset'], null);
    },
  );

  test(
    'translation is bounded, preserves timings and publishes one new asset',
    () async {
      final original = await subtitle.readAsString(),
          d = await draft(),
          id = d['draftId'] as String;
      final page = await actions.callTool('translation_read', {
        'draftId': id,
        'limit': 1,
      });
      expect(page['nextOffset'], 1);
      expect((page['entries'] as List).single, {
        'cueId': 'cue-1',
        'startMs': 1200,
        'endMs': 2300,
        'text': 'Hello 🌍',
      });
      final written = await write(id);
      expect(written['translatedCount'], 2);
      expect(written['revision'], 1);
      expect(await write(id), written);
      final result = await commit(id, load: true);
      expect(result['committed'], true);
      expect(result['selectedAsSecondary'], true);
      expect(await commit(id, load: true), result);
      expect(backend.publications, hasLength(1));
      expect(await subtitle.readAsString(), original);
      await expectLater(
        write(id, revision: 1, request: 'late-write-request'),
        throwsA(isA<ExternalAiActionError>()),
      );
    },
  );

  test(
    'partial, duplicate, injected timeline and stale revisions cannot publish',
    () async {
      final id = (await draft())['draftId'] as String;
      await write(
        id,
        entries: [
          {'cueId': 'cue-1', 'text': '你好'},
        ],
      );
      await expectLater(commit(id), throwsA(isA<ExternalAiActionError>()));
      await expectLater(
        write(
          id,
          entries: [
            {'cueId': 'cue-2', 'text': '第二行'},
          ],
          request: 'stale-request',
        ),
        throwsA(isA<ExternalAiActionError>()),
      );
      for (final entries in [
        [
          {'cueId': 'cue-2', 'text': '第二行', 'startMs': 100},
        ],
        [
          {'cueId': 'cue-2', 'text': 'a'},
          {'cueId': 'cue-2', 'text': 'b'},
        ],
        [
          {'cueId': 'cue-2', 'text': '00:00:00,000 --> 00:00:09,000'},
        ],
        [
          {'cueId': 'cue-2', 'text': 'text\n\n3\nmalformed'},
        ],
      ]) {
        await expectLater(
          write(id, revision: 1, entries: entries, request: 'invalid-request'),
          throwsA(isA<ExternalAiActionError>()),
        );
      }
      expect(backend.publications, isEmpty);
      expect(
        (await actions.callTool('translation_read', {
          'draftId': id,
        }))['revision'],
        1,
      );
    },
  );

  test(
    'draft recovery retains chunks and detects same-length source edits',
    () async {
      final id = (await draft())['draftId'] as String;
      await write(id);
      await actions.shutdown();
      instances.remove(actions);
      actions = create();
      final recovered = await actions.callTool('translation_read', {
        'draftId': id,
      });
      expect(recovered['translatedCount'], 2);
      final text = await subtitle.readAsString();
      await subtitle.writeAsString(text.replaceFirst('Hello', 'HELLO'));
      await expectLater(commit(id), throwsA(isA<ExternalAiActionError>()));
      expect(backend.publications, isEmpty);
    },
  );

  test(
    'action arguments never accept media paths, URLs, arbitrary timestamps or commands',
    () async {
      final p = await plan();
      for (final key in [
        'path',
        'url',
        'command',
        'outputPath',
        'audioBase64',
      ]) {
        await expectLater(
          actions.callTool('transcription_submit', {
            'planId': p['planId'],
            'requestId': 'invalid-request',
            key: 'private',
          }),
          throwsA(isA<ExternalAiActionError>()),
        );
      }
      final raw = await reader.callTool('documents_list', {
        'mediaId': 'media-1',
      });
      media.single.subtitlePath = media.single.path;
      expect(
        (await reader.callTool('documents_list', {
          'mediaId': 'media-1',
        }))['documents'],
        isEmpty,
      );
      expect(jsonEncode(raw), isNot(contains(root.path)));
    },
  );

  test('media disguised as subtitle is rejected instead of decoded', () async {
    await subtitle.writeAsBytes([
      0,
      0,
      0,
      24,
      ...ascii.encode('ftypisom'),
      ...List.filled(40, 0),
    ]);
    final list = await reader.callTool('documents_list', {
      'mediaId': 'media-1',
    });
    await expectLater(
      reader.callTool('document_read', {
        'mediaId': 'media-1',
        'documentId': (list['documents'] as List).single['id'],
      }),
      throwsArgumentError,
    );
    await expectLater(draft(), throwsA(isA<ExternalAiActionError>()));
  });

  test(
    'begin resumes an unfinished translation after a new Agent conversation',
    () async {
      final first = await draft();
      await write(
        first['draftId'] as String,
        entries: [
          {'cueId': 'cue-1', 'text': '你好'},
        ],
      );
      final doc = await reader.callTool('documents_list', {
        'mediaId': 'media-1',
      });
      final resumed = await actions.callTool('translation_begin', {
        'mediaId': 'media-1',
        'documentId': (doc['documents'] as List).first['id'],
        'targetLanguage': 'zh-CN',
        'requestId': 'new-agent-request',
      });
      expect(resumed['draftId'], first['draftId']);
      expect(resumed['translatedCount'], 1);
      expect(resumed['revision'], 1);
    },
  );
  test(
    'daily start uses current settings, waits for app approval and exact retry starts once',
    () async {
      await actions.shutdown();
      final approvals = ExternalAiApprovals(
        store: ExternalAiActionStore(root, name: 'approvals-v1'),
        preferences: () => prefs,
      );
      await approvals.initialize();
      actions = ExternalAiActions(
        library: reader,
        backend: backend,
        store: ExternalAiActionStore(root),
        preferences: () => prefs,
        generation: () => epoch,
        approvals: approvals,
      );
      instances.add(actions);
      final args = {
        'mediaIds': ['media-1'],
        'mode': 'transcribe',
        'requestId': 'daily-start-1',
      };
      final pending = await actions.callTool('transcription_start', args);
      expect(pending['status'], 'approval_required');
      expect(backend.enqueues, 0);
      expect(
        (await actions.callTool('transcription_start', args))['approvalId'],
        pending['approvalId'],
      );
      await approvals.resolve(pending['approvalId'] as String, approve: true);
      final started = await actions.callTool('transcription_start', args);
      expect(started['taskIds'], hasLength(1));
      expect(backend.enqueues, 1);
      expect(backend.controls, 1);
      expect(backend.configurations.single['frozen'], null);
      expect(await actions.callTool('transcription_start', args), started);
      expect(backend.enqueues, 1);
      await expectLater(
        actions.callTool('transcription_start', {
          'mediaIds': ['media-1'],
          'mode': 'transcribe_translate',
          'requestId': 'daily-start-1',
        }),
        throwsA(isA<ExternalAiActionError>()),
      );
      approvals.dispose();
    },
  );
}
