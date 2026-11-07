import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../services/settings_service.dart';
import '../utils/media_display_title.dart';

import '../services/batch_import_service.dart';
import '../theme/app_tokens.dart';
import '../utils/supported_media_extensions.dart';
import 'button_aware_drag.dart';
import 'desktop_button_click_region.dart';

enum _RowAction { importMedia, undo, removeMedia, removeSubtitle, removeRow }

/// Both columns keep independent ordering and synchronized vertical scrolling.
/// Compact rows share one action menu so both files remain visible on phones.
class BatchImportTable extends StatelessWidget {
  const BatchImportTable({
    super.key,
    required this.batch,
    required this.folderId,
    required this.media,
    required this.subtitles,
    required this.mediaController,
    required this.subtitleController,
    required this.actionController,
    required this.horizontalController,
    required this.onAddMedia,
    required this.onAddSubtitles,
    required this.onPreviewMedia,
    required this.onPreviewSubtitle,
    required this.onImport,
    required this.onUndo,
  });

  final BatchImportService batch;
  final String? folderId;
  final List<BatchItem> media;
  final List<BatchItem> subtitles;
  final ScrollController mediaController;
  final ScrollController subtitleController;
  final ScrollController actionController;
  final ScrollController horizontalController;
  final VoidCallback onAddMedia;
  final VoidCallback onAddSubtitles;
  final ValueChanged<BatchItem> onPreviewMedia;
  final ValueChanged<BatchItem> onPreviewSubtitle;
  final void Function(BatchItem, BatchItem?) onImport;
  final ValueChanged<BatchItem> onUndo;

