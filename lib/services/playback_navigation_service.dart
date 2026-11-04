import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:video_player_app/theme/playback_page_route.dart';
import 'package:video_player/video_player.dart' show VideoPlayerController;

import '../models/video_item.dart';
import '../widgets/playback_source_viewport.dart';
import '../screens/portrait_video_screen.dart';
import '../screens/video_player_screen.dart';
import '../utils/app_toast.dart';
import 'settings_service.dart';
import 'community_media_input.dart';
import 'media_playback_service.dart';
import 'playback_browse_history.dart';
import 'playlist_manager.dart';

bool resolvePlaybackPageEntryAutoPlay({
  required bool? entryAutoPlay,
  required bool isCurrentItem,
  required bool desiredPlaying,
}) {
  // Enabling page-entry auto-play is an explicit request to start/resume.
  if (entryAutoPlay == true) return true;

  // Opening the page must never pause an already-active session when the
  // setting is off. This also preserves pause/play state during portrait ↔
  // landscape hand-offs and notification/mini-player navigation.
  if (isCurrentItem) return desiredPlaying;

  // null is used by internal/non-library routes and keeps their legacy
  // behavior. A library entry always supplies the persisted boolean.
  return entryAutoPlay ?? true;
}

class PlaybackNavigationService {
  PlaybackNavigationService._() {
    observer.onPlaybackPagesClosed = () {
      if (!_suppressAutoPauseOnRouteCleanup) browseHistory.clear();
    };
  }

  static final PlaybackNavigationService instance =
      PlaybackNavigationService._();

  static const String portraitRouteName = '/playback/portrait';
  static const String landscapeRouteName = '/playback/landscape';

  final PlaybackRouteObserver observer = PlaybackRouteObserver();
  Future<void> _navigationQueue = Future<void>.value();
  bool _suppressAutoPauseOnRouteCleanup = false;
  final Object _navigationVisibilityOwner = Object();
  final browseHistory = PlaybackBrowseHistory();
  bool _restoringBrowseVisit = false;
  bool _exitingWindowFullScreen = false;

