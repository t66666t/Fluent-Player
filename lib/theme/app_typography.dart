import 'package:flutter/material.dart';

/// Semantic weights shared by reading surfaces and interface chrome.
abstract final class AppFontWeight {
  static const reading = FontWeight.w400;
  static const label = FontWeight.w500;
  static const heading = FontWeight.w600;
  static const action = FontWeight.w600;
}

/// Reading and controls share the variable Noto face and its CJK fallback.
const appReadingStyle = TextStyle(
  fontFamily: 'App Reading',
  fontFamilyFallback: ['Noto Sans CJK Fallback'],
  fontWeight: AppFontWeight.reading,
);

/// Reading stays regular; navigation and actions have a stronger visual anchor.
/// Keep the Material sizes/leading and the platform's existing font families.
TextTheme appTextTheme({bool isIOS = false}) {
  final family = isIOS ? 'CupertinoSystemText' : 'Noto Sans SC';
  final displayFamily = isIOS ? 'CupertinoSystemDisplay' : family;
  final base = ThemeData.dark(useMaterial3: true).textTheme.apply(
    bodyColor: Colors.white,
    displayColor: Colors.white,
    fontFamily: family,
    fontFamilyFallback: const ['Noto Sans CJK Fallback'],
  );
  TextStyle? title(TextStyle? style) => style?.copyWith(
    fontFamily: displayFamily,
    fontWeight: AppFontWeight.heading,
  );
  TextStyle? body(TextStyle? style) =>
      style?.copyWith(fontWeight: AppFontWeight.reading);
  TextStyle? label(TextStyle? style) =>
      style?.copyWith(fontWeight: AppFontWeight.label);
  return base.copyWith(
    displayLarge: base.displayLarge?.copyWith(fontFamily: displayFamily),
    displayMedium: base.displayMedium?.copyWith(fontFamily: displayFamily),
    displaySmall: base.displaySmall?.copyWith(fontFamily: displayFamily),
    headlineLarge: title(base.headlineLarge),
    headlineMedium: title(base.headlineMedium),
    headlineSmall: title(base.headlineSmall),
    titleLarge: title(base.titleLarge),
    titleMedium: base.titleMedium?.copyWith(fontWeight: AppFontWeight.label),
    titleSmall: base.titleSmall?.copyWith(fontWeight: AppFontWeight.label),
    bodyLarge: body(base.bodyLarge),
    bodyMedium: body(base.bodyMedium),
    bodySmall: body(base.bodySmall),
    labelLarge: label(base.labelLarge),
    labelMedium: label(base.labelMedium),
    labelSmall: label(base.labelSmall),
  );
}

/// Color and disabled/focus states remain owned by each Material button.
ButtonStyle appActionTextStyle({bool isIOS = false, bool emphasized = false}) =>
    ButtonStyle(
      textStyle: WidgetStatePropertyAll(
        appTextTheme(isIOS: isIOS).labelLarge!.copyWith(
          fontWeight: emphasized ? AppFontWeight.action : AppFontWeight.label,
        ),
      ),
    );
