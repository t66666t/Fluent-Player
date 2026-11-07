import 'dart:async';
import 'dart:collection';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../features/media_cache/media_cache_models.dart';
import '../features/media_cache/media_cache_service.dart';
import '../models/video_collection.dart';
import '../utils/route_transition_work.dart';
import '../models/video_item.dart';
import '../services/thumbnail_cache_service.dart';
import '../services/thumbnail_decode_scheduler.dart';
import '../services/settings_service.dart';
import 'media_library_layout_profile.dart';
import 'media_library_view_defaults.dart';
import 'media_list_layout_metrics.dart';

/// Page-owned, bounded predecode. Ranges use actual mixed-folder item indexes,
/// not a second list with the folders removed. Scroll ticks never setState.
class MediaLibraryCardPreload extends StatefulWidget {
  factory MediaLibraryCardPreload.library({
    Key? key,
    required BuildContext context,
    required SettingsService settings,
    required ScrollController controller,
    required List<dynamic> contents,
    required double availableWidth,
    required Widget child,
    bool active = true,
  }) {
    final size = MediaQuery.sizeOf(context);
    if (!settings.mediaLibraryUsesRowPipeline) {
      final m = MediaLibraryLayoutDefaults.cardGrid(
        textScaler: MediaQuery.textScalerOf(context),
        textStyle: DefaultTextStyle.of(context).style,
        screenSize: Size(availableWidth, size.height),
        style: settings.homeCardStyleFor(size),
      );
      return MediaLibraryCardPreload(
        key: key,
        controller: controller,
        contents: contents,
        active: active,
        thumbnailWidth: m.cellWidth,
        thumbnailHeight: m.cellWidth * 9 / 16,
        geometry: MediaLibraryGridGeometry(
          crossAxisCount: m.crossAxisCount,
          itemWidth: m.cellWidth,
          itemHeight: m.cellHeight,
          horizontalSpacing: m.crossSpacing,
          verticalSpacing: m.mainSpacing,
          horizontalPadding: m.outerPadding,
          topPadding: m.topPadding,
        ),
        child: child,
      );
    }
    final style = settings.listStyleFor(size);
    final m = MediaListLayoutMetrics.forStyle(
      style: style,
      screenShortestSide: size.shortestSide,
      availableWidth: availableWidth,
    );
    final thumbnail = style.isTable
        ? MediaLibraryViewDefaults.tableThumbnailSize(m.rowHeight)
        : MediaLibraryViewDefaults.rowsThumbnailSize(m.rowHeight, m.cellWidth);
    return MediaLibraryCardPreload(
      key: key,
      controller: controller,
      contents: contents,
      active: active,
      decodeImages: style.showThumbnail,
      thumbnailWidth: thumbnail.width,
      thumbnailHeight: thumbnail.height,
      geometry: MediaLibraryGridGeometry(
        crossAxisCount: style.isTable ? 1 : style.crossAxisCount,
        itemWidth: m.cellWidth,
        itemHeight: m.rowHeight,
        horizontalSpacing: m.crossSpacing,
        verticalSpacing: m.mainSpacing,
        horizontalPadding: m.outerPadding,
        topPadding: m.topPadding,
      ),
      child: child,
    );
  }
  const MediaLibraryCardPreload({
    super.key,
    required this.controller,
    required this.contents,
    required this.geometry,
    required this.thumbnailWidth,
    required this.thumbnailHeight,
    required this.child,
    this.active = true,
    this.decodeImages = true,
  });
  final ScrollController controller;
  final List<dynamic> contents;
  final MediaLibraryGridGeometry geometry;
  final double thumbnailWidth, thumbnailHeight;
  final bool active, decodeImages;
  final Widget child;
  @override
  State<MediaLibraryCardPreload> createState() =>
      _MediaLibraryCardPreloadState();
}

