import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../../models/media_artwork_ref.dart';
import '../../models/video_collection.dart';
import '../../services/media_artwork_repository.dart';
import '../../theme/app_tokens.dart';
import '../../theme/app_interaction_theme.dart';
import '../../widgets/media_artwork_view.dart';
import '../../widgets/media_library_empty_viewport.dart';
import '../../widgets/cached_thumbnail_widget.dart';
import 'podcast_models.dart';
import 'podcast_runtime.dart';
import 'podcast_typography.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

export 'podcast_filter_bar.dart';

/// Heard wins over a leftover end position so completion cannot look started.
String podcastListenLabel(PodcastEpisodeState state) {
  if (state.played) return '已听';
  if (state.positionMs > 0) {
    return '进行中 · 听到 ${podcastTime(state.positionMs)}';
  }
  return '未听';
}

class PodcastListenLabel extends StatelessWidget {
  const PodcastListenLabel({super.key, required this.state});

  final PodcastEpisodeState state;

  @override
  Widget build(BuildContext context) {
    final inProgress = !state.played && state.positionMs > 0;
    return Text(
      podcastListenLabel(state),
      style: TextStyle(
        fontSize: 11,
        height: 1.4,
        color: inProgress ? AppTokens.text2 : AppTokens.text3,
      ),
    );
  }
}

