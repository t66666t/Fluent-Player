import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../../widgets/dialog_keyboard_viewport.dart';
import 'ai_chat_copy.dart';
import 'ai_chat_layout.dart';
import 'ai_quick_prompts.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';
import 'package:video_player_app/widgets/button_aware_drag.dart';

Future<void> showAiQuickPrompts(
  BuildContext context, {
  AiQuickPromptStore? store,
  required AiChatMediaCopy media,
}) => showDialog<void>(
  context: context,
  useSafeArea: false,
  barrierDismissible: false,
  builder: (_) => AiQuickPromptsDialog(
    store: store ?? AiQuickPromptStore.instance,
    media: media,
  ),
);

class AiQuickPromptsDialog extends StatefulWidget {
  const AiQuickPromptsDialog({
    super.key,
    required this.store,
    required this.media,
  });

  final AiQuickPromptStore store;
  final AiChatMediaCopy media;

  @override
  State<AiQuickPromptsDialog> createState() => _AiQuickPromptsDialogState();
}

class _AiQuickPromptsDialogState extends State<AiQuickPromptsDialog> {
  bool _busy = false;
  String? _error;
  bool get _locked => _busy || widget.store.loading;

  @override
  void initState() {
    super.initState();
    unawaited(widget.store.load());
  }

