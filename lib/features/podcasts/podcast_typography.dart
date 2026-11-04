import 'package:flutter/material.dart';
import '../../theme/app_typography.dart';

/// Reading paragraphs use regular weight; controls use medium and titles
/// semibold. Preserve the podcast's existing reading and figure families.
abstract final class PodcastType {
  /// Titles, buttons, filters, menus, and other interface chrome.
  static const ui = 'MiSans';

  /// Show notes, channel copy, and episode summaries.
  /// Keep prose regular for sustained reading.
  static const reading = 'Noto Sans SC';

  /// Clocks and durations. Latin figures, with a CJK face behind them.
  static const figures = 'Inter';

  static const uiFallback = <String>[reading];
  static const figureFallback = <String>[reading, ui];

  static const title = TextStyle(
    fontFamily: ui,
    fontFamilyFallback: uiFallback,
    fontWeight: FontWeight.w600,
  );

  static const label = TextStyle(
    fontFamily: ui,
    fontFamilyFallback: uiFallback,
    fontWeight: FontWeight.w500,
  );

  /// Secondary lines: dates, counts, authors, status.
  static const meta = TextStyle(
    fontFamily: ui,
    fontFamilyFallback: uiFallback,
    fontWeight: AppFontWeight.reading,
  );

  static const prose = TextStyle(
    fontFamily: reading,
    fontFamilyFallback: <String>[ui],
    fontWeight: AppFontWeight.reading,
  );

  static const heading = TextStyle(
    fontFamily: reading,
    fontFamilyFallback: <String>[ui],
    fontWeight: FontWeight.w700,
  );

  static const time = TextStyle(
    fontFamily: figures,
    fontFamilyFallback: figureFallback,
    fontWeight: AppFontWeight.reading,
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
  );

  static ThemeData theme(ThemeData base) {
    TextStyle paint(TextStyle? style, FontWeight weight) {
      return (style ?? const TextStyle()).copyWith(
        fontFamily: ui,
        fontFamilyFallback: uiFallback,
        fontWeight: weight,
      );
    }

    final text = base.textTheme;
    return base.copyWith(
      textTheme: text.copyWith(
        displayLarge: paint(text.displayLarge, FontWeight.w600),
        displayMedium: paint(text.displayMedium, FontWeight.w600),
        displaySmall: paint(text.displaySmall, FontWeight.w600),
        headlineLarge: paint(text.headlineLarge, FontWeight.w600),
        headlineMedium: paint(text.headlineMedium, FontWeight.w600),
        headlineSmall: paint(text.headlineSmall, FontWeight.w600),
        titleLarge: paint(text.titleLarge, FontWeight.w600),
        titleMedium: paint(text.titleMedium, AppFontWeight.label),
        titleSmall: paint(text.titleSmall, AppFontWeight.label),
        bodyLarge: paint(text.bodyLarge, AppFontWeight.reading),
        bodyMedium: paint(text.bodyMedium, AppFontWeight.reading),
        bodySmall: paint(text.bodySmall, AppFontWeight.reading),
        labelLarge: paint(text.labelLarge, FontWeight.w500),
        labelMedium: paint(text.labelMedium, FontWeight.w500),
        labelSmall: paint(text.labelSmall, FontWeight.w500),
      ),
    );
  }
}

/// Applies [PodcastType.theme] to one podcast surface, including its menus.
class PodcastTypography extends StatelessWidget {
  const PodcastTypography({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final data = PodcastType.theme(Theme.of(context));
    return Theme(
      data: data,
      child: DefaultTextStyle.merge(
        style: const TextStyle(
          fontFamily: PodcastType.ui,
          fontFamilyFallback: PodcastType.uiFallback,
          fontWeight: AppFontWeight.reading,
        ),
        child: child,
      ),
    );
  }
}
