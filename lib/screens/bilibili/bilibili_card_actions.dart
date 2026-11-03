import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/screens/bilibili/bilibili_watch_loading_page.dart';
import 'package:video_player_app/screens/bilibili_download_screen.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_history_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_open_timeline.dart';
import 'package:video_player_app/services/bilibili/bilibili_panel_playback.dart';
import 'package:video_player_app/services/bilibili/bilibili_stream_card.dart';
import 'package:video_player_app/services/bilibili/bilibili_watch_cards.dart';
import 'package:video_player_app/services/bilibili/bilibili_watch_launch.dart';
import 'package:video_player_app/services/bilibili/bilibili_watch_playlist.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playback_navigation_service.dart';
import 'package:video_player_app/services/playback_browse_history.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:video_player_app/utils/bilibili_image_url.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';

/// True while a loading page of a tapped video is open, so a second tap
/// does not open another.
bool _watchLaunchOpen = false;

/// Opens a video from a Bilibili page on the playback page. Pages take one
/// of these so tests can check the tap without starting playback.
/// [preview] is the title and cover the tapped entry shows.
typedef BilibiliVideoWatcher =
    Future<void> Function(
      BuildContext context, {
      required String bvid,
      int? page,
      Duration? startAt,
      BilibiliWatchPreview? preview,
    });

/// The tap on a video in search results, watch history, an uploader's posts,
/// a collection or a pasted link: plays [bvid] on the regular playback page.
///
/// A loading page opens right away with [preview] (or what is already known
/// of the video) and the video gets ready behind it; then the playback page
/// takes its place. Back on the loading page drops the request. See
/// [BilibiliWatchLoader] for the order of the steps.
///
/// By default a watch-only card is used (or the library card when one exists
/// for the BV + part) and nothing is added to the media library; with "auto
/// import on play" on, the library card is reused or created as before. [page]
/// null continues the part saved in the watch history, [startAt] overrides
/// the saved position.
///
/// [replaceCurrent] plays it on a page that takes the place of the open
/// playback page instead of one more page on top (the Bilibili panel of the
/// playback page, and Bilibili pages opened above it). Null decides by
/// itself: replace whenever a playback page is on the stack. The video being
/// left has its position saved first.
/// [rememberCurrent] additionally keeps a return visit for description links;
/// part/queue selections keep their ordinary playback navigation.
Future<void> watchBilibiliVideo(
  BuildContext context, {
  required String bvid,
  int? page,
  Duration? startAt,
  bool? replaceCurrent,
  bool rememberCurrent = false,
  BilibiliWatchPreview? preview,
}) {
  final service = context.read<BilibiliDownloadService>();
  final library = context.read<LibraryService>();
  final playback = context.read<MediaPlaybackService>();
  final sources = BilibiliWatchSources.current;
  final replace =
      replaceCurrent ?? PlaybackNavigationService.instance.hasPlaybackPage;
  return _openLoadingPage(
    context,
    bvid: bvid,
    page: resolveBilibiliWatchStart(
      entry: BilibiliHistoryService.instance.watchEntryOf(bvid),
      requestedPage: page,
      startAt: startAt,
      historyEnabled: SettingsService().bilibiliRecordWatchHistory,
    ).page,
    preview: preview ?? sources.previewOf(bvid) ?? _historyPreview(bvid),
    replace: replace,
    browseOrigin: rememberCurrent && replace
        ? PlaybackNavigationService.instance.captureBrowseOrigin(
            playback,
            context.read<PlaylistManager>(),
          )
        : null,
    load: (attempt) async {
      await service.init();
      if (replace) await saveCurrentWatchPosition(playback);
      final loader = BilibiliWatchLoader(
        service: service,
        library: library,
        bvid: bvid,
        page: page,
        startAt: startAt,
        playingItemId: playback.currentItem?.id,
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
      );
      return loader(attempt);
    },
  );
}

