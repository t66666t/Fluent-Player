import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'desktop_button_click_region.dart';

/// Matches the frosted actions in the podcast player's transcript fallback.
class QuietEmptyAction extends StatelessWidget {
  const QuietEmptyAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.expanded = false,
    this.textStyle,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  /// Primary actions, such as trial playback, use the full row.
  final bool expanded;

  /// Overrides the compact chip face. Callers that need a heavier label
  /// pass it here so the frosted chrome stays shared.
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final radius = BorderRadius.circular(expanded ? 22 : 17);
    final face =
        textStyle ??
        const TextStyle(
          fontFamily: 'Noto Sans SC',
          fontFamilyFallback: ['Noto Sans CJK Fallback'],
          fontWeight: FontWeight.w500,
          fontSize: 13,
          height: 20 / 13,
        );
    // Noto's ink sits below its line-box center. Correct the label optically
    // without shifting the glass, icon, layout bounds, or native hit target.
    final labelText = Transform.translate(
      offset: const Offset(0, -2),
      child: Text(label, textAlign: TextAlign.center),
    );
    return SizedBox(
      width: expanded ? double.infinity : null,
      child: DesktopButtonClickRegion(
        child: TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            foregroundColor: Colors.white.withValues(alpha: .86),
            disabledForegroundColor: Colors.white.withValues(alpha: .34),
            backgroundColor: Colors.transparent,
            overlayColor: Colors.white.withValues(alpha: .08),
            minimumSize: Size(44, expanded ? 48 : 44),
            // Keep the compact face at 34 px and the native hit area at 44 px.
            // Larger text can grow naturally instead of being clipped.
            padding: EdgeInsets.symmetric(vertical: expanded ? 0 : 5),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.standard,
            shape: RoundedRectangleBorder(borderRadius: radius),
            textStyle: face,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: enabled ? .10 : .04),
                  blurRadius: 12,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: radius,
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.white.withValues(alpha: enabled ? .10 : .05),
                        Colors.white.withValues(alpha: enabled ? .035 : .02),
                      ],
                    ),
                    border: Border.all(
                      color: Colors.white.withValues(
                        alpha: enabled ? .10 : .045,
                      ),
                    ),
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: expanded ? 48 : 34),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: expanded ? 10 : 7,
                      ),
                      child: icon == null
                          ? labelText
                          : Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: expanded
                                  ? MainAxisSize.max
                                  : MainAxisSize.min,
                              children: [
                                Icon(icon, size: 20),
                                const SizedBox(width: 6),
                                Flexible(child: labelText),
                              ],
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
}
