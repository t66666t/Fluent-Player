import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/material.dart';

import 'package:video_player_app/models/subtitle_debug_preset.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/models/video_compose_models.dart';
import 'package:video_player_app/services/video_compose/video_compose_executor.dart';
import 'package:video_player_app/services/video_compose/video_compose_precise_renderer.dart';
import 'package:video_player_app/services/video_compose/video_compose_probe_service.dart';
import 'package:video_player_app/services/video_compose/video_compose_types.dart';

/// Actual Android composition using the production renderer, executor and Kit.
/// Call after Flutter has mounted its probe view and bundled font assets.
/// All new files stay in a unique directory beside the probe's own fixture.
Future<Map<String, Object?>> runAndroidResourceComposeAudit(
  File syntheticFixture,
) async {
  final report = <String, Object?>{
    'ok': false,
    'status': 'started',
    'stage': 'platform',
    'platform': Platform.operatingSystem,
    'limitations': [
      'Synthetic 2-second 640x360/60fps input, no audio track or audio session.',
      'Exercises precise raster subtitles, actual encoding and mov_text muxing.',
      'Pixel timing proves subtitle presence and gaps; it does not establish '
          'Chinese glyph legibility, all styles, HDR, VFR, or 4K performance.',
      'No local models, downloads, queue persistence or user settings are used.',
    ],
  };
  if (!Platform.isAndroid) {
    return report..addAll({'status': 'unsupported', 'error': 'Android only'});
  }
  final watch = Stopwatch()..start();
  try {
    if (!await syntheticFixture.exists()) {
      throw StateError('Synthetic input missing: ${syntheticFixture.path}');
    }
    final root = await syntheticFixture.parent.createTemp('compose_audit_');
    report['artifactsDirectory'] = root.path;
    final source = File('${root.path}/source_2s_60fps.mp4');
    report['stage'] = 'prepare_source';
    // Retain the actual fixture's decoded timestamps, while a black canvas
    // makes white subtitle pixels objectively distinguishable from video.
    await _composeKit([
      '-hide_banner',
      '-y',
      '-i',
      syntheticFixture.path,
      '-t',
      '2',
      '-map',
      '0:v:0',
      '-an',
      '-vf',
      'scale=640:360,setsar=1,lut=y=0:u=128:v=128',
      '-r',
      '60',
      '-c:v',
      'libx264',
      '-preset',
      'ultrafast',
      '-threads',
      '2',
      '-crf',
      '18',
      '-pix_fmt',
      'yuv420p',
      source.path,
    ]);
    const probe = VideoComposeProbeService(preferSystemFfmpeg: false);
    final info = await probe.probeVideoInfo(source.path);
    _composeRequire(info.width == 640 && info.height == 360, 'source canvas');
    _composeRequire((info.frameRate - 60).abs() < .01, 'source frame rate');
    _composeRequire(
      (info.duration.inMilliseconds - 2000).abs() <= 40,
      'source duration',
    );
    report['source'] = {
      'path': source.path,
      'width': info.width,
      'height': info.height,
      'durationMs': info.duration.inMilliseconds,
      'fps': info.frameRate,
    };

    final cues = [
      _composeCue(1, 123, 789, 'Precise 中文字幕\nTiming 60 fps'),
      _composeCue(2, 900, 1233, 'Second 中文 caption'),
      _composeCue(3, 1450, 1789, 'Precise 中文字幕\nTiming 60 fps'),
    ];
    const style = SubtitleStyle();
    // A fixed bundled-font preset bypasses configurable/user font resolution.
    const preset = SubtitleDebugPreset(
      id: 'android-resource-audit',
      name: 'Resource audit',
      category: 'audit',
      description: 'Fixed precise-render native validation',
      primaryFont: 'Noto Sans SC',
      secondaryFont: 'Comic Relief',
      size: 32,
      bottom: .08,
    );
    final artifacts = <String>[];
    report['stage'] = 'render_precise';
    final assets = await VideoComposePreciseRenderer().render(
      outputDirectory: Directory('${root.path}/subtitle_scenes'),
      width: 640,
      height: 360,
      duration: info.duration,
      primary: cues,
      secondary: const [],
      style: style,
      subtitlePreset: preset,
      alignment: const Alignment(0, .8),
      splitSubtitleByLine: true,
      itemGap: 6,
      onProgress: (_) {},
      onArtifact: artifacts.add,
    );
    final concat = await File(assets.concatPath).readAsString();
    _composeRequire(assets.frameCount == 3, 'repeated scene raster reuse');
    _composeRequire(
      concat.contains('option framerate 1000'),
      'millisecond precise timeline',
    );
    report['precise'] = {
      'uniqueScenes': assets.frameCount,
      'concatPath': assets.concatPath,
      'cues': [
        for (final cue in cues)
          {
            'startMs': cue.startTime.inMilliseconds,
            'endMs': cue.endTime.inMilliseconds,
            'text': cue.text,
          },
      ],
    };

    final soft = File('${root.path}/soft_zh.srt');
    await soft.writeAsString(
      '1\n00:00:00,123 --> 00:00:00,789\n中文软字幕 audit\n\n'
      '2\n00:00:00,900 --> 00:00:01,233\n第二段 soft track\n\n',
    );
    final output = File('${root.path}/composed.mp4');
    final executor = VideoComposeExecutor(preferSystemFfmpeg: false);
    final encoders = <String>[];
    report['stage'] = 'execute';
    await executor.execute(
      request: VideoComposeRequest(
        videoId: 'android-resource-compose-audit',
        videoPath: source.path,
        title: 'Synthetic Android compose audit',
        renderSecondarySubtitle: false,
        continuousSubtitle: false,
        embedSoftSubtitles: true,
        softSubtitleOnly: false,
        softSubtitleUseSourceQuality: true,
        softSubtitleTracks: const [],
        resolution: VideoComposeResolution.source,
        subtitleStyle: style,
        subtitlePreset: preset,
        subtitleAlignment: const Alignment(0, .8),
        outputPath: output.path,
      ),
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
          title: '中文 audit',
          language: 'chi',
        ),
      ],
      duration: info.duration,
      transcodeVideo: true,
      outputWidth: 640,
      outputHeight: 360,
      frameRate: info.frameRate,
      onProgress: (_) {},
      onEncoderChanged: encoders.add,
      onArtifact: artifacts.add,
    );
    report['encodersAttempted'] = encoders;
    report['outputPath'] = output.path;
    report['stage'] = 'inspect_encoded_output';
    final outputInfo = await probe.probeVideoInfo(output.path);
    final measured = await _composeProbe(output.path);
    report['ffprobe'] = measured;
    final streams = (measured['streams'] as List).cast<Map>();
    final video = streams.where((s) => s['codec_type'] == 'video').toList();
    final subtitles = streams
        .where((s) => s['codec_type'] == 'subtitle')
        .toList();
    _composeRequire(video.length == 1, 'one encoded video track');
    _composeRequire(
      subtitles.length == 1 && subtitles.single['codec_name'] == 'mov_text',
      'mov_text subtitle track',
    );
    _composeRequire(
      !streams.any((s) => s['codec_type'] == 'audio'),
      'no introduced audio track',
    );
    _composeRequire(
      outputInfo.width == 640 && outputInfo.height == 360,
      'encoded canvas',
    );
    _composeRequire(
      (outputInfo.frameRate - 60).abs() < .01,
      'encoded frame rate',
    );
    _composeRequire(
      (outputInfo.duration.inMilliseconds - 2000).abs() <= 50,
      'encoded duration',
    );
    _composeRequire(
      '${video.single['nb_read_frames']}' == '120',
      'FFprobe counted exactly 120 video frames',
    );

    report['stage'] = 'decode_and_verify_pixels';
    final raw = File('${root.path}/composed_96x54.gray');
    await _composeKit([
      '-hide_banner',
      '-y',
      '-i',
      output.path,
      '-map',
      '0:v:0',
      '-vf',
      'scale=96:54:flags=area,format=gray',
      '-vsync',
      '0',
      '-f',
      'rawvideo',
      '-pix_fmt',
      'gray',
      raw.path,
    ]);
    final pixels = await raw.readAsBytes();
    const frameSize = 96 * 54;
    _composeRequire(
      pixels.length == 120 * frameSize,
      'actual decoded 120 grayscale frames',
    );
    final mismatches = <Map<String, Object?>>[];
    var visibleFrames = 0;
    for (var frame = 0; frame < 120; frame++) {
      final ms = frame * 1000 / 60;
      final expected = cues.any(
        (cue) =>
            ms >= cue.startTime.inMilliseconds &&
            ms < cue.endTime.inMilliseconds,
      );
      final end = (frame + 1) * frameSize;
      var brightPixels = 0;
      for (var i = frame * frameSize; i < end; i++) {
        if (pixels[i] > 40) brightPixels++;
      }
      final visible = brightPixels > 0;
      if (visible) visibleFrames++;
      if (visible != expected) {
        mismatches.add({
          'frame': frame,
          'timeMs': ms,
          'expectedVisible': expected,
          'brightPixels': brightPixels,
        });
      }
    }
    report['pixelVerification'] = {
      'decodedFrames': 120,
      'visibleFrames': visibleFrames,
      'threshold': 40,
      'mismatches': mismatches,
    };
    _composeRequire(
      mismatches.isEmpty,
      'burned subtitles match all caption/gap frame boundaries',
    );
    final extracted = File('${root.path}/extracted_soft.srt');
    await _composeKit([
      '-hide_banner',
      '-y',
      '-i',
      output.path,
      '-map',
      '0:s:0',
      '-c:s',
      'srt',
      extracted.path,
    ]);
    final softText = await extracted.readAsString();
    report['extractedSoftSubtitles'] = softText;
    _composeRequire(
      softText.contains('中文软字幕 audit') && softText.contains('第二段 soft track'),
      'soft track text roundtrip',
    );
    report.addAll({
      'ok': true,
      'status': 'passed',
      'stage': 'complete',
      'retainedArtifacts': artifacts,
    });
  } catch (error, stack) {
    report.addAll({
      'status': 'failed',
      'error': '$error',
      'stack': stack.toString().split('\n').take(8).join('\n'),
    });
  } finally {
    report['elapsedMs'] = watch.elapsedMilliseconds;
  }
  return report;
}

SubtitleItem _composeCue(int index, int start, int end, String text) =>
    SubtitleItem(
      index: index,
      startTime: Duration(milliseconds: start),
      endTime: Duration(milliseconds: end),
      text: text,
    );

void _composeRequire(bool value, String check) {
  if (!value) throw StateError('Compose verification failed: $check');
}

Future<void> _composeKit(List<String> arguments) async {
  final session = await FFmpegKit.executeWithArguments(arguments);
  if (!ReturnCode.isSuccess(await session.getReturnCode())) {
    final log = await session.getAllLogsAsString() ?? 'No FFmpeg log';
    throw StateError(
      log.length <= 6000 ? log : log.substring(log.length - 6000),
    );
  }
}

Future<Map<String, dynamic>> _composeProbe(String path) async {
  final session = await FFprobeKit.executeWithArguments([
    '-v',
    'error',
    '-count_frames',
    '-show_streams',
    '-show_format',
    '-of',
    'json',
    path,
  ]);
  if (!ReturnCode.isSuccess(await session.getReturnCode())) {
    throw StateError(await session.getAllLogsAsString() ?? 'FFprobe failed');
  }
  final output = await session.getOutput();
  return Map<String, dynamic>.from(jsonDecode(output ?? '') as Map);
}