/// "Play" on an in-app Bilibili page: reuse or create the online card for
/// [bvid] part [page], then open it on the regular playback page (through
/// the same loading page as [watchBilibiliVideo]).
Future<void> playBilibiliVideoAsCard(
  BuildContext context, {
  required String bvid,
  required int page,
}) {
  final service = context.read<BilibiliDownloadService>();
  final library = context.read<LibraryService>();
  return _openLoadingPage(
    context,
    bvid: bvid,
    page: page,
    preview: BilibiliWatchSources.current.previewOf(bvid),
    replace: PlaybackNavigationService.instance.hasPlaybackPage,
    load: (attempt) async {
      await service.init();
      BilibiliWatchHistoryEntry? historyEntry;
      final batch = await obtainBilibiliPlaybackCard(
        service,
        library,
        bvid: bvid,
        page: page,
        // Written once the playback page opens.
        recordHistory: false,
        onHistoryEntry: (entry) => historyEntry = entry,
      );
      final item = batch.cards.first.item;
      BilibiliWatchCards.instance?.track(item);
      attempt.timeline.mark('card ready');
      return BilibiliWatchPlan(
        item: item,
        videoInfo: batch.videoInfo,
        imported: true,
        historyEntry: historyEntry,
      );
    },
  );
}

BilibiliWatchPreview? _historyPreview(String bvid) {
  final entry = BilibiliHistoryService.instance.watchEntryOf(bvid);
  if (entry == null) return null;
  return BilibiliWatchPreview(
    title: entry.title,
    coverUrl: bilibiliCoverThumbnailUrl(entry.coverUrl),
  );
}

Future<void> _openLoadingPage(
  BuildContext context, {
  required String bvid,
  required int page,
  required BilibiliWatchPreview? preview,
  required bool replace,
  PlaybackBrowseEntry? browseOrigin,
  required Future<BilibiliWatchPlan> Function(BilibiliWatchAttempt attempt)
  load,
}) {
  if (_watchLaunchOpen) return Future<void>.value();
  final service = context.read<BilibiliDownloadService>();
  final library = context.read<LibraryService>();
  final playback = context.read<MediaPlaybackService>();
  final playlist = context.read<PlaylistManager>();
  final tapped = BilibiliOpenTimeline(bvid)..mark('tap');
  var firstTry = true;
  BilibiliOpenTimeline timeline() {
    if (!firstTry) return BilibiliOpenTimeline(bvid)..mark('retry');
    firstTry = false;
    return tapped;
  }

  final closed = Completer<void>();
  _watchLaunchOpen = true;
  unawaited(
    pushAboveMediaLibrary(
      context,
      AppMaterialPageRoute<void>(
        settings: RouteSettings(
          name: BilibiliWatchLoadingPage.routeName,
          arguments: bvid,
        ),
        builder: (_) => BilibiliWatchLoadingPage(
          bvid: bvid,
          page: page,
          preview: preview,
          timeline: timeline,
          load: load,
          open: (navigator, page, plan, timeline) => _openWatchPlan(
            navigator,
            page,
            plan,
            timeline,
            replace: replace,
            bvid: bvid,
            service: service,
            library: library,
            playback: playback,
            playlist: playlist,
            browseOrigin: browseOrigin,
          ),
          discard: (plan, kept) => discardAbandonedWatch(
            plan,
            keep: <String>{
              ...?kept?.itemIds,
              // The Bilibili playlist's entries stay.
              ...?BilibiliWatchPlaylistSession.instance?.queuedItemIds(),
            },
            library: library,
            playingItemId: playback.currentItem?.id,
            openPageItemIds: _openPlaybackPageItemIds(),
            cards: BilibiliWatchCards.instance,
          ),
          onClosed: () {
            _watchLaunchOpen = false;
            if (!closed.isCompleted) closed.complete();
          },
        ),
      ),
    ),
  );
  return closed.future;
}

Iterable<String> _openPlaybackPageItemIds() sync* {
  yield* PlaybackNavigationService.instance.browseHistory.itemIds;
  for (final route in PlaybackNavigationService.instance.observer.routes) {
    final id = route.settings.arguments;
    if (PlaybackNavigationService.isPlaybackRouteName(route.settings.name) &&
        id is String) {
      yield id;
    }
  }
}

