import '../../utils/page_shortcut_keys.dart';
import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../widgets/media_library_page_shortcuts.dart';

import '../../theme/app_tokens.dart';
import '../../theme/app_page_transitions.dart';
import '../../utils/route_transition_work.dart';
import 'folder_transfer_widgets.dart';
import 'folder_sync_models.dart';
import 'folder_sync_settings_sheet.dart';
import 'folder_sync_conflict_sheet.dart';
import 'progress_sync_components.dart';
import 'progress_sync_models.dart';
import 'progress_sync_service.dart';
import 'progress_sync_webdav.dart';
import 'sync_folder_picker.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';
import '../portable_transfer/portable_export_cache_dialog.dart';
import '../portable_transfer/portable_export_readiness.dart';
import '../media_cache/media_cache_models.dart';
import '../media_cache/media_cache_actions.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

Future<void> openProgressSync(
  BuildContext context,
  ProgressSyncService service, {
  String? collectionId,
  bool sendFolder = false,
}) => Navigator.of(context, rootNavigator: true).push<void>(
  AppMaterialPageRoute(
    builder: (_) => ProgressSyncScreen(
      service: service,
      initialCollectionId: collectionId,
      sendFolder: sendFolder,
    ),
  ),
);

class ProgressSyncScreen extends StatefulWidget {
  static int _openDepth = 0;
  static bool get isOpen => _openDepth > 0;
  const ProgressSyncScreen({
    super.key,
    required this.service,
    this.initialCollectionId,
    this.sendFolder = false,
  });

  final ProgressSyncService service;
  final String? initialCollectionId;
  final bool sendFolder;

  @override
  State<ProgressSyncScreen> createState() => _ProgressSyncScreenState();
}

class _ProgressSyncScreenState extends State<ProgressSyncScreen> {
  ProgressSyncService get _service => widget.service;
  final _storageForm = GlobalKey<FormState>();
  final _url = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _scroll = ScrollController();
  final _routeWork = RouteTransitionWork();
  bool _storageExpanded = false;
  bool _showPassword = false;
  bool _working = false;
  bool _storageFilled = false;
  bool _sendPickerOpen = false;
  bool _resumeSendQueued = false;
  String? _pendingSendCollectionId;

  bool get _busy => _working || _service.busy;
  bool get _canKeepStoredPassword {
    final stored = _service.webDavConfig;
    if (stored == null || stored.username != _username.text.trim()) {
      return false;
    }
    final previous = Uri.tryParse(stored.url);
    final current = Uri.tryParse(_url.text.trim());
    return previous != null &&
        current != null &&
        previous.scheme == current.scheme &&
        previous.host == current.host &&
        previous.port == current.port;
  }

