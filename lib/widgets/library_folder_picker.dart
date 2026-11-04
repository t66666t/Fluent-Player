import 'package:flutter/material.dart';

import '../models/video_collection.dart';
import '../services/library_service.dart';
import '../theme/app_tokens.dart';
import 'cached_thumbnail_widget.dart';
import 'folder_placeholder_cover.dart';
import 'keyboard_inset_padding.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Screens at least this wide get the picker as a centred dialog; narrower
/// ones get a bottom sheet.
const double kLibraryFolderPickerWideBreakpoint = 600;

enum LibraryFolderPickerMode { destination, singleFolder }

/// Result of [showLibraryFolderPicker].
class LibraryFolderPick {
  const LibraryFolderPick({required this.folderId, required this.setAsDefault});

  /// The chosen folder; null is the library root.
  final String? folderId;

  /// "设为默认位置" was ticked.
  final bool setAsDefault;
}

/// Lets the user choose a media library folder: breadcrumb path, folders in
/// the media library's style with their item counts, a search across all
/// levels, "new folder" in the current level and a fixed confirm bar.
///
/// [header] is shown above the folders (for example the parts to import).
/// [mode] can require an explicit, single folder selection instead of using
/// the current location as an import destination. The library root cannot be
/// selected in that mode, and browsing does not change the selection.
Future<LibraryFolderPick?> showLibraryFolderPicker(
  BuildContext context, {
  required LibraryService library,
  String? initialFolderId,
  String title = '选择位置',
  String confirmLabel = '导入到这里',
  bool offerSetAsDefault = true,
  bool setAsDefaultInitially = true,
  LibraryFolderPickerMode mode = LibraryFolderPickerMode.destination,
  Color accent = AppTokens.accent,
  WidgetBuilder? header,
}) {
  Widget picker(BuildContext _) => LibraryFolderPicker(
    library: library,
    initialFolderId: initialFolderId,
    title: title,
    confirmLabel: confirmLabel,
    offerSetAsDefault: offerSetAsDefault,
    setAsDefaultInitially: setAsDefaultInitially,
    mode: mode,
    accent: accent,
    header: header,
  );

  final size = MediaQuery.sizeOf(context);
  if (size.width >= kLibraryFolderPickerWideBreakpoint) {
    return showDialog<LibraryFolderPick>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetAnimationDuration: Duration.zero,
        key: const ValueKey('library-folder-picker-dialog'),
        backgroundColor: AppTokens.bgRaised,
        insetPadding: const EdgeInsets.all(24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 520,
          height: (size.height - 48).clamp(320.0, 620.0),
          child: picker(dialogContext),
        ),
      ),
    );
  }
  return showModalBottomSheet<LibraryFolderPick>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AppTokens.bgRaised,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    clipBehavior: Clip.antiAlias,
    builder: (sheetContext) => KeyboardInsetPadding(
      key: const ValueKey('library-folder-picker-sheet'),
      child: SizedBox(height: size.height * 0.78, child: picker(sheetContext)),
    ),
  );
}

class LibraryFolderPicker extends StatefulWidget {
  const LibraryFolderPicker({
    super.key,
    required this.library,
    this.initialFolderId,
    this.title = '选择位置',
    this.confirmLabel = '导入到这里',
    this.offerSetAsDefault = true,
    this.setAsDefaultInitially = true,
    this.mode = LibraryFolderPickerMode.destination,
    this.showTitleBar = true,
    this.accent = AppTokens.accent,
    this.header,
  });

  final LibraryService library;
  final String? initialFolderId;
  final String title;
  final String confirmLabel;
  final bool offerSetAsDefault;
  final bool setAsDefaultInitially;
  final LibraryFolderPickerMode mode;

  /// Hide when the picker is embedded in a page with its own app bar.
  final bool showTitleBar;
  final Color accent;
  final WidgetBuilder? header;

  @override
  State<LibraryFolderPicker> createState() => _LibraryFolderPickerState();
}

