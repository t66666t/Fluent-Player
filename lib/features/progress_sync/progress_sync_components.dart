import 'package:flutter/material.dart';
import '../../widgets/keyboard_inset_padding.dart';

import '../../theme/app_tokens.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

Future<bool> showProgressSyncPairingConfirmation({
  required BuildContext context,
  required String deviceName,
  required String code,
}) async =>
    await showSyncSheet<bool>(
      context: context,
      title: '连接设备',
      child: Builder(
        builder: (sheetContext) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '请核对「$deviceName」上的确认码',
              style: const TextStyle(color: AppTokens.text2, height: 1.5),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: SelectableText(
                code,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 5,
                  color: AppTokens.text1,
                ),
              ),
            ),
            const Text(
              '两端确认码相同，再允许连接。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppTokens.text2),
            ),
            const SizedBox(height: 24),
            DesktopButtonClickRegion(
              child: FilledButton(
                onPressed: () => Navigator.pop(sheetContext, true),
                child: const Text('相同，允许连接'),
              ),
            ),
            const SizedBox(height: 4),
            DesktopButtonClickRegion(
              child: TextButton(
                onPressed: () => Navigator.pop(sheetContext, false),
                child: const Text('取消'),
              ),
            ),
          ],
        ),
      ),
    ) ??
    false;

Future<String?> showProgressSyncTextInput({
  required BuildContext context,
  required String title,
  required String label,
  required String action,
  String value = '',
  String? hint,
  String? description,
  int? maxLength,
  int maxLines = 1,
}) => showSyncSheet<String>(
  context: context,
  title: title,
  child: _SyncTextInput(
    label: label,
    action: action,
    value: value,
    hint: hint,
    description: description,
    maxLength: maxLength,
    maxLines: maxLines,
  ),
);

class _SyncTextInput extends StatefulWidget {
  const _SyncTextInput({
    required this.label,
    required this.action,
    required this.value,
    required this.maxLines,
    this.hint,
    this.description,
    this.maxLength,
  });

  final String label;
  final String action;
  final String value;
  final String? hint;
  final String? description;
  final int? maxLength;
  final int maxLines;

  @override
  State<_SyncTextInput> createState() => _SyncTextInputState();
}

class _SyncTextInputState extends State<_SyncTextInput> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.value,
  );
  final _form = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Form(
    key: _form,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.description != null) ...[
          Text(
            widget.description!,
            style: const TextStyle(color: AppTokens.text2, height: 1.5),
          ),
          const SizedBox(height: 16),
        ],
        TextFormField(
          controller: _controller,
          maxLength: widget.maxLength,
          maxLines: widget.maxLines,
          decoration: InputDecoration(
            labelText: widget.label,
            hintText: widget.hint,
          ),
          validator: (value) =>
              value?.trim().isNotEmpty == true ? null : '请输入${widget.label}',
        ),
        const SizedBox(height: 24),
        DesktopButtonClickRegion(
          child: FilledButton(
            onPressed: () {
              if (_form.currentState!.validate()) {
                Navigator.pop(context, _controller.text.trim());
              }
            },
            child: Text(widget.action),
          ),
        ),
      ],
    ),
  );
}

/// Quiet, shared surfaces for the progress-sync screen and its sheets.
class SyncSection extends StatelessWidget {
  const SyncSection({
    super.key,
    required this.title,
    required this.child,
    this.action,
  });

  final String title;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 9),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppTokens.text2,
                  ),
                ),
              ),
              ?action,
            ],
          ),
        ),
        Material(
          color: AppTokens.bgRaised,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: child,
        ),
      ],
    ),
  );
}

class SyncEmpty extends StatelessWidget {
  const SyncEmpty({
    super.key,
    required this.icon,
    required this.title,
    this.description,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? description;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(22),
    child: SizedBox(
      width: double.infinity,
      child: Column(
        children: [
          Icon(icon, color: AppTokens.text3, size: 28),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: AppTokens.text1),
          ),
          if (description != null) ...[
            const SizedBox(height: 6),
            Text(
              description!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                height: 1.55,
                color: AppTokens.text2,
              ),
            ),
          ],
          if (action != null) ...[const SizedBox(height: 12), action!],
        ],
      ),
    ),
  );
}

class SyncStatus extends StatelessWidget {
  const SyncStatus({super.key, required this.label, this.active = false});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          color: active ? AppTokens.accent : AppTokens.text3,
          shape: BoxShape.circle,
        ),
      ),
      const SizedBox(width: 6),
      Flexible(
        child: Text(
          label,
          style: const TextStyle(fontSize: 12, color: AppTokens.text2),
        ),
      ),
    ],
  );
}

Future<T?> showSyncSheet<T>({
  required BuildContext context,
  required String title,
  required Widget child,
}) {
  final narrow = MediaQuery.sizeOf(context).width < 600;
  final content = _SyncSheetBody(title: title, child: child);
  if (narrow) {
    return showModalBottomSheet<T>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppTokens.bgRaised,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => KeyboardInsetPadding(child: content),
    );
  }
  return showDialog<T>(
    context: context,
    builder: (_) => Dialog(
      insetAnimationDuration: Duration.zero,
      backgroundColor: AppTokens.bgRaised,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(width: 480, child: content),
    ),
  );
}

class _SyncSheetBody extends StatelessWidget {
  const _SyncSheetBody({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * .85,
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 22),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppTokens.text1,
                    ),
                  ),
                ),
                DesktopButtonClickRegion(
                  child: IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, size: 20),
                    color: AppTokens.text2,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    ),
  );
}
