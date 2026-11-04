import 'dart:async';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'cancelling mobile compose never cancels another FFmpeg/OCR session',
    () async {
      final backend = _KitBackend();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(_KitBackend.channel, backend.handle);
      messenger.setMockMethodCallHandler(_KitBackend.events, (_) async => null);
      addTearDown(() {
        messenger.setMockMethodCallHandler(_KitBackend.channel, null);
        messenger.setMockMethodCallHandler(_KitBackend.events, null);
      });
      final otherDone = Completer<void>();
      final other = await FFmpegKit.executeWithArgumentsAsync([
        'ocr-extraction',
      ], (_) => otherDone.complete());
      final started = Completer<int>();
      backend.onExecuted = started.complete;
      final executor = VideoComposeExecutor(
        preferSystemFfmpeg: false,
        enableHardwareEncoding: false,
      );
      final running = executor.execute(
        request: _request(),
        filter: '',
        softSubtitleInputs: const [],
        duration: const Duration(seconds: 3),
        transcodeVideo: true,
        onProgress: (_) {},
      );
      final assertion = expectLater(running, throwsStateError);
      final composeId = await started.future;
      final command = backend.commands[composeId]!;
      expect(
        command,
        containsAll(['-filter_threads', '-filter_complex_threads', '-threads']),
      );
      expect(
        int.parse(command[command.indexOf('-i') - 1]),
        inInclusiveRange(1, 3),
      );
      await executor.cancel();
      await assertion;
      expect(backend.cancelled, [composeId]);
      expect(backend.cancelled, isNot(contains(other.getSessionId())));
      expect(otherDone.isCompleted, isFalse);
      backend.finish(other.getSessionId()!, 0);
      await otherDone.future;
    },
  );

  for (final platform in ['windows', 'android', 'linux', 'macos', 'ios']) {
    test(
      '$platform: queued compose cancellation preserves the active AI owner',
      () async {
        var resourceOpens = 0;
        final scheduler = InferenceScheduler(
          openResources: () async {
            resourceOpens++;
            return InferenceResourceSession(
              InferenceResourceGovernor(
                DeviceResourceSnapshot(
                  platform: platform,
                  processors: 8,
                  capturedAt: DateTime.now(),
                  memoryBytes: 12 * 1073741824,
                  availableMemoryBytes: 6 * 1073741824,
                ),
              ),
            );
          },
        );
        final owner = await scheduler.acquire();
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
        final queued = orchestrator.run(
          taskId: 'queued',
          request: _request(),
          onArtifact: (_) {},
          onStatus: ({stage, progress, message, error}) {},
        );
        final assertion = expectLater(queued, throwsStateError);
        await orchestrator.cancelRunningCompose();
        await assertion;
        expect(scheduler.busy, isTrue);
        expect(resourceOpens, 0);
        owner();
        expect(scheduler.busy, isFalse);
        // A cancelled attempt must not leave the orchestrator permanently busy.
        await expectLater(
          orchestrator.run(
            taskId: 'again',
            request: _request(),
            onArtifact: (_) {},
            onStatus: ({stage, progress, message, error}) {},
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              '视频文件不存在',
            ),
          ),
        );
        expect(resourceOpens, 1);
        expect(scheduler.busy, isFalse);
      },
    );
  }
}

VideoComposeRequest _request() => const VideoComposeRequest(
  videoId: 'compose',
  videoPath: 'missing-compose-safety-input.mp4',
  title: 'test',
  renderSecondarySubtitle: false,
  continuousSubtitle: false,
  embedSoftSubtitles: false,
  softSubtitleOnly: true,
  softSubtitleUseSourceQuality: true,
  softSubtitleTracks: [],
  resolution: VideoComposeResolution.source,
  subtitleStyle: SubtitleStyle(),
  subtitleAlignment: Alignment.bottomCenter,
  outputPath: 'unused-compose-safety-output.mp4',
);

class _KitBackend {
  static const channel = MethodChannel('flutter.arthenica.com/ffmpeg_kit');
  static const events = MethodChannel('flutter.arthenica.com/ffmpeg_kit_event');
  final commands = <int, List<String>>{};
  final cancelled = <int?>[];
  final _codes = <int, int>{};
  void Function(int)? onExecuted;

  void finish(int id, int code) {
    _codes[id] = code;
    ServicesBinding.instance.channelBuffers.push(
      events.name,
      const StandardMethodCodec().encodeSuccessEnvelope({
        'FFmpegKitCompleteCallbackEvent': {'sessionId': id},
      }),
      (_) {},
    );
  }

  Future<Object?> handle(MethodCall call) async {
    final args = Map<Object?, Object?>.from(call.arguments as Map? ?? const {});
    final id = args['sessionId'] as int?;
    switch (call.method) {
      case 'getLogLevel':
        return 32;
      case 'getPlatform':
      case 'getArch':
        return 'test';
      case 'getPackageName':
        return 'full-gpl';
      case 'isLTSBuild':
        return false;
      case 'setLogLevel':
      case 'enableRedirection':
        return null;
      case 'ffmpegSession':
        final next = commands.length + 1;
        commands[next] = List<String>.from(args['arguments']! as List);
        return {'sessionId': next, 'type': 1, 'command': ''};
      case 'getSession':
        return {'sessionId': id, 'type': 1, 'command': ''};
      case 'asyncFFmpegSessionExecute':
        onExecuted?.call(id!);
        return null;
      case 'abstractSessionGetReturnCode':
        return _codes[id];
      case 'abstractSessionGetAllLogsAsString':
        return 'Cancelled by user';
      case 'cancel':
      case 'cancelSession':
        cancelled.add(id);
        if (id != null) finish(id, 255);
        return null;
      default:
        throw MissingPluginException(call.method);
    }
  }
}
