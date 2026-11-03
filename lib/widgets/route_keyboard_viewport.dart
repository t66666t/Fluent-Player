import 'package:flutter/widgets.dart';
import 'playback_source_viewport.dart';

/// A keyboard belongs to the front route. Keep covered pages at their last
/// visible keyboard geometry instead of laying them out for every IME frame.
/// Screen size, rotation, text scaling and the remaining media data stay live.
class RouteKeyboardViewport extends StatefulWidget {
  const RouteKeyboardViewport({super.key, required this.child});

  final Widget child;

  @override
  State<RouteKeyboardViewport> createState() => _RouteKeyboardViewportState();
}

class _RouteKeyboardViewportState extends State<RouteKeyboardViewport> {
  late MediaQueryData _media;
  double _bottomInset = 0;
  double? _bottomPadding;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final media = MediaQuery.of(context);
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if (current) {
      _bottomInset = media.viewInsets.bottom;
      _bottomPadding = media.padding.bottom;
      _media = media;
    } else {
      _media = media.copyWith(
        viewInsets: media.viewInsets.copyWith(bottom: _bottomInset),
        padding: media.padding.copyWith(
          bottom: _bottomPadding ?? media.viewPadding.bottom,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => MediaQuery(
    data: _media,
    child: PlaybackSourceViewport(child: widget.child),
  );
}
