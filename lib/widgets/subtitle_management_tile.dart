import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'desktop_button_click_region.dart';

/// A subtitle row sized by the space available to the manager, including when
/// it is hosted in a narrow sidebar on an otherwise wide screen.
class SubtitleManagementTile extends StatelessWidget {
  const SubtitleManagementTile({
    super.key,
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.actions,
    this.selectionBadge,
    this.badges = const [],
    this.selected = false,
    this.onTap,
  });

  final Widget leading;
  final Widget title;
  final Text subtitle;
  final List<Widget> actions;
  final Widget? selectionBadge;
  final List<Widget> badges;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Flexible(
              child: DefaultTextStyle.merge(
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                child: title,
              ),
            ),
            if (selectionBadge != null) ...[
              const SizedBox(width: 5),
              selectionBadge!,
            ],
          ],
        ),
        const SizedBox(height: 3),
        Text.rich(
          TextSpan(
            children: [
              if (subtitle.data != null) TextSpan(text: subtitle.data),
              if (subtitle.textSpan != null) subtitle.textSpan!,
              for (final badge in badges)
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: badge,
                ),
            ],
          ),
          style: subtitle.style,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
    return Semantics(
      selected: selected,
      child: Material(
        color: selected ? Colors.white10 : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
            child: Row(
              children: [
                leading,
                const SizedBox(width: 8),
                Expanded(child: details),
                if (actions.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  SubtitleManagementRowActions(actions: actions),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SubtitleManagementRowActions extends StatelessWidget {
  const SubtitleManagementRowActions({
    super.key,
    required this.actions,
    this.compact = false,
  });

  final List<Widget> actions;
  final bool compact;

  @override
  Widget build(BuildContext context) => IconButtonTheme(
    data: IconButtonThemeData(
      style: IconButton.styleFrom(
        fixedSize: Size(compact ? 28 : 32, 40),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.standard,
      ),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: actions),
  );
}

/// Reveals the full name beneath a row while keeping its tap and actions intact.
class SubtitleManagementRowDetails extends StatefulWidget {
  const SubtitleManagementRowDetails({
    super.key,
    required this.name,
    required this.metadata,
    required this.child,
  });

  final String name;
  final List<String> metadata;
  final Widget child;

  @override
  State<SubtitleManagementRowDetails> createState() =>
      _SubtitleManagementRowDetailsState();
}

class _SubtitleManagementRowDetailsState
    extends State<SubtitleManagementRowDetails> {
  bool _expanded = false;

  void _toggleDetails() => setState(() => _expanded = !_expanded);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPress: _toggleDetails,
          onSecondaryTap: _toggleDetails,
          child: widget.child,
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
            child: Material(
              color: Colors.white.withValues(alpha: 0.055),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
              ),
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 9, 5, 1),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 5),
                      child: SelectableText(
                        widget.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          height: 1.45,
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 2,
                            children: [
                              for (final label in widget.metadata)
                                Text(
                                  label,
                                  style: const TextStyle(
                                    color: Colors.white60,
                                    fontSize: 11,
                                    height: 1.35,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 4),
                        SubtitleManagementRowActions(
                          actions: [
                            DesktopButtonClickRegion(
                              child: IconButton(
                                tooltip: '复制完整名称',
                                icon: const Icon(
                                  Icons.copy_outlined,
                                  color: Colors.white60,
                                  size: 16,
                                ),
                                onPressed: () => Clipboard.setData(
                                  ClipboardData(text: widget.name),
                                ),
                              ),
                            ),
                            DesktopButtonClickRegion(
                              child: IconButton(
                                tooltip: '收起字幕信息',
                                icon: const Icon(
                                  Icons.keyboard_arrow_up,
                                  color: Colors.white60,
                                  size: 18,
                                ),
                                onPressed: _toggleDetails,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
