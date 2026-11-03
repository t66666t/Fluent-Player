import '../../services/storage_migration_coordinator.dart';
import '../../services/app_storage_service.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import '../../models/import_card_placement.dart';
import '../../services/settings_service.dart';
import '../../models/media_chapter.dart';
import '../../models/media_source_ref.dart';
import '../../models/podcast_source_ref.dart';
import '../../models/video_collection.dart';
import '../../models/video_item.dart';
import '../../models/media_artwork_ref.dart';
import '../../services/effective_media_playback_preferences.dart';
import '../../services/library_service.dart';
import '../../services/media_artwork_repository.dart';
import '../../services/media_playback_service.dart';
import '../../services/playlist_manager.dart';
import '../../utils/app_data_paths.dart';
import 'podcast_background.dart';
import 'podcast_client.dart';
import 'podcast_controller.dart';
import 'podcast_feed_parser.dart';
import 'podcast_media_store.dart';
import 'podcast_models.dart';
import 'podcast_notifications.dart';
import 'podcast_playback_hooks.dart';
import 'podcast_settings.dart';
import 'podcast_store.dart';
import 'podcast_transfer.dart';
import '../media_cache/media_cache_hooks.dart';
import '../media_cache/media_cache_models.dart';

class PodcastRuntime extends ChangeNotifier with WidgetsBindingObserver {
  static final _instance = PodcastRuntime();
  @visibleForTesting
  static PodcastRuntime? debugOverride;
  static PodcastRuntime get instance => debugOverride ?? _instance;
  PodcastRuntime();
  @visibleForTesting
  PodcastRuntime.forTesting(
    PodcastController controller, {
    this.library,
    this.playlist,
    this.playback,
  }) : _controller = controller {
    controller.addListener(notifyListeners);
    library?.addRenameObserver(_itemRenamed);
    _restoreEpisodeTitles();
  }
  PodcastController? _controller;
  PodcastController get controller => _controller!;
  PodcastStore get store => controller.store;
  bool get ready => _controller != null;
  String? initializationError;
  Future<void>? _initializing;
  Future<void>? _preparingCardArtwork;
  final Map<String, PodcastChannel> _cardChannels = {};
  LibraryService? library;
  PlaylistManager? playlist;
  MediaPlaybackService? playback;
  MediaArtworkRepository? artwork;
  Timer? _refreshTimer;
  Timer? _progressTimer;
  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  final notifications = PodcastNotifications();
  final ValueNotifier<String?> pendingChannel = ValueNotifier(null);
  String? _outroSkipped;
  String? openingEpisodeId;
  String? failedEpisodeId, playbackError;
  int _openingGeneration = 0;

  /// Episodes the user asked to start from. A later retry must reuse this
  /// snapshot instead of inventing a one-episode queue.
  List<PodcastEpisode>? _openingCatalog;

  /// Episode ids actually written into the media library. Queue projection
  /// must not grow this once per row.
  @visibleForTesting
  final persistedEpisodeIds = <String>[];

  /// Test hook. Playback must not wait for this future before opening media.
  @visibleForTesting
  Future<void> Function()? persistAdaptersOverride;
  final Map<String, int> _learningUses = {};
  final Map<String, String> _sourceIdentities = {};
  final String _learningOwner = podcastHash(
    '${DateTime.now().microsecondsSinceEpoch}:${identityHashCode(Object())}',
  );
  Timer? _learningLeaseTimer;
  bool _checkingLibrary = false;
  bool _shuttingDown = false;

  /// Local card metadata and covers can be shown before playback, notifications
  /// and background refresh services have finished starting.
  Future<void> prepareCardArtwork({LibraryService? library}) async {
    if (StorageMigrationCoordinator.maintenance) {
      throw const StorageUnavailableException('数据目录正在迁移');
    }
    if (library != null) this.library = library;
    _shuttingDown = false;
    try {
      await (_preparingCardArtwork ??= _prepareCardArtwork());
    } catch (_) {
      _preparingCardArtwork = null;
      rethrow;
    }
  }

  PodcastChannel? channelForCard(String channelId) =>
      ready ? store.channel(channelId) : _cardChannels[channelId];

  Future<Directory> _podcastDirectory() async {
    final dataRoot =
        library?.dataRootDirOrNull ?? await resolveAppDataDirectory();
    final directory = AppStorageService.instance.isReady
        ? await AppStorageService.instance.featureDirectory(
            'podcasts',
            marker: 'podcasts.sqlite',
          )
        : Directory(p.join(dataRoot.path, 'podcasts'));
    await directory.create(recursive: true);
    return directory;
  }

  Future<void> _prepareCardArtwork() async {
    final directory = await _podcastDirectory();
    final previewStore = PodcastStore.open(
      p.join(directory.path, 'podcasts.sqlite'),
    );
    try {
      _cardChannels.addEntries(
        previewStore.channels.map((channel) => MapEntry(channel.id, channel)),
      );
    } finally {
      previewStore.close();
    }
    final dataRoot =
        library?.dataRootDirOrNull ?? await resolveAppDataDirectory();
    artwork = await MediaArtworkRepository.open(
      AppStorageService.instance.isReady
          ? await AppStorageService.instance.featureDirectory('artwork')
          : Directory(p.join(dataRoot.path, 'artwork')),
      legacyPodcastDirectory: Directory(p.join(directory.path, 'artwork')),
    );
    notifyListeners();
  }

  Future<void> initialize({
    LibraryService? library,
    PlaylistManager? playlist,
    MediaPlaybackService? playback,
  }) async {
    if (StorageMigrationCoordinator.maintenance) {
      throw const StorageUnavailableException('数据目录正在迁移');
    }
    if (library != null) this.library = library;
    if (playlist != null) this.playlist = playlist;
    if (playback != null) this.playback = playback;
    if (ready && _initializing == null) return;
    await (_initializing ??= _open());
  }

