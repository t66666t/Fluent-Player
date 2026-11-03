import 'dart:async';
import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../debug/developer_log.dart' as developer;
import '../../models/bilibili_browse_models.dart';
import '../../models/bilibili_models.dart';
import '../../models/media_source_ref.dart';
import '../../models/video_item.dart';
import '../../utils/bilibili_image_url.dart';
import '../library_service.dart';
import '../media_playback_service.dart';
import '../settings_service.dart';
import 'bilibili_download_service.dart';
import 'bilibili_history_service.dart';
import 'bilibili_open_timeline.dart';
import 'bilibili_startup.dart';
import 'bilibili_public_api_service.dart';
import 'bilibili_video_detail_cache.dart';
import 'bilibili_watch_cards.dart';

/// What a tapped list entry already shows of a video (title and cover), so
/// the loading page has something to show from the first frame.
@immutable
class BilibiliWatchPreview {
  const BilibiliWatchPreview({this.title, this.coverUrl});

  final String? title;
  final String? coverUrl;
}

/// Video infos of recent watches, so tapping the same video again soon does
/// not ask for it again. Kept for [lifetime], at most [capacity] videos.
class BilibiliWatchInfoCache {
  BilibiliWatchInfoCache({
    this.capacity = 32,
    this.lifetime = const Duration(minutes: 10),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  static final BilibiliWatchInfoCache instance = BilibiliWatchInfoCache();

  final int capacity;
  final Duration lifetime;
  final DateTime Function() _clock;
  final LinkedHashMap<String, ({BilibiliVideoInfo info, DateTime at})>
  _entries = LinkedHashMap<String, ({BilibiliVideoInfo info, DateTime at})>();

  BilibiliVideoInfo? get(String bvid) {
    final entry = _entries[bvid];
    if (entry == null) return null;
    if (_clock().difference(entry.at) >= lifetime) {
      _entries.remove(bvid);
      return null;
    }
    return entry.info;
  }

  void put(String bvid, BilibiliVideoInfo info) {
    if (info.pages.isEmpty) return;
    _entries
      ..remove(bvid)
      ..[bvid] = (info: info, at: _clock());
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  int get length => _entries.length;

  void clear() => _entries.clear();
}

/// The video info a watch needs, read from a detail the Bilibili panel has
/// already loaded.
BilibiliVideoInfo bilibiliWatchInfoFromDetail(BilibiliVideoDetail detail) {
  return BilibiliVideoInfo(
    title: detail.title,
    desc: detail.description,
    pic: detail.coverUrl ?? '',
    bvid: detail.bvid,
    aid: detail.aid > 0 ? '${detail.aid}' : '',
    ownerName: detail.owner.name,
    ownerMid: detail.owner.mid > 0 ? '${detail.owner.mid}' : '',
    pubDate: (detail.publishedAt?.millisecondsSinceEpoch ?? 0) ~/ 1000,
    pages: <BilibiliPage>[
      for (final part in detail.parts)
        BilibiliPage(
          cid: part.cid,
          page: part.page,
          part: part.title,
          duration: part.durationSeconds,
        ),
    ],
  );
}

/// One try at getting a video ready. [cancel] is called when the user goes
/// back or the time limit passes; the work stops at its next step and what
/// it made is removed.
class BilibiliWatchAttempt {
  BilibiliWatchAttempt(this.timeline);

  final BilibiliOpenTimeline timeline;
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
    timeline.startup.cancel();
  }
}

/// The steps between a tap and a playable card, in the order that waits the
/// least:
///
/// * the signing keys of the play address request are fetched at once;
/// * the video info comes from memory, from the Bilibili panel's detail
///   cache, or from one request (the detail cache is the fallback when that
///   request fails); the panel's detail is fetched alongside;
/// * as soon as the part's cid is known its play address is fetched, next to
///   the card work, so the player finds it ready;
/// * the watch-only card is made without waiting for its cover, subtitles,
///   danmaku and preview frames, which arrive while it plays.
/// Longest wait for the cover file before the playback page opens anyway.
const Duration kBilibiliCoverWait = Duration(seconds: 2);

class BilibiliWatchLoader {
  BilibiliWatchLoader({
    required this.service,
    required this.library,
    required this.bvid,
    this.page,
    this.startAt,
    this.playingItemId,
    this.history,
    this.settings,
    this.cards,
    this.details,
    this.infoCache,
    Future<BilibiliVideoInfo> Function(String bvid)? fetchInfo,
    this.warmPlayUrl,
    this.warmSigning,
    this.warmCover,
    this.playUrlWait = const Duration(seconds: 6),
  }) : fetchInfo = fetchInfo ?? service.apiService.fetchVideoInfo;

  final BilibiliDownloadService service;
  final LibraryService library;
  final String bvid;
  final int? page;
  final Duration? startAt;
  final String? playingItemId;
  final BilibiliHistoryService? history;
  final SettingsService? settings;
  final BilibiliWatchCards? cards;
  final BilibiliVideoDetailCache? details;
  final BilibiliWatchInfoCache? infoCache;
  final Future<BilibiliVideoInfo> Function(String bvid) fetchInfo;

  /// Fetches the play address of [bvid] / [cid] into the player's cache.
  final Future<void> Function(String bvid, int cid)? warmPlayUrl;

  /// Gets the signing keys of the play address request while the video info
  /// is still on its way.
  final Future<void> Function()? warmSigning;

  /// Downloads the cover of the card about to play to its cover file, so the
  /// playback page shows it in its first frame (see [kBilibiliCoverWait]).
  final Future<void> Function(VideoItem item)? warmCover;

  /// Longest wait for that address before the page opens anyway (the player
  /// then asks for it itself).
  final Duration playUrlWait;

  Future<BilibiliWatchPlan> call(BilibiliWatchAttempt attempt) async {
    final timeline = attempt.timeline;
    final signing = warmSigning;
    if (signing != null) unawaited(signing());
    final detailCache = details;
    if (detailCache != null && detailCache.peek(bvid) == null) {
      // For the Bilibili panel; never awaited here.
      unawaited(detailCache.get(bvid).then<void>((_) {}, onError: (_) {}));
    }
    Future<void>? warming;
    final plan = await prepareBilibiliWatch(
      service: service,
      library: library,
      bvid: bvid,
      page: page,
      startAt: startAt,
      history: history,
      settings: settings,
      cards: cards,
      playingItemId: playingItemId,
      loadInfo: (id) => _loadInfo(id, timeline),
      onInfo: (info, part) {
        final warm = warmPlayUrl;
        if (warm == null || part.cid <= 0) return;
        final partBvid = (part.bvid ?? info.bvid).trim();
        warming = warm(partBvid.isNotEmpty ? partBvid : bvid, part.cid).then(
          (_) => timeline.mark('play address'),
          onError: (Object error) {
            // The player asks again and reports the reason itself.
            timeline.mark('play address failed');
            developer.log('Play address not prefetched', error: error);
          },
        );
      },
      deferPlayerData: true,
      isCancelled: () => attempt.isCancelled,
      onStep: timeline.mark,
      // Written when the playback page opens: a try given up meanwhile
      // leaves no history entry.
      recordHistory: false,
      // The launch janitor owns cards across retries. Returning a cancelled
      // creator's plan lets it protect shared cards, and later clean them if
      // the retry is also abandoned, instead of deleting them during prepare.
      returnPlanOnLateCancellation: true,
    );
    timeline.mark('watch plan ready');
    final cover = warmCover;
    if (cover != null && !attempt.isCancelled) {
      unawaited(
        cover(plan.item).then<void>(
          (_) => timeline.mark('cover'),
          onError: (Object error) {
            developer.log('Cover not prefetched', error: error);
          },
        ),
      );
    }
    // Only the play address is a prerequisite. Cover work continues beside
    // native initialization; it no longer adds a two-second serial wait.
    if (warming != null) {
      try {
        await attempt.timeline.startup.run(warming!, cap: playUrlWait);
      } on TimeoutException {
        // The playback page joins the existing address request. Its budget
        // continues from the tap; optional warming never restarts that clock.
      } on BilibiliStartupCancelled {
        // Return the already-made plan to the launch janitor, even on cancel.
        // Throwing here would orphan a transient card while warming finishes.
      }
    }
    timeline.startup.geometry.reportVideo(
      service.streamingService.cachedDisplayAspectRatioFor(plan.item),
    );
    return plan;
  }

  Future<BilibiliVideoInfo> _loadInfo(
    String id,
    BilibiliOpenTimeline timeline,
  ) async {
    final remembered = infoCache?.get(id);
    if (remembered != null) {
      timeline.mark('info from memory');
      return remembered;
    }
    final known = details?.peek(id);
    if (known != null && known.parts.isNotEmpty) {
      final info = bilibiliWatchInfoFromDetail(known);
      infoCache?.put(id, info);
      timeline.mark('info from detail cache');
      return info;
    }
    try {
      final info = await fetchInfo(id);
      infoCache?.put(id, info);
      return info;
    } catch (error, stack) {
      final detailCache = details;
      if (detailCache == null) rethrow;
      try {
        final detail = await detailCache.get(id);
        if (detail.parts.isEmpty) throw StateError('detail without parts');
        final info = bilibiliWatchInfoFromDetail(detail);
        infoCache?.put(id, info);
        timeline.mark('info from detail fallback');
        return info;
      } catch (_) {
        Error.throwWithStackTrace(error, stack);
      }
    }
  }
}

/// A play address request for [bvid] / [cid] answered into the player's
/// cache, without opening a playback session.
Future<void> Function(String bvid, int cid) bilibiliPlayUrlWarmer(
  BilibiliDownloadService service,
) {
  return (bvid, cid) => service.streamingService.listQualities(
    VideoItem(
      id: 'bilibili-warm:$bvid:$cid',
      path: 'bilibili://stream/$bvid?cid=$cid',
      title: bvid,
      durationMs: 0,
      lastUpdated: 0,
      sourceRef: MediaSourceRef(
        value: bvid,
        kind: MediaSourceKind.bilibiliStream,
        bvid: bvid,
        cid: cid,
      ),
    ),
  );
}

enum BilibiliWatchLaunchPhase { loading, failed, ready, cancelled }

/// Drives one loading page: runs [load] with a time limit, answers back and
/// retry, and removes what an abandoned try made.
class BilibiliWatchLaunch<T> extends ChangeNotifier {
  BilibiliWatchLaunch({
    required this.load,
    required this.timelineFor,
    this.onReady,
    this.discard,
    this.timeLimit = kBilibiliWatchTimeLimit,
  });

  final Future<T> Function(BilibiliWatchAttempt attempt) load;
  final BilibiliOpenTimeline Function() timelineFor;

  /// Runs once with the result of the try that made it in time.
  final void Function(T result, BilibiliOpenTimeline timeline)? onReady;

  /// Runs with the result of a try that was given up (back, time limit,
  /// retry) and finished anyway, once it is clear what to keep: [kept] is the
  /// result that opened (its entries stay), null when none did.
  ///
  /// Until the launch is ready or left, such results are held: a newer try
  /// may reuse what the given-up one made (or make the same again), and only
  /// the end tells which of it is not needed.
  final Future<void> Function(T abandoned, T? kept)? discard;
  final Duration timeLimit;

  BilibiliWatchLaunchPhase _phase = BilibiliWatchLaunchPhase.loading;
  String? _failure;
  BilibiliWatchAttempt? _attempt;
  Timer? _timer;
  bool _disposed = false;
  final List<T> _held = <T>[];
  T? _ready;

  /// Given-up results cleaned up while [_ready] kept part of them (a retry
  /// reused their cards).
  final List<T> _keptByReady = <T>[];

  BilibiliWatchLaunchPhase get phase => _phase;

  /// Why the last try failed, for the page.
  String? get failure => _failure;

  BilibiliOpenTimeline? get timeline => _attempt?.timeline;

  void start() {
    _attempt?.cancel();
    _timer?.cancel();
    final attempt = BilibiliWatchAttempt(timelineFor());
    _attempt = attempt;
    _phase = BilibiliWatchLaunchPhase.loading;
    _failure = null;
    _notify();
    _timer = Timer(timeLimit, () {
      if (!identical(_attempt, attempt) ||
          _phase != BilibiliWatchLaunchPhase.loading) {
        return;
      }
      attempt.cancel();
      attempt.timeline.mark('time limit');
      _phase = BilibiliWatchLaunchPhase.failed;
      _failure = '加载超时（${timeLimit.inSeconds} 秒），请检查网络后重试';
      _notify();
    });
    Future<T>.sync(() => load(attempt)).then(
      (result) {
        if (attempt.isCancelled || !identical(_attempt, attempt) || _disposed) {
          _abandon(result);
          return;
        }
        _timer?.cancel();
        _phase = BilibiliWatchLaunchPhase.ready;
        _ready = result;
        attempt.timeline.mark('ready');
        _notify();
        _releaseHeld();
        onReady?.call(result, attempt.timeline);
      },
      onError: (Object error, StackTrace stack) {
        if (attempt.isCancelled || !identical(_attempt, attempt) || _disposed) {
          return;
        }
        developer.log(
          'Bilibili watch not ready',
          error: error,
          stackTrace: stack,
        );
        _timer?.cancel();
        attempt.timeline.mark('failed');
        _phase = BilibiliWatchLaunchPhase.failed;
        _failure = describeBilibiliWatchFailure(error);
        _notify();
      },
    );
  }

  /// Another try after a failure.
  void retry() => start();

  /// Back pressed: the running try is dropped.
  void cancel() {
    _attempt?.cancel();
    _attempt?.timeline.mark('cancelled');
    _timer?.cancel();
    if (_phase == BilibiliWatchLaunchPhase.ready) return;
    _phase = BilibiliWatchLaunchPhase.cancelled;
    _releaseHeld();
    _notify();
  }

  /// Whether nothing runs any more that could still use a given-up result.
  bool get _settled =>
      _disposed ||
      _phase == BilibiliWatchLaunchPhase.ready ||
      _phase == BilibiliWatchLaunchPhase.cancelled;

  void _abandon(T result) {
    if (_settled) {
      _discardGivenUp(result);
    } else {
      _held.add(result);
    }
  }

  void _releaseHeld() {
    final held = List<T>.of(_held);
    _held.clear();
    held.forEach(_discardGivenUp);
  }

  void _discardGivenUp(T result) {
    final kept = _ready;
    if (kept != null) _keptByReady.add(result);
    unawaited(_discard(result, kept));
  }

  /// The ready result is not used after all (the page was left before the
  /// playback page opened): it is cleaned up at once, together with what
  /// given-up tries left only because it reused it.
  void discardReady() {
    final ready = _ready;
    if (ready == null) return;
    _ready = null;
    unawaited(_discard(ready, null));
    final again = List<T>.of(_keptByReady);
    _keptByReady.clear();
    for (final result in again) {
      unawaited(_discard(result, null));
    }
  }

  Future<void> _discard(T result, T? kept) async {
    try {
      await discard?.call(result, kept);
    } catch (error) {
      developer.log('Abandoned watch not cleaned up', error: error);
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_phase == BilibiliWatchLaunchPhase.loading) cancel();
    _disposed = true;
    _timer?.cancel();
    _releaseHeld();
    super.dispose();
  }
}

/// Whole wait between a tap and the playback page before the loading page
/// shows a failure.
const Duration kBilibiliWatchTimeLimit = Duration(seconds: 30);

/// The reason shown on the loading page.
String describeBilibiliWatchFailure(Object error) {
  if (error is StateError) return error.message;
  if (error is BilibiliPublicApiException) return error.message;
  if (error is TimeoutException) return '加载超时，请检查网络后重试';
  if (error is DioException) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '连接 B 站超时，请检查网络后重试';
      case DioExceptionType.badResponse:
        final status = error.response?.statusCode;
        if (status == 412) return '请求被 B 站暂时拦截，请稍后再试';
        return 'B 站暂时没有响应（HTTP ${status ?? '?'}），请稍后重试';
      default:
        return '网络连接失败，请检查网络后重试';
    }
  }
  return '播放准备失败，请检查网络或 B 站登录状态';
}

