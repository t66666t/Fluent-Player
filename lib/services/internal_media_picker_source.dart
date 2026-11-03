import '../features/cloud_drive/services/cloud_drive_runtime.dart';
import '../features/podcasts/podcast_runtime.dart';
import '../models/video_collection.dart';
import '../models/media_source_ref.dart';
import '../models/library_activity.dart';
import '../models/video_item.dart';
import '../models/video_picker_tree_node.dart';
import '../utils/media_duration_label.dart';
import 'library_service.dart';
import 'transcription_manager.dart';

/// Browsing projects the podcast catalog without inserting library records or
/// preparing media. Only confirmed episodes acquire a persistent library id.
class InternalMediaPickerSource {
  InternalMediaPickerSource({required this.library, required this.manager});

  final LibraryService library;
  final TranscriptionManager manager;
  final _podcastFolders = <String, VideoCollection>{};

  VideoPickerTree buildTree() {
    _podcastFolders.clear();
    final visited = <String>{};
    List<VideoPickerTreeNode> build(String? parentId) => [
      for (final item in library.getContents(parentId))
        if (item is VideoCollection && visited.add(item.id))
          VideoPickerTreeNode(
            nodeId: item.id,
            name: item.name,
            isFolder: true,
            parentId: parentId,
            childrenLoaded: !item.isPodcast,
            children: item.isPodcast ? _deferPodcast(item) : build(item.id),
          )
        else if (item is VideoItem)
          nodeFor(item, parentId: parentId),
    ];
    return VideoPickerTree(roots: build(null))..recalculateCounts();
  }

  List<VideoPickerTreeNode> _deferPodcast(VideoCollection folder) {
    _podcastFolders[folder.id] = folder;
    return [];
  }

  bool isPodcastFolder(VideoPickerTreeNode node) =>
      _podcastFolders.containsKey(node.nodeId);

  VideoPickerTreeNode nodeFor(
    VideoItem item, {
    String? parentId,
    String? name,
    int? durationMs,
  }) => VideoPickerTreeNode(
    nodeId: item.id,
    name: name ?? item.title,
    isFolder: false,
    parentId: parentId ?? item.parentId,
    videoId: item.id,
    videoPath: item.path,
    videoDuration: formatMediaDurationLabel(durationMs ?? item.durationMs),
    mediaItem: item,
    isAlreadyInQueue: isQueued(item.path, item.id),
  );

  bool isQueued(String path, String? id) =>
      manager.isVideoQueued(path, videoId: id) ||
      manager.isVideoRunning(path, videoId: id);

  bool hasEarlierEpisodes(VideoPickerTreeNode node) {
    final channelId = _podcastFolders[node.nodeId]?.podcastRef?.channelId;
    final runtime = PodcastRuntime.instance;
    return channelId != null &&
        runtime.ready &&
        runtime.store.channel(channelId)?.nextPage != null;
  }

  Future<void> loadEarlierEpisodes(VideoPickerTreeNode node) async {
    final runtime = PodcastRuntime.instance;
    final channelId = _podcastFolders[node.nodeId]!.podcastRef!.channelId;
    final previousPage = runtime.store.channel(channelId)?.nextPage;
    if (previousPage == null) return;
    await runtime.controller.refreshChannel(
      channelId,
      history: true,
      manual: true,
    );
    if (runtime.store.channel(channelId)?.nextPage == previousPage) {
      throw StateError('更早的节目暂未加载，请重试');
    }
    await loadChildren(node, reload: true);
  }

  Future<void> loadChildren(
    VideoPickerTreeNode node, {
    bool reload = false,
  }) async {
    if (node.childrenLoaded && !reload) return;
    final folder = _podcastFolders[node.nodeId]!;
    final selectedIds = {
      for (final child in node.children)
        if (child.isSelected) child.nodeId,
    };
    final children = await nodesForPodcastChannel(
      folder.podcastRef!.channelId,
      folderId: folder.id,
    );
    for (final child in children) {
      child.isSelected =
          selectedIds.contains(child.nodeId) && !child.isAlreadyInQueue;
    }
    node.children
      ..clear()
      ..addAll(children);
    node.childrenLoaded = true;
  }

