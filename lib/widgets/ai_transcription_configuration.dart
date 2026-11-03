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
import 'transcript_translate_settings_sheet.dart';
import 'transcription_hotword_editor.dart';
import 'translation_language_controls.dart';
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
  });
  final ModelCenterService center;
  final TranscriptionHotwordStore hotwords;
  final String mediaKey, mediaTitle;
  final SubtitleTranslateSettings? translation;
  @override
  State<AiTranscriptionConfiguration> createState() =>
      _AiTranscriptionConfigurationState();
}

class _AiTranscriptionConfigurationState
    extends State<AiTranscriptionConfiguration> {
  bool _ready = false;
  String? _error, _wordsError;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant AiTranscriptionConfiguration oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.center != widget.center ||
        oldWidget.hotwords != widget.hotwords) {
      _ready = false;
      unawaited(_load());
    }
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
    animation: Listenable.merge([widget.center, widget.hotwords]),
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
      const foreground = Colors.white;
      return Column(
        key: const ValueKey('ai-transcription-configuration'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: ModelCenterButton(
              foregroundColor: Colors.lightBlueAccent,
              service: center,
              translateSettings: widget.translation,
            ),
          ),
          Container(
            key: const ValueKey('ai-subtitle-methods'),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .035),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DesktopButtonClickRegion(
                  child: TextButton(
                    key: const ValueKey('transcription-method-summary'),
                    onPressed: _ready ? _chooseService : null,
                    style: TextButton.styleFrom(
                      foregroundColor: foreground,
                      alignment: Alignment.centerLeft,
                      minimumSize: const Size(0, 44),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.record_voice_over_outlined, size: 17),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '转录方式',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                _ready
                                    ? '${_kind(profile)} · $identity${model != null && !center.installed(model.id) ? ' · 未安装' : ''}'
                                    : '正在读取设置…',
                                key: const ValueKey(
                                  'transcription-current-method',
                                ),
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.white70,
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
                Padding(
                  padding: const EdgeInsets.only(left: 25),
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 2,
                    children: [
                      TranscriptionLanguageSelector(
                        center: center,
                        foregroundColor: foreground,
                      ),
                      if (_ready && supportsWords)
                        DesktopButtonClickRegion(
                          child: TextButton.icon(
                            key: const ValueKey('video-hotwords-button'),
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.lightBlueAccent,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                            ),
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
                            icon: const Icon(
                              Icons.text_fields_rounded,
                              size: 15,
                            ),
                            label: Text(
                              count == 0 ? '热词 / 预设' : '热词 · $count 条',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (_error != null)
                  DesktopButtonClickRegion(
                    child: TextButton(
                      onPressed: _load,
                      child: Text('$_error · 重试'),
                    ),
                  ),
                if (_wordsError != null && supportsWords)
                  DesktopButtonClickRegion(
                    child: TextButton(
                      onPressed: _loadWords,
                      child: const Text('热词未能读取，点击重试'),
                    ),
                  ),
                const Divider(
                  height: 9,
                  indent: 8,
                  endIndent: 8,
                  color: Colors.white12,
                ),
                TranslationDirectionSummary(
                  settings: widget.translation,
                  label: '翻译方式',
                  maxLines: 3,
                  foregroundColor: foreground,
                  onOpen: (settings) => showTranscriptTranslateSettings(
                    context,
                    settings: settings,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
}
