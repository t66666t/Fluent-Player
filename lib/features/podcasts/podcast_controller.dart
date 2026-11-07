import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import '../../services/network/network_recovery.dart';
import '../progress_sync/folder_transfer_disk_space.dart' as disk;
import 'podcast_client.dart';
import 'podcast_media_store.dart';
import 'podcast_models.dart';
import 'podcast_source_policy.dart';
import 'podcast_store.dart';
import 'podcast_preview_loader.dart';
import 'podcast_transfer.dart';

class PodcastController extends ChangeNotifier {
  PodcastController({
    required this.store,
    required this.client,
    required this.mediaStore,
    this.readConnectivity,
  });
  final PodcastStore store;
  final PodcastClient client;
  final PodcastMediaStore mediaStore;
  final Future<List<ConnectivityResult>> Function()? readConnectivity;
  late final previews = PodcastPreviewLoader(
    client: client,
    readConnectivity: readConnectivity,
  );
  final String _owner = podcastHash(
    '${DateTime.now().microsecondsSinceEpoch}|${identityHashCode(Object())}',
  );
  final Set<String> refreshing = {}, _running = {};
  final Map<String, int> _reservations = {};
  final Map<String, PodcastTransferProgress> _transfers = {};
  final Map<String, Completer<void>> _downloadCancels = {};
  final Map<String, int> _preparationConsumers = {};
  final Map<String, int> _taskEpoch = {};
  final Map<String, Future<void>> _jobs = {};
  bool _dispatching = false;
  bool _redispatch = false;
  Future<void>? _dispatchFuture;
  Duration? _pendingBudget;
  final List<Future<void>> _budgetFutures = [];
  DateTime Function() now = DateTime.now;
  final Map<String, Timer> _stateWrites = {};
  final Map<String, PodcastEpisodeState> _states = {};

  /// Byte progress. Catalog pages listen to [ChangeNotifier] instead, so a
  /// 200 ms tick does not rebuild the episode list.
  final ValueNotifier<int> transferTick = ValueNotifier<int>(0);
  Map<String, PodcastDownload>? _downloadIndex;

  void Function(String, PodcastEpisodeState)? onUserStateChanged;
  bool _closed = false;
  // Reconnection notifications use this snapshot. Transfers use actual HTTP
  // results and never gate admission on a radio type or a detector response.
  List<ConnectivityResult> connectivity = const [];

  List<PodcastDownload> get downloads => _downloadsById().values.toList();

  /// One lookup per row. Building a visible row must not walk every download.
  PodcastDownload? downloadFor(String episodeId) => _downloadsById()[episodeId];

  Map<String, PodcastDownload> _downloadsById() {
    return _downloadIndex ??= {
      for (final item in store.list('download').map(PodcastDownload.fromJson))
        item.episodeId: item,
    };
  }

  @override
  void notifyListeners() {
    _downloadIndex = null;
    super.notifyListeners();
  }

  PodcastTransferProgress? transferProgress(String episodeId) =>
      _transfers[episodeId];
  List<PodcastChannel> get channels =>
      store.channels.where((c) => c.active).toList();
  PodcastEpisodeState state(String id) =>
      _states.putIfAbsent(id, () => store.state(id));
  int newCount(String channelId) {
    final channel = store.channel(channelId);
    if (channel == null || !store.effective(channelId).flag('badges')) return 0;
    return store.countEpisodes(
      channelId,
      newSince: channel.seenMs,
      unplayed: true,
    );
  }

  int unheardCount(String channelId) =>
      store.countEpisodes(channelId, unplayed: true);
  void reload() {
    _states.clear();
    store.invalidateCatalogCache();
    notifyListeners();
  }

  void markSeen(String channelId) {
    final channel = store.channel(channelId);
    if (channel == null) return;
    channel.seenMs = DateTime.now().millisecondsSinceEpoch;
    store.write('channel', channelId, channel.toJson());
    notifyListeners();
  }

  void updateState(
    String id,
    void Function(PodcastEpisodeState) update, {
    bool debounced = false,
    bool notify = true,
    bool project = true,
    bool forcePlaybackUpdate = false,
  }) {
    final value = state(id);
    final bucketBefore = value.listenBucket;
    final wasFavorite = value.favorite;
    final positionBefore = value.positionMs;
    final playedBefore = value.played;
    final lastPlayedBefore = value.lastPlayedMs;
    final playedAtBefore = value.playedAtMs;
    update(value);
    value.updatedMs = DateTime.now().millisecondsSinceEpoch;
    if (forcePlaybackUpdate ||
        value.positionMs != positionBefore ||
        value.played != playedBefore ||
        value.lastPlayedMs != lastPlayedBefore ||
        value.playedAtMs != playedAtBefore) {
      value.playbackUpdatedMs = value.updatedMs;
    }
    if (wasFavorite != value.favorite) {
      value.favoriteUpdatedMs = value.updatedMs;
    }
    // A tick inside 进行中 must not rebuild the channel query. Crossing into
    // or out of that bucket has to hit the database immediately, or the
    // 未听 / 进行中 filters keep the row until some later refresh.
    final crossed =
        bucketBefore != value.listenBucket || wasFavorite != value.favorite;
    _stateWrites.remove(id)?.cancel();
    if (debounced && !crossed) {
      _stateWrites[id] = Timer(const Duration(seconds: 2), () {
        _stateWrites.remove(id);
        if (!_closed) store.saveState(id, value);
      });
    } else {
      store.saveState(id, value);
      if (project) onUserStateChanged?.call(id, value);
      if (notify) notifyListeners();
    }
  }

