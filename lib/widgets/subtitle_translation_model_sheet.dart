import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../features/model_center/model_catalog.dart';
import '../features/model_center/model_center_service.dart';
import '../services/ai_subtitle_api_settings.dart';
import '../services/subtitle_translate_settings.dart';
import '../services/subtitle_translation_service.dart';
import '../utils/app_toast.dart';
import 'ai_subtitle_api_dialog.dart';
import 'capsule_selector.dart';
import 'keyboard_inset_padding.dart';
import 'subtitle_settings_layout.dart';

/// Opens the translation model choices shared by subtitle processing.
///
/// Optimization only edits an AI connection. Translation can also stay on Bing
/// or switch to a local model, so this sheet keeps those choices together.
Future<void> showSubtitleTranslationModelSettings(
  BuildContext context, {
  SubtitleTranslateSettings? settings,
  ModelCenterService? center,
}) async {
  final shared =
      settings ?? lookupSubtitleTranslateSettings(context, listen: false);
  final selected = shared ?? SubtitleTranslateSettings();
  final models = center ?? ModelCenterService.instance;
  try {
    await selected.ensureLoaded();
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
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
            child: _TranslationModelSheet(settings: selected, center: models),
          ),
        ),
      ),
    );
  } catch (error) {
    if (context.mounted) {
      AppToast.show('翻译模型未打开：$error', type: AppToastType.error);
    }
  } finally {
    if (shared == null) selected.dispose();
  }
}

/// Points translation at one saved connection without copying its key into
/// preferences. The connection store remains the credential source.
Future<void> useTranslationAiConnection(
  SubtitleTranslateSettings settings,
  String connectionId,
) async {
  if (connectionId.isNotEmpty) {
    final endpoint = await SubtitleAiConnectionStore().endpoint(connectionId);
    await AiSubtitleApiSettingsStore().save(
      endpoint.copyWith(profiles: const {}),
    );
  }
  await settings.setProviderEnZh(SubtitleTranslateProvider.ai);
}

Future<void> useLocalTranslationModel(
  SubtitleTranslateSettings settings,
  ModelCenterService center,
  String modelId,
) async {
  if (modelId.isEmpty) throw StateError('请选择本地翻译模型');
  center.translationModelId = modelId;
  await center.settingsChanged();
  await settings.setProviderEnZh(SubtitleTranslateProvider.local);
}

/// Local models shown once translation is set to the on-device provider.
class LocalTranslationModelField extends StatefulWidget {
  const LocalTranslationModelField({
    super.key,
    required this.settings,
    this.center,
    this.enabled = true,
    this.dark = false,
  });

  final SubtitleTranslateSettings settings;
  final ModelCenterService? center;
  final bool enabled;
  final bool dark;

  @override
  State<LocalTranslationModelField> createState() =>
      _LocalTranslationModelFieldState();
}

class _LocalTranslationModelFieldState
    extends State<LocalTranslationModelField> {
  ModelCenterService get _center =>
      widget.center ?? ModelCenterService.instance;
  ModelCenterService? _listened;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _listen(_center);
    if (!_center.loaded) unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant LocalTranslationModelField oldWidget) {
    super.didUpdateWidget(oldWidget);
    _listen(_center);
    if (!_center.loaded) unawaited(_load());
  }

  void _listen(ModelCenterService center) {
    if (identical(_listened, center)) return;
    _listened?.removeListener(_changed);
    _listened = center;
    center.addListener(_changed);
  }

  @override
  void dispose() {
    _listened?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _center.initialize();
      if (mounted) setState(() => _loading = false);
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '本地模型未读取';
        });
      }
    }
  }

  List<ModelArtifact> get _models => [
    for (final model in _center.catalog)
      if (model.purpose == ModelPurpose.translation && !model.retired) model,
  ];

  Future<void> _select(String? id) async {
    if (id == null || !widget.enabled) return;
    try {
      await useLocalTranslationModel(widget.settings, _center, id);
    } catch (error) {
      if (mounted) AppToast.show('本地模型未切换：$error', type: AppToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return TextButton(onPressed: _load, child: Text('$_error · 重试'));
    }
    if (_loading && _models.isEmpty) return const LinearProgressIndicator();
    final models = _models;
    final selected =
        models.any((model) => model.id == _center.translationModelId)
        ? _center.translationModelId
        : null;
    return CapsuleDropdownButtonFormField<String>(
      key: ValueKey('local-translation-model-$selected'),
      useInputTheme: !widget.dark,
      initialValue: selected,
      isExpanded: true,
      isDense: true,
      decoration: InputDecoration(
        labelText: '本地翻译模型',
        isDense: widget.dark,
        border: const OutlineInputBorder(),
      ),
      dropdownColor: widget.dark ? const Color(0xFF2A2A2A) : null,
      style: widget.dark
          ? const TextStyle(color: Colors.white, fontSize: 12)
          : null,
      items: [
        for (final model in models)
          DropdownMenuItem(
            value: model.id,
            child: Text(
              _center.installed(model.id) ? model.name : '${model.name} · 未安装',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: widget.dark ? const TextStyle(fontSize: 12) : null,
            ),
          ),
      ],
      onChanged: widget.enabled ? _select : null,
    );
  }
}

