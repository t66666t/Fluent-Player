import 'package:flutter/material.dart';

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
    final buttons = IconButtonTheme(
      data: IconButtonThemeData(
        style: IconButton.styleFrom(
          fixedSize: const Size(32, 40),
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.standard,
        ),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: actions),
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
                if (actions.isNotEmpty) ...[const SizedBox(width: 4), buttons],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
