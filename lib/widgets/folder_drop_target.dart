import 'dart:async';
import 'package:flutter/material.dart';

import 'custom_drag.dart';

class FolderDropTarget extends StatefulWidget {
  final Widget child;
  final String folderId;
  final int index;
  final Function(int draggedIndex, String targetFolderId) onMoveToFolder;
  final Function(int draggedIndex, int newIndex) onReorder;
  final bool allowReorder;

  const FolderDropTarget({
    super.key,
    required this.child,
    required this.folderId,
    required this.index,
    required this.onMoveToFolder,
    required this.onReorder,
    this.allowReorder = true,
  });

  @override
  State<FolderDropTarget> createState() => _FolderDropTargetState();
}

class _FolderDropTargetState extends State<FolderDropTarget> {
  Timer? _hoverTimer;
  bool _isHovering = false;
  bool _isMoveMode = false;

  @override
  void dispose() {
    _hoverTimer?.cancel();
    super.dispose();
  }

  void _handleDragEnter() {
    setState(() {
      _isHovering = true;
      _isMoveMode = !widget.allowReorder;
    });

    if (!widget.allowReorder) return;

    _hoverTimer?.cancel();
    _hoverTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted && _isHovering) {
        setState(() {
          _isMoveMode = true;
        });
      }
    });
  }

  void _handleDragLeave() {
    _hoverTimer?.cancel();
    setState(() {
      _isHovering = false;
      _isMoveMode = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final unit = constraints.biggest.shortestSide;
        return DropZone<int>(
          data: widget.index,
          onWillAccept: (draggedIndex) {
            if (draggedIndex == widget.index) return false;
            _handleDragEnter();
            return true;
          },
          onLeave: _handleDragLeave,
          onAcceptWithDetails: (draggedIndex, _) {
            _hoverTimer?.cancel();

            if (_isMoveMode || !widget.allowReorder) {
              widget.onMoveToFolder(draggedIndex, widget.folderId);
            } else {
              widget.onReorder(draggedIndex, widget.index);
            }

            setState(() {
              _isHovering = false;
              _isMoveMode = false;
            });
          },
          builder: (context, candidateData) {
            if (!_isHovering || candidateData.isEmpty) {
              return widget.child;
            }

            return Stack(
              children: [
                widget.child,
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(unit * 0.16),
                      color: _isMoveMode
                          ? Colors.greenAccent.withValues(alpha: 0.3)
                          : Colors.transparent,
                      border: Border.all(
                        color: _isMoveMode
                            ? Colors.greenAccent
                            : Colors.blueAccent,
                        width: unit * 0.025,
                      ),
                    ),
                    child: _isMoveMode
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.move_to_inbox,
                                  color: Colors.white,
                                  size: unit * 0.28,
                                ),
                                SizedBox(height: unit * 0.05),
                                Text(
                                  "移动到此处",
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: unit * 0.09,
                                    height: 1,
                                    fontWeight: FontWeight.bold,
                                    shadows: const [
                                      Shadow(
                                        blurRadius: 4,
                                        color: Colors.black,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          )
                        : null,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
