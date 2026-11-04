import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/model_center/device_resource_snapshot.dart';
import 'package:video_player_app/features/model_center/inference_resource_governor.dart';
import 'package:video_player_app/models/ocr_subtitle_models.dart';
import 'package:video_player_app/services/ocr_frame_pipeline.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _KitBackend backend;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ocr tail test ');
    backend = _KitBackend();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_KitBackend.channel, backend.handle);
    messenger.setMockMethodCallHandler(_KitBackend.events, (_) async => null);
  });

  tearDown(() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_KitBackend.channel, null);
    messenger.setMockMethodCallHandler(_KitBackend.events, null);
    if (await root.exists()) await root.delete(recursive: true);
  });

  OcrRawExtractor extractor(InferenceResourceSession resources) =>
      OcrRawExtractor(
        resources: resources,
        cancelSignal: Completer<void>().future,
        preferSystemFfmpeg: false,
      );

  for (final platform in ['android', 'ios', 'windows', 'macos', 'linux']) {
    for (final prefetch in [false, true]) {
      test(
        '$platform policy: fractional tail terminates, prefetch=$prefetch',
        () async {
          final resources = _resources(platform, prefetch: prefetch);
          addTearDown(resources.close);
          expect(resources.decision.allowAudioPrefetch, prefetch);
          final chunks = <(Duration, Duration)>[];
          await for (final chunk in extractor(resources).chunks(_job(), root)) {
            chunks.add((chunk.start, chunk.end));
            expect(chunk.end, greaterThan(chunk.start));
            for (final frame in chunk.frames[1]!) {
              expect(
                await File(frame.path).length(),
                frame.width * frame.height * 3,
              );
            }
          }
          expect(chunks, [
            (const Duration(seconds: 650), const Duration(seconds: 655)),
            (
              const Duration(seconds: 655),
              const Duration(milliseconds: 658398),
            ),
          ]);
          expect(backend.executions, hasLength(2));
          expect(await root.list().toList(), isEmpty);
          expect(resources.activeThreads, 0);
        },
      );
    }
  }

  test(
    'a range below FFmpeg timestamp precision never launches extraction',
    () async {
      final resources = _resources('android');
      addTearDown(resources.close);
      final job = _job(
        start: const Duration(microseconds: 658398100),
        end: const Duration(microseconds: 658398567),
      );
      expect(await extractor(resources).chunks(job, root).toList(), isEmpty);
      expect(backend.executions, isEmpty);
      expect(backend.probes, 0);
    },
  );

  for (final platform in ['android', 'ios', 'windows', 'macos', 'linux']) {
    test('$platform: resume keeps the original extraction block grid', () async {
      final resources = _resources(platform);
      addTearDown(resources.close);
      final job = _job(end: const Duration(seconds: 710));
      final original = <(Duration, Duration)>[];
      await for (final chunk in extractor(resources).chunks(job, root)) {
        original.add((chunk.start, chunk.end));
      }
      final resumed = <(Duration, Duration)>[];
      await for (final chunk in extractor(resources).chunks(job, root,
          resumeFrom: original[1].$1)) {
        resumed.add((chunk.start, chunk.end));
      }
      expect(resumed, original.skip(1).toList());
      expect(resources.activeThreads, 0);
      expect(await root.list().toList(), isEmpty);
    });
  }

  test('an invalid resume boundary fails without extracting or holding resources', () async {
    final resources = _resources('android');
    addTearDown(resources.close);
    await expectLater(extractor(resources).chunks(
      _job(end: const Duration(seconds: 700)), root,
      resumeFrom: const Duration(seconds: 656),
    ).drain<void>(), throwsStateError);
    expect(backend.executions, isEmpty);
    expect(resources.activeThreads, 0);
  });

  test(
    'player duration beyond the video tail finishes with an empty chunk',
    () async {
      final resources = _resources('android');
      addTearDown(resources.close);
      final job = _job(start: const Duration(microseconds: 658220123));
      var count = 0;
      await for (final chunk in extractor(resources).chunks(job, root)) {
        count++;
        expect(chunk.frames[1], isEmpty);
      }
      expect(count, 1);
      expect(backend.executions, hasLength(1));
      expect(await root.list().toList(), isEmpty);
    },
  );

  test(
    'cleaning one extraction cannot delete another at the same timestamp',
    () async {
      final resources = _resources('android');
      addTearDown(resources.close);
      final job = _job(end: const Duration(seconds: 651));
      final first = StreamIterator(extractor(resources).chunks(job, root));
      final second = StreamIterator(extractor(resources).chunks(job, root));
      addTearDown(second.cancel);
      addTearDown(first.cancel);
      expect(await Future.wait([first.moveNext(), second.moveNext()]), [
        true,
        true,
      ]);
      expect(
        first.current.directory.path,
        isNot(second.current.directory.path),
      );
      await first.cancel();
      expect(await second.current.directory.exists(), isTrue);
      final frame = second.current.frames[1]!.single;
      expect(await File(frame.path).length(), frame.width * frame.height * 3);
      await second.cancel();
      expect(await root.list().toList(), isEmpty);
    },
  );

  test(
    'real extraction errors propagate and release temporary files and permits',
    () async {
      final resources = _resources('android');
      addTearDown(resources.close);
      backend.failure = 'Permission denied';
      await expectLater(
        extractor(resources).chunks(_job(), root).drain<void>(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Permission denied'),
          ),
        ),
      );
      expect(await root.list().toList(), isEmpty);
      expect(resources.activeThreads, 0);
    },
  );
}