String podcastTime(int milliseconds) {
  final seconds = (milliseconds ~/ 1000).clamp(0, 1 << 40);
  final hours = seconds ~/ 3600;
  return hours > 0
      ? '$hours:${(seconds ~/ 60 % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}'
      : '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

String podcastSize(int bytes) => bytes >= 1024 * 1024 * 1024
    ? '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
String podcastDay(int milliseconds) {
  if (milliseconds <= 0) return '';
  final date = DateTime.fromMillisecondsSinceEpoch(milliseconds);
  return '${date.year}.${date.month.toString().padLeft(2, '0')}.${date.day.toString().padLeft(2, '0')}';
}

String podcastLibrarySummary(VideoCollection collection) {
  final runtime = PodcastRuntime.instance;
  final channelId = collection.podcastRef?.channelId;
  final author = channelId != null
      ? runtime.channelForCard(channelId)?.author.trim() ?? ''
      : '';
  return author.isEmpty ? '播客频道' : author;
}

Color podcastDarkTint(Color source) {
  final hsl = HSLColor.fromColor(source);
  if (hsl.saturation < 0.08 || hsl.lightness > 0.88) {
    return const Color(0xFF303034);
  }
  return hsl
      .withLightness(hsl.lightness.clamp(0.12, 0.23))
      .withSaturation(hsl.saturation.clamp(0.12, 0.45))
      .toColor();
}

class PodcastArtwork extends StatelessWidget {
  const PodcastArtwork({
    super.key,
    required this.url,
    this.fallbackUrl = '',
    this.ownerKind = 'podcast',
    this.ownerId = '',
    this.size = 56,
    this.radius = 10,
    this.fit = BoxFit.cover,
    this.expand = false,
    this.priority = ArtworkPriority.visible,
  });

  final String url;
  final String fallbackUrl;
  final String ownerKind;
  final String ownerId;
  final double size, radius;
  final BoxFit fit;

  /// Fill the parent instead of drawing a fixed square. [size] is then only
  /// the decode bucket. The parent must be bounded, as a card cover is.
  final bool expand;
  final ArtworkPriority priority;

  @override
  Widget build(BuildContext context) {
    final placeholder = _placeholder();
    final image = url.isEmpty && fallbackUrl.isEmpty
        ? placeholder
        : MediaArtworkView(
            reference: podcastArtworkRef(
              ownerKind: ownerKind,
              ownerId: ownerId.isEmpty ? url : ownerId,
              primaryUrl: url,
              fallbackUrl: fallbackUrl,
              temporary: ownerKind == 'search',
            ),
            size: size,
            fit: fit,
            priority: priority,
            placeholder: placeholder,
          );
    final framed = radius <= 0
        ? image
        : ClipRRect(borderRadius: BorderRadius.circular(radius), child: image);
    if (expand) return SizedBox.expand(child: framed);
    return SizedBox(width: size, height: size, child: framed);
  }

  Widget _placeholder() => ColoredBox(
    color: const Color(0xFF27272B),
    child: LayoutBuilder(
      builder: (_, constraints) => Center(
        child: Icon(
          Icons.podcasts_rounded,
          size: constraints.biggest.shortestSide * 0.42,
          color: AppTokens.text3,
        ),
      ),
    ),
  );
}

class PodcastBackdrop extends StatefulWidget {
  const PodcastBackdrop({
    super.key,
    required this.imageUrl,
    required this.child,
    this.intensity = 0.18,
  });
  final String imageUrl;
  final Widget child;
  final double intensity;
  @override
  State<PodcastBackdrop> createState() => _PodcastBackdropState();
}

class _PodcastBackdropState extends State<PodcastBackdrop> {
  static const _neutral = Color(0xFF303034);
  Color _tint = _neutral;
  String? _loaded;
  MediaArtworkRepository? _repository;
  int _requestId = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
  }

  @override
  void didUpdateWidget(covariant PodcastBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    _load();
  }

  /// Color comes from the same local bytes as the cover, never a second download.
  Future<void> _load() async {
    final repository = MediaArtworkRepository.active;
    final url = widget.imageUrl;
    if (_loaded == url && identical(_repository, repository)) return;
    _loaded = url;
    _repository = repository;
    final request = ++_requestId;
    // Never leave the previous channel's tint behind on an empty/recycled page.
    _tint = _neutral;
    if (repository == null || url.isEmpty) return;
    final reference = podcastArtworkRef(
      ownerKind: 'backdrop',
      ownerId: url,
      primaryUrl: url,
    );
    final cached = repository.cachedPalette(reference);
    if (cached != null) {
      _tint = Color(cached);
    }
    try {
      final snapshot = await repository.load(
        reference,
        priority: ArtworkPriority.palette,
      );
      if (!mounted || request != _requestId || snapshot.blobHash == null) {
        return;
      }
      final palette = repository.palette(snapshot.blobHash!);
      if (palette != null) {
        setState(() => _tint = Color(palette));
        return;
      }
      final path = snapshot.localPath;
      if (path == null) return;
      final data = await File(path).readAsBytes();
      if (!mounted || request != _requestId) return;
      final codec = await ui.instantiateImageCodec(
        data,
        targetWidth: 24,
        targetHeight: 24,
      );
      ByteData? bytes;
      try {
        final frame = await codec.getNextFrame();
        try {
          bytes = await frame.image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
      if (!mounted || request != _requestId || bytes == null) return;
      var red = 0, green = 0, blue = 0, count = 0;
      for (var i = 0; i + 3 < bytes.lengthInBytes; i += 16) {
        if (bytes.getUint8(i + 3) < 128) continue;
        red += bytes.getUint8(i);
        green += bytes.getUint8(i + 1);
        blue += bytes.getUint8(i + 2);
        count++;
      }
      if (count == 0) return;
      final tint = podcastDarkTint(
        Color.fromARGB(255, red ~/ count, green ~/ count, blue ~/ count),
      );
      repository.rememberPalette(snapshot.blobHash!, tint.toARGB32());
      setState(() => _tint = tint);
    } catch (_) {
      /* Neutral dark background remains readable. */
    }
  }

  @override
  void dispose() {
    _requestId++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: appInteractionTheme(Theme.of(context)),
    child: Material(
      color: AppTokens.bgBase,
      child: TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: _tint),
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 240),
        builder: (_, color, child) => Ink(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              stops: const [0, 0.5, 1],
              colors: [
                Color.alphaBlend(
                  (color ?? _tint).withValues(
                    alpha: (widget.intensity / 0.30).clamp(0, 1),
                  ),
                  AppTokens.bgBase,
                ),
                AppTokens.bgBase,
                AppTokens.bgBase,
              ],
            ),
          ),
          child: child,
        ),
        child: RepaintBoundary(child: widget.child),
      ),
    ),
  );
}

