import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/video_item.dart';
import 'ai_chat_layout.dart';
import 'ai_chat_models.dart';
import 'ai_conversation_export.dart';
import 'ai_video_context.dart';

Future<void> showAiConversationExportDialog(
  BuildContext context, {
  required VideoItem video,
  required List<AiConversation> conversations,
  required String conversationId,
  AiVideoContext? videoContext,
  Future<bool> Function(String fileName, String contents)? saveDocument,
}) => showDialog<void>(
  context: context,
  builder: (context) => _ExportDialog(
    video: video,
    conversations: conversations,
    conversationId: conversationId,
    videoContext: videoContext,
    saveDocument: saveDocument ?? _saveDocument,
  ),
);

Future<bool> _saveDocument(String fileName, String contents) async {
  final bytes = Uint8List.fromList(utf8.encode(contents));
  final path = await FilePicker.platform.saveFile(
    dialogTitle: '导出完整对话',
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: [fileName.split('.').last],
    bytes: bytes,
  );
  if (path == null) return false;
  if (!Platform.isAndroid && !Platform.isIOS) {
    await File(path).writeAsBytes(bytes, flush: true);
  }
  return true;
}

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({
    required this.video,
    required this.conversations,
    required this.conversationId,
    required this.videoContext,
    required this.saveDocument,
  });
  final VideoItem video;
  final List<AiConversation> conversations;
  final String conversationId;
  final AiVideoContext? videoContext;
  final Future<bool> Function(String, String) saveDocument;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  var _format = AiConversationExportFormat.markdown;
  bool _all = false, _transcripts = false, _reasoning = false, _busy = false;
  String? _error;

  AiConversationExport get _document {
    final records =
        widget.conversations
            .where((record) => _all || record.id == widget.conversationId)
            .toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return AiConversationExport(
      video: widget.video,
      conversations: records,
      videoContext: widget.videoContext,
      includeTranscripts: _transcripts,
      includeReasoning: _reasoning,
    );
  }

  Future<void> _export({required bool copy}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final document = _document;
      final contents = document.render(_format);
      if (copy) {
        await Clipboard.setData(ClipboardData(text: contents));
      } else if (!await widget.saveDocument(
        document.fileName(_format),
        contents,
      )) {
        return;
      }
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(copy ? '已复制完整对话' : '对话已导出')));
        Navigator.pop(context);
      }
    } catch (_) {
      if (mounted) setState(() => _error = '导出未完成，原对话已保留，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final count = _document.conversations.fold<int>(
      0,
      (total, record) => total + record.messages.length,
    );
    return AiAdaptiveDialog(
      title: const Text('导出完整对话'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('包含从第一轮开始的全部 $count 条消息，可直接交给其他 AI。未发送的草稿不包含在内。'),
              const SizedBox(height: 12),
              DropdownButtonFormField<AiConversationExportFormat>(
                initialValue: _format,
                decoration: const InputDecoration(labelText: '格式'),
                items: [
                  for (final format in AiConversationExportFormat.values)
                    DropdownMenuItem(
                      value: format,
                      child: Text('${format.label}（.${format.extension}）'),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _format = value!),
              ),
              if (widget.conversations.length > 1)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('包含此媒体的全部对话及分支'),
                  value: _all,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _all = value!),
                ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('附上所选文稿'),
                subtitle: const Text('附加导出时可用的完整文稿及时间戳'),
                value: _transcripts,
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _transcripts = value!),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('包含 AI 已返回的思考内容'),
                value: _reasoning,
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _reasoning = value!),
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: _busy || count == 0 ? null : () => _export(copy: true),
          child: const Text('复制全部'),
        ),
        FilledButton(
          onPressed: _busy || count == 0 ? null : () => _export(copy: false),
          child: Text(_busy ? '正在导出…' : '保存文件'),
        ),
      ],
    );
  }
}
