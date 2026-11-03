import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/app_haptics.dart';
import '../../services/settings_service.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/anchored_menu_layout.dart';
import '../../widgets/capsule_option.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Chat surfaces are already near-black, so this is a step lighter than the
/// playback quality pill while keeping that pill's border, radius and type.
const Color _capsuleFill = Color(0xFF323232);
const double _itemHeight = 34;
const double _menuRadius = _itemHeight / 2;

/// Shared hit size for the chat toolbar. Message actions stay larger; the
/// header is a dense row on a phone, so these targets sit flush instead of
/// using the 48dp padded tap target.
const double kAiToolbarExtent = 32;

const TextStyle _choiceStyle = TextStyle(
  color: Colors.white,
  fontSize: 13,
  fontWeight: FontWeight.w600,
  height: 1.1,
);

/// One row in a capsule menu. [danger] is for destructive actions such as
/// deleting a conversation; disabled rows stay visible but cannot be chosen.
class AiCapsuleChoice<T> {
  const AiCapsuleChoice({
    required this.value,
    required this.label,
    this.enabled = true,
    this.danger = false,
  });

  final T value;
  final String label;
  final bool enabled;
  final bool danger;
}

/// Compact toolbar icon. Material 3 otherwise pads every icon button out to
/// 48dp, which is the gap that made the phone toolbar look sparse.
Widget aiToolbarIcon({
  required String tooltip,
  required IconData icon,
  required VoidCallback? onPressed,
}) {
  return DesktopButtonClickRegion(
    child: IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.standard,
        minimumSize: const Size(kAiToolbarExtent, kAiToolbarExtent),
        maximumSize: const Size(kAiToolbarExtent, kAiToolbarExtent),
        fixedSize: const Size(kAiToolbarExtent, kAiToolbarExtent),
        padding: EdgeInsets.zero,
        iconSize: 18,
      ),
    ),
  );
}

/// Labeled pill used for "新建". It stays outside the overflow menu so creating
/// a conversation is a visible control on a phone, not a menu row.
class AiCapsuleAction extends StatelessWidget {
  const AiCapsuleAction({
    super.key,
    required this.tooltip,
    required this.label,
    required this.onPressed,
    this.icon = Icons.add,
  });

