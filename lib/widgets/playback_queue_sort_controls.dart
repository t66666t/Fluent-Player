import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import 'package:provider/provider.dart';
import '../services/playlist_manager.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';
import 'package:video_player_app/widgets/button_aware_drag.dart';

/// Always-visible order actions. Narrow headers keep the same touch targets
/// and use icons; wide headers add short labels beside them.
class PlaybackQueueSortControls extends StatelessWidget {
  const PlaybackQueueSortControls({
    super.key,
    required this.onReverse,
    required this.onReset,
    this.canReverse = true,
    this.canReset = false,
    this.compact = false,
    this.color = Colors.white70,
  });

  final VoidCallback onReverse, onReset;
  final bool canReverse, canReset, compact;
  final Color color;

  Widget _button({
    required String id,
    required String tooltip,
    required String label,
    required IconData icon,
    required VoidCallback? onPressed,
  }) => Tooltip(
    message: tooltip,
    child: compact
        ? DesktopButtonClickRegion(
            child: IconButton(
              key: ValueKey(id),
              onPressed: onPressed,
              icon: Icon(icon, size: 19),
              style: IconButton.styleFrom(
                foregroundColor: color,
                disabledForegroundColor: color.withValues(alpha: 0.28),
                fixedSize: const Size.square(48),
                minimumSize: const Size.square(48),
                maximumSize: const Size.square(48),
                visualDensity: VisualDensity.standard,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          )
        : DesktopButtonClickRegion(
            child: TextButton.icon(
              key: ValueKey(id),
              onPressed: onPressed,
              icon: Icon(icon, size: 18),
              label: Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              style: TextButton.styleFrom(
                foregroundColor: color,
                disabledForegroundColor: color.withValues(alpha: 0.28),
                minimumSize: const Size(72, 48),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                visualDensity: VisualDensity.standard,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
  );

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      _button(
        id: 'queue-sort-reverse',
        tooltip: '倒序排列',
        label: '倒序',
        icon: Icons.swap_vert_rounded,
        onPressed: canReverse ? onReverse : null,
      ),
      const SizedBox(width: 4),
      _button(
        id: 'queue-sort-reset',
        tooltip: '恢复来源顺序',
        label: '恢复',
        icon: Icons.restore_rounded,
        onPressed: canReset ? onReset : null,
      ),
    ],
  );
}

/// Keep the title left and sorting at the right edge. Existing transport and
/// source actions move below only when their combined width needs another row.
class PlaybackQueueHeader extends StatelessWidget {
  const PlaybackQueueHeader({
    super.key,
    required this.title,
    required this.titleStyle,
    required this.leading,
    required this.onReverse,
    required this.onReset,
    this.canReverse = true,
    this.canReset = false,
    this.secondaryActions = const [],
    this.separateSecondaryActions = false,
    this.beforeSort,
    this.compactTitle,
  });

  final String title;
  final TextStyle titleStyle;
  final Widget leading;
  final VoidCallback onReverse, onReset;
  final bool canReverse, canReset, separateSecondaryActions;
  final List<Widget> secondaryActions;
  final Widget? beforeSort;
  final String? compactTitle;

  @override
  Widget build(BuildContext context) {
    final queue = context.watch<PlaylistManager?>();
    final canUndoAddition = queue?.canUndoQueueAddition == true;
    final secondary = [
      if (canUndoAddition) PlaybackQueueUndoAdditionButton(queue: queue!),
      ...secondaryActions,
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final inline =
            constraints.maxWidth >= 480 &&
            textScale <= 1.3 &&
            !separateSecondaryActions &&
            !canUndoAddition;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                leading,
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    compactTitle != null &&
                            (constraints.maxWidth < 330 || textScale > 1.3)
                        ? compactTitle!
                        : title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle,
                  ),
                ),
                if (inline && secondary.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Row(mainAxisSize: MainAxisSize.min, children: secondary),
                ],
                const SizedBox(width: 8),
                if (beforeSort != null) ...[
                  beforeSort!,
                  const SizedBox(width: 4),
                ],
                PlaybackQueueSortControls(
                  onReverse: onReverse,
                  onReset: onReset,
                  canReverse: canReverse,
                  canReset: canReset,
                  compact: constraints.maxWidth < 420 || textScale > 1.3,
                ),
              ],
            ),
            if (!inline && secondary.isNotEmpty)
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  spacing: 4,
                  runSpacing: 2,
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: secondary,
                ),
              ),
          ],
        );
      },
    );
  }
}

