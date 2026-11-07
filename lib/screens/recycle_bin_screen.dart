import '../widgets/recycle_bin_deletion_dialog.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/media_playback_service.dart';
import '../services/playlist_manager.dart';
import '../services/app_haptics.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
import '../services/playback_navigation_service.dart';
import '../models/video_collection.dart';
import '../models/video_item.dart';
import '../models/media_source_ref.dart';
import '../utils/app_toast.dart';
import '../utils/route_transition_work.dart';
import '../utils/hardware_keyboard_shortcuts.dart';
import '../utils/page_shortcut_keys.dart';
import '../widgets/media_library_keyboard_navigation.dart';
import '../widgets/responsive_icon_button.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

Future<void> _openRecycleBinVideo(
  BuildContext context,
  VideoItem item, {
  required List<VideoItem> directoryVideos,
  String? recycleFolderId,
}) async {
  final isOnline =
      item.sourceRef?.kind == MediaSourceKind.bilibiliStream ||
      item.path.startsWith('bilibili://stream/');
  final file = File(item.path);
  if (!isOnline && !await file.exists()) {
    if (!context.mounted) return;
    AppToast.show("媒体文件不存在，可能已被移动或删除", type: AppToastType.error);
    return;
  }
  if (!context.mounted) return;

  final playbackService = Provider.of<MediaPlaybackService>(
    context,
    listen: false,
  );
  final playlistManager = Provider.of<PlaylistManager>(context, listen: false);
  // 当前回收站页面上的视频共用一个队列，嵌套文件夹不并进来。
  playlistManager.setRecycleBinPlaylist(
    directoryVideos,
    currentItemId: item.id,
    folderId: recycleFolderId,
  );
  final existingController = playbackService.currentItem?.id == item.id
      ? playbackService.controller
      : null;

  final Route<void> route = PlaybackNavigationService.buildPlaybackEntryRoute(
    item,
    existingController: existingController,
  );

  Navigator.of(context).push(route);
}

class RecycleBinScreen extends StatefulWidget {
  final VideoCollection? collection;

  const RecycleBinScreen({super.key, this.collection});

  @override
  State<RecycleBinScreen> createState() => _RecycleBinScreenState();
}

class SizeDisplay extends StatefulWidget {
  final dynamic item;
  final LibraryService library;

  const SizeDisplay({super.key, required this.item, required this.library});

  @override
  State<SizeDisplay> createState() => _SizeDisplayState();
}

class _SizeDisplayState extends State<SizeDisplay> {
  Future<int>? _sizeFuture;
  int? _cachedSize;
  final _routeWork = RouteTransitionWork();

  @override
  void initState() {
    super.initState();
    widget.library.addListener(_handleLibraryChanged);
    _syncSizeState();
  }

  @override
  void didUpdateWidget(SizeDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.library != widget.library) {
      oldWidget.library.removeListener(_handleLibraryChanged);
      widget.library.addListener(_handleLibraryChanged);
    }
    if (oldWidget.item != widget.item || oldWidget.library != widget.library) {
      _syncSizeState();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeWork.bind(ModalRoute.of(context));
  }

  @override
  void dispose() {
    _routeWork.dispose();
    widget.library.removeListener(_handleLibraryChanged);
    super.dispose();
  }

  void _handleLibraryChanged() {
    if (!mounted) return;
    final nextCachedSize = widget.library.getCachedItemSize(widget.item);
    if (nextCachedSize == _cachedSize) return;
    setState(_syncSizeState);
  }

