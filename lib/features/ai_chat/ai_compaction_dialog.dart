import 'package:flutter/material.dart';

import 'ai_chat_controller.dart';
import 'ai_chat_layout.dart';
import 'ai_chat_models.dart';
import 'ai_token_usage.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

Future<void> showAiCompactionDialog(
  BuildContext context,
  AiChatController controller,
) => showDialog<void>(
  context: context,
  builder: (_) => _CompactionDialog(
    controller: controller,
    conversationId: controller.active?.id,
  ),
);

class _CompactionDialog extends StatefulWidget {
  const _CompactionDialog({
    required this.controller,
    required this.conversationId,
  });
  final AiChatController controller;
  final String? conversationId;
  @override
  State<_CompactionDialog> createState() => _CompactionDialogState();
}

class _CompactionDialogState extends State<_CompactionDialog> {
  final focus = TextEditingController();
  bool saving = false;
  String? saveError;
  @override
  void dispose() {
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      AiConversation? record;
      for (final item in controller.conversations) {
        if (item.id == widget.conversationId) record = item;
      }
      final same = record != null && controller.active?.id == record.id;
      final checkpoint =
          record?.contextCheckpoint?.matches(record.messages) == true
          ? record!.contextCheckpoint
          : null;
      final info = record?.compactionInfo;
      final usage = info?['usage'] is Map
          ? AiTokenUsage.fromMap(Map<String, dynamic>.from(info!['usage']))
          : null;
      final busy = record != null && controller.isGenerating(record.id);
      return AiAdaptiveDialog(
        title: Text(
          '上下文压缩',
          style: TextStyle(
            fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '整理较早对话，保留近期交流。完整聊天记录继续保存在本地，字幕沿用当前资料模式。摘要使用当前模型，可能产生额外用量。',
              ),
              const SizedBox(height: 8),
              SwitchListTile.adaptive(
                key: const ValueKey('ai-auto-compaction'),
                contentPadding: EdgeInsets.zero,
                title: const Text('自动压缩'),
                subtitle: const Text('接近有效输入预算时自动整理'),
                value: controller.settings.autoCompact,
                onChanged: saving || controller.busy
                    ? null
                    : (value) async {
                        setState(() {
                          saving = true;
                          saveError = null;
                        });
                        try {
                          await controller.saveSettings(
                            controller.settings.copyWith(autoCompact: value),
                          );
                        } catch (_) {
                          if (mounted) setState(() => saveError = '设置未保存，请重试。');
                        } finally {
                          if (mounted) setState(() => saving = false);
                        }
                      },
              ),
              if (saveError != null) Text(saveError!),
              TextField(
                key: const ValueKey('ai-compaction-focus'),
                controller: focus,
                enabled: same && !busy,
                maxLines: 2,
                maxLength: 1000,
                decoration: const InputDecoration(
                  labelText: '保留重点（可选）',
                  hintText: '例如：保留我的纠正、限制条件和未解决问题',
                ),
              ),
              if (!same) const Text('已切换对话，请关闭后在目标对话中重新打开。'),
              if (busy)
                Text(
                  same
                      ? controller.preparationStatus ?? '当前对话正在生成，请稍后压缩。'
                      : '原对话仍在处理中。',
                ),
              if (info != null) ...[
                const Divider(),
                Text(
                  '${info['message'] ?? ''}',
                  key: const ValueKey('ai-compaction-result'),
                ),
                if (info['before_tokens'] != null &&
                    info['after_tokens'] != null)
                  Text(
                    '输入估算：${info['before_tokens']} → ${info['after_tokens']} token',
                  ),
                Text('摘要请求：${info['calls'] ?? 0}/8 次'),
                if (usage != null)
                  Text(
                    usage.total == null
                        ? '实际用量：服务未完整返回'
                        : '${usage.complete ? '实际' : '已知'}摘要用量：${usage.total} token',
                  ),
              ],
              if (checkpoint != null) ...[
                const Divider(),
                ExpansionTile(
                  key: const ValueKey('ai-compaction-summary'),
                  tilePadding: EdgeInsets.zero,
                  title: const Text('查看摘要'),
                  subtitle: Text(
                    '覆盖前 ${checkpoint.coveredMessages} 条历史消息 · ${checkpoint.createdAt.toLocal().toString().split('.').first}',
                  ),
                  children: [SelectableText(checkpoint.summary)],
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (same && controller.compacting)
            DesktopButtonClickRegion(child: TextButton(onPressed: controller.stop, child: const Text('停止压缩'))),
          DesktopButtonClickRegion(child: FilledButton(
            key: const ValueKey('ai-compact-now'),
            onPressed: same && !busy && !controller.busy
                ? () => controller.compactContext(focus: focus.text)
                : null,
            child: const Text('立即压缩'),
          )),
          DesktopButtonClickRegion(child: TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          )),
        ],
      );
    },
  );
}
