import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/ambient_letterbox_policy.dart';
import 'package:video_player_app/widgets/settings_panel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('留边氛围默认关闭，并可写入持久化', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();

    expect(settings.experimentalAmbientLetterbox, isFalse);

    await settings.saveExperimentalAmbientLetterbox(true);
    expect(settings.experimentalAmbientLetterbox, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('experimentalAmbientLetterbox'), isTrue);
  });

  test('侧栏改宽度不触发抽帧，用户变换不改变背景矩形', () {
    expect(
      AmbientLetterboxPolicy.requestsFrameForColumnResize(
        const Size(1280, 720),
        const Size(860, 720),
      ),
      isFalse,
    );

    const column = Size(1280, 720);
    final still = AmbientLetterboxPolicy.backdropRect(columnSize: column);
    final transformed = AmbientLetterboxPolicy.backdropRect(
      columnSize: column,
      userScale: 2.4,
      userRotation: 0.8,
      userOffset: const Offset(40, -18),
    );
    expect(transformed, still);
    expect(transformed, const Rect.fromLTWH(0, 0, 1280, 720));
  });

  test('露边、拖动、缓冲和手势决定是否取样', () {
    const covered = Size(1600, 900);
    expect(
      AmbientLetterboxPolicy.hasVisibleGap(
        columnSize: covered,
        containedVideoSize: covered,
        userScale: 1,
        userRotation: 0,
        userOffset: Offset.zero,
      ),
      isFalse,
    );
    expect(
      AmbientLetterboxPolicy.hasVisibleGap(
        columnSize: const Size(900, 700),
        containedVideoSize: const Size(900, 506),
        userScale: 1,
        userRotation: 0,
        userOffset: Offset.zero,
      ),
      isTrue,
    );
    expect(
      AmbientLetterboxPolicy.hasVisibleGap(
        columnSize: covered,
        containedVideoSize: covered,
        userScale: 0.6,
        userRotation: 0,
        userOffset: Offset.zero,
      ),
      isTrue,
    );
    expect(
      AmbientLetterboxPolicy.hasVisibleGap(
        columnSize: covered,
        containedVideoSize: covered,
        userScale: 1,
        userRotation: 0.4,
        userOffset: Offset.zero,
      ),
      isTrue,
    );

    bool sample({
      bool seeking = false,
      bool buffering = false,
      bool transforming = false,
      bool visibleGap = true,
    }) {
      return AmbientLetterboxPolicy.shouldSample(
        enabled: true,
        hasPlayableVideo: true,
        visibleGap: visibleGap,
        seeking: seeking,
        buffering: buffering,
        transforming: transforming,
        captureInFlight: false,
      );
    }

    expect(sample(), isTrue);
    expect(sample(seeking: true), isFalse);
    expect(sample(buffering: true), isFalse);
    expect(sample(transforming: true), isFalse);
    expect(sample(visibleGap: false), isFalse);
  });

  test('模糊保持尺寸，并把硬边晕开', () {
    const width = 8;
    const height = 4;
    final pixels = Uint8List(width * height * 4);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final pixel = (y * width + x) * 4;
        pixels[pixel] = x < width ~/ 2 ? 255 : 0;
        pixels[pixel + 3] = 255;
      }
    }
    final blurred = blurAmbientRgba(
      pixels: pixels,
      width: width,
      height: height,
      radius: 1,
    );
    expect(blurred.length, pixels.length);
    final boundary = (width ~/ 2) * 4;
    expect(blurred[boundary], lessThan(255));
    expect(blurred[boundary], greaterThan(0));
  });

  test('委托给系统播放器时取帧为空且不抛错', () async {
    final captured = Uint8List.fromList(<int>[1, 2, 3, 4]);
    expect(
      NativeVideoPlayerMediaKit.selectAmbientFrame(
        delegatedToPlatformPlayer: true,
        captured: captured,
      ),
      isNull,
    );
    expect(
      NativeVideoPlayerMediaKit.selectAmbientFrame(
        delegatedToPlatformPlayer: false,
        captured: captured,
      ),
      same(captured),
    );
    expect(await NativeVideoPlayerMediaKit.ambientFrameFor(-1), isNull);
  });

  for (final size in [const Size(320, 640), const Size(844, 390)]) {
    testWidgets('playback settings remain readable at 200% text, $size', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _host(
          audio: false,
          ambient: false,
          onAmbient: (_) {},
          textScaler: const TextScaler.linear(2),
        ),
      );
      await tester.scrollUntilVisible(
        find.text('有字幕时双击跳句'),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(
        find.widgetWithText(SwitchListTile, '有字幕时双击跳句'),
      );
      expect(find.textContaining('没有字幕时按下方秒数'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('画面留边氛围'),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.widgetWithText(SwitchListTile, '画面留边氛围'));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('视频设置底部有留边开关，音频模式不显示', (tester) async {
    final previousOnError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      final message = details.exceptionAsString();
      // Existing playback rows paint ListTiles on a tinted box. That debug
      // check is unrelated to whether this switch is present.
      if (message.contains('ListTile background color')) return;
      previousOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = previousOnError);

    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var enabled = false;
    await tester.pumpWidget(
      _host(
        audio: false,
        ambient: enabled,
        onAmbient: (value) => enabled = value,
      ),
    );
    await tester.scrollUntilVisible(
      find.text('画面留边氛围'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester.getTopLeft(find.text('画面留边氛围')).dy,
      greaterThan(tester.getTopLeft(find.text('水平翻转')).dy),
    );
    final tile = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, '画面留边氛围'),
    );
    expect(tile.value, isFalse);

    await tester.ensureVisible(find.widgetWithText(SwitchListTile, '画面留边氛围'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SwitchListTile, '画面留边氛围'));
    await tester.pump();
    expect(enabled, isTrue);

    await tester.pumpWidget(
      _host(audio: true, ambient: false, onAmbient: (_) {}),
    );
    await tester.pump();
    expect(find.text('画面留边氛围'), findsNothing);
    expect(find.text('实验功能'), findsNothing);
  });
}

