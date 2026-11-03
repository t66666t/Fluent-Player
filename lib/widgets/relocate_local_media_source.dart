import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/video_item.dart';
import '../services/library_service.dart';
import '../services/media_playback_service.dart';
import '../utils/app_toast.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// File picker + confirm + library rebind for a missing local source.
class RelocateLocalMediaSourceAction {
  RelocateLocalMediaSourceAction._();

  @visibleForTesting
  static Future<String?> Function({required MediaType expectedType})?
  pickPathOverrideForTesting;

  @visibleForTesting
  static Future<bool> Function({
    required String title,
    required String fileName,
  })?
  confirmOverrideForTesting;

  static Future<void> run(BuildContext context, VideoItem item) async {
    final library = LibraryService();
    if (!library.canRelocateLocalMediaSource(item)) {
      AppToast.show('该媒体不能通过本地文件恢复', type: AppToastType.error);
      return;
    }

    final picked = await _pickPath(expectedType: item.type);
    if (picked == null) return;
    if (!context.mounted) return;

    final confirmed = await _confirm(
      context,
      title: item.title,
      fileName: p.basename(picked),
    );
    if (!confirmed) return;

    final result = await library.relocateLocalMediaSource(
      mediaId: item.id,
      pickedPath: picked,
    );
    if (!result.isSuccess) {
      AppToast.show(_messageFor(result.status), type: AppToastType.error);
      return;
    }
    if (result.positionClamped) {
      AppToast.show('播放进度已按新时长截断');
    } else {
      AppToast.show('已关联新文件', type: AppToastType.success);
    }
    await MediaPlaybackService().reloadAfterSourceRelocate(mediaId: item.id);
  }

  static Future<String?> _pickPath({required MediaType expectedType}) async {
    final override = pickPathOverrideForTesting;
    if (override != null) {
      return override(expectedType: expectedType);
    }
    final extensions = expectedType == MediaType.audio
        ? LibraryService.supportedAudioExtensions
        : LibraryService.supportedVideoExtensions;
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: '重新定位文件',
      type: FileType.custom,
      allowMultiple: false,
      withData: false,
      withReadStream: false,
      allowedExtensions: extensions
          .map((ext) => ext.replaceFirst('.', ''))
          .toList(),
    );
    final path = result?.files.isEmpty == true
        ? null
        : result?.files.first.path;
    if (path == null || path.trim().isEmpty) return null;
    return path;
  }

  static Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required String fileName,
  }) async {
    final override = confirmOverrideForTesting;
    if (override != null) {
      return override(title: title, fileName: fileName);
    }
    final agreed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('确认关联'),
          content: Text('将「$title」关联到「$fileName」？这会替换当前来源，不是再次导入。'),
          actions: [
            DesktopButtonClickRegion(
              child: TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('取消'),
              ),
            ),
            DesktopButtonClickRegion(
              child: TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('确认关联'),
              ),
            ),
          ],
        );
      },
    );
    return agreed == true;
  }

  static String _messageFor(RelocateLocalMediaStatus status) {
    switch (status) {
      case RelocateLocalMediaStatus.typeMismatch:
        return '请选择与当前媒体相同类型的文件';
      case RelocateLocalMediaStatus.unsupportedType:
        return '不支持的文件类型';
      case RelocateLocalMediaStatus.missingFile:
        return '无法访问所选文件';
      case RelocateLocalMediaStatus.onlineSource:
        return '该媒体不能通过本地文件恢复';
      case RelocateLocalMediaStatus.mediaNotFound:
        return '媒体记录不存在';
      case RelocateLocalMediaStatus.success:
        return '已关联新文件';
    }
  }
}

/// Missing-source surface on landscape/portrait video pages.
class MissingLocalSourcePanel extends StatelessWidget {
  const MissingLocalSourcePanel({
    super.key,
    required this.item,
    this.fontSize = 20,
  });

  final VideoItem? item;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final current = item;
    final canRelocate =
        current != null &&
        LibraryService().canRelocateLocalMediaSource(current);
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                canRelocate ? '文件找不到' : '没有原媒体',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: fontSize,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
              if (canRelocate) ...[
                const SizedBox(height: 16),
                DesktopButtonClickRegion(
                  child: TextButton(
                    onPressed: () =>
                        RelocateLocalMediaSourceAction.run(context, current),
                    child: const Text('重新定位文件'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
