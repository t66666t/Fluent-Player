import 'package:path/path.dart' as p;

/// Selects the wide-codec backend only for Android local files that need it.
///
/// Normal Android local media stays on the platform video_player backend. A
/// path is added here after its audio stream has been probed, or after that
/// platform backend has failed once. The media_kit adapter then consumes the
/// same [VideoPlayerController] API, so queue, notification and page state do
/// not fork into a second playback session.
class LocalPlaybackBackendPolicy {
  LocalPlaybackBackendPolicy._();

  static final Set<String> _runtimeForcedPaths = <String>{};
  static final Set<String> _probedWideCodecPaths = <String>{};

  static const Set<String> _wideCodecExtensions = <String>{
    '.aif',
    '.aifc',
    '.aiff',
    '.alac',
    '.ape',
    '.au',
    '.caf',
    '.dff',
    '.dsf',
    '.dts',
    '.mka',
    '.ra',
    '.snd',
    '.tta',
    '.wma',
    '.wv',
  };

  static const Set<String> _platformSafeAudioCodecs = <String>{
    'aac',
    'amr_nb',
    'amr_wb',
    'flac',
    'mp3',
    'opus',
    'vorbis',
  };

  /// Records an actual platform-player failure. Codec probing must never
  /// clear this promotion or the same file would fail once on every replay.
  static void preferWideCodecBackend(String resource) {
    _runtimeForcedPaths.add(_key(resource));
  }

  static void preferProbedWideCodecBackend(String resource) {
    _probedWideCodecPaths.add(_key(resource));
  }

  static void preferPlatformBackend(String resource) {
    _probedWideCodecPaths.remove(_key(resource));
  }

  static bool isWideCodecBackendPreferred(String resource) {
    final key = _key(resource);
    return _runtimeForcedPaths.contains(key) ||
        _probedWideCodecPaths.contains(key) ||
        _wideCodecExtensions.contains(p.extension(key).toLowerCase());
  }

  /// M4A/M4B are intentionally decided by codec rather than extension: the
  /// same container may hold ordinary AAC (keep the stable platform path) or
  /// ALAC (use media_kit/libmpv).
  static bool codecNeedsWideCodecBackend(String? codec) {
    if (codec == null || codec.trim().isEmpty) return false;
    final normalized = codec.trim().toLowerCase();
    return !_platformSafeAudioCodecs.contains(normalized) &&
        !normalized.startsWith('pcm_');
  }

  static String _key(String resource) {
    var value = resource;
    try {
      final uri = Uri.parse(resource);
      if (uri.scheme == 'file') {
        value = uri.toFilePath();
      } else if (uri.scheme.isNotEmpty) {
        value = uri.path;
      }
    } catch (_) {}
    return p.normalize(value).replaceAll('\\', '/');
  }

  static void clearForTesting() {
    _runtimeForcedPaths.clear();
    _probedWideCodecPaths.clear();
  }
}