class _MediaLibraryCardPreloadState extends State<MediaLibraryCardPreload> {
  final _queue = Queue<int>();
  final _requests = <ThumbnailLoadRequest>{};
  final _decodeRequests = <ThumbnailDecodeRequest>{};
  int _generation = 0, _running = 0;
  (int, int)? _range;
  bool _active = true;
  final _entryWork = RouteTransitionWork();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_schedule);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _entryWork.bind(ModalRoute.of(context));
    _active =
        widget.active &&
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    _reset();
    if (_active) _schedule();
  }

  @override
  void didUpdateWidget(MediaLibraryCardPreload oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_schedule);
      widget.controller.addListener(_schedule);
    }
    if (!identical(oldWidget.contents, widget.contents) ||
        oldWidget.geometry != widget.geometry ||
        oldWidget.active != widget.active ||
        oldWidget.decodeImages != widget.decodeImages) {
      _active =
          widget.active &&
          TickerMode.valuesOf(context).enabled &&
          (ModalRoute.isCurrentOf(context) ?? true);
      _reset();
      if (_active) _schedule();
    }
  }

  void _reset() {
    _entryWork.cancel(this);
    _range = null;
    _generation++;
    _queue.clear();
    for (final request in _requests) {
      request.dispose();
    }
    _requests.clear();
    for (final request in _decodeRequests) {
      request.dispose();
    }
    _decodeRequests.clear();
  }

  void _schedule() {
    if (!_active) return;
    // Visible Image widgets load normally. Optional ahead-of-viewport work
    // must wait for entry AND the covering route's reverse transition: eager
    // predecode on pop otherwise competes with the grid being revealed.
    _entryWork.schedule(this, () {
      if (!mounted || !_active) return;
      _updateRange();
      _pump();
    });
  }

  void _updateRange() {
    if (!widget.controller.hasClients || widget.contents.isEmpty) return;
    final position = widget.controller.position;
    if (!position.hasContentDimensions) return;
    final geometry = widget.geometry;
    final rowExtent = geometry.itemHeight + geometry.verticalSpacing;
    if (rowExtent <= 0) return;
    final row = ((position.pixels - geometry.topPadding) / rowExtent)
        .floor()
        .clamp(0, widget.contents.length);
    final rows = (position.viewportDimension / rowExtent).ceil().clamp(
      1,
      widget.contents.length,
    );
    final down = position.userScrollDirection != ScrollDirection.forward;
    final start =
        ((row - (down ? (rows / 2).ceil() : rows)) * geometry.crossAxisCount)
            .clamp(0, widget.contents.length);
    final end =
        ((row + rows + (down ? rows : (rows / 2).ceil())) *
                geometry.crossAxisCount)
            .clamp(0, widget.contents.length);
    if (_range == (start, end)) return;
    _reset();
    _range = (start, end);
    final first = (row * geometry.crossAxisCount).clamp(start, end);
    final visibleEnd = ((row + rows) * geometry.crossAxisCount).clamp(
      first,
      end,
    );
    _queue.addAll(List.generate(visibleEnd - first, (i) => first + i));
    if (down) {
      for (var i = visibleEnd; i < end; i++) {
        _queue.add(i);
      }
      for (var i = first - 1; i >= start; i--) {
        _queue.add(i);
      }
    } else {
      for (var i = first - 1; i >= start; i--) {
        _queue.add(i);
      }
      for (var i = visibleEnd; i < end; i++) {
        _queue.add(i);
      }
    }
    _pump();
  }

  void _pump() {
    while (_active && _running < 4 && _queue.isNotEmpty) {
      final index = _queue.removeFirst();
      _running++;
      unawaited(
        _prepare(index, _generation).whenComplete(() {
          _running--;
          if (mounted) _schedule();
        }),
      );
    }
  }

  Future<void> _prepare(int index, int generation) async {
    if (!mounted || generation != _generation) return;
    final item = widget.contents[index];
    if (item is VideoItem) {
      final source = CacheSource.fromItem(item);
      if (source != null) {
        unawaited(MediaCacheService.instance?.prepareCardStates([source]));
      }
    }
    if (!widget.decodeImages) return;
    final String id;
    final String? path;
    if (item is VideoItem) {
      id = item.id;
      path = item.thumbnailPath;
    } else if (item is VideoCollection) {
      id = item.id;
      path = item.thumbnailPath;
    } else {
      return;
    }
    if (path == null || path.isEmpty) return;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final configuration = createLocalImageConfiguration(context);
    final request = ThumbnailCacheService().requestThumbnail(
      id,
      path,
      prefetch: true,
    );
    _requests.add(request);
    try {
      final provider = await request.image;
      if (!mounted || generation != _generation || provider == null) return;
      final decode = ThumbnailDecodeScheduler.instance.request(
        libraryThumbnailProvider(
          provider,
          width: (widget.thumbnailWidth * dpr).round(),
          height: (widget.thumbnailHeight * dpr).round(),
        ),
        configuration,
        priority: ThumbnailDecodeScheduler.prefetchPriority,
        shouldDefer: () =>
            !mounted ||
            !_active ||
            generation != _generation ||
            (widget.controller.hasClients &&
                widget.controller.position.isScrollingNotifier.value),
      );
      _decodeRequests.add(decode);
      try {
        await decode.ready;
      } finally {
        decode.dispose();
        _decodeRequests.remove(decode);
      }
    } finally {
      request.dispose();
      _requests.remove(request);
    }
  }

  @override
  void dispose() {
    _active = false;
    _entryWork.dispose();
    widget.controller.removeListener(_schedule);
    _reset();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
