import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/app_haptics.dart';
import '../services/settings_service.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

const List<double> kPlaybackSpeedPresets = <double>[
  0.25,
  0.5,
  0.75,
  1.0,
  1.25,
  1.5,
  2.0,
  2.5,
  3.0,
  4.0,
  5.0,
];

/// Next picker notch in [direction] (`-1` slower, `+1` faster).
///
/// Off-list rates snap to the adjacent visible notch instead of jumping to
/// the nearest neighbor, matching "one tick on the speed bar". Returns
/// `null` at either end so callers can leave the current rate unchanged.
double? nextPlaybackSpeedPreset(double current, {required int direction}) {
  const epsilon = 0.001;
  if (direction < 0) {
    for (int i = kPlaybackSpeedPresets.length - 1; i >= 0; i--) {
      if (kPlaybackSpeedPresets[i] < current - epsilon) {
        return kPlaybackSpeedPresets[i];
      }
    }
    return null;
  }
  for (int i = 0; i < kPlaybackSpeedPresets.length; i++) {
    if (kPlaybackSpeedPresets[i] > current + epsilon) {
      return kPlaybackSpeedPresets[i];
    }
  }
  return null;
}

/// Formats a playback rate for compact control labels (`1.0`, `1.25`).
String formatPlaybackSpeedLabel(double speed) {
  if (speed == speed.roundToDouble()) return speed.toStringAsFixed(1);
  return speed.toString().replaceFirst(RegExp(r'0+$'), '');
}

/// Invisible width probe so two-digit rates like `1.0x` keep the same slot as
/// three-digit rates like `1.25x`, avoiding control-bar layout jumps.
const String kPlaybackSpeedWidthProbe = '1.25x';

/// Control-bar speed text that reserves a stable width across common rates.
class PlaybackSpeedText extends StatelessWidget {
  const PlaybackSpeedText({
    super.key,
    required this.speed,
    required this.style,
    this.maxLines = 1,
    this.overflow = TextOverflow.fade,
    this.textAlign = TextAlign.center,
  });

  final double speed;
  final TextStyle style;
  final int maxLines;
  final TextOverflow overflow;
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context) {
    final labelStyle = style.copyWith(
      fontFeatures: <FontFeature>[
        ...?style.fontFeatures,
        const FontFeature.tabularFigures(),
      ],
    );
    return Stack(
      alignment: Alignment.center,
      children: [
        // Reserve the three-digit rate width even when the visible label is shorter.
        ExcludeSemantics(
          child: Text(
            kPlaybackSpeedWidthProbe,
            maxLines: maxLines,
            softWrap: false,
            style: labelStyle.copyWith(color: const Color(0x00000000)),
          ),
        ),
        Text(
          '${formatPlaybackSpeedLabel(speed)}x',
          maxLines: maxLines,
          overflow: overflow,
          softWrap: false,
          textAlign: textAlign,
          style: labelStyle,
        ),
      ],
    );
  }
}

Future<void> showPlaybackSpeedDialog({
  required BuildContext context,
  BuildContext? anchorContext,
  required double initialSpeed,
  required SettingsService settings,
  required Future<void> Function(double speed) onSpeedSelected,
}) {
  final anchorRect = _resolveGlobalBounds(anchorContext);
  final screenSize = MediaQuery.sizeOf(context);
  final anchorAlignment = anchorRect == null
      ? Alignment.center
      : Alignment(
          ((anchorRect.center.dx / math.max(1, screenSize.width)) * 2 - 1)
              .clamp(-1.0, 1.0),
          ((anchorRect.center.dy / math.max(1, screenSize.height)) * 2 - 1)
              .clamp(-1.0, 1.0),
        );

  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭倍速选择',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 150),
    pageBuilder: (dialogContext, _, _) => PlaybackSpeedDialog(
      initialSpeed: initialSpeed,
      settings: settings,
      onSpeedSelected: onSpeedSelected,
      anchorRect: anchorRect,
    ),
    transitionBuilder: (_, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          alignment: anchorAlignment,
          scale: Tween<double>(begin: 0.94, end: 1).animate(curved),
          child: child,
        ),
      );
    },
  );
}

Rect? _resolveGlobalBounds(BuildContext? context) {
  if (context == null) return null;
  final renderObject = context.findRenderObject();
  if (renderObject is! RenderBox ||
      !renderObject.attached ||
      !renderObject.hasSize) {
    return null;
  }
  return renderObject.localToGlobal(Offset.zero) & renderObject.size;
}

class PlaybackSpeedDialog extends StatefulWidget {
  const PlaybackSpeedDialog({
    super.key,
    required this.initialSpeed,
    required this.settings,
    required this.onSpeedSelected,
    this.anchorRect,
  });

