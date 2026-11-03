import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/bilibili/bilibili_startup.dart';
import 'bilibili_cover_image.dart';
import 'bilibili_cover_geometry_image.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// The same poster remains mounted while a native texture warms underneath it.
/// A late cover-file download never replaces the image already shown on entry.
class BilibiliStartupPoster extends StatelessWidget {
  const BilibiliStartupPoster({
    super.key,
    required this.startup,
    required this.covered,
    this.thumbnailPath,
    this.onRetry,
  });

  final PlaybackStartupContext? startup;
  final bool covered;
  final String? thumbnailPath;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final state = startup;
    return state == null
        ? _buildPoster(context)
        : ListenableBuilder(
            listenable: state,
            builder: (context, _) => _buildPoster(context),
          );
  }

  Widget _buildPoster(BuildContext context) {
    final url = startup?.coverUrl;
    final path = thumbnailPath;
    const fallback = ColoredBox(color: Colors.black);
    final Widget image;
    if (url != null && url.isNotEmpty) {
      image = BilibiliSharpCoverImage(
        url: url,
        videoFrame: true,
        preserveAspectRatio: true,
        onAspectRatio: _reportCoverAspectRatio,
        borderRadius: 0,
      );
    } else if (path != null && path.isNotEmpty && File(path).existsSync()) {
      image = BilibiliCoverGeometryImage(
        image: FileImage(File(path)),
        sourceKey: path,
        onAspectRatio: _reportCoverAspectRatio,
      );
    } else {
      image = fallback;
    }
    return IgnorePointer(
      ignoring: !covered || startup?.hasFailed != true,
      child: AnimatedOpacity(
        key: const ValueKey('bilibili-startup-poster'),
        opacity: covered ? 1 : 0,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : BilibiliStartupContext.coverFadeDuration,
        child: Stack(
          fit: StackFit.expand,
          children: [
            fallback,
            image,
            if (startup?.hasFailed == true)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      startup!.failure!,
                      style: const TextStyle(color: Colors.white),
                    ),
                    const SizedBox(height: 8),
                    if (onRetry != null)
                      DesktopButtonClickRegion(
                        child: TextButton(
                          onPressed: onRetry,
                          child: const Text('重试'),
                        ),
                      ),
                  ],
                ),
              )
            else if (covered)
              Center(child: BilibiliStartupIndicator(startup: startup)),
          ],
        ),
      ),
    );
  }

  void _reportCoverAspectRatio(double ratio) {
    final context = startup;
    if (context is BilibiliStartupContext && !context.isCancelled) {
      context.geometry.reportCover(ratio);
    }
  }
}

/// Delaying only the hint, rather than playback, avoids a spinner flash on a
/// fast cached open. Disposing or replacing a route cancels its timer.
class BilibiliStartupIndicator extends StatefulWidget {
  const BilibiliStartupIndicator({super.key, this.startup});
  final PlaybackStartupContext? startup;

  @override
  State<BilibiliStartupIndicator> createState() =>
      _BilibiliStartupIndicatorState();
}

class _BilibiliStartupIndicatorState extends State<BilibiliStartupIndicator> {
  Timer? _timer;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(BilibiliStartupIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.startup, widget.startup)) _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    final delay =
        BilibiliStartupContext.indicatorDelay -
        (widget.startup?.elapsed ?? Duration.zero);
    _visible = delay <= Duration.zero;
    if (!_visible) {
      _timer = Timer(delay, () {
        if (mounted) setState(() => _visible = true);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => !_visible
      ? const SizedBox.shrink()
      : const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: Colors.white70,
              ),
            ),
            SizedBox(width: 9),
            Flexible(
              child: Text(
                '正在打开',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
          ],
        );
}
