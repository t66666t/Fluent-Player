import 'ui_refresh_rate_scope.dart';
import 'media_library_folder_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../services/media_playback_service.dart';
import '../services/playback_navigation_service.dart';
import '../services/clipboard_detection_routes.dart';
import '../utils/app_toast.dart';
import '../utils/stable_system_ui_insets.dart';
import '../theme/app_tokens.dart';
import 'media_library_search_prompt.dart';
import 'clipboard_detection_scope.dart';
import 'mini_playback_card.dart';
import 'media_library_tooltip.dart';
import 'playback_card_layout.dart';

/// The library must stay live while a covering page zooms in or out: a route
/// snapshot would freeze the mini player's title while its ticker advances.
/// Only this route opts out; covering pages keep their own snapshot policy.
MaterialPageRoute<T> buildMediaLibraryShellRoute<T>({
  required Widget home,
  RouteSettings? settings,
}) {
  return MaterialPageRoute<T>(
    settings: settings,
    allowSnapshotting: false,
    builder: (_) => MediaLibraryShell(home: home),
  );
}

/// The page frame shared by the media library: home, folders and search
/// results switch inside it while the one mini player stays put.
///
/// Library pages live on the frame's own navigator. Every other page (the
/// players, the Bilibili loading page and sub pages, downloads, the recycle
/// bin, ...) goes on the app navigator above the frame through
/// [pushAboveMediaLibrary], so it covers the mini player like it covers the
/// library itself.
class MediaLibraryShell extends StatefulWidget {
  const MediaLibraryShell({super.key, required this.home});

  /// First page of the frame's navigator.
  final Widget home;

  /// The dimming laid over the mini player while files are dragged in.
  static const Key miniPlayerDropCoverKey = ValueKey<String>(
    'media-library-mini-player-drop-cover',
  );

  /// The frame around [context], or null outside one (tests that pump a
  /// library page on its own). Does not rebuild [context] on changes.
  static MediaLibraryShellController? maybeOf(BuildContext context) {
    return context
        .getInheritedWidgetOfExactType<_MediaLibraryShellScope>()
        ?.controller;
  }

  /// How far the mini player is lifted for the page on top, so list padding
  /// can keep the last row above both the player and the selection bar.
  ///
  /// Subscribes [context]. Pointer handlers should use
  /// [selectionBarObstructionPeek], which reads without subscribing.
  static double selectionBarObstructionOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_MediaLibraryShellScope>();
    return scope?.selectionBarObstruction ?? 0.0;
  }

  /// The selection-bar lift of the page that owns [context], without
  /// subscribing. For drag handlers that run outside of build.
  static double selectionBarObstructionPeek(BuildContext context) {
    final shell = maybeOf(context);
    final route = ModalRoute.of(context);
    if (shell == null || route == null) return 0.0;
    return shell.selectionBarObstructionOfRoute(route);
  }

  /// The stable bottom inset of the library page at [context], so its action
  /// buttons line up with the mini player the frame shows over it.
  ///
  /// Only visible routes observe window changes. Transient system-bar
  /// animations are stabilized; a settled smaller inset can shrink again.
  static double? stableBottomInsetOf(BuildContext context) {
    // A returning page may have a different retained inset even when the
    // shell's visible inset did not change. Observe this page's activation,
    // without relying on a whole-subtree reparent to refresh its reservation.
    ModalRoute.isCurrentOf(context);
    final scope = context
        .dependOnInheritedWidgetOfExactType<_MediaLibraryShellScope>();
    return scope?.insets.insetOf(context);
  }

  @override
  State<MediaLibraryShell> createState() => _MediaLibraryShellState();
}

/// What a library page may ask of the frame around it.
abstract class MediaLibraryShellController {
  /// The stable bottom inset of [route], a library page on the frame's
  /// navigator; null when [route] is not one.
  double? stableBottomInsetOfRoute(Route<dynamic> route);

  /// The app route that hosts the frame.
  ModalRoute<dynamic>? get hostRoute;

  /// The frame's own navigator.
  NavigatorState? get libraryNavigator;

  /// Dims the mini player together with the page's own drop cover while
  /// files are dragged over the page of [owner].
  void setFileDropActive(Object owner, bool active);

