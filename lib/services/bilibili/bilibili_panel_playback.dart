import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../library_service.dart';
import '../media_playback_service.dart';
import '../playback_browse_history.dart';
import '../playback_navigation_service.dart';
import '../playlist_manager.dart';
import '../settings_service.dart';
import 'bilibili_download_service.dart';
import 'bilibili_open_timeline.dart';
import 'bilibili_player_video.dart';
import 'bilibili_quick_import.dart';
import 'bilibili_watch_cards.dart';
import 'bilibili_watch_launch.dart';
import 'bilibili_watch_playlist.dart';

/// Opens a panel selection through the existing media-switch path. Keeping
/// the route alive also keeps its orientation, fullscreen and panel state.
Future<void> switchBilibiliPanelVideo(
  BuildContext context, {
  required String bvid,
  int? page,
  Duration? startAt,
  BilibiliWatchPreview? preview,
  bool rememberCurrent = false,
}) async {
  final playback = context.read<MediaPlaybackService>();
  final playlist = context.read<PlaylistManager>();
  final library = context.read<LibraryService>();
  final service = context.read<BilibiliDownloadService>();
  final route = ModalRoute.of(context);
  final previous = playback.currentItem;
  if (previous == null || route?.isCurrent != true) return;
  final playingVideo = bilibiliPlayerVideoOf(previous);
  final requestedPage =
      page ?? (playingVideo?.bvid == bvid ? playingVideo?.page : null);
  final generation = playback.sessionGeneration;
  final queueIds = playlist.playlist.map((item) => item.id).toList();
  final navigation = PlaybackNavigationService.instance;
  final browseOrigin = rememberCurrent
      ? navigation.captureBrowseOrigin(playback, playlist)
      : null;
  bool isCurrent() =>
      context.mounted &&
      route!.isCurrent &&
      playback.currentItem?.id == previous.id &&
      playback.sessionGeneration == generation &&
      playback.pendingSwitchItem == null &&
      listEquals(queueIds, playlist.playlist.map((item) => item.id).toList());

  final sources = BilibiliWatchSources.current;
  final timeline = BilibiliOpenTimeline(bvid)..mark('panel selection');
  timeline.startup.coverUrl = preview?.coverUrl;
  final ready = Completer<BilibiliWatchPlan?>();
  late final BilibiliWatchLaunch<BilibiliWatchPlan> launch;
  launch = BilibiliWatchLaunch<BilibiliWatchPlan>(
    timelineFor: () => timeline,
    load: (attempt) async {
      await service.init();
      if (!isCurrent()) {
        launch.cancel();
        throw const BilibiliWatchCancelledException();
      }
      return BilibiliWatchLoader(
        service: service,
        library: library,
        bvid: bvid,
        page: requestedPage,
        startAt: startAt,
        playingItemId: previous.id,
        settings: SettingsService(),
        cards: BilibiliWatchCards.instance,
        details: sources.details,
        infoCache: sources.infoCache,
        fetchInfo: sources.fetchInfo,
        warmPlayUrl: sources.warmPlayUrl ?? bilibiliPlayUrlWarmer(service),
        warmSigning: sources.warmSigning
            ? service.apiService.warmUpSigning
            : null,
        warmCover: sources.warmCover
            ? (item) => service.prefetchWatchCover(library, item.id)
            : null,
      )(attempt);
    },
    onReady: (plan, _) => ready.complete(plan),
    discard: (plan, kept) => discardAbandonedWatch(
      plan,
      library: library,
      playingItemId: playback.currentItem?.id,
      keep: <String>{
        ...?kept?.itemIds,
        ...playlist.playlist.map((item) => item.id),
        ...navigation.browseHistory.itemIds,
        ...?BilibiliWatchPlaylistSession.instance?.queuedItemIds(),
      },
      cards: BilibiliWatchCards.instance,
    ),
  );
  launch.addListener(() {
    if (ready.isCompleted) return;
    if (launch.phase == BilibiliWatchLaunchPhase.failed) {
      ready.completeError(StateError(launch.failure ?? '视频切换失败，请重试'));
    } else if (launch.phase == BilibiliWatchLaunchPhase.cancelled) {
      ready.complete(null);
    }
  });
  void playbackChanged() {
    if (!isCurrent()) launch.cancel();
  }

  playback.addListener(playbackChanged);
  try {
    launch.start();
    final plan = await ready.future;
    if (plan == null) return;
    if (!isCurrent()) {
      launch.discardReady();
      return;
    }
    try {
      await playback.persistCurrentProgress(expectedItemId: previous.id);
      await BilibiliWatchCards.instance?.recorder.flush(previous.id);
    } catch (error) {
      debugPrint('Position before panel switch not saved: $error');
    }
    if (!isCurrent()) {
      launch.discardReady();
      return;
    }
    // The next notifications belong to our own committed switch.
    playback.removeListener(playbackChanged);
    final origin = browseOrigin == null
        ? null
        : PlaybackBrowseEntry(
            item: previous,
            position: playback.position,
            wasPlaying: playback.desiredPlaying,
            queue: browseOrigin.queue,
            queueOwner: browseOrigin.queueOwner,
          );
    final session = BilibiliWatchPlaylistSession.instance;
    if (session != null) {
      session.opened(plan);
    } else {
      playlist.prepareLibraryPlayback(
        plan.item,
        searchItems: plan.queue,
        useSearchResultsAsQueue: plan.queue != null,
      );
    }
    timeline.attachTo(plan.item.id);
    playback.prepareBilibiliStartup(plan.item.id, timeline.startup);
    timeline.followPlayback(playback, plan.item.id);
    await playback.playPlaylistItem(
      plan.item,
      autoPlay: true,
      startPosition: startAt,
    );
    if (playback.currentItem?.id == plan.item.id) {
      if (origin != null) {
        navigation.browseHistory.record(origin: origin, target: plan.item);
      } else {
        navigation.browseHistory.clear();
      }
      await noteOpenedWatch(plan);
      unawaited(
        fillImportedBilibiliWatchParts(
          service: service,
          library: library,
          playlist: playlist,
          plan: plan,
          bvid: bvid,
        ),
      );
    } else {
      launch.discardReady();
    }
  } catch (_) {
    launch.discardReady();
    rethrow;
  } finally {
    playback.removeListener(playbackChanged);
    launch.dispose();
  }
}

/// Keep the same bounded auto-import behavior for page entry and panel taps.
Future<void> fillImportedBilibiliWatchParts({
  required BilibiliDownloadService service,
  required LibraryService library,
  required PlaylistManager playlist,
  required BilibiliWatchPlan plan,
  required String bvid,
}) async {
  final info = plan.videoInfo;
  if (!plan.imported ||
      info.pages.length <= 1 ||
      info.pages.length > kBilibiliAutoFillPartLimit) {
    return;
  }
  try {
    final filled = await service.obtainStreamCardsForVideo(
      library,
      bvid: bvid,
      pages: [for (final part in info.pages) part.page],
      videoInfo: info,
    );
    if (filled.createdCount > 0) {
      playlist.reloadPlaylist();
      BilibiliWatchPlaylistSession.instance?.refresh();
    }
  } catch (error) {
    debugPrint('Filling parts of $bvid failed: $error');
  }
}
