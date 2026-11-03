import '../../widgets/bilibili_startup_poster.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/bilibili/bilibili_open_timeline.dart';
import '../../services/bilibili/bilibili_startup.dart';
import '../../services/bilibili/bilibili_player_panel_memory.dart';
import '../../services/bilibili/bilibili_player_panel_policy.dart';
import '../../services/bilibili/bilibili_watch_cards.dart';
import '../../services/bilibili/bilibili_watch_launch.dart';
import '../../services/bilibili/bilibili_watch_orientation.dart';
import '../../services/settings_service.dart';
import '../../services/media_playback_service.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/bilibili_cover_image.dart';
import '../../widgets/bilibili_player_panel.dart';
import '../../widgets/bilibili_portrait_tabs.dart';
import '../../widgets/subtitle_sidebar.dart';
import '../../widgets/mobile_system_bar_surface.dart';
import '../../widgets/video_controls_overlay.dart';
import 'bilibili_watch_page_layout.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Opens the playback page of a video that is ready: [page] is this loading
/// page's route, which the playback page takes the place of.
typedef BilibiliWatchOpener =
    Future<void> Function(
      NavigatorState navigator,
      Route<dynamic> page,
      BilibiliWatchPlan plan,
      BilibiliOpenTimeline timeline,
    );

/// Shown the moment a Bilibili video is tapped: the cover and title the list
/// already had, with a spinner, while the video gets ready. It is laid out as
/// the playback page will be (the cover where that page shows the video, the
/// side panel shown as the page will show it), so the switch moves nothing.
/// It does not play
/// anything; once the video is ready the regular playback page takes its
/// place. Back leaves at once and drops the request; a failure or the time
/// limit shows the reason with a retry button instead of spinning on.
class BilibiliWatchLoadingPage extends StatefulWidget {
  const BilibiliWatchLoadingPage({
    super.key,
    required this.bvid,
    required this.load,
    required this.open,
    required this.timeline,
    this.page = 1,
    this.preview,
    this.discard,
    this.onClosed,
    this.timeLimit = kBilibiliWatchTimeLimit,
    this.shape,
    this.orientation = const BilibiliWatchOrientation(),
  });

  static const String routeName = '/bilibili/watch-loading';

  final String bvid;
  final int page;
  final BilibiliWatchPreview? preview;
  final Future<BilibiliWatchPlan> Function(BilibiliWatchAttempt attempt) load;
  final BilibiliWatchOpener open;
  final BilibiliOpenTimeline Function() timeline;

  /// Cleans up after a try that was given up; [kept] is the plan that
  /// opened, whose entries stay.
  final Future<void> Function(BilibiliWatchPlan plan, BilibiliWatchPlan? kept)?
  discard;

  /// Runs when the page goes away, whichever way.
  final VoidCallback? onClosed;
  final Duration timeLimit;

  /// How the playback page will be laid out; null reads the settings.
  final BilibiliWatchPageShape? shape;

  /// On a phone, turns the screen to landscape while the landscape playback
  /// page is coming, and back when the page is left without it.
  final BilibiliWatchOrientation orientation;

  @override
  State<BilibiliWatchLoadingPage> createState() =>
      _BilibiliWatchLoadingPageState();
}

class _BilibiliWatchLoadingPageState extends State<BilibiliWatchLoadingPage> {
  late final BilibiliWatchLaunch<BilibiliWatchPlan> _launch;
  bool _opening = false;
  BilibiliStartupGeometry? _geometry;

  /// The portrait 「详情 | 字幕」 tab shown here. A tap only changes what this
  /// page and the playback page it opens show, never the remembered tab.
  PortraitBilibiliTab _portraitTab = BilibiliPortraitTabMemory.of(
    SettingsService(),
  ).remembered;
  bool _portraitTabPicked = false;
  PortraitBilibiliTab _landscapeTab =
      SettingsService().bilibiliLandscapeShowsSubtitles
      ? PortraitBilibiliTab.subtitles
      : PortraitBilibiliTab.details;

