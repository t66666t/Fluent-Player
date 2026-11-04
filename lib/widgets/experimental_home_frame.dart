import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/media_library_root_entry.dart';
import '../theme/app_tokens.dart';
import '../models/media_library_root_entry_order.dart';
import 'media_library_entry_switcher.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';
import 'package:video_player_app/widgets/button_aware_drag.dart';

const _surface = Color(0xff191919);
const _accent = Color(0xff90b9ff);

class ExperimentalSidebarAction {
  const ExperimentalSidebarAction(
    this.label,
    this.icon,
    this.onPressed, {
    this.color = AppTokens.text1,
  });
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final Color color;
}

/// Shared by the home scaffold and frame so tools have exactly one owner.
class ExperimentalSidebarMetrics {
  static bool usesSidebar(double width) => width >= 900;
  static double maximumWidth(double width) =>
      math.min(420, math.min(width * .35, width - 560));
  static double resolveWidth(double width, double? fraction) =>
      (fraction == null ? (width * .2).clamp(220.0, 320.0) : width * fraction)
          .clamp(200.0, maximumWidth(width))
          .toDouble();
}

class ExperimentalHomeFrame extends StatefulWidget {
  const ExperimentalHomeFrame({
    super.key,
    required this.selected,
    required this.available,
    required this.onSelected,
    required this.onSettings,
    required this.child,
    this.actions = const [],
    this.bottomObstruction = 0,
    this.shortcutsEnabled,
    this.entries = MediaLibraryRootEntryOrder.defaults,
    this.onReorder,
  });
  final MediaLibraryRootEntry selected;
  final Set<MediaLibraryRootEntry> available;
  final ValueChanged<MediaLibraryRootEntry> onSelected;
  final VoidCallback onSettings;
  final Widget child;
  final List<ExperimentalSidebarAction> actions;
  final double bottomObstruction;
  final bool Function()? shortcutsEnabled;
  final List<MediaLibraryRootEntry> entries;
  final void Function(int oldIndex, int newIndex)? onReorder;
  static const local = [
    MediaLibraryRootEntry.continueLearning,
    MediaLibraryRootEntry.folders,
    MediaLibraryRootEntry.recent,
  ];
  static const online = [
    MediaLibraryRootEntry.bilibili,
    MediaLibraryRootEntry.podcasts,
    MediaLibraryRootEntry.cloudDrive,
  ];
  static const visiblePreference = 'experimentalSidebarVisibleV1';
  static const widthPreference = 'experimentalSidebarWidthFractionV1';
  @override
  State<ExperimentalHomeFrame> createState() => _ExperimentalHomeFrameState();
}

class _ExperimentalHomeFrameState extends State<ExperimentalHomeFrame> {
  final _frameFocus = FocusNode(debugLabel: 'experimental-home');
  final _contentKey = GlobalKey();
  final _sidebarFocus = FocusNode(debugLabel: 'experimental-sidebar');
  final _entryKeys = {
    for (final entry in MediaLibraryRootEntry.values) entry: GlobalKey(),
  };
  late final Future<SharedPreferences> _preferences;
  Future<void> _writes = Future<void>.value();
  bool _visible = true, _touched = false, _dragging = false, _hovering = false;
  double? _fraction;

  @override
  void initState() {
    super.initState();
    _preferences = SharedPreferences.getInstance();
    unawaited(_restore());
  }

  Future<void> _restore() async {
    final prefs = await _preferences;
    if (!mounted || _touched) return;
    final saved = prefs.getDouble(ExperimentalHomeFrame.widthPreference);
    setState(() {
      _visible = prefs.getBool(ExperimentalHomeFrame.visiblePreference) ?? true;
      _fraction = saved != null && saved.isFinite && saved > 0 ? saved : null;
    });
  }

  void _persist() {
    final visible = _visible;
    final fraction = _fraction;
    _writes = _writes
        .then((_) async {
          final prefs = await _preferences;
          await prefs.setBool(ExperimentalHomeFrame.visiblePreference, visible);
          if (fraction == null) {
            await prefs.remove(ExperimentalHomeFrame.widthPreference);
          } else {
            await prefs.setDouble(
              ExperimentalHomeFrame.widthPreference,
              fraction,
            );
          }
        })
        .catchError((Object error) {
          debugPrint('侧栏偏好保存失败: $error');
        });
  }

