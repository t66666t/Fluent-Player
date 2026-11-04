import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'network_http.dart';
export 'network_models.dart';

/// Low-level network image. Podcast and shared covers should go through
/// MediaArtworkRepository so one URL is downloaded once; this provider stays
/// for callers that intentionally load a single remote image themselves.
class ScopedNetworkImage extends ImageProvider<ScopedNetworkImage> {
  final String url;
  final NetworkScope scope;
  final Uri? source;
  final double scale;
  final Map<String, String>? headers;
  final RequestNetworkContext? _context;
  final String _generation;
  ScopedNetworkImage(
    this.url, {
    this.scope = NetworkScope.bilibili,
    this.source,
    this.scale = 1,
    this.headers,
    RequestNetworkContext? context,
  }) : _context = context,
       _generation =
           context?.key ??
           NetworkSettingsService.instance.imageGeneration(scope);

  @override
  Future<ScopedNetworkImage> obtainKey(ImageConfiguration configuration) async {
    final context =
        _context ??
        await NetworkSettingsService.instance.context(scope, source: source);
    return ScopedNetworkImage(
      url,
      scope: scope,
      source: source,
      scale: scale,
      headers: headers,
      context: context,
    );
  }

  @override
  ImageStreamCompleter loadImage(
    ScopedNetworkImage key,
    ImageDecoderCallback decode,
  ) {
    final chunks = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _load(key, decode, chunks),
      scale: scale,
      chunkEvents: chunks.stream,
      debugLabel: url,
    );
  }

  Future<ui.Codec> _load(
    ScopedNetworkImage key,
    ImageDecoderCallback decode,
    StreamController<ImageChunkEvent> chunks,
  ) async {
    final client = NetworkHttp.instance.createClient(context: key._context)
      ..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await openNetworkRequest(
        client,
        'GET',
        Uri.parse(url),
        timeout: const Duration(seconds: 12),
      );
      headers?.forEach(request.headers.set);
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      if (response.statusCode != HttpStatus.ok) {
        await response.listen((_) {}).cancel();
        throw HttpException('图片加载失败（${response.statusCode}）');
      }
      final bytes = await readNetworkResponseBytes(
        response,
        totalTimeout: const Duration(seconds: 30),
        onBytes: (cumulative, total) => chunks.add(
          ImageChunkEvent(
            cumulativeBytesLoaded: cumulative,
            expectedTotalBytes: total,
          ),
        ),
      );
      // New image keys adopt the new route; successfully received bytes from
      // the previous route still represent the same requested image.
      if (bytes.isEmpty) throw const HttpException('图片内容为空');
      return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    } catch (_) {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      rethrow;
    } finally {
      client.close(force: true);
      await chunks.close();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ScopedNetworkImage &&
      other.url == url &&
      other.scale == scale &&
      other.scope == scope &&
      other._generation == _generation &&
      mapEquals(other.headers, headers);
  @override
  int get hashCode => Object.hash(url, scale, scope, _generation);
}

/// Rebuild failed images after policy changes while keeping the last frame.
class NetworkPicture extends StatelessWidget {
  final String url;
  final NetworkScope scope;
  final Uri? source;
  final double? width, height;
  final BoxFit? fit;
  final Map<String, String>? headers;
  final bool gaplessPlayback;
  final ImageErrorWidgetBuilder? errorBuilder;
  final ImageFrameBuilder? frameBuilder;
  final ImageLoadingBuilder? loadingBuilder;
  final FilterQuality filterQuality;
  final int? cacheWidth, cacheHeight;
  const NetworkPicture(
    this.url, {
    super.key,
    this.scope = NetworkScope.bilibili,
    this.source,
    this.width,
    this.height,
    this.fit,
    this.headers,
    this.gaplessPlayback = false,
    this.errorBuilder,
    this.frameBuilder,
    this.loadingBuilder,
    this.filterQuality = FilterQuality.medium,
    this.cacheWidth,
    this.cacheHeight,
  });
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: NetworkSettingsService.instance,
    builder: (_, _) => Image(
      image: ResizeImage.resizeIfNeeded(
        cacheWidth,
        cacheHeight,
        ScopedNetworkImage(url, scope: scope, source: source, headers: headers),
      ),
      width: width,
      height: height,
      fit: fit,
      gaplessPlayback: gaplessPlayback,
      errorBuilder: errorBuilder,
      frameBuilder: frameBuilder,
      loadingBuilder: loadingBuilder,
      filterQuality: filterQuality,
    ),
  );
}
