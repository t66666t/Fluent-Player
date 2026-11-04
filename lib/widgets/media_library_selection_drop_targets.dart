import 'package:flutter/material.dart';
import 'media_library_tooltip.dart';

import '../utils/desktop_media_management_shortcuts.dart';
import 'media_library_compact_app_bar.dart';

/// AppBar 标题槽里的「移动到上一级」投放区。
const Key mediaLibraryMoveToParentDropKey = ValueKey(
  'media-library-move-to-parent-drop',
);

/// AppBar 标题槽里的「移入回收站」投放区。
const Key mediaLibraryMoveToRecycleDropKey = ValueKey(
  'media-library-move-to-recycle-drop',
);

/// Resolves which library item IDs a selection-mode drop / tap should act on.
///
/// Dragging an already-selected card moves the whole selection. Dragging an
/// unselected card moves only that card. A tap (no [draggedIndex]) uses the
/// current selection. This matches the existing "move to parent" drop zone.
List<String> resolveMediaLibrarySelectionDropIds({
  required Iterable<dynamic> contents,
  required Set<String> selectedIds,
  int? draggedIndex,
}) {
  final items = contents.toList(growable: false);
  if (draggedIndex != null) {
    if (draggedIndex < 0 || draggedIndex >= items.length) {
      return const <String>[];
    }
    final draggedId = (items[draggedIndex] as dynamic).id as String;
    if (selectedIds.contains(draggedId)) {
      return items
          .where((item) => selectedIds.contains((item as dynamic).id))
          .map((item) => (item as dynamic).id as String)
          .toList();
    }
    return <String>[draggedId];
  }
  return items
      .where((item) => selectedIds.contains((item as dynamic).id))
      .map((item) => (item as dynamic).id as String)
      .toList();
}

/// Selection-mode drop zone(s) that replace the media-library AppBar title.
///
/// Folder pages split the original "move to parent" strip into two halves:
/// parent on the left, recycle bin on the right. The root library reuses the
/// same visual language as a single recycle-bin strip, because there is no
/// parent to move into.
///
/// Phone and desktop layouts are independent so labels stay readable in the
/// tight compact AppBar and on a wide desktop toolbar.
class MediaLibrarySelectionDropTargets extends StatelessWidget {
  const MediaLibrarySelectionDropTargets({
    super.key,
    required this.hasSelectedItems,
    required this.onMoveToRecycleBin,
    this.showMoveToParent = false,
    this.onMoveToParent,
    this.removeLabel,
    this.removeCompactLabel,
    this.removeTooltip,
    this.removeIcon = Icons.delete_outline,
  }) : assert(!showMoveToParent || onMoveToParent != null);

  /// Whether tapping a zone should fire (drag still works with an empty
  /// selection, because the dragged card itself is the payload).
  final bool hasSelectedItems;

  /// When true, the strip is split 50/50: parent | recycle.
  final bool showMoveToParent;

  /// Called with the dragged card index, or `null` when the user taps.
  final ValueChanged<int?>? onMoveToParent;

  /// Called with the dragged card index, or `null` when the user taps.
  final ValueChanged<int?> onMoveToRecycleBin;
  final String? removeLabel, removeCompactLabel, removeTooltip;
  final IconData removeIcon;