  /// Playback bookmarks and listened history are independent. Only an
  /// explicit completion value (for example a synced user change) replaces
  /// the listened flag; replaying or leaving an episode only moves its bookmark.
  void savePlaybackProgress(
    String id,
    int positionMs, {
    bool? completed,
    int? lastPlayedMs,
    bool debounced = false,
  }) {
    updateState(
      id,
      (state) {
        state.positionMs = positionMs;
        if (completed != null) {
          if (completed && !state.played) {
            state.playedAtMs =
                lastPlayedMs ?? DateTime.now().millisecondsSinceEpoch;
          } else if (!completed) {
            state.playedAtMs = 0;
          }
          state.played = completed;
        }
        if (lastPlayedMs != null) state.lastPlayedMs = lastPlayedMs;
      },
      debounced: debounced,
      project: false,
    );
  }

  /// Single and batch listened changes share one write. Either direction
  /// clears the resume position: heard episodes restart, and marking unheard
  /// returns an in-progress episode to the unheard bucket instead of leaving
  /// it started. Unheard does not invent a new position.
  void setPlayed(
    String id,
    bool played, {
    bool notify = true,
    bool project = true,
  }) {
    updateState(
      id,
      (state) {
        state.played = played;
        state.playedAtMs = played ? DateTime.now().millisecondsSinceEpoch : 0;
        state.positionMs = 0;
      },
      notify: notify,
      project: project,
      forcePlaybackUpdate: true,
    );
  }

  /// One rebuild after a batch of silent writes.
  void publish() => notifyListeners();

  void flushStates() {
    for (final e in _stateWrites.entries) {
      e.value.cancel();
      store.saveState(e.key, state(e.key));
    }
    _stateWrites.clear();
  }

  bool _lease(String key, [int seconds = 90]) => store.transaction(() {
    final existing = store.read('lease', key);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (existing != null &&
        existing['owner'] != _owner &&
        (existing['until'] as int) > now) {
      return false;
    }
    store.write('lease', key, {'owner': _owner, 'until': now + seconds * 1000});
    return true;
  });
  void _release(String key) {
    if (store.read('lease', key)?['owner'] == _owner) {
      store.remove('lease', key);
    }
  }

  Future<PodcastChannel> subscribe(PodcastFeed feed) async {
    final canonical = podcastCanonicalUrl(feed.channel.feedUrl);
    final existing = store.channels
        .where(
          (c) =>
              podcastCanonicalUrl(c.feedUrl) == canonical ||
              c.aliases.contains(feed.channel.feedUrl) ||
              (feed.channel.guid.isNotEmpty && c.guid == feed.channel.guid),
        )
        .firstOrNull;
    if (existing != null) {
      existing.active = true;
      store.write('channel', existing.id, existing.toJson());
      if (feed.channel.id == existing.id) store.mergeFeed(feed);
      notifyListeners();
      return existing;
    }
    store.mergeFeed(feed, initial: true);
    notifyListeners();
    return store.channel(feed.channel.id)!;
  }

  Future<void> refreshAll({
    bool manual = false,
    String trigger = 'timer',
    Duration? budget,
  }) async {
    final global = store.preferences;
    if (!manual && global.flag('pauseAllUpdates')) return;
    final started = DateTime.now();
    for (final channel in channels) {
      if (_closed ||
          (budget != null && DateTime.now().difference(started) >= budget)) {
        break;
      }
      final settings = store.effective(channel.id);
      if (!manual && !settings.flag('autoRefresh')) continue;
      if (!manual && trigger == 'launch' && !settings.flag('onLaunch')) {
        continue;
      }
      if (!manual && trigger == 'resume' && !settings.flag('onResume')) {
        continue;
      }
      if (!manual && trigger == 'network' && !settings.flag('onReconnect')) {
        continue;
      }
      final interval = trigger == 'timer'
          ? Duration(minutes: settings.integer('refreshMinutes'))
          : const Duration(minutes: 5);
      final backoff = channel.failureCount == 0
          ? Duration.zero
          : Duration(
              minutes: (5 * (1 << channel.failureCount.clamp(0, 8))).clamp(
                5,
                1440,
              ),
            );
      if (!manual &&
          DateTime.now().millisecondsSinceEpoch - channel.checkedMs <
              (backoff > interval ? backoff : interval).inMilliseconds) {
        continue;
      }
      await refreshChannel(channel.id, manual: manual);
    }
  }

  Future<void> refreshChannel(
    String id, {
    bool manual = true,
    bool history = false,
  }) async {
    if (refreshing.contains(id) || !_lease('refresh:$id')) return;
    final channel = store.channel(id);
    if (channel != null &&
        !manual &&
        (store.preferences.flag('pauseAllUpdates') ||
            !store.effective(id).flag('autoRefresh') ||
            DateTime.now().millisecondsSinceEpoch - channel.checkedMs <
                const Duration(minutes: 5).inMilliseconds)) {
      _release('refresh:$id');
      return;
    }
    if (channel == null || !channel.active) {
      _release('refresh:$id');
      return;
    }
    refreshing.add(id);
    notifyListeners();
    try {
      final oldIds = store.episodes(id).map((e) => e.id).toSet();
      final needsSourceConfirmation = store
          .episodes(id)
          .any((episode) => episode.sourceFeedUrl.isEmpty);
      final url = history ? channel.nextPage : channel.feedUrl;
      if (url == null) return;
      final response = await client.http.get(
        url,
        headers: {
          if (!history && !needsSourceConfirmation && channel.etag != null)
            'If-None-Match': channel.etag!,
          if (!history &&
              !needsSourceConfirmation &&
              channel.lastModified != null)
            'If-Modified-Since': channel.lastModified!,
        },
      );
      if (_closed ||
          (!manual &&
              (store.preferences.flag('pauseAllUpdates') ||
                  !store.effective(id).flag('autoRefresh')))) {
        return;
      }
      if (response.status == 304) {
        channel.checkedMs = channel.successMs =
            DateTime.now().millisecondsSinceEpoch;
        channel.error = '';
        channel.failureCount = 0;
        store.write('channel', id, channel.toJson());
        return;
      }
      final feed = client.parser.parse(
        response.bytes,
        response.url,
        channelId: id,
      );
      if (history) {
        for (final e in feed.episodes) {
          final existing = store.episode(e.id);
          store.write(
            'episode',
            e.id,
            e.toJson()
              ..['discoveredMs'] =
                  existing?.discoveredMs ?? channel.subscribedMs,
            channel: id,
          );
        }
        channel.nextPage = feed.channel.nextPage;
        store.write('channel', id, channel.toJson());
        return;
      }
      feed.channel.etag = response.headers['etag'];
      feed.channel.lastModified = response.headers['last-modified'];
      final mergedEpisodes = store.mergeFeed(feed);
      final newEpisodes = mergedEpisodes
          .where((e) => !oldIds.contains(e.id))
          .toList();
      if (newEpisodes.isNotEmpty && store.effective(id).flag('notify')) {
        for (final episode in newEpisodes) {
          if (store.read('notified', episode.id) == null) {
            store.write('notice', episode.id, {
              'channelId': id,
              'episodeId': episode.id,
              'title': episode.title,
            });
          }
        }
      }
      final settings = store.effective(id);
      if (settings.flag('autoDownload')) {
        final latest = store
            .episodes(id)
            .where((e) => !state(e.id).played)
            .take(settings.integer('keepLatest'))
            .toList();
        for (final episode in latest) {
          if (newEpisodes.any((e) => e.id == episode.id)) {
            enqueue(episode, automatic: true);
          }
        }
      }
    } catch (error) {
      if (!_closed) {
        channel.checkedMs = DateTime.now().millisecondsSinceEpoch;
        channel.failureCount++;
        channel.error = error is FormatException
            ? error.message
            : '暂时无法更新，请检查网络或稍后重试';
        store.write('channel', id, channel.toJson());
      }
    } finally {
      refreshing.remove(id);
      _release('refresh:$id');
      if (!_closed) notifyListeners();
    }
  }