  /// How tall [route]'s selection bar is. The mini player sits above that bar
  /// instead of covering its actions. Zero clears the reservation.
  void setSelectionBarObstruction(Route<dynamic> route, double height);

  /// The height last reported for [route], or zero when it has no bar.
  double selectionBarObstructionOfRoute(Route<dynamic> route);
}

/// The navigator for pages that must cover the media library and its mini
/// player.
NavigatorState mediaLibraryCoverNavigator(BuildContext context) {
  return Navigator.of(context, rootNavigator: true);
}

/// Opens [route] above the media library frame, covering the mini player.
///
/// Library pages (folders, search results, locate) stay on the frame's
/// navigator through `Navigator.of(context)`; everything else uses this.
Future<T?> pushAboveMediaLibrary<T extends Object?>(
  BuildContext context,
  Route<T> route,
) {
  return mediaLibraryCoverNavigator(context).push<T>(route);
}

/// Whether the library page at [context] is the page the user sees: its own
/// route is current and nothing covers the frame. Null when [context] has no
/// route at all.
bool? mediaLibraryRouteIsCurrent(BuildContext context) {
  final route = ModalRoute.of(context);
  if (route == null) return null;
  if (!route.isCurrent) return false;
  // Subscribe to the outer route as well as the nested library route. Popup
  // routes on the app navigator do not change the nested route's isCurrent.
  final shell = context
      .dependOnInheritedWidgetOfExactType<_MediaLibraryShellScope>();
  return shell?.hostIsCurrent ?? true;
}

/// [mediaLibraryRouteIsCurrent] with "no route" counted as not current.
bool isMediaLibraryRouteCurrent(BuildContext context) {
  return mediaLibraryRouteIsCurrent(context) == true;
}

class _MediaLibraryShellScope extends InheritedWidget {
  _MediaLibraryShellScope({
    required this.controller,
    required this.insets,
    required this.selectionBarObstruction,
    required this.bottomInset,
    required this.hostIsCurrent,
    required Widget child,
  }) : super(
         child: MediaLibraryTooltipScope(
           isCurrent: hostIsCurrent,
           child: child,
         ),
       );

  final MediaLibraryShellController controller;
  final _PageBottomInsets insets;

  /// Height of the top page's selection bar. Zero when that page has none.
  final double selectionBarObstruction;
  final double bottomInset;
  final bool hostIsCurrent;

  @override
  bool updateShouldNotify(_MediaLibraryShellScope oldWidget) {
    // The nested ModalRoute already publishes current-page changes. Repeating
    // that notification here rebuilds every inset consumer during push/pop,
    // even when its layout is unchanged (including the covered card grid).
    return controller != oldWidget.controller ||
        insets != oldWidget.insets ||
        bottomInset != oldWidget.bottomInset ||
        hostIsCurrent != oldWidget.hostIsCurrent ||
        selectionBarObstruction != oldWidget.selectionBarObstruction;
  }
}

/// Reservations belong to routes, but metrics belong to the visible window.
/// Hidden routes pause their timers until they are shown in that window again.
class _PageBottomInsets {
  _PageBottomInsets(this._routes, {required this.onChanged});

  final _LibraryRouteStack _routes;
  final VoidCallback onChanged;
  final Map<Route<dynamic>, StableSystemUiInsetController> _values = {};
  bool _active = true;
  MediaQueryData? _metrics;
  final Expando<Route<dynamic>> _routeOfContext = Expando<Route<dynamic>>(
    'media library page route',
  );

  double update(MediaQueryData mediaQuery, {required bool active}) {
    _active = active;
    if (active) _metrics = mediaQuery;
    for (final route in _values.keys.toList()) {
      if (!_routes.contains(route)) {
        _values.remove(route)!.dispose();
      } else if (!active || !identical(route, _routes.top)) {
        _values[route]!.pause();
      }
    }
    final top = _routes.top;
    if (top == null) {
      return PlaybackCardOverlayLayout.resolveStableBottomInset(
        mediaQuery,
        0.0,
      );
    }
    return _resolve(top, mediaQuery);
  }

  double? valueOf(Route<dynamic> route) {
    if (!_routes.contains(route)) return null;
    return _values[route]?.reservedBottom;
  }

