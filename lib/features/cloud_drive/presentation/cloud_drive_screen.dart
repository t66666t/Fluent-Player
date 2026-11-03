import '../../../utils/keyboard_shortcut_hints.dart';
import 'dart:async';
import '../../../widgets/add_to_playlist_button.dart';
import '../../../widgets/playback_queue_add_actions.dart';
import '../../../widgets/transcription_queue_actions.dart';
import '../../../services/app_default_settings_trial.dart';
import '../../media_cache/media_cache_actions.dart';
import '../../media_cache/media_cache_selection.dart';
import '../../media_cache/media_cache_widgets.dart';
import '../../media_cache/media_cache_service.dart';
import '../../media_cache/media_cache_models.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../theme/app_page_transitions.dart';
import '../../../theme/app_tokens.dart';
import '../../../models/video_collection.dart';
import '../../../models/import_card_placement.dart';
import '../../../models/video_item.dart';
import '../../../services/library_service.dart';
import '../../../services/media_playback_service.dart';
import '../../../services/playback_queue_add_service.dart';
import '../../../services/settings_service.dart';
import '../../../utils/app_toast.dart';
import '../../../utils/media_library_range_selection.dart';
import '../../../widgets/library_folder_picker.dart';
import '../../../widgets/cached_thumbnail_widget.dart';
import '../../../widgets/media_library_browse_grid_cards.dart';
import '../../../widgets/media_library_list_tile.dart';
import '../../../widgets/playback_source_viewport.dart';
import '../../../widgets/media_library_layout_profile.dart';
import '../../../widgets/media_library_scroll_viewport.dart';
import '../../../widgets/media_list_layout_metrics.dart';
import '../../../widgets/media_library_page_shortcuts.dart';
import '../../../widgets/media_library_safe_area.dart';
import '../../../widgets/media_library_selection_bottom_bar.dart';
import '../../../widgets/media_library_tooltip.dart';
import '../../../widgets/media_library_style_sheet.dart';
import '../../../widgets/media_library_folder_breadcrumb.dart';
import '../models/cloud_drive_models.dart';
import '../models/cloud_drive_view_options.dart';
import '../providers/cloud_drive_provider.dart';
import '../services/cloud_drive_account_repository.dart';
import '../services/cloud_drive_directory_session.dart';
import '../services/cloud_drive_reference_import.dart';
import '../services/cloud_drive_runtime.dart';
import '../services/cloud_drive_startup.dart';
import '../services/cloud_drive_initialization_error.dart';
import '../services/cloud_drive_view_preferences.dart';
import 'cloud_drive_login_screen.dart';
import 'cloud_drive_navigation.dart';
import 'cloud_drive_entry_reveal.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

part 'cloud_drive_browser_pane.dart';

class CloudDriveRoute extends MaterialPageRoute<void> {
  CloudDriveRoute({String? targetFolderId})
    : super(
        settings: const RouteSettings(name: '/cloud_drive'),
        builder: (_) => CloudDriveScreen(targetFolderId: targetFolderId),
      );
}

/// Official web login. The page stays in the live exit zoom.
///
/// Snapshotting this route reads the WebView texture back off the GPU, then
/// paints a still that does not contain that texture. The page fades with the
/// still while the live browser stays put and cuts away after the zoom.
class CloudDriveLoginRoute extends AppMaterialPageRoute<CloudDriveAccount> {
  CloudDriveLoginRoute({
    required CloudDriveProvider provider,
    required CloudDriveAccountRepository accounts,
  }) : super(
         builder: (_) =>
             CloudDriveLoginScreen(provider: provider, accounts: accounts),
         settings: RouteSettings(name: '/cloud_drive/login/${provider.id}'),
         allowSnapshotting: false,
       );
}

class CloudDriveScreen extends StatefulWidget {
  const CloudDriveScreen({
    super.key,
    this.targetFolderId,
    this.initialAccount,
    this.initialProviderId,
    this.popOnSearchBack = false,
    this.initialDirectoryId,
    this.initialQuery,
    this.runtime,
    this.embedded = false,
    this.isActive = true,
    this.onSelectionChanged,
  });
  final String? targetFolderId;
  final CloudDriveAccount? initialAccount;

