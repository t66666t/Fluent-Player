import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/models/bilibili_favorites_models.dart';
import 'package:video_player_app/models/bilibili_uploader_models.dart';
import 'package:video_player_app/models/import_card_placement.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_favorites_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_favorites_import.dart';
import 'package:video_player_app/services/bilibili/bilibili_favorites_selection.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_watch_launch.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:video_player_app/utils/bilibili_text.dart';
import 'package:video_player_app/widgets/bilibili_loading.dart';
import 'package:video_player_app/widgets/bilibili_video_list_tile.dart';
import 'package:video_player_app/widgets/bilibili_favorites_import_buttons.dart';
import 'package:video_player_app/widgets/library_folder_picker.dart';
import 'package:video_player_app/widgets/media_library_selection_bottom_bar.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';

import 'bilibili_account_screen.dart';
import 'bilibili_card_actions.dart';
import 'bilibili_import_buttons.dart';
import 'bilibili_uploader_screen.dart';

typedef BilibiliFavoritesBatchImporter =
    Future<BilibiliFavoritesImportResult> Function(
      BuildContext context,
      BilibiliFavoritesImportRequest request, {
      required bool Function() isCancelled,
      void Function(String message)? onProgress,
    });

typedef BilibiliFavoritesLocationPicker =
    Future<ImportPlacementRequest?> Function(
      BuildContext context,
      ImportPlacementRequest current,
    );

Future<void> openBilibiliFavorites(
  BuildContext context, {
  BilibiliApiService? accountApi,
  BilibiliPublicApiService? api,
}) => pushAboveMediaLibrary(
  context,
  AppMaterialPageRoute<void>(
    builder: (_) => BilibiliFavoritesScreen(accountApi: accountApi, api: api),
  ),
);

class BilibiliFavoritesScreen extends StatefulWidget {
  const BilibiliFavoritesScreen({
    super.key,
    this.accountApi,
    this.api,
    this.service,
    this.folder,
    this.ownerMid,
    this.onWatch,
    this.onImport,
    this.onBatchImport,
    this.onPickImportLocation,
  });

  final BilibiliApiService? accountApi;
  final BilibiliPublicApiService? api;
  final BilibiliFavoritesService? service;
  final BilibiliFavoriteFolder? folder;
  final int? ownerMid;
  final BilibiliVideoWatcher? onWatch;
  final BilibiliQuickImporter? onImport;
  final BilibiliFavoritesBatchImporter? onBatchImport;
  final BilibiliFavoritesLocationPicker? onPickImportLocation;

  @override
  State<BilibiliFavoritesScreen> createState() =>
      _BilibiliFavoritesScreenState();
}

class _BilibiliFavoritesScreenState extends State<BilibiliFavoritesScreen> {
  late final BilibiliApiService? _accountApi = widget.accountApi ?? _appApi();
  late final BilibiliPublicApiService _api =
      widget.api ??
      BilibiliPublicApiService(loginCookies: _accountApi?.readLoginCookies);
  late final BilibiliFavoritesService _service =
      widget.service ?? BilibiliFavoritesService(api: _api);
  late final _folders = BilibiliUploaderPager<BilibiliFavoriteFolder>(
    (page) => _service.fetchFolders(_account?.mid ?? 0, page: page),
    keyOf: (folder) => folder.id,
  );
  late final _videos = BilibiliUploaderPager<BilibiliFavoriteVideo>(
    _fetchVideos,
    keyOf: (video) => video.key,
  );

