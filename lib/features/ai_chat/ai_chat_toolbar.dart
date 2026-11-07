import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'ai_capsule_menu.dart';
import 'ai_chat_typography.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// A compact command band shared by sidebar, portrait panel and fullscreen.
/// Adapt to the panel's own width, rather than the device or window width.
class AiChatToolbar extends StatelessWidget {
  const AiChatToolbar({
    super.key,
    required this.availableHeight,
    required this.title,
    required this.model,
    required this.selectedSources,
    required this.sourceCount,
    required this.sourcesLabel,
    required this.isFullscreen,
    required this.onNew,
    required this.onHistory,
    required this.onSettings,
    required this.onContext,
    required this.onFullscreen,
    required this.contextMeter,
    required this.menu,
    this.onBack,
    this.backLabel = '返回字幕',
    this.onClose,
    this.fullscreenReturnLabel,
    this.leadingCommand,
  });

  final double availableHeight;
  final String title;
  final String model;
  final int selectedSources;
  final int sourceCount;

  /// 「视频资料」「播客资料」or「音频资料」, already chosen for this media.
  final String sourcesLabel;
  final bool isFullscreen;
  final String? fullscreenReturnLabel;
  final VoidCallback? onBack;
  final String backLabel;
  final VoidCallback? onClose;
  final VoidCallback? onNew;
  final VoidCallback? onHistory;
  final VoidCallback? onSettings;
  final VoidCallback? onContext;
  final VoidCallback? onFullscreen;

  /// Fullscreen-only command rendered before the history button. The host
  /// decides whether the surface it controls currently exists.
  final Widget? leadingCommand;
  final Widget Function(bool compact) contextMeter;
  final Widget Function({
    required bool history,
    required bool settings,
    required bool fullscreen,
    required bool sources,
    required bool newConversation,
    required bool close,
  })
  menu;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final colors = Theme.of(context).colorScheme;
      final scaler = MediaQuery.textScalerOf(context);
      final textFactor = math.max(1.0, scaler.scale(13) / 13);
      final width = constraints.maxWidth;
      final leftInset = AiChatTypography.of(context).horizontalInset;
      // Wide enough that a short panel can still keep the status line.
      // The line itself is never placed beside the command buttons.
      final wide = width >= 820 * textFactor;
      final tiny = width < 300 * textFactor;
      final minimal = width < 180;
      final showSettings = !tiny;
      final showMetadata = !minimal && (wide || availableHeight >= 440);
      final showModel = width >= 320 * textFactor;
      final showFullscreen = isFullscreen
          ? fullscreenReturnLabel == null
          : !tiny;
      final showClose = onClose != null && onBack == null && !isFullscreen;

      // Own row, same width as the command row. A side slot capped under the
      // buttons made this line ellipsize while the column beneath them sat empty.
      Widget metadata() => Row(
        key: const ValueKey('ai-chat-toolbar-metadata'),
        children: [
          // Cap against the padded row. Using the full toolbar width let this
          // button grow 2px past the space left for the meter.
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: math.max(120, (width - leftInset - 6) * .55),
            ),
            child: DesktopButtonClickRegion(
              child: TextButton(
                key: const ValueKey('ai-chat-context'),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.standard,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                ),
                onPressed: onContext,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.subtitles_outlined, size: 15),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        '${tiny ? '资料' : sourcesLabel} · $selectedSources/$sourceCount',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (showModel && model.isNotEmpty)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Tooltip(
                  message: model,
                  child: Text(
                    model,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            )
          else
            const Spacer(),
          contextMeter(tiny),
        ],
      );

      return DecoratedBox(
        key: const ValueKey('ai-chat-toolbar'),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: colors.outlineVariant)),
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(leftInset, 2, 6, 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: math.max(kAiToolbarExtent, scaler.scale(15) + 8),
                ),
                child: Flex(
                  key: const ValueKey('ai-chat-toolbar-commands'),
                  direction: minimal ? Axis.vertical : Axis.horizontal,
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: minimal
                      ? CrossAxisAlignment.stretch
                      : CrossAxisAlignment.center,
                  children: [
                    Flexible(
                      flex: minimal ? 0 : 1,
                      fit: FlexFit.tight,
                      child: Row(
                        children: [
                          Expanded(
                            child: Tooltip(
                              key: const ValueKey('ai-chat-toolbar-title'),
                              message: title,
                              child:
                                  width < 560 * textFactor && textFactor <= 1.25
                                  ? Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          'AI 对话',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 15,
                                            height: 1.1,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        Text(
                                          title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 10.5,
                                            height: 1.1,
                                            color: colors.onSurfaceVariant,
                                          ),
                                        ),
                                      ],
                                    )
                                  : Text.rich(
                                      TextSpan(
                                        children: [
                                          const TextSpan(
                                            text: 'AI 对话',
                                            style: TextStyle(
                                              fontSize: 15,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          if (width >= 560 * textFactor)
                                            TextSpan(
                                              text: ' · $title',
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: colors.onSurfaceVariant,
                                              ),
                                            ),
                                        ],
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Keep history and new beside each other at every width.
                    // An extremely narrow sidebar wraps the command group
                    // below its title instead of hiding frequent actions.
                    Wrap(
                      alignment: WrapAlignment.end,
                      children: [
                        ?leadingCommand,
                        aiToolbarIcon(
                          tooltip: '对话历史',
                          icon: Icons.history,
                          onPressed: onHistory,
                        ),
                        aiToolbarIcon(
                          tooltip: '新建对话',
                          icon: Icons.add,
                          onPressed: onNew,
                        ),
                        if (showSettings)
                          aiToolbarIcon(
                            tooltip: 'AI 设置',
                            icon: Icons.tune,
                            onPressed: onSettings,
                          ),
                        menu(
                          history: false,
                          settings: !showSettings,
                          fullscreen: !isFullscreen && !showFullscreen,
                          sources: !showMetadata,
                          newConversation: false,
                          close: onClose != null && !showClose && !isFullscreen,
                        ),
                        if (showFullscreen)
                          aiToolbarIcon(
                            tooltip: isFullscreen ? '退出全屏' : '全屏对话',
                            icon: isFullscreen
                                ? Icons.fullscreen_exit
                                : Icons.fullscreen,
                            onPressed: onFullscreen,
                          ),
                        if (showClose)
                          aiToolbarIcon(
                            tooltip: '关闭 AI 对话',
                            icon: Icons.close,
                            onPressed: onClose,
                          ),
                        if (isFullscreen
                            ? fullscreenReturnLabel != null
                            : onBack != null)
                          aiToolbarIcon(
                            tooltip: isFullscreen
                                ? fullscreenReturnLabel!
                                : backLabel,
                            icon: Icons.arrow_back,
                            onPressed: isFullscreen ? onFullscreen : onBack,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (showMetadata) metadata(),
            ],
          ),
        ),
      );
    },
  );
}