class PlaybackQueueUndoAdditionButton extends StatelessWidget {
  const PlaybackQueueUndoAdditionButton({super.key, required this.queue});
  final PlaylistManager queue;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: '撤销上次加入',
    child: DesktopButtonClickRegion(
      child: TextButton.icon(
        key: const ValueKey('queue-undo-addition'),
        onPressed: queue.undoLastQueueAddition,
        icon: const Icon(Icons.undo_rounded, size: 18),
        label: const Text('撤销加入', style: TextStyle(fontSize: 12)),
        style: TextButton.styleFrom(
          foregroundColor: Colors.white70,
          minimumSize: const Size(0, 44),
        ),
      ),
    ),
  );
}

/// The row number is the drag target. Its touch area stays generous without
/// adding another visible grip; taps never start playback.
class PlaybackQueueDragHandle extends StatefulWidget {
  const PlaybackQueueDragHandle({
    super.key,
    required this.index,
    required this.title,
    this.enabled = true,
    this.onMoveUp,
    this.onMoveDown,
    this.color = Colors.white38,
    this.isCurrent = false,
    this.numberColor,
  });

  final int index;
  final String title;
  final bool enabled;
  final VoidCallback? onMoveUp, onMoveDown;
  final Color color;
  final bool isCurrent;
  final Color? numberColor;

  @override
  State<PlaybackQueueDragHandle> createState() =>
      _PlaybackQueueDragHandleState();
}

class _PlaybackQueueDragHandleState extends State<PlaybackQueueDragHandle> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '第 ${widget.index + 1} 项，调整顺序：${widget.title}',
    hint: '拖动序号，或按 Alt 加上下方向键',
    enabled: widget.enabled,
    customSemanticsActions: {
      if (widget.onMoveUp != null)
        const CustomSemanticsAction(label: '上移'): widget.onMoveUp!,
      if (widget.onMoveDown != null)
        const CustomSemanticsAction(label: '下移'): widget.onMoveDown!,
    },
    child: Focus(
      canRequestFocus: widget.enabled,
      onFocusChange: (focused) => setState(() => _focused = focused),
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent || !HardwareKeyboard.instance.isAltPressed) {
          return KeyEventResult.ignored;
        }
        final action = event.logicalKey == LogicalKeyboardKey.arrowUp
            ? widget.onMoveUp
            : event.logicalKey == LogicalKeyboardKey.arrowDown
            ? widget.onMoveDown
            : null;
        if (action == null) return KeyEventResult.ignored;
        action();
        return KeyEventResult.handled;
      },
      child: Tooltip(
        message: '拖动序号调整顺序',
        child: MouseRegion(
          cursor: widget.enabled
              ? SystemMouseCursors.grab
              : SystemMouseCursors.basic,
          child: ButtonAwareReorderableDragStartListener(
            index: widget.index,
            enabled: widget.enabled,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {},
              child: Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: _focused ? Border.all(color: Colors.white54) : null,
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '${widget.index + 1}',
                    key: const ValueKey('queue-position'),
                    style: TextStyle(
                      fontSize: 12,
                      height: 1,
                      color:
                          widget.numberColor ??
                          (widget.isCurrent ? Colors.white : Colors.white60),
                      fontWeight: widget.isCurrent
                          ? FontWeight.w700
                          : FontWeight.w500,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class PlaybackQueueListView extends StatelessWidget {
  const PlaybackQueueListView({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.controller,
    this.padding,
    this.shrinkWrap = false,
    this.findChildIndexCallback,
    this.onReorder,
    this.onReorderStart,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final ScrollController? controller;
  final EdgeInsets? padding;
  final bool shrinkWrap;
  final int? Function(Key)? findChildIndexCallback;
  final ReorderCallback? onReorder;
  final ValueChanged<int>? onReorderStart;

  @override
  Widget build(BuildContext context) {
    if (onReorder == null) {
      return ListView.builder(
        controller: controller,
        shrinkWrap: shrinkWrap,
        padding: padding,
        itemCount: itemCount,
        itemBuilder: itemBuilder,
        findChildIndexCallback: findChildIndexCallback,
      );
    }
    return ReorderableListView.builder(
      scrollController: controller,
      shrinkWrap: shrinkWrap,
      padding: padding,
      itemCount: itemCount,
      itemBuilder: itemBuilder,
      buildDefaultDragHandles: false,
      onReorderItem: onReorder!,
      onReorderStart: onReorderStart,
      autoScrollerVelocityScalar: 40,
      proxyDecorator: (child, _, animation) => Material(
        color: const Color(0xFF303030),
        elevation: 6,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }
}