  void enqueue(
    PodcastEpisode episode, {
    bool automatic = false,
    bool preparation = false,
    String? mediaUrl,
  }) {
    final preferences = store.effective(episode.channelId);
    final media = mediaUrl == null
        ? episode.preferredMedia(preferences.text('mediaPreference'))
        : episode.media.firstWhere((m) => m.url == mediaUrl);
    final existing = store.read('download', episode.id);
    final active =
        existing != null &&
        [
          PodcastDownloadStatus.downloading.name,
          PodcastDownloadStatus.queued.name,
          PodcastDownloadStatus.waitingNetwork.name,
        ].contains(existing['status']);
    if (active && existing['mediaUrl'] != media.url) {
      // A running video download must not be silently replaced by audio.
      return;
    }
    if (active && existing['mediaUrl'] == media.url) {
      if (!automatic && !preparation && existing['manualRetain'] != true) {
        existing['manualRetain'] = true;
        existing['preparation'] =
            existing['preparation'] == true || preparation;
        store.write(
          'download',
          episode.id,
          existing,
          channel: episode.channelId,
        );
        notifyListeners();
      }
      requestDispatch();
      return;
    }
    final previous = existing == null
        ? null
        : PodcastDownload.fromJson(existing);
    final task = PodcastDownload(
      episodeId: episode.id,
      mediaUrl: media.url,
      automatic: automatic,
      manualRetain:
          previous?.manualRetain == true || (!automatic && !preparation),
      preparation: preparation || (previous?.preparation ?? false),
      queuedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    if (media.isStreamManifest) {
      task.status = PodcastDownloadStatus.failed;
      task.error = '分段流媒体不能作为完整离线文件下载，请选择音频文件或 MP4 版本';
    }
    if (!podcastHasRssMedia(episode, media)) {
      task.status = PodcastDownloadStatus.failed;
      task.error = podcastRssSourceMessage;
    }
    if (mediaStore.isDownloaded(episode.id, media.url)) {
      task.status = PodcastDownloadStatus.completed;
    }
    _taskEpoch[episode.id] = (_taskEpoch[episode.id] ?? 0) + 1;
    store.write(
      'download',
      episode.id,
      task.toJson(),
      channel: episode.channelId,
    );
    notifyListeners();
    requestDispatch();
  }

  void pause(String id) {
    final raw = store.read('download', id);
    if (raw == null) return;
    final task = PodcastDownload.fromJson(raw)
      ..status = PodcastDownloadStatus.paused;
    final cancellation = _downloadCancels[id];
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
    store.write(
      'download',
      id,
      task.toJson(),
      channel: store.episode(id)?.channelId ?? '',
    );
    notifyListeners();
  }

  Future<void> forgetDeletedStorage(List<String> paths) async {
    await mediaStore.forgetDeletedStorage(paths);
    notifyListeners();
  }

  Future<bool> cancel(
    String id, {
    bool removeFile = false,
    bool preserveCompleted = false,
  }) async {
    bool keepCompleted(Map<String, dynamic> task) {
      final url = task['mediaUrl'];
      if (task['status'] != PodcastDownloadStatus.completed.name &&
          !(url is String && mediaStore.isDownloaded(id, url))) {
        return false;
      }
      if (task['status'] != PodcastDownloadStatus.completed.name) {
        task['status'] = PodcastDownloadStatus.completed.name;
        store.write(
          'download',
          id,
          task,
          channel: store.episode(id)?.channelId ?? '',
        );
        notifyListeners();
      }
      return true;
    }

    if (preserveCompleted) {
      final task = store.read('download', id);
      if (task == null || keepCompleted(task)) return false;
    }
    pause(id);
    while (_running.contains(id)) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    final task = store.read('download', id);
    // A transfer can finish while cancellation is waiting for its worker.
    // Completed offline files are outside a partial-download cleanup's scope.
    if (preserveCompleted && (task == null || keepCompleted(task))) {
      return false;
    }
    if (removeFile && task != null) {
      await mediaStore.remove(id, task['mediaUrl'], includeDownload: true);
    }
    store.remove('download', id);
    notifyListeners();
    return true;
  }

  /// Transcription and offline playback use the same persistent download task.
  Future<File> prepareLocalMedia(
    PodcastEpisode episode,
    PodcastMedia media, {
    bool Function()? isCancelled,
    Future<void>? cancelSignal,
    void Function(PodcastTransferProgress)? onProgress,
  }) async {
    if (media.isStreamManifest) {
      throw const FormatException('这个来源是分段流媒体，请选择文件版本以生成字幕');
    }
    if (!mediaStore.isComplete(episode.id, media.url)) {
      requirePodcastRssMedia(episode, media);
    }
    var cancelled = false, settled = false;
    cancelSignal?.then((_) {
      if (!settled) cancelled = true;
    });
    final previous = store.read('download', episode.id);
    if (_running.contains(episode.id) && previous?['mediaUrl'] != media.url) {
      throw const HttpException('这集播客正在下载另一个媒体版本，请等下载完成后再生成字幕');
    }
    final joined =
        previous != null &&
        previous['mediaUrl'] == media.url &&
        [
          PodcastDownloadStatus.queued.name,
          PodcastDownloadStatus.downloading.name,
          PodcastDownloadStatus.waitingNetwork.name,
        ].contains(previous['status']);
    _preparationConsumers.update(
      episode.id,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
    if (joined) {
      final task = PodcastDownload.fromJson(previous);
      task.preparation = true;
      store.write(
        'download',
        episode.id,
        task.toJson(),
        channel: episode.channelId,
      );
    }
    void checkCancelled() {
      if (isCancelled?.call() == true) cancelled = true;
      if (_closed || cancelled) {
        throw const HttpException('播客字幕准备已取消，已下载的数据会保留');
      }
    }

    var reused = mediaStore.cachedBytes(episode.id, media.url);

    Future<void> reuseCompleteMedia() async {
      checkCancelled();
      final total = mediaStore.manifest(episode.id, media.url)['total'] as int;
      reused = total;
      final canRetain =
          mediaStore.isDownloaded(episode.id, media.url) ||
          mediaStore.downloadBytes + total <=
              store.preferences.integer('downloadLimitMb') * 1024 * 1024;
      final raw = store.read('download', episode.id);
      final task = raw != null && raw['mediaUrl'] == media.url
          ? PodcastDownload.fromJson(raw)
          : PodcastDownload(episodeId: episode.id, mediaUrl: media.url);
      if (canRetain) {
        await mediaStore.markDownloaded(episode, media);
        checkCancelled();
        task
          ..status = PodcastDownloadStatus.completed
          ..received = total
          ..total = total
          ..error = '';
        store.write(
          'download',
          episode.id,
          task.toJson(),
          channel: episode.channelId,
        );
      } else if (raw != null &&
          raw['mediaUrl'] == media.url &&
          !_running.contains(episode.id)) {
        if (!task.manualRetain && !task.automatic) {
          // A preparation-only wait must not pin a temporary cache forever.
          store.remove('download', episode.id);
        } else {
          task
            ..status = PodcastDownloadStatus.paused
            ..error = '离线空间达到上限，可清理下载或调整容量';
          store.write(
            'download',
            episode.id,
            task.toJson(),
            channel: episode.channelId,
          );
        }
      }
      final progress = PodcastTransferProgress(
        receivedBytes: total,
        totalBytes: total,
        reusedBytes: total,
        phase: PodcastTransferPhase.assembling,
        message: canRetain ? '复用完整本地播客，正在准备转录' : '复用完整缓存；离线下载容量已满，暂按缓存规则保留',
      );
      _transfers[episode.id] = progress;
      onProgress?.call(progress);
      if (!_closed) transferTick.value++;
      notifyListeners();
    }

    try {
      checkCancelled();
      if (mediaStore.isComplete(episode.id, media.url)) {
        await reuseCompleteMedia();
      } else {
        if (store.preferences.flag('pauseAllDownloads')) {
          throw const HttpException(
            '播客下载已全局暂停，请在“播客设置 → 离线下载”中关闭“暂停所有下载任务”后继续生成字幕',
          );
        }
        if (!joined) {
          // A paused request can still be releasing its socket/lease. Do not
          // let its final state overwrite the replacement task.
          while (_running.contains(episode.id)) {
            checkCancelled();
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          enqueue(episode, mediaUrl: media.url, preparation: true);
        }
        while (true) {
          checkCancelled();
          final raw = store.read('download', episode.id);
          if (raw == null || raw['mediaUrl'] != media.url) {
            throw const HttpException('播客下载任务已更改，请重新开始字幕生成');
          }
          final task = PodcastDownload.fromJson(raw);
          if (task.status == PodcastDownloadStatus.completed) break;
          // Playback or another worker may have supplied the missing blocks
          // while admission was waiting. Local completion needs no network.
          if (mediaStore.isComplete(episode.id, media.url)) {
            await reuseCompleteMedia();
            break;
          }
          if (store.preferences.flag('pauseAllDownloads')) {
            throw const HttpException('播客下载已全局暂停，已下载的数据会保留');
          }
          if (task.status == PodcastDownloadStatus.failed ||
              task.status == PodcastDownloadStatus.paused) {
            throw HttpException(
              task.error.isNotEmpty ? task.error : '播客下载已暂停，已下载的数据会保留',
            );
          }
          onProgress?.call(
            _transfers[episode.id] ??
                PodcastTransferProgress(
                  receivedBytes: mediaStore.cachedBytes(episode.id, media.url),
                  totalBytes: task.total ?? media.length,
                  reusedBytes: reused,
                  phase: PodcastTransferPhase.queued,
                  message: '正在等待播客下载',
                ),
          );
          requestDispatch();
          await Future.any<void>([
            Future<void>.delayed(const Duration(milliseconds: 200)),
            ?cancelSignal,
          ]);
        }
      }
      checkCancelled();
      final file = await mediaStore.assemble(
        episode,
        media,
        cancelSignal: cancelSignal,
      );
      checkCancelled();
      final progress = PodcastTransferProgress(
        receivedBytes: file.lengthSync(),
        totalBytes: file.lengthSync(),
        reusedBytes: reused,
        phase: PodcastTransferPhase.ready,
        message: mediaStore.isDownloaded(episode.id, media.url)
            ? '播客已保留为下载资源，正在准备转录'
            : '完整播客缓存已复用，正在准备转录',
      );
      _transfers[episode.id] = progress;
      onProgress?.call(progress);
      if (!_closed) transferTick.value++;
      return file;
    } finally {
      settled = true;
      final remaining = (_preparationConsumers[episode.id] ?? 1) - 1;
      if (remaining > 0) {
        _preparationConsumers[episode.id] = remaining;
      } else {
        _preparationConsumers.remove(episode.id);
        final raw = store.read('download', episode.id);
        if (raw != null && raw['mediaUrl'] == media.url) {
          final task = PodcastDownload.fromJson(raw);
          task.preparation = false;
          store.write(
            'download',
            episode.id,
            task.toJson(),
            channel: episode.channelId,
          );
          final alive = [
            PodcastDownloadStatus.queued,
            PodcastDownloadStatus.downloading,
            PodcastDownloadStatus.waitingNetwork,
          ].contains(task.status);
          if (cancelled && alive && !task.manualRetain && !task.automatic) {
            pause(episode.id);
          }
        }
        requestDispatch();
      }
    }
  }

  /// Wakes the dispatcher. Returns when this pass has started every task that
  /// currently fits, without waiting for those downloads to finish.
  Future<void> requestDispatch() async {
    if (_closed) return Future<void>.value();
    if (_dispatchFuture != null) {
      _redispatch = true;
      return _dispatchFuture!;
    }
    final done = Completer<void>();
    _dispatchFuture = done.future;
    _dispatching = true;
    unawaited(() async {
      try {
        do {
          _redispatch = false;
          _startEligible();
        } while (_redispatch && !_closed);
      } finally {
        _dispatching = false;
        _dispatchFuture = null;
        if (!done.isCompleted) done.complete();
      }
    }());
    return done.future;
  }

  Future<void> pumpDownloads({Duration? budget}) async {
    if (budget != null) _pendingBudget = budget;
    await requestDispatch();
    if (budget == null) return;
    final pending = List<Future<void>>.of(_budgetFutures);
    _budgetFutures.clear();
    _pendingBudget = null;
    if (pending.isEmpty) return;
    // Only the tasks this budget pass started. An already-running foreground
    // download must not hold the background worker open.
    await Future.wait(pending);
  }

  Future<void> waitForIdle() async {
    while (!_closed && (_running.isNotEmpty || _dispatching)) {
      final jobs = List<Future<void>>.of(_jobs.values);
      await Future.any<void>([
        Future<void>.delayed(const Duration(milliseconds: 20)),
        ...jobs,
      ]);
    }
  }

  Future<void> waitForTask(String episodeId) async {
    final job = _jobs[episodeId];
    if (job != null) await job;
  }

  void _startEligible() {
    if (_closed || store.preferences.flag('pauseAllDownloads')) return;
    final limit = store.preferences.integer('downloadConcurrency');
    final ordered = _prioritized(downloads);
    var position = 0;
    for (final task in ordered) {
      position++;
      if (_running.contains(task.episodeId) ||
          ![
            PodcastDownloadStatus.queued,
            PodcastDownloadStatus.waitingNetwork,
            PodcastDownloadStatus.downloading,
          ].contains(task.status)) {
        continue;
      }
      final episode = store.episode(task.episodeId);
      if (episode == null) continue;
      final media = episode.media
          .where((candidate) => candidate.url == task.mediaUrl)
          .firstOrNull;
      if (!mediaStore.isComplete(episode.id, task.mediaUrl) &&
          (media == null || !podcastHasRssMedia(episode, media))) {
        task.status = PodcastDownloadStatus.failed;
        task.error = podcastRssSourceMessage;
        store.write(
          'download',
          task.episodeId,
          task.toJson(),
          channel: episode.channelId,
        );
        continue;
      }
      final settings = store.effective(episode.channelId);
      if (task.automatic && !settings.flag('autoDownload')) {
        pause(task.episodeId);
        continue;
      }
      if (_running.length >= limit) {
        if ((_preparationConsumers[task.episodeId] ?? 0) > 0 ||
            task.preparation) {
          _transfers[task.episodeId] = PodcastTransferProgress(
            receivedBytes: task.received,
            totalBytes: task.total,
            phase: PodcastTransferPhase.queued,
            waitingReason: PodcastWaitingReason.concurrency,
            queuePosition: position,
            message: '正在等待下载名额（前面还有 ${position - 1} 项）',
          );
        }
        continue;
      }
      if (!_lease('download:${task.episodeId}', 120)) {
        _transfers[task.episodeId] = PodcastTransferProgress(
          receivedBytes: task.received,
          totalBytes: task.total,
          phase: PodcastTransferPhase.queued,
          waitingReason: PodcastWaitingReason.otherWorker,
          message: '后台正在下载',
        );
        continue;
      }
      _running.add(task.episodeId);
      final budget = _pendingBudget;
      final future = _download(task, episode, budget: budget);
      _jobs[task.episodeId] = future;
      if (budget != null) _budgetFutures.add(future);
      unawaited(
        future.whenComplete(() {
          if (identical(_jobs[task.episodeId], future)) {
            _jobs.remove(task.episodeId);
          }
          requestDispatch();
        }),
      );
    }
    if (!_closed) notifyListeners();
  }

  List<PodcastDownload> _prioritized(List<PodcastDownload> tasks) {
    final nowMs = now().millisecondsSinceEpoch;
    int rank(PodcastDownload task) {
      if (mediaStore.playbackDemands.contains(task.episodeId)) return 0;
      if ((_preparationConsumers[task.episodeId] ?? 0) > 0 ||
          task.preparation) {
        return 1;
      }
      if (task.manualRetain) return 2;
      final age = task.queuedAtMs == 0 ? 0 : nowMs - task.queuedAtMs;
      if (task.automatic && age > const Duration(minutes: 2).inMilliseconds) {
        return 2;
      }
      return 3;
    }

    final copy = [...tasks];
    copy.sort((a, b) {
      final byRank = rank(a).compareTo(rank(b));
      if (byRank != 0) return byRank;
      return a.queuedAtMs.compareTo(b.queuedAtMs);
    });
    return copy;
  }

  Future<void> _download(
    PodcastDownload task,
    PodcastEpisode episode, {
    Duration? budget,
  }) async {
    mediaStore.activeDownloads.add(episode.id);
    final cancellation = Completer<void>();
    _downloadCancels[episode.id] = cancellation;
    final started = DateTime.now();
    final media =
        episode.media.where((m) => m.url == task.mediaUrl).firstOrNull ??
        PodcastMedia(url: task.mediaUrl);
    final reused = mediaStore.cachedBytes(episode.id, media.url);
    final watch = Stopwatch()..start();
    final speed = PodcastSpeedWindow();
    var transferred = 0, lastReportMs = -250;
    var latestReceived = reused;
    var latestMessage = '';
    var phase = PodcastTransferPhase.connecting;
    var waitingReason = PodcastWaitingReason.none;
    DateTime? lastNetworkByteAt, lastUsefulByteAt;
    var lastNetworkMs = 0;
    void report({
      int? received,
      String? message,
      bool force = false,
      PodcastTransferPhase? nextPhase,
    }) {
      if (received != null) {
        if (received > latestReceived) lastUsefulByteAt = now();
        latestReceived = received;
      }
      if (message != null) latestMessage = message;
      if (nextPhase != null) phase = nextPhase;
      if (!force && watch.elapsedMilliseconds - lastReportMs < 200) return;
      lastReportMs = watch.elapsedMilliseconds;
      final total =
          mediaStore.manifest(episode.id, media.url)['total'] as int? ??
          media.length;
      final count = latestReceived;
      final nowMs = now().millisecondsSinceEpoch;
      speed.add(nowMs, count);
      final rate = speed.bytesPerSecond(nowMs);
      _transfers[episode.id] = PodcastTransferProgress(
        receivedBytes: total == null ? count : count.clamp(0, total),
        totalBytes: total,
        reusedBytes: reused,
        committedBytes: count,
        networkBytes: transferred,
        bytesPerSecond: rate,
        phase: phase,
        waitingReason: waitingReason,
        message: latestMessage,
        lastNetworkByteAt: lastNetworkByteAt,
        lastUsefulByteAt: lastUsefulByteAt,
      );
      if (!_closed) transferTick.value++;
    }

    void networkBytes(int bytes) {
      transferred += bytes;
      lastNetworkByteAt = now();
      lastNetworkMs = watch.elapsedMilliseconds;
      waitingReason = PodcastWaitingReason.none;
    }

    void waiting(String message, bool limited) {
      waitingReason = limited
          ? PodcastWaitingReason.retry
          : PodcastWaitingReason.concurrency;
      report(
        message: message,
        nextPhase: limited
            ? PodcastTransferPhase.retrying
            : PodcastTransferPhase.queued,
      );
    }

    var lastLeaseMs = 0;
    final progressTimer = Timer.periodic(const Duration(milliseconds: 200), (
      _,
    ) {
      if (!_closed && watch.elapsedMilliseconds - lastLeaseMs >= 30000) {
        lastLeaseMs = watch.elapsedMilliseconds;
        if (!_lease('download:${episode.id}', 120) &&
            !cancellation.isCompleted) {
          task.error = '下载已由另一个任务接管';
          cancellation.complete();
        }
      }
      if ((phase == PodcastTransferPhase.downloading ||
              phase == PodcastTransferPhase.connecting) &&
          watch.elapsedMilliseconds - lastNetworkMs >=
              PodcastTransferPolicy.stallNotice.inMilliseconds) {
        report(message: '来源暂时没有返回数据，超时后会自动重连并保留进度');
      } else {
        report();
      }
    });

    try {
      final free = await disk.availableBytes(mediaStore.root);
      if (free != null && free < 512 * 1024 * 1024) {
        task.status = PodcastDownloadStatus.paused;
        task.error = '设备可用空间不足，已暂停下载';
        return;
      }
      task.status = PodcastDownloadStatus.downloading;
      task.error = '';
      store.write(
        'download',
        task.episodeId,
        task.toJson(),
        channel: episode.channelId,
      );
      notifyListeners();
      report(force: true);
      for (var index = 0; !_closed; index++) {
        if (task.automatic &&
            (!store.effective(episode.channelId).flag('autoDownload') ||
                store.channel(episode.channelId)?.active != true)) {
          task.status = PodcastDownloadStatus.paused;
          break;
        }
        final latest = store.read('download', task.episodeId);
        if (latest == null ||
            latest['status'] == PodcastDownloadStatus.paused.name) {
          task.status = PodcastDownloadStatus.paused;
          break;
        }
        if (store.preferences.flag('pauseAllDownloads')) {
          task.status = PodcastDownloadStatus.queued;
          break;
        }
        if (budget != null && DateTime.now().difference(started) > budget) {
          task.status = PodcastDownloadStatus.queued;
          break;
        }
        final manifest = mediaStore.manifest(episode.id, media.url);
        final total = manifest['total'] as int? ?? media.length;
        final existing = mediaStore.cachedBytes(episode.id, media.url);
        final incoming = total ?? existing + podcastChunkBytes;
        final reservedOthers = _reservations.entries
            .where((e) => e.key != episode.id)
            .fold<int>(0, (sum, e) => sum + e.value);
        final remaining = (incoming - existing).clamp(0, 1 << 50);
        if (mediaStore.downloadBytes +
                mediaStore.partialDownloadBytes +
                reservedOthers +
                remaining >
            store.preferences.integer('downloadLimitMb') * 1024 * 1024) {
          task.status = PodcastDownloadStatus.paused;
          task.error = '离线空间达到上限，可清理下载或调整容量';
          break;
        }
        _reservations[episode.id] = remaining;
        if (manifest['rangeUnsupported'] == true) {
          var sequentialBytes = 0;
          Future<bool> fill() => mediaStore.fillSequential(
            episode,
            media,
            cancelSignal: cancellation.future,
            onWaiting: waiting,
            onNetworkBytes: (bytes) {
              networkBytes(bytes);
              sequentialBytes += bytes;
              report(
                received: sequentialBytes > existing
                    ? sequentialBytes
                    : existing,
                message: '',
                nextPhase: PodcastTransferPhase.downloading,
              );
            },
            onProgress: (received, total) {
              if (!_lease('download:${task.episodeId}', 120)) {
                task.status = PodcastDownloadStatus.paused;
                task.error = '下载已由另一个任务接管';
                return false;
              }
              if (free != null &&
                  free - (received - existing) < 128 * 1024 * 1024) {
                task.status = PodcastDownloadStatus.paused;
                task.error = '设备可用空间不足，已保存进度并暂停';
                return false;
              }
              final current = store.read('download', task.episodeId);
              if (current?['status'] == PodcastDownloadStatus.paused.name) {
                task.status = PodcastDownloadStatus.paused;
                return false;
              }
              if (_closed ||
                  store.preferences.flag('pauseAllDownloads') ||
                  (budget != null &&
                      DateTime.now().difference(started) > budget)) {
                task.status = PodcastDownloadStatus.queued;
                return false;
              }
              final settings = store.effective(episode.channelId);
              if ((task.automatic &&
                  (!settings.flag('autoDownload') ||
                      store.channel(episode.channelId)?.active != true))) {
                task.status = PodcastDownloadStatus.paused;
                return false;
              }
              final needed =
                  ((total ?? received + podcastChunkBytes) - received).clamp(
                    0,
                    1 << 50,
                  );
              final others = _reservations.entries
                  .where((e) => e.key != episode.id)
                  .fold<int>(0, (sum, e) => sum + e.value);
              if (mediaStore.downloadBytes +
                      mediaStore.partialDownloadBytes +
                      needed +
                      others >
                  store.preferences.integer('downloadLimitMb') * 1024 * 1024) {
                task.status = PodcastDownloadStatus.paused;
                task.error = '离线空间达到上限，可清理下载或调整容量';
                return false;
              }
              _reservations[episode.id] = needed;
              task.received = received;
              task.total = total;
              store.write(
                'download',
                task.episodeId,
                task.toJson(),
                channel: episode.channelId,
              );
              notifyListeners();
              return true;
            },
          );
          final completed = await _withDownloadRetry(
            episode,
            fill,
            cancelSignal: cancellation.future,
            onRetry: (message) {
              sequentialBytes = 0;
              report(
                received: mediaStore.cachedBytes(episode.id, media.url),
                message: message,
                force: true,
              );
            },
          );
          if (completed) {
            await mediaStore.markDownloaded(episode, media);
            task.status = PodcastDownloadStatus.completed;
            task.total =
                mediaStore.manifest(episode.id, media.url)['total'] as int?;
          }
          break;
        }
        if (index > 0 && index % 16 == 0) {
          final available = await disk.availableBytes(mediaStore.root);
          if (available != null && available < 128 * 1024 * 1024) {
            task.status = PodcastDownloadStatus.paused;
            task.error = '设备可用空间不足，已保存进度并暂停';
            break;
          }
        }
        final result = await _withDownloadRetry(
          episode,
          () => mediaStore.fillWindow(
            episode,
            media,
            cancelSignal: cancellation.future,
            onWaiting: waiting,
            shouldContinue: () {
              if (_closed || cancellation.isCompleted) return false;
              if (budget != null && now().difference(started) > budget) {
                task.status = PodcastDownloadStatus.queued;
                return false;
              }
              if (store.preferences.flag('pauseAllDownloads')) {
                task.status = PodcastDownloadStatus.queued;
                return false;
              }
              final current = store.read('download', task.episodeId);
              if (current?['status'] == PodcastDownloadStatus.paused.name) {
                task.status = PodcastDownloadStatus.paused;
                return false;
              }
              return true;
            },
            onNetworkBytes: (bytes) {
              networkBytes(bytes);
              report(message: '', nextPhase: PodcastTransferPhase.downloading);
            },
            onUseful: (committed, inFlight) {
              report(
                received: committed + inFlight,
                message: '',
                nextPhase: PodcastTransferPhase.downloading,
              );
            },
          ),
          cancelSignal: cancellation.future,
          onRetry: (message) {
            report(
              received: mediaStore.cachedBytes(episode.id, media.url),
              message: message,
              force: true,
              nextPhase: PodcastTransferPhase.retrying,
            );
          },
        );
        final afterChunk = store.read('download', task.episodeId);
        if (afterChunk?['status'] == PodcastDownloadStatus.paused.name) {
          task.status = PodcastDownloadStatus.paused;
          break;
        }
        if (!_lease('download:${task.episodeId}', 120)) {
          throw const HttpException('下载正在另一任务中执行');
        }
        final current = mediaStore.manifest(episode.id, media.url);
        if (current['revision'] != manifest['revision']) {
          index = -1;
          continue;
        }
        task.received = mediaStore.cachedBytes(episode.id, media.url);
        task.total = current['total'] as int?;
        report(received: task.received, message: '', force: true);
        store.write(
          'download',
          task.episodeId,
          task.toJson(),
          channel: episode.channelId,
        );
        if (!_closed) notifyListeners();
        if (result.complete || mediaStore.isComplete(episode.id, media.url)) {
          await mediaStore.markDownloaded(episode, media);
          task.status = PodcastDownloadStatus.completed;
          report(
            received: task.received,
            message: '整理本地音频',
            force: true,
            nextPhase: PodcastTransferPhase.assembling,
          );
          break;
        }
        if (result.stopped) break;
      }
    } catch (error) {
      task.status = _closed
          ? PodcastDownloadStatus.queued
          : cancellation.isCompleted
          ? PodcastDownloadStatus.paused
          : PodcastDownloadStatus.failed;
      task.error = cancellation.isCompleted
          ? task.error
          : error is HttpException
          ? error.message
          : '下载中断，已保留进度，可以继续重试';
    } finally {
      progressTimer.cancel();
      if (task.status == PodcastDownloadStatus.downloading) {
        task.status = PodcastDownloadStatus.queued;
      }
      store.write(
        'download',
        task.episodeId,
        task.toJson(),
        channel: episode.channelId,
      );
      _running.remove(task.episodeId);
      _reservations.remove(task.episodeId);
      _downloadCancels.remove(episode.id);
      report(
        received: mediaStore.cachedBytes(episode.id, media.url),
        force: true,
      );
      mediaStore.activeDownloads.remove(task.episodeId);
      _release('download:${task.episodeId}');
      if (!_closed) notifyListeners();
    }
  }

  Future<T> _withDownloadRetry<T>(
    PodcastEpisode episode,
    Future<T> Function() action, {
    required Future<void> cancelSignal,
    required void Function(String) onRetry,
  }) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await action();
      } catch (error) {
        if (_closed ||
            _downloadCancels[episode.id]?.isCompleted == true ||
            store.read('download', episode.id)?['status'] ==
                PodcastDownloadStatus.paused.name) {
          rethrow;
        }
        final typed = error is PodcastTransferException ? error : null;
        final retryable =
            typed?.retryable == true ||
            error is SocketException ||
            error is TimeoutException ||
            (typed == null &&
                error is HttpException &&
                !RegExp(
                  r'返回 (4(?!08|29)\d\d|501|505)',
                ).hasMatch(error.message) &&
                !error.message.contains('范围无效') &&
                !error.message.contains('错误的数据范围'));
        if (!retryable || attempt >= NetworkRecovery.retryDelays.length) {
          rethrow;
        }
        final wait = typed?.retryAfter ?? NetworkRecovery.retryDelays[attempt];
        onRetry(
          typed?.kind == PodcastTransferFailureKind.retryLater
              ? '来源暂时限流，已保存进度，${wait.inSeconds < 1 ? 1 : wait.inSeconds} 秒后重试'
              : '下载被网络打断，已保存缓存，${wait.inSeconds < 1 ? 1 : wait.inSeconds} 秒后重试缺少的分段',
        );
        await NetworkRecovery.wait(
          wait,
          cancelSignal: cancelSignal,
          checkCancelled: () {
            if (_closed ||
                _downloadCancels[episode.id]?.isCompleted == true ||
                store.read('download', episode.id)?['status'] ==
                    PodcastDownloadStatus.paused.name) {
              throw const HttpException('播客下载已暂停，已下载的数据会保留');
            }
          },
        );
        if (_closed ||
            _downloadCancels[episode.id]?.isCompleted == true ||
            store.read('download', episode.id)?['status'] ==
                PodcastDownloadStatus.paused.name) {
          rethrow;
        }
      }
    }
  }

