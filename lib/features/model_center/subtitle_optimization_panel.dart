import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/ai_subtitle_api_settings.dart';
import '../../services/subtitle_optimization.dart';
import '../../utils/app_toast.dart';
import '../../widgets/desktop_button_click_region.dart';
import '../../widgets/subtitle_ai_connection_picker.dart';
import '../../widgets/subtitle_optimization_control.dart';
import 'model_center_widgets.dart';

/// Edits the same defaults used by subtitle management and the task queue.
class SubtitleOptimizationPanel extends StatefulWidget {
  const SubtitleOptimizationPanel({super.key});

  @override
  State<SubtitleOptimizationPanel> createState() =>
      _SubtitleOptimizationPanelState();
}

class _SubtitleOptimizationPanelState extends State<SubtitleOptimizationPanel> {
  SubtitleOptimizationSettings _settings = const SubtitleOptimizationSettings();
  AiSubtitleApiSettings? _endpoint;
  String? _error;
  bool _ready = false, _saving = false;
  int _loadVersion = 0;

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
    final version = ++_loadVersion;
    try {
      final settings = await SubtitleOptimizationSettings.load();
      final endpoint = settings.connectionId.isEmpty
          ? await AiSubtitleApiSettingsStore().loadMetadata()
          : await SubtitleAiConnectionStore().endpoint(
              settings.connectionId,
              withKey: false,
            );
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _settings = settings;
        _endpoint = endpoint;
        _ready = true;
        _error = null;
      });
    } catch (error) {
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _error = '优化设置未能读取，点击重试';
        _ready = false;
      });
    }
  }

  Future<void> _save(
    SubtitleOptimizationSettings Function(SubtitleOptimizationSettings) change,
  ) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final latest = await SubtitleOptimizationSettings.load();
      await change(latest).save();
      await _load();
    } catch (error) {
      if (mounted) AppToast.show('优化设置未保存：$error', type: AppToastType.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _chooseModel() => showSubtitleOptimizationSettings(context);

  Future<void> _manageConnections() async {
    final endpoint = await showSubtitleAiConnectionPicker(
      context,
      selectedId: _settings.connectionId,
    );
    if (endpoint != null && mounted) {
      await _save(
        (settings) => settings.copyWith(connectionId: endpoint.connectionId),
      );
    }
  }

  @override
  Widget build(BuildContext context) => ModelCenterPanel(
    title: '字幕优化',
    icon: Icons.auto_fix_high_rounded,
    subtitle: '按批纠错，保留原语言。',
    trailing: Tooltip(
      message: '启用字幕优化',
      child: Switch.adaptive(
        key: const ValueKey('model-center-optimization-toggle'),
        value: _settings.enabled,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        onChanged: _ready && !_saving
            ? (value) => _save((settings) => settings.copyWith(enabled: value))
            : null,
      ),
    ),
    children: [
      if (_error case final error?)
        TextButton(onPressed: _load, child: Text(error)),
      ModelCenterSetting(
        key: const ValueKey('model-center-optimization-model'),
        label: '优化模型',
        value: _endpoint?.ready == true ? _endpoint!.model : '请选择 AI 接口与模型',
        subtitle: _settings.connectionId.isEmpty ? '跟随翻译的 AI 接口' : '独立的 AI 接口',
        onTap: _saving ? null : _chooseModel,
      ),
      const SizedBox(height: 4),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          DesktopButtonClickRegion(
            child: TextButton.icon(
              key: const ValueKey('model-center-optimization-prompt'),
              onPressed: _saving
                  ? null
                  : () => showSubtitleOptimizationSettings(
                      context,
                      showPrompt: true,
                    ),
              icon: const Icon(Icons.edit_note_rounded, size: 18),
              label: const Text('提示词'),
            ),
          ),
          DesktopButtonClickRegion(
            child: TextButton.icon(
              key: const ValueKey('model-center-optimization-connections'),
              onPressed: _saving ? null : _manageConnections,
              icon: const Icon(Icons.hub_outlined, size: 18),
              label: const Text('管理 AI 接口'),
            ),
          ),
        ],
      ),
    ],
  );
}
