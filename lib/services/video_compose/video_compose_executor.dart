import 'dart:async';
import '../community_media_input.dart';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../features/model_center/inference_resource_governor.dart';
import '../../models/video_compose_models.dart';
import '../../utils/ffmpeg_progress.dart';
import '../../utils/ffmpeg_utils.dart';
import 'video_compose_encoding.dart';
import 'video_compose_types.dart';

typedef VideoComposeProgressCallback = void Function(double ratio);
typedef VideoComposeCommandRunner =
    Future<void> Function(List<String> arguments, void Function(String) onLine);

class VideoComposeExecutor {
  VideoComposeExecutor({
    bool? preferSystemFfmpeg,
    this.enableHardwareEncoding = true,
    VideoComposeCommandRunner? commandRunner,
    Future<Set<String>> Function()? loadEncoders,
    String? platform,
  }) : _preferSystemFfmpeg = preferSystemFfmpeg,
       _commandRunner = commandRunner,
       _loadEncoders = loadEncoders,
       _platform = platform ?? Platform.operatingSystem;

  final bool? _preferSystemFfmpeg;
  final bool enableHardwareEncoding;
  final VideoComposeCommandRunner? _commandRunner;
  final Future<Set<String>> Function()? _loadEncoders;
  final String _platform;
  static final Map<String, Set<String>> _encoderCache = {};
  Process? _activeDesktopComposeProcess;
  FFmpegSession? _activeMobileComposeSession;
  bool _cancelled = false;
  Completer<void>? _done;
  Completer<void>? _cancelSignal;
  bool get _desktop =>
      _preferSystemFfmpeg ?? FFmpegUtils.useDesktopProcessFfmpeg;

  Future<void> execute({
    required VideoComposeRequest request,
    required String filter,
    String? preciseSubtitleConcatPath,
    required List<ComposeSubtitleInput> softSubtitleInputs,
    required Duration duration,
    required bool transcodeVideo,
    required VideoComposeProgressCallback onProgress,
    void Function(String encoder)? onEncoderChanged,
    void Function(String path)? onArtifact,
    int outputWidth = 1920,
    int outputHeight = 1080,
    double frameRate = 30,
  }) async {
    requireCommunityLocalMedia(request.videoPath);
    if (_done != null) throw StateError('已有视频编码任务正在运行');
    _cancelled = false;
    _done = Completer<void>();
    _cancelSignal = Completer<void>();
    Directory? staging;
    Future<void> perform(int threadBudget) async {
      _throwIfCancelled();
      final output = File(request.outputPath).absolute;
      final source = File(request.videoPath).absolute;
      if (p.equals(output.path, source.path) ||
          await output.exists() &&
              await source.exists() &&
              await FileSystemEntity.identical(output.path, source.path)) {
        throw StateError('输出路径不能覆盖源视频');
      }
      await output.parent.create(recursive: true);
      staging = await output.parent.createTemp('.compose_');
      onArtifact?.call(staging!.path);
      final stagedPath = '${staging!.path}/encoded.mp4';
      final encoders = transcodeVideo && enableHardwareEncoding
          ? await _availableEncoders()
          : <String>{};
      _throwIfCancelled();
      final devices = <String>[];
      if (_platform == 'linux' && encoders.contains('h264_vaapi')) {
        final dri = Directory('/dev/dri');
        if (await dri.exists()) {
          await for (final device in dri.list(followLinks: false)) {
            if (RegExp(r'renderD\d+$').hasMatch(device.path)) {
              devices.add(device.path);
            }
          }
          devices.sort();
        }
      }
      final candidates = VideoComposeEncoding.candidates(
        platform: _platform,
        available: encoders,
        vaapiDevices: devices,
        allowHardware: transcodeVideo && enableHardwareEncoding,
      );
      var currentFilter = filter;
      var transcodeAudio = false;
      var legacyFrameSync = false;
      var reportedProgress = 0.0;
      for (final encoding in candidates) {
        _throwIfCancelled();
        onEncoderChanged?.call(transcodeVideo ? encoding.label : '直接封装');
        while (true) {
          _throwIfCancelled();
          final args = buildVideoComposeArguments(
            request: request,
            outputPath: stagedPath,
            filter: currentFilter,
            preciseSubtitleConcatPath: preciseSubtitleConcatPath,
            softSubtitleInputs: softSubtitleInputs,
            transcodeVideo: transcodeVideo,
            encoding: encoding,
            threadBudget: threadBudget,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            frameRate: frameRate,
            transcodeAudio: transcodeAudio,
            legacyFrameSync: legacyFrameSync,
          );
          final progress = FfmpegProgress(
            duration: duration,
            onProgress: (ratio) {
              if (ratio >= reportedProgress && !_cancelled) {
                reportedProgress = ratio;
                onProgress(ratio);
              }
            },
          );
          try {
            await _runCommand(args, progress.readLine, progress: progress);
            _throwIfCancelled();
            final staged = File(stagedPath);
            if (!await staged.exists() || await staged.length() <= 1024) {
              throw StateError('FFmpeg 输出文件异常');
            }
          } catch (error) {
            _throwIfCancelled();
            final text = error.toString().toLowerCase();
            if (!legacyFrameSync &&
                text.contains('fps_mode') &&
                (text.contains('unrecognized option') ||
                    text.contains('not found'))) {
              legacyFrameSync = true;
              continue;
            }
            if (transcodeVideo &&
                (_platform == 'android' || _platform == 'ios') &&
                currentFilter.contains(':fontsdir=') &&
                _isFontsDirRelatedError(text)) {
              currentFilter = removeFontsDirOption(currentFilter);
              continue;
            }
            if (!transcodeAudio && _isAudioContainerError(text)) {
              transcodeAudio = true;
              continue;
            }
            if (!encoding.hardware || _isOutputAccessError(text)) rethrow;
            final lines = '$error'.split('\n');
            final detail = lines.firstWhere(
              (line) => RegExp(
                r'cannot load|cannot init|failed to|no device|unsupported|not available',
                caseSensitive: false,
              ).hasMatch(line),
              orElse: () => lines.lastWhere(
                (line) => line.trim().isNotEmpty,
                orElse: () => '编码器初始化失败',
              ),
            );
            debugPrint('视频合成 ${encoding.label} 不可用，尝试下一个编码器：$detail');
            break;
          }
          // Publish only a complete result. Retry attempts never touch an
          // existing output. Rename failures must not trigger a full re-encode.
          _throwIfCancelled();
          await _publishOutput(File(stagedPath), output);
          onProgress(1);
          return;
        }
      }
      throw StateError('没有可用的视频编码器');
    }

    try {
      final resources = InferenceResourceSession.current;
      if (resources == null) {
        final limit = (_platform == 'android' || _platform == 'ios') ? 6 : 12;
        await perform((Platform.numberOfProcessors - 1).clamp(1, limit));
      } else {
        await resources.run(
          InferenceLane.compilation,
          (permit) => perform(permit.threads),
          cancelSignal: _cancelSignal!.future,
        );
      }
    } finally {
      try {
        if (staging != null && await staging!.exists()) {
          await staging!.delete(recursive: true);
        }
      } on FileSystemException catch (error) {
        debugPrint('清理合成临时输出失败：$error');
      } finally {
        _done!.complete();
        _done = null;
        _cancelSignal = null;
      }
    }
  }