  void _syncSizeState() {
    _cachedSize = widget.library.getCachedItemSize(widget.item);
    _sizeFuture = null;
    if (_cachedSize != null) return;
    // Keep cached values instant. Uncached disk accounting keeps the library's
    // ownership checks, cache and concurrency limits, after the page is visible.
    _routeWork.schedule('item-size', () {
      if (!mounted) return;
      setState(() {
        _cachedSize = widget.library.getCachedItemSize(widget.item);
        _sizeFuture = _cachedSize == null
            ? widget.library.calculateItemSize(widget.item)
            : null;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_cachedSize != null) {
      if (_cachedSize == 0) return const SizedBox.shrink();
      return Text(
        " • 可释放: ${LibraryService.formatSize(_cachedSize!)}",
        style: const TextStyle(color: Colors.grey, fontSize: 12),
      );
    }

    if (_sizeFuture == null) return const SizedBox.shrink();

    return FutureBuilder<int>(
      future: _sizeFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SizedBox.shrink();
        final size = snapshot.data!;
        if (size == 0) return const SizedBox.shrink();
        return Text(
          " • 可释放: ${LibraryService.formatSize(size)}",
          style: const TextStyle(color: Colors.grey, fontSize: 12),
        );
      },
    );
  }
}

class _RecycleBinScreenState extends State<RecycleBinScreen> {
  final _keyboardRegionKey = GlobalKey<MediaLibraryKeyboardRegionState>();
  final Set<String> _selectedIds = {};
  bool _isSelectionMode = false;
  final FocusNode _shortcutFocusNode = FocusNode(
    debugLabel: 'RecycleBinShortcutFocus',
  );
  Future<int>? _selectedSizeFuture;
  String _selectedSizeKey = '';

  void _navigateToFolderDetail(
    BuildContext context,
    VideoCollection collection,
  ) {
    Navigator.of(context).push(
      AppMaterialPageRoute(
        builder: (context) =>
            RecycledFolderDetailScreen(collection: collection),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (supportsNativeHardwareKeyboardShortcuts && mounted) {
        _shortcutFocusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _shortcutFocusNode.dispose();
    super.dispose();
  }

  void _updateSelectedSizeFuture(LibraryService library, List<dynamic> bin) {
    final selectedItems = bin
        .where((item) => _selectedIds.contains(item.id))
        .toList();
    final nextKey = selectedItems.map((item) => item.id as String).join('|');
    if (_selectedSizeKey == nextKey) return;

    _selectedSizeKey = nextKey;
    if (selectedItems.isEmpty) {
      setState(() {
        _selectedSizeFuture = null;
      });
      return;
    }

    setState(() {
      _selectedSizeFuture = library.calculateItemsTotalSize(selectedItems);
    });
  }

  void _clearSelection() {
    _isSelectionMode = false;
    _selectedIds.clear();
    _selectedSizeFuture = null;
    _selectedSizeKey = '';
  }

  Future<void> _deleteItems(LibraryService library, List<String> ids) async {
    final result = await showDialog<RecycleBinDeleteResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => RecycleBinDeletionDialog(library: library, ids: ids),
    );
    if (!mounted || result == null) return;
    setState(() {
      _selectedIds.retainWhere(
        (id) =>
            result.failedIds.containsKey(id) &&
            library.isStorageItemRecycled(id),
      );
      if (_selectedIds.isEmpty) _clearSelection();
    });
  }

  String _formatCompactSize(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    double value = bytes.toDouble();
    var unitIndex = 0;
    while (value >= 1024 && unitIndex < suffixes.length - 1) {
      value /= 1024;
      unitIndex++;
    }

    final decimals = value >= 100 ? 0 : (value >= 10 ? 1 : 2);
    final text = value.toStringAsFixed(decimals);
    final normalized = text.contains('.')
        ? text.replaceFirst(RegExp(r'\.?0+$'), '')
        : text;
    return '$normalized ${suffixes[unitIndex]}';
  }

  double _responsiveTitleFontSize(double width) =>
      (width * 0.048).clamp(15.0, 19.0);

  double _responsiveSubtitleFontSize(double width) =>
      (width * 0.032).clamp(11.0, 13.5);

  double _responsiveToolbarHeight(double width) =>
      (width * 0.16).clamp(58.0, 72.0);

  Widget _buildAppBarTitle(
    BuildContext context,
    int visibleCount,
    int selectedCount,
  ) {
    final width = MediaQuery.sizeOf(context).width;
    final titleFontSize = _responsiveTitleFontSize(width);
    final subtitleFontSize = _responsiveSubtitleFontSize(width);
    final isSelectionHeader = _isSelectionMode;

    if (!isSelectionHeader) {
      return Text(
        widget.collection == null
            ? '已显示 $visibleCount 项'
            : '${widget.collection!.name} · $visibleCount 项',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: titleFontSize,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      );
    }

    return FutureBuilder<int>(
      future: _selectedSizeFuture,
      builder: (context, snapshot) {
        final sizeText = snapshot.hasData
            ? _formatCompactSize(snapshot.data!)
            : '正在计算...';
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '已选中 $selectedCount 项',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: titleFontSize,
                fontWeight: FontWeight.w600,
                color: Colors.white,
                height: 1.1,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '可释放 $sizeText',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: subtitleFontSize,
                fontWeight: FontWeight.w400,
                color: Colors.white70,
                height: 1.1,
              ),
            ),
          ],
        );
      },
    );
  }

