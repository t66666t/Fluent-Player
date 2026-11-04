import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/models/playback_mode.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/desktop_media_session_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/desktop_media_settings_dialog.dart';

class _Playback extends MediaPlaybackService {
  _Playback() : super.forTesting();
  VideoItem? item;
  PlaybackState phase = PlaybackState.idle;
  bool intent = false, previous = false, next = false;
  int plays = 0, pauses = 0, nexts = 0, previouses = 0;
  Completer<void>? skip;
  final seeks = <(bool, int, bool, Duration)>[];
  List<SubtitleItem> cues = [];
  @override
  List<SubtitleItem> get subtitles => cues;
  @override
  void handleExternalDoubleTapSeek({
    required bool isLeft,
    required int doubleTapSeekSeconds,
    required bool enableDoubleTapSubtitleSeek,
    required Duration subtitleOffset,
    String source = 'external_double_tap',
  }) {
    seeks.add((
      isLeft,
      doubleTapSeekSeconds,
      enableDoubleTapSubtitleSeek,
      subtitleOffset,
    ));
  }

  @override
  VideoItem? get currentItem => item;
  @override
  PlaybackState get state => phase;
  @override
  bool get desiredPlaying => intent;
  @override
  bool get hasPlayablePrevious => previous;
  @override
  bool get hasPlayableNext => next;
  @override
  Duration get position => const Duration(seconds: 12);
  @override
  Duration get duration => const Duration(minutes: 2);
  @override
  Future<void> resume() async {
    plays++;
    intent = true;
    notifyListeners();
  }

  @override
  Future<void> pause({
    String? expectedItemId,
    VideoPlayerController? expectedController,
    bool notify = true,
  }) async {
    pauses++;
    intent = false;
    notifyListeners();
  }

  @override
  Future<void> playNext({bool? autoPlay}) async {
    nexts++;
    phase = PlaybackState.loading;
    notifyListeners();
    await skip?.future;
    phase = intent ? PlaybackState.playing : PlaybackState.paused;
    notifyListeners();
  }

  @override
  Future<void> playPrevious({bool? autoPlay}) async {
    previouses++;
  }