  final String tooltip;
  final String label;
  final VoidCallback? onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: Opacity(
        opacity: enabled ? 1 : 0.38,
        child: _CapsuleSurface(
          radius: kAiToolbarExtent / 2,
          onTap: onPressed,
          child: SizedBox(
            height: kAiToolbarExtent,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 16, color: Colors.white),
                  const SizedBox(width: 2),
                  Text(label, style: _choiceStyle),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Form control that shows the current choice and opens the same menu as the
/// playback quality button: a capsule anchored to the field, current row lit.
class AiCapsuleSelectField<T> extends StatelessWidget {
  const AiCapsuleSelectField({
    super.key,
    this.label,
    required this.value,
    required this.choices,
    required this.onChanged,
  });

  final String? label;
  final T value;
  final List<AiCapsuleChoice<T>> choices;
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) {
    AiCapsuleChoice<T>? current;
    for (final choice in choices) {
      if (choice.value == value) {
        current = choice;
        break;
      }
    }
    final currentLabel = current?.label ?? '';
    final enabled = onChanged != null;
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (label != null) ...[
          Text(
            label!,
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
        ],
        Builder(
          builder: (pillContext) => Tooltip(
            message: currentLabel,
            child: _CapsuleSurface(
              radius: 18,
              onTap: enabled
                  ? () async {
                      unawaited(AppHaptics.lightTap(SettingsService()));
                      final picked = await showAiCapsuleMenu<T>(
                        context: pillContext,
                        anchorContext: pillContext,
                        choices: choices,
                        selected: value,
                      );
                      if (picked != null &&
                          picked != value &&
                          pillContext.mounted) {
                        onChanged!(picked);
                      }
                    }
                  : null,
              child: SizedBox(
                height: 32,
                child: Padding(
                  padding: const EdgeInsets.only(left: 14, right: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          currentLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _choiceStyle.copyWith(
                            color: Colors.white.withValues(
                              alpha: enabled ? 1 : 0.45,
                            ),
                          ),
                        ),
                      ),
                      Icon(
                        Icons.keyboard_arrow_down,
                        size: 18,
                        color: Colors.white.withValues(
                          alpha: enabled ? 0.9 : 0.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Icon that opens [showAiCapsuleMenu]. Items are built on tap so enablement
/// matches the controller at that moment, the same as a popup menu.
class AiCapsuleIconMenu<T> extends StatelessWidget {
  const AiCapsuleIconMenu({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.items,
    required this.onSelected,
    this.enabled = true,
    this.feedbackOnSelection = true,
  });

  final String tooltip;
  final IconData icon;
  final List<AiCapsuleChoice<T>> Function() items;
  final ValueChanged<T> onSelected;
  final bool enabled;
  final bool feedbackOnSelection;

  @override
  Widget build(BuildContext context) {
    return aiToolbarIcon(
      tooltip: tooltip,
      icon: icon,
      onPressed: enabled
          ? () async {
              unawaited(AppHaptics.lightTap(SettingsService()));
              final value = await showAiCapsuleMenu<T>(
                context: context,
                anchorContext: context,
                choices: items(),
                feedbackOnSelection: feedbackOnSelection,
              );
              if (value != null && context.mounted) onSelected(value);
            }
          : null,
    );
  }
}

/// Anchored capsule menu. Mirrors the playback quality picker: transparent
/// barrier, scale from the button, and a highlighted capsule on the current row.
Future<T?> showAiCapsuleMenu<T>({
  required BuildContext context,
  required BuildContext anchorContext,
  required List<AiCapsuleChoice<T>> choices,
  T? selected,
  bool feedbackOnSelection = true,
}) {
  if (choices.isEmpty) return Future<T?>.value();
  final position = AnchoredMenuPosition.fromContext(anchorContext);
  return showGeneralDialog<T>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: true,
    barrierLabel: '关闭选项',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 140),
    pageBuilder: (dialogContext, _, _) => _AiCapsuleMenu<T>(
      choices: choices,
      selected: selected,
      feedbackOnSelection: feedbackOnSelection,
      position: position,
    ),
    transitionBuilder: (_, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
  );
}

class _AiCapsuleMenu<T> extends StatelessWidget {
  const _AiCapsuleMenu({
    required this.choices,
    required this.selected,
    required this.position,
    required this.feedbackOnSelection,
  });

  final List<AiCapsuleChoice<T>> choices;
  final T? selected;
  final bool feedbackOnSelection;
  final AnchoredMenuPosition position;

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final screenSize = mediaQuery.size;
    final padding = mediaQuery.padding;
    final width = _width(
      context: context,
      screenSize: screenSize,
      padding: padding,
    );
    final contentHeight = _itemHeight * choices.length;
    return Material(
      type: MaterialType.transparency,
      child: AnchoredMenuLayout(
        position: position,
        width: width,
        child: SizedBox(
          height: contentHeight,
          child: Semantics(
            namesRoute: true,
            label: '选项',
            child: _CapsuleSurface(
              radius: _menuRadius,
              child: ListView.builder(
                padding: EdgeInsets.zero,
                primary: false,
                physics: const ClampingScrollPhysics(),
                itemCount: choices.length,
                itemExtent: _itemHeight,
                itemBuilder: (context, index) {
                  final choice = choices[index];
                  final isSelected = choice.value == selected;
                  final color = choice.danger ? AppTokens.danger : Colors.white;
                  return Padding(
                    padding: const EdgeInsets.all(3),
                    child: CapsuleOption(
                      color: isSelected
                          ? Colors.white.withValues(alpha: 0.12)
                          : Colors.transparent,
                      onTap: choice.enabled
                          ? () {
                              if (feedbackOnSelection && !isSelected) {
                                unawaited(
                                  AppHaptics.selectionClick(SettingsService()),
                                );
                              }
                              Navigator.of(context).pop(choice.value);
                            }
                          : null,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            choice.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: _choiceStyle.copyWith(
                              color: color.withValues(
                                alpha: !choice.enabled
                                    ? 0.35
                                    : isSelected
                                    ? 1
                                    : 0.72,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  double _width({
    required BuildContext context,
    required Size screenSize,
    required EdgeInsets padding,
  }) {
    final available = math.max(
      0.0,
      screenSize.width - padding.left - padding.right - 16,
    );
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    var labelWidth = 0.0;
    for (final choice in choices) {
      final painter = TextPainter(
        text: TextSpan(text: choice.label, style: _choiceStyle),
        maxLines: 1,
        textDirection: direction,
        textScaler: scaler,
      )..layout();
      labelWidth = math.max(labelWidth, painter.width);
      painter.dispose();
    }
    // Inner text padding plus the 3px capsule inset on both sides.
    final desired = labelWidth + 36;
    final anchorWidth = position.globalBounds.width;
    // A wide field keeps the menu the same width as the button. An icon
    // button grows so the labels are readable.
    if (anchorWidth >= desired) return math.min(anchorWidth, available);
    return math.min(math.max(desired, 132), available);
  }
}

class _CapsuleSurface extends StatelessWidget {
  const _CapsuleSurface({
    required this.radius,
    required this.child,
    this.onTap,
  });

  final double radius;
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: BorderSide(
        color: Colors.white.withValues(alpha: 0.16),
        width: 0.75,
      ),
    );
    return Material(
      color: _capsuleFill,
      elevation: 2,
      shadowColor: Colors.black.withValues(alpha: 0.5),
      shape: shape,
      clipBehavior: Clip.antiAlias,
      // The option list scrolls itself. An InkWell around it would compete
      // with that drag.
      child: onTap == null
          ? child
          : InkWell(customBorder: shape, onTap: onTap, child: child),
    );
  }
}
