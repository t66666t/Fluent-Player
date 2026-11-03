import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/platform/app_video_player_controller.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';

/// Desktop native regression. Requires ffmpeg on PATH to create local fixtures.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native video keeps its presentation ratio after slow loading, '
      'sidebar resizing, rotation and anamorphic decoding', (tester) async {
    SharedPreferences.setMockInitialValues({});
    NativeVideoPlayerMediaKit.ensureInitialized();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final directory = await Directory.systemTemp.createTemp('video_geometry_');
    HttpServer? server;
    AppVideoPlayerController? active;
    Future<void> ffmpeg(List<String> args) async {
      final result = await Process.run('ffmpeg', [
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        ...args,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    }

    Future<void> frames([int count = 20]) async {
      for (var i = 0; i < count; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    Widget host(VideoPlayerController controller, double sidebar) =>
        MaterialApp(
          home: ColoredBox(
            color: Colors.black,
            child: Row(
              children: [
                Expanded(
                  child: Center(
                    child: ValueListenableBuilder<VideoPlayerValue>(
                      valueListenable: controller,
                      builder: (context, value, child) => AspectRatio(
                        aspectRatio: value.aspectRatio,
                        child: child,
                      ),
                      child: SizedBox(
                        key: const ValueKey('native-picture'),
                        child: VideoPlayer(controller),
                      ),
                    ),
                  ),
                ),
                SizedBox(width: sidebar),
              ],
            ),
          ),
        );

    try {
      final landscape = '${directory.path}/landscape.mp4';
      final rotated = '${directory.path}/rotated.mp4';
      final anamorphic = '${directory.path}/anamorphic.mp4';
      await ffmpeg([
        '-f',
        'lavfi',
        '-i',
        'testsrc2=size=640x360:rate=10',
        '-f',
        'lavfi',
        '-i',
        'anullsrc=r=48000:cl=stereo',
        '-t',
        '6',
        '-c:v',
        'libx264',
        '-preset',
        'ultrafast',
        '-g',
        '10',
        '-pix_fmt',
        'yuv420p',
        '-c:a',
        'aac',
        '-movflags',
        '+faststart',
        landscape,
      ]);
      await ffmpeg([
        '-display_rotation:v:0',
        '90',
        '-i',
        landscape,
        '-c',
        'copy',
        rotated,
      ]);
      await ffmpeg([
        '-f',
        'lavfi',
        '-i',
        'testsrc2=size=720x576:rate=10',
        '-t',
        '4',
        '-vf',
        'setsar=64/45',
        '-c:v',
        'libx264',
        '-preset',
        'ultrafast',
        '-pix_fmt',
        'yuv420p',
        anamorphic,
      ]);
      final bytes = await File(landscape).readAsBytes();
      final data = ByteData.sublistView(bytes);
      var mediaOffset = 0;
      while (mediaOffset + 8 < bytes.length) {
        final length = data.getUint32(mediaOffset);
        final type = String.fromCharCodes(
          bytes.sublist(mediaOffset + 4, mediaOffset + 8),
        );
        if (type == 'mdat' || length < 8) break;
        mediaOffset += length;
      }
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        debugPrint(
          'Geometry fixture request: ${request.headers.value('range')}',
        );
        final match = RegExp(
          r'bytes=(\d+)-(\d*)',
        ).firstMatch(request.headers.value('range') ?? '');
        final start = match == null ? 0 : int.parse(match[1]!);
        final end = match == null || match[2]!.isEmpty
            ? bytes.length - 1
            : int.parse(match[2]!);
        final response = request.response;
        response.headers.set('Accept-Ranges', 'bytes');
        response.headers.contentType = ContentType('video', 'mp4');
        response.contentLength = end - start + 1;
        if (match != null) {
          response.statusCode = HttpStatus.partialContent;
          response.headers.set(
            'Content-Range',
            'bytes $start-$end/${bytes.length}',
          );
        }
        try {
          if (start < mediaOffset) {
            response.add(
              bytes.sublist(start, mediaOffset.clamp(start, end + 1)),
            );
            await response.flush();
          }
          // Duration/track metadata is available, video decoding is still late.
          await Future<void>.delayed(const Duration(milliseconds: 2300));
          final bodyStart = start < mediaOffset ? mediaOffset : start;
          if (bodyStart <= end) response.add(bytes.sublist(bodyStart, end + 1));
          await response.close();
        } catch (_) {
          // The demuxer can cancel a Range request when it seeks.
        }
      });
      final sources = <(String, double)>[
        (landscape, 16 / 9),
        (rotated, 9 / 16),
        (anamorphic, 16 / 9),
        ('http://127.0.0.1:${server.port}/slow.mp4', 16 / 9),
      ];
      for (final (source, ratio) in sources) {
        final controller = source.startsWith('http')
            ? AppVideoPlayerController.networkUrl(Uri.parse(source))
            : AppVideoPlayerController.file(File(source));
        active = controller;
        debugPrint('Geometry fixture opening: $source');
        var initialized = false;
        final initialization = controller.initialize().timeout(
          const Duration(seconds: 25),
        );
        initialization.then(
          (_) => initialized = true,
          onError: (Object _) {
            initialized = true;
          },
        );
        while (!initialized) {
          await frames(1);
        }
        await initialization;
        expect(controller.value.size.shortestSide, greaterThan(0));
        expect(
          controller.value.aspectRatio,
          closeTo(ratio, 0.005),
          reason: source,
        );
        // ignore: invalid_use_of_visible_for_testing_member
        final firstFrame = NativeVideoPlayerMediaKit.firstFrameRenderedFor(
          controller.playerId,
        );
        await controller.play();
        await tester.pumpWidget(host(controller, 300));
        await frames(30);
        if (firstFrame != null) {
          await firstFrame.timeout(const Duration(seconds: 10));
        }
        for (final sidebar in [300.0, 200.0, 0.0, 300.0]) {
          await tester.pumpWidget(host(controller, sidebar));
          await frames();
          expect(
            tester
                .getSize(find.byKey(const ValueKey('native-picture')))
                .aspectRatio,
            closeTo(ratio, 0.005),
            reason: '$source sidebar=$sidebar',
          );
          expect(controller.value.hasError, isFalse);
        }
        await tester.pumpWidget(const SizedBox());
        await controller.dispose();
        active = null;
      }
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await active?.dispose();
      await server?.close(force: true);
      await directory.delete(recursive: true);
    }
  }, skip: !(Platform.isWindows || Platform.isMacOS || Platform.isLinux));
}
