import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/media_library_view_mode.dart';
import '../services/settings_service.dart';
import '../theme/app_tokens.dart';
import '../utils/desktop_media_management_shortcuts.dart';
import 'anchored_menu_layout.dart';
import 'desktop_button_click_region.dart';
import 'media_library_compact_app_bar.dart';
import 'media_library_layout_profile.dart';
import 'media_library_style_sheet.dart';

/// Top-bar control that opens the four-way media-library view style picker.
class MediaLibraryViewModeButton extends StatelessWidget {
  const MediaLibraryViewModeButton({super.key, this.compact = false});

  final bool compact;

  static IconData iconFor(MediaLibraryViewMode mode) => switch (mode) {
    MediaLibraryViewMode.grid => Icons.grid_view_rounded,
    MediaLibraryViewMode.rows => Icons.view_agenda_rounded,
    MediaLibraryViewMode.table => Icons.table_rows_rounded,
    MediaLibraryViewMode.tree => Icons.account_tree_rounded,
  };

  static const Key buttonKey = ValueKey('media-library-view-mode-button');

  static Key optionKey(MediaLibraryViewMode mode) =>
      ValueKey('media-library-view-mode-option-${mode.name}');

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final mode = settings.mediaLibraryViewStyle;
    final tooltip = DesktopMediaManagementShortcuts.buildTooltip(
      '切换视图风格',
      DesktopMediaManagementShortcutAction.toggleViewMode,
      context: context,
    );

    final iconChild = AnimatedSwitcher(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 200),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeOutCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(scale: animation, child: child),
      ),
      child: Icon(
        iconFor(mode),
        key: ValueKey<String>(mode.name),
        color: AppTokens.text2,
      ),
    );

    void openMenu() => unawaited(_showViewModeMenu(context: context));

    if (compact) {
      return Semantics(
        button: true,
        label: tooltip,
        child: SizedBox(
          key: buttonKey,
          width: 40,
          child: DesktopButtonClickRegion(
            child: IconButton(
              onPressed: openMenu,
              tooltip: tooltip,
              icon: iconChild,
              iconSize: 21,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 40, height: 48),
              splashRadius: 20,
            ),
          ),
        ),
      );
    }

    return Semantics(
      button: true,
      label: tooltip,
      child: DesktopButtonClickRegion(
        child: IconButton(
          key: buttonKey,
          tooltip: tooltip,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 36, height: 36),
          onPressed: openMenu,
          icon: iconChild,
        ),
      ),
    );
  }
}

Future<void> _showViewModeMenu({required BuildContext context}) {
  final width = MediaQuery.sizeOf(context).width;
  if (width < mediaLibraryCompactTopBarBreakpoint) {
    return showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: AppTokens.bgRaised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (sheetContext) => _ViewModeSheetBody(
        key: const ValueKey('media-library-view-mode-sheet'),
        anchorContext: context,
      ),
    );
  }

  final anchor = AnchoredMenuPosition.fromContext(context);
  final themes = InheritedTheme.capture(
    from: context,
    to: Navigator.of(context, rootNavigator: true).context,
  );
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭视图风格菜单',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (_, _, _) => themes.wrap(
      _ViewModeAnchoredMenu(anchor: anchor, anchorContext: context),
    ),
    transitionBuilder: (_, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
          alignment: Alignment.topCenter,
          child: child,
        ),
      );
    },
  );
}

class _ViewModeAnchoredMenu extends StatelessWidget {
  const _ViewModeAnchoredMenu({
    required this.anchor,
    required this.anchorContext,
  });

  final AnchoredMenuPosition anchor;
  final BuildContext anchorContext;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.of(context).pop(),
        },
        child: AnchoredMenuLayout(
          position: anchor,
          width: 320,
          child: _ViewModeMenuPanel(
            onClose: () => Navigator.of(context).pop(),
            styleSheetContext: anchorContext,
          ),
        ),
      ),
    );
  }
}

class _ViewModeSheetBody extends StatelessWidget {
  const _ViewModeSheetBody({super.key, required this.anchorContext});

  final BuildContext anchorContext;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 8, 12, 12 + bottom),
      child: _ViewModeMenuPanel(
        onClose: () => Navigator.of(context).pop(),
        styleSheetContext: anchorContext,
        isBottomSheet: true,
      ),
    );
  }
}

class _ViewModeMenuPanel extends StatelessWidget {
  const _ViewModeMenuPanel({
    required this.onClose,
    required this.styleSheetContext,
    this.isBottomSheet = false,
  });