  final double initialSpeed;
  final SettingsService settings;
  final Future<void> Function(double speed) onSpeedSelected;
  final Rect? anchorRect;

  @override
  State<PlaybackSpeedDialog> createState() => _PlaybackSpeedDialogState();
}

class _PlaybackSpeedDialogState extends State<PlaybackSpeedDialog> {
  late double _selectedSpeed;
  late List<double> _speeds;
  bool _lockOperationInProgress = false;
  int _selectionRequestId = 0;

  @override
  void initState() {
    super.initState();
    _selectedSpeed = widget.initialSpeed;
    _speeds = List<double>.of(kPlaybackSpeedPresets);
    _ensureSpeedIsVisible(_selectedSpeed);
    if (widget.settings.isPlaybackSpeedLocked) {
      _ensureSpeedIsVisible(widget.settings.playbackSpeed);
    }
    widget.settings.addListener(_handleSettingsChanged);
  }

  @override
  void dispose() {
    widget.settings.removeListener(_handleSettingsChanged);
    super.dispose();
  }

  bool _isSameSpeed(double first, double second) =>
      (first - second).abs() < 0.001;

  void _ensureSpeedIsVisible(double speed) {
    if (_speeds.any((candidate) => _isSameSpeed(candidate, speed))) return;
    _speeds.add(speed);
    _speeds.sort();
  }

  void _handleSettingsChanged() {
    if (!mounted) return;
    if (widget.settings.isPlaybackSpeedLocked) {
      _ensureSpeedIsVisible(widget.settings.playbackSpeed);
    }
    setState(() {});
  }

  Future<void> _selectSpeed(double speed) async {
    if (_isSameSpeed(speed, _selectedSpeed)) return;
    unawaited(AppHaptics.selectionClick(widget.settings));
    final previousSpeed = _selectedSpeed;
    final requestId = ++_selectionRequestId;
    setState(() => _selectedSpeed = speed);
    try {
      await widget.onSpeedSelected(speed);
    } catch (_) {
      if (!mounted || requestId != _selectionRequestId) return;
      setState(() => _selectedSpeed = previousSpeed);
      _showOperationError('切换倍速失败，请重试');
    }
  }

  Future<void> _setSpeedLocked(double speed, bool locked) async {
    if (_lockOperationInProgress) return;
    setState(() => _lockOperationInProgress = true);
    try {
      await widget.settings.setPlaybackSpeedLock(speed, locked);
    } catch (_) {
      if (mounted) _showOperationError('保存全局倍速失败，请重试');
    } finally {
      if (mounted) setState(() => _lockOperationInProgress = false);
    }
  }

