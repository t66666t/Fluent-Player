import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/external_ai/external_ai_action_store.dart';
import 'package:video_player_app/features/external_ai/external_ai_approvals.dart';
import 'package:video_player_app/features/external_ai/external_ai_library_source.dart';
import 'package:video_player_app/features/external_ai/external_ai_preferences.dart';
import 'package:video_player_app/features/external_ai/external_ai_queue.dart';
import 'package:video_player_app/models/video_item.dart';

ExternalAiQueueTask task({
  String id = 'lesson',
  String generation = 'private/checkpoint-1',
  String status = 'paused',
  String config = 'config-1',
  bool remote = false,
  bool downloads = false,
  String? identity,
}) => ExternalAiQueueTask(
  mediaId: id,
  generation: generation,
  mediaIdentity: identity ?? 'identity-$id',
  configurationIdentity: config,
  restartConfigurationIdentity: config,
  status: status,
  phase: 'optimizing',
  progress: .4,
  optimizationCompleted: 4,
  optimizationTotal: 10,
  optimizationTotalIsFinal: true,
  settings: {
    'serviceId': 'gongyi',
    'serviceName': '公益接口',
    'serviceKind': 'gongyi',
    'optimizationEnabled': true,
    'translationEnabled': true,
    'apiKey': 'NEVER-RETURN',
    'path': '/private/movie.mp4',
    'endpoint': 'https://private.invalid/?key=SECRET',
  },
  restartSettings: {'serviceId': 'gongyi', 'serviceName': '公益接口'},
  actions: status == 'completed'
      ? ['restart']
      : status == 'failed'
      ? ['retry', 'cancel', 'restart']
      : ['start', 'pause', 'resume', 'cancel', 'restart'],
  usesRemote: remote,
  needsDownloads: downloads,
  restartUsesRemote: remote,
  restartNeedsDownloads: downloads,
);

class _Backend implements ExternalAiQueueBackend {
  List<ExternalAiQueueTask> rows = [task()];
  final calls = <String>[];
  void Function()? beforeControl;
  bool throwPrivate = false;
  bool includePathIdentity = false;
  @override
  String mediaIdentity(VideoItem item) =>
      'identity-${item.id}${includePathIdentity ? ':${item.path}' : ''}';
  @override
  Future<List<ExternalAiQueueTask>> queueSnapshot() async => rows;
  @override
  Future<bool> controlQueueTask(
    VideoItem media,
    ExternalAiQueueTask selected,
    String action,
    void Function() guard,
  ) async {
    beforeControl?.call();
    guard();
    if (throwPrivate) throw StateError('/private/movie.mp4?key=NEVER-RETURN');
    calls.add(action);
    return true;
  }
}