  Future<void> _open() async {
    try {
      await prepareCardArtwork();
      final directory = await _podcastDirectory();
      final store = PodcastStore.open(
        p.join(directory.path, 'podcasts.sqlite'),
      );
      final client = PodcastClient();
      _controller = PodcastController(
        store: store,
        client: client,
        readConnectivity: Connectivity().checkConnectivity,
        mediaStore: PodcastMediaStore(
          root: Directory(p.join(directory.path, 'media')),
          store: store,
          http: client.http,
        ),
      );
      controller.addListener(notifyListeners);
      // Progress and listened state update an existing projection only.
      // Marking a whole channel heard must not insert one library row per episode.
      controller.onUserStateChanged = (id, state) {
        final item = adapterFor(id);
        if (item == null || library == null) return;
        unawaited(
          library!.applySyncedPlaybackProgress(
            mediaId: item.id,
            positionMs: state.positionMs,
            completed: state.played,
            continueEnrolled: state.positionMs > 0 && !state.played,
            accumulatedWatchMs:
                library!.mediaActivity(item.id)?.accumulatedWatchMs ?? 0,
            lastPlayedAtMs: state.lastPlayedMs == 0 ? null : state.lastPlayedMs,
          ),
        );
      };
      library?.addProgressObserver(_progressChanged);
      library?.addListener(_libraryChanged);
      library?.addRenameObserver(_itemRenamed);
      playback?.addListener(_playbackChanged);
      PodcastPlaybackHooks.resolve = resolvePlayback;
      PodcastPlaybackHooks.restoreSource = restoreSource;
      PodcastPlaybackHooks.prepareSeek = (item) => controller.mediaStore
          .prepareForSeek(item.sourceRef!.podcast!.episodeId);
      PodcastPlaybackHooks.speed = (item) =>
          _resolvedSpeed(item.sourceRef?.podcast?.channelId).value;
      PodcastPlaybackHooks.speedOverridden = (item) {
        final channelId = item.sourceRef?.podcast?.channelId;
        final global = store.read('settings', 'global') ?? {};
        final channel = channelId == null ? null : store.overrides(channelId);
        return (channel?.containsKey('speed') ?? false) ||
            global.containsKey('speed');
      };
      PodcastPlaybackHooks.setSpeedDefault = (item, speed, locked) => setting(
        item.sourceRef!.podcast!.channelId,
        'speed',
        locked ? speed : null,
      );
      PodcastPlaybackHooks.continuous = (item) =>
          _resolvedContinuous(item.sourceRef?.podcast?.channelId).value;
      PodcastPlaybackHooks.completed = (item) =>
          controller.setPlayed(item.sourceRef!.podcast!.episodeId, true);
      PodcastPlaybackHooks.syncedProgress =
          (item, position, completed, lastPlayed) {
            final id = item.sourceRef!.podcast!.episodeId;
            controller.savePlaybackProgress(
              id,
              position,
              completed: completed,
              lastPlayedMs: lastPlayed,
            );
          };
      PodcastPlaybackHooks.materialize = materialize;
      PodcastPlaybackHooks.materializeVideo =
          (item, {isCancelled, cancelSignal, onProgress}) => materialize(
            item,
            requireVideo: true,
            isCancelled: isCancelled,
            cancelSignal: cancelSignal,
            onProgress: onProgress,
          );
      PodcastPlaybackHooks.cachedVariants = cachedVariants;
      PodcastPlaybackHooks.isStoragePathInUse = (path) =>
          !_shuttingDown &&
          ready &&
          controller.mediaStore.isStoragePathInUse(path);
      PodcastPlaybackHooks.forgetDeletedStorage = (paths) async {
        if (!_shuttingDown && ready) {
          await controller.forgetDeletedStorage(paths);
        }
      };
      PodcastPlaybackHooks.releaseMaterialized = releaseMaterialized;
      WidgetsBinding.instance.addObserver(this);
      _connectivity = Connectivity().onConnectivityChanged.listen((value) {
        final wasOffline = controller.connectivity.contains(
          ConnectivityResult.none,
        );
        controller.connectivity = value;
        if (!value.contains(ConnectivityResult.none)) {
          if (wasOffline) unawaited(refresh(trigger: 'network'));
          unawaited(controller.pumpDownloads());
        }
      }, onError: (_) {});
      await _reconcile();
      try {
        await notifications.initialize(
          onOpen: (id) => pendingChannel.value = id,
        );
      } catch (_) {
        /* Playback and subscriptions work without system notifications. */
      }
      try {
        await configurePodcastBackground(
          directory.path,
          store.preferences.flag('backgroundRefresh') &&
              !store.preferences.flag('pauseAllUpdates'),
        );
      } catch (_) {
        /* Foreground checks remain available on unsupported hosts. */
      }
      _refreshTimer = Timer.periodic(const Duration(minutes: 1), (_) {
        unawaited(refresh());
      });
      _progressTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _playbackChanged(),
      );
      notifyListeners();
      unawaited(refresh(trigger: 'launch'));
      unawaited(controller.pumpDownloads());
    } catch (error) {
      initializationError = '播客数据暂时无法打开：$error';
      _initializing = null;
      notifyListeners();
      rethrow;
    }
  }

  VideoCollection? collectionFor(String channelId) => library
      ?.storageCollections
      .where((c) => c.podcastRef?.channelId == channelId)
      .firstOrNull;

  /// A subscription's library card owns its application-wide display name.
  /// Feed metadata stays untouched so refresh and source identity remain stable.
  String channelTitle(PodcastChannel channel) =>
      collectionFor(channel.id)?.name ?? channel.title;

  Future<void> showChannelInFolders(String channelId) async {
    final card = collectionFor(channelId);
    if (card == null || card.isRecycled) return;
    await library!.setPodcastVisibleInFolders(card.id, visible: true);
    notifyListeners();
  }

  Future<void> unsubscribe(String channelId) async {
    final card = collectionFor(channelId);
    if (card != null) await library!.moveToRecycleBin([card.id]);
    final channel = store.channel(channelId);
    if (channel == null) return;
    channel.active = false;
    store.write('channel', channelId, channel.toJson());
    notifyListeners();
  }

  String episodeTitle(PodcastEpisode episode) {
    final alias = store.presentation(episode.id)['localTitle'] as String?;
    return alias == null || alias.trim().isEmpty ? episode.title : alias;
  }

  void _restoreEpisodeTitles() {
    // Recover renames made before the podcast runtime was initialized, including
    // names saved by older releases that only changed the library adapter.
    for (final item in library?.storageVideos ?? <VideoItem>[]) {
      final ref = item.sourceRef?.podcast;
      if (ref == null) continue;
      final episode = store.episode(ref.episodeId);
      if (episode != null &&
          item.title != episode.title &&
          (store.presentation(episode.id)['localTitle'] as String? ?? '')
              .isEmpty) {
        store.setPresentation(episode.id, localTitle: item.title);
      }
    }
  }

  void _itemRenamed(String itemId, String name) {
    final episodeId = library?.getVideo(itemId)?.sourceRef?.podcast?.episodeId;
    if (episodeId != null) {
      _setEpisodeTitle(episodeId, name);
    } else if (library?.getCollection(itemId)?.isPodcast == true) {
      notifyListeners();
    }
  }

  void _setEpisodeTitle(String episodeId, String name) {
    store.setPresentation(episodeId, localTitle: name);
    var queueChanged = false;
    for (final item in playlist?.playlist ?? <VideoItem>[]) {
      if (item.sourceRef?.podcast?.episodeId == episodeId) {
        item.title = name;
        queueChanged = true;
      }
    }
    if (queueChanged) playlist?.revalidatePlaylist();
    final current = playback?.currentItem;
    if (current?.sourceRef?.podcast?.episodeId == episodeId) {
      current!.title = name;
    }
    notifyListeners();
  }

  Future<void> renameEpisode(String episodeId, String name) async {
    name = name.trim();
    if (name.isEmpty) return;
    final adapter = _existingAdapter(episodeId);
    if (adapter != null && library != null) {
      await library!.renameItem(adapter.id, name);
    } else {
      // Naming a catalog row does not materialize a library/playback card.
      _setEpisodeTitle(episodeId, name);
    }
  }

  Future<VideoCollection?> subscribe(
    PodcastFeed feed, {
    String? parentId,
    bool standalone = false,
    bool explicitPlacement = false,
    ImportPlacementRequest? importPlacement,
  }) async {
    final feature = standalone
        ? ImportCardFeature.podcastEpisode
        : ImportCardFeature.podcast;
    final placement =
        importPlacement ??
        (explicitPlacement
            ? ImportPlacementRequest.explicit(feature, parentId)
            : SettingsService().captureImportPlacement(
                feature,
                openedFromFolderId: parentId,
              ));
    store.write('card', feed.channel.id, {'pending': true});
    final channel = await controller.subscribe(feed);
    if (standalone) {
      final target = await library?.resolveImportCardParentId(
        feature: feature,
        openedFromFolderId: parentId,
        request: placement,
      );
      channel.active = false;
      store.write('channel', channel.id, channel.toJson());
      final item = await itemFor(
        feed.episodes.first,
        parentId: target,
        standalone: true,
      );
      library?.noteImportedMedia(item.id);
      store.write('card', channel.id, {'pending': false});
      return null;
    }
    final existing = collectionFor(channel.id);
    if (existing != null) {
      if (existing.isRecycled) {
        await library!.restoreFromRecycleBin([existing.id]);
      }
      return existing;
    }
    final target = await library?.resolveImportCardParentId(
      feature: feature,
      openedFromFolderId: parentId,
      request: placement,
    );
    final card = await library?.createCollection(
      channel.title,
      target,
      podcastRef: PodcastChannelRef(
        channelId: channel.id,
        feedUrl: channel.feedUrl,
      ),
    );
    store.write('card', channel.id, {'pending': false});
    if (card != null) library?.noteImportedCollection(card.id, batchId: null);
    notifyListeners();
    return card;
  }

  Future<void> _reconcile() async {
    if (library == null) return;
    _restoreEpisodeTitles();
    for (final channel in store.channels) {
      final card = collectionFor(channel.id);
      if (card == null &&
          store.read('card', channel.id)?['pending'] == true &&
          channel.active) {
        await library!.createCollection(
          channel.title,
          null,
          podcastRef: PodcastChannelRef(
            channelId: channel.id,
            feedUrl: channel.feedUrl,
          ),
        );
        store.write('card', channel.id, {'pending': false});
      }
    }
    _libraryChanged();
  }

  void _libraryChanged() {
    if (!ready || _checkingLibrary || library == null) return;
    _checkingLibrary = true;
    try {
      for (final channel in store.channels) {
        final card = collectionFor(channel.id);
        if (card == null &&
            store.read('card', channel.id)?['pending'] == true) {
          continue;
        }
        final active = card != null && !library!.isStorageItemRecycled(card.id);
        if (channel.active != active) {
          channel.active = active;
          store.write('channel', channel.id, channel.toJson());
        }
      }
    } finally {
      _checkingLibrary = false;
    }
  }

  ResolvedPlaybackPreference<bool> _resolvedContinuous(String? channelId) {
    return const EffectiveMediaPlaybackPreferences().continuous(
      globalRaw: store.read('settings', 'global') ?? {},
      channelRaw: channelId == null ? null : store.overrides(channelId),
      software: SoftwarePlaybackDefaults.current(),
    );
  }

  ResolvedPlaybackPreference<double> _resolvedSpeed(String? channelId) {
    return const EffectiveMediaPlaybackPreferences().speed(
      globalRaw: store.read('settings', 'global') ?? {},
      channelRaw: channelId == null ? null : store.overrides(channelId),
      software: SoftwarePlaybackDefaults.current(),
    );
  }

  /// Asks the shared cover store. This runtime no longer downloads images itself.
  Future<String?> _artwork(PodcastEpisode episode) async {
    final repository = artwork ?? MediaArtworkRepository.active;
    if (repository == null) return null;
    final channel = store.channel(episode.channelId);
    final snapshot = await repository.load(
      podcastArtworkRef(
        ownerKind: 'episode',
        ownerId: episode.id,
        primaryUrl: episode.imageUrl.isNotEmpty
            ? episode.imageUrl
            : channel?.imageUrl ?? '',
        fallbackUrl: episode.imageUrl.isNotEmpty ? channel?.imageUrl ?? '' : '',
      ),
      priority: ArtworkPriority.player,
    );
    return snapshot.localPath;
  }

  /// Lightweight playback row. [persist] writes a library adapter only for an
  /// episode the user is actually opening, downloading or learning. A queue
  /// of hundreds of episodes must not insert one library row each.
  Future<VideoItem> itemFor(
    PodcastEpisode episode, {
    String? parentId,
    bool standalone = false,
    String? mediaUrl,
    bool persist = true,
  }) async {
    final item = _projectEpisode(
      episode,
      parentId: parentId,
      standalone: standalone,
      mediaUrl: mediaUrl,
      lookupExisting: persist,
      lookupDownload: persist,
    );
    if (!persist) return item;
    return _commitAdapter(episode, item);
  }

  /// Uses the same media preference and downloaded variant as playback, with
  /// no adapter writes or source resolution, for the first player frame.
  VideoItem previewItemFor(PodcastEpisode episode) =>
      _projectEpisode(episode, lookupExisting: true, lookupDownload: true);

  VideoItem _projectEpisode(
    PodcastEpisode episode, {
    String? parentId,
    bool standalone = false,
    String? mediaUrl,
    bool lookupExisting = false,
    bool lookupDownload = false,
  }) {
    final channel = store.channel(episode.channelId)!;
    var media = mediaUrl == null
        ? episode.preferredMedia(
            store.effective(channel.id).text('mediaPreference'),
          )
        : episode.media.firstWhere((m) => m.url == mediaUrl);
    if (lookupDownload &&
        mediaUrl == null &&
        !controller.mediaStore.isDownloaded(episode.id, media.url)) {
      media =
          episode.media
              .where(
                (m) => controller.mediaStore.isDownloaded(episode.id, m.url),
              )
              .firstOrNull ??
          media;
    }
    final value = controller.state(episode.id);
    final existing = lookupExisting ? _existingAdapter(episode.id) : null;
    return VideoItem(
      id: existing?.id ?? episode.id,
      path: 'podcast:${episode.id}',
      title: episodeTitle(episode),
      durationMs: episode.durationMs,
      lastPositionMs: value.positionMs,
      lastUpdated: episode.discoveredMs,
      parentId: standalone ? parentId : collectionFor(channel.id)?.id,
      thumbnailPath: existing?.thumbnailPath,
      type: media.isVideo ? MediaType.video : MediaType.audio,
      sourceRef: MediaSourceRef(
        value: 'podcast:${episode.id}',
        kind: MediaSourceKind.podcastEpisode,
        originalValue: episode.link,
        podcast: PodcastEpisodeRef(
          channelId: channel.id,
          episodeId: episode.id,
          feedUrl: channel.feedUrl,
          mediaUrl: media.url,
        ),
      ),
    );
  }

  VideoItem? _existingAdapter(String episodeId) {
    final library = this.library;
    if (library == null) return null;
    final direct = library.getVideo(episodeId);
    if (direct != null &&
        direct.sourceRef?.podcast?.episodeId == episodeId &&
        !direct.isRecycled) {
      return direct;
    }
    return library.storageVideos
        .where(
          (item) =>
              item.sourceRef?.podcast?.episodeId == episodeId &&
              !item.isRecycled,
        )
        .firstOrNull;
  }

  /// Registers one interacted episode. The snapshot write is serialized by the
  /// library, but the caller does not wait for it before opening media.
  Future<VideoItem> _commitAdapter(
    PodcastEpisode episode,
    VideoItem item,
  ) async {
    final library = this.library;
    if (library == null) {
      persistedEpisodeIds.add(episode.id);
      return item;
    }
    final saved = await library.upsertPodcastEpisode(item, persist: false);
    saved.title = episodeTitle(episode);
    persistedEpisodeIds.add(episode.id);
    final override = persistAdaptersOverride;
    unawaited(override != null ? override() : library.persistPodcastAdapters());
    if (saved.thumbnailPath == null) {
      unawaited(
        _artwork(episode).then((path) {
          if (path != null) {
            saved.thumbnailPath = path;
            notifyListeners();
          }
        }),
      );
    }
    return saved;
  }

  VideoItem? _activeItem(String episodeId) {
    return playlist?.playlist
        .where((item) => item.sourceRef?.podcast?.episodeId == episodeId)
        .firstOrNull;
  }

  Future<void> play(
    PodcastEpisode episode, {
    List<PodcastEpisode>? queue,
    String? mediaUrl,
    bool standalone = false,
  }) async {
    final generation = ++_openingGeneration;
    if (queue != null) _openingCatalog = List<PodcastEpisode>.of(queue);
    openingEpisodeId = episode.id;
    failedEpisodeId = playbackError = null;
    notifyListeners();
    try {
      await _play(
        episode,
        queue: queue,
        mediaUrl: mediaUrl,
        standalone: standalone,
        generation: generation,
      );
    } catch (error) {
      if (generation == _openingGeneration) {
        failedEpisodeId = episode.id;
        playbackError = error is FormatException
            ? error.message
            : '暂时无法播放，请检查网络后重试。';
      }
      rethrow;
    } finally {
      if (generation == _openingGeneration) {
        openingEpisodeId = null;
        notifyListeners();
      }
    }
  }

  Future<void> _play(
    PodcastEpisode episode, {
    List<PodcastEpisode>? queue,
    String? mediaUrl,
    bool standalone = false,
    required int generation,
  }) async {
    final settings = store.effective(episode.channelId);
    if (standalone) {
      final item = await _commitAdapter(
        episode,
        _projectEpisode(
          episode,
          mediaUrl: mediaUrl,
          lookupExisting: true,
          lookupDownload: true,
        ),
      );
      if (generation != _openingGeneration) return;
      final before = [...?playlist?.playlist];
      playlist?.setPlaylist([item], currentItemId: item.id);
      _rememberQueue(
        [item],
        channelId: episode.channelId,
        custom: true,
        before: before,
        reason: 'standalone',
      );
      await _startPlayback(item, episode, settings, generation);
      return;
    }
    if (queue == null) {
      final active = _activeItem(episode.id);
      if (active != null) {
        final item = await _commitAdapter(
          episode,
          mediaUrl == null
              ? active
              : _projectEpisode(
                  episode,
                  mediaUrl: mediaUrl,
                  lookupExisting: true,
                  lookupDownload: true,
                ),
        );
        if (generation != _openingGeneration) return;
        await _startPlayback(item, episode, settings, generation);
        return;
      }
      final remembered = _openingCatalog;
      if (remembered != null &&
          remembered.any((item) => item.id == episode.id)) {
        queue = remembered;
      } else if (playlist?.playlist.isNotEmpty == true) {
        // A retry or resume must not replace the live queue with one episode.
        if (generation == _openingGeneration) {
          failedEpisodeId = episode.id;
          playbackError = '这个节目不在当前队列中';
          notifyListeners();
        }
        return;
      } else {
        queue = [episode];
        standalone = true;
      }
    }
    if (standalone) {
      await _play(
        episode,
        mediaUrl: mediaUrl,
        standalone: true,
        generation: generation,
      );
      return;
    }
    final source = queue;
    final entries = <VideoItem>[];
    for (final candidate in source.where(
      (candidate) =>
          candidate.id == episode.id ||
          !settings.flag('skipPlayed') ||
          !controller.state(candidate.id).played,
    )) {
      if (generation != _openingGeneration) return;
      entries.add(
        _projectEpisode(
          candidate,
          mediaUrl: candidate.id == episode.id ? mediaUrl : null,
          lookupExisting: candidate.id == episode.id,
          lookupDownload: candidate.id == episode.id,
        ),
      );
    }
    if (!entries.any((e) => e.sourceRef?.podcast?.episodeId == episode.id)) {
      entries.add(
        _projectEpisode(
          episode,
          mediaUrl: mediaUrl,
          lookupExisting: true,
          lookupDownload: true,
        ),
      );
    }
    if (generation != _openingGeneration) return;
    final index = entries.indexWhere(
      (e) => e.sourceRef?.podcast?.episodeId == episode.id,
    );
    final item = await _commitAdapter(episode, entries[index]);
    entries[index] = item;
    if (generation != _openingGeneration) return;
    final before = [...?playlist?.playlist];
    playlist?.setPlaylist(entries, currentItemId: item.id);
    _rememberQueue(
      entries,
      channelId: episode.channelId,
      custom: false,
      before: before,
      reason: 'catalog',
    );
    await _startPlayback(item, episode, settings, generation);
  }

  Future<void> _startPlayback(
    VideoItem item,
    PodcastEpisode episode,
    PodcastPreferences settings,
    int generation,
  ) async {
    final start = controller.state(episode.id).played
        ? settings.integer('skipIntro') * 1000
        : item.lastPositionMs == 0
        ? settings.integer('skipIntro') * 1000
        : item.lastPositionMs;
    await playback?.play(item, startPosition: Duration(milliseconds: start));
    if (generation == _openingGeneration &&
        playback?.currentItem?.id == item.id &&
        playback?.state == PlaybackState.error) {
      throw const FormatException('暂时无法播放这个节目，请检查网络后重试。');
    }
    if (generation == _openingGeneration &&
        playback?.currentItem?.id == item.id) {
      await playback?.setPlaybackSpeed(_resolvedSpeed(episode.channelId).value);
    }
  }

  Future<void> addToQueue(PodcastEpisode episode) async {
    final item = await itemFor(episode);
    playlist?.addToPlaybackQueue([item]);
    _rememberQueue(playlist?.playlist ?? [item], custom: true);
    notifyListeners();
  }

  void rememberActiveQueue() {
    final queue = playlist;
    if (queue != null && _tracksQueue(queue)) {
      _rememberQueue(queue.playlist, custom: true);
      notifyListeners();
    }
  }

  void removeFromQueue(String episodeId) {
    final item = playlist?.playlist
        .where((item) => item.sourceRef?.podcast?.episodeId == episodeId)
        .firstOrNull;
    if (item != null) removeQueueItem(item.id);
  }

  /// Shared player lists can also remove non-podcast members of a mixed queue.
  bool removeQueueItem(String mediaId) {
    final queue = playlist;
    if (queue == null || queue.indexOfItem(mediaId) < 0) return false;
    final remember = _tracksQueue(queue);
    queue.removeFromQueue(mediaId);
    if (remember) _rememberQueue(queue.playlist, custom: true);
    notifyListeners();
    return true;
  }

  bool _tracksQueue(PlaylistManager queue) {
    final ids = queue.playlist.map((item) => item.id).toSet();
    final saved = store.read('queue', 'current')?['entries'];
    final savedIds = saved is List
        ? saved.whereType<Map>().map((entry) => entry['mediaId']).toSet()
        : const <Object?>{};
    return queue.playlist.any((item) => item.sourceRef?.podcast != null) ||
        (savedIds.isNotEmpty &&
            savedIds.length == ids.length &&
            savedIds.every(ids.contains));
  }

  bool reorderQueueItems(List<String> mediaIds) {
    final queue = playlist;
    if (queue == null) return false;
    final remember = _tracksQueue(queue);
    if (!queue.reorderQueue(mediaIds)) return false;
    if (remember) {
      _rememberQueue(queue.playlist, custom: true, reason: 'reorder');
    }
    notifyListeners();
    return true;
  }

  bool resetQueueOrder() {
    final queue = playlist;
    if (queue == null) return false;
    final remember = _tracksQueue(queue);
    if (!queue.resetQueueOrder()) return false;
    if (remember) {
      _rememberQueue(queue.playlist, custom: true, reason: 'reset-order');
    }
    notifyListeners();
    return true;
  }

  /// Saves podcast ids for the queue page and the full source list so a mixed
  /// queue is not reduced to podcasts on the next restore.
  void _rememberQueue(
    List<VideoItem> items, {
    String? channelId,
    required bool custom,
    List<VideoItem>? before,
    String reason = 'update',
  }) {
    final previous = store.read('queue', 'current') ?? {};
    final currentId = playback?.currentItem?.id;
    final beforeIds = (before ?? const <VideoItem>[])
        .map((item) => item.id)
        .join(',');
    final afterIds = items.map((item) => item.id).join(',');
    if (before != null && beforeIds != afterIds) {
      debugPrint(
        'podcast queue $reason '
        'len ${before.length}->${items.length} '
        'current=$currentId '
        'before=${_queueDigest(before)} after=${_queueDigest(items)}',
      );
    }
    store.write('queue', 'current', {
      'version': 2,
      'ids': items
          .where((item) => item.sourceRef?.podcast != null)
          .map((item) => item.sourceRef!.podcast!.episodeId)
          .toList(),
      'entries': [
        for (final item in items)
          if (item.sourceRef?.podcast != null)
            {
              'kind': 'podcast',
              'episodeId': item.sourceRef!.podcast!.episodeId,
              'channelId': item.sourceRef!.podcast!.channelId,
              'mediaId': item.id,
              'mediaUrl': item.sourceRef!.podcast!.mediaUrl,
            }
          else
            {'kind': 'media', 'mediaId': item.id},
      ],
      'currentMediaId': currentId ?? previous['currentMediaId'],
      'channelId': channelId ?? previous['channelId'],
      'custom': custom,
    });
  }

  String _queueDigest(List<VideoItem> items) {
    String idOf(VideoItem item) =>
        item.sourceRef?.podcast?.episodeId ?? item.id;
    if (items.length <= 6) return items.map(idOf).join(',');
    final head = items.take(3).map(idOf).join(',');
    final tail = items.skip(items.length - 3).map(idOf).join(',');
    return '$head…$tail';
  }

  /// Rebuilds the saved queue after the catalog is open. A missing row is
  /// skipped; it must not wipe the rest of the queue.
  Future<bool> restoreSavedQueue({String? expectedMediaId}) async {
    if (!ready || playlist == null) return false;
    final record = store.read('queue', 'current');
    if (record == null) return false;
    final items = _itemsFromQueueRecord(record);
    if (items.isEmpty) return false;
    if (expectedMediaId != null &&
        !items.any((item) => item.id == expectedMediaId) &&
        !items.any(
          (item) => item.sourceRef?.podcast?.episodeId == expectedMediaId,
        )) {
      return false;
    }
    final current = items.any((item) => item.id == expectedMediaId)
        ? expectedMediaId
        : items.any(
            (item) => item.sourceRef?.podcast?.episodeId == expectedMediaId,
          )
        ? items
              .firstWhere(
                (item) => item.sourceRef?.podcast?.episodeId == expectedMediaId,
              )
              .id
        : record['currentMediaId'] as String?;
    playlist!.setPlaylist(items, currentItemId: current ?? items.first.id);
    return true;
  }

  List<VideoItem> _itemsFromQueueRecord(Map<String, dynamic> record) {
    final entries = record['entries'];
    final items = <VideoItem>[];
    if (entries is List && entries.isNotEmpty) {
      for (final raw in entries) {
        if (raw is! Map) continue;
        final row = Map<String, dynamic>.from(raw);
        final item = _itemFromQueueEntry(row);
        if (item != null) items.add(item);
      }
      return items;
    }
    for (final raw in record['ids'] as List? ?? const []) {
      final episode = store.episode('$raw');
      if (episode == null) continue;
      items.add(
        _existingAdapter(episode.id) ??
            _projectEpisode(episode, lookupDownload: false),
      );
    }
    return items;
  }

  VideoItem? _itemFromQueueEntry(Map<String, dynamic> row) {
    if (row['kind'] == 'media') {
      final id = row['mediaId'];
      if (id is! String || id.isEmpty) return null;
      return library?.getVideo(id);
    }
    final episodeId = row['episodeId'];
    if (episodeId is! String || episodeId.isEmpty) return null;
    final savedId = row['mediaId'];
    if (savedId is String) {
      final saved = library?.getVideo(savedId);
      if (saved != null) return saved;
    }
    final episode = store.episode(episodeId);
    if (episode == null) return null;
    final mediaUrl = row['mediaUrl'];
    return _existingAdapter(episode.id) ??
        _projectEpisode(
          episode,
          mediaUrl: mediaUrl is String && mediaUrl.isNotEmpty ? mediaUrl : null,
          lookupDownload: false,
        );
  }

  /// Moves podcast members inside the live queue and writes the full entry
  /// list. Local files sitting between them keep their places.
  void reorderPodcastQueue(List<String> episodeIds) {
    final current = [...?playlist?.playbackQueue];
    final rank = <String, int>{
      for (var i = 0; i < episodeIds.length; i++) episodeIds[i]: i,
    };
    if (current.isEmpty) {
      final rebuilt = <VideoItem>[];
      for (final id in episodeIds) {
        final episode = store.episode(id);
        if (episode == null) continue;
        rebuilt.add(
          _existingAdapter(episode.id) ??
              _projectEpisode(episode, lookupDownload: false),
        );
      }
      playlist?.setPlaylist(rebuilt, currentItemId: playback?.currentItem?.id);
      _rememberQueue(rebuilt, custom: true, reason: 'reorder');
      notifyListeners();
      return;
    }
    final result = [...current];
    final indexes = <int>[];
    for (var i = 0; i < result.length; i++) {
      final id = result[i].sourceRef?.podcast?.episodeId;
      if (id != null && rank.containsKey(id)) indexes.add(i);
    }
    final members = indexes.map((index) => result[index]).toList()
      ..sort(
        (a, b) => rank[a.sourceRef!.podcast!.episodeId]!.compareTo(
          rank[b.sourceRef!.podcast!.episodeId]!,
        ),
      );
    for (var i = 0; i < indexes.length; i++) {
      result[indexes[i]] = members[i];
    }
    reorderQueueItems(result.map((item) => item.id).toList());
  }

  /// Podcast rows in the live queue, in playback order. The saved record is
  /// only a fallback before a session exists.
  List<PodcastEpisode> queueEpisodes() {
    final live = playlist?.playbackQueue ?? const <VideoItem>[];
    if (live.isNotEmpty) {
      return [
        for (final item in live)
          if (item.sourceRef?.podcast?.episodeId != null)
            ?store.episode(item.sourceRef!.podcast!.episodeId),
      ];
    }
    final record = store.read('queue', 'current');
    if (record == null) return const [];
    return [
      for (final item in _itemsFromQueueRecord(record))
        if (item.sourceRef?.podcast?.episodeId != null)
          ?store.episode(item.sourceRef!.podcast!.episodeId),
    ];
  }

  /// Reorders podcast members already in a queue that still follows this channel.
  /// A queue the user edited by hand is left alone, and new episodes are not inserted.
  void syncBoundQueue(String channelId) {
    final record = store.read('queue', 'current');
    if (record == null || record['custom'] == true) return;
    if (record['channelId'] != channelId) return;
    final currentItems = playlist?.playlist;
    if (currentItems == null || currentItems.isEmpty) return;
    final order = store.manualOrder(channelId);
    final rank = <String, int>{
      for (var i = 0; i < order.ids.length; i++) order.ids[i]: i,
    };
    final result = [...currentItems];
    final podcastIndexes = <int>[];
    for (var i = 0; i < result.length; i++) {
      if (result[i].sourceRef?.podcast?.channelId == channelId) {
        podcastIndexes.add(i);
      }
    }
    final members = podcastIndexes.map((index) => result[index]).toList()
      ..sort((a, b) {
        final left = rank[a.sourceRef!.podcast!.episodeId] ?? 1 << 30;
        final right = rank[b.sourceRef!.podcast!.episodeId] ?? 1 << 30;
        return left.compareTo(right);
      });
    for (var i = 0; i < podcastIndexes.length; i++) {
      result[podcastIndexes[i]] = members[i];
    }
    playlist?.setPlaylist(result, currentItemId: playback?.currentItem?.id);
    _rememberQueue(result, channelId: channelId, custom: false);
  }

  Future<Uri> resolvePlayback(VideoItem item) async {
    final ref = item.sourceRef!.podcast!;
    var episode = store.episode(ref.episodeId);
    if (episode == null) {
      final resolution = await controller.client.resolve(ref.feedUrl);
      final feed = controller.client.parser.parse(
        (await controller.client.http.get(
          resolution.feed.channel.feedUrl,
        )).bytes,
        resolution.feed.channel.feedUrl,
        channelId: ref.channelId,
      );
      store.mergeFeed(feed, initial: true);
      episode = store.episode(ref.episodeId);
    }
    episode ??= PodcastEpisode(
      id: ref.episodeId,
      channelId: ref.channelId,
      title: item.title,
      media: [
        PodcastMedia(
          url: ref.mediaUrl,
          mimeType: item.type == MediaType.video ? 'video/mp4' : 'audio/mpeg',
        ),
      ],
    );
    final media =
        episode.media.where((m) => m.url == ref.mediaUrl).firstOrNull ??
        episode.preferredMedia(
          store.effective(ref.channelId).text('mediaPreference'),
        );
    if (item.thumbnailPath == null) {
      unawaited(
        _artwork(episode).then((path) {
          if (path != null) {
            item.thumbnailPath = path;
            notifyListeners();
          }
        }),
      );
    }
    return controller.mediaStore.playbackUri(episode, media);
  }

  VideoItem? restoreSource(String path, String? itemId) {
    if (_shuttingDown || !ready || !path.startsWith('podcast:')) return null;
    final episode = store.episode(path.substring('podcast:'.length));
    if (episode == null || store.channel(episode.channelId) == null) {
      return null;
    }
    final item = _projectEpisode(
      episode,
      lookupExisting: true,
      lookupDownload: true,
    );
    if (itemId == null || item.id == itemId) return item;
    return VideoItem.fromJson(item.toJson()..['id'] = itemId);
  }

  void _progressChanged(VideoItem item, int positionMs) {
    if (item.sourceRef?.podcast == null || !ready) return;
    controller.savePlaybackProgress(
      item.sourceRef!.podcast!.episodeId,
      positionMs,
      lastPlayedMs: DateTime.now().millisecondsSinceEpoch,
      debounced: true,
    );
  }

  void _playbackChanged() {
    if (!ready || playback == null) return;
    final item = playback!.currentItem;
    controller.mediaStore.protectedEpisodes
      ..clear()
      ..addAll([
        ..._learningUses.keys,
        if (item?.sourceRef?.podcast != null)
          item!.sourceRef!.podcast!.episodeId,
      ]);
    if (item?.sourceRef?.podcast == null) {
      _outroSkipped = null;
      return;
    }
    final activity = library?.mediaActivity(item!.id);
    if (activity?.completed == true &&
        !controller.state(item!.sourceRef!.podcast!.episodeId).played) {
      controller.updateState(item.sourceRef!.podcast!.episodeId, (s) {
        s.played = true;
        s.playedAtMs = DateTime.now().millisecondsSinceEpoch;
      });
    }
    final outro =
        store
            .effective(item!.sourceRef!.podcast!.channelId)
            .integer('skipOutro') *
        1000;
    if (outro > 0 &&
        playback!.isPlaying &&
        playback!.duration.inMilliseconds > outro &&
        playback!.position.inMilliseconds >=
            playback!.duration.inMilliseconds - outro &&
        _outroSkipped != item.id) {
      _outroSkipped = item.id;
      unawaited(playback!.seekTo(playback!.duration));
    }
  }

  Future<String> materialize(
    VideoItem item, {
    bool requireVideo = false,
    bool Function()? isCancelled,
    Future<void>? cancelSignal,
    void Function(PodcastTransferProgress)? onProgress,
  }) async {
    if (_shuttingDown) {
      throw StateError('播客服务正在关闭');
    }
    final episode = store.episode(item.sourceRef!.podcast!.episodeId);
    if (episode == null) throw const FormatException('节目尚未载入');
    final ref = item.sourceRef!.podcast!;
    final active = store.read('download', episode.id);
    final activeUrl =
        active != null &&
            active['status'] != PodcastDownloadStatus.completed.name &&
            active['status'] != PodcastDownloadStatus.failed.name
        ? active['mediaUrl'] as String?
        : null;
    final choice = resolveTranscriptionSource(
      episode: episode,
      selectedUrl: ref.mediaUrl,
      isComplete: (url) => controller.mediaStore.isComplete(episode.id, url),
      activeDownloadUrl: activeUrl,
    );
    final media = requireVideo
        ? episode.media
                  .where(
                    (m) =>
                        m.isVideo &&
                        !m.isStreamManifest &&
                        m.url == ref.mediaUrl,
                  )
                  .firstOrNull ??
              episode.media
                  .where((m) => m.isVideo && !m.isStreamManifest)
                  .firstOrNull
        : choice.media;
    if (media == null || !requireVideo && choice.waiting) {
      throw FormatException(choice.reason ?? '这个来源不能生成字幕');
    }
    // Automatically advanced queue entries are lightweight projections. A
    // requested learning operation registers only this episode so generated
    // subtitles retain their normal library association after playback moves on.
    if (library != null && adapterFor(episode.id) == null) {
      await _commitAdapter(episode, item);
    }
    _learningUses.update(episode.id, (count) => count + 1, ifAbsent: () => 1);
    controller.mediaStore.protectedEpisodes.add(episode.id);
    controller.mediaStore.retainForUse(episode.id, _learningOwner);
    _learningLeaseTimer ??= Timer.periodic(const Duration(minutes: 1), (_) {
      for (final id in _learningUses.keys) {
        controller.mediaStore.retainForUse(id, _learningOwner);
      }
    });
    try {
      final file = await controller.prepareLocalMedia(
        episode,
        media,
        isCancelled: isCancelled,
        cancelSignal: cancelSignal,
        onProgress: onProgress,
      );
      final manifest = controller.mediaStore.manifest(episode.id, media.url);
      _sourceIdentities[file.path] = podcastHash(
        '${manifest['revision']}|${manifest['etag'] ?? ''}|${manifest['total']}',
      );
      PodcastPlaybackHooks.sourceIdentity ??= (path) => _sourceIdentities[path];
      try {
        await MediaCacheHooks.publish?.call(await cachedVariants(item));
      } catch (_) {
        /* Feature output remains usable if the optional index is unavailable. */
      }
      return file.path;
    } catch (_) {
      releaseMaterialized(item);
      rethrow;
    }
  }

  Future<List<CacheVariant>> cachedVariants(VideoItem item) async {
    final ref = item.sourceRef?.podcast;
    if (ref == null || _shuttingDown) return [];
    final episode = store.episode(ref.episodeId);
    if (episode == null) return [];
    final variants = <CacheVariant>[];
    for (final media in episode.media) {
      final file = controller.mediaStore.localFileFor(episode.id, media.url);
      if (file == null) continue;
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file || stat.size <= 0) continue;
      final manifest = controller.mediaStore.manifest(episode.id, media.url);
      final source = CacheSource(
        ref: item.sourceRef!.copyWith(
          podcast: PodcastEpisodeRef(
            channelId: ref.channelId,
            episodeId: ref.episodeId,
            feedUrl: ref.feedUrl,
            mediaUrl: media.url,
          ),
        ),
        itemId: item.id,
        title: item.title,
        thumbnail: item.thumbnailPath,
        kind: media.isVideo ? MediaType.video : MediaType.audio,
        durationMs: item.durationMs,
      );
      variants.add(
        CacheVariant(
          source: source,
          quality: CacheQuality(
            id: 'original',
            label: media.isVideo ? '原视频' : '原音质',
            revision:
                '${manifest['revision']}|${manifest['etag'] ?? ''}|${manifest['total']}',
          ),
          path: file.path,
          bytes: stat.size,
          createdAt: stat.modified.millisecondsSinceEpoch,
        ),
      );
    }
    return variants;
  }

  void releaseMaterialized(VideoItem item) {
    final id = item.sourceRef?.podcast?.episodeId;
    if (id == null) return;
    final count = _learningUses[id] ?? 0;
    if (count > 1) {
      _learningUses[id] = count - 1;
    } else {
      _learningUses.remove(id);
      if (!_shuttingDown) {
        controller.mediaStore.releaseForUse(id, _learningOwner);
      }
      if (playback?.currentItem?.sourceRef?.podcast?.episodeId != id) {
        controller.mediaStore.protectedEpisodes.remove(id);
      }
      if (_learningUses.isEmpty) {
        _learningLeaseTimer?.cancel();
        _learningLeaseTimer = null;
      }
    }
  }

  final Map<String, Future<void>> _preparingLearning = {};
  final Map<String, PodcastOfficialTranscript> officialTranscript = {};

  Future<void> retryOfficialTranscript(PodcastEpisode episode) {
    officialTranscript[episode.id] = PodcastOfficialTranscript.loading;
    notifyListeners();
    return prepareLearning(episode);
  }

  Future<void> prepareLearning(PodcastEpisode episode) =>
      _preparingLearning.putIfAbsent(
        episode.id,
        () => _prepareLearning(
          episode,
        ).whenComplete(() => _preparingLearning.remove(episode.id)),
      );

  Future<void> _prepareLearning(PodcastEpisode episode) async {
    final item = adapterFor(episode.id);
    if (item == null) return;
    final generation = _openingGeneration;
    bool stillCurrent() =>
        generation == _openingGeneration &&
        (playback?.currentItem == null ||
            playback?.currentItem?.sourceRef?.podcast?.episodeId == episode.id);
    var changed = false;
    if (episode.chaptersUrl != null &&
        episode.chaptersUrl!.isNotEmpty &&
        item.chapters.isEmpty) {
      try {
        final response = await controller.client.http.get(
          episode.chaptersUrl!,
          maxBytes: 4 * 1024 * 1024,
        );
        if (!stillCurrent()) return;
        final rows =
            (jsonDecode(utf8.decode(response.bytes)) as Map)['chapters']
                as List? ??
            [];
        item.chapters = MediaChapter.normalize(
          rows.whereType<Map>().map(
            (j) => MediaChapter(
              title: (j['title'] ?? '').toString(),
              startMs: ((j['startTime'] as num? ?? 0) * 1000).round(),
              endMs: ((j['endTime'] as num? ?? 0) * 1000).round(),
            ),
          ),
          durationMs: item.durationMs,
        );
        changed = item.chapters.isNotEmpty;
      } catch (_) {
        /* Playback stays available if supplementary metadata fails. */
      }
    }
    if (item.subtitlePath == null) {
      officialTranscript[episode.id] = episode.transcripts.isEmpty
          ? PodcastOfficialTranscript.absent
          : PodcastOfficialTranscript.loading;
      notifyListeners();
      var loaded = false;
      var failed = episode.transcripts.isNotEmpty;
      for (final transcript in episode.transcripts) {
        final type = transcript.type.toLowerCase();
        final isJson =
            type.contains('json') ||
            Uri.tryParse(transcript.url)?.path.endsWith('.json') == true;
        final extension =
            type.contains('vtt') ||
                transcript.url.split('?').first.endsWith('.vtt')
            ? '.vtt'
            : type.contains('srt') ||
                  type.contains('subrip') ||
                  transcript.url.split('?').first.endsWith('.srt')
            ? '.srt'
            : isJson
            ? '.srt'
            : null;
        if (extension == null) continue;
        try {
          final response = await controller.client.http.get(
            transcript.url,
            maxBytes: 16 * 1024 * 1024,
          );
          if (!stillCurrent()) return;
          final file = File(
            p.join(
              p.dirname(store.path),
              'transcripts',
              '${episode.id}$extension',
            ),
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(
            isJson
                ? utf8.encode(
                    podcastJsonTranscriptToSrt(utf8.decode(response.bytes)),
                  )
                : response.bytes,
            flush: true,
          );
          if (await file.length() == 0) continue;
          // A subtitle the user already chose must win over a late official file.
          if (item.subtitlePath != null) {
            loaded = true;
            failed = false;
            break;
          }
          item.subtitlePath = file.path;
          changed = true;
          loaded = true;
          failed = false;
          break;
        } catch (_) {
          /* Try the next timed transcript. */
        }
      }
      officialTranscript[episode.id] = loaded
          ? PodcastOfficialTranscript.loaded
          : failed
          ? PodcastOfficialTranscript.failed
          : PodcastOfficialTranscript.absent;
      notifyListeners();
    }
    if (changed) {
      // Chapters can stay on the adapter. A late transcript must not retarget
      // the episode the user has already switched to.
      if (!stillCurrent()) return;
      await library?.persistPodcastAdapters();
      if (!stillCurrent()) return;
      await playback?.refreshAssociatedSubtitles(item);
      notifyListeners();
    }
  }

  VideoItem? adapterFor(String episodeId) =>
      library?.getVideo(episodeId) ??
      library?.storageVideos
          .where(
            (item) =>
                item.sourceRef?.podcast?.episodeId == episodeId &&
                !item.isRecycled,
          )
          .firstOrNull;

  Future<void> refresh({String trigger = 'timer', bool manual = false}) async {
    if (!ready) return;
    await controller.refreshAll(manual: manual, trigger: trigger);
    try {
      await notifications.deliver(store);
    } catch (_) {
      /* In-page updates still work when notifications are unavailable. */
    }
    await controller.cleanup();
    unawaited(controller.pumpDownloads());
  }

  Future<void> setting(String? channelId, String key, Object? value) async {
    if (key == 'notify' && value == true) {
      if (!await notifications.requestPermission()) {
        throw const FormatException('系统通知权限尚未开启，可以在系统设置中允许通知');
      }
    }
    store.setSetting(channelId, key, value);
    if (['backgroundRefresh', 'pauseAllUpdates'].contains(key)) {
      try {
        await configurePodcastBackground(
          p.dirname(store.path),
          store.preferences.flag('backgroundRefresh') &&
              !store.preferences.flag('pauseAllUpdates'),
        );
      } catch (_) {}
    }
    notifyListeners();
    unawaited(controller.pumpDownloads());
  }

  void resetOverrides(String channelId) {
    store.write('settings', channelId, {});
    store.write('settingClock', channelId, {
      'updatedMs': DateTime.now().millisecondsSinceEpoch,
    });
    notifyListeners();
  }

  Future<void> flushPreferencesForTrial() async {
    await _initializing;
  }

  Future<void> reloadPreferencesForTrial() async {
    if (!ready) return;
    await configurePodcastBackground(
      p.dirname(store.path),
      store.preferences.flag('backgroundRefresh') &&
          !store.preferences.flag('pauseAllUpdates'),
    );
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!ready) return;
    if (state == AppLifecycleState.resumed) {
      controller.reload();
      unawaited(refresh(trigger: 'resume'));
      unawaited(controller.pumpDownloads());
    } else {
      controller.flushStates();
    }
  }

  Future<void> prepareStorageMigration() async {
    for (final pending in [_preparingCardArtwork, _initializing]) {
      if (pending == null) continue;
      try {
        await pending;
      } catch (_) {}
    }
    if (ready || artwork != null) await shutdown();
  }

  Future<void> shutdown() async {
    _shuttingDown = true;
    _learningLeaseTimer?.cancel();
    if (ready) {
      for (final id in _learningUses.keys) {
        controller.mediaStore.releaseForUse(id, _learningOwner);
      }
    }
    _refreshTimer?.cancel();
    _progressTimer?.cancel();
    await _connectivity?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    library?.removeProgressObserver(_progressChanged);
    library?.removeListener(_libraryChanged);
    library?.removeRenameObserver(_itemRenamed);
    playback?.removeListener(_playbackChanged);
    if (ready) {
      await controller.close();
      store.close();
      _controller = null;
    }
    artwork?.close();
    artwork = null;
    _cardChannels.clear();
    _preparingCardArtwork = null;
    _initializing = null;
  }
}
