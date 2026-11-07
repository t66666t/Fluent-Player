import '../../utils/keyboard_shortcut_hints.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/theme/app_page_transitions.dart';

import '../../services/app_haptics.dart';
import '../../services/library_service.dart';
import '../../utils/android_hardware_input_bridge.dart';
import '../../utils/batch_tool_shortcuts.dart';
import '../../utils/hardware_keyboard_shortcuts.dart';
import '../../utils/media_library_search_query.dart';
import '../../utils/page_shortcut_keys.dart';
import '../../widgets/cached_thumbnail_widget.dart';
import 'portable_export_format_page.dart';
import 'portable_media_selection.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Hierarchical media-card picker used by portable export.
///
/// Folders can be expanded so nested cards are visible and independently
/// selectable. A checked folder still means "this folder and everything in
/// it"; unchecking one child keeps the rest and preserves ancestor folders
/// for import.
class PortableSelectionPage extends StatefulWidget {
  final LibraryService library;
  const PortableSelectionPage({super.key, required this.library});

  @override
  State<PortableSelectionPage> createState() => _PortableSelectionPageState();
}

class _PortableSelectionPageState extends State<PortableSelectionPage> {
  final PortableMediaSelection _selection = PortableMediaSelection();
  final Set<String> _expanded = <String>{};
  String _query = '';
  final FocusNode _shortcutFocusNode = FocusNode();
  final AndroidHardwareKeyDeduplicator _androidKeyDeduplicator =
      AndroidHardwareKeyDeduplicator();
  var _continuing = false;

  @override
  void initState() {
    super.initState();
    AndroidHardwareInputBridge.addKeyListener(_handleAndroidHardwareKeyEvent);
    HardwareKeyboard.instance.addHandler(_handleGlobalHardwareKeyEvent);
  }

