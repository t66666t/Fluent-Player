import '../../widgets/card_context_menu.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;

import '../../models/video_item.dart';
import '../../screens/collection_screen.dart';
import '../../screens/home_screen.dart';
import '../../services/library_service.dart';
import '../../services/media_playback_service.dart';
import '../../services/playback_navigation_service.dart';
import '../../services/storage_audit_models.dart';
import '../../theme/app_tokens.dart';
import '../../utils/app_toast.dart';
import '../../widgets/media_library_folder_route.dart';
import '../../widgets/media_library_anchor_menu.dart';
import '../../widgets/add_to_playlist_button.dart';
import '../../widgets/playback_queue_add_actions.dart';
import '../../widgets/transcription_queue_actions.dart';
import '../../widgets/media_library_shell.dart';
import '../../widgets/media_library_tooltip.dart';
import '../cloud_drive/models/cloud_drive_models.dart';
import '../cloud_drive/presentation/cloud_drive_screen.dart';
import '../cloud_drive/services/cloud_drive_runtime.dart';
import 'media_cache_models.dart';
import 'media_cache_screen.dart';
import 'media_cache_selection.dart';
import 'media_cache_service.dart';
import 'media_cache_widgets.dart';
import 'media_cache_variants_dialog.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

Future<void> openMediaCache(
  BuildContext context, {
  String? focusMediaKey,
}) async {
  final service = MediaCacheService.instance;
  if (service == null) {
    AppToast.show('缓存服务正在准备');
    return;
  }
  final navigator =
      MediaLibraryShell.maybeOf(context)?.libraryNavigator ??
      Navigator.of(context);
  await navigator.push(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/media_cache'),
      builder: (pageContext) => MediaCacheScreen(
        service: service,
        focusMediaKey: focusMediaKey,
        onPlay: (source, quality) async {
          final library = pageContext.read<LibraryService>();
          final item = library.getVideo(source.itemId) ?? source.toItem();
          final playback = pageContext.read<MediaPlaybackService>();
          await playback.play(
            item,
            userInitiatedWatch: true,
            cloudDriveQualityId: source.isBilibili ? null : quality,
            bilibiliQualityId: source.isBilibili
                ? int.tryParse(quality ?? '')
                : null,
          );
          if (!pageContext.mounted) return;
          if (pageContext.mounted) {
            await pushAboveMediaLibrary(
              pageContext,
              PlaybackNavigationService.buildPlaybackEntryRoute(item),
            );
          }
        },
        onLocate: (source) {
          final item = pageContext.read<LibraryService>().getVideo(
            source.itemId,
          );
          if (item != null) {
            final page = item.parentId == null
                ? HomeScreen(revealItemId: item.id, returnToSearchResults: true)
                : CollectionScreen(
                    collectionId: item.parentId!,
                    revealItemId: item.id,
                    returnToSearchResults: true,
                  );
            Navigator.of(pageContext).push(
              item.parentId == null
                  ? MaterialPageRoute<void>(builder: (_) => page)
                  : buildMediaLibraryFolderRoute<void>(
                      folderId: item.parentId!,
                      builder: (_) => page,
                    ),
            );
          } else if (source.ref.cloudDrive != null) {
            unawaited(_runLocateCloud(pageContext, source));
          } else {
            AppToast.show('该媒体尚未加入媒体库，可直接播放缓存');
          }
        },
      ),
    ),
  );
}

Future<void> _runLocateCloud(BuildContext context, CacheSource source) =>
    cacheUiAction(() async {
      final runtime = await CloudDriveRuntime.ensureInstalled();
      final ref = source.ref.cloudDrive!;
      final account = runtime.accounts.findRemote(
        ref.providerId,
        ref.remoteAccountId,
      );
      if (!context.mounted) return;
      if (account == null) {
        AppToast.show('请登录原网盘账号后定位媒体');
        return;
      }
      final directory =
          source.remoteParentId ??
          (ref.providerId == 'baidu' && ref.pathHint != null
              ? p.posix.dirname(ref.pathHint!)
              : null);
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CloudDriveScreen(
            runtime: runtime,
            initialAccount: account,
            initialDirectoryId: directory,
            initialQuery: source.title,
          ),
        ),
      );
    });

