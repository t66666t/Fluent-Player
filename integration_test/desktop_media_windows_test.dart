import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/models/playback_mode.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';
import 'package:video_player_app/services/desktop_media_session_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playback_state_store.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/progress_tracker.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:window_manager/window_manager.dart';

// Uses silent local WAV files and in-memory preferences. No user library,
// credentials, downloads or existing playback history are read or modified.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Windows minimized commands control the real session and queue',
    (tester) async {
      if (!Platform.isWindows) return;
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService()..resetForTest();
      await settings.init();
      settings.desktopGlobalMediaHotkeys = true;
      settings.desktopMediaHotkeyModifiers = 'ctrl+alt+shift';
      settings.autoPlayNextVideo = true;
      settings.autoPlayOnCompletion = false;
      settings.enableVideoPreload = false;
      settings.playlistWrapToFirst = false;
      settings.doubleTapSeekSeconds = 7;
      settings.enableDoubleTapSubtitleSeek = false;
      NativeVideoPlayerMediaKit.ensureInitialized();
      final directory = await Directory.systemTemp.createTemp(
        'fluent_desktop_media_',
      );
      final store = PlaybackStateStore(platform: TargetPlatform.android);
      final playlist = PlaylistManager(modeStore: store);
      final playback = MediaPlaybackService.forTesting();
      final media = DesktopMediaSessionService();
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Desktop media integration')),
        ),
      );
      await windowManager.ensureInitialized();
      final title = 'Fluent desktop media integration $pid';
      await windowManager.setTitle(title);
      final user = DynamicLibrary.open('user32.dll');
      final find = user
          .lookupFunction<
            Pointer<Void> Function(Pointer<Utf16>, Pointer<Utf16>),
            Pointer<Void> Function(Pointer<Utf16>, Pointer<Utf16>)
          >('FindWindowW');
      final post = user
          .lookupFunction<
            Int32 Function(Pointer<Void>, Uint32, UintPtr, IntPtr),
            int Function(Pointer<Void>, int, int, int)
          >('PostMessageW');
      final titlePointer = title.toNativeUtf16();
      final hwnd = find(nullptr, titlePointer);
      calloc.free(titlePointer);
      expect(hwnd, isNot(nullptr));
      final frames = Timer.periodic(
        const Duration(milliseconds: 16),
        (_) => binding.scheduleFrame(),
      );
      Future<void> waitFor(bool Function() condition) async {
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (!condition()) {
          if (DateTime.now().isAfter(deadline)) {
            throw StateError(
              'Playback condition timed out: ${playback.state} ${playback.currentItem?.id}',
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
      }

      try {
        await playback.initialize(
          playlistManager: playlist,
          progressTracker: ProgressTracker(playbackStateStore: store),
        );
        final items = <VideoItem>[];
        for (var i = 0; i < 2; i++) {
          final file = File('${directory.path}/$i.wav');
          await file.writeAsBytes(_silence());
          items.add(
            VideoItem(
              id: 'desktop-probe-$i',
              path: file.path,
              title: 'Desktop media probe $i',
              type: MediaType.audio,
              durationMs: 30000,
              lastUpdated: 1,
            ),
          );
        }
        playlist.setPlaylist(items);
        await media.initialize(
          playbackService: playback,
          playlistManager: playlist,
          settings: settings,
        );
        expect(media.status.value['systemMedia'], true);
        await playback
            .play(items.first, autoPlay: true)
            .timeout(const Duration(seconds: 20));
        await media.refreshNow();
        expect(media.status.value['hotkeysRegistered'], true);
        await windowManager.minimize();
        expect(await windowManager.isMinimized(), true);
        // Genuine Win32 native-message -> channel -> real playback service path.
        expect(post(hwnd, 0x0312, 0x6170, 0), 1); // WM_HOTKEY: play/pause
        await waitFor(
          () =>
              !playback.desiredPlaying &&
              playback.controller?.value.isPlaying == false,
        );
        await media.refreshNow();
        // Configured seek amount, while paused, through the thumbnail buttons.
        expect(post(hwnd, 0x0111, (0x1800 << 16) | 0x6184, 0), 1);
        await waitFor(() => playback.position >= const Duration(seconds: 6));
        expect(playback.position, lessThan(const Duration(seconds: 9)));
        expect(playback.desiredPlaying, false);
        expect(post(hwnd, 0x0111, (0x1800 << 16) | 0x6183, 0), 1);
        await waitFor(() => playback.position < const Duration(seconds: 2));
        for (final mode in [
          PlaybackMode.shuffle,
          PlaybackMode.repeatOne,
          PlaybackMode.sequential,
        ]) {
          expect(post(hwnd, 0x0111, (0x1800 << 16) | 0x6185, 0), 1);
          await waitFor(() => playlist.playbackMode == mode);
          expect(playback.desiredPlaying, false);
        }
        expect(post(hwnd, 0x0312, 0x6170, 0), 1);
        await waitFor(
          () =>
              playback.desiredPlaying &&
              playback.controller?.value.isPlaying == true,
        );
        expect(post(hwnd, 0x0312, 0x6172, 0), 1); // next
        await waitFor(
          () =>
              playback.currentItem?.id == items.last.id &&
              playback.state == PlaybackState.playing,
        );
        await media.refreshNow();
        // Taskbar previous button, using the exact THBN_CLICKED window command.
        expect(post(hwnd, 0x0111, (0x1800 << 16) | 0x6180, 0), 1);
        await waitFor(
          () =>
              playback.currentItem?.id == items.first.id &&
              playback.state == PlaybackState.playing,
        );
        expect(await windowManager.isMinimized(), true);
        await playback.stop();
        await media.refreshNow();
        expect(media.status.value['hotkeysRegistered'], false);
      } finally {
        frames.cancel();
        media.dispose();
        await playback.stop();
        playback.dispose();
        playlist.dispose();
        await windowManager.restore();
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Uint8List _silence() {
  const samples = 8000 * 30;
  final bytes = Uint8List(44 + samples * 2);
  final data = ByteData.sublistView(bytes);
  void ascii(int offset, String text) =>
      bytes.setRange(offset, offset + text.length, text.codeUnits);
  ascii(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 8000, Endian.little);
  data.setUint32(28, 16000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, samples * 2, Endian.little);
  return bytes;
}