OcrSubtitleJob _job({Duration? start, Duration? end}) => OcrSubtitleJob(
  videoId: 'tail',
  videoPath: 'materialized video.m4s',
  tracks: const [
    OcrSubtitleTrack(
      number: 1,
      region: NormalizedOcrRegion.subtitleDefault(),
      language: OcrSubtitleLanguage.chinese,
    ),
  ],
  start: start ?? const Duration(microseconds: 650000123),
  end: end ?? const Duration(microseconds: 658398567),
);

InferenceResourceSession _resources(String platform, {bool prefetch = true}) {
  final now = DateTime.now();
  return InferenceResourceSession(
    InferenceResourceGovernor(
      DeviceResourceSnapshot(
        platform: platform,
        processors: prefetch ? 8 : 1,
        capturedAt: now,
        memoryBytes: 12 * 1073741824,
        availableMemoryBytes: 6 * 1073741824,
        thermal: ResourceThermalState.normal,
        memoryPressure: ResourceMemoryPressure.normal,
      ),
      now: () => now,
    ),
  );
}

// Exercise FFmpegKit's actual Dart session/callback adapter on any test host.
// Only native probing/encoding is substituted; output writes use real files.
class _KitBackend {
  static const channel = MethodChannel('flutter.arthenica.com/ffmpeg_kit');
  static const events = MethodChannel('flutter.arthenica.com/ffmpeg_kit_event');
  final executions = <List<String>>[];
  final _sessions = <int, Map<String, Object?>>{};
  final _arguments = <int, List<String>>{};
  final _logs = <int, String>{};
  final _codes = <int, int>{};
  int probes = 0;
  String? failure;

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
      case 'mediaInformationSessionExecute':
      case 'cancel':
        return null;
      case 'mediaInformationSession':
      case 'ffmpegSession':
        final nextId = _sessions.length + 1;
        _arguments[nextId] = List<String>.from(args['arguments']! as List);
        return _sessions[nextId] = {
          'sessionId': nextId,
          'type': call.method == 'ffmpegSession' ? 1 : 3,
          'command': '',
        };
      case 'getMediaInformation':
        probes++;
        return {
          'format': {'duration': '658.220'},
          'streams': [
            {'codec_type': 'video', 'width': 1920, 'height': 1080},
          ],
        };
      case 'getSession':
        return _sessions[id];
      case 'abstractSessionGetReturnCode':
        return _codes[id];
      case 'abstractSessionGetAllLogsAsString':
        return _logs[id] ?? '';
      case 'asyncFFmpegSessionExecute':
        final command = _arguments[id]!;
        executions.add(command);
        try {
          if (failure != null) throw StateError(failure!);
          final duration = double.parse(command[command.indexOf('-t') + 1]);
          if (duration <= 0) throw StateError('zero-duration extraction');
          final start = double.parse(command[command.indexOf('-ss') + 1]);
          final logs = StringBuffer();
          for (var i = 0; i + 2 < command.length; i++) {
            if (command[i] != '-f' || command[i + 1] != 'rawvideo') continue;
            final file = File(command[i + 2]);
            final track = RegExp(
              r'track_(\d+)',
            ).firstMatch(p.basename(file.path))![1];
            final hasFrame = start < 658.220;
            await file.writeAsBytes(
              hasFrame ? List.filled(8 * 4 * 3, 127) : [],
            );
            if (hasFrame) {
              logs.writeln(
                '[showinfo@ocr_$track @ test] n: 0 pts: 0 pts_time:0 fmt:rgb24 s:8x4',
              );
            }
          }
          _logs[id!] = logs.toString();
          _codes[id] = 0;
        } catch (error) {
          _logs[id!] = error.toString();
          _codes[id] = 1;
        }
        ServicesBinding.instance.channelBuffers.push(
          events.name,
          const StandardMethodCodec().encodeSuccessEnvelope({
            'FFmpegKitCompleteCallbackEvent': {'sessionId': id},
          }),
          (_) {},
        );
        return null;
      default:
        throw MissingPluginException(call.method);
    }
  }
}
