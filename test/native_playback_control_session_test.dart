import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/models/playback_control_session.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/native_playback_control_session.dart';

class _Controller extends VideoPlayerController {
  _Controller() : super.networkUrl(Uri.parse('https://unused.test')) {
    value = const VideoPlayerValue(
      duration: Duration(minutes: 2),
      isInitialized: true,
    );
  }
}

class _NativePlayback extends MediaPlaybackService {
  _NativePlayback() : super.forTesting();
  final decoder = _Controller();
  final positionUpdates = _Positions();
  VideoItem? item = VideoItem(
    id: 'local-one',
    path: '/local/one.mp4',
    title: 'one',
    durationMs: 120000,
    lastUpdated: 0,
  );
  Duration at = Duration.zero;
  bool running = false, muted = false;
  double speed = 1, loudness = 1;
  int commands = 0;
  String? lastSeekSource;
  @override
  VideoItem? get currentItem => item;
  @override
  VideoPlayerController? get controller => decoder;
  @override
  ValueNotifier<Duration> get positionNotifier => positionUpdates;
  @override
  Duration get position => at;
  @override
  Duration get duration => const Duration(minutes: 2);
  @override
  bool get isPlaying => running;
  @override
  PlaybackState get state =>
      running ? PlaybackState.playing : PlaybackState.paused;
  @override
  double get volume => loudness;
  @override
  double get playbackSpeed => speed;
  @override
  bool get isMuted => muted;
  @override
  Future<void> resume() async {
    commands++;
    running = true;
    notifyListeners();
  }

  @override
  Future<void> pause({
    String? expectedItemId,
    VideoPlayerController? expectedController,
    bool notify = true,
  }) async {
    commands++;
    running = false;
    notifyListeners();
  }

  @override
  Future<void> seekTo(Duration position, {String source = 'ui'}) async {
    commands++;
    lastSeekSource = source;
    at = position;
    positionUpdates.value = at;
    notifyListeners();
  }

  @override
  Future<void> setPlaybackSpeed(double speed) async {
    commands++;
    this.speed = speed;
    notifyListeners();
  }

  @override
  Future<void> setVolume(double volume) async {
    commands++;
    loudness = volume;
    notifyListeners();
  }

  @override
  Future<void> toggleMute() async {
    commands++;
    muted = !muted;
    notifyListeners();
  }
}

class _Positions extends ValueNotifier<Duration> {
  _Positions() : super(Duration.zero);
  bool get observed => hasListeners;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native adapter delegates existing transport and clamps seeks without owning decoder',
    () async {
      final native = _NativePlayback();
      final session = NativePlaybackControlSession(native);
      expect(session.value.ready, true);
      expect((await session.play()).succeeded, true);
      expect(session.value.playing, true);
      await session.seekBy(const Duration(seconds: 5));
      expect(native.position, const Duration(seconds: 5));
      await session.seekTo(const Duration(seconds: 200));
      expect(native.position, const Duration(minutes: 2));
      await session.seekTo(const Duration(seconds: -3));
      expect(native.position, Duration.zero);
      await session.setRate(1.5);
      await session.setVolume(.4);
      await session.setMuted(true);
      expect(session.value.rate, 1.5);
      expect(session.value.volume, .4);
      expect(session.value.muted, true);
      session.dispose();
      expect(native.controller!.value.isInitialized, true);
      native.positionUpdates.dispose();
      await native.decoder.dispose();
      native.dispose();
    },
  );

  test(
    'owned-page bridge preserves subtitle source and releases its listeners',
    () async {
      final native = _NativePlayback();
      final unrelated = _Controller();
      expect(native.positionUpdates.observed, false);
      final denied = await NativePlaybackControlSession.seekOwned(
        service: native,
        expectedController: unrelated,
        position: const Duration(seconds: 20),
        source: 'subtitle_hop',
      );
      expect(denied.status, PlaybackCommandStatus.notReady);
      expect(native.commands, 0);
      final result = await NativePlaybackControlSession.seekOwned(
        service: native,
        expectedController: native.decoder,
        position: const Duration(seconds: 20),
        source: 'subtitle_hop',
      );
      expect(result.succeeded, true);
      expect(native.lastSeekSource, 'subtitle_hop');
      expect(native.position, const Duration(seconds: 20));
      expect(native.positionUpdates.observed, false);
      native.positionUpdates.dispose();
      await unrelated.dispose();
      await native.decoder.dispose();
      native.dispose();
    },
  );

  test('old native page cannot control a newly selected native item', () async {
    final native = _NativePlayback();
    final session = NativePlaybackControlSession(native);
    native.item = VideoItem(
      id: 'local-two',
      path: '/local/two.mp4',
      title: 'two',
      durationMs: 120000,
      lastUpdated: 0,
    );
    native.notifyListeners();
    expect(session.value.ready, false);
    expect(
      (await session.seekTo(const Duration(seconds: 40))).status,
      PlaybackCommandStatus.notReady,
    );
    expect((await session.play()).status, PlaybackCommandStatus.notReady);
    expect(native.commands, 0);
    session.dispose();
    native.positionUpdates.dispose();
    await native.decoder.dispose();
    native.dispose();
  });
}
