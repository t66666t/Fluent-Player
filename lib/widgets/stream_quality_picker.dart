import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/app_haptics.dart';
import '../services/bilibili/bilibili_streaming_service.dart';
import '../services/settings_service.dart';
import 'player_control_metrics.dart';
import 'capsule_option.dart';
import '../features/media_cache/media_cache_models.dart';
import '../features/media_cache/media_cache_widgets.dart';

/// Same chrome as the progress-bar quality capsule.
const Color kStreamQualityPillFill = Color(0xD9222222);

Future<int?> showStreamQualityPicker({
  required BuildContext context,
  BuildContext? anchorContext,
  required List<BilibiliStreamQuality> qualities,
  required int? selectedId,
  required PlayerControlMetrics metrics,
  double? minWidth,
  CacheSource? cacheSource,
  String title = '清晰度',
  String controlName = 'quality',
  Color? selectedColor,
}) {
  if (qualities.isEmpty) return Future<int?>.value();

  final anchorRect = _resolveGlobalBounds(anchorContext);
  final screenSize = MediaQuery.sizeOf(context);
  final anchorAlignment = anchorRect == null
      ? Alignment.bottomRight
      : Alignment(
          ((anchorRect.center.dx / math.max(1, screenSize.width)) * 2 - 1)
              .clamp(-1.0, 1.0),
          ((anchorRect.bottom / math.max(1, screenSize.height)) * 2 - 1).clamp(
            -1.0,
            1.0,
          ),
        );

  return showGeneralDialog<int>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭$title选择',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 140),
    pageBuilder: (dialogContext, _, _) => StreamQualityPicker(
      qualities: qualities,
      selectedId: selectedId,
      metrics: metrics,
      minWidth: minWidth,
      anchorRect: anchorRect,
      cacheSource: cacheSource,
      title: title,
      controlName: controlName,
      selectedColor: selectedColor,
    ),
    transitionBuilder: (_, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          alignment: anchorAlignment,
          scale: Tween<double>(begin: 0.92, end: 1).animate(curved),
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

class StreamQualityPicker extends StatelessWidget {
  const StreamQualityPicker({
    super.key,
    required this.qualities,
    required this.selectedId,
    required this.metrics,
    this.minWidth,
    this.anchorRect,
    this.cacheSource,
    this.title = '清晰度',
    this.controlName = 'quality',
    this.selectedColor,
  });

  final List<BilibiliStreamQuality> qualities;
  final int? selectedId;
  final PlayerControlMetrics metrics;
  final double? minWidth;
  final Rect? anchorRect;
  final CacheSource? cacheSource;
  final String title;
  final String controlName;
  final Color? selectedColor;

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final screenSize = mediaQuery.size;
    final padding = mediaQuery.padding;
    final itemHeight = cacheSource == null ? metrics.chapterButtonHeight : math.max(48.0, metrics.chapterButtonHeight);
    final radius = itemHeight / 2;
    final width = _resolveWidth(screenSize: screenSize, padding: padding);
    final maxHeight = math.max(
      itemHeight,
      screenSize.height - padding.top - padding.bottom - 16,
    );
    final contentHeight = itemHeight * qualities.length;
    final height = math.min(contentHeight, maxHeight);
    final placement = _resolvePlacement(
      screenSize: screenSize,
      padding: padding,
      width: width,
      height: height,
    );

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned(
            left: placement.dx,
            top: placement.dy,
            width: width,
            height: height,
            child: Semantics(
              namesRoute: true,
              label: title,
              child: Material(
                key: ValueKey('video-controls-$controlName-picker'),
                color: kStreamQualityPillFill,
                elevation: 2,
                shadowColor: Colors.black.withValues(alpha: 0.5),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(radius),
                  side: BorderSide(
                    color: Colors.white.withValues(alpha: 0.16),
                    width: 0.75,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  physics: contentHeight > height
                      ? const ClampingScrollPhysics()
                      : const NeverScrollableScrollPhysics(),
                  itemCount: qualities.length,
                  itemExtent: itemHeight,
                  itemBuilder: (context, index) {
                    final quality = qualities[index];
                    final selected = quality.id == selectedId;
                    return Padding(
                      padding: const EdgeInsets.all(3),
                      child: CapsuleOption(
                        color: selected
                            ? Colors.white.withValues(alpha: 0.12)
                            : Colors.transparent,
                        onTap: () {
                          if (quality.id != selectedId) {
                            unawaited(
                              AppHaptics.selectionClick(SettingsService()),
                            );
                          }
                          Navigator.of(context).pop(quality.id);
                        },
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: math.max(
                              0,
                              metrics.progressPillHorizontalPadding - 3,
                            ),
                          ),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Row(children: [Expanded(child: Text(
                              quality.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: selected && selectedColor != null
                                    ? selectedColor
                                    : Colors.white.withValues(
                                        alpha: selected ? 1 : 0.72,
                                      ),
                                fontSize: metrics.progressPillFontSize,
                                fontWeight: FontWeight.w600,
                              ),
                            )),
                              if (cacheSource != null && quality.id > 0)
                                CacheQualityAction(source: cacheSource!, qualityId: '${quality.id}', compact: true),
                            ]),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  double _resolveWidth({
    required Size screenSize,
    required EdgeInsets padding,
  }) {
    final available = math.max(
      0.0,
      screenSize.width - padding.left - padding.right - 16,
    );
    final anchorWidth = anchorRect?.width;
    if (cacheSource != null) return math.min(available, 300);
    if (anchorWidth != null && anchorWidth > 0) {
      return math.min(math.max(anchorWidth, minWidth ?? 0), available);
    }
    return math.min(available, 160);
  }

  Offset _resolvePlacement({
    required Size screenSize,
    required EdgeInsets padding,
    required double width,
    required double height,
  }) {
    const gap = 6.0;
    const edgeGap = 8.0;
    final minLeft = padding.left + edgeGap;
    final maxLeft = math.max(
      minLeft,
      screenSize.width - padding.right - edgeGap - width,
    );
    final minTop = padding.top + edgeGap;
    final maxTop = math.max(
      minTop,
      screenSize.height - padding.bottom - edgeGap - height,
    );

    final anchor = anchorRect;
    if (anchor == null) {
      return Offset(maxLeft, maxTop);
    }

    // Keep the menu the same width and right edge as the capsule, opening
    // upward so it does not cover the next-episode controls.
    var left = (anchor.right - width).clamp(minLeft, maxLeft);
    var top = anchor.top - gap - height;
    if (top < minTop) {
      top = math.min(maxTop, anchor.bottom + gap);
    }
    return Offset(left.toDouble(), top.clamp(minTop, maxTop).toDouble());
  }
}
