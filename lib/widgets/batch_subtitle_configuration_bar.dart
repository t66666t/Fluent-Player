import '../theme/app_settings_theme.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../features/model_center/model_center_screen.dart';
import '../features/model_center/model_center_service.dart';
import '../services/settings_service.dart';
import '../services/subtitle_translate_settings.dart';
import 'desktop_button_click_region.dart';
import 'transcript_translate_settings_sheet.dart';
import 'transcription_language_selector.dart';
import 'subtitle_optimization_control.dart';

/// Settings actions own their single-line summaries. The bar measures those
/// contents before choosing one row or two aligned rows; phone details remain
/// collapsible so queue space is available in short windows.
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
    if (profile.local) {
      return center.artifact(profile.model)?.name ?? profile.name;
    }
    return [
      profile.name,
      if (model.isNotEmpty && model != profile.name) model,
    ].join(' · ');
  }

  String get _translationSummary =>
      '${translate.binding.label} · ${translate.mode == SubtitleTranslationMode.smart ? translate.smartPolicy.compactSummary : translate.languageSummary}';

  @override
  Widget build(BuildContext context) =>
      AppSettingsTheme(child: Builder(builder: _buildThemedSurface));

  Widget _buildThemedSurface(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([widget.settings, translate, center]),
    builder: (context, _) => Material(
      color: Theme.of(context).colorScheme.surface,
      child: Container(
        key: const ValueKey('batch-configuration-bar'),
        padding: EdgeInsets.symmetric(
          horizontal: widget.horizontalPadding,
          vertical: MediaQuery.sizeOf(context).shortestSide < 600 ? 4 : 6,
        ),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: Theme.of(context).dividerColor,
              width: .5,
            ),
          ),
        ),
        child: LayoutBuilder(
          builder: (context, pane) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final enabled = widget.settings.batchSubtitleTranslateEnabled;
                  final height = math.max(
                    40.0,
                    MediaQuery.textScalerOf(context).scale(12) * 1.25 + 12,
                  );
                  final languageOptions = center.currentAsrLanguageOptions;
                  final languageLabel = languageOptions.label(
                    center.effectiveAsrLanguage,
                  );
                  final languageWidth =
                      _textWidth(context, languageLabel) +
                      16 +
                      6 +
                      16 +
                      (languageOptions.editable ? 19 : 0);
                  final toggleWidth = _textWidth(context, '翻译字幕') + 44 + 6 + 16;
                  final auxiliaryWidth = math.max(languageWidth, toggleWidth);
                  // Cap only unusually long model/service names. Ordinary summaries
                  // get their full measured width rather than half the screen each.
                  final maxActionWidth =
                      440 * MediaQuery.textScalerOf(context).scale(1);
                  final asrWidth = math.min(
                    maxActionWidth,
                    _actionWidth(context, '转录设置', _transcriptionSummary),
                  );
                  final translationWidth = math.min(
                    maxActionWidth,
                    _actionWidth(context, '翻译设置', _translationSummary),
                  );
                  final optimizationWidth =
                      160 * MediaQuery.textScalerOf(context).scale(1);
                  final inlineWidth =
                      asrWidth +
                      translationWidth +
                      auxiliaryWidth * 2 +
                      optimizationWidth +
                      32;
                  final language = TranscriptionLanguageSelector(
                    center: center,
                    buttonKey: const ValueKey('batch-transcription-language'),
                    compact: true,
                    controlHeight: height,
                  );
                  final toggle = _BatchTranslationToggle(
                    key: const ValueKey('batch-current-mode'),
                    enabled: enabled,
                    height: height,
                    onChanged:
                        widget.settings.updateBatchSubtitleTranslateEnabled,
                  );
                  if (constraints.maxWidth >= inlineWidth &&
                      MediaQuery.sizeOf(context).height >= 480) {
                    final extra = (constraints.maxWidth - inlineWidth) / 2;
                    return Row(
                      key: const ValueKey('batch-configuration-inline'),
                      children: [
                        SizedBox(
                          width: asrWidth + extra,
                          child: _asrAction(context, height: height),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(width: auxiliaryWidth, child: language),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: optimizationWidth,
                          height: height,
                          child: const SubtitleOptimizationControl(
                            compact: true,
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: translationWidth + extra,
                          child: _translationAction(context, height: height),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(width: auxiliaryWidth, child: toggle),
                      ],
                    );
                  }
                  if (constraints.maxWidth < 600 ||
                      MediaQuery.sizeOf(context).height < 480) {
                    return _compactConfiguration(
                      context,
                      constraints.maxWidth,
                      height,
                      language,
                      auxiliaryWidth,
                      enabled,
                    );
                  }
                  return Column(
                    key: const ValueKey('batch-configuration-stacked'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(child: _asrAction(context, height: height)),
                          const SizedBox(width: 8),
                          SizedBox(width: auxiliaryWidth, child: language),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          SizedBox(
                            width: optimizationWidth,
                            height: height,
                            child: const SubtitleOptimizationControl(
                              compact: true,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _translationAction(context, height: height),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(width: auxiliaryWidth, child: toggle),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _asrAction(
    BuildContext context, {
    required double height,
    bool detail = true,
    bool shortLabel = false,
    bool dense = false,
  }) => _ConfigurationAction(
    buttonKey: const ValueKey('batch-transcription-settings'),
    summaryKey: const ValueKey('batch-transcription-summary'),
    icon: Icons.subtitles_outlined,
    label: shortLabel ? '转录' : '转录设置',
    tooltip: '转录设置 · $_transcriptionSummary',
    detail: _transcriptionSummary,
    height: height,
    showDetail: detail,
    dense: dense,
    onPressed: () => openModelCenter(
      context,
      service: center,
      translateSettings: translate,
      transcriptionOnly: true,
    ),
  );

  Widget _translationAction(
    BuildContext context, {
    required double height,
    bool detail = true,
    bool shortLabel = false,
    bool dense = false,
  }) => _ConfigurationAction(
    buttonKey: const ValueKey('batch-translation-settings'),
    summaryKey: const ValueKey('batch-translation-summary'),
    icon: Icons.translate_rounded,
    label: shortLabel ? '翻译' : '翻译设置',
    tooltip: '翻译设置 · ${translate.summary}',
    detail: _translationSummary,
    height: height,
    showDetail: detail,
    dense: dense,
    onPressed: () =>
        showTranscriptTranslateSettings(context, settings: translate),
  );

  Widget _compactConfiguration(
    BuildContext context,
    double width,
    double height,
    Widget language,
    double auxiliaryWidth,
    bool enabled,
  ) {
    final compactToggleWidth =
        _textWidth(context, '翻译', fontSize: 11) + 44 + 4 + 8;
    final minShortAction = _textWidth(context, '转录', bold: true) + 14 + 4 + 12;
    final optimizationWidth = width < 600
        ? 38 + _textWidth(context, '优化') + 14 + 8 + 10
        : 160 * MediaQuery.textScalerOf(context).scale(1);
    final twoRows =
        width <
        minShortAction + optimizationWidth + compactToggleWidth + 40 + 12;
    final actionWidth =
        width -
        optimizationWidth -
        (twoRows ? 4 : compactToggleWidth + 40 + 12);
    final shortLabels =
        actionWidth < _textWidth(context, '转录设置', bold: true) + 14 + 4 + 12;
    final showDetail = width >= 600;
    final actions = [
      Expanded(
        child: Align(
          alignment: Alignment.centerLeft,
          child: _asrAction(
            context,
            height: math.max(32, height - 8),
            detail: showDetail,
            shortLabel: shortLabels,
            dense: true,
          ),
        ),
      ),
      const SizedBox(width: 4),
      SizedBox(
        width: optimizationWidth,
        child: SizedBox(
          height: height,
          child: const SubtitleOptimizationControl(compact: true),
        ),
      ),
    ];
    final controls = [
      SizedBox(
        width: compactToggleWidth,
        child: _BatchTranslationToggle(
          enabled: enabled,
          height: height,
          compact: true,
          onChanged: widget.settings.updateBatchSubtitleTranslateEnabled,
        ),
      ),
      const SizedBox(width: 4),
      DesktopButtonClickRegion(
        child: IconButton(
          key: const ValueKey('batch-configuration-details'),
          tooltip: _detailsExpanded ? '收起配置详情' : '展开配置详情',
          onPressed: () => setState(() => _detailsExpanded = !_detailsExpanded),
          icon: Icon(
            _detailsExpanded ? Icons.expand_less : Icons.expand_more,
            size: 18,
          ),
          constraints: BoxConstraints.tightFor(width: 40, height: height),
          style: IconButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          padding: EdgeInsets.zero,
        ),
      ),
    ];
    return Column(
      key: const ValueKey('batch-current-mode'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            ...actions,
            if (!twoRows) ...[const SizedBox(width: 4), ...controls],
          ],
        ),
        if (twoRows) Row(children: [const Spacer(), ...controls]),
        if (_detailsExpanded) ...[
          _translationAction(context, height: height),
          const SizedBox(height: 6),
          Row(
            children: [
              if (!showDetail)
                Expanded(
                  child: _SummaryText(
                    text: _transcriptionSummary,
                    summaryKey: const ValueKey('batch-transcription-summary'),
                  ),
                )
              else
                const Spacer(),
              const SizedBox(width: 8),
              SizedBox(
                width: math.min(auxiliaryWidth, width * .55),
                child: language,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  enabled ? '翻译字幕' : '不翻译',
                  style: _labelStyle(context),
                ),
              ),
              TextButton.icon(
                key: const ValueKey('batch-optimization-prompt'),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () =>
                    showSubtitleOptimizationSettings(context, showPrompt: true),
                icon: const Icon(Icons.edit_note_rounded, size: 16),
                label: const Text('优化提示词', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

TextStyle _labelStyle(BuildContext context) => Theme.of(context)
    .textTheme
    .labelMedium!
    .copyWith(fontSize: 12, height: 1.25, fontWeight: FontWeight.w600);

TextStyle _detailStyle(BuildContext context) => _labelStyle(context).copyWith(
  fontWeight: FontWeight.w400,
  color: Theme.of(context).colorScheme.onSurfaceVariant,
);

double _textWidth(
  BuildContext context,
  String text, {
  bool bold = false,
  double fontSize = 12,
}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: (bold ? _labelStyle(context) : _detailStyle(context)).copyWith(
        fontSize: fontSize,
      ),
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

double _actionWidth(BuildContext context, String label, String detail) =>
    _textWidth(context, label, bold: true) + _textWidth(context, detail) + 70;

class _SummaryText extends StatelessWidget {
  const _SummaryText({required this.text, this.summaryKey});
  final String text;
  final Key? summaryKey;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: text,
    child: Text(
      text,
      key: summaryKey,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: _detailStyle(context),
    ),
  );
}

class _ConfigurationAction extends StatelessWidget {
  const _ConfigurationAction({
    required this.buttonKey,
    required this.summaryKey,
    required this.icon,
    required this.label,
    required this.detail,
    required this.tooltip,
    required this.height,
    required this.onPressed,
    this.showDetail = true,
    this.dense = false,
  });
  final Key buttonKey, summaryKey;
  final IconData icon;
  final String label, detail, tooltip;
  final double height;
  final VoidCallback onPressed;
  final bool showDetail, dense;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: DesktopButtonClickRegion(
        child: SizedBox(
          height: height,
          child: OutlinedButton(
            key: buttonKey,
            onPressed: onPressed,
            style: OutlinedButton.styleFrom(
              foregroundColor: colors.onSurface,
              backgroundColor: colors.surfaceContainerHighest.withValues(
                alpha: .16,
              ),
              minimumSize: Size(0, height),
              padding: EdgeInsets.symmetric(horizontal: dense ? 6 : 10),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              side: BorderSide(
                color: colors.outlineVariant.withValues(alpha: .65),
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Row(
              mainAxisSize: showDetail ? MainAxisSize.max : MainAxisSize.min,
              children: [
                Icon(icon, size: dense ? 14 : 16, color: colors.primary),
                SizedBox(width: dense ? 4 : 6),
                if (showDetail) ...[
                  Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    style: _labelStyle(context),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _SummaryText(text: detail, summaryKey: summaryKey),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 14,
                    color: colors.onSurfaceVariant,
                  ),
                ] else
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: _labelStyle(context),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BatchTranslationToggle extends StatelessWidget {
  const _BatchTranslationToggle({
    super.key,
    required this.enabled,
    required this.onChanged,
    required this.height,
    this.compact = false,
  });
  final bool enabled, compact;
  final double height;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return MergeSemantics(
      child: Tooltip(
        message: enabled ? '翻译字幕' : '不翻译',
        child: DesktopButtonClickRegion(
          child: Material(
            color: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(
                color: colors.outlineVariant.withValues(
                  alpha: compact ? 0 : .65,
                ),
              ),
            ),
            child: InkWell(
              onTap: () => onChanged(!enabled),
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                height: height,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          compact
                              ? '翻译'
                              : enabled
                              ? '翻译字幕'
                              : '不翻译',
                          maxLines: 1,
                          softWrap: false,
                          style: _labelStyle(
                            context,
                          ).copyWith(fontSize: compact ? 11 : 12),
                        ),
                      ),
                      SizedBox(width: compact ? 4 : 6),
                      SizedBox(
                        width: 44,
                        height: height,
                        child: OverflowBox(
                          minWidth: 60,
                          maxWidth: 60,
                          child: Transform.scale(
                            scale: .72,
                            transformHitTests: false,
                            child: Switch(
                              key: const ValueKey('batch-translation-enabled'),
                              value: enabled,
                              onChanged: onChanged,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                        ),
                      ),
                    ],
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
