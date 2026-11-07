import 'dart:async';

import 'package:flutter/material.dart';

import '../features/model_center/model_catalog.dart';
import '../features/model_center/model_adapters.dart';
import '../features/model_center/model_center_service.dart';
import '../features/model_center/model_center_widgets.dart';
import '../services/subtitle_translate_settings.dart';
import '../features/model_center/asr_language_options.dart';
import 'transcription_language_selector.dart';
import '../services/transcription_hotword_store.dart';
import '../utils/app_toast.dart';
import 'model_center_button.dart';
import 'subtitle_settings_layout.dart';
import 'transcript_translate_settings_sheet.dart';
import 'transcription_hotword_editor.dart';
import 'subtitle_optimization_control.dart';
import 'subtitle_processing_stage.dart';
import 'subtitle_translation_model_sheet.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// One compact group for the settings used by the next subtitle generation.
/// The word editor receives a captured media key, even if playback changes.
class AiTranscriptionConfiguration extends StatefulWidget {
  const AiTranscriptionConfiguration({
    super.key,
    required this.center,
    required this.hotwords,
    required this.mediaKey,
    required this.mediaTitle,
    this.translation,
    this.translationEnabled = false,
    this.onTranslationChanged,
    this.backgroundPreview,
  });
  final ModelCenterService center;
  final TranscriptionHotwordStore hotwords;
  final String mediaKey, mediaTitle;
  final SubtitleTranslateSettings? translation;
  final bool translationEnabled;
  final ValueChanged<bool>? onTranslationChanged;
  final Future<String> Function()? backgroundPreview;
  @override
  State<AiTranscriptionConfiguration> createState() =>
      _AiTranscriptionConfigurationState();
}

