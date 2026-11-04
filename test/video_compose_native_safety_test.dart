import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/model_center/device_resource_snapshot.dart';
import 'package:video_player_app/features/model_center/inference_resource_governor.dart';
import 'package:video_player_app/features/model_center/inference_scheduler.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/models/video_compose_models.dart';
import 'package:video_player_app/services/video_compose/video_compose_ass_renderer.dart';
import 'package:video_player_app/services/video_compose/video_compose_executor.dart';
import 'package:video_player_app/services/video_compose/video_compose_font_service.dart';
import 'package:video_player_app/services/video_compose/video_compose_orchestrator.dart';
import 'package:video_player_app/services/video_compose/video_compose_output_path_service.dart';
import 'package:video_player_app/services/video_compose/video_compose_precise_renderer.dart';
import 'package:video_player_app/services/video_compose/video_compose_probe_service.dart';
import 'package:video_player_app/services/video_compose/video_compose_subtitle_service.dart';
import 'package:video_player_app/utils/ffmpeg_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const fixture = String.fromEnvironment('VIDEO_COMPOSE_NATIVE_FIXTURE');
  test(
    'Windows queued compose executes real FFmpeg and releases resources',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'compose native safety ',
      );
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(paths, (call) async {
        if (call.method == 'getTemporaryDirectory') return root.path;
        throw MissingPluginException(call.method);
      });
      addTearDown(() => messenger.setMockMethodCallHandler(paths, null));
      final scheduler = InferenceScheduler(
        openResources: () async => InferenceResourceSession(
          InferenceResourceGovernor(
            DeviceResourceSnapshot(
              platform: 'windows',
              processors: 8,
              capturedAt: DateTime.now(),
              memoryBytes: 16 * 1073741824,
              availableMemoryBytes: 8 * 1073741824,
            ),
          ),
        ),
      );
      final releaseOwner = await scheduler.acquire();
      try {
        final subtitle = File('${root.path}/input.srt');
        await subtitle.writeAsString(
          '1\n00:00:00,000 --> 00:00:02,000\nNative compose safety\n\n',
        );
        final output = File('${root.path}/output.mp4');
        final fonts = VideoComposeFontService();
        final orchestrator = VideoComposeOrchestrator(
          probeService: const VideoComposeProbeService(),
          subtitleService: const VideoComposeSubtitleService(),
          assRenderer: VideoComposeAssRenderer(fonts),
          fontService: fonts,
          preciseRenderer: VideoComposePreciseRenderer(),
          executor: VideoComposeExecutor(),
          outputPathService: const VideoComposeOutputPathService(),
          scheduler: scheduler,
        );
        final running = orchestrator.run(
          taskId: 'real-compose',
          request: VideoComposeRequest(
            videoId: 'native',
            videoPath: fixture,
            title: 'Native compose',
            renderSecondarySubtitle: false,
            continuousSubtitle: false,
            embedSoftSubtitles: true,
            softSubtitleOnly: true,
            softSubtitleUseSourceQuality: true,
            softSubtitleTracks: [
              VideoComposeSoftSubtitleTrack(path: subtitle.path, title: 'Test'),
            ],
            resolution: VideoComposeResolution.source,
            subtitleStyle: const SubtitleStyle(),
            subtitleAlignment: Alignment.bottomCenter,
            outputPath: output.path,
          ),
          onArtifact: (_) {},
          onStatus: ({stage, progress, message, error}) {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(await output.exists(), isFalse);
        expect(scheduler.busy, isTrue);
        releaseOwner();
        await running;
        expect(await output.length(), greaterThan(1024));
        final probe = await Process.run(await FFmpegUtils.ffprobePath, [
          '-v',
          'error',
          '-show_entries',
          'stream=codec_type,codec_name',
          '-of',
          'json',
          output.path,
        ]);
        expect(probe.exitCode, 0, reason: '${probe.stderr}');
        final streams =
            (jsonDecode(probe.stdout as String) as Map)['streams'] as List;
        expect(
          streams.any((stream) => stream['codec_type'] == 'video'),
          isTrue,
        );
        expect(
          streams.any((stream) => stream['codec_name'] == 'mov_text'),
          isTrue,
        );
        expect(scheduler.busy, isFalse);
        expect(InferenceProcessRegistry.instance.pids, isEmpty);
      } finally {
        releaseOwner();
        await root.delete(recursive: true);
      }
    },
    skip: fixture.isEmpty || !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