class _TranslationModelSheet extends StatefulWidget {
  const _TranslationModelSheet({required this.settings, required this.center});

  final SubtitleTranslateSettings settings;
  final ModelCenterService center;

  @override
  State<_TranslationModelSheet> createState() => _TranslationModelSheetState();
}

class _TranslationModelSheetState extends State<_TranslationModelSheet> {
  List<SubtitleAiConnection> _connections = const [];
  AiSubtitleApiSettings? _endpoint;
  String _selection = 'bing';
  String? _error;
  bool _loading = true, _saving = false;
  int _endpointEpoch = 0;

  @override
  void initState() {
    super.initState();
    widget.settings.addListener(_onSettings);
    unawaited(_load());
  }

  @override
  void dispose() {
    widget.settings.removeListener(_onSettings);
    super.dispose();
  }

  void _onSettings() {
    if (mounted) setState(() {});
  }

  String _selectionFor(SubtitleTranslateSettings settings) {
    return switch (settings.providerEnZh) {
      SubtitleTranslateProvider.bing => 'bing',
      SubtitleTranslateProvider.local =>
        'local:${widget.center.translationModelId}',
      SubtitleTranslateProvider.ai =>
        'ai:${settings.binding.api?.connectionId ?? ''}',
    };
  }

  Future<void> _load() async {
    try {
      if (!widget.center.loaded) await widget.center.initialize();
      final connections = await SubtitleAiConnectionStore().load();
      if (!mounted) return;
      setState(() {
        _connections = connections;
        _selection = _selectionFor(widget.settings);
        _error = null;
      });
      if (_selection.startsWith('ai:')) {
        await _showEndpoint(_selection.substring(3));
      } else if (mounted) {
        setState(() => _loading = false);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '翻译模型未读取：$error';
          _loading = false;
        });
      }
    }
  }

  Future<void> _showEndpoint(String id) async {
    final epoch = ++_endpointEpoch;
    setState(() {
      _loading = true;
      _error = null;
      _endpoint = null;
    });
    try {
      // Metadata avoids writing a chat seed just because the sheet opened.
      final value = id.isEmpty
          ? await AiSubtitleApiSettingsStore().loadMetadata()
          : await SubtitleAiConnectionStore().endpoint(id);
      if (mounted && epoch == _endpointEpoch) {
        setState(() {
          _endpoint = value;
          _loading = false;
        });
      }
    } catch (error) {
      if (mounted && epoch == _endpointEpoch) {
        setState(() {
          _error = '接口未读取：$error';
          _loading = false;
        });
      }
    }
  }

  Future<void> _choose(String? value) async {
    if (value == null || _saving) return;
    setState(() => _selection = value);
    try {
      if (value == 'bing') {
        await widget.settings.setProviderEnZh(SubtitleTranslateProvider.bing);
        return;
      }
      if (value.startsWith('local:')) {
        await useLocalTranslationModel(
          widget.settings,
          widget.center,
          value.substring(6),
        );
        return;
      }
      final id = value.substring(3);
      if (id.isNotEmpty) {
        // Picking an existing connection is the manual translation choice.
        // Further edits stay local until「保存并使用」.
        await useTranslationAiConnection(widget.settings, id);
      }
      await _showEndpoint(id);
    } catch (error) {
      if (mounted) {
        setState(() => _error = '翻译方式未切换：$error');
      }
    }
  }

  Future<void> _saveEndpoint(AiSubtitleApiSettings value) async {
    if (_saving || _endpoint == null) return;
    setState(() => _saving = true);
    try {
      final previous = _endpoint!.normalized();
      final same =
          value.baseUrl == previous.baseUrl &&
          value.apiKey == previous.apiKey &&
          value.model == previous.model &&
          value.models.length == previous.models.length &&
          value.models.indexed.every(
            (entry) => entry.$2 == previous.models[entry.$1],
          );
      var id = _selection.startsWith('ai:') ? _selection.substring(3) : '';
      if (!same || id.isEmpty) {
        // A changed form becomes its own connection, so optimization and any
        // running job keep the endpoint they already captured.
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
      await useTranslationAiConnection(widget.settings, id);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = '接口未保存：$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final localModels = [
      for (final model in widget.center.catalog)
        if (model.purpose == ModelPurpose.translation && !model.retired) model,
    ];
    final items = <DropdownMenuItem<String>>[
      const DropdownMenuItem(value: 'bing', child: Text('必应翻译')),
      for (final model in localModels)
        DropdownMenuItem(
          value: 'local:${model.id}',
          child: Text(
            '本地 · ${model.name}${widget.center.installed(model.id) ? '' : ' · 未安装'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      if (_selection.startsWith('local:') &&
          localModels.every((model) => 'local:${model.id}' != _selection))
        DropdownMenuItem(
          value: _selection,
          child: Text('本地 · ${_selection.substring(6)}'),
        ),
      if (_connections.isEmpty)
        const DropdownMenuItem(value: 'ai:', child: Text('AI 接口')),
      for (final entry in _connections)
        DropdownMenuItem(
          value: 'ai:${entry.id}',
          child: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
    ];
    final selected = items.any((item) => item.value == _selection)
        ? _selection
        : null;
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
                    const Expanded(
                      child: Text(
                        '翻译模型',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: SubtitleSettingsTheme.foreground,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭翻译模型',
                      onPressed: _saving ? null : () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded, size: 20),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  key: const ValueKey('subtitle-translation-model-scroll'),
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        '还没单独选过翻译接口时，AI 会先用优化字幕里已经配置的模型。在这里改成其他接口后，翻译才不再跟着变。',
                        style: SubtitleSettingsTheme.description,
                      ),
                      const SizedBox(height: 10),
                      SubtitleSettingsGroup(
                        title: '使用的方式',
                        child: CapsuleDropdownButtonFormField<String>(
                          key: ValueKey('translation-model-$selected'),
                          useInputTheme: true,
                          initialValue: selected,
                          isExpanded: true,
                          isDense: true,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                          ),
                          items: items,
                          onChanged: _loading || _saving ? null : _choose,
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (_selection == 'bing')
                        const Text(
                          '必应翻译在线完成，不需要填写密钥或下载模型。',
                          style: SubtitleSettingsTheme.description,
                        ),
                      if (_selection.startsWith('local:'))
                        const Text(
                          '本地模型在这台设备上运行。未安装的模型可在模型中心下载。',
                          style: SubtitleSettingsTheme.description,
                        ),
                      if (_selection.startsWith('ai:')) ...[
                        const Text(
                          '模型和提示词可与优化字幕分开。相同接口的密钥与优化、AI 对话共用。',
                          style: SubtitleSettingsTheme.description,
                        ),
                        const SizedBox(height: 10),
                        if (_loading || _saving)
                          const LinearProgressIndicator(),
                        if (_endpoint case final value?)
                          AbsorbPointer(
                            absorbing: _saving,
                            child: AiSubtitleApiEditor(
                              key: ValueKey('translation-api-$_selection'),
                              settings: value,
                              title: '接口配置',
                              saveLabel: '保存并使用',
                              onSaved: _saveEndpoint,
                            ),
                          ),
                      ],
                      if (_error != null)
                        TextButton(
                          onPressed: _load,
                          child: Text('$_error · 重试'),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
