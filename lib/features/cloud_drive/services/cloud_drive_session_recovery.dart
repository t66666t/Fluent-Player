/// A route update must not replace a healthy native playback session. Future
/// gateway requests pick up the new policy; failed sessions may be recovered.
bool shouldReopenCloudDrivePlayback({
  required bool deviceChanged,
  required bool configurationChanged,
  required bool sessionHealthy,
}) {
  return !sessionHealthy;
}

/// Whether the service may treat the live controller as the same session.
///
/// A brief Dart `isPlaying` lag is not enough to call the session dead.
bool cloudDriveSessionIsHealthy({
  required bool controllerReady,
  required bool controllerFailed,
  required bool playingOrPaused,
}) {
  return controllerReady && !controllerFailed && playingOrPaused;
}