  Future<void> cancel() async {
    _cancelled = true;
    final done = _done;
    if (_cancelSignal?.isCompleted == false) _cancelSignal!.complete();
    final process = _activeDesktopComposeProcess;
    if (process != null) {
      try {
        process.kill(ProcessSignal.sigkill);
      } catch (_) {
        process.kill();
      }
    }
    await _activeMobileComposeSession?.cancel();
    // The caller can delete assets safely only after native handles close.
    await done?.future;
  }

  Future<void> _publishOutput(File staged, File output) async {
    for (var attempt = 0; ; attempt++) {
      _throwIfCancelled();
      try {
        await staged.rename(output.path);
        return;
      } on FileSystemException catch (error) {
        final code = error.osError?.errorCode;
        // Replacing an open destination can report ACCESS_DENIED (5), whereas
        // deleting/opening the same locked file reports SHARING_VIOLATION (32).
        if (!Platform.isWindows ||
            (code != 5 && code != 32 && code != 33) ||
            attempt >= 5) {
          rethrow;
        }
        await Future<void>.delayed(Duration(milliseconds: 30 << attempt));
      }
    }
  }

  Future<Set<String>> _availableEncoders() async {
    if (_loadEncoders != null) return _loadEncoders();
    final key = _desktop
        ? 'process:${await FFmpegUtils.ffmpegPath}'
        : 'kit:$_platform';
    final cached = _encoderCache[key];
    if (cached != null) return cached;
    final listing = StringBuffer();
    try {
      await _runCommand(['-hide_banner', '-encoders'], listing.writeln);
      _throwIfCancelled();
      final encoders = VideoComposeEncoding.parseEncoders(listing.toString());
      _encoderCache[key] = encoders;
      return encoders;
    } catch (error) {
      _throwIfCancelled();
      debugPrint('读取视频编码器失败，使用 CPU 编码：$error');
      return {};
    }
  }

