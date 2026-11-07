import 'dart:async';
import 'package:flutter/material.dart';
import '../services/ai_subtitle_api_settings.dart';
import '../services/subtitle_optimization.dart';
import '../utils/app_toast.dart';
import 'capsule_selector.dart';
import 'desktop_button_click_region.dart';
import 'keyboard_inset_padding.dart';
import 'ai_subtitle_api_dialog.dart';
import 'package:uuid/uuid.dart';
import 'subtitle_settings_layout.dart';
import 'subtitle_processing_stage.dart';

Future<void> showSubtitleOptimizationSettings(
  BuildContext context, {
  Future<String> Function()? backgroundPreview,
  bool showPrompt = false,
}) async {
  try {
    final settings = await SubtitleOptimizationSettings.load();
    if (!context.mounted) return;
    final result = await showModalBottomSheet<SubtitleOptimizationSettings>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      backgroundColor: SubtitleSettingsTheme.background,
      builder: (_) => KeyboardInsetPadding(
        child: Align(
          alignment: Alignment.bottomCenter,
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: _OptimizationEditor(
              settings: settings,
              backgroundPreview: backgroundPreview,
              showPrompt: showPrompt,
            ),
          ),
        ),
      ),
    );
    if (result != null) await result.save();
  } catch (error) {
    if (context.mounted) {
      AppToast.show('优化设置未保存：$error', type: AppToastType.error);
    }
  }
}

/// Shared settings and switches for the player, file manager and queue.
class SubtitleOptimizationControl extends StatefulWidget {
  const SubtitleOptimizationControl({
    super.key,
    this.foregroundColor,
    this.enabled = true,
    this.backgroundPreview,
    this.compact = false,
    this.value,
    this.onChanged,
    this.filePanel = false,
  });
  final Color? foregroundColor;
  final bool enabled;
  final Future<String> Function()? backgroundPreview;
  final bool compact;

  /// File processing owns its enabled preference; model and prompt stay shared.
  final bool? value;
  final Future<void> Function(bool)? onChanged;
  final bool filePanel;
  @override
  State<SubtitleOptimizationControl> createState() =>
      _SubtitleOptimizationControlState();
}

class _SubtitleOptimizationControlState
    extends State<SubtitleOptimizationControl> {
  SubtitleOptimizationSettings settings = const SubtitleOptimizationSettings();
  String summary = '跟随翻译的 AI 接口';
  bool ready = false, saving = false;
  int _loadEpoch = 0;
  @override
  void initState() {
    super.initState();
    SubtitleOptimizationSettings.changes.addListener(_changed);
    AiSubtitleApiSettingsStore.changes.addListener(_changed);
    _changed();
  }

  @override
  void dispose() {
    SubtitleOptimizationSettings.changes.removeListener(_changed);
    AiSubtitleApiSettingsStore.changes.removeListener(_changed);
    super.dispose();
  }

  void _changed() => unawaited(_load());

  Future<void> _load() async {
    final epoch = ++_loadEpoch;
    try {
      final value = await SubtitleOptimizationSettings.load();
      final endpoint = value.connectionId.isEmpty
          ? await AiSubtitleApiSettingsStore().loadMetadata()
          : await SubtitleAiConnectionStore().endpoint(
              value.connectionId,
              withKey: false,
            );
      if (mounted && epoch == _loadEpoch) {
        setState(() {
          settings = value;
          ready = true;
          summary = endpoint.ready
              ? '${value.connectionId.isEmpty ? '跟随翻译 · ' : ''}${endpoint.model}'
              : '请选择 AI 接口与模型';
        });
      }
    } catch (_) {
      if (mounted && epoch == _loadEpoch) {
        setState(() {
          ready = true;
          summary = '接口需要重新配置';
        });
      }
    }
  }

  Future<void> _save(bool enabled) async {
    if (saving) return;
    setState(() => saving = true);
    try {
      if (widget.onChanged case final onChanged?) {
        await onChanged(enabled);
      } else {
        await settings.copyWith(enabled: enabled).save();
      }
    } catch (error) {
      if (mounted) AppToast.show('优化设置未保存：$error', type: AppToastType.error);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _configure({bool showPrompt = false}) =>
      showSubtitleOptimizationSettings(
        context,
        backgroundPreview: widget.backgroundPreview,
        showPrompt: showPrompt,
      );

  @override
  Widget build(BuildContext context) {
    final active = widget.enabled && ready && !saving;
    final selected = widget.value ?? settings.enabled;
    if (widget.filePanel) {
      return SubtitleSettingsTheme(
        child: SubtitleProcessingStage(
          title: '优化字幕',
          summary: selected ? summary : '校对原文，保留时间轴',
          value: selected,
          onChanged: active ? _save : null,
          onConfigure: active ? _configure : null,
          configureLabel: '模型',
          onEditPrompt: active ? () => _configure(showPrompt: true) : null,
          promptKey: const ValueKey('subtitle-optimization-prompt-button'),
          toggleKey: const ValueKey('subtitle-optimization-toggle'),
          settingsKey: const ValueKey('subtitle-optimization-settings'),
        ),
      );
    }
    final toggle = Switch.adaptive(
      key: const ValueKey('subtitle-optimization-toggle'),
      value: selected,
      onChanged: active ? _save : null,
    );
    final settingsButton = DesktopButtonClickRegion(
      child: TextButton(
        key: const ValueKey('subtitle-optimization-settings'),
        onPressed: active ? _configure : null,
        child: widget.compact
            ? LayoutBuilder(
                builder: (context, constraints) {
                  final painter = TextPainter(
                    text: TextSpan(
                      text: '优化设置',
                      style: DefaultTextStyle.of(context).style,
                    ),
                    textDirection: Directionality.of(context),
                    textScaler: MediaQuery.textScalerOf(context),
                  )..layout();
                  final fits = painter.width <= constraints.maxWidth;
                  painter.dispose();
                  return Text(
                    fits ? '优化设置' : '优化',
                    maxLines: 1,
                    softWrap: false,
                  );
                },
              )
            : const Text('设置'),
      ),
    );
    return SubtitleSettingsTheme(
      child: widget.compact
          ? Row(
              key: const ValueKey('subtitle-optimization-control'),
              children: [
                SizedBox(
                  width: 44,
                  child: Transform.scale(scale: .82, child: toggle),
                ),
                Expanded(child: settingsButton),
              ],
            )
          : SubtitleSettingsRow(
              key: const ValueKey('subtitle-optimization-control'),
              title: '优化字幕',
              titleKey: const ValueKey('subtitle-optimization-prompt-button'),
              description: settings.enabled ? summary : null,
              onTap: active ? () => _configure(showPrompt: true) : null,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  settingsButton,
                  SizedBox(width: 48, child: toggle),
                ],
              ),
            ),
    );
  }
}