class _AiTranscriptionConfigurationState
    extends State<AiTranscriptionConfiguration> {
  bool _ready = false;
  bool _translationOptionsExpanded = false;
  SubtitleTranslateSettings? _fallbackTranslation;
  SubtitleTranslateSettings get _translation =>
      widget.translation ??
      (_fallbackTranslation ??= SubtitleTranslateSettings());
  String? _error, _wordsError;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
    unawaited(_act(() => _translation.ensureLoaded()));
  }

  @override
  void didUpdateWidget(covariant AiTranscriptionConfiguration oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.center != widget.center ||
        oldWidget.hotwords != widget.hotwords) {
      _ready = false;
      unawaited(_load());
    }
    if (oldWidget.translation != widget.translation) {
      unawaited(_act(() => _translation.ensureLoaded()));
    }
  }

  @override
  void dispose() {
    _fallbackTranslation?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final center = widget.center;
    try {
      await center.initialize();
      if (!mounted || center != widget.center) return;
      setState(() {
        _ready = true;
        _error = null;
      });
    } catch (error) {
      if (mounted && center == widget.center) {
        setState(() => _error = '转录设置读取失败：$error');
      }
    }
    await _loadWords();
  }

  Future<void> _loadWords() async {
    final store = widget.hotwords;
    try {
      await store.load();
      await store.preserveLegacyWords(widget.center.asrEnhancements.hotwords);
      if (mounted && store == widget.hotwords) {
        setState(() => _wordsError = null);
      }
    } catch (error) {
      if (mounted && store == widget.hotwords) {
        setState(() => _wordsError = '$error');
      }
    }
  }

  String _language(String code) => asrLanguageLabel(code);
  String _kind(ModelServiceProfile profile) => switch (profile.kind) {
    TranscriptionServiceKind.local => '本地模型',
    TranscriptionServiceKind.gongyi => '公益接口',
    TranscriptionServiceKind.openai => '转录接口',
    TranscriptionServiceKind.tencent => '腾讯云接口',
    TranscriptionServiceKind.aliyun => '阿里云百炼接口',
    TranscriptionServiceKind.volcengine => '火山引擎接口',
    TranscriptionServiceKind.elevenlabs ||
    TranscriptionServiceKind.soniox ||
    TranscriptionServiceKind.assemblyai ||
    TranscriptionServiceKind.deepgram ||
    TranscriptionServiceKind.gemini => '云端转录',
  };

  Future<void> _act(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (mounted) AppToast.show('设置未保存：$error', type: AppToastType.error);
    }
  }

  Future<void> _chooseService() async {
    final center = widget.center;
    final models = {
      for (final model in center.catalog)
        if (model.purpose == ModelPurpose.transcription)
          'local:${model.id}': model,
    };
    final result = await showModelCenterPicker<String>(
      context,
      title: '转录方式',
      selected: center.asrProfileId,
      choices: [
        for (final profile in center.profiles.values.where((p) => !p.local))
          ModelCenterChoice(
            value: profile.id,
            title: profile.name,
            group: _kind(profile),
            detail: profile.model,
          ),
        for (final entry in models.entries)
          ModelCenterChoice(
            value: entry.key,
            title: entry.value.name,
            group: '本地模型',
            subtitle: center.installed(entry.value.id)
                ? '已安装'
                : '尚未安装 · 可在模型中心下载',
            detail: entry.value.languages.map(_language).join('、'),
          ),
      ],
    );
    if (result == null || !mounted) return;
    await _act(() async {
      final model = models[result.value];
      if (model != null) {
        // Binding alone must not silently start multi-GB enhancement downloads.
        final profile = ModelServiceProfile(
          id: result.value,
          name: model.name,
          kind: TranscriptionServiceKind.local,
          model: model.id,
        );
        await center.saveProfile(profile);
      }
      center.asrProfileId = result.value;
      await center.settingsChanged();
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([widget.center, widget.hotwords, _translation]),
    builder: (context, _) {
      final center = widget.center, profile = center.asrProfile;
      final model = profile.local ? center.artifact(profile.model) : null;
      final supportsWords =
          localAsrAdapters[model?.engine]?.supportsHotwords == true;
      final words = widget.hotwords.wordsFor(widget.mediaKey);
      final count = words.isEmpty ? 0 : words.split('\n').length;
      final identity = profile.local
          ? model?.name ?? profile.name
          : '${profile.name}${profile.model.isEmpty ? '' : ' · ${profile.model}'}';
      return SubtitleSettingsTheme(
        child: Column(
          key: const ValueKey('ai-transcription-configuration'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SubtitleSettingsGroup(
              key: const ValueKey('ai-subtitle-methods'),
              padding: EdgeInsets.zero,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ModelCenterButton(
                    key: const ValueKey('transcription-model-settings'),
                    settingsRow: true,
                    transcriptionOnly: true,
                    service: center,
                    translateSettings: _translation,
                  ),
                  const Divider(),
                  SubtitleSettingsRow(
                    key: const ValueKey('transcription-method-summary'),
                    title: '转录方式',
                    description: _ready
                        ? '${_kind(profile)} · $identity${model != null && !center.installed(model.id) ? ' · 未安装' : ''}'
                        : '正在读取设置…',
                    onTap: _ready ? _chooseService : null,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 2,
                      children: [
                        TranscriptionLanguageSelector(
                          center: center,
                          foregroundColor: SubtitleSettingsTheme.foreground,
                        ),
                        if (_ready && supportsWords)
                          DesktopButtonClickRegion(
                            child: TextButton(
                              key: const ValueKey('video-hotwords-button'),
                              onPressed: widget.hotwords.loaded
                                  ? () => showTranscriptionHotwords(
                                      context,
                                      store: widget.hotwords,
                                      mediaKey: widget.mediaKey,
                                      mediaTitle: widget.mediaTitle,
                                      enhancementsEnabled:
                                          center.asrEnhancements.enabled,
                                    )
                                  : _loadWords,
                              child: Text(
                                count == 0 ? '热词 / 预设' : '热词 · $count 条',
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (_error != null)
                    TextButton(onPressed: _load, child: Text('$_error · 重试')),
                  if (_wordsError != null && supportsWords)
                    TextButton(
                      onPressed: _loadWords,
                      child: const Text('热词未能读取，点击重试'),
                    ),
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SubtitleOptimizationControl(
                          // Share the row layout, keeping transcription's preference.
                          filePanel: true,
                          backgroundPreview: widget.backgroundPreview,
                        ),
                        const Divider(
                          height: 16,
                          color: SubtitleSettingsTheme.divider,
                        ),
                        SubtitleProcessingStage(
                          title: '翻译字幕',
                          summary: _translation.summary,
                          value: widget.translationEnabled,
                          onChanged: widget.onTranslationChanged,
                          onModel: () => showSubtitleTranslationModelSettings(
                            context,
                            settings: _translation,
                            center: widget.center,
                          ),
                          modelKey: const ValueKey(
                            'ai-transcription-translation-model',
                          ),
                          onConfigure: () => setState(
                            () => _translationOptionsExpanded =
                                !_translationOptionsExpanded,
                          ),
                          expanded: _translationOptionsExpanded,
                          toggleKey: const ValueKey(
                            'ai-transcription-translation-toggle',
                          ),
                          settingsKey: const ValueKey(
                            'ai-transcription-translation-settings',
                          ),
                          expansionKey: const ValueKey(
                            'ai-transcription-translation-expand',
                          ),
                        ),
                        if (_translationOptionsExpanded)
                          Padding(
                            key: const ValueKey(
                              'ai-transcription-translation-options',
                            ),
                            padding: const EdgeInsets.only(top: 12, bottom: 6),
                            child: TranscriptTranslateSettingsSheet(
                              key: ObjectKey(_translation),
                              settings: _translation,
                              embedded: true,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}
