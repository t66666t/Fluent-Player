import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../services/app_haptics.dart';
import '../services/settings_service.dart';
import 'custom_drag.dart';
import 'folder_drop_target.dart';
import 'package:video_player_app/widgets/button_aware_drag.dart';

/// Uses movement-gated desktop dragging while preserving long-press dragging
/// on touch-first mobile platforms. On desktop, a short still press stays a
/// click; holding past [delay] enters selection without treating the release
/// as another tap.
class MediaLibraryAdaptiveDraggable<T extends Object> extends StatefulWidget {
  const MediaLibraryAdaptiveDraggable({
    super.key,
    required this.data,
    required this.delay,
    required this.feedback,
    required this.child,
    required this.childWhenDragging,
    required this.onDragStarted,
    this.onTap,
    this.onDragPosition,
    this.onDragEnd,
    this.selectionHapticOnStart = true,
  });

  final T data;
  final Duration delay;
  final Widget feedback;
  final Widget child;
  final Widget childWhenDragging;
  final VoidCallback onDragStarted;

  /// 位移未达拖拽阈值时补偿点击的回调（桌面端）。
  final VoidCallback? onTap;

  /// 拖拽残影移动中的全局坐标，供列表边缘自动滚动使用。
  final MediaLibraryCardDragUpdate? onDragPosition;

  /// 拖拽结束或取消。未真正拖动时父级应自行忽略。
  final VoidCallback? onDragEnd;

  /// Mobile long-press used to rely on [LongPressDraggable]'s built-in click,
  /// which ignores the vibration switch. Pin reorder passes false because its
  /// own reorder pulse is the feedback for that gesture.
  final bool selectionHapticOnStart;

  @override
  State<MediaLibraryAdaptiveDraggable<T>> createState() =>
      _MediaLibraryAdaptiveDraggableState<T>();
}

class _MediaLibraryAdaptiveDraggableState<T extends Object>
    extends State<MediaLibraryAdaptiveDraggable<T>> {
  int? _pointer;
  int? _viewId;
  PointerDeviceKind? _kind;

  bool get _usesDesktopPointerGesture {
    return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  }

  void _rememberPointer(PointerDownEvent event) {
    // 右键不参与换位拖拽，避免把选择手势的指针身份冲掉。
    if (event.kind == PointerDeviceKind.mouse &&
        event.buttons != kPrimaryButton) {
      return;
    }
    _pointer = event.pointer;
    _viewId = event.viewId;
    _kind = event.kind;
  }

  void _reportDragPosition(Offset globalPosition) {
    final pointer = _pointer;
    final viewId = _viewId;
    final kind = _kind;
    if (pointer == null || viewId == null || kind == null) return;
    widget.onDragPosition?.call(globalPosition, pointer, viewId, kind);
  }

  @override
  Widget build(BuildContext context) {
    if (_usesDesktopPointerGesture) {
      return GatedDraggable<T>(
        data: widget.data,
        feedback: widget.feedback,
        onDragStarted: widget.onDragStarted,
        onTap: widget.onTap == null
            ? null
            : () {
                // The alternate click path owns the feedback when its child
                // InkWell does not receive this same activation.
                unawaited(AppHaptics.cardTap(SettingsService()));
                widget.onTap!();
              },
        onDragPosition: widget.onDragPosition,
        onDragEnd: widget.onDragEnd,
        longPressDuration: widget.delay,
        child: widget.child,
      );
    }
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _rememberPointer,
      child: ButtonAwareLongPressDraggable<T>(
        delay: widget.delay,
        // The framework click cannot see [SettingsService.enableHapticFeedback].
        hapticFeedbackOnStart: false,
        data: widget.data,
        feedback: widget.feedback,
        childWhenDragging: widget.childWhenDragging,
        onDragStarted: () {
          if (widget.selectionHapticOnStart) {
            unawaited(AppHaptics.selectionClick(SettingsService()));
          }
          widget.onDragStarted();
        },
        onDragUpdate: (details) => _reportDragPosition(details.globalPosition),
        onDragEnd: (_) => widget.onDragEnd?.call(),
        child: widget.child,
      ),
    );
  }
}

/// Applies the same long-press drag, reorder and folder-drop interaction to
/// any media-library presentation (grid card or proportional list tile).
class MediaLibraryItemInteractionWrapper extends StatelessWidget {
  const MediaLibraryItemInteractionWrapper({
    super.key,
    required this.child,
    required this.index,
    required this.dragDelay,
    required this.isSelected,
    required this.selectedCount,
    required this.onDragStarted,
    required this.onReorder,
    this.onDragPosition,
    this.onDragEnd,
    this.folderId,
    this.onMoveToFolder,
    this.onTap,
    this.allowReorder = true,
  });