class _OptimizationEditor extends StatefulWidget {
  const _OptimizationEditor({
    required this.settings,
    this.backgroundPreview,
    this.showPrompt = false,
  });
  final SubtitleOptimizationSettings settings;
  final Future<String> Function()? backgroundPreview;
  final bool showPrompt;
  @override
  State<_OptimizationEditor> createState() => _OptimizationEditorState();
}

class _OptimizationEditorState extends State<_OptimizationEditor> {
  late final TextEditingController prompt;
  late String connectionId;
  List<SubtitleAiConnection> entries = [];
  AiSubtitleApiSettings? endpoint;
  String inheritedModel = '尚未配置', background = '';
  String? error;
  bool loading = true, saving = false;
  int _loadEpoch = 0;

  @override
  void initState() {
    super.initState();
    prompt = TextEditingController(text: widget.settings.prompt);
    connectionId = widget.settings.connectionId;
    if (widget.showPrompt) {
      loading = false;
      unawaited(_loadBackground());
    } else {
      unawaited(_load());
    }
  }

  Future<void> _loadBackground() async {
    try {
      final preview = await widget.backgroundPreview?.call() ?? '';
      if (mounted) {
        setState(
          () => background = subtitleOptimizationBackgroundPreview(preview),
        );
      }
    } catch (_) {
      /* Optional background must not prevent prompt editing. */
    }
  }