Widget _host({
  required bool audio,
  required bool ambient,
  required ValueChanged<bool> onAmbient,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  return MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: textScaler),
      child: child!,
    ),
    home: Scaffold(
      body: SettingsPanel(
        playbackSpeed: 1,
        isPlaybackSpeedLocked: false,
        showSubtitles: true,
        isMirroredH: false,
        isMirroredV: false,
        onSpeedChanged: (_) {},
        onSpeedLockChanged: (_, _) async {},
        onSubtitleToggle: (_) {},
        onMirrorHChanged: (_) {},
        onMirrorVChanged: (_) {},
        onClose: () {},
        doubleTapSeekSeconds: 10,
        onSeekSecondsChanged: (_) {},
        enableDoubleTapSubtitleSeek: false,
        onDoubleTapSubtitleSeekChanged: (_) {},
        subtitleDelay: 0,
        onSubtitleDelayChanged: (_) {},
        longPressSpeed: 2,
        onLongPressSpeedChanged: (_) {},
        showLongPressSpeedIndicator: true,
        onShowLongPressSpeedIndicatorChanged: (_) {},
        autoCacheSubtitles: false,
        onAutoCacheSubtitlesChanged: (_) {},
        splitSubtitleByLine: false,
        onSplitSubtitleByLineChanged: (_) {},
        continuousSubtitle: false,
        onContinuousSubtitleChanged: (_) {},
        isAudioMode: audio,
        autoPauseOnExit: false,
        onAutoPauseOnExitChanged: (_) {},
        avoidPlaybackControlsWithSubtitles: true,
        onAvoidPlaybackControlsWithSubtitlesChanged: (_) {},
        pausePlaybackWhenAppBackgrounded: false,
        onPausePlaybackWhenAppBackgroundedChanged: (_) {},
        allowConcurrentPlayback: false,
        onAllowConcurrentPlaybackChanged: (_) {},
        showVideoDecoderSetting: false,
        useHardwareVideoDecoding: true,
        onVideoDecoderChanged: (_) async {},
        enableHeadsetMediaControls: true,
        onEnableHeadsetMediaControlsChanged: (_) {},
        skipPortraitPlayer: false,
        onSkipPortraitPlayerChanged: (_) {},
        autoPlayOnPageEntry: false,
        onAutoPlayOnPageEntryChanged: (_) {},
        autoPlayNextVideo: true,
        onAutoPlayNextVideoChanged: (_) {},
        autoPlayOnCompletion: false,
        onAutoPlayOnCompletionChanged: (_) {},
        autoPlayOnCompletionFromStart: false,
        onAutoPlayOnCompletionFromStartChanged: (_) {},
        playlistWrapToFirst: false,
        onPlaylistWrapToFirstChanged: (_) {},
        enableSeekPreview: true,
        onEnableSeekPreviewChanged: (_) {},
        enableHapticFeedback: false,
        onEnableHapticFeedbackChanged: (_) {},
        isLeftHandedMode: false,
        onLeftHandedModeChanged: (_) {},
        experimentalAmbientLetterbox: ambient,
        onExperimentalAmbientLetterboxChanged: onAmbient,
      ),
    ),
  );
}
