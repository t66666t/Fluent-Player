import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/playback_navigation_service.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'page-entry auto-play defaults to enabled and persists changes',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final settings = SettingsService()..resetForTest();
      await settings.init();

      expect(settings.autoPlayOnPageEntry, isTrue);

      await settings.saveAutoPlayOnPageEntry(false);
      expect(settings.autoPlayOnPageEntry, isFalse);
      expect(
        (await SharedPreferences.getInstance()).getBool('autoPlayOnPageEntry'),
        isFalse,
      );

      settings.resetForTest();
      await settings.init();
      expect(settings.autoPlayOnPageEntry, isFalse);
    },
  );

  group(
    'page-entry auto-play remains independent from other playback intent',
    () {
      test('enabled starts both new and paused current media', () {
        expect(
          resolvePlaybackPageEntryAutoPlay(
            entryAutoPlay: true,
            isCurrentItem: false,
            desiredPlaying: false,
          ),
          isTrue,
        );
        expect(
          resolvePlaybackPageEntryAutoPlay(
            entryAutoPlay: true,
            isCurrentItem: true,
            desiredPlaying: false,
          ),
          isTrue,
        );
      });

      test(
        'disabled keeps an existing session state but does not start a new item',
        () {
          expect(
            resolvePlaybackPageEntryAutoPlay(
              entryAutoPlay: false,
              isCurrentItem: false,
              desiredPlaying: true,
            ),
            isFalse,
          );
          expect(
            resolvePlaybackPageEntryAutoPlay(
              entryAutoPlay: false,
              isCurrentItem: true,
              desiredPlaying: true,
            ),
            isTrue,
          );
          expect(
            resolvePlaybackPageEntryAutoPlay(
              entryAutoPlay: false,
              isCurrentItem: true,
              desiredPlaying: false,
            ),
            isFalse,
          );
        },
      );

      test('internal page hand-offs retain their previous behavior', () {
        expect(
          resolvePlaybackPageEntryAutoPlay(
            entryAutoPlay: null,
            isCurrentItem: true,
            desiredPlaying: false,
          ),
          isFalse,
        );
        expect(
          resolvePlaybackPageEntryAutoPlay(
            entryAutoPlay: null,
            isCurrentItem: false,
            desiredPlaying: false,
          ),
          isTrue,
        );
      });
    },
  );

  test('Mini and library entry use page-entry auto-play without pausing a live clock', () {
    final navigation = File(
      'lib/services/playback_navigation_service.dart',
    ).readAsStringSync();
    expect(navigation, contains('resolvePlaybackPageEntryAutoPlay('));
    expect(
      navigation,
      isNot(contains('autoPlay: SettingsService().autoPlayOnPageEntry')),
    );
  });
}