  Future<void> _load() async {
    try {
      final connections = await SubtitleAiConnectionStore().load();
      final inherited = await AiSubtitleApiSettingsStore().loadMetadata();
      if (!mounted) return;
      setState(() {
        entries = connections;
        inheritedModel = inherited.ready ? inherited.model : '尚未配置';
      });
      await _selectEndpoint(connectionId);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '接口未读取：$e';
          loading = false;
        });
      }
    }
  }

  Future<void> _selectEndpoint(String id) async {
    final epoch = ++_loadEpoch;
    setState(() {
      connectionId = id;
      loading = true;
      error = null;
      endpoint = null;
    });
    try {
      final value = id.isEmpty
          ? await AiSubtitleApiSettingsStore().load()
          : await SubtitleAiConnectionStore().endpoint(id);
      if (mounted && epoch == _loadEpoch) {
        setState(() {
          endpoint = value;
          loading = false;
        });
      }
    } catch (e) {
      if (mounted && epoch == _loadEpoch) {
        setState(() {
          error = '接口未读取：$e';
          loading = false;
        });
      }
    }
  }

  Future<void> _saveModel(AiSubtitleApiSettings value) async {
    if (saving) return;
    setState(() => saving = true);
    try {
      final previous = endpoint!.normalized();
      final same =
          value.baseUrl == previous.baseUrl &&
          value.apiKey == previous.apiKey &&
          value.model == previous.model &&
          value.models.length == previous.models.length &&
          value.models.indexed.every(
            (entry) => entry.$2 == previous.models[entry.$1],
          );
      var id = connectionId;
      if (!same) {
        // Keep the shared translation connection and captured jobs intact.
        id = const Uuid().v4();
        final saved = value.copyWith(connectionId: id, profiles: const {});
        await SubtitleAiConnectionStore().save(
          SubtitleAiConnection(
            id,
            '${saved.model} · ${Uri.tryParse(saved.baseUrl)?.host ?? ''}',
            saved,
          ),
          previousEndpoint: previous,
        );
      }
      if (mounted) {
        Navigator.pop(context, widget.settings.copyWith(connectionId: id));
      }
    } catch (e) {
      if (mounted) setState(() => error = '接口未保存：$e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  void dispose() {
    prompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final short = constraints.maxHeight < 240;
      final title = widget.showPrompt ? '优化提示词' : '优化模型';
      void savePrompt() =>
          Navigator.pop(context, widget.settings.copyWith(prompt: prompt.text));
      return SubtitleSettingsTheme(
        child: SafeArea(
          child: Material(
            color: SubtitleSettingsTheme.background,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            color: SubtitleSettingsTheme.foreground,
                          ),
                        ),
                      ),
                      if (short && widget.showPrompt)
                        TextButton(
                          onPressed: savePrompt,
                          child: const Text('保存'),
                        ),
                      IconButton(
                        tooltip: '关闭优化设置',
                        onPressed: saving ? null : () => Navigator.pop(context),
                        icon: const Icon(Icons.close_rounded, size: 20),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    key: const ValueKey('subtitle-optimization-scroll'),
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (!widget.showPrompt) ...[
                          SubtitleSettingsGroup(
                            title: '使用的接口',
                            child: CapsuleDropdownButtonFormField<String>(
                              useInputTheme: true,
                              key: ValueKey('optimization-model-$connectionId'),
                              initialValue:
                                  connectionId.isEmpty ||
                                      entries.any((e) => e.id == connectionId)
                                  ? connectionId
                                  : null,
                              isExpanded: true,
                              isDense: true,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                              ),
                              items: [
                                DropdownMenuItem(
                                  value: '',
                                  child: Text(
                                    '跟随翻译的 AI 接口 · $inheritedModel',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                for (final entry in entries)
                                  DropdownMenuItem(
                                    value: entry.id,
                                    child: Text(
                                      entry.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: loading || saving
                                  ? null
                                  : (id) {
                                      if (id != null) {
                                        unawaited(_selectEndpoint(id));
                                      }
                                    },
                            ),
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            '模型和提示词可独立选择；相同接口的密钥与 AI 对话、翻译共用。翻译还没单独选过接口时，会先用这里保存的模型。',
                            style: SubtitleSettingsTheme.description,
                          ),
                          const SizedBox(height: 10),
                          if (loading || saving)
                            const LinearProgressIndicator(),
                          if (endpoint case final value?)
                            AbsorbPointer(
                              absorbing: saving,
                              child: AiSubtitleApiEditor(
                                key: ValueKey('optimization-api-$connectionId'),
                                settings: value,
                                title: '接口配置',
                                saveLabel: '保存并使用',
                                onSaved: _saveModel,
                              ),
                            ),
                          if (error != null)
                            TextButton(
                              onPressed: _load,
                              child: Text('$error · 重试'),
                            ),
                        ] else ...[
                          SubtitleSettingsGroup(
                            title: '校对要求',
                            action: TextButton(
                              onPressed: () => prompt.text =
                                  defaultSubtitleOptimizationPrompt,
                              child: const Text('恢复默认'),
                            ),
                            child: TextField(
                              key: const ValueKey(
                                'subtitle-optimization-prompt',
                              ),
                              controller: prompt,
                              minLines: 6,
                              maxLines: null,
                              maxLength: 3000,
                              style: SubtitleSettingsTheme.title.copyWith(
                                fontWeight: FontWeight.w400,
                              ),
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                alignLabelWithHint: true,
                                helperText: '可自由编辑；保留原语言、条数和编号，输出格式由程序校验。',
                                helperMaxLines: 3,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          SubtitleSettingsGroup(
                            title: '自动背景',
                            child: SelectableText(
                              background.isEmpty
                                  ? '每个任务自动使用已有标题、简短简介和标签。缺失时跳过，不额外联网或调用 AI 摘要。'
                                  : background,
                              style: SubtitleSettingsTheme.description,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (widget.showPrompt && !short) ...[
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 44),
                        ),
                        onPressed: savePrompt,
                        child: const Text('保存'),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    },
  );
}
