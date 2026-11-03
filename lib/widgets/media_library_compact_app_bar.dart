import 'package:flutter/material.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

const double mediaLibraryCompactTopBarBreakpoint = 600;

bool useCompactMediaLibraryTopBar(BuildContext context) {
  return MediaQuery.sizeOf(context).width < mediaLibraryCompactTopBarBreakpoint;
}

/// Noto Sans SC sits slightly low in its line box; even leading plus a 1px
/// lift keeps titles on the same visual center as toolbar icons. A 2px lift
/// overshoots and reads as sitting above the icon row.
const TextStyle mediaLibraryCompactTitleStyle = TextStyle(
  fontFamily: 'Noto Sans SC',
  fontSize: 16,
  height: 1.0,
  leadingDistribution: TextLeadingDistribution.even,
  fontWeight: FontWeight.w500,
  letterSpacing: -0.15,
);
const double mediaLibraryCompactTitleOpticalOffset = -1;

/// Noto Sans SC's visual glyph center sits slightly below its line box center.
/// This 1px optical correction aligns titles, text chips, and breadcrumbs
/// with adjacent toolbar icons without changing layout or hit targets.
class MediaLibraryCompactTitle extends StatelessWidget {
  const MediaLibraryCompactTitle({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      offset: const Offset(0, mediaLibraryCompactTitleOpticalOffset),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: mediaLibraryCompactTitleStyle,
      ),
    );
  }
}

class MediaLibraryCompactIconButton extends StatelessWidget {
  const MediaLibraryCompactIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.onLongPress,
    this.color,
    this.width = 40,
    this.iconSize = 21,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final VoidCallback? onLongPress;
  final Color? color;
  final double width;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: DesktopButtonClickRegion(
        child: IconButton(
          onPressed: onPressed,
          onLongPress: onLongPress,
          tooltip: tooltip,
          icon: Icon(icon, color: color),
          iconSize: iconSize,
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          constraints: BoxConstraints.tightFor(width: width, height: 48),
          splashRadius: 20,
        ),
      ),
    );
  }
}

class MediaLibraryCompactMoreButton extends StatelessWidget {
  const MediaLibraryCompactMoreButton({
    super.key,
    required this.itemBuilder,
    this.iconSize = 22,
  });

  final PopupMenuItemBuilder<VoidCallback> itemBuilder;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return CapsulePopupMenuButton<VoidCallback>(
      tooltip: '更多',
      useRootNavigator: true,
      icon: const Icon(Icons.more_horiz_rounded),
      iconSize: iconSize,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 176),
      onSelected: (action) => action(),
      itemBuilder: itemBuilder,
    );
  }
}

PopupMenuItem<VoidCallback> mediaLibraryCompactMenuItem({
  required IconData icon,
  required String label,
  required VoidCallback onSelected,
  VoidCallback? onLongPress,
  Color? color,
}) {
  final itemColor = color ?? Colors.white;
  final row = Row(
    children: [
      Icon(icon, size: 20, color: itemColor),
      const SizedBox(width: 12),
      Text(
        label,
        style: TextStyle(
          fontFamily: 'Noto Sans SC',
          fontSize: 14,
          height: 1.0,
          leadingDistribution: TextLeadingDistribution.even,
          color: itemColor,
        ),
      ),
    ],
  );
  return PopupMenuItem<VoidCallback>(
    value: onSelected,
    height: 44,
    child: onLongPress == null
        ? row
        : Builder(
            builder: (itemContext) => GestureDetector(
              behavior: HitTestBehavior.translucent,
              onLongPress: () {
                Navigator.of(itemContext).pop();
                onLongPress();
              },
              child: SizedBox(width: double.infinity, child: row),
            ),
          ),
  );
}
