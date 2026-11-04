import 'dart:async';
import 'add_to_playlist_button.dart';
import 'playback_queue_add_actions.dart';

import 'package:flutter/material.dart';
import '../services/app_web_navigation.dart';
import 'package:video_player_app/models/bilibili_browse_models.dart';
import 'package:video_player_app/screens/bilibili/bilibili_card_actions.dart';
import 'package:video_player_app/screens/bilibili/bilibili_home_page.dart';
import 'package:video_player_app/screens/bilibili/bilibili_description_text.dart';
import 'package:video_player_app/screens/bilibili/bilibili_import_buttons.dart';
import 'package:video_player_app/screens/bilibili/bilibili_uploader_screen.dart';
import 'package:video_player_app/services/bilibili/bilibili_offline_details.dart';
import 'package:video_player_app/services/bilibili/bilibili_collection_import.dart';
import 'package:video_player_app/services/bilibili/bilibili_part_playback.dart';
import 'package:video_player_app/services/bilibili/bilibili_panel_playback.dart';
import 'package:video_player_app/services/bilibili/bilibili_uploader_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_watch_cards.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_video_detail_cache.dart';
import 'package:video_player_app/services/bilibili/bilibili_watch_launch.dart';
import 'package:video_player_app/services/app_haptics.dart';
import 'package:video_player_app/services/playback_navigation_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:video_player_app/utils/bilibili_description_links.dart';
import 'package:video_player_app/utils/bilibili_text.dart';
import 'package:video_player_app/utils/bilibili_url_parser.dart';
import 'package:video_player_app/widgets/bilibili_cover_image.dart';
import 'package:video_player_app/widgets/bilibili_collection_import_button.dart';
import 'package:video_player_app/widgets/bilibili_parts_picker.dart';
import 'package:video_player_app/widgets/bilibili_video_link_actions.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Plays another video in place of the open playback page.
Future<void> _watchInPlace(
  BuildContext context, {
  required String bvid,
  int? page,
  Duration? startAt,
  BilibiliWatchPreview? preview,
  bool rememberCurrent = false,
}) {
  if (PlaybackNavigationService.isPlaybackRouteName(
    ModalRoute.of(context)?.settings.name,
  )) {
    return switchBilibiliPanelVideo(
      context,
      bvid: bvid,
      page: page,
      startAt: startAt,
      preview: preview,
      rememberCurrent: rememberCurrent,
    );
  }
  return watchBilibiliVideo(
    context,
    bvid: bvid,
    page: page,
    startAt: startAt,
    replaceCurrent: true,
    preview: preview,
    rememberCurrent: rememberCurrent,
  );
}

/// The playback page's Bilibili panel: what the video is (title, UP, counts,
/// tags, description), import and download, links to the official video,
/// the part list entry and the collection.
///
/// The detail comes from [BilibiliVideoDetailCache] by BV id. Until it is
/// there, and when it cannot be loaded, the panel shows what the card
/// already knows ([fallbackTitle]) with a retry, never an endless spinner.
class BilibiliPlayerPanel extends StatefulWidget {
  const BilibiliPlayerPanel({
    super.key,
    required this.bvid,
    this.page = 1,
    this.fallbackTitle = '',
    this.onCollapse,
    this.showHeader = true,
    this.onSelectPart,
    this.canSelectParts = true,
    this.onImportCollection,
    this.onWatchVideo,
    this.cache,
    this.api,
    this.offlineDetails,
  });

  final String bvid;

  /// Part being played.
  final int page;

  /// Title of the playing card, shown before the detail is there.
  final String fallbackTitle;

  /// The panel's collapse button; hidden when null.
  final VoidCallback? onCollapse;
  final bool showHeader;

  final BilibiliPartSwitcher? onSelectPart;

  /// The loading page cannot switch parts before playback has opened.
  final bool canSelectParts;
  final BilibiliCollectionImporter? onImportCollection;