class _LibraryFolderPickerState extends State<LibraryFolderPicker> {
  final TextEditingController _query = TextEditingController();
  final TextEditingController _newName = TextEditingController();
  final ScrollController _breadcrumbScroll = ScrollController();
  String? _currentId;
  String? _selectedId;
  late bool _setAsDefault = widget.setAsDefaultInitially;
  bool _creating = false;

  LibraryService get _library => widget.library;
  bool get _singleFolder => widget.mode == LibraryFolderPickerMode.singleFolder;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialFolderId;
    if (initial != null && _isLiveFolder(initial)) {
      _currentId = initial;
      if (_singleFolder) _selectedId = initial;
    }
    _query.addListener(() => setState(() {}));
    _revealBreadcrumbTail();
  }

  @override
  void dispose() {
    _query.dispose();
    _newName.dispose();
    _breadcrumbScroll.dispose();
    super.dispose();
  }

  bool _isLiveFolder(String id) {
    final seen = <String>{};
    String? cursor = id;
    while (cursor != null) {
      if (!seen.add(cursor)) return false;
      final folder = _library.getCollection(cursor);
      if (folder == null ||
          folder.isRecycled ||
          folder.isPodcast ||
          folder.isHiddenFromFolders) {
        return false;
      }
      cursor = folder.parentId;
    }
    return true;
  }

  /// Folders from the root down to [id], [id] last.
  List<VideoCollection> _pathTo(String? id) {
    final path = <VideoCollection>[];
    final seen = <String>{};
    var cursor = id;
    while (cursor != null && seen.add(cursor)) {
      final folder = _library.getCollection(cursor);
      if (folder == null) break;
      path.insert(0, folder);
      cursor = folder.parentId;
    }
    return path;
  }

  List<VideoCollection> _foldersIn(String? parentId) => <VideoCollection>[
    for (final child in _library.getContents(parentId))
      if (child is VideoCollection && !child.isRecycled && !child.isPodcast)
        child,
  ];

  int _itemCount(String folderId) => _library.getContents(folderId).length;

  List<VideoCollection> _search(String query) {
    final needle = query.toLowerCase();
    final found = <VideoCollection>[];
    final seen = <String>{};
    void walk(String? parentId) {
      for (final folder in _foldersIn(parentId)) {
        if (!seen.add(folder.id)) continue;
        if (folder.name.toLowerCase().contains(needle)) found.add(folder);
        walk(folder.id);
      }
    }

    walk(null);
    return found;
  }

  void _open(String? folderId) {
    setState(() {
      _currentId = folderId;
      _creating = false;
      _query.clear();
    });
    _revealBreadcrumbTail();
  }

  /// A short trail must stay on the left. `reverse` on the scroller would
  /// pin it to the right once the bar is full width, so overflow instead
  /// jumps to the current folder after layout.
  void _revealBreadcrumbTail() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_breadcrumbScroll.hasClients) return;
      final position = _breadcrumbScroll.position;
      if (!position.hasContentDimensions) return;
      final max = position.maxScrollExtent;
      if (max <= 0 || position.pixels == max) return;
      position.jumpTo(max);
    });
  }

  /// Android back and desktop Esc walk out one step at a time: the
  /// new-folder field, then search, then the parent folder. Only the
  /// library root closes the picker. The close and confirm buttons call
  /// [Navigator.pop], which still leaves immediately.
  void _onSystemBack() {
    if (_creating) {
      setState(() => _creating = false);
      return;
    }
    if (_query.text.trim().isNotEmpty) {
      _query.clear();
      return;
    }
    if (_currentId != null) {
      _open(_library.getCollection(_currentId!)?.parentId);
    }
  }

  Future<void> _createFolder() async {
    final name = _newName.text.trim();
    if (name.isEmpty) return;
    final folder = await _library.createCollection(name, _currentId);
    if (!mounted) return;
    _newName.clear();
    _open(folder.id);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _library,
      builder: (context, _) {
        if (_currentId != null && !_isLiveFolder(_currentId!)) {
          _currentId = null;
        }
        if (_selectedId != null && !_isLiveFolder(_selectedId!)) {
          _selectedId = null;
        }
        final query = _query.text.trim();
        // Stretch so the breadcrumb bar takes the full width. The column's
        // default center alignment would otherwise center a shrink-wrapped
        // trail once a folder is selected.
        return PopScope(
          canPop: _currentId == null && !_creating && query.isEmpty,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            _onSystemBack();
          },
          child: Material(
            color: AppTokens.bgRaised,
            child: RadioGroup<String>(
              groupValue: _selectedId,
              onChanged: (id) => setState(() => _selectedId = id),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: CustomScrollView(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      slivers: [
                        SliverToBoxAdapter(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (widget.showTitleBar) _buildTitleBar(context),
                              _buildBreadcrumb(),
                              _buildToolbar(),
                              if (_creating) _buildNewFolderRow(),
                              if (widget.header != null)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    4,
                                    16,
                                    4,
                                  ),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: widget.header!(context),
                                  ),
                                ),
                              if (_singleFolder &&
                                  _currentId != null &&
                                  query.isEmpty)
                                _buildCurrentFolderSelection(),
                              const Divider(
                                height: 1,
                                color: AppTokens.lineSubtle,
                              ),
                            ],
                          ),
                        ),
                        query.isEmpty ? _buildFolders() : _buildResults(query),
                      ],
                    ),
                  ),
                  _buildConfirmBar(context),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTitleBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
      child: Row(
        children: [
          DesktopButtonClickRegion(
            child: IconButton(
              key: const ValueKey('folder-picker-up'),
              tooltip: '上一级',
              onPressed: _currentId == null
                  ? null
                  : () => _open(_library.getCollection(_currentId!)?.parentId),
              icon: const Icon(Icons.arrow_back_rounded),
              color: AppTokens.text1,
              disabledColor: AppTokens.text4,
            ),
          ),
          Expanded(
            child: Text(
              widget.title,
              style: const TextStyle(
                color: AppTokens.text1,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          DesktopButtonClickRegion(
            child: IconButton(
              tooltip: '关闭',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close_rounded),
              color: AppTokens.text2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBreadcrumb() {
    final path = _pathTo(_currentId);
    Widget crumb(String key, String label, String? folderId, bool last) {
      return DesktopButtonClickRegion(
        child: TextButton(
          key: ValueKey('folder-picker-crumb-$key'),
          onPressed: last ? null : () => _open(folderId),
          style: TextButton.styleFrom(
            foregroundColor: AppTokens.text2,
            disabledForegroundColor: AppTokens.text1,
            minimumSize: const Size(0, 32),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: last ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      );
    }

    const separator = Icon(
      Icons.chevron_right_rounded,
      size: 16,
      color: AppTokens.text3,
    );
    return SizedBox(
      height: 36,
      child: Align(
        alignment: Alignment.centerLeft,
        child: SingleChildScrollView(
          key: const ValueKey('folder-picker-breadcrumb'),
          controller: _breadcrumbScroll,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              crumb('root', '媒体库', null, path.isEmpty),
              for (var i = 0; i < path.length; i++) ...[
                separator,
                crumb(
                  path[i].id,
                  path[i].name,
                  path[i].id,
                  i == path.length - 1,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 12, 6),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 36,
              child: TextField(
                key: const ValueKey('folder-picker-search'),
                controller: _query,
                style: const TextStyle(color: AppTokens.text1, fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '搜索文件夹',
                  hintStyle: const TextStyle(color: AppTokens.text3),
                  prefixIcon: const Icon(
                    Icons.search_rounded,
                    size: 18,
                    color: AppTokens.text3,
                  ),
                  filled: true,
                  fillColor: AppTokens.bgCard,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          ),
          if (!_singleFolder) ...[
            const SizedBox(width: 8),
            DesktopButtonClickRegion(
              child: TextButton.icon(
                key: const ValueKey('folder-picker-new'),
                onPressed: () => setState(() => _creating = !_creating),
                style: TextButton.styleFrom(foregroundColor: widget.accent),
                icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                label: const Text('新建文件夹', style: TextStyle(fontSize: 13)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildNewFolderRow() {
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 12, 6),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('folder-picker-new-name'),
              controller: _newName,
              autofocus: true,
              style: const TextStyle(color: AppTokens.text1, fontSize: 13),
              onSubmitted: (_) => _createFolder(),
              decoration: InputDecoration(
                isDense: true,
                hintText: '新文件夹名称',
                hintStyle: const TextStyle(color: AppTokens.text3),
                filled: true,
                fillColor: AppTokens.bgCard,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          DesktopButtonClickRegion(
            child: IconButton(
              key: const ValueKey('folder-picker-new-confirm'),
              tooltip: '创建',
              onPressed: _createFolder,
              icon: Icon(Icons.check_rounded, color: widget.accent),
            ),
          ),
        ],
      ),
    );
    return TextFieldTapRegion(child: row);
  }

  Widget _buildFolders() {
    final folders = _foldersIn(_currentId);
    if (folders.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Text(
            _singleFolder && _currentId == null
                ? '媒体库里还没有文件夹，请先在媒体库添加。'
                : '这里没有子文件夹',
            style: const TextStyle(color: AppTokens.text3, fontSize: 13),
          ),
        ),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      sliver: SliverList.separated(
        itemCount: folders.length,
        separatorBuilder: (_, _) => const SizedBox(height: 6),
        itemBuilder: (context, index) {
          final folder = folders[index];
          return _FolderRow(
            folder: folder,
            subtitle: '${_itemCount(folder.id)} 项',
            onTap: () => _open(folder.id),
            selector: _singleFolder ? _buildSelector(folder.id) : null,
            selected: _singleFolder && _selectedId == folder.id,
            accent: widget.accent,
          );
        },
      ),
    );
  }

  Widget _buildResults(String query) {
    final found = _search(query);
    if (found.isEmpty) {
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Text(
            '没有找到文件夹',
            style: TextStyle(color: AppTokens.text3, fontSize: 13),
          ),
        ),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      sliver: SliverList.separated(
        itemCount: found.length,
        separatorBuilder: (_, _) => const SizedBox(height: 6),
        itemBuilder: (context, index) {
          final folder = found[index];
          final parents = _pathTo(folder.parentId).map((f) => f.name);
          final location = ['媒体库', ...parents].join(' / ');
          return _FolderRow(
            folder: folder,
            subtitle: '$location · ${_itemCount(folder.id)} 项',
            onTap: () => _open(folder.id),
            selector: _singleFolder ? _buildSelector(folder.id) : null,
            selected: _singleFolder && _selectedId == folder.id,
            accent: widget.accent,
          );
        },
      ),
    );
  }

  Widget _buildSelector(String id) => Tooltip(
    message: '选择此文件夹',
    child: Radio<String>(
      key: ValueKey('folder-picker-select-$id'),
      value: id,
      activeColor: widget.accent,
    ),
  );

  Widget _buildCurrentFolderSelection() => RadioListTile<String>(
    key: const ValueKey('folder-picker-select-current'),
    value: _currentId!,
    activeColor: widget.accent,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
    title: const Text(
      '选择当前文件夹',
      style: TextStyle(color: AppTokens.text1, fontSize: 13),
    ),
    subtitle: Text(
      _library.getCollection(_currentId!)!.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(color: AppTokens.text3, fontSize: 12),
    ),
  );

  Widget _buildSingleFolderConfirmBar(BuildContext context) {
    final selectedPath = _selectedId == null
        ? '尚未选择文件夹'
        : '已选：媒体库 / ${_pathTo(_selectedId).map((f) => f.name).join(' / ')}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: selectedPath,
            child: Text(
              selectedPath,
              key: const ValueKey('folder-picker-selection'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppTokens.text2, fontSize: 12),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              DesktopButtonClickRegion(
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
              ),
              const SizedBox(width: 8),
              DesktopButtonClickRegion(
                child: FilledButton(
                  key: const ValueKey('folder-picker-confirm'),
                  style: FilledButton.styleFrom(
                    backgroundColor: widget.accent,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: _selectedId == null
                      ? null
                      : () => Navigator.of(context).pop(
                          LibraryFolderPick(
                            folderId: _selectedId,
                            setAsDefault: false,
                          ),
                        ),
                  child: Text(widget.confirmLabel),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildConfirmBar(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: AppTokens.bgOverlay,
        border: Border(top: BorderSide(color: AppTokens.lineSubtle)),
      ),
      child: SafeArea(
        top: false,
        child: _singleFolder
            ? _buildSingleFolderConfirmBar(context)
            : Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
                child: Wrap(
                  alignment: widget.offerSetAsDefault
                      ? WrapAlignment.spaceBetween
                      : WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    if (widget.offerSetAsDefault)
                      InkWell(
                        key: const ValueKey('folder-picker-set-default'),
                        borderRadius: BorderRadius.circular(8),
                        onTap: () =>
                            setState(() => _setAsDefault = !_setAsDefault),
                        child: Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Checkbox(
                                value: _setAsDefault,
                                activeColor: widget.accent,
                                onChanged: (value) => setState(
                                  () => _setAsDefault = value ?? false,
                                ),
                              ),
                              const Text(
                                '设为默认位置',
                                style: TextStyle(
                                  color: AppTokens.text2,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    DesktopButtonClickRegion(
                      child: FilledButton.icon(
                        key: const ValueKey('folder-picker-confirm'),
                        style: FilledButton.styleFrom(
                          backgroundColor: widget.accent,
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () => Navigator.of(context).pop(
                          LibraryFolderPick(
                            folderId: _currentId,
                            setAsDefault:
                                widget.offerSetAsDefault && _setAsDefault,
                          ),
                        ),
                        icon: const Icon(Icons.download_done_rounded, size: 18),
                        label: Text(widget.confirmLabel),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// A folder row in the media library's list style: rounded card with a
/// thin border and a square cover (the folder's cover or its placeholder).
class _FolderRow extends StatelessWidget {
  const _FolderRow({
    required this.folder,
    required this.subtitle,
    required this.onTap,
    this.selector,
    this.selected = false,
    this.accent = AppTokens.accent,
  });

  final VideoCollection folder;
  final String subtitle;
  final VoidCallback onTap;
  final Widget? selector;
  final bool selected;
  final Color accent;

  static const double _extent = 44;

  @override
  Widget build(BuildContext context) {
    final placeholder = FolderPlaceholderCover(
      folderId: folder.id,
      folderName: folder.name,
      coverLabel: folder.coverLabel,
    );
    final thumbnail = folder.thumbnailPath;
    return Material(
      key: ValueKey('folder-picker-folder-${folder.id}'),
      color: selected ? accent.withValues(alpha: 0.08) : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected ? accent : Colors.white.withValues(alpha: 0.075),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        hoverColor: Colors.white.withValues(alpha: 0.045),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Row(
            children: [
              ?selector,
              SizedBox.square(
                dimension: _extent,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(_extent * 0.14),
                  child: ColoredBox(
                    color: const Color(0xFF17191D),
                    child: thumbnail != null && thumbnail.isNotEmpty
                        ? CachedThumbnailWidget(
                            videoId: folder.id,
                            thumbnailPath: thumbnail,
                            fit: BoxFit.cover,
                            placeholder: placeholder,
                            errorWidget: placeholder,
                          )
                        : placeholder,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      folder.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTokens.text1,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTokens.text3,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                color: AppTokens.text3,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
