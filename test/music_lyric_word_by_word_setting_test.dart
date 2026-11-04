import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoSwitch;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/screens/music_player_screen.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/music_lyric_view.dart';
import 'package:video_player_app/widgets/music_timed_lyric_text.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    final settings = SettingsService();
    settings.musicLyricWordByWordEnabled = true;
    settings.musicLyricBlurEnabled = true;
    try {
      await settings.updateMusicLyricWordByWordEnabled(true);
      await settings.updateMusicLyricBlurEnabled(true);
    } catch (_) {
      // 还没 init 的用例没有偏好存储，内存值已经回到默认。
    }
  });

  test('逐词显示默认打开，关闭后写入偏好', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsService()..resetForTest();
    await settings.init();

    expect(settings.musicLyricWordByWordEnabled, isTrue);

    await settings.updateMusicLyricWordByWordEnabled(false);
    expect(settings.musicLyricWordByWordEnabled, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('musicLyricWordByWordEnabled'), isFalse);

    settings.resetForTest();
    await settings.init();
    expect(settings.musicLyricWordByWordEnabled, isFalse);
  });

  testWidgets('关闭逐词后整行显示，重新打开后恢复逐词着色', (tester) async {
    final clock = ValueNotifier<Duration>(Duration.zero);
    addTearDown(clock.dispose);
    final cue = SubtitleItem(
      index: 0,
      startTime: Duration.zero,
      endTime: Duration(milliseconds: 1900),
      text: 'MMMM NNNN',
      timedSpans: [
        SubtitleTimedSpan(
          textStart: 0,
          textEnd: 4,
          startTime: Duration.zero,
          endTime: Duration(milliseconds: 600),
        ),
        SubtitleTimedSpan(
          textStart: 5,
          textEnd: 9,
          startTime: Duration(milliseconds: 900),
          endTime: Duration(milliseconds: 1900),
        ),
      ],
    );

    Future<void> pump({required bool wordByWord}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: MusicLyricView(
              subtitles: [cue],
              positionListenable: clock,
              isPlaying: false,
              applyEdgeFade: false,
              wordByWordEnabled: wordByWord,
              onSeek: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
    }

    Finder line() => find.byWidgetPredicate(
      (widget) => widget is MusicTimedLyricText && widget.text == 'MMMM NNNN',
    );

    await pump(wordByWord: true);
    expect(tester.widget<MusicTimedLyricText>(line()).spans, isNotEmpty);

    await pump(wordByWord: false);
    expect(tester.widget<MusicTimedLyricText>(line()).spans, isEmpty);

    await pump(wordByWord: true);
    expect(tester.widget<MusicTimedLyricText>(line()).spans, isNotEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('字号弹层里的逐词开关立即生效，并在重新进入后保持', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsService()..resetForTest();
    await settings.init();
    final playback = MediaPlaybackService();
    playback.setSubtitles([
      SubtitleItem(
        index: 0,
        startTime: Duration.zero,
        endTime: Duration(seconds: 2),
        text: 'WORD LINE',
        timedSpans: [
          SubtitleTimedSpan(
            textStart: 0,
            textEnd: 4,
            startTime: Duration.zero,
            endTime: Duration(milliseconds: 800),
          ),
        ],
      ),
    ]);

    Future<void> openPlayer() async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsService>.value(value: settings),
            ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
          ],
          child: const MaterialApp(home: MusicPlayerScreen(title: 'Track')),
        ),
      );
      await tester.pump();
    }

    Finder lyric() => find.byWidgetPredicate(
      (widget) => widget is MusicTimedLyricText && widget.text == 'WORD LINE',
    );
    final toggle = find.byKey(const ValueKey('music-word-by-word-switch'));

    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await openPlayer();
    expect(
      find.byKey(const ValueKey('music-word-by-word-switch')),
      findsNothing,
    );

    await tester.tap(find.byIcon(Icons.format_size));
    await tester.pump();

    expect(toggle, findsOneWidget);
    expect(tester.widget<CupertinoSwitch>(toggle).value, isTrue);
    expect(tester.widget<MusicTimedLyricText>(lyric()).spans, isNotEmpty);

    await tester.tap(toggle);
    await tester.pump();

    expect(
      find.byKey(const ValueKey('music-font-size-slider')),
      findsOneWidget,
    );
    expect(tester.widget<CupertinoSwitch>(toggle).value, isFalse);
    expect(settings.musicLyricWordByWordEnabled, isFalse);
    expect(tester.widget<MusicTimedLyricText>(lyric()).spans, isEmpty);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('musicLyricWordByWordEnabled'), isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    await openPlayer();
    await tester.tap(find.byIcon(Icons.format_size));
    await tester.pump();
    expect(tester.widget<CupertinoSwitch>(toggle).value, isFalse);
    expect(tester.widget<MusicTimedLyricText>(lyric()).spans, isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('歌词模糊默认打开，关闭后写入偏好', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsService()..resetForTest();
    await settings.init();

    expect(settings.musicLyricBlurEnabled, isTrue);

    await settings.updateMusicLyricBlurEnabled(false);
    expect(settings.musicLyricBlurEnabled, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('musicLyricBlurEnabled'), isFalse);

    settings.resetForTest();
    await settings.init();
    expect(settings.musicLyricBlurEnabled, isFalse);
  });

  testWidgets('页面设置里的模糊开关默认打开，关闭后歌词不再虚化并保持', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsService()..resetForTest();
    await settings.init();
    final playback = MediaPlaybackService();
    playback.setSubtitles([
      SubtitleItem(
        index: 0,
        startTime: Duration.zero,
        endTime: const Duration(seconds: 2),
        text: 'BLUR LINE',
      ),
    ]);

    Future<void> openPlayer() async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsService>.value(value: settings),
            ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
          ],
          child: const MaterialApp(home: MusicPlayerScreen(title: 'Track')),
        ),
      );
      await tester.pump();
    }

    Finder depth() => find.ancestor(
      of: find.byWidgetPredicate(
        (widget) => widget is MusicTimedLyricText && widget.text == 'BLUR LINE',
      ),
      matching: find.byType(MusicLyricDepth),
    );
    final toggle = find.byKey(const ValueKey('music-lyric-blur-switch'));

    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await openPlayer();
    expect(find.byTooltip('页面设置 (S)'), findsOneWidget);
    expect(find.byTooltip('调节字号'), findsNothing);
    expect(tester.widget<MusicLyricDepth>(depth()).blurEnabled, isTrue);

    await tester.tap(find.byIcon(Icons.format_size));
    await tester.pump();

    expect(toggle, findsOneWidget);
    expect(tester.widget<CupertinoSwitch>(toggle).value, isTrue);

    await tester.tap(toggle);
    await tester.pump();

    expect(
      find.byKey(const ValueKey('music-font-size-slider')),
      findsOneWidget,
    );
    expect(tester.widget<CupertinoSwitch>(toggle).value, isFalse);
    expect(settings.musicLyricBlurEnabled, isFalse);
    expect(tester.widget<MusicLyricDepth>(depth()).blurEnabled, isFalse);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('musicLyricBlurEnabled'), isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    await openPlayer();
    await tester.tap(find.byIcon(Icons.format_size));
    await tester.pump();
    expect(tester.widget<CupertinoSwitch>(toggle).value, isFalse);
    expect(tester.widget<MusicLyricDepth>(depth()).blurEnabled, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