/// Removes the watch-only cards an abandoned watch made, unless something
/// already plays or shows them.
Future<void> discardAbandonedWatch(
  BilibiliWatchPlan plan, {
  required LibraryService library,
  String? playingItemId,
  Iterable<String> openPageItemIds = const <String>[],
  Iterable<String> keep = const <String>[],
  BilibiliWatchCards? cards,
}) async {
  final inUse = <String>{?playingItemId, ...openPageItemIds, ...keep};
  for (final id in plan.createdItemIds) {
    if (inUse.contains(id)) continue;
    try {
      await cards?.recorder.forget(id);
      await library.discardTransientVideo(id);
    } catch (error) {
      developer.log('Abandoned watch-only card not removed', error: error);
    }
  }
}

/// After the cover, subtitles, danmaku and chapters of the watch-only card
/// [item] arrived while it plays: its subtitle is loaded unless one is
/// already showing or the user turned subtitles off, and the page redraws so
/// the danmaku appear.
Future<void> applyCompletedWatchCard({
  required VideoItem item,
  required String? currentItemId,
  required List<String> loadedSubtitlePaths,
  required Future<bool> Function({
    required String itemId,
    required List<String> paths,
  })
  loadSubtitles,
}) async {
  if (currentItemId != item.id) return;
  // The user turned subtitles off before they arrived: they stay off.
  if (loadedSubtitlePaths.isEmpty &&
      item.blockAutoAssociatedSubtitleSelection) {
    return;
  }
  final primary = item.subtitlePath?.trim() ?? '';
  final paths = loadedSubtitlePaths.isNotEmpty
      ? List<String>.of(loadedSubtitlePaths)
      : <String>[if (primary.isNotEmpty) primary];
  await loadSubtitles(itemId: item.id, paths: paths);
}

