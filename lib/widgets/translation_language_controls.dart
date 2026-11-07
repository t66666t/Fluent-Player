import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/subtitle_translate_settings.dart';
import '../services/subtitle_translation_languages.dart';
import '../utils/app_toast.dart';
import 'subtitle_settings_layout.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// The same visible direction and translator identity on single/batch pages.
class TranslationDirectionSummary extends StatefulWidget {
  const TranslationDirectionSummary({
    super.key,
    this.settings,
    required this.onOpen,
    this.foregroundColor,
    this.enabled = true,
    this.label,
    this.maxLines = 1,
    this.flat = false,
  });
  final SubtitleTranslateSettings? settings;
  final void Function(SubtitleTranslateSettings) onOpen;
  final Color? foregroundColor;
  final bool enabled;
  final String? label;
  final int maxLines;
  final bool flat;
  @override
  State<TranslationDirectionSummary> createState() =>
      _TranslationDirectionSummaryState();
}

class _TranslationDirectionSummaryState
    extends State<TranslationDirectionSummary> {
  SubtitleTranslateSettings? _fallback;
  SubtitleTranslateSettings get settings =>
      widget.settings ?? (_fallback ??= SubtitleTranslateSettings());
  @override
  void initState() {
    super.initState();
    unawaited(settings.ensureLoaded());
  }

  @override
  void didUpdateWidget(covariant TranslationDirectionSummary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.settings, widget.settings)) {
      unawaited(settings.ensureLoaded());
    }
  }

  @override
  void dispose() {
    _fallback?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: settings,
    builder: (_, _) {
      if (widget.flat) {
        return SubtitleSettingsRow(
          key: const ValueKey('translation-direction-summary'),
          title: widget.label ?? '翻译方式',
          description:
              '${settings.mode == SubtitleTranslationMode.smart ? settings.smartPolicy.compactSummary : settings.languageSummary} · ${settings.binding.label}',
          enabled: widget.enabled,
          onTap: () => widget.onOpen(settings),
        );
      }
      final color =
          widget.foregroundColor ?? Theme.of(context).colorScheme.onSurface;
      return Tooltip(
        message: '翻译设置：${settings.summary}',
        child: DesktopButtonClickRegion(
          child: TextButton(
            key: const ValueKey('translation-direction-summary'),
            onPressed: widget.enabled ? () => widget.onOpen(settings) : null,
            style: TextButton.styleFrom(
              foregroundColor: color,
              minimumSize: const Size(0, 44),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              alignment: Alignment.centerLeft,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Row(
              children: [
                const Icon(Icons.translate_rounded, size: 17),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${widget.label == null ? '' : '${widget.label} · '}${settings.mode == SubtitleTranslationMode.smart ? settings.smartPolicy.compactSummary : settings.languageSummary}',
                        maxLines: widget.maxLines,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        settings.binding.label,
                        maxLines: widget.maxLines,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: color.withValues(alpha: .7),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                const Text('设置', style: TextStyle(fontSize: 12)),
                const SizedBox(width: 3),
                const Icon(Icons.edit_outlined, size: 14),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class TranslationLanguageControls extends StatelessWidget {
  const TranslationLanguageControls({
    super.key,
    required this.settings,
    this.enabled = true,
    this.showContext = true,
    this.foregroundColor,
  });
  final SubtitleTranslateSettings settings;
  final bool enabled, showContext;
  final Color? foregroundColor;

  Future<void> _choose(BuildContext context, bool source) async {
    final binding = settings.binding;
    final selected = source ? settings.sourceLanguage : settings.targetLanguage;
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _LanguagePicker(
        source: source,
        selected: selected,
        binding: binding,
        showTranslator: showContext,
      ),
    );
    if (result != null) {
      await settings.setLanguages(
        bindingKey: binding.key,
        source: source ? result : null,
        target: source ? null : result,
      );
    }
  }

  Future<void> _savePolicy(SmartTranslationPolicy policy, String key) async {
    try {
      await settings.setSmartPolicy(policy, bindingKey: key);
    } catch (error) {
      AppToast.show('规则未保存：$error', type: AppToastType.error);
    }
  }

  Future<void> _chooseRule(BuildContext context, int index, bool source) async {
    final binding = settings.binding, policy = settings.smartPolicy;
    final rule = index < 0 ? null : policy.rules[index];
    final selected = index < 0
        ? policy.otherTarget
        : source
        ? rule!.source
        : rule!.target;
    final excluded = source
        ? policy.rules.indexed
              .where((entry) => entry.$1 != index)
              .map((entry) => subtitleLanguageFamily(entry.$2.source))
              .toSet()
        : <String>{};
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _LanguagePicker(
        source: source,
        selected: selected,
        binding: binding,
        allowAuto: false,
        allowOriginal: !source,
        excludedFamilies: excluded,
        showTranslator: showContext,
        title: source ? '选择规则的源语言' : '选择规则的目标语言',
      ),
    );
    if (result == null) return;
    if (index < 0) {
      await _savePolicy(policy.copyWith(otherTarget: result), binding.key);
      return;
    }
    final rules = policy.rules.toList();
    rules[index] = SmartTranslationRule(
      source: source ? result : rule!.source,
      target: source ? rule!.target : result,
    );
    await _savePolicy(policy.copyWith(rules: rules), binding.key);
  }

  Widget _smartRules(BuildContext context, Color color) {
    final policy = settings.smartPolicy, binding = settings.binding;
    Widget field(String title, String code, String key, VoidCallback onTap) =>
        DesktopButtonClickRegion(
          child: OutlinedButton(
            key: ValueKey(key),
            onPressed: enabled ? onTap : null,
            style: OutlinedButton.styleFrom(
              foregroundColor: color,
              alignment: Alignment.centerLeft,
              minimumSize: const Size(0, 48),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 10,
                          color: color.withValues(alpha: .65),
                        ),
                      ),
                      Text(
                        title == '检测到' && subtitleLanguageFamily(code) == 'zh'
                            ? '中文'
                            : SmartTranslationPolicy.targetLabel(code),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.expand_more, size: 14),
              ],
            ),
          ),
        );
    final used = policy.rules
        .map((rule) => subtitleLanguageFamily(rule.source))
        .toSet();
    final next = binding.languages
        .where(
          (language) => !used.contains(subtitleLanguageFamily(language.code)),
        )
        .firstOrNull;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (index, rule) in policy.rules.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Row(
              children: [
                Expanded(
                  child: field(
                    '检测到',
                    rule.source,
                    'smart-rule-$index-source',
                    () => _chooseRule(context, index, true),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(Icons.arrow_forward, size: 14),
                ),
                Expanded(
                  child: field(
                    '译为',
                    rule.target,
                    'smart-rule-$index-target',
                    () => _chooseRule(context, index, false),
                  ),
                ),
                DesktopButtonClickRegion(
                  child: IconButton(
                    key: ValueKey('smart-rule-$index-delete'),
                    tooltip: '删除规则',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 28,
                      height: 40,
                    ),
                    icon: const Icon(Icons.remove_circle_outline, size: 17),
                    onPressed: enabled
                        ? () => _savePolicy(
                            policy.copyWith(
                              rules: [
                                for (var i = 0; i < policy.rules.length; i++)
                                  if (i != index) policy.rules[i],
                              ],
                            ),
                            binding.key,
                          )
                        : null,
                  ),
                ),
              ],
            ),
          ),
        Row(
          children: [
            const Expanded(child: Text('其他语言', style: TextStyle(fontSize: 12))),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Icon(Icons.arrow_forward, size: 14),
            ),
            Expanded(
              child: field(
                '译为',
                policy.otherTarget,
                'smart-other-target',
                () => _chooseRule(context, -1, false),
              ),
            ),
            const SizedBox(width: 28),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: DesktopButtonClickRegion(
            child: TextButton.icon(
              key: const ValueKey('smart-add-rule'),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('添加语言规则'),
              onPressed: enabled && next != null
                  ? () => _savePolicy(
                      policy.copyWith(
                        rules: [
                          ...policy.rules,
                          SmartTranslationRule(
                            source: next.code,
                            target: policy.otherTarget,
                          ),
                        ],
                      ),
                      binding.key,
                    )
                  : null,
            ),
          ),
        ),
        Row(
          children: [
            Expanded(
              child: Text(
                '方向不确定时保留原文',
                style: TextStyle(
                  fontSize: 11,
                  color: color.withValues(alpha: .75),
                ),
              ),
            ),
            Switch(
              key: const ValueKey('smart-keep-uncertain'),
              value: policy.keepUncertain,
              onChanged: enabled
                  ? (value) => _savePolicy(
                      policy.copyWith(keepUncertain: value),
                      binding.key,
                    )
                  : null,
            ),
          ],
        ),
        Text(
          policy.keepUncertain
              ? '简繁中文合并判断；混合字幕按片段互译。规则也可选择“保留原文”。'
              : '无法判断语言的片段按“其他语言”处理。',
          style: TextStyle(fontSize: 11, color: color.withValues(alpha: .65)),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: settings,
    builder: (_, _) {
      final color = foregroundColor ?? Theme.of(context).colorScheme.onSurface;
      Widget language(bool source) => Expanded(
        child: DesktopButtonClickRegion(
          child: OutlinedButton(
            key: ValueKey(
              source
                  ? 'translation-source-language'
                  : 'translation-target-language',
            ),
            onPressed: enabled ? () => _choose(context, source) : null,
            style: OutlinedButton.styleFrom(
              foregroundColor: color,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              alignment: Alignment.centerLeft,
              minimumSize: const Size(0, 48),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        source ? '源语言' : '目标语言',
                        style: TextStyle(
                          fontSize: 11,
                          color: color.withValues(alpha: .65),
                        ),
                      ),
                      Text(
                        subtitleLanguageLabel(
                          source
                              ? settings.sourceLanguage
                              : settings.targetLanguage,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.expand_more, size: 16),
              ],
            ),
          ),
        ),
      );
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showContext)
            Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: Text(
                '当前翻译：${settings.binding.label}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: color.withValues(alpha: .75),
                ),
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final mode in SubtitleTranslationMode.values)
                ChoiceChip(
                  key: ValueKey('translation-mode-${mode.name}'),
                  label: Text(
                    mode == SubtitleTranslationMode.fixed ? '固定目标' : '智能互译',
                  ),
                  selected: settings.mode == mode,
                  onSelected: enabled ? (_) => settings.setMode(mode) : null,
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (settings.mode == SubtitleTranslationMode.smart)
            _smartRules(context, color)
          else
            Row(
              children: [
                language(true),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Icon(
                    Icons.arrow_forward_rounded,
                    size: 16,
                    color: color.withValues(alpha: .65),
                  ),
                ),
                language(false),
              ],
            ),
        ],
      );
    },
  );
}

