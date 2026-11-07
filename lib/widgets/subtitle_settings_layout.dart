import 'package:flutter/material.dart';

import '../theme/app_settings_theme.dart';
import 'desktop_button_click_region.dart';

/// Subtitle workflows share the application editing theme.
class SubtitleSettingsTheme extends AppSettingsTheme {
  const SubtitleSettingsTheme({super.key, required super.child})
    : super(preserveLayout: false);
  static const background = AppSettingsTheme.background;
  static const surface = AppSettingsTheme.surface;
  static const divider = AppSettingsTheme.divider;
  static const foreground = AppSettingsTheme.foreground;
  static const secondary = AppSettingsTheme.secondary;
  static const accent = AppSettingsTheme.accent;
  static const controlHeight = AppSettingsTheme.controlHeight;
  static const title = AppSettingsTheme.title;
  static const description = AppSettingsTheme.description;
  static const heading = AppSettingsTheme.heading;
}

class SubtitleSettingsGroup extends StatelessWidget {
  const SubtitleSettingsGroup({
    super.key,
    this.title,
    this.action,
    this.padding = const EdgeInsets.all(12),
    required this.child,
  });

  final String? title;
  final Widget? action;
  final EdgeInsetsGeometry padding;
  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
    color: SubtitleSettingsTheme.surface,
    borderRadius: BorderRadius.circular(12),
    clipBehavior: Clip.antiAlias,
    child: Padding(
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null) ...[
            Row(
              children: [
                Expanded(
                  child: Text(title!, style: SubtitleSettingsTheme.heading),
                ),
                ?action,
              ],
            ),
            const SizedBox(height: 8),
          ],
          child,
        ],
      ),
    ),
  );
}

class SubtitleSettingsRow extends StatelessWidget {
  const SubtitleSettingsRow({
    super.key,
    required this.title,
    this.titleKey,
    this.description,
    this.trailing,
    this.onTap,
    this.enabled = true,
  });

  final String title;
  final Key? titleKey;
  final String? description;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) => DesktopButtonClickRegion(
    child: ListTile(
      title: Text(title, key: titleKey, style: SubtitleSettingsTheme.title),
      subtitle: description == null
          ? null
          : Text(description!, style: SubtitleSettingsTheme.description),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      minVerticalPadding: 6,
      dense: true,
      enabled: enabled,
      onTap: enabled ? onTap : null,
      trailing:
          trailing ??
          (onTap == null
              ? null
              : const Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: SubtitleSettingsTheme.secondary,
                )),
    ),
  );
}
