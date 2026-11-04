import 'package:flutter/material.dart';

import '../../widgets/media_library_scroll_viewport.dart';

/// Channel panes share the library's compact left-hand scrollbar and gutters.
class PodcastScrollbar extends StatelessWidget {
  const PodcastScrollbar({
    super.key,
    required this.controller,
    required this.child,
  });

  final ScrollController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) => MediaLibraryScrollViewport(
    controller: controller,
    // Both identity and episode panes can be visible together. Page shortcuts
    // remain owned by the channel rather than whichever pane mounted first.
    keyboardScrolling: false,
    child: child,
  );
}