  @override
  void dispose() {
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

  String _psTooltip(String label, PortableSelectionShortcutAction action) {
    return hoverAwareShortcutTooltip(
      label,
      PortableSelectionShortcuts.defaults[action]!,
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
    final PortableSelectionShortcutAction? action =
        PortableSelectionShortcuts.matchAction(event.logicalKey);
    if (action == null) return KeyEventResult.ignored;
    final bool hasBlockingModifier =
        hasBlockingModifierOverride ?? hasBlockingKeyboardModifier();
    if (hasBlockingModifier) return KeyEventResult.ignored;
    final bool editing = isEditableTextFocused();
    if (editing && action != PortableSelectionShortcutAction.back) {
      return KeyEventResult.ignored;
    }
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    final tree = _tree;
    final search = MediaLibrarySearchQuery(_query);
    final searching = !search.isEmpty;
    final visibleIds = searching
        ? tree.nodes.values
              .where((node) => search.matchesTitle(node.name))
              .map((node) => node.id)
              .toList(growable: false)
        : tree.rootIds;
    switch (action) {
      case PortableSelectionShortcutAction.back:
        Navigator.of(context).maybePop();
        return KeyEventResult.handled;
      case PortableSelectionShortcutAction.selectAll:
        if (visibleIds.isEmpty) return KeyEventResult.handled;
        final allVisibleSelected = visibleIds.every(
          (id) => _selection.checkState(tree, id) == PortableCheckState.checked,
        );
        setState(() {
          _selection.setAll(tree, visibleIds, !allVisibleSelected);
        });
        return KeyEventResult.handled;
      case PortableSelectionShortcutAction.toggleExpand:
        if (searching) return KeyEventResult.handled;
        if (tree.nodes.values.any((node) => node.isFolder)) {
          setState(_toggleExpandAll);
        }
        return KeyEventResult.handled;
      case PortableSelectionShortcutAction.confirm:
        if (_selection.isEmpty) return KeyEventResult.handled;
        unawaited(_continue());
        return KeyEventResult.handled;
    }
  }

  PortableTreeIndex get _tree => PortableTreeIndex.fromLibrary(widget.library);

  Future<void> _continue() async {
    if (_continuing || _selection.isEmpty || !mounted) return;
    _continuing = true;
    try {
      final started = await Navigator.of(context).push<bool>(
        AppMaterialPageRoute<bool>(
          builder: (_) => PortableExportFormatPage(
            library: widget.library,
            rootIds: _selection.selectedRoots.toList(),
          ),
        ),
      );
      if (started == true && mounted) {
        Navigator.of(context).pop(true);
      }
    } finally {
      _continuing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final inheritedTheme = Theme.of(context);
    final tree = _tree;
    final search = MediaLibrarySearchQuery(_query);
    final searching = !search.isEmpty;
    final visibleIds = searching
        ? tree.nodes.values
              .where((node) => search.matchesTitle(node.name))
              .map((node) => node.id)
              .toList(growable: false)
        : tree.rootIds;
    final rows = searching
        ? [
            for (final id in visibleIds)
              if (tree.node(id) != null)
                _PickerRow(node: tree.node(id)!, depth: 0, searching: true),
          ]
        : _visibleTreeRows(tree);
    final allVisibleSelected =
        visibleIds.isNotEmpty &&
        visibleIds.every(
          (id) => _selection.checkState(tree, id) == PortableCheckState.checked,
        );
    final selectedMedia = _selection.selectedMediaCount(tree);
    final inclusion = _selection.resolveAgainstLibrary(widget.library);

    return Focus(
      focusNode: _shortcutFocusNode,
      autofocus: true,
      onKeyEvent: (node, event) => _handleShortcutKeyEvent(event),
      child: Theme(
        data: inheritedTheme.copyWith(
          textTheme: inheritedTheme.textTheme.apply(fontFamily: 'Noto Sans SC'),
          primaryTextTheme: inheritedTheme.primaryTextTheme.apply(
            fontFamily: 'Noto Sans SC',
          ),
        ),
        child: Scaffold(
          backgroundColor: const Color(0xFF0F1014),
          appBar: AppBar(
            title: Text(_title(inclusion, selectedMedia)),
            actions: [
              if (!searching)
                DesktopButtonClickRegion(
                  child: IconButton(
                    tooltip: _psTooltip(
                      _allFoldersExpanded(tree) ? '全部折叠' : '全部展开',
                      PortableSelectionShortcutAction.toggleExpand,
                    ),
                    onPressed: tree.nodes.values.any((node) => node.isFolder)
                        ? AppHaptics.wrap(
                            () => setState(_toggleExpandAll),
                            light: true,
                          )
                        : null,
                    icon: Icon(
                      _allFoldersExpanded(tree)
                          ? Icons.unfold_less_rounded
                          : Icons.unfold_more_rounded,
                    ),
                  ),
                ),
              DesktopButtonClickRegion(
                child: IconButton(
                  tooltip: _psTooltip(
                    allVisibleSelected ? '取消全选' : '全选',
                    PortableSelectionShortcutAction.selectAll,
                  ),
                  onPressed: visibleIds.isEmpty
                      ? null
                      : AppHaptics.wrap(
                          () => setState(() {
                            _selection.setAll(
                              tree,
                              visibleIds,
                              !allVisibleSelected,
                            );
                          }),
                          light: true,
                        ),
                  icon: Icon(
                    allVisibleSelected
                        ? Icons.deselect_rounded
                        : Icons.select_all_rounded,
                  ),
                ),
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: TextField(
                    onChanged: (value) => setState(() => _query = value.trim()),
                    decoration: InputDecoration(
                      hintText: '搜索任意层级的媒体或文件夹',
                      prefixIcon: const Icon(Icons.search_rounded),
                      filled: true,
                      fillColor: const Color(0xFF191B22),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    '勾选文件夹会带出其中全部内容；展开后可只选部分卡片。跨层级多选会在导入时还原所在文件夹路径，不会带上未勾选的兄弟项。',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
                Expanded(
                  child: rows.isEmpty
                      ? Center(
                          child: Text(
                            searching ? '没有匹配的媒体或文件夹' : '没有找到可导出的内容',
                            style: const TextStyle(color: Colors.white54),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(8, 0, 8, 100),
                          itemCount: rows.length,
                          itemBuilder: (context, index) {
                            return _buildRow(tree, rows[index]);
                          },
                        ),
                ),
              ],
            ),
          ),
          bottomNavigationBar: SafeArea(
            minimum: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: DesktopButtonClickRegion(
              child: FilledButton.icon(
                onPressed: AppHaptics.wrap(
                  _selection.isEmpty ? null : _continue,
                  light: true,
                ),
                icon: const Icon(Icons.arrow_forward_rounded),
                label: Text(
                  _selection.isEmpty
                      ? '请选择内容'
                      : selectedMedia == 0
                      ? shortcutHintLabel(
                          context,
                          '继续 · ${inclusion.folderCount} 个文件夹',
                          'Enter',
                        )
                      : shortcutHintLabel(
                          context,
                          '继续 · $selectedMedia 个媒体',
                          'Enter',
                        ),
                ),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _title(PortableExportInclusion inclusion, int selectedMedia) {
    if (_selection.isEmpty) return '选择要导出的内容';
    if (selectedMedia == 0) {
      return '已选 ${inclusion.folderCount} 个文件夹';
    }
    if (inclusion.folderCount == 0) return '已选 $selectedMedia 个媒体';
    return '已选 $selectedMedia 个媒体 · ${inclusion.folderCount} 个文件夹';
  }

  bool _allFoldersExpanded(PortableTreeIndex tree) {
    final folders = tree.nodes.values
        .where((node) => node.isFolder)
        .map((node) => node.id)
        .toList(growable: false);
    return folders.isNotEmpty && folders.every(_expanded.contains);
  }

  void _toggleExpandAll() {
    final tree = _tree;
    if (_allFoldersExpanded(tree)) {
      _expanded.clear();
      return;
    }
    _expanded.addAll(
      tree.nodes.values.where((node) => node.isFolder).map((node) => node.id),
    );
  }

  List<_PickerRow> _visibleTreeRows(PortableTreeIndex tree) {
    final rows = <_PickerRow>[];
    void append(String? parentId, int depth) {
      for (final node in tree.childrenOf(parentId)) {
        rows.add(_PickerRow(node: node, depth: depth, searching: false));
        if (node.isFolder && _expanded.contains(node.id)) {
          append(node.id, depth + 1);
        }
      }
    }

    append(null, 0);
    return rows;
  }

  Widget _buildRow(PortableTreeIndex tree, _PickerRow row) {
    final node = row.node;
    final state = _selection.checkState(tree, node.id);
    final checked = state == PortableCheckState.checked;
    final isFolder = node.isFolder;
    final mediaTotal = isFolder ? tree.descendantMediaCount(node.id) : 0;
    final mediaSelected = isFolder
        ? _selection.selectedMediaCount(tree, underFolderId: node.id)
        : 0;
    final subtitle = _subtitle(
      tree,
      node,
      searching: row.searching,
      mediaTotal: mediaTotal,
      mediaSelected: mediaSelected,
      state: state,
    );
    final value = switch (state) {
      PortableCheckState.checked => true,
      PortableCheckState.unchecked => false,
      PortableCheckState.partial => null,
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: checked || state == PortableCheckState.partial
            ? const Color(0xFF202536)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(13),
        child: InkWell(
          borderRadius: BorderRadius.circular(13),
          onTap: () {
            AppHaptics.pulse();
            setState(() {
              if (isFolder && !row.searching) {
                if (!_expanded.add(node.id)) {
                  _expanded.remove(node.id);
                }
              } else {
                _selection.setChecked(tree, node.id, !checked);
              }
            });
          },
          child: Padding(
            padding: EdgeInsets.fromLTRB(4.0 + row.depth * 16.0, 6, 4, 6),
            child: Row(
              children: [
                SizedBox(
                  width: 36,
                  child: isFolder && !row.searching
                      ? DesktopButtonClickRegion(
                          child: IconButton(
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            onPressed: AppHaptics.wrap(
                              () => setState(() {
                                if (!_expanded.add(node.id)) {
                                  _expanded.remove(node.id);
                                }
                              }),
                              light: true,
                            ),
                            icon: Icon(
                              _expanded.contains(node.id)
                                  ? Icons.expand_more_rounded
                                  : Icons.chevron_right_rounded,
                              color: Colors.white70,
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                _Thumb(node: node),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        node.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                ),
                Checkbox(
                  tristate: isFolder,
                  value: value,
                  onChanged: AppHaptics.wrapValue((_) {
                    setState(() {
                      _selection.setChecked(
                        tree,
                        node.id,
                        state != PortableCheckState.checked,
                      );
                    });
                  }),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _subtitle(
    PortableTreeIndex tree,
    PortableTreeNode node, {
    required bool searching,
    required int mediaTotal,
    required int mediaSelected,
    required PortableCheckState state,
  }) {
    final crumbs = tree.breadcrumb(node.parentId);
    final pathLabel = crumbs.isEmpty ? '媒体库根目录' : crumbs.join(' / ');
    if (node.isFolder) {
      final base = mediaTotal == 0
          ? '空文件夹'
          : '$mediaTotal 个媒体 · ${node.childIds.length} 个直接项目';
      final selectionLabel = switch (state) {
        PortableCheckState.checked => '将导出该文件夹全部内容',
        PortableCheckState.partial => '已选 $mediaSelected / $mediaTotal 个媒体',
        PortableCheckState.unchecked => '展开后可只选其中部分卡片',
      };
      return searching
          ? '$pathLabel\n$base · $selectionLabel'
          : '$base · $selectionLabel';
    }
    final kind = node.isOnline
        ? 'Bilibili 在线卡片 · 不打包视频缓存'
        : (node.fileName == null || node.fileName!.isEmpty
              ? (node.mediaTypeAudio ? '音频' : '视频')
              : p.basename(node.fileName!));
    return searching ? '$pathLabel\n$kind' : kind;
  }
}

class _PickerRow {
  const _PickerRow({
    required this.node,
    required this.depth,
    required this.searching,
  });

  final PortableTreeNode node;
  final int depth;
  final bool searching;
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.node});

  final PortableTreeNode node;

  @override
  Widget build(BuildContext context) {
    final hasThumb =
        node.thumbnailPath != null && node.thumbnailPath!.trim().isNotEmpty;
    final fallback = Icon(
      node.isFolder
          ? Icons.folder_rounded
          : node.isOnline
          ? Icons.cloud_outlined
          : node.mediaTypeAudio
          ? Icons.audiotrack_rounded
          : Icons.movie_outlined,
      color: node.isFolder
          ? const Color(0xFFFFCC66)
          : node.isOnline
          ? const Color(0xFFFF8FAB)
          : const Color(0xFF9DBDFF),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 56,
        height: 32,
        color: node.isFolder
            ? const Color(0xFF4C4020)
            : const Color(0xFF243352),
        child: hasThumb
            ? CachedThumbnailWidget(
                videoId: node.id,
                thumbnailPath: node.thumbnailPath,
                fit: BoxFit.cover,
                cacheWidth: 112,
                cacheHeight: 64,
                placeholder: Center(child: fallback),
                errorWidget: Center(child: fallback),
              )
            : Center(child: fallback),
      ),
    );
  }
}
