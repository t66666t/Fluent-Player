import 'package:flutter/material.dart';

import '../utils/keyboard_focus_visibility.dart';

/// A quiet, immediate press surface. It is removed before onTap navigates,
/// so a covered route has no unfinished ripple to resume when it returns.
ThemeData appInteractionTheme(
  ThemeData theme, {
  bool keyboardFocusVisible = true,
}) {
  final overlay = WidgetStateProperty.resolveWith<Color?>((states) {
    // Press feedback is painted by AppPressInk, not InkHighlight's ticker.
    if (states.contains(WidgetState.pressed)) return Colors.transparent;
    if (keyboardFocusVisible && states.contains(WidgetState.focused)) {
      return theme.colorScheme.primary.withValues(alpha: 0.28);
    }
    if (states.contains(WidgetState.hovered)) return theme.hoverColor;
    return null;
  });
  ButtonStyle style(ButtonStyle? original) =>
      (original ?? const ButtonStyle()).copyWith(
        animationDuration: KeyboardFocusVisibility.fadeDuration,
        overlayColor: overlay,
        side: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.focused) &&
              !states.contains(WidgetState.disabled)) {
            if (keyboardFocusVisible) {
              return BorderSide(color: theme.colorScheme.primary, width: 1.5);
            }
            return original?.side?.resolve(
              {...states}..remove(WidgetState.focused),
            );
          }
          return original?.side?.resolve(states);
        }),
      );
  return theme.copyWith(
    focusColor: keyboardFocusVisible
        ? theme.colorScheme.primary.withValues(alpha: 0.28)
        : Colors.transparent,
    splashFactory: AppPressInk.splashFactory,
    highlightColor: Colors.transparent,
    splashColor: const Color(0x14FFFFFF),
    textButtonTheme: TextButtonThemeData(
      style: style(theme.textButtonTheme.style),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: style(theme.filledButtonTheme.style),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: style(theme.elevatedButtonTheme.style),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: style(theme.outlinedButtonTheme.style),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: style(theme.iconButtonTheme.style),
    ),
  );
}

/// Updates focus feedback without rebuilding the Navigator or changing focus.
class KeyboardFocusTheme extends StatelessWidget {
  const KeyboardFocusTheme({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (context
            .dependOnInheritedWidgetOfExactType<_KeyboardFocusThemeScope>() !=
        null) {
      return child;
    }
    return KeyboardFocusVisibilityBuilder(
      child: _KeyboardFocusThemeScope(child: child),
      builder: (context, visible, child) => Theme(
        data: appInteractionTheme(
          Theme.of(context),
          keyboardFocusVisible: visible,
        ),
        child: child!,
      ),
    );
  }
}

class _KeyboardFocusThemeScope extends InheritedWidget {
  const _KeyboardFocusThemeScope({required super.child});

  @override
  bool updateShouldNotify(_KeyboardFocusThemeScope oldWidget) => false;
}

class _AppPressInkFactory extends InteractiveInkFeatureFactory {
  const _AppPressInkFactory();

  @override
  InteractiveInkFeature create({
    required MaterialInkController controller,
    required RenderBox referenceBox,
    required Offset position,
    required Color color,
    required TextDirection textDirection,
    bool containedInkWell = false,
    RectCallback? rectCallback,
    BorderRadius? borderRadius,
    ShapeBorder? customBorder,
    double? radius,
    VoidCallback? onRemoved,
  }) => AppPressInk(
    controller: controller,
    referenceBox: referenceBox,
    // Buttons suppress the separate pressed highlight with a transparent
    // overlay; they still get the same subtle press surface as an InkWell.
    color: color.a == 0 ? const Color(0x14FFFFFF) : color,
    textDirection: textDirection,
    contained: containedInkWell,
    rectCallback: rectCallback,
    borderRadius: borderRadius ?? BorderRadius.zero,
    customBorder: customBorder,
    radius: radius,
    onRemoved: onRemoved,
  );
}

class AppPressInk extends InteractiveInkFeature {
  AppPressInk({
    required super.controller,
    required super.referenceBox,
    required super.color,
    required this.textDirection,
    required this.contained,
    required this.borderRadius,
    this.rectCallback,
    this.radius,
    super.customBorder,
    super.onRemoved,
  }) {
    controller.addInkFeature(this);
  }

  static const InteractiveInkFeatureFactory splashFactory =
      _AppPressInkFactory();
  final TextDirection textDirection;
  final bool contained;
  final BorderRadius borderRadius;
  final RectCallback? rectCallback;
  final double? radius;
  bool _disposed = false;

  // InkResponse refreshes the splash color when button state rebuilds.
  @override
  set color(Color value) =>
      super.color = value.a == 0 ? const Color(0x14FFFFFF) : value;

  @override
  void confirm() => dispose();

  @override
  void cancel() => dispose();

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }

  @override
  void paintFeature(Canvas canvas, Matrix4 transform) {
    final rect = rectCallback?.call() ?? Offset.zero & referenceBox.size;
    canvas.save();
    canvas.transform(transform.storage);
    final paint = Paint()..color = color;
    if (customBorder != null) {
      canvas.drawPath(
        customBorder!.getOuterPath(rect, textDirection: textDirection),
        paint,
      );
    } else if (contained) {
      canvas.drawRRect(borderRadius.toRRect(rect), paint);
    } else {
      canvas.drawCircle(rect.center, radius ?? rect.shortestSide / 2, paint);
    }
    canvas.restore();
  }
}
