import 'dart:async';

import 'package:flutter/material.dart';

import '../features/model_center/model_center_screen.dart';
import '../features/model_center/model_center_service.dart';
import '../services/settings_service.dart';
import '../services/subtitle_translate_settings.dart';
import 'transcript_translate_settings_sheet.dart';
import 'transcription_language_selector.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Keeps transcription and translation defaults beside their settings actions.
class BatchSubtitleConfigurationBar extends StatefulWidget {
  const BatchSubtitleConfigurationBar({
    super.key,
    required this.settings,
    this.translateSettings,
    this.modelCenter,
    this.horizontalPadding = 16,
  });

  final SettingsService settings;
  final SubtitleTranslateSettings? translateSettings;
  final ModelCenterService? modelCenter;
  final double horizontalPadding;

  @override
  State<BatchSubtitleConfigurationBar> createState() =>
      _BatchSubtitleConfigurationBarState();
}

class _BatchSubtitleConfigurationBarState
    extends State<BatchSubtitleConfigurationBar> {
  bool _detailsExpanded = false;
  SubtitleTranslateSettings? _fallback;
  SubtitleTranslateSettings get translate =>
      widget.translateSettings ?? (_fallback ??= SubtitleTranslateSettings());
  ModelCenterService get center =>
      widget.modelCenter ?? ModelCenterService.instance;

  @override
  void initState() {
    super.initState();
    unawaited(translate.ensureLoaded());
  }

  @override
  void didUpdateWidget(covariant BatchSubtitleConfigurationBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.translateSettings, widget.translateSettings)) {
      unawaited(translate.ensureLoaded());
    }
  }

  @override
  void dispose() {
    _fallback?.dispose();
    super.dispose();
  }

  String get _transcriptionSummary {
    final profile = center.asrProfile;
    final model = center.artifact(profile.model)?.name ?? profile.model;
    return [
      profile.name,
      if (model.isNotEmpty && model != profile.name) model,
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([widget.settings, translate, center]),
    builder: (context, _) {
      final theme = Theme.of(context);
      final enabled = widget.settings.batchSubtitleTranslateEnabled;
      final compactLabels =
          MediaQuery.sizeOf(context).width < 420 &&
          MediaQuery.textScalerOf(context).scale(1) >= 1.5;
      final transcription = _ConfigurationSummary(
        icon: Icons.subtitles_outlined,
        label: '转录',
        detail: _transcriptionSummary,
        primary: true,
      );
      final languageSummary = translate.mode == SubtitleTranslationMode.smart
          ? translate.smartPolicy.compactSummary
          : translate.languageSummary;
      final translation = Tooltip(
        message: translate.summary,
        child: _ConfigurationSummary(
          icon: Icons.translate_rounded,
          label: '翻译设置',
          detail: '${translate.binding.label} · $languageSummary',
        ),
      );
      final mode = _BatchModeStatus(enabled: enabled, compact: compactLabels);
      final toggle = _BatchTranslationToggle(
        enabled: enabled,
        compact: compactLabels,
        onChanged: widget.settings.updateBatchSubtitleTranslateEnabled,
      );
      final transcriptionButton = DesktopButtonClickRegion(child: OutlinedButton.icon(
        key: const ValueKey('batch-transcription-settings'),
        onPressed: () => openModelCenter(
          context,
          service: center,
          translateSettings: translate,
          transcriptionOnly: true,
        ),
        icon: const Icon(Icons.settings_outlined, size: 16),
        label: const Text('转录设置'),
        style: _settingsButtonStyle(context, primary: true),
      ));
      final translationButton = DesktopButtonClickRegion(child: OutlinedButton.icon(
        key: const ValueKey('batch-translation-settings'),
        onPressed: () =>
            showTranscriptTranslateSettings(context, settings: translate),
        icon: const Icon(Icons.settings_outlined, size: 16),
        label: const Text('翻译设置'),
        style: _settingsButtonStyle(context),
      ));
      final transcriptionRow = LayoutBuilder(
        builder: (context, constraints) {
          final language = TranscriptionLanguageSelector(
            center: center,
            buttonKey: const ValueKey('batch-transcription-language'),
          );
          if (constraints.maxWidth >=
              440 * MediaQuery.textScalerOf(context).scale(1)) {
            return Row(
              children: [
                Expanded(child: transcription),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 190),
                  child: language,
                ),
                const SizedBox(width: 8),
                transcriptionButton,
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: transcription),
                  const SizedBox(width: 12),
                  transcriptionButton,
                ],
              ),
              Align(alignment: Alignment.centerLeft, child: language),
            ],
          );
        },
      );
      final translationRow = Row(
        children: [
          Expanded(child: translation),
          const SizedBox(width: 12),
          translationButton,
        ],
      );
      return Material(
        color: theme.colorScheme.surface,
        child: Container(
          key: const ValueKey('batch-configuration-bar'),
          padding: EdgeInsets.symmetric(
            horizontal: widget.horizontalPadding,
            vertical: MediaQuery.sizeOf(context).shortestSide < 600 ? 0 : 6,
          ),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: theme.dividerColor, width: .5),
            ),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (MediaQuery.sizeOf(context).shortestSide < 600 ||
                  constraints.maxWidth < 600) {
                return _buildCompactConfiguration(context, enabled);
              }
              final inline =
                  constraints.maxWidth >=
                  1100 * MediaQuery.textScalerOf(context).scale(1);
              if (inline) {
                return Row(
                  children: [
                    mode,
                    const SizedBox(width: 16),
                    Expanded(child: transcriptionRow),
                    const SizedBox(width: 24),
                    Expanded(child: translationRow),
                    const SizedBox(width: 16),
                    SizedBox(width: 166, child: toggle),
                  ],
                );
              }
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: mode,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(flex: 5, child: toggle),
                    ],
                  ),
                  const SizedBox(height: 6),
                  transcriptionRow,
                  const SizedBox(height: 6),
                  translationRow,
                ],
              );
            },
          ),
        ),
      );
    },
  );

  Widget _buildCompactConfiguration(BuildContext context, bool enabled) {
    final languageSummary = translate.mode == SubtitleTranslationMode.smart
        ? translate.smartPolicy.compactSummary
        : translate.languageSummary;
    return Column(
      key: const ValueKey('batch-current-mode'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(children: [
          Expanded(
            child: Row(
              children: [
                Flexible(child: _CompactConfigurationAction(
                  buttonKey: const ValueKey('batch-transcription-settings'),
                  icon: Icons.subtitles_outlined,
                  label: '转录设置', detail: _transcriptionSummary, primary: true,
                  onPressed: () => openModelCenter(context, service: center,
                    translateSettings: translate, transcriptionOnly: true),
                )),
                const SizedBox(width: 4),
                Flexible(child: _CompactConfigurationAction(
                  buttonKey: const ValueKey('batch-translation-settings'),
                  icon: Icons.translate_rounded,
                  label: '翻译设置', detail: '${translate.binding.label} · $languageSummary',
                  onPressed: () => showTranscriptTranslateSettings(context, settings: translate),
                )),
              ],
            ),
          ),
          const SizedBox(width: 4),
          const Text('翻译', style: TextStyle(fontSize: 11)),
          Tooltip(
            message: enabled ? '转录并翻译' : '仅转录',
            child: SizedBox(
              width: 44,
              height: 44,
              child: OverflowBox(
                minWidth: 60,
                maxWidth: 60,
                child: Transform.scale(
                  scale: .62,
                  // Keep the original hit area while reducing the visual size.
                  transformHitTests: false,
                  child: Switch(
                    key: const ValueKey('batch-translation-enabled'),
                    value: enabled,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: widget.settings.updateBatchSubtitleTranslateEnabled,
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: _detailsExpanded ? '收起配置详情' : '展开配置详情',
            onPressed: () => setState(() => _detailsExpanded = !_detailsExpanded),
            icon: Icon(_detailsExpanded ? Icons.expand_less : Icons.expand_more, size: 18),
            constraints: const BoxConstraints.tightFor(width: 44, height: 44),
            style: IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            padding: EdgeInsets.zero,
          ),
        ]),
        if (_detailsExpanded) ...[
          Text(enabled ? '转录并翻译' : '仅转录', style: const TextStyle(fontSize: 12)),
          Align(alignment: Alignment.centerLeft,
            child: Text('$_transcriptionSummary · ${translate.binding.label} · $languageSummary',
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant))),
          TranscriptionLanguageSelector(center: center,
            buttonKey: const ValueKey('batch-transcription-language')),
        ],
      ],
    );
  }

  ButtonStyle _settingsButtonStyle(
    BuildContext context, {
    bool primary = false,
  }) {
    final theme = Theme.of(context);
    return OutlinedButton.styleFrom(
      foregroundColor: primary
          ? theme.colorScheme.primary
          : theme.colorScheme.onSurface,
      side: BorderSide(
        color: primary
            ? theme.colorScheme.primary.withValues(alpha: .6)
            : theme.colorScheme.outlineVariant,
      ),
      minimumSize: const Size(108, 40),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      textStyle: theme.textTheme.labelMedium?.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

/// Settings and their summaries share one tap target on narrow screens.
class _CompactConfigurationAction extends StatelessWidget {
  const _CompactConfigurationAction({
    required this.buttonKey,
    required this.label,
    required this.detail,
    required this.icon,
    required this.onPressed,
    this.primary = false,
  });

  final Key buttonKey;
  final IconData icon;
  final String label, detail;
  final VoidCallback onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: '$label · $detail',
      child: DesktopButtonClickRegion(child: TextButton(
        key: buttonKey, onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: colors.onSurface.withValues(alpha: .8),
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16),
            const SizedBox(width: 4),
            Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, height: 1, fontWeight: FontWeight.w500))),
          ],
        ),
      )),
    );
  }
}

