import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/video_compose/video_compose_preview_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VideoComposePreviewController', () {
    late Directory tempDirectory;
    late File primary;
    late File secondary;

    setUp(() async {
      tempDirectory = await Directory.systemTemp.createTemp('compose_preview_');
      primary = File('${tempDirectory.path}${Platform.pathSeparator}main.srt');
      secondary = File(
        '${tempDirectory.path}${Platform.pathSeparator}secondary.srt',
      );
      await primary.writeAsString('1\n00:00:01,000 --> 00:00:03,000\n主字幕\n');
      await secondary.writeAsString(
        '1\n00:00:01,000 --> 00:00:03,000\nSecondary\n',
      );
    });

    tearDown(() async {
      await tempDirectory.delete(recursive: true);
    });

    test('副字幕开关只改变独立预览内容', () async {
      final controller = VideoComposePreviewController();
      await controller.configure(
        VideoComposePreviewConfig(
          primarySubtitlePath: primary.path,
          secondarySubtitlePath: secondary.path,
          renderSecondarySubtitle: true,
          continuousSubtitle: false,
          splitSubtitleByLine: false,
          burnSubtitles: true,
        ),
      );
      controller.update(const Duration(seconds: 2));
      expect(controller.displayNotifier.value.entries.single.text, '主字幕');
      expect(
        controller.displayNotifier.value.entries.single.secondaryText,
        'Secondary',
      );

      await controller.configure(
        VideoComposePreviewConfig(
          primarySubtitlePath: primary.path,
          secondarySubtitlePath: secondary.path,
          renderSecondarySubtitle: false,
          continuousSubtitle: false,
          splitSubtitleByLine: false,
          burnSubtitles: true,
        ),
      );
      controller.update(const Duration(seconds: 2));
      expect(controller.displayNotifier.value.entries.single.text, '主字幕');
      expect(
        controller.displayNotifier.value.entries.single.secondaryText,
        isNull,
      );
      controller.dispose();
    });

    test('纯软字幕和退出预览都不显示烧录字幕', () async {
      final controller = VideoComposePreviewController();
      await controller.configure(
        VideoComposePreviewConfig(
          primarySubtitlePath: primary.path,
          secondarySubtitlePath: secondary.path,
          renderSecondarySubtitle: true,
          continuousSubtitle: false,
          splitSubtitleByLine: false,
          burnSubtitles: false,
        ),
      );
      controller.update(const Duration(seconds: 2));
      expect(controller.displayNotifier.value.isEmpty, isTrue);

      await controller.configure(
        VideoComposePreviewConfig(
          primarySubtitlePath: primary.path,
          secondarySubtitlePath: null,
          renderSecondarySubtitle: false,
          continuousSubtitle: false,
          splitSubtitleByLine: false,
          burnSubtitles: true,
        ),
      );
      controller.update(const Duration(seconds: 2));
      expect(controller.displayNotifier.value.isEmpty, isFalse);
      controller.clear();
      expect(controller.displayNotifier.value.isEmpty, isTrue);
      controller.dispose();
    });
  });
}
