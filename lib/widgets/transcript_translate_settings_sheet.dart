import 'dart:async';
import 'model_center_button.dart';

import 'package:flutter/material.dart';

import '../services/ai_subtitle_api_settings.dart';
import '../services/ai_subtitle_translator.dart';
import '../services/subtitle_translate_settings.dart';
import '../services/subtitle_translation_service.dart';
import '../utils/app_toast.dart';
import 'ai_subtitle_api_dialog.dart';
import 'keyboard_inset_padding.dart';
import 'translation_language_controls.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Opens the translation choices shared with subtitle management.
Future<void> showTranscriptTranslateSettings(
  BuildContext context, {
  SubtitleTranslateSettings? settings,
}) async {
  final shared =
      settings ?? lookupSubtitleTranslateSettings(context, listen: false);
  final selected = shared ?? SubtitleTranslateSettings();
  try {
    await selected.ensureLoaded();
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => KeyboardInsetPadding(
        child: Align(
          alignment: Alignment.bottomCenter,
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: TranscriptTranslateSettingsSheet(settings: selected),
          ),
        ),
      ),
    );
  } finally {
    if (shared == null) selected.dispose();
  }
}

class TranscriptTranslateSettingsSheet extends StatefulWidget {
  const TranscriptTranslateSettingsSheet({super.key, required this.settings});

  final SubtitleTranslateSettings settings;

  @override
  State<TranscriptTranslateSettingsSheet> createState() =>
      _TranscriptTranslateSettingsSheetState();
}

class _TranscriptTranslateSettingsSheetState
    extends State<TranscriptTranslateSettingsSheet> {
  late final TextEditingController _prompt;
  late final FocusNode _promptFocus;
  Timer? _promptSave;

  @override
  void initState() {
    super.initState();
    widget.settings.addListener(_onSettings);
    _prompt = TextEditingController(
      text: widget.settings.aiOptions.customPrompt,
    );
    _promptFocus = FocusNode();
    _prompt.addListener(_onPromptChanged);
    unawaited(
      widget.settings.ensureLoaded().then((_) {
        if (!mounted) return;
        _copyPromptFromSettings();
      }),
    );
  }

  @override
  void dispose() {
    if (_promptSave?.isActive == true) {
      unawaited(
        widget.settings.setAiOptions(
          widget.settings.aiOptions.copyWith(customPrompt: _prompt.text),
        ),
      );
    }
    _promptSave?.cancel();
    widget.settings.removeListener(_onSettings);
    _prompt.removeListener(_onPromptChanged);
    _prompt.dispose();
    _promptFocus.dispose();
    super.dispose();
  }

  void _onSettings() {
    if (!mounted) return;
    if (!_promptFocus.hasFocus) {
      _copyPromptFromSettings();
    }
    setState(() {});
  }

  void _copyPromptFromSettings() {
    final prompt = widget.settings.aiOptions.customPrompt;
    if (_prompt.text == prompt) return;
    _prompt.removeListener(_onPromptChanged);
    _prompt.text = prompt;
    _prompt.addListener(_onPromptChanged);
  }

  void _onPromptChanged() {
    _promptSave?.cancel();
    _promptSave = Timer(const Duration(milliseconds: 260), () {
      unawaited(
        widget.settings.setAiOptions(
          widget.settings.aiOptions.copyWith(customPrompt: _prompt.text),
        ),
      );
    });
  }

  Future<void> _openApiSettings() async {
    try {
      final store = AiSubtitleApiSettingsStore();
      final current = await store.load();
      if (!mounted) return;
      final result = await showDialog<AiSubtitleApiSettings>(
        context: context,
        builder: (context) => AiSubtitleApiDialog(settings: current),
      );
      if (result != null) {
        await store.save(result);
        widget.settings.notifyApiChanged();
        if (mounted) {
          AppToast.show('已保存翻译接口', type: AppToastType.success);
        }
      }
      await widget.settings.refreshBinding();
    } catch (error) {
      if (mounted) {
        AppToast.show('接口未保存成功：$error', type: AppToastType.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    final theme = Theme.of(context);
    final aiSelected = settings.providerEnZh == SubtitleTranslateProvider.ai;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '翻译设置',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                ModelCenterButton(translateSettings: settings),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '语言设置会按当前翻译接口或模型分别记忆。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            CapsuleDropdownButtonFormField<SubtitleTranslateProvider>(
              key: ValueKey(settings.providerEnZh),
              initialValue: settings.providerEnZh,
              isDense: true,
              decoration: const InputDecoration(
                labelText: '翻译服务',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final entry in subtitleTranslateProviderLabels.entries)
                  DropdownMenuItem(value: entry.key, child: Text(entry.value)),
              ],
              onChanged: (value) {
                if (value == null) return;
                unawaited(settings.setProviderEnZh(value));
              },
            ),
            const SizedBox(height: 12),
            TranslationLanguageControls(settings: settings),
            if (aiSelected) ...[
              const SizedBox(height: 12),
              CapsuleDropdownButtonFormField<int>(
                key: ValueKey('batch-${settings.aiOptions.batchSize}'),
                initialValue: settings.aiOptions.batchSize,
                isDense: true,
                decoration: const InputDecoration(
                  labelText: '每批条数',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final size in AiSubtitleTranslationSettings.batchChoices)
                    DropdownMenuItem(value: size, child: Text('$size 条')),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  unawaited(
                    settings.setAiOptions(
                      settings.aiOptions.copyWith(batchSize: value),
                    ),
                  );
                },
              ),
              const SizedBox(height: 8),
              CapsuleDropdownButtonFormField<int>(
                key: ValueKey('threads-${settings.aiOptions.threadNum}'),
                initialValue: settings.aiOptions.threadNum,
                isDense: true,
                decoration: const InputDecoration(
                  labelText: '并发数',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final count
                      in AiSubtitleTranslationSettings.threadChoices)
                    DropdownMenuItem(value: count, child: Text('$count')),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  unawaited(
                    settings.setAiOptions(
                      settings.aiOptions.copyWith(threadNum: value),
                    ),
                  );
                },
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _prompt,
                focusNode: _promptFocus,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: '提示词',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: DesktopButtonClickRegion(
                  child: TextButton(
                    onPressed: _openApiSettings,
                    child: const Text('管理 AI 接口与模型'),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