  /// Plays another video (collection entries, links in the description) in
  /// place of the open playback page.
  final BilibiliVideoWatcher? onWatchVideo;

  final BilibiliVideoDetailCache? cache;

  /// Short links and av numbers in the description, and the uploader page.
  final BilibiliPublicApiService? api;

  /// Title, uploader and description last seen online, shown while the
  /// detail cannot be loaded; defaults to [BilibiliOfflineDetails.instance].
  final BilibiliOfflineDetails? offlineDetails;

  @override
  State<BilibiliPlayerPanel> createState() => _BilibiliPlayerPanelState();
}

class _BilibiliPlayerPanelState extends State<BilibiliPlayerPanel> {
  late final BilibiliPublicApiService _api =
      widget.api ?? BilibiliPublicApiService();
  BilibiliVideoDetail? _detail;
  bool _failed = false;

  /// The last failure got no answer at all: the network is down.
  bool _offline = false;

  /// What is known about the video without the network.
  BilibiliOfflineDetail? _known;
  bool _showAllEpisodes = false;
  bool _openingParts = false;
  bool _switchingVideo = false;
  bool _openingLink = false;
  String? _linkError;
  int _loadGeneration = 0;
  // Keep an in-flight link action alive when the pending list becomes details.
  final GlobalKey _videoLinksKey = GlobalKey();
  final GlobalKey _seasonKey = GlobalKey();
  final ScrollController _scrollController = ScrollController();