  /// A home search chooses a provider, then restores its selected signed-in
  /// account once local account metadata has finished loading.
  final String? initialProviderId;
  final bool popOnSearchBack;
  final String? initialDirectoryId, initialQuery;
  final CloudDriveRuntime? runtime;
  final bool embedded;
  final bool isActive;
  final ValueChanged<bool>? onSelectionChanged;
  @override
  State<CloudDriveScreen> createState() => _CloudDriveScreenState();
}

class _CloudDriveScreenState extends State<CloudDriveScreen> {
  CloudDriveRuntime? _runtime;
  CloudDriveViewPreferences? _preferences;
  String _providerId = 'baidu';
  final _accounts = <String, String>{};
  final _options = <String, CloudDriveViewOptions>{};
  String? _error;
  bool _initializing = false;
  final _providerTabKeys = <String, GlobalKey>{};
  List<String> get _providerIds =>
      _runtime?.providers.all.map((p) => p.id).toList() ??
      cloudDriveProviderNames.keys.toList();
  String _providerName(String id) =>
      _runtime?.providers[id]?.displayName ?? cloudDriveProviderNames[id] ?? id;

  @override
  void initState() {
    super.initState();
    _providerId =
        widget.initialAccount?.providerId ??
        widget.initialProviderId ??
        'baidu';
    DefaultTrialRuntime.revision.addListener(_trialPreferencesChanged);
    unawaited(_init());
  }

  void _trialPreferencesChanged() {
    if (!mounted || _preferences == null) return;
    _providerId = _preferences!.providerId;
    _changed();
    _revealProviderTab();
  }

  Future<void> _init() async {
    if (_initializing) return;
    _initializing = true;
    if (mounted) setState(() => _error = null);
    try {
      final preferences = CloudDriveViewPreferences(
        await SharedPreferences.getInstance(),
      );
      final CloudDriveRuntime runtime =
          widget.runtime ??
          await waitForCloudDriveInitialization<CloudDriveRuntime>(
            CloudDriveRuntime.ensureInstalled(),
          );
      if (!mounted) return;
      _runtime = runtime;
      _preferences = preferences;
      final requestedProvider =
          widget.initialProviderId ?? preferences.providerId;
      _providerId = _providerIds.contains(requestedProvider)
          ? requestedProvider
          : 'baidu';
      for (final id in _providerIds) {
        _options[id] = preferences.options(id);
        final saved = preferences.accountId(id);
        final available = runtime.accounts.accounts.where(
          (a) => a.providerId == id,
        );
        final preferred = id == widget.initialProviderId
            ? available.where(
                (a) => a.authState != CloudDriveAuthState.needsLogin,
              )
            : available;
        final selected =
            preferred.where((a) => a.localId == saved).firstOrNull ??
            preferred.firstOrNull ??
            available.firstOrNull;
        if (selected != null) _accounts[id] = selected.localId;
      }
      final initial = widget.initialAccount;
      if (initial != null) {
        _providerId = initial.providerId;
        _accounts[initial.providerId] = initial.localId;
      }
      runtime.accounts.sessionChanges.addListener(_changed);
      setState(() {});
      _revealProviderTab();
    } catch (error, stack) {
      debugPrint(
        'Cloud drive startup failed: ${redactCloudDriveLog('$error')}',
      );
      debugPrintStack(stackTrace: stack);
      _runtime?.accounts.sessionChanges.removeListener(_changed);
      _runtime = null;
      _preferences = null;
      _accounts.clear();
      _options.clear();
      if (mounted) {
        setState(() => _error = cloudDriveInitializationMessage(error));
      }
    } finally {
      _initializing = false;
    }
  }

  void _changed() {
    if (mounted) {
      setState(() {
        for (final id in _providerIds) {
          _options[id] = _preferences!.options(id);
        }
      });
    }
  }

