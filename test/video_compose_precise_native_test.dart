import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/model_center/inference_resource_governor.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/models/video_compose_models.dart';
import 'package:video_player_app/services/video_compose/video_compose_executor.dart';
import 'package:video_player_app/services/video_compose/video_compose_encoding.dart';
import 'package:video_player_app/services/video_compose/video_compose_precise_renderer.dart';
import 'package:video_player_app/services/video_compose/video_compose_probe_service.dart';
import 'package:video_player_app/services/video_compose/video_compose_types.dart';
import 'package:video_player_app/utils/ffmpeg_utils.dart';

void main() {
  const enabled = bool.fromEnvironment('VIDEO_COMPOSE_NATIVE');
  testWidgets(
    'real FFmpeg burns precise PNGs with timed gaps, audio and soft subtitles',
    (tester) async {
      await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp(
          "compose native 空格 O'Brien [,]; ",
        );
        try {
          const binaryOverride = String.fromEnvironment(
            'VIDEO_COMPOSE_NATIVE_FFMPEG',
          );
          final ffmpeg = binaryOverride.isEmpty
              ? await FFmpegUtils.ffmpegPath
              : binaryOverride;
          final input = File('${root.path}/source.mkv');
          final generated = await Process.run(ffmpeg, [
            '-v',
            'error',
            '-y',
            '-f',
            'lavfi',
            '-i',
            'color=c=black:s=640x360:r=60:d=2',
            '-f',
            'lavfi',
            '-i',
            'sine=frequency=440:sample_rate=48000:duration=2',
            '-c:v',
            'libx264',
            '-preset',
            'ultrafast',
            '-threads',
            '2',
            '-pix_fmt',
            'yuv420p',
            '-c:a',
            'pcm_mulaw',
            '-shortest',
            input.path,
          ]);
          expect(generated.exitCode, 0, reason: generated.stderr.toString());
          // This desktop CLI test explicitly requires ffprobe; the macOS app
          // itself uses FFprobeKit and does not require a standalone binary.
          final probe = await const VideoComposeProbeService(
            preferSystemFfmpeg: true,
          ).probeVideoInfo(input.path);
          expect(probe.frameRate, closeTo(60, .01));
          expect(probe.displayWidth, 640);
          final assets = await VideoComposePreciseRenderer().render(
            outputDirectory: Directory('${root.path}/scenes'),
            width: 640,
            height: 360,
            duration: probe.duration,
            primary: [
              _cue(1, 123, 789, 'Precise 中文\nTiming 60 fps'),
              _cue(1, 900, 1233, 'Second caption'),
              _cue(3, 1450, 1789, 'Precise 中文\nTiming 60 fps'),
            ],
            secondary: [],
            style: const SubtitleStyle(),
            alignment: const Alignment(0, .8),
            splitSubtitleByLine: true,
            itemGap: 6,
            onProgress: (_) {},
            onArtifact: (_) {},
          );
          expect(assets.frameCount, 3);
          final concat = await File(assets.concatPath).readAsString();
          expect(concat, contains('option framerate 1000'));
          final soft = File('${root.path}/soft.srt');
          await soft.writeAsString(
            '1\n00:00:00,123 --> 00:00:00,789\nSoft subtitle\n\n',
          );
          for (final hardware in [false, true]) {
            final output = File('${root.path}/result_$hardware.mp4');
            final labels = <String>[];
            final watch = Stopwatch()..start();
            final executor = VideoComposeExecutor(
              enableHardwareEncoding: hardware,
              loadEncoders: binaryOverride.isEmpty
                  ? null
                  : () async {
                      final listing = await Process.run(ffmpeg, [
                        '-hide_banner',
                        '-encoders',
                      ]);
                      expect(listing.exitCode, 0);
                      return VideoComposeEncoding.parseEncoders(
                        '${listing.stdout}\n${listing.stderr}',
                      );
                    },
              commandRunner: binaryOverride.isEmpty
                  ? null
                  : (args, onLine) async {
                      final result = await Process.run(ffmpeg, args);
                      for (final line in const LineSplitter().convert(
                        '${result.stdout}\n${result.stderr}',
                      )) {
                        onLine(line);
                      }
                      if (result.exitCode != 0) {
                        throw StateError(result.stderr.toString());
                      }
                    },
            );
            final request = VideoComposeRequest(
              videoId: 'native',
              videoPath: input.path,
              title: 'native',
              renderSecondarySubtitle: false,
              continuousSubtitle: false,
              embedSoftSubtitles: true,
              softSubtitleOnly: false,
              softSubtitleUseSourceQuality: true,
              softSubtitleTracks: [],
              resolution: VideoComposeResolution.source,
              subtitleStyle: const SubtitleStyle(),
              subtitleAlignment: Alignment.bottomCenter,
              outputPath: output.path,
            );
            await executor.execute(
              request: request,
              filter: executor.buildVideoFilter(
                sourceWidth: 640,
                sourceHeight: 360,
                targetWidth: 640,
                targetHeight: 360,
              ),
              preciseSubtitleConcatPath: assets.concatPath,
              softSubtitleInputs: [
                ComposeSubtitleInput(
                  path: soft.path,
                  title: '中文',
                  language: 'chi',
                ),
              ],
              duration: probe.duration,
              transcodeVideo: true,
              outputWidth: 640,
              outputHeight: 360,
              frameRate: probe.frameRate,
              onProgress: (_) {},
              onEncoderChanged: labels.add,
            );
            watch.stop();
            final inspected = await Process.run(await FFmpegUtils.ffprobePath, [
              '-v',
              'error',
              '-show_streams',
              '-show_format',
              '-of',
              'json',
              output.path,
            ]);
            expect(inspected.exitCode, 0, reason: inspected.stderr.toString());
            final info = jsonDecode(inspected.stdout as String) as Map;
            final streams = info['streams'] as List;
            expect(
              streams.where((s) => s['codec_type'] == 'video'),
              hasLength(1),
            );
            expect(
              streams.where((s) => s['codec_name'] == 'aac'),
              hasLength(1),
              reason: '$streams',
            );
            expect(
              streams.where((s) => s['codec_name'] == 'mov_text'),
              hasLength(1),
              reason: '$streams',
            );
            expect(
              double.parse(info['format']['duration'] as String),
              closeTo(2, .05),
            );
            final decoded = await Process.run(ffmpeg, [
              '-v',
              'error',
              '-i',
              output.path,
              '-map',
              '0:v:0',
              '-vf',
              'scale=64:36:flags=area,format=gray',
              '-f',
              'rawvideo',
              '-pix_fmt',
              'gray',
              '-',
            ], stdoutEncoding: null);
            expect(decoded.exitCode, 0, reason: decoded.stderr.toString());
            final pixels = decoded.stdout as Uint8List;
            const frameSize = 64 * 36;
            expect(pixels.length ~/ frameSize, 120);
            for (var frame = 0; frame < 120; frame++) {
              final timeMs = frame * 1000 / 60;
              final expected =
                  timeMs >= 123 && timeMs < 789 ||
                  timeMs >= 900 && timeMs < 1233 ||
                  timeMs >= 1450 && timeMs < 1789;
              final visible = pixels
                  .sublist(frame * frameSize, (frame + 1) * frameSize)
                  .any((pixel) => pixel > 40);
              expect(
                visible,
                expected,
                reason: 'frame $frame ($timeMs ms), hardware=$hardware',
              );
            }
            expect(InferenceProcessRegistry.instance.pids, isEmpty);
            // ignore: avoid_print
            print(
              'Native burn: hardware=$hardware, encoders=$labels, elapsed=${watch.elapsedMilliseconds} ms',
            );
          }
        } finally {
          await root.delete(recursive: true);
        }
      });
      expect(tester.takeException(), isNull);
    },
    skip:
        !enabled ||
        !(Platform.isWindows || Platform.isLinux || Platform.isMacOS),
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'VFR source timestamps survive sparse PNG overlay encoding',
    () async {
      final root = await Directory.systemTemp.createTemp('compose vfr ');
      try {
        final ffmpeg = await FFmpegUtils.ffmpegPath;
        final input = File('${root.path}/vfr.mp4');
        final generated = await Process.run(ffmpeg, [
          '-v',
          'error',
          '-y',
          '-f',
          'lavfi',
          '-i',
          'testsrc2=s=160x90:r=30:d=2',
          '-vf',
          "setpts='if(lt(N,30),N/(30*TB),(N-30)/(15*TB)+1/TB)'",
          '-fps_mode',
          'vfr',
          '-c:v',
          'libx264',
          '-threads',
          '2',
          input.path,
        ]);
        expect(generated.exitCode, 0, reason: generated.stderr.toString());
        final blank = await Process.run(ffmpeg, [
          '-v',
          'error',
          '-y',
          '-f',
          'lavfi',
          '-i',
          'color=c=black@0:s=160x90,format=rgba',
          '-frames:v',
          '1',
          '-threads',
          '1',
          '${root.path}/blank.png',
        ]);
        expect(blank.exitCode, 0, reason: blank.stderr.toString());
        final concat = File('${root.path}/subtitles.ffconcat');
        await concat.writeAsString(
          "ffconcat version 1.0\nfile 'blank.png'\noption framerate 1000\n"
          "duration 4.0\nfile 'blank.png'\noption framerate 1000\n",
        );
        final output = File('${root.path}/output.mp4');
        await VideoComposeExecutor(enableHardwareEncoding: false).execute(
          request: VideoComposeRequest(
            videoId: 'vfr',
            videoPath: input.path,
            title: 'VFR',
            renderSecondarySubtitle: false,
            continuousSubtitle: false,
            embedSoftSubtitles: false,
            softSubtitleOnly: false,
            softSubtitleUseSourceQuality: true,
            softSubtitleTracks: [],
            resolution: VideoComposeResolution.source,
            subtitleStyle: const SubtitleStyle(),
            subtitleAlignment: Alignment.bottomCenter,
            outputPath: output.path,
          ),
          filter: 'null',
          preciseSubtitleConcatPath: concat.path,
          softSubtitleInputs: [],
          duration: const Duration(seconds: 3),
          transcodeVideo: true,
          onProgress: (_) {},
        );
        Future<List<double>> timestamps(String path) async {
          final result = await Process.run(await FFmpegUtils.ffprobePath, [
            '-v',
            'error',
            '-select_streams',
            'v:0',
            '-show_frames',
            '-show_entries',
            'frame=best_effort_timestamp_time',
            '-of',
            'json',
            path,
          ]);
          expect(result.exitCode, 0);
          return ((jsonDecode(result.stdout as String) as Map)['frames']
                  as List)
              .map(
                (f) => double.parse(f['best_effort_timestamp_time'] as String),
              )
              .toList();
        }

        final before = await timestamps(input.path),
            after = await timestamps(output.path);
        expect(before, hasLength(60));
        expect(after, hasLength(before.length));
        for (var i = 0; i < before.length; i++) {
          expect(after[i], closeTo(before[i], .002), reason: 'VFR frame $i');
        }
      } finally {
        await root.delete(recursive: true);
      }
    },
    skip:
        !enabled ||
        !(Platform.isWindows || Platform.isLinux || Platform.isMacOS),
  );
}

SubtitleItem _cue(int index, int start, int end, String text) => SubtitleItem(
  index: index,
  startTime: Duration(milliseconds: start),
  endTime: Duration(milliseconds: end),
  text: text,
);
