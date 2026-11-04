import '../features/cloud_drive/models/cloud_drive_models.dart';
import '../features/cloud_drive/models/cloud_drive_view_options.dart';
import '../features/cloud_drive/services/cloud_drive_directory_session.dart';
import '../features/cloud_drive/services/cloud_drive_runtime.dart';
import '../features/podcasts/podcast_runtime.dart';
import '../models/media_source_ref.dart';
import '../models/video_item.dart';
import '../models/video_picker_tree_node.dart';
import 'internal_media_picker_source.dart';
import 'library_service.dart';
import 'transcription_manager.dart';

/// A snapshot of the user's selection, independent of the originating page.
class TranscriptionMediaSelection {
  TranscriptionMediaSelection({
    Iterable<String> libraryIds = const [],
    Iterable<CloudDriveEntry> cloudEntries = const [],
    Iterable<String> podcastChannelIds = const [],
    Iterable<String> podcastEpisodeIds = const [],
    Iterable<VideoItem> items = const [],
  }) : libraryIds = List.unmodifiable(libraryIds),
       cloudEntries = List.unmodifiable(cloudEntries),
       podcastChannelIds = List.unmodifiable(podcastChannelIds),
       podcastEpisodeIds = List.unmodifiable(podcastEpisodeIds),
       items = List.unmodifiable(items);

  final List<String> libraryIds, podcastChannelIds, podcastEpisodeIds;
  final List<CloudDriveEntry> cloudEntries;
  final List<VideoItem> items;
}

/// Resolves metadata only. Media preparation remains in the existing queue.
/// Each branch can fail independently, and retrying is safe after a partial read.
class TranscriptionMediaResolver {
  TranscriptionMediaResolver({
    required this.library,
    required TranscriptionManager manager,
    this.cloudRuntime,
  }) : source = InternalMediaPickerSource(library: library, manager: manager);

  final LibraryService library;
  final InternalMediaPickerSource source;
  final CloudDriveRuntime? cloudRuntime;
  final nodes = <VideoPickerTreeNode>[];
  final failures = <({String label, Object error})>[];
  final _visited = <String>{};
  final _media = <String>{};
  CloudDriveDirectorySession? _directory;
  bool cancelled = false;

  void cancel() {
    cancelled = true;
    _directory?.pause();
  }

  Future<void> _attempt(String label, Future<void> Function() read) async {
    if (cancelled) return;
    try {
      await read();
    } catch (error) {
      if (!cancelled) failures.add((label: label, error: error));
    }
  }

  void _add(VideoPickerTreeNode node) {
    final item = node.mediaItem;
    if (cancelled || item == null || item.isRecycled) return;
    final identity =
        (item.sourceRef?.cloudDrive == null
            ? null
            : 'cloud:${item.sourceRef!.cloudDrive!.sourceKey}') ??
        (item.sourceRef?.podcast == null
            ? null
            : 'podcast:${item.sourceRef!.podcast!.episodeId}') ??
        'library:${item.id}';
    if (_media.add(identity)) nodes.add(node);
  }

  Future<void> resolve(TranscriptionMediaSelection selection) async {
    for (final id in selection.libraryIds) {
      await _attempt(
        library.getCollection(id)?.name ?? library.getVideo(id)?.title ?? id,
        () => _libraryEntry(id),
      );
    }
    for (final entry in selection.cloudEntries) {
      await _attempt(entry.name, () => _cloudEntry(entry));
    }
    for (final id in selection.podcastChannelIds) {
      await _attempt(id, () => _podcastChannel(id));
    }
    for (final id in selection.podcastEpisodeIds) {
      await _attempt(id, () async {
        final runtime = PodcastRuntime.instance;
        if (!runtime.ready) await runtime.initialize(library: library);
        final episode = runtime.store.episode(id);
        if (episode == null || episode.media.isEmpty) {
          throw StateError('节目媒体暂不可用');
        }
        final item = await runtime.itemFor(episode, persist: false);
        _add(
          source.nodeFor(
            item,
            name: runtime.episodeTitle(episode),
            durationMs: item.durationMs > 0
                ? item.durationMs
                : episode.durationMs,
          ),
        );
      });
    }
    for (final item in selection.items) {
      _add(source.nodeFor(library.getVideo(item.id) ?? item));
    }
  }

  Future<void> _libraryEntry(String id) async {
    if (cancelled || !_visited.add('library:$id')) return;
    if (_visited.length % 64 == 0) await Future<void>.delayed(Duration.zero);
    if (cancelled) return;
    final item = library.getVideo(id);
    if (item != null) {
      _add(source.nodeFor(item));
      return;
    }
    final folder = library.getCollection(id);
    if (folder == null || folder.isRecycled) {
      throw StateError('文件夹或媒体已不可用');
    }
    if (folder.podcastRef case final podcast?) {
      await _podcastChannel(podcast.channelId, folderId: folder.id);
    } else {
      for (final child in library.getContents(id)) {
        await _attempt(
          child is VideoItem ? child.title : child.name as String,
          () => _libraryEntry(child.id as String),
        );
      }
      if (folder.sourceRef?.cloudDrive != null) {
        await _attempt(
          folder.name,
          () => _cloudFolder(folder.sourceRef!, folder.name),
        );
      }
    }
  }

  Future<void> _podcastChannel(String id, {String? folderId}) async {
    if (cancelled || !_visited.add('podcast:$id')) return;
    final children = await source.nodesForPodcastChannel(
      id,
      folderId: folderId ?? PodcastRuntime.instance.collectionFor(id)?.id,
    );
    for (final node in children) {
      _add(node);
    }
  }

  Future<void> _cloudEntry(CloudDriveEntry entry) async {
    if (cancelled) return;
    if (entry.kind == CloudDriveEntryKind.folder) {
      await _cloudFolder(cloudDriveEntrySource(entry), entry.name);
    } else if (entry.kind == CloudDriveEntryKind.video ||
        entry.kind == CloudDriveEntryKind.audio) {
      final item = await library.upsertCloudDriveCard(
        source: cloudDriveEntrySource(entry),
        title: entry.name,
        persist: false,
        durationMs: entry.durationMs ?? 0,
        mediaType: entry.kind == CloudDriveEntryKind.audio
            ? MediaType.audio
            : MediaType.video,
        thumbnailRef: entry.thumbnailRef,
      );
      _add(source.nodeFor(item));
    }
  }

  Future<void> _cloudFolder(MediaSourceRef sourceRef, String name) async {
    final ref = sourceRef.cloudDrive!;
    if (cancelled || !_visited.add('cloud:${ref.sourceKey}')) return;
    final runtime = cloudRuntime ?? await CloudDriveRuntime.ensureInstalled();
    if (cancelled) return;
    final account = runtime.accounts.findRemote(
      ref.providerId,
      ref.remoteAccountId,
    );
    if (account == null) throw StateError('需要登录网盘');
    final directory = CloudDriveDirectorySession(
      runtime: runtime,
      account: account,
      directoryId: ref.providerId == 'baidu'
          ? ref.pathHint ?? ref.fileId
          : ref.fileId,
    );
    _directory = directory;
    try {
      await directory.finish();
      if (cancelled) return;
      if (!directory.complete) throw StateError('$name 未读取完整，请重试');
      final entries = List<CloudDriveEntry>.of(directory.entries)
        ..sort(const CloudDriveViewOptions().compare);
      for (final entry in entries) {
        await _attempt(entry.name, () => _cloudEntry(entry));
      }
    } finally {
      if (identical(_directory, directory)) _directory = null;
      directory.release();
    }
  }
}
