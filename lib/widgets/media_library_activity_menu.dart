import 'card_context_menu.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_haptics.dart';
import '../services/settings_service.dart';
import '../features/progress_sync/progress_sync_service.dart';
import '../features/progress_sync/progress_sync_screen.dart';
import '../features/progress_sync/folder_sync_models.dart';
import '../features/progress_sync/folder_sync_settings_sheet.dart';

import '../features/portable_transfer/portable_transfer_navigation.dart';
import '../models/video_item.dart';
import '../services/library_service.dart';
import '../services/media_playback_service.dart';
import '../utils/app_toast.dart';
import '../utils/source_media_file_actions.dart';
import 'media_library_anchor_menu.dart';
import 'media_library_tooltip.dart';
import 'library_rename_dialog.dart';
import 'add_to_playlist_button.dart';
import 'playback_queue_add_actions.dart';
import 'transcription_queue_actions.dart';

/// Rename / pin / hide / locate / recycle / export overflow for library cards.
///
/// Hide never stops playback. Recycle and export act on this card
/// only. Move-to-parent is shown only when [onMoveToParent] is set, which is
/// the opened-folder page and not continue, recent, search, or the library root.
/// [allowHide] is continue-learning only. [allowDismissFromRecent] hides a
/// recent-added card without touching continue-learning or history.
/// The visible ⋯ lives on the bottom-right action dock, not on the cover.
class MediaLibraryActivityMenuMetrics {
  /// Visible "⋯" size. Tracks card width so a 3-column phone stays small.
  static double glyphSize(double cardWidth) =>
      (cardWidth * 0.12).clamp(12.0, 20.0);

  /// Layout slot in the title row, matched to the first title line.
  static double layoutSize(double cardWidth) =>
      (cardWidth * 0.14).clamp(14.0, 22.0);

  /// Finger/cursor target. Extra area extends left and down into the info
  /// block, not up onto the cover.
  static double hitSize(double cardWidth) {
    final layout = layoutSize(cardWidth);
    return math.max(layout, math.min(40.0, cardWidth * 0.36));
  }
}

class MediaLibraryActivityMenuButton extends StatefulWidget {
  const MediaLibraryActivityMenuButton({
    super.key,
    required this.targetId,
    required this.isCollection,
    this.allowHide = false,
    this.allowDismissFromRecent = false,
    this.allowHidePodcastFromFolders = false,
    this.onLocate,
    this.onHidden,
    this.onMoveToParent,
    this.cardWidth,
    this.fillSlot = false,
  });

  final String targetId;
  final bool isCollection;
  final bool allowHide;

  /// Shows 「从本页移除」 for a 最近添加 media or folder card.
  final bool allowDismissFromRecent;

  /// Retained for old callers; subscription actions are unavailable locally.
  final bool allowHidePodcastFromFolders;
  final VoidCallback? onLocate;
  final VoidCallback? onHidden;

  /// Moves this card to the folder that contains the folder currently open.
  /// Null on continue, recent, search, and the library root.
  final VoidCallback? onMoveToParent;

  /// Grid cell / list cell width used to scale glyph and hit target.
  final double? cardWidth;

  /// Transparent hit layer; the action dock paints the ⋯ glyph.
  final bool fillSlot;

  @override
  State<MediaLibraryActivityMenuButton> createState() =>
      _MediaLibraryActivityMenuButtonState();
}