class _BatchModeStatus extends StatelessWidget {
  const _BatchModeStatus({required this.enabled, this.compact = false});
  final bool enabled, compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = enabled ? colors.primary : colors.onSurface;
    return Container(
      key: const ValueKey('batch-current-mode'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: enabled
            ? colors.primary.withValues(alpha: .12)
            : colors.surfaceContainerHighest.withValues(alpha: .5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!compact)
            Text(
              '当前模式',
              style: TextStyle(
                fontSize: 11,
                color: colors.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
            ),
          Text(
            enabled ? '转录并翻译' : '仅转录',
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _BatchTranslationToggle extends StatelessWidget {
  const _BatchTranslationToggle({
    required this.enabled,
    required this.onChanged,
    this.compact = false,
  });
  final bool enabled, compact;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Flexible(
          child: InkWell(
            onTap: () => onChanged(!enabled),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
              child: Text(
                compact ? '翻译' : '转录并翻译',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
        Switch(
          key: const ValueKey('batch-translation-enabled'),
          value: enabled,
          onChanged: onChanged,
        ),
      ],
    ),
  );
}

class _ConfigurationSummary extends StatelessWidget {
  const _ConfigurationSummary({
    required this.icon,
    required this.label,
    required this.detail,
    this.primary = false,
  });

  final IconData icon;
  final String label, detail;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = primary ? colors.onSurface : colors.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 16, color: primary ? colors.primary : color),
        ),
        const SizedBox(width: 7),
        Flexible(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '$label  ',
                  style: TextStyle(
                    fontWeight: primary ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
                TextSpan(text: detail),
              ],
            ),
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: color,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
