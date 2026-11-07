import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../services/ai_subtitle_api_settings.dart';
import 'ai_subtitle_api_dialog.dart';
import '../utils/app_toast.dart';

Future<AiSubtitleApiSettings?> showSubtitleAiConnectionPicker(
  BuildContext context, {
  String selectedId = '',
}) => showDialog<AiSubtitleApiSettings>(
  context: context,
  builder: (_) => _ConnectionPicker(selectedId: selectedId),
);

class _ConnectionPicker extends StatefulWidget {
  const _ConnectionPicker({required this.selectedId});
  final String selectedId;
  @override
  State<_ConnectionPicker> createState() => _ConnectionPickerState();
}

class _ConnectionPickerState extends State<_ConnectionPicker> {
  final store = SubtitleAiConnectionStore();
  List<SubtitleAiConnection>? entries;
  String? error;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await store.load();
      if (mounted) {
        setState(() {
          entries = items;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> _edit(SubtitleAiConnection? item) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final current = item == null
          ? const AiSubtitleApiSettings()
          : await store.endpoint(item.id);
      if (!mounted) return;
      final result = await showDialog<AiSubtitleApiSettings>(
        context: context,
        builder: (_) => AiSubtitleApiDialog(settings: current),
      );
      if (result == null) return;
      final id = item?.id ?? const Uuid().v4();
      final endpoint = result.copyWith(connectionId: id, profiles: const {});
      final name =
          '${endpoint.model} · ${Uri.tryParse(endpoint.baseUrl)?.host ?? ''}';
      await store.save(SubtitleAiConnection(id, name, endpoint));
      if (mounted) Navigator.pop(context, endpoint);
    } catch (e) {
      if (mounted) AppToast.show('接口未保存：$e', type: AppToastType.error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _select(SubtitleAiConnection item) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final result = await store.endpoint(item.id);
      if (mounted) Navigator.pop(context, result);
    } catch (e) {
      if (mounted) AppToast.show('接口未读取：$e', type: AppToastType.error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('优化/翻译接口'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '优化和翻译共用接口列表，各自选择使用的接口。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 10),
            if (error != null)
              TextButton(onPressed: _load, child: Text('$error · 重试'))
            else if (entries == null)
              const LinearProgressIndicator()
            else ...[
              for (final item in entries!)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Icon(
                    item.id == widget.selectedId
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 19,
                  ),
                  title: Text(
                    item.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    item.endpoint.model,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: busy ? null : () => _select(item),
                  trailing: IconButton(
                    tooltip: '编辑接口',
                    onPressed: busy ? null : () => _edit(item),
                    icon: const Icon(Icons.edit_outlined, size: 19),
                  ),
                ),
              if (entries!.isEmpty)
                const Text('尚未添加接口', style: TextStyle(fontSize: 12)),
            ],
            TextButton.icon(
              onPressed: busy ? null : () => _edit(null),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('新增接口'),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}