class _LanguagePicker extends StatefulWidget {
  const _LanguagePicker({
    required this.source,
    required this.selected,
    required this.binding,
    this.allowAuto = true,
    this.allowOriginal = false,
    this.excludedFamilies = const {},
    this.showTranslator = true,
    this.title,
  });
  final bool source;
  final String selected;
  final SubtitleTranslationBinding binding;
  final bool allowAuto, allowOriginal;
  final Set<String> excludedFamilies;

  /// 手动翻译不使用内部引擎，选语言时也不展示“当前翻译”。
  final bool showTranslator;
  final String? title;
  @override
  State<_LanguagePicker> createState() => _LanguagePickerState();
}

class _LanguagePickerState extends State<_LanguagePicker> {
  String _search = '';
  @override
  Widget build(BuildContext context) {
    final choices =
        [
              if (widget.source && widget.allowAuto)
                const SubtitleTranslationLanguage(code: 'auto', label: '自动检测'),
              if (widget.allowOriginal)
                const SubtitleTranslationLanguage(
                  code: keepOriginal,
                  label: '保留原文',
                ),
              ...widget.binding.languages,
            ]
            .where(
              (language) =>
                  !widget.excludedFamilies.contains(
                    subtitleLanguageFamily(language.code),
                  ) &&
                  (language.label.toLowerCase().contains(_search) ||
                      language.code.toLowerCase().contains(_search)),
            )
            .toList();
    return _LanguagePickerViewport(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              widget.title ?? (widget.source ? '选择源语言' : '选择目标语言'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (widget.showTranslator)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
              child: Text(
                '当前翻译：${widget.binding.label}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              key: const ValueKey('translation-language-search'),
              decoration: const InputDecoration(
                isDense: true,
                hintText: '搜索语言或语言代码',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (value) =>
                  setState(() => _search = value.trim().toLowerCase()),
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: choices.isEmpty
                ? const Center(child: Text('没有匹配的语言'))
                : ListView.builder(
                    key: const ValueKey('translation-language-options'),
                    itemCount: choices.length,
                    itemBuilder: (_, index) {
                      final language = choices[index];
                      return ListTile(
                        key: ValueKey('translation-language-${language.code}'),
                        dense: true,
                        title: Text(language.label),
                        subtitle: Text(language.code),
                        trailing: language.code == widget.selected
                            ? const Icon(Icons.check_rounded)
                            : null,
                        onTap: () => Navigator.pop(context, language.code),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Keyboard geometry changes the viewport, not the language projection or field.
class _LanguagePickerViewport extends StatelessWidget {
  const _LanguagePickerViewport({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SizedBox(
        height: math.min(
          560,
          math.max(
            160,
            MediaQuery.sizeOf(context).height -
                bottom -
                MediaQuery.paddingOf(context).top -
                64,
          ),
        ),
        child: child,
      ),
    );
  }
}
