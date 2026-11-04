import 'package:flutter/material.dart';
import '../models/video_item.dart';
import '../models/media_source_ref.dart';
import 'media_card_preparation.dart';

/// Multipart imports persist a part-specific original URL, including P1.
/// Do not turn ordinary single-video cards or downloaded files into numbers.
int? bilibiliPartCoverPage(VideoItem item) {
  final ref = item.sourceRef;
  if (item.type != MediaType.video ||
      ref?.kind != MediaSourceKind.bilibiliStream) {
    return null;
  }
  final page = ref?.page;
  if (page == null || page < 1) return null;
  final original = Uri.tryParse(ref?.originalValue ?? '');
  return page > 1 || original?.queryParameters['p'] == '$page' ? page : null;
}

/// A local vector-like cover. One design coordinate system scales every element,
/// including typography and whitespace, in both square and widescreen slots.
class BilibiliPartCover extends StatefulWidget {
  const BilibiliPartCover({
    super.key,
    required this.identity,
    required this.page,
  });
  final String identity;
  final int page;
  @override
  State<BilibiliPartCover> createState() => _BilibiliPartCoverState();
}

class _BilibiliPartCoverState extends State<BilibiliPartCover>
    with SingleTickerProviderStateMixin {
  static final _seen = <String>{};
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  late final _fade = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );
  MediaCardPreparation? _preparation;
  bool _scheduled = false;

  void _reveal() {
    if (_preparation?.isReady == false || _scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted || _preparation?.isReady == false) return;
      if (_seen.contains(widget.identity) ||
          MediaQuery.disableAnimationsOf(context)) {
        _controller.value = 1;
      } else {
        _seen.add(widget.identity);
        if (_seen.length > 512) _seen.remove(_seen.first);
        _controller.forward();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final preparation = MediaCardPreparationHost.maybeOf(context);
    if (!identical(preparation, _preparation)) {
      _preparation?.removeListener(_reveal);
      _preparation = preparation;
      preparation?.addListener(_reveal);
    }
    if (_seen.contains(widget.identity) ||
        MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
    } else {
      _reveal();
    }
  }

  @override
  void didUpdateWidget(BilibiliPartCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity != widget.identity) {
      _controller.value = _seen.contains(widget.identity) ? 1 : 0;
      _reveal();
    }
  }

  @override
  void dispose() {
    _preparation?.removeListener(_reveal);
    _fade.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: '第 ${widget.page} P',
    image: true,
    child: ExcludeSemantics(
      child: ColoredBox(
        color: const Color(0xFF2B2D30),
        child: FadeTransition(
          opacity: _fade,
          child: RepaintBoundary(
            child: FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(
                width: 208,
                height: 117,
                child: Stack(
                  children: [
                    const Positioned(
                      left: 16,
                      top: 12,
                      child: Text(
                        '分 P 视频',
                        textScaler: TextScaler.noScaling,
                        style: TextStyle(
                          fontSize: 11,
                          color: Color(0xFF9B9A97),
                          height: 1.2,
                        ),
                      ),
                    ),
                    Positioned(
                      left: 14,
                      top: 32,
                      width: 155,
                      height: 66,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          widget.page.toString().padLeft(2, '0'),
                          textScaler: TextScaler.noScaling,
                          style: const TextStyle(
                            fontSize: 66,
                            height: 1,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFC1C2C4),
                          ),
                        ),
                      ),
                    ),
                    const Positioned(
                      right: 16,
                      bottom: 20,
                      child: Text(
                        'P',
                        textScaler: TextScaler.noScaling,
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF84878D),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
