import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/video_item.dart';
import '../../services/media_playback_service.dart';
import '../../services/storage_audit_models.dart';
import '../../services/storage_audit_service.dart' show storagePathKey;
import '../../utils/stable_system_ui_insets.dart';
import '../../widgets/playback_card_layout.dart';
import 'media_cache_models.dart';
import 'media_cache_service.dart';
import 'media_cache_widgets.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Manages one media identity. Transfers remain owned by the cache service;
/// opening, closing or refreshing this window never switches playback quality.
class MediaCacheVariantsDialog extends StatefulWidget {
  const MediaCacheVariantsDialog({
    super.key,
    required this.service,
    required this.source,
    this.playback,
    this.reserveMiniPlayer = false,
    this.selectionBarHeight = 0,
  });

  final MediaCacheService service;
  final CacheSource source;
  final MediaPlaybackService? playback;
  final bool reserveMiniPlayer;
  final double selectionBarHeight;

  @override
  State<MediaCacheVariantsDialog> createState() =>
      _MediaCacheVariantsDialogState();
}

class _MediaCacheVariantsDialogState extends State<MediaCacheVariantsDialog> {
  final _bodyScroll = ScrollController(), _windowScroll = ScrollController();
  late final _insets = StableSystemUiInsetController(
    includeSystemGestureInsets: true,
    onChanged: () {
      if (mounted) setState(() {});
    },
  );
  late final VoidCallback _release;
  final Set<String> _busy = {};
  List<CacheQuality> _remote = [];
  bool _loading = true;
  int _request = 0;
  String? _loadError, _actionError;

  @override
  void initState() {
    super.initState();
    widget.service.addListener(_changed);
    widget.playback?.addListener(_changed);
    _release = widget.service.observeMediaAvailability(widget.source.key);
    unawaited(
      widget.service
          .refreshAvailability(mediaKey: widget.source.key)
          .catchError((Object _) {}),
    );
    unawaited(_loadQualities());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _loadQualities() async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final qualities = await widget.service.backend.qualities(widget.source);
      if (!mounted || request != _request) return;
      setState(() {
        _remote = qualities;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || request != _request) return;
      setState(() {
        _loading = false;
        _loadError = '暂时无法获取在线版本，已有缓存仍可管理。';
      });
    }
  }