  @override
  Widget build(BuildContext context) {
    final compact = useCompactMediaLibraryTopBar(context);
    final metrics = compact
        ? _SelectionDropMetrics.compact
        : _SelectionDropMetrics.regular;

    return LayoutBuilder(
      builder: (context, constraints) {
        // AppBar titles are bounded; fall back to the toolbar height when
        // this widget is pumped in isolation during tests.
        final height = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : (compact ? 50.0 : kToolbarHeight);
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;

        return SizedBox(
          width: width,
          height: height,
          child: Padding(
            padding: metrics.outerPadding,
            child: Row(
              children: [
                if (showMoveToParent) ...[
                  Expanded(
                    child: _SelectionDropCell(
                      cellKey: mediaLibraryMoveToParentDropKey,
                      compact: compact,
                      metrics: metrics,
                      icon: Icons.reply_all,
                      // Visible labels stay shortcut-free so compact cells
                      // remain readable; the tooltip still shows (U).
                      label: compact ? '上一级' : '移动到上一级',
                      tooltip: DesktopMediaManagementShortcuts.buildTooltip(
                        '移动到上一级',
                        DesktopMediaManagementShortcutAction.moveToParent,
                        context: context,
                      ),
                      accent: Colors.blueAccent,
                      idleBackground: const Color(0xFF2C2C2C),
                      idleForeground: Colors.white70,
                      idleBorder: Colors.white24,
                      showIdleBorder: false,
                      enabledTap: hasSelectedItems,
                      onAccept: (index) => onMoveToParent!(index),
                      onTap: () => onMoveToParent!(null),
                    ),
                  ),
                  SizedBox(width: metrics.gap),
                ],
                Expanded(
                  child: _SelectionDropCell(
                    cellKey: mediaLibraryMoveToRecycleDropKey,
                    compact: compact,
                    metrics: metrics,
                    icon: removeIcon,
                    // Split phone cells only have room for the short noun;
                    // a full-width root-library cell can keep the verb.
                    // Do not borrow openRecycleBin's (R) — this zone moves
                    // items, it does not open the recycle page.
                    label: compact && showMoveToParent
                        ? removeCompactLabel ?? removeLabel ?? '回收站'
                        : removeLabel ?? '移入回收站',
                    tooltip: removeTooltip ?? removeLabel ?? '移入回收站',
                    accent: Colors.redAccent,
                    idleBackground: const Color(0xFF3A2426),
                    idleForeground: const Color(0xFFFF8A80),
                    idleBorder: Colors.redAccent.withValues(alpha: 0.42),
                    showIdleBorder: true,
                    enabledTap: hasSelectedItems,
                    onAccept: onMoveToRecycleBin,
                    onTap: () => onMoveToRecycleBin(null),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Visual metrics for the compact phone toolbar vs the regular desktop one.
class _SelectionDropMetrics {
  const _SelectionDropMetrics({
    required this.outerPadding,
    required this.gap,
    required this.radius,
    required this.iconSize,
    required this.labelGap,
    required this.fontSize,
    required this.minWidthForLabel,
  });

  final EdgeInsets outerPadding;
  final double gap;
  final double radius;
  final double iconSize;
  final double labelGap;
  final double fontSize;

  /// Below this cell width, hide the label and keep the icon + tooltip so
  /// split zones never overflow on very narrow phones.
  final double minWidthForLabel;

  /// Phone compact AppBar (50px, tight leading/actions).
  static const compact = _SelectionDropMetrics(
    outerPadding: EdgeInsets.fromLTRB(0, 5, 2, 5),
    gap: 4,
    radius: 8,
    iconSize: 16,
    labelGap: 4,
    fontSize: 12,
    minWidthForLabel: 64,
  );

  /// Desktop/tablet toolbar — matches the original move-to-parent strip.
  static const regular = _SelectionDropMetrics(
    outerPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    gap: 8,
    radius: 12,
    iconSize: 24,
    labelGap: 8,
    fontSize: 16,
    minWidthForLabel: 90,
  );
}

class _SelectionDropCell extends StatelessWidget {
  const _SelectionDropCell({
    required this.cellKey,
    required this.compact,
    required this.metrics,
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.accent,
    required this.idleBackground,
    required this.idleForeground,
    required this.idleBorder,
    required this.showIdleBorder,
    required this.enabledTap,
    required this.onAccept,
    required this.onTap,
  });

  final Key cellKey;
  final bool compact;
  final _SelectionDropMetrics metrics;
  final IconData icon;
  final String label;
  final String tooltip;
  final Color accent;
  final Color idleBackground;
  final Color idleForeground;
  final Color idleBorder;
  final bool showIdleBorder;
  final bool enabledTap;
  final ValueChanged<int?> onAccept;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return DragTarget<int>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) => onAccept(details.data),
      builder: (context, candidateData, _) {
        final hovering = candidateData.isNotEmpty;
        final foreground = hovering ? accent : idleForeground;
        return MediaLibraryTooltip(
          message: tooltip,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              key: cellKey,
              borderRadius: BorderRadius.circular(metrics.radius),
              onTap: enabledTap ? onTap : null,
              child: Ink(
                width: double.infinity,
                height: double.infinity,
                decoration: BoxDecoration(
                  color: hovering
                      ? accent.withValues(alpha: 0.3)
                      : idleBackground,
                  borderRadius: BorderRadius.circular(metrics.radius),
                  border: Border.all(
                    color: hovering ? accent : idleBorder,
                    width: 2,
                    style: hovering || showIdleBorder
                        ? BorderStyle.solid
                        : BorderStyle.none,
                  ),
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // Keep the icon when a split cell is extremely narrow;
                    // FittedBox is the second line of defense for large text.
                    final showLabel =
                        constraints.maxWidth >= metrics.minWidthForLabel;
                    return Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: compact ? 4 : 8,
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              icon,
                              color: foreground,
                              size: metrics.iconSize,
                            ),
                            if (showLabel) ...[
                              SizedBox(width: metrics.labelGap),
                              Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: compact ? 'Noto Sans SC' : null,
                                  color: foreground,
                                  fontSize: metrics.fontSize,
                                  fontWeight: FontWeight.bold,
                                  height: compact ? 1.1 : null,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
