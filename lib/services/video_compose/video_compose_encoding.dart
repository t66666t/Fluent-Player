import 'dart:math' as math;

import '../../models/video_compose_models.dart';
import 'video_compose_types.dart';

/// Encoder names come from the same binary/Kit instance that does the render.
/// A listed encoder still needs a working driver, so execution must fall back.
class VideoComposeEncoding {
  final String codec;
  final String? device;
  const VideoComposeEncoding(this.codec, {this.device});

  bool get hardware => codec != 'libx264';

  String get label => switch (codec) {
    'h264_nvenc' => 'NVIDIA NVENC',
    'h264_qsv' => 'Intel Quick Sync',
    'h264_amf' => 'AMD AMF',
    'h264_mf' => 'Media Foundation',
    'h264_vaapi' => 'VAAPI',
    'h264_videotoolbox' => 'VideoToolbox',
    'h264_mediacodec' => 'MediaCodec',
    _ => 'CPU x264',
  };

  static Set<String> parseEncoders(String output) => RegExp(
    r'^\s*V[A-Z.]{5}\s+(\S+)',
    multiLine: true,
  ).allMatches(output).map((match) => match.group(1)!).toSet();

  static List<VideoComposeEncoding> candidates({
    required String platform,
    required Set<String> available,
    List<String> vaapiDevices = const [],
    bool allowHardware = true,
  }) {
    final names = switch (platform) {
      'windows' => ['h264_nvenc', 'h264_qsv', 'h264_amf', 'h264_mf'],
      'linux' => ['h264_nvenc', 'h264_qsv', 'h264_amf', 'h264_vaapi'],
      'macos' || 'ios' => ['h264_videotoolbox'],
      'android' => ['h264_mediacodec'],
      _ => <String>[],
    };
    return [
      if (allowHardware)
        for (final name in names)
          if (available.contains(name))
            if (name == 'h264_vaapi')
              for (final device in vaapiDevices)
                VideoComposeEncoding(name, device: device)
            else
              VideoComposeEncoding(name),
      const VideoComposeEncoding('libx264'),
    ];
  }

  List<String> outputArguments({required int threads, required int bitrate}) =>
      [
        '-c:v',
        codec,
        '-threads:v',
        '$threads',
        ...switch (codec) {
          'h264_nvenc' => [
            '-preset',
            'fast',
            '-rc',
            'vbr',
            '-cq',
            '20',
            '-b:v',
            '0',
            '-pix_fmt',
            'yuv420p',
          ],
          'h264_qsv' => [
            '-preset',
            'veryfast',
            '-global_quality',
            '20',
            '-look_ahead',
            '0',
            '-pix_fmt',
            'nv12',
          ],
          'h264_amf' => [
            '-quality',
            'speed',
            '-rc',
            'cqp',
            '-qp_i',
            '20',
            '-qp_p',
            '20',
            '-pix_fmt',
            'nv12',
          ],
          'h264_vaapi' => ['-qp', '20'],
          'h264_mf' => [
            '-hw_encoding',
            '1',
            '-b:v',
            '$bitrate',
            '-pix_fmt',
            'nv12',
          ],
          'h264_videotoolbox' => [
            '-allow_sw',
            '0',
            '-realtime',
            '0',
            '-b:v',
            '$bitrate',
            '-pix_fmt',
            'nv12',
          ],
          'h264_mediacodec' => ['-b:v', '$bitrate', '-pix_fmt', 'yuv420p'],
          _ => ['-preset', 'veryfast', '-crf', '20', '-pix_fmt', 'yuv420p'],
        },
      ];
}