  Future<bool> exitWindowFullScreenIfNeeded() async {
    if (_exitingWindowFullScreen) return true;
    if (kIsWeb ||
        !(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return false;
    }
    final settings = SettingsService();
    if (!settings.isFullScreen) return false;
    _exitingWindowFullScreen = true;
    try {
      await settings.toggleFullScreen();
    } finally {
      _exitingWindowFullScreen = false;
    }
    return true;
  }

  Future<void> _enqueueNavigation(Future<void> Function() action) {
    final next = _navigationQueue.then((_) => action());
    // A failed operation must not disable all subsequent navigation.
    _navigationQueue = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        debugPrint('Playback navigation failed: $error');
      },
    );
    return next;
  }

  PlaybackBrowseEntry? captureBrowseOrigin(
    MediaPlaybackService playback,
    PlaylistManager playlist,
  ) {
    final item = playback.currentItem;
    if (item == null || !hasPlaybackPage) return null;
    return PlaybackBrowseEntry(
      item: item,
      position: playback.position,
      wasPlaying: playback.desiredPlaying,
      queue: playlist.playlist,
      queueOwner: playlist.queueOwner,
    );
  }

  /// Leave a nested landscape page before stepping through visited videos.
  Future<bool> returnToBrowseOrigin(
    MediaPlaybackService playback,
    PlaylistManager playlist,
  ) async {
    if (_restoringBrowseVisit) return true;
    final players = observer.routes.where(
      (route) => isPlaybackRouteName(route.settings.name),
    );
    if (players.length > 1) return false;
    final current = playback.currentItem;
    if (current == null) return false;
    final entry = browseHistory.previousFor(current);
    if (entry == null) return false;
    final sourceRoute = observer.topRoute;
    _restoringBrowseVisit = true;
    try {
      await _enqueueNavigation(() async {
        if (sourceRoute == null ||
            !sourceRoute.isActive ||
            sourceRoute != observer.topRoute ||
            playback.currentItem?.id != current.id) {
          return;
        }
        playlist.setPlaylist(
          entry.queue,
          currentItemId: entry.item.id,
          owner: entry.queueOwner,
        );
        _holdPlaybackPageVisibleUntilOwned(playback);
        unawaited(
          playback.play(
            entry.item,
            startPosition: entry.position,
            autoPlay: entry.wasPlaying,
            keepBookmarkOnFailure: true,
          ),
        );
        await _openPlaybackInternal(
          entry.item,
          entryAutoPlay: entry.wasPlaying,
        );
        browseHistory.returned(entry);
      });
    } catch (error) {
      AppToast.show('无法返回上个视频，请重试', type: AppToastType.error);
    } finally {
      _restoringBrowseVisit = false;
    }
    return true;
  }

  void clearBrowseHistoryOnExit() {
    final players = observer.routes.where(
      (route) => isPlaybackRouteName(route.settings.name),
    );
    if (players.length <= 1) browseHistory.clear();
  }

  bool get suppressAutoPauseOnRouteCleanup => _suppressAutoPauseOnRouteCleanup;

  /// 在临时抑制"退出自动暂停"的前提下移除路由，
  /// 避免被移除的播放页在清理时误暂停仍在播放的控制器。
  void removeRouteSuppressed(NavigatorState navigator, Route<dynamic> route) {
    _suppressAutoPauseOnRouteCleanup = true;
    try {
      navigator.removeRoute(route);
    } finally {
      _suppressAutoPauseOnRouteCleanup = false;
    }
  }

  static bool isPlaybackRouteName(String? routeName) {
    return routeName == portraitRouteName ||
        routeName == landscapeRouteName ||
        routeName == '/playback/podcast';
  }

  static RouteSettings portraitRouteSettings(VideoItem item) {
    return RouteSettings(name: portraitRouteName, arguments: item.id);
  }

  static RouteSettings landscapeRouteSettings(VideoItem item) {
    return RouteSettings(name: landscapeRouteName, arguments: item.id);
  }

  Route<void> buildPortraitRoute(VideoItem item) {
    requireCommunityLocalMedia(item.path);
    return buildPlaybackPageRoute<void>(
      builder: (context) => PortraitVideoScreen(videoItem: item),
      settings: portraitRouteSettings(item),
    );
  }

  /// 通知栏点击与媒体卡片使用同一入口页：默认竖屏，开启「跳过竖屏播放页」
  /// 时直接进入横屏。不传入自动播放参数，已在播的会话保持当前播放状态。
  Route<void> buildNotificationPlaybackRoute(VideoItem item) {
    requireCommunityLocalMedia(item.path);
    if (entrySkipsPortraitPlayer) {
      return buildPlaybackPageRoute<void>(
        settings: landscapeRouteSettings(item),
        builder: (context) => VideoPlayerScreen(videoItem: item),
      );
    }
    return buildPortraitRoute(item);
  }

  /// 桌面端以及开启"跳过竖屏播放页"的移动端，直接进入横屏播放页。
  static bool get entrySkipsPortraitPlayer {
    if (kIsWeb) return true;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      return true;
    }
    return SettingsService().skipPortraitPlayer;
  }

  /// 媒体卡片点击后的统一播放入口路由：
  /// 桌面端或开启"跳过竖屏播放页"时直入横屏播放页，否则进入竖屏播放页。
  /// 播放页使用实时的轻量淡入缩放；浏览页保持原位，不读取视频纹理快照。
  /// 视频进入时保留即时启动，退出时从首个动画帧计时。
  static Route<void> buildPlaybackEntryRoute(
    VideoItem item, {
    VideoPlayerController? existingController,
    bool? entryAutoPlay,
  }) {
    final override = entryRouteOverrideForTesting;
    if (override != null) return override(item);
    requireCommunityLocalMedia(item.path);
    final autoPlayOnEntry =
        entryAutoPlay ?? SettingsService().autoPlayOnPageEntry;
    if (entrySkipsPortraitPlayer) {
      return buildPlaybackPageRoute<void>(
        settings: landscapeRouteSettings(item),
        builder: (context) => VideoPlayerScreen(
          videoItem: item,
          existingController: existingController,
          autoPlayOnEntry: autoPlayOnEntry,
        ),
      );
    }
    return buildPlaybackPageRoute<void>(
      settings: portraitRouteSettings(item),
      builder: (context) => PortraitVideoScreen(
        videoItem: item,
        autoPlayOnEntry: autoPlayOnEntry,
      ),
    );
  }

  /// Replaces the playback page [buildPlaybackEntryRoute] builds, so tests
  /// can check the navigator stack without a player.
  @visibleForTesting
  static Route<void> Function(VideoItem item)? entryRouteOverrideForTesting;

  /// Each widget test runs in its own zone: a queue left by an earlier test
  /// would run its next step in that finished zone, which never comes.
  @visibleForTesting
  void resetNavigationQueueForTesting() {
    _navigationQueue = Future<void>.value();
    browseHistory.clear();
    _restoringBrowseVisit = false;
    _exitingWindowFullScreen = false;
  }

  /// Shared live transition for portrait, landscape and podcast playback.
  /// Video keeps its immediate entry clock while source preparation overlaps
  /// navigation; audio podcasts can still align their first animation tick.
  static PlaybackPageRoute<T> buildPlaybackPageRoute<T>({
    required WidgetBuilder builder,
    RouteSettings? settings,
    bool delayPushOneFrame = false,
  }) {
    return PlaybackPageRoute<T>(
      builder: builder,
      settings: settings,
      delayPushOneFrame: delayPushOneFrame,
    );
  }

  /// Whether a playback page is on the app navigator's stack.
  bool get hasPlaybackPage =>
      observer.routes.any((route) => isPlaybackRouteName(route.settings.name));

  /// Shows [item] on a playback page that takes the place of the open one:
  /// every playback page on the stack is removed (without pausing the
  /// session, which has already moved on to [item]) and one page for [item]
  /// is pushed on top. Playing another video from a page's Bilibili panel, or
  /// from a Bilibili page opened above the player, so never piles playback
  /// pages up. Nothing happens when the top page already shows [item].
  /// [inPlaceOf] is the page the new playback page takes the place of at
  /// once, without a transition (the Bilibili loading page); null pushes it.
  Future<void> replaceCurrentPlayback(
    VideoItem item, {
    Route<dynamic>? inPlaceOf,
    PlaybackBrowseEntry? browseOrigin,
  }) {
    return _enqueueNavigation(() async {
      if (inPlaceOf != null && !inPlaceOf.isActive) return;
      await _openPlaybackInternal(item, inPlaceOf: inPlaceOf);
      if (browseOrigin != null) {
        browseHistory.record(origin: browseOrigin, target: item);
      } else {
        browseHistory.clear();
      }
    });
  }

  Future<void> openPortraitFromNotification(VideoItem item) async {
    return _enqueueNavigation(
      () => _openPlaybackInternal(item, notificationEntry: true),
    );
  }

  /// Opens the authoritative current session for both notification and mini
  /// player taps. The temporary visibility owner lets Android create a real
  /// video output before the route exists, while navigation happens as soon as
  /// that controller is mountable (first-frame readiness may then complete).
  Future<void> openCurrentPlaybackSession(
    MediaPlaybackService playbackService, {
    int? expectedGeneration,
  }) async {
    return _enqueueNavigation(() async {
      // Generations only move forward. A delayed tap is allowed to converge on
      // a newer current session, but must never navigate using a service that
      // has somehow been reset behind the captured notification generation.
      if (expectedGeneration != null &&
          playbackService.sessionGeneration < expectedGeneration) {
        return;
      }
      var item = playbackService.currentItem;
      if (item == null) return;
      if (!communityMediaIsLocal(item.path)) {
        await _openPlaybackInternal(item);
        return;
      }

      // Keep the warmup owner until a real playback page registers. Dropping
      // it after one frame used to deselect Bilibili's video track while the
      // route was still mounting, painting a black texture over a ready stream.
      _holdPlaybackPageVisibleUntilOwned(playbackService, maxAttempts: 1800);
      if (MediaPlaybackService.shouldStartPlayWhenOpeningMiniSession(
        hasController: playbackService.controller != null,
        state: playbackService.state,
      )) {
        // Restored Mini chrome has metadata only. Start prepare now so the
        // playback page does not wait 25s for a player that was never created.
        // Skip this when restore is already preparing the same item at its
        // saved position.
        unawaited(
          playbackService.play(
            item,
            autoPlay: resolvePlaybackPageEntryAutoPlay(
              entryAutoPlay: SettingsService().autoPlayOnPageEntry,
              isCurrentItem: true,
              desiredPlaying: playbackService.desiredPlaying,
            ),
            startPosition: MediaPlaybackService.startPositionForCurrentSession(
              currentItemId: playbackService.currentItem?.id,
              itemId: item.id,
              currentPosition: playbackService.position,
            ),
          ),
        );
      }
      // Do not await video attach/enable. The page should open on the live
      // audio clock immediately; the texture catches up under the poster.
      if (playbackService.needsVisibleVideoOutputRecovery(item.id)) {
        unawaited(playbackService.ensureVisibleVideoOutput(item.id));
      }
      item = playbackService.currentItem;
      if (item == null) return;
      await _openPlaybackInternal(item);
    });
  }

  /// Starts source preparation as soon as a library card is tapped, overlapping
  /// the page-route animation. Also marks a playback page as imminent so a
  /// Bilibili split stream keeps its video track selected during initialize.
  void primeLibraryPlaybackEntry({
    required MediaPlaybackService playbackService,
    required VideoItem item,
    VideoPlayerController? existingController,
  }) {
    if (!communityMediaIsLocal(item.path)) return;
    _holdPlaybackPageVisibleUntilOwned(playbackService);

    if (existingController != null) return;
    if (playbackService.currentItem?.id == item.id &&
        playbackService.controller != null) {
      return;
    }

    unawaited(
      playbackService.play(
        item,
        autoPlay: resolvePlaybackPageEntryAutoPlay(
          entryAutoPlay: SettingsService().autoPlayOnPageEntry,
          isCurrentItem: playbackService.currentItem?.id == item.id,
          desiredPlaying: playbackService.desiredPlaying,
        ),
        startPosition: MediaPlaybackService.startPositionForCurrentSession(
          currentItemId: playbackService.currentItem?.id,
          itemId: item.id,
          currentPosition: playbackService.position,
        ),
      ),
    );
  }

  /// Keep the warmup owner until a real playback page registers. Dropping it on
  /// the first frame can deselect Bilibili's video track while the route is
  /// still mounting, which paints a black texture over an already-ready stream.
  void _holdPlaybackPageVisibleUntilOwned(
    MediaPlaybackService playbackService, {
    int maxAttempts = 12,
  }) {
    playbackService.setPlaybackPageVisible(_navigationVisibilityOwner, true);
    var attempts = 0;
    void releaseWhenPageOwnsIt() {
      attempts++;
      if (playbackService.hasPlaybackPageOwnerOtherThan(
            _navigationVisibilityOwner,
          ) ||
          attempts >= maxAttempts) {
        playbackService.setPlaybackPageVisible(
          _navigationVisibilityOwner,
          false,
        );
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        releaseWhenPageOwnsIt();
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      releaseWhenPageOwnsIt();
    });
  }

  /// Notification body taps follow the pre-streaming behavior: navigate to
  /// the service's current item immediately. They must not join video-output
  /// recovery or reopen the media, because a control-button episode change
  /// may still be settling when Android brings the app to the foreground.
  Future<void> openCurrentPlaybackSessionFromNotification(
    MediaPlaybackService playbackService, {
    int? expectedGeneration,
  }) async {
    return _enqueueNavigation(() async {
      if (expectedGeneration != null &&
          playbackService.sessionGeneration < expectedGeneration) {
        return;
      }
      final item = playbackService.currentItem;
      if (item == null) return;
      if (!communityMediaIsLocal(item.path)) {
        await _openPlaybackInternal(item, notificationEntry: true);
        return;
      }
      final warmOnlineVideo = playbackService.isCurrentItemOnlineBilibiliStream;
      if (warmOnlineVideo) {
        _holdPlaybackPageVisibleUntilOwned(playbackService, maxAttempts: 1800);
        if (playbackService.needsVisibleVideoOutputRecovery(item.id)) {
          unawaited(playbackService.ensureVisibleVideoOutput(item.id));
        }
      }
      await _openPlaybackInternal(item, notificationEntry: true);
    });
  }

  Future<void> _openPlaybackInternal(
    VideoItem item, {
    bool notificationEntry = false,
    Route<dynamic>? inPlaceOf,
    bool? entryAutoPlay,
  }) async {
    if (!communityMediaIsLocal(item.path)) {
      AppToast.show('社区版仅支持本地媒体，请导入本地文件', type: AppToastType.info);
      return;
    }
    final navigator = await _waitForNavigator();
    if (navigator == null) {
      return;
    }
    // The page to take the place of was closed in the meantime.
    if (inPlaceOf != null && !inPlaceOf.isActive) return;

    final trackedRoutes = observer.routes;
    final playbackRoutes = trackedRoutes
        .where((route) => isPlaybackRouteName(route.settings.name))
        .toList(growable: false);

    final Route<dynamic>? topRoute = observer.topRoute;
    final bool alreadyOnTargetPlayback =
        topRoute != null &&
        isPlaybackRouteName(topRoute.settings.name) &&
        topRoute.settings.arguments == item.id;
    final String notificationRouteName = entrySkipsPortraitPlayer
        ? landscapeRouteName
        : portraitRouteName;
    // A notification entry has one canonical mobile back stack: media library
    // root -> the page selected by "skip portrait player". Merely finding the
    // target item on top is insufficient, because a stale MusicPlayerScreen
    // may still sit below it, or the page may be the other orientation.
    final bool hasCanonicalNotificationStack =
        notificationEntry &&
        trackedRoutes.length == 2 &&
        alreadyOnTargetPlayback &&
        topRoute.settings.name == notificationRouteName &&
        trackedRoutes.first.isFirst;
    if ((!notificationEntry && alreadyOnTargetPlayback) ||
        hasCanonicalNotificationStack) {
      return;
    }

    // Construct the destination before mutating the live stack. If a route
    // factory fails, the current player must still be available.
    final route = notificationEntry
        ? buildNotificationPlaybackRoute(item)
        : buildPlaybackEntryRoute(item, entryAutoPlay: entryAutoPlay);
    _suppressAutoPauseOnRouteCleanup = true;
    try {
      final routesToRemove = notificationEntry
          ? trackedRoutes.skip(1).toList(growable: false)
          : playbackRoutes;
      for (final route in routesToRemove.reversed) {
        navigator.removeRoute(route);
      }

      // Notification taps use the same page as media cards. With "skip
      // portrait player" on, that is the landscape page; otherwise portrait.
      // The stack is reset to the media-library root first, so popping the
      // player returns there.
      if (inPlaceOf != null) {
        navigator.replace(oldRoute: inPlaceOf, newRoute: route);
      } else {
        unawaited(navigator.push(route));
      }
    } finally {
      _suppressAutoPauseOnRouteCleanup = false;
    }
  }

  Future<NavigatorState?> _waitForNavigator() async {
    final navigator = AppToast.navigatorKey.currentState;
    if (navigator != null) {
      return navigator;
    }

    final completer = Completer<NavigatorState?>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      completer.complete(AppToast.navigatorKey.currentState);
    });
    return completer.future;
  }
}

