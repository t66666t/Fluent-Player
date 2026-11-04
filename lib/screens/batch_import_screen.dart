import '../services/settings_service.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';
import 'package:video_player_app/screens/simple_video_preview_screen.dart';
import 'package:video_player_app/screens/subtitle_preview_screen.dart';
import 'package:video_player_app/services/batch_import_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:linked_scroll_controller/linked_scroll_controller.dart';
import '../models/import_card_placement.dart';
import '../models/video_item.dart';
import '../models/video_item.dart' as vi;
import '../utils/app_toast.dart';
import '../utils/android_hardware_input_bridge.dart';
import '../utils/batch_tool_shortcuts.dart';
import '../utils/hardware_keyboard_shortcuts.dart';
import '../utils/page_shortcut_keys.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';
import 'package:video_player_app/widgets/button_aware_drag.dart';

class BatchImportScreen extends StatefulWidget {
  final String? folderId;
  const BatchImportScreen({super.key, this.folderId});

  @override
  State<BatchImportScreen> createState() => _BatchImportScreenState();
}

class _BatchImportScreenState extends State<BatchImportScreen> {
  late LinkedScrollControllerGroup _controllers;
  late ScrollController _videoController;
  late ScrollController _subtitleController;
  late ScrollController _actionController;
  final FocusNode _shortcutFocusNode = FocusNode(
    debugLabel: 'BatchImportShortcutFocus',
  );
  final AndroidHardwareKeyDeduplicator _androidKeyDeduplicator =
      AndroidHardwareKeyDeduplicator();

