import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
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
import '../services/batch_import_files.dart';
import '../services/community_media_input.dart';
import '../theme/app_tokens.dart';
import '../utils/import_gallery_access.dart';
import '../utils/android_hardware_input_bridge.dart';
import '../utils/batch_tool_shortcuts.dart';
import '../utils/hardware_keyboard_shortcuts.dart';
import '../utils/page_shortcut_keys.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';
import '../widgets/batch_import_table.dart';
import '../theme/app_interaction_theme.dart';

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
  final _horizontalController = ScrollController();
  Future<void> _fileImportQueue = Future.value();
  final _addedArchives = <String>{};
  int _pendingFileBatches = 0;
  bool _dragging = false;
  bool _committing = false;

  bool get _desktop => switch (defaultTargetPlatform) {
    TargetPlatform.windows ||
    TargetPlatform.macOS ||
    TargetPlatform.linux => true,
    _ => false,
  };

  bool get _mobile => switch (defaultTargetPlatform) {
    TargetPlatform.android || TargetPlatform.iOS => true,
    _ => false,
  };
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
    _horizontalController.dispose();
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
    if (_committing) return KeyEventResult.handled;
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
    if (!_mobile) {
      await _pickFiles(mediaOnly: true);
      return;
    }
    final importType = await _showImportTypeDialog();
    if (importType == null) return;

    if (importType == 'gallery') {
      await _pickFromGallery();
    } else {
      await _pickFiles(mediaOnly: true);
    }
  }

  Future<String?> _showImportTypeDialog() async {
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加媒体'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('相册'),
              onTap: () => Navigator.pop(context, 'gallery'),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text('文件'),
              onTap: () => Navigator.pop(context, 'file_manager'),
            ),
          ],
        ),
        actions: [
          DesktopButtonClickRegion(
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickFiles({
    bool mediaOnly = false,
    bool subtitlesOnly = false,
  }) async {
    try {
      final extensions = {
        if (!subtitlesOnly) ...batchImportMediaExtensions,
        if (!mediaOnly) ...batchImportSubtitleExtensions,
        if (!mediaOnly) '.zip',
      };
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: extensions
            .map((extension) => extension.substring(1))
            .toList(),
        allowMultiple: true,
        withData: false,
      );
      if (result != null && mounted) {
        await _enqueueFiles(result.paths.whereType<String>().toList());
      }
    } catch (error) {
      if (mounted) {
        debugPrint('Batch file picker: $error');
        _showError(
          '无法选择文件',
          retry: () =>
              _pickFiles(mediaOnly: mediaOnly, subtitlesOnly: subtitlesOnly),
        );
      }
    }
  }

  // Serializing drops also makes consecutive mixed drops append in arrival order.
  // The existing batch service retains ownership of saved lists and empty slots.
  Future<void> _enqueueFiles(
    List<String> paths, {
    Map<String, String>? titles,
  }) {
    if (!mounted || paths.isEmpty || _committing) return Future.value();
    final batch = context.read<BatchImportService>();
    setState(() => _pendingFileBatches++);
    final operation = _fileImportQueue
        .then((_) async {
          if (!mounted) return;
          final files = await collectBatchImportFiles(
            paths,
            existingMedia: batch
                .getVideoItems(widget.folderId)
                .map((item) => item.path)
                .whereType<String>(),
            existingSubtitles: batch
                .getSubtitleItems(widget.folderId)
                .map((item) => item.path)
                .whereType<String>(),
            existingArchives: _addedArchives,
            extractSubtitleArchive: (path) => compute(_extractZipWorker, path),
          );
          if (!mounted) return;
          if (files.media.isNotEmpty) {
            await batch.addVideos(
              widget.folderId,
              files.media,
              titles: titles == null
                  ? null
                  : [
                      for (final path in files.media)
                        titles[path] ?? p.basename(path),
                    ],
            );
          }
          if (files.subtitles.isNotEmpty) {
            await batch.addSubtitles(widget.folderId, files.subtitles);
          }
          _addedArchives.addAll(files.archives);
          if (mounted && files.failedArchives > 0) {
            _showError(
              '${files.failedArchives} 个压缩包读取失败',
              retry: () => _enqueueFiles(paths, titles: titles),
            );
          }
        })
        .catchError((Object error) {
          if (mounted) {
            debugPrint('Batch file selection: $error');
            _showError(
              '无法添加文件',
              retry: () => _enqueueFiles(paths, titles: titles),
            );
          }
        })
        .whenComplete(() {
          if (mounted) setState(() => _pendingFileBatches--);
        });
    _fileImportQueue = operation;
    return operation;
  }

  Future<void> _pickFromGallery() async {
    try {
      final requestType = await requestImportGalleryAccess();
      if (requestType == null) {
        if (mounted) {
          AppToast.show("未获得相册权限，请在系统设置中开启", type: AppToastType.error);
        }
        return;
      }

      if (!mounted) return;
      final List<AssetEntity>? assets = await AssetPicker.pickAssets(
        context,
        pickerConfig: AssetPickerConfig(
          requestType: requestType,
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
        await _enqueueFiles(paths, titles: Map.fromIterables(paths, titles));
      }
    } catch (e) {
      debugPrint("Gallery import error: $e");
      if (mounted) {
        AppToast.show("相册导入失败: $e", type: AppToastType.error);
      }
    }
  }

  Future<void> _pickSubtitles() => _pickFiles(subtitlesOnly: true);

  Future<void> _handleMerge(
    String videoPath,
    String? subtitlePath, {
    String? title,
  }) async {
    requireCommunityLocalMedia(videoPath);
    if (subtitlePath != null) requireCommunityLocalMedia(subtitlePath);
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
    if (resultId == null) throw StateError('媒体未能导入，请重试');
    final actualId = resultId;

    // Update Batch Service with new paths (LibraryService modified item.path/item.subtitlePath)
    if (item.path != videoPath) {
      batch.updateItemPath(widget.folderId, videoPath, item.path);
    }
    if (subtitlePath != null &&
        item.subtitlePath != null &&
        item.subtitlePath != subtitlePath) {
      batch.updateItemPath(widget.folderId, subtitlePath, item.subtitlePath!);
    }

    await batch.markImported(widget.folderId, item.path, actualId);
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
      await batch.unmarkImported(widget.folderId, videoPath);
    }
  }

  Future<void> _runRowAction(Future<void> Function() action) async {
    if (_committing || _pendingFileBatches > 0) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    setState(() => _committing = true);
    try {
      await action();
    } catch (error) {
      debugPrint('Batch import action: $error');
      if (mounted) _showError('操作失败', retry: () => _runRowAction(action));
    } finally {
      if (mounted) setState(() => _committing = false);
    }
  }

  Future<void> _importAll() => _runRowAction(() async {
    final batch = context.read<BatchImportService>();
    // Copy the pairings before LibraryService updates any managed file paths.
    final videos = batch.getVideoItems(widget.folderId);
    final subtitles = batch.getSubtitleItems(widget.folderId);
    final pairs = [
      for (var i = 0; i < videos.length; i++)
        if (videos[i].path != null &&
            !batch.isImported(widget.folderId, videos[i].path!))
          (
            path: videos[i].path!,
            title: videos[i].title,
            subtitle: i < subtitles.length ? subtitles[i].path : null,
          ),
    ];
    var failed = 0;
    for (final pair in pairs) {
      if (!mounted) break;
      try {
        await _handleMerge(pair.path, pair.subtitle, title: pair.title);
      } catch (_) {
        failed++;
      }
    }
    if (mounted && failed > 0) {
      _showError('$failed 项未导入', retry: _importAll);
    }
  });

  void _showError(String message, {VoidCallback? retry}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          backgroundColor: AppTokens.bgOverlay,
          content: Text(
            message,
            style: const TextStyle(color: AppTokens.text1),
          ),
          action: retry == null
              ? null
              : SnackBarAction(
                  label: '重试',
                  textColor: AppTokens.text1,
                  onPressed: retry,
                ),
        ),
      );
  }

  void _showHelpDialog() {
    final platform = currentNativeTargetPlatform;
    showDialog<void>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('快捷键'),
        children: [
          for (final action in BatchImportShortcutAction.values)
            if (action != BatchImportShortcutAction.help &&
                platform != null &&
                BatchImportShortcuts.isAvailableOnPlatform(action, platform))
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(switch (action) {
                        BatchImportShortcutAction.back => '返回',
                        BatchImportShortcutAction.importMedia => '添加媒体',
                        BatchImportShortcutAction.importSubtitles => '添加字幕',
                        BatchImportShortcutAction.help => '快捷键',
                      }),
                    ),
                    Text(
                      formatShortcutKey(BatchImportShortcuts.defaults[action]!),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  void _showFontSizeDialog(BatchImportService batch) {
    showDialog<void>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('字号'),
        children: [
          for (final size in [10.0, 12.0, 14.0, 16.0, 20.0, 24.0, 30.0])
            SimpleDialogOption(
              onPressed: () {
                batch.setFontSize(size);
                Navigator.pop(context);
              },
              child: Row(
                children: [
                  Expanded(child: Text('${size.toInt()}')),
                  if (size == batch.fontSize)
                    const Icon(Icons.check_rounded, size: 18),
                ],
              ),
            ),
        ],
      ),
    );
  }

  ThemeData _pageTheme(BuildContext context) {
    final base = Theme.of(context);
    return appInteractionTheme(
      base.copyWith(
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: AppTokens.text1,
          onPrimary: AppTokens.bgBase,
          surface: AppTokens.bgBase,
          onSurface: AppTokens.text1,
          error: AppTokens.danger,
        ),
        scaffoldBackgroundColor: AppTokens.bgBase,
        dividerColor: AppTokens.lineSubtle,
        textTheme: base.textTheme.apply(
          bodyColor: AppTokens.text1,
          displayColor: AppTokens.text1,
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: AppTokens.bgBase,
          foregroundColor: AppTokens.text1,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          titleTextStyle: base.textTheme.titleLarge?.copyWith(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: AppTokens.text1,
          ),
        ),
        iconTheme: const IconThemeData(color: AppTokens.text2),
        scrollbarTheme: ScrollbarThemeData(
          thumbColor: WidgetStatePropertyAll(
            AppTokens.text3.withValues(alpha: 0.5),
          ),
          thickness: const WidgetStatePropertyAll(3),
          radius: const Radius.circular(3),
        ),
        iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(
            foregroundColor: AppTokens.text2,
            minimumSize: Size.square(_mobile ? 44 : 30),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: AppTokens.text1,
            side: const BorderSide(color: Color(0xFF454544)),
            minimumSize: Size(0, _mobile ? 44 : 30),
            padding: EdgeInsets.symmetric(
              horizontal: 12,
              vertical: _mobile ? 8 : 4,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF363A38),
            foregroundColor: AppTokens.text1,
            minimumSize: Size(0, _mobile ? 44 : 30),
            padding: EdgeInsets.symmetric(
              horizontal: 12,
              vertical: _mobile ? 8 : 4,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      ),
    );
  }

  Widget _addFilesButton(bool busy, {bool iconOnly = false}) =>
      DesktopButtonClickRegion(
        child: iconOnly
            ? IconButton(
                key: const ValueKey('batch-import-pick-files'),
                tooltip: '添加文件',
                onPressed: busy ? null : () => _pickFiles(),
                icon: const Icon(Icons.add_rounded, size: 20),
              )
            : OutlinedButton.icon(
                key: const ValueKey('batch-import-pick-files'),
                onPressed: busy ? null : () => _pickFiles(),
                icon: const Icon(Icons.add_rounded, size: 16),
                label: const Text('添加文件'),
              ),
      );

  Widget _importButton(bool busy, int pending, {bool compact = false}) =>
      DesktopButtonClickRegion(
        child: Tooltip(
          message: '导入全部',
          child: FilledButton(
            key: const ValueKey('batch-import-all'),
            onPressed: busy || pending == 0 ? null : _importAll,
            child: Text(compact ? '导入' : '导入全部'),
          ),
        ),
      );

  Widget _toolbar({required bool busy, required int pending}) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final add = _addFilesButton(busy);
        final commit = _importButton(busy, pending);
        if (constraints.maxWidth < 420) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [add, const SizedBox(height: 8), commit],
          );
        }
        return Row(children: [add, const Spacer(), commit]);
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    final batch = context.watch<BatchImportService>();
    final videos = batch.getVideoItems(widget.folderId);
    final subtitles = batch.getSubtitleItems(widget.folderId);
    final pending = videos
        .where(
          (item) =>
              item.path != null &&
              !batch.isImported(widget.folderId, item.path!),
        )
        .length;
    final busy = _committing || _pendingFileBatches > 0;
    final inlineActions = MediaQuery.textScalerOf(context).scale(14) <= 20;
    final wideActions = MediaQuery.sizeOf(context).width >= 700;
    return Theme(
      data: _pageTheme(context),
      child: Builder(
        builder: (context) => Focus(
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
              appBar: AppBar(
                toolbarHeight: _mobile ? 52 : 44,
                title: const Text(
                  '媒体与字幕导入',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                centerTitle: false,
                actions: [
                  if (inlineActions) ...[
                    _addFilesButton(busy, iconOnly: !wideActions),
                    const SizedBox(width: 8),
                    _importButton(busy, pending, compact: !wideActions),
                    const SizedBox(width: 8),
                  ],
                  PopupMenuButton<String>(
                    tooltip: '更多',
                    icon: const Icon(Icons.more_horiz_rounded),
                    enabled: !busy,
                    onSelected: (value) {
                      switch (value) {
                        case 'gallery':
                          unawaited(_pickFromGallery());
                        case 'font':
                          _showFontSizeDialog(batch);
                        case 'shortcuts':
                          _showHelpDialog();
                      }
                    },
                    itemBuilder: (_) => [
                      if (_mobile)
                        const PopupMenuItem(
                          value: 'gallery',
                          child: Text('从相册添加'),
                        ),
                      const PopupMenuItem(value: 'font', child: Text('字号')),
                      PopupMenuItem(
                        value: 'shortcuts',
                        child: Text(
                          _biTooltip('快捷键', BatchImportShortcutAction.help),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 8),
                ],
              ),
              body: SafeArea(
                top: false,
                child: DropTarget(
                  key: const ValueKey('batch-import-drop-target'),
                  enable:
                      _desktop &&
                      !_committing &&
                      (ModalRoute.of(context)?.isCurrent ?? false),
                  onDragEntered: (_) => setState(() => _dragging = true),
                  onDragExited: (_) {
                    if (mounted) setState(() => _dragging = false);
                  },
                  onDragDone: (details) {
                    if (!_desktop ||
                        _committing ||
                        ModalRoute.of(context)?.isCurrent != true) {
                      return;
                    }
                    setState(() => _dragging = false);
                    unawaited(
                      _enqueueFiles(
                        details.files.map((file) => file.path).toList(),
                      ),
                    );
                  },
                  child: Stack(
                    children: [
                      Column(
                        children: [
                          if (!inlineActions)
                            _toolbar(busy: busy, pending: pending),
                          SizedBox(
                            height: 2,
                            child: busy
                                ? const LinearProgressIndicator(
                                    minHeight: 2,
                                    color: AppTokens.text2,
                                    backgroundColor: AppTokens.lineSubtle,
                                  )
                                : null,
                          ),
                          Expanded(
                            child: AbsorbPointer(
                              absorbing: busy,
                              child: BatchImportTable(
                                batch: batch,
                                folderId: widget.folderId,
                                media: videos,
                                subtitles: subtitles,
                                mediaController: _videoController,
                                subtitleController: _subtitleController,
                                actionController: _actionController,
                                horizontalController: _horizontalController,
                                onAddMedia: () =>
                                    unawaited(_pickFiles(mediaOnly: true)),
                                onAddSubtitles: () =>
                                    unawaited(_pickSubtitles()),
                                onPreviewMedia: (item) => Navigator.push(
                                  context,
                                  AppMaterialPageRoute(
                                    builder: (_) => SimpleVideoPreviewScreen(
                                      videoPath: item.path!,
                                    ),
                                  ),
                                ),
                                onPreviewSubtitle: (item) => Navigator.push(
                                  context,
                                  AppMaterialPageRoute(
                                    builder: (_) => SubtitlePreviewScreen(
                                      subtitlePath: item.path!,
                                    ),
                                  ),
                                ),
                                onImport: (media, subtitle) => unawaited(
                                  _runRowAction(
                                    () => _handleMerge(
                                      media.path!,
                                      subtitle?.path,
                                      title: media.title,
                                    ),
                                  ),
                                ),
                                onUndo: (media) => unawaited(
                                  _runRowAction(() => _handleUndo(media.path!)),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (_dragging && !_committing)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: Container(
                              margin: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: AppTokens.bgOverlay.withValues(
                                  alpha: 0.96,
                                ),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: AppTokens.text2),
                              ),
                              child: const Center(
                                child: Icon(
                                  Icons.file_download_outlined,
                                  size: 36,
                                  color: AppTokens.text1,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
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
  const subtitleExtensions = batchImportSubtitleExtensions;
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