Future<void> cacheLibrarySelection(
  BuildContext context,
  LibraryService library,
  Iterable<String> ids,
) async {
  final selected = ids.toSet();
  final containsFolder = selected.any(
    (id) => library.getCollection(id) != null,
  );
  if (containsFolder) {
    await _preview(context, () {
      final collector = CacheSelectionCollector();
      return (
        collector: collector,
        load: () => collector.library(library, selected),
      );
    });
  } else {
    final sources = selected
        .map(library.getVideo)
        .whereType<VideoItem>()
        .map(CacheSource.fromItem)
        .whereType<CacheSource>()
        .toList();
    await cacheSources(context, sources);
  }
}

class MediaCacheSelectionControl extends StatelessWidget {
  const MediaCacheSelectionControl({
    super.key,
    required this.library,
    required this.ids,
    this.compact = false,
  });
  final LibraryService library;
  final Iterable<String> ids;
  final bool compact;
  @override
  Widget build(BuildContext context) {
    final service = MediaCacheService.instance;
    if (service == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final selected = ids.toSet();
        final hasFolder = selected.any(
          (id) => library.getCollection(id) != null,
        );
        final sources = selected
            .map(library.getVideo)
            .whereType<VideoItem>()
            .map(CacheSource.fromItem)
            .whereType<CacheSource>()
            .toList();
        final allCached =
            !hasFolder &&
            sources.isNotEmpty &&
            sources.every((s) => service.hasCache(s.key));
        return Material(
          color: cacheQuietBlue.withValues(alpha: .045),
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            height: 48,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Expanded(
                  child: DesktopButtonClickRegion(
                    child: TextButton(
                      onPressed: sources.isEmpty && !hasFolder
                          ? null
                          : () => unawaited(
                              cacheUiAction(
                                () => cacheLibrarySelection(
                                  context,
                                  library,
                                  selected,
                                ),
                              ),
                            ),
                      style: TextButton.styleFrom(
                        foregroundColor: cacheQuietBlue,
                        padding: EdgeInsets.symmetric(
                          horizontal: compact ? 2 : 8,
                        ),
                        minimumSize: const Size(0, 48),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.standard,
                        shape: const RoundedRectangleBorder(),
                        textStyle: TextStyle(
                          fontSize: compact ? 12 : 14,
                          fontWeight: FontWeight.w600,
                          height: 1.3,
                        ),
                      ),
                      child: compact
                          ? Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  allCached
                                      ? Icons.delete_sweep_outlined
                                      : Icons.download_outlined,
                                  size: 18,
                                ),
                                const SizedBox(height: 2),
                                SizedBox(
                                  height: 16,
                                  width: double.infinity,
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      allCached ? '删除缓存' : '缓存',
                                      maxLines: 1,
                                    ),
                                  ),
                                ),
                              ],
                            )
                          : FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    allCached
                                        ? Icons.delete_sweep_outlined
                                        : Icons.download_outlined,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    allCached ? '删除所有缓存' : '缓存',
                                    maxLines: 1,
                                  ),
                                ],
                              ),
                            ),
                    ),
                  ),
                ),
                Container(
                  width: 1,
                  height: 20,
                  color: cacheQuietBlue.withValues(alpha: .16),
                ),
                DesktopButtonClickRegion(
                  child: MediaLibraryTooltip(
                    message: '缓存画质设置',
                    child: IconButton(
                      onPressed: () => unawaited(
                        cacheUiAction(() => showMediaCacheSettings(context)),
                      ),
                      style: IconButton.styleFrom(
                        minimumSize: Size(compact ? 32 : 48, 48),
                        maximumSize: Size(compact ? 32 : 48, 48),
                        padding: EdgeInsets.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.standard,
                        shape: const RoundedRectangleBorder(),
                      ),
                      icon: const Icon(
                        Icons.tune_rounded,
                        size: 20,
                        color: cacheQuietBlue,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class CloudEntryCacheMenu extends StatelessWidget {
  const CloudEntryCacheMenu({
    super.key,
    required this.entry,
    this.cloudRuntime,
    this.onAddToLibrary,
    this.onChooseLibraryLocation,
    this.onViewInLibrary,
  });
  final CloudDriveEntry entry;
  final CloudDriveRuntime? cloudRuntime;
  final Future<void> Function()? onAddToLibrary;
  final Future<void> Function()? onChooseLibraryLocation;
  final VoidCallback? onViewInLibrary;
  @override
  Widget build(BuildContext context) {
    return CardContextMenuTarget(
      onOpen: () => unawaited(_open(context)),
      child: Semantics(
        button: true,
        label: '更多',
        child: MediaLibraryTooltip(
          message: '更多',
          child: Material(
            key: const ValueKey('cloud-entry-cache-menu'),
            color: Colors.transparent,
            child: InkWell(
              onTap: () => unawaited(_open(context)),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    final box = context.findRenderObject();
    final overlay = Navigator.of(
      context,
      rootNavigator: true,
    ).overlay?.context.findRenderObject();
    if (box is! RenderBox || overlay is! RenderBox || !box.hasSize) return;
    final anchor = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
    final source = cacheSourceForCloudEntry(entry);
    final hasCache =
        source != null &&
        MediaCacheService.instance?.hasCache(source.key) == true;
    final action = await MediaLibraryAnchorMenu.show(
      context: context,
      anchor: anchor,
      items: [
        if (entry.kind == CloudDriveEntryKind.folder ||
            entry.kind == CloudDriveEntryKind.video ||
            entry.kind == CloudDriveEntryKind.audio)
          const MediaLibraryAnchorMenuEntry(
            value: 'transcribe',
            label: transcriptionQueueLabel,
            icon: transcriptionQueueIcon,
            key: ValueKey('cloud-transcribe'),
          ),
        if (onAddToLibrary != null)
          const MediaLibraryAnchorMenuEntry(
            value: 'add_to_library',
            label: '加入媒体库',
            icon: Icons.video_library_outlined,
            key: ValueKey('cloud-add-to-library'),
          ),
        if (onChooseLibraryLocation != null)
          const MediaLibraryAnchorMenuEntry(
            value: 'choose_library_location',
            label: '选择入库位置…',
            icon: Icons.drive_folder_upload_outlined,
            key: ValueKey('cloud-choose-library-location'),
          ),
        if (onViewInLibrary != null)
          const MediaLibraryAnchorMenuEntry(
            value: 'view_in_library',
            label: '在媒体库中查看',
            icon: Icons.folder_open_outlined,
            key: ValueKey('cloud-view-in-library'),
          ),
        if (entry.kind == CloudDriveEntryKind.video ||
            entry.kind == CloudDriveEntryKind.audio)
          const MediaLibraryAnchorMenuEntry(
            value: 'add_to_playlist',
            label: AddToPlaylistButton.defaultLabel,
            icon: AddToPlaylistButton.icon,
            key: ValueKey('cloud-add-to-playlist'),
          ),
        if (MediaCacheService.instance != null)
          MediaLibraryAnchorMenuEntry(
            value: 'cache',
            label: hasCache ? '缓存其他画质' : '缓存',
            icon: CupertinoIcons.arrow_down_to_line,
          ),
        if (hasCache)
          const MediaLibraryAnchorMenuEntry(
            value: 'delete',
            label: '删除所有缓存',
            icon: CupertinoIcons.trash,
          ),
        if (source != null && MediaCacheService.instance != null)
          const MediaLibraryAnchorMenuEntry(
            value: 'manage',
            label: '管理缓存',
            icon: CupertinoIcons.tray,
          ),
      ],
    );
    if (action == null || !context.mounted) return;
    if (action == 'transcribe') {
      await openTranscriptionQueue(
        context,
        TranscriptionMediaSelection(cloudEntries: [entry]),
        cloudRuntime: cloudRuntime,
      );
      return;
    }
    if (action == 'add_to_library') {
      await onAddToLibrary?.call();
      return;
    }
    if (action == 'choose_library_location') {
      await onChooseLibraryLocation?.call();
      return;
    }
    if (action == 'view_in_library') {
      onViewInLibrary?.call();
      return;
    }
    if (action == 'add_to_playlist') {
      await addCloudSelectionToQueue(context, [entry]);
      return;
    }
    await cacheUiAction(() async {
      if (action == 'manage' && source != null) {
        await showCacheQualities(context, source);
      } else if (action == 'delete' && source != null) {
        await deleteCacheSources(context, [source]);
      } else if (source != null &&
          MediaCacheService.instance?.hasCache(source.key) == true) {
        await showCacheQualities(context, source);
      } else {
        await cacheCloudSelection(context, [entry]);
      }
    });
  }
}

Future<void> cacheCloudSelection(
  BuildContext context,
  Iterable<CloudDriveEntry> entries,
) async {
  final selected = entries.toList();
  if (selected.any((e) => e.kind == CloudDriveEntryKind.folder)) {
    await _preview(context, () {
      final collector = CacheSelectionCollector();
      return (collector: collector, load: () => collector.cloud(selected));
    });
  } else {
    await cacheSources(
      context,
      selected.map(cacheSourceForCloudEntry).whereType<CacheSource>().toList(),
    );
  }
}

Future<void> cacheSources(
  BuildContext context,
  List<CacheSource> sources,
) async {
  final service = MediaCacheService.instance;
  if (service == null) return;
  await cacheUiAction(() async {
    await service.initialize();
    if (sources.isEmpty) {
      AppToast.show('所选内容中没有可缓存的 B 站或网盘媒体');
      return;
    }
    if (!context.mounted) return;
    if (sources.every((s) => service.hasCache(s.key))) {
      await deleteCacheSources(context, sources);
      return;
    }
    final count = await service.enqueueAll(sources);
    AppToast.show(count > 0 ? '已加入 $count 个缓存任务' : '所选媒体已在缓存任务中');
  });
}

Future<void> cacheSingleMedia(BuildContext context, VideoItem item) async {
  final source = CacheSource.fromItem(item);
  final service = MediaCacheService.instance;
  if (source == null || service == null) return;
  await cacheUiAction(() async {
    await service.initialize();
    if (!context.mounted) return;
    if (service.hasCache(source.key)) {
      await showCacheQualities(context, source);
    } else {
      await service.enqueue(source);
      AppToast.show('已加入缓存任务');
    }
  });
}

Future<void> deleteCacheSources(
  BuildContext context,
  Iterable<CacheSource> sources,
) async {
  final service = MediaCacheService.instance;
  if (service == null) return;
  final unique = {for (final source in sources) source.key: source};
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('删除所有缓存'),
      content: Text('删除 ${unique.length} 项媒体的全部画质缓存及未完成任务？在线来源、字幕和观看记录会保留。'),
      actions: [
        DesktopButtonClickRegion(
          child: TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('保留'),
          ),
        ),
        DesktopButtonClickRegion(
          child: TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除缓存'),
          ),
        ),
      ],
    ),
  );
  if (confirmed == true) {
    await cacheUiAction(() async {
      for (final key in unique.keys) {
        await service.deleteAll(key);
      }
    });
  }
}

Future<void> showCacheQualities(
  BuildContext context,
  CacheSource source,
) async {
  final service = MediaCacheService.instance;
  if (service == null) return;
  await service.initialize();
  await service.discoverMaterial(source);
  await service.refreshAvailability(mediaKey: source.key);
  if (!context.mounted || mediaLibraryRouteIsCurrent(context) == false) return;
  MediaPlaybackService? playback;
  try {
    playback = context.read<MediaPlaybackService>();
  } on ProviderNotFoundException {
    // A standalone preview or tests may not provide a playback session.
  }
  final inShell = MediaLibraryShell.maybeOf(context) != null;
  await showDialog<void>(
    context: context,
    useSafeArea: false,
    routeSettings: const RouteSettings(name: '/media_cache/variants'),
    builder: (_) => MediaCacheVariantsDialog(
      key: ValueKey(source.key),
      service: service,
      source: source,
      playback: playback,
      reserveMiniPlayer: inShell,
      selectionBarHeight: inShell
          ? MediaLibraryShell.selectionBarObstructionPeek(context)
          : 0,
    ),
  );
}

typedef _CollectionJob = ({
  CacheSelectionCollector collector,
  Future<void> Function() load,
});
Future<void> _preview(
  BuildContext context,
  _CollectionJob Function() create,
) async {
  await showDialog<void>(
    context: context,
    builder: (_) => _CachePreview(create: create),
  );
}

class _CachePreview extends StatefulWidget {
  const _CachePreview({required this.create});
  final _CollectionJob Function() create;
  @override
  State<_CachePreview> createState() => _CachePreviewState();
}

class _CachePreviewState extends State<_CachePreview> {
  late _CollectionJob _job;
  final _excluded = <String>{};
  String? _error;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _job = widget.create();
    _job.collector.addListener(_changed);
    unawaited(
      _job.load().catchError((Object _) {
        if (mounted) setState(() => _error = '文件夹未能完整读取，请重试；尚未开始下载。');
      }),
    );
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _release() {
    _job.collector.cancel();
    _job.collector.removeListener(_changed);
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final collector = _job.collector;
    final sources = collector.sources.values.toList();
    return AlertDialog(
      title: const Text('确认缓存范围'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${sources.length} 项媒体${collector.skipped == 0 ? '' : ' · 已跳过 ${collector.skipped} 项非媒体'}',
            ),
            if (collector.knownBytes > 0)
              Text(
                '已知原文件大小 ${formatStorageSize(collector.knownBytes)}，转码大小以实际画质为准',
                style: const TextStyle(color: AppTokens.text3, fontSize: 12),
              ),
            const SizedBox(height: 10),
            if (collector.loading) ...[
              const LinearProgressIndicator(minHeight: 2),
              const SizedBox(height: 8),
              Text(
                '正在读取 ${collector.currentName}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppTokens.text2),
              ),
            ],
            if (_error != null) ...[
              Text(_error!),
              DesktopButtonClickRegion(
                child: TextButton(
                  onPressed: () {
                    _release();
                    _error = null;
                    _excluded.clear();
                    _load();
                    setState(() {});
                  },
                  child: const Text('重新读取'),
                ),
              ),
            ],
            if (sources.isNotEmpty)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * .35,
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: sources.length,
                  itemBuilder: (_, i) {
                    final source = sources[i];
                    return CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(
                        source.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(source.providerLabel),
                      value: !_excluded.contains(source.key),
                      onChanged: _busy
                          ? null
                          : (v) => setState(() {
                              if (v == true) {
                                _excluded.remove(source.key);
                              } else {
                                _excluded.add(source.key);
                              }
                            }),
                    );
                  },
                ),
              ),
            if (!collector.loading && _error == null && sources.isEmpty)
              const Text('没有可缓存的媒体'),
          ],
        ),
      ),
      actions: [
        DesktopButtonClickRegion(
          child: TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ),
        DesktopButtonClickRegion(
          child: FilledButton.tonal(
            onPressed:
                collector.loading ||
                    _error != null ||
                    _busy ||
                    sources.length == _excluded.length
                ? null
                : () async {
                    setState(() => _busy = true);
                    await cacheSources(
                      context,
                      sources.where((s) => !_excluded.contains(s.key)).toList(),
                    );
                    if (context.mounted) Navigator.pop(context);
                  },
            child: Text('缓存 ${sources.length - _excluded.length} 项'),
          ),
        ),
      ],
    );
  }
}
