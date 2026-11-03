import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/app_haptics.dart';
import '../services/settings_service.dart';
import 'capsule_option.dart';

/// 和播放页清晰度菜单同一套底色。字幕行的操作从这里弹出，不再走底部操作表。
const Color _menuFill = Color(0xD9222222);

class SubtitleRowAction {
  const SubtitleRowAction({
    required this.label,
    required this.onSelected,
    this.destructive = false,
  });

  final String label;
  final VoidCallback onSelected;
  final bool destructive;
}

/// 字幕行右侧的三个点。菜单锚在这颗按钮上，而不是从屏幕底部升起。
class SubtitleRowActionMenuButton extends StatelessWidget {
  const SubtitleRowActionMenuButton({super.key, required this.actions});

  final List<SubtitleRowAction> actions;

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: const Size(32, 32),
      onPressed: actions.isEmpty
          ? null
          : () => showSubtitleRowActionMenu(
              context: context,
              anchorContext: context,
              actions: actions,
            ),
      child: const Icon(
        CupertinoIcons.ellipsis,
        color: Colors.white60,
        size: 22,
      ),
    );
  }
}

Future<void> showSubtitleRowActionMenu({
  required BuildContext context,
  required BuildContext anchorContext,
  required List<SubtitleRowAction> actions,
}) {
  if (actions.isEmpty) return Future<void>.value();

  final anchorRect = _resolveGlobalBounds(anchorContext);
  final screenSize = MediaQuery.sizeOf(context);
  final anchorAlignment = anchorRect == null
      ? Alignment.topRight
      : Alignment(
          ((anchorRect.center.dx / math.max(1, screenSize.width)) * 2 - 1)
              .clamp(-1.0, 1.0),
          ((anchorRect.center.dy / math.max(1, screenSize.height)) * 2 - 1)
              .clamp(-1.0, 1.0),
        );

  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭字幕操作',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 140),
    pageBuilder: (dialogContext, _, _) =>
        SubtitleRowActionMenu(actions: actions, anchorRect: anchorRect),
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

Rect? _resolveGlobalBounds(BuildContext context) {
  final renderObject = context.findRenderObject();
  if (renderObject is! RenderBox ||
      !renderObject.attached ||
      !renderObject.hasSize) {
    return null;
  }
  return renderObject.localToGlobal(Offset.zero) & renderObject.size;
}

class SubtitleRowActionMenu extends StatelessWidget {
  const SubtitleRowActionMenu({
    super.key,
    required this.actions,
    this.anchorRect,
  });

  final List<SubtitleRowAction> actions;
  final Rect? anchorRect;

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final screenSize = mediaQuery.size;
    final padding = mediaQuery.padding;
    final scale = mediaQuery.textScaler.scale(1);
    final itemHeight = (36 * scale).clamp(34.0, 56.0);
    final radius = itemHeight / 2;
    final width = _resolveWidth(
      context: context,
      screenSize: screenSize,
      padding: padding,
      scale: scale,
    );
    final height = itemHeight * actions.length;
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
              label: '字幕操作',
              child: Material(
                key: const ValueKey('subtitle-row-action-menu'),
                color: _menuFill,
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
                child: Column(
                  children: [
                    for (final action in actions)
                      SizedBox(
                        height: itemHeight,
                        child: Padding(
                          padding: const EdgeInsets.all(3),
                          child: CapsuleOption(
                            onTap: () {
                              unawaited(
                                AppHaptics.selectionClick(SettingsService()),
                              );
                              Navigator.of(context).pop();
                              action.onSelected();
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                              ),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  action.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: action.destructive
                                        ? const Color(0xFFFF8A80)
                                        : Colors.white.withValues(alpha: 0.92),
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  double _resolveWidth({
    required BuildContext context,
    required Size screenSize,
    required EdgeInsets padding,
    required double scale,
  }) {
    final available = math.max(
      0.0,
      screenSize.width - padding.left - padding.right - 16,
    );
    const style = TextStyle(fontSize: 13, fontWeight: FontWeight.w600);
    var longest = 0.0;
    for (final action in actions) {
      final painter = TextPainter(
        text: TextSpan(text: action.label, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      if (painter.width > longest) longest = painter.width;
    }
    // 胶囊左右留白，再让菜单至少比三个点宽，避免贴着按钮缩成一条。
    final desired = math.max(132 * scale, longest + 44);
    return math.min(available, desired.clamp(132.0, 220.0));
  }

  /// 优先在按钮下方展开；贴底时翻到上方，右缘和三个点对齐。
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
      return Offset(maxLeft, minTop);
    }

    var left = (anchor.right - width).clamp(minLeft, maxLeft);
    var top = anchor.bottom + gap;
    if (top + height > screenSize.height - padding.bottom - edgeGap) {
      final above = anchor.top - gap - height;
      top = above >= minTop ? above : top.clamp(minTop, maxTop);
    }
    return Offset(left.toDouble(), top.clamp(minTop, maxTop).toDouble());
  }
}
