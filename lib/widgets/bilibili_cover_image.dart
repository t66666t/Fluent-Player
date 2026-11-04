import 'package:flutter/material.dart';
import '../services/network/scoped_network_image.dart';
import '../services/network/network_settings_service.dart';

import '../theme/app_tokens.dart';
import '../utils/bilibili_image_url.dart';
import 'bilibili_cover_geometry_image.dart';
import 'bilibili_image_reveal.dart';

/// Network image for Bilibili covers/avatars. A null [url] (missing or not on
/// an allowed host) and load failures both show a placeholder.
class BilibiliCoverImage extends StatefulWidget {
  const BilibiliCoverImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.borderRadius = 6,
    this.fit = BoxFit.cover,
    this.icon = Icons.smart_display_outlined,
  });

  final String? url;
  final double? width;
  final double? height;
  final double borderRadius;
  final BoxFit fit;
  final IconData icon;

  @override
  State<BilibiliCoverImage> createState() => _BilibiliCoverImageState();
}

class _BilibiliCoverImageState extends State<BilibiliCoverImage> {
  bool _hasFrame = false;

  @override
  void didUpdateWidget(BilibiliCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _hasFrame = false;
  }

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: AppTokens.bgCard,
      child: Center(child: Icon(widget.icon, color: AppTokens.text3, size: 26)),
    );
    final value = widget.url;
    final Widget child = value == null
        ? placeholder
        : NetworkPicture(
            value,
            key: ValueKey(value),
            fit: widget.fit,
            // TickerMode changes resolve the asynchronous provider again.
            // Keep the decoded pixels and their reveal state for this URL.
            // The URL key above replaces the image state for a different item.
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => placeholder,
            frameBuilder: (context, child, frame, wasSync) {
              _hasFrame = _hasFrame || wasSync || frame != null;
              return BilibiliImageReveal(
                ready: _hasFrame,
                synchronous: wasSync,
                placeholder: placeholder,
                child: child,
              );
            },
          );
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: SizedBox(width: widget.width, height: widget.height, child: child),
    );
  }
}

/// Large cover (detail header). Shows the small list thumbnail [url] first,
/// which is usually already cached, then swaps to a sharper size picked from
/// the laid-out width × devicePixelRatio once it has loaded. If the sharp
/// image fails, the thumbnail stays.
///
/// [videoFrame] is the player poster. The list thumbnail is 16:10, and
/// covering the 16:9 video with it zooms the picture until the sharper file
/// arrives. The stand-in there is a 16:9 crop of the same image instead.
class BilibiliSharpCoverImage extends StatelessWidget {
  const BilibiliSharpCoverImage({
    super.key,
    required this.url,
    this.borderRadius = 10,
    this.videoFrame = false,
    this.preserveAspectRatio = false,
    this.onAspectRatio,
  });

  /// Thumbnail URL; the sharp URL is derived from the same image path.
  final String? url;
  final double borderRadius;

  /// Player poster: both sizes are 16:9 center crops, forced to the slot.
  final bool videoFrame;
  final bool preserveAspectRatio;
  final ValueChanged<double>? onAspectRatio;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (preserveAspectRatio) {
            final natural = bilibiliCoverNaturalUrl(
              url,
              constraints.maxWidth * dpr,
            );
            if (natural == null) return const ColoredBox(color: Colors.black);
            return ListenableBuilder(
              listenable: NetworkSettingsService.instance,
              builder: (context, _) => BilibiliCoverGeometryImage(
                image: ScopedNetworkImage(natural),
                sourceKey: url,
                onAspectRatio: onAspectRatio,
              ),
            );
          }
          if (videoFrame) {
            return _videoFrame(constraints.maxWidth * dpr);
          }
          final small = BilibiliCoverImage(url: url, borderRadius: 0);
          final sharp = bilibiliCoverSharpUrl(url, constraints.maxWidth * dpr);
          if (sharp == null || sharp == url) return small;
          return _sharpImage(sharp, fallback: small);
        },
      ),
    );
  }

  /// 16:9 stand-in, then a sharper 16:9 file in the same box. Neither is the
  /// list thumbnail, and neither is the uncropped original.
  Widget _videoFrame(double pixelWidth) {
    const fallback = ColoredBox(color: Colors.black);
    final standInUrl = bilibiliCoverFrameUrl(url);
    final standIn = _fillNetwork(standInUrl, fallback: fallback);
    final sharp = bilibiliCoverVideoFrameUrl(url, pixelWidth);
    if (sharp == null || sharp == standInUrl) return standIn;
    return _fillNetwork(sharp, fallback: standIn);
  }

  /// Fills the slot. A bare network image can lay out at its pixel size,
  /// which is larger than the video, until a later pass fits it.
  Widget _fillNetwork(String? url, {required Widget fallback}) {
    final image = _sharpImage(url, fallback: fallback);
    return SizedBox.expand(child: image);
  }

  Widget _sharpImage(String? url, {required Widget fallback}) {
    if (url == null) return fallback;
    return NetworkPicture(
      url,
      key: ValueKey(url),
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => fallback,
      frameBuilder: (context, child, frame, wasSync) => BilibiliImageReveal(
        ready: wasSync || frame != null,
        synchronous: wasSync,
        placeholder: fallback,
        child: child,
      ),
    );
  }
}

/// Centers [child] in the rectangle the player will use for the video.
///
/// The playback surface is often taller than the picture. Painting the cover
/// across that whole surface zooms it, then the real frame snaps back to the
/// video size.
class BilibiliVideoPosterSlot extends StatelessWidget {
  const BilibiliVideoPosterSlot({
    super.key,
    required this.aspectRatio,
    required this.child,
    this.geometry,
    this.aspectRatioOf,
  });

  final double aspectRatio;
  final Widget child;
  final Listenable? geometry;
  final double Function()? aspectRatioOf;

  @override
  Widget build(BuildContext context) {
    final changes = geometry;
    if (changes != null) {
      return ListenableBuilder(
        listenable: changes,
        builder: (context, _) => _slot(),
      );
    }
    return _slot();
  }

  Widget _slot() {
    final value = aspectRatioOf?.call() ?? aspectRatio;
    final ratio = value.isFinite && value > 0 ? value : 16 / 9;
    return Center(
      child: AspectRatio(aspectRatio: ratio, child: child),
    );
  }
}

/// Keep a portrait player's outer rectangle in sync when its own video
/// dimensions arrive, including while the controller is still absent.
class BilibiliVideoAspectRatio extends StatelessWidget {
  const BilibiliVideoAspectRatio({
    super.key,
    required this.aspectRatio,
    required this.child,
    this.geometry,
  });
  final double Function() aspectRatio;
  final Widget child;
  final Listenable? geometry;

  @override
  Widget build(BuildContext context) {
    Widget frame() => AspectRatio(aspectRatio: aspectRatio(), child: child);
    final changes = geometry;
    return changes == null
        ? frame()
        : ListenableBuilder(listenable: changes, builder: (_, _) => frame());
  }
}

/// Circular avatar that keeps the original image framing (no crop suffix).
class BilibiliAvatar extends StatelessWidget {
  const BilibiliAvatar({super.key, required this.url, this.size = 40});

  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    return BilibiliCoverImage(
      url: url,
      width: size,
      height: size,
      borderRadius: size / 2,
      icon: Icons.person_outline,
    );
  }
}