  BilibiliVideoDetailCache get _cache =>
      widget.cache ??
      BilibiliWatchSources.current.details ??
      BilibiliVideoDetailCache.instance;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(covariant BilibiliPlayerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bvid != widget.bvid) {
      final sameSeason =
          _detail?.season?.episodes.any((ep) => ep.bvid == widget.bvid) ??
          false;
      if (!sameSeason) {
        _showAllEpisodes = false;
        if (_scrollController.hasClients) _scrollController.jumpTo(0);
      }
      _start(retainDetail: sameSeason);
    }
  }

  @override
  void dispose() {
    _loadGeneration++;
    _scrollController.dispose();
    super.dispose();
  }

  void _start({bool retainDetail = false}) {
    _failed = false;
    _offline = false;
    _known = null;
    final cached = _cache.peek(widget.bvid);
    if (cached != null) {
      _replaceDetail(cached);
      _loadGeneration++;
    } else {
      if (!retainDetail) _detail = null;
      unawaited(_lookUpKnown());
      unawaited(_load());
    }
  }

  Future<void> _lookUpKnown() async {
    final bvid = widget.bvid;
    final store = widget.offlineDetails ?? BilibiliOfflineDetails.instance;
    BilibiliOfflineDetail? known;
    try {
      known = await store.lookup(bvid);
    } catch (_) {
      return;
    }
    if (!mounted || bvid != widget.bvid || known == null) return;
    setState(() => _known = known);
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final bvid = widget.bvid;
    if (mounted) setState(() => _failed = false);
    try {
      final detail = await _cache.get(bvid);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _replaceDetail(detail);
        _offline = false;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _failed = true;
        if (_detail?.bvid != widget.bvid) _detail = null;
        _offline = isBilibiliNetworkFailure(error);
      });
    }
  }

  void _replaceDetail(BilibiliVideoDetail detail) {
    final previous = _detail;
    final sameSeason =
        previous?.season != null && previous!.season!.id == detail.season?.id;
    final anchor = sameSeason ? _seasonTop() : null;
    if (!sameSeason) _showAllEpisodes = false;
    _detail = detail;
    if (anchor == null) return;
    // Titles and part entries can have different heights. Keep the collection
    // at the same place in the viewport when its video's metadata arrives.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(_detail, detail)) return;
      final next = _seasonTop();
      if (next == null || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      _scrollController.jumpTo(
        (position.pixels + next - anchor).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    });
  }

  double? _seasonTop() {
    final render = _seasonKey.currentContext?.findRenderObject();
    return render is RenderBox && render.hasSize
        ? render.localToGlobal(Offset.zero).dy
        : null;
  }

  int get _partCount {
    final parts = _detail?.parts.length ?? 0;
    return parts < 1 ? 1 : parts;
  }

  Future<void> _watchSeasonEpisode(
    String bvid, {
    int? page,
    BilibiliWatchPreview? preview,
  }) {
    unawaited(AppHaptics.selectionClick(SettingsService()));
    return _watch(bvid, page: page, preview: preview);
  }

  Future<void> _watch(
    String bvid, {
    int? page,
    Duration? startAt,
    BilibiliWatchPreview? preview,
    bool rememberCurrent = false,
  }) async {
    if (_switchingVideo || _openingParts) return;
    setState(() {
      _switchingVideo = true;
      _linkError = null;
    });
    try {
      final watch = widget.onWatchVideo;
      if (watch != null) {
        await watch(
          context,
          bvid: bvid,
          page: page,
          startAt: startAt,
          preview: preview,
        );
      } else {
        await _watchInPlace(
          context,
          bvid: bvid,
          page: page,
          startAt: startAt,
          preview: preview,
          rememberCurrent: rememberCurrent,
        );
      }
    } on BilibiliWatchCancelledException {
      // A newer playback action or leaving the page superseded this tap.
    } catch (error) {
      if (mounted) {
        setState(() => _linkError = describeBilibiliWatchFailure(error));
      }
    } finally {
      if (mounted) setState(() => _switchingVideo = false);
    }
  }

  Future<void> _download() async {
    await openBilibiliVideoDownload(
      context,
      bvid: widget.bvid,
      page: widget.page,
      partCount: _partCount,
    );
  }

  Future<void> _openParts(BilibiliVideoDetail detail) async {
    if (_openingParts || _switchingVideo) return;
    final bvid = widget.bvid;
    setState(() => _openingParts = true);
    try {
      final page = await showBilibiliPartsPicker(
        context,
        detail: detail,
        currentPage: widget.page,
      );
      if (!mounted ||
          widget.bvid != bvid ||
          page == null ||
          page == widget.page) {
        return;
      }
      await (widget.onSelectPart ?? switchBilibiliPart)(context, detail, page);
    } on BilibiliWatchCancelledException {
      // Another playback action superseded the selection.
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('分P切换失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _openingParts = false);
    }
  }

  Future<void> _openTarget(BilibiliLinkTarget target) async {
    if (_openingLink) return;
    _openingLink = true;
    try {
      var resolved = target;
      if (target.needsResolve) {
        final result = await _api.resolveShortLink(target.shortLink!);
        final next = result.target;
        if (next == null || !next.isVideo) {
          if (next != null ||
              result.failure == BilibiliShortLinkFailure.noVideo) {
            await _launchExternal(target.shortLink!);
          } else if (mounted) {
            setState(() => _linkError = result.message ?? '无法打开该链接');
          }
          return;
        }
        resolved = next;
      }
      var bvid = resolved.bvid;
      final aid = resolved.aid;
      if (bvid == null && aid != null) {
        bvid = (await _api.fetchVideoDetail(aid: aid)).bvid;
      }
      if (!mounted || bvid == null || bvid.isEmpty) return;
      if (bvid == widget.bvid && resolved.pageOrFirst == widget.page) {
        return;
      }
      await _watch(
        bvid,
        page: resolved.page ?? (bvid == widget.bvid ? null : 1),
        startAt: resolved.startAt,
        rememberCurrent: bvid != widget.bvid,
      );
    } on BilibiliPublicApiException catch (e) {
      if (mounted) setState(() => _linkError = e.message);
    } finally {
      _openingLink = false;
    }
  }

  Future<void> _openDescriptionLink(BilibiliDescriptionSegment segment) async {
    switch (segment.kind) {
      case BilibiliDescriptionSegmentKind.text:
        return;
      case BilibiliDescriptionSegmentKind.bvid:
      case BilibiliDescriptionSegmentKind.aid:
        final target = parseBilibiliLink(segment.text);
        if (target != null && target.isVideo) await _openTarget(target);
        return;
      case BilibiliDescriptionSegmentKind.url:
        final target = parseBilibiliLink(segment.text);
        if (target != null && target.isVideo) {
          await _openTarget(target);
          return;
        }
        final uri = Uri.tryParse(segment.text);
        if (uri != null) await _launchExternal(uri);
    }
  }

  Future<void> _launchExternal(Uri uri) async {
    if (uri.scheme != 'https' && uri.scheme != 'http') return;
    try {
      await AppWebNavigation.open(context, uri);
    } catch (_) {
      if (mounted) setState(() => _linkError = '无法打开该链接');
    }
  }

  @override
  Widget build(BuildContext context) {
    return BilibiliQuietTap(
      child: Material(
        key: const ValueKey('bilibili-player-panel'),
        color: AppTokens.bgPlayerSidebar,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.showHeader) ...[
              _buildHeader(),
              const Divider(height: 1, thickness: 1, color: AppTokens.bgCard),
            ],
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
      child: Row(
        children: [
          const Icon(
            Icons.smart_display_outlined,
            size: 18,
            color: AppTokens.brandBilibili,
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '哔哩哔哩',
              style: TextStyle(
                color: AppTokens.text1,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (_switchingVideo ||
              _detail?.bvid != null && _detail?.bvid != widget.bvid)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              ),
            ),
          if (widget.onCollapse != null)
            DesktopButtonClickRegion(
              child: IconButton(
                key: const ValueKey('bilibili-panel-collapse'),
                tooltip: '收起',
                icon: const Icon(Icons.close, size: 18, color: AppTokens.text2),
                onPressed: widget.onCollapse,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final detail = _detail;
    if (detail == null) return _buildWithoutDetail();
    return CustomScrollView(
      key: const ValueKey('bilibili-panel-detail'),
      controller: _scrollController,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
          sliver: SliverMainAxisGroup(
            slivers: [
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SelectableText(
                      detail.title,
                      style: const TextStyle(
                        color: AppTokens.text1,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                      ),
                    ),
                    BilibiliVideoLinkActions(
                      showActions: false,
                      bvid: widget.bvid,
                      page: widget.page,
                    ),
                    const SizedBox(height: 10),
                    _buildOwner(detail),
                    const SizedBox(height: 10),
                    _buildStats(detail),
                    const SizedBox(height: 14),
                    IgnorePointer(
                      ignoring: detail.bvid != widget.bvid,
                      child: _buildActions(),
                    ),
                    if (_linkError case final linkError?) ...[
                      const SizedBox(height: 8),
                      Text(
                        linkError,
                        key: const ValueKey('bilibili-panel-link-error'),
                        style: const TextStyle(
                          color: AppTokens.danger,
                          fontSize: 12,
                        ),
                      ),
                    ],
                    if (detail.parts.length > 1 && widget.canSelectParts) ...[
                      const SizedBox(height: 14),
                      _buildEpisodesEntry(detail),
                    ],
                  ],
                ),
              ),
              if (detail.season != null && detail.season!.episodes.isNotEmpty)
                ..._buildSeasonSlivers(detail),
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (detail.tags.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      _buildTags(detail),
                    ],
                    const SizedBox(height: 18),
                    _sectionTitle('简介'),
                    const SizedBox(height: 8),
                    BilibiliDescriptionText(
                      text: detail.description,
                      onLinkTap: _openDescriptionLink,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Before the detail is there: what the card knows (and what was last
  /// seen online), then a short loading line or, after a failure, a retry.
  /// External links remain available while offline; nothing spins on.
  Widget _buildWithoutDetail() {
    final known = _known;
    final knownTitle = known?.title.trim() ?? '';
    final title = knownTitle.isNotEmpty
        ? knownTitle
        : widget.fallbackTitle.trim();
    final owner = known?.ownerName.trim() ?? '';
    final description = known?.description.trim() ?? '';
    return ListView(
      key: const ValueKey('bilibili-panel-pending'),
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
      children: [
        if (title.isNotEmpty) ...[
          Text(
            title,
            style: const TextStyle(
              color: AppTokens.text1,
              fontSize: 15,
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 10),
        ],
        BilibiliVideoLinkActions(
          key: _videoLinksKey,
          bvid: widget.bvid,
          page: widget.page,
        ),
        const SizedBox(height: 10),
        if (owner.isNotEmpty) ...[
          Row(
            key: const ValueKey('bilibili-panel-known-owner'),
            children: [
              const BilibiliAvatar(url: null, size: 32),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  owner,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTokens.brandBilibili,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
        ],
        if (_failed)
          Row(
            key: ValueKey(
              _offline ? 'bilibili-panel-offline' : 'bilibili-panel-failed',
            ),
            children: [
              const Icon(
                Icons.cloud_off_outlined,
                size: 16,
                color: AppTokens.text3,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _offline ? '离线，联网后可加载' : '详情暂时加载不了',
                  style: const TextStyle(color: AppTokens.text2, fontSize: 13),
                ),
              ),
              DesktopButtonClickRegion(
                child: TextButton(
                  key: const ValueKey('bilibili-panel-retry'),
                  onPressed: () => unawaited(_load()),
                  child: const Text('重试'),
                ),
              ),
            ],
          )
        else ...[
          const Text(
            '正在加载详情…',
            style: TextStyle(color: AppTokens.text3, fontSize: 13),
          ),
          const SizedBox(height: 14),
          _DetailSkeleton(showOwner: owner.isEmpty),
        ],
        if (description.isNotEmpty) ...[
          const SizedBox(height: 18),
          _sectionTitle('简介'),
          const SizedBox(height: 8),
          BilibiliDescriptionText(
            key: const ValueKey('bilibili-panel-known-description'),
            text: description,
            onLinkTap: _openDescriptionLink,
          ),
        ],
      ],
    );
  }

  Widget _sectionTitle(String text) => Text(
    text,
    style: const TextStyle(
      color: AppTokens.text1,
      fontSize: 14,
      fontWeight: FontWeight.w600,
    ),
  );

  Widget _buildOwner(BilibiliVideoDetail detail) {
    final owner = detail.owner;
    return InkWell(
      key: const ValueKey('bilibili-panel-owner'),
      borderRadius: BorderRadius.circular(8),
      onTap: owner.mid > 0
          ? () => openBilibiliUploader(
              context,
              mid: owner.mid,
              name: owner.name,
              api: _api,
            )
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            BilibiliAvatar(url: owner.avatarUrl, size: 32),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    owner.name.isEmpty ? '未知 UP 主' : owner.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTokens.brandBilibili,
                      fontSize: 13,
                    ),
                  ),
                  if (detail.publishedAt != null)
                    Text(
                      formatBilibiliDate(detail.publishedAt),
                      style: const TextStyle(
                        color: AppTokens.text3,
                        fontSize: 11,
                      ),
                    ),
                ],
              ),
            ),
            if (owner.mid > 0)
              const Icon(Icons.chevron_right, size: 18, color: AppTokens.text3),
          ],
        ),
      ),
    );
  }

  Widget _buildStats(BilibiliVideoDetail detail) {
    final stat = detail.stat;
    final items = <(IconData, String, int)>[
      (Icons.play_circle_outline, '播放', stat.view),
      (Icons.subtitles_outlined, '弹幕', stat.danmaku),
      (Icons.thumb_up_alt_outlined, '点赞', stat.like),
      (Icons.monetization_on_outlined, '投币', stat.coin),
      (Icons.star_border, '收藏', stat.favorite),
      (Icons.chat_bubble_outline, '评论', stat.reply),
    ];
    return Wrap(
      key: const ValueKey('bilibili-panel-stats'),
      spacing: 12,
      runSpacing: 6,
      children: [
        for (final (icon, label, value) in items)
          Tooltip(
            message: label,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: AppTokens.text2),
                const SizedBox(width: 3),
                Text(
                  formatBilibiliCount(value),
                  style: const TextStyle(color: AppTokens.text2, fontSize: 12),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildActions() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        BilibiliImportButtons(
          bvid: widget.bvid,
          page: widget.page,
          emphasized: true,
        ),
        AddToPlaylistButton(
          key: const ValueKey('bilibili-detail-add-to-playlist'),
          onAdd: (progress) =>
              addBilibiliVideoToQueue(context, widget.bvid, progress: progress),
          height: 36,
          iconSize: 17,
        ),
        DesktopButtonClickRegion(
          child: OutlinedButton.icon(
            key: const ValueKey('bilibili-panel-download'),
            style: bilibiliCompactOutlinedStyle(foreground: AppTokens.text1),
            onPressed: _download,
            icon: const Icon(Icons.download_outlined, size: 17),
            label: const Text('下载', style: TextStyle(fontSize: 13)),
          ),
        ),
        BilibiliVideoLinkActions(
          key: _videoLinksKey,
          bvid: widget.bvid,
          page: widget.page,
          showIdentity: false,
        ),
      ],
    );
  }

  Widget _buildEpisodesEntry(BilibiliVideoDetail detail) {
    String current = '';
    for (final part in detail.parts) {
      if (part.page == widget.page) current = 'P${part.page} ${part.title}';
    }
    return Material(
      color: AppTokens.bgCard,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        key: const ValueKey('bilibili-panel-episodes'),
        dense: true,
        textColor: AppTokens.text1,
        iconColor: AppTokens.text2,
        leading: const Icon(Icons.playlist_play, size: 20),
        title: Text('选集（${detail.parts.length}）'),
        subtitle: current.isEmpty
            ? null
            : Text(
                current,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppTokens.text3, fontSize: 12),
              ),
        trailing: const Icon(Icons.chevron_right, size: 18),
        onTap: _openingParts || _switchingVideo || detail.bvid != widget.bvid
            ? null
            : () => unawaited(_openParts(detail)),
      ),
    );
  }

  List<Widget> _buildSeasonSlivers(BilibiliVideoDetail detail) {
    final season = detail.season!;
    final count = _showAllEpisodes
        ? season.episodes.length
        : season.episodes.length.clamp(0, 20);
    return [
      SliverToBoxAdapter(
        child: Padding(
          key: _seasonKey,
          padding: const EdgeInsets.only(top: 18, bottom: 8),
          child: Row(
            key: const ValueKey('bilibili-panel-season'),
            children: [
              Expanded(
                child: Text(
                  '合集 · ${season.title}（${season.episodes.length}）',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTokens.text1,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              BilibiliCollectionImportButton(
                source: BilibiliCollectionImportSource.fromDetail(detail),
                uploader: BilibiliUploaderService(api: _api),
                onImport: widget.onImportCollection,
              ),
            ],
          ),
        ),
      ),
      SliverList.builder(
        itemCount: count,
        itemBuilder: (context, index) {
          final ep = season.episodes[index];
          return Material(
            color: AppTokens.bgCard,
            borderRadius: BorderRadius.vertical(
              top: index == 0 ? const Radius.circular(8) : Radius.zero,
              bottom: index == count - 1 && count == season.episodes.length
                  ? const Radius.circular(8)
                  : Radius.zero,
            ),
            clipBehavior: Clip.hardEdge,
            child: _SeasonRow(
              key: ValueKey('bilibili-panel-season-${ep.bvid}'),
              index: index + 1,
              title: ep.title,
              duration: ep.durationSeconds > 0
                  ? formatBilibiliDuration(ep.durationSeconds)
                  : null,
              selected: ep.bvid == widget.bvid,
              onTap: ep.bvid == widget.bvid || _switchingVideo || _openingParts
                  ? null
                  : () => unawaited(
                      _watchSeasonEpisode(
                        ep.bvid,
                        page: 1,
                        preview: BilibiliWatchPreview(
                          title: ep.title,
                          coverUrl: ep.coverUrl,
                        ),
                      ),
                    ),
            ),
          );
        },
      ),
      if (count < season.episodes.length)
        SliverToBoxAdapter(
          child: Material(
            color: AppTokens.bgCard,
            borderRadius: const BorderRadius.vertical(
              bottom: Radius.circular(8),
            ),
            child: DesktopButtonClickRegion(
              child: TextButton(
                onPressed: () => setState(() => _showAllEpisodes = true),
                child: Text('展开全部 ${season.episodes.length} 个'),
              ),
            ),
          ),
        ),
    ];
  }

  Widget _buildTags(BilibiliVideoDetail detail) {
    return Wrap(
      key: const ValueKey('bilibili-panel-tags'),
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final tag in detail.tags)
          Material(
            color: AppTokens.bgCard,
            borderRadius: BorderRadius.circular(10),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: ValueKey('bilibili-panel-tag-$tag'),
              splashFactory: NoSplash.splashFactory,
              highlightColor: Colors.transparent,
              onTap: () => unawaited(openBilibiliSearch(context, keyword: tag)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                child: Text(
                  tag,
                  style: const TextStyle(color: AppTokens.text2, fontSize: 11),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// One collection row. The index starts at the left inset; the title
/// follows after a short gap. A fixed-width, right-aligned index left a
/// blank in front of shorter numbers.
class _SeasonRow extends StatelessWidget {
  const _SeasonRow({
    super.key,
    required this.index,
    required this.title,
    required this.selected,
    required this.onTap,
    this.duration,
  });

  final int index;
  final String title;
  final String? duration;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppTokens.brandBilibili : AppTokens.text1;
    return InkWell(
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              '$index',
              style: TextStyle(
                color: selected ? AppTokens.brandBilibili : AppTokens.text3,
                fontSize: 12,
                height: 1.3,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: color, fontSize: 13, height: 1.3),
              ),
            ),
            if (duration != null) ...[
              const SizedBox(width: 8),
              Text(
                duration!,
                style: const TextStyle(color: AppTokens.text3, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Whether [error] means no answer came back at all (offline, connection
/// failed, timed out), rather than Bilibili refusing the request.
bool isBilibiliNetworkFailure(Object error) =>
    error is TimeoutException ||
    (error is BilibiliPublicApiException && error.isNetworkError);

/// Grey outlines of the uploader row, the counts and
/// the description, where the detail will show once it is there.
class _DetailSkeleton extends StatelessWidget {
  const _DetailSkeleton({required this.showOwner});

  final bool showOwner;

  @override
  Widget build(BuildContext context) {
    Widget bar(double widthFactor, {double height = 10}) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: widthFactor,
        child: Container(
          height: height,
          decoration: BoxDecoration(
            color: AppTokens.bgCard,
            borderRadius: BorderRadius.circular(5),
          ),
        ),
      ),
    );
    return Column(
      key: const ValueKey('bilibili-panel-skeleton'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showOwner) ...[
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: const BoxDecoration(
                  color: AppTokens.bgCard,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Container(
                  width: 96,
                  height: 12,
                  decoration: BoxDecoration(
                    color: AppTokens.bgCard,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
        ],
        bar(0.6),
        const SizedBox(height: 14),
        bar(0.9),
        bar(0.75),
        bar(0.5),
      ],
    );
  }
}
