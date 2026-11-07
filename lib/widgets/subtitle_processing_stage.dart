import 'package:flutter/material.dart';

import 'desktop_button_click_region.dart';
import 'subtitle_settings_layout.dart';

/// Equal treatment for the two optional stages, with parameters kept separate
/// from the switch that enables the stage.
class SubtitleProcessingStage extends StatelessWidget {
  const SubtitleProcessingStage({
    super.key,
    required this.title,
    required this.summary,
    required this.value,
    required this.onChanged,
    required this.onConfigure,
    required this.toggleKey,
    required this.settingsKey,
    this.onEditPrompt,
    this.promptKey,
    this.onModel,
    this.modelKey,
    this.modelLabel = '模型',
    this.expansionKey,
    this.configureLabel = '翻译选项',
    this.expanded,
  });

  final String title, summary;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final VoidCallback? onConfigure;
  final VoidCallback? onEditPrompt;
  final VoidCallback? onModel;
  final Key? modelKey;
  final String modelLabel;
  final Key? promptKey;
  final Key? expansionKey;
  final String configureLabel;
  final Key toggleKey, settingsKey;
  final bool? expanded;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final inline =
            constraints.maxWidth >=
            280 * MediaQuery.textScalerOf(context).scale(1);
        final actions = <Widget>[
          if (onModel != null || modelKey != null)
            DesktopButtonClickRegion(
              child: OutlinedButton.icon(
                key: modelKey,
                onPressed: onModel,
                style: _buttonStyle,
                icon: const Icon(Icons.tune_rounded, size: 15),
                label: Text(modelLabel),
              ),
            ),
          DesktopButtonClickRegion(
            child: expanded != null
                ? Tooltip(
                    message: expanded! ? '收起翻译选项' : '展开翻译选项',
                    child: TextButton(
                      key: settingsKey,
                      onPressed: onConfigure,
                      style: TextButton.styleFrom(
                        foregroundColor: SubtitleSettingsTheme.foreground,
                        minimumSize: const Size(0, 44),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(configureLabel),
                          const SizedBox(width: 2),
                          Icon(
                            expanded! ? Icons.expand_less : Icons.expand_more,
                            key: expansionKey,
                            size: 20,
                          ),
                        ],
                      ),
                    ),
                  )
                : OutlinedButton.icon(
                    key: settingsKey,
                    onPressed: onConfigure,
                    style: _buttonStyle,
                    icon: const Icon(Icons.tune_rounded, size: 15),
                    label: Text(configureLabel),
                  ),
          ),
          if (promptKey != null)
            DesktopButtonClickRegion(
              child: OutlinedButton.icon(
                key: promptKey,
                onPressed: onEditPrompt,
                style: _buttonStyle,
                icon: const Icon(Icons.edit_note_rounded, size: 16),
                label: const Text('提示词'),
              ),
            ),
        ];
        final toggle = SizedBox(
          width: 48,
          child: Semantics(
            label: title,
            child: Switch.adaptive(
              key: toggleKey,
              value: value,
              onChanged: onChanged,
            ),
          ),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title, style: SubtitleSettingsTheme.title),
                ),
                if (inline) ...[
                  Wrap(spacing: 6, children: actions),
                  const SizedBox(width: 8),
                ],
                toggle,
              ],
            ),
            Text(
              summary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: SubtitleSettingsTheme.description,
            ),
            if (!inline) ...[
              const SizedBox(height: 4),
              Wrap(spacing: 6, runSpacing: 4, children: actions),
            ],
          ],
        );
      },
    ),
  );

  static final _buttonStyle =
      OutlinedButton.styleFrom(
        foregroundColor: SubtitleSettingsTheme.foreground,
        backgroundColor: Colors.transparent,
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        tapTargetSize: MaterialTapTargetSize.padded,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ).copyWith(
        side: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.focused) &&
                  !states.contains(WidgetState.disabled)
              ? const BorderSide(
                  color: SubtitleSettingsTheme.accent,
                  width: 1.5,
                )
              : const BorderSide(color: Color(0xFF464950)),
        ),
      );
}