  final VoidCallback onClose;
  final BuildContext styleSheetContext;
  final bool isBottomSheet;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final current = settings.mediaLibraryViewStyle;

    Future<void> select(MediaLibraryViewMode mode) async {
      if (mode != current) {
        await settings.setMediaLibraryViewStyle(mode);
      }
      onClose();
    }

    return Material(
      color: isBottomSheet ? Colors.transparent : AppTokens.bgOverlay,
      elevation: isBottomSheet ? 0 : 8,
      shadowColor: Colors.black,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(isBottomSheet ? 0 : 12),
        side: BorderSide(
          color: isBottomSheet ? Colors.transparent : const Color(0x14FFFFFF),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.all(isBottomSheet ? 0 : 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (isBottomSheet)
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: AppTokens.text4,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                isBottomSheet ? 6 : 8,
                isBottomSheet ? 0 : 4,
                8,
                8,
              ),
              child: Text(
                '视图风格',
                style: TextStyle(
                  color: AppTokens.text3,
                  fontSize: isBottomSheet ? 13 : 11.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                ),
              ),
            ),
            for (final mode in MediaLibraryViewMode.values)
              _ViewModeMenuRow(
                key: MediaLibraryViewModeButton.optionKey(mode),
                mode: mode,
                selected: mode == current,
                comfortable: isBottomSheet,
                onTap: () => select(mode),
              ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Divider(height: 1, color: Color(0x12FFFFFF)),
            ),
            _MenuActionRow(
              key: const ValueKey('media-library-view-mode-adjust-style'),
              comfortable: isBottomSheet,
              icon: Icons.tune_rounded,
              label: '调整${current.label}样式…',
              onTap: () {
                onClose();
                unawaited(
                  MediaLibraryStyleSheet.show(
                    context: styleSheetContext,
                    scope: MediaLibraryCardStyleScope.home,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ViewModeMenuRow extends StatefulWidget {
  const _ViewModeMenuRow({
    super.key,
    required this.mode,
    required this.selected,
    required this.onTap,
    this.comfortable = false,
  });

  final MediaLibraryViewMode mode;
  final bool selected;
  final VoidCallback onTap;

  /// Bottom sheets get taller touch targets than the desktop popover.
  final bool comfortable;

  @override
  State<_ViewModeMenuRow> createState() => _ViewModeMenuRowState();
}

class _ViewModeMenuRowState extends State<_ViewModeMenuRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final motion = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 160);
    final selected = widget.selected;
    final Color bg;
    if (selected) {
      bg = AppTokens.accent.withValues(alpha: 0.12);
    } else if (_hovered) {
      bg = const Color(0x0DFFFFFF);
    } else {
      bg = const Color(0x00FFFFFF);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedContainer(
          duration: motion,
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              hoverColor: Colors.transparent,
              splashColor: AppTokens.accent.withValues(alpha: 0.10),
              onTap: widget.onTap,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: widget.comfortable ? 10 : 7,
                ),
                child: Row(
                  children: [
                    _ViewModeThumbnail(
                      mode: widget.mode,
                      selected: selected,
                      hovered: _hovered,
                      motion: motion,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.mode.label,
                            style: TextStyle(
                              color: AppTokens.text1,
                              fontSize: widget.comfortable ? 14.5 : 13.5,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            widget.mode.description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppTokens.text3,
                              fontSize: widget.comfortable ? 12 : 11.5,
                              height: 1.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    AnimatedScale(
                      duration: motion,
                      curve: Curves.easeOutCubic,
                      scale: selected ? 1 : 0.6,
                      child: AnimatedOpacity(
                        duration: motion,
                        curve: Curves.easeOutCubic,
                        opacity: selected ? 1 : 0,
                        child: const Icon(
                          Icons.check_rounded,
                          size: 18,
                          color: AppTokens.accent,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuActionRow extends StatelessWidget {
  const _MenuActionRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.comfortable = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool comfortable;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        hoverColor: const Color(0x0DFFFFFF),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 10,
            vertical: comfortable ? 12 : 9,
          ),
          child: Row(
            children: [
              Icon(icon, color: AppTokens.text2, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: AppTokens.text1,
                    fontSize: comfortable ? 14.5 : 13.5,
                  ),
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                color: AppTokens.text3,
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Miniature of each layout, drawn like a tiny screenshot of the real view.
class _ViewModeThumbnail extends StatelessWidget {
  const _ViewModeThumbnail({
    required this.mode,
    required this.selected,
    required this.hovered,
    required this.motion,
  });

  final MediaLibraryViewMode mode;
  final bool selected;
  final bool hovered;
  final Duration motion;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: motion,
      curve: Curves.easeOutCubic,
      width: 56,
      height: 40,
      decoration: BoxDecoration(
        color: const Color(0xFF161616),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: selected
              ? AppTokens.accent.withValues(alpha: 0.7)
              : hovered
              ? const Color(0x29FFFFFF)
              : const Color(0x17FFFFFF),
        ),
      ),
      child: CustomPaint(
        painter: _ViewModePreviewPainter(mode: mode, selected: selected),
      ),
    );
  }
}

class _ViewModePreviewPainter extends CustomPainter {
  const _ViewModePreviewPainter({required this.mode, required this.selected});

  final MediaLibraryViewMode mode;
  final bool selected;

  @override
  void paint(Canvas canvas, Size size) {
    final cover = Paint()
      ..color = selected
          ? AppTokens.accent.withValues(alpha: 0.55)
          : const Color(0xFF4A4A48);
    final text = Paint()..color = const Color(0xFF5E5D5B);
    final faint = Paint()..color = const Color(0xFF353533);
    final accent = Paint()..color = AppTokens.accent;

    void box(
      double x,
      double y,
      double w,
      double h,
      Paint p, [
      double r = 1.5,
    ]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), Radius.circular(r)),
        p,
      );
    }

    const pad = 6.0;
    final inner = size.width - pad * 2;
    switch (mode) {
      case MediaLibraryViewMode.grid:
        const cols = 3;
        const gap = 3.0;
        final w = (inner - gap * (cols - 1)) / cols;
        final h = w * 0.62;
        for (var r = 0; r < 2; r++) {
          for (var c = 0; c < cols; c++) {
            final x = pad + c * (w + gap);
            final y = pad + r * (h + 6.5);
            box(x, y, w, h, cover);
            box(x, y + h + 1.5, w * 0.8, 2, text, 1);
          }
        }
      case MediaLibraryViewMode.rows:
        const rowH = 7.5;
        for (var i = 0; i < 3; i++) {
          final y = pad - 1 + i * (rowH + 3);
          box(pad, y, rowH * 16 / 9, rowH, cover);
          final tx = pad + rowH * 16 / 9 + 3;
          box(tx, y + 0.5, inner - (tx - pad) - 2, 2.2, text, 1);
          box(tx, y + 4, (inner - (tx - pad)) * 0.55, 1.8, faint, 1);
          if (i == 0) box(pad, y + rowH - 1.2, rowH * 1.1, 1.2, accent, 0.6);
        }
      case MediaLibraryViewMode.table:
        box(pad, pad, inner, 2.2, faint, 1);
        for (var i = 0; i < 4; i++) {
          final y = pad + 5 + i * 6.2;
          box(pad, y, 5, 3.5, cover, 1);
          box(pad + 7, y + 0.8, inner * 0.38, 2, text, 1);
          box(pad + inner * 0.62, y + 0.8, inner * 0.14, 2, faint, 1);
          box(pad + inner * 0.82, y + 0.8, inner * 0.18, 2, faint, 1);
          if (i < 3) {
            canvas.drawRect(
              Rect.fromLTWH(pad, y + 5, inner, 0.6),
              Paint()..color = const Color(0x14FFFFFF),
            );
          }
        }
      case MediaLibraryViewMode.tree:
        final sideW = inner * 0.34;
        box(pad - 2, pad - 2, sideW + 2, size.height - pad * 2 + 4, faint, 2);
        for (var i = 0; i < 4; i++) {
          final indent = i == 0 ? 0.0 : (i == 3 ? 4.0 : 2.0);
          final y = pad + 1 + i * 6;
          box(pad + indent, y, 2.6, 2.6, i == 1 ? accent : cover, 0.6);
          box(pad + indent + 4, y + 0.4, sideW - indent - 6, 1.8, text, 1);
        }
        final cx = pad + sideW + 3;
        final cw = inner - sideW - 3;
        box(cx, pad, cw * 0.6, 1.8, faint, 1);
        for (var r = 0; r < 2; r++) {
          for (var c = 0; c < 2; c++) {
            final w = (cw - 2.5) / 2;
            box(cx + c * (w + 2.5), pad + 4 + r * 11, w, 8.5, cover);
          }
        }
    }
  }

  @override
  bool shouldRepaint(_ViewModePreviewPainter oldDelegate) =>
      oldDelegate.mode != mode || oldDelegate.selected != selected;
}
