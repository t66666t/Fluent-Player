import 'package:flutter/material.dart';

import '../../theme/app_page_transitions.dart';
import '../../theme/app_tokens.dart';
import '../../utils/desktop_media_management_shortcuts.dart';
import '../../widgets/desktop_button_click_region.dart';
import '../../widgets/media_library_compact_app_bar.dart';
import '../../widgets/media_library_shell.dart';
import '../../widgets/responsive_icon_button.dart';
import 'external_ai_connection_status.dart';
import 'external_ai_controller.dart';
import 'external_ai_preferences.dart';
import 'external_ai_screen.dart';

/// Direct library-toolbar entry, including compact desktop windows.
class ExternalAiToolbarAction extends StatelessWidget {
  const ExternalAiToolbarAction({
    super.key,
    this.compact = false,
    this.controller,
  });

  final bool compact;
  final ExternalAiController? controller;
  static bool get isSupported => ExternalAiPreferences.isDesktopSupported;

  static void open(BuildContext context, {ExternalAiController? controller}) {
    if (!isSupported) return;
    pushAboveMediaLibrary<void>(
      context,
      AppMaterialPageRoute<void>(
        builder: (_) => ExternalAiScreen(controller: controller),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final connection = controller ?? ExternalAiController.instance;
    return AnimatedBuilder(
      animation: connection,
      builder: (context, _) {
        final lastCall = connection.lastExternalToolCallAt;
        final color = lastCall != null
            ? externalAiVerifiedColor
            : AppTokens.text2;
        final status = !connection.running
            ? '读取已关闭'
            : lastCall != null
            ? '已收到 Agent 调用 · ${externalAiCallTime(lastCall)}'
            : '等待 Agent 调用';
        final label = DesktopMediaManagementShortcuts.buildTooltip(
          '连接外部 AI',
          DesktopMediaManagementShortcutAction.openExternalAi,
          context: context,
        );
        final tooltip = '$label\n$status';
        void open() =>
            ExternalAiToolbarAction.open(context, controller: connection);

        final showLabel =
            MediaQuery.sizeOf(context).width >= 1100 &&
            MediaQuery.textScalerOf(context).scale(13) <= 18;
        if (showLabel) {
          return Tooltip(
            message: tooltip,
            child: DesktopButtonClickRegion(
              child: TextButton.icon(
                onPressed: open,
                style: TextButton.styleFrom(
                  foregroundColor: AppTokens.text1,
                  textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                icon: Icon(Icons.hub_outlined, size: 20, color: color),
                label: const Text('连接外部 AI'),
              ),
            ),
          );
        }
        return compact
            ? MediaLibraryCompactIconButton(
                icon: Icons.hub_outlined,
                tooltip: tooltip,
                color: color,
                onPressed: open,
              )
            : ResponsiveIconButton(
                icon: Icons.hub_outlined,
                tooltip: tooltip,
                color: color,
                onPressed: open,
              );
      },
    );
  }
}
