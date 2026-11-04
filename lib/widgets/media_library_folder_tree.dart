import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/video_collection.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
import '../theme/app_tokens.dart';
import 'media_library_view_defaults.dart';

/// Parses a nested library folder route name into a folder id.
String? mediaLibraryFolderIdFromRouteName(String? routeName) {
  const prefix = 'media-library-folder:';
  if (routeName == null || !routeName.startsWith(prefix)) return null;
  final id = routeName.substring(prefix.length);
  return id.isEmpty ? null : id;
}

/// Folder-tree state owned by [MediaLibraryShell]: expansion, selection and
/// scroll position survive route changes on the right-hand navigator.
class MediaLibraryFolderTreeController extends ChangeNotifier {
  MediaLibraryFolderTreeController();

  final ScrollController scrollController = ScrollController();

  final Set<String> _expandedFolderIds = <String>{};
  String? _selectedFolderId;
  int _keyboardFocusIndex = 0;

  String? get selectedFolderId => _selectedFolderId;

  int get keyboardFocusIndex => _keyboardFocusIndex;

  bool isExpanded(String folderId) => _expandedFolderIds.contains(folderId);

  void setKeyboardFocusIndex(int index) {
    if (_keyboardFocusIndex == index) return;
    _keyboardFocusIndex = index;
    notifyListeners();
  }

  void toggleExpanded(String folderId) {
    if (!_expandedFolderIds.remove(folderId)) {
      _expandedFolderIds.add(folderId);
    }
    notifyListeners();
  }

  void setExpanded(String folderId, bool expanded) {
    final changed = expanded
        ? _expandedFolderIds.add(folderId)
        : _expandedFolderIds.remove(folderId);
    if (!changed) return;
    notifyListeners();
  }

  /// Aligns the tree with the nested navigator and opens ancestors of [folderId].
  void syncSelection(String? folderId, LibraryService library) {
    _ensureAncestorsExpanded(folderId, library);
    if (_selectedFolderId == folderId) return;
    _selectedFolderId = folderId;
    notifyListeners();
  }

  void _ensureAncestorsExpanded(String? folderId, LibraryService library) {
    var id = folderId;
    final visited = <String>{};
    while (id != null && visited.add(id)) {
      _expandedFolderIds.add(id);
      id = library.getCollection(id)?.parentId;
    }
  }

  @override
  void dispose() {
    scrollController.dispose();
    super.dispose();
  }
}

/// One visible row in the flattened folder tree.
@immutable
class _FolderTreeRow {
  const _FolderTreeRow({
    required this.folderId,
    required this.label,
    required this.depth,
    required this.hasChildFolders,
    this.itemCount,
  });

  /// Null marks the synthetic library root row.
  final String? folderId;
  final String label;
  final int depth;
  final bool hasChildFolders;
  final int? itemCount;
}

/// Left sidebar listing folders; data comes from [LibraryService].
class MediaLibraryFolderTreePane extends StatefulWidget {
  const MediaLibraryFolderTreePane({
    super.key,
    required this.controller,
    required this.onFolderSelected,
    required this.onCollapseSidebar,
    this.showCounts = true,
  });

  final MediaLibraryFolderTreeController controller;
  final ValueChanged<String?> onFolderSelected;
  final VoidCallback onCollapseSidebar;
  final bool showCounts;

  @visibleForTesting
  static const Key paneKey = Key('media-library-folder-tree-pane');

  @override
  State<MediaLibraryFolderTreePane> createState() =>
      _MediaLibraryFolderTreePaneState();
}

