import 'package:video_player_app/widgets/dialog_keyboard_viewport.dart';
import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../models/batch_subtitle_task_view.dart';
import '../models/subtitle_output_path_strategy.dart';
import '../models/transcription_status.dart';
import '../models/video_picker_tree_node.dart';
import '../features/cloud_drive/services/cloud_drive_runtime.dart';
import '../services/transcription_media_selection.dart';
import '../services/playback_navigation_service.dart';
import '../services/transcription_manager.dart';
import '../widgets/transcription_restart_dialog.dart';
import '../services/settings_service.dart';
import '../services/library_service.dart';
import '../services/subtitle_translate_settings.dart';
import '../utils/reveal_in_file_manager.dart';
import '../utils/android_hardware_input_bridge.dart';
import '../utils/batch_tool_shortcuts.dart';
import '../utils/hardware_keyboard_shortcuts.dart';
import '../utils/media_folder_scanner.dart';
import '../utils/page_shortcut_keys.dart';
import '../widgets/internal_video_picker_dialog.dart';
import '../widgets/task_queue_table.dart';
import '../widgets/batch_subtitle_configuration_bar.dart';
import '../widgets/model_center_button.dart';
import '../widgets/operation_status.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

class BatchSubtitleScreen extends StatefulWidget {
  final String? collectionId;
  final TranscriptionMediaSelection? initialSelection;
  final CloudDriveRuntime? cloudRuntime;

  const BatchSubtitleScreen({
    super.key,
    this.collectionId,
    this.initialSelection,
    this.cloudRuntime,
  });

  @override
  State<BatchSubtitleScreen> createState() => _BatchSubtitleScreenState();
}

class _BatchSubtitleScreenState extends State<BatchSubtitleScreen> {
  String? _noticeTitle;
  String? _noticeDetails;
  bool _noticeIsError = false;
  VoidCallback? _noticeRetry;
  String? _noticePath;
  bool _importing = false;
  bool _scanning = false;
  TranscriptionMediaResolver? _selectionResolver;
  final FocusNode _shortcutFocusNode = FocusNode();
  final AndroidHardwareKeyDeduplicator _androidKeyDeduplicator =
      AndroidHardwareKeyDeduplicator();

