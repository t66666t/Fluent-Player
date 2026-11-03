import 'dart:math' as math;
import 'package:flutter/material.dart';

import 'media_library_compact_app_bar.dart';

class MediaLibraryBreadcrumbCrumb {
  const MediaLibraryBreadcrumbCrumb({
    required this.folderId,
    required this.label,
  });

  /// Null is the library root (文件夹入口).
  final String? folderId;
  final String label;
}

/// Clickable 媒体库 > … > current.
///
/// The trail stays in the title slot (clipped, never painted over actions) and
/// scrolls horizontally when it cannot fit. Compact mode uses a smaller type
/// and tighter separators instead of collapsing with an ellipsis menu.
class MediaLibraryFolderBreadcrumb extends StatefulWidget {
  const MediaLibraryFolderBreadcrumb({
    super.key,
    required this.crumbs,
    required this.onSelected,
    this.compact = false,
    this.hitPadding = EdgeInsets.zero,
    this.textStyle,
  });

  final List<MediaLibraryBreadcrumbCrumb> crumbs;
  final ValueChanged<String?> onSelected;
  final bool compact;
  final EdgeInsets hitPadding;
  final TextStyle? textStyle;

  @override
  State<MediaLibraryFolderBreadcrumb> createState() =>
      _MediaLibraryFolderBreadcrumbState();
}

class _MediaLibraryFolderBreadcrumbState
    extends State<MediaLibraryFolderBreadcrumb> {
  final ScrollController _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollToCurrent();
  }

  @override
  void didUpdateWidget(MediaLibraryFolderBreadcrumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.crumbs.length != widget.crumbs.length ||
        oldWidget.crumbs.lastOrNull?.folderId !=
            widget.crumbs.lastOrNull?.folderId) {
      _scrollToCurrent();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _scrollToCurrent() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      final max = _controller.position.maxScrollExtent;
      if (max <= 0) return;
      _controller.jumpTo(max);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.crumbs.isEmpty) return const SizedBox.shrink();
    final compact = widget.compact;
    final style =
        widget.textStyle ??
        (compact
            ? mediaLibraryCompactTitleStyle.copyWith(fontSize: 13)
            : mediaLibraryCompactTitleStyle);
    final height = math.max(
      compact ? 28.0 : 36.0,
      MediaQuery.textScalerOf(context).scale(style.fontSize ?? 13) *
              (style.height ?? 1) +
          widget.hitPadding.vertical,
    );
    final trail = _trail(style, separatorPad: compact ? 2.0 : 4.0);

    return Transform.translate(
      offset: const Offset(0, mediaLibraryCompactTitleOpticalOffset),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final bounded = constraints.maxWidth.isFinite;
          final scroller = SingleChildScrollView(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.hardEdge,
            padding: EdgeInsets.only(right: compact ? 6 : 8),
            child: trail,
          );
          final body = bounded
              ? SizedBox(
                  width: constraints.maxWidth,
                  height: height,
                  child: scroller,
                )
              : SizedBox(height: height, child: trail);
          return ClipRect(
            child: Align(alignment: Alignment.centerLeft, child: body),
          );
        },
      ),
    );
  }

  Widget _trail(TextStyle style, {required double separatorPad}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (var i = 0; i < widget.crumbs.length; i++) ...[
          if (i > 0)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: separatorPad),
              child: Text('>', style: style.copyWith(color: Colors.white38)),
            ),
          _crumbLabel(
            widget.crumbs[i],
            style,
            isCurrent: i == widget.crumbs.length - 1,
          ),
        ],
      ],
    );
  }

  Widget _crumbLabel(
    MediaLibraryBreadcrumbCrumb crumb,
    TextStyle style, {
    required bool isCurrent,
  }) {
    final text = Text(
      crumb.label,
      maxLines: 1,
      softWrap: false,
      style: style.copyWith(
        color: isCurrent ? Colors.white : Colors.white70,
        fontWeight: isCurrent ? FontWeight.w500 : style.fontWeight,
      ),
    );
    final label = Padding(padding: widget.hitPadding, child: text);
    if (isCurrent) return label;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => widget.onSelected(crumb.folderId),
        behavior: HitTestBehavior.opaque,
        child: label,
      ),
    );
  }
}
