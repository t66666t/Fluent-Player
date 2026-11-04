part of 'podcast_pages.dart';

enum PodcastPlayerPresentation { automatic, music, standard }

/// Source integration only: the actual playback UI belongs to the shared
/// music/video screens, so improvements there apply to podcasts as well.
class PodcastPlayerPage extends StatefulWidget {
  const PodcastPlayerPage({
    super.key,
    required this.episodeId,
    this.presentation = PodcastPlayerPresentation.automatic,
    this.restoreSystemUiOnExit = true,
  });
  final String episodeId;
  final PodcastPlayerPresentation presentation;
  final bool restoreSystemUiOnExit;
  @override
  State<PodcastPlayerPage> createState() => _PodcastPlayerPageState();
}

class _PodcastPlayerPageState extends State<PodcastPlayerPage> with RouteAware {
  PageRoute<dynamic>? _route;
  bool _adoptedSession = false;
  String? _metadataEpisodeId, _restoringSubtitleEpisodeId, _status;
  PodcastPlayerPresentation? _presentation;
  final _notesAnchor = GlobalKey();
  final _menuAnchor = GlobalKey();

  Future<void> _showNotes(
    BuildContext context,
    PodcastEpisode episode, {
    String? status,
  }) =>
      _showPodcastNotes(context, episode, status: status, anchor: _notesAnchor);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic> && route != _route) {
      AppToast.routeObserver.unsubscribe(this);
      _route = route;
      AppToast.routeObserver.subscribe(this, route);
    }
    _visible(route?.isCurrent == true);
  }

  void _visible(bool visible) =>
      PodcastRuntime.instance.playback?.setPlaybackPageVisible(this, visible);
  @override
  void didPush() => _visible(true);
  @override
  void didPopNext() => _visible(true);
  @override
  void didPushNext() => _visible(false);
  @override
  void didPop() => _visible(false);
  @override
  void dispose() {
    AppToast.routeObserver.unsubscribe(this);
    _visible(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PodcastGate(
    builder: (runtime) {
      final playback = runtime.playback;
      if (playback == null) {
        return const Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            top: false,
            child: PodcastEmpty(title: '播放器正在准备', message: '请稍后重试。'),
          ),
        );
      }
      Widget player = ChangeNotifierProvider<MediaPlaybackService>.value(
        value: playback,
        child:
            Selector<
              MediaPlaybackService,
              ({
                String? episodeId,
                String? itemId,
                MediaType? type,
                bool loading,
              })
            >(
              selector: (_, service) => (
                episodeId: service.currentItem?.sourceRef?.podcast?.episodeId,
                itemId: service.currentItem?.id,
                type: service.currentItem?.type,
                loading:
                    service.state == PlaybackState.loading ||
                    (service.isPlaying &&
                        (service.controller?.value.isBuffering ?? false)),
              ),
              builder: (context, session, _) {
                if (session.episodeId == widget.episodeId) {
                  _adoptedSession = true;
                }
                final id =
                    runtime.openingEpisodeId == widget.episodeId ||
                        !_adoptedSession
                    ? widget.episodeId
                    : session.episodeId;
                final item = playback.currentItem;
                final episode = id == null ? null : runtime.store.episode(id);
                if (episode == null && (!_adoptedSession || item == null)) {
                  return const Scaffold(
                    backgroundColor: Colors.black,
                    body: SafeArea(
                      top: false,
                      child: PodcastEmpty(
                        title: '节目尚未载入',
                        message: '请返回频道重新选择。',
                      ),
                    ),
                  );
                }
                final current =
                    episode == null ||
                    item?.sourceRef?.podcast?.episodeId == episode.id;
                final presentation = _presentation ?? widget.presentation;
                final displayItem = current
                    ? item
                    : episode.media.isNotEmpty &&
                          runtime.store.channel(episode.channelId) != null
                    ? runtime.previewItemFor(episode)
                    : null;
                final standard =
                    presentation == PodcastPlayerPresentation.standard ||
                    (presentation == PodcastPlayerPresentation.automatic &&
                        displayItem?.type == MediaType.video);
                if (episode != null &&
                    current &&
                    _metadataEpisodeId != episode.id) {
                  _metadataEpisodeId = episode.id;
                  if ((item?.subtitlePath?.isNotEmpty == true ||
                          item?.secondarySubtitlePath?.isNotEmpty == true) &&
                      playback.subtitles.isEmpty &&
                      playback.secondarySubtitles.isEmpty) {
                    _restoringSubtitleEpisodeId = episode.id;
                  }
                  WidgetsBinding.instance.addPostFrameCallback((_) async {
                    if (!mounted) return;
                    try {
                      // Opening a page can follow a late library association or
                      // a superseded initial load. Restore local selections
                      // before waiting for chapters or any official transcript.
                      try {
                        final bound = playback.currentItem;
                        if (_restoringSubtitleEpisodeId == episode.id &&
                            bound?.sourceRef?.podcast?.episodeId ==
                                episode.id &&
                            !playback.isLoadingSubtitles) {
                          await playback.refreshAssociatedSubtitles(bound!);
                        }
                      } finally {
                        if (mounted &&
                            _restoringSubtitleEpisodeId == episode.id) {
                          setState(() => _restoringSubtitleEpisodeId = null);
                        }
                      }
                      if (!mounted ||
                          playback.currentItem?.sourceRef?.podcast?.episodeId !=
                              episode.id) {
                        return;
                      }
                      await runtime.prepareLearning(episode);
                    } catch (_) {
                      if (mounted) {
                        setState(() => _status = '文字稿暂时未能载入，播放不受影响。');
                      }
                    }
                  });
                }
                if (standard && displayItem != null) {
                  return VideoPlayerScreen(
                    videoItem: displayItem,
                    existingController: current ? playback.controller : null,
                    autoPlayOnEntry: false,
                    deferPlaybackUntilCurrent: !current,
                  );
                }
                final channel = episode == null
                    ? null
                    : runtime.store.channel(episode.channelId);
                return MusicPlayerScreen(
                  landscapeToolbarKey: _notesAnchor,
                  restoreSystemUiOnExit: widget.restoreSystemUiOnExit,
                  followCurrentSession: current,
                  isLoading:
                      episode != null &&
                      ((current && session.loading) ||
                          (runtime.openingEpisodeId == episode.id &&
                              (!current ||
                                  playback.state == PlaybackState.idle))),
                  title: episode == null
                      ? item?.title ?? ''
                      : runtime.episodeTitle(episode),
                  artist: channel == null ? '' : runtime.channelTitle(channel),
                  album: channel?.author ?? '',
                  coverImagePath: current ? item?.thumbnailPath : null,
                  totalDuration: Duration(
                    milliseconds: episode?.durationMs ?? item?.durationMs ?? 0,
                  ),
                  previousLabel: episode == null ? '上一曲' : '上一集',
                  nextLabel: episode == null ? '下一曲' : '下一集',
                  onPrevious: current && playback.hasPlayablePrevious
                      ? playback.playPrevious
                      : null,
                  onNext: current && playback.hasPlayableNext
                      ? playback.playNext
                      : null,
                  onPlayPause: () async {
                    if (current && playback.controller != null) {
                      if (playback.isPlaying) {
                        await playback.pause();
                      } else {
                        await playback.resume();
                      }
                    } else if (episode != null) {
                      try {
                        await runtime.play(episode);
                      } catch (_) {
                        if (mounted) {
                          setState(() => _status = '暂时无法播放，请检查网络后重试。');
                        }
                      }
                    }
                  },
                  detailsAction: episode == null
                      ? null
                      : DesktopButtonClickRegion(
                          child: IconButton(
                            key: const ValueKey('podcast-description-toggle'),
                            tooltip: '节目简介',
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.transparent,
                              side: BorderSide.none,
                            ),
                            onPressed: () =>
                                _showNotes(context, episode, status: _status),
                            icon: const Icon(Icons.notes_rounded, size: 20),
                          ),
                        ),
                  transcriptFallback: episode == null
                      ? null
                      : _PodcastTranscriptFallback(
                          episode: episode,
                          sessionReady: current,
                          restoringSelectedSubtitle:
                              _restoringSubtitleEpisodeId == episode.id,
                          onNotes: () => _showNotes(context, episode),
                          playbackError:
                              _status ??
                              (runtime.failedEpisodeId == episode.id
                                  ? runtime.playbackError
                                  : null),
                        ),
                  headerAction: episode == null
                      ? null
                      : Builder(
                          builder: (context) =>
                              _actions(context, runtime, episode),
                        ),
                );
              },
            ),
      );
      if (runtime.playlist != null) {
        player = ChangeNotifierProvider<PlaylistManager>.value(
          value: runtime.playlist!,
          child: player,
        );
      }
      return player;
    },
  );

  Widget _actions(
    BuildContext context,
    PodcastRuntime runtime,
    PodcastEpisode episode,
  ) {
    final state = runtime.controller.state(episode.id);
    final task = runtime.controller.downloads
        .where((t) => t.episodeId == episode.id)
        .firstOrNull;
    final preferences = runtime.store.effective(episode.channelId);
    return PodcastMenuButton(
      key: _menuAnchor,
      compact: true,
      title: '节目操作',
      iconColor: IconButtonTheme.of(
        context,
      ).style?.foregroundColor?.resolve({}),
      subtitle: runtime.episodeTitle(episode),
      tooltip: '播客设置与节目操作',
      actions: [
        const PodcastMenuAction('rename', '重命名', Icons.edit_outlined),
        PodcastMenuAction(
          'favorite',
          state.favorite ? '取消收藏' : '收藏节目',
          state.favorite
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded,
          selected: state.favorite,
        ),
        PodcastMenuAction(
          'download',
          task?.status == PodcastDownloadStatus.downloading
              ? '暂停下载'
              : task?.status == PodcastDownloadStatus.completed
              ? '已完整下载'
              : '下载完整节目',
          Icons.download_outlined,
        ),
        const PodcastMenuAction('notes', '节目简介与章节', Icons.article_outlined),
        const PodcastMenuAction('links', '节目与频道链接', Icons.link_rounded),
        PodcastMenuAction(
          'speed',
          '播放倍速 · ${runtime.playback!.playbackSpeed}×',
          Icons.speed_rounded,
        ),
        PodcastMenuAction(
          'backward',
          '后退 ${preferences.integer('rewindSeconds')} 秒',
          Icons.replay_rounded,
        ),
        PodcastMenuAction(
          'forward',
          '前进 ${preferences.integer('forwardSeconds')} 秒',
          Icons.forward_rounded,
        ),
        const PodcastMenuAction(
          'learning',
          '字幕与 AI 学习',
          Icons.subtitles_outlined,
        ),
        const PodcastMenuAction(
          'standard',
          '使用普通播放器',
          Icons.video_settings_outlined,
        ),
        const PodcastMenuAction('settings', '频道播放设置', Icons.tune_rounded),
      ],
      onSelected: (action) async {
        try {
          if (['speed', 'backward', 'forward', 'learning'].contains(action) &&
              runtime.playback!.currentItem?.sourceRef?.podcast?.episodeId !=
                  episode.id) {
            setState(() => _status = '节目正在载入，请稍后再试。');
            return;
          }
          switch (action) {
            case 'rename':
              await _renamePodcastEpisode(context, runtime, episode);
            case 'backward':
              await runtime.playback!.seekTo(
                Duration(
                  milliseconds: max(
                    0,
                    runtime.playback!.position.inMilliseconds -
                        preferences.integer('rewindSeconds') * 1000,
                  ),
                ),
              );
            case 'forward':
              final target =
                  runtime.playback!.position.inMilliseconds +
                  preferences.integer('forwardSeconds') * 1000;
              final duration = runtime.playback!.duration.inMilliseconds;
              await runtime.playback!.seekTo(
                Duration(
                  milliseconds: duration > 0 ? min(duration, target) : target,
                ),
              );
            case 'links':
              final channel = runtime.store.channel(episode.channelId);
              await showPodcastLinks(
                context,
                title: '节目与频道链接',
                links: [
                  PodcastLink('单集原始页面', episode.link),
                  if (channel != null) ...[
                    PodcastLink('频道主页', channel.link),
                    PodcastLink('RSS 订阅地址', channel.feedUrl),
                  ],
                  for (final media in episode.media)
                    PodcastLink(media.isVideo ? '视频文件' : '音频文件', media.url),
                ],
              );
            case 'favorite':
              runtime.controller.updateState(
                episode.id,
                (s) => s.favorite = !s.favorite,
              );
            case 'download':
              if (task?.status == PodcastDownloadStatus.downloading) {
                runtime.controller.pause(episode.id);
              } else if (task?.status != PodcastDownloadStatus.completed) {
                runtime.controller.enqueue(episode);
              }
            case 'settings':
              _openSettings(context, episode.channelId);
            case 'standard':
              setState(
                () => _presentation = PodcastPlayerPresentation.standard,
              );
            case 'learning':
              await runtime.prepareLearning(episode);
              if (mounted) {
                setState(
                  () => _presentation = PodcastPlayerPresentation.standard,
                );
              }
            case 'notes':
              await _showNotes(context, episode, status: _status);
            case 'speed':
              final value = await showPodcastMenu(
                _menuAnchor.currentContext ?? context,
                title: '播放倍速',
                actions: [
                  for (final rate in [
                    0.75,
                    1.0,
                    1.25,
                    1.5,
                    1.75,
                    2.0,
                    2.5,
                    3.0,
                  ])
                    PodcastMenuAction(
                      '$rate',
                      '$rate×',
                      Icons.speed_rounded,
                      selected: runtime.playback!.playbackSpeed == rate,
                    ),
                ],
              );
              if (value != null) {
                await runtime.playback!.setPlaybackSpeed(double.parse(value));
              }
          }
        } catch (_) {
          if (mounted) setState(() => _status = '操作暂时未完成，请稍后重试。');
        }
      },
    );
  }
}