class _Store extends ExternalAiActionStore {
  _Store(super.root) : super(name: 'queue-tests');
  bool fail = false;
  @override
  Future<void> save(Map<String, dynamic> state) async {
    if (fail) throw const FileSystemException('fixture persistence failure');
    await super.save(state);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ExternalAiPreferences prefs;
  late ExternalAiApprovals approvals;
  late ExternalAiQueueSource queue;
  late _Backend backend;
  late _Store store;
  late List<VideoItem> videos;
  var epoch = 0;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mcp-app-queue-');
    prefs = ExternalAiPreferences(
      token: ExternalAiPreferences.generateToken(),
      enabled: true,
      allowTaskControl: true,
      autoTaskDecisions: true,
      autoRemoteProcessing: true,
      autoModelDownloads: true,
    );
    backend = _Backend();
    store = _Store(root);
    epoch = 0;
    videos = [
      VideoItem(
        id: 'lesson',
        title: '课程',
        path: '${root.path}/private.mp4',
        durationMs: 0,
        lastUpdated: 0,
      ),
    ];
    approvals = ExternalAiApprovals(
      store: ExternalAiActionStore(root, name: 'approval-tests'),
      preferences: () => prefs,
    );
    final library = ExternalAiLibrarySource(
      videos: () => videos,
      folders: () => [],
      children: (_) => videos,
      scopeFolder: () => prefs.scopeFolderId,
    );
    queue = ExternalAiQueueSource(
      library: library,
      backend: backend,
      store: store,
      approvals: approvals,
      preferences: () => prefs,
      generation: () => epoch,
    );
    await queue.initialize();
  });
  tearDown(() async {
    store.fail = false;
    await queue.shutdown();
    approvals.dispose();
    await root.delete(recursive: true);
  });
  Future<Map<String, dynamic>> read([Map<String, dynamic> a = const {}]) =>
      queue.callTool('transcription_queue', a);
  Future<String> id() async =>
      ((await read())['tasks'] as List).first['taskId'] as String;
  Future<Map<String, dynamic>> control(
    String action, {
    String? taskId,
    String? requestId,
  }) async => queue.callTool('transcription_queue_control', {
    'taskIds': [taskId ?? await id()],
    'action': action,
    'requestId': requestId ?? 'request-$action',
  });

  test(
    'software queue exposes manual tasks and actual optimization counters, never native identity or secrets',
    () async {
      backend.rows = [task(), task(id: 'hidden')];
      final response = await read();
      final rows = response['tasks'] as List;
      expect(rows, hasLength(1));
      expect(rows.single['createdBy'], 'app');
      expect(rows.single['optimizationCompleted'], 4);
      expect(rows.single['settings']['serviceKind'], 'gongyi');
      final encoded = jsonEncode(response);
      for (final private in [
        'checkpoint-1',
        'NEVER-RETURN',
        '/private/',
        'SECRET',
        'hidden',
      ]) {
        expect(encoded, isNot(contains(private)));
      }
      expect(rows.single['taskId'], startsWith('queue_'));
    },
  );

  test(
    'manual tasks support each native action, safe replay and reject arbitrary paths',
    () async {
      for (final action in ['start', 'pause', 'resume', 'cancel']) {
        final response = await control(action);
        expect(response['status'], 'completed');
        expect(await control(action), response);
      }
      expect(backend.calls, ['start', 'pause', 'resume', 'cancel']);
      await expectLater(
        queue.callTool('transcription_queue_control', {
          'taskIds': [await id()],
          'action': 'pause',
          'requestId': 'bad-extra-path',
          'path': '/private/movie.mp4',
        }),
        throwsStateError,
      );
    },
  );

  test(
    'restart requires its own concrete approval even after task delegation',
    () async {
      backend.rows = [task(status: 'completed')];
      final response = await control('restart');
      expect(response['status'], 'approval_required');
      expect(response['categories'], contains('restart'));
      expect(backend.calls, isEmpty);
      await approvals.resolve(response['approvalId'] as String, approve: true);
      expect((await control('restart'))['status'], 'completed');
      expect(backend.calls, ['restart']);
    },
  );

  test(
    'remote and missing-model consent remain separate from task delegation',
    () async {
      backend.rows = [task(remote: true, downloads: true)];
      prefs = prefs.copyWith(
        autoRemoteProcessing: false,
        autoModelDownloads: false,
      );
      final response = await control('start');
      expect(response['status'], 'approval_required');
      expect(
        response['categories'],
        containsAll(['tasks', 'remote', 'downloads']),
      );
      expect(backend.calls, isEmpty);
    },
  );

  test(
    'old handles never control a replacement generation, substituted media or another grant',
    () async {
      final old = await id();
      backend.rows = [task(generation: 'private/new-checkpoint')];
      await expectLater(control('pause', taskId: old), throwsStateError);
      expect(backend.calls, isEmpty);
      final next = await id();
      prefs = prefs.copyWith(token: ExternalAiPreferences.generateToken());
      epoch++;
      await expectLater(control('pause', taskId: next), throwsStateError);
      expect(backend.calls, isEmpty);
      backend.rows = [task(id: 'hidden')];
      expect((await read())['tasks'], isEmpty);
    },
  );

  test(
    'pending approval cannot authorize a changed task configuration',
    () async {
      prefs = prefs.copyWith(autoTaskDecisions: false);
      final response = await control('start');
      await approvals.resolve(response['approvalId'] as String, approve: true);
      backend.rows = [task(config: 'new-config')];
      final changed = await control('start');
      expect(changed['status'], 'approval_required');
      expect(changed['approvalId'], isNot(response['approvalId']));
      expect(backend.calls, isEmpty);
    },
  );

  test(
    'revocation blocks a queued request and safe failures do not leak native exceptions',
    () async {
      backend.throwPrivate = true;
      final response = await control('pause');
      expect(response['status'], 'completed_with_errors');
      expect(jsonEncode(response), isNot(contains('NEVER-RETURN')));
      backend.throwPrivate = false;
      backend.beforeControl = () {
        prefs = prefs.copyWith(allowTaskControl: false);
        epoch++;
      };
      await expectLater(
        control('pause', requestId: 'revoked-request'),
        throwsStateError,
      );
      expect(backend.calls, isEmpty);
    },
  );

  test(
    'moving a media outside authorization during native consent blocks its side effect and receipt replay',
    () async {
      final selected = await id();
      final original = videos.single;
      backend.beforeControl = () { original.isRecycled = true; };
      await expectLater(control('start', taskId: selected), throwsArgumentError);
      expect(backend.calls, isEmpty);
      original.isRecycled = false;
      backend.beforeControl = null;
      await control('pause', taskId: selected, requestId: 'scope-receipt');
      original.isRecycled = true;
      await expectLater(control('pause', taskId: selected, requestId: 'scope-receipt'), throwsArgumentError);
      expect(backend.calls, ['pause']);
    },
  );

  test(
    'in-place media source replacement during native consent cannot reuse the authorized identity',
    () async {
      backend.includePathIdentity = true;
      final original = videos.single;
      backend.rows = [task(identity: backend.mediaIdentity(original))];
      final selected = await id();
      backend.beforeControl = () { original.path = '${root.path}/substituted.mp4'; };
      await expectLater(control('start', taskId: selected), throwsStateError);
      expect(identical(videos.single, original), true);
      expect(backend.calls, isEmpty);
    },
  );

  test(
    'journal persistence is durable before side effects and retry does not duplicate them',
    () async {
      store.fail = true;
      await expectLater(control('pause'), throwsA(isA<FileSystemException>()));
      expect(backend.calls, isEmpty);
      store.fail = false;
      expect((await control('pause'))['status'], 'completed');
      expect(backend.calls, ['pause']);
    },
  );

  test(
    'failed tasks can be retried without a restart and queue pagination rejects changed membership',
    () async {
      backend.rows = [task(status: 'failed')];
      expect((await control('retry'))['status'], 'completed');
      expect(backend.calls, ['retry']);
      final page = await read({'limit': 1});
      backend.rows = [];
      await expectLater(
        read({'revision': page['revision'], 'offset': 0}),
        throwsStateError,
      );
    },
  );
}