/// One argument builder for desktop FFmpeg and mobile FFmpegKit. No shell
/// quoting is applied to file names; filter paths use their own escaping.
List<String> buildVideoComposeArguments({
  required VideoComposeRequest request,
  required String outputPath,
  required String filter,
  String? preciseSubtitleConcatPath,
  required List<ComposeSubtitleInput> softSubtitleInputs,
  required bool transcodeVideo,
  required VideoComposeEncoding encoding,
  required int threadBudget,
  int outputWidth = 1920,
  int outputHeight = 1080,
  double frameRate = 30,
  bool transcodeAudio = false,
  bool legacyFrameSync = false,
}) {
  final budget = threadBudget.clamp(1, 12);
  // With x264 the encoder benefits most from the CPU allowance; extra overlay
  // threads compete for memory bandwidth at 4K. Hardware encoding leaves that
  // allowance available for parallel decoding/filtering instead.
  final decodeThreads = encoding.hardware ? math.max(1, budget ~/ 6) : 1;
  final filterThreads = encoding.hardware ? math.max(1, budget ~/ 3) : 1;
  final encodeThreads = math.max(1, budget - decodeThreads - filterThreads);
  final precise = preciseSubtitleConcatPath?.isNotEmpty == true;
  final bitrate = (outputWidth * outputHeight * frameRate.clamp(1, 120) * .16)
      .round()
      .clamp(1200000, 100000000);
  final args = <String>[
    '-hide_banner',
    '-nostdin',
    '-y',
    if (encoding.device != null) ...['-vaapi_device', encoding.device!],
    '-filter_threads',
    '$filterThreads',
    '-filter_complex_threads',
    '$filterThreads',
    '-threads',
    '$decodeThreads',
    '-i',
    request.videoPath,
    if (precise) ...[
      '-threads',
      '1',
      '-f',
      'concat',
      '-safe',
      '0',
      '-i',
      preciseSubtitleConcatPath!,
    ],
    for (final input in softSubtitleInputs) ...['-i', input.path],
  ];
  if (transcodeVideo) {
    final upload = encoding.device == null ? '' : ',format=nv12,hwupload';
    if (precise) {
      args.addAll([
        '-filter_complex',
        '[0:V:0]${filter.isEmpty ? 'null' : filter}[base];[1:v:0]format=rgba[sub];'
            '[base][sub]overlay=0:0:eof_action=pass:repeatlast=1:format=yuv420'
            ',format=yuv420p$upload[outv]',
        '-map',
        '[outv]',
      ]);
    } else {
      if (filter.isNotEmpty || upload.isNotEmpty) {
        args.addAll(['-vf', '${filter.isEmpty ? 'null' : filter}$upload']);
      }
      args.addAll(['-map', '0:V:0']);
    }
    args.addAll(
      encoding.outputArguments(threads: encodeThreads, bitrate: bitrate),
    );
    // Sparse subtitle PNGs must not determine the output rate. Keep the source
    // frame timestamps for both CFR and VFR media.
    args.addAll([legacyFrameSync ? '-vsync' : '-fps_mode', 'vfr']);
  } else {
    args.addAll(['-map', '0:V:0', '-c:v', 'copy']);
  }
  // Explicit mapping prevents a subtitle PNG or an attached cover from being
  // chosen as the output video. Do not inherit incompatible source subtitles.
  args.addAll(['-map', '0:a?', '-c:a', transcodeAudio ? 'aac' : 'copy']);
  if (transcodeAudio) args.addAll(['-b:a', '192k']);
  final softOffset = precise ? 2 : 1;
  for (var i = 0; i < softSubtitleInputs.length; i++) {
    final input = softSubtitleInputs[i];
    final title = input.title.trim().isEmpty
        ? '字幕 ${i + 1}'
        : input.title.trim();
    args.addAll([
      '-map',
      '${i + softOffset}:0',
      '-metadata:s:s:$i',
      'title=$title',
      '-metadata:s:s:$i',
      'handler_name=$title',
      '-metadata:s:s:$i',
      'language=${input.language}',
    ]);
  }
  if (softSubtitleInputs.isNotEmpty) args.addAll(['-c:s', 'mov_text']);
  args.addAll(['-map_metadata', '0', '-movflags', '+faststart', outputPath]);
  return args;
}
