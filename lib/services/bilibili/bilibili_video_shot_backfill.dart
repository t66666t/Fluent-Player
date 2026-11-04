import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../models/video_item.dart';
import 'bilibili_streaming_service.dart';

/// Fetches seek-preview sprites for a Bilibili card that does not have them yet.
///
/// Online cards usually receive sprites during playback prepare. Downloaded
/// cards only received them at library import, so a failed import-time download
/// left the desktop progress bar without a sprite. This retries once per card.
void scheduleBilibiliVideoShotBackfill({
  required BuildContext context,
  required VideoItem item,
  required bool Function() isStillCurrent,
  required VoidCallback onUpdated,
}) {
  if (item.bilibiliVideoShot?.hasLocalSprites == true) return;
  final source = item.sourceRef;
  if (source?.bvid?.trim().isNotEmpty != true || (source?.cid ?? 0) <= 0) {
    return;
  }
  // Playback init can run before inherited providers are available. Wait one
  // frame so the lookup does not throw, then download off the critical path.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!isStillCurrent()) return;
    final BilibiliStreamingService streaming;
    try {
      streaming = Provider.of<BilibiliStreamingService>(context, listen: false);
    } catch (_) {
      return;
    }
    unawaited(() async {
      await streaming.ensureVideoShot(item);
      if (!isStillCurrent()) return;
      if (item.bilibiliVideoShot?.isUsable == true) onUpdated();
    }());
  });
  // This can now be requested after the route's last animation frame, with a
  // paused player. Deliver the callback even when nothing else needs a frame.
  WidgetsBinding.instance.ensureVisualUpdate();
}
