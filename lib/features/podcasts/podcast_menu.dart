import '../../widgets/card_context_menu.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../widgets/anchored_menu_layout.dart';
import '../../widgets/media_library_anchor_menu.dart';
import '../../theme/app_tokens.dart';
import 'podcast_typography.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

class PodcastMenuAction {
  const PodcastMenuAction(
    this.value,
    this.label,
    this.icon, {
    this.description,
    this.section,
    this.destructive = false,
    this.selected = false,
  });
  final String value, label;
  final IconData icon;
  final String? description, section;
  final bool destructive, selected;
}

/// Fixed circular action for repeated episode rows. InkResponse supplies
/// focus, keyboard activation and feedback without a full styled-button tree.
class PodcastIconButton extends StatelessWidget {
  const PodcastIconButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    required this.icon,
    this.extent,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final Widget icon;
  final double? extent;

  @override
  Widget build(BuildContext context) {
    final extent =
        this.extent ??
        (Theme.of(context).materialTapTargetSize == MaterialTapTargetSize.padded
            ? 48.0
            : 44.0);
    return Semantics(
      button: true,
      child: Tooltip(
        message: tooltip,
        child: InkResponse(
          onTap: onPressed,
          radius: 22,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: extent,
            height: extent,
            child: Center(child: icon),
          ),
        ),
      ),
    );
  }
}

/// Action menus stay attached to their trigger on every screen size.
class PodcastMenuButton extends StatelessWidget {
  const PodcastMenuButton({
    super.key,
    required this.title,
    this.actions,
    this.actionsBuilder,
    required this.onSelected,
    this.subtitle,
    this.label,
    this.tooltip = '更多操作',
    this.icon = Icons.more_horiz_rounded,
    this.iconColor,
    this.fillSlot = false,
    this.compact = false,
    this.dense = false,
  }) : assert((actions == null) != (actionsBuilder == null));
  final String title, tooltip;
  final String? subtitle, label;
  final IconData icon;
  final Color? iconColor;

  /// Transparent hit area when the card's action dock already paints the dots.
  final bool fillSlot;
  final bool compact;
  final bool dense;
  final List<PodcastMenuAction>? actions;

