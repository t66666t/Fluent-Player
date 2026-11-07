import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/transcription_hotword_store.dart';
import 'subtitle_settings_layout.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

Future<void> showTranscriptionHotwords(
  BuildContext context, {
  required TranscriptionHotwordStore store,
  required String mediaKey,
  required String mediaTitle,
  bool enhancementsEnabled = true,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => SubtitleSettingsTheme(
    child: _HotwordEditor(
      store: store,
      mediaKey: mediaKey,
      mediaTitle: mediaTitle,
      enhancementsEnabled: enhancementsEnabled,
    ),
  ),
);

class _HotwordEditor extends StatefulWidget {
  const _HotwordEditor({
    required this.store,
    required this.mediaKey,
    required this.mediaTitle,
    required this.enhancementsEnabled,
  });
  final TranscriptionHotwordStore store;
  final String mediaKey, mediaTitle;
  final bool enhancementsEnabled;
  @override
  State<_HotwordEditor> createState() => _HotwordEditorState();
}

class _HotwordEditorState extends State<_HotwordEditor> {
  late final _text = TextEditingController(
    text: widget.store.wordsFor(widget.mediaKey),
  );
  bool _busy = false;
  String? _error, _presetName;
  @override
  void initState() {
    super.initState();
    widget.store.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.store.removeListener(_changed);
    _text.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is FormatException ? error.message : '$error',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _apply() => _run(() async {
    await widget.store.setWords(widget.mediaKey, _text.text);
    if (mounted) Navigator.pop(context);
  });

  Future<void> _savePreset({
    TranscriptionHotwordPreset? preset,
    bool update = false,
  }) async {
    if (_busy) return;
    final name = update
        ? preset!.name
        : await showDialog<String>(
            context: context,
            builder: (_) => _PresetNameDialog(name: preset?.name ?? ''),
          );
    if (name == null || !mounted) return;
    await _run(
      () => widget.store.savePreset(
        id: preset?.id,
        name: name,
        words: preset != null && !update ? preset.words : _text.text,
      ),
    );
  }

  void _use(TranscriptionHotwordPreset preset) {
    _text.value = TextEditingValue(
      text: preset.words,
      selection: TextSelection.collapsed(offset: preset.words.length),
    );
    setState(() {
      _presetName = preset.name;
      _error = null;
    });
  }

  Widget _presets() => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) => Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final preset in widget.store.presets)
          Container(
            key: ValueKey('hotword-preset-${preset.id}'),
            constraints: const BoxConstraints(maxWidth: 240),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: DesktopButtonClickRegion(
                    child: TextButton(
                      key: ValueKey('apply-hotword-preset-${preset.id}'),
                      onPressed: _busy ? null : () => _use(preset),
                      child: Text(
                        preset.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
                DesktopButtonClickRegion(
                  child: PopupMenuButton<String>(
                    tooltip: '管理预设 ${preset.name}',
                    enabled: !_busy,
                    icon: const Icon(Icons.more_horiz_rounded, size: 18),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 150),
                    onSelected: (action) {
                      if (action == 'rename') _savePreset(preset: preset);
                      if (action == 'update') {
                        _savePreset(preset: preset, update: true);
                      }
                      if (action == 'delete') {
                        _run(() => widget.store.deletePreset(preset.id));
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'rename', child: Text('重命名')),
                      PopupMenuItem(value: 'update', child: Text('用当前热词更新')),
                      PopupMenuItem(value: 'delete', child: Text('删除预设')),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final available = size.height - MediaQuery.viewInsetsOf(context).bottom;
    final compact = size.width < 480 || available < 420;
    final content = SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.mediaTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 6),
          const Text('仅用于本视频的新任务，不会自动带到其他视频。', style: TextStyle(fontSize: 12)),
          if (!widget.enhancementsEnabled) ...[
            const SizedBox(height: 6),
            Text(
              '识别增强当前已关闭；开启后才会使用热词。',
              style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
            ),
          ],
          const SizedBox(height: 14),
          TextField(
            key: const ValueKey('video-hotwords-input'),
            controller: _text,
            enabled: !_busy,
            minLines: 3,
            maxLines: 6,
            maxLength: 4000,
            textCapitalization: TextCapitalization.none,
            decoration: const InputDecoration(
              labelText: '热词（每行一个）',
              helperText: '最多 100 条',
              hintText: '人名、品牌、专业名词…',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {
              _presetName = null;
              _error = null;
            }),
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  _presetName == null
                      ? '热词是识别参考，不会强制替换原文。'
                      : '已载入「$_presetName」',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              DesktopButtonClickRegion(
                child: TextButton(
                  onPressed: _busy
                      ? null
                      : () {
                          _text.clear();
                          setState(() => _presetName = null);
                        },
                  child: const Text('清空'),
                ),
              ),
            ],
          ),
          const Divider(height: 20),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              const Text('常用预设', style: TextStyle(fontWeight: FontWeight.w600)),
              DesktopButtonClickRegion(
                child: TextButton.icon(
                  key: const ValueKey('save-hotword-preset'),
                  onPressed: _busy ? null : () => _savePreset(),
                  icon: const Icon(Icons.bookmark_add_outlined, size: 17),
                  label: const Text('存为预设'),
                ),
              ),
            ],
          ),
          if (widget.store.presets.isEmpty)
            const Text('保存常用领域词汇并命名，下次点选即可填入。', style: TextStyle(fontSize: 12))
          else
            _presets(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                key: const ValueKey('hotword-editor-error'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
        ],
      ),
    );
    final bar = AppBar(
      automaticallyImplyLeading: false,
      leading: DesktopButtonClickRegion(
        child: IconButton(
          tooltip: '关闭热词编辑器',
          onPressed: _busy ? null : () => Navigator.pop(context),
          icon: const Icon(Icons.close_rounded),
        ),
      ),
      title: const Text('本视频热词'),
      titleTextStyle: theme.textTheme.titleMedium,
      actions: [
        DesktopButtonClickRegion(
          child: TextButton(
            key: const ValueKey('apply-video-hotwords'),
            onPressed: _busy ? null : _apply,
            child: Text(_busy ? '保存中…' : '应用'),
          ),
        ),
        const SizedBox(width: 8),
      ],
    );
    if (compact) {
      return PopScope(
        canPop: !_busy,
        child: Dialog.fullscreen(
          child: Scaffold(appBar: bar, body: content),
        ),
      );
    }
    return PopScope(
      canPop: !_busy,
      child: Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 520,
            maxHeight: math.min(560, available - 64),
          ),
          child: Column(
            children: [
              SizedBox(height: bar.preferredSize.height, child: bar),
              Expanded(child: content),
            ],
          ),
        ),
      ),
    );
  }
}

class _PresetNameDialog extends StatefulWidget {
  const _PresetNameDialog({required this.name});
  final String name;
  @override
  State<_PresetNameDialog> createState() => _PresetNameDialogState();
}

class _PresetNameDialogState extends State<_PresetNameDialog> {
  late final _name = TextEditingController(text: widget.name);
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = '请输入预设名称');
      return;
    }
    Navigator.pop(context, _name.text.trim());
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('预设名称'),
    content: TextField(
      key: const ValueKey('hotword-preset-name'),
      controller: _name,
      autofocus: true,
      maxLength: 40,
      textInputAction: TextInputAction.done,
      decoration: InputDecoration(hintText: '例如：医学讲座、项目成员', errorText: _error),
      onSubmitted: (_) => _save(),
    ),
    actions: [
      DesktopButtonClickRegion(
        child: TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ),
      DesktopButtonClickRegion(
        child: FilledButton(onPressed: _save, child: const Text('保存')),
      ),
    ],
  );
}
