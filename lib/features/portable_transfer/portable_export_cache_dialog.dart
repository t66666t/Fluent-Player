import 'package:flutter/material.dart';

import '../../models/video_item.dart';
import '../../services/library_service.dart';
import '../../widgets/desktop_button_click_region.dart';

/// Legacy constructor retained for callers; missing files require local import
/// or relocation. This dialog cannot start a cache/download or browse sources.
class PortableExportCacheDialog extends StatelessWidget {
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
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('需要本地媒体文件'),
    scrollable: true,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          forSync ? '请先重新定位或导入需要同步的本地媒体文件，然后重试。' : '请先重新定位或导入需要导出的本地媒体文件，然后重试。',
        ),
        for (final item in missing)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(item.title),
          ),
      ],
    ),
    actions: [
      DesktopButtonClickRegion(
        child: TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('返回'),
        ),
      ),
    ],
  );
}