  double? insetOf(BuildContext context) {
    final route = _routeOf(context);
    if (route == null) return null;
    // A Scaffold with extendBody injects its bottom bar's height into padding.
    // Never mistake that consumed/local padding for a physical system inset.
    return _resolve(
      route,
      _metrics ?? MediaQueryData.fromView(View.of(context)),
    );
  }

  double _resolve(Route<dynamic> route, MediaQueryData mediaQuery) {
    final controller = _values.putIfAbsent(
      route,
      () => StableSystemUiInsetController(
        includeSystemGestureInsets: true,
        onChanged: onChanged,
      ),
    );
    return controller
        .observe(mediaQuery, active: _active && identical(route, _routes.top))
        .bottom;
  }

  void dispose() {
    for (final controller in _values.values) {
      controller.dispose();
    }
    _values.clear();
  }

  Route<dynamic>? _routeOf(BuildContext context) {
    final cached = _routeOfContext[context];
    if (cached != null) return _routes.contains(cached) ? cached : null;
    final bySubtree = <Element, Route<dynamic>>{};
    for (final route in _routes.routes) {
      if (route is! ModalRoute<dynamic>) continue;
      final subtree = route.subtreeContext;
      if (subtree is Element) bySubtree[subtree] = route;
    }
    if (bySubtree.isEmpty) return null;
    Route<dynamic>? found = bySubtree[context];
    if (found == null) {
      context.visitAncestorElements((element) {
        found = bySubtree[element];
        return found == null;
      });
    }
    if (found != null) _routeOfContext[context] = found;
    return found;
  }
}

