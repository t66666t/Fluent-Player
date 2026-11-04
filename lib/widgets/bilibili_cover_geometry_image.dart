import 'package:flutter/widgets.dart';

/// Observe the same cached image the poster displays. No second download,
/// decode, or playback wait is needed to learn this cover's own dimensions.
class BilibiliCoverGeometryImage extends StatefulWidget {
  const BilibiliCoverGeometryImage({
    super.key,
    required this.image,
    this.sourceKey,
    this.onAspectRatio,
  });

  final ImageProvider image;
  final Object? sourceKey;
  final ValueChanged<double>? onAspectRatio;

  @override
  State<BilibiliCoverGeometryImage> createState() =>
      _BilibiliCoverGeometryImageState();
}

class _BilibiliCoverGeometryImageState
    extends State<BilibiliCoverGeometryImage> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  int _revision = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _observe();
  }

  @override
  void didUpdateWidget(BilibiliCoverGeometryImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image ||
        oldWidget.onAspectRatio != widget.onAspectRatio) {
      _observe();
    }
  }

  void _detach() {
    final listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    _listener = null;
    _stream = null;
  }

  void _observe() {
    _detach();
    final revision = ++_revision;
    if (widget.onAspectRatio == null) return;
    _stream = widget.image.resolve(createLocalImageConfiguration(context));
    _listener = ImageStreamListener(
      (info, _) {
        final ratio = info.image.width / info.image.height;
        info.dispose();
        if (revision != _revision) return;
        _detach();
        // A cache hit can arrive inside build. Geometry may rebuild the page,
        // so publish after composition and reject a superseded image callback.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && revision == _revision) {
            widget.onAspectRatio?.call(ratio);
          }
        });
        WidgetsBinding.instance.ensureVisualUpdate();
      },
      onError: (Object _, StackTrace? _) {
        if (revision == _revision) _detach();
      },
    );
    _stream!.addListener(_listener!);
  }

  @override
  void dispose() {
    _revision++;
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Image(
    key: ValueKey(widget.sourceKey ?? widget.image),
    image: widget.image,
    fit: BoxFit.contain,
    gaplessPlayback: true,
    errorBuilder: (_, _, _) => const ColoredBox(color: Color(0xFF000000)),
  );
}