  @override
  void initState() {
    super.initState();
    AndroidHardwareInputBridge.addKeyListener(_handleAndroidHardwareKeyEvent);
    HardwareKeyboard.instance.addHandler(_handleGlobalHardwareKeyEvent);
    _controllers = LinkedScrollControllerGroup();
    _videoController = _controllers.addAndGet();
    _subtitleController = _controllers.addAndGet();
    _actionController = _controllers.addAndGet();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (supportsNativeHardwareKeyboardShortcuts && mounted) {
        _shortcutFocusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _videoController.dispose();
    _subtitleController.dispose();
    _actionController.dispose();
    AndroidHardwareInputBridge.removeKeyListener(
      _handleAndroidHardwareKeyEvent,
    );
    HardwareKeyboard.instance.removeHandler(_handleGlobalHardwareKeyEvent);
    _shortcutFocusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleEscKeyEvent(KeyEvent event) {
    return _handleShortcutKeyEvent(event);
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

  String _biTooltip(String label, BatchImportShortcutAction action) {
    return hoverAwareShortcutTooltip(
      label,
      BatchImportShortcuts.defaults[action]!,
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
    final BatchImportShortcutAction? action = BatchImportShortcuts.matchAction(
      event.logicalKey,
    );
    final platform = currentNativeTargetPlatform;
    if (action == null ||
        platform == null ||
        !BatchImportShortcuts.isAvailableOnPlatform(action, platform)) {
      return KeyEventResult.ignored;
    }
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    switch (action) {
      case BatchImportShortcutAction.back:
        Navigator.of(context).maybePop();
        return KeyEventResult.handled;
      case BatchImportShortcutAction.importMedia:
        unawaited(_pickVideos());
        return KeyEventResult.handled;
      case BatchImportShortcutAction.importSubtitles:
        unawaited(_pickSubtitles());
        return KeyEventResult.handled;
      case BatchImportShortcutAction.help:
        _showHelpDialog();
        return KeyEventResult.handled;
    }
  }

  Future<void> _pickVideos() async {
    // 显示导入方式选择对话框
    final importType = await _showImportTypeDialog();
    if (importType == null) return;

    if (importType == 'gallery') {
      await _pickFromGallery();
    } else {
      await _pickFromFileManager();
    }
  }

  Future<String?> _showImportTypeDialog() async {
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2C),
        title: const Text("选择导入方式", style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(
                Icons.photo_library,
                color: Colors.blueAccent,
              ),
              title: const Text("从相册导入", style: TextStyle(color: Colors.white)),
              subtitle: const Text(
                "选择手机相册中的媒体文件",
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              onTap: () => Navigator.pop(context, 'gallery'),
            ),
            const Divider(color: Colors.white24),
            ListTile(
              leading: const Icon(
                Icons.folder_open,
                color: Colors.orangeAccent,
              ),
              title: const Text(
                "从文件管理器导入",
                style: TextStyle(color: Colors.white),
              ),
              subtitle: const Text(
                "浏览文件系统选择媒体文件",
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              onTap: () => Navigator.pop(context, 'file_manager'),
            ),
          ],
        ),
        actions: [
          DesktopButtonClickRegion(
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("取消", style: TextStyle(color: Colors.white70)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickFromFileManager() async {
    final filterExtensions = context
        .read<SettingsService>()
        .localImportFilterMediaExtensions;
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: filterExtensions ? FileType.custom : FileType.any,
        allowedExtensions: filterExtensions
            ? LibraryService.supportedMediaExtensions
                  .map((extension) => extension.substring(1))
                  .toList()
            : null,
        allowMultiple: true,
      );
    } catch (e) {
      debugPrint('文件选择器失败: $e');
      if (mounted) {
        AppToast.show('文件选择失败: $e', type: AppToastType.error);
      }
      return;
    }

    if (result != null) {
      final paths = result.paths.whereType<String>().toList();
      final validPaths = paths
          .where(
            (path) =>
                !filterExtensions || LibraryService.isSupportedMediaPath(path),
          )
          .toList();

      if (validPaths.length < paths.length) {
        final skippedCount = paths.length - validPaths.length;
        if (mounted) {
          AppToast.show("已跳过 $skippedCount 个不支持的文件");
        }
      }

      if (validPaths.isNotEmpty && mounted) {
        context.read<BatchImportService>().addVideos(
          widget.folderId,
          validPaths,
        );
      }
    }
  }

  Future<void> _pickFromGallery() async {
    try {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.isAuth && !permission.isLimited) {
        if (mounted) {
          AppToast.show("未获得相册权限，请在系统设置中开启", type: AppToastType.error);
        }
        return;
      }

      if (!mounted) return;
      final List<AssetEntity>? assets = await AssetPicker.pickAssets(
        context,
        pickerConfig: AssetPickerConfig(
          requestType: RequestType.video | RequestType.audio,
          maxAssets: 999,
        ),
      );

      if (assets == null || assets.isEmpty) return;

      final List<String> paths = [];
      final List<String> titles = [];
      final processingToast = AppToast.showLoading("正在处理媒体文件...");
      try {
        for (final asset in assets) {
          final File? file = await asset.file;
          if (file == null) continue;
          paths.add(file.path);

          String title = asset.title ?? '';
          if (title.isEmpty || title.trim().isEmpty) {
            final date = asset.createDateTime;
            final prefix = asset.type == AssetType.video
                ? "Video"
                : (asset.type == AssetType.audio ? "Audio" : "Media");
            title =
                "${prefix}_${date.year}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}_${date.hour.toString().padLeft(2, '0')}${date.minute.toString().padLeft(2, '0')}${date.second.toString().padLeft(2, '0')}";
          }
          titles.add(title);
        }
      } finally {
        await processingToast.dismiss(immediate: true);
      }

      if (paths.isEmpty) {
        if (mounted) {
          AppToast.show("未找到可用的媒体文件", type: AppToastType.error);
        }
        return;
      }

      if (paths.isNotEmpty && mounted) {
        context.read<BatchImportService>().addVideos(
          widget.folderId,
          paths,
          titles: titles,
        );
      }
    } catch (e) {
      debugPrint("Gallery import error: $e");
      if (mounted) {
        AppToast.show("相册导入失败: $e", type: AppToastType.error);
      }
    }
  }

  Future<void> _pickSubtitles() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          'srt',
          'vtt',
          'lrc',
          'ass',
          'ssa',
          'sup',
          'zip',
          'sub',
          'idx',
          'scc',
        ],
        allowMultiple: true,
      );
    } catch (e) {
      debugPrint('字幕选择器失败: $e');
      if (mounted) {
        AppToast.show('字幕选择失败: $e', type: AppToastType.error);
      }
      return;
    }

    if (result != null) {
      List<String> finalPaths = [];
      for (var path in result.paths.whereType<String>()) {
        final ext = p.extension(path).toLowerCase();
        if (ext == '.zip') {
          final extracted = await _extractZip(path);
          finalPaths.addAll(extracted);
        } else if ([
          '.srt',
          '.vtt',
          '.lrc',
          '.ass',
          '.ssa',
          '.sup',
          '.sub',
          '.idx',
          '.scc',
        ].contains(ext)) {
          finalPaths.add(path);
        }
      }

      if (finalPaths.isNotEmpty && mounted) {
        context.read<BatchImportService>().addSubtitles(
          widget.folderId,
          finalPaths,
        );
      }
    }
  }