/// The ready video takes the place of the loading page [page] on the
/// regular playback page, or of the open playback page when [replace].
Future<void> _openWatchPlan(
  NavigatorState navigator,
  Route<dynamic> page,
  BilibiliWatchPlan plan,
  BilibiliOpenTimeline timeline, {
  required bool replace,
  required String bvid,
  required BilibiliDownloadService service,
  required LibraryService library,
  required MediaPlaybackService playback,
  required PlaylistManager playlist,
  PlaybackBrowseEntry? browseOrigin,
}) async {
  final item = plan.item;
  // The old video may have continued playing (or been paused) while the link
  // loaded. Resume at the point actually left, keeping its original queue.
  final origin =
      browseOrigin != null && playback.currentItem?.id == browseOrigin.item.id
      ? PlaybackBrowseEntry(
          item: browseOrigin.item,
          position: playback.position,
          wasPlaying: playback.desiredPlaying,
          queue: browseOrigin.queue,
          queueOwner: browseOrigin.queueOwner,
        )
      : null;
  // Only a watch that really opens goes into the history.
  unawaited(noteOpenedWatch(plan));
  timeline.attachTo(item.id);
  playback.prepareBilibiliStartup(item.id, timeline.startup);
  timeline.followPlayback(playback, item.id);
  final existingController = playback.currentItem?.id == item.id
      ? playback.controller
      : null;
  final watchList = BilibiliWatchPlaylistSession.instance;
  if (watchList != null) {
    // The video joins the temporary Bilibili playlist, which becomes the
    // queue (before playback starts, which keeps a queue holding it).
    watchList.opened(plan);
  } else {
    playlist.prepareLibraryPlayback(
      item,
      searchItems: plan.queue,
      useSearchResultsAsQueue: plan.queue != null,
    );
  }
  final navigation = PlaybackNavigationService.instance;
  navigation.primeLibraryPlaybackEntry(
    playbackService: playback,
    item: item,
    existingController: existingController,
  );
  // The playback page takes the place of this page at once, without a
  // transition: the loading page already shows the cover where the playback
  // page shows it.
  if (replace) {
    // Every playback page under this page goes as well.
    await navigation.replaceCurrentPlayback(
      item,
      inPlaceOf: page,
      browseOrigin: origin,
    );
  } else if (page.isActive) {
    navigator.replace(
      oldRoute: page,
      newRoute: PlaybackNavigationService.buildPlaybackEntryRoute(
        item,
        existingController: existingController,
      ),
    );
  }
  timeline.mark('playback page pushed');
  unawaited(
    fillImportedBilibiliWatchParts(
      service: service,
      library: library,
      playlist: playlist,
      plan: plan,
      bvid: bvid,
    ),
  );
}

/// Card half of [playBilibiliVideoAsCard]: reuses or creates the online card
/// for [bvid] part [page] and records the watch history entry (or with
/// [recordHistory] false hands it to [onHistoryEntry]). Opening the playback
/// page is left to the caller.
Future<BilibiliStreamCardBatch> obtainBilibiliPlaybackCard(
  BilibiliDownloadService service,
  LibraryService library, {
  required String bvid,
  required int page,
  BilibiliHistoryService? history,
  bool recordHistory = true,
  void Function(BilibiliWatchHistoryEntry entry)? onHistoryEntry,
}) async {
  final batch = await service.obtainStreamCardsForVideo(
    library,
    bvid: bvid,
    pages: <int>[page],
  );
  final card = batch.cards.first.item;
  final entry = bilibiliWatchHistoryEntry(
    info: batch.videoInfo,
    bvid: bvid,
    page: card.sourceRef?.page ?? page,
  );
  if (recordHistory) {
    await noteOpenedWatch(
      BilibiliWatchPlan(
        item: card,
        videoInfo: batch.videoInfo,
        imported: true,
        historyEntry: entry,
      ),
      history: history,
    );
  }
  onHistoryEntry?.call(entry);
  return batch;
}

/// Saves where the current video is before another one takes its page: the
/// card's position, and for a Bilibili video its watch history entry. The
/// left watch-only card is then removed by the usual clean-up once its page
/// is gone.
Future<void> saveCurrentWatchPosition(
  MediaPlaybackService playback, {
  BilibiliWatchCards? cards,
}) async {
  final current = playback.currentItem;
  if (current == null) return;
  try {
    await playback.persistCurrentProgress(expectedItemId: current.id);
    await (cards ?? BilibiliWatchCards.instance)?.recorder.flush(current.id);
  } catch (error) {
    // Saving is best effort and never blocks the next video.
    developer.log('Position before switching not saved', error: error);
  }
}

/// "Download": hands the BV + part to the existing Bilibili download page.
Future<void> openBilibiliVideoDownload(
  BuildContext context, {
  required String bvid,
  required int page,
  required int partCount,
}) {
  final input = partCount > 1
      ? 'https://www.bilibili.com/video/$bvid?p=$page'
      : 'https://www.bilibili.com/video/$bvid';
  return pushAboveMediaLibrary(
    context,
    AppMaterialPageRoute<void>(
      builder: (_) =>
          BilibiliDownloadScreen(initialInput: input, initialPage: page),
    ),
  );
}
