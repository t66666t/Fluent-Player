import 'package:flutter/material.dart';

import 'package:video_player_app/theme/app_tokens.dart';
import 'bilibili_cover_image.dart';

/// Cover and information always share the same top and bottom edges.
/// Uses the cell's width, so desktop grids and narrow player panes adapt too.
class BilibiliVideoListTile extends StatelessWidget {
  const BilibiliVideoListTile({
    super.key,
    required this.title,
    required this.coverUrl,
    required this.metadata,
    required this.actions,
    required this.onTap,
    this.duration,
    this.onLongPress,
    this.selectionMode = false,
    this.selected = false,
    this.selectionEnabled = true,
  });

  final String title;
  final String? coverUrl;
  final List<Widget> metadata;
  final Widget actions;
  final VoidCallback onTap;
  final String? duration;
  final VoidCallback? onLongPress;
  final bool selectionMode;
  final bool selected;
  final bool selectionEnabled;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: selectionMode && !selectionEnabled ? null : onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
            final inline = constraints.maxWidth >= 600 * scale;
            final coverWidth = (constraints.maxWidth * .38).clamp(104.0, 144.0);
            final details = DefaultTextStyle.merge(
              style: const TextStyle(height: 1.2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: metadata,
              ),
            );
            final cover = SizedBox(
              key: const ValueKey('bilibili-tile-cover'),
              width: coverWidth,
              child: Stack(
                children: [
                  Positioned.fill(child: BilibiliCoverImage(url: coverUrl)),
                  if (selectionMode)
                    Positioned(
                      top: 5,
                      left: 5,
                      child: Semantics(
                        label: selected ? '已选择' : '未选择',
                        checked: selected,
                        enabled: selectionEnabled,
                        child: DecoratedBox(
                          decoration: const ShapeDecoration(
                            color: Colors.black54,
                            shape: CircleBorder(),
                          ),
                          child: Icon(
                            selected
                                ? Icons.check_circle
                                : Icons.radio_button_unchecked,
                            color: !selectionEnabled
                                ? AppTokens.text4
                                : selected
                                ? AppTokens.brandBilibili
                                : Colors.white,
                            size: 24,
                          ),
                        ),
                      ),
                    ),
                  if (duration != null)
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          duration!,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            );
            final info = ConstrainedBox(
              key: const ValueKey('bilibili-tile-info'),
              constraints: BoxConstraints(minHeight: coverWidth * .625),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    // Reserve two title lines for short titles too, keeping
                    // the metadata and controls aligned between list entries.
                    height:
                        MediaQuery.textScalerOf(context).scale(14) * 1.3 * 2,
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTokens.text1,
                        fontSize: 14,
                        height: 1.3,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (inline)
                    details
                  else
                    Row(
                      children: [
                        Expanded(child: details),
                        const SizedBox(width: 6),
                        actions,
                      ],
                    ),
                ],
              ),
            );
            // Only the information determines the row's natural height.
            // A fill cell then gives the cover that exact height in the same
            // layout pass. BoxFit.cover crops the artwork without stretching.
            // This avoids both a fixed thumbnail height and intrinsic sizing
            // of the import buttons, which contain LayoutBuilder widgets.
            final row = Table(
              columnWidths: {
                0: FixedColumnWidth(coverWidth),
                1: const FixedColumnWidth(10),
                2: const FlexColumnWidth(),
              },
              defaultVerticalAlignment: TableCellVerticalAlignment.top,
              children: [
                TableRow(
                  children: [
                    TableCell(
                      verticalAlignment: TableCellVerticalAlignment.fill,
                      child: cover,
                    ),
                    const SizedBox.shrink(),
                    info,
                  ],
                ),
              ],
            );
            if (!inline) return row;
            return Row(
              children: [
                Expanded(child: row),
                const SizedBox(width: 16),
                actions,
              ],
            );
          },
        ),
      ),
    );
  }
}
