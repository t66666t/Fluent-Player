import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_interaction_theme.dart';
import '../theme/app_tokens.dart';
import '../utils/clipboard_link.dart';
import '../services/settings_service.dart';
import 'clipboard_detection_control.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

enum ClipboardLinkDestination { browser, download, douyin, podcast }

class ClipboardLinkChoice {
  const ClipboardLinkChoice(this.link, this.destination);
  final ClipboardLink link;
  final ClipboardLinkDestination destination;
}

/// A small native-looking chooser. No preview requests or parsing happen here.
class ClipboardLinkDialog extends StatefulWidget {
  const ClipboardLinkDialog({
    super.key,
    required this.links,
    required this.settings,
    this.title = '剪贴板中的链接',
  });
  final List<ClipboardLink> links;
  final SettingsService settings;
  final String title;

  @override
  State<ClipboardLinkDialog> createState() => _ClipboardLinkDialogState();
}

class _ClipboardLinkDialogState extends State<ClipboardLinkDialog> {
  var _selected = 0;

  @override
  Widget build(BuildContext context) {
    final link = widget.links[_selected];
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final surface = dark ? AppTokens.bgRaised : theme.colorScheme.surface;
    final foreground = dark ? AppTokens.text1 : theme.colorScheme.onSurface;
    final secondary = dark
        ? AppTokens.text2
        : theme.colorScheme.onSurfaceVariant;
    final line = foreground.withValues(alpha: .09);
    final size = MediaQuery.sizeOf(context);
    final insets = MediaQuery.viewInsetsOf(context);
    final padding = MediaQuery.paddingOf(context);
    final maxHeight = math.max(
      0.0,
      size.height - insets.vertical - padding.vertical - 32,
    );
    return Dialog(
      key: const ValueKey('clipboard-link-dialog'),
      insetPadding: const EdgeInsets.all(16),
      constraints: BoxConstraints(maxWidth: 420, maxHeight: maxHeight),
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: .32),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: line),
      ),
      child: SizedBox(
        key: const ValueKey('clipboard-link-surface'),
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            widget.title,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontSize: 16,
                              height: 1.4,
                              fontWeight: FontWeight.w600,
                              color: foreground,
                            ),
                          ),
                          const SizedBox(height: 12),
                          if (widget.links.length > 1) ...[
                            DesktopButtonClickRegion(
                              child: DropdownButton<int>(
                                key: const ValueKey('clipboard-link-selector'),
                                value: _selected,
                                isExpanded: true,
                                underline: const SizedBox.shrink(),
                                dropdownColor: surface,
                                borderRadius: BorderRadius.circular(4),
                                icon: Icon(
                                  Icons.keyboard_arrow_down,
                                  size: 18,
                                  color: secondary,
                                ),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontSize: 12,
                                  height: 1.4,
                                  fontWeight: FontWeight.w500,
                                  color: secondary,
                                ),
                                items: [
                                  for (var i = 0; i < widget.links.length; i++)
                                    DropdownMenuItem(
                                      value: i,
                                      child: Text(
                                        '${i + 1}. ${widget.links[i].label}',
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                ],
                                onChanged: (value) {
                                  if (value != null) {
                                    setState(() => _selected = value);
                                  }
                                },
                              ),
                            ),
                            const SizedBox(height: 4),
                          ] else ...[
                            Text(
                              link.label,
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontSize: 12,
                                height: 1.4,
                                fontWeight: FontWeight.w500,
                                color: secondary,
                              ),
                            ),
                            const SizedBox(height: 4),
                          ],
                          Text(
                            link.url,
                            key: const ValueKey('clipboard-link-url'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontSize: 13,
                              height: 1.5,
                              fontWeight: FontWeight.w400,
                              color: secondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Divider(
                      height: 1,
                      thickness: 1,
                      indent: 20,
                      endIndent: 20,
                      color: line,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (link.kind == ClipboardLinkKind.douyin)
                            _entry(
                              link,
                              ClipboardLinkDestination.douyin,
                              '抖音下载页',
                              Icons.download_outlined,
                            ),
                          if (link.kind == ClipboardLinkKind.podcast ||
                              link.kind == ClipboardLinkKind.feed)
                            _entry(
                              link,
                              ClipboardLinkDestination.podcast,
                              '播客解析页',
                              Icons.podcasts_outlined,
                            ),
                          _entry(
                            link,
                            ClipboardLinkDestination.browser,
                            '浏览器导入',
                            Icons.language_outlined,
                          ),
                          if (link.offersGenericDownload)
                            _entry(
                              link,
                              ClipboardLinkDestination.download,
                              '通用下载页',
                              Icons.download_outlined,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Divider(
              height: 1,
              thickness: 1,
              indent: 20,
              endIndent: 20,
              color: line,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 12, 8),
              child: LayoutBuilder(
                builder: (context, bounds) {
                  final checkbox = ClipboardDetectionCheckbox(
                    settings: widget.settings,
                  );
                  final ignore = DesktopButtonClickRegion(
                    child: TextButton(
                      key: const ValueKey('clipboard-link-ignore'),
                      onPressed: () => Navigator.pop(context),
                      style: _buttonStyle(context).copyWith(
                        foregroundColor: WidgetStatePropertyAll(secondary),
                        minimumSize: const WidgetStatePropertyAll(Size(64, 44)),
                        padding: const WidgetStatePropertyAll(
                          EdgeInsets.symmetric(horizontal: 12),
                        ),
                      ),
                      child: const Text('忽略'),
                    ),
                  );
                  final label = TextPainter(
                    text: TextSpan(
                      text: clipboardDetectionDisableLabel,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                    textDirection: Directionality.of(context),
                    textScaler: MediaQuery.textScalerOf(context),
                  )..layout();
                  final stacked = bounds.maxWidth < label.width + 48 + 64 + 12;
                  label.dispose();
                  if (stacked) {
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        checkbox,
                        Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: ignore,
                        ),
                      ],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(child: checkbox),
                      ignore,
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _entry(
    ClipboardLink link,
    ClipboardLinkDestination destination,
    String title,
    IconData icon,
  ) => DesktopButtonClickRegion(
    child: TextButton(
      key: ValueKey('clipboard-destination-${destination.name}'),
      style: _buttonStyle(context),
      onPressed: () =>
          Navigator.pop(context, ClipboardLinkChoice(link, destination)),
      child: Row(
        children: [
          Icon(
            icon,
            size: 19,
            color: Theme.of(context).brightness == Brightness.dark
                ? AppTokens.text2
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(title)),
          const SizedBox(width: 8),
          Icon(
            Icons.chevron_right,
            size: 16,
            color: Theme.of(context).brightness == Brightness.dark
                ? AppTokens.text3
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    ),
  );

  ButtonStyle _buttonStyle(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = theme.brightness == Brightness.dark
        ? AppTokens.text1
        : theme.colorScheme.onSurface;
    return TextButton.styleFrom(
      foregroundColor: foreground,
      minimumSize: const Size(0, 52),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      alignment: AlignmentDirectional.centerStart,
      textStyle: theme.textTheme.bodyMedium?.copyWith(
        fontSize: 14,
        height: 1.4,
        fontWeight: FontWeight.w400,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      splashFactory: AppPressInk.splashFactory,
    ).copyWith(
      overlayColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.pressed)) return Colors.transparent;
        if (states.contains(WidgetState.focused)) {
          return theme.colorScheme.primary.withValues(alpha: .12);
        }
        if (states.contains(WidgetState.hovered)) {
          return foreground.withValues(alpha: .055);
        }
        return null;
      }),
    );
  }
}