  Future<void> _persist(Future<void> Function() operation) async {
    if (_locked) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
    } catch (_) {
      if (mounted) setState(() => _error = '提示词未保存，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit([AiQuickPrompt? original, bool duplicate = false]) async {
    final initial = AiQuickPrompt(
      id: original != null && !duplicate ? original.id : const Uuid().v4(),
      name: original == null
          ? ''
          : duplicate
          ? '${original.name}（副本）'
          : original.name,
      text: original?.text ?? '',
    );
    await showDialog<void>(
      context: context,
      useSafeArea: false,
      barrierDismissible: false,
      builder: (_) => AiQuickPromptEditor(
        initial: initial,
        isNew: original == null || duplicate,
        onSave: (entry) async {
          final entries = List<AiQuickPrompt>.of(widget.store.entries);
          final index = entries.indexWhere((item) => item.id == entry.id);
          if (original != null && !duplicate) {
            if (index < 0) throw StateError('此提示词已被删除，请重新打开。');
            entries[index] = entry;
          } else {
            entries.add(entry);
          }
          await widget.store.replace(entries);
        },
      ),
    );
  }

  Future<void> _restore() async {
    final confirmed = await _confirm(
      context,
      title: '恢复默认预设？',
      message: '所有自定义提示词和排列顺序都将替换为默认的四条预设。',
      action: '恢复默认',
    );
    if (confirmed && mounted) await _persist(widget.store.restoreDefaults);
  }

  Future<void> _delete(AiQuickPrompt entry) async {
    final confirmed = await _confirm(
      context,
      title: '删除提示词？',
      message: entry.nameFor(widget.media),
      action: '删除',
    );
    if (confirmed && mounted) {
      await _persist(
        () => widget.store.replace([
          for (final item in widget.store.entries)
            if (item.id != entry.id) item,
        ]),
      );
    }
  }

  void _move(int from, int to) {
    if (from == to || _locked) return;
    final entries = List<AiQuickPrompt>.of(widget.store.entries);
    entries.insert(to, entries.removeAt(from));
    unawaited(_persist(() => widget.store.replace(entries)));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) {
      final entries = widget.store.entries;
      final canEdit = !_locked && widget.store.loadError == null;
      return PopScope(
        canPop: !_busy,
        child: _PromptSurface(
          title: '管理提示词',
          onClose: _busy ? null : () => Navigator.pop(context),
          child: Column(
            children: [
              if (_locked) const LinearProgressIndicator(),
              Expanded(
                child: ReorderableListView.builder(
                  key: const ValueKey('ai-quick-prompt-list'),
                  padding: const EdgeInsets.only(bottom: 16),
                  buildDefaultDragHandles: false,
                  itemCount: entries.length,
                  header: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            DesktopButtonClickRegion(
                              child: FilledButton.icon(
                                key: const ValueKey('ai-quick-prompt-add'),
                                onPressed: canEdit ? () => _edit() : null,
                                icon: const Icon(Icons.add),
                                label: const Text('新增提示词'),
                              ),
                            ),
                            DesktopButtonClickRegion(
                              child: TextButton(
                                onPressed: _locked ? null : _restore,
                                child: const Text('恢复默认'),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                        child: Text(
                          '所有 AI 对话共用，保存后立即生效。拖动手柄或使用条目菜单调整顺序。',
                          style: Theme.of(context).textTheme.bodySmall,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (_error ?? widget.store.loadError
                          case final String error)
                        _ErrorNotice(
                          error,
                          retry: widget.store.loadError == null
                              ? null
                              : () async {
                                  setState(() => _error = null);
                                  final loading = widget.store.load();
                                  setState(() {});
                                  await loading;
                                },
                        ),
                    ],
                  ),
                  footer: entries.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text('还没有预设，点击“新增提示词”开始添加。'),
                        )
                      : null,
                  onReorderItem: (from, to) {
                    if (!canEdit) return;
                    _move(from, to);
                  },
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    final name = entry.nameFor(widget.media);
                    final text = entry.textFor(widget.media);
                    return Material(
                      key: ValueKey(entry.id),
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: canEdit ? () => _edit(entry) : null,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
                          child: Row(
                            children: [
                              ButtonAwareReorderableDragStartListener(
                                index: index,
                                enabled: canEdit,
                                child: const Tooltip(
                                  message: '拖动排序',
                                  child: SizedBox(
                                    width: 40,
                                    height: 48,
                                    child: Icon(Icons.drag_indicator),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      name,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleSmall,
                                    ),
                                    if (text != name) ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        text.characters.take(160).toString(),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              DesktopButtonClickRegion(
                                child: PopupMenuButton<String>(
                                  key: ValueKey(
                                    'ai-quick-prompt-menu-${entry.id}',
                                  ),
                                  tooltip: '提示词操作',
                                  enabled: canEdit,
                                  itemBuilder: (_) => [
                                    const PopupMenuItem(
                                      value: 'edit',
                                      child: Text('编辑'),
                                    ),
                                    const PopupMenuItem(
                                      value: 'copy',
                                      child: Text('复制为新提示词'),
                                    ),
                                    PopupMenuItem(
                                      value: 'up',
                                      enabled: index > 0,
                                      child: const Text('上移'),
                                    ),
                                    PopupMenuItem(
                                      value: 'down',
                                      enabled: index < entries.length - 1,
                                      child: const Text('下移'),
                                    ),
                                    const PopupMenuItem(
                                      value: 'delete',
                                      child: Text('删除'),
                                    ),
                                  ],
                                  onSelected: (value) {
                                    switch (value) {
                                      case 'edit':
                                        unawaited(_edit(entry));
                                      case 'copy':
                                        unawaited(_edit(entry, true));
                                      case 'up':
                                        _move(index, index - 1);
                                      case 'down':
                                        _move(index, index + 1);
                                      case 'delete':
                                        unawaited(_delete(entry));
                                    }
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Own route and controllers: long, multiline drafts survive window resizing,
/// IME changes and failed saves without changing the globally saved library.
class AiQuickPromptEditor extends StatefulWidget {
  const AiQuickPromptEditor({
    super.key,
    required this.initial,
    required this.onSave,
    this.isNew = false,
  });

  final AiQuickPrompt initial;
  final Future<void> Function(AiQuickPrompt) onSave;
  final bool isNew;

  @override
  State<AiQuickPromptEditor> createState() => _AiQuickPromptEditorState();
}

class _AiQuickPromptEditorState extends State<AiQuickPromptEditor> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.initial.name);
  late final _text = TextEditingController(text: widget.initial.text);
  final _nameFocus = FocusNode();
  final _textFocus = FocusNode();
  bool _saving = false;
  bool _confirmingClose = false;
  String? _error;

  bool get _dirty =>
      _name.text != widget.initial.name || _text.text != widget.initial.text;
  bool get _composing => [_name, _text].any(
    (input) =>
        input.value.composing.isValid && !input.value.composing.isCollapsed,
  );

  @override
  void initState() {
    super.initState();
    _name.addListener(_edited);
    _text.addListener(_edited);
  }

  void _edited() => setState(() {});

  Future<void> _close() async {
    if (_saving || _composing || _confirmingClose) return;
    _confirmingClose = true;
    final discard =
        !_dirty ||
        await _confirm(
          context,
          title: '放弃未保存的修改？',
          message: '当前名称和正文的修改尚未保存。',
          action: '放弃修改',
        );
    _confirmingClose = false;
    if (discard && mounted) Navigator.pop(context);
  }

  Future<void> _save() async {
    if (_saving || _composing || !_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(
        AiQuickPrompt(
          id: widget.initial.id,
          name: _name.text.trim(),
          text: _text.text,
        ),
      );
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) setState(() => _error = '提示词未保存，请重试。当前编辑内容已保留。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_composing) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if ((keyboard.isControlPressed || keyboard.isMetaPressed) &&
        !keyboard.isAltPressed &&
        event.logicalKey == LogicalKeyboardKey.keyS) {
      if (event is KeyDownEvent) unawaited(_save());
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (event is KeyDownEvent) unawaited(_close());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _name.dispose();
    _text.dispose();
    _nameFocus.dispose();
    _textFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    // Read live editor state in _close, even if back arrives between a text
    // input event and the next frame that would rebuild this PopScope.
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_close());
    },
    child: Focus(
      onKeyEvent: _onKey,
      child: _PromptSurface(
        title: widget.isNew ? '新增提示词' : '编辑提示词',
        onClose: _saving ? null : _close,
        action: DesktopButtonClickRegion(
          child: FilledButton(
            key: const ValueKey('ai-quick-prompt-save'),
            onPressed: _saving ? null : _save,
            child: Text(_saving ? '保存中…' : '保存'),
          ),
        ),
        child: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Form(
                    key: _form,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_error != null) _ErrorNotice(_error!),
                        TextFormField(
                          key: const ValueKey('ai-quick-prompt-name'),
                          controller: _name,
                          focusNode: _nameFocus,
                          readOnly: _saving,
                          decoration: const InputDecoration(
                            labelText: '名称',
                            hintText: '例如：完整学习笔记',
                            border: OutlineInputBorder(),
                          ),
                          textInputAction: TextInputAction.next,
                          onFieldSubmitted: (_) => _textFocus.requestFocus(),
                          validator: (value) =>
                              (value ?? '').trim().isEmpty ? '请输入名称' : null,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '正文支持长文本、换行和粘贴。可选用 {{媒体}} 自动填入“视频 / 音频 / 播客”。',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          height: math.max(
                            180,
                            constraints.maxHeight -
                                190 *
                                    math.max(
                                      1,
                                      MediaQuery.textScalerOf(
                                            context,
                                          ).scale(14) /
                                          14,
                                    ),
                          ),
                          child: TextFormField(
                            key: const ValueKey('ai-quick-prompt-text'),
                            controller: _text,
                            focusNode: _textFocus,
                            readOnly: _saving,
                            expands: true,
                            minLines: null,
                            maxLines: null,
                            keyboardType: TextInputType.multiline,
                            textInputAction: TextInputAction.newline,
                            textAlignVertical: TextAlignVertical.top,
                            style: const TextStyle(height: 1.5),
                            decoration: const InputDecoration(
                              labelText: '提示词正文',
                              alignLabelWithHint: true,
                              hintText: '输入点击预设后要填入的完整内容…',
                              border: OutlineInputBorder(),
                            ),
                            validator: (value) => (value ?? '').trim().isEmpty
                                ? '请输入提示词正文'
                                : null,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${_text.text.characters.length} 字符 · Enter 换行 · Ctrl/Cmd+S 保存',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _PromptSurface extends StatelessWidget {
  const _PromptSurface({
    required this.title,
    required this.onClose,
    required this.child,
    this.action,
  });

  final String title;
  final VoidCallback? onClose;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Theme(
    data: aiChatDialogTheme(Theme.of(context)),
    child: DialogKeyboardViewport(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact =
              constraints.maxWidth < 640 || constraints.maxHeight < 460;
          final margin = compact ? 8.0 : 24.0;
          return Dialog(
            key: const ValueKey('ai-quick-prompt-surface'),
            insetPadding: EdgeInsets.all(margin),
            constraints: const BoxConstraints(maxWidth: 900),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: math.min(900, constraints.maxWidth - margin * 2),
              height: math.min(640, constraints.maxHeight - margin * 2),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        DesktopButtonClickRegion(
                          child: IconButton(
                            tooltip: '关闭$title',
                            onPressed: onClose,
                            icon: const Icon(Icons.close),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        ?action,
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(child: child),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
}

class _ErrorNotice extends StatelessWidget {
  const _ErrorNotice(this.message, {this.retry});
  final String message;
  final VoidCallback? retry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: DesktopButtonClickRegion(
      child: TextButton(
        onPressed: retry,
        child: Text(
          '$message${retry == null ? '' : ' 点击重试'}',
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ),
    ),
  );
}

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String message,
  required String action,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => DialogKeyboardViewport(
        child: AlertDialog(
          scrollable: true,
          insetPadding: const EdgeInsets.all(12),
          title: Text(title),
          content: Text(message),
          actions: [
            DesktopButtonClickRegion(
              child: TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
            ),
            DesktopButtonClickRegion(
              child: TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(action),
              ),
            ),
          ],
        ),
      ),
    ) ??
    false;