  void _showOperationError(String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final screenSize = mediaQuery.size;
    final padding = mediaQuery.padding;
    final availableWidth = math.max(
      0.0,
      screenSize.width - padding.left - padding.right - 16,
    );
    final availableHeight = math.max(
      0.0,
      screenSize.height - padding.top - padding.bottom - 16,
    );
    final popoverWidth = math.min(218.0, availableWidth);
    final preferredHeight = math.min(330.0, availableHeight);
    final placement = _resolvePlacement(
      screenSize: screenSize,
      padding: padding,
      width: popoverWidth,
      preferredHeight: preferredHeight,
    );

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned(
            left: placement.left,
            top: placement.top,
            width: popoverWidth,
            height: placement.height,
            child: Semantics(
              namesRoute: true,
              label: '播放倍速',
              child: Material(
                key: const ValueKey('playback-speed-popover'),
                color: const Color(0xFF202124),
                elevation: 14,
                shadowColor: Colors.black87,
                borderRadius: BorderRadius.circular(12),
                clipBehavior: Clip.antiAlias,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.09),
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      _buildHeader(context),
                      Divider(
                        height: 1,
                        thickness: 1,
                        color: Colors.white.withValues(alpha: 0.07),
                      ),
                      Expanded(
                        child: ListView.separated(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 6,
                          ),
                          itemCount: _speeds.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 2),
                          itemBuilder: (context, index) {
                            final speed = _speeds[index];
                            return _buildSpeedItem(
                              speed,
                              isSelected: _isSameSpeed(speed, _selectedSpeed),
                              isLocked: widget.settings.isLockedPlaybackSpeed(
                                speed,
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  _PopoverPlacement _resolvePlacement({
    required Size screenSize,
    required EdgeInsets padding,
    required double width,
    required double preferredHeight,
  }) {
    const gap = 6.0;
    const edgeGap = 8.0;
    final anchor = widget.anchorRect;
    final minLeft = padding.left + edgeGap;
    final maxLeft = math.max(
      minLeft,
      screenSize.width - padding.right - edgeGap - width,
    );

    if (anchor == null) {
      return _PopoverPlacement(
        left: ((screenSize.width - width) / 2).clamp(minLeft, maxLeft),
        top:
            padding.top +
            (screenSize.height - padding.vertical - preferredHeight) / 2,
        height: preferredHeight,
      );
    }

    final spaceAbove = math.max(0.0, anchor.top - padding.top - edgeGap - gap);
    final spaceBelow = math.max(
      0.0,
      screenSize.height - padding.bottom - edgeGap - anchor.bottom - gap,
    );
    final openBelow =
        spaceBelow >= math.min(240.0, preferredHeight) ||
        spaceBelow >= spaceAbove;
    final chosenSpace = openBelow ? spaceBelow : spaceAbove;
    final useAnchoredPlacement = chosenSpace >= 140;
    final height = useAnchoredPlacement
        ? math.min(preferredHeight, chosenSpace)
        : preferredHeight;
    final left = (anchor.center.dx - width / 2).clamp(minLeft, maxLeft);
    final top = useAnchoredPlacement
        ? openBelow
              ? anchor.bottom + gap
              : anchor.top - gap - height
        : padding.top +
              (screenSize.height - padding.vertical - preferredHeight) / 2;

    return _PopoverPlacement(left: left, top: top, height: height);
  }

  Widget _buildHeader(BuildContext context) {
    final isLocked = widget.settings.isPlaybackSpeedLocked;
    return SizedBox(
      height: 42,
      child: Padding(
        padding: const EdgeInsets.only(left: 11, right: 3),
        child: Row(
          children: [
            const Icon(Icons.speed, size: 17, color: Colors.blueAccent),
            const SizedBox(width: 7),
            const Expanded(
              child: Text(
                '播放倍速',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (isLocked)
              Container(
                constraints: const BoxConstraints(maxWidth: 62),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.blueAccent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.lock_outline,
                      size: 11,
                      color: Colors.blueAccent,
                    ),
                    const SizedBox(width: 3),
                    Flexible(
                      child: Text(
                        '${_formatSpeed(widget.settings.playbackSpeed)}x',
                        maxLines: 1,
                        overflow: TextOverflow.fade,
                        style: const TextStyle(
                          color: Colors.blueAccent,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            SizedBox(
              width: 32,
              height: 32,
              child: DesktopButtonClickRegion(
                child: IconButton(
                  tooltip: '关闭',
                  padding: EdgeInsets.zero,
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(
                    Icons.close,
                    color: Colors.white54,
                    size: 17,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSpeedItem(
    double speed, {
    required bool isSelected,
    required bool isLocked,
  }) {
    final showCheckbox = isSelected || isLocked;
    return AnimatedContainer(
      key: ValueKey('playback-speed-item-$speed'),
      duration: const Duration(milliseconds: 130),
      curve: Curves.easeOutCubic,
      height: 36,
      decoration: BoxDecoration(
        color: isSelected
            ? Colors.blueAccent.withValues(alpha: 0.15)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isSelected
              ? Colors.blueAccent.withValues(alpha: 0.55)
              : Colors.transparent,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => unawaited(_selectSpeed(speed)),
        child: Padding(
          padding: const EdgeInsets.only(left: 10, right: 2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${_formatSpeed(speed)}x',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isSelected ? Colors.white : Colors.white70,
                    fontSize: 13,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              if (isSelected)
                Padding(
                  padding: const EdgeInsets.only(right: 3),
                  child: Text(
                    '当前',
                    style: TextStyle(
                      color: Colors.blueAccent.shade100,
                      fontSize: 9,
                    ),
                  ),
                ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 120),
                child: showCheckbox
                    ? SizedBox(
                        key: ValueKey('speed-checkbox-$speed'),
                        width: 32,
                        height: 32,
                        child: Checkbox(
                          value: isLocked,
                          onChanged: _lockOperationInProgress
                              ? null
                              : (value) => unawaited(
                                  _setSpeedLocked(speed, value ?? false),
                                ),
                          activeColor: Colors.blueAccent,
                          checkColor: Colors.white,
                          side: const BorderSide(
                            color: Colors.white54,
                            width: 1.25,
                          ),
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatSpeed(double speed) => formatPlaybackSpeedLabel(speed);
}

class _PopoverPlacement {
  const _PopoverPlacement({
    required this.left,
    required this.top,
    required this.height,
  });

  final double left;
  final double top;
  final double height;
}
