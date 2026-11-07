import 'package:flutter/material.dart';

/// A responsive transcript toolbar with equal action slots and a persistent
/// handle. Landscape panels compact their actions before allowing another row.
class SubtitleToolbar extends StatelessWidget {
  const SubtitleToolbar({
    super.key,
    required this.actions,
    required this.onOpenSettings,
    this.expanded = true,
    this.isPortrait = true,
    this.isLeftHanded = false,
    this.onToggleExpanded,
    this.onExpansionEnd,
    this.content,
  });

  final List<SubtitleToolbarAction> actions;
  final VoidCallback? onOpenSettings;
  final bool expanded;
  final bool isPortrait;
  final bool isLeftHanded;
  final VoidCallback? onToggleExpanded;
  final VoidCallback? onExpansionEnd;
  final Widget? content;

  static const expandedHeight = 44.0;
  static const collapsedHeight = 28.0;
  static const collapsedReservedHeight = 0.0;
  static const expansionDuration = Duration(milliseconds: 280);

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(end: expanded ? 1 : 0),
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : expansionDuration,
    curve: Curves.easeInOutCubic,
    onEnd: onExpansionEnd,
    child: content,
    builder: (context, progress, content) => LayoutBuilder(
      builder: (context, constraints) {
        final allActions = [
          ...actions,
          SubtitleToolbarAction(
            icon: Icons.settings,
            tooltip: '设置',
            onTap: onOpenSettings,
          ),
        ];
        final count = allActions.length + 1;
        // Keep all actions on one row down to compact 13dp landscape slots.
        // Portrait keeps its 20dp single-row threshold and roomier wrapped rows.
        final singleRowMinimum = isPortrait ? 20.0 : 13.0;
        final wrappedRowMinimum = isPortrait ? 24.0 : singleRowMinimum;
        final columns = constraints.maxWidth >= count * singleRowMinimum
            ? count
            : (constraints.maxWidth / wrappedRowMinimum).floor().clamp(
                1,
                count,
              );
        final cellWidth = (constraints.maxWidth / columns).clamp(0.0, 32.0);
        final handleWidth =
            cellWidth * progress +
            constraints.maxWidth.clamp(0.0, collapsedHeight) * (1 - progress);
        final actionRows = <Widget>[];
        var cursor = 0;
        for (var row = 0; cursor < allActions.length; row++) {
          final capacity = columns - (row == 0 ? 1 : 0);
          var end = cursor;
          while (end < allActions.length && end - cursor < capacity) {
            final group = allActions[end].group;
            var groupEnd = end + 1;
            if (group != null) {
              while (groupEnd < allActions.length &&
                  allActions[groupEnd].group == group) {
                groupEnd++;
              }
            }
            final groupCount = groupEnd - end;
            final remaining = capacity - (end - cursor);
            // Keep view/language groups together whenever a row can hold one.
            if (groupCount <= columns && groupCount > remaining) break;
            end += groupCount.clamp(1, remaining);
          }
          final children = <Widget>[];
          for (var index = cursor; index < end;) {
            final action = allActions[index];
            if (action.group == null) {
              children.add(_ToolbarButton(width: cellWidth, action: action));
              index++;
            } else {
              final start = index++;
              while (index < end && allActions[index].group == action.group) {
                index++;
              }
              children.add(
                _ToolbarGroup(
                  actions: allActions.sublist(start, index),
                  cellWidth: cellWidth,
                ),
              );
            }
          }
          cursor = end;
          actionRows.add(
            Padding(
              padding: EdgeInsets.only(
                left: row == 0 && isLeftHanded ? cellWidth : 0,
                right: row == 0 && !isLeftHanded ? cellWidth : 0,
              ),
              child: SizedBox(
                height: expandedHeight,
                child: Row(
                  textDirection: TextDirection.ltr,
                  mainAxisAlignment: isLeftHanded
                      ? MainAxisAlignment.start
                      : MainAxisAlignment.end,
                  children: children,
                ),
              ),
            ),
          );
        }
        final openHeight = actionRows.length * expandedHeight;
        final height = openHeight * progress;
        final handleHeight =
            collapsedHeight + (expandedHeight - collapsedHeight) * progress;
        final controls = RepaintBoundary(
          child: Material(
            type: MaterialType.transparency,
            child: SizedBox(
              key: const ValueKey('subtitle-toolbar'),
              height: height > handleHeight ? height : handleHeight,
              child: Stack(
                children: [
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: SizedBox(
                      key: const ValueKey('subtitle-toolbar-reserved-space'),
                      height: height,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: Colors.white.withValues(
                                alpha: .06 * progress,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: height,
                    child: ClipRect(
                      child: Stack(
                        children: [
                          Positioned(
                            left: 0,
                            right: 0,
                            top: -8 * (1 - progress),
                            height: openHeight,
                            child: Offstage(
                              offstage: progress == 0,
                              child: IgnorePointer(
                                ignoring: !expanded,
                                child: ExcludeSemantics(
                                  excluding: !expanded,
                                  child: Opacity(
                                    opacity: progress,
                                    child: Column(children: actionRows),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    left: isLeftHanded ? 0 : null,
                    right: isLeftHanded ? null : 0,
                    top: 0,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(
                          alpha: .18 * (1 - progress),
                        ),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: _ToolbarButton(
                        key: const ValueKey('subtitle-toolbar-toggle'),
                        width: handleWidth,
                        height: handleHeight,
                        action: SubtitleToolbarAction(
                          icon: expanded
                              ? Icons.keyboard_arrow_up
                              : Icons.keyboard_arrow_down,
                          tooltip: expanded ? '收起字幕工具栏' : '展开字幕工具栏',
                          onTap: onToggleExpanded,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        if (content == null) return controls;
        return Stack(
          fit: StackFit.expand,
          children: [
            Padding(
              padding: EdgeInsets.only(top: height),
              child: content,
            ),
            Positioned(top: 0, left: 0, right: 0, child: controls),
          ],
        );
      },
    ),
  );
}

enum SubtitleToolbarGroup { view, language }

class SubtitleToolbarAction {
  const SubtitleToolbarAction({
    this.icon,
    this.label,
    required this.tooltip,
    this.onTap,
    this.selected,
    this.group,
    this.selectedBadge,
  }) : assert(icon != null || label != null);

  final IconData? icon;
  final String? label;
  final String tooltip;
  final VoidCallback? onTap;
  final bool? selected;
  final SubtitleToolbarGroup? group;

  /// Show an accent-colored icon and badge instead of a filled selection tile.
  final String? selectedBadge;
}

class _ToolbarGroup extends StatelessWidget {
  const _ToolbarGroup({required this.actions, required this.cellWidth});

  final List<SubtitleToolbarAction> actions;
  final double cellWidth;

  @override
  Widget build(BuildContext context) {
    final width = cellWidth * actions.length;
    // Match the space between two group surfaces to the gap between ordinary
    // glyphs, including the one-dp gap between fitted glyphs in compact slots.
    final minimumInset = (cellWidth / 2).clamp(0.0, .5);
    final inset = ((cellWidth - 19) / 2).clamp(minimumInset, 7.0);
    return SizedBox(
      key: ValueKey('subtitle-toolbar-${actions.first.group!.name}-group'),
      width: width,
      height: 44,
      child: Stack(
        children: [
          Positioned(
            left: inset,
            right: inset,
            top: 7,
            bottom: 7,
            child: DecoratedBox(
              key: ValueKey(
                'subtitle-toolbar-${actions.first.group!.name}-surface',
              ),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                border: Border.all(color: Colors.white12),
                borderRadius: BorderRadius.circular(5),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: inset),
            child: Row(
              children: [
                for (final action in actions)
                  _ToolbarButton(
                    width: (width - inset * 2) / actions.length,
                    action: action,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    super.key,
    required this.width,
    required this.action,
    this.height = SubtitleToolbar.expandedHeight,
  });

  final double width;
  final double height;
  final SubtitleToolbarAction action;

  @override
  Widget build(BuildContext context) {
    final active = action.selected == true;
    final grouped = action.group != null;
    final badged = action.selectedBadge != null;
    final glyphSize = grouped ? 16.0 : 19.0;
    final color = action.onTap == null
        ? Colors.white24
        : active
        ? (badged ? Colors.blueAccent : Colors.white)
        : Colors.white70;
    final Widget glyph;
    if (badged && action.icon != null) {
      // Keep the icon and badge inside the same FittedBox below so their
      // painted sizes shrink together. System text scaling must not enlarge
      // the badge independently of this composite icon.
      glyph = SizedBox.square(
        dimension: glyphSize,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Icon(action.icon, size: 18, color: color),
            if (active)
              Positioned(
                right: 0,
                bottom: 0,
                child: Text(
                  action.selectedBadge!,
                  textScaler: TextScaler.noScaling,
                  style: TextStyle(
                    fontSize: 6,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ),
          ],
        ),
      );
    } else {
      glyph = action.icon != null
          ? Icon(action.icon, size: glyphSize, color: color)
          : Text(
              action.label!,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            );
    }
    return SizedBox(
      width: width,
      height: height,
      child: Semantics(
        button: true,
        selected: action.selected,
        enabled: action.onTap != null,
        child: Tooltip(
          message: action.tooltip,
          child: InkWell(
            canRequestFocus: false,
            onTap: action.onTap,
            borderRadius: BorderRadius.circular(6),
            child: Center(
              child: Container(
                width: width,
                height: 28,
                padding: EdgeInsets.symmetric(horizontal: width < 28 ? .5 : 3),
                decoration: BoxDecoration(
                  color: active && !badged
                      ? (grouped ? Colors.blueAccent : Colors.white12)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(grouped ? 3 : 6),
                ),
                child: Center(
                  child: SizedBox(
                    height: glyphSize,
                    child: FittedBox(fit: BoxFit.scaleDown, child: glyph),
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
