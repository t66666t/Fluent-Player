import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:video_player_app/platform/pitch_preserving_audio_pipeline.dart';

void main() {
  test('native pause never keeps a silent device stream alive', () {
    for (final platform in ['android', 'ios', 'macos', 'windows', 'linux']) {
      final options = PitchPreservingAudioPipeline.pauseOptionsFor(platform);
      expect(options['audio-stream-silence'], 'no', reason: platform);
      expect(options.containsKey('opensles-buffer-size-in-ms'), isFalse);
    }
  });

  test(
    'Windows shared texture rendering does not wait ahead under its mutex',
    () {
      expect(PitchPreservingAudioPipeline.videoTimingOffsetFor('windows'), 0.0);
      for (final platform in ['android', 'ios', 'macos', 'linux']) {
        expect(
          PitchPreservingAudioPipeline.videoTimingOffsetFor(platform),
          0.05,
        );
      }
    },
  );

  final runNativeTest =
      Platform.environment['RUN_NATIVE_MEDIA_KIT_TESTS'] == '1';
  final nativeTestSkip = runNativeTest
      ? false
      : 'Set RUN_NATIVE_MEDIA_KIT_TESTS=1 with libmpv on PATH.';

  test(
    'native speed crossover keeps one neutral-pitch WSOLA filter',
    () async {
      if (!(Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isLinux ||
          Platform.isMacOS ||
          Platform.isWindows)) {
        return;
      }

      final tempDirectory = await Directory.systemTemp.createTemp(
        'pitch_preserving_audio_test_',
      );
      final audio = await _writeToneWav(tempDirectory);
      addTearDown(() => tempDirectory.delete(recursive: true));

      MediaKit.ensureInitialized();
      final player = Player(
        configuration: const PlayerConfiguration(
          vo: 'null',
          osc: false,
          libass: false,
          pitch: false,
        ),
      );
      var playerDisposed = false;
      addTearDown(() async {
        if (!playerDisposed) await player.dispose();
      });

      final platform = player.platform;
      expect(platform, isA<NativePlayer>());
      final nativePlayer = platform! as NativePlayer;
      final capturedAudio = File(
        '${tempDirectory.path}${Platform.pathSeparator}captured.wav',
      );
      await nativePlayer.setProperty('ao', 'pcm');
      await nativePlayer.setProperty('ao-pcm-file', capturedAudio.path);
      await nativePlayer.setProperty('audio-format', 's16');
      await nativePlayer.setProperty('audio-samplerate', '48000');
      await nativePlayer.setProperty('audio-channels', 'mono');

      await PitchPreservingAudioPipeline.configure(player);
      expect(await nativePlayer.getProperty('audio-stream-silence'), 'no');
      await player.open(Media(audio.path), play: false);

      final filterAtNormalSpeed = await nativePlayer.getProperty('af');
      final audioBuffer = double.parse(
        await nativePlayer.getProperty('audio-buffer'),
      );
      expect(
        audioBuffer,
        closeTo(
          PitchPreservingAudioPipeline.responsiveAudioBufferSeconds,
          0.005,
        ),
      );
      expect(filterAtNormalSpeed, contains('scaletempo2'));
      expect(await nativePlayer.getProperty('video-sync'), 'audio');
      expect(
        int.parse(await nativePlayer.getProperty('autosync')),
        PitchPreservingAudioPipeline.avClockSmoothing,
      );
      expect(
        double.parse(await nativePlayer.getProperty('video-timing-offset')),
        closeTo(PitchPreservingAudioPipeline.videoTimingOffsetSeconds, 0.005),
      );
      expect(await nativePlayer.getProperty('framedrop'), 'vo');
      expect(player.state.pitch, 1.0);

      await player.setRate(2.0);
      expect(player.state.pitch, 1.0);
      expect(await nativePlayer.getProperty('af'), filterAtNormalSpeed);

      await player.setRate(1.0);
      expect(player.state.pitch, 1.0);
      expect(await nativePlayer.getProperty('af'), filterAtNormalSpeed);

      await player.setRate(2.0);
      await player.play();
      await player.stream.completed
          .firstWhere((completed) => completed)
          .timeout(const Duration(seconds: 5));
      await player.dispose();
      playerDisposed = true;

      expect(await capturedAudio.exists(), isTrue);
      final capturedPitch = await _estimateWavePitch(capturedAudio);
      expect(capturedPitch, closeTo(440, 35));
    },
    skip: nativeTestSkip,
  );

  test(
    'live 1x-2x-1x crossover does not rebuild the native audio graph',
    () async {
      if (!(Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isLinux ||
          Platform.isMacOS ||
          Platform.isWindows)) {
        return;
      }

      final tempDirectory = await Directory.systemTemp.createTemp(
        'live_rate_crossover_test_',
      );
      final audio = await _writeToneWav(tempDirectory, seconds: 3);
      addTearDown(() => tempDirectory.delete(recursive: true));

      MediaKit.ensureInitialized();
      final player = Player(
        configuration: const PlayerConfiguration(
          vo: 'null',
          osc: false,
          libass: false,
          pitch: false,
          logLevel: MPVLogLevel.v,
        ),
      );
      var playerDisposed = false;
      addTearDown(() async {
        if (!playerDisposed) await player.dispose();
      });

      final platform = player.platform;
      expect(platform, isA<NativePlayer>());
      final nativePlayer = platform! as NativePlayer;
      await PitchPreservingAudioPipeline.configure(player);
      await nativePlayer.setProperty('ao', 'null');
      await nativePlayer.setProperty('ao-null-untimed', 'no');
      await player.open(Media(audio.path), play: false);

      final filter = await nativePlayer.getProperty('af');
      final boundaryLogs = <PlayerLog>[];
      final logSubscription = player.stream.log.listen(boundaryLogs.add);
      addTearDown(logSubscription.cancel);

      await player.play();
      await player.stream.position
          .firstWhere(
            (position) => position >= const Duration(milliseconds: 300),
          )
          .timeout(const Duration(seconds: 3));
      boundaryLogs.clear();

      await player.setRate(2.0);
      expect(player.state.pitch, 1.0);
      expect(await nativePlayer.getProperty('af'), filter);
      await player.stream.position
          .firstWhere(
            (position) => position >= const Duration(milliseconds: 900),
          )
          .timeout(const Duration(seconds: 3));

      await player.setRate(1.0);
      expect(player.state.pitch, 1.0);
      expect(await nativePlayer.getProperty('af'), filter);
      await player.stream.position
          .firstWhere(
            (position) => position >= const Duration(milliseconds: 1200),
          )
          .timeout(const Duration(seconds: 3));

      final logText = boundaryLogs
          .map((log) => '${log.prefix} ${log.text}'.toLowerCase())
          .join('\n');
      expect(logText, isNot(contains('adding scaletempo2')));
      expect(logText, isNot(contains('reinitializing resampler')));

      await player.dispose();
      playerDisposed = true;
    },
    skip: nativeTestSkip,
  );
}

