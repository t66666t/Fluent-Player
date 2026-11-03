import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/models/bilibili_browse_models.dart';
import 'package:video_player_app/screens/bilibili/bilibili_account_screen.dart';
import 'package:video_player_app/screens/bilibili/bilibili_favorites_screen.dart';
import 'package:video_player_app/screens/bilibili/bilibili_uploader_screen.dart';
import 'package:video_player_app/screens/bilibili/bilibili_card_actions.dart';
import 'package:video_player_app/screens/bilibili/bilibili_import_buttons.dart';
import 'package:video_player_app/screens/bilibili/bilibili_watch_history_screen.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_history_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_watch_launch.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';
import 'package:video_player_app/widgets/media_library_page_shortcuts.dart';
import 'package:video_player_app/utils/page_shortcut_keys.dart';
import 'package:video_player_app/widgets/playback_source_viewport.dart';
import 'package:video_player_app/widgets/media_library_scroll_viewport.dart';
import 'package:video_player_app/utils/bilibili_image_url.dart';
import 'package:video_player_app/utils/bilibili_text.dart';
import 'package:video_player_app/utils/bilibili_url_parser.dart';
import 'package:video_player_app/widgets/bilibili_adaptive_list.dart';
import 'package:video_player_app/widgets/bilibili_video_list_tile.dart';
import 'package:video_player_app/widgets/bilibili_cover_image.dart';
import 'package:video_player_app/widgets/bilibili_duration_picker.dart';
import 'package:video_player_app/widgets/bilibili_filter_picker.dart';
import 'package:video_player_app/widgets/bilibili_loading.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Opens the in-app Bilibili search and runs [keyword] immediately.
Future<void> openBilibiliSearch(
  BuildContext context, {
  required String keyword,
}) {
  final text = keyword.trim();
  if (text.isEmpty) return Future<void>.value();
  return pushAboveMediaLibrary(
    context,
    AppMaterialPageRoute<void>(
      builder: (_) => BilibiliHomePage(
        isActive: true,
        initialKeyword: text,
        showAppBar: true,
      ),
    ),
  );
}

/// Fourth root page: Bilibili search with video/user results.
///
/// Nothing is requested until the user searches; the login avatar is read
/// the first time the page becomes active.
class BilibiliHomePage extends StatefulWidget {
  const BilibiliHomePage({
    super.key,
    required this.isActive,
    this.api,
    this.bottomPadding = 0,
    this.onWatch,
    this.onImport,
    this.initialKeyword,
    this.showAppBar = false,
  });

  final bool isActive;
  final BilibiliPublicApiService? api;
  final double bottomPadding;

  /// When set, the page searches this text as soon as it opens.
  final String? initialKeyword;

  /// Pushed search (a tag, for example) needs a back button. The root tab
  /// does not.
  final bool showAppBar;

  /// Plays a tapped video or pasted link; defaults to [watchBilibiliVideo].
  final BilibiliVideoWatcher? onWatch;

  /// Runs the import buttons of the results; defaults to
  /// [importBilibiliVideoQuick].
  final BilibiliQuickImporter? onImport;

  @override
  State<BilibiliHomePage> createState() => _BilibiliHomePageState();
}

class _SearchResults<T> {
  final List<T> items = <T>[];
  int page = 0;
  bool hasMore = false;
  bool loading = false;
  String? error;
  bool loadedOnce = false;
  bool scanPaused = false;
  int token = 0;

  void reset() {
    items.clear();
    page = 0;
    hasMore = false;
    loading = false;
    error = null;
    loadedOnce = false;
    scanPaused = false;
    token++;
  }
}

class _BilibiliHomePageState extends State<BilibiliHomePage> {
  late final BilibiliPublicApiService _api =
      widget.api ?? BilibiliPublicApiService();
  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  final ScrollController _videoScroll = PlaybackScrollController();
  final ScrollController _userScroll = PlaybackScrollController();
  final _SearchResults<BilibiliSearchVideo> _videos = _SearchResults();
  final _SearchResults<BilibiliSearchUser> _users = _SearchResults();
  final BilibiliHistoryService _history = BilibiliHistoryService.instance;

