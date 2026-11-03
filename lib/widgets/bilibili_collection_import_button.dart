import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/import_card_placement.dart';
import '../services/bilibili/bilibili_collection_import.dart';
import '../services/bilibili/bilibili_download_service.dart';
import '../services/bilibili/bilibili_uploader_service.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
import '../theme/app_tokens.dart';
import 'library_folder_picker.dart';
import 'stable_width_label.dart';
import 'add_to_playlist_button.dart';
import 'playback_queue_add_actions.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

typedef BilibiliCollectionImporter =
    Future<int> Function(
      BuildContext context,
      BilibiliCollectionImportSource source, {
      ImportPlacementRequest? placement,
    });

/// A quiet, fixed-width action for existing collection headings and rows.
/// Busy, success and retry labels occupy the same space.
class BilibiliCollectionImportButton extends StatefulWidget {
  const BilibiliCollectionImportButton({
    super.key,
    required this.source,
    required this.uploader,
    this.onImport,
  });

  final BilibiliCollectionImportSource source;
  final BilibiliUploaderService uploader;
  final BilibiliCollectionImporter? onImport;

  @override
  State<BilibiliCollectionImportButton> createState() =>
      _BilibiliCollectionImportButtonState();
}

class _BilibiliCollectionImportButtonState
    extends State<BilibiliCollectionImportButton> {
  // Different views of the same collection share the in-flight operation.
  static final Map<String, Future<int>> _imports = {};
  bool _busy = false;
  bool _importing = false;
  bool _done = false;
  bool _failed = false;

  @override
  void didUpdateWidget(covariant BilibiliCollectionImportButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source.key != widget.source.key) {
      _busy = false;
      _importing = false;
      _done = false;
      _failed = false;
    }
  }

  Future<void> _import({bool pickPlace = false}) async {
    if (_busy) return;
    final source = widget.source;
    setState(() {
      _busy = true;
      _importing = !pickPlace;
      _failed = false;
    });
    try {
      var placement = SettingsService().captureImportPlacement(
        ImportCardFeature.bilibiliPage,
      );
      if (pickPlace) {
        final pick = await showLibraryFolderPicker(
          context,
          library: context.read<LibraryService>(),
          initialFolderId: placement.folderId,
          title: '导入${source.collection.isSeason ? '合集' : '系列'}到…',
          offerSetAsDefault: false,
          accent: AppTokens.brandBilibili,
        );
        if (pick == null || !mounted || widget.source.key != source.key) return;
        placement = ImportPlacementRequest.explicit(
          ImportCardFeature.bilibiliPage,
          pick.folderId,
        );
        setState(() => _importing = true);
      }
      final operationKey =
          '${source.key}:${placement.placement.name}:'
          '${placement.folderId ?? 'root'}';
      final job = _imports.putIfAbsent(
        operationKey,
        () => Future<int>.sync(() {
          final custom = widget.onImport;
          if (custom != null) {
            return custom(context, source, placement: placement);
          }
          return importBilibiliCollection(
            service: context.read<BilibiliDownloadService>(),
            library: context.read<LibraryService>(),
            uploader: widget.uploader,
            source: source,
            placement: placement,
          );
        }),
      );
      final count = await job.whenComplete(() {
        if (identical(_imports[operationKey], job)) {
          _imports.remove(operationKey);
        }
      });
      if (!mounted || widget.source.key != source.key) return;
      setState(() => _done = true);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('已导入“${source.collection.title}”（$count 个分P）')),
      );
    } catch (error) {
      if (!mounted || widget.source.key != source.key) return;
      setState(() => _failed = true);
      final message = switch (error) {
        BilibiliCollectionImportException(:final message) ||
        ImportPlacementException(:final message) => message,
        _ => '合集导入失败，请检查网络或 B 站登录状态后重试',
      };
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted && widget.source.key == source.key) {
        setState(() {
          _busy = false;
          _importing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final textStyle = Theme.of(context).textTheme.labelLarge!.copyWith(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      height: 1.2,
    );
    final painter = TextPainter(
      text: TextSpan(text: '导入中', style: textStyle),
      textDirection: Directionality.of(context),
      textScaler: scaler,
    )..layout();
    final width = painter.width.ceilToDouble() + 64;
    final height = (painter.height + 10).clamp(32.0, double.infinity);
    painter.dispose();
    return SizedBox(
      width: width,
      height: height,
      child: Row(
        children: [
          Expanded(
            child: DesktopButtonClickRegion(child: TextButton(
              key: ValueKey('bilibili-collection-import-${widget.source.key}'),
              onPressed: _busy ? null : () => unawaited(_import()),
              style: TextButton.styleFrom(
                foregroundColor: _failed
                    ? AppTokens.danger
                    : AppTokens.brandBilibili,
                disabledForegroundColor: AppTokens.brandBilibili.withValues(
                  alpha: .65,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 1),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: textStyle,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: Tooltip(
                message:
                    '导入整个${widget.source.collection.isSeason ? '合集' : '系列'}，包含全部分P',
                child: StableWidthLabel(
                  _importing
                      ? '导入中'
                      : _failed
                      ? '重试'
                      : _done
                      ? '已导入'
                      : '导入',
                  variants: const ['导入', '导入中', '已导入', '重试'],
                ),
              ),
            )),
          ),
          const SizedBox(width: 1),
          SizedBox(
            width: 30,
            height: height,
            child: DesktopButtonClickRegion(child: IconButton(
              key: ValueKey(
                'bilibili-collection-import-pick-${widget.source.key}',
              ),
              tooltip: '选择导入位置',
              onPressed: _busy
                  ? null
                  : () => unawaited(_import(pickPlace: true)),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              style: IconButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              color: AppTokens.text3,
              disabledColor: AppTokens.text4,
              icon: StableIconSlot(
                icon: Icons.drive_folder_upload_outlined,
                size: 17,
                busy: _importing,
                spinnerColor: AppTokens.brandBilibili,
              ),
            )),
          ),
          const SizedBox(width: 1),
          SizedBox(
            width: 30,
            child: AddToPlaylistButton(
              onAdd: (progress) => addBilibiliCollectionToQueue(
                context,
                widget.source,
                widget.uploader,
                progress: progress,
              ),
              key: ValueKey('bilibili-collection-add-${widget.source.key}'),
              iconOnly: true,
              tooltip:
                  '整个${widget.source.collection.isSeason ? '合集' : '系列'}加入播放列表',
              height: height,
              iconSize: 17,
            ),
          ),
        ],
      ),
    );
  }
}
