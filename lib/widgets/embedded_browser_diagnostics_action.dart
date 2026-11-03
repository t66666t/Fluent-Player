import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/browser/embedded_browser_diagnostics.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

Future<void> showEmbeddedBrowserDiagnostics(BuildContext context) async {
  final report = await EmbeddedBrowserDiagnostics.report();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('浏览器诊断'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(child: SelectableText(report)),
      ),
      actions: [
        DesktopButtonClickRegion(
          child: TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: report)),
            child: const Text('复制诊断'),
          ),
        ),
        DesktopButtonClickRegion(
          child: TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ),
      ],
    ),
  );
}

class EmbeddedBrowserDiagnosticsAction extends StatelessWidget {
  const EmbeddedBrowserDiagnosticsAction({super.key});

  @override
  Widget build(BuildContext context) => CapsulePopupMenuButton<String>(
    tooltip: '浏览器选项',
    onSelected: (_) => showEmbeddedBrowserDiagnostics(context),
    itemBuilder: (_) => const [
      PopupMenuItem(value: 'diagnostics', child: Text('浏览器诊断')),
    ],
  );
}
