import 'package:flutter/material.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Keep a small icon inside a full touch target, including with compact themes.
class PlaybackQueueRemoveButton extends StatelessWidget {
  const PlaybackQueueRemoveButton({
    super.key,
    required this.title,
    required this.onPressed,
    this.color = Colors.white60,
  });

  final String title;
  final VoidCallback onPressed;
  final Color color;

  @override
  Widget build(BuildContext context) => DesktopButtonClickRegion(
    child: IconButton(
      tooltip: '从队列移除：$title',
      onPressed: onPressed,
      icon: const Icon(Icons.close_rounded),
      iconSize: 20,
      color: color,
      padding: const EdgeInsets.all(14),
      constraints: const BoxConstraints.tightFor(width: 48, height: 48),
      visualDensity: VisualDensity.standard,
      style: IconButton.styleFrom(
        minimumSize: const Size.square(48),
        maximumSize: const Size.square(48),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
  );
}