Future<File> _writeToneWav(Directory directory, {int seconds = 1}) async {
  const sampleRate = 48000;
  final sampleCount = sampleRate * seconds;
  const bytesPerSample = 2;
  final dataSize = sampleCount * bytesPerSample;
  final bytes = ByteData(44 + dataSize);

  void writeAscii(int offset, String value) {
    for (var index = 0; index < value.length; index++) {
      bytes.setUint8(offset + index, value.codeUnitAt(index));
    }
  }

  writeAscii(0, 'RIFF');
  bytes.setUint32(4, 36 + dataSize, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * bytesPerSample, Endian.little);
  bytes.setUint16(32, bytesPerSample, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  writeAscii(36, 'data');
  bytes.setUint32(40, dataSize, Endian.little);

  for (var sample = 0; sample < sampleCount; sample++) {
    final value = (math.sin(2 * math.pi * 440 * sample / sampleRate) * 12000)
        .round();
    bytes.setInt16(44 + sample * bytesPerSample, value, Endian.little);
  }

  final file = File(
    '${directory.path}${Platform.pathSeparator}neutral_pitch.wav',
  );
  await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
  return file;
}

Future<double> _estimateWavePitch(File file) async {
  final data = ByteData.sublistView(
    Uint8List.fromList(await file.readAsBytes()),
  );
  final sampleRate = data.getUint32(24, Endian.little);
  final bitsPerSample = data.getUint16(34, Endian.little);
  expect(bitsPerSample, 16);

  var dataOffset = 12;
  var dataLength = 0;
  while (dataOffset + 8 <= data.lengthInBytes) {
    final chunkId = String.fromCharCodes(<int>[
      for (var index = 0; index < 4; index++) data.getUint8(dataOffset + index),
    ]);
    final chunkLength = data.getUint32(dataOffset + 4, Endian.little);
    if (chunkId == 'data') {
      dataOffset += 8;
      dataLength = chunkLength;
      break;
    }
    dataOffset += 8 + chunkLength + (chunkLength.isOdd ? 1 : 0);
  }
  expect(dataLength, greaterThan(sampleRate ~/ 5));

  final sampleCount = dataLength ~/ 2;
  final startSample = (sampleCount * 0.2).round();
  final endSample = (sampleCount * 0.8).round();
  var positiveCrossings = 0;
  var previous = data.getInt16(dataOffset + startSample * 2, Endian.little);
  for (var sample = startSample + 1; sample < endSample; sample++) {
    final current = data.getInt16(dataOffset + sample * 2, Endian.little);
    if (previous <= 0 && current > 0) positiveCrossings++;
    previous = current;
  }
  final measuredSeconds = (endSample - startSample) / sampleRate;
  return positiveCrossings / measuredSeconds;
}
