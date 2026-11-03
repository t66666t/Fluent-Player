import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import 'anchored_menu_layout.dart';
import 'capsule_option.dart';

class BilibiliFilterButton extends StatelessWidget {
  const BilibiliFilterButton({
    super.key,
    required this.label,
    required this.tooltip,
    required this.onPressed,
    this.active = false,
  });

  final String label;
  final String tooltip;
  final void Function(BuildContext anchorContext) onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) => Builder(
    builder: (anchorContext) => Tooltip(
      message: tooltip,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: math.max(0, MediaQuery.sizeOf(context).width - 24),
        ),
        child: CapsuleOption(
          color: active
              ? AppTokens.brandBilibili.withValues(alpha: 0.12)
              : AppTokens.bgCard,
          side: BorderSide(
            color: active
                ? AppTokens.brandBilibili.withValues(alpha: 0.35)
                : Colors.white.withValues(alpha: 0.1),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          onTap: () => onPressed(anchorContext),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: active ? AppTokens.brandBilibili : AppTokens.text1,
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              const Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 16,
                color: AppTokens.text2,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<T?> showBilibiliFilterPicker<T>({
  required BuildContext context,
  required BuildContext anchorContext,
  required String title,
  required T selected,
  required List<T> values,
  required String Function(T) labelOf,
}) {
  final anchor = AnchoredMenuPosition.fromContext(anchorContext);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭$title选择',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 140),
    transitionBuilder: (_, animation, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
      child: child,
    ),
    pageBuilder: (dialogContext, _, _) {
      final media = MediaQuery.of(dialogContext);
      final width = math.min(
        math.max(anchor.globalBounds.width, 184.0),
        math.max(0.0, media.size.width - media.padding.horizontal - 16),
      );
      return Material(
        type: MaterialType.transparency,
        child: AnchoredMenuLayout(
          position: anchor,
          width: width,
          alignLeft: true,
          child: SizedBox(
            height: values.length * 46.0 + 8,
            child: Semantics(
              namesRoute: true,
              label: title,
              child: Material(
                color: AppTokens.bgOverlay,
                elevation: 2,
                shadowColor: Colors.black.withValues(alpha: 0.5),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
                ),
                clipBehavior: Clip.antiAlias,
                child: ListView(
                  padding: const EdgeInsets.all(4),
                  children: [
                    for (final value in values)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Semantics(
                          selected: value == selected,
                          child: CapsuleOption(
                            color: value == selected
                                ? AppTokens.brandBilibili.withValues(
                                    alpha: 0.14,
                                  )
                                : Colors.transparent,
                            onTap: () => Navigator.of(dialogContext).pop(value),
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            child: SizedBox(
                              height: 42,
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      labelOf(value),
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: value == selected
                                            ? AppTokens.brandBilibili
                                            : AppTokens.text1,
                                      ),
                                    ),
                                  ),
                                  if (value == selected)
                                    const Icon(
                                      Icons.check_rounded,
                                      size: 16,
                                      color: AppTokens.brandBilibili,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