  Future<List<String>> _extractZip(String zipPath) async {
    try {
      // 在独立 isolate 中使用流式解压，避免将整个 ZIP 加载到内存导致 OOM 闪退
      final result = await compute(_extractZipWorker, zipPath);
      return result;
    } catch (e) {
      debugPrint("Error extracting zip: $e");
      if (mounted) {
        AppToast.show("解压失败: ${p.basename(zipPath)}", type: AppToastType.error);
      }
      return [];
    }
  }

  Future<void> _handleMerge(
    String videoPath,
    String? subtitlePath, {
    String? title,
  }) async {
    final library = Provider.of<LibraryService>(context, listen: false);
    final batch = Provider.of<BatchImportService>(context, listen: false);

    final id = Uuid().v4();
    final parentId = await library.resolveImportCardParentId(
      feature: ImportCardFeature.localFile,
      openedFromFolderId: widget.folderId,
    );
    final item = VideoItem(
      id: id,
      path: videoPath,
      title: title ?? p.basename(videoPath),
      durationMs: 0,
      lastUpdated: DateTime.now().millisecondsSinceEpoch,
      parentId: parentId,
      subtitlePath: subtitlePath,
      type: _detectMediaType(videoPath),
    );

    // 使用原始文件路径，不创建缓存副本
    final resultId = await library.addSingleVideo(item, useOriginalPath: true);
    final actualId = resultId ?? id;

    // Update Batch Service with new paths (LibraryService modified item.path/item.subtitlePath)
    if (item.path != videoPath) {
      batch.updateItemPath(widget.folderId, videoPath, item.path);
    }
    if (subtitlePath != null && item.subtitlePath != subtitlePath) {
      batch.updateItemPath(widget.folderId, subtitlePath, item.subtitlePath!);
    }

    batch.markImported(widget.folderId, item.path, actualId);

    if (mounted) {
      AppToast.show("已合成并导入", type: AppToastType.success);
    }
  }

  vi.MediaType _detectMediaType(String path) {
    final ext = p.extension(path).toLowerCase();
    if (LibraryService.supportedAudioExtensions.contains(ext)) {
      return vi.MediaType.audio;
    }
    return vi.MediaType.video;
  }

  Future<void> _handleUndo(String videoPath) async {
    final library = Provider.of<LibraryService>(context, listen: false);
    final batch = Provider.of<BatchImportService>(context, listen: false);

    final importedId = batch.getImportedId(widget.folderId, videoPath);
    if (importedId != null) {
      // Keep the file because it's now in permanent storage and we want to allow re-import.
      // If we delete it, the user loses the file (since original temp was deleted on import).
      await library.removeSingleVideo(importedId, keepFile: true);
      batch.unmarkImported(widget.folderId, videoPath);

      if (mounted) {
        AppToast.show("已撤回导入", type: AppToastType.success);
      }
    }
  }

