import '../utils/app_branding.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/playback_mode.dart';
import '../models/video_item.dart';
import 'desktop_media_artwork.dart';
import 'desktop_media_icons.dart';
import 'media_playback_service.dart';
import 'playlist_manager.dart';
import 'settings_service.dart';

/// A desktop bridge to the existing playback session, never a second player.
/// Native controls remain alive while the Flutter window is minimized.
class DesktopMediaSessionService {
  DesktopMediaSessionService({
    this.channel = const MethodChannel(
      'com.example.video_player_app/desktop_media',
    ),
  });

  static final instance = DesktopMediaSessionService();
  static bool get isSupportedPlatform =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  final MethodChannel channel;
  final status = ValueNotifier<Map<String, Object?>>({});
  MediaPlaybackService? _playback;
  PlaylistManager? _playlist;
  SettingsService? _settings;
  Timer? _timer;
  String? _lastIdentity;
  bool _initialized = false, _publishing = false, _dirty = false;
  Completer<void>? _publicationDone;
  bool _skipInFlight = false;
  int _generation = 0;
  String? _artworkPath;
  String? _checkedArtwork;
  DateTime? _artworkRetryAfter;
  int _artworkGeneration = 0;
  DesktopMediaArtwork _artwork = DesktopMediaArtwork();

