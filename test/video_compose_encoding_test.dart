import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/models/video_compose_models.dart';
import 'package:video_player_app/services/video_compose/video_compose_encoding.dart';
import 'package:video_player_app/services/video_compose/video_compose_executor.dart';
import 'package:video_player_app/services/video_compose/video_compose_types.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('discovery accepts FFmpeg encoder flags and excludes audio', () {
    expect(
      VideoComposeEncoding.parseEncoders('''
 V....D h264_nvenc NVIDIA
 V..... h264_qsv Intel
 VF...D png PNG
 A....D aac audio
'''),
      {'h264_nvenc', 'h264_qsv', 'png'},
    );
  });
  for (final entry in {
    'windows': ['h264_nvenc', 'h264_qsv', 'h264_amf', 'h264_mf', 'libx264'],
    'linux': ['h264_nvenc', 'h264_qsv', 'h264_amf', 'h264_vaapi', 'libx264'],
    'android': ['h264_mediacodec', 'libx264'],
    'ios': ['h264_videotoolbox', 'libx264'],
    'macos': ['h264_videotoolbox', 'libx264'],
  }.entries) {
    test('${entry.key} selects compatible codecs with CPU fallback', () {
      final plans = VideoComposeEncoding.candidates(
        platform: entry.key,
        available: {
          'h264_nvenc',
          'h264_qsv',
          'h264_amf',
          'h264_mf',
          'h264_vaapi',
          'h264_mediacodec',
          'h264_videotoolbox',
        },
        vaapiDevices: ['/dev/dri/renderD128'],
      );
      expect(plans.map((plan) => plan.codec), entry.value);
      expect(
        VideoComposeEncoding.candidates(
          platform: entry.key,
          available: {},
        ).map((plan) => plan.codec),
        ['libx264'],
      );
    });
  }
  test('VAAPI requires a device and uploads the final overlay', () {
    expect(
      VideoComposeEncoding.candidates(
        platform: 'linux',
        available: {'h264_vaapi'},
      ).map((plan) => plan.codec),
      ['libx264'],
    );
    final args = buildVideoComposeArguments(
      request: _request('out.mp4'),
      outputPath: 'stage.mp4',
      filter: 'scale=1280:720',
      preciseSubtitleConcatPath: 'scene.ffconcat',
      softSubtitleInputs: const [
        ComposeSubtitleInput(path: 'soft.srt', title: '中文', language: 'chi'),
      ],
      transcodeVideo: true,
      encoding: const VideoComposeEncoding(
        'h264_vaapi',
        device: '/dev/dri/renderD128',
      ),
      threadBudget: 8,
    );
    expect(args, containsAllInOrder(['-vaapi_device', '/dev/dri/renderD128']));
    expect(
      args[args.indexOf('-filter_complex') + 1],
      contains('format=nv12,hwupload[outv]'),
    );
    expect(
      args,
      containsAllInOrder(['-map', '[outv]', '-map', '0:a?', '-map', '2:0']),
    );
    expect(args, isNot(contains('-hwaccel')));
  });
  test(
    'CPU encoding splits a bounded budget across decode, filters and encode',
    () {
      final args = buildVideoComposeArguments(
        request: _request('out.mp4'),
        outputPath: 'stage.mp4',
        filter: 'scale=1280:720',
        softSubtitleInputs: const [],
        transcodeVideo: true,
        encoding: const VideoComposeEncoding('libx264'),
        threadBudget: 12,
      );
      final decode = int.parse(args[args.indexOf('-threads') + 1]);
      final filters = int.parse(
        args[args.indexOf('-filter_complex_threads') + 1],
      );
      final encode = int.parse(args[args.indexOf('-threads:v') + 1]);
      expect(decode + filters + encode, lessThanOrEqualTo(12));
      expect(encode, greaterThan(1));
      expect(decode, greaterThan(0));
      expect(filters, greaterThan(0));
      expect(args, containsAllInOrder(['-crf', '20', '-pix_fmt', 'yuv420p']));
      expect(args, containsAllInOrder(['-map', '0:V:0', '-map', '0:a?']));
    },
  );
  for (final platform in ['windows', 'linux', 'android', 'ios', 'macos']) {
    test(
      '$platform retries driver failures without touching old output',
      () async {
        final root = await Directory.systemTemp.createTemp('compose fallback ');
        addTearDown(() => root.delete(recursive: true));
        final output = File('${root.path}/existing.mp4');
        await output.writeAsString('previous complete output');
        final codecs = <String>[], paths = <String>[], labels = <String>[];
        final artifacts = <String>[];
        final progress = <double>[];
        final executor = VideoComposeExecutor(
          platform: platform,
          loadEncoders: () async => {
            'h264_nvenc',
            'h264_qsv',
            'h264_amf',
            'h264_mf',
            'h264_mediacodec',
            'h264_videotoolbox',
          },
          commandRunner: (args, onLine) async {
            final codec = args[args.indexOf('-c:v') + 1];
            codecs.add(codec);
            paths.add(args.last);
            expect(await output.readAsString(), 'previous complete output');
            await File(args.last).writeAsBytes(List.filled(2048, 42));
            onLine('out_time_us=1000000');
            if (codec != 'libx264') {
              throw StateError(
                'Permission denied while opening GPU device ($codec)',
              );
            }
          },
        );
        await executor.execute(
          request: _request(output.path),
          filter: 'scale=640:360',
          softSubtitleInputs: [],
          duration: const Duration(seconds: 2),
          transcodeVideo: true,
          onProgress: progress.add,
          onEncoderChanged: labels.add,
          onArtifact: artifacts.add,
        );
        expect(codecs.last, 'libx264');
        expect(codecs.length, greaterThan(1));
        expect(paths.toSet(), hasLength(1));
        expect(progress, orderedEquals([...progress]..sort()));
        expect(labels.last, 'CPU x264');
        expect(await output.length(), 2048);
        expect(await root.list().length, 1);
        expect(artifacts, hasLength(1));
        expect(await Directory(artifacts.single).exists(), isFalse);
      },
    );
  }
  test(
    'MP4-incompatible audio retries AAC with the same video encoder',
    () async {
      final root = await Directory.systemTemp.createTemp('compose audio ');
      addTearDown(() => root.delete(recursive: true));
      final commands = <List<String>>[];
      final executor = VideoComposeExecutor(
        enableHardwareEncoding: false,
        commandRunner: (args, _) async {
          commands.add(args);
          if (args[args.indexOf('-c:a') + 1] == 'copy') {
            throw StateError(
              'Could not find tag for codec pcm_s16le in stream #1, codec not currently supported in container',
            );
          }
          await File(args.last).writeAsBytes(List.filled(2048, 3));
        },
      );
      await executor.execute(
        request: _request('${root.path}/out.mp4'),
        filter: '',
        softSubtitleInputs: [],
        duration: const Duration(seconds: 1),
        transcodeVideo: false,
        onProgress: (_) {},
      );
      expect(commands, hasLength(2));
      expect(
        commands.last,
        containsAllInOrder(['-c:v', 'copy', '-c:a', 'aac']),
      );
    },
  );
  test(
    'cancel during discovery never starts rendering or publishes output',
    () async {
      final root = await Directory.systemTemp.createTemp('compose cancel ');
      addTearDown(() => root.delete(recursive: true));
      final started = Completer<void>(), release = Completer<Set<String>>();
      var rendered = false;
      final executor = VideoComposeExecutor(
        loadEncoders: () {
          started.complete();
          return release.future;
        },
        commandRunner: (_, _) async {
          rendered = true;
        },
      );
      final running = executor.execute(
        request: _request('${root.path}/out.mp4'),
        filter: '',
        softSubtitleInputs: [],
        duration: Duration.zero,
        transcodeVideo: true,
        onProgress: (_) {},
      );
      final assertion = expectLater(running, throwsStateError);
      await started.future;
      final cancellation = executor.cancel();
      release.complete({'h264_nvenc'});
      await cancellation;
      await assertion;
      expect(rendered, isFalse);
      expect(await root.list().length, 0);
    },
  );
  test('output IO errors preserve old output and do not re-encode', () async {
    final root = await Directory.systemTemp.createTemp('compose io ');
    addTearDown(() => root.delete(recursive: true));
    final output = File('${root.path}/out.mp4');
    await output.writeAsString('keep');
    var attempts = 0;
    final executor = VideoComposeExecutor(
      platform: 'windows',
      loadEncoders: () async => {'h264_nvenc'},
      commandRunner: (_, _) async {
        attempts++;
        throw StateError('No space left on device');
      },
    );
    await expectLater(
      executor.execute(
        request: _request(output.path),
        filter: '',
        softSubtitleInputs: [],
        duration: Duration.zero,
        transcodeVideo: true,
        onProgress: (_) {},
      ),
      throwsStateError,
    );
    expect(attempts, 1);
    expect(await output.readAsString(), 'keep');
    expect(await root.list().length, 1);
  });
  test('older FFmpeg retries VFR with the legacy frame sync option', () async {
    final root = await Directory.systemTemp.createTemp('compose legacy sync ');
    addTearDown(() => root.delete(recursive: true));
    final commands = <List<String>>[];
    final executor = VideoComposeExecutor(
      enableHardwareEncoding: false,
      commandRunner: (args, _) async {
        commands.add(args);
        if (args.contains('-fps_mode')) {
          throw StateError("Unrecognized option 'fps_mode'. Option not found");
        }
        await File(args.last).writeAsBytes(List.filled(2048, 3));
      },
    );
    await executor.execute(
      request: _request('${root.path}/out.mp4'),
      filter: '',
      softSubtitleInputs: [],
      duration: const Duration(seconds: 1),
      transcodeVideo: true,
      onProgress: (_) {},
    );
    expect(commands, hasLength(2));
    expect(commands.last, containsAllInOrder(['-vsync', 'vfr']));
    expect(commands.last, isNot(contains('-fps_mode')));
  });
  test(
    'publishing retries a short Windows reader lock without another encode',
    () async {
      final root = await Directory.systemTemp.createTemp('compose publish ');
      Process? locker;
      addTearDown(() async {
        locker?.kill();
        await locker?.exitCode;
        await root.delete(recursive: true);
      });
      final output = File('${root.path}/existing.mp4');
      await output.writeAsString('keep until publication');
      var attempts = 0;
      final executor = VideoComposeExecutor(
        enableHardwareEncoding: false,
        commandRunner: (args, _) async {
          attempts++;
          await File(args.last).writeAsBytes(List.filled(2048, 42));
          locker = await Process.start(
            'powershell.exe',
            [
              '-NoProfile',
              '-NonInteractive',
              '-Command',
              r'''
$stream = [System.IO.File]::Open($env:COMPOSE_PUBLISH_LOCK_PATH,
  [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
  [System.IO.FileShare]::ReadWrite)
[Console]::WriteLine('locked')
Start-Sleep -Milliseconds 350
$stream.Dispose()
''',
            ],
            environment: {'COMPOSE_PUBLISH_LOCK_PATH': output.path},
          );
          locker!.stderr.drain<void>();
          expect(
            await locker!.stdout
                .transform(utf8.decoder)
                .transform(const LineSplitter())
                .first,
            'locked',
          );
        },
      );
      await executor.execute(
        request: _request(output.path),
        filter: '',
        softSubtitleInputs: [],
        duration: Duration.zero,
        transcodeVideo: true,
        onProgress: (_) {},
      );
      expect(attempts, 1);
      expect(await output.length(), 2048);
      expect(await root.list().length, 1);
    },
    skip: !Platform.isWindows,
  );

  test('output cannot overwrite the source video', () async {
    final root = await Directory.systemTemp.createTemp('compose same source ');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}/source.mp4');
    await source.writeAsString('original video');
    var encoded = false;
    await expectLater(
      VideoComposeExecutor(
        enableHardwareEncoding: false,
        commandRunner: (_, _) async {
          encoded = true;
        },
      ).execute(
        request: _request(source.path).copyWith(videoPath: source.path),
        filter: '',
        softSubtitleInputs: [],
        duration: Duration.zero,
        transcodeVideo: true,
        onProgress: (_) {},
      ),
      throwsStateError,
    );
    expect(encoded, isFalse);
    expect(await source.readAsString(), 'original video');
  });
}

VideoComposeRequest _request(String path) => VideoComposeRequest(
  videoId: 'test',
  videoPath: 'source with 空格.mp4',
  title: 'test',
  renderSecondarySubtitle: false,
  continuousSubtitle: false,
  embedSoftSubtitles: false,
  softSubtitleOnly: false,
  softSubtitleUseSourceQuality: true,
  softSubtitleTracks: [],
  resolution: VideoComposeResolution.source,
  subtitleStyle: const SubtitleStyle(),
  subtitleAlignment: Alignment.bottomCenter,
  outputPath: path,
);
