import 'package:flutter/material.dart';

import 'sidebar_surface_transition.dart';
import 'player_sidebar_motion.dart';

/// Two reading surfaces in one sidebar. Keep both elements and their viewports
/// alive during navigation, but create the conversation only on its first visit.
class SubtitleChatSidebar extends StatefulWidget {
  const SubtitleChatSidebar({
    super.key,
    required this.showChat,
    required this.subtitles,
    required this.chat,
    this.isVisible = true,
    this.subtitleWidth,
    this.chatWidth,
    this.onLeft = false,
    this.motion,
  });

  final bool showChat;
  final bool isVisible;
  final Widget subtitles;
  final Widget chat;
  final double? subtitleWidth;
  final double? chatWidth;
  final bool onLeft;
  final PlayerSidebarMotion? motion;

  @override
  State<SubtitleChatSidebar> createState() => _SubtitleChatSidebarState();
}

class _SubtitleChatSidebarState extends State<SubtitleChatSidebar>
    with SingleTickerProviderStateMixin {
  PlayerSidebarMotion? _localMotion;
  PlayerSidebarMotion get _motion =>
      widget.motion ?? (_localMotion ??= PlayerSidebarMotion(vsync: this));
  late bool _chatVisited = widget.showChat;
  late bool _showChat = widget.showChat;

  @override
  void dispose() {
    _localMotion?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(SubtitleChatSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isVisible) _showChat = widget.showChat;
    _chatVisited |= _showChat;
  }

  Widget _surface(
    Widget child, {
    required bool selected,
    required Object surface,
    double? width,
    bool animateInitial = false,
  }) {
    return Positioned.fill(
      child: OverflowBox(
        minWidth: width,
        maxWidth: width,
        alignment: widget.onLeft ? Alignment.centerRight : Alignment.centerLeft,
        child: SidebarSurfaceTransition(
          visible: selected,
          active: widget.isVisible,
          animateInitial: animateInitial,
          opacity: _motion.opacityFor(surface),
          child: child,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.motion == null) {
      _motion.configure(
        target: _showChat ? 'chat' : 'subtitles',
        dockExtent: 0,
        visibleSurfaces: {
          _showChat
              ? PlayerSidebarMotion.chatSurface
              : PlayerSidebarMotion.subtitleSurface,
        },
        immediate:
            !widget.isVisible ||
            MediaQuery.disableAnimationsOf(context) ||
            !TickerMode.valuesOf(context).enabled,
      );
    }
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          _surface(
            widget.subtitles,
            selected: !_showChat,
            surface: PlayerSidebarMotion.subtitleSurface,
            width: widget.subtitleWidth,
          ),
          if (_chatVisited)
            _surface(
              widget.chat,
              selected: _showChat,
              surface: PlayerSidebarMotion.chatSurface,
              width: widget.chatWidth,
              animateInitial: true,
            ),
        ],
      ),
    );
  }
}