  Future<void> _runCommand(
    List<String> args,
    void Function(String) onLine, {
    FfmpegProgress? progress,
  }) async {
    _throwIfCancelled();
    if (_commandRunner != null) return _commandRunner(args, onLine);
    if (!_desktop) return _runMobile(args, onLine, progress);
    await FFmpegUtils.ensureAvailable();
    _throwIfCancelled();
    final process = await Process.start(await FFmpegUtils.ffmpegPath, [
      if (progress != null) ...['-progress', 'pipe:1', '-nostats'],
      ...args,
    ], runInShell: false);
    _activeDesktopComposeProcess = process;
    final releasePid = InferenceProcessRegistry.instance.retain(process.pid);
    if (_cancelled) process.kill();
    final buffer = StringBuffer();
    void readLine(String line) {
      _appendLog(buffer, line);
      onLine(line);
    }

    try {
      final completed = await Future.wait<Object?>([
        process.exitCode,
        process.stderr
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .forEach(readLine),
        process.stdout
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .forEach(readLine),
      ]);
      if (completed.first != 0) throw StateError(buffer.toString());
    } finally {
      releasePid();
      if (identical(_activeDesktopComposeProcess, process)) {
        _activeDesktopComposeProcess = null;
      }
    }
  }

  Future<void> _runMobile(
    List<String> args,
    void Function(String) onLine,
    FfmpegProgress? progress,
  ) async {
    final completer = Completer<void>();
    completer.future.ignore();
    final active = await FFmpegKit.executeWithArgumentsAsync(
      args,
      (session) async {
        try {
          final code = await session.getReturnCode();
          if (ReturnCode.isSuccess(code)) {
            if (progress == null) {
              onLine(await session.getAllLogsAsString() ?? '');
            }
            completer.complete();
          } else {
            completer.completeError(
              StateError(await session.getAllLogsAsString() ?? 'FFmpeg 执行失败'),
            );
          }
        } catch (error, stack) {
          if (!completer.isCompleted) completer.completeError(error, stack);
        }
      },
      (log) => onLine(log.getMessage()),
      (statistics) =>
          progress?.update(Duration(milliseconds: statistics.getTime())),
    );
    _activeMobileComposeSession = active;
    try {
      if (_cancelled) await active.cancel();
      await completer.future;
    } finally {
      if (identical(_activeMobileComposeSession, active)) {
        _activeMobileComposeSession = null;
      }
    }
  }

  String buildVideoFilter({
    required int sourceWidth,
    required int sourceHeight,
    required int targetWidth,
    required int targetHeight,
    String? assPath,
    String? fontsDir,
  }) {
    if (targetWidth <= 0 || targetHeight <= 0) return '';
    final base =
        'scale=$targetWidth:$targetHeight:force_original_aspect_ratio=decrease,'
        'pad=$targetWidth:$targetHeight:(ow-iw)/2:(oh-ih)/2,setsar=1';
    if (assPath == null || assPath.isEmpty) return base;
    final fonts = fontsDir == null
        ? ''
        : ":fontsdir='${escapeFilterPath(fontsDir)}'";
    return "$base,ass=filename='${escapeFilterPath(assPath)}'$fonts";
  }

  String removeFontsDirOption(String filter) =>
      filter.replaceAll(RegExp(r":fontsdir='[^']*'"), '');

  String escapeFilterPath(String path) => path
      .replaceAll(r'\', '/')
      .replaceAll(':', r'\:')
      .replaceAll("'", r"'\\\''");

  bool _isFontsDirRelatedError(String text) =>
      text.contains('fontsdir') ||
      text.contains('fontconfig') ||
      text.contains('no such filter') ||
      text.contains('unable to open') ||
      text.contains('cannot open');

  bool _isAudioContainerError(String text) =>
      text.contains('could not find tag for codec') ||
      text.contains('codec not currently supported in container') ||
      text.contains('flac in mp4 support is experimental') ||
      text.contains('audio codec') && text.contains('not supported');

  bool _isOutputAccessError(String text) =>
      text.contains('no space left') ||
      text.contains('disk full') ||
      (text.contains('permission denied') ||
              text.contains('read-only file system')) &&
          RegExp(
            r'error opening output|could not open .* for writing',
          ).hasMatch(text);

  static void _appendLog(StringBuffer buffer, String line) {
    buffer.writeln(line);
    if (buffer.length > 64 * 1024) {
      final tail = buffer.toString();
      buffer.clear();
      buffer.write(tail.substring(tail.length - 32 * 1024));
    }
  }

  void _throwIfCancelled() {
    if (_cancelled) throw StateError('视频合成已取消');
  }
}
