import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import '../services/playback_queue_add_service.dart';
import 'media_library_anchor_menu.dart';
import 'media_library_tooltip.dart';
import 'transcription_queue_actions.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// A quiet responsive action. A short checkmark confirms success in place;
/// tapping again during preparation cancels without changing the queue.
class AddToPlaylistButton extends StatefulWidget {
  const AddToPlaylistButton({
    super.key,
    this.iconOnly = false,
    this.label = defaultLabel,
    this.tooltip,
    this.height = 36,
    this.iconSize = 18,
    this.fontSize = 13,
    this.filled = false,
    this.stacked = false,
    this.fitLabel = false,
    this.onAdd,
  });

  static const defaultLabel = '加入播放列表';
  static const icon = Icons.playlist_add_rounded;

  final bool iconOnly;
  final String label;
  final String? tooltip;
  final double height;
  final double iconSize;
  final double fontSize;
  final bool filled;
  final bool stacked;

  /// Selection bars keep their label visible within a fixed action slot.
  final bool fitLabel;
  final Future<QueueAddResult> Function(QueueAddProgress progress)? onAdd;

  @override
  State<AddToPlaylistButton> createState() => _AddToPlaylistButtonState();
}

class _AddToPlaylistButtonState extends State<AddToPlaylistButton> {
  bool _busy = false, _done = false;
  QueueAddProgress? _progress;
  Timer? _confirmation;
  bool get iconOnly => widget.iconOnly;
  String get label => widget.label;
  String? get tooltip => widget.tooltip;
  double get height => widget.height;
  double get iconSize => widget.iconSize;
  double get fontSize => widget.fontSize;
  bool get filled => widget.filled;
  bool get stacked => widget.stacked;
  IconData get icon => _busy
      ? Icons.close_rounded
      : _done
      ? Icons.check_rounded
      : AddToPlaylistButton.icon;

  Future<void> _invoke() async {
    if (_busy) {
      _progress?.cancel();
      return;
    }
    if (widget.onAdd == null) return;
    _confirmation?.cancel();
    final progress = _progress = QueueAddProgress();
    setState(() {
      _busy = true;
      _done = false;
    });
    try {
      final result = await widget.onAdd!(progress);
      if (!mounted) return;
      setState(() => _done = result.completed);
      _confirmation = Timer(const Duration(milliseconds: 900), () {
        if (mounted) setState(() => _done = false);
      });
    } finally {
      _progress = null;
      progress.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _confirmation?.cancel();
    _progress?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(context).textTheme.labelLarge!.copyWith(
      fontSize: fontSize,
      fontWeight: filled ? FontWeight.w600 : FontWeight.w500,
      height: filled ? 1.3 : 1.2,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: label, style: textStyle),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout();
        final labelHeight = stacked
            ? iconSize + 2 + painter.height + 8
            : painter.height + 12;
        final showLabel =
            !iconOnly &&
            (widget.fitLabel ||
                (constraints.maxWidth >=
                        painter.width + (stacked ? 16 : iconSize + 22) &&
                    constraints.maxHeight >= labelHeight));
        final targetHeight = showLabel && !widget.fitLabel
            ? math.max(height, labelHeight)
            : height;
        painter.dispose();
        return MediaLibraryTooltip(
          message: _busy ? '正在整理，点击取消' : tooltip ?? label,
          waitDuration: const Duration(milliseconds: 450),
          excludeFromSemantics: true,
          child: Semantics(
            label: tooltip ?? label,
            button: true,
            onTap: widget.onAdd == null ? null : _invoke,
            excludeSemantics: true,
            child: SizedBox(
              height: targetHeight,
              child: DesktopButtonClickRegion(
                child: TextButton(
                  onPressed: widget.onAdd == null ? null : _invoke,
                  style: TextButton.styleFrom(
                    foregroundColor: filled ? AppTokens.text1 : AppTokens.text2,
                    backgroundColor: filled
                        ? AppTokens.text1.withValues(alpha: 0.045)
                        : Colors.transparent,
                    padding: EdgeInsets.symmetric(
                      horizontal: widget.fitLabel
                          ? 2
                          : showLabel
                          ? 8
                          : 0,
                    ),
                    minimumSize: Size(showLabel ? 0 : 28, height),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.standard,
                    textStyle: textStyle,
                    splashFactory: NoSplash.splashFactory,
                    overlayColor: AppTokens.text1.withValues(alpha: 0.08),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(filled ? 12 : 8),
                    ),
                  ),
                  child: showLabel && stacked
                      ? widget.fitLabel
                            ? Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(icon, size: iconSize),
                                  const SizedBox(height: 2),
                                  SizedBox(
                                    height: 16,
                                    width: double.infinity,
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Text(
                                        label,
                                        maxLines: 1,
                                        softWrap: false,
                                      ),
                                    ),
                                  ),
                                ],
                              )
                            : FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(icon, size: iconSize),
                                    const SizedBox(height: 2),
                                    Text(label, maxLines: 1, softWrap: false),
                                  ],
                                ),
                              )
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(icon, size: iconSize),
                            if (showLabel) ...[
                              const SizedBox(width: 6),
                              Text(label, maxLines: 1, softWrap: false),
                            ],
                          ],
                        ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The same menu row for playable cached-media cards.
class AddToPlaylistOverflowButton extends StatelessWidget {
  const AddToPlaylistOverflowButton({super.key, this.onAdd, this.onTranscribe});
  final Future<void> Function()? onAdd;
  final Future<void> Function()? onTranscribe;

  @override
  Widget build(BuildContext context) => DesktopButtonClickRegion(
    child: MediaLibraryTooltip(
      message: '更多',
      child: IconButton(
        icon: const Icon(
          Icons.more_horiz_rounded,
          size: 20,
          color: AppTokens.text2,
        ),
        onPressed: () async {
          final box = context.findRenderObject();
          final overlay = Navigator.of(
            context,
            rootNavigator: true,
          ).overlay?.context.findRenderObject();
          if (box is! RenderBox || overlay is! RenderBox || !box.hasSize) {
            return;
          }
          final action = await MediaLibraryAnchorMenu.show(
            context: context,
            anchor:
                box.localToGlobal(Offset.zero, ancestor: overlay) & box.size,
            items: [
              if (onTranscribe != null)
                const MediaLibraryAnchorMenuEntry(
                  value: 'transcribe',
                  label: transcriptionQueueLabel,
                  icon: transcriptionQueueIcon,
                ),
              const MediaLibraryAnchorMenuEntry(
                value: 'add_to_playlist',
                label: AddToPlaylistButton.defaultLabel,
                icon: AddToPlaylistButton.icon,
              ),
            ],
          );
          if (action == 'add_to_playlist') await onAdd?.call();
          if (action == 'transcribe') await onTranscribe?.call();
        },
      ),
    ),
  );
}