  void seed() {
    item = VideoItem(
      id: 'episode',
      path: '/offline.mp4',
      title: '第二集',
      durationMs: 120000,
      lastUpdated: 1,
    );
    phase = PlaybackState.paused;
    previous = true;
    next = true;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.example.video_player_app/desktop_media');
  late SettingsService settings;
  late _Playback playback;
  late PlaylistManager playlist;
  late DesktopMediaSessionService service;
  final updates = <Map<Object?, Object?>>[];
  var disposed = 0;
  Completer<void>? blockedUpdate;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService()..resetForTest();
    await settings.init();
    playback = _Playback();
    playlist = PlaylistManager();
    service = DesktopMediaSessionService();
    updates.clear();
    disposed = 0;
    blockedUpdate = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'dispose') {
            disposed++;
            return null;
          }
          if (call.method == 'update') {
            updates.add(Map<Object?, Object?>.from(call.arguments as Map));
            final block = blockedUpdate;
            blockedUpdate = null;
            await block?.future;
          }
          return {
            'systemMedia': true,
            'taskbar': true,
            'globalHotkeys': true,
            'hotkeysRegistered':
                updates.isNotEmpty &&
                updates.last['active'] == true &&
                updates.last['hotkeysEnabled'] == true,
            'error': '',
          };
        });
    await service.initialize(
      playbackService: playback,
      playlistManager: playlist,
      settings: settings,
    );
  });
  tearDown(() async {
    service.dispose();
    await Future<void>.delayed(Duration.zero);
    playback.dispose();
    playlist.dispose();
    settings.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'no idle registrations; metadata and play intent follow the current session',
    () async {
      expect(updates.last['active'], false);
      expect(updates.last['hotkeysEnabled'], false);
      playback.seed();
      await service.refreshNow();
      await Future<void>.delayed(Duration.zero);
      expect(updates.last['title'], '第二集');
      expect(updates.last['canPrevious'], true);
      expect(updates.last['playing'], false);
      await service.handleCommand('play');
      expect(playback.plays, 1);
      expect(updates.last['playing'], true);
      await service.handleCommand('playPause');
      expect(playback.pauses, 1);
      expect(updates.last['playing'], false);
    },
  );

  test(
    'system, taskbar and hotkey switches are independent and persist',
    () async {
      playback.seed();
      await service.refreshNow();
      await settings.updateSetting('desktopSystemMediaControls', false);
      await service.handleCommand('play');
      expect(playback.plays, 0);
      await service.handleCommand('play', source: 'taskbar');
      expect(playback.plays, 1);
      await service.handleCommand('pause', source: 'hotkey');
      expect(playback.pauses, 0);
      await settings.updateSetting('desktopGlobalMediaHotkeys', true);
      await settings.updateSetting(
        'desktopMediaHotkeyModifiers',
        'ctrl+alt+shift',
      );
      await service.handleCommand('pause', source: 'hotkey');
      expect(playback.pauses, 1);
      expect(
        settings.exportSettingsSnapshot()['home']['desktopGlobalMediaHotkeys'],
        true,
      );
      expect(updates.last['hotkeyModifiers'], 'ctrl+alt+shift');
    },
  );

  test(
    'repeated skips drop while loading; pause remains immediate and boundaries do nothing',
    () async {
      playback.seed();
      playback.intent = true;
      playback.skip = Completer<void>();
      final first = service.handleCommand('next');
      await Future<void>.delayed(Duration.zero);
      await service.handleCommand('next');
      await service.handleCommand('previous');
      expect((playback.nexts, playback.previouses), (1, 0));
      await service.handleCommand('pause');
      expect(playback.intent, false);
      playback.skip!.complete();
      await first;
      expect(playback.phase, PlaybackState.paused);
      playback.next = false;
      playback.previous = false;
      await service.handleCommand('next');
      await service.handleCommand('previous');
      expect((playback.nexts, playback.previouses), (1, 0));
    },
  );

  test('stopping/disposal clears controls and removes listeners', () async {
    playback.seed();
    await service.refreshNow();
    playback.item = null;
    playback.phase = PlaybackState.idle;
    playback.notifyListeners();
    await service.refreshNow();
    await Future<void>.delayed(Duration.zero);
    expect(updates.last['active'], false);
    service.dispose();
    await Future<void>.delayed(Duration.zero);
    final count = updates.length;
    playback.notifyListeners();
    await service.handleCommand('play');
    expect(updates.length, count);
    expect(playback.plays, 0);
    expect(disposed, 1);
  });

  test(
    'desktop seeks use the configured mobile notification jump policy',
    () async {
      playback.seed();
      settings.doubleTapSeekSeconds = 17;
      settings.enableDoubleTapSubtitleSeek = true;
      settings.subtitleOffset = const Duration(milliseconds: 450);
      await service.handleCommand('fastForward', source: 'taskbar');
      expect(playback.seeks.single, (
        false,
        17,
        false,
        settings.subtitleOffset,
      ));
      playback.cues = [
        SubtitleItem(
          index: 1,
          startTime: Duration.zero,
          endTime: const Duration(seconds: 2),
          text: 'cue',
        ),
      ];
      await service.handleCommand('rewind');
      expect(playback.seeks.last, (true, 17, true, settings.subtitleOffset));
      expect(updates.last['seekSeconds'], 17);
      expect(updates.last['subtitleSeek'], true);
      playback.phase = PlaybackState.loading;
      await service.handleCommand('rewind');
      expect(playback.seeks.length, 2);
      expect(updates.last['canSeek'], false);
    },
  );

  test(
    'taskbar and system requests share the existing queue mode and wrap setting',
    () async {
      playback.seed();
      playlist.setPlaybackMode(PlaybackMode.sequential);
      await service.handleCommand('cyclePlaybackMode', source: 'taskbar');
      expect(playlist.playbackMode, PlaybackMode.shuffle);
      expect(updates.last['playbackMode'], 'shuffle');
      await service.handleCommand('cyclePlaybackMode', source: 'taskbar');
      expect(playlist.playbackMode, PlaybackMode.repeatOne);
      await service.handleCommand('cyclePlaybackMode', source: 'taskbar');
      expect(playlist.playbackMode, PlaybackMode.sequential);
      await service.handleCommand('repeatOne');
      expect(playlist.playbackMode, PlaybackMode.repeatOne);
      await service.handleCommand('repeatList');
      expect(playlist.playbackMode, PlaybackMode.sequential);
      expect(settings.playlistWrapToFirst, true);
      await service.handleCommand('shuffleOn');
      await service.handleCommand('repeatOff');
      expect(playlist.playbackMode, PlaybackMode.shuffle);
      expect(settings.playlistWrapToFirst, false);
      await service.handleCommand('shuffleOff');
      expect(playlist.playbackMode, PlaybackMode.sequential);
      settings.desktopTaskbarMediaControls = false;
      await service.handleCommand('cyclePlaybackMode', source: 'taskbar');
      expect(playlist.playbackMode, PlaybackMode.sequential);
    },
  );

  test(
    'refresh waits until an in-flight publication drains the latest stop',
    () async {
      final block = Completer<void>();
      blockedUpdate = block;
      playback.seed();
      await Future<void>.delayed(Duration.zero);
      playback.item = null;
      playback.phase = PlaybackState.idle;
      playback.notifyListeners();
      var flushed = false;
      final flush = service.refreshNow().then((_) => flushed = true);
      await Future<void>.delayed(Duration.zero);
      expect(flushed, false);
      block.complete();
      await flush;
      expect(updates.last['active'], false);
      expect(service.status.value['hotkeysRegistered'], false);
    },
  );

  testWidgets('desktop settings remain readable and hotkeys start disabled', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(540, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    DesktopMediaSessionService.instance.status.value = {
      'globalHotkeys': true,
      'error': '',
    };
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: nav, home: const Scaffold()),
    );
    unawaited(showDesktopMediaSettings(nav.currentContext!, settings));
    await tester.pumpAndSettle();
    expect(find.text('桌面媒体控制'), findsOneWidget);
    final toggle = find.byKey(const ValueKey('desktop-global-hotkeys'));
    await tester.ensureVisible(toggle);
    expect(tester.widget<SwitchListTile>(toggle).value, false);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(settings.desktopGlobalMediaHotkeys, true);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
  });
}