  KeyEventResult _handleEscKeyEvent(KeyEvent event) {
    if (!supportsNativeHardwareKeyboardShortcuts || isEditableTextFocused()) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (event is KeyDownEvent &&
        _shortcutFocusNode.hasPrimaryFocus &&
        !keyboard.isControlPressed &&
        !keyboard.isMetaPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isShiftPressed &&
        (event.logicalKey == LogicalKeyboardKey.arrowUp ||
            event.logicalKey == LogicalKeyboardKey.arrowDown ||
            event.logicalKey == LogicalKeyboardKey.arrowLeft ||
            event.logicalKey == LogicalKeyboardKey.arrowRight) &&
        (_keyboardRegionKey.currentState?.focusInitial() ?? false)) {
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyB &&
        !keyboard.isControlPressed &&
        !keyboard.isMetaPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isShiftPressed) {
      setState(() => _isSelectionMode = true);
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyA &&
        _isSelectionMode &&
        (keyboard.isControlPressed || keyboard.isMetaPressed) &&
        !keyboard.isAltPressed &&
        !keyboard.isShiftPressed) {
      final library = context.read<LibraryService>();
      final bin = widget.collection == null
          ? library.getRecycleBinContents()
          : library.getRecycledFolderContents(widget.collection!.id);
      setState(() => _selectedIds.addAll(bin.map((item) => item.id as String)));
      _updateSelectedSizeFuture(library, bin);
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        !hasBlockingKeyboardModifier() &&
        !keyboard.isShiftPressed) {
      if (_isSelectionMode) {
        setState(() {
          _clearSelection();
        });
      } else {
        Navigator.of(context).maybePop();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return MediaLibrarySpatialNavigation(
      child: Focus(
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
          child: Consumer<LibraryService>(
            builder: (context, library, child) {
              final bin = widget.collection == null
                  ? library.getRecycleBinContents()
                  : library.getRecycledFolderContents(widget.collection!.id);
              final selectedItems = bin
                  .where((item) => _selectedIds.contains(item.id))
                  .toList();

              return MediaLibraryKeyboardRegion(
                key: _keyboardRegionKey,
                surface: () => 'recycle-${widget.collection?.id ?? 'root'}',
                orderedIds: () => bin.map((item) => item.id as String).toList(),
                selectionMode: () => _isSelectionMode,
                selectedIds: () => _selectedIds,
                onSelectionChanged: (ids) {
                  setState(() {
                    _selectedIds
                      ..clear()
                      ..addAll(ids);
                  });
                  _updateSelectedSizeFuture(library, bin);
                },
                child: Scaffold(
                  appBar: AppBar(
                    toolbarHeight: _isSelectionMode
                        ? _responsiveToolbarHeight(
                            MediaQuery.sizeOf(context).width,
                          )
                        : null,
                    title: _buildAppBarTitle(
                      context,
                      bin.length,
                      selectedItems.length,
                    ),
                    actions: [
                      if (bin.isNotEmpty) ...[
                        ResponsiveActionButtons(
                          buttons: [
                            if (_isSelectionMode) ...[
                              ResponsiveIconButton(
                                icon: Icons.select_all,
                                onPressed: () {
                                  final shouldSelectAll =
                                      _selectedIds.length != bin.length;
                                  setState(() {
                                    if (!shouldSelectAll) {
                                      _selectedIds.clear();
                                    } else {
                                      _selectedIds.addAll(
                                        bin.map((e) => e.id as String),
                                      );
                                    }
                                  });
                                  _updateSelectedSizeFuture(library, bin);
                                },
                                tooltip: "全选/反选",
                              ),
                              ResponsiveIconButton(
                                icon: Icons.close,
                                onPressed: () {
                                  setState(() {
                                    _clearSelection();
                                  });
                                },
                                tooltip: "关闭",
                              ),
                            ] else ...[
                              ResponsiveIconButton(
                                icon: Icons.checklist,
                                onPressed: () {
                                  setState(() {
                                    _isSelectionMode = true;
                                  });
                                },
                                tooltip: "选择",
                              ),
                            ],
                          ],
                        ),
                      ],
                    ],
                  ),
                  body: SafeArea(
                    top: false,
                    child: Column(
                      children: [
                        Expanded(
                          child: bin.isEmpty
                              ? Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      const Icon(
                                        Icons.delete_outline,
                                        size: 80,
                                        color: Colors.white24,
                                      ),
                                      const SizedBox(height: 16),
                                      Text(
                                        widget.collection == null
                                            ? "回收站是空的"
                                            : "没有待还原的内容",
                                        style: TextStyle(color: Colors.white54),
                                      ),
                                    ],
                                  ),
                                )
                              : ListView.builder(
                                  padding: const EdgeInsets.all(16),
                                  itemCount: bin.length,
                                  itemBuilder: (context, index) {
                                    final item = bin[index];
                                    // Handle dynamic item type
                                    final String id = item.id;
                                    final VideoCollection? folder =
                                        item is VideoCollection ? item : null;
                                    final String name =
                                        folder?.name ?? (item as dynamic).title;
                                    final bool isFolder = folder != null;
                                    final String subtitleText = folder != null
                                        ? "${library.getRecycledFolderContents(folder.id).length} 个项目"
                                        : (item as dynamic).path ?? "未知路径";

                                    final isSelected = _selectedIds.contains(
                                      id,
                                    );

                                    void activate() {
                                      AppHaptics.pulse(light: true);
                                      if (_isSelectionMode) {
                                        setState(() {
                                          if (isSelected) {
                                            _selectedIds.remove(id);
                                          } else {
                                            _selectedIds.add(id);
                                          }
                                        });
                                        _updateSelectedSizeFuture(library, bin);
                                      } else if (folder != null) {
                                        _navigateToFolderDetail(
                                          context,
                                          folder,
                                        );
                                      } else {
                                        _openRecycleBinVideo(
                                          context,
                                          item as VideoItem,
                                          directoryVideos: library
                                              .getRecycleBinDirectoryVideos(
                                                widget.collection?.id,
                                              ),
                                          recycleFolderId:
                                              widget.collection?.id,
                                        );
                                      }
                                    }

                                    return MediaLibraryKeyboardItem(
                                      itemId: id,
                                      selected: isSelected,
                                      selectionMode: _isSelectionMode,
                                      onActivate: activate,
                                      child: Card(
                                        color: isSelected
                                            ? Colors.blueAccent.withValues(
                                                alpha: 0.2,
                                              )
                                            : const Color(0xFF2C2C2C),
                                        margin: const EdgeInsets.only(
                                          bottom: 8,
                                        ),
                                        child: ListTile(
                                          leading: _isSelectionMode
                                              ? Checkbox(
                                                  value: isSelected,
                                                  onChanged: AppHaptics.wrapValue((val) {
                                                    setState(() {
                                                      if (val == true) {
                                                        _selectedIds.add(id);
                                                      } else {
                                                        _selectedIds.remove(id);
                                                      }
                                                    });
                                                    _updateSelectedSizeFuture(
                                                      library,
                                                      bin,
                                                    );
                                                  }),
                                                )
                                              : Icon(
                                                  isFolder
                                                      ? Icons.folder
                                                      : Icons.movie,
                                                  color: isFolder
                                                      ? Colors.amber
                                                      : Colors.blue,
                                                ),
                                          title: Text(
                                            name,
                                            style: const TextStyle(
                                              color: Colors.white,
                                            ),
                                          ),
                                          subtitle: Row(
                                            children: [
                                              Expanded(
                                                child: SingleChildScrollView(
                                                  scrollDirection:
                                                      Axis.horizontal,
                                                  child: Text(
                                                    subtitleText,
                                                    style: const TextStyle(
                                                      color: Colors.white54,
                                                      fontSize: 12,
                                                    ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.visible,
                                                  ),
                                                ),
                                              ),
                                              SizeDisplay(
                                                item: item,
                                                library: library,
                                              ),
                                            ],
                                          ),
                                          trailing: !_isSelectionMode
                                              ? Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    DesktopButtonClickRegion(
                                                      child: IconButton(
                                                        icon: const Icon(
                                                          Icons.restore,
                                                          color: Colors.green,
                                                        ),
                                                        onPressed: () async {
                                                          await library
                                                              .restoreFromRecycleBin(
                                                                [id],
                                                              );
                                                          if (!context
                                                              .mounted) {
                                                            return;
                                                          }
                                                          AppToast.show(
                                                            "已还原",
                                                            type: AppToastType
                                                                .success,
                                                          );
                                                        },
                                                        tooltip: "还原",
                                                      ),
                                                    ),
                                                    DesktopButtonClickRegion(
                                                      child: IconButton(
                                                        icon: const Icon(
                                                          Icons.delete_forever,
                                                          color:
                                                              Colors.redAccent,
                                                        ),
                                                        tooltip: '彻底删除',
                                                        onPressed: () =>
                                                            _deleteItems(
                                                              library,
                                                              [id],
                                                            ),
                                                      ),
                                                    ),
                                                  ],
                                                )
                                              : null,
                                          onTap: activate,
                                          onLongPress: () {
                                            if (!_isSelectionMode) {
                                              setState(() {
                                                _isSelectionMode = true;
                                                _selectedIds.add(id);
                                              });
                                              _updateSelectedSizeFuture(
                                                library,
                                                bin,
                                              );
                                              unawaited(
                                                AppHaptics.selectionClick(
                                                  context
                                                      .read<SettingsService>(),
                                                ),
                                              );
                                            }
                                          },
                                        ),
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
                  ),
                  bottomNavigationBar:
                      _isSelectionMode && _selectedIds.isNotEmpty
                      ? BottomAppBar(
                          color: const Color(0xFF1E1E1E),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              DesktopButtonClickRegion(
                                child: TextButton.icon(
                                  icon: const Icon(
                                    Icons.restore,
                                    color: Colors.green,
                                  ),
                                  label: const Text(
                                    "还原",
                                    style: TextStyle(color: Colors.green),
                                  ),
                                  onPressed: AppHaptics.wrap(() async {
                                    await library.restoreFromRecycleBin(
                                      _selectedIds.toList(),
                                    );
                                    if (!context.mounted) return;
                                    setState(() {
                                      _clearSelection();
                                    });
                                    AppToast.show(
                                      "已还原选中项",
                                      type: AppToastType.success,
                                    );
                                  }, light: true),
                                ),
                              ),
                              DesktopButtonClickRegion(
                                child: TextButton.icon(
                                  icon: const Icon(
                                    Icons.delete_forever,
                                    color: Colors.redAccent,
                                  ),
                                  label: const Text(
                                    "彻底删除",
                                    style: TextStyle(color: Colors.redAccent),
                                  ),
                                  onPressed: AppHaptics.wrap(
                                    () => _deleteItems(
                                      library,
                                      _selectedIds.toList(),
                                    ),
                                    light: true,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                      : null,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class RecycledFolderDetailScreen extends StatelessWidget {
  final VideoCollection collection;

  const RecycledFolderDetailScreen({super.key, required this.collection});

  @override
  Widget build(BuildContext context) =>
      RecycleBinScreen(collection: collection);
}