class PlaybackRouteObserver extends NavigatorObserver {
  final List<Route<dynamic>> _routes = <Route<dynamic>>[];
  VoidCallback? onPlaybackPagesClosed;

  void _notifyPlaybackExit(Route<dynamic> route) {
    if (PlaybackNavigationService.isPlaybackRouteName(route.settings.name) &&
        !routes.any(
          (entry) => PlaybackNavigationService.isPlaybackRouteName(
            entry.settings.name,
          ),
        )) {
      onPlaybackPagesClosed?.call();
    }
  }

  List<Route<dynamic>> get routes => List.unmodifiable(
    _routes.where((route) => route.isActive && route.navigator == navigator),
  );
  Route<dynamic>? get topRoute => routes.lastOrNull;

  void _recordPush(Route<dynamic> route) {
    // An observer can be attached to a new Navigator after its old one is
    // disposed. Never retain dead routes from that earlier navigation tree.
    _routes.removeWhere(
      (entry) => !entry.isActive || entry.navigator != navigator,
    );
    _routes.remove(route);
    _routes.add(route);
  }

  void _recordRemoval(Route<dynamic> route) {
    _routes.remove(route);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _recordPush(route);
    PlaybackViewportRegistry.updateRoutes(_routes);
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _recordRemoval(route);
    PlaybackViewportRegistry.updateRoutes(_routes);
    _notifyPlaybackExit(route);
    super.didPop(route, previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _recordRemoval(route);
    PlaybackViewportRegistry.updateRoutes(_routes);
    _notifyPlaybackExit(route);
    super.didRemove(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) {
      _recordRemoval(oldRoute);
    }
    if (newRoute != null) {
      _recordPush(newRoute);
    }
    PlaybackViewportRegistry.updateRoutes(_routes);
    if (oldRoute != null) _notifyPlaybackExit(oldRoute);
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }
}