  BilibiliAccountInfo? _account;
  BilibiliFavoriteFolder? _folder;
  BilibiliLoginStatus _status = BilibiliLoginStatus.loggedOut;
  bool _checking = true;
  int _accountRequest = 0;
  final _selection = BilibiliFavoritesSelection();
  int _operation = 0;
  bool _importing = false;
  int? _importingFolder;
  String? _progress;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _folder = widget.folder;
    _selection.addListener(_selectionChanged);
    final cached = _accountApi?.cachedLoginState;
    if (cached?.status == BilibiliLoginStatus.loggedIn) {
      _account = cached?.account;
    }
    _accountApi?.loginChanges.addListener(_accountChanged);
    unawaited(_refresh());
  }

  BilibiliApiService? _appApi() {
    try {
      return context.read<BilibiliDownloadService>().apiService;
    } on ProviderNotFoundException {
      return null;
    }
  }

  @override
  void dispose() {
    _accountRequest++;
    _operation++;
    _selection.removeListener(_selectionChanged);
    _selection.dispose();
    _accountApi?.loginChanges.removeListener(_accountChanged);
    _folders.dispose();
    _videos.dispose();
    super.dispose();
  }

  void _accountChanged() {
    if (!mounted) return;
    // Invalidate pending reads before another account's session is used.
    _accountRequest++;
    _cancelImport();
    _selection.exit();
    _folders.reset();
    _videos.reset();
    setState(() {
      _account = null;
      _folder = null;
      _checking = true;
      _notice = null;
    });
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    if (_selection.active || _importing) return;
    final request = ++_accountRequest;
    final api = _accountApi;
    final revision = api?.loginChanges.value;
    setState(() => _checking = true);
    BilibiliLoginState state;
    try {
      if (api == null) {
        state = const BilibiliLoginState(BilibiliLoginStatus.loggedOut);
      } else {
        await api.init();
        state = await api.fetchLoginState();
      }
    } catch (_) {
      state = const BilibiliLoginState(BilibiliLoginStatus.networkError);
    }
    if (!mounted ||
        request != _accountRequest ||
        revision != api?.loginChanges.value) {
      return;
    }
    final account = state.status == BilibiliLoginStatus.loggedIn
        ? state.account
        : state.status == BilibiliLoginStatus.networkError
        ? _account
        : null;
    if (account?.mid != _account?.mid || account == null) {
      _folders.reset();
      _videos.reset();
    }
    setState(() {
      _account = account;
      _status = state.status;
      _checking = false;
      if (_folder != null && widget.ownerMid != account?.mid) _folder = null;
    });
    if (account == null) return;
    if (_folder == null) {
      await _folders.refresh();
    } else {
      await _videos.refresh();
    }
  }

  Future<BilibiliUploaderResult<BilibiliUploaderPage<BilibiliFavoriteVideo>>>
  _fetchVideos(int page) async {
    final folder = _folder;
    final account = _account;
    final request = _accountRequest;
    if (folder == null || account == null) {
      return const BilibiliUploaderResult.failure(
        BilibiliUploaderStatus.failed,
        '请先登录 B 站',
      );
    }
    final result = await _service.fetchVideos(
      account.mid,
      folder.id,
      page: page,
    );
    if (mounted && request == _accountRequest && result.isSuccess) {
      setState(() => _folder = result.data!.folder);
    }
    return result;
  }

  Future<void> _openLogin() async {
    await openBilibiliAccount(context, api: _accountApi);
    if (mounted) await _refresh();
  }

  Future<void> _openFolder(BilibiliFavoriteFolder folder) async {
    if (_importing) return;
    final account = _account;
    if (account == null) return;
    await pushAboveMediaLibrary(
      context,
      AppMaterialPageRoute<void>(
        builder: (_) => BilibiliFavoritesScreen(
          accountApi: _accountApi,
          api: _api,
          service: _service,
          folder: folder,
          ownerMid: account.mid,
          onWatch: widget.onWatch,
          onImport: widget.onImport,
          onBatchImport: widget.onBatchImport,
          onPickImportLocation: widget.onPickImportLocation,
        ),
      ),
    );
    if (mounted && _account?.mid == account.mid) await _refresh();
  }

  void _watch(BilibiliFavoriteVideo video) {
    if (_importing) return;
    if (_selection.active) {
      _selection.toggle(video);
      return;
    }
    if (!video.canPlay) return;
    unawaited(
      (widget.onWatch ?? watchBilibiliVideo)(
        context,
        bvid: video.bvid,
        preview: BilibiliWatchPreview(
          title: video.title,
          coverUrl: video.coverUrl,
        ),
      ),
    );
  }

  void _selectionChanged() {
    if (mounted) setState(() {});
  }

  void _cancelImport() {
    _operation++;
    _importing = false;
    _importingFolder = null;
    _progress = null;
  }

  void _exitSelection() {
    _cancelImport();
    _selection.exit();
  }

  Future<ImportPlacementRequest?> _pickLocation(
    ImportPlacementRequest current,
  ) async {
    if (widget.onPickImportLocation case final custom?) {
      return custom(context, current);
    }
    final pick = await showLibraryFolderPicker(
      context,
      library: context.read<LibraryService>(),
      initialFolderId: current.folderId,
      title: '导入到…',
      offerSetAsDefault: false,
      accent: AppTokens.brandBilibili,
    );
    return pick == null
        ? null
        : ImportPlacementRequest.explicit(
            ImportCardFeature.bilibiliPage,
            pick.folderId,
          );
  }

  Future<void> _import(
    BilibiliFavoriteFolder folder, {
    bool pickPlace = false,
    List<BilibiliFavoriteVideo>? selected,
  }) async {
    final account = _account;
    if (account == null ||
        _checking ||
        _importing ||
        _selection.loading ||
        selected?.isEmpty == true) {
      return;
    }
    final operation = ++_operation;
    final revision = _accountApi?.loginChanges.value;
    bool cancelled() =>
        !mounted ||
        operation != _operation ||
        _account?.mid != account.mid ||
        revision != _accountApi?.loginChanges.value;
    setState(() {
      _importing = true;
      _selection.error = null;
      _importingFolder = folder.id;
      _notice = null;
      _progress = pickPlace ? null : '正在准备导入…';
    });
    try {
      var placement = SettingsService().captureImportPlacement(
        ImportCardFeature.bilibiliPage,
      );
      if (pickPlace) {
        final picked = await _pickLocation(placement);
        if (picked == null || cancelled()) return;
        placement = picked;
      }
      if (!mounted || cancelled()) return;
      final request = BilibiliFavoritesImportRequest(
        mid: account.mid,
        folder: folder,
        placement: placement,
        selectedVideos: selected == null ? null : List.unmodifiable(selected),
      );
      void progress(String value) {
        if (!cancelled()) setState(() => _progress = value);
      }

      final custom = widget.onBatchImport;
      final result = custom != null
          ? await custom(
              context,
              request,
              isCancelled: cancelled,
              onProgress: progress,
            )
          : await importBilibiliFavorites(
              request: request,
              service: context.read<BilibiliDownloadService>(),
              library: context.read<LibraryService>(),
              favorites: _service,
              isCancelled: cancelled,
              onProgress: progress,
            );
      if (cancelled()) return;
      if (selected != null) _selection.imported(result.imported);
      setState(() => _notice = result.message);
    } on BilibiliFavoritesCancelled {
      // The account or page that cancelled the job owns the next state.
    } catch (error) {
      if (!cancelled()) {
        setState(
          () => _notice = error is BilibiliFavoritesException
              ? error.message
              : '导入失败，请检查网络和导入位置后重试',
        );
      }
    } finally {
      if (mounted && operation == _operation) {
        setState(() {
          _importing = false;
          _importingFolder = null;
          _progress = null;
        });
      }
    }
  }

  Widget _folderImportButtons(BilibiliFavoriteFolder folder) =>
      BilibiliFavoritesImportButtons(
        folderId: folder.id,
        enabled:
            !_checking &&
            !_importing &&
            !_selection.active &&
            folder.mediaCount > 0,
        busy: _importing && _importingFolder == folder.id,
        onImport: (pick) => _import(folder, pickPlace: pick),
      );

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_selection.active,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selection.active) _exitSelection();
      },
      child: BilibiliQuietTap(
        child: Scaffold(
          backgroundColor: AppTokens.bgBase,
          appBar: AppBar(
            backgroundColor: AppTokens.bgBase,
            foregroundColor: AppTokens.text1,
            elevation: 0,
            leading: _selection.active
                ? DesktopButtonClickRegion(
                    child: IconButton(
                      key: const ValueKey(
                        'bilibili-favorites-selection-cancel',
                      ),
                      tooltip: '退出多选',
                      onPressed: _exitSelection,
                      icon: const Icon(Icons.close),
                    ),
                  )
                : null,
            title: Text(
              _selection.active
                  ? '已选 ${_selection.count} 项'
                  : _folder == null
                  ? 'B 站收藏夹'
                  : '收藏夹 · ${_folder!.title}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16),
            ),
            actions: [
              if (_selection.active)
                DesktopButtonClickRegion(
                  child: IconButton(
                    key: const ValueKey('bilibili-favorites-select-all'),
                    tooltip: _selection.allSelected ? '取消全选' : '全选整个收藏夹',
                    onPressed: _selection.loading || _importing
                        ? null
                        : () => unawaited(
                            _selection.selectAll(
                              _service,
                              _account!.mid,
                              _folder!.id,
                            ),
                          ),
                    icon: Icon(
                      _selection.allSelected
                          ? Icons.deselect
                          : Icons.select_all,
                    ),
                  ),
                )
              else ...[
                if (_folder != null && _account != null)
                  DesktopButtonClickRegion(
                    child: IconButton(
                      key: const ValueKey('bilibili-favorites-select'),
                      tooltip: '多选',
                      onPressed: _checking || _importing
                          ? null
                          : _selection.enter,
                      icon: const Icon(Icons.checklist),
                    ),
                  ),
                ListenableBuilder(
                  listenable: Listenable.merge([_folders, _videos]),
                  builder: (context, _) => DesktopButtonClickRegion(
                    child: IconButton(
                      key: const ValueKey('bilibili-favorites-refresh'),
                      tooltip: '刷新收藏夹',
                      onPressed:
                          _checking ||
                              _importing ||
                              _folders.loading ||
                              _videos.loading
                          ? null
                          : _refresh,
                      icon: const Icon(
                        Icons.refresh,
                        size: 22,
                        color: AppTokens.text2,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          body: SafeArea(
            top: false,
            child: Column(
              children: [
                if (_folder != null && _account != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${_folder!.mediaCount} 个内容',
                            style: const TextStyle(
                              color: AppTokens.text3,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        Visibility(
                          visible: !_selection.active,
                          maintainState: true,
                          maintainAnimation: true,
                          maintainSize: true,
                          child: _folderImportButtons(_folder!),
                        ),
                      ],
                    ),
                  ),
                if (_selection.loading ||
                    _selection.error != null ||
                    _progress != null ||
                    _notice != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _selection.loading
                                ? '正在读取全部收藏 ${_selection.loaded}/${_selection.total}'
                                : _selection.error ?? _progress ?? _notice!,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppTokens.text2,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        if (_selection.loading)
                          TextButton(
                            onPressed: _exitSelection,
                            child: const Text('取消'),
                          ),
                      ],
                    ),
                  ),
                Expanded(
                  child: ListenableBuilder(
                    listenable: Listenable.merge([_folders, _videos]),
                    builder: (context, _) => _buildBody(),
                  ),
                ),
              ],
            ),
          ),
          bottomNavigationBar: MediaLibrarySelectionBarTransition(
            child: !_selection.active
                ? null
                : MediaLibrarySelectionBottomBar.custom(
                    showAddToQueue: false,
                    onAddToQueue: null,
                    actions: [
                      MediaLibrarySelectionBarAction(
                        label: '导入默认位置',
                        compactLabel: '导入',
                        icon: Icons.playlist_add,
                        color: AppTokens.brandBilibili,
                        onPressed:
                            _selection.count == 0 ||
                                _selection.loading ||
                                _importing
                            ? null
                            : () => unawaited(
                                _import(_folder!, selected: _selection.videos),
                              ),
                      ),
                      MediaLibrarySelectionBarAction(
                        label: '选择导入位置',
                        compactLabel: '选择位置',
                        icon: Icons.drive_folder_upload_outlined,
                        color: AppTokens.brandBilibili,
                        onPressed:
                            _selection.count == 0 ||
                                _selection.loading ||
                                _importing
                            ? null
                            : () => unawaited(
                                _import(
                                  _folder!,
                                  pickPlace: true,
                                  selected: _selection.videos,
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

  Widget _buildBody() {
    final failure = _folder == null ? _folders.failure : _videos.failure;
    if (_account == null) {
      return BilibiliLoadTransition(
        loading: _checking,
        stateKey: _status,
        placeholder: BilibiliListSkeleton(
          kind: _folder == null
              ? BilibiliSkeletonKind.collection
              : BilibiliSkeletonKind.video,
        ),
        child: _checking ? const SizedBox.shrink() : _accountHint(),
      );
    }
    if (failure?.code == -101) return _accountHint(expired: true);
    return RefreshIndicator(
      color: AppTokens.brandBilibili,
      onRefresh: _refresh,
      notificationPredicate: (notification) =>
          !_selection.active &&
          !_importing &&
          notification.depth == 0 &&
          notification.metrics.axis == Axis.vertical,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          physics: AlwaysScrollableScrollPhysics(
            parent: ScrollConfiguration.of(context).getScrollPhysics(context),
          ),
        ),
        child: _folder == null
            ? BilibiliUploaderPagedList<BilibiliFavoriteFolder>(
                key: ValueKey('bilibili-favorite-folders-${_account!.mid}'),
                pager: _folders,
                skeletonKind: BilibiliSkeletonKind.collection,
                emptyText: '还没有 B 站收藏夹',
                itemKey: (folder) => folder.id,
                itemBuilder: (folder) => BilibiliVideoListTile(
                  key: ValueKey('bilibili-favorite-folder-${folder.id}'),
                  title: folder.title,
                  coverUrl: folder.coverUrl,
                  metadata: [
                    Text(
                      '${folder.mediaCount} 个内容 · ${folder.isPublic ? '公开' : '私密'}',
                      style: const TextStyle(
                        color: AppTokens.text3,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  actions: _folderImportButtons(folder),
                  onTap: () => unawaited(_openFolder(folder)),
                ),
              )
            : BilibiliUploaderPagedList<BilibiliFavoriteVideo>(
                key: ValueKey(
                  'bilibili-favorite-videos-${_account!.mid}-${_folder!.id}',
                ),
                pager: _videos,
                emptyText: '这个收藏夹还没有内容',
                itemKey: (video) => video.key,
                itemBuilder: _videoTile,
              ),
      ),
    );
  }

  Widget _accountHint({bool expired = false}) {
    final networkError =
        !expired && _status == BilibiliLoginStatus.networkError;
    return BilibiliUploaderStateHint(
      icon: networkError ? Icons.cloud_off_outlined : Icons.lock_outline,
      title: networkError
          ? '暂时无法验证 B 站登录，请检查网络后重试'
          : expired || _status == BilibiliLoginStatus.expired
          ? 'B 站登录已失效，请重新登录'
          : '登录后查看自己的 B 站收藏夹',
      action: DesktopButtonClickRegion(
        child: TextButton(
          key: const ValueKey('bilibili-favorites-login'),
          onPressed: networkError ? _refresh : _openLogin,
          child: Text(networkError ? '重试' : '登录 B 站'),
        ),
      ),
    );
  }

  Widget _videoTile(BilibiliFavoriteVideo video) => BilibiliVideoListTile(
    key: ValueKey('bilibili-favorite-video-${video.key}'),
    title: video.title,
    coverUrl: video.coverUrl,
    duration: video.durationSeconds > 0
        ? formatBilibiliDuration(video.durationSeconds)
        : null,
    metadata: [
      Text(
        video.ownerName.isEmpty ? '未知 UP 主' : video.ownerName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: AppTokens.text2, fontSize: 12),
      ),
      if (video.favoredAt case final date?)
        Text(
          '收藏于 ${formatBilibiliDate(date)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: AppTokens.text3, fontSize: 11),
        ),
    ],
    actions: Visibility(
      visible: !_selection.active,
      maintainState: true,
      maintainAnimation: true,
      maintainSize: true,
      child: video.canPlay
          ? BilibiliImportButtons(bvid: video.bvid, onImport: widget.onImport)
          : Tooltip(
              message: video.unavailableLabel,
              child: Text(
                video.type == 2 ? '不可播放' : '非视频',
                style: const TextStyle(color: AppTokens.text3, fontSize: 11),
              ),
            ),
    ),
    onTap: () => _watch(video),
    onLongPress: !video.canPlay || _importing || _selection.loading
        ? null
        : () => _selection.enter(video),
    selectionMode: _selection.active,
    selectionEnabled: video.canPlay && !_importing && !_selection.loading,
    selected: _selection.contains(video),
  );
}
