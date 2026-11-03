import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/music_lyric_display_mode.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/music_lyric_content_resolver.dart';
import 'package:video_player_app/services/settings_service.dart';

SubtitleItem _cue(
  int index,
  int startMs,
  String text, {
  int endMs = 0,
  String translation = '',
  String romanization = '',
  List<SubtitleTimedSpan> spans = const [],
}) {
  return SubtitleItem(
    index: index,
    startTime: Duration(milliseconds: startMs),
    endTime: Duration(milliseconds: endMs == 0 ? startMs + 1000 : endMs),
    text: text,
    lyricTranslation: translation,
    lyricRomanization: romanization,
    timedSpans: spans,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('embedded translation outranks newline splitting', () {
    final projection = resolveMusicLyricProjection(
      mediaId: 'song',
      primary: [_cue(1, 0, 'Hello\nWorld', translation: '你好')],
      secondary: const [],
      splitSubtitleByLine: true,
      mode: MusicLyricTrackDisplayMode.both,
    );
    final row = projection.rows.single;
    expect(row.main.text, 'Hello\nWorld');
    expect(row.translation, '你好');
    expect(row.fragments.map((piece) => piece.role), [
      MusicLyricFragmentRole.main,
      MusicLyricFragmentRole.secondary,
    ]);
  });

  test('newline split is only the fallback without a secondary track', () {
    final split = resolveMusicLyricProjection(
      mediaId: 'song',
      primary: [_cue(1, 0, 'Hello\nWorld')],
      secondary: const [],
      splitSubtitleByLine: true,
      mode: MusicLyricTrackDisplayMode.both,
    );
    expect(split.rows.single.main.text, 'Hello');
    expect(split.rows.single.translation, 'World');

    final kept = resolveMusicLyricProjection(
      mediaId: 'song',
      primary: [_cue(1, 0, 'Hello\nWorld')],
      secondary: const [],
      splitSubtitleByLine: false,
      mode: MusicLyricTrackDisplayMode.both,
    );
    expect(kept.rows.single.main.text, 'Hello\nWorld');
    expect(kept.rows.single.translation, isEmpty);
  });

  test('independent secondary track is not split and orphans stay unique', () {
    final primary = [
      _cue(1, 0, 'One', endMs: 1000),
      _cue(2, 3000, 'Two', endMs: 4000),
    ];
    final secondary = [
      _cue(1, 0, '一', endMs: 500),
      _cue(2, 500, '壹', endMs: 1000),
      _cue(9, 1500, '孤立', endMs: 2000),
    ];
    final both = resolveMusicLyricProjection(
      mediaId: 'song',
      primary: primary,
      secondary: secondary,
      splitSubtitleByLine: true,
      mode: MusicLyricTrackDisplayMode.both,
    );
    expect(both.rows.map((row) => row.groupId), ['p:0', 's:2', 'p:1']);
    expect(both.rows[0].translation, '一\n壹');
    expect(both.rows[1].independentSecondary, isTrue);
    expect(both.rows[1].main.text, '孤立');

    final secondaryOnly = resolveMusicLyricProjection(
      mediaId: 'song',
      primary: primary,
      secondary: secondary,
      splitSubtitleByLine: true,
      mode: MusicLyricTrackDisplayMode.secondary,
    );
    expect(secondaryOnly.rows, hasLength(3));
    expect(secondaryOnly.rows.map((row) => row.main.text), ['一', '壹', '孤立']);
  });

  test('background and romanization stay with the main role', () {
    final cue = SubtitleItem(
      index: 1,
      startTime: Duration.zero,
      endTime: const Duration(seconds: 2),
      text: 'Lead (echo)',
      lyricRomanization: 'li:d',
      timedSpans: [
        SubtitleTimedSpan(
          textStart: 5,
          textEnd: 11,
          startTime: const Duration(milliseconds: 200),
          endTime: const Duration(milliseconds: 800),
          role: 'x-bg',
        ),
      ],
    );
    final both = resolveMusicLyricProjection(
      mediaId: 'song',
      primary: [cue],
      secondary: const [],
      splitSubtitleByLine: false,
      mode: MusicLyricTrackDisplayMode.both,
    );
    expect(both.rows.single.background, isNotEmpty);
    expect(both.rows.single.romanization, 'li:d');
    expect(
      both.rows.single.fragments.map((piece) => piece.role),
      containsAll([
        MusicLyricFragmentRole.main,
        MusicLyricFragmentRole.background,
        MusicLyricFragmentRole.romanization,
      ]),
    );
    expect(
      both.rows.single.fragments.map((piece) => piece.role),
      isNot(contains(MusicLyricFragmentRole.secondary)),
    );

    final secondary = resolveMusicLyricProjection(
      mediaId: 'song',
      primary: [cue],
      secondary: [_cue(1, 0, '回声')],
      splitSubtitleByLine: false,
      mode: MusicLyricTrackDisplayMode.secondary,
    );
    expect(secondary.rows.single.main.text, '回声');
    expect(secondary.rows.single.background, isEmpty);
    expect(secondary.rows.single.romanization, isEmpty);
  });

  test('image-only cues do not invent selectable text', () {
    final image = SubtitleItem(
      index: 1,
      startTime: Duration.zero,
      endTime: const Duration(seconds: 1),
      imageLoader: () async => null,
    );
    final projection = resolveMusicLyricProjection(
      mediaId: 'song',
      primary: [image],
      secondary: const [],
      splitSubtitleByLine: true,
      mode: MusicLyricTrackDisplayMode.both,
    );
    expect(projection.rows, isEmpty);
    expect(projection.availability.imageOnly, isTrue);
    expect(projection.availability.hasSelectableText, isFalse);
  });

  test(
    'missing roles downgrade the effective mode without rewriting preference',
    () {
      final onlyPrimary = resolveMusicLyricEffectiveDisplay(
        preference: MusicLyricTrackDisplayMode.secondary,
        availability: const MusicLyricTrackAvailability(
          hasPrimaryText: true,
          hasSecondaryText: false,
          imageOnly: false,
        ),
      );
      expect(onlyPrimary.effective, MusicLyricTrackDisplayMode.primary);
      expect(onlyPrimary.preference, MusicLyricTrackDisplayMode.secondary);
      expect(onlyPrimary.secondaryEnabled, isFalse);
      expect(onlyPrimary.notice, '当前无副字幕，已显示主字幕');

      final onlySecondary = resolveMusicLyricEffectiveDisplay(
        preference: MusicLyricTrackDisplayMode.primary,
        availability: const MusicLyricTrackAvailability(
          hasPrimaryText: false,
          hasSecondaryText: true,
          imageOnly: false,
        ),
      );
      expect(onlySecondary.effective, MusicLyricTrackDisplayMode.secondary);
      expect(onlySecondary.notice, '当前无主字幕，已显示副字幕');
    },
  );

  test(
    'display preference survives restart, corrupt values and export',
    () async {
      SharedPreferences.setMockInitialValues({
        'musicLyricTrackDisplayMode': 'not-a-mode',
      });
      final settings = SettingsService();
      await settings.init();
      expect(settings.musicLyricTrackDisplayMode, 'both');
      await settings.updateMusicLyricTrackDisplayMode('secondary');
      expect(
        settings
            .exportSettingsSnapshot()['music']['musicLyricTrackDisplayMode'],
        'secondary',
      );
      expect(settings.splitSubtitleByLine, isTrue);

      settings.resetForTest();
      final reloaded = SettingsService();
      await reloaded.init();
      expect(reloaded.musicLyricTrackDisplayMode, 'secondary');
      await reloaded.updateMusicLyricTrackDisplayMode('primary');
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('musicLyricTrackDisplayMode');
      settings.resetForTest();
      final reset = SettingsService();
      await reset.init();
      expect(reset.musicLyricTrackDisplayMode, 'both');
    },
  );
}
