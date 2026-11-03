import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import '../services/media_playback_service.dart';
import '../services/playback_behavior_policy.dart';
import '../services/playback_navigation_service.dart';
import '../services/settings_service.dart';
import '../theme/playback_page_route.dart';

/// A decoded texture belongs on screen only while its controller is live and
/// the music cover is not borrowing the same output.
bool shouldKeepPlaybackVideoSurface({
  required bool controllerIsCurrent,
  required bool initialized,
  required bool hasDecodedTexture,
  required bool musicCoverOwnsSurface,
}) =>
    controllerIsCurrent &&
    !musicCoverOwnsSurface &&
    (initialized || hasDecodedTexture);

/// Establishes visibility without treating a popup as leaving the player.
///
/// ModalRoute.isCurrent is false underneath the speed picker too. Passing that
/// value directly to setPlaybackPageVisible deselects Bilibili's video track on
/// mobile while its external audio keeps playing. Only PageRoute-aware exit
/// callbacks (or app backgrounding) should hide the playback page.
void registerPlaybackPageIfCurrent(BuildContext context, Object owner) {
  if (ModalRoute.of(context)?.isCurrent == true) {
    MediaPlaybackService().setPlaybackPageVisible(owner, true);
  }
}

/// A retained player route also leaves the screen when a browsing page covers
/// it. Pause its own session, including a stream still opening/cache-paused.
/// Playback presentations and compose previews manage their own handoffs.
Future<void> pausePlaybackPageWhenCovered({
  required Route<dynamic>? coveringRoute,
  required SettingsService settings,
  required MediaPlaybackService playbackService,
  required String? itemId,
  required VideoPlayerController? controller,
  required bool controllerOwner,
}) async {
  if (coveringRoute is! PageRoute ||
      coveringRoute is PlaybackPageRoute ||
      PlaybackNavigationService.isPlaybackRouteName(
        coveringRoute.settings.name,
      ) ||
      coveringRoute.settings.name == 'music-player' ||
      coveringRoute.settings.name == '/compose/preview' ||
      itemId == null) {
    return;
  }
  final serviceOwnsSession =
      playbackService.currentItem?.id == itemId &&
      (controller == null || identical(playbackService.controller, controller));
  if (!PlaybackBehaviorPolicy.shouldPauseOnPlaybackPageExit(
    autoPauseOnExit: settings.autoPauseOnExit,
    explicitExit: true,
    suppressRouteCleanup:
        PlaybackNavigationService.instance.suppressAutoPauseOnRouteCleanup,
    transportPlaying: serviceOwnsSession
        ? playbackService.isTransportPlaying
        : controllerOwner && controller?.value.isPlaying == true,
  )) {
    return;
  }
  try {
    if (serviceOwnsSession) {
      await playbackService.pause(
        expectedItemId: itemId,
        expectedController: controller,
        notify: false,
      );
    } else {
      await controller?.pause();
    }
  } catch (error) {
    debugPrint('Pausing covered playback page failed: $error');
  }
}
