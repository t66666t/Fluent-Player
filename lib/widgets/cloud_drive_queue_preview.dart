import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../features/cloud_drive/services/cloud_drive_thumbnails.dart';
import '../models/video_item.dart';
import '../services/library_service.dart';

/// Enriches only mounted queue rows, without registering unplayed library cards.
class CloudDriveQueuePreview extends StatefulWidget {
  const CloudDriveQueuePreview({
    super.key,
    required this.item,
    required this.builder,
  });

  final VideoItem item;
  final WidgetBuilder builder;

  @override
  State<CloudDriveQueuePreview> createState() => _CloudDriveQueuePreviewState();
}

class _CloudDriveQueuePreviewState extends State<CloudDriveQueuePreview> {
  Future<void>? _pending;
  String? _identity;
  CloudDriveThumbnails? _service;
  VideoItem? _item;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
  }

  @override
  void didUpdateWidget(CloudDriveQueuePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    _load();
  }

  void _load() {
    final item = widget.item;
    final source = item.sourceRef?.cloudDrive;
    if (source == null) return;
    final service = context.read<LibraryService?>()?.cloudDriveThumbnails;
    final identity = '${CloudDriveThumbnails.cacheKey(source)}|${item.id}';
    if (_identity == identity &&
        identical(service, _service) &&
        identical(item, _item)) {
      return;
    }
    _identity = identity;
    _service = service;
    _item = item;
    _pending = () async {
      if (service == null) return;
      bool current() {
        final currentSource = item.sourceRef?.cloudDrive;
        return mounted &&
            _identity == identity &&
            identical(widget.item, item) &&
            currentSource != null &&
            CloudDriveThumbnails.cacheKey(currentSource) ==
                CloudDriveThumbnails.cacheKey(source);
      }

      // Each result appears as soon as it arrives; neither waits for the other.
      // Both share the service's in-flight metadata request and bounded cache.
      await Future.wait([
        service.ensure(source).then((path) {
          if (current() && path != null) {
            setState(() => item.thumbnailPath = path);
          }
        }),
        if (item.durationMs <= 0)
          service.metadata(source).then((details) {
            if (current() &&
                item.durationMs <= 0 &&
                (details?.durationMs ?? 0) > 0) {
              setState(() => item.durationMs = details!.durationMs!);
            }
          }),
      ]);
    }();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _pending,
    builder: (context, _) => widget.builder(context),
  );
}
