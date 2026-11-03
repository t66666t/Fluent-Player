import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_tokens.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

enum OperationStatusKind { progress, success, error, info }

/// A persistent result next to the operation that produced it.
class OperationStatus extends StatelessWidget {
  const OperationStatus({
    super.key,
    required this.title,
    this.message,
    this.kind = OperationStatusKind.info,
    this.details,
    this.actions = const [],
    this.progress,
  });

  final String title;
  final String? message;
  final OperationStatusKind kind;
  final String? details;
  final List<Widget> actions;
  final double? progress;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: kind == OperationStatusKind.error,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: TextStyle(
            color: kind == OperationStatusKind.error
                ? Theme.of(context).colorScheme.error
                : AppTokens.text1,
            fontSize: 13,
            height: 1.5,
          ),
        ),
        if (message != null && message!.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(message!, style: const TextStyle(fontSize: 13, height: 1.5)),
        ],
        if (kind == OperationStatusKind.progress) ...[
          const SizedBox(height: 8),
          LinearProgressIndicator(value: progress, minHeight: 2),
        ],
        if (details != null && details!.trim().isNotEmpty)
          _OperationDetails(
            text: safeOperationDiagnostic(details!),
            actions: actions,
          )
        else if (actions.isNotEmpty)
          Wrap(spacing: 8, runSpacing: 4, children: actions),
      ],
    ),
  );
}

class _OperationDetails extends StatefulWidget {
  const _OperationDetails({required this.text, this.actions = const []});
  final String text;
  final List<Widget> actions;
  @override
  State<_OperationDetails> createState() => _OperationDetailsState();
}

class _OperationDetailsState extends State<_OperationDetails> {
  bool _copied = false;
  bool _expanded = false;
  final _diagnosticScrollController = ScrollController(keepScrollOffset: false);
  // Diagnostics keep their scroll state separate from the surrounding page.
  final _diagnosticPageStorage = PageStorageBucket();

  @override
  void dispose() {
    _diagnosticScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          ...widget.actions,
          DesktopButtonClickRegion(
            child: TextButton(
              onPressed: () => setState(() => _expanded = !_expanded),
              child: const Text('诊断详情'),
            ),
          ),
        ],
      ),
      if (_expanded) ...[
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: PageStorage(
            bucket: _diagnosticPageStorage,
            child: SingleChildScrollView(
              controller: _diagnosticScrollController,
              primary: false,
              child: SelectableText(
                widget.text,
                style: const TextStyle(fontSize: 13, height: 1.5),
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: DesktopButtonClickRegion(
            child: TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: widget.text));
                if (mounted) setState(() => _copied = true);
              },
              child: Text(_copied ? '已复制' : '复制详情'),
            ),
          ),
        ),
      ],
    ],
  );
}

String operationErrorSummary(Object error, {required String fallback}) {
  if (error is TimeoutException) return '操作超时，请稍后重试。';
  if (error is SocketException) return '无法连接网络，请检查连接后重试。';
  if (error is FileSystemException) {
    final code = error.osError?.errorCode;
    if ((code == 5 && Platform.isWindows) || code == 13) {
      return '无法访问文件，请检查文件权限后重试。';
    }
    if (code == 28 || code == 112) return '存储空间不足，请释放空间后重试。';
    if (code == 2 || code == 3) return '找不到文件或文件夹，请检查原位置。';
  }
  return fallback;
}

String safeOperationDiagnostic(Object error) {
  var text = error.toString();
  text = text.replaceAllMapped(
    RegExp(
      r'(authorization|cookie|set-cookie)\s*[:=]\s*[^\r\n]+',
      caseSensitive: false,
    ),
    (match) => '${match[1]}: [已隐藏]',
  );
  text = text.replaceAll(
    RegExp(r'''Bearer\s+[^\s,;"']+''', caseSensitive: false),
    'Bearer [已隐藏]',
  );
  text = text.replaceAllMapped(
    RegExp(
      r'''([?&](?:api_key|apiKey|access_token|refresh_token|client_secret|password|token|sign|signature|key|cookie)=)[^&\s#"'<>]+''',
      caseSensitive: false,
    ),
    (match) => '${match[1]}[已隐藏]',
  );

  text = text.replaceAllMapped(
    RegExp(r'([a-z][a-z0-9+.-]*://)[^/\s@:]+:[^/\s@]*@', caseSensitive: false),
    (match) => '${match[1]}[已隐藏]@',
  );
  // Match explicit credential fields, rather than substrings in filenames or
  // model names. Preserve JSON quotes and delimiters so diagnostics stay useful.
  text = text.replaceAllMapped(
    RegExp(
      r'''(^|[\s{,;])((["\']?)(?:api_key|apiKey|access_token|refresh_token|client_secret|password|authorization|cookie|set-cookie)\3\s*[:=]\s*)(\[已隐藏\]|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|[^\s,;}\]&]+)''',
      caseSensitive: false,
      multiLine: true,
    ),
    (match) {
      final value = match[4]!;
      final quote = value.startsWith('"')
          ? '"'
          : value.startsWith("'")
          ? "'"
          : '';
      return '${match[1]}${match[2]}$quote[已隐藏]$quote';
    },
  );
  return text;
}

Future<void> showOperationFailureDialog(
  BuildContext context, {
  required String title,
  required String message,
  Object? error,
  List<Widget> actions = const [],
}) => showDialog<void>(
  context: context,
  builder: (dialog) => AlertDialog(
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    title: Text(title, style: const TextStyle(fontSize: 16)),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(message, style: const TextStyle(fontSize: 13, height: 1.5)),
            if (error != null)
              _OperationDetails(text: safeOperationDiagnostic(error)),
          ],
        ),
      ),
    ),
    actions: [
      ...actions,
      DesktopButtonClickRegion(
        child: TextButton(
          onPressed: () => Navigator.pop(dialog),
          child: const Text('关闭'),
        ),
      ),
    ],
  ),
);
