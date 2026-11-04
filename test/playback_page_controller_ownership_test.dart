import 'package:video_player_app/platform/windows_video_player_media_kit.dart';
import 'package:video_player_app/utils/playback_page_visibility.dart';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('playback pages never create or transfer native controllers', () {
    for (final path in <String>[
      'lib/screens/portrait_video_screen.dart',
      'lib/screens/video_player_screen.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains('VideoPlayerController.file(')));
      expect(source, isNot(contains('VideoPlayerController.networkUrl(')));
      expect(source, isNot(contains('.setController(')));
    }
  });

  test('popup routes do not report playback pages as hidden', () {
    for (final path in <String>[
      'lib/screens/portrait_video_screen.dart',
      'lib/screens/video_player_screen.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(
        RegExp(
          r'setPlaybackPageVisible\s*\(\s*this\s*,\s*ModalRoute\.of\(context\)\?\.isCurrent',
        ).hasMatch(source),
        isFalse,
        reason:
            '$path must not disable Bilibili video merely because a popup route is open',
      );
      expect(
        source,
        contains('registerPlaybackPageIfCurrent(context, this)'),
        reason: '$path must still register its initial visible state',
      );
    }
  });

  test('video rejoin preserves a live audio clock and repairs only a reset', () {
    expect(NativeVideoPlayerMediaKit.shouldRepairClockAfterExternalVideoTrackEnable(
      clockBefore: const Duration(seconds: 24),
      clockAfter: const Duration(milliseconds: 24100)), isFalse);
    expect(NativeVideoPlayerMediaKit.shouldRepairClockAfterExternalVideoTrackEnable(
      clockBefore: const Duration(seconds: 24), clockAfter: Duration.zero), isTrue);
    expect(NativeVideoPlayerMediaKit.shouldSeekAfterExternalVideoTrackEnable(
      previousTrackId: 'no', nextTrackId: '1', clockPosition: const Duration(seconds: 24)), isTrue);
    expect(NativeVideoPlayerMediaKit.shouldSeekAfterExternalVideoTrackEnable(
      previousTrackId: '1', nextTrackId: '1', clockPosition: const Duration(seconds: 24)), isFalse);
    expect(NativeVideoPlayerMediaKit.shouldSeekAfterExternalVideoTrackEnable(
      previousTrackId: 'no', nextTrackId: '1', clockPosition: Duration.zero), isFalse);
  });

  test('released controllers never mount; a live decoded texture survives re-entry', () {
    bool visible({bool current = true, bool initialized = true,
        bool decoded = true, bool borrowed = false}) => shouldKeepPlaybackVideoSurface(
      controllerIsCurrent: current, initialized: initialized,
      hasDecodedTexture: decoded, musicCoverOwnsSurface: borrowed);
    expect(visible(current: false), isFalse, reason: 'The service released this controller');
    expect(visible(initialized: false, decoded: false), isFalse, reason: 'No decoded output yet');
    expect(visible(initialized: false), isTrue, reason: 'Keep a live warm texture during a page handoff');
    expect(visible(borrowed: true), isFalse, reason: 'Only one page can own the output');
    expect(visible(), isTrue);
  });

  test('re-entry defers play while an active Bilibili session remounts', () {
    final landscape = File(
      'lib/screens/video_player_screen.dart',
    ).readAsStringSync();
    final portrait = File(
      'lib/screens/portrait_video_screen.dart',
    ).readAsStringSync();
    final service = File(
      'lib/services/media_playback_service.dart',
    ).readAsStringSync();
    expect(service, contains('shouldDeferPlayForActiveSession('));
    expect(
      landscape,
      contains('shouldDeferPlayForActiveSession(currentItem.id)'),
    );
    expect(
      portrait,
      contains('shouldDeferPlayForActiveSession(currentItem.id)'),
    );
    expect(landscape, contains('startPositionForCurrentSession('));
    expect(portrait, contains('startPositionForCurrentSession('));
  });

  test('ready Bilibili video is not covered by the loading overlay', () {
    final landscape = File(
      'lib/screens/video_player_screen.dart',
    ).readAsStringSync();
    final portrait = File(
      'lib/screens/portrait_video_screen.dart',
    ).readAsStringSync();
    expect(landscape, isNot(contains('!service.isSwitchingStreamQuality')));
    expect(portrait, isNot(contains('!service.isSwitchingStreamQuality')));
    expect(landscape, contains('!(_initialized && _controllerAssigned)'));
    expect(portrait, contains('!(_initialized && _isControllerAssigned)'));
    expect(landscape, contains('_buildVisibleVideoFrameCover()'));
    expect(portrait, contains('_buildVisibleVideoFrameCover()'));
    expect(
      portrait,
      contains(
        'Mark the texture visible before the aspect-ratio persist await',
      ),
    );
    expect(
      portrait,
      contains('Only drop the decoded picture once reuse is impossible'),
    );
    final navigation = File(
      'lib/services/playback_navigation_service.dart',
    ).readAsStringSync();
    expect(navigation, contains('_holdPlaybackPageVisibleUntilOwned('));
    // Mini / notification entry used to drop the warmup owner after one frame.
    expect(
      navigation,
      isNot(
        contains(
          'if (warmOnlineVideo) await WidgetsBinding.instance.endOfFrame',
        ),
      ),
    );
  });

  test('library entry primes playback before the page route mounts', () {
    for (final path in <String>[
      'lib/screens/home_screen.dart',
      'lib/screens/collection_screen.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, contains('primeLibraryPlaybackEntry('));
      expect(source, contains('shouldShowMiniPlaybackCard'));
    }
    expect(
      File('lib/main.dart').readAsStringSync(),
      contains('restoredPlaybackPreview = await restorePlaybackPreview('),
    );
    expect(
      File('lib/services/playback_restore_preview.dart').readAsStringSync(),
      contains('publishRestoredSessionPreview('),
    );
    expect(
      File('lib/main.dart').readAsStringSync(),
      contains('shouldPrepareNativePlayerOnRestore('),
    );
    expect(
      File('lib/main.dart').readAsStringSync(),
      contains('warmRestoredOnlinePlayback('),
    );
    final home = File('lib/screens/home_screen.dart').readAsStringSync();
    final shell = File(
      'lib/widgets/media_library_shell.dart',
    ).readAsStringSync();
    final miniCardRegion = shell.substring(
      shell.indexOf('MediaLibraryOverlayKeys.miniPlaybackCard'),
    );
    expect(miniCardRegion, contains('shouldShowMiniPlaybackCard'));
    expect(
      shell.split('shouldShowMiniPlaybackCard').length,
      greaterThan(2),
      reason: 'The library frame Mini card and fill use metadata visibility',
    );
    expect(
      home.split('shouldShowMiniPlaybackCard').length,
      greaterThan(2),
      reason: 'Home padding and FAB must use metadata visibility',
    );
  });

  test(
    'every episode navigation UI delegates playback behavior to service',
    () {
      for (final path in <String>[
        'lib/screens/portrait_video_screen.dart',
        'lib/screens/video_player_screen.dart',
        'lib/widgets/episode_picker_panel.dart',
        'lib/widgets/mini_playback_card.dart',
        'lib/services/system_media_session_service.dart',
      ]) {
        final source = File(path).readAsStringSync();
        expect(
          RegExp(r'playNext\s*\(\s*autoPlay:').hasMatch(source),
          isFalse,
          reason: '$path must not override the persisted switch',
        );
        expect(
          RegExp(r'playPrevious\s*\(\s*autoPlay:').hasMatch(source),
          isFalse,
          reason: '$path must not override the persisted switch',
        );
      }

      final landscapePage = File(
        'lib/screens/video_player_screen.dart',
      ).readAsStringSync();
      expect(landscapePage, isNot(contains('autoPlayNextEnabled')));
    },
  );
}