  Future<void> _run(String id, Future<void> Function() operation) async {
    if (_busy.contains(id) || _busy.contains('*')) return;
    setState(() {
      _busy.add(id);
      _actionError = null;
    });
    try {
      await operation();
    } catch (_) {
      if (mounted) setState(() => _actionError = '操作未完成，请稍后重试。');
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _deleteAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除全部缓存'),
        scrollable: true,
        content: const Text('删除此媒体的全部画质缓存，并取消它的缓存任务？在线来源、字幕和观看记录会保留。'),
        actions: [
          DesktopButtonClickRegion(
            child: TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('保留'),
            ),
          ),
          DesktopButtonClickRegion(
            child: TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除缓存'),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _run('*', () => widget.service.deleteAll(widget.source.key));
    }
  }

  List<CacheTask> get _tasks => widget.service.tasks
      .where((task) => task.source.key == widget.source.key && task.unfinished)
      .toList();

  Widget _header() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 10, 8, 6),
    child: Row(
      children: [
        const Expanded(
          child: Text(
            '管理缓存',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
        ),
        DesktopButtonClickRegion(
          child: IconButton(
            tooltip: '刷新可缓存画质',
            onPressed: _loading ? null : () => unawaited(_loadQualities()),
            icon: const Icon(Icons.refresh_rounded, size: 21),
          ),
        ),
        DesktopButtonClickRegion(
          child: IconButton(
            key: const ValueKey('cache-variants-close'),
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded, size: 21),
          ),
        ),
      ],
    ),
  );

  int _priority(CacheTask task) => task.state.running
      ? 0
      : task.state == CacheTaskState.queued
      ? 1
      : task.state == CacheTaskState.failed
      ? 3
      : 2;

  Widget _quality(CacheQuality quality, List<CacheTask> tasks) {
    final service = widget.service;
    final variants = service
        .variantsFor(widget.source.key)
        .where((variant) => variant.quality.id == quality.id)
        .toList();
    final pending = service.variants.any(
      (variant) =>
          variant.source.key == widget.source.key &&
          variant.quality.id == quality.id &&
          variant.pendingDelete,
    );
    final matching =
        tasks
            .where(
              (task) =>
                  task.quality?.id == quality.id ||
                  task.requestedQuality == quality.id ||
                  quality.id == 'auto' &&
                      task.quality == null &&
                      task.requestedQuality == null,
            )
            .toList()
          ..sort((a, b) => _priority(a).compareTo(_priority(b)));
    final task = matching.firstOrNull;
    final files = {for (final v in variants) storagePathKey(v.path): v.bytes};
    final bytes = files.values.fold<int>(0, (a, b) => a + b);
    final cached = variants.any((v) => v.completeMedia);
    final reusable = variants.isNotEmpty;
    final busy = _busy.contains(quality.id) || _busy.contains('*');
    final downloadable = _remote.any((q) => q.id == quality.id && q.available);
    final status = pending && !cached
        ? '使用结束后删除'
        : cached
        ? '已缓存 · ${formatStorageSize(bytes)}'
        : reusable
        ? '${variants.first.contentLabel} · ${formatStorageSize(bytes)}'
        : task != null
        ? task.state.label
        : downloadable
        ? '未缓存'
        : _loading
        ? '正在获取画质'
        : '当前暂不可缓存';
    final actions = <Widget>[];
    void action(
      String tooltip,
      IconData icon,
      Future<void> Function()? operation,
    ) {
      actions.add(
        DesktopButtonClickRegion(
          child: IconButton(
            tooltip: tooltip,
            onPressed: busy || operation == null
                ? null
                : () => unawaited(_run(quality.id, operation)),
            icon: Icon(icon, size: 21),
          ),
        ),
      );
    }

    if (reusable) {
      action('删除 ${quality.label} 缓存', Icons.delete_outline_rounded, () async {
        for (final variant in variants) {
          await service.deleteVariant(variant.id);
        }
      });
    }
    if (task != null) {
      if (task.state.canPause) {
        action(
          '暂停 ${quality.label}',
          Icons.pause_rounded,
          () => service.pause(task.id),
        );
      } else {
        action(
          '${task.state.primaryActionLabel} ${quality.label}',
          task.state.canRetry
              ? Icons.refresh_rounded
              : Icons.play_arrow_rounded,
          () => service.resume(task.id),
        );
      }
      action(
        '取消 ${quality.label} 任务',
        Icons.close_rounded,
        () => service.cancel(task.id),
      );
    } else if (!cached && !pending) {
      action(
        reusable ? '补齐 ${quality.label} 缓存' : '缓存 ${quality.label}',
        Icons.download_rounded,
        downloadable
            ? () async {
                await service.enqueue(widget.source, qualityId: quality.id);
              }
            : null,
      );
    }
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          quality.label,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 5),
        Text(
          status,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        if (task?.state.running == true && cached)
          Text(task!.state.label, style: const TextStyle(fontSize: 12)),
        if (task?.progress != null &&
            !cached &&
            (task!.state.running || task.state == CacheTaskState.paused))
          Text(
            '${(task.progress! * 100).floor()}%${task.bytesPerSecond > 0 ? ' · ${cacheSpeed(task.bytesPerSecond)}' : ''}',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        if (task?.error != null)
          Text(
            task!.error!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
    return Container(
      key: ValueKey('cache-variant-quality-${quality.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Theme.of(
            context,
          ).colorScheme.outlineVariant.withValues(alpha: .35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final controls = Wrap(
                spacing: 2,
                alignment: WrapAlignment.end,
                children: actions,
              );
              if (constraints.maxWidth < 340 ||
                  MediaQuery.textScalerOf(context).scale(14) > 20) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [details, const SizedBox(height: 4), controls],
                );
              }
              return Row(
                children: [
                  Expanded(child: details),
                  const SizedBox(width: 12),
                  controls,
                ],
              );
            },
          ),
          if (task?.state.running == true) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: task!.progress,
                minHeight: 3,
                color: cacheQuietBlue,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _contents() {
    final variants = widget.service.variantsFor(widget.source.key);
    final tasks = _tasks;
    final values = <String, CacheQuality>{for (final q in _remote) q.id: q};
    for (final variant in variants) {
      values.putIfAbsent(variant.quality.id, () => variant.quality);
    }
    for (final task in tasks) {
      final quality =
          task.quality ??
          CacheQuality(
            id: task.requestedQuality ?? 'auto',
            label: task.requestedQuality == null
                ? '自动选择画质'
                : '${task.requestedQuality}',
          );
      values.putIfAbsent(quality.id, () => quality);
    }
    for (final variant in widget.service.variants.where(
      (v) => v.source.key == widget.source.key && v.pendingDelete,
    )) {
      values.putIfAbsent(variant.quality.id, () => variant.quality);
    }
    final qualities = values.values.toList()
      ..sort((a, b) {
        int rank(CacheQuality q) =>
            q.id == 'original' ? 100000 : q.resolutionHeight ?? 0;
        return rank(b).compareTo(rank(a));
      });
    final count = variants
        .where((v) => v.completeMedia)
        .map((v) => v.quality.id)
        .toSet()
        .length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.source.title,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 5),
          Text(
            '${widget.source.providerLabel} · $count 个已缓存${widget.source.kind == MediaType.audio ? '音质' : '画质'}',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 18),
          if (_loading)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(
                children: [
                  const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: cacheQuietBlue,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.source.kind == MediaType.audio
                          ? '正在获取可缓存音质'
                          : '正在获取可缓存画质',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          for (final quality in qualities) _quality(quality, tasks),
          if (!_loading && qualities.isEmpty && _loadError == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text('当前没有可缓存的版本'),
            ),
          if (_loadError != null) ...[
            Text(
              _loadError!,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: DesktopButtonClickRegion(
                child: TextButton.icon(
                  onPressed: () => unawaited(_loadQualities()),
                  icon: const Icon(Icons.refresh, size: 17),
                  label: const Text('重新获取'),
                ),
              ),
            ),
          ],
          if (_actionError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_actionError!, style: const TextStyle(fontSize: 12)),
            ),
          if (variants.isNotEmpty) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: DesktopButtonClickRegion(
                child: TextButton.icon(
                  key: const ValueKey('cache-variants-delete-all'),
                  onPressed: _busy.isEmpty
                      ? () => unawaited(_deleteAll())
                      : null,
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  label: const Text('删除全部缓存'),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final safeBottom = _insets
        .observe(media, active: ModalRoute.isCurrentOf(context) ?? true)
        .bottom;
    final miniVisible =
        widget.reserveMiniPlayer &&
        widget.playback?.shouldShowMiniPlaybackCard == true;
    final bottom = PlaybackCardOverlayLayout.contentBottomPadding(
      stableBottomInset: safeBottom,
      selectionBarHeight: widget.selectionBarHeight,
      cardHeight: PlaybackCardLayout.calculate(context).height,
      isCardVisible: miniVisible,
    );
    final horizontal = media.size.width < 600 ? 12.0 : 24.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        math.max(media.viewPadding.left, media.systemGestureInsets.left) +
            horizontal,
        math.max(media.padding.top, media.viewPadding.top) + 12,
        math.max(media.viewPadding.right, media.systemGestureInsets.right) +
            horizontal,
        math.max(bottom, media.viewInsets.bottom) + 12,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final height = math.min(620.0, constraints.maxHeight);
          if (height <= 0) return const SizedBox.shrink();
          final short = height < 240;
          Widget scroll(Widget child, ScrollController controller) => Scrollbar(
            controller: controller,
            thumbVisibility: media.size.width >= 600,
            child: SingleChildScrollView(controller: controller, child: child),
          );
          return Center(
            child: SizedBox(
              width: math.min(560.0, constraints.maxWidth),
              child: MediaQuery.removeViewInsets(
                context: context,
                removeBottom: true,
                child: Dialog(
                  insetPadding: EdgeInsets.zero,
                  clipBehavior: Clip.antiAlias,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: ConstrainedBox(
                    key: const ValueKey('media-cache-variants-dialog'),
                    constraints: BoxConstraints(maxHeight: height),
                    child: short
                        ? scroll(
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [_header(), _contents()],
                            ),
                            _windowScroll,
                          )
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _header(),
                              const Divider(height: 1),
                              Flexible(
                                fit: FlexFit.loose,
                                child: scroll(_contents(), _bodyScroll),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _request++;
    _release();
    widget.service.removeListener(_changed);
    widget.playback?.removeListener(_changed);
    _insets.dispose();
    _bodyScroll.dispose();
    _windowScroll.dispose();
    super.dispose();
  }
}