class _MediaLibraryShellState extends State<MediaLibraryShell>
    implements MediaLibraryShellController {
  static const Color _fillColor = AppTokens.bgCard;

  /// The fill under the dimming the library page shows over its own body.
  static final Color _droppedFillColor = Color.alphaBlend(
    Colors.black54,
    _fillColor,
  );

  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>(
    debugLabel: 'media-library',
  );
  late final _LibraryRouteStack _routeStack = _LibraryRouteStack(
    onChanged: _onRoutesChanged,
  );
  late final _PageBottomInsets _pageInsets = _PageBottomInsets(
    _routeStack,
    onChanged: _rebuildWhenTreeIsUnlocked,
  );
  late List<NavigatorObserver> _observers = <NavigatorObserver>[
    AppToast.createRouteChangeObserver(),
    _routeStack,
  ];
  final Set<Object> _fileDropOwners = <Object>{};
  final Map<Route<dynamic>, double> _selectionBarObstruction =
      <Route<dynamic>, double>{};
  final ValueNotifier<bool> _fileDropActive = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _searchResultsOnTop = ValueNotifier<bool>(false);
  bool _topSyncScheduled = false;
  ModalRoute<dynamic>? _hostRoute;
  ClipboardDetectionRoutes? _clipboardRoutes;
  ClipboardDetectionNavigatorObserver? _clipboardObserver;

  @override
  ModalRoute<dynamic>? get hostRoute => mounted ? _hostRoute : null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _hostRoute = ModalRoute.of(context);
    final clipboardRoutes = ClipboardDetectionScope.maybeOf(context)?.routes;
    if (!identical(clipboardRoutes, _clipboardRoutes)) {
      _observers = [
        for (final observer in _observers)
          if (!identical(observer, _clipboardObserver)) observer,
      ];
      _clipboardObserver?.dispose();
      _clipboardRoutes = clipboardRoutes;
      _clipboardObserver = clipboardRoutes?.observeNestedNavigator(
        hostRoute: () => _hostRoute,
      );
      if (_clipboardObserver != null) {
        _observers.add(_clipboardObserver!);
        final current = _routeStack.top;
        if (current != null) _clipboardObserver!.didChangeTop(current, null);
      }
    }
  }

  @override
  NavigatorState? get libraryNavigator => _navigatorKey.currentState;

  @override
  double? stableBottomInsetOfRoute(Route<dynamic> route) {
    return _pageInsets.valueOf(route);
  }

  @override
  void setSelectionBarObstruction(Route<dynamic> route, double height) {
    final next = height < 1 ? 0.0 : height;
    final previous = _selectionBarObstruction[route] ?? 0.0;
    if ((previous - next).abs() < 1) return;
    if (next == 0) {
      _selectionBarObstruction.remove(route);
    } else {
      _selectionBarObstruction[route] = next;
    }
    // A covered page can report while the user is selecting on it offstage.
    // Only the page on top moves the player the user can see.
    if (!identical(_routeStack.top, route)) return;
    _rebuildWhenTreeIsUnlocked();
  }

  @override
  double selectionBarObstructionOfRoute(Route<dynamic> route) {
    return _selectionBarObstruction[route] ?? 0.0;
  }

  double _topSelectionBarObstruction() {
    final top = _routeStack.top;
    if (top == null) return 0.0;
    return _selectionBarObstruction[top] ?? 0.0;
  }

  /// Animation ticks can rebuild before layout; page disposal must wait until
  /// the tree is unlocked. Keeping ticks in this frame avoids a one-frame lag
  /// between the selection bar and the mini player above it.
  void _rebuildWhenTreeIsUnlocked() {
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase != SchedulerPhase.persistentCallbacks) {
      if (mounted) setState(() {});
      return;
    }
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void setFileDropActive(Object owner, bool active) {
    final changed = active
        ? _fileDropOwners.add(owner)
        : _fileDropOwners.remove(owner);
    if (!changed) return;
    final next = _fileDropOwners.isNotEmpty;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      _fileDropActive.value = next;
      return;
    }
    // A page leaving the tree reports from dispose, while the tree is locked.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _fileDropActive.value = _fileDropOwners.isNotEmpty;
    });
  }

  void _onRoutesChanged() {
    _selectionBarObstruction.removeWhere(
      (route, _) => !_routeStack.contains(route),
    );
    _scheduleTopRouteSync();
    // The mini player sits at the top page's inset from the frame the page
    // opens or comes back, as it did when each page placed its own.
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else if (mounted) {
      setState(() {});
    }
  }

  void _scheduleTopRouteSync() {
    if (_topSyncScheduled) return;
    _topSyncScheduled = true;
    // Navigator reports pushes made while it builds; wait for the frame.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _topSyncScheduled = false;
      if (!mounted) return;
      _searchResultsOnTop.value =
          _routeStack.top?.settings.name == mediaLibrarySearchResultsRouteName;
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _clipboardObserver?.dispose();
    _pageInsets.dispose();
    _fileDropActive.dispose();
    _searchResultsOnTop.dispose();
    super.dispose();
  }

  List<Route<dynamic>> _initialRoutes(NavigatorState navigator, String name) {
    return <Route<dynamic>>[
      // Match folder routes' delegated transition from the first level.
      // A different transition makes Navigator wrap/unwrap the whole home
      // subtree during push/pop, reparenting every retained card and tab.
      buildMediaLibraryFolderRoute<void>(
        restored: true,
        builder: (_) => widget.home,
      ),
    ];
  }

  void _openPlayback(MediaPlaybackService playbackService) {
    if (playbackService.currentItem == null) {
      final item = playbackService.queuedPreviewItem;
      if (item == null) return;
      playbackService.playlistManager?.anchorCurrentItem(item);
      playbackService.publishRestoredSessionPreview(
        item,
        Duration(milliseconds: item.lastPositionMs),
      );
    }
    PlaybackNavigationService.instance.openCurrentPlaybackSession(
      playbackService,
      expectedGeneration: playbackService.sessionGeneration,
    );
  }

  @override
  Widget build(BuildContext context) {
    final stableBottomInset = _pageInsets.update(
      // The shell reserves system bars, not the keyboard. Observe only the
      // metrics used by StableSystemUiInsetController so IME height changes do
      // not reconstruct the nested navigator and mini player every frame.
      MediaQueryData(
        size: MediaQuery.sizeOf(context),
        devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        padding: MediaQuery.paddingOf(context),
        viewPadding: MediaQuery.viewPaddingOf(context),
        systemGestureInsets: MediaQuery.systemGestureInsetsOf(context),
      ),
      active: ModalRoute.isCurrentOf(context) ?? true,
    );
    // Selection actions live in the page scaffold, under this overlay. Lift
    // the player by the bar that is actually on screen so those buttons stay
    // visible and tappable.
    final selectionBarHeight = _topSelectionBarObstruction();
    final playbackCardBottom = PlaybackCardOverlayLayout.cardBottomAbove(
      stableBottomInset: stableBottomInset,
      selectionBarHeight: selectionBarHeight,
    );
    return UiRefreshRateScope(
      child: _MediaLibraryShellScope(
        controller: this,
        insets: _pageInsets,
        selectionBarObstruction: selectionBarHeight,
        bottomInset: stableBottomInset,
        hostIsCurrent: ModalRoute.isCurrentOf(context) ?? true,
        child: NavigatorPopHandler<Object?>(
          onPopWithResult: (_) => _navigatorKey.currentState?.maybePop(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Navigator(
                key: _navigatorKey,
                observers: _observers,
                onGenerateInitialRoutes: _initialRoutes,
              ),
              Positioned(
                key: MediaLibraryOverlayKeys.miniPlaybackCard,
                left: 0,
                right: 0,
                bottom: playbackCardBottom,
                child: Stack(
                  fit: StackFit.passthrough,
                  children: [
                    ValueListenableBuilder<bool>(
                      valueListenable: _searchResultsOnTop,
                      builder: (context, searchOnTop, child) {
                        return Theme(
                          data: searchOnTop
                              ? mediaLibrarySearchResultsTheme(
                                  Theme.of(context),
                                )
                              : Theme.of(context),
                          child: child!,
                        );
                      },
                      child: Consumer<MediaPlaybackService>(
                        builder: (context, playbackService, child) {
                          return MiniPlaybackCard(
                            isVisible:
                                playbackService.shouldShowMiniPlaybackCard,
                            onTap: () => _openPlayback(playbackService),
                          );
                        },
                      ),
                    ),
                    Positioned.fill(
                      child: IgnorePointer(
                        child: ValueListenableBuilder<bool>(
                          valueListenable: _fileDropActive,
                          builder: (context, dropActive, child) {
                            if (!dropActive) return const SizedBox.shrink();
                            return Selector<MediaPlaybackService, bool>(
                              selector: (_, playbackService) =>
                                  playbackService.shouldShowMiniPlaybackCard,
                              builder: (context, isVisible, child) {
                                if (!isVisible) return const SizedBox.shrink();
                                return const DecoratedBox(
                                  key: MediaLibraryShell.miniPlayerDropCoverKey,
                                  decoration: BoxDecoration(
                                    color: Colors.black54,
                                    borderRadius: BorderRadius.vertical(
                                      top: Radius.circular(16.0),
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Paint after the card so its downward shadow cannot darken the
              // gap or system navigation area. The upward shadow stays visible.
              Positioned(
                key: MediaLibraryOverlayKeys.playbackBottomFill,
                left: 0,
                right: 0,
                // Selection actions keep their own background below the card.
                bottom: selectionBarHeight,
                child: Selector<MediaPlaybackService, bool>(
                  selector: (_, playbackService) =>
                      playbackService.shouldShowMiniPlaybackCard,
                  builder: (context, isVisible, child) {
                    if (!isVisible) return const SizedBox.shrink();
                    return IgnorePointer(
                      child: ValueListenableBuilder<bool>(
                        valueListenable: _fileDropActive,
                        builder: (context, dropActive, child) {
                          return Container(
                            height: playbackCardBottom - selectionBarHeight,
                            color: dropActive ? _droppedFillColor : _fillColor,
                          );
                        },
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Keeps the frame navigator's routes in order, so the frame knows which
/// library page is on top.
class _LibraryRouteStack extends NavigatorObserver {
  _LibraryRouteStack({required this.onChanged});

  final VoidCallback onChanged;
  final List<Route<dynamic>> _routes = <Route<dynamic>>[];

  Route<dynamic>? get top => _routes.isEmpty ? null : _routes.last;

  Iterable<Route<dynamic>> get routes => _routes;

  bool contains(Route<dynamic> route) => _routes.contains(route);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    onChanged();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    onChanged();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    onChanged();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (newRoute != null) {
      if (index >= 0) {
        _routes[index] = newRoute;
      } else {
        _routes.add(newRoute);
      }
    } else if (index >= 0) {
      _routes.removeAt(index);
    }
    onChanged();
  }
}