  @override
  void initState() {
    super.initState();
    AndroidHardwareInputBridge.addKeyListener(_handleAndroidHardwareKeyEvent);
    HardwareKeyboard.instance.addHandler(_handleGlobalHardwareKeyEvent);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.initialSelection case final selection?) {
        unawaited(_importSelection(selection));
      }
      if (supportsNativeHardwareKeyboardShortcuts && mounted) {
        _shortcutFocusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _selectionResolver?.cancel();
    AndroidHardwareInputBridge.removeKeyListener(
      _handleAndroidHardwareKeyEvent,
    );
    HardwareKeyboard.instance.removeHandler(_handleGlobalHardwareKeyEvent);
    _shortcutFocusNode.dispose();
    super.dispose();
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

  String _bsTooltip(String label, BatchSubtitleShortcutAction action) {
    return hoverAwareShortcutTooltip(
      label,
      BatchSubtitleShortcuts.defaults[action]!,
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
    final BatchSubtitleShortcutAction? action =
        BatchSubtitleShortcuts.matchAction(event.logicalKey);
    final platform = currentNativeTargetPlatform;
    if (action == null ||
        platform == null ||
        !BatchSubtitleShortcuts.isAvailableOnPlatform(action, platform)) {
      return KeyEventResult.ignored;
    }
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    final manager = context.read<TranscriptionManager>();
    final settings = context.read<SettingsService>();
    switch (action) {
      case BatchSubtitleShortcutAction.back:
        Navigator.of(context).maybePop();
        return KeyEventResult.handled;
      case BatchSubtitleShortcutAction.addVideos:
        _showInternalVideoPicker(context);
        return KeyEventResult.handled;
      case BatchSubtitleShortcutAction.pickExternal:
        unawaited(_pickExternalFiles(context));
        return KeyEventResult.handled;
      case BatchSubtitleShortcutAction.toggleAll:
        _toggleBatch(manager);
        return KeyEventResult.handled;
      case BatchSubtitleShortcutAction.toggleAutoRemove:
        settings.updateBatchSubtitleAutoDelete(
          !settings.batchSubtitleAutoDelete,
        );
        return KeyEventResult.handled;
      case BatchSubtitleShortcutAction.openSettings:
        _showBatchSettingsSheet(context);
        return KeyEventResult.handled;
      case BatchSubtitleShortcutAction.clearCompleted:
        _clearCompleted(manager);
        return KeyEventResult.handled;
    }
  }

  void _showImportNotice(
    String message, {
    bool isError = true,
    VoidCallback? retry,
    String? path,
    String? details,
  }) {
    if (!mounted) return;
    setState(() {
      _noticeTitle = message;
      _noticeDetails = details;
      _noticeIsError = isError;
      _noticeRetry = retry;
      _noticePath = path;
    });
  }

  Future<void> _addMediaToQueue(
    List<
      ({String label, Future<TranscriptionEnqueueResult> Function() enqueue})
    >
    requests, {
    List<String> preparationFailures = const [],
    VoidCallback? retryPreparation,
  }) async {
    if (_importing || (requests.isEmpty && preparationFailures.isEmpty)) return;
    setState(() {
      _importing = true;
      _noticeTitle = '正在添加转录任务 · 0 / ${requests.length}';
      _noticeDetails = null;
      _noticeIsError = false;
      _noticeRetry = null;
      _noticePath = null;
    });
    var added = 0, existing = 0, processed = 0;
    final failures = <String>[...preparationFailures];
    final failedRequests =
        <
          ({
            String label,
            Future<TranscriptionEnqueueResult> Function() enqueue,
          })
        >[];
    try {
      for (final request in requests) {
        try {
          final result = await request.enqueue();
          if (result == TranscriptionEnqueueResult.added) {
            added++;
          } else {
            existing++;
          }
        } catch (error) {
          failures.add('${request.label}：${safeOperationDiagnostic(error)}');
          failedRequests.add(request);
        }
        processed++;
        if (mounted) {
          setState(() {
            _noticeTitle = '正在添加转录任务 · $processed / ${requests.length}';
          });
        }
      }
      if (failures.isNotEmpty) {
        _showImportNotice(
          '新增 $added 项，已存在 $existing 项，添加失败 ${failures.length} 项',
          details: failures.join('\n'),
          retry: () {
            if (retryPreparation != null) {
              retryPreparation();
            } else {
              unawaited(_addMediaToQueue(failedRequests));
            }
          },
        );
      } else if (mounted) {
        setState(() => _noticeTitle = existing > 0 ? '已存在 $existing 项' : null);
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _importSelection(TranscriptionMediaSelection selection) async {
    if (_importing || _scanning) return;
    final resolver = _selectionResolver = TranscriptionMediaResolver(
      library: context.read<LibraryService>(),
      manager: context.read<TranscriptionManager>(),
      cloudRuntime: widget.cloudRuntime,
    );
    setState(() => _scanning = true);
    _showImportNotice('正在读取所选媒体…', isError: false);
    try {
      await resolver.resolve(selection);
      if (!mounted || resolver.cancelled) return;
      await resolver.source.prepareSelection(resolver.nodes);
      if (!mounted || resolver.cancelled) return;
      if (resolver.nodes.isEmpty && resolver.failures.isEmpty) {
        _showImportNotice('所选内容中没有可转录的媒体', isError: false);
        return;
      }
      await _addInternalMediaToQueue(
        resolver.nodes,
        preparationFailures: [
          for (final failure in resolver.failures)
            '${failure.label}：${safeOperationDiagnostic(failure.error)}',
        ],
        retryPreparation: () => unawaited(_importSelection(selection)),
      );
    } catch (error) {
      _showImportNotice(
        '添加媒体失败，请重试',
        details: safeOperationDiagnostic(error),
        retry: () => unawaited(_importSelection(selection)),
      );
    } finally {
      if (identical(_selectionResolver, resolver)) _selectionResolver = null;
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _addInternalMediaToQueue(
    List<VideoPickerTreeNode> nodes, {
    List<String> preparationFailures = const [],
    VoidCallback? retryPreparation,
  }) {
    final library = context.read<LibraryService>();
    final manager = context.read<TranscriptionManager>();
    final autoCache = context.read<SettingsService>().autoCacheSubtitles;
    return _addMediaToQueue(
      [
        for (final node in nodes)
          if (node.videoPath != null)
            (
              label: node.name,
              enqueue: () => manager.startTranscription(
                node.videoPath!,
                videoId: node.videoId,
                videoTitle: node.name,
                videoDuration: node.videoDuration,
                sourceItem: node.mediaItem,
                libraryService: library,
                autoCache: autoCache,
              ),
            ),
      ],
      preparationFailures: preparationFailures,
      retryPreparation: retryPreparation,
    );
  }

  @override
  Widget build(BuildContext context) {
    final metrics = _BatchLayoutMetrics.fromSize(MediaQuery.sizeOf(context));
    // 页面级主题：批量字幕页所有文本（含弹窗/菜单/底部面板，经由
    // capturedThemes 一并继承）统一使用思源黑体。
    return Theme(
      data: _sourceHanSansTheme(context),
      child: Focus(
        focusNode: _shortcutFocusNode,
        autofocus: supportsNativeHardwareKeyboardShortcuts,
        onKeyEvent: (node, event) => _handleShortcutKeyEvent(event),
        child: Scaffold(
          appBar: AppBar(
            title: const Text('语音转录队列'),
            centerTitle: metrics.isCompact,
            toolbarHeight: metrics.isCompact ? 44 : 56,
            actions: [
              ModelCenterButton(
                compact: metrics.isCompact,
                service: context.read<TranscriptionManager>().modelCenter,
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Consumer<TranscriptionManager>(
              builder: (context, manager, _) {
                final library = context.read<LibraryService>();
                final tasks = manager.getQueueSnapshot().map((task) {
                  if (task.isExternal || task.videoId == null) return task;
                  final item = library.getVideo(task.videoId!);
                  if (item == null || item.title.trim().isEmpty) return task;
                  return task.copyWith(videoName: item.title.trim());
                }).toList();
                final settings = context.watch<SettingsService>();
                return Column(
                  children: [
                    _buildTopBar(context, metrics, manager),
                    BatchSubtitleConfigurationBar(
                      settings: settings,
                      modelCenter: manager.modelCenter,
                      translateSettings: lookupSubtitleTranslateSettings(
                        context,
                      ),
                      horizontalPadding: metrics.horizontalPadding,
                    ),
                    _buildCustomOutputDirBar(context, settings, metrics),
                    if (tasks.isNotEmpty || _noticeTitle != null)
                      _buildQueueStatusBar(
                        context,
                        metrics,
                        manager.processingCount,
                        manager.queuedCount,
                        manager.pendingCount,
                      ),
                    Expanded(
                      child: TaskQueueTable(
                        tasks: tasks,
                        autoDeletedKeys: manager.pendingCompletedRemovals,
                        onStart: (mediaKey) =>
                            unawaited(_startTask(manager, mediaKey)),
                        onPause: (mediaKey) {
                          manager.pauseTask(mediaKey);
                        },
                        onRetry: (mediaKey) =>
                            unawaited(_retryTask(manager, mediaKey)),
                        onRestart: (mediaKey) =>
                            unawaited(_restartTask(manager, mediaKey)),
                        onDelete: (mediaKey) => _deleteTask(manager, mediaKey),
                        onReorder: (mediaKey, newIndex) =>
                            manager.reorderTask(mediaKey, newIndex),
                        onTapCompleted: (task) =>
                            _onTapCompletedTask(context, task),
                        onConfigure: () => _showBatchSettingsSheet(context),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// 思源黑体主题：在应用主题基础上将全部文本字体统一替换为思源黑体
  /// （Noto Sans SC，即思源黑体的 Google 命名）。
  ThemeData _sourceHanSansTheme(BuildContext context) {
    const fontFamily = 'Noto Sans SC';
    final base = Theme.of(context);
    return base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: fontFamily),
    );
  }

  Widget _buildTopBar(
    BuildContext context,
    _BatchLayoutMetrics metrics,
    TranscriptionManager manager,
  ) {
    final settings = context.watch<SettingsService>();
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: metrics.horizontalPadding,
        vertical: metrics.isCompact ? 0 : 9,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(color: theme.dividerColor, width: 0.5),
        ),
      ),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: metrics.isCompact
            ? _buildCompactToolbar(context, settings, manager, metrics)
            : metrics.isTablet
            ? _buildTabletToolbar(context, settings, manager, metrics)
            : _buildExpandedToolbar(context, settings, manager, metrics),
      ),
    );
  }

  Widget _buildCompactToolbar(
    BuildContext context,
    SettingsService settings,
    TranscriptionManager manager,
    _BatchLayoutMetrics metrics,
  ) {
    return Row(
      children: [
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: _buildCompactAction(
                  context: context,
                  label: '添加媒体',
                  tooltip: _bsTooltip(
                    '添加媒体',
                    BatchSubtitleShortcutAction.addVideos,
                  ),
                  icon: Icons.add_rounded,
                  color: Theme.of(context).colorScheme.primary,
                  onPressed: () => _showInternalVideoPicker(context),
                ),
              ),
              const SizedBox(width: 4),
              Flexible(
                child: _buildCompactAction(
                  context: context,
                  label: manager.canPauseAll ? '暂停全部' : '开始全部',
                  tooltip: _bsTooltip(
                    manager.canPauseAll ? '暂停全部' : '开始全部',
                    BatchSubtitleShortcutAction.toggleAll,
                  ),
                  icon: manager.canPauseAll
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  color: Theme.of(context).colorScheme.onSurface,
                  onPressed: () => _toggleBatch(manager),
                ),
              ),
              const SizedBox(width: 4),
              Flexible(child: _buildKeepAwakeSetting(context, settings)),
            ],
          ),
        ),
        const SizedBox(width: 4),
        _buildCompactMoreMenu(context, settings, manager, metrics),
      ],
    );
  }

  Widget _buildCompactMoreMenu(
    BuildContext context,
    SettingsService settings,
    TranscriptionManager manager,
    _BatchLayoutMetrics metrics,
  ) {
    final theme = Theme.of(context);
    return PopupMenuButton<_BatchOverflowAction>(
      key: const ValueKey('batch-toolbar-more'),
      padding: EdgeInsets.zero,
      menuPadding: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      tooltip: '更多操作',
      position: PopupMenuPosition.under,
      onSelected: (action) {
        switch (action) {
          case _BatchOverflowAction.toggleAutoRemove:
            settings.updateBatchSubtitleAutoDelete(
              !settings.batchSubtitleAutoDelete,
            );
            break;
          case _BatchOverflowAction.pickExternal:
            _pickExternalFiles(context);
            break;
          case _BatchOverflowAction.settings:
            _showBatchSettingsSheet(context);
            break;
          case _BatchOverflowAction.clearCompleted:
            _clearCompleted(manager);
            break;
          case _BatchOverflowAction.clearAll:
            _showClearAllConfirm(context, manager);
            break;
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          height: 44,
          value: _BatchOverflowAction.toggleAutoRemove,
          child: Semantics(
            checked: settings.batchSubtitleAutoDelete,
            child: _PopupMenuLabel(
              icon: settings.batchSubtitleAutoDelete
                  ? Icons.check_box_outlined
                  : Icons.check_box_outline_blank,
              label: '完成后自动移除',
            ),
          ),
        ),
        const PopupMenuDivider(height: 8),
        if (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
          PopupMenuItem(
            height: 44,
            value: _BatchOverflowAction.pickExternal,
            child: _PopupMenuLabel(
              icon: Icons.folder_open_outlined,
              label: '选择外部文件',
            ),
          ),
        if (metrics.isDesktopPlatform)
          PopupMenuItem(
            height: 44,
            value: _BatchOverflowAction.settings,
            child: _PopupMenuLabel(icon: Icons.tune_rounded, label: '外部视频设置'),
          ),
        PopupMenuItem(
          height: 44,
          value: _BatchOverflowAction.clearCompleted,
          child: _PopupMenuLabel(
            icon: Icons.cleaning_services_outlined,
            label: '清除已完成',
          ),
        ),
        PopupMenuItem(
          height: 44,
          value: _BatchOverflowAction.clearAll,
          child: _PopupMenuLabel(
            icon: Icons.delete_sweep_outlined,
            label: '清除全部',
            color: theme.colorScheme.error,
          ),
        ),
      ],
      icon: Icon(
        Icons.more_horiz_rounded,
        size: 22,
        color: theme.colorScheme.onSurface,
      ),
      style: IconButton.styleFrom(
        fixedSize: const Size(44, 44),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  Widget _buildTabletToolbar(
    BuildContext context,
    SettingsService settings,
    TranscriptionManager manager,
    _BatchLayoutMetrics metrics,
  ) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: metrics.gap,
          runSpacing: 7,
          children: [
            _buildActionButton(
              context: context,
              label: '选择内部媒体',
              tooltip: _bsTooltip(
                '选择内部媒体',
                BatchSubtitleShortcutAction.addVideos,
              ),
              icon: Icons.video_library_outlined,
              height: metrics.buttonHeight,
              fontSize: metrics.fontSize,
              onPressed: () => _showInternalVideoPicker(context),
            ),
            if (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
              _buildActionButton(
                context: context,
                label: '选择外部文件',
                tooltip: _bsTooltip(
                  '选择外部文件',
                  BatchSubtitleShortcutAction.pickExternal,
                ),
                icon: Icons.folder_open_outlined,
                height: metrics.buttonHeight,
                fontSize: metrics.fontSize,
                onPressed: () => _pickExternalFiles(context),
              ),
            _buildActionButton(
              context: context,
              label: manager.canPauseAll ? '暂停全部' : '开始全部',
              tooltip: _bsTooltip(
                manager.canPauseAll ? '暂停全部' : '开始全部',
                BatchSubtitleShortcutAction.toggleAll,
              ),
              icon: manager.canPauseAll
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
              height: metrics.buttonHeight,
              fontSize: metrics.fontSize,
              color: manager.canPauseAll
                  ? Colors.orange.shade800
                  : theme.colorScheme.primary,
              onPressed: () => _toggleBatch(manager),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _buildSettingsRow(
          context,
          settings,
          metrics,
          showExternalSettings: metrics.isDesktopPlatform,
          onClearCompleted: () => _clearCompleted(manager),
          onClearAll: () => _showClearAllConfirm(context, manager),
        ),
      ],
    );
  }

  Widget _buildExpandedToolbar(
    BuildContext context,
    SettingsService settings,
    TranscriptionManager manager,
    _BatchLayoutMetrics metrics,
  ) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final useSingleRow =
            constraints.maxWidth >= 1440 && metrics.isDesktopPlatform;
        final actions = <Widget>[
          _buildActionButton(
            context: context,
            label: '选择内部媒体',
            tooltip: _bsTooltip(
              '选择内部媒体',
              BatchSubtitleShortcutAction.addVideos,
            ),
            icon: Icons.video_library_outlined,
            height: metrics.buttonHeight,
            fontSize: metrics.fontSize,
            onPressed: () => _showInternalVideoPicker(context),
          ),
          if (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
            _buildActionButton(
              context: context,
              label: '选择外部文件',
              tooltip: _bsTooltip(
                '选择外部文件',
                BatchSubtitleShortcutAction.pickExternal,
              ),
              icon: Icons.folder_open_outlined,
              height: metrics.buttonHeight,
              fontSize: metrics.fontSize,
              onPressed: () => _pickExternalFiles(context),
            ),
          _buildActionButton(
            context: context,
            label: manager.canPauseAll ? '全部暂停' : '全部开始',
            tooltip: _bsTooltip(
              manager.canPauseAll ? '全部暂停' : '全部开始',
              BatchSubtitleShortcutAction.toggleAll,
            ),
            icon: manager.canPauseAll
                ? Icons.pause_rounded
                : Icons.play_arrow_rounded,
            height: metrics.buttonHeight,
            fontSize: metrics.fontSize,
            color: manager.canPauseAll
                ? Colors.orange.shade800
                : theme.colorScheme.primary,
            onPressed: () => _toggleBatch(manager),
          ),
        ];

        if (useSingleRow) {
          return Row(
            children: [
              ..._withSpacing(actions, metrics.gap),
              const Spacer(),
              _buildSettingsRow(
                context,
                settings,
                metrics,
                showExternalSettings: true,
                onClearCompleted: () => _clearCompleted(manager),
                onClearAll: () => _showClearAllConfirm(context, manager),
              ),
            ],
          );
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                ..._withSpacing(actions, metrics.gap),
                const Spacer(),
                if (!metrics.isDesktopPlatform)
                  _buildSettingsRow(
                    context,
                    settings,
                    metrics,
                    showExternalSettings: false,
                    onClearCompleted: () => _clearCompleted(manager),
                    onClearAll: () => _showClearAllConfirm(context, manager),
                  ),
              ],
            ),
            if (metrics.isDesktopPlatform) ...[
              const SizedBox(height: 7),
              Align(
                alignment: Alignment.centerRight,
                child: _buildSettingsRow(
                  context,
                  settings,
                  metrics,
                  showExternalSettings: true,
                  onClearCompleted: () => _clearCompleted(manager),
                  onClearAll: () => _showClearAllConfirm(context, manager),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  List<Widget> _withSpacing(List<Widget> children, double spacing) {
    return [
      for (var index = 0; index < children.length; index++) ...[
        if (index > 0) SizedBox(width: spacing),
        children[index],
      ],
    ];
  }

  /// 自定义输出目录提示条（仅当输出策略为「指定目录」且有路径时显示）
  Widget _buildCustomOutputDirBar(
    BuildContext context,
    SettingsService settings,
    _BatchLayoutMetrics metrics,
  ) {
    final isCustom =
        settings.batchSubtitleOutputPathStrategy ==
        SubtitleOutputPathStrategy.customDirectory;
    final dir = settings.batchSubtitleCustomOutputDir;
    if (!isCustom || dir == null || dir.isEmpty) {
      return const SizedBox.shrink();
    }

    if (!metrics.isDesktopPlatform) return const SizedBox.shrink();

    final fontSize = (metrics.shortestSide * 0.021).clamp(10.5, 12.5);
    final padding = (metrics.shortestSide * 0.012).clamp(6.0, 9.0);

    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: padding * 1.6,
        vertical: padding * 0.5,
      ),
      color: Colors.blueGrey.withValues(alpha: 0.08),
      child: Row(
        children: [
          Icon(
            Icons.folder_outlined,
            size: fontSize + 2,
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.7),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '外部输出: $dir',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: fontSize,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.65),
              ),
            ),
          ),
          if (metrics.isDesktopPlatform) ...[
            const SizedBox(width: 8),
            Tooltip(
              message: '打开文件夹',
              child: SizedBox(
                width: fontSize + 12,
                height: fontSize + 12,
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(4),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: () => _openDirectoryInExplorer(dir),
                    child: Icon(
                      Icons.open_in_new,
                      size: fontSize + 2,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 桌面端用文件管理器打开指定文件夹
  Future<void> _openDirectoryInExplorer(String dirPath) async {
    try {
      if (!await Directory(dirPath).exists()) {
        throw FileSystemException(
          '输出文件夹不存在',
          dirPath,
          const OSError('not found', 2),
        );
      }
      if (!await revealInFileManager(dirPath) && mounted) {
        await _showLocationFailure(dirPath);
      }
    } catch (error) {
      if (mounted) await _showLocationFailure(dirPath, error: error);
    }
  }

  Future<void> _showLocationFailure(
    String path, {
    Object? error,
    String title = '无法打开输出文件夹',
  }) async {
    _showImportNotice(
      title,
      details: error == null ? null : safeOperationDiagnostic(error),
      path: path,
      retry: () => unawaited(_retryLocation(path)),
    );
  }

  Future<void> _retryLocation(String path) async {
    try {
      if (await revealInFileManager(path)) {
        if (mounted) setState(() => _noticeTitle = null);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _noticeDetails = safeOperationDiagnostic(error));
      }
    }
  }

  Future<void> _showNoticeDetails() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('诊断详情'),
      scrollable: true,
      content: SelectableText(
        _noticeDetails ?? '',
        style: const TextStyle(fontSize: 13),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );

  Widget _buildQueueStatusBar(
    BuildContext context,
    _BatchLayoutMetrics metrics,
    int processingCount,
    int queuedCount,
    int pendingCount,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (pendingCount > 0)
        _buildQueueMetrics(
          context,
          metrics,
          processingCount,
          queuedCount,
          pendingCount,
        ),
      if (_noticeTitle != null)
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: metrics.horizontalPadding,
            vertical: 4,
          ),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              Text(
                _noticeTitle!,
                style: TextStyle(
                  fontSize: 13,
                  color: _noticeIsError
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              if (_noticeRetry != null && !_importing && !_scanning)
                TextButton(onPressed: _noticeRetry, child: const Text('重试')),
              if (_noticePath != null)
                TextButton(
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: _noticePath!)),
                  child: const Text('复制路径'),
                ),
              if (_noticeDetails != null)
                TextButton(
                  onPressed: _showNoticeDetails,
                  child: const Text('诊断详情'),
                ),
            ],
          ),
        ),
    ],
  );

  Widget _buildQueueMetrics(
    BuildContext context,
    _BatchLayoutMetrics metrics,
    int processingCount,
    int queuedCount,
    int pendingCount,
  ) {
    final theme = Theme.of(context);
    final fontSize = metrics.isCompact ? 10.5 : metrics.fontSize;

    if (metrics.isCompact) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.35,
        ),
        child: Row(
          children: [
            Expanded(
              child: _CompactQueueMetric(
                label: '处理中',
                count: processingCount,
                color: theme.colorScheme.primary,
              ),
            ),
            _CompactMetricDivider(color: theme.dividerColor),
            Expanded(
              child: _CompactQueueMetric(
                label: '排队中',
                count: queuedCount,
                color: Colors.orange.shade700,
              ),
            ),
            _CompactMetricDivider(color: theme.dividerColor),
            Expanded(
              child: _CompactQueueMetric(
                label: '总任务',
                count: pendingCount,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: metrics.horizontalPadding,
        vertical: metrics.isCompact ? 6 : 7,
      ),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
      child: Row(
        children: [
          Icon(
            Icons.queue_play_next_rounded,
            size: fontSize + 4,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 6),
          if (!metrics.isCompact || metrics.width >= 390)
            Text(
              '语音转录队列',
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
            ),
          const Spacer(),
          _QueueCount(
            label: metrics.isCompact ? '处理' : '处理中',
            count: processingCount,
            color: theme.colorScheme.primary,
            fontSize: fontSize - 0.5,
          ),
          SizedBox(width: metrics.isCompact ? 7 : 14),
          _QueueCount(
            label: '排队',
            count: queuedCount,
            color: Colors.orange.shade700,
            fontSize: fontSize - 0.5,
          ),
          SizedBox(width: metrics.isCompact ? 7 : 14),
          _QueueCount(
            label: '总计',
            count: pendingCount,
            color: theme.colorScheme.onSurfaceVariant,
            fontSize: fontSize - 0.5,
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required BuildContext context,
    required String label,
    String? tooltip,
    required IconData icon,
    required double height,
    required double fontSize,
    Color? color,
    required VoidCallback onPressed,
  }) {
    final theme = Theme.of(context);
    final foreground = color == null
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onPrimary;
    final button = SizedBox(
      height: height,
      child: DesktopButtonClickRegion(
        child: ElevatedButton.icon(
          onPressed: onPressed,
          icon: Icon(icon, size: fontSize + 4),
          label: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w500),
          ),
          style: ElevatedButton.styleFrom(
            elevation: 0,
            foregroundColor: foreground,
            backgroundColor:
                color ??
                theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.55,
                ),
            padding: EdgeInsets.symmetric(horizontal: fontSize * 0.85),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
      ),
    );
    if (tooltip == null || tooltip.isEmpty) return button;
    return Tooltip(message: tooltip, child: button);
  }

  Widget _buildCompactAction({
    required BuildContext context,
    required String label,
    String? tooltip,
    required IconData icon,
    required VoidCallback onPressed,
    Color? color,
    bool filled = false,
  }) {
    final theme = Theme.of(context);
    final foreground = filled
        ? theme.colorScheme.onPrimary
        : color ?? theme.colorScheme.onSurface;
    final action = Material(
      color: filled ? color ?? theme.colorScheme.primary : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 16, color: foreground),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1,
                      fontWeight: FontWeight.w500,
                      color: foreground,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (tooltip == null || tooltip.isEmpty) return action;
    return Tooltip(message: tooltip, child: action);
  }

  Widget _buildSettingsRow(
    BuildContext context,
    SettingsService settings,
    _BatchLayoutMetrics metrics, {
    required bool showExternalSettings,
    VoidCallback? onClearCompleted,
    VoidCallback? onClearAll,
  }) {
    return Wrap(
      spacing: metrics.gap,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _buildAutoDeleteSetting(context, settings, metrics),
        _buildKeepAwakeSetting(context, settings),
        if (showExternalSettings) ...[
          _buildEmbedSoftSubtitleButton(context, settings, metrics),
          _buildOutputStrategyButton(context, settings, metrics),
        ],
        if (onClearCompleted != null && onClearAll != null)
          _buildCleanupMenu(
            context,
            metrics,
            onClearCompleted: onClearCompleted,
            onClearAll: onClearAll,
          ),
      ],
    );
  }

  Widget _buildKeepAwakeSetting(
    BuildContext context,
    SettingsService settings,
  ) {
    final enabled = settings.batchSubtitleKeepScreenAwake;
    return Tooltip(
      message: '仅在字幕任务处理时保持屏幕常亮，暂停或处理结束后自动恢复',
      child: Semantics(
        checked: enabled,
        child: TextButton(
          key: const ValueKey('batch-keep-screen-awake'),
          onPressed: () =>
              settings.updateBatchSubtitleKeepScreenAwake(!enabled),
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 44),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            foregroundColor: enabled
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.onSurfaceVariant,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                enabled
                    ? Icons.check_box_outlined
                    : Icons.check_box_outline_blank,
                size: 18,
              ),
              const SizedBox(width: 4),
              const Flexible(
                child: Text(
                  '保持亮屏',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAutoDeleteSetting(
    BuildContext context,
    SettingsService settings,
    _BatchLayoutMetrics metrics,
  ) {
    final enabled = settings.batchSubtitleAutoDelete;
    final accent = Theme.of(context).colorScheme.primary;
    return Semantics(
      button: true,
      toggled: enabled,
      label: '完成后移除任务',
      child: _buildToolbarSettingCard(
        context: context,
        metrics: metrics,
        width: 160,
        icon: Icons.auto_delete_outlined,
        title: '完成后移除',
        subtitle: enabled ? '已开启' : '已关闭',
        accent: accent,
        active: enabled,
        tooltip: _bsTooltip(
          enabled ? '点击关闭完成后自动移除' : '点击开启完成后自动移除',
          BatchSubtitleShortcutAction.toggleAutoRemove,
        ),
        trailing: Icon(
          enabled ? Icons.check_circle_rounded : Icons.circle_outlined,
          size: 15,
          color: enabled
              ? accent
              : Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        onTap: () => settings.updateBatchSubtitleAutoDelete(!enabled),
      ),
    );
  }

  Widget _buildOutputStrategyButton(
    BuildContext context,
    SettingsService settings,
    _BatchLayoutMetrics metrics,
  ) {
    final theme = Theme.of(context);
    final strategy = settings.batchSubtitleOutputPathStrategy;
    final isCustom = strategy == SubtitleOutputPathStrategy.customDirectory;
    final dir = settings.batchSubtitleCustomOutputDir;
    final folderName = dir == null || dir.trim().isEmpty
        ? null
        : p.basename(p.normalize(dir));
    final subtitle = isCustom
        ? folderName == null || folderName.isEmpty
              ? '指定目录'
              : '指定目录 · $folderName'
        : '视频同目录';

    return CapsulePopupMenuButton<SubtitleOutputPathStrategy>(
      tooltip: _bsTooltip(
        '选择外部视频字幕输出位置',
        BatchSubtitleShortcutAction.openSettings,
      ),
      position: PopupMenuPosition.under,
      onSelected: (value) => _changeOutputStrategy(settings, value),
      itemBuilder: (context) => [
        _buildOutputMenuItem(
          context,
          value: SubtitleOutputPathStrategy.sameAsVideo,
          selected: !isCustom,
          icon: Icons.video_file_outlined,
          title: '与视频同目录',
          subtitle: '字幕保存在原视频所在文件夹',
        ),
        _buildOutputMenuItem(
          context,
          value: SubtitleOutputPathStrategy.customDirectory,
          selected: isCustom,
          icon: Icons.create_new_folder_outlined,
          title: '选择指定目录',
          subtitle: '为外部视频选择统一输出文件夹',
        ),
      ],
      child: _buildToolbarSettingCard(
        context: context,
        metrics: metrics,
        width: 180,
        icon: Icons.folder_copy_outlined,
        title: '字幕输出位置',
        subtitle: subtitle,
        accent: theme.colorScheme.primary,
        active: isCustom,
        trailing: Icon(
          Icons.keyboard_arrow_down_rounded,
          size: 17,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  PopupMenuItem<SubtitleOutputPathStrategy> _buildOutputMenuItem(
    BuildContext context, {
    required SubtitleOutputPathStrategy value,
    required bool selected,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final theme = Theme.of(context);
    return PopupMenuItem<SubtitleOutputPathStrategy>(
      value: value,
      child: SizedBox(
        width: 260,
        child: Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: selected ? theme.colorScheme.primary : null,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 10,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (selected) ...[
              const SizedBox(width: 8),
              Icon(
                Icons.check_rounded,
                size: 18,
                color: theme.colorScheme.primary,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCleanupMenu(
    BuildContext context,
    _BatchLayoutMetrics metrics, {
    required VoidCallback onClearCompleted,
    required VoidCallback onClearAll,
  }) {
    final theme = Theme.of(context);
    return CapsulePopupMenuButton<_BatchOverflowAction>(
      tooltip: '清理任务队列',
      position: PopupMenuPosition.under,
      onSelected: (action) {
        switch (action) {
          case _BatchOverflowAction.clearCompleted:
            onClearCompleted();
            break;
          case _BatchOverflowAction.clearAll:
            onClearAll();
            break;
          case _BatchOverflowAction.pickExternal:
          case _BatchOverflowAction.settings:
          case _BatchOverflowAction.toggleAutoRemove:
            break;
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: _BatchOverflowAction.clearCompleted,
          child: _PopupMenuLabel(icon: Icons.task_alt_rounded, label: '清除已完成'),
        ),
        PopupMenuItem(
          value: _BatchOverflowAction.clearAll,
          child: _PopupMenuLabel(
            icon: Icons.delete_sweep_outlined,
            label: '清除全部任务',
            color: theme.colorScheme.error,
          ),
        ),
      ],
      child: _buildToolbarSettingCard(
        context: context,
        metrics: metrics,
        width: 124,
        icon: Icons.cleaning_services_outlined,
        title: '清理队列',
        subtitle: '已完成 / 全部',
        accent: theme.colorScheme.onSurfaceVariant,
        trailing: Icon(
          Icons.keyboard_arrow_down_rounded,
          size: 17,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildToolbarSettingCard({
    required BuildContext context,
    required _BatchLayoutMetrics metrics,
    required double width,
    required IconData icon,
    required String title,
    required String subtitle,
    required Color accent,
    Widget? trailing,
    VoidCallback? onTap,
    String? tooltip,
    bool active = false,
  }) {
    final theme = Theme.of(context);
    final card = Material(
      color: active
          ? accent.withValues(alpha: 0.1)
          : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.34),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: active
              ? accent.withValues(alpha: 0.48)
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
          width: 0.8,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: width,
          height: metrics.buttonHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9),
            child: Row(
              children: [
                Container(
                  width: 25,
                  height: 25,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: active ? 0.16 : 0.09),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Icon(icon, size: 16, color: accent),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          height: 1.05,
                          fontSize: metrics.fontSize - 1.1,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          // Leave enough line-box space for CJK fallback fonts.
                          // A 1.0 line height clips the bottom of some glyphs on
                          // Windows (notably in the cleanup queue subtitle).
                          height: 1.2,
                          fontSize: metrics.fontSize - 3.2,
                          fontWeight: active
                              ? FontWeight.w500
                              : FontWeight.w400,
                          color: active
                              ? accent
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 5), trailing],
              ],
            ),
          ),
        ),
      ),
    );
    return tooltip == null ? card : Tooltip(message: tooltip, child: card);
  }

  Future<void> _changeOutputStrategy(
    SettingsService settings,
    SubtitleOutputPathStrategy? value,
  ) async {
    if (value == null) return;
    if (value == SubtitleOutputPathStrategy.customDirectory) {
      final dir = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择外部视频字幕输出目录',
      );
      if (dir == null) return;
      await settings.updateBatchSubtitleOutputLocation(
        value,
        customOutputDir: dir,
      );
      return;
    }
    await settings.updateBatchSubtitleOutputLocation(value);
  }

  /// 外部视频内嵌软字幕设置按钮
  Widget _buildEmbedSoftSubtitleButton(
    BuildContext context,
    SettingsService settings,
    _BatchLayoutMetrics metrics,
  ) {
    final theme = Theme.of(context);
    final copyAndEmbed = settings.batchSubtitleEmbedSoftCopyAndEmbed;
    final replaceOriginal = settings.batchSubtitleEmbedSoftDeleteOriginal;
    final enabled = copyAndEmbed || replaceOriginal;
    final status = copyAndEmbed
        ? '已开启 · 复制并内嵌'
        : replaceOriginal
        ? '已开启 · 替换原视频'
        : '未启用 · 点击配置';

    return _buildToolbarSettingCard(
      context: context,
      metrics: metrics,
      width: 190,
      icon: Icons.subtitles_outlined,
      title: '外部视频软字幕内嵌',
      subtitle: status,
      accent: enabled ? Colors.green.shade600 : theme.colorScheme.primary,
      active: enabled,
      tooltip: '配置外部视频软字幕内嵌',
      trailing: Icon(
        Icons.chevron_right_rounded,
        size: 17,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      onTap: () => _showEmbedSoftSubtitleDialog(context, settings),
    );
  }

  void _showBatchSettingsSheet(BuildContext context) {
    final metrics = _BatchLayoutMetrics.fromSize(MediaQuery.sizeOf(context));
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            metrics.horizontalPadding,
            0,
            metrics.horizontalPadding,
            18,
          ),
          child: Consumer<SettingsService>(
            builder: (context, settings, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '外部视频设置',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 14),
                _buildSettingsRow(
                  context,
                  settings,
                  metrics,
                  showExternalSettings: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 外部视频内嵌软字幕设置弹窗
  void _showEmbedSoftSubtitleDialog(
    BuildContext context,
    SettingsService settings,
  ) {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final theme = Theme.of(ctx);
          return DialogKeyboardViewport(
            child: AlertDialog(
              title: Row(
                children: [
                  Icon(Icons.closed_caption, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  const Text('外部视频内嵌软字幕'),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── 复制并内嵌软字幕 ──
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('复制并内嵌软字幕'),
                      subtitle: const Text(
                        '生成新文件，保留原视频',
                        style: TextStyle(fontSize: 12),
                      ),
                      value: settings.batchSubtitleEmbedSoftCopyAndEmbed,
                      onChanged: (v) {
                        settings.updateBatchSubtitleEmbedMode(
                          copyAndEmbed: v,
                          deleteOriginal: v
                              ? false
                              : settings.batchSubtitleEmbedSoftDeleteOriginal,
                        );
                        setDialogState(() {});
                      },
                    ),
                    // ── 内嵌软字幕（删除原视频） ──
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('内嵌软字幕（删除原视频）'),
                      subtitle: const Text(
                        '新视频生成成功后删除原视频',
                        style: TextStyle(fontSize: 12),
                      ),
                      value: settings.batchSubtitleEmbedSoftDeleteOriginal,
                      onChanged: (v) {
                        settings.updateBatchSubtitleEmbedMode(
                          copyAndEmbed: v
                              ? false
                              : settings.batchSubtitleEmbedSoftCopyAndEmbed,
                          deleteOriginal: v,
                        );
                        setDialogState(() {});
                      },
                    ),
                    const Divider(),
                    // ── 前缀设置 ──
                    const Text(
                      '视频命名设置',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        SizedBox(
                          width: 50,
                          child: Switch(
                            value: settings.batchSubtitleEmbedSoftPrefixEnabled,
                            onChanged: (v) {
                              settings
                                  .updateBatchSubtitleEmbedSoftPrefixEnabled(v);
                              setDialogState(() {});
                            },
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                        const Text('前缀: '),
                        Expanded(
                          child: TextField(
                            controller: TextEditingController(
                              text: settings.batchSubtitleEmbedSoftPrefix,
                            ),
                            enabled:
                                settings.batchSubtitleEmbedSoftPrefixEnabled,
                            decoration: const InputDecoration(
                              isDense: true,
                              hintText: '例如 [AI字幕]',
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 8,
                              ),
                            ),
                            style: TextStyle(fontSize: 13),
                            onChanged: (v) {
                              settings.updateBatchSubtitleEmbedSoftPrefix(v);
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // ── 后缀设置 ──
                    Row(
                      children: [
                        SizedBox(
                          width: 50,
                          child: Switch(
                            value: settings.batchSubtitleEmbedSoftSuffixEnabled,
                            onChanged: (v) {
                              settings
                                  .updateBatchSubtitleEmbedSoftSuffixEnabled(v);
                              setDialogState(() {});
                            },
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                        const Text('后缀: '),
                        Expanded(
                          child: TextField(
                            controller: TextEditingController(
                              text: settings.batchSubtitleEmbedSoftSuffix,
                            ),
                            enabled:
                                settings.batchSubtitleEmbedSoftSuffixEnabled,
                            decoration: const InputDecoration(
                              isDense: true,
                              hintText: '例如 _字幕版',
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 8,
                              ),
                            ),
                            style: TextStyle(fontSize: 13),
                            onChanged: (v) {
                              settings.updateBatchSubtitleEmbedSoftSuffix(v);
                            },
                          ),
                        ),
                      ],
                    ),
                    const Divider(),
                    // ── 内嵌后自动删除字幕文件 ──
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('内嵌后自动删除字幕文件'),
                      subtitle: const Text(
                        '流程完成后删除 SRT 字幕文件',
                        style: TextStyle(fontSize: 12),
                      ),
                      value: settings.batchSubtitleEmbedAutoDeleteSrt,
                      onChanged: (v) {
                        settings.updateBatchSubtitleEmbedAutoDeleteSrt(v);
                        setDialogState(() {});
                      },
                    ),
                    const SizedBox(height: 8),
                    // 提示信息
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            size: 16,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '文件命名示例：${_buildPreviewFileName('示例视频.mp4', settings)}',
                              style: TextStyle(
                                fontSize: 12,
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.7,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                DesktopButtonClickRegion(
                  child: TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('关闭'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _buildPreviewFileName(String fileName, SettingsService settings) {
    final ext = p.extension(fileName);
    final baseName = p.basenameWithoutExtension(fileName);
    String result = baseName;
    if (settings.batchSubtitleEmbedSoftPrefixEnabled &&
        settings.batchSubtitleEmbedSoftPrefix.isNotEmpty) {
      result = '${settings.batchSubtitleEmbedSoftPrefix}$result';
    }
    if (settings.batchSubtitleEmbedSoftSuffixEnabled &&
        settings.batchSubtitleEmbedSoftSuffix.isNotEmpty) {
      result = '$result${settings.batchSubtitleEmbedSoftSuffix}';
    }
    if (settings.batchSubtitleEmbedSoftCopyAndEmbed && result == baseName) {
      result = '${baseName}_AI字幕';
    }
    return '$result$ext';
  }

  void _showInternalVideoPicker(BuildContext context) {
    if (_importing || _scanning) return;
    final library = context.read<LibraryService>();
    final manager = context.read<TranscriptionManager>();
    showDialog(
      context: context,
      builder: (ctx) => InternalVideoPickerDialog(
        libraryService: library,
        transcriptionManager: manager,
        defaultCollectionId: widget.collectionId,
        onConfirm: _addInternalMediaToQueue,
      ),
    );
  }

  Future<void> _pickExternalFiles(BuildContext context) async {
    if (_importing || _scanning) return;
    final source = await showDialog<_ExternalPickSource>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选择导入来源'),
        content: const Text('请选择要加入转录队列的媒体来源。'),
        actions: [
          DesktopButtonClickRegion(
            child: TextButton(
              onPressed: () =>
                  Navigator.of(ctx).pop(_ExternalPickSource.folder),
              child: const Text('导入文件夹'),
            ),
          ),
          DesktopButtonClickRegion(
            child: FilledButton(
              onPressed: () => Navigator.of(ctx).pop(_ExternalPickSource.files),
              child: const Text('导入文件'),
            ),
          ),
        ],
      ),
    );
    if (source == null || !context.mounted) return;

    switch (source) {
      case _ExternalPickSource.files:
        await _pickExternalFilesImpl(context);
        break;
      case _ExternalPickSource.folder:
        await _pickExternalFolder(context);
        break;
    }
  }

  /// 选择并导入多个外部媒体文件到转录队列。
  Future<void> _pickExternalFilesImpl(BuildContext context) async {
    final manager = context.read<TranscriptionManager>();
    final settings = context.read<SettingsService>();
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: LibraryService.supportedMediaExtensions
          .map((ext) => ext.replaceFirst('.', ''))
          .toList(),
      allowMultiple: true,
    );

    if (result == null || result.files.isEmpty) return;

    if (!mounted) return;
    final strategy = settings.batchSubtitleOutputPathStrategy;
    final directory = settings.batchSubtitleCustomOutputDir;
    await _addMediaToQueue([
      for (final file in result.files)
        (
          label: file.name,
          enqueue: () async {
            if (file.path == null) {
              throw const FileSystemException('所选文件没有可访问的本机路径');
            }
            return manager.startExternalTranscription(
              file.path!,
              outputPathStrategy: strategy,
              customOutputDir: directory,
            );
          },
        ),
    ]);
  }

  /// 导入文件夹：递归扫描（文件夹优先 + 每层自然排序）→ 确认框 → 批量加入队列。
  Future<void> _pickExternalFolder(BuildContext context) async {
    final manager = context.read<TranscriptionManager>();
    final settings = context.read<SettingsService>();

    final folderPath = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择要导入的文件夹',
    );
    if (folderPath == null || folderPath.isEmpty) return;
    if (!context.mounted) return;

    setState(() {
      _scanning = true;
      _noticeTitle = '正在扫描所选文件夹';
      _noticeDetails = null;
      _noticeIsError = false;
      _noticeRetry = null;
      _noticePath = null;
    });
    try {
      final mediaPaths = await scanMediaFolderOrdered(folderPath);
      if (!context.mounted) return;

      if (mediaPaths.isEmpty) {
        _showImportNotice('所选文件夹中没有可识别的媒体文件', isError: false);
        return;
      }

      final folderName = p.basename(p.normalize(folderPath));
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('导入文件夹'),
          content: Text(
            '「$folderName」中递归共找到 ${mediaPaths.length} 个媒体文件，确认全部加入转录队列？',
          ),
          actions: [
            DesktopButtonClickRegion(
              child: TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('取消'),
              ),
            ),
            DesktopButtonClickRegion(
              child: FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('确认添加'),
              ),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) {
        if (mounted) setState(() => _noticeTitle = null);
        return;
      }
      if (mounted) setState(() => _scanning = false);

      final strategy = settings.batchSubtitleOutputPathStrategy;
      final directory = settings.batchSubtitleCustomOutputDir;
      await _addMediaToQueue([
        for (final path in mediaPaths)
          (
            label: p.basename(path),
            enqueue: () => manager.startExternalTranscription(
              path,
              outputPathStrategy: strategy,
              customOutputDir: directory,
            ),
          ),
      ]);
    } catch (e) {
      if (e is FileSystemException) {
        _showImportNotice(
          '所选文件夹不存在或无法访问',
          retry: () => unawaited(_pickExternalFolder(context)),
        );
      } else if (e is TimeoutException) {
        _showImportNotice(
          '文件夹扫描超时，请缩小范围后重试。',
          isError: true,
          details: safeOperationDiagnostic(e),
          retry: () => unawaited(_pickExternalFolder(context)),
        );
      } else {
        debugPrint('扫描文件夹失败: $e');
        _showImportNotice(
          operationErrorSummary(e, fallback: '无法扫描文件夹，请检查权限后重试。'),
          isError: true,
          details: safeOperationDiagnostic(e),
          retry: () => unawaited(_pickExternalFolder(context)),
        );
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<TranscriptTranslateChoice> _batchTranslateChoice() async {
    final enabled = context
        .read<SettingsService>()
        .batchSubtitleTranslateEnabled;
    final shared = lookupSubtitleTranslateSettings(context, listen: false);
    if (!enabled || shared == null) {
      return const TranscriptTranslateChoice.off();
    }
    return TranscriptTranslateChoice.capture(shared, enabled: true);
  }

  Future<void> _startTask(TranscriptionManager manager, String mediaKey) async {
    if (_noticeTitle != null) setState(() => _noticeTitle = null);
    try {
      final choice = await _batchTranslateChoice();
      if (!mounted) return;
      manager.startTask(mediaKey, translateIfUnfrozen: choice);
    } catch (error) {
      if (mounted) {
        _showImportNotice(
          operationErrorSummary(error, fallback: '无法开始转录，请检查媒体和任务设置后重试。'),
          isError: true,
          details: safeOperationDiagnostic(error),
          retry: () => unawaited(_startTask(manager, mediaKey)),
        );
      }
    }
  }

  Future<void> _retryTask(TranscriptionManager manager, String mediaKey) async {
    if (_noticeTitle != null) setState(() => _noticeTitle = null);
    try {
      final choice = await _batchTranslateChoice();
      if (!mounted) return;
      manager.retryTask(mediaKey, translate: choice);
    } catch (error) {
      if (mounted) {
        _showImportNotice(
          operationErrorSummary(error, fallback: '无法重试转录，请检查媒体和任务设置后重试。'),
          isError: true,
          details: safeOperationDiagnostic(error),
          retry: () => unawaited(_retryTask(manager, mediaKey)),
        );
      }
    }
  }

  Future<void> _restartTask(
    TranscriptionManager manager,
    String mediaKey,
  ) async {
    if (!await confirmTranscriptionRestart(
          context,
          modelCenter: manager.modelCenter,
        ) ||
        !mounted) {
      return;
    }
    try {
      final choice = await _batchTranslateChoice();
      if (!mounted) return;
      if (!manager.restartTask(mediaKey, translate: choice)) {
        _showImportNotice('任务状态已变化，请先暂停后再从头开始。');
      }
    } catch (error) {
      if (mounted) {
        _showImportNotice(
          operationErrorSummary(error, fallback: '无法重新转录，请检查媒体和任务设置后重试。'),
          isError: true,
          details: safeOperationDiagnostic(error),
          retry: () => unawaited(_restartTask(manager, mediaKey)),
        );
      }
    }
  }

  void _startAll(TranscriptionManager manager) {
    final tasks = manager.getQueueSnapshot();
    final idleCount = tasks
        .where(
          (t) =>
              (t.status == TranscriptionStatus.idle && !t.isStarted) ||
              t.status == TranscriptionStatus.error,
        )
        .length;
    if (idleCount == 0) {
      return;
    }
    final enabled = context
        .read<SettingsService>()
        .batchSubtitleTranslateEnabled;
    if (!enabled) {
      manager.startAllTasks(
        translateIfUnfrozen: const TranscriptTranslateChoice.off(),
      );
      return;
    }
    unawaited(() async {
      try {
        final choice = await _batchTranslateChoice();
        if (!mounted) return;
        manager.startAllTasks(translateIfUnfrozen: choice);
      } catch (error) {
        if (mounted) {
          _showImportNotice(
            operationErrorSummary(error, fallback: '无法开始转录，请检查媒体和任务设置后重试。'),
            isError: true,
            details: safeOperationDiagnostic(error),
            retry: () => _startAll(manager),
          );
        }
      }
    }());
  }

  void _toggleBatch(TranscriptionManager manager) {
    if (manager.canPauseAll) {
      manager.pauseAllTasks();
      return;
    }
    _startAll(manager);
  }

  void _clearCompleted(TranscriptionManager manager) {
    manager.clearAllCompleted();
  }

  void _showClearAllConfirm(
    BuildContext context,
    TranscriptionManager manager,
  ) {
    final tasks = manager.getQueueSnapshot();
    final count = tasks.length;
    if (count == 0) {
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认清除全部'),
        content: Text('将取消正在处理的任务，并清除队列中所有 $count 个任务，确定继续？'),
        actions: [
          DesktopButtonClickRegion(
            child: TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
          ),
          DesktopButtonClickRegion(
            child: TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                _clearAll(manager);
              },
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('清除全部'),
            ),
          ),
        ],
      ),
    );
  }

  void _clearAll(TranscriptionManager manager) {
    manager.clearAllTasks();
  }

  void _deleteTask(TranscriptionManager manager, String mediaKey) {
    manager.removeFromQueue(mediaKey);
  }

  /// 点击已完成任务的名称：
  /// - 内部视频：跳转到播放页（桌面端横屏，移动端竖屏）
  /// - 外部视频：桌面端用文件资源管理器定位，移动端触发"用其他应用打开"
  Future<void> _onTapCompletedTask(
    BuildContext context,
    BatchSubtitleTaskView task,
  ) async {
    if (task.status != TranscriptionStatus.completed) return;

    if (!task.isExternal && task.videoId != null) {
      // ── 内部视频：跳转到播放页 ──
      await _openInternalVideo(context, task.videoId!);
    } else {
      // ── 外部视频：桌面端打开文件位置，移动端用其他应用打开 ──
      await _openExternalVideoFile(task.videoPath);
    }
  }

  /// 跳转到内部视频的播放页
  Future<void> _openInternalVideo(BuildContext context, String videoId) async {
    final library = context.read<LibraryService>();
    final item = library.getVideo(videoId);
    if (item == null) {
      _showImportNotice('找不到媒体，可能已移动或删除。', isError: true);
      return;
    }

    if (!mounted) return;

    final navigator = Navigator.of(context);

    // 桌面端或开启"跳过竖屏播放页"时直入横屏播放页，否则进入竖屏播放页
    await navigator.push(
      PlaybackNavigationService.buildPlaybackEntryRoute(item),
    );
  }

  /// 打开外部视频文件
  Future<void> _openExternalVideoFile(String filePath) async {
    try {
      if (!await File(filePath).exists()) {
        throw FileSystemException(
          '媒体文件不存在',
          filePath,
          const OSError('not found', 2),
        );
      }
      if (!await revealInFileManager(filePath) && mounted) {
        await _showLocationFailure(filePath, title: '无法打开文件位置');
      }
    } catch (error) {
      if (mounted) {
        await _showLocationFailure(filePath, title: '无法打开文件位置', error: error);
      }
    }
  }
}

enum _BatchOverflowAction {
  toggleAutoRemove,
  pickExternal,
  settings,
  clearCompleted,
  clearAll,
}

/// 「选择外部文件」入口的来源选择。
enum _ExternalPickSource { files, folder }

class _BatchLayoutMetrics {
  final double width;
  final double height;
  final double shortestSide;
  final bool isCompact;
  final bool isTablet;
  final bool isDesktopPlatform;
  final double horizontalPadding;
  final double gap;
  final double fontSize;
  final double buttonHeight;

  const _BatchLayoutMetrics({
    required this.width,
    required this.height,
    required this.shortestSide,
    required this.isCompact,
    required this.isTablet,
    required this.isDesktopPlatform,
    required this.horizontalPadding,
    required this.gap,
    required this.fontSize,
    required this.buttonHeight,
  });

  factory _BatchLayoutMetrics.fromSize(Size size) {
    final shortestSide = size.shortestSide;
    final isCompact = shortestSide < 600;
    final isTablet = !isCompact && size.width < 1100;
    return _BatchLayoutMetrics(
      width: size.width,
      height: size.height,
      shortestSide: shortestSide,
      isCompact: isCompact,
      isTablet: isTablet,
      isDesktopPlatform:
          Platform.isWindows || Platform.isLinux || Platform.isMacOS,
      horizontalPadding: (shortestSide * 0.026).clamp(8.0, 18.0),
      gap: (shortestSide * 0.012).clamp(5.0, 10.0),
      fontSize: (shortestSide * 0.021).clamp(11.5, 13.5),
      buttonHeight: (shortestSide * 0.058).clamp(34.0, 40.0),
    );
  }
}

class _PopupMenuLabel extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;

  const _PopupMenuLabel({required this.icon, required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    final foreground = color ?? Theme.of(context).colorScheme.onSurface;
    return Row(
      children: [
        Icon(icon, size: 19, color: foreground),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(color: foreground, fontSize: 13)),
      ],
    );
  }
}

class _CompactQueueMetric extends StatelessWidget {
  final String label;
  final int count;
  final Color color;

  const _CompactQueueMetric({
    required this.label,
    required this.count,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          '$count',
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w800,
            color: color,
          ),
        ),
      ],
    );
  }
}

class _CompactMetricDivider extends StatelessWidget {
  final Color color;

  const _CompactMetricDivider({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 18,
      color: color.withValues(alpha: 0.55),
    );
  }
}

class _QueueCount extends StatelessWidget {
  final String label;
  final int count;
  final Color color;
  final double fontSize;

  const _QueueCount({
    required this.label,
    required this.count,
    required this.color,
    required this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label ',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          TextSpan(
            text: '$count',
            style: TextStyle(color: color, fontWeight: FontWeight.w700),
          ),
        ],
      ),
      maxLines: 1,
      style: TextStyle(fontSize: fontSize, height: 1.2),
    );
  }
}