  @override
  void initState() {
    super.initState();
    ProgressSyncScreen._openDepth++;
    _service.addListener(_changed);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    await _run(() async {
      await _service.init();
      if (mounted) _fillStorage();
    });
    final collectionId = widget.initialCollectionId;
    if (mounted && _service.initialized && collectionId != null) {
      _routeWork.schedule('initial-send', () {
        if (mounted) {
          unawaited(_sendFolder(initialId: collectionId));
        }
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeWork.bind(ModalRoute.of(context));
  }

  void _fillStorage() {
    if (_storageFilled) return;
    _storageFilled = true;
    final config = _service.webDavConfig;
    _url.text = config?.url ?? '';
    _username.text = config?.username ?? '';
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    _resumePendingSend();
  }

  void _resumePendingSend() {
    if (_pendingSendCollectionId != null &&
        !_working &&
        !_sendPickerOpen &&
        !_resumeSendQueued &&
        _service.pairedDevices.isNotEmpty) {
      _resumeSendQueued = true;
      _routeWork.schedule('resume-send', () {
        _resumeSendQueued = false;
        if (mounted && ModalRoute.of(context)?.isCurrent == true) {
          unawaited(_sendFolder(initialId: _pendingSendCollectionId));
        }
      });
    }
  }

  @override
  void dispose() {
    _routeWork.dispose();
    ProgressSyncScreen._openDepth--;
    _service.removeListener(_changed);
    _scroll.dispose();
    for (final controller in [_url, _username, _password]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _run(Future<void> Function() action, {String? success}) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await action();
      if (success != null && mounted) _notice(success);
    } catch (error) {
      final detail = error is FormatException ? error.message.trim() : '';
      _notice(
        RegExp(r'^[\u3400-\u9FFF]').hasMatch(detail) && detail.length < 160
            ? detail
            : (_service.error ?? '未能完成，请检查连接后重试'),
      );
    } finally {
      if (mounted) {
        setState(() => _working = false);
        _resumePendingSend();
      }
    }
  }

  Future<String?> _pickFolder({
    String title = '选择本机文件夹',
    String description = '包含子文件夹，新增内容和观看进度会持续同步。',
  }) => showSyncFolderPicker(
    context,
    library: _service.library,
    title: title,
    description: description,
  );

  Future<void> _addFolder({String? initialId}) =>
      _sendFolder(initialId: initialId);

  Future<void> _sendFolder({String? initialId}) async {
    if (_working || _sendPickerOpen) return;
    _routeWork.cancel('initial-send');
    _routeWork.cancel('resume-send');
    _resumeSendQueued = false;
    if (!_service.enabled) {
      await _run(() => _service.setEnabled(true));
      if (!mounted || !_service.enabled) return;
    }
    final id =
        initialId ??
        await _pickFolder(
          title: '选择要发送的文件夹',
          description: '包含子文件夹，接收后内容与观看进度持续同步。',
        );
    if (id == null || !mounted) return;
    try {
      final missing = await uncachedCloudExportItems(_service.library, [id]);
      if (!mounted) return;
      if (missing.isNotEmpty) {
        final ready = await showDialog<bool>(
          context: context,
          builder: (_) => PortableExportCacheDialog(
            library: _service.library,
            rootIds: [id],
            missing: missing,
            forSync: true,
          ),
        );
        if (!mounted || ready != true) return;
      }
    } catch (_) {
      _notice('无法检查网盘缓存，请检查本地存储后重试');
      return;
    }
    _pendingSendCollectionId = null;
    _sendPickerOpen = true;
    final folder = _service.localFolders
        .where((folder) => folder.id == id)
        .firstOrNull;
    final peerId = await showSyncSheet<String>(
      context: context,
      title: '同步到设备',
      child: Builder(
        builder: (sheetContext) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              folder == null
                  ? '选择接收设备。'
                  : '「${folder.name}」· ${folder.mediaCount} 个媒体文件',
              style: const TextStyle(color: AppTokens.text2, height: 1.5),
            ),
            const SizedBox(height: 16),
            if (_service.pairedDevices.isEmpty) ...[
              const SyncEmpty(
                icon: Icons.devices_outlined,
                title: '先连接另一台设备',
                description: '两台设备连接同一 Wi-Fi，打开此页并确认配对。',
              ),
              DesktopButtonClickRegion(
                child: FilledButton(
                  onPressed: () =>
                      Navigator.pop(sheetContext, '__connect_nearby__'),
                  child: const Text('连接附近设备'),
                ),
              ),
            ],
            for (final peer in _service.pairedDevices.entries)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.phonelink_outlined),
                title: Text(peer.value),
                subtitle: Text(
                  _service.lan?.nearbyDevices.any(
                            (device) => device.id == peer.key,
                          ) ==
                          true
                      ? '对方确认接收后开始传输'
                      : '等待设备上线后发送',
                  style: const TextStyle(fontSize: 12, color: AppTokens.text2),
                ),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => Navigator.pop(sheetContext, peer.key),
              ),
            const SizedBox(height: 6),
            DesktopButtonClickRegion(
              child: TextButton(
                onPressed: () => Navigator.pop(sheetContext),
                child: const Text('取消'),
              ),
            ),
          ],
        ),
      ),
    );
    _sendPickerOpen = false;
    if (!mounted) return;
    if (peerId == '__connect_nearby__') {
      _pendingSendCollectionId = id;
      unawaited(_run(_service.discover));
      if (_scroll.hasClients) {
        unawaited(
          _scroll.animateTo(
            0,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
          ),
        );
      }
    } else if (peerId != null) {
      await _run(
        () => _service.proposeFolderSync(peerId, id),
        success: '已创建发送任务，请在另一台设备接收',
      );
    }
  }

  Future<void> _acceptInvitation(SyncFolderInvitation invitation) async {
    final id = await _pickFolder(title: '关联「${invitation.name}」');
    if (id == null || !mounted) return;
    await _run(
      () => _service.acceptInvitation(invitation.groupId, id),
      success: '文件夹已关联，正在核对进度',
    );
  }

  Future<void> _resolve(SyncProgressConflict conflict) async {
    final eventId = await showSyncSheet<String>(
      context: context,
      title: '选择要保留的进度',
      child: Builder(
        builder: (sheetContext) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              conflict.title,
              style: const TextStyle(color: AppTokens.text1),
            ),
            const SizedBox(height: 6),
            const Text(
              '两端都产生了新记录。选择一次，其他设备会跟随。',
              style: TextStyle(
                color: AppTokens.text2,
                fontSize: 12,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 16),
            for (final event in conflict.choices)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.play_circle_outline),
                title: Text(event.deviceName),
                subtitle: Text(
                  '${event.value.completed ? '已看完' : _position(event.value.positionMs)} · ${_date(DateTime.fromMillisecondsSinceEpoch(event.createdAtMs))}',
                ),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => Navigator.pop(sheetContext, event.id),
              ),
          ],
        ),
      ),
    );
    if (eventId != null && mounted) {
      await _run(() => _service.resolveConflict(conflict.id, eventId));
    }
  }

  Future<void> _renameDevice() async {
    final name = await _textInput(
      title: '设备名称',
      label: '名称',
      value: _service.deviceName,
      action: '保存',
      maxLength: 40,
    );
    if (name != null && mounted) {
      await _run(() => _service.renameDevice(name));
    }
  }

  Future<void> _manualConnect() async {
    final address = await _textInput(
      title: '手动连接',
      label: '另一台设备的地址',
      hint: '192.168.1.10:端口',
      description: '在另一台设备的“进度同步”页查看本机地址。',
      action: '连接',
    );
    if (address != null && mounted) {
      await _run(() => _service.connectAddress(address));
    }
  }

  Future<String?> _textInput({
    required String title,
    required String label,
    required String action,
    String value = '',
    String? hint,
    String? description,
    int? maxLength,
    int maxLines = 1,
  }) => showProgressSyncTextInput(
    context: context,
    title: title,
    label: label,
    action: action,
    value: value,
    hint: hint,
    description: description,
    maxLength: maxLength,
    maxLines: maxLines,
  );
  Future<void> _syncCode(bool exporting) async {
    if (exporting) {
      if (_service.bindings.isEmpty) {
        _notice('先关联一个文件夹');
        return;
      }
      await _run(() async {
        final code = await _service.exportSyncCode();
        if (!mounted) return;
        await showSyncSheet<void>(
          context: context,
          title: '同步码',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '在自己的另一台设备导入此码，再选择对应文件夹。同步码含有关联权限，请妥善保管。',
                style: TextStyle(color: AppTokens.text2, height: 1.5),
              ),
              const SizedBox(height: 16),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 160),
                child: SingleChildScrollView(
                  child: SelectableText(
                    code,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTokens.text2,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              DesktopButtonClickRegion(
                child: FilledButton.icon(
                  icon: const Icon(Icons.copy_outlined, size: 18),
                  label: const Text('复制同步码'),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: code));
                    if (mounted) _notice('已复制');
                  },
                ),
              ),
            ],
          ),
        );
      });
    } else {
      final code = await _textInput(
        title: '导入同步码',
        label: '同步码',
        description: '从自己的另一台设备复制同步码。导入后，选择本机对应文件夹。',
        action: '导入',
        maxLines: 4,
      );
      if (code != null && mounted) {
        await _run(
          () => _service.importSyncCode(code),
          success: '已导入，请关联本机文件夹',
        );
      }
    }
  }

  Future<void> _saveStorage() async {
    if (!_storageForm.currentState!.validate()) return;
    final config = ProgressSyncWebDavConfig(
      url: _url.text.trim(),
      username: _username.text.trim(),
      password: _password.text.isNotEmpty
          ? _password.text
          : (_canKeepStoredPassword
                ? (_service.webDavConfig?.password ?? '')
                : ''),
    );
    await _run(
      () => _service.configureWebDav(config),
      success: '存储已连接，之后会自动同步',
    );
    if (mounted && _service.webDavConfig != null) {
      setState(() => _password.clear());
    }
  }

  @override
  Widget build(BuildContext context) => MediaLibraryPageShortcuts(
    enabled: _service.initialized,
    bindings: {
      LogicalKeyboardKey.keyR: () {
        if (!_busy && _service.enabled) unawaited(_run(_service.syncNow));
      },
      LogicalKeyboardKey.keyN: () {
        if (!_working) unawaited(_sendFolder());
      },
    },
    child: _buildPage(context),
  );

  Widget _buildPage(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        scaffoldBackgroundColor: AppTokens.bgBase,
        colorScheme: theme.colorScheme.copyWith(
          primary: AppTokens.accent,
          surface: AppTokens.bgRaised,
          onSurface: AppTokens.text1,
        ),
        textTheme: theme.textTheme.apply(
          bodyColor: AppTokens.text1,
          displayColor: AppTokens.text1,
        ),
        dividerColor: AppTokens.lineSubtle,
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF191919),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 14,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none,
          ),
          labelStyle: const TextStyle(color: AppTokens.text2, fontSize: 13),
        ),
      ),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('设备同步', style: TextStyle(fontSize: 17)),
          backgroundColor: AppTokens.bgBase,
          scrolledUnderElevation: 0,
          actions: [
            DesktopButtonClickRegion(
              child: IconButton(
                tooltip: hoverAwareShortcutTooltip(
                  '立即同步',
                  LogicalKeyboardKey.keyR,
                  context: context,
                ),
                onPressed: _busy || !_service.enabled
                    ? null
                    : () => unawaited(_run(_service.syncNow)),
                icon: const Icon(Icons.sync_outlined, size: 21),
              ),
            ),
            CapsulePopupMenuButton<bool>(
              tooltip: '更多',
              enabled: !_busy && _service.initialized,
              icon: const Icon(Icons.more_horiz, size: 21),
              onSelected: (value) => unawaited(_syncCode(value)),
              itemBuilder: (_) => const [
                PopupMenuItem(value: true, child: Text('导出同步码')),
                PopupMenuItem(value: false, child: Text('导入同步码')),
              ],
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: !_service.initialized
                  ? _buildLoading()
                  : ListView(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                      children: [
                        const Text(
                          '换一台设备，接着看。',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '关联文件夹，让内容和观看进度自动互通。',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppTokens.text2,
                          ),
                        ),
                        const SizedBox(height: 24),
                        DesktopButtonClickRegion(
                          child: FilledButton.icon(
                            key: const ValueKey('send-folder-primary'),
                            onPressed: _working
                                ? null
                                : () => unawaited(_sendFolder()),
                            icon: const Icon(Icons.send_outlined, size: 18),
                            label: Tooltip(
                              message: hoverAwareShortcutTooltip(
                                '发送文件夹',
                                LogicalKeyboardKey.keyN,
                                context: context,
                              ),
                              child: const Text('发送文件夹'),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        _buildSwitch(),
                        if (_service.error != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            _service.error!,
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppTokens.danger,
                            ),
                          ),
                        ],
                        const SizedBox(height: 24),
                        FolderTransferSection(service: _service),
                        if (_service.enabled) ...[
                          _buildPairings(),
                          _buildInvitations(),
                          _buildFileIssues(),
                          _buildConflicts(),
                          _buildDevices(),
                        ],
                        _buildFolders(),
                        _buildStorage(),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoading() => Center(
    child: _service.error == null
        ? const CircularProgressIndicator(strokeWidth: 2)
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_service.error!),
              DesktopButtonClickRegion(
                child: TextButton(
                  onPressed: _initialize,
                  child: const Text('重试'),
                ),
              ),
            ],
          ),
  );

  Widget _buildSwitch() => Material(
    color: AppTokens.bgRaised,
    borderRadius: BorderRadius.circular(12),
    child: Column(
      children: [
        SwitchListTile.adaptive(
          key: const ValueKey('progress-sync-enabled'),
          value: _service.enabled,
          activeThumbColor: AppTokens.text1,
          activeTrackColor: AppTokens.accent,
          inactiveThumbColor: AppTokens.text2,
          inactiveTrackColor: AppTokens.bgCard,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 5,
          ),
          title: const Text('自动同步', style: TextStyle(fontSize: 14)),
          subtitle: const Padding(
            padding: EdgeInsets.only(top: 5),
            child: Text(
              '无需账号，设备间直接同步',
              style: TextStyle(fontSize: 12, color: AppTokens.text2),
            ),
          ),
          onChanged: _busy
              ? null
              : (value) => unawaited(_run(() => _service.setEnabled(value))),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          child: Row(
            children: [
              if (_busy) ...[
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  _service.enabled
                      ? '${_service.status} 网盘条目目前只记录在本机。'
                      : '已暂停，本机仍会记录进度。网盘条目目前只记录在本机。',
                  style: const TextStyle(fontSize: 12, color: AppTokens.text2),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _buildPairings() {
    final pairings = _service.lan?.pairings ?? [];
    if (pairings.isEmpty) return const SizedBox.shrink();
    return SyncSection(
      title: '连接确认',
      child: Column(
        children: [
          for (final pairing in pairings)
            ListTile(
              leading: const Icon(Icons.phonelink_lock_outlined),
              title: Text(pairing.peer.name),
              subtitle: Text(
                pairing.localApproved ? '已确认，等待另一台设备' : '核对两端的确认码后连接',
                style: const TextStyle(fontSize: 12, color: AppTokens.text2),
              ),
              trailing: pairing.localApproved
                  ? DesktopButtonClickRegion(
                      child: IconButton(
                        tooltip: '取消连接',
                        onPressed: _busy
                            ? null
                            : () => unawaited(
                                _run(
                                  () => _service.lan!.rejectPair(pairing.id),
                                ),
                              ),
                        icon: const Icon(Icons.close, size: 20),
                      ),
                    )
                  : DesktopButtonClickRegion(
                      child: TextButton(
                        onPressed: _busy
                            ? null
                            : () async {
                                final allowed =
                                    await showProgressSyncPairingConfirmation(
                                      context: context,
                                      deviceName: pairing.peer.name,
                                      code: pairing.code,
                                    );
                                if (!mounted) return;
                                await _run(
                                  () => allowed
                                      ? _service.lan!.approvePair(
                                          pairing.id,
                                          expectedCode: pairing.code,
                                        )
                                      : _service.lan!.rejectPair(pairing.id),
                                );
                              },
                        child: const Text('核对'),
                      ),
                    ),
            ),
        ],
      ),
    );
  }

  Widget _buildInvitations() => _service.invitations.isEmpty
      ? const SizedBox.shrink()
      : SyncSection(
          title: '待关联文件夹',
          child: Column(
            children: [
              for (final invitation in _service.invitations)
                ListTile(
                  leading: const Icon(Icons.create_new_folder_outlined),
                  title: Text(invitation.name),
                  subtitle: Text(
                    [
                      if (invitation.fromDevice.isNotEmpty)
                        invitation.fromDevice,
                      if (invitation.mediaCount > 0)
                        '${invitation.mediaCount} 条进度',
                      if (invitation.fromDevice.isEmpty &&
                          invitation.mediaCount == 0)
                        '选择本机对应文件夹',
                    ].join(' · '),
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTokens.text2,
                    ),
                  ),
                  trailing: DesktopButtonClickRegion(
                    child: TextButton(
                      onPressed: _busy
                          ? null
                          : () => unawaited(_acceptInvitation(invitation)),
                      child: const Text('关联'),
                    ),
                  ),
                ),
            ],
          ),
        );

  Widget _buildConflicts() => _service.conflicts.isEmpty
      ? const SizedBox.shrink()
      : SyncSection(
          title: '需要选择的进度',
          child: Column(
            children: [
              for (final conflict in _service.conflicts)
                ListTile(
                  leading: const Icon(Icons.alt_route_outlined),
                  title: Text(conflict.title),
                  subtitle: const Text(
                    '两台设备都有新记录',
                    style: TextStyle(fontSize: 12, color: AppTokens.text2),
                  ),
                  trailing: DesktopButtonClickRegion(
                    child: TextButton(
                      onPressed: _busy
                          ? null
                          : () => unawaited(_resolve(conflict)),
                      child: const Text('选择'),
                    ),
                  ),
                ),
            ],
          ),
        );

  Future<void> _relinkSyncedMedia(FolderSyncIssue issue) => _run(() async {
    final selected = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      dialogTitle: '重新定位本机文件',
    );
    if (selected == null || selected.files.isEmpty || !mounted) return;
    final path = selected.files.first.path;
    if (path == null || path.isEmpty) {
      throw const FormatException('无法读取此文件，请选择本机的视频或音频');
    }
    await _service.relinkSyncedMedia(issue.groupId, issue.nodeId, path);
    if (mounted) _notice('已重新定位，观看进度已保留');
  });

  Widget _buildFileIssues() => _service.folderSyncIssues.isEmpty
      ? const SizedBox.shrink()
      : SyncSection(
          title: '文件需要确认',
          child: Column(
            children: [
              for (final issue in _service.folderSyncIssues)
                ListTile(
                  leading: const Icon(
                    Icons.compare_arrows_outlined,
                    color: AppTokens.text2,
                  ),
                  title: Text(issue.title),
                  subtitle: Text(
                    switch (issue.reason) {
                      'cloudNeedsCache' => '网盘媒体需要先完成缓存，再迁移为离线媒体',
                      'missingLocalFile' => '本机文件暂不可用，可自动补齐或重新定位',
                      'deleteHasLiveDescendants' => '另一端新增的内容已保留，请确认文件夹。',
                      _ => issue.message,
                    },
                    maxLines: issue.reason == 'missingLocalFile' ? 3 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTokens.text2,
                    ),
                  ),
                  trailing: DesktopButtonClickRegion(
                    child: TextButton(
                      onPressed: _working
                          ? null
                          : () async {
                              if (issue.reason == 'cloudNeedsCache') {
                                final catalogItem = _service.mediaForSyncIssue(
                                  issue.groupId,
                                  issue.nodeId,
                                );
                                final source = catalogItem == null
                                    ? null
                                    : CacheSource.fromItem(catalogItem);
                                if (source != null) {
                                  await showCacheQualities(context, source);
                                }
                                return;
                              }
                              if (issue.reason == 'missingLocalFile') {
                                await _relinkSyncedMedia(issue);
                                return;
                              }
                              if ((issue.kind == FolderSyncIssueKind.blocked &&
                                      issue.reason !=
                                          'deleteHasLiveDescendants') ||
                                  issue.choices.isEmpty) {
                                final binding = _service.bindings
                                    .where(
                                      (binding) =>
                                          binding.groupId == issue.groupId,
                                    )
                                    .firstOrNull;
                                if (binding != null) {
                                  await showFolderSyncActions(
                                    context,
                                    _service,
                                    binding.collectionId,
                                    name: binding.name,
                                  );
                                }
                                return;
                              }
                              final result = await showFolderSyncConflict(
                                context,
                                issue,
                              );
                              if (result != null && mounted) {
                                await _run(
                                  () => _service.resolveFolderSyncConflict(
                                    issue.groupId,
                                    issue.nodeId,
                                    result.eventId,
                                    keepBoth: result.keepBoth,
                                  ),
                                );
                              }
                            },
                      child: Text(
                        issue.reason == 'cloudNeedsCache'
                            ? '缓存'
                            : issue.reason == 'missingLocalFile'
                            ? '重新定位'
                            : '处理',
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );

  Widget _buildDevices() {
    final lan = _service.lan;
    final nearby = (lan?.nearbyDevices ?? [])
        .where((device) => !_service.pairedDevices.containsKey(device.id))
        .toList();
    return SyncSection(
      title: '设备',
      action: DesktopButtonClickRegion(
        child: TextButton(
          onPressed: _busy ? null : () => unawaited(_run(_service.discover)),
          child: const Text('刷新', style: TextStyle(fontSize: 12)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: const Icon(Icons.devices_outlined, color: AppTokens.text2),
            title: Text(_service.deviceName),
            subtitle: const Text(
              '本机',
              style: TextStyle(fontSize: 12, color: AppTokens.text2),
            ),
            trailing: DesktopButtonClickRegion(
              child: IconButton(
                tooltip: '修改设备名称',
                onPressed: _busy ? null : _renameDevice,
                icon: const Icon(Icons.edit_outlined, size: 18),
                color: AppTokens.text2,
              ),
            ),
          ),
          if (_service.pairedDevices.isNotEmpty || nearby.isNotEmpty)
            const Divider(height: 1, indent: 16, endIndent: 16),
          for (final peer in _service.pairedDevices.entries)
            ListTile(
              key: ValueKey('paired-device-${peer.key}'),
              leading: Icon(
                Icons.phonelink_outlined,
                color: lan?.connectedPeers.contains(peer.key) == true
                    ? AppTokens.accent
                    : AppTokens.text2,
              ),
              title: Text(peer.value),
              subtitle: SyncStatus(
                label: lan?.connectedPeers.contains(peer.key) == true
                    ? '已连接，自动同步'
                    : '等待设备上线',
                active: lan?.connectedPeers.contains(peer.key) == true,
              ),
              trailing: CapsulePopupMenuButton<String>(
                tooltip: '设备选项',
                enabled: !_busy,
                onSelected: (_) =>
                    unawaited(_run(() => lan!.removePeer(peer.key))),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'remove', child: Text('取消配对')),
                ],
              ),
            ),
          for (final device in nearby)
            ListTile(
              key: ValueKey('nearby-device-${device.publicKeyBase64}'),
              leading: const Icon(
                Icons.phonelink_outlined,
                color: AppTokens.text2,
              ),
              title: Text(device.name),
              subtitle: const Text(
                '附近设备',
                style: TextStyle(fontSize: 12, color: AppTokens.text2),
              ),
              trailing: DesktopButtonClickRegion(
                child: TextButton(
                  onPressed: _busy
                      ? null
                      : () => unawaited(
                          _run(() async {
                            await lan!.requestPair(device);
                          }),
                        ),
                  child: const Text('连接'),
                ),
              ),
            ),
          if (_service.pairedDevices.isEmpty && nearby.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Text(
                '在另一台设备打开此页，并连接同一 Wi-Fi。',
                style: TextStyle(
                  fontSize: 12,
                  color: AppTokens.text2,
                  height: 1.6,
                ),
              ),
            ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                if (_service.connectionAddress != null)
                  SelectableText(
                    '本机地址 ${_service.connectionAddress}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppTokens.text3,
                    ),
                  ),
                DesktopButtonClickRegion(
                  child: TextButton(
                    onPressed: _busy ? null : _manualConnect,
                    child: const Text('手动连接', style: TextStyle(fontSize: 12)),
                  ),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: Text(
              '两台设备同时打开软件时同步，离线记录下次自动补齐。',
              style: TextStyle(
                fontSize: 11,
                color: AppTokens.text3,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFolders() => SyncSection(
    title: '同步的文件夹',
    action: DesktopButtonClickRegion(
      child: TextButton.icon(
        onPressed: _busy ? null : () => unawaited(_addFolder()),
        icon: const Icon(Icons.add, size: 16),
        label: const Text('添加', style: TextStyle(fontSize: 12)),
      ),
    ),
    child: _service.bindings.isEmpty
        ? const SyncEmpty(
            icon: Icons.folder_outlined,
            title: '选择想要接着看的文件夹',
            description: '两端文件夹名称和路径可以不同。',
          )
        : Column(
            children: [
              for (final binding in _service.bindings)
                ListTile(
                  leading: const Icon(
                    Icons.folder_outlined,
                    color: AppTokens.text2,
                  ),
                  title: Text(binding.name),
                  subtitle: Text(
                    [
                      folderSyncModeLabel(binding.mode),
                      if (!_service.enabled)
                        '同步已暂停'
                      else if (binding.status.isNotEmpty)
                        binding.status
                      else if (binding.lastSyncedAt != null)
                        _date(binding.lastSyncedAt!)
                      else
                        '等待同步',
                      if (binding.pendingCount > 0)
                        '${binding.pendingCount} 项待同步',
                      if (binding.conflictCount > 0)
                        '${binding.conflictCount} 项需确认',
                    ].join(' · '),
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTokens.text2,
                    ),
                  ),
                  onTap: _working
                      ? null
                      : () => unawaited(
                          showFolderSyncActions(
                            context,
                            _service,
                            binding.collectionId,
                            name: binding.name,
                          ),
                        ),
                  trailing: CapsulePopupMenuButton<String>(
                    tooltip: '文件夹选项',
                    enabled: !_busy,
                    onSelected: (action) {
                      if (action == 'send') {
                        unawaited(_sendFolder(initialId: binding.collectionId));
                      } else if (action == 'settings') {
                        unawaited(
                          showFolderSyncSettings(
                            context,
                            _service,
                            binding.collectionId,
                            name: binding.name,
                          ),
                        );
                      } else if (action == 'sync') {
                        unawaited(
                          _run(
                            () => _service.syncFolderNow(binding.collectionId),
                          ),
                        );
                      } else {
                        unawaited(
                          _run(
                            () => _service.unbindFolder(binding.collectionId),
                          ),
                        );
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'sync', child: Text('立即同步')),
                      PopupMenuItem(value: 'settings', child: Text('同步设置')),
                      PopupMenuItem(value: 'send', child: Text('同步到设备')),
                      PopupMenuItem(value: 'remove', child: Text('停止同步此文件夹')),
                    ],
                  ),
                ),
            ],
          ),
  );

  Widget _buildStorage() => SyncSection(
    title: '更多方式',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          key: const ValueKey('progress-sync-storage'),
          leading: const Icon(Icons.storage_outlined, color: AppTokens.text2),
          title: const Text('使用已有存储', style: TextStyle(fontSize: 14)),
          subtitle: Text(
            _service.webDavConfig == null
                ? 'WebDAV / NAS · 可选'
                : !_service.enabled
                ? '已暂停'
                : (_service.webDavStatus ?? '已配置'),
            style: const TextStyle(fontSize: 12, color: AppTokens.text2),
          ),
          trailing: Icon(
            _storageExpanded ? Icons.expand_less : Icons.expand_more,
          ),
          onTap: () => setState(() => _storageExpanded = !_storageExpanded),
        ),
        if (_storageExpanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Form(
              key: _storageForm,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    '已有存储可保存同步记录；传文件时两台设备仍需在线。填写服务提供的 WebDAV 地址。',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTokens.text2,
                      height: 1.6,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _url,
                    enabled: !_busy,
                    onChanged: (_) => setState(() {}),
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: '存储地址',
                      hintText: 'https://example.com/dav/',
                    ),
                    validator: (value) {
                      final uri = Uri.tryParse(value?.trim() ?? '');
                      return uri != null &&
                              ['https', 'http'].contains(uri.scheme) &&
                              uri.host.isNotEmpty &&
                              uri.userInfo.isEmpty
                          ? null
                          : '请输入完整的 http 或 https 地址';
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _username,
                    enabled: !_busy,
                    onChanged: (_) => setState(() {}),
                    autocorrect: false,
                    decoration: const InputDecoration(labelText: '用户名（如有）'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _password,
                    enabled: !_busy,
                    obscureText: !_showPassword,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: _canKeepStoredPassword ? '密码（留空保留）' : '密码（如有）',
                      suffixIcon: DesktopButtonClickRegion(
                        child: IconButton(
                          tooltip: _showPassword ? '隐藏密码' : '显示密码',
                          icon: Icon(
                            _showPassword
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                            size: 19,
                          ),
                          onPressed: () =>
                              setState(() => _showPassword = !_showPassword),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(
                      spacing: 8,
                      children: [
                        if (_service.webDavConfig != null)
                          DesktopButtonClickRegion(
                            child: TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => unawaited(
                                      _run(_service.disconnectWebDav),
                                    ),
                              child: const Text('断开'),
                            ),
                          ),
                        DesktopButtonClickRegion(
                          child: TextButton(
                            onPressed: _busy ? null : _saveStorage,
                            child: const Text('测试并连接'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '两端连接同一存储。先关联文件夹；不在同一网络时，可用右上角的同步码关联。',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppTokens.text3,
                      height: 1.6,
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

String _position(int milliseconds) {
  final seconds = milliseconds ~/ 1000;
  final minutes = seconds ~/ 60;
  return minutes >= 60
      ? '${minutes ~/ 60}:${(minutes % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}'
      : '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
}

String _date(DateTime date) {
  final local = date.toLocal();
  final now = DateTime.now();
  final time =
      '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  return local.year == now.year &&
          local.month == now.month &&
          local.day == now.day
      ? '今天 $time'
      : '${local.month}/${local.day} $time';
}