  Timer? _suggestDebounce;
  List<String> _suggestions = const <String>[];
  int _suggestToken = 0;
  String _keyword = '';
  int _tab = 0;
  BilibiliVideoSearchFilter _filter = const BilibiliVideoSearchFilter();
  bool _openingTarget = false;
  String? _inlineError;

  bool _accountChecked = false;
  String? _avatarUrl;
  bool _loggedIn = false;
  final SettingsService _settings = SettingsService();

  @override
  void initState() {
    super.initState();
    _videoScroll.addListener(() => _maybeLoadMore(0));
    _userScroll.addListener(() => _maybeLoadMore(1));
    _inputFocus.addListener(_handleFocusChange);
    _history.addListener(_handleHistoryChanged);
    _settings.addListener(_handleHistoryChanged);
    unawaited(_history.ensureLoaded());
    if (widget.isActive) _scheduleAccountCheck();
    final keyword = widget.initialKeyword?.trim() ?? '';
    if (keyword.isNotEmpty) {
      _input.text = keyword;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_submit(keyword));
      });
    }
  }

  void _handleHistoryChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant BilibiliHomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) _scheduleAccountCheck();
    if (!widget.isActive && oldWidget.isActive) {
      _inputFocus.unfocus();
    }
  }

  @override
  void dispose() {
    _suggestDebounce?.cancel();
    _history.removeListener(_handleHistoryChanged);
    _settings.removeListener(_handleHistoryChanged);
    _input.dispose();
    _inputFocus.dispose();
    _videoScroll.dispose();
    _userScroll.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- account

  void _scheduleAccountCheck() {
    if (_accountChecked) return;
    _accountChecked = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refreshAccount());
    });
  }

  BilibiliDownloadService? _downloadService() {
    try {
      return context.read<BilibiliDownloadService>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  Future<void> _refreshAccount() async {
    final service = _downloadService();
    if (service == null) return;
    try {
      await service.apiService.init();
      final state = await service.apiService.fetchLoginState();
      _applyAccountState(state);
    } catch (_) {
      // The avatar is decorative; the account page shows the real state.
    }
  }

  void _applyAccountState(BilibiliLoginState state) {
    if (!mounted) return;
    final account = state.account;
    setState(() {
      _loggedIn =
          state.status == BilibiliLoginStatus.loggedIn ||
          (state.status == BilibiliLoginStatus.networkError && account != null);
      _avatarUrl = _loggedIn ? bilibiliAvatarUrl(account?.avatarUrl) : null;
    });
  }

  /// The avatar opens the account page; its login changes reach the avatar
  /// right away.
  Future<void> _openAccount() async {
    _inputFocus.unfocus();
    await openBilibiliAccount(
      context,
      api: _downloadService()?.apiService,
      onStateChanged: _applyAccountState,
    );
  }

  void _openHistory() {
    _inputFocus.unfocus();
    unawaited(openBilibiliWatchHistory(context, api: _api));
  }

  void _openFavorites() {
    _inputFocus.unfocus();
    unawaited(
      openBilibiliFavorites(
        context,
        accountApi: _downloadService()?.apiService,
        api: widget.api,
      ),
    );
  }

  void _refreshSearch() {
    final results = _resultsFor(_tab);
    if (_keyword.isEmpty || results.loading || _openingTarget) return;
    setState(results.reset);
    final scroll = _tab == 0 ? _videoScroll : _userScroll;
    if (scroll.hasClients) scroll.jumpTo(0);
    unawaited(_load(_tab));
  }

  // ------------------------------------------------------------ suggestions

  void _handleFocusChange() {
    // The search history overlay follows focus.
    if (mounted) setState(() {});
    if (!_inputFocus.hasFocus && _suggestions.isNotEmpty) {
      // Let a tap on a suggestion land before the list disappears.
      Future<void>.delayed(const Duration(milliseconds: 150), () {
        if (mounted && !_inputFocus.hasFocus) {
          setState(() => _suggestions = const <String>[]);
        }
      });
    }
  }

  void _handleInputChanged(String value) {
    _suggestDebounce?.cancel();
    final token = ++_suggestToken;
    final text = value.trim();
    if (text.isEmpty || (parseBilibiliLink(text)?.isVideo ?? false)) {
      if (_suggestions.isNotEmpty) {
        setState(() => _suggestions = const <String>[]);
      } else {
        setState(() {});
      }
      return;
    }
    setState(() {});
    _suggestDebounce = Timer(const Duration(milliseconds: 300), () async {
      final result = await _api.suggestKeywords(text);
      if (!mounted || token != _suggestToken || !_inputFocus.hasFocus) return;
      setState(() => _suggestions = result);
    });
  }

  void _clearInput() {
    _input.clear();
    _suggestToken++;
    setState(() => _suggestions = const <String>[]);
    _inputFocus.requestFocus();
  }

  // ----------------------------------------------------------------- search

  Future<void> _submit(String raw) async {
    final text = raw.trim();
    _suggestDebounce?.cancel();
    _suggestToken++;
    setState(() => _suggestions = const <String>[]);
    if (text.isEmpty) return;
    _inputFocus.unfocus();

    final target = parseBilibiliLink(text);
    if (target != null && target.isVideo) {
      await _openTarget(target);
      return;
    }
    unawaited(_history.addSearch(text));
    setState(() {
      _keyword = text;
      _inlineError = null;
      _videos.reset();
      _users.reset();
    });
    _jumpToTop();
    unawaited(_load(_tab));
  }

  void _searchFromHistory(String keyword) {
    _input.text = keyword;
    _input.selection = TextSelection.collapsed(offset: keyword.length);
    unawaited(_submit(keyword));
  }

  /// Over the results while the empty search box has focus; before the first
  /// search the history is part of the page body instead.
  bool get _showSearchHistoryOverlay =>
      _keyword.isNotEmpty &&
      _inputFocus.hasFocus &&
      _input.text.trim().isEmpty &&
      _hasVisibleSearchHistory;

  /// Turning search history off in the Bilibili settings hides it here; the
  /// saved keywords stay until cleared.
  bool get _hasVisibleSearchHistory =>
      _settings.bilibiliRecordSearchHistory &&
      _history.searchHistory.isNotEmpty;

  void _jumpToTop() {
    for (final controller in [_videoScroll, _userScroll]) {
      if (controller.hasClients) controller.jumpTo(0);
    }
  }

  Future<void> _openTarget(BilibiliLinkTarget target) async {
    if (_openingTarget) return;
    var resolved = target;
    if (target.needsResolve) {
      _openingTarget = true;
      if (mounted) setState(() => _inlineError = '正在解析链接…');
      try {
        final result = await _api.resolveShortLink(target.shortLink!);
        final next = result.target;
        if (next == null || !next.isVideo) {
          if (mounted) {
            setState(() {
              _inlineError =
                  result.message ?? BilibiliShortLinkFailure.noVideo.message;
            });
          }
          return;
        }
        resolved = next;
      } finally {
        _openingTarget = false;
      }
    }
    if (!mounted) return;
    final bvid =
        resolved.bvid ??
        (resolved.aid != null ? bvidFromAid(resolved.aid!) : null);
    if (bvid == null) {
      setState(() => _inlineError = BilibiliShortLinkFailure.noVideo.message);
      return;
    }
    if (_inlineError != null) setState(() => _inlineError = null);
    await _watch(bvid, page: resolved.page, startAt: resolved.startAt);
  }

  Future<void> _watch(
    String bvid, {
    int? page,
    Duration? startAt,
    BilibiliWatchPreview? preview,
  }) {
    final watch = widget.onWatch ?? watchBilibiliVideo;
    return watch(
      context,
      bvid: bvid,
      page: page,
      startAt: startAt,
      preview: preview,
    );
  }

  _SearchResults<Object?> _resultsFor(int tab) =>
      (tab == 0 ? _videos : _users) as _SearchResults<Object?>;

  Future<void> _load(int tab) async {
    final results = tab == 0 ? _videos : _users;
    if (_keyword.isEmpty || results.loading) return;
    if (results.loadedOnce && !results.hasMore) return;
    final token = results.token;
    final keyword = _keyword;
    final filter = _filter;
    setState(() {
      results.loading = true;
      results.error = null;
      results.scanPaused = false;
    });
    try {
      if (tab == 0) {
        final initialCount = _videos.items.length;
        final range = filter.durationRange;
        for (var scanned = 1; ; scanned++) {
          if (!mounted || token != _videos.token) return;
          final result = await _api.searchVideos(
            keyword,
            page: _videos.page + 1,
            filter: filter,
          );
          if (!mounted || token != _videos.token) return;
          var keepScanning = false;
          setState(() {
            final seen = _videos.items.map((v) => v.bvid).toSet();
            _videos.items.addAll(
              result.items.where(
                (v) =>
                    (range == null || range.includes(v.durationSeconds)) &&
                    seen.add(v.bvid),
              ),
            );
            _applyPage(_videos, result.page, result.hasMore);
            final needsMore =
                range?.isRestricted == true &&
                result.hasMore &&
                _videos.items.length - initialCount < 20;
            keepScanning =
                needsMore && scanned < 5 && _tab == 0 && widget.isActive;
            _videos.loading = keepScanning;
            _videos.scanPaused = needsMore && !keepScanning;
          });
          if (!keepScanning) break;
          await Future<void>.delayed(const Duration(milliseconds: 180));
        }
      } else {
        final result = await _api.searchUsers(keyword, page: _users.page + 1);
        if (!mounted || token != _users.token) return;
        setState(() {
          final seen = _users.items.map((u) => u.mid).toSet();
          _users.items.addAll(result.items.where((u) => seen.add(u.mid)));
          _applyPage(_users, result.page, result.hasMore);
        });
      }
      WidgetsBinding.instance.addPostFrameCallback((_) => _fillViewport(tab));
    } on BilibiliPublicApiException catch (e) {
      if (!mounted || token != results.token) return;
      setState(() {
        results.loading = false;
        results.error = e.message;
      });
    }
  }

  void _applyPage(_SearchResults<dynamic> results, int page, bool hasMore) {
    results
      ..page = page
      ..hasMore = hasMore
      ..loading = false
      ..loadedOnce = true;
  }

  /// A short first page cannot be scrolled, so keep loading until it can.
  void _fillViewport(int tab) {
    if (!mounted || tab != _tab) return;
    final controller = tab == 0 ? _videoScroll : _userScroll;
    if (!controller.hasClients) return;
    if (controller.position.maxScrollExtent <= 0) _maybeLoadMore(tab);
  }

  void _maybeLoadMore(int tab) {
    final controller = tab == 0 ? _videoScroll : _userScroll;
    final results = _resultsFor(tab);
    if (!controller.hasClients ||
        results.loading ||
        !results.hasMore ||
        results.scanPaused) {
      return;
    }
    if (results.error != null) return;
    if (controller.position.extentAfter < 600) unawaited(_load(tab));
  }

  void _selectTab(int tab) {
    if (tab == _tab) return;
    setState(() => _tab = tab);
    final results = _resultsFor(tab);
    if (_keyword.isNotEmpty && !results.loadedOnce && !results.loading) {
      unawaited(_load(tab));
    }
  }

  void _updateFilter(BilibiliVideoSearchFilter next) {
    if (next == _filter) return;
    setState(() {
      _filter = next;
      _videos.reset();
    });
    if (_videoScroll.hasClients) _videoScroll.jumpTo(0);
    if (_keyword.isNotEmpty) unawaited(_load(0));
  }

  // --------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final page = _buildPage();
    final wrapped = widget.showAppBar
        ? Scaffold(
            backgroundColor: AppTokens.bgBase,
            appBar: AppBar(
              backgroundColor: AppTokens.bgBase,
              foregroundColor: AppTokens.text1,
              elevation: 0,
              title: const Text('搜索 B 站', style: TextStyle(fontSize: 16)),
            ),
            body: SafeArea(top: false, child: page),
          )
        : page;
    return MediaLibraryPageShortcuts(
      enabled: widget.isActive,
      bindings: {
        LogicalKeyboardKey.keyS: _inputFocus.requestFocus,
        LogicalKeyboardKey.slash: _inputFocus.requestFocus,
        LogicalKeyboardKey.keyH: _openHistory,
        LogicalKeyboardKey.keyL: () => unawaited(_openAccount()),
        LogicalKeyboardKey.keyR: _refreshSearch,
      },
      child: BilibiliQuietTap(child: wrapped),
    );
  }

  Widget _buildPage() {
    return Material(
      color: AppTokens.bgBase,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSearchBar(),
          if (_inlineError case final inlineError?)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(
                inlineError,
                key: const ValueKey('bilibili-search-inline-error'),
                style: TextStyle(
                  color: inlineError.startsWith('正在')
                      ? AppTokens.text3
                      : AppTokens.danger,
                  fontSize: 12,
                ),
              ),
            ),
          _buildTabs(),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: IndexedStack(
                    index: _tab,
                    children: [
                      // The hidden tab must not keep a spinner ticking.
                      TickerMode(
                        enabled: widget.isActive && _tab == 0,
                        child: _buildVideoTab(),
                      ),
                      TickerMode(
                        enabled: widget.isActive && _tab == 1,
                        child: _buildUserTab(),
                      ),
                    ],
                  ),
                ),
                if (_showSearchHistoryOverlay)
                  Positioned(
                    left: 12,
                    right: 12,
                    top: 0,
                    // Taps inside count as the search box, so it keeps focus.
                    child: TextFieldTapRegion(
                      child: _buildSearchHistory(overlay: true),
                    ),
                  ),
                if (_suggestions.isNotEmpty && _inputFocus.hasFocus)
                  Positioned(
                    left: 12,
                    right: 12,
                    top: 0,
                    // A tap here must count as inside the search box. Otherwise
                    // the field unfocuses on pointer-down, this list is taken
                    // down in the same frame, and the suggestion's onTap never
                    // runs — the row vanishes and nothing is searched.
                    child: TextFieldTapRegion(child: _buildSuggestions()),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 6),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _input,
              focusNode: _inputFocus,
              textInputAction: TextInputAction.search,
              onChanged: _handleInputChanged,
              onSubmitted: _submit,
              // Mobile touch taps do not unfocus a TextField by default.
              // Suggestions and history remain inside TextFieldTapRegion.
              onTapOutside: (_) => _inputFocus.unfocus(),
              style: const TextStyle(color: AppTokens.text1, fontSize: 14),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: AppTokens.bgCard,
                hintText: hoverAwareShortcutTooltip(
                  '搜索 B 站视频、UP 主，或粘贴 BV 号/链接',
                  LogicalKeyboardKey.keyS,
                  context: context,
                ),
                hintStyle: const TextStyle(
                  color: AppTokens.text3,
                  fontSize: 14,
                ),
                prefixIcon: const Icon(
                  Icons.search,
                  size: 20,
                  color: AppTokens.text2,
                ),
                suffixIcon: _input.text.isEmpty
                    ? null
                    : DesktopButtonClickRegion(
                        child: IconButton(
                          tooltip: '清空',
                          icon: const Icon(
                            Icons.close,
                            size: 18,
                            color: AppTokens.text2,
                          ),
                          onPressed: _clearInput,
                        ),
                      ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          if (_keyword.isNotEmpty)
            DesktopButtonClickRegion(
              child: IconButton(
                tooltip: hoverAwareShortcutTooltip(
                  '刷新搜索结果',
                  LogicalKeyboardKey.keyR,
                  context: context,
                ),
                onPressed: _resultsFor(_tab).loading || _openingTarget
                    ? null
                    : _refreshSearch,
                icon: const Icon(
                  Icons.refresh,
                  size: 22,
                  color: AppTokens.text2,
                ),
              ),
            ),
          DesktopButtonClickRegion(
            child: IconButton(
              tooltip: hoverAwareShortcutTooltip(
                '观看历史',
                LogicalKeyboardKey.keyH,
                context: context,
              ),
              onPressed: _openHistory,
              icon: const Icon(Icons.history, size: 24, color: AppTokens.text2),
            ),
          ),
          DesktopButtonClickRegion(
            child: IconButton(
              key: const ValueKey('bilibili-favorites-button'),
              tooltip: 'B 站收藏夹',
              onPressed: _openFavorites,
              icon: const Icon(
                Icons.folder_special_outlined,
                size: 24,
                color: AppTokens.text2,
              ),
            ),
          ),
          DesktopButtonClickRegion(
            child: IconButton(
              key: const ValueKey('bilibili-account-button'),
              tooltip: hoverAwareShortcutTooltip(
                _loggedIn ? 'B 站账号' : '登录 B 站',
                LogicalKeyboardKey.keyL,
                context: context,
              ),
              onPressed: _openAccount,
              icon: _avatarUrl == null
                  ? const Icon(
                      Icons.account_circle_outlined,
                      size: 30,
                      color: AppTokens.text2,
                    )
                  : BilibiliAvatar(url: _avatarUrl, size: 30),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabs() {
    Widget tab(int index, String label) {
      final selected = _tab == index;
      return InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => _selectTab(index),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: selected ? AppTokens.text1 : AppTokens.text2,
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              const SizedBox(height: 4),
              Container(
                width: 18,
                height: 2,
                decoration: BoxDecoration(
                  color: selected
                      ? AppTokens.brandBilibili
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(children: [tab(0, '视频'), tab(1, '用户')]),
    );
  }

  Widget _buildSuggestions() {
    return Material(
      color: AppTokens.bgOverlay,
      elevation: 6,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final value in _suggestions)
            InkWell(
              key: ValueKey<String>('bilibili-search-suggestion-$value'),
              onTap: () {
                _input.text = value;
                _input.selection = TextSelection.collapsed(
                  offset: value.length,
                );
                unawaited(_submit(value));
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.search, size: 16, color: AppTokens.text3),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTokens.text1,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSearchHistory({required bool overlay}) {
    final entries = _history.searchHistory;
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '搜索历史',
                style: TextStyle(
                  color: AppTokens.text2,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              DesktopButtonClickRegion(
                child: TextButton(
                  key: const ValueKey<String>('bilibili-search-history-clear'),
                  onPressed: () => unawaited(_history.clearSearch()),
                  child: const Text(
                    '清空',
                    style: TextStyle(color: AppTokens.text3, fontSize: 12),
                  ),
                ),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final keyword in entries) _historyChip(keyword)],
          ),
        ],
      ),
    );
    if (!overlay) return content;
    return Material(
      color: AppTokens.bgOverlay,
      elevation: 6,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: content,
    );
  }

  Widget _historyChip(String keyword) {
    return Material(
      color: AppTokens.bgCard,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        key: ValueKey<String>('bilibili-search-history-$keyword'),
        borderRadius: BorderRadius.circular(14),
        onTap: () => _searchFromHistory(keyword),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 5, 4, 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  keyword,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppTokens.text1, fontSize: 13),
                ),
              ),
              const SizedBox(width: 2),
              InkResponse(
                key: ValueKey<String>(
                  'bilibili-search-history-remove-$keyword',
                ),
                radius: 12,
                onTap: () => unawaited(_history.removeSearch(keyword)),
                child: const Padding(
                  padding: EdgeInsets.all(2),
                  child: Icon(Icons.close, size: 14, color: AppTokens.text3),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFilterBar() {
    Widget menu<T>({
      required String label,
      required T value,
      required List<T> values,
      required String Function(T) labelOf,
      required ValueChanged<T> onSelected,
    }) {
      return BilibiliFilterButton(
        label: labelOf(value),
        tooltip: label,
        active: value != values.first,
        onPressed: (anchorContext) async {
          _inputFocus.unfocus();
          final next = await showBilibiliFilterPicker<T>(
            context: context,
            anchorContext: anchorContext,
            title: label,
            selected: value,
            values: values,
            labelOf: labelOf,
          );
          if (mounted && next != null) onSelected(next);
        },
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          menu<BilibiliVideoSearchOrder>(
            label: '排序',
            value: _filter.order,
            values: BilibiliVideoSearchOrder.values,
            labelOf: (v) => v.label,
            onSelected: (v) => _updateFilter(_filter.copyWith(order: v)),
          ),
          BilibiliFilterButton(
            label: _filter.durationRange?.label ?? _filter.duration.label,
            tooltip: '时长',
            active:
                _filter.durationRange?.isRestricted ??
                _filter.duration != BilibiliVideoDurationFilter.any,
            onPressed: (_) async {
              _inputFocus.unfocus();
              final range = await showBilibiliDurationPicker(
                context: context,
                selected:
                    _filter.durationRange ??
                    BilibiliVideoDurationRange.fromPreset(_filter.duration),
              );
              if (!mounted || range == null) return;
              _updateFilter(
                _filter.copyWith(
                  duration: BilibiliVideoDurationFilter.any,
                  durationRange: range,
                  clearDurationRange: !range.isRestricted,
                ),
              );
            },
          ),
          menu<BilibiliPublishedFilter>(
            label: '发布时间',
            value: _filter.published,
            values: BilibiliPublishedFilter.values,
            labelOf: (v) => v.label,
            onSelected: (v) => _updateFilter(_filter.copyWith(published: v)),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildFilterBar(),
        Expanded(
          child: _buildResultList<BilibiliSearchVideo>(
            results: _videos,
            controller: _videoScroll,
            tab: 0,
            itemBuilder: _buildVideoTile,
          ),
        ),
      ],
    );
  }

  Widget _buildUserTab() {
    return _buildResultList<BilibiliSearchUser>(
      results: _users,
      controller: _userScroll,
      tab: 1,
      itemBuilder: _buildUserTile,
    );
  }

  Widget _buildResultList<T>({
    required _SearchResults<T> results,
    required ScrollController controller,
    required int tab,
    required Widget Function(T item) itemBuilder,
  }) {
    final loading =
        _keyword.isNotEmpty &&
        results.items.isEmpty &&
        (results.loading || !results.loadedOnce && results.error == null);
    final state = _keyword.isEmpty
        ? 'idle'
        : results.items.isNotEmpty
        ? 'content'
        : results.error != null
        ? 'error'
        : 'empty';
    return MediaLibraryScrollViewport(
      controller: controller,
      isActive: widget.isActive && _tab == tab,
      bottomObstruction: widget.bottomPadding,
      child: BilibiliLoadTransition(
        loading: loading,
        stateKey: (results.token, state),
        placeholder: BilibiliListSkeleton(
          kind: tab == 0
              ? BilibiliSkeletonKind.video
              : BilibiliSkeletonKind.user,
          showLabel: tab == 0 && _filter.durationRange?.isRestricted == true,
          label: tab == 0 && _filter.durationRange?.isRestricted == true
              ? '正在寻找符合时长的视频…'
              : '正在搜索…',
          padding: EdgeInsets.only(bottom: 16 + widget.bottomPadding),
        ),
        child: loading
            ? const SizedBox.shrink()
            : _buildResultBody(
                results: results,
                controller: controller,
                tab: tab,
                itemBuilder: itemBuilder,
              ),
      ),
    );
  }

  Widget _buildResultBody<T>({
    required _SearchResults<T> results,
    required ScrollController controller,
    required int tab,
    required Widget Function(T item) itemBuilder,
  }) {
    if (_keyword.isEmpty) {
      final hint = _buildHint(
        Icons.travel_explore,
        '输入关键词搜索 B 站内容',
        '也可以直接粘贴 BV 号或视频链接播放',
      );
      if (!_hasVisibleSearchHistory) return hint;
      return ListView(
        controller: controller,
        padding: EdgeInsets.only(bottom: 16 + widget.bottomPadding),
        children: [_buildSearchHistory(overlay: false), hint],
      );
    }
    if (results.items.isEmpty) {
      if (results.error != null) {
        return _buildHint(
          Icons.cloud_off_outlined,
          results.error!,
          '',
          action: DesktopButtonClickRegion(
            child: TextButton(
              onPressed: () => _load(tab),
              child: const Text('重试'),
            ),
          ),
        );
      }
      if (tab == 0 && _filter.durationRange?.isRestricted == true) {
        return _buildHint(
          Icons.search_off,
          results.hasMore ? '暂未找到符合时长的视频' : '没有符合时长范围的视频',
          results.hasMore ? '可以继续查找，或放宽时长范围' : '试试放宽时长范围，或换个关键词',
          action: results.hasMore
              ? DesktopButtonClickRegion(
                  child: TextButton(
                    onPressed: () => _load(tab),
                    child: const Text('继续查找'),
                  ),
                )
              : null,
        );
      }
      return _buildHint(Icons.search_off, '没有找到相关结果', '换个关键词试试');
    }
    // Wide windows show the results in columns: a page may then no longer
    // fill the list, so check for more whenever its size changes.
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        _maybeLoadMore(tab);
        return false;
      },
      child: BilibiliAdaptiveList(
        itemKey: (index) => switch (results.items[index]) {
          BilibiliSearchVideo video => video.bvid,
          BilibiliSearchUser user => user.mid,
          final item => item as Object,
        },
        animateItems: true,
        controller: controller,
        padding: EdgeInsets.only(bottom: 16 + widget.bottomPadding),
        itemCount: results.items.length,
        itemBuilder: (context, index) => itemBuilder(results.items[index]),
        footer: (context) => _buildFooter(results, tab),
      ),
    );
  }

  Widget _buildFooter(_SearchResults<dynamic> results, int tab) {
    final Widget child;
    if (results.loading) {
      child = Text(
        tab == 0 && _filter.durationRange?.isRestricted == true
            ? '正在寻找符合时长的视频…'
            : '正在加载更多…',
        style: const TextStyle(color: AppTokens.text3, fontSize: 12),
      );
    } else if (results.error != null) {
      child = DesktopButtonClickRegion(
        child: TextButton(
          onPressed: () => _load(tab),
          child: Text('${results.error}，点此重试'),
        ),
      );
    } else if (results.scanPaused) {
      child = DesktopButtonClickRegion(
        child: TextButton(
          onPressed: () => _load(tab),
          child: const Text('继续查找符合时长的视频'),
        ),
      );
    } else if (!results.hasMore) {
      child = Text(
        results.page >= kBilibiliSearchMaxPages ? '最多显示 50 页结果' : '没有更多了',
        style: const TextStyle(color: AppTokens.text3, fontSize: 12),
      );
    } else {
      child = const SizedBox(height: 20);
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 64),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Center(child: child),
      ),
    );
  }

  Widget _buildHint(
    IconData icon,
    String title,
    String subtitle, {
    Widget? action,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: AppTokens.text3),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTokens.text1, fontSize: 14),
            ),
            if (subtitle.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppTokens.text3, fontSize: 12),
              ),
            ],
            ?action,
          ],
        ),
      ),
    );
  }

  Widget _buildVideoTile(BilibiliSearchVideo video) {
    final meta = <String>[
      if (video.playCount > 0) '${formatBilibiliCount(video.playCount)} 播放',
      if (video.publishedAt != null) formatBilibiliDate(video.publishedAt),
    ];
    return BilibiliVideoListTile(
      title: video.title,
      coverUrl: bilibiliCoverThumbnailUrl(video.coverUrl),
      duration: video.durationSeconds > 0
          ? formatBilibiliDuration(video.durationSeconds)
          : null,
      onTap: () => unawaited(
        _watch(
          video.bvid,
          preview: BilibiliWatchPreview(
            title: video.title,
            coverUrl: bilibiliCoverThumbnailUrl(video.coverUrl),
          ),
        ),
      ),
      metadata: [
        _buildAuthor(video),
        // At the default text scale, these three compact lines fit within
        // the existing action row, keeping the tile and cover height stable.
        for (final line in meta)
          Text(
            line,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppTokens.text3, fontSize: 11),
          ),
      ],
      actions: BilibiliImportButtons(
        bvid: video.bvid,
        onImport: widget.onImport,
      ),
    );
  }

  /// The UP name opens the uploader page; the rest of the tile plays the
  /// video.
  Widget _buildAuthor(BilibiliSearchVideo video) {
    final text = Text(
      video.author.isEmpty ? '未知 UP 主' : video.author,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(color: AppTokens.text2, fontSize: 12),
    );
    if (video.mid <= 0) return text;
    return GestureDetector(
      key: ValueKey('bilibili-search-video-author-${video.bvid}'),
      behavior: HitTestBehavior.opaque,
      onTap: () => openBilibiliUploader(
        context,
        mid: video.mid,
        name: video.author,
        api: _api,
      ),
      child: MouseRegion(cursor: SystemMouseCursors.click, child: text),
    );
  }

  Widget _buildUserTile(BilibiliSearchUser user) {
    final meta = <String>[
      if (user.level > 0) 'Lv${user.level}',
      '${formatBilibiliCount(user.fans)} 粉丝',
      '${formatBilibiliCount(user.videos)} 个视频',
    ].join(' · ');
    final subtitle = user.officialDesc.isNotEmpty
        ? user.officialDesc
        : user.sign;
    return InkWell(
      key: ValueKey('bilibili-search-user-${user.mid}'),
      onTap: () => openBilibiliUploader(
        context,
        mid: user.mid,
        name: user.name,
        api: _api,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            BilibiliAvatar(url: user.avatarUrl, size: 48),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTokens.text1,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    meta,
                    style: const TextStyle(
                      color: AppTokens.text3,
                      fontSize: 11,
                    ),
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTokens.text2,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
