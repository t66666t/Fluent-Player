import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../models/video_item.dart';
import '../services/settings_service.dart';
import '../utils/media_display_title.dart';

/// Subscribe at the title's build context so cached library cards update too.
String mediaLibraryItemTitle(BuildContext context, VideoItem item) {
  final showExtension = context.select<SettingsService?, bool>(
    (settings) => settings?.showLocalMediaExtensions ?? false,
  );
  return mediaItemDisplayTitle(item, showLocalMediaExtensions: showExtension);
}
