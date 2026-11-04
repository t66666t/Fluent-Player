import 'dart:async';
import 'package:flutter/material.dart';
import '../features/model_center/asr_language_options.dart';
import '../features/model_center/model_center_service.dart';
import '../features/model_center/model_center_widgets.dart';
import '../utils/app_toast.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Captures the model before opening: a service change behind the picker must
/// not apply its answer to a different model or a running task.
Future<bool> chooseTranscriptionLanguage(
  BuildContext context,
  ModelCenterService center, {
  bool queueEnhancements = false,
}) async {
  final profile = center.asrProfile;
  final options = center.languageOptionsFor(profile);
  if (!options.editable) return false;
  final result = await showModelCenterPicker<String>(
    context,
    title: '识别语言',
    selected: center.languageForProfile(profile),
    searchable: options.codes.length > 10,
    choices: [
      for (final code in options.codes)
        ModelCenterChoice(
          value: code,
          title: options.label(code),
          group: '',
          detail: code,
          subtitle: code == 'auto'
              ? '${options.description} 选择按模型保存，已开始的任务保持原配置。'
              : '',
        ),
    ],
  );
  if (result == null || !context.mounted) return false;
  await center.selectAsrLanguage(result.value, profile: profile);
  if (queueEnhancements &&
      profile.local &&
      asrLanguagePreferenceKey(profile) ==
          asrLanguagePreferenceKey(center.asrProfile)) {
    final model = center.artifact(profile.model);
    if (model != null) await center.queueAsrEnhancements(model);
  }
  return true;
}

class TranscriptionLanguageSelector extends StatefulWidget {
  const TranscriptionLanguageSelector({
    super.key,
    required this.center,
    this.foregroundColor,
    this.buttonKey = const ValueKey('transcription-language-summary'),
    this.compact = false,
    this.controlHeight = 40,
  });
  final ModelCenterService center;
  final Color? foregroundColor;
  final Key buttonKey;
  final bool compact;
  final double controlHeight;
  @override
  State<TranscriptionLanguageSelector> createState() =>
      _TranscriptionLanguageSelectorState();
}

class _TranscriptionLanguageSelectorState
    extends State<TranscriptionLanguageSelector> {
  bool _ready = false, _saving = false;
  Object? _error;
  @override
  void initState() {
    super.initState();
    _ready = widget.center.loaded;
    if (!_ready) unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant TranscriptionLanguageSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.center, widget.center)) {
      _ready = widget.center.loaded;
      _error = null;
      if (!_ready) unawaited(_load());
    }
  }

  Future<void> _load() async {
    final center = widget.center;
    try {
      await center.initialize();
      if (mounted && identical(center, widget.center)) {
        setState(() {
          _ready = true;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted && identical(center, widget.center)) {
        setState(() => _error = error);
      }
    }
  }

  Future<void> _choose() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await chooseTranscriptionLanguage(context, widget.center);
    } catch (error) {
      if (mounted) AppToast.show('语言设置未保存：$error', type: AppToastType.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.center,
    builder: (context, _) {
      final options = widget.center.currentAsrLanguageOptions;
      final label = options.label(widget.center.effectiveAsrLanguage);
      return Tooltip(
        message: _error != null
            ? '语言设置读取失败：$_error'
            : '${options.description}\n选择按模型保存；已开始的任务保持原语言。',
        child: DesktopButtonClickRegion(
          child: TextButton(
            key: widget.buttonKey,
            onPressed: _error != null
                ? _load
                : _ready && options.editable && !_saving
                ? _choose
                : null,
            style: TextButton.styleFrom(
              foregroundColor: widget.foregroundColor,
              disabledForegroundColor: widget.foregroundColor?.withValues(
                alpha: .7,
              ),
              minimumSize: Size(0, widget.controlHeight),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: EdgeInsets.symmetric(
                horizontal: 8,
                vertical: widget.compact ? 0 : 6,
              ),
              shape: widget.compact
                  ? RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: BorderSide(
                        color: Theme.of(
                          context,
                        ).colorScheme.outlineVariant.withValues(alpha: .65),
                      ),
                    )
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.language_rounded, size: 15),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    _error != null
                        ? (widget.compact ? '点击重试' : '识别语言：点击重试')
                        : widget.compact
                        ? label
                        : '识别语言：$label',
                    maxLines: widget.compact ? 1 : 2,
                    softWrap: !widget.compact,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: widget.compact ? 1.25 : null,
                    ),
                  ),
                ),
                if (_ready && options.editable) ...[
                  const SizedBox(width: 3),
                  const Icon(Icons.expand_more_rounded, size: 16),
                ],
              ],
            ),
          ),
        ),
      );
    },
  );
}
