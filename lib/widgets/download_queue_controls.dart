import 'package:flutter/material.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Presentation only: every source keeps its own scheduler and capabilities.
class DownloadQueueAction {
  const DownloadQueueAction({
    this.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.destructive = false,
  });
  final String label;
  final Key? key;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool destructive;
}

class DownloadQueueToolbar extends StatelessWidget {
  const DownloadQueueToolbar({
    super.key,
    required this.selectionLabel,
    required this.onSelectAll,
    required this.allSelected,
    this.primary,
    this.secondary,
    this.more = const [],
  });
  final String selectionLabel;
  final VoidCallback? onSelectAll;
  final bool allSelected;
  final DownloadQueueAction? primary, secondary;
  final List<DownloadQueueAction> more;

  Widget _button(BuildContext context, DownloadQueueAction action) =>
      DesktopButtonClickRegion(
        child: TextButton.icon(
          key: action.key,
          onPressed: action.onPressed,
          style: TextButton.styleFrom(
            minimumSize: const Size(48, 48),
            foregroundColor: action.destructive
                ? Theme.of(context).colorScheme.error
                : null,
          ),
          icon: Icon(action.icon, size: 20),
          label: Text(action.label),
        ),
      );

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Wrap(
          spacing: 4,
          runSpacing: 0,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            DesktopButtonClickRegion(
              child: TextButton.icon(
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: onSelectAll,
                icon: Icon(
                  allSelected ? Icons.check_box : Icons.check_box_outline_blank,
                  size: 20,
                ),
                label: Text(selectionLabel),
              ),
            ),
            if (primary != null) _button(context, primary!),
            if (secondary != null) _button(context, secondary!),
            if (more.isNotEmpty)
              DesktopButtonClickRegion(
                child: PopupMenuButton<int>(
                  tooltip: '队列操作',
                  constraints: const BoxConstraints(minWidth: 220),
                  icon: const Icon(Icons.more_vert),
                  style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
                  onSelected: (index) => more[index].onPressed?.call(),
                  itemBuilder: (_) => [
                    for (var i = 0; i < more.length; i++)
                      PopupMenuItem<int>(
                        value: i,
                        enabled: more[i].onPressed != null,
                        child: Row(
                          children: [
                            Icon(
                              more[i].icon,
                              size: 20,
                              color: more[i].destructive
                                  ? Theme.of(context).colorScheme.error
                                  : null,
                            ),
                            const SizedBox(width: 12),
                            Flexible(child: Text(more[i].label)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

/// Keeps the action slot and overflow button stable as task state changes.
class DownloadTaskActions extends StatelessWidget {
  const DownloadTaskActions({super.key, this.primary, required this.more});
  final DownloadQueueAction? primary;
  final Widget more;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (primary != null)
        DesktopButtonClickRegion(
          child: TextButton.icon(
            key: primary!.key,
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: primary!.onPressed,
            icon: Icon(primary!.icon, size: 20),
            label: Text(primary!.label),
          ),
        ),
      more,
    ],
  );
}