/// Quiet loading feedback without a continuously running animation.
class PodcastLoadingNotice extends StatelessWidget {
  const PodcastLoadingNotice({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Text(
      message,
      textAlign: TextAlign.center,
      style: PodcastType.meta.copyWith(color: AppTokens.text3, fontSize: 12),
    ),
  );
}

class PodcastSkeleton extends StatelessWidget {
  const PodcastSkeleton({super.key, this.rows = 6});
  final int rows;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '正在加载播客列表',
    child: ExcludeSemantics(
      child: IgnorePointer(
        child: ListView.builder(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.all(24),
          itemCount: rows,
          itemBuilder: (_, i) => Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: Row(
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: AppTokens.bgCard,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        height: 14,
                        width: i.isEven ? 240 : 180,
                        decoration: BoxDecoration(
                          color: AppTokens.bgCard,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        height: 10,
                        width: 120,
                        decoration: BoxDecoration(
                          color: AppTokens.bgCard,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class PodcastEmpty extends StatelessWidget {
  const PodcastEmpty({
    super.key,
    required this.title,
    required this.message,
    this.action,
    this.bottomPadding = 0,
  });
  final String title, message;
  final Widget? action;
  final double bottomPadding;
  @override
  Widget build(BuildContext context) => MediaLibraryEmptyViewport(
    bottomPadding: bottomPadding,
    padding: const EdgeInsets.all(32),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.podcasts_rounded, size: 44, color: AppTokens.text3),
          const SizedBox(height: 20),
          Text(
            title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          Text(
            message,
            style: const TextStyle(color: AppTokens.text2, height: 1.7),
            textAlign: TextAlign.center,
          ),
          if (action != null) ...[const SizedBox(height: 22), action!],
        ],
      ),
    ),
  );
}

class PodcastCardCover extends StatelessWidget {
  const PodcastCardCover({super.key, required this.collection});
  final VideoCollection collection;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: PodcastRuntime.instance,
    builder: (_, _) {
      final runtime = PodcastRuntime.instance;
      final channel = runtime.channelForCard(collection.podcastRef!.channelId);
      final count = runtime.ready
          ? runtime.controller.newCount(collection.podcastRef!.channelId)
          : 0;
      return ColoredBox(
        color: const Color(0xFF222225),
        child: LayoutBuilder(
          builder: (_, constraints) {
            // Use the short side so both 16:9 grid covers and square list
            // thumbnails keep the same proportions, even in dense grids.
            final extent = constraints.biggest.shortestSide;
            final inset = extent * 0.07;
            final artworkSize = extent * 0.86;
            final artwork = PodcastArtwork(
              url: channel?.imageUrl ?? '',
              ownerKind: 'channel',
              ownerId: collection.podcastRef!.channelId,
              size: artworkSize,
              radius: extent * 0.06,
            );
            final thumbnailPath = collection.thumbnailPath;
            return Stack(
              fit: StackFit.expand,
              children: [
                Center(
                  child: thumbnailPath != null && thumbnailPath.isNotEmpty
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(extent * 0.06),
                          child: SizedBox.square(
                            dimension: artworkSize,
                            child: CachedThumbnailWidget(
                              videoId: collection.id,
                              thumbnailPath: thumbnailPath,
                              placeholder: artwork,
                              errorWidget: artwork,
                            ),
                          ),
                        )
                      : artwork,
                ),
                Positioned(
                  left: inset,
                  bottom: inset,
                  child: Semantics(
                    label: '播客频道',
                    child: Container(
                      key: const ValueKey('podcast-card-badge'),
                      width: extent * 0.25,
                      height: extent * 0.25,
                      decoration: BoxDecoration(
                        color: const Color(0xE6252525),
                        borderRadius: BorderRadius.circular(extent * 0.08),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.12),
                          width: extent * 0.006,
                        ),
                      ),
                      child: Icon(
                        Icons.podcasts_rounded,
                        size: extent * 0.16,
                        color: AppTokens.text1,
                      ),
                    ),
                  ),
                ),
                if (count > 0)
                  Positioned(
                    right: inset,
                    bottom: inset,
                    child: Container(
                      key: const ValueKey('podcast-card-updates'),
                      constraints: BoxConstraints(
                        maxWidth: constraints.maxWidth - extent * 0.46,
                      ),
                      padding: EdgeInsets.symmetric(
                        horizontal: extent * 0.07,
                        vertical: extent * 0.03,
                      ),
                      decoration: BoxDecoration(
                        color: AppTokens.bgOverlay,
                        borderRadius: BorderRadius.circular(extent * 0.06),
                      ),
                      child: Text(
                        '$count 集更新',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: extent * 0.11,
                          color: AppTokens.text1,
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      );
    },
  );
}

class PodcastGate extends StatefulWidget {
  const PodcastGate({super.key, required this.builder, this.bottomPadding = 0});
  final Widget Function(PodcastRuntime) builder;
  final double bottomPadding;
  @override
  State<PodcastGate> createState() => _PodcastGateState();
}

class _PodcastGateState extends State<PodcastGate> {
  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) => PodcastTypography(
    child: ListenableBuilder(
      listenable: PodcastRuntime.instance,
      builder: (_, _) {
        final runtime = PodcastRuntime.instance;
        if (runtime.initializationError != null) {
          return PodcastEmpty(
            bottomPadding: widget.bottomPadding,
            title: '暂时无法打开播客',
            message: runtime.initializationError!,
            action: DesktopButtonClickRegion(
              child: TextButton(
                onPressed: () => runtime.initialize(),
                child: const Text('重试'),
              ),
            ),
          );
        }
        return runtime.ready
            ? ListenableBuilder(
                listenable: runtime.playlist ?? const AlwaysStoppedAnimation(0),
                builder: (_, _) => widget.builder(runtime),
              )
            : Padding(
                padding: EdgeInsets.only(bottom: widget.bottomPadding),
                child: const PodcastSkeleton(),
              );
      },
    ),
  );
}