class _MediaLibraryActivityMenuButtonState
    extends State<MediaLibraryActivityMenuButton> {
  bool _opening = false;

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryService>();
    final pinned = library.activityProjection.isPinned(widget.targetId);
    final ink = Material(
      key: const ValueKey('media-library-activity-menu'),
      color: Colors.transparent,
      child: InkWell(
        onTap: () => unawaited(_openMenu(library, pinned: pinned)),
        child: widget.fillSlot ? const SizedBox.expand() : _standaloneGlyph(),
      ),
    );
    return CardContextMenuTarget(
      onOpen: () => unawaited(_openMenu(library, pinned: pinned)),
      child: Semantics(
        button: true,
        label: '更多',
        child: MediaLibraryTooltip(
          message: '更多',
          child: widget.fillSlot ? ink : _standaloneFrame(ink),
        ),
      ),
    );
  }

  Widget _standaloneGlyph() {
    final extent = widget.cardWidth ?? 160;
    final glyph = MediaLibraryActivityMenuMetrics.glyphSize(extent);
    final layout = MediaLibraryActivityMenuMetrics.layoutSize(extent);
    return Align(
      alignment: Alignment.topRight,
      child: SizedBox(
        width: layout,
        height: layout,
        child: Icon(
          Icons.more_horiz,
          color: const Color(0xE6FFFFFF),
          size: glyph,
        ),
      ),
    );
  }

  Widget _standaloneFrame(Widget ink) {
    final extent = widget.cardWidth ?? 160;
    final layout = MediaLibraryActivityMenuMetrics.layoutSize(extent);
    final hit = MediaLibraryActivityMenuMetrics.hitSize(extent);
    return SizedBox(
      width: layout,
      height: layout,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(top: 0, right: 0, width: hit, height: hit, child: ink),
        ],
      ),
    );
  }

  Future<void> _openMenu(LibraryService library, {required bool pinned}) async {
    if (_opening || !mounted) return;
    _opening = true;
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.maybeOf(context, rootOverlay: true)?.context.findRenderObject()
            as RenderBox?;
    if (box == null || overlay == null || !box.hasSize) {
      _opening = false;
      return;
    }
    final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
    final anchor = origin & box.size;
    final VideoItem? localMedia = !widget.isCollection
        ? library.getVideo(widget.targetId)
        : null;
    final sourceActions = SourceMediaFileActions();
    final canAccessSource =
        localMedia != null && sourceActions.pathFor(localMedia) != null;
    final items = <MediaLibraryAnchorMenuEntry>[
      const MediaLibraryAnchorMenuEntry(
        value: 'transcribe',
        label: transcriptionQueueLabel,
        icon: transcriptionQueueIcon,
        key: ValueKey('media-library-transcribe'),
      ),
      if (!widget.isCollection)
        const MediaLibraryAnchorMenuEntry(
          value: 'add_to_playlist',
          label: AddToPlaylistButton.defaultLabel,
          icon: AddToPlaylistButton.icon,
          key: ValueKey('media-library-add-to-playlist'),
        ),
      const MediaLibraryAnchorMenuEntry(
        value: 'rename',
        label: '重命名',
        icon: CupertinoIcons.pencil,
      ),
      MediaLibraryAnchorMenuEntry(
        value: pinned ? 'unpin' : 'pin',
        label: pinned ? '取消「继续学习」置顶' : '置顶到「继续学习」',
        icon: pinned ? CupertinoIcons.pin_slash : CupertinoIcons.pin,
      ),
      if (widget.onLocate != null)
        const MediaLibraryAnchorMenuEntry(
          value: 'locate',
          label: '显示所在目录',
          icon: CupertinoIcons.folder,
        ),
      if (widget.onMoveToParent != null)
        const MediaLibraryAnchorMenuEntry(
          value: 'parent',
          label: '移动到上一级',
          icon: CupertinoIcons.arrow_turn_up_left,
        ),
      const MediaLibraryAnchorMenuEntry(
        value: 'export',
        label: '导出',
        icon: CupertinoIcons.square_arrow_up,
      ),
      if (widget.isCollection)
        const MediaLibraryAnchorMenuEntry(
          value: 'send_folder',
          label: '同步到设备',
          icon: CupertinoIcons.arrow_2_circlepath,
        ),
      const MediaLibraryAnchorMenuEntry(
        value: 'recycle',
        label: '移入回收站',
        icon: CupertinoIcons.trash,
      ),
      if (canAccessSource)
        MediaLibraryAnchorMenuEntry(
          value: 'source_file',
          label: sourceActions.label,
          icon: sourceActions.isMobile
              ? CupertinoIcons.square_arrow_up
              : CupertinoIcons.folder_open,
          key: const ValueKey('source-media-file-menu'),
        ),
      if (widget.allowDismissFromRecent)
        const MediaLibraryAnchorMenuEntry(
          value: 'dismiss_recent',
          label: '从本页移除',
          icon: CupertinoIcons.eye_slash,
        ),
      if (!widget.isCollection &&
          widget.allowHide &&
          !widget.allowDismissFromRecent)
        const MediaLibraryAnchorMenuEntry(
          value: 'hide',
          label: '从本页移除',
          icon: CupertinoIcons.eye_slash,
        ),
    ];
    try {
      // Opening the card menu is a selection boundary. The raw platform call
      // used to ignore the vibration switch.
      unawaited(AppHaptics.selectionClick(SettingsService()));
      final action = await MediaLibraryAnchorMenu.show(
        context: context,
        anchor: anchor,
        items: items,
      );
      if (!mounted || action == null) return;
      await _onSelected(library, action, sourceAnchor: anchor);
    } finally {
      _opening = false;
    }
  }

  Future<void> _onSelected(
    LibraryService library,
    String value, {
    Rect? sourceAnchor,
  }) async {
    switch (value) {
      case 'transcribe':
        await openTranscriptionQueue(
          context,
          TranscriptionMediaSelection(libraryIds: [widget.targetId]),
        );
        return;
      case 'add_to_playlist':
        await addLibrarySelectionToQueue(context, [widget.targetId]);
        return;
      case 'rename':
        final name = widget.isCollection
            ? library.getCollection(widget.targetId)?.name
            : library.getVideo(widget.targetId)?.title;
        if (name == null) return;
        await showLibraryRenameDialog(
          context: context,
          itemId: widget.targetId,
          currentName: name,
        );
        return;
      case 'send_folder':
      case 'progress_sync':
        ProgressSyncService? sync;
        try {
          sync = context.read<ProgressSyncService>();
        } on ProviderNotFoundException {
          return;
        }
        await openProgressSync(
          context,
          sync,
          collectionId: widget.targetId,
          sendFolder: true,
        );
        return;
      case 'pin':
        await library.pinLibraryItem(widget.targetId);
        return;
      case 'unpin':
        await library.unpinLibraryItem(widget.targetId);
        return;
      case 'locate':
        widget.onLocate?.call();
        return;
      case 'parent':
        widget.onMoveToParent?.call();
        return;
      case 'export':
        await PortableTransferNavigation.openExportSettings(context, [
          widget.targetId,
        ]);
        return;
      case 'recycle':
        final syncRoot = _syncRootFor(library, widget.targetId);
        if (syncRoot != null) {
          final sync = context.read<ProgressSyncService>();
          final settings = sync.folderSettings(syncRoot);
          final allowEverywhere =
              settings.mode == FolderSyncMode.smart ||
              (settings.mode == FolderSyncMode.oneWay &&
                  settings.sourceDeviceId == sync.deviceId);
          final itemName =
              library.getCollection(widget.targetId)?.name ??
              library.getVideo(widget.targetId)?.title ??
              '此项目';
          final everywhere = await showSyncedItemRemoval(
            context,
            name: itemName,
            isRoot: syncRoot == widget.targetId,
            allowEverywhere: allowEverywhere,
          );
          if (everywhere == null || !mounted) return;
          try {
            await context.read<ProgressSyncService>().removeSyncedItem(
              syncRoot,
              widget.targetId,
              everywhere: everywhere,
            );
            if (mounted) AppToast.show('已移入回收站', type: AppToastType.success);
          } catch (_) {
            if (mounted) AppToast.show('暂未移除，请稍后重试', type: AppToastType.error);
          }
          return;
        }
        await library.moveToRecycleBin([widget.targetId]);
        if (!mounted) return;
        AppToast.show('已移入回收站', type: AppToastType.success);
        return;
      case 'source_file':
        // Re-read after the menu closes: recovery/sync may have updated the
        // card's source while it was open.
        await _accessSourceMedia(
          library.getVideo(widget.targetId),
          anchor: sourceAnchor,
        );
        return;
      case 'hide':
        // Block the current watch cycle from immediately undoing hide.
        MediaPlaybackService().noteLibraryMediaHidden(widget.targetId);
        await library.hideLibraryMedia(widget.targetId);
        widget.onHidden?.call();
        return;
      case 'dismiss_recent':
        final targetId = widget.targetId;
        final removed = await library.dismissFromRecentAdded(targetId);
        if (!removed) return;
        // The card rebuilds away as soon as the library notifies, so the
        // undo action closes over the service instead of this State.
        AppToast.show(
          '已从本页移除',
          type: AppToastType.success,
          duration: const Duration(seconds: 4),
          action: AppToastAction(
            label: '撤销',
            onPressed: () {
              unawaited(library.restoreRecentAdded(targetId));
            },
          ),
        );
        return;
    }
  }

  String? _syncRootFor(LibraryService library, String itemId) {
    ProgressSyncService service;
    try {
      service = context.read<ProgressSyncService>();
    } on ProviderNotFoundException {
      return null;
    }
    final roots = service.bindings
        .map((binding) => binding.collectionId)
        .toSet();
    String? id = itemId;
    final visited = <String>{};
    while (id != null && visited.add(id)) {
      if (roots.contains(id)) return id;
      id =
          library.getCollection(id)?.parentId ?? library.getVideo(id)?.parentId;
    }
    return null;
  }

  Future<void> _accessSourceMedia(VideoItem? item, {Rect? anchor}) async {
    if (item == null) {
      AppToast.show('源媒体文件已不存在', type: AppToastType.error);
      return;
    }
    final actions = SourceMediaFileActions();
    final loading = AppToast.showLoading(
      actions.isMobile ? '正在打开分享菜单…' : '正在定位源文件…',
    );
    final SourceMediaFileResult result;
    try {
      result = await actions.open(item, sharePositionOrigin: anchor);
    } finally {
      await loading.dismiss(immediate: true);
    }
    if (!mounted || result == SourceMediaFileResult.opened) return;
    final message = switch (result) {
      SourceMediaFileResult.missing => '源媒体文件已移动或删除，请重新定位源文件',
      SourceMediaFileResult.permissionDenied => '无法读取源媒体文件，请检查文件访问权限',
      SourceMediaFileResult.invalidSource => '此媒体没有可用的本地源文件',
      _ => actions.isMobile ? '无法打开分享菜单，请稍后重试' : '无法打开源文件位置，请稍后重试',
    };
    AppToast.show(message, type: AppToastType.error);
  }
}
