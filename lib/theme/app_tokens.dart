import 'package:flutter/material.dart';
import 'app_interaction_theme.dart';

/// Home-library colors from docs/design/design-tokens.md.
///
/// Covers, placeholders, and playback artwork do not use these.
class AppTokens {
  const AppTokens._();

  static const Color bgBase = Color(0xFF191919);
  // Shared surface for player details, reading tabs, and subtitle sidebars.
  static const Color bgPlayerSidebar = Color(0xFF1E1E1E);
  static const Color bgCard = Color(0xFF2C2C2C);
  static const Color bgRaised = Color(0xFF202020);
  static const Color bgOverlay = Color(0xFF252525);

  static const Color text1 = Color(0xFFE3E2E0);
  static const Color text2 = Color(0xFF9B9A97);
  // Muted metadata must still be readable on bgCard, not look disabled.
  static const Color text3 = Color(0xFF969592);
  static const Color text4 = Color(0xFF4A4A48);

  static const Color accent = Color(0xFF4B8EF0);
  static const Color danger = Color(0xFFE5625C);

  static const Color brandBilibili = Color(0xFFFB7299);
  static const Color brandYtDlp = Color(0xFFFF5A52);
  static const Color brandBatch = Color(0xFFA98BF2);

  static const Color lineSubtle = Color(0x0EFFFFFF);

  static Color get accentSoft => accent.withValues(alpha: 0.16);
}

/// Bilibili pages stay mounted under the next route, so a splash that
/// started on the tap freezes and finishes only after coming back.
/// Use the same immediate press feedback as the rest of the app. It is removed
/// before navigation, so returning never resumes an unfinished ripple.
ThemeData bilibiliQuietTapTheme(ThemeData theme) {
  return appInteractionTheme(theme);
}

class BilibiliQuietTap extends StatelessWidget {
  const BilibiliQuietTap({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Theme(data: bilibiliQuietTapTheme(Theme.of(context)), child: child);
  }
}
