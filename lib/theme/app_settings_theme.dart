import 'package:flutter/material.dart';

import 'app_interaction_theme.dart';

/// Shared presentation for compact editing, queue and download pages.
class AppSettingsTheme extends StatefulWidget {
  const AppSettingsTheme({
    super.key,
    required this.child,
    this.preserveLayout = true,
  });

  final Widget child;

  /// Existing pages keep their own sizing, typography metrics and arrangement.
  final bool preserveLayout;

  static const background = Color(0xFF191A1C);
  static const surface = Color(0xFF232425);
  static const divider = Color(0xFF303234);
  static const foreground = Color(0xFFE9EBEF);
  static const secondary = Color(0xFFA0A4AC);
  static const accent = Color(0xFF4B8EF0);
  static const controlHeight = 44.0;
  static const title = TextStyle(
    color: foreground,
    fontSize: 13,
    fontWeight: FontWeight.w500,
    height: 1.35,
  );
  static const description = TextStyle(
    color: secondary,
    fontSize: 12,
    height: 1.4,
  );
  static const heading = TextStyle(
    color: foreground,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    height: 1.35,
  );

  static ThemeData _appearance(ThemeData base) {
    const shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(10)),
    );
    ButtonStyle buttons(ButtonStyle? original) =>
        (original ?? const ButtonStyle()).copyWith(
          shape: const WidgetStatePropertyAll(shape),
        );
    return base.copyWith(
      scaffoldBackgroundColor: background,
      colorScheme: base.colorScheme.copyWith(
        primary: accent,
        onPrimary: Colors.white,
        surface: surface,
        onSurface: foreground,
        onSurfaceVariant: secondary,
        outline: divider,
      ),
      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: base.cardTheme.copyWith(color: surface, elevation: 0),
      dialogTheme: base.dialogTheme.copyWith(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
      ),
      dividerTheme: base.dividerTheme.copyWith(color: divider),
      switchTheme: base.switchTheme.copyWith(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? const Color(0xFF86898E)
              : const Color(0xFFF5F7FA),
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? const Color(0xFF34373C)
              : states.contains(WidgetState.selected)
              ? accent
              : const Color(0xFF4B5058),
        ),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      textButtonTheme: TextButtonThemeData(
        style: buttons(base.textButtonTheme.style),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: buttons(base.outlinedButtonTheme.style),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: buttons(base.filledButtonTheme.style),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: buttons(base.elevatedButtonTheme.style),
      ),
    );
  }

  static ThemeData _theme(ThemeData base) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: divider),
    );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
    );
    return appInteractionTheme(
      base.copyWith(
        scaffoldBackgroundColor: background,
        appBarTheme: base.appBarTheme.copyWith(
          backgroundColor: background,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
          toolbarHeight: 52,
          titleTextStyle: base.textTheme.titleLarge?.copyWith(
            color: foreground,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
          iconTheme: const IconThemeData(color: secondary, size: 20),
        ),
        chipTheme: base.chipTheme.copyWith(
          backgroundColor: surface,
          selectedColor: accent.withValues(alpha: .16),
          secondarySelectedColor: accent.withValues(alpha: .16),
          labelStyle: base.textTheme.bodySmall?.copyWith(
            color: foreground,
            fontSize: 12,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: divider),
          ),
        ),
        cardTheme: base.cardTheme.copyWith(
          color: surface,
          elevation: 0,
          shape: shape,
        ),
        dialogTheme: base.dialogTheme.copyWith(
          backgroundColor: background,
          surfaceTintColor: Colors.transparent,
          shape: shape,
        ),
        colorScheme: base.colorScheme.copyWith(
          primary: accent,
          onPrimary: Colors.white,
          surface: surface,
          onSurface: foreground,
          onSurfaceVariant: secondary,
          outline: divider,
        ),
        textTheme: base.textTheme.copyWith(
          bodyMedium: base.textTheme.bodyMedium?.merge(title),
          bodySmall: base.textTheme.bodySmall?.merge(description),
          titleSmall: base.textTheme.titleSmall?.merge(heading),
        ),
        listTileTheme: base.listTileTheme.copyWith(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 4,
          ),
          minVerticalPadding: 6,
          titleTextStyle: base.textTheme.bodyMedium?.merge(title),
          subtitleTextStyle: base.textTheme.bodySmall?.merge(description),
        ),
        inputDecorationTheme: base.inputDecorationTheme.copyWith(
          isDense: true,
          constraints: const BoxConstraints(minHeight: 44),
          filled: true,
          fillColor: const Color(0xFF27292C),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
          border: border,
          enabledBorder: border,
          disabledBorder: border,
          focusedBorder: border.copyWith(
            borderSide: const BorderSide(color: accent),
          ),
          labelStyle: description,
          helperStyle: description,
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: foreground,
            minimumSize: const Size(0, 40),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            textStyle: base.textTheme.labelLarge?.copyWith(
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
            shape: shape,
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: foreground,
            side: const BorderSide(color: divider),
            minimumSize: const Size(0, 40),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            textStyle: base.textTheme.labelLarge?.copyWith(fontSize: 12),
            shape: shape,
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: accent,
            foregroundColor: Colors.white,
            minimumSize: const Size(0, 40),
            shape: shape,
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: accent,
            foregroundColor: Colors.white,
            elevation: 0,
            minimumSize: const Size(0, 44),
            shape: shape,
          ),
        ),
        switchTheme: base.switchTheme.copyWith(
          thumbColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled)
                ? const Color(0xFF86898E)
                : const Color(0xFFF5F7FA),
          ),
          trackColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return const Color(0xFF34373C);
            }
            return states.contains(WidgetState.selected)
                ? accent
                : const Color(0xFF4B5058);
          }),
          trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
          trackOutlineWidth: const WidgetStatePropertyAll(0),
          thumbIcon: const WidgetStatePropertyAll(Icon(null)),
        ),
        dividerTheme: const DividerThemeData(
          color: divider,
          thickness: 1,
          space: 1,
        ),
      ),
    );
  }

  @override
  State<AppSettingsTheme> createState() => _AppSettingsThemeState();
}

class _AppSettingsThemeState extends State<AppSettingsTheme> {
  ThemeData? _base, _data;
  bool? _preserveLayout;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    // Feature updates must not replace ScrollPositions or reset focused editors.
    if (_base != base || _preserveLayout != widget.preserveLayout) {
      _base = base;
      _preserveLayout = widget.preserveLayout;
      _data = widget.preserveLayout
          ? AppSettingsTheme._appearance(base)
          : AppSettingsTheme._theme(base);
    }
    return Theme(data: _data!, child: widget.child);
  }
}
