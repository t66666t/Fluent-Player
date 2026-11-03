import 'package:flutter/material.dart';

import 'dialog_keyboard_viewport.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// The shared create-collection form; the active page owns where it is saved.
Future<void> showLibraryCreateCollectionDialog({
  required BuildContext context,
  required Future<void> Function(String name) onCreate,
}) => showDialog<void>(
  context: context,
  builder: (_) => _CreateCollectionDialog(onCreate: onCreate),
);

class _CreateCollectionDialog extends StatefulWidget {
  const _CreateCollectionDialog({required this.onCreate});
  final Future<void> Function(String name) onCreate;

  @override
  State<_CreateCollectionDialog> createState() =>
      _CreateCollectionDialogState();
}

class _CreateCollectionDialogState extends State<_CreateCollectionDialog> {
  final _name = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (_saving || name.isEmpty) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onCreate(name);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '创建失败，请重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => DialogKeyboardViewport(
    child: AlertDialog(
      title: const Text('新建合集'),
      content: TextField(
        controller: _name,
        decoration: InputDecoration(hintText: '合集名称', errorText: _error),
        autofocus: true,
        enabled: !_saving,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        DesktopButtonClickRegion(
          child: TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ),
        DesktopButtonClickRegion(
          child: TextButton(
            onPressed: _saving ? null : _submit,
            child: const Text('创建'),
          ),
        ),
      ],
    ),
  );
}