/// Gives the watch-only entry [itemId] its player data and, when it is the
/// one playing, hands the new subtitle and danmaku to the player. Returns
/// false when there was nothing to complete.
Future<bool> completeAndApplyWatchCard({
  required BilibiliDownloadService service,
  required LibraryService library,
  required MediaPlaybackService playback,
  required String itemId,
}) async {
  final completed = await service.completeWatchPart(library, itemId);
  if (!completed) return false;
  BilibiliOpenTimeline.ofItem(itemId)?.mark('extras ready');
  final item = library.getVideo(itemId);
  if (item == null) return true;
  try {
    await applyCompletedWatchCard(
      item: item,
      currentItemId: playback.currentItem?.id,
      loadedSubtitlePaths: playback.subtitlePaths,
      loadSubtitles: playback.loadSubtitlePathsForCurrentItem,
    );
  } catch (error) {
    developer.log('Late card data not shown', error: error);
  }
  return true;
}

/// Where a watch from the Bilibili pages gets its video info and play
/// address. [app] is the running app; tests put fakes in [overrideForTesting].
class BilibiliWatchSources {
  const BilibiliWatchSources({
    this.details,
    this.infoCache,
    this.fetchInfo,
    this.warmPlayUrl,
    this.warmSigning = false,
    this.warmCover = false,
  });