  void _revealProviderTab() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _providerTabKeys[_providerId]?.currentContext;
      if (mounted && context != null) {
        unawaited(
          Scrollable.ensureVisible(
            context,
            alignment: 0.5,
            duration: const Duration(milliseconds: 150),
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    DefaultTrialRuntime.revision.removeListener(_trialPreferencesChanged);
    _runtime?.accounts.sessionChanges.removeListener(_changed);
    super.dispose();
  }

  CloudDriveAccount? _account(String provider) => _runtime?.accounts.accounts
      .where(
        (a) => a.providerId == provider && a.localId == _accounts[provider],
      )
      .firstOrNull;

  void _selectAccount(CloudDriveAccount account) {
    setState(() => _accounts[account.providerId] = account.localId);
    unawaited(_preferences!.selectAccount(account.providerId, account.localId));
  }

  Future<void> _login(String providerId) async {
    final runtime = _runtime;
    final provider = runtime?.providers[providerId];
    if (runtime == null || provider == null) return;
    final account = await Navigator.of(context).push<CloudDriveAccount>(
      CloudDriveLoginRoute(provider: provider, accounts: runtime.accounts),
    );
    if (account != null && mounted) _selectAccount(account);
  }

  Future<void> _accountAction(CloudDriveAccount account, String action) async {
    final runtime = _runtime!;
    if (action == 'relogin') {
      await _login(account.providerId);
      return;
    }
    final removing = action == 'remove';
    final playing = runtime.launch.playback.isCloudDriveAccountActive(
      account.localId,
    );
    if (removing || playing) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(removing ? '移除网盘账号' : '退出网盘账号'),
          content: Text(
            removing
                ? '将从本机移除“${account.displayName}”及其登录信息，网盘文件和观看记录会保留。'
                      '${playing ? '\n\n同时会停止该账号正在播放的视频。' : ''}'
                : '退出将停止该账号正在播放的视频',
          ),
          actions: [
            DesktopButtonClickRegion(child: TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            )),
            DesktopButtonClickRegion(child: TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(removing ? '移除' : '退出'),
            )),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    if (playing) await runtime.launch.playback.stop();
    await runtime.playback.releaseAccount(account.localId);
    if (removing) {
      await runtime.accounts.remove(account.localId);
    } else {
      await runtime.accounts.signOut(account.localId);
    }
    if (!mounted) return;
    if (removing && _accounts[account.providerId] == account.localId) {
      final next = runtime.accounts.accounts
          .where((a) => a.providerId == account.providerId)
          .firstOrNull;
      setState(() {
        _accounts.remove(account.providerId);
      });
      if (next != null) {
        _selectAccount(next);
      } else {
        await _preferences!.selectAccount(account.providerId, null);
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _settings() async {
    if (_preferences == null) return;
    final provider = _providerId;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _CloudDriveSettingsPage(
          preferences: _preferences!,
          providerId: provider,
          accounts: _runtime!.accounts,
          onAccountAction: _accountAction,
          onAddAccount: () => _login(provider),
          onChanged: _changed,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Widget _providerTab(String id, String label, double width) => SizedBox(
    key: _providerTabKeys.putIfAbsent(id, () => GlobalKey()),
    width: width,
    child: Semantics(
      selected: _providerId == id,
      button: true,
      child: InkWell(
        key: ValueKey('cloud-drive-tab-$id'),
        onTap: () {
          setState(() => _providerId = id);
          unawaited(_preferences?.selectProvider(id));
          _revealProviderTab();
        },
        borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: _providerId == id ? AppTokens.bgRaised : Colors.transparent,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: _providerId == id ? AppTokens.text1 : AppTokens.text3,
            ),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final runtime = _runtime;
    final account = _account(_providerId);
    final surface = ColoredBox(
      color: AppTokens.bgBase,
      child: SafeArea(
        // The library toolbar already consumes the system status bar. Its
        // embedded pages can still inherit the window's original top padding.
        top: !widget.embedded,
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) => Column(
            children: [
              SizedBox(
                height: math.min(
                  constraints.maxHeight,
                  math.max(44, MediaQuery.textScalerOf(context).scale(14) + 20),
                ),
                child: Row(
                  children: [
                    const SizedBox(width: 8),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (final id in _providerIds)
                              _providerTab(
                                id,
                                _providerName(id),
                                math.max(
                                  104,
                                  math.min(
                                    168,
                                    (constraints.maxWidth - 104) /
                                        _providerIds.length,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    if (constraints.maxWidth >= 600 && account != null)
                      SizedBox(
                        width: 120,
                        child: Text(
                          account.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            color: AppTokens.text2,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    if (runtime != null)
                      CapsulePopupMenuButton<String>(
                        key: const ValueKey('cloud-drive-account-menu'),
                        useRootNavigator: true,
                        tooltip: '账号管理',
                        icon: const Icon(
                          Icons.account_circle_outlined,
                          size: 20,
                        ),
                        onSelected: (value) {
                          if (value == 'add') {
                            unawaited(_login(_providerId));
                          } else if (value == 'remove') {
                            if (account != null) {
                              unawaited(_accountAction(account, 'remove'));
                            }
                          } else {
                            _selectAccount(runtime.accounts.findLocal(value)!);
                          }
                        },
                        itemBuilder: (_) => [
                          for (final a in runtime.accounts.accounts.where(
                            (a) => a.providerId == _providerId,
                          ))
                            PopupMenuItem(
                              value: a.localId,
                              child: Row(
                                children: [
                                  Icon(
                                    a.localId == account?.localId
                                        ? Icons.check
                                        : Icons.person_outline,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(child: Text(a.displayName)),
                                ],
                              ),
                            ),
                          const PopupMenuItem(
                            value: 'add',
                            child: Text('添加账号'),
                          ),
                          if (account != null)
                            const PopupMenuItem(
                              value: 'remove',
                              child: Text('移除当前账号'),
                            ),
                        ],
                      ),
                    DesktopButtonClickRegion(child: IconButton(
                      tooltip: shortcutHintLabel(context, '网盘设置', 'P'),
                      onPressed: runtime == null ? null : _settings,
                      icon: const Icon(Icons.tune_rounded, size: 20),
                    )),
                  ],
                ),
              ),
              Expanded(
                child: runtime == null
                    ? MediaLibrarySafeArea(
                        child: Center(
                          child: _error == null
                              ? const Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    CircularProgressIndicator(),
                                    SizedBox(height: 12),
                                    Text('正在读取本机网盘账号…'),
                                  ],
                                )
                              : DesktopButtonClickRegion(child: TextButton(
                                  onPressed: _init,
                                  child: Text(_error!),
                                )),
                        ),
                      )
                    : IndexedStack(
                        index: math.max(0, _providerIds.indexOf(_providerId)),
                        children: [
                          for (final id in _providerIds) _providerContent(id),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
    Widget result = surface;
    if (runtime != null) {
      result = MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(
            value: SettingsService(),
          ),
          ChangeNotifierProvider<MediaPlaybackService>.value(
            value: runtime.launch.playback,
          ),
          ChangeNotifierProvider<LibraryService>.value(
            value: runtime.launch.library,
          ),
        ],
        child: surface,
      );
    }
    if (runtime == null && !widget.embedded) {
      result = MediaLibraryPageShortcuts(child: result);
    }
    return widget.embedded
        ? result
        : Scaffold(
            appBar: AppBar(title: const Text('网盘')),
            body: result,
          );
  }

  Widget _providerContent(String id) {
    final account = _account(id);
    final active = widget.isActive && _providerId == id;
    if (account == null ||
        account.authState == CloudDriveAuthState.needsLogin) {
      return MediaLibraryPageShortcuts(
        enabled: active,
        bindings: {LogicalKeyboardKey.keyP: _settings},
        child: MediaLibrarySafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.cloud_outlined,
                    size: 48,
                    color: AppTokens.text4,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    account == null ? '添加网盘账号' : '登录已过期',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    account == null ? '登录后浏览文件，选择媒体开始学习' : '重新登录后继续访问原来的文件',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppTokens.text2),
                  ),
                  const SizedBox(height: 20),
                  DesktopButtonClickRegion(child: FilledButton.tonalIcon(
                    onPressed: () => _login(id),
                    icon: const Icon(Icons.login, size: 18),
                    label: Text('登录${_providerName(id)}'),
                  )),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return _CloudDriveBrowserPane(
      key: ValueKey(account.localId),
      runtime: _runtime!,
      account: account,
      initialDirectoryId: widget.initialAccount?.localId == account.localId
          ? widget.initialDirectoryId
          : null,
      initialQuery:
          (widget.initialAccount?.localId == account.localId ||
              (widget.initialAccount == null && widget.initialProviderId == id))
          ? widget.initialQuery
          : null,
      popOnSearchBack: widget.popOnSearchBack,
      options: _options[id] ?? const CloudDriveViewOptions(),
      isActive: active,
      targetFolderId: widget.targetFolderId,
      onOptions: (options) {
        setState(() => _options[id] = options);
        unawaited(_preferences!.save(id, options));
      },
      onSettings: _settings,
      onSelectionChanged: widget.onSelectionChanged,
    );
  }
}

class _CloudDriveSettingsPage extends StatefulWidget {
  const _CloudDriveSettingsPage({
    required this.preferences,
    required this.providerId,
    required this.accounts,
    required this.onAccountAction,
    required this.onAddAccount,
    required this.onChanged,
  });
  final CloudDriveViewPreferences preferences;
  final String providerId;
  final CloudDriveAccountRepository accounts;
  final Future<void> Function(CloudDriveAccount, String) onAccountAction;
  final Future<void> Function() onAddAccount;
  final VoidCallback onChanged;
  @override
  State<_CloudDriveSettingsPage> createState() =>
      _CloudDriveSettingsPageState();
}

class _CloudDriveSettingsPageState extends State<_CloudDriveSettingsPage> {
  @override
  void initState() {
    super.initState();
    DefaultTrialRuntime.revision.addListener(_trialPreferencesChanged);
  }

  void _trialPreferencesChanged() {
    if (mounted) {
      setState(() => _options = widget.preferences.options(widget.providerId));
    }
  }

  @override
  void dispose() {
    DefaultTrialRuntime.revision.removeListener(_trialPreferencesChanged);
    super.dispose();
  }

  late CloudDriveViewOptions _options = widget.preferences.options(
    widget.providerId,
  );
  Future<void> _save(CloudDriveViewOptions options) async {
    setState(() => _options = options);
    await widget.preferences.save(widget.providerId, options);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) => MediaLibraryPageShortcuts(
    child: Scaffold(
      backgroundColor: AppTokens.bgBase,
      appBar: AppBar(title: const Text('网盘设置')),
      body: MediaLibrarySafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              cloudDriveProviderNames[widget.providerId] ?? widget.providerId,
              style: const TextStyle(color: AppTokens.text2),
            ),
            ListTile(
              title: const Text('排序方式'),
              trailing: CapsuleDropdownButton<CloudDriveViewSort>(
                value: _options.sort,
                onChanged: (v) => _save(_options.copyWith(sort: v)),
                items: [
                  for (final sort in CloudDriveViewSort.values)
                    DropdownMenuItem(value: sort, child: Text(sort.label)),
                ],
              ),
            ),
            SwitchListTile(
              title: const Text('降序排列'),
              value: _options.descending,
              onChanged: (v) => _save(_options.copyWith(descending: v)),
            ),
            SwitchListTile(
              title: const Text('文件夹优先'),
              value: _options.foldersFirst,
              onChanged: (v) => _save(_options.copyWith(foldersFirst: v)),
            ),
            ListTile(
              title: const Text('文件筛选'),
              trailing: CapsuleDropdownButton<CloudDriveViewFilter>(
                value: _options.filter,
                onChanged: (v) => _save(_options.copyWith(filter: v)),
                items: [
                  for (final filter in CloudDriveViewFilter.values)
                    DropdownMenuItem(value: filter, child: Text(filter.label)),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.dashboard_customize_outlined),
              title: const Text('调整卡片与列表样式'),
              subtitle: const Text('与文件夹页面共用设置'),
              onTap: () => MediaLibraryStyleSheet.show(
                context: context,
                scope: MediaLibraryCardStyleScope.collection,
              ),
            ),
            const Divider(height: 32),
            for (final account in widget.accounts.accounts.where(
              (a) => a.providerId == widget.providerId,
            ))
              ListTile(
                leading: const Icon(Icons.account_circle_outlined),
                title: Text(account.displayName),
                subtitle: Text(switch (account.authState) {
                  CloudDriveAuthState.signedIn => '已登录',
                  CloudDriveAuthState.needsLogin => '需要重新登录',
                  CloudDriveAuthState.temporarySession => '本次临时会话',
                }),
                trailing: CapsulePopupMenuButton<String>(
                  useRootNavigator: true,
                  tooltip: '账号管理',
                  onSelected: (action) async {
                    await widget.onAccountAction(account, action);
                    if (mounted) setState(() {});
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'relogin', child: Text('重新登录')),
                    PopupMenuItem(value: 'signout', child: Text('退出账号')),
                    PopupMenuItem(value: 'remove', child: Text('从本机移除')),
                  ],
                ),
              ),
            ListTile(
              leading: const Icon(Icons.person_add_outlined),
              title: const Text('添加账号'),
              onTap: () async {
                await widget.onAddAccount();
                if (mounted) setState(() {});
              },
            ),
          ],
        ),
      ),
    ),
  );
}
