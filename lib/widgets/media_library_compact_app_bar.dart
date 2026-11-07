import 'package:flutter/material.dart';
import 'package:video_player_app/services/app_haptics.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';
import 'media_library_anchor_menu.dart';

const double mediaLibraryCompactTopBarBreakpoint = 600;

/// Portrait home pins search, library settings, and more as one cluster.
///
/// A 40px slot leaves a 20px gap between 20px icons. 34px brings that gap
/// down to 14px — the same gap the responsive toolbar already uses on a
/// phone — so the three stay narrower than the page titles.
const double mediaLibraryHomePinnedActionWidth = 34;

/// Icon size paired with [mediaLibraryHomePinnedActionWidth].
const double mediaLibraryHomePinnedActionIconSize = 20;

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
          onPressed: AppHaptics.wrap(onPressed, light: true),
          onLongPress: AppHaptics.wrap(onLongPress, light: true),
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
    this.width = 40,
  });

  final PopupMenuItemBuilder<VoidCallback> itemBuilder;
  final double iconSize;

  /// Toolbar slot. The portrait home passes
  /// [mediaLibraryHomePinnedActionWidth], which is under Material's 40px
  /// icon-button minimum, so the glyph is a child instead of [IconButton].
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: 48,
      child: CapsulePopupMenuButton<VoidCallback>(
        tooltip: '更多',
        useRootNavigator: true,
        padding: EdgeInsets.zero,
        // Menu panel width, not the toolbar button.
        constraints: const BoxConstraints(minWidth: 176),
        onOpened: () => AppHaptics.pulse(light: true),
        onSelected: (action) {
          AppHaptics.pulse();
          action();
        },
        itemBuilder: itemBuilder,
        child: Center(child: Icon(Icons.more_horiz_rounded, size: iconSize)),
      ),
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
  final row = _CompactMenuItemLabel(icon: icon, label: label, color: itemColor);
  return PopupMenuItem<VoidCallback>(
    value: onSelected,
    height: 44,
    child: onLongPress == null
        ? row
        : Builder(
            builder: (itemContext) => GestureDetector(
              behavior: HitTestBehavior.translucent,
              onLongPress: () {
                AppHaptics.pulse();
                Navigator.of(itemContext).pop();
                onLongPress();
              },
              child: SizedBox(width: double.infinity, child: row),
            ),
          ),
  );
}

/// Keep the same icon slot and text column inside tap and long-press entries.
class _CompactMenuItemLabel extends StatelessWidget {
  const _CompactMenuItemLabel({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final metrics = MediaLibraryAnchorMenuMetrics.of(
      MediaQuery.sizeOf(context),
    );
    return Row(
      children: [
        SizedBox.square(
          dimension: metrics.iconSize,
          child: Icon(icon, size: metrics.iconSize, color: color),
        ),
        SizedBox(width: metrics.iconGap),
        Expanded(
          child: Text(
            label,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'Noto Sans SC',
              fontSize: metrics.fontSize,
              height: 1.15,
              fontWeight: FontWeight.w400,
              letterSpacing: -0.2,
              leadingDistribution: TextLeadingDistribution.even,
              color: color,
            ),
          ),
        ),
      ],
    );
  }
}
