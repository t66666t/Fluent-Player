import '../../utils/keyboard_shortcut_hints.dart';
import 'dart:async';
import 'dart:io';
import '../../models/import_card_placement.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../services/app_haptics.dart';
import '../../services/library_service.dart';
import '../../services/settings_service.dart';
import '../../utils/app_toast.dart';
import '../../utils/reveal_in_file_manager.dart';
import '../../utils/android_hardware_input_bridge.dart';
import '../../utils/batch_tool_shortcuts.dart';
import '../../utils/hardware_keyboard_shortcuts.dart';
import '../../utils/page_shortcut_keys.dart';
import '../../utils/route_transition_work.dart';
import 'portable_export_format_page.dart';
import 'portable_selection_page.dart';
import 'portable_transfer_models.dart';
import 'portable_transfer_service.dart';
import '../../widgets/stable_width_label.dart';
import '../../widgets/capsule_selector.dart';
import '../progress_sync/folder_transfer_models.dart';
import '../progress_sync/folder_transfer_widgets.dart';
import '../progress_sync/progress_sync_service.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

class PortableTransferScreen extends StatefulWidget {
  const PortableTransferScreen({
    super.key,
    this.initialTab = PortableTransferKind.export,
    this.pendingImportSources,
    this.pendingExportRootIds,
    this.libraryFolderId,
    this.pendingImportPlacement,
  });

  final PortableTransferKind initialTab;
  final List<PortableImportSource>? pendingImportSources;
  final List<String>? pendingExportRootIds;
  final String? libraryFolderId;
  final ImportPlacementRequest? pendingImportPlacement;

  @override
  State<PortableTransferScreen> createState() => _PortableTransferScreenState();
}

class _PortableTransferScreenState extends State<PortableTransferScreen> {
  static const String _unsupportedImportMessage =
      '只能选择 .fluentpack，或 zip、tar、tar.gz、tar.bz2、tar.xz 压缩包';
  static const MethodChannel _androidFileManagerChannel = MethodChannel(
    'com.example.video_player_app/file_manager',
  );
  final PortableTransferService _service = PortableTransferService.instance;
  final _routeWork = RouteTransitionWork();
  late PortableTransferKind _tab;
  bool _picking = false;
  bool _managingTasks = false;
  bool _serviceInitialized = false;
  bool _consumedPendingLaunch = false;
  final Set<String> _selectedTaskIds = <String>{};
  final FocusNode _shortcutFocusNode = FocusNode();
  final AndroidHardwareKeyDeduplicator _androidKeyDeduplicator =
      AndroidHardwareKeyDeduplicator();

  bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  @override
  void initState() {
    super.initState();
    AndroidHardwareInputBridge.addKeyListener(_handleAndroidHardwareKeyEvent);
    HardwareKeyboard.instance.addHandler(_handleGlobalHardwareKeyEvent);
    _tab = widget.initialTab;
    if (widget.pendingImportSources?.isNotEmpty == true) {
      // Drop/share already submitted the files. Keep job creation and owned
      // temporary-file cleanup on their original first-frame path.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_consumePendingLaunch());
      });
    } else {
      _routeWork.schedule('pending-launch', () {
        unawaited(_consumePendingLaunch());
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeWork.bind(ModalRoute.of(context));
    if (_serviceInitialized) return;
    _serviceInitialized = true;
    unawaited(_service.initialize(library: context.read<LibraryService>()));
  }

  /// External imports keep their immediate first-frame start. Only automatic
  /// export-option navigation waits for a fully built, settled parent page.
  Future<void> _consumePendingLaunch() async {
    if (_consumedPendingLaunch || !mounted) return;
    _consumedPendingLaunch = true;
    final sources = widget.pendingImportSources;
    final exportIds = widget.pendingExportRootIds;
    if (sources != null && sources.isNotEmpty) {
      await _startImportFromSources(sources);
      return;
    }
    if (exportIds != null && exportIds.isNotEmpty) {
      await Navigator.of(context).push<bool>(
        AppMaterialPageRoute<bool>(
          builder: (_) => PortableExportFormatPage(
            library: context.read<LibraryService>(),
            rootIds: exportIds,
          ),
        ),
      );
    }
  }

  bool _handleGlobalHardwareKeyEvent(KeyEvent event) {
    if (_shortcutFocusNode.hasFocus) return false;
    return _handleShortcutKeyEvent(event) != KeyEventResult.ignored;
  }

  void _handleAndroidHardwareKeyEvent(AndroidHardwareKeyMessage message) {
    _handleShortcutKeyEvent(
      message.toKeyEvent(),
      fromAndroidNativeBridge: true,
      hasBlockingModifierOverride: message.hasBlockingModifier,
    );
  }

  String _ptTooltip(String label, PortableTransferShortcutAction action) {
    return hoverAwareShortcutTooltip(
      label,
      PortableTransferShortcuts.defaults[action]!,
      context: context,
    );
  }

  KeyEventResult _handleShortcutKeyEvent(
    KeyEvent event, {
    bool fromAndroidNativeBridge = false,
    bool? hasBlockingModifierOverride,
  }) {
    if (!supportsNativeHardwareKeyboardShortcuts) {
      return KeyEventResult.ignored;
    }
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return KeyEventResult.ignored;
    if (Platform.isAndroid &&
        !_androidKeyDeduplicator.shouldDispatch(
          event,
          fromNativeBridge: fromAndroidNativeBridge,
        )) {
      return KeyEventResult.handled;
    }
    if (isEditableTextFocused()) return KeyEventResult.ignored;
    final bool hasBlockingModifier =
        hasBlockingModifierOverride ?? hasBlockingKeyboardModifier();
    if (hasBlockingModifier) return KeyEventResult.ignored;
    final PortableTransferShortcutAction? action =
        PortableTransferShortcuts.matchAction(event.logicalKey);
    final platform = currentNativeTargetPlatform;
    if (action == null ||
        platform == null ||
        !PortableTransferShortcuts.isAvailableOnPlatform(action, platform)) {
      return KeyEventResult.ignored;
    }
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    switch (action) {
      case PortableTransferShortcutAction.backOrExitManagement:
        if (_managingTasks) {
          _leaveTaskManagement();
        } else {
          Navigator.of(context).maybePop();
        }
        return KeyEventResult.handled;
      case PortableTransferShortcutAction.exportTab:
        _switchTab(PortableTransferKind.export);
        return KeyEventResult.handled;
      case PortableTransferShortcutAction.importTab:
        _switchTab(PortableTransferKind.import);
        return KeyEventResult.handled;
      case PortableTransferShortcutAction.primaryAction:
        if (_managingTasks) return KeyEventResult.handled;
        if (_tab == PortableTransferKind.export) {
          unawaited(_startExport());
        } else {
          unawaited(_startImport());
        }
        return KeyEventResult.handled;
      case PortableTransferShortcutAction.enterManagement:
        if (!_managingTasks && _manageableTasks.isNotEmpty) {
          _enterTaskManagement();
        }
        return KeyEventResult.handled;
      case PortableTransferShortcutAction.selectAll:
        if (_managingTasks) _toggleSelectAll(_manageableTasks);
        return KeyEventResult.handled;
      case PortableTransferShortcutAction.deleteSelected:
        if (_managingTasks && _selectedTaskIds.isNotEmpty) {
          unawaited(_deleteSelectedTasks());
        }
        return KeyEventResult.handled;
    }
  }

  @override
  void dispose() {
    _routeWork.dispose();
    AndroidHardwareInputBridge.removeKeyListener(
      _handleAndroidHardwareKeyEvent,
    );
    HardwareKeyboard.instance.removeHandler(_handleGlobalHardwareKeyEvent);
    _shortcutFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inheritedTheme = Theme.of(context);
    ProgressSyncService? progressSync;
    try {
      progressSync = context.read<ProgressSyncService>();
    } on ProviderNotFoundException {
      // Standalone import/export sessions also work without device sync.
    }
    final transferUpdates = progressSync == null
        ? _service
        : Listenable.merge([_service, progressSync]);
    return Theme(
      data: inheritedTheme.copyWith(
        textTheme: inheritedTheme.textTheme.apply(fontFamily: 'Noto Sans SC'),
        primaryTextTheme: inheritedTheme.primaryTextTheme.apply(
          fontFamily: 'Noto Sans SC',
        ),
        scaffoldBackgroundColor: const Color(0xFF0F1014),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7C8CFF),
          brightness: Brightness.dark,
        ),
      ),
      child: Focus(
        focusNode: _shortcutFocusNode,
        autofocus: supportsNativeHardwareKeyboardShortcuts,
        onKeyEvent: (node, event) => _handleShortcutKeyEvent(event),
        child: Scaffold(
          appBar: AppBar(
            backgroundColor: const Color(0xFF0F1014),
            surfaceTintColor: Colors.transparent,
            leading: _managingTasks
                ? DesktopButtonClickRegion(
                    child: IconButton(
                      onPressed: AppHaptics.wrap(
                        _leaveTaskManagement,
                        light: true,
                      ),
                      tooltip: _ptTooltip(
                        '退出管理',
                        PortableTransferShortcutAction.backOrExitManagement,
                      ),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  )
                : null,
            title: Text(
              _managingTasks ? '已选择 ${_selectedTaskIds.length} 项' : '导入与导出',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            actions: [
              AnimatedBuilder(
                animation: _service,
                builder: (context, _) {
                  final manageable = _manageableTasks;
                  if (manageable.isEmpty) return const SizedBox.shrink();
                  if (!_managingTasks) {
                    return DesktopButtonClickRegion(
                      child: IconButton(
                        onPressed: AppHaptics.wrap(
                          _enterTaskManagement,
                          light: true,
                        ),
                        tooltip: _ptTooltip(
                          '批量管理',
                          PortableTransferShortcutAction.enterManagement,
                        ),
                        icon: const Icon(Icons.checklist_rounded),
                      ),
                    );
                  }
                  final allSelected = manageable.every(
                    (task) => _selectedTaskIds.contains(task.id),
                  );
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      DesktopButtonClickRegion(
                        child: IconButton(
                          onPressed: AppHaptics.wrap(
                            () => _toggleSelectAll(manageable),
                            light: true,
                          ),
                          tooltip: _ptTooltip(
                            allSelected ? '取消全选' : '全选',
                            PortableTransferShortcutAction.selectAll,
                          ),
                          icon: Icon(
                            allSelected
                                ? Icons.deselect_rounded
                                : Icons.select_all_rounded,
                          ),
                        ),
                      ),
                      DesktopButtonClickRegion(
                        child: IconButton(
                          onPressed: AppHaptics.wrap(
                            _selectedTaskIds.isEmpty
                                ? null
                                : _deleteSelectedTasks,
                            light: true,
                          ),
                          tooltip: _ptTooltip(
                            '删除所选任务',
                            PortableTransferShortcutAction.deleteSelected,
                          ),
                          icon: const Icon(Icons.delete_outline_rounded),
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Column(
              children: [
                _buildHeader(),
                Expanded(
                  child: AnimatedBuilder(
                    animation: transferUpdates,
                    builder: (context, _) {
                      final tasks = _service.tasks
                          .where((task) => task.kind == _tab)
                          .toList();
                      final direction = _tab == PortableTransferKind.export
                          ? FolderTransferDirection.send
                          : FolderTransferDirection.receive;
                      final hasDeviceTransfers =
                          progressSync?.folderTransfers.any(
                            (task) => task.direction == direction,
                          ) ??
                          false;
                      return AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        child: tasks.isEmpty && !hasDeviceTransfers
                            ? _EmptyTransferState(
                                key: ValueKey(_tab),
                                kind: _tab,
                                onPressed: _tab == PortableTransferKind.export
                                    ? _startExport
                                    : _startImport,
                              )
                            : ListView.separated(
                                key: ValueKey('list-$_tab'),
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  12,
                                  16,
                                  120,
                                ),
                                itemCount:
                                    tasks.length + (hasDeviceTransfers ? 1 : 0),
                                separatorBuilder: (_, _) =>
                                    const SizedBox(height: 10),
                                itemBuilder: (context, index) {
                                  if (hasDeviceTransfers && index == 0) {
                                    return FolderTransferSection(
                                      service: progressSync!,
                                      direction: direction,
                                    );
                                  }
                                  final taskIndex =
                                      index - (hasDeviceTransfers ? 1 : 0);
                                  return TweenAnimationBuilder<double>(
                                    tween: Tween(begin: 0, end: 1),
                                    duration: Duration(
                                      milliseconds:
                                          180 + index.clamp(0, 4) * 45,
                                    ),
                                    curve: Curves.easeOutCubic,
                                    builder: (context, value, child) => Opacity(
                                      opacity: value,
                                      child: Transform.translate(
                                        offset: Offset(0, 10 * (1 - value)),
                                        child: child,
                                      ),
                                    ),
                                    child: _TransferTaskCard(
                                      task: tasks[taskIndex],
                                      isDesktop: _isDesktop,
                                      selectionMode: _managingTasks,
                                      selected: _selectedTaskIds.contains(
                                        tasks[taskIndex].id,
                                      ),
                                      onCancel: () =>
                                          _service.cancel(tasks[taskIndex].id),
                                      onMore: (anchor) => _showTaskActions(
                                        tasks[taskIndex],
                                        anchor,
                                      ),
                                      onToggleSelection: () =>
                                          _toggleTaskSelection(
                                            tasks[taskIndex],
                                          ),
                                      onLongPress: () => _enterTaskManagement(
                                        tasks[taskIndex],
                                      ),
                                      onOpen: () =>
                                          _openTaskFile(tasks[taskIndex]),
                                      onReveal: () =>
                                          _revealTaskFile(tasks[taskIndex]),
                                      onShare: () =>
                                          _shareTaskFile(tasks[taskIndex]),
                                    ),
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
          floatingActionButton: AnimatedBuilder(
            animation: transferUpdates,
            builder: (context, _) {
              final direction = _tab == PortableTransferKind.export
                  ? FolderTransferDirection.send
                  : FolderTransferDirection.receive;
              final hasTasks =
                  _service.tasks.any((task) => task.kind == _tab) ||
                  (progressSync?.folderTransfers.any(
                        (task) => task.direction == direction,
                      ) ??
                      false);
              if (!hasTasks || _managingTasks) return const SizedBox.shrink();
              return FloatingActionButton.extended(
                onPressed: AppHaptics.wrap(
                  _picking
                      ? null
                      : (_tab == PortableTransferKind.export
                            ? _startExport
                            : _startImport),
                  light: true,
                ),
                icon: Icon(
                  _tab == PortableTransferKind.export
                      ? Icons.add_rounded
                      : Icons.file_open_outlined,
                ),
                label: Text(
                  _ptTooltip(
                    _tab == PortableTransferKind.export ? '新建导出' : '选择文件',
                    PortableTransferShortcutAction.primaryAction,
                  ),
                ),
              );
            },
          ),
          bottomNavigationBar: _managingTasks
              ? _TaskManagementBar(
                  selectedCount: _selectedTaskIds.length,
                  onDelete: _selectedTaskIds.isEmpty
                      ? null
                      : _deleteSelectedTasks,
                )
              : null,
        ),
      ),
    );
  }

  List<PortableTransferTask> get _manageableTasks => _service.tasks
      .where((task) => task.kind == _tab && !task.isActive)
      .toList(growable: false);

  void _switchTab(PortableTransferKind kind) {
    if (_tab == kind) return;
    setState(() {
      _tab = kind;
      _managingTasks = false;
      _selectedTaskIds.clear();
    });
  }

  void _enterTaskManagement([PortableTransferTask? initiallySelected]) {
    if (initiallySelected?.isActive == true) return;
    setState(() {
      _managingTasks = true;
      if (initiallySelected != null) {
        _selectedTaskIds.add(initiallySelected.id);
      }
    });
    unawaited(AppHaptics.selectionClick(context.read<SettingsService>()));
  }

  void _leaveTaskManagement() {
    setState(() {
      _managingTasks = false;
      _selectedTaskIds.clear();
    });
  }

  void _toggleTaskSelection(PortableTransferTask task) {
    if (task.isActive) return;
    setState(() {
      if (!_selectedTaskIds.add(task.id)) {
        _selectedTaskIds.remove(task.id);
      }
    });
  }

  void _toggleSelectAll(List<PortableTransferTask> manageable) {
    setState(() {
      final allSelected = manageable.every(
        (task) => _selectedTaskIds.contains(task.id),
      );
      if (allSelected) {
        _selectedTaskIds.removeAll(manageable.map((task) => task.id));
      } else {
        _selectedTaskIds.addAll(manageable.map((task) => task.id));
      }
    });
  }

  Future<void> _showTaskActions(
    PortableTransferTask task,
    BuildContext anchor,
  ) async {
    if (task.isActive) return;
    final action = await showCapsuleMenu<_TaskAction>(
      context: context,
      anchorContext: anchor,
      constraints: const BoxConstraints(maxWidth: 320),
      items: [
        PopupMenuItem(
          enabled: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                task.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                task.filePath == null
                    ? task.subtitle
                    : '${task.subtitle}\n${task.filePath}',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        const PopupMenuItem(
          value: _TaskAction.select,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.checklist_rounded),
            title: Text('进入批量管理'),
            subtitle: Text('可继续勾选其他任务'),
          ),
        ),
        if (_service.canRetry(task.id))
          const PopupMenuItem(
            value: _TaskAction.retry,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.refresh_rounded),
              title: Text('重试任务'),
              subtitle: Text('会先清理上次中断留下的半成品'),
            ),
          ),
        const PopupMenuItem(
          value: _TaskAction.delete,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            iconColor: Color(0xFFFF8490),
            textColor: Color(0xFFFF9AA4),
            leading: Icon(Icons.delete_outline_rounded),
            title: Text('删除任务…'),
            subtitle: Text('下一步可选择是否同时删除文件'),
          ),
        ),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case _TaskAction.select:
        _enterTaskManagement(task);
      case _TaskAction.delete:
        await _confirmAndDeleteTasks(<PortableTransferTask>[task]);
      case _TaskAction.retry:
        await _service.retryTask(task.id, context.read<LibraryService>());
      case null:
        break;
    }
  }

  Future<void> _deleteSelectedTasks() async {
    final selected = _manageableTasks
        .where((task) => _selectedTaskIds.contains(task.id))
        .toList(growable: false);
    if (selected.isEmpty) return;
    await _confirmAndDeleteTasks(selected);
  }

  Future<void> _confirmAndDeleteTasks(List<PortableTransferTask> tasks) async {
    final existingPaths = tasks
        .map((task) => task.filePath)
        .whereType<String>()
        .where((path) => path.isNotEmpty && File(path).existsSync())
        .toSet();
    var deleteFiles = true;
    final decision = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            tasks.length == 1 ? '删除这条任务？' : '删除 ${tasks.length} 条任务？',
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                existingPaths.isEmpty
                    ? '只会移除任务记录，没有找到仍然存在的关联文件。'
                    : '将移除任务记录，并处理 ${existingPaths.length} 个关联文件。',
                style: const TextStyle(color: Colors.white70, height: 1.4),
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: existingPaths.isNotEmpty && deleteFiles,
                onChanged: existingPaths.isEmpty
                    ? null
                    : AppHaptics.wrapValue(
                        (value) =>
                            setDialogState(() => deleteFiles = value ?? true),
                      ),
                title: const Text('同时删除文件'),
                subtitle: Text(
                  tasks.any((task) => task.kind == PortableTransferKind.import)
                      ? '默认开启；导入任务可能指向你选择的原始文件。'
                      : '默认开启；关闭后只删除记录，导出包仍会保留。',
                ),
              ),
              if (existingPaths.isNotEmpty && deleteFiles)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    '文件删除后无法从应用内恢复。',
                    style: TextStyle(color: Color(0xFFFF9AA4), fontSize: 12),
                  ),
                ),
            ],
          ),
          actions: [
            DesktopButtonClickRegion(
              child: TextButton(
                onPressed: AppHaptics.wrap(
                  () => Navigator.pop(dialogContext),
                  light: true,
                ),
                child: const Text('取消'),
              ),
            ),
            DesktopButtonClickRegion(
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFD9515D),
                ),
                onPressed: AppHaptics.wrap(
                  () => Navigator.pop(
                    dialogContext,
                    existingPaths.isNotEmpty && deleteFiles,
                  ),
                  light: true,
                ),
                child: const Text('删除'),
              ),
            ),
          ],
        ),
      ),
    );
    if (decision == null || !mounted) return;

    final result = await _service.removeTasks(
      tasks.map((task) => task.id),
      deleteFiles: decision,
    );
    if (!mounted) return;
    setState(() {
      _selectedTaskIds.removeAll(tasks.map((task) => task.id));
      if (_manageableTasks.isEmpty) {
        _managingTasks = false;
        _selectedTaskIds.clear();
      }
    });
    if (result.hasFailures) {
      AppToast.show(
        '${result.failedFilePaths.length} 个文件删除失败，对应任务已保留',
        type: AppToastType.error,
      );
    }
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF191B22),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: PortableTransferKind.values.map((kind) {
            final selected = _tab == kind;
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: InkWell(
                  borderRadius: BorderRadius.circular(11),
                  onTap: () {
                    AppHaptics.pulse();
                    _switchTab(kind);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    height: 42,
                    decoration: BoxDecoration(
                      color: selected
                          ? const Color(0xFF292D3B)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(11),
                    ),
                    alignment: Alignment.center,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          kind == PortableTransferKind.export
                              ? Icons.north_east_rounded
                              : Icons.south_west_rounded,
                          size: 18,
                          color: selected
                              ? const Color(0xFFAEB8FF)
                              : Colors.white54,
                        ),
                        const SizedBox(width: 7),
                        Text(
                          kind == PortableTransferKind.export
                              ? shortcutHintLabel(context, '导出', 'E')
                              : shortcutHintLabel(context, '导入', 'I'),
                          style: TextStyle(
                            color: selected ? Colors.white : Colors.white60,
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Future<void> _startExport() async {
    if (_picking) return;
    // An explicit action supersedes a launch request still waiting for entry.
    _consumedPendingLaunch = true;
    final library = context.read<LibraryService>();
    await Navigator.of(context).push<void>(
      AppMaterialPageRoute<void>(
        builder: (_) => PortableSelectionPage(library: library),
      ),
    );
  }

  Future<void> _startImport() async {
    if (_picking) return;
    _consumedPendingLaunch = true;
    setState(() => _picking = true);
    try {
      final package = await _pickPortablePackage();
      if (package == null) return;
      if (!mounted) {
        await package.disposeIfOwned();
        return;
      }
      if (package.archive) {
        await _importPickedArchive(package, showPreview: true);
      } else {
        await _importPickedPackage(package, showPreview: true);
      }
    } catch (error) {
      AppToast.show('无法导入：$error', type: AppToastType.error);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// External drop / share already chose the files, so skip picker + preview
  /// and create import tasks immediately so they show up on the import tab.
  Future<void> _startImportFromSources(
    List<PortableImportSource> sources,
  ) async {
    if (_picking || sources.isEmpty) return;
    setState(() => _picking = true);
    try {
      for (final source in sources) {
        if (!mounted) return;
        final package = _PickedPortablePackage(
          source.path,
          displayName: source.displayName,
          ownedTemporaryCopy: source.ownedTemporaryCopy,
        );
        try {
          await _importPickedPackage(
            package,
            showPreview: false,
            importPlacement: widget.pendingImportPlacement,
          );
        } catch (error) {
          AppToast.show(
            '无法导入 ${source.displayName}：$error',
            type: AppToastType.error,
          );
          await package.disposeIfOwned();
        }
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _importPickedPackage(
    _PickedPortablePackage package, {
    required bool showPreview,
    ImportPlacementRequest? importPlacement,
  }) async {
    var handedToService = false;
    try {
      final preview = await _service.inspectPackage(package.path);
      if (!mounted) return;
      if (showPreview) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (_) => _ImportPreviewDialog(
            preview: preview,
            fileName: package.displayName,
          ),
        );
        if (confirmed != true || !mounted) return;
      }
      await _service.importPackage(
        library: context.read<LibraryService>(),
        packagePath: package.path,
        preview: preview,
        deletePackageWhenDone: package.ownedTemporaryCopy,
        importPlacement: importPlacement,
        libraryFolderId: widget.libraryFolderId,
      );
      handedToService = true;
      if (mounted) setState(() => _tab = PortableTransferKind.import);
    } finally {
      if (!handedToService) await package.disposeIfOwned();
    }
  }

  Future<void> _importPickedArchive(
    _PickedPortablePackage package, {
    required bool showPreview,
  }) async {
    var handedToService = false;
    try {
      if (!LibraryService.isSupportedArchivePath(package.displayName) &&
          !LibraryService.isSupportedArchivePath(package.path)) {
        throw UnsupportedError('当前仅支持 zip、tar、tar.gz、tar.bz2、tar.xz 压缩包');
      }
      final library = context.read<LibraryService>();
      if (library.hasActiveImport) {
        throw StateError('已有导入任务正在运行，请等待完成后再试');
      }
      var sizeBytes = 0;
      final file = File(package.path);
      if (await file.exists()) {
        sizeBytes = await file.length();
      }
      if (!mounted) return;
      final rootName = LibraryService.archiveRootCollectionName(
        package.displayName.trim().isNotEmpty
            ? package.displayName
            : package.path,
      );
      if (showPreview) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (_) => _ArchiveImportPreviewDialog(
            title: rootName,
            fileName: package.displayName,
            sizeBytes: sizeBytes,
          ),
        );
        if (confirmed != true || !mounted) return;
      }
      await _service.importArchive(
        library: context.read<LibraryService>(),
        archivePath: package.path,
        displayName: package.displayName,
        deleteArchiveWhenDone: package.ownedTemporaryCopy,
        libraryFolderId: widget.libraryFolderId,
      );
      handedToService = true;
      if (mounted) setState(() => _tab = PortableTransferKind.import);
    } finally {
      if (!handedToService) await package.disposeIfOwned();
    }
  }

  Future<void> _openTaskFile(PortableTransferTask task) async {
    if (task.filePath == null) return;
    await OpenFilex.open(
      task.filePath!,
      type: Platform.isAndroid
          ? 'application/zip'
          : PortableTransferService.mimeType,
    );
  }

  Future<void> _shareTaskFile(PortableTransferTask task) async {
    if (task.filePath == null) return;
    final size = MediaQuery.sizeOf(context);
    await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile(
            task.filePath!,
            // Android cannot globally register a private extension-to-MIME
            // mapping. Advertising the ZIP container lets Files/Downloads
            // index saved packages as archives and surface new ones in Recents.
            mimeType: Platform.isAndroid
                ? 'application/zip'
                : PortableTransferService.mimeType,
          ),
        ],
        subject: task.title,
        // iPad presents sharing as a popover and requires a valid anchor.
        sharePositionOrigin: Rect.fromLTWH(
          size.width / 2,
          size.height / 2,
          1,
          1,
        ),
      ),
    );
  }

  Future<void> _revealTaskFile(PortableTransferTask task) async {
    final path = task.filePath;
    if (path == null) return;
    await revealInFileManager(path);
  }

  Future<_PickedPortablePackage?> _pickPortablePackage() async {
    if (Platform.isAndroid) {
      final selection = await _androidFileManagerChannel
          .invokeMapMethod<String, dynamic>('pickImportFile');
      if (selection == null) return null;
      final displayName = selection['displayName']?.toString() ?? '';
      final archive = _isArchiveImportName(displayName);
      final fluentPack = PortableTransferService.hasPackageExtension(
        displayName,
      );
      if (!fluentPack && !archive) {
        throw const FormatException(_unsupportedImportMessage);
      }
      final directPath = selection['path']?.toString();
      if (directPath != null &&
          directPath.isNotEmpty &&
          await File(directPath).exists()) {
        return _PickedPortablePackage(
          directPath,
          displayName: displayName,
          ownedTemporaryCopy: false,
          archive: archive,
        );
      }
      final uri = selection['uri']?.toString();
      if (uri == null || uri.isEmpty) {
        throw const FileSystemException('系统文件选择器没有提供可读取的文件');
      }
      final materializedPath = await _androidFileManagerChannel
          .invokeMethod<String>(
            archive
                ? 'materializeArchiveForImport'
                : 'materializeFluentPackForImport',
            {'uri': uri, 'displayName': displayName},
          );
      if (materializedPath == null || materializedPath.isEmpty) {
        throw FileSystemException(
          archive ? '无法读取所选压缩包' : '无法读取所选 .fluentpack 文件',
        );
      }
      return _PickedPortablePackage(
        materializedPath,
        displayName: displayName,
        ownedTemporaryCopy: true,
        archive: archive,
      );
    }

    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: '选择要导入的文件',
      type: FileType.custom,
      allowedExtensions: PortableTransferService.importPickerExtensions,
      allowMultiple: false,
      withReadStream: true,
    );
    if (picked == null) return null;
    final pickedFile = picked.files.single;
    final archive =
        _isArchiveImportName(pickedFile.name) ||
        (pickedFile.path != null && _isArchiveImportName(pickedFile.path!));
    final fluentPack =
        PortableTransferService.hasPackageExtension(pickedFile.name) ||
        (pickedFile.path != null &&
            PortableTransferService.hasPackageExtension(pickedFile.path!));
    if (!fluentPack && !archive) {
      throw const FormatException(_unsupportedImportMessage);
    }
    return _materializePickedPackage(
      pickedFile,
      archive: archive && !fluentPack,
    );
  }

  static bool _isArchiveImportName(String pathOrName) {
    if (PortableTransferService.hasPackageExtension(pathOrName)) return false;
    return LibraryService.isSupportedArchivePath(pathOrName);
  }

  Future<_PickedPortablePackage> _materializePickedPackage(
    PlatformFile picked, {
    required bool archive,
  }) async {
    final pickedPath = picked.path;
    if (pickedPath != null && pickedPath.isNotEmpty) {
      final file = File(pickedPath);
      if (await file.exists()) {
        return _PickedPortablePackage(
          file.path,
          displayName: picked.name,
          ownedTemporaryCopy: false,
          archive: archive,
        );
      }
    }

    final tempRoot = await getTemporaryDirectory();
    final importDirectory = Directory(
      p.join(tempRoot.path, 'fluent_player_portable_imports'),
    );
    await importDirectory.create(recursive: true);
    var fileName = _safeFileName(picked.name);
    if (fileName.isEmpty) {
      fileName = archive
          ? 'import.zip'
          : 'import.${PortableTransferService.extension}';
    }
    final target = File(_nextAvailablePath(importDirectory, fileName));
    final sink = target.openWrite();
    try {
      final stream = picked.readStream;
      if (stream != null) {
        await sink.addStream(stream);
      } else if (picked.bytes != null) {
        sink.add(picked.bytes!);
      } else {
        throw const FileSystemException('系统文件选择器没有提供可读取的文件内容');
      }
      await sink.flush();
      await sink.close();
    } catch (_) {
      await sink.close();
      if (await target.exists()) await target.delete();
      rethrow;
    }
    return _PickedPortablePackage(
      target.path,
      displayName: picked.name,
      ownedTemporaryCopy: true,
      archive: archive,
    );
  }

  static String _nextAvailablePath(Directory directory, String fileName) {
    final extension = p.extension(fileName);
    final stem = p.basenameWithoutExtension(fileName);
    var candidate = p.join(directory.path, fileName);
    var suffix = 2;
    while (File(candidate).existsSync()) {
      candidate = p.join(directory.path, '$stem ($suffix)$extension');
      suffix++;
    }
    return candidate;
  }

  static String _safeFileName(String value) => value
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
      .replaceAll(RegExp(r'[. ]+$'), '');
}

class _PickedPortablePackage {
  final String path;
  final String displayName;
  final bool ownedTemporaryCopy;
  final bool archive;

  const _PickedPortablePackage(
    this.path, {
    required this.displayName,
    required this.ownedTemporaryCopy,
    this.archive = false,
  });

  Future<void> disposeIfOwned() async {
    if (!ownedTemporaryCopy) return;
    final file = File(path);
    if (await file.exists()) {
      try {
        await file.delete();
      } catch (_) {}
    }
  }
}

class _ImportPreviewDialog extends StatefulWidget {
  final PortablePackagePreview preview;
  final String fileName;
  const _ImportPreviewDialog({required this.preview, required this.fileName});

  @override
  State<_ImportPreviewDialog> createState() => _ImportPreviewDialogState();
}

class _ImportPreviewDialogState extends State<_ImportPreviewDialog> {
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleGlobalHardwareKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleGlobalHardwareKeyEvent);
    _focusNode.dispose();
    super.dispose();
  }

  bool _handleGlobalHardwareKeyEvent(KeyEvent event) {
    if (_focusNode.hasFocus) return false;
    return _handleKey(event) != KeyEventResult.ignored;
  }

  KeyEventResult _handleKey(KeyEvent event) {
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (hasBlockingKeyboardModifier()) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      Navigator.pop(context, false);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      Navigator.pop(context, true);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final inheritedTheme = Theme.of(context);
    final preview = widget.preview;
    final fileName = widget.fileName;
    return Theme(
      data: inheritedTheme.copyWith(
        textTheme: inheritedTheme.textTheme.apply(fontFamily: 'Noto Sans SC'),
        primaryTextTheme: inheritedTheme.primaryTextTheme.apply(
          fontFamily: 'Noto Sans SC',
        ),
      ),
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: (node, event) => _handleKey(event),
        child: AlertDialog(
          icon: const Icon(Icons.inventory_2_outlined, size: 34),
          title: Text(
            preview.packageName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(fileName, style: const TextStyle(color: Colors.white54)),
              const SizedBox(height: 18),
              _PreviewRow(
                icon: Icons.movie_outlined,
                label: '媒体',
                value: '${preview.mediaCount} 个',
              ),
              _PreviewRow(
                icon: Icons.folder_outlined,
                label: '文件夹',
                value: '${preview.folderCount} 个',
              ),
              _PreviewRow(
                icon: Icons.data_usage_rounded,
                label: '原始大小',
                value: _prettyBytes(preview.totalBytes),
              ),
              _PreviewRow(
                icon: preview.hasChecksums
                    ? Icons.verified_user_outlined
                    : Icons.gpp_maybe_outlined,
                label: '完整性清单',
                value: preview.hasChecksums ? '有' : '无',
              ),
              const SizedBox(height: 10),
              const Text(
                '内容将复制到应用管理目录，原文件不会被修改。',
                style: TextStyle(color: Colors.white60, height: 1.4),
              ),
            ],
          ),
          actions: [
            DesktopButtonClickRegion(
              child: TextButton(
                onPressed: AppHaptics.wrap(
                  () => Navigator.pop(context, false),
                  light: true,
                ),
                child: Text(shortcutHintLabel(context, '取消', 'Esc')),
              ),
            ),
            DesktopButtonClickRegion(
              child: FilledButton(
                onPressed: AppHaptics.wrap(
                  () => Navigator.pop(context, true),
                  light: true,
                ),
                child: Text(shortcutHintLabel(context, '开始导入', 'Enter')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ArchiveImportPreviewDialog extends StatefulWidget {
  final String title;
  final String fileName;
  final int sizeBytes;

  const _ArchiveImportPreviewDialog({
    required this.title,
    required this.fileName,
    required this.sizeBytes,
  });

  @override
  State<_ArchiveImportPreviewDialog> createState() =>
      _ArchiveImportPreviewDialogState();
}

class _ArchiveImportPreviewDialogState
    extends State<_ArchiveImportPreviewDialog> {
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleGlobalHardwareKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleGlobalHardwareKeyEvent);
    _focusNode.dispose();
    super.dispose();
  }

  bool _handleGlobalHardwareKeyEvent(KeyEvent event) {
    if (_focusNode.hasFocus) return false;
    return _handleKey(event) != KeyEventResult.ignored;
  }

  KeyEventResult _handleKey(KeyEvent event) {
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (hasBlockingKeyboardModifier()) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      Navigator.pop(context, false);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      Navigator.pop(context, true);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String _archiveSuffixLabel(String name) {
    final lower = name.toLowerCase();
    const suffixes = <String>[
      '.tar.gz',
      '.tar.bz2',
      '.tar.xz',
      '.tbz2',
      '.tgz',
      '.tbz',
      '.txz',
      '.zip',
      '.tar',
    ];
    for (final suffix in suffixes) {
      if (lower.endsWith(suffix)) return suffix;
    }
    final extension = p.extension(name);
    return extension.isEmpty ? '压缩包' : extension;
  }

  @override
  Widget build(BuildContext context) {
    final inheritedTheme = Theme.of(context);
    return Theme(
      data: inheritedTheme.copyWith(
        textTheme: inheritedTheme.textTheme.apply(fontFamily: 'Noto Sans SC'),
        primaryTextTheme: inheritedTheme.primaryTextTheme.apply(
          fontFamily: 'Noto Sans SC',
        ),
      ),
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: (node, event) => _handleKey(event),
        child: AlertDialog(
          icon: const Icon(Icons.folder_zip_outlined, size: 34),
          title: Text(
            widget.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.fileName,
                style: const TextStyle(color: Colors.white54),
              ),
              const SizedBox(height: 18),
              _PreviewRow(
                icon: Icons.inventory_2_outlined,
                label: '压缩包',
                value: _archiveSuffixLabel(widget.fileName),
              ),
              _PreviewRow(
                icon: Icons.data_usage_rounded,
                label: '文件大小',
                value: widget.sizeBytes > 0
                    ? _prettyBytes(widget.sizeBytes)
                    : '未知',
              ),
              const SizedBox(height: 10),
              const Text(
                '确认后会解压压缩包，并把里面的媒体写入媒体库。原文件不会被修改。',
                style: TextStyle(color: Colors.white60, height: 1.4),
              ),
            ],
          ),
          actions: [
            DesktopButtonClickRegion(
              child: TextButton(
                onPressed: AppHaptics.wrap(
                  () => Navigator.pop(context, false),
                  light: true,
                ),
                child: Text(shortcutHintLabel(context, '取消', 'Esc')),
              ),
            ),
            DesktopButtonClickRegion(
              child: FilledButton(
                onPressed: AppHaptics.wrap(
                  () => Navigator.pop(context, true),
                  light: true,
                ),
                child: Text(shortcutHintLabel(context, '开始导入', 'Enter')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _PreviewRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        Icon(icon, size: 18, color: const Color(0xFFAEB8FF)),
        const SizedBox(width: 10),
        Expanded(child: Text(label)),
        Text(value, style: const TextStyle(color: Colors.white70)),
      ],
    ),
  );
}

class _EmptyTransferState extends StatelessWidget {
  final PortableTransferKind kind;
  final VoidCallback onPressed;
  const _EmptyTransferState({
    super.key,
    required this.kind,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final exporting = kind == PortableTransferKind.export;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 92,
              height: 92,
              decoration: BoxDecoration(
                color: const Color(0xFF202431),
                borderRadius: BorderRadius.circular(28),
              ),
              child: Icon(
                exporting
                    ? Icons.move_to_inbox_outlined
                    : Icons.unarchive_outlined,
                size: 42,
                color: const Color(0xFFAEB8FF),
              ),
            ),
            const SizedBox(height: 22),
            Text(
              exporting ? '把喜欢的东西打成一包' : '把熟悉的东西搬回来',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              exporting
                  ? '选择媒体和文件夹，再决定导出为 .fluentpack 或 .zip。'
                  : '接受 .fluentpack，以及 .zip、.tar、.tar.gz、.tar.bz2、.tar.xz，选择后会先确认再导入。',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, height: 1.5),
            ),
            const SizedBox(height: 24),
            DesktopButtonClickRegion(
              child: FilledButton.icon(
                onPressed: AppHaptics.wrap(onPressed, light: true),
                icon: Icon(
                  exporting ? Icons.add_rounded : Icons.file_open_outlined,
                ),
                label: StableWidthLabel(
                  shortcutHintLabel(context, exporting ? '新建导出' : '选择文件', 'N'),
                  variants: [
                    shortcutHintLabel(context, '新建导出', 'N'),
                    shortcutHintLabel(context, '选择文件', 'N'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _TaskAction { select, retry, delete }

class _TransferTaskCard extends StatelessWidget {
  final PortableTransferTask task;
  final bool isDesktop;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onCancel;
  final ValueChanged<BuildContext> onMore;
  final VoidCallback onToggleSelection;
  final VoidCallback onLongPress;
  final VoidCallback onOpen;
  final VoidCallback onReveal;
  final VoidCallback onShare;

  const _TransferTaskCard({
    required this.task,
    required this.isDesktop,
    required this.selectionMode,
    required this.selected,
    required this.onCancel,
    required this.onMore,
    required this.onToggleSelection,
    required this.onLongPress,
    required this.onOpen,
    required this.onReveal,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    final accent = switch (task.status) {
      PortableTransferStatus.completed => const Color(0xFF70D8A4),
      PortableTransferStatus.failed => const Color(0xFFFF8490),
      PortableTransferStatus.cancelled => Colors.white38,
      _ => const Color(0xFF9CA9FF),
    };
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(17),
        onTap: AppHaptics.wrap(
          selectionMode && !task.isActive ? onToggleSelection : null,
        ),
        onLongPress: task.isActive ? null : onLongPress,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF242838) : const Color(0xFF181A21),
            borderRadius: BorderRadius.circular(17),
            border: Border.all(
              color: selected
                  ? const Color(0xFF9CA9FF).withValues(alpha: 0.72)
                  : Colors.white.withValues(alpha: 0.055),
              width: selected ? 1.4 : 1,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(17),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(15, 15, 10, 11),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(13),
                        ),
                        child: Icon(
                          task.kind == PortableTransferKind.export
                              ? Icons.outbox_outlined
                              : Icons.move_to_inbox_outlined,
                          color: accent,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              task.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              task.error == null
                                  ? task.subtitle
                                  : '${task.subtitle} · ${task.error}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color:
                                    task.status == PortableTransferStatus.failed
                                    ? accent
                                    : Colors.white54,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (selectionMode && !task.isActive)
                        Checkbox(
                          value: selected,
                          onChanged: AppHaptics.wrapValue(
                            (_) => onToggleSelection(),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(5),
                          ),
                        )
                      else if (task.isActive &&
                          (task.kind == PortableTransferKind.export ||
                              task.progress < 0.4))
                        DesktopButtonClickRegion(
                          child: IconButton(
                            onPressed: AppHaptics.wrap(onCancel, light: true),
                            tooltip: '取消',
                            icon: const Icon(Icons.close_rounded, size: 20),
                          ),
                        )
                      else if (task.isActive)
                        const SizedBox(
                          width: 48,
                          height: 48,
                          child: Center(
                            child: SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        )
                      else
                        Builder(
                          builder: (anchor) => DesktopButtonClickRegion(
                            child: IconButton(
                              onPressed: AppHaptics.wrap(
                                () => onMore(anchor),
                                light: true,
                              ),
                              tooltip: '更多操作',
                              icon: const Icon(Icons.more_horiz_rounded),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (task.isActive)
                  LinearProgressIndicator(
                    minHeight: 3,
                    value: task.status == PortableTransferStatus.preparing
                        ? null
                        : task.progress.clamp(0, 1),
                    color: accent,
                    backgroundColor: Colors.white10,
                  )
                else if (task.status == PortableTransferStatus.completed)
                  Container(height: 3, color: accent)
                else
                  const SizedBox(height: 3),
                if (!selectionMode && !task.isActive && task.canOpen)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
                    child: Row(
                      children: [
                        if (isDesktop)
                          DesktopButtonClickRegion(
                            child: TextButton.icon(
                              onPressed: AppHaptics.wrap(
                                onReveal,
                                light: true,
                              ),
                              icon: const Icon(
                                Icons.folder_open_outlined,
                                size: 17,
                              ),
                              label: const Text('在文件管理器中选中'),
                            ),
                          )
                        else
                          DesktopButtonClickRegion(
                            child: TextButton.icon(
                              onPressed: AppHaptics.wrap(
                                onShare,
                                light: true,
                              ),
                              icon: const Icon(
                                Icons.ios_share_rounded,
                                size: 17,
                              ),
                              label: const Text('分享'),
                            ),
                          ),
                        const Spacer(),
                        DesktopButtonClickRegion(
                          child: TextButton.icon(
                            onPressed: AppHaptics.wrap(
                              onOpen,
                              light: true,
                            ),
                            icon: const Icon(
                              Icons.open_in_new_rounded,
                              size: 17,
                            ),
                            label: Text(isDesktop ? '打开' : '其他应用'),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TaskManagementBar extends StatelessWidget {
  final int selectedCount;
  final VoidCallback? onDelete;

  const _TaskManagementBar({
    required this.selectedCount,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: const BoxDecoration(
        color: Color(0xFF181A21),
        border: Border(top: BorderSide(color: Colors.white10)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              selectedCount == 0 ? '点按任务进行选择' : '已选择 $selectedCount 项',
              style: const TextStyle(color: Colors.white70),
            ),
          ),
          DesktopButtonClickRegion(
            child: FilledButton.icon(
              onPressed: AppHaptics.wrap(onDelete, light: true),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFD9515D),
                disabledBackgroundColor: Colors.white10,
              ),
              icon: const Icon(Icons.delete_outline_rounded, size: 19),
              label: Text(shortcutHintLabel(context, '删除', 'R')),
            ),
          ),
        ],
      ),
    ),
  );
}

String _prettyBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}
