/// Prevents more than one asynchronous playback-page exit from popping routes.
///
/// The guard is intentionally one-way: it belongs to a playback route and that
/// route is expected to be disposed after the first accepted exit request.
class PlaybackExitGuard {
  bool _exitStarted = false;

  bool get exitStarted => _exitStarted;

  /// Returns `true` only for the first exit request.
  bool tryStart() {
    if (_exitStarted) return false;
    _exitStarted = true;
    return true;
  }
}