  /// The same catalog projection for the picker and direct queue imports.
  Future<List<VideoPickerTreeNode>> nodesForPodcastChannel(
    String channelId, {
    String? folderId,
  }) async {
    final runtime = PodcastRuntime.instance;
    if (!runtime.ready) await runtime.initialize(library: library);
    if (runtime.store.channel(channelId) == null) {
      throw StateError('播客频道数据暂不可用，请在播客页面刷新后重试');
    }
    // Query the whole visible catalog, independent of downloads, heard state,
    // the channel page's current filter and which episodes already have cards.
    final ids = runtime.store.queryEpisodeIds(channelId: channelId);
    final existing = <String, VideoItem>{
      for (final item in library.storageVideos)
        if (!item.isRecycled && item.sourceRef?.podcast?.channelId == channelId)
          item.sourceRef!.podcast!.episodeId: item,
    };
    final children = <VideoPickerTreeNode>[];
    for (final id in ids) {
      final episode = runtime.store.episode(id);
      if (episode == null || episode.media.isEmpty) continue;
      final item =
          existing[id] ?? await runtime.itemFor(episode, persist: false);
      children.add(
        nodeFor(
          item,
          parentId: folderId,
          name: runtime.episodeTitle(episode),
          durationMs: item.durationMs > 0
              ? item.durationMs
              : episode.durationMs,
        ),
      );
      if (children.length % 100 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    // Keep ordinary media that was explicitly imported into a legacy channel.
    final episodeIds = ids.toSet();
    for (final item
        in folderId == null
            ? const <VideoItem>[]
            : library.getContents(folderId).whereType<VideoItem>()) {
      final episodeId = item.sourceRef?.podcast?.episodeId;
      if (episodeId == null || !episodeIds.contains(episodeId)) {
        // Hidden episodes follow the podcast catalog's visibility policy.
        if (episodeId != null && runtime.store.episode(episodeId) != null) {
          continue;
        }
        children.add(nodeFor(item, parentId: folderId));
      }
    }
    return children;
  }

  /// Uses the existing account-aware, revision-checked metadata cache. This
  /// never resolves a playback URL or downloads media to discover a duration.
  Future<bool> refreshDuration(
    VideoPickerTreeNode node, {
    bool force = false,
  }) async {
    final item = node.mediaItem;
    final source = item?.sourceRef?.cloudDrive;
    if (item == null || source == null) return false;
    if (item.durationMs > 0) {
      node.videoDuration = formatMediaDurationLabel(item.durationMs);
      return true;
    }
    final service =
        library.cloudDriveThumbnails ??
        (await CloudDriveRuntime.ensureInstalled()).thumbnails;
    final details = await service?.metadata(source, refresh: force);
    final duration = details?.durationMs ?? 0;
    final current = library.getVideo(item.id);
    if (duration <= 0 ||
        current == null ||
        current.sourceRef?.cloudDrive?.sourceKey != source.sourceKey ||
        current.sourceRef?.cloudDrive?.revision != source.revision) {
      return false;
    }
    await library.updateVideoDuration(item.id, duration);
    node.videoDuration = formatMediaDurationLabel(duration);
    return true;
  }

  Future<void> prepareSelection(List<VideoPickerTreeNode> nodes) async {
    var inserted = false, insertedCloud = false;
    for (final node in nodes) {
      final item = node.mediaItem;
      if (item == null || library.getVideo(item.id) != null) continue;
      if (item.sourceRef?.cloudDrive != null) {
        // Queue tasks need a stable card for subtitle registration and opening
        // completed results. This stores a reference, never the media bytes.
        await library.upsertCloudDriveCard(
          source: item.sourceRef!,
          title: item.title,
          libraryItemId: item.id,
          explicitPlacement: true,
          save: false,
          durationMs: item.durationMs,
          mediaType: item.type,
        );
        insertedCloud = true;
      } else if (item.sourceRef?.podcast != null) {
        await library.upsertPodcastEpisode(item, persist: false);
        inserted = true;
      } else if (item.sourceRef?.kind == MediaSourceKind.bilibiliStream) {
        final card = VideoItem.fromJson(item.toJson())
          ..isTransient = false
          ..parentId = null;
        await library.addSingleVideo(
          card,
          useOriginalPath: true,
          sourceKind: LibraryImportSourceKind.bilibili,
        );
      }
    }
    if (insertedCloud ||
        (library.hasPersistenceFailure &&
            nodes.any(
              (node) => node.mediaItem?.sourceRef?.cloudDrive != null,
            ))) {
      await library.commitCloudDriveReferences();
    } else if (inserted) {
      await library.persistPodcastAdapters();
    }
  }
}