class _MediaLibraryFolderTreePaneState
    extends State<MediaLibraryFolderTreePane> {
  final FocusNode _focusNode = FocusNode(
    debugLabel: 'media-library-folder-tree',
  );

  Duration get _motion => MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 200);

  Curve get _curve => Curves.easeOutCubic;

  static SettingsService? _maybeSettings(BuildContext context) {
    try {
      return Provider.of<SettingsService>(context, listen: true);
    } on ProviderNotFoundException {
      return null;
    }
  }

  static LibraryService? _maybeLibrary(BuildContext context) {
    try {
      return Provider.of<LibraryService>(context, listen: true);
    } on ProviderNotFoundException {
      return null;
    }
  }

  List<VideoCollection> _childFolders(
    LibraryService library,
    String? parentId,
  ) {
    return library
        .getContents(parentId)
        .whereType<VideoCollection>()
        .toList(growable: false);
  }

  int? _itemCount(LibraryService library, String folderId, bool showCounts) {
    if (!showCounts) return null;
    return library.getContents(folderId).length;
  }

  List<_FolderTreeRow> _visibleRows(LibraryService library, bool showCounts) {
    final rows = <_FolderTreeRow>[
      const _FolderTreeRow(
        folderId: null,
        label: '媒体库',
        depth: 0,
        hasChildFolders: true,
      ),
    ];
    void walk(String? parentId, int depth) {
      for (final folder in _childFolders(library, parentId)) {
        final hasChildFolders = _childFolders(library, folder.id).isNotEmpty;
        rows.add(
          _FolderTreeRow(
            folderId: folder.id,
            label: folder.name,
            depth: depth,
            hasChildFolders: hasChildFolders,
            itemCount: _itemCount(library, folder.id, showCounts),
          ),
        );
        if (widget.controller.isExpanded(folder.id)) {
          walk(folder.id, depth + 1);
        }
      }
    }

    walk(null, 1);
    return rows;
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final library = _maybeLibrary(context);
    if (library == null) return KeyEventResult.ignored;
    final rows = _visibleRows(library, widget.showCounts);
    if (rows.isEmpty) return KeyEventResult.ignored;
    var index = widget.controller.keyboardFocusIndex.clamp(0, rows.length - 1);

    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        index = (index + 1).clamp(0, rows.length - 1);
        widget.controller.setKeyboardFocusIndex(index);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        index = (index - 1).clamp(0, rows.length - 1);
        widget.controller.setKeyboardFocusIndex(index);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        final row = rows[index];
        if (row.folderId != null &&
            row.hasChildFolders &&
            !widget.controller.isExpanded(row.folderId!)) {
          widget.controller.setExpanded(row.folderId!, true);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
        final row = rows[index];
        if (row.folderId != null &&
            row.hasChildFolders &&
            widget.controller.isExpanded(row.folderId!)) {
          widget.controller.setExpanded(row.folderId!, false);
        } else if (row.folderId != null) {
          final parentId = library.getCollection(row.folderId!)?.parentId;
          final parentIndex = rows.indexWhere((r) => r.folderId == parentId);
          if (parentIndex >= 0) {
            widget.controller.setKeyboardFocusIndex(parentIndex);
          }
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        widget.onFolderSelected(rows[index].folderId);
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final library = _maybeLibrary(context);
    final settings = _maybeSettings(context);
    final showCounts =
        widget.showCounts && (settings?.mediaTreeShowCounts ?? true);

    // Material gives descendant Text a proper DefaultTextStyle (no debug
    // underline) and hosts the ink of every row.
    return Material(
      color: AppTokens.bgRaised,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TreeHeader(onCollapse: widget.onCollapseSidebar),
          Expanded(
            child: Focus(
              focusNode: _focusNode,
              onKeyEvent: _handleKey,
              onFocusChange: (_) => setState(() {}),
              child: ListenableBuilder(
                listenable: widget.controller,
                builder: (context, _) {
                  final rows = library == null
                      ? const <_FolderTreeRow>[]
                      : _visibleRows(library, showCounts);
                  return ListView.builder(
                    key: MediaLibraryFolderTreePane.paneKey,
                    controller: widget.controller.scrollController,
                    padding: const EdgeInsets.fromLTRB(8, 2, 8, 12),
                    itemCount: rows.length,
                    itemBuilder: (context, index) {
                      final row = rows[index];
                      final selected =
                          row.folderId == widget.controller.selectedFolderId;
                      // The keyboard ring only appears while the tree is
                      // actually being driven from the keyboard.
                      final focused =
                          _focusNode.hasFocus &&
                          index == widget.controller.keyboardFocusIndex;
                      return _FolderTreeTile(
                        row: row,
                        selected: selected,
                        focused: focused,
                        expanded: row.folderId == null
                            ? true
                            : widget.controller.isExpanded(row.folderId!),
                        motion: _motion,
                        curve: _curve,
                        onTap: () {
                          widget.controller.setKeyboardFocusIndex(index);
                          widget.onFolderSelected(row.folderId);
                        },
                        onExpandTap:
                            row.folderId == null || !row.hasChildFolders
                            ? null
                            : () => widget.controller.toggleExpanded(
                                row.folderId!,
                              ),
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small caption row above the tree, styled like a sidebar section label.
class _TreeHeader extends StatelessWidget {
  const _TreeHeader({required this.onCollapse});

  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                '文件夹',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                  color: AppTokens.text3,
                ),
              ),
            ),
            IconButton(
              tooltip: '收起侧栏',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 28, height: 28),
              style: IconButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              onPressed: onCollapse,
              icon: const Icon(
                Icons.keyboard_double_arrow_left_rounded,
                size: 17,
                color: AppTokens.text3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FolderTreeTile extends StatefulWidget {
  const _FolderTreeTile({
    required this.row,
    required this.selected,
    required this.focused,
    required this.expanded,
    required this.motion,
    required this.curve,
    required this.onTap,
    this.onExpandTap,
  });

  final _FolderTreeRow row;
  final bool selected;
  final bool focused;
  final bool expanded;
  final Duration motion;
  final Curve curve;
  final VoidCallback onTap;
  final VoidCallback? onExpandTap;

  @override
  State<_FolderTreeTile> createState() => _FolderTreeTileState();
}

class _FolderTreeTileState extends State<_FolderTreeTile> {
  bool _hovered = false;

  static const double _rowHeight = 30;
  static const double _indentStep = 14;

  @override
  Widget build(BuildContext context) {
    final isRoot = widget.row.folderId == null;
    // Top-level folders sit flush with the root row; deeper levels step in.
    final indent = isRoot ? 0.0 : (widget.row.depth - 1) * _indentStep;
    final Color bg;
    if (widget.selected) {
      bg = const Color(0x17FFFFFF);
    } else if (_hovered) {
      bg = const Color(0x0AFFFFFF);
    } else {
      bg = const Color(0x00FFFFFF);
    }

    final IconData icon;
    final Color iconColor;
    if (isRoot) {
      icon = Icons.video_library_outlined;
      iconColor = widget.selected ? AppTokens.text1 : AppTokens.text2;
    } else {
      icon = widget.selected ? Icons.folder_open_rounded : Icons.folder_rounded;
      iconColor = widget.selected
          ? AppTokens.accent
          : AppTokens.accent.withValues(alpha: 0.78);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 1),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          hoverColor: Colors.transparent,
          splashColor: AppTokens.accent.withValues(alpha: 0.08),
          highlightColor: Colors.white.withValues(alpha: 0.03),
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: widget.motion,
            curve: widget.curve,
            height: _rowHeight,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(6),
            ),
            foregroundDecoration: widget.focused
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: AppTokens.accent.withValues(alpha: 0.45),
                    ),
                  )
                : null,
            child: Row(
              children: [
                SizedBox(width: 2 + indent),
                _ExpandGlyph(
                  visible: widget.row.hasChildFolders && !isRoot,
                  expanded: widget.expanded,
                  motion: widget.motion,
                  onTap: widget.onExpandTap,
                ),
                Icon(icon, size: 16, color: iconColor),
                const SizedBox(width: 8),
                Expanded(
                  child: AnimatedDefaultTextStyle(
                    duration: widget.motion,
                    curve: widget.curve,
                    // Merge so the inherited font family survives.
                    style: DefaultTextStyle.of(context).style.merge(
                      TextStyle(
                        fontSize: 13,
                        height: 1.2,
                        color: widget.selected || _hovered
                            ? AppTokens.text1
                            : AppTokens.text2,
                        fontWeight: widget.selected || isRoot
                            ? FontWeight.w500
                            : FontWeight.w400,
                      ),
                    ),
                    child: Text(
                      widget.row.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                if (widget.row.itemCount != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 6, right: 8),
                    child: Text(
                      '${widget.row.itemCount}',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: widget.selected
                            ? AppTokens.text3
                            : AppTokens.text4,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  )
                else
                  const SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Disclosure chevron; keeps its slot when hidden so labels stay aligned.
class _ExpandGlyph extends StatelessWidget {
  const _ExpandGlyph({
    required this.visible,
    required this.expanded,
    required this.motion,
    this.onTap,
  });

  final bool visible;
  final bool expanded;
  final Duration motion;
  final VoidCallback? onTap;

  static const double _width = 20;

  @override
  Widget build(BuildContext context) {
    if (!visible) {
      return const SizedBox(width: _width);
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: _width,
        height: 30,
        child: Center(
          child: AnimatedRotation(
            turns: expanded ? 0.25 : 0,
            duration: motion,
            curve: Curves.easeOutCubic,
            child: const Icon(
              Icons.chevron_right_rounded,
              size: 16,
              color: AppTokens.text3,
            ),
          ),
        ),
      ),
    );
  }
}

/// Drag handle between the tree and the library content; persists width on
/// pointer up and restores the default width on double-click.
class MediaLibraryFolderTreeResizeHandle extends StatefulWidget {
  const MediaLibraryFolderTreeResizeHandle({
    super.key,
    required this.onDragDelta,
    required this.onDragEnd,
    required this.onResetWidth,
  });

  final ValueChanged<double> onDragDelta;
  final VoidCallback onDragEnd;
  final VoidCallback onResetWidth;

  @visibleForTesting
  static const Key handleKey = Key('media-library-folder-tree-resize');

  @override
  State<MediaLibraryFolderTreeResizeHandle> createState() =>
      _MediaLibraryFolderTreeResizeHandleState();
}

class _MediaLibraryFolderTreeResizeHandleState
    extends State<MediaLibraryFolderTreeResizeHandle> {
  bool _hovered = false;
  bool _dragging = false;

  Duration get _motion => MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 140);

  @override
  Widget build(BuildContext context) {
    final active = _hovered || _dragging;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        key: MediaLibraryFolderTreeResizeHandle.handleKey,
        behavior: HitTestBehavior.translucent,
        onDoubleTap: widget.onResetWidth,
        onHorizontalDragStart: (_) => setState(() => _dragging = true),
        onHorizontalDragUpdate: (details) =>
            widget.onDragDelta(details.delta.dx),
        onHorizontalDragEnd: (_) {
          setState(() => _dragging = false);
          widget.onDragEnd();
        },
        onHorizontalDragCancel: () {
          setState(() => _dragging = false);
          widget.onDragEnd();
        },
        child: SizedBox(
          width: 6,
          child: Center(
            child: AnimatedContainer(
              duration: _motion,
              curve: Curves.easeOutCubic,
              width: active ? 2 : 1,
              color: active ? AppTokens.accent : AppTokens.lineSubtle,
            ),
          ),
        ),
      ),
    );
  }
}

/// Thin edge control that re-expands a collapsed docked tree pane.
class MediaLibraryFolderTreeExpandHandle extends StatelessWidget {
  const MediaLibraryFolderTreeExpandHandle({
    super.key,
    required this.onPressed,
  });

  final VoidCallback onPressed;

  @visibleForTesting
  static const Key handleKey = Key('media-library-folder-tree-expand');

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTokens.bgRaised,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox(
          width: 28,
          child: Center(
            child: IconButton(
              key: handleKey,
              tooltip: '展开文件夹树',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              onPressed: onPressed,
              icon: const Icon(
                Icons.account_tree_outlined,
                size: 18,
                color: AppTokens.text2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Clamps a sidebar width to user and responsive limits.
double clampMediaLibraryTreeSidebarWidth({
  required double width,
  required double windowWidth,
}) {
  final maxByFraction =
      windowWidth * MediaLibraryViewDefaults.treeMaxWidthFraction;
  var maxWidth = MediaLibraryViewDefaults.maxTreeSidebarWidth < maxByFraction
      ? MediaLibraryViewDefaults.maxTreeSidebarWidth
      : maxByFraction;
  var minWidth = MediaLibraryViewDefaults.minTreeSidebarWidth;
  if (maxWidth < minWidth) {
    minWidth = maxWidth;
  }
  return width.clamp(minWidth, maxWidth);
}