  void _showHelpDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2C),
        title: const Text("操作说明", style: TextStyle(color: Colors.white)),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHelpItem(
                "1. 导入文件",
                "• 媒体（视频/音频）：支持批量多选导入。\n• 字幕：支持 srt, vtt, ass, ssa, lrc 格式，支持 zip 压缩包自动解压导入。",
              ),
              const SizedBox(height: 12),
              _buildHelpItem(
                "2. 列表调整",
                "• 滑动表格视图：二指同时按住列表项并上下滑动可滑动表格。\n• 拖拽：按住列表项可极速拖拽调整顺序。\n• 删除：左右滑动列表项可单独删除该项；点击最右侧红色删除按钮可删除整行。",
              ),
              const SizedBox(height: 12),
              _buildHelpItem("3. 预览内容", "点击媒体或字幕文件名可进入预览页面。"),
              const SizedBox(height: 12),
              _buildHelpItem(
                "4. 合成与撤回",
                "• 合成：点击\"合并\"图标将当前行的媒体与字幕关联并导入。\n• 撤回：已合成的项显示绿色，点击\"撤回\"图标可取消导入。",
              ),
              const SizedBox(height: 12),
              _buildHelpItem("5. 自动保存", "所有操作自动保存。文件夹外的红色数字表示待处理媒体数。"),
            ],
          ),
        ),
        actions: [
          DesktopButtonClickRegion(
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                "我知道了",
                style: TextStyle(color: Colors.blueAccent),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHelpItem(String title, String content) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 15,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          content,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 13,
            height: 1.4,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final batch = context.watch<BatchImportService>();
    final videoItems = batch.getVideoItems(widget.folderId);
    final subtitleItems = batch.getSubtitleItems(widget.folderId);
    final fontSize = batch.fontSize;
    final rowHeight = 40.0 + fontSize * 1.5;

    final maxLen = max(videoItems.length, subtitleItems.length);

    return Focus(
      focusNode: _shortcutFocusNode,
      autofocus: supportsNativeHardwareKeyboardShortcuts,
      onKeyEvent: (node, event) => _handleEscKeyEvent(event),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) {
          if (supportsNativeHardwareKeyboardShortcuts &&
              !_shortcutFocusNode.hasFocus) {
            _shortcutFocusNode.requestFocus();
          }
        },
        child: Scaffold(
          backgroundColor: const Color(0xFF121212),
          appBar: AppBar(
            title: const Text("批量导入媒体及对应字幕", style: TextStyle(fontSize: 15)),
            centerTitle: false,
            backgroundColor: const Color(0xFF1E1E1E),
            foregroundColor: Colors.white,
            actions: [
              DesktopButtonClickRegion(
                child: IconButton(
                  icon: const Icon(Icons.remove),
                  onPressed: () => batch.setFontSize(max(10.0, fontSize - 2)),
                ),
              ),
              Center(
                child: Text(
                  "${fontSize.toInt()}",
                  style: const TextStyle(fontSize: 16),
                ),
              ),
              DesktopButtonClickRegion(
                child: IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: () => batch.setFontSize(min(30.0, fontSize + 2)),
                ),
              ),
              const SizedBox(width: 16),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Column(
              children: [
                // Top Buttons
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Row(
                    children: [
                      Expanded(
                        child: DesktopButtonClickRegion(
                          child: ElevatedButton.icon(
                            onPressed: _pickVideos,
                            icon: const Icon(Icons.video_library),
                            label: Text(
                              _biTooltip(
                                '导入媒体',
                                BatchImportShortcutAction.importMedia,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              backgroundColor: Colors.blueAccent,
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: DesktopButtonClickRegion(
                          child: ElevatedButton.icon(
                            onPressed: _pickSubtitles,
                            icon: const Icon(Icons.subtitles),
                            label: Text(
                              _biTooltip(
                                '导入字幕 (支持zip)',
                                BatchImportShortcutAction.importSubtitles,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              backgroundColor: Colors.orangeAccent,
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      DesktopButtonClickRegion(
                        child: IconButton(
                          onPressed: _showHelpDialog,
                          icon: const Icon(
                            Icons.help_outline,
                            color: Colors.white70,
                          ),
                          tooltip: _biTooltip(
                            "操作说明",
                            BatchImportShortcutAction.help,
                          ),
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.white10,
                            padding: const EdgeInsets.all(12),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                    ],
                  ),
                ),

                // Header Row
                Container(
                  color: Colors.white.withValues(alpha: 0.05),
                  height: 40,
                  child: Row(
                    children: [
                      Expanded(
                        child: Center(
                          child: Text(
                            '媒体列表',
                            style: TextStyle(
                              color: Colors.blueAccent.shade100,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      Container(width: 1, color: Colors.white24),
                      Expanded(
                        child: Center(
                          child: Text(
                            '字幕列表',
                            style: TextStyle(
                              color: Colors.orangeAccent.shade100,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      Container(width: 1, color: Colors.white24),
                      SizedBox(
                        width: 100,
                        child: Center(
                          child: Text(
                            '操作',
                            style: TextStyle(
                              color: Colors.white70,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Lists
                Expanded(
                  child: Row(
                    children: [
                      // Video Column
                      Expanded(
                        child: ReorderableListView.builder(
                          scrollController: _videoController,
                          buildDefaultDragHandles: false,
                          itemCount: videoItems.length,
                          onReorderItem: (oldIndex, newIndex) {
                            batch.moveVideo(
                              widget.folderId,
                              oldIndex,
                              newIndex,
                            );
                          },
                          itemBuilder: (context, index) {
                            final item = videoItems[index];
                            final isImported =
                                item.path != null &&
                                batch.isImported(widget.folderId, item.path!);
                            final duration = item.path != null
                                ? batch.getDuration(widget.folderId, item.path!)
                                : null;

                            return ButtonAwareReorderableDragStartListener(
                              key: ValueKey(item.id),
                              index: index,
                              child: Dismissible(
                                key: ValueKey("${item.id}_dismiss"),
                                direction: DismissDirection.horizontal,
                                dismissThresholds: {
                                  DismissDirection.startToEnd: 0.8,
                                  DismissDirection.endToStart: 0.8,
                                },
                                background: Container(
                                  color: Colors.red,
                                  alignment: Alignment.centerLeft,
                                  padding: const EdgeInsets.only(left: 20),
                                  child: const Icon(
                                    Icons.delete,
                                    color: Colors.white,
                                  ),
                                ),
                                secondaryBackground: Container(
                                  color: Colors.red,
                                  alignment: Alignment.centerRight,
                                  padding: const EdgeInsets.only(right: 20),
                                  child: const Icon(
                                    Icons.delete,
                                    color: Colors.white,
                                  ),
                                ),
                                onDismissed: (_) {
                                  batch.removeVideoItem(widget.folderId, index);
                                },
                                child: Container(
                                  height: rowHeight,
                                  decoration: BoxDecoration(
                                    border: Border(
                                      bottom: BorderSide(color: Colors.white12),
                                    ),
                                    color: index % 2 == 0
                                        ? Colors.white.withValues(alpha: 0.02)
                                        : Colors.transparent,
                                  ),
                                  child: item.path == null
                                      ? Center(
                                          child: Text(
                                            "--",
                                            style: TextStyle(
                                              color: Colors.white24,
                                              fontSize: fontSize * 0.8,
                                            ),
                                          ),
                                        )
                                      : InkWell(
                                          onTap: () {
                                            Navigator.push(
                                              context,
                                              AppMaterialPageRoute(
                                                builder: (_) =>
                                                    SimpleVideoPreviewScreen(
                                                      videoPath: item.path!,
                                                    ),
                                              ),
                                            );
                                          },
                                          child: Container(
                                            width: double.infinity,
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8.0,
                                            ),
                                            child: Column(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  item.title ??
                                                      p.basename(item.path!),
                                                  style: TextStyle(
                                                    color: isImported
                                                        ? Colors.green
                                                        : Colors.white,
                                                    fontSize: fontSize,
                                                  ),
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                                if (duration != null)
                                                  Text(
                                                    duration,
                                                    style: TextStyle(
                                                      color: Colors.white54,
                                                      fontSize: fontSize * 0.7,
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                        ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),

                      VerticalDivider(width: 1, color: Colors.white24),

                      // Subtitle Column
                      Expanded(
                        child: ReorderableListView.builder(
                          scrollController: _subtitleController,
                          buildDefaultDragHandles: false,
                          itemCount: subtitleItems.length,
                          onReorderItem: (oldIndex, newIndex) {
                            batch.moveSubtitle(
                              widget.folderId,
                              oldIndex,
                              newIndex,
                            );
                          },
                          itemBuilder: (context, index) {
                            final item = subtitleItems[index];
                            return ButtonAwareReorderableDragStartListener(
                              key: ValueKey(item.id),
                              index: index,
                              child: Dismissible(
                                key: ValueKey("${item.id}_dismiss"),
                                direction: DismissDirection.horizontal,
                                dismissThresholds: {
                                  DismissDirection.startToEnd: 0.8,
                                  DismissDirection.endToStart: 0.8,
                                },
                                background: Container(
                                  color: Colors.red,
                                  alignment: Alignment.centerLeft,
                                  padding: const EdgeInsets.only(left: 20),
                                  child: const Icon(
                                    Icons.delete,
                                    color: Colors.white,
                                  ),
                                ),
                                secondaryBackground: Container(
                                  color: Colors.red,
                                  alignment: Alignment.centerRight,
                                  padding: const EdgeInsets.only(right: 20),
                                  child: const Icon(
                                    Icons.delete,
                                    color: Colors.white,
                                  ),
                                ),
                                onDismissed: (_) {
                                  batch.removeSubtitleItem(
                                    widget.folderId,
                                    index,
                                  );
                                },
                                child: Container(
                                  height: rowHeight,
                                  decoration: BoxDecoration(
                                    border: Border(
                                      bottom: BorderSide(color: Colors.white12),
                                    ),
                                    color: index % 2 == 0
                                        ? Colors.white.withValues(alpha: 0.02)
                                        : Colors.transparent,
                                  ),
                                  child: item.path == null
                                      ? Center(
                                          child: Text(
                                            "--",
                                            style: TextStyle(
                                              color: Colors.white24,
                                              fontSize: fontSize * 0.8,
                                            ),
                                          ),
                                        )
                                      : InkWell(
                                          onTap: () {
                                            Navigator.push(
                                              context,
                                              AppMaterialPageRoute(
                                                builder: (_) =>
                                                    SubtitlePreviewScreen(
                                                      subtitlePath: item.path!,
                                                    ),
                                              ),
                                            );
                                          },
                                          child: Container(
                                            width: double.infinity,
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8.0,
                                            ),
                                            alignment: Alignment.centerLeft,
                                            child: Text(
                                              p.basename(item.path!),
                                              style: TextStyle(
                                                color: Colors.white70,
                                                fontSize: fontSize,
                                              ),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),

                      VerticalDivider(width: 1, color: Colors.white24),

                      // Action Column
                      SizedBox(
                        width: 100,
                        child: ListView.builder(
                          controller: _actionController,
                          itemCount: maxLen,
                          itemExtent: rowHeight,
                          itemBuilder: (context, index) {
                            final videoItem = index < videoItems.length
                                ? videoItems[index]
                                : null;
                            final subItem = index < subtitleItems.length
                                ? subtitleItems[index]
                                : null;

                            final hasVideo = videoItem?.path != null;
                            final isImported =
                                hasVideo &&
                                batch.isImported(
                                  widget.folderId,
                                  videoItem!.path!,
                                );

                            return Container(
                              height: rowHeight,
                              decoration: BoxDecoration(
                                border: Border(
                                  bottom: BorderSide(color: Colors.white12),
                                ),
                                color: index % 2 == 0
                                    ? Colors.white.withValues(alpha: 0.02)
                                    : Colors.transparent,
                              ),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceEvenly,
                                children: [
                                  if (hasVideo)
                                    DesktopButtonClickRegion(
                                      child: IconButton(
                                        icon: Icon(
                                          isImported
                                              ? Icons.undo
                                              : Icons.merge_type,
                                          color: isImported
                                              ? Colors.orange
                                              : (subItem?.path != null
                                                    ? Colors.blue
                                                    : Colors.grey),
                                          size: fontSize + 4,
                                        ),
                                        onPressed: () {
                                          final videoPath = videoItem?.path;
                                          if (videoPath == null) return;
                                          if (isImported) {
                                            _handleUndo(videoPath);
                                          } else {
                                            _handleMerge(
                                              videoPath,
                                              subItem?.path,
                                              title: videoItem?.title,
                                            );
                                          }
                                        },
                                      ),
                                    ),
                                  DesktopButtonClickRegion(
                                    child: IconButton(
                                      icon: Icon(
                                        Icons.delete,
                                        color: Colors.red,
                                        size: fontSize + 4,
                                      ),
                                      onPressed: () {
                                        batch.removeRow(widget.folderId, index);
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
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

// isolate worker 函数：流式解压 ZIP，仅提取字幕文件，失败时自动清理临时目录
List<String> _extractZipWorker(String zipPath) {
  // 支持的字幕文件扩展名
  const subtitleExtensions = {
    '.srt',
    '.vtt',
    '.lrc',
    '.ass',
    '.ssa',
    '.sup',
    '.sub',
    '.idx',
    '.scc',
  };
  const maxEntryCount = 20000;
  const maxPathDepth = 64;
  const maxSingleSubtitleBytes = 64 * 1024 * 1024;
  const maxTotalSubtitleBytes = 512 * 1024 * 1024;
  const maxCompressionRatio = 1000;

  Directory? destDir;
  InputStream? inputStream;
  Archive? archive;

  try {
    final tempDir = Directory.systemTemp;
    destDir = Directory(
      p.join(
        tempDir.path,
        'unzip_${DateTime.now().millisecondsSinceEpoch}_${zipPath.hashCode}',
      ),
    );
    destDir.createSync(recursive: true);

    // 使用 InputFileStream 流式读取，避免将整个 ZIP 加载到内存
    inputStream = InputFileStream(zipPath);
    var entryCount = 0;
    var declaredSubtitleBytes = 0;
    archive = ZipDecoder().decodeStream(
      inputStream,
      callback: (entry) {
        entryCount++;
        if (entryCount > maxEntryCount) {
          throw StateError('字幕压缩包文件数量超过安全上限 ($maxEntryCount)');
        }
        final depth = entry.name
            .split(RegExp(r'[\\/]+'))
            .where((segment) => segment.isNotEmpty)
            .length;
        if (depth > maxPathDepth) {
          throw StateError('字幕压缩包目录层级超过安全上限 ($maxPathDepth)');
        }
        if (!entry.isFile ||
            !subtitleExtensions.contains(
              p.extension(entry.name).toLowerCase(),
            )) {
          return;
        }
        final entrySize = entry.size;
        if (entrySize < 0 || entrySize > maxSingleSubtitleBytes) {
          throw StateError('单个字幕文件超过 64MB 安全上限');
        }
        declaredSubtitleBytes += entrySize;
        if (declaredSubtitleBytes > maxTotalSubtitleBytes) {
          throw StateError('字幕解压总大小超过 512MB 安全上限');
        }
        final compressedSize = entry.rawContent?.length ?? entrySize;
        if (entrySize > 0 &&
            (compressedSize <= 0 ||
                entrySize > compressedSize * maxCompressionRatio)) {
          throw StateError('字幕压缩包压缩比异常');
        }
      },
    );

    final extractedPaths = <String>[];
    final writeBudget = _SubtitleArchiveWriteBudget(maxTotalSubtitleBytes);
    for (final entry in archive) {
      if (!entry.isFile) continue;

      final rawName = entry.name.replaceAll('\\', '/');
      // 跳过 macOS 系统元数据文件和隐藏文件
      final firstSegment = rawName.split('/').first;
      if (firstSegment == '__MACOSX' || firstSegment.startsWith('.')) continue;

      final ext = p.extension(rawName).toLowerCase();
      if (!subtitleExtensions.contains(ext)) continue;

      // 安全路径构建：防止路径穿越攻击
      final safeName = rawName
          .split('/')
          .where((s) => s.isNotEmpty && s != '.' && s != '..')
          .join(Platform.pathSeparator);
      if (safeName.isEmpty) continue;

      final outFile = File(p.join(destDir.path, safeName));
      // 二次校验路径安全
      final normalizedOut = p.normalize(outFile.path);
      final normalizedDest = p.normalize(destDir.path);
      if (!p.isWithin(normalizedDest, normalizedOut) &&
          !p.equals(normalizedDest, normalizedOut)) {
        continue;
      }

      final parentDir = Directory(p.dirname(normalizedOut));
      if (!parentDir.existsSync()) {
        parentDir.createSync(recursive: true);
      }

      final output = _BudgetedSubtitleOutputStream(
        OutputFileStream(normalizedOut),
        writeBudget,
        maxSingleSubtitleBytes,
      );
      try {
        entry.writeContent(output);
      } finally {
        output.closeSync();
      }
      extractedPaths.add(normalizedOut);
    }

    return extractedPaths;
  } catch (_) {
    // 解压失败时删除整个临时目录，不留任何残余文件
    if (destDir != null) {
      try {
        if (destDir.existsSync()) {
          destDir.deleteSync(recursive: true);
        }
      } catch (_) {}
    }
    rethrow;
  } finally {
    try {
      inputStream?.closeSync();
    } catch (_) {}
    try {
      archive?.clear();
    } catch (_) {}
  }
}

class _SubtitleArchiveWriteBudget {
  final int maxTotalBytes;
  int writtenBytes = 0;

  _SubtitleArchiveWriteBudget(this.maxTotalBytes);

  void reserve(int byteCount) {
    if (byteCount < 0 || writtenBytes + byteCount > maxTotalBytes) {
      throw StateError('字幕解压总大小超过 512MB 安全上限');
    }
    writtenBytes += byteCount;
  }
}

class _BudgetedSubtitleOutputStream extends OutputStream {
  final OutputFileStream _delegate;
  final _SubtitleArchiveWriteBudget _budget;
  final int _maxFileBytes;
  int _writtenForFile = 0;

  _BudgetedSubtitleOutputStream(
    this._delegate,
    this._budget,
    this._maxFileBytes,
  ) : super(byteOrder: _delegate.byteOrder);

  void _reserve(int count) {
    if (count < 0 || _writtenForFile + count > _maxFileBytes) {
      throw StateError('单个字幕文件超过 64MB 安全上限');
    }
    _budget.reserve(count);
    _writtenForFile += count;
  }

  @override
  int get length => _delegate.length;

  @override
  bool get isOpen => _delegate.isOpen;

  @override
  void clear() => _delegate.clear();

  @override
  void flush() => _delegate.flush();

  @override
  Future<void> close() => _delegate.close();

  @override
  void closeSync() => _delegate.closeSync();

  @override
  void writeByte(int value) {
    _reserve(1);
    _delegate.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    _reserve(count);
    _delegate.writeBytes(bytes, length: count);
  }

  @override
  void writeStream(InputStream stream) {
    const chunkSize = 1024 * 1024;
    while (!stream.isEOS) {
      final count = min(chunkSize, stream.length);
      if (count <= 0) break;
      writeBytes(stream.readBytes(count).toUint8List());
    }
  }

  @override
  Uint8List subset(int start, [int? end]) => _delegate.subset(start, end);
}
