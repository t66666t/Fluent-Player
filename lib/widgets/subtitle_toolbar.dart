import 'package:flutter/material.dart';

/// A single-row transcript toolbar. Each action owns a non-overlapping target;
/// only its glyph shrinks when the panel is narrower than the preferred width.
class SubtitleToolbar extends StatelessWidget {
  const SubtitleToolbar({
    super.key,
    required this.actions,
    required this.onOpenSettings,
  });

  final List<SubtitleToolbarAction> actions;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    key: const ValueKey('subtitle-toolbar'),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: Colors.white10)),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) {
        // Cap desktop targets at 36px, with more compact 28px segments and
        // 4px breathing room on either side of each group. Narrow panels reduce
        // those widths together; glyphs only shrink when their own slot needs it.
        var preferredWidth = 36.0; // Settings is an ordinary trailing action.
        for (var index = 0; index < actions.length; index++) {
          final group = actions[index].group;
          preferredWidth += group == null ? 36 : 28;
          if (group != null &&
              (index == 0 || actions[index - 1].group != group)) {
            preferredWidth += 8;
          }
        }
        final scale = (constraints.maxWidth / preferredWidth).clamp(0.0, 1.0);
        final actionWidth = 36 * scale;
        final children = <Widget>[];
        for (var index = 0; index < actions.length;) {
          final action = actions[index];
          if (action.group == null) {
            children.add(_ToolbarButton(width: actionWidth, action: action));
            index++;
            continue;
          }
          final start = index;
          while (index < actions.length &&
              actions[index].group == action.group) {
            index++;
          }
          children.add(
            _ToolbarGroup(actions: actions.sublist(start, index), scale: scale),
          );
        }
        return SizedBox(
          height: 44,
          child: Row(
            children: [
              ...children,
              _ToolbarButton(
                width: actionWidth,
                action: SubtitleToolbarAction(
                  icon: Icons.settings,
                  tooltip: '设置',
                  onTap: onOpenSettings,
                ),
              ),
            ],
          ),
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
  const _ToolbarGroup({required this.actions, required this.scale});

  final List<SubtitleToolbarAction> actions;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final width = (28 * actions.length + 8) * scale;
    final inset = 5 * scale;
    return SizedBox(
      key: ValueKey('subtitle-toolbar-${actions.first.group!.name}-group'),
      width: width,
      height: 44,
      child: Stack(
        children: [
          Positioned(
            left: 4 * scale,
            right: 4 * scale,
            top: 7,
            bottom: 7,
            child: DecoratedBox(
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
  const _ToolbarButton({required this.width, required this.action});

  final double width;
  final SubtitleToolbarAction action;

  @override
  Widget build(BuildContext context) {
    final active = action.selected == true;
    final grouped = action.group != null;
    final badged = action.selectedBadge != null;
    final glyphSize = grouped ? 16.0 : 20.0;
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
      height: 44,
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
                padding: EdgeInsets.symmetric(horizontal: width < 24 ? 1 : 3),
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