  Future<void> cleanup() async {
    if (_cleaning) return;
    _cleaning = true;
    try {
      await mediaStore.clean();
      for (final task in downloads.where(
        (t) => t.status == PodcastDownloadStatus.completed,
      )) {
        final episode = store.episode(task.episodeId);
        if (episode == null) continue;
        final settings = store.effective(episode.channelId),
            value = state(episode.id);
        final days = settings.integer('deletePlayedDays');
        final latestIds = store
            .episodes(episode.channelId)
            .take(settings.integer('keepLatest'))
            .map((e) => e.id)
            .toSet();
        final expiredAutomatic =
            task.automatic &&
            settings.flag('autoDownload') &&
            !latestIds.contains(episode.id);
        final expiredPlayed =
            days > 0 &&
            value.played &&
            value.playedAtMs > 0 &&
            DateTime.now().millisecondsSinceEpoch - value.playedAtMs >
                Duration(days: days).inMilliseconds;
        if ((expiredAutomatic || expiredPlayed) &&
            !value.retained &&
            !value.favorite &&
            !mediaStore.activeDownloads.contains(episode.id) &&
            !mediaStore.protectedEpisodes.contains(episode.id)) {
          await mediaStore.remove(
            episode.id,
            task.mediaUrl,
            includeDownload: true,
          );
          store.remove('download', task.episodeId);
        }
      }
    } finally {
      _cleaning = false;
    }
    if (!_closed) notifyListeners();
  }

  bool _cleaning = false;

  Future<void> close() async {
    _closed = true;
    for (final cancellation in _downloadCancels.values) {
      if (!cancellation.isCompleted) cancellation.complete();
    }
    mediaStore.cancelActiveReads();
    flushStates();
    while (_running.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    await mediaStore.close();
    transferTick.dispose();
    super.dispose();
  }

  String exportOpml() => client.parser.exportOpml(channels);
  Future<List<String>> importOpml(
    String source,
    Future<void> Function(PodcastFeed) subscribe,
  ) async {
    final failures = <String>[];
    for (final url in client.parser.parseOpml(source)) {
      try {
        final result = await client.resolve(url);
        if (result.singleEpisode) throw const FormatException('不是频道');
        await subscribe(result.feed);
      } catch (_) {
        failures.add(url);
      }
    }
    return failures;
  }

  String exportBundle() {
    flushStates();
    return jsonEncode({
      'version': 2,
      'inheritanceVersion': 1,
      'channels': channels.map((c) => store.exportChannel(c.id)).toList(),
    });
  }
}
