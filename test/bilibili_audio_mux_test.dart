import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_audio_selection.dart';
import 'package:video_player_app/services/bilibili/download_manager.dart';
import 'package:video_player_app/utils/ffmpeg_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File video;
  late String ffmpeg;
  late String ffprobe;
  final reports = <Map<String, Object?>>[];

  Future<void> run(List<String> args) async {
    final result = await Process.run(ffmpeg, ['-v', 'error', '-y', ...args]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  }

  Future<Map<String, dynamic>> probe(File file) async {
    final result = await Process.run(ffprobe, [
      '-v',
      'error',
      '-select_streams',
      'a:0',
      '-show_streams',
      '-of',
      'json',
      file.path,
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return Map<String, dynamic>.from(
      (jsonDecode(result.stdout as String)['streams'] as List).single,
    );
  }

  Future<List<String>> packetHashes(File file) async {
    final result = await Process.run(ffprobe, [
      '-v',
      'error',
      '-select_streams',
      'a:0',
      '-show_packets',
      '-show_entries',
      'packet=data_hash',
      '-show_data_hash',
      'sha256',
      '-of',
      'json',
      file.path,
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return [
      for (final packet in jsonDecode(result.stdout as String)['packets'])
        packet['data_hash'] as String,
    ];
  }

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('bilibili-special-mux-');
    ffmpeg = await FFmpegUtils.ffmpegPath;
    ffprobe = await FFmpegUtils.ffprobePath;
    video = File('${root.path}/video-with-aac.mp4');
    // A competing embedded AAC track catches accidental FFmpeg auto-selection.
    await run([
      '-f',
      'lavfi',
      '-i',
      'testsrc2=s=160x90:r=10',
      '-f',
      'lavfi',
      '-i',
      'anullsrc=r=48000:cl=5.1',
      '-t',
      '3',
      '-c:v',
      'libx264',
      '-pix_fmt',
      'yuv420p',
      '-c:a',
      'aac',
      video.path,
    ]);
  });
  tearDownAll(() async {
    final reportPath = Platform.environment['BILIBILI_AUDIO_MUX_REPORT'];
    if (reportPath != null) {
      await File(
        reportPath,
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(reports));
    }
    await root.delete(recursive: true);
  });

  for (final (id, codec, rate, channels) in [
    (30251, 'flac', 96000, 2),
    (30250, 'eac3', 48000, 6),
  ]) {
    for (final live in [false, true]) {
      final liveRoot = Platform.environment['BILIBILI_SPECIAL_AUDIO_SAMPLES'];
      test(
        'download manager preserves ${live ? 'reference video' : 'generated'} $codec packets, rate and channels',
        () async {
          final audio = File('${root.path}/$id-$live.mp4');
          if (live) {
            final sample = id == 30251
                ? 'BV1gHjGzyE5Z-flac.m4a'
                : 'BV1kX4y197P4-dolby.m4a';
            await run([
              '-i',
              '$liveRoot/$sample',
              '-t',
              '3',
              '-map',
              '0:a:0',
              '-c:a',
              'copy',
              '-strict',
              'experimental',
              audio.path,
            ]);
          } else {
            await run([
              '-f',
              'lavfi',
              '-i',
              'anoisesrc=color=pink:sample_rate=$rate:duration=3',
              '-ac',
              '$channels',
              '-c:a',
              codec,
              if (codec == 'flac') ...[
                '-sample_fmt',
                's32',
                '-bits_per_raw_sample',
                '24',
              ],
              '-strict',
              'experimental',
              audio.path,
            ]);
          }
          final audioTrack = StreamItem(
            id: id,
            baseUrl: 'https://upos-test.bilivideo.com/$id',
            bandwidth: 1000000,
            codecs: codec == 'flac' ? 'fLaC' : 'ec-3',
            codecid: 0,
          );
          final videoTrack = StreamItem(
            id: 16,
            baseUrl: 'https://upos-test.bilivideo.com/video',
            bandwidth: 100000,
            codecs: 'avc1.640028',
            codecid: 7,
          );
          final manager = BilibiliDownloadManager(BilibiliApiService());
          final output = File(
            await manager.downloadAndMerge(
              videoStream: videoTrack,
              audioStream: audioTrack,
              fileName: 'special-audio',
              tempArtifactKey: '$id-$live',
              workDirectory: Directory('${root.path}/mux-$id-$live'),
              onProgress: (_) {},
              trackDownloader:
                  ({
                    required stream,
                    required filePath,
                    required initialState,
                    required cancelToken,
                    required onProgress,
                  }) async {
                    final source = stream.id == 16 ? video : audio;
                    await source.copy(filePath);
                    final length = await source.length();
                    return DownloadPartResumeState(
                      tempPath: filePath,
                      url: stream.baseUrl,
                      downloadedBytes: length,
                      totalBytes: length,
                      streamId: stream.id,
                      codecid: stream.codecid,
                      codecs: stream.codecs,
                    );
                  },
            ),
          );
          final metadata = await probe(output);
          expect(metadata['codec_name'], codec);
          expect(metadata['sample_rate'], '$rate');
          expect(metadata['channels'], channels);
          expect(await packetHashes(output), await packetHashes(audio));
          if (codec == 'flac') expect(metadata['bits_per_raw_sample'], '24');
          if (live && codec == 'eac3') {
            expect(metadata['profile'], contains('Atmos'));
          }

          final repaired = File('${root.path}/repair-$id-$live.mp4');
          await run([
            '-i',
            output.path,
            '-map',
            '0:v:0',
            '-map',
            '0:a:0',
            '-c:v',
            'libx264',
            '-preset',
            'ultrafast',
            ...bilibiliAudioRepairArguments(audioTrack),
            repaired.path,
          ]);
          expect(await packetHashes(repaired), await packetHashes(audio));
          reports.add({
            'source': live ? 'reference' : 'generated',
            'audioId': id,
            'codec': metadata['codec_name'],
            'rate': metadata['sample_rate'],
            'channels': metadata['channels'],
            'profile': metadata['profile'],
            'bits': metadata['bits_per_raw_sample'],
            'mergePacketsIdentical': true,
            'repairPacketsIdentical': true,
          });
        },
        skip: !Platform.isWindows || (live && liveRoot == null),
      );
    }
  }
}
