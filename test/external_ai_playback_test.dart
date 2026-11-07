import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/external_ai/external_ai_context.dart';
import 'package:video_player_app/features/external_ai/external_ai_library_source.dart';
import 'package:video_player_app/features/external_ai/external_ai_playback_source.dart';
import 'package:video_player_app/models/playback_mode.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/playback_queue_policy.dart';

class _Queue implements PlaylistManager {
  _Queue(this.playbackQueue);
  @override
  final List<VideoItem> playbackQueue;
  @override
  PlaybackQueueSnapshot get snapshot => PlaybackQueueSnapshot(
    revision: 9,
    entries: playbackQueue,
    currentItemId: playbackQueue.first.id,
    folderId: null,
  );
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw StateError('Unexpected queue mutation');
}

class _Playback implements MediaPlaybackService {
  _Playback(this.currentItem, this.playlistManager);
  @override
  final VideoItem? currentItem;
  @override
  final PlaylistManager playlistManager;
  @override
  VideoItem? get queuedPreviewItem => null;
  @override
  PlaybackState get state => PlaybackState.loading;
  @override
  bool get isPlaying => false;
  @override
  bool get isTransportPlaying => true;
  @override
  Duration get position => const Duration(seconds: 37);
  @override
  Duration get duration => const Duration(minutes: 3);
  @override
  PlaybackMode get playbackMode => PlaybackMode.shuffle;
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw StateError('MCP must not initialize or control playback');
}

void main() {
  late Directory temp;
  late List<VideoItem> library;
  late List<VideoCollection> folders;
  late ExternalAiPlaybackSnapshot state;
  String? scope;
  VideoItem item(String id, {String? parent, bool transient = true}) =>
      VideoItem(
        id: id,
        title: '媒体 $id',
        path: '${temp.path}/$id.mp4',
        durationMs: 180000,
        lastUpdated: 0,
        parentId: parent,
        isTransient: transient,
      );
  ExternalAiLibrarySource source() => ExternalAiLibrarySource(
    videos: () => library,
    folders: () => folders,
    children: (_) => [],
    playback: () => state,
    scopeFolder: () => scope,
  );
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mcp_playback_');
    library = [];
    folders = [];
    scope = null;
    state = const ExternalAiPlaybackSnapshot();
  });
  tearDown(() => temp.delete(recursive: true));

  test(
    'live adapter reads the mini-player display order and transport state without mutations',
    () {
      final first = item('second');
      final current = item('first');
      final snapshot = externalAiPlaybackSnapshot(
        _Playback(current, _Queue([first, current])),
      );
      expect(snapshot.queue.map((v) => v.id), ['second', 'first']);
      expect(snapshot.state, 'loading');
      expect(snapshot.transportPlaying, isTrue);
      expect(snapshot.isPlaying, isFalse);
      expect(snapshot.positionMs, 37000);
      expect(snapshot.mode, 'shuffle');
      expect(snapshot.queueRevision, 9);
    },
  );
  test(
    'current transient mini media is readable, with a bounded 500-item queue',
    () async {
      final queue = [for (var i = 0; i < 500; i++) item('$i')];
      state = ExternalAiPlaybackSnapshot(
        current: queue[12],
        queue: queue,
        state: 'playing',
        isPlaying: true,
        transportPlaying: true,
        positionMs: 37000,
        durationMs: 180000,
        queueRevision: 2,
      );
      final reader = source();
      final overview = await reader.callTool('player_overview', {});
      expect(overview['currentMedia']['id'], '12');
      expect(
        overview['mediaCount'],
        0,
      ); // Not silently imported into the library.
      final result = await reader.callTool('playback_read', {});
      expect(result['positionMs'], 37000);
      expect(result['queue']['items'], hasLength(50));
      expect(result['queue']['total'], 500);
      expect(result['queue']['currentIndex'], 12);
      expect(result['queue']['nextOffset'], 50);
      final info = await reader.callTool('media_info', {'mediaId': '12'});
      expect(info['id'], '12');
      expect(jsonEncode(result), isNot(contains(temp.path)));
      await expectLater(
        reader.callTool('playback_read', {'offset': 50, 'revision': 1}),
        throwsStateError,
      );
      final next = await reader.callTool('playback_read', {
        'offset': 50,
        'revision': 2,
      });
      expect(next['queue']['items'].first['id'], '50');
    },
  );
  test('a queue preview is not reported as currently playing', () async {
    final preview = item('preview');
    state = ExternalAiPlaybackSnapshot(preview: preview, queue: [preview]);
    final result = await source().callTool('playback_read', {});
    expect(result['currentMedia'], isNull);
    expect(result['previewMedia']['id'], 'preview');
    expect(result['isPlaying'], isFalse);
    expect(result['state'], 'idle');
    expect(result['queue']['currentIndex'], -1);
  });
  test(
    'queue membership never bypasses folder scope or recycled/hidden ancestors',
    () async {
      folders.addAll([
        VideoCollection(id: 'allowed', name: '允许', createTime: 0),
        VideoCollection(id: 'private', name: '私有', createTime: 0),
        VideoCollection(
          id: 'hidden',
          name: '隐藏',
          createTime: 0,
          parentId: 'allowed',
          isHiddenFromFolders: true,
        ),
      ]);
      final allowed = item('allowed', parent: 'allowed', transient: false);
      final private = item('private', parent: 'private', transient: false);
      final hidden = item('hidden', parent: 'hidden', transient: false);
      library.addAll([allowed, private, hidden]);
      scope = 'allowed';
      // A detached copy of a private library item cannot launder its scope.
      final detached = item('private');
      state = ExternalAiPlaybackSnapshot(
        current: detached,
        queue: [allowed, detached, hidden, item('outside')],
        positionMs: 32100,
        state: 'playing',
        isPlaying: true,
      );
      final reader = source();
      final result = await reader.callTool('playback_read', {});
      expect(result['currentMedia'], isNull);
      expect(result['positionMs'], isNull);
      expect(result['queue']['total'], 1);
      expect(result['queue']['items'].single['id'], 'allowed');
      await expectLater(
        reader.callTool('media_info', {'mediaId': 'outside'}),
        throwsArgumentError,
      );
    },
  );
  test(
    'session IDs support direct batch transcript reading without exposing unrelated transient cards',
    () async {
      final current = item('current');
      current.subtitlePath = (await File(
        '${temp.path}/transcript.txt',
      ).writeAsString('当前媒体完整文稿')).path;
      library.add(item('unrelated'));
      state = ExternalAiPlaybackSnapshot(
        current: current,
        queue: [current],
        state: 'paused',
        positionMs: 42000,
      );
      final reader = source();
      final result = await reader.callTool('documents_read_batch', {
        'mediaIds': ['current'],
      });
      expect(result['items'].single['text'], '当前媒体完整文稿');
      expect(result['complete'], isTrue);
      final status = await reader.callTool('playback_read', {});
      expect(status['state'], 'paused');
      expect(status['isPlaying'], isFalse);
      await expectLater(
        reader.callTool('media_info', {'mediaId': 'unrelated'}),
        throwsArgumentError,
      );
    },
  );
}