  bool get _touch =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Widget build(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);
    final scaledFont = textScaler.scale(batch.fontSize);
    final metrics = TextPainter(
      text: TextSpan(
        text: 'Ag',
        style: DefaultTextStyle.of(
          context,
        ).style.copyWith(fontSize: batch.fontSize),
      ),
      textDirection: Directionality.of(context),
      textScaler: textScaler,
    );
    final rowHeight = math.max(
      _touch ? 48.0 : 36.0,
      metrics.preferredLineHeight * (_touch ? 2 : 1) + 8,
    );
    metrics.dispose();
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 600 && scaledFont <= 28;
        final width = compact
            ? constraints.maxWidth
            : math.max(640.0, constraints.maxWidth);
        final actionWidth = compact ? 40.0 : (_touch ? 96.0 : 72.0);
        final scrolls = width > constraints.maxWidth;
        return Scrollbar(
          controller: horizontalController,
          thumbVisibility: scrolls,
          notificationPredicate: (notification) =>
              notification.metrics.axis == Axis.horizontal,
          child: SingleChildScrollView(
            key: const ValueKey('batch-import-horizontal-scroll'),
            controller: horizontalController,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width,
              height: constraints.maxHeight,
              child: Column(
                children: [
                  if (constraints.maxHeight >= 96)
                    DecoratedBox(
                      decoration: const BoxDecoration(
                        border: Border(
                          bottom: BorderSide(color: AppTokens.lineSubtle),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(child: _header('媒体', onAddMedia)),
                          Expanded(child: _header('字幕', onAddSubtitles)),
                          SizedBox(width: actionWidth),
                        ],
                      ),
                    ),
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(
                          child: _files(
                            media,
                            true,
                            rowHeight,
                            canDismiss: !compact && !scrolls,
                          ),
                        ),
                        Expanded(
                          child: _files(
                            subtitles,
                            false,
                            rowHeight,
                            canDismiss: !compact && !scrolls,
                          ),
                        ),
                        SizedBox(
                          width: actionWidth,
                          child: _actions(rowHeight, compact: compact),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _header(String label, VoidCallback onAdd) => Padding(
    padding: const EdgeInsets.only(left: 12, right: 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: AppTokens.text2),
          ),
        ),
        DesktopButtonClickRegion(
          child: IconButton(
            key: ValueKey(
              'batch-import-add-${label == '媒体' ? 'media' : 'subtitles'}',
            ),
            tooltip: '添加$label',
            style: IconButton.styleFrom(
              minimumSize: Size.square(_touch ? 44 : 28),
              padding: const EdgeInsets.all(4),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: onAdd,
            icon: const Icon(Icons.add_rounded, size: 18),
          ),
        ),
      ],
    ),
  );

  BoxDecoration _rowDecoration({
    bool imported = false,
    bool mediaColumn = false,
  }) => BoxDecoration(
    color: imported ? const Color(0x088CB99B) : null,
    border: Border(
      bottom: const BorderSide(color: AppTokens.lineSubtle),
      right: mediaColumn
          ? const BorderSide(color: AppTokens.lineSubtle)
          : BorderSide.none,
    ),
  );

  Widget _files(
    List<BatchItem> items,
    bool isMedia,
    double height, {
    required bool canDismiss,
  }) {
    return ReorderableListView.builder(
      key: ValueKey(isMedia ? 'batch-media-list' : 'batch-subtitle-list'),
      scrollController: isMedia ? mediaController : subtitleController,
      buildDefaultDragHandles: false,
      proxyDecorator: (child, _, _) => Material(
        color: AppTokens.bgRaised,
        elevation: 2,
        borderRadius: BorderRadius.circular(4),
        child: child,
      ),
      itemExtent: height,
      itemCount: items.length,
      padding: const EdgeInsets.only(bottom: 12),
      onReorderItem: (from, to) => isMedia
          ? batch.moveVideo(folderId, from, to)
          : batch.moveSubtitle(folderId, from, to),
      itemBuilder: (context, index) {
        final item = items[index];
        final path = item.path;
        final imported =
            isMedia && path != null && batch.isImported(folderId, path);
        final duration = isMedia && path != null
            ? batch.getDuration(folderId, path)
            : null;
        return Dismissible(
          key: ValueKey(item.id),
          direction: canDismiss
              ? DismissDirection.horizontal
              : DismissDirection.none,
          dismissThresholds: const {
            DismissDirection.startToEnd: 0.8,
            DismissDirection.endToStart: 0.8,
          },
          background: Container(
            color: AppTokens.danger.withValues(alpha: 0.15),
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.all(12),
            child: const Icon(Icons.close_rounded, color: AppTokens.danger),
          ),
          secondaryBackground: Container(
            color: AppTokens.danger.withValues(alpha: 0.15),
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.all(12),
            child: const Icon(Icons.close_rounded, color: AppTokens.danger),
          ),
          onDismissed: (_) => isMedia
              ? batch.removeVideoItem(folderId, index)
              : batch.removeSubtitleItem(folderId, index),
          child: ButtonAwareReorderableDelayedDragStartListener(
            index: index,
            enabled: _touch,
            child: Container(
              key: ValueKey(
                'batch-cell-${isMedia ? 'media' : 'subtitle'}-${item.id}',
              ),
              height: height,
              decoration: _rowDecoration(
                imported: imported,
                mediaColumn: isMedia,
              ),
              child: Row(
                children: [
                  if (path == null)
                    SizedBox(width: _touch ? 24 : 28)
                  else
                    _FileDragHandle(
                      key: ValueKey('batch-import-grip-${item.id}'),
                      index: index,
                      width: _touch ? 24 : 28,
                      height: height,
                      label: '调整${isMedia ? '媒体' : '字幕'}顺序',
                      icon: !isMedia
                          ? Icons.subtitles_outlined
                          : kSupportedAudioExtensions.contains(
                              p.extension(path).toLowerCase(),
                            )
                          ? Icons.audio_file_outlined
                          : Icons.video_file_outlined,
                      onTap: () =>
                          (isMedia ? onPreviewMedia : onPreviewSubtitle)(item),
                    ),
                  Expanded(
                    child: path == null
                        ? const Text(
                            '—',
                            style: TextStyle(color: AppTokens.text3),
                          )
                        : Semantics(
                            button: true,
                            value: imported ? '已导入' : null,
                            child: Tooltip(
                              message: [path, ?duration].join('\n'),
                              triggerMode: TooltipTriggerMode.manual,
                              child: InkWell(
                                onTap: () => (isMedia
                                    ? onPreviewMedia
                                    : onPreviewSubtitle)(item),
                                child: Container(
                                  height: height,
                                  alignment: Alignment.centerLeft,
                                  padding: const EdgeInsets.only(right: 8),
                                  child: Builder(
                                    builder: (context) => Text(
                                      isMedia
                                          ? localMediaDisplayTitle(
                                              item.title ?? p.basename(path),
                                              showExtension: context
                                                  .select<
                                                    SettingsService?,
                                                    bool
                                                  >(
                                                    (settings) =>
                                                        settings
                                                            ?.showLocalMediaExtensions ??
                                                        false,
                                                  ),
                                            )
                                          : item.title ?? p.basename(path),
                                      maxLines: _touch ? 2 : 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: batch.fontSize,
                                        color: AppTokens.text1,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                  ),
                  if (imported)
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: Icon(
                        Icons.check_rounded,
                        size: 14,
                        color: Color(0xFF9DB8A5),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _actions(double height, {required bool compact}) => ListView.builder(
    controller: actionController,
    itemCount: math.max(media.length, subtitles.length),
    itemExtent: height,
    padding: const EdgeInsets.only(bottom: 12),
    itemBuilder: (context, index) {
      final video = index < media.length ? media[index] : null;
      final subtitle = index < subtitles.length ? subtitles[index] : null;
      final videoPath = video?.path;
      final imported =
          videoPath != null && batch.isImported(folderId, videoPath);
      final buttonStyle = IconButton.styleFrom(
        minimumSize: Size.square(_touch ? 44 : 28),
        padding: EdgeInsets.all(_touch ? 8 : 4),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      );
      final menu = PopupMenuButton<_RowAction>(
        style: buttonStyle,
        key: ValueKey('batch-import-row-actions-$index'),
        tooltip: '第 ${index + 1} 行操作',
        padding: EdgeInsets.zero,
        icon: const Icon(
          Icons.more_horiz_rounded,
          size: 20,
          color: AppTokens.text3,
        ),
        onSelected: (action) {
          switch (action) {
            case _RowAction.importMedia:
              onImport(video!, subtitle);
            case _RowAction.undo:
              onUndo(video!);
            case _RowAction.removeMedia:
              batch.removeVideoItem(folderId, index);
            case _RowAction.removeSubtitle:
              batch.removeSubtitleItem(folderId, index);
            case _RowAction.removeRow:
              batch.removeRow(folderId, index);
          }
        },
        itemBuilder: (_) => [
          if (compact && videoPath != null)
            PopupMenuItem(
              value: imported ? _RowAction.undo : _RowAction.importMedia,
              child: Text(imported ? '撤回导入' : '导入'),
            ),
          if (videoPath != null)
            const PopupMenuItem(
              value: _RowAction.removeMedia,
              child: Text('移除媒体'),
            ),
          if (subtitle?.path != null)
            const PopupMenuItem(
              value: _RowAction.removeSubtitle,
              child: Text('移除字幕'),
            ),
          const PopupMenuItem(value: _RowAction.removeRow, child: Text('移除整行')),
        ],
      );
      return Container(
        decoration: _rowDecoration(imported: imported),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (!compact)
              DesktopButtonClickRegion(
                child: IconButton(
                  key: ValueKey('batch-import-row-import-$index'),
                  style: buttonStyle,
                  tooltip: imported
                      ? '撤回导入（保留文件）'
                      : subtitle?.path == null
                      ? '仅导入媒体'
                      : '关联字幕并导入',
                  onPressed: video == null || videoPath == null
                      ? null
                      : () => imported
                            ? onUndo(video)
                            : onImport(video, subtitle),
                  icon: Icon(
                    imported ? Icons.undo_rounded : Icons.file_upload_outlined,
                    size: 20,
                  ),
                ),
              ),
            SizedBox(width: compact ? 40 : (_touch ? 48 : 32), child: menu),
          ],
        ),
      );
    },
  );
}

class _FileDragHandle extends StatefulWidget {
  const _FileDragHandle({
    super.key,
    required this.index,
    required this.width,
    required this.height,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final int index;
  final double width;
  final double height;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  State<_FileDragHandle> createState() => _FileDragHandleState();
}

class _FileDragHandleState extends State<_FileDragHandle> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => Semantics(
    label: widget.label,
    child: MouseRegion(
      cursor: SystemMouseCursors.grab,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: ButtonAwareReorderableDragStartListener(
        index: widget.index,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: SizedBox(
            width: widget.width,
            height: widget.height,
            child: Icon(
              _hovered ? Icons.drag_handle_rounded : widget.icon,
              size: 14,
              color: _hovered
                  ? AppTokens.text2
                  : AppTokens.text3.withValues(alpha: 0.65),
            ),
          ),
        ),
      ),
    ),
  );
}