  Future<void> initialize({
    required MediaPlaybackService playbackService,
    required PlaylistManager playlistManager,
    SettingsService? settings,
  }) async {
    if (_initialized) return;
    _playback = playbackService;
    _playlist = playlistManager;
    _settings = settings ?? SettingsService();
    final generation = ++_generation;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'command') {
        final args = Map<Object?, Object?>.from(call.arguments as Map);
        await handleCommand(
          args['command'] as String? ?? '',
          source: args['source'] as String? ?? 'system',
          rate: (args['rate'] as num?)?.toDouble(),
          volume: (args['volume'] as num?)?.toDouble(),
        );
      }
    });
    try {
      final result = await channel.invokeMapMethod<String, Object?>(
        'initialize',
        Platform.isWindows
            ? {'modeIcons': await desktopPlaybackModeIcons()}
            : null,
      );
      if (generation != _generation) return;
      status.value = result ?? {};
      _initialized = true;
      _playback!.addListener(_changed);
      _playback!.coarsePositionNotifier.addListener(_positionChanged);
      _playlist!.addListener(_changed);
      _settings!.addListener(_changed);
      await refreshNow();
    } on MissingPluginException {
      status.value = {'error': '当前构建未包含桌面媒体控制，请重新编译应用。'};
    } catch (error) {
      status.value = {'error': '桌面媒体控制初始化失败：$error'};
    }
  }

  String _identity() {
    final p = _playback!;
    final s = _settings!;
    return [
      p.currentItem?.id,
      p.currentItem?.title,
      p.currentItem?.thumbnailPath,
      p.state,
      p.desiredPlaying,
      p.hasPlayablePrevious,
      p.hasPlayableNext,
      p.isSourceMissing,
      s.desktopSystemMediaControls,
      s.desktopTaskbarMediaControls,
      s.desktopGlobalMediaHotkeys,
      s.desktopMediaHotkeyModifiers,
      s.doubleTapSeekSeconds,
      s.enableDoubleTapSubtitleSeek,
      s.playlistWrapToFirst,
      _playlist!.playbackMode,
    ].join('|');
  }

  void _changed() {
    if (!_initialized) return;
    final identity = _identity();
    if (_lastIdentity != identity) {
      _lastIdentity = identity;
      unawaited(refreshNow());
    } else {
      _positionChanged();
    }
  }

  void _positionChanged() {
    if (!_initialized || _timer != null) return;
    _timer = Timer(const Duration(seconds: 1), () {
      _timer = null;
      unawaited(refreshNow());
    });
  }

  void _resolveArtwork(VideoItem? item) {
    final key =
        '${item?.id}|${item?.thumbnailPath}|${item?.bilibiliPendingCardData?.coverUrl}';
    if (key == _checkedArtwork &&
        (_artworkRetryAfter == null ||
            DateTime.now().isBefore(_artworkRetryAfter!))) {
      return;
    }
    final changed = key != _checkedArtwork;
    _checkedArtwork = key;
    _artworkRetryAfter = null; // Also prevents duplicate loads while in flight.
    if (changed) _artworkPath = null;
    final generation = ++_artworkGeneration;
    final artwork = _artwork;
    unawaited(() async {
      final fallback = await artwork.fallback();
      if (!_initialized || generation != _artworkGeneration) return;
      if (_artworkPath == null && fallback != null) {
        _artworkPath = fallback;
        unawaited(refreshNow());
      }
      final resolved = item == null ? null : await artwork.resolve(item);
      if (!_initialized || generation != _artworkGeneration) return;
      // A generated cover can appear later at the same path. Retry failures
      // without touching playback or downloading on every progress tick.
      if (resolved == null) {
        _artworkRetryAfter = DateTime.now().add(const Duration(seconds: 30));
      }
      if (resolved != null && resolved != _artworkPath) {
        _artworkPath = resolved;
        await refreshNow();
      }
    }());
  }

  Future<void> refreshNow() async {
    if (!_initialized) return;
    _dirty = true;
    if (_publishing) {
      await _publicationDone?.future;
      if (_initialized && _dirty) await refreshNow();
      return;
    }
    _publishing = true;
    final publication = Completer<void>();
    _publicationDone = publication;
    final generation = _generation;
    try {
      while (_dirty && _initialized && generation == _generation) {
        _dirty = false;
        final p = _playback!, s = _settings!;
        final item = p.currentItem;
        final active = item != null && p.state != PlaybackState.idle;
        _resolveArtwork(item);
        // Metadata IO can complete after a stop or a source switch.
        if (!_initialized || generation != _generation) return;
        if (p.currentItem?.id != item?.id) {
          _dirty = true;
          continue;
        }
        final canControl =
            active && !p.isSourceMissing && p.state != PlaybackState.error;
        final duration = p.duration > Duration.zero
            ? p.duration.inMilliseconds
            : item?.durationMs ?? 0;
        final result = await channel
            .invokeMapMethod<String, Object?>('update', {
              'active': active,
              'itemId': item?.id ?? '',
              'mediaType': item?.type.name ?? '',
              'title': item?.title ?? '',
              'subtitle': item?.type.name == 'audio'
                  ? '音频 · $kAppDisplayName'
                  : '视频 · $kAppDisplayName',
              'artworkPath': _artworkPath ?? '',
              'artworkUri': _artworkPath == null
                  ? ''
                  : File(_artworkPath!).uri.toString(),
              'playing': canControl && p.desiredPlaying,
              'canPlay': canControl,
              'canSeek':
                  canControl &&
                  p.duration > Duration.zero &&
                  p.state != PlaybackState.loading,
              'seekSeconds': s.doubleTapSeekSeconds,
              'subtitleSeek':
                  s.enableDoubleTapSubtitleSeek && p.subtitles.isNotEmpty,
              'playbackMode': _playlist!.playbackMode.name,
              'playlistWrap': s.playlistWrapToFirst,
              'canPrevious':
                  canControl &&
                  p.hasPlayablePrevious &&
                  !_skipInFlight &&
                  !p.isEpisodeNavigationBusy,
              'canNext':
                  canControl &&
                  p.hasPlayableNext &&
                  !_skipInFlight &&
                  !p.isEpisodeNavigationBusy,
              'positionMs': p.position.inMilliseconds.clamp(
                0,
                duration > 0 ? duration : 0x7fffffff,
              ),
              'durationMs': duration,
              'rate': p.playbackSpeed,
              'volume': p.isMuted ? 0.0 : p.volume,
              'systemEnabled': s.desktopSystemMediaControls,
              'taskbarEnabled': s.desktopTaskbarMediaControls,
              'hotkeysEnabled': s.desktopGlobalMediaHotkeys,
              'hotkeyModifiers': s.desktopMediaHotkeyModifiers,
            });
        if (_initialized &&
            generation == _generation &&
            result != null &&
            !mapEquals(status.value, result)) {
          status.value = result;
        }
      }
    } catch (error) {
      if (_initialized && generation == _generation) {
        status.value = {...status.value, 'error': '$error'};
      }
    } finally {
      _publishing = false;
      _publicationDone = null;
      publication.complete();
    }
  }

  @visibleForTesting
  Future<void> handleCommand(
    String command, {
    String source = 'system',
    double? rate,
    double? volume,
  }) async {
    final p = _playback, s = _settings;
    if (!_initialized ||
        p == null ||
        s == null ||
        p.currentItem == null ||
        p.state == PlaybackState.idle) {
      return;
    }
    final enabled = switch (source) {
      'hotkey' => s.desktopGlobalMediaHotkeys,
      'taskbar' => s.desktopTaskbarMediaControls,
      _ => s.desktopSystemMediaControls,
    };
    if (!enabled || p.isSourceMissing || p.state == PlaybackState.error) return;
    // Play intent is applied immediately, including while an episode is loading.
    // Repeated skip callbacks are dropped, never queued behind a slow switch.
    try {
      switch (command) {
        case 'play':
          await p.resume();
        case 'pause':
          await p.pause();
        case 'playPause':
          if (p.desiredPlaying) {
            await p.pause();
          } else {
            await p.resume();
          }
        case 'stop':
          await p.stop();
        case 'setRate':
          if (rate != null && rate.isFinite && rate >= 0.25 && rate <= 5) {
            await p.setPlaybackSpeed(rate);
          }
        case 'setVolume':
          if (volume != null && volume.isFinite && volume >= 0 && volume <= 1) {
            await p.setVolume(volume);
          }
        case 'rewind':
        case 'fastForward':
          if (p.state == PlaybackState.loading || p.duration <= Duration.zero) {
            return;
          }
          p.handleExternalDoubleTapSeek(
            isLeft: command == 'rewind',
            doubleTapSeekSeconds: s.doubleTapSeekSeconds,
            enableDoubleTapSubtitleSeek:
                s.enableDoubleTapSubtitleSeek && p.subtitles.isNotEmpty,
            subtitleOffset: s.subtitleOffset,
            source: 'desktop_$source',
          );
        case 'cyclePlaybackMode':
          _playlist!.cyclePlaybackMode();
        case 'shuffleOn':
          _playlist!.setPlaybackMode(PlaybackMode.shuffle);
        case 'shuffleOff':
          if (_playlist!.playbackMode == PlaybackMode.shuffle) {
            _playlist!.setPlaybackMode(PlaybackMode.sequential);
          }
        case 'repeatOne':
          _playlist!.setPlaybackMode(PlaybackMode.repeatOne);
        case 'repeatList':
        case 'repeatOff':
          if (_playlist!.playbackMode == PlaybackMode.repeatOne) {
            _playlist!.setPlaybackMode(PlaybackMode.sequential);
          }
          await s.savePlaylistWrapToFirst(command == 'repeatList');
        case 'next':
        case 'previous':
          if (_skipInFlight ||
              p.isEpisodeNavigationBusy ||
              (command == 'next'
                  ? !p.hasPlayableNext
                  : !p.hasPlayablePrevious)) {
            return;
          }
          _skipInFlight = true;
          unawaited(refreshNow());
          try {
            if (command == 'next') {
              await p.playNext();
            } else {
              await p.playPrevious();
            }
          } finally {
            _skipInFlight = false;
          }
        default:
          return;
      }
    } catch (error) {
      debugPrint('Desktop media command $command failed: $error');
    } finally {
      await refreshNow();
    }
  }

  void dispose() {
    _initialized = false;
    _generation++;
    _skipInFlight = false;
    _timer?.cancel();
    _timer = null;
    _playback?.removeListener(_changed);
    _playback?.coarsePositionNotifier.removeListener(_positionChanged);
    _playlist?.removeListener(_changed);
    _settings?.removeListener(_changed);
    channel.setMethodCallHandler(null);
    unawaited(channel.invokeMethod<void>('dispose').catchError((Object _) {}));
    _playback = null;
    _playlist = null;
    _settings = null;
    _lastIdentity = null;
    _checkedArtwork = null;
    _artworkPath = null;
    _artworkGeneration++;
    _artworkRetryAfter = null;
    unawaited(_artwork.dispose().catchError((Object _) {}));
    _artwork = DesktopMediaArtwork();
  }
}