  /// Resolve stateful or expensive actions at the moment the menu opens.
  final List<PodcastMenuAction> Function()? actionsBuilder;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) => Builder(
    builder: (anchor) {
      Future<void> open() async {
        final keyboard = HardwareKeyboard.instance;
        final fromKeyboard =
            keyboard.isLogicalKeyPressed(LogicalKeyboardKey.enter) ||
            keyboard.isLogicalKeyPressed(LogicalKeyboardKey.numpadEnter) ||
            keyboard.isLogicalKeyPressed(LogicalKeyboardKey.space) ||
            keyboard.isLogicalKeyPressed(LogicalKeyboardKey.contextMenu) ||
            (keyboard.isShiftPressed &&
                keyboard.isLogicalKeyPressed(LogicalKeyboardKey.f10));
        final previousFocus = FocusManager.instance.primaryFocus;
        final value = await showPodcastMenu(
          anchor,
          title: title,
          subtitle: subtitle,
          actions: actionsBuilder?.call() ?? actions!,
          compact: compact,
          cardLayout: fillSlot,
        );
        if (anchor.mounted &&
            fromKeyboard &&
            previousFocus?.context?.mounted == true &&
            previousFocus!.canRequestFocus &&
            ModalRoute.of(anchor)?.isCurrent != false) {
          previousFocus.requestFocus();
        }
        if (anchor.mounted && value != null) onSelected(value);
      }

      if (fillSlot) {
        return CardContextMenuTarget(
          onOpen: open,
          child: Semantics(
            button: true,
            label: tooltip,
            child: Tooltip(
              message: tooltip,
              child: Material(
                color: Colors.transparent,
                child: InkWell(onTap: open, child: const SizedBox.expand()),
              ),
            ),
          ),
        );
      }
      return CardContextMenuTarget(
        onOpen: open,
        child: label == null
            ? PodcastIconButton(
                tooltip: tooltip,
                extent: dense ? 40 : null,
                onPressed: open,
                icon: Icon(icon, size: 21, color: iconColor ?? AppTokens.text2),
              )
            : Tooltip(
                message: tooltip,
                child: DesktopButtonClickRegion(
                  child: TextButton(
                    onPressed: open,
                    style: TextButton.styleFrom(
                      foregroundColor: AppTokens.text1,
                      backgroundColor: Colors.transparent,
                      minimumSize: dense ? const Size(0, 36) : null,
                      tapTargetSize: dense
                          ? MaterialTapTargetSize.shrinkWrap
                          : null,
                      padding: EdgeInsets.symmetric(
                        horizontal: dense ? 6 : 12,
                        vertical: dense ? 6 : 10,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, size: 17, color: AppTokens.text2),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            label!,
                            overflow: TextOverflow.ellipsis,
                            style: PodcastType.label.copyWith(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
      );
    },
  );
}

Future<String?> showPodcastMenu(
  BuildContext context, {
  required String title,
  String? subtitle,
  required List<PodcastMenuAction> actions,
  bool compact = false,
  bool cardLayout = false,
}) {
  if (actions.isEmpty) return Future.value();
  FocusScope.of(context).unfocus();
  if (compact) {
    return _showCompactPodcastMenu(
      context,
      title,
      subtitle,
      actions,
      cardLayout: cardLayout,
    );
  }
  return showCapsuleMenu<String>(
    context: context,
    anchorContext: context,
    color: AppTokens.bgOverlay,
    surfaceTintColor: Colors.transparent,
    elevation: 12,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: const BorderSide(color: AppTokens.lineSubtle),
    ),
    constraints: const BoxConstraints(minWidth: 290, maxWidth: 360),
    menuPadding: const EdgeInsets.all(8),
    items: [
      PopupMenuItem<String>(
        enabled: false,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
        child: _MenuHeading(title: title, subtitle: subtitle),
      ),
      for (var i = 0; i < actions.length; i++) ...[
        if (actions[i].section != null &&
            (i == 0 || actions[i - 1].section != actions[i].section))
          PopupMenuItem<String>(
            enabled: false,
            height: 30,
            child: _SectionLabel(actions[i].section!),
          ),
        if (actions[i].destructive && (i == 0 || !actions[i - 1].destructive))
          const PopupMenuDivider(height: 12),
        PopupMenuItem<String>(
          value: actions[i].value,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: _ActionContent(actions[i]),
        ),
      ],
    ],
  );
}

Future<String?> _showCompactPodcastMenu(
  BuildContext context,
  String title,
  String? subtitle,
  List<PodcastMenuAction> actions, {
  bool cardLayout = false,
}) {
  final anchor = AnchoredMenuPosition.fromContext(context);
  final themes = InheritedTheme.capture(
    from: context,
    to: Navigator.of(context, rootNavigator: true).context,
  );
  return showGeneralDialog<String>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: true,
    barrierLabel: '关闭$title',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 140),
    requestFocus: true,
    transitionBuilder: (_, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
    pageBuilder: (dialog, _, _) => themes.wrap(
      PodcastTypography(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final safe = anchoredMenuSafeBounds(
              MediaQuery.of(context),
              constraints.biggest,
            );
            final availableWidth = safe.width;
            final availableHeight = anchoredMenuAvailableHeight(
              anchor.boundsIn(context),
              safe,
            );
            final phone = constraints.maxWidth < 600;
            final scaler = MediaQuery.textScalerOf(context);
            final style = PodcastType.label.copyWith(
              fontSize: 13,
              height: 1.35,
              color: AppTokens.text1,
            );
            final headingHeight =
                (scaler.scale(14) * 1.4).ceilToDouble() +
                (subtitle?.isNotEmpty == true
                    ? (scaler.scale(11) * 1.4).ceilToDouble() + 3
                    : 0) +
                16;
            double rowHeight(double width) {
              var height = phone ? 44.0 : 36.0;
              for (final action in actions) {
                final painter =
                    TextPainter(
                      text: TextSpan(text: action.label, style: style),
                      textDirection: Directionality.of(context),
                      textScaler: scaler,
                    )..layout(
                      maxWidth: math.max(
                        1,
                        width - (action.selected ? 52 : 38),
                      ),
                    );
                height = math.max(height, painter.height + 8);
                painter.dispose();
              }
              return height;
            }

            // More than six commands form a compact palette instead of a tall list.
            final cardGrid =
                cardLayout && actions.length >= 3 && availableWidth >= 220;
            var columns =
                cardGrid || (actions.length > 6 && availableWidth >= 260)
                ? 2
                : 1;
            var width = math.min(
              cardGrid
                  ? 236.0
                  : columns == 2
                  ? 280.0
                  : 196.0,
              availableWidth,
            );
            var extent = rowHeight((width - 12) / columns);
            if (columns == 1 &&
                headingHeight + actions.length * extent + 6 > availableHeight &&
                availableWidth >= 260) {
              columns = 2;
              width = math.min(280.0, availableWidth);
              extent = rowHeight((width - 12) / columns);
            }
            if (headingHeight + (actions.length / columns).ceil() * extent + 8 >
                    availableHeight &&
                availableWidth >= 600) {
              columns = 3;
              width = math.min(420.0, availableWidth);
              extent = rowHeight((width - 12) / columns);
            }
            final height = math.min(
              availableHeight,
              headingHeight + (actions.length / columns).ceil() * extent + 6,
            );
            return AnchoredMenuLayout(
              position: anchor,
              width: width,
              focusContainer: false,
              child: SizedBox(
                height: height,
                child: Material(
                  key: const ValueKey('podcast-compact-menu'),
                  color: AppTokens.bgRaised,
                  elevation: 12,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: const BorderSide(color: AppTokens.lineSubtle),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      SizedBox(
                        height: headingHeight,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: PodcastType.title.copyWith(
                                    fontSize: 14,
                                    height: 1.4,
                                    color: AppTokens.text1,
                                  ),
                                ),
                                if (subtitle?.isNotEmpty == true) ...[
                                  const SizedBox(height: 3),
                                  Text(
                                    subtitle!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: PodcastType.meta.copyWith(
                                      fontSize: 11,
                                      height: 1.4,
                                      color: AppTokens.text2,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                          child: Wrap(
                            children: [
                              for (final (index, action) in actions.indexed)
                                SizedBox(
                                  width: (width - 12) / columns,
                                  height: extent,
                                  child: Tooltip(
                                    message: action.description ?? action.label,
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(9),
                                      focusColor: Colors.transparent,
                                      autofocus: index == 0,
                                      onTap: () => Navigator.of(
                                        dialog,
                                      ).pop(action.value),
                                      child: Builder(
                                        builder: (context) =>
                                            MediaLibraryMenuItemFocus(
                                              focused: Focus.of(
                                                context,
                                              ).hasFocus,
                                              radius: 9,
                                              child: Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 8,
                                                    ),
                                                child: Row(
                                                  children: [
                                                    Icon(
                                                      action.icon,
                                                      size: 16,
                                                      color: action.destructive
                                                          ? AppTokens.danger
                                                          : AppTokens.text2,
                                                    ),
                                                    const SizedBox(width: 6),
                                                    Expanded(
                                                      child: Text(
                                                        action.label,
                                                        style: style.copyWith(
                                                          color:
                                                              action.destructive
                                                              ? AppTokens.danger
                                                              : AppTokens.text1,
                                                        ),
                                                      ),
                                                    ),
                                                    if (action.selected)
                                                      const Icon(
                                                        Icons.check_rounded,
                                                        size: 14,
                                                        color: AppTokens.accent,
                                                      ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Text(
    label,
    style: PodcastType.meta.copyWith(color: AppTokens.text3, fontSize: 11),
  );
}

class _MenuHeading extends StatelessWidget {
  const _MenuHeading({required this.title, this.subtitle});
  final String title;
  final String? subtitle;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: PodcastType.title.copyWith(
          fontSize: 16,
          color: AppTokens.text1,
          height: 1.4,
        ),
      ),
      if (subtitle?.isNotEmpty == true) ...[
        const SizedBox(height: 5),
        Text(
          subtitle!,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: PodcastType.meta.copyWith(
            fontSize: 11,
            color: AppTokens.text2,
            height: 1.5,
          ),
        ),
      ],
    ],
  );
}

class _ActionContent extends StatelessWidget {
  const _ActionContent(this.action);
  final PodcastMenuAction action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      children: [
        SizedBox(
          width: 22,
          child: Icon(
            action.icon,
            size: 18,
            color: action.destructive ? AppTokens.danger : AppTokens.text2,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                action.label,
                style: PodcastType.label.copyWith(
                  fontSize: MediaQuery.sizeOf(context).width < 600 ? 14 : 13,
                  color: action.destructive
                      ? AppTokens.danger
                      : AppTokens.text1,
                  height: 1.5,
                ),
              ),
              if (action.description != null) ...[
                const SizedBox(height: 3),
                Text(
                  action.description!,
                  style: PodcastType.meta.copyWith(
                    fontSize: 12,
                    color: AppTokens.text2,
                    height: 1.5,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (action.selected)
          const Padding(
            padding: EdgeInsets.only(left: 12),
            child: Icon(Icons.check_rounded, size: 17, color: AppTokens.accent),
          ),
      ],
    ),
  );
}