  /// The Bilibili panel was collapsed on this page.
  bool _panelCollapsed = false;

  /// Landscape was asked for and not given back yet.
  bool _holdsLandscape = false;
  bool _landscapeChromeVisible = false;

  @override
  void initState() {
    super.initState();
    _launch = BilibiliWatchLaunch<BilibiliWatchPlan>(
      load: widget.load,
      timelineFor: () {
        final timeline = widget.timeline();
        timeline.startup.coverUrl = widget.preview?.coverUrl;
        _geometry?.removeListener(_onLaunchChanged);
        _geometry = timeline.startup.geometry;
        _geometry!.addListener(_onLaunchChanged);
        return timeline;
      },
      discard: widget.discard,
      timeLimit: widget.timeLimit,
      onReady: _openPlayback,
    )..addListener(_onLaunchChanged);
    _launch.start();
    final shape = widget.shape ?? BilibiliWatchPageShape.current();
    if (shape.landscape && shape.isMobilePlatform) {
      // Once, as the landscape playback page does; a retry asks nothing.
      _holdsLandscape = true;
      unawaited(widget.orientation.requestLandscape());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _launch.timeline?.mark('loading page shown');
    });
  }

  void _onLaunchChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _openPlayback(
    BilibiliWatchPlan plan,
    BilibiliOpenTimeline timeline,
  ) async {
    var route = mounted ? ModalRoute.of(context) : null;
    if (route != null && route.isActive) {
      // The playback page draws the card's cover file in its first frame
      // when the image is decoded already. It also takes over this page's
      // transition as it stands, so that has to be over.
      await _shown(route);
      route = mounted ? ModalRoute.of(context) : null;
    }
    if (!mounted || route == null || !route.isActive) {
      // Left in the instant between ready and open: what this watch made,
      // including cards a retry took over from a given-up try, goes now.
      _launch.discardReady();
      return;
    }
    _opening = true;
    if (_portraitTabPicked) {
      BilibiliPortraitTabMemory.handOff(plan.item.id, _portraitTab);
    }
    if ((widget.shape ?? BilibiliWatchPageShape.current()).landscape) {
      VideoControlsOverlay.handOffEntryVisibility(
        plan.item.id,
        _landscapeChromeVisible,
      );
    }
    unawaited(widget.open(Navigator.of(context), route, plan, timeline));
  }

  /// Completes once [route] finished coming in (or is going away).
  static Future<void> _shown(ModalRoute<dynamic> route) async {
    final animation = route.animation;
    bool over(AnimationStatus status) =>
        status == AnimationStatus.completed ||
        status == AnimationStatus.reverse ||
        !route.isActive;
    if (animation == null || over(animation.status)) return;
    final done = Completer<void>();
    void onStatus(AnimationStatus status) {
      if (over(status) && !done.isCompleted) done.complete();
    }

    animation.addStatusListener(onStatus);
    try {
      await done.future.timeout(const Duration(seconds: 1), onTimeout: () {});
    } finally {
      animation.removeStatusListener(onStatus);
    }
  }

  /// Left without the playback page: the orientation goes back to what it
  /// was before the tap. The playback page keeps landscape when it opens.
  void _giveBackOrientation() {
    if (!_holdsLandscape || _opening) return;
    _holdsLandscape = false;
    unawaited(widget.orientation.restore());
  }

  @override
  void dispose() {
    _geometry?.removeListener(_onLaunchChanged);
    _giveBackOrientation();
    _launch
      ..removeListener(_onLaunchChanged)
      ..dispose();
    widget.onClosed?.call();
    super.dispose();
  }

  void _back() {
    _launch.cancel();
    _giveBackOrientation();
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final failed = _launch.phase == BilibiliWatchLaunchPhase.failed;
    var shape = widget.shape ?? BilibiliWatchPageShape.current();
    final sharedSidebar =
        shape.landscape &&
        !bilibiliPanelOverlaysVideo(
          isMobilePlatform: shape.isMobilePlatform,
          shortestSide: MediaQuery.sizeOf(context).shortestSide,
        );
    if (_panelCollapsed) {
      shape = BilibiliWatchPageShape(
        landscape: shape.landscape,
        leftHanded: shape.leftHanded,
        bilibiliPanelRemembered: false,
        subtitleSidebarRemembered: sharedSidebar
            ? false
            : shape.subtitleSidebarRemembered,
        subtitleSidebarWidth: shape.subtitleSidebarWidth,
        isMobilePlatform: shape.isMobilePlatform,
        isDesktop: shape.isDesktop,
      );
    }
    return PopScope<Object?>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && !_opening) {
          _launch.cancel();
          _giveBackOrientation();
        }
      },
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): _back,
          if (sharedSidebar) ...{
            const SingleActivator(
              LogicalKeyboardKey.arrowLeft,
              alt: true,
            ): () =>
                _pickLandscapeTab(PortraitBilibiliTab.details),
            const SingleActivator(
              LogicalKeyboardKey.arrowRight,
              alt: true,
            ): () =>
                _pickLandscapeTab(PortraitBilibiliTab.subtitles),
          },
          if (!shape.landscape) ...{
            const SingleActivator(
              LogicalKeyboardKey.arrowLeft,
              alt: true,
            ): () =>
                _pickPortraitTab(PortraitBilibiliTab.details),
            const SingleActivator(
              LogicalKeyboardKey.arrowRight,
              alt: true,
            ): () =>
                _pickPortraitTab(PortraitBilibiliTab.subtitles),
          },
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            key: const ValueKey('bilibili-watch-loading'),
            backgroundColor: Colors.black,
            resizeToAvoidBottomInset: false,
            body: shape.landscape
                ? _landscape(context, shape, failed)
                : _portrait(context, shape, failed),
          ),
        ),
      ),
    );
  }

  String get _title {
    final title = widget.preview?.title?.trim();
    return title == null || title.isEmpty ? widget.bvid : title;
  }

  /// The playback page's Bilibili panel: the detail right away when it is
  /// kept already, else the panel's own outline while it loads (the
  /// request is shared with the playback page's panel).
  Widget _bilibiliPanel({VoidCallback? onCollapse, bool showHeader = true}) {
    return BilibiliPlayerPanel(
      cache: BilibiliWatchSources.current.details,
      bvid: widget.bvid,
      page: widget.page,
      fallbackTitle: widget.preview?.title ?? '',
      canSelectParts: false,
      onCollapse: onCollapse,
      showHeader: showHeader,
    );
  }

  void _collapsePanel() {
    BilibiliPlayerPanelMemory.of(SettingsService()).userCollapsed();
    setState(() => _panelCollapsed = true);
  }

  void _pickPortraitTab(PortraitBilibiliTab tab) {
    setState(() {
      _portraitTab = tab;
      _portraitTabPicked = true;
    });
  }

  void _pickLandscapeTab(PortraitBilibiliTab tab) {
    unawaited(
      SettingsService().saveBilibiliLandscapeShowsSubtitles(
        tab == PortraitBilibiliTab.subtitles,
      ),
    );
    unawaited(SettingsService().saveLandscapeSubtitleSidebarVisible(true));
    setState(() {
      _landscapeTab = tab;
      _panelCollapsed = false;
    });
  }

  void _collapseSharedSidebar() {
    unawaited(SettingsService().saveLandscapeSubtitleSidebarVisible(false));
    setState(() => _panelCollapsed = true);
  }

  /// As the landscape playback page: the cover over the whole area beside
  /// the side panel the page opens with, which is kept free here.
  Widget _landscape(
    BuildContext context,
    BilibiliWatchPageShape shape,
    bool failed,
  ) {
    final media = MediaQuery.of(context);
    final layout = shape.landscapeLayout(
      window: media.size,
      padding: media.padding,
    );
    // The page's only safe area is the top one.
    return MediaQuery.removePadding(
      context: context,
      removeTop: true,
      child: Stack(
        children: [
          Positioned.fromRect(
            rect: layout.surface,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _videoArea(
                  failed: failed,
                  backButton: _backButton(shape),
                  backAt: EdgeInsets.zero,
                  titleInArea: false,
                  showBackButton: false,
                  // The surface beside the panel is taller than the video.
                  letterbox: true,
                ),
                if (!failed)
                  MultiProvider(
                    providers: [
                      ChangeNotifierProvider<SettingsService>.value(
                        value: SettingsService(),
                      ),
                      ChangeNotifierProvider<MediaPlaybackService>.value(
                        value: MediaPlaybackService(),
                      ),
                    ],
                    child: VideoControlsOverlay.preparing(
                      mediaTitle: _title,
                      mediaItemId: 'bilibili-preparing:${widget.bvid}',
                      onBackPressed: _back,
                      isSubtitleSidebarVisible: shape.subtitleSidebarRemembered,
                      showSubtitles: SettingsService().showSubtitles,
                      initialShowControls: _landscapeChromeVisible,
                      onControlsVisibilityIntent: (visible) =>
                          _landscapeChromeVisible = visible,
                      backButtonKey: const ValueKey(
                        'bilibili-watch-loading-back',
                      ),
                      titleTextKey: const ValueKey(
                        'bilibili-watch-loading-title',
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (layout.slot != BilibiliWatchSidebarSlot.none)
            Positioned.fromRect(
              rect: layout.sidebar,
              child: _sidebar(layout.slot, shape),
            ),
        ],
      ),
    );
  }

  /// As the portrait playback page: the video area on top of a centered
  /// column at most [kPortraitPlayerMaxWidth] wide, the player's controls
  /// below it, then the 「详情 | 字幕」 switch with its panel.
  Widget _portrait(
    BuildContext context,
    BilibiliWatchPageShape shape,
    bool failed,
  ) {
    final media = MediaQuery.of(context);
    final gestureBottom = media.systemGestureInsets.bottom;
    final insets = media.padding.copyWith(
      bottom: gestureBottom > media.padding.bottom
          ? gestureBottom
          : media.padding.bottom,
    );
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kPortraitPlayerMaxWidth),
        child: MobileSystemBarSurface(
          topColor: Colors.black,
          insets: insets,
          bottomColor: _portraitTab == PortraitBilibiliTab.details
              ? AppTokens.bgBase
              : const Color(0xFF1E1E1E),
          child: SafeArea(
            top: true,
            bottom: true,
            minimum: EdgeInsets.only(bottom: gestureBottom),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ColoredBox(
                  color: Colors.black,
                  child: AspectRatio(
                    aspectRatio: _geometry?.aspectRatio ?? 16 / 9,
                    child: _videoArea(
                      failed: failed,
                      backButton: _backButton(shape),
                      backAt: const EdgeInsets.only(top: 4, left: 4),
                      titleInArea: false,
                      // This area already follows this video's own geometry.
                      letterbox: false,
                    ),
                  ),
                ),
                const _PortraitControlsOutline(),
                Expanded(
                  child: BilibiliPortraitTabs(
                    key: const ValueKey('bilibili-watch-loading-portrait-tabs'),
                    tab: _portraitTab,
                    onSelect: _pickPortraitTab,
                    details: _bilibiliPanel(),
                    // The player's empty list as it shows before subtitles are
                    // there; its buttons work once the player is open.
                    subtitles: IgnorePointer(
                      child: SubtitleSidebar(
                        subtitles: const [],
                        onOpenSettings: _noop,
                        onLoadSubtitle: _noop,
                        onOpenSubtitleStyle: _noop,
                        onOpenSubtitleManager: _noop,
                        onOpenEpisodePicker: _noop,
                        onOpenVideoCompose: _noop,
                        onOpenOcrSubtitle: _playerOffersOcr ? _noop : null,
                        onOpenSubtitleEditor: _noop,
                        isCompact: true,
                        isPortrait: true,
                        isVisible:
                            _portraitTab == PortraitBilibiliTab.subtitles,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static void _noop() {}

  /// As the portrait player decides whether its subtitle list offers OCR.
  static bool get _playerOffersOcr =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isWindows ||
      Platform.isMacOS;

  /// Where the playback page shows the video: the cover in that rectangle,
  /// a spinner, and the way back. Landscape letterboxes it inside the taller
  /// surface; portrait's area already follows this video's own rectangle.
  Widget _videoArea({
    required bool failed,
    required Widget backButton,
    required EdgeInsets backAt,
    required bool titleInArea,
    required bool letterbox,
    bool showBackButton = true,
  }) {
    final cover = BilibiliSharpCoverImage(
      key: const ValueKey('bilibili-watch-loading-cover'),
      url: widget.preview?.coverUrl,
      borderRadius: 0,
      videoFrame: true,
      preserveAspectRatio: true,
      onAspectRatio: _geometry?.reportCover,
    );
    return Stack(
      key: const ValueKey('bilibili-watch-loading-video-area'),
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
        // Landscape: the surface beside the panel is taller than the video.
        // Filling it zooms the cover, then the picture snaps smaller once
        // the real frame is ready. Portrait's area is already that box.
        if (letterbox)
          BilibiliVideoPosterSlot(
            key: const ValueKey('bilibili-watch-loading-cover-frame'),
            aspectRatio: _geometry?.aspectRatio ?? 16 / 9,
            child: cover,
          )
        else
          cover,
        if (failed) ...[
          const ColoredBox(color: Color(0x99000000)),
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: _failure(
                CrossAxisAlignment.center,
                backButtonKey: showBackButton
                    ? null
                    : const ValueKey('bilibili-watch-loading-back'),
              ),
            ),
          ),
        ] else if (!failed)
          Center(
            child: BilibiliStartupIndicator(
              key: const ValueKey('bilibili-watch-loading-spinner'),
              startup: _launch.timeline?.startup,
            ),
          ),
        if (showBackButton)
          Positioned(
            top: backAt.top,
            left: backAt.left,
            right: titleInArea ? backAt.left : null,
            child: SafeArea(
              bottom: false,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  backButton,
                  if (titleInArea) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        _title,
                        key: const ValueKey('bilibili-watch-loading-title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _backButton(BilibiliWatchPageShape shape) {
    return DesktopButtonClickRegion(
      child: IconButton(
        key: const ValueKey('bilibili-watch-loading-back'),
        tooltip: shape.isDesktop ? '退出播放 (Esc)' : '返回',
        onPressed: _back,
        icon: Icon(
          shape.isDesktop ? Icons.close : Icons.arrow_back,
          color: Colors.white,
        ),
      ),
    );
  }

  /// The side panel's place: the Bilibili panel itself (collapsing it here
  /// is remembered as on the playback page), or the subtitle list's
  /// background.
  Widget _sidebar(BilibiliWatchSidebarSlot slot, BilibiliWatchPageShape shape) {
    final leftHanded = shape.leftHanded;
    if (slot == BilibiliWatchSidebarSlot.subtitles) {
      final sharedSidebar = !bilibiliPanelOverlaysVideo(
        isMobilePlatform: shape.isMobilePlatform,
        shortestSide: MediaQuery.sizeOf(context).shortestSide,
      );
      final handle = Container(
        width: kPlayerSubtitleSidebarResizerWidth,
        color: Colors.black12,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          child: const Center(
            child: VerticalDivider(
              color: Colors.white24,
              width: 4,
              thickness: 4,
              indent: 40,
              endIndent: 40,
            ),
          ),
        ),
      );
      return Row(
        key: const ValueKey('bilibili-watch-loading-sidebar-subtitles'),
        children: [
          if (!leftHanded) handle,
          Expanded(
            child: sharedSidebar
                ? BilibiliPortraitTabs(
                    key: const ValueKey(
                      'bilibili-watch-loading-landscape-tabs',
                    ),
                    tab: _landscapeTab,
                    detailsLabel: '哔哩哔哩',
                    keyPrefix: 'bilibili-landscape',
                    onSelect: _pickLandscapeTab,
                    onClose: _collapseSharedSidebar,
                    details: _bilibiliPanel(showHeader: false),
                    subtitles: IgnorePointer(
                      child: SubtitleSidebar(
                        subtitles: const [],
                        isCompact: true,
                        isVisible:
                            _landscapeTab == PortraitBilibiliTab.subtitles,
                      ),
                    ),
                  )
                : const ColoredBox(color: Color(0xFF1E1E1E)),
          ),
          if (leftHanded) handle,
        ],
      );
    }
    return KeyedSubtree(
      key: const ValueKey('bilibili-watch-loading-sidebar-bilibili'),
      child: _bilibiliPanel(onCollapse: _collapsePanel),
    );
  }

  Widget _failure(CrossAxisAlignment alignment, {Key? backButtonKey}) {
    return Column(
      key: const ValueKey('bilibili-watch-failed'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: alignment,
      children: [
        Text(
          _launch.failure ?? '播放准备失败',
          textAlign: alignment == CrossAxisAlignment.center
              ? TextAlign.center
              : TextAlign.start,
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            DesktopButtonClickRegion(
              child: TextButton(
                key: backButtonKey,
                onPressed: _back,
                child: const Text(
                  '返回',
                  style: TextStyle(color: Colors.white70),
                ),
              ),
            ),
            const SizedBox(width: 8),
            DesktopButtonClickRegion(
              child: FilledButton.icon(
                key: const ValueKey('bilibili-watch-retry'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppTokens.brandBilibili,
                  foregroundColor: Colors.white,
                ),
                onPressed: _launch.retry,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('重试'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The portrait player's controls as they show before the video is ready
/// (the same heights, all greyed), so the panel below starts where the
/// player's does.
class _PortraitControlsOutline extends StatelessWidget {
  const _PortraitControlsOutline();

  /// Heights of the portrait player's play controls and its progress bar
  /// while it loads.
  static const double controlsHeight = 50;
  static const double progressHeight = 36;

  @override
  Widget build(BuildContext context) {
    const background = Color(0xFF1E1E1E);
    Widget seek({required bool forward}) => SizedBox(
      width: 44,
      height: 44,
      child: Transform(
        alignment: Alignment.center,
        transform: forward ? Matrix4.rotationY(3.14159) : Matrix4.identity(),
        child: const Icon(Icons.replay, color: Colors.white38, size: 28),
      ),
    );
    return Column(
      key: const ValueKey('bilibili-watch-loading-controls'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          // Match the real portrait controls' vertical padding as well as
          // their 50px play button, so opening playback preserves the panel.
          constraints: const BoxConstraints(minHeight: controlsHeight),
          padding: const EdgeInsets.symmetric(vertical: 0.1),
          color: background,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                width: 48,
                height: 48,
                child: Icon(
                  Icons.skip_previous,
                  color: Colors.white38,
                  size: 32,
                ),
              ),
              const SizedBox(width: 16),
              seek(forward: false),
              const SizedBox(width: 30),
              const Icon(
                Icons.play_circle_fill,
                color: Colors.white38,
                size: 50,
              ),
              const SizedBox(width: 30),
              seek(forward: true),
              const SizedBox(width: 16),
              const SizedBox(
                width: 48,
                height: 48,
                child: Icon(Icons.skip_next, color: Colors.white38, size: 32),
              ),
            ],
          ),
        ),
        Container(
          height: progressHeight,
          color: background,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              const Text(
                '00:00:00 / --:--:--',
                style: TextStyle(color: Colors.white70, fontSize: 10),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Container(height: 2, color: Colors.white24),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
