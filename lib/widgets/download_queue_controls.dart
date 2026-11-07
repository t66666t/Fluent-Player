import '../theme/app_settings_theme.dart';
import '../theme/app_tokens.dart';
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

/// Fixed-height bottom actions with the same proportions as the folder bar.
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

  Widget _content(IconData icon, String label, {required bool dense}) {
    final text = FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(label, maxLines: 1, softWrap: false),
    );
    return dense
        ? Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18),
              const SizedBox(height: 2),
              SizedBox(height: 16, width: double.infinity, child: text),
            ],
          )
        : FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [Icon(icon, size: 20), const SizedBox(width: 6), text],
            ),
          );
  }

  Widget _button(
    BuildContext context,
    DownloadQueueAction action, {
    required bool dense,
    Color color = AppTokens.text1,
  }) {
    final foreground = action.destructive ? AppTokens.danger : color;
    return Tooltip(
      message: action.label,
      child: DesktopButtonClickRegion(
        child: TextButton(
          key: action.key,
          onPressed: action.onPressed,
          style: TextButton.styleFrom(
            foregroundColor: foreground,
            backgroundColor: foreground.withValues(alpha: .045),
            minimumSize: const Size(0, 48),
            padding: EdgeInsets.symmetric(horizontal: dense ? 2 : 8),
            textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
              fontSize: dense ? 12 : 14,
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
            visualDensity: VisualDensity.standard,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: _content(action.icon, action.label, dense: dense),
        ),
      ),
    );
  }

  Widget _more(BuildContext context, {required bool dense}) =>
      DesktopButtonClickRegion(
        child: PopupMenuButton<int>(
          tooltip: '队列操作',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 220),
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
                      color: more[i].destructive ? AppTokens.danger : null,
                    ),
                    const SizedBox(width: 12),
                    Flexible(child: Text(more[i].label)),
                  ],
                ),
              ),
          ],
          child: Container(
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppTokens.text2.withValues(alpha: .045),
              borderRadius: BorderRadius.circular(12),
            ),
            child: DefaultTextStyle.merge(
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: AppTokens.text2,
                fontSize: dense ? 12 : 14,
                fontWeight: FontWeight.w600,
                height: 1.3,
              ),
              child: IconTheme(
                data: const IconThemeData(color: AppTokens.text2),
                child: _content(Icons.more_horiz, '更多', dense: dense),
              ),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) =>
      AppSettingsTheme(child: Builder(builder: _buildThemedSurface));

  Widget _buildThemedSurface(BuildContext context) => Material(
    color: AppTokens.bgRaised,
    child: DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppTokens.lineSubtle)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: MediaQuery.sizeOf(context).width < 600 ? 8 : 24,
            vertical: 4,
          ),
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final count =
                      1 +
                      (primary == null ? 0 : 1) +
                      (secondary == null ? 0 : 1) +
                      (more.isEmpty ? 0 : 1);
                  final slotWidth = constraints.maxWidth / count;
                  final dense = slotWidth < 130;
                  final actions = [
                    _button(
                      context,
                      DownloadQueueAction(
                        label: selectionLabel,
                        icon: allSelected
                            ? Icons.check_box
                            : Icons.check_box_outline_blank,
                        onPressed: onSelectAll,
                      ),
                      dense: dense,
                      color: allSelected ? AppTokens.accent : AppTokens.text2,
                    ),
                    if (primary != null)
                      _button(
                        context,
                        primary!,
                        dense: dense,
                        color: AppTokens.accent,
                      ),
                    if (secondary != null)
                      _button(context, secondary!, dense: dense),
                    if (more.isNotEmpty) _more(context, dense: dense),
                  ];
                  return SizedBox(
                    height: 48,
                    child: Row(
                      children: [
                        for (final action in actions)
                          Expanded(
                            child: Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: slotWidth < 40 ? 0 : 2,
                              ),
                              child: action,
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
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