  static BilibiliWatchSources get app => BilibiliWatchSources(
    details: BilibiliVideoDetailCache.instance,
    infoCache: BilibiliWatchInfoCache.instance,
    warmSigning: true,
    warmCover: true,
  );

  @visibleForTesting
  static BilibiliWatchSources? overrideForTesting;

  static BilibiliWatchSources get current => overrideForTesting ?? app;

  final BilibiliVideoDetailCache? details;
  final BilibiliWatchInfoCache? infoCache;

  /// Null asks the logged-in API service.
  final Future<BilibiliVideoInfo> Function(String bvid)? fetchInfo;

  /// Null fetches through the player's own address cache.
  final Future<void> Function(String bvid, int cid)? warmPlayUrl;

  /// Whether the logged-in API fetches its signing keys at the tap.
  final bool warmSigning;

  /// Whether the cover file of the card is downloaded before the playback
  /// page opens.
  final bool warmCover;

  /// Title and cover of [bvid] when something here already knows them.
  BilibiliWatchPreview? previewOf(String bvid) {
    final detail = details?.peek(bvid);
    if (detail != null) {
      return BilibiliWatchPreview(
        title: detail.title,
        coverUrl: detail.coverUrl,
      );
    }
    final info = infoCache?.get(bvid);
    if (info != null) {
      return BilibiliWatchPreview(
        title: info.title,
        coverUrl: bilibiliCoverThumbnailUrl(info.pic),
      );
    }
    return null;
  }
}