  void _toggle() {
    _touched = true;
    setState(() => _visible = !_visible);
    _persist();
    if (_visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _visible) _sidebarFocus.requestFocus();
      });
      _reveal(widget.selected);
    } else {
      _frameFocus.requestFocus();
    }
  }

  void _reveal(MediaLibraryRootEntry entry) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_visible) return;
      final context = _entryKeys[entry]?.currentContext;
      if (context != null) Scrollable.ensureVisible(context, alignment: .4);
    });
  }

  bool get _editing {
    var editing = false;
    final context = FocusManager.instance.primaryFocus?.context;
    if (context?.widget is EditableText) return true;
    context?.visitAncestorElements((element) {
      if (element.widget is EditableText) {
        editing = true;
        return false;
      }
      return true;
    });
    return editing;
  }

  KeyEventResult _key(KeyEvent event, bool wide) {
    if (!wide ||
        _editing ||
        !(widget.shortcutsEnabled?.call() ?? true) ||
        ModalRoute.of(context)?.isCurrent == false) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed ||
        keyboard.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    if (!_visible || !_sidebarFocus.hasFocus) return KeyEventResult.ignored;
    final down = event.logicalKey == LogicalKeyboardKey.arrowDown;
    final up = event.logicalKey == LogicalKeyboardKey.arrowUp;
    if (!down && !up) return KeyEventResult.ignored;
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      final entries = MediaLibraryRootEntryOrder.normalize(
        widget.entries,
      ).where(widget.available.contains).toList();
      if (entries.isNotEmpty) {
        final current = entries.indexOf(widget.selected);
        final index = current < 0
            ? 0
            : (current + (down ? 1 : -1)) % entries.length;
        final next = entries[index];
        widget.onSelected(next);
        _reveal(next);
      }
    }
    return KeyEventResult.handled;
  }

  void _resize(double delta, double width) {
    _touched = true;
    setState(
      () => _fraction =
          (ExperimentalSidebarMetrics.resolveWidth(width, _fraction) + delta)
              .clamp(200.0, ExperimentalSidebarMetrics.maximumWidth(width)) /
          width,
    );
  }

  @override
  void dispose() {
    _frameFocus.dispose();
    _sidebarFocus.dispose();
    super.dispose();
  }

  Widget _destination(MediaLibraryRootEntry entry) => Padding(
    key: _entryKeys[entry],
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
    child: ListTile(
      minTileHeight: 44,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      selected: widget.selected == entry,
      selectedTileColor: _accent.withValues(alpha: .12),
      selectedColor: _accent,
      leading: Icon(_icon(entry), size: 20),
      title: Text(entry.label, style: const TextStyle(fontSize: 14)),
      enabled: widget.available.contains(entry),
      onTap: () {
        _sidebarFocus.requestFocus();
        widget.onSelected(entry);
      },
    ),
  );

  Widget _sidebar(double availableHeight) => Focus(
    focusNode: _sidebarFocus,
    child: Material(
      color: _surface,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 20, right: 6),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '导航',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                DesktopButtonClickRegion(
                  child: IconButton(
                    tooltip: '收起侧栏',
                    onPressed: _toggle,
                    icon: const Icon(Icons.chevron_left),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _SectionLabel('首页入口 · 长按拖动可排序'),
                  if (widget.onReorder == null)
                    ...MediaLibraryRootEntryOrder.normalize(
                      widget.entries,
                    ).map(_destination)
                  else
                    ReorderableListView(
                      shrinkWrap: true,
                      primary: false,
                      physics: const NeverScrollableScrollPhysics(),
                      buildDefaultDragHandles: false,
                      onReorderItem: widget.onReorder!,
                      children: [
                        for (final (index, entry)
                            in MediaLibraryRootEntryOrder.normalize(
                              widget.entries,
                            ).indexed)
                          ButtonAwareReorderableDelayedDragStartListener(
                            key: ValueKey('sidebar-entry-${entry.name}'),
                            index: index,
                            child: _destination(entry),
                          ),
                      ],
                    ),
                  if (widget.actions.isNotEmpty) ...[
                    const _SectionLabel('导入与工具'),
                    _toolGrid(),
                  ],
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
            leading: const Icon(Icons.settings_outlined, size: 20),
            title: const Text('设置'),
            onTap: widget.onSettings,
          ),
          SizedBox(
            height: math.min(
              widget.bottomObstruction,
              math.max(0, availableHeight - 160),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _toolGrid() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
    child: LayoutBuilder(
      builder: (context, constraints) {
        const gap = 8.0;
        final minCell = math.max(
          72.0,
          MediaQuery.textScalerOf(context).scale(12) * 4 + 16,
        );
        final columns = math.max(
          1,
          ((constraints.maxWidth + gap) / (minCell + gap)).floor(),
        );
        // Bound the cell width as well as the gap: a nearly-wide-enough
        // sidebar should not stretch the remaining columns far apart.
        final cellWidth = math.min(
          minCell + 24,
          (constraints.maxWidth - gap * (columns - 1)) / columns,
        );
        return Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: cellWidth * columns + gap * (columns - 1),
            child: Wrap(
              spacing: gap,
              runSpacing: 10,
              children: [
                for (final action in widget.actions)
                  SizedBox(
                    width: cellWidth,
                    child: Tooltip(
                      message: action.label,
                      child: InkWell(
                        key: ValueKey('sidebar-tool-${action.label}'),
                        onTap: action.onPressed,
                        borderRadius: BorderRadius.circular(6),
                        hoverColor: Colors.white.withValues(alpha: .06),
                        focusColor: _accent.withValues(alpha: .12),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 8,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(action.icon, size: 28, color: action.color),
                              const SizedBox(height: 8),
                              Text(
                                action.label,
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                style: const TextStyle(
                                  fontSize: 12,
                                  height: 1.3,
                                  color: AppTokens.text1,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    ),
  );

  Widget _divider(double width) => MouseRegion(
    cursor: SystemMouseCursors.resizeLeftRight,
    onEnter: (_) => setState(() => _hovering = true),
    onExit: (_) => setState(() => _hovering = false),
    child: Semantics(
      label: '侧栏宽度',
      value:
          '${ExperimentalSidebarMetrics.resolveWidth(width, _fraction).round()}',
      increasedValue:
          '${(ExperimentalSidebarMetrics.resolveWidth(width, _fraction) + 16).clamp(200.0, ExperimentalSidebarMetrics.maximumWidth(width)).round()}',
      decreasedValue:
          '${(ExperimentalSidebarMetrics.resolveWidth(width, _fraction) - 16).clamp(200.0, ExperimentalSidebarMetrics.maximumWidth(width)).round()}',
      onIncrease: () {
        _resize(16, width);
        _persist();
      },
      onDecrease: () {
        _resize(-16, width);
        _persist();
      },
      child: Tooltip(
        message: '拖动调整宽度，双击恢复默认',
        child: GestureDetector(
          key: const ValueKey('experimental-sidebar-resizer'),
          behavior: HitTestBehavior.opaque,
          onDoubleTap: () {
            _touched = true;
            setState(() => _fraction = null);
            _persist();
          },
          onHorizontalDragStart: (_) => setState(() => _dragging = true),
          onHorizontalDragUpdate: (details) => _resize(details.delta.dx, width),
          onHorizontalDragEnd: (_) {
            setState(() => _dragging = false);
            _persist();
          },
          onHorizontalDragCancel: () {
            setState(() => _dragging = false);
            _persist();
          },
          child: SizedBox(
            width: 8,
            child: Center(
              child: Container(
                width: _dragging || _hovering ? 3 : 1,
                color: _dragging || _hovering ? _accent : Colors.white12,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final wide = ExperimentalSidebarMetrics.usesSidebar(bounds.maxWidth);
      Widget content() => LayoutBuilder(
        builder: (context, constraints) => MediaQuery(
          data: MediaQuery.of(context).copyWith(size: constraints.biggest),
          child: KeyedSubtree(key: _contentKey, child: widget.child),
        ),
      );
      return Focus(
        focusNode: _frameFocus,
        onKeyEvent: (_, event) => _key(event, wide),
        child: wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Offstage(
                    offstage: !_visible,
                    child: SizedBox(
                      key: const ValueKey('experimental-sidebar'),
                      width: ExperimentalSidebarMetrics.resolveWidth(
                        bounds.maxWidth,
                        _fraction,
                      ),
                      child: ExcludeFocus(
                        excluding: !_visible,
                        child: _sidebar(bounds.maxHeight),
                      ),
                    ),
                  ),
                  if (_visible)
                    _divider(bounds.maxWidth)
                  else
                    const SizedBox(width: 0),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 24, 16),
                          child: Row(
                            children: [
                              if (!_visible) ...[
                                DesktopButtonClickRegion(
                                  child: IconButton(
                                    tooltip: '展开侧栏',
                                    onPressed: _toggle,
                                    icon: const Icon(Icons.menu),
                                  ),
                                ),
                                const SizedBox(width: 12),
                              ],
                              Expanded(
                                child: Text(
                                  widget.selected.label,
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineSmall
                                      ?.copyWith(fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Expanded(child: content()),
                      ],
                    ),
                  ),
                ],
              )
            : _compact(content()),
      );
    },
  );

  Widget _compact(Widget content) {
    return Column(
      children: [
        Material(
          color: _surface,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
            child: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 44,
                    child: MediaLibraryEntrySwitcher(
                      selected: widget.selected,
                      availableEntries: widget.available,
                      entries: widget.entries,
                      onSelected: widget.onSelected,
                      onReorder: widget.onReorder,
                      reorderEnabled: widget.onReorder != null,
                      compact: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                DesktopButtonClickRegion(
                  child: IconButton(
                    tooltip: '设置',
                    onPressed: widget.onSettings,
                    icon: const Icon(Icons.settings_outlined),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(child: content),
      ],
    );
  }
}

IconData _icon(MediaLibraryRootEntry entry) => switch (entry) {
  MediaLibraryRootEntry.continueLearning => Icons.play_circle_outline,
  MediaLibraryRootEntry.folders => Icons.folder_outlined,
  MediaLibraryRootEntry.recent => Icons.history_rounded,
  MediaLibraryRootEntry.bilibili => Icons.live_tv_outlined,
  MediaLibraryRootEntry.podcasts => Icons.podcasts,
  MediaLibraryRootEntry.cloudDrive => Icons.cloud_outlined,
};

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 16, 16, 8),
    child: Text(
      text,
      style: const TextStyle(fontSize: 12, color: Colors.white60),
    ),
  );
}
