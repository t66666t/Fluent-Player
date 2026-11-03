import 'package:flutter/material.dart';

import '../../models/video_item.dart';
import '../../services/library_service.dart';
import '../media_cache/media_cache_actions.dart';
import '../media_cache/media_cache_models.dart';
import '../media_cache/media_cache_service.dart';
import 'portable_export_readiness.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Uses the existing per-media quality picker and durable download queue.
class PortableExportCacheDialog extends StatefulWidget {
  const PortableExportCacheDialog({
    super.key,
    required this.library,
    required this.rootIds,
    required this.missing,
    this.forSync = false,
  });

  final LibraryService library;
  final List<String> rootIds;
  final List<VideoItem> missing;
  final bool forSync;

  @override
  State<PortableExportCacheDialog> createState() =>
      _PortableExportCacheDialogState();
}

class _PortableExportCacheDialogState extends State<PortableExportCacheDialog> {
  late List<VideoItem> _missing = widget.missing;
  bool _busy = false;
  String? _error;

  Future<void> _check() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final missing = await uncachedCloudExportItems(
        widget.library,
        widget.rootIds,
      );
      if (!mounted) return;
      if (missing.isEmpty) {
        Navigator.of(context).pop(true);
      } else {
        setState(() => _missing = missing);
      }
    } catch (_) {
      if (mounted) setState(() => _error = '无法检查缓存，请稍后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _choose(VideoItem item) async {
    final source = CacheSource.fromItem(item);
    if (source == null || MediaCacheService.instance == null) {
      setState(() => _error = '缓存服务暂不可用，请稍后重试。');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await showCacheQualities(context, source);
    } catch (_) {
      if (mounted) setState(() => _error = '无法打开画质列表，请检查登录和网络后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('先缓存网盘媒体'),
    scrollable: true,
    content: SizedBox(
      width: 480,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.forSync
                ? '迁移网盘媒体需要完整的本地文件。请选择可用画质缓存，完成后继续；播放分片、未完成下载和单独音视频轨不能用于迁移。接收端可直接离线播放，不需要登录原网盘。'
                : '导出需要完整的本地媒体。请选择可用画质缓存；未完成的下载、播放分片和单独音视频轨不能用于导出。缓存任务会在后台继续。',
          ),
          const SizedBox(height: 12),
          for (final item in _missing)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  DesktopButtonClickRegion(
                    child: TextButton.icon(
                      onPressed: _busy ? null : () => _choose(item),
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('选择缓存画质'),
                    ),
                  ),
                ],
              ),
            ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      DesktopButtonClickRegion(
        child: TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(widget.forSync ? '稍后迁移' : '稍后导出'),
        ),
      ),
      DesktopButtonClickRegion(
        child: FilledButton(
          onPressed: _busy ? null : _check,
          child: Text(_busy ? '正在检查' : '检查缓存并继续'),
        ),
      ),
    ],
  );
}