  final Widget child;
  final int index;
  final Duration dragDelay;
  final bool isSelected;
  final int selectedCount;
  final VoidCallback onDragStarted;
  final void Function(int oldIndex, int newIndex) onReorder;

  /// 拖拽卡片换位置时的指针更新，用来驱动列表边缘自动滚动。
  final MediaLibraryCardDragUpdate? onDragPosition;

  final VoidCallback? onDragEnd;
  final String? folderId;
  final void Function(int draggedIndex, String targetFolderId)? onMoveToFolder;

  /// 位移未达拖拽阈值时补偿点击的回调（桌面端），通常与子项点击行为一致。
  final VoidCallback? onTap;

  final bool allowReorder;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final unit = size.shortestSide;
        final target = folderId != null && onMoveToFolder != null
            ? FolderDropTarget(
                folderId: folderId!,
                index: index,
                onMoveToFolder: onMoveToFolder!,
                onReorder: onReorder,
                allowReorder: allowReorder,
                child: child,
              )
            : DropZone<int>(
                data: index,
                onWillAccept: (draggedData) =>
                    allowReorder && draggedData != index,
                onAcceptWithDetails: (draggedData, _) {
                  if (!allowReorder) return;
                  onReorder(draggedData, index);
                },
                builder: (context, candidateData) {
                  if (candidateData.isEmpty) return child;
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      child,
                      IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(unit * 0.16),
                            border: Border.all(
                              color: Colors.blueAccent,
                              width: unit * 0.025,
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              );

        return MediaLibraryAdaptiveDraggable<int>(
          delay: dragDelay,
          data: index,
          onDragStarted: onDragStarted,
          onDragPosition: onDragPosition,
          onDragEnd: onDragEnd,
          onTap: onTap,
          feedback: SizedBox(
            width: size.width,
            height: size.height,
            child: Material(
              type: MaterialType.transparency,
              child: Opacity(
                opacity: 0.9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    IgnorePointer(child: child),
                    if (isSelected && selectedCount > 1)
                      Positioned(
                        top: unit * 0.06,
                        right: unit * 0.06,
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: unit * 0.12,
                            vertical: unit * 0.05,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.blueAccent,
                            borderRadius: BorderRadius.circular(unit * 0.14),
                          ),
                          child: Text(
                            '$selectedCount',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: unit * 0.16,
                              height: 1,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.3, child: target),
          child: target,
        );
      },
    );
  }
}

/// Drag payload for continue-learning pins. Distinct from folder `int` indices
/// so a parked folders grid cannot accept a pin drop as a children reorder.
class MediaLibraryPinnedDragData {
  const MediaLibraryPinnedDragData(this.visibleIndex);

  final int visibleIndex;
}

/// Long-press reorder limited to the pin strip. Never offers folder-move hover.
class MediaLibraryPinnedReorderWrapper extends StatelessWidget {
  const MediaLibraryPinnedReorderWrapper({
    super.key,
    required this.child,
    required this.visibleIndex,
    required this.dragDelay,
    required this.onReorder,
    this.onTap,
    this.onDragStarted,
  });

  final Widget child;
  final int visibleIndex;
  final Duration dragDelay;
  final void Function(int fromVisibleIndex, int toVisibleIndex) onReorder;
  final VoidCallback? onTap;
  final VoidCallback? onDragStarted;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final unit = size.shortestSide;
        final target = DropZone<MediaLibraryPinnedDragData>(
          data: MediaLibraryPinnedDragData(visibleIndex),
          onWillAccept: (draggedData) =>
              draggedData.visibleIndex != visibleIndex,
          onAcceptWithDetails: (draggedData, _) {
            onReorder(draggedData.visibleIndex, visibleIndex);
          },
          builder: (context, candidateData) {
            if (candidateData.isEmpty) return child;
            return Stack(
              fit: StackFit.expand,
              children: [
                child,
                IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(unit * 0.16),
                      border: Border.all(
                        color: Colors.blueAccent,
                        width: unit * 0.025,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );

        return MediaLibraryAdaptiveDraggable<MediaLibraryPinnedDragData>(
          delay: dragDelay,
          data: MediaLibraryPinnedDragData(visibleIndex),
          selectionHapticOnStart: false,
          onDragStarted: onDragStarted ?? () {},
          onTap: onTap,
          feedback: SizedBox(
            width: size.width,
            height: size.height,
            child: Material(
              type: MaterialType.transparency,
              child: Opacity(opacity: 0.9, child: IgnorePointer(child: child)),
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.3, child: target),
          child: target,
        );
      },
    );
  }
}
