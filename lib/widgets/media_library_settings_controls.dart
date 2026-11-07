import 'package:flutter/material.dart';

import '../services/app_haptics.dart';
import '../theme/app_tokens.dart';
import 'desktop_button_click_region.dart';

/// Short explanations stay visible. Long-form help is an explicit action.
class MediaLibrarySettingsRow extends StatelessWidget {
  const MediaLibrarySettingsRow({
    super.key,
    required this.title,
    this.description,
    this.value,
    this.trailing,
    this.feedback,
    this.onTap,
    this.onInformation,
    this.informationKey,
    this.informationLabel,
    this.enabled = true,
    this.toggled,
    this.compact = false,
  });

  final Widget title;
  final Widget? description;
  final Widget? value;
  final Widget? trailing;
  final Widget? feedback;
  final VoidCallback? onTap;
  final VoidCallback? onInformation;
  final Key? informationKey;
  final String? informationLabel;
  final bool enabled;
  final bool? toggled;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final label = title is Text ? (title as Text).data ?? '设置' : '设置';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          container: true,
          toggled: toggled,
          enabled: enabled,
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            minTileHeight: compact ? 56 : 64,
            minVerticalPadding: compact ? 4 : 8,
            horizontalTitleGap: 8,
            title: title,
            subtitle: description,
            titleTextStyle: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: AppTokens.text1,
              fontSize: compact ? 14 : 15,
              height: 1.4,
            ),
            subtitleTextStyle: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppTokens.text2,
              fontSize: compact ? 11 : 12,
              height: 1.4,
            ),
            enabled: enabled,
            onTap: enabled ? AppHaptics.wrap(onTap) : null,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (value != null)
                  DefaultTextStyle.merge(
                    style: const TextStyle(
                      color: AppTokens.text2,
                      fontSize: 13,
                    ),
                    child: value!,
                  ),
                if (onInformation != null)
                  DesktopButtonClickRegion(
                    child: IconButton(
                      key: informationKey ?? ValueKey('setting-info-$label'),
                      tooltip: informationLabel ?? '$label说明',
                      icon: const Icon(Icons.info_outline_rounded, size: 17),
                      color: const Color(0xFF969AA2),
                      constraints: const BoxConstraints.tightFor(
                        width: 44,
                        height: 44,
                      ),
                      padding: EdgeInsets.zero,
                      style: IconButton.styleFrom(
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: AppHaptics.wrap(onInformation),
                    ),
                  ),
                if (trailing != null)
                  trailing!
                else if (onTap != null)
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: AppTokens.text2,
                  ),
              ],
            ),
          ),
        ),
        if (feedback != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: feedback!,
          ),
      ],
    );
  }
}

/// A quiet pill switch using Flutter's native focus, drag and key handling.
/// The row and the control retain a full touch target.
class MediaLibrarySettingsSwitch extends StatelessWidget {
  const MediaLibrarySettingsSwitch({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 48,
    height: 48,
    child: Center(
      child: Transform.scale(
        scale: .82,
        child: Switch(
          value: value,
          onChanged: AppHaptics.wrapValue(onChanged),
          padding: EdgeInsets.zero,
          materialTapTargetSize: MaterialTapTargetSize.padded,
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
                ? AppTokens.accent
                : const Color(0xFF4B5058);
          }),
          trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
          trackOutlineWidth: const WidgetStatePropertyAll(0),
          thumbIcon: const WidgetStatePropertyAll(Icon(null)),
        ),
      ),
    ),
  );
}

/// Keeps the existing value/onChanged contract while sharing the same row.
class MediaLibrarySettingsSwitchTile extends SwitchListTile {
  const MediaLibrarySettingsSwitchTile({
    super.key,
    required super.value,
    required super.onChanged,
    super.title,
    Widget? description,
    this.feedback,
    this.valueControl,
    this.compact = false,
  }) : super(subtitle: description);

  final Widget? feedback;
  final Widget? valueControl;
  final bool compact;

  @override
  Widget build(BuildContext context) => MediaLibrarySettingsRow(
    title: title ?? const SizedBox.shrink(),
    description: subtitle,
    feedback: feedback,
    value: valueControl,
    compact: compact,
    toggled: value,
    enabled: onChanged != null,
    trailing: ExcludeSemantics(
      child: ExcludeFocus(
        child: MediaLibrarySettingsSwitch(value: value, onChanged: onChanged),
      ),
    ),
    onTap: onChanged == null ? null : () => onChanged!(!value),
  );
}

/// An inline choice keeps dependent settings from expanding the whole row.
class MediaLibrarySettingsDropdown<T> extends StatelessWidget {
  const MediaLibrarySettingsDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 44),
    child: DropdownButtonHideUnderline(
      child: DesktopButtonClickRegion(
        child: DropdownButton<T>(
          value: value,
          items: items,
          onChanged: AppHaptics.wrapValue(onChanged),
          isDense: true,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: AppTokens.text2, fontSize: 13),
          dropdownColor: const Color(0xFF292B2E),
          borderRadius: BorderRadius.circular(12),
          icon: const Icon(
            Icons.unfold_more_rounded,
            size: 16,
            color: AppTokens.text2,
          ),
        ),
      ),
    ),
  );
}