Future<void> _showPodcastNotes(
  BuildContext context,
  PodcastEpisode episode, {
  String? status,
  required GlobalKey anchor,
}) {
  final size = MediaQuery.sizeOf(context);
  if (musicPlayerUsesVerticalLayout(size)) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: .28),
      elevation: 0,
      showDragHandle: false,
      constraints: const BoxConstraints(maxWidth: 720),
      // Float above the home indicator. Short articles still size to content;
      // the pinned heading stays visible while a long article scrolls.
      builder: (sheet) => KeyboardInsetPadding(
        child: SafeArea(
          top: false,
          minimum: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: size.height * .72),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: .28),
                    blurRadius: 32,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                  child: Material(
                    key: const ValueKey('podcast-notes-sheet'),
                    color: Colors.transparent,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(color: const Color(0x1FFFFFFF)),
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xF2353539), Color(0xF2222226)],
                        ),
                      ),
                      child: _PodcastShowNotes(
                        episode: episode,
                        status: status,
                        portrait: true,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
  final overlay = Navigator.of(context, rootNavigator: true).overlay!;
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '收起节目简介',
    barrierColor: Colors.transparent,
    transitionDuration: reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 180),
    pageBuilder: (context, animation, secondaryAnimation) {
      final media = MediaQuery.of(context);
      final target = anchor.currentContext?.findRenderObject();
      final overlayBox = overlay.context.findRenderObject();
      final rect =
          target is RenderBox && target.attached && overlayBox is RenderBox
          ? target.localToGlobal(Offset.zero, ancestor: overlayBox) &
                target.size
          : Rect.fromLTWH(
              media.padding.left + 16,
              media.padding.top + 16,
              44,
              44,
            );
      return CustomSingleChildLayout(
        delegate: _PodcastNotesPlacement(
          anchor: rect,
          padding: media.padding + media.viewInsets,
        ),
        child: FadeTransition(
          opacity: animation.drive(CurveTween(curve: Curves.easeOutCubic)),
          child: ScaleTransition(
            alignment: Alignment.topLeft,
            scale: animation.drive(
              Tween(
                begin: .96,
                end: 1.0,
              ).chain(CurveTween(curve: Curves.easeOutCubic)),
            ),
            child: Semantics(
              namesRoute: true,
              label: '节目简介',
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: .3),
                      blurRadius: 28,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                    child: Material(
                      key: const ValueKey('podcast-notes-popover'),
                      color: const Color(0xFF242426).withValues(alpha: .90),
                      child: _PodcastShowNotes(
                        episode: episode,
                        status: status,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Measure the article first; only long notes consume the available height.
class _PodcastNotesPlacement extends SingleChildLayoutDelegate {
  const _PodcastNotesPlacement({required this.anchor, required this.padding});
  final Rect anchor;
  final EdgeInsets padding;
  static const double _margin = 16;
  static const double _gap = 4;

  double _top(Size size) => (anchor.bottom + _gap).clamp(
    padding.top + _margin,
    max(padding.top + _margin, size.height - padding.bottom - _margin),
  );

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final width = min(
      420.0,
      max(0.0, constraints.maxWidth - padding.horizontal - _margin * 2),
    );
    return BoxConstraints(
      minWidth: width,
      maxWidth: width,
      maxHeight: max(
        0,
        constraints.maxHeight -
            _top(constraints.biggest) -
            padding.bottom -
            _margin,
      ),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    anchor.left.clamp(
      padding.left + _margin,
      max(
        padding.left + _margin,
        size.width - padding.right - _margin - childSize.width,
      ),
    ),
    _top(size),
  );

  @override
  bool shouldRelayout(covariant _PodcastNotesPlacement oldDelegate) =>
      oldDelegate.anchor != anchor || oldDelegate.padding != padding;
}

/// A compact article below the toolbar, without resizing the transcript.
class _PodcastShowNotes extends StatelessWidget {
  const _PodcastShowNotes({
    required this.episode,
    this.status,
    this.portrait = false,
  });
  final PodcastEpisode episode;
  final String? status;
  final bool portrait;
  @override
  Widget build(BuildContext context) {
    final runtime = PodcastRuntime.instance;
    final chapters = runtime.adapterFor(episode.id)?.chapters ?? [];
    final playing =
        runtime.playback?.currentItem?.sourceRef?.podcast?.episodeId ==
        episode.id;
    final channel = runtime.store.channel(episode.channelId);
    return Column(
      key: const ValueKey('podcast-show-notes'),
      mainAxisSize: MainAxisSize.min,
      children: [
        if (portrait)
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 10, bottom: 2),
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0x38FFFFFF),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        Padding(
          padding: portrait
              ? const EdgeInsets.fromLTRB(24, 2, 12, 8)
              : const EdgeInsets.fromLTRB(20, 6, 6, 4),
          child: Row(
            children: [
              if (portrait) ...[
                const Icon(
                  Icons.notes_rounded,
                  size: 18,
                  color: Colors.white60,
                ),
                const SizedBox(width: 9),
              ],
              Expanded(
                child: Text(
                  '节目简介',
                  style: PodcastType.title.copyWith(
                    color: portrait ? Colors.white70 : Colors.white,
                    fontSize: 15,
                  ),
                ),
              ),
              DesktopButtonClickRegion(
                child: IconButton(
                  key: const ValueKey('podcast-description-collapse'),
                  tooltip: '收起简介',
                  style: IconButton.styleFrom(
                    foregroundColor: Colors.white60,
                    backgroundColor: portrait
                        ? const Color(0x0FFFFFFF)
                        : Colors.transparent,
                    side: BorderSide.none,
                    shape: const CircleBorder(),
                    minimumSize: const Size.square(44),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => Navigator.of(context).pop(),
                  icon: Icon(
                    portrait
                        ? Icons.keyboard_arrow_down_rounded
                        : Icons.keyboard_arrow_up_rounded,
                    size: 20,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (portrait)
          const Divider(height: 1, thickness: 1, color: Color(0x12FFFFFF)),
        Flexible(
          child: SingleChildScrollView(
            key: const ValueKey('podcast-notes-scroll'),
            padding: portrait
                ? const EdgeInsets.fromLTRB(24, 20, 24, 28)
                : const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  runtime.episodeTitle(episode),
                  style: PodcastType.title.copyWith(
                    color: Colors.white,
                    fontSize: portrait ? 21 : 17,
                    height: portrait ? 1.4 : 1.5,
                  ),
                ),
                if (portrait && channel != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    runtime.channelTitle(channel),
                    style: PodcastType.meta.copyWith(
                      fontSize: 12,
                      height: 1.5,
                      color: Colors.white54,
                    ),
                  ),
                ],
                if (portrait) ...[
                  const SizedBox(height: 20),
                  const Divider(
                    height: 1,
                    thickness: 1,
                    color: Color(0x12FFFFFF),
                  ),
                ],
                const SizedBox(height: 16),
                if (status != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      status!,
                      style: const TextStyle(color: Colors.white60),
                    ),
                  ),
                PodcastArticleView(
                  source: episode.description,
                  onSeek: playing
                      ? (clock) => runtime.playback?.seekTo(
                          Duration(milliseconds: podcastDuration(clock)),
                        )
                      : null,
                ),
                if (chapters.isNotEmpty) ...[
                  const SizedBox(height: 28),
                  Text(
                    '章节',
                    style: PodcastType.title.copyWith(color: Colors.white),
                  ),
                  if (playing)
                    Padding(
                      padding: const EdgeInsets.only(top: 6, bottom: 8),
                      child: Text(
                        '点击章节跳转播放',
                        style: PodcastType.meta.copyWith(
                          fontSize: 12,
                          color: PodcastArticleView.seekColor,
                        ),
                      ),
                    ),
                  for (final chapter in chapters)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: playing
                          ? const Icon(
                              Icons.play_circle_outline_rounded,
                              color: PodcastArticleView.seekColor,
                              size: 18,
                            )
                          : null,
                      title: Text(
                        chapter.title,
                        style: PodcastType.prose.copyWith(
                          color: Colors.white70,
                        ),
                      ),
                      trailing: Text(
                        podcastTime(chapter.startMs),
                        style: PodcastType.time.copyWith(
                          color: playing
                              ? PodcastArticleView.seekColor
                              : Colors.white54,
                          decoration: playing ? TextDecoration.underline : null,
                          decorationColor: PodcastArticleView.seekColor,
                        ),
                      ),
                      onTap: playing
                          ? () => runtime.playback?.seekTo(chapter.start)
                          : null,
                    ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Transcript guidance shared by the portrait and landscape player.
class _PodcastTranscriptFallback extends StatelessWidget {
  const _PodcastTranscriptFallback({
    required this.episode,
    required this.sessionReady,
    required this.onNotes,
    this.restoringSelectedSubtitle = false,
    this.playbackError,
  });
  final PodcastEpisode episode;
  final bool sessionReady;
  final VoidCallback onNotes;
  final bool restoringSelectedSubtitle;
  final String? playbackError;

  @override
  Widget build(BuildContext context) {
    final runtime = PodcastRuntime.instance;
    final manager = _maybeProvider<TranscriptionManager>(context);
    if (manager != null) context.watch<TranscriptionManager>();
    final playback = context.watch<MediaPlaybackService>();
    final item = playback.currentItem;
    final bound = item?.sourceRef?.podcast?.episodeId == episode.id
        ? item
        : null;
    final official =
        runtime.officialTranscript[episode.id] ??
        PodcastOfficialTranscript.unknown;
    final source = resolveTranscriptionSource(
      episode: episode,
      selectedUrl:
          bound?.sourceRef?.podcast?.mediaUrl ?? episode.media.firstOrNull?.url,
      isComplete: (url) =>
          runtime.controller.mediaStore.isComplete(episode.id, url),
    );
    final path = bound?.path ?? '';
    final running =
        manager != null &&
        path.isNotEmpty &&
        (manager.isVideoRunning(path, videoId: bound?.id) ||
            manager.isVideoQueued(path, videoId: bound?.id));
    final generated = path.isEmpty
        ? null
        : manager?.getGeneratedSrtPathForVideo(path, videoId: bound?.id);
    final loaded =
        generated != null && playback.subtitlePaths.contains(generated);
    final snapshot = manager
        ?.getQueueSnapshot()
        .where((task) => task.videoId == bound?.id)
        .firstOrNull;
    final failed = snapshot?.status == TranscriptionStatus.error;
    final action = resolvePodcastTranscriptAction(
      sessionReady: sessionReady && bound != null,
      sourceSupported: source.media != null,
      official: official,
      aiRunning: running,
      aiFailed: failed && !running,
      hasGenerated: generated != null,
      generatedLoaded: loaded,
      subtitlesLoading:
          restoringSelectedSubtitle ||
          (bound != null && playback.isLoadingSubtitles),
      hasSelectedSubtitle:
          bound?.subtitlePath?.isNotEmpty == true ||
          bound?.secondarySubtitlePath?.isNotEmpty == true,
      stage: snapshot?.statusMessage,
      failure: snapshot?.statusMessage,
    );
    final message =
        playbackError ??
        (source.media == null ? source.reason : null) ??
        action.message;
    if (playbackError == null &&
        action.kind == PodcastTranscriptActionKind.loading) {
      return const _PodcastTranscriptPlaceholder();
    }
    return AnimatedBuilder(
      animation: runtime,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxHeight < 260;
          return MediaQuery.withClampedTextScaling(
            maxScaleFactor: 1.4,
            child: SingleChildScrollView(
              key: const ValueKey('podcast-transcript-guidance'),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? 16 : 20,
                      vertical: compact ? 8 : 20,
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 360),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!compact) ...[
                            const Icon(
                              Icons.graphic_eq_rounded,
                              size: 30,
                              color: Colors.white30,
                            ),
                            const SizedBox(height: 14),
                          ],
                          Text(
                            message,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white60,
                              fontSize: compact ? 14 : 15,
                              height: 1.45,
                            ),
                          ),
                          if (action.detail.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              action.detail,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white38,
                                fontSize: 12,
                                height: 1.45,
                              ),
                            ),
                          ],
                          SizedBox(height: compact ? 8 : 14),
                          Wrap(
                            alignment: WrapAlignment.center,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              _PodcastGlassAction(
                                key: const ValueKey('podcast-ai-transcribe'),
                                onPressed: !action.enabled
                                    ? null
                                    : action.kind ==
                                          PodcastTranscriptActionKind
                                              .retrySelected
                                    ? () => unawaited(
                                        playback.refreshAssociatedSubtitles(
                                          bound!,
                                        ),
                                      )
                                    : () => showMusicSubtitleManagementDialog(
                                        context,
                                        initialShowAi: true,
                                      ),
                                label: action.primaryLabel,
                              ),
                              _PodcastGlassAction(
                                key: const ValueKey('podcast-transcript-notes'),
                                onPressed: onNotes,
                                label: '节目简介',
                              ),
                              if (official == PodcastOfficialTranscript.failed)
                                DesktopButtonClickRegion(
                                  child: TextButton(
                                    onPressed: () => unawaited(
                                      runtime.retryOfficialTranscript(episode),
                                    ),
                                    child: const Text(
                                      '重试官方文字稿',
                                      style: TextStyle(
                                        color: Colors.white70,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Keeps the transcript surface quiet while local cues are being restored.
class _PodcastTranscriptPlaceholder extends StatelessWidget {
  const _PodcastTranscriptPlaceholder();

  @override
  Widget build(BuildContext context) => Semantics(
    label: '正在加载文字稿',
    child: Center(
      key: const ValueKey('podcast-transcript-loading'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final width in const [1.0, 0.82, 0.6])
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: FractionallySizedBox(
                    widthFactor: width,
                    child: Container(
                      height: 12,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(6),
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

/// Neutral frosted glass lets the artwork remain visible through both actions.
class _PodcastGlassAction extends StatelessWidget {
  const _PodcastGlassAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.expanded = false,
    this.textStyle,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  /// Primary actions, such as trial playback, use the full row.
  final bool expanded;

  /// Overrides the compact chip face. Callers that need a heavier label
  /// pass it here so the frosted chrome stays shared.
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) => QuietEmptyAction(
    label: label,
    onPressed: onPressed,
    icon: icon,
    expanded: expanded,
    textStyle: textStyle,
  );
}
