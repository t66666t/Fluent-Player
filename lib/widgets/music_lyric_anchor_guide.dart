import 'package:flutter/material.dart';

/// A temporary, non-interactive marker at the resolved lyric block's top.
class MusicLyricAnchorGuide extends StatelessWidget {
  final bool visible;

  const MusicLyricAnchorGuide({super.key, required this.visible});

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: visible || MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 180),
        child: const SizedBox(
          height: 1.5,
          child: ColoredBox(color: Color(0xFF42A5F5)),
        ),
      ),
    ),
  );
}
