import '../subtitle_font_service.dart';
import 'dart:io';
import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/subtitle_model.dart';
import '../../models/video_compose_models.dart';
import '../../features/model_center/inference_scheduler.dart';
import '../../features/model_center/inference_resource_governor.dart';
import 'video_compose_ass_renderer.dart';
import 'video_compose_executor.dart';
import 'video_compose_font_service.dart';
import 'video_compose_output_path_service.dart';
import 'video_compose_probe_service.dart';
import 'video_compose_precise_renderer.dart';
import 'video_compose_subtitle_service.dart';
import 'video_compose_types.dart';

typedef VideoComposeStatusCallback =
    void Function({
      VideoComposeStage? stage,
      double? progress,
      String? message,
      String? error,
    });

typedef VideoComposeArtifactCallback = void Function(String filePath);

class VideoComposeOrchestrator {
  final VideoComposeProbeService _probeService;
  final VideoComposeSubtitleService _subtitleService;
  final VideoComposeAssRenderer _assRenderer;
  final VideoComposeFontService _fontService;
  final VideoComposePreciseRenderer _preciseRenderer;
  final VideoComposeExecutor _executor;
  final VideoComposeOutputPathService _outputPathService;
  final InferenceScheduler _scheduler;
  Completer<void>? _cancellation;

  VideoComposeOrchestrator({
    required VideoComposeProbeService probeService,
    required VideoComposeSubtitleService subtitleService,
    required VideoComposeAssRenderer assRenderer,
    required VideoComposeFontService fontService,
    required VideoComposePreciseRenderer preciseRenderer,
    required VideoComposeExecutor executor,
    required VideoComposeOutputPathService outputPathService,
    InferenceScheduler? scheduler,
  }) : _probeService = probeService,
       _subtitleService = subtitleService,
       _assRenderer = assRenderer,
       _fontService = fontService,
       _preciseRenderer = preciseRenderer,
       _executor = executor,
       _outputPathService = outputPathService,
       _scheduler = scheduler ?? InferenceScheduler.instance;

  Future<String?> getSourceResolutionLabel(String videoPath) async {
    try {
      final VideoProbeInfo probe = await _probeService.probeVideoInfo(
        videoPath,
      );
      if (probe.displayWidth <= 0 || probe.displayHeight <= 0) {
        return null;
      }
      return '${probe.displayWidth}×${probe.displayHeight}';
    } catch (_) {
      return null;
    }
  }

  Future<void> cancelRunningCompose() {
    final cancellation = _cancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
    _preciseRenderer.cancel();
    return _executor.cancel();
  }

  Future<void> run({
    required String taskId,
    required VideoComposeRequest request,
    required VideoComposeArtifactCallback onArtifact,
    required VideoComposeStatusCallback onStatus,
  }) async {
    if (_cancellation != null) throw StateError('已有视频合成任务正在运行');
    final cancellation = _cancellation = Completer<void>();
    try {
      onStatus(stage: VideoComposeStage.preparing, message: '等待本地处理资源');
      await _scheduler.run(
        () => _run(
          taskId: taskId,
          request: request,
          onArtifact: onArtifact,
          onStatus: onStatus,
        ),
        cancelSignal: cancellation.future,
      );
    } finally {
      _cancellation = null;
    }
  }

  void _throwIfCancelled() {
    if (_cancellation?.isCompleted == true) throw StateError('视频合成已取消');
  }

  Future<void> _run({
    required String taskId,
    required VideoComposeRequest request,
    required VideoComposeArtifactCallback onArtifact,
    required VideoComposeStatusCallback onStatus,
  }) async {
    _throwIfCancelled();
    final File videoFile = File(request.videoPath);
    if (!await videoFile.exists()) {
      throw StateError('视频文件不存在');
    }
    final bool softOnly = request.softSubtitleOnly;
    final bool shouldEmbedSoftSubtitles =
        request.embedSoftSubtitles || softOnly;
    final bool shouldRenderVideoSubtitles = !softOnly;
    final bool softOnlyUseSourceQuality =
        softOnly && request.softSubtitleUseSourceQuality;
    VideoProbeInfo? probe;
    TargetResolution? target;
    if (shouldRenderVideoSubtitles || !softOnlyUseSourceQuality) {
      probe = await _probeService.probeVideoInfo(request.videoPath);
      target = _probeService.targetResolution(
        sourceWidth: probe.displayWidth,
        sourceHeight: probe.displayHeight,
        resolution: request.resolution,
      );
    }
    final bool shouldTranscodeVideo;
    if (shouldRenderVideoSubtitles) {
      shouldTranscodeVideo = true;
    } else if (softOnlyUseSourceQuality) {
      shouldTranscodeVideo = false;
    } else if (probe != null && target != null) {
      final int sourceWidth = _probeService.ensureEven(probe.displayWidth);
      final int sourceHeight = _probeService.ensureEven(probe.displayHeight);
      shouldTranscodeVideo =
          target.width != sourceWidth || target.height != sourceHeight;
    } else {
      shouldTranscodeVideo = true;
    }
    if (shouldTranscodeVideo && target != null) {
      await InferenceResourceSession.current?.checkAllocation(
        target.width * target.height * 96 + 128 * 1024 * 1024,
        modelLabel: '视频合成缓冲',
      );
    }
    _throwIfCancelled();

    onStatus(
      stage: VideoComposeStage.preparing,
      progress: 0.08,
      message: '加载字幕',
    );

    final List<VideoComposeSoftSubtitleTrack> softTracks =
        request.softSubtitleTracks.isNotEmpty
        ? request.softSubtitleTracks
        : <VideoComposeSoftSubtitleTrack>[
            if (request.primarySubtitlePath != null &&
                request.primarySubtitlePath!.trim().isNotEmpty)
              VideoComposeSoftSubtitleTrack(
                path: request.primarySubtitlePath!,
                title: '主字幕',
              ),
            if (request.secondarySubtitlePath != null &&
                request.secondarySubtitlePath!.trim().isNotEmpty)
              VideoComposeSoftSubtitleTrack(
                path: request.secondarySubtitlePath!,
                title: '副字幕',
              ),
          ];

    final List<ComposeSubtitleSource> softSubtitles = <ComposeSubtitleSource>[];
    List<SubtitleItem> effectivePrimary = const <SubtitleItem>[];
    List<SubtitleItem> effectiveSecondary = const <SubtitleItem>[];
    if (shouldEmbedSoftSubtitles) {
      for (final VideoComposeSoftSubtitleTrack track in softTracks) {
        if (track.path.trim().isEmpty) continue;
        final List<SubtitleItem> items = await _subtitleService.loadSubtitle(
          track.path,
        );
        if (items.isEmpty) continue;
        softSubtitles.add(
          ComposeSubtitleSource(
            title: track.title.trim().isEmpty ? '字幕' : track.title.trim(),
            language: 'chi',
            items: items,
          ),
        );
      }
    }

    if (!softOnly) {
      final String? primaryPath = request.primarySubtitlePath;
      final String? secondaryPath = request.renderSecondarySubtitle
          ? request.secondarySubtitlePath
          : null;
      if ((primaryPath == null || primaryPath.isEmpty) &&
          (secondaryPath == null || secondaryPath.isEmpty)) {
        throw StateError('未选择可渲染字幕');
      }
      final List<SubtitleItem> primarySubtitles = await _subtitleService
          .loadSubtitle(primaryPath);
      final List<SubtitleItem> secondarySubtitles = await _subtitleService
          .loadSubtitle(secondaryPath);
      effectivePrimary = primarySubtitles;
      effectiveSecondary = secondarySubtitles;
      if (effectivePrimary.isEmpty && effectiveSecondary.isNotEmpty) {
        effectivePrimary = effectiveSecondary;
        effectiveSecondary = const <SubtitleItem>[];
      }
      if (effectivePrimary.isEmpty) {
        throw StateError('主字幕为空，无法合成');
      }
      if (request.continuousSubtitle && probe != null) {
        effectivePrimary = _subtitleService.continuousSubtitles(
          effectivePrimary,
          probe.duration,
        );
        if (effectiveSecondary.isNotEmpty) {
          effectiveSecondary = _subtitleService.continuousSubtitles(
            effectiveSecondary,
            probe.duration,
          );
        }
      }
    }

    final usedFonts = <String>{};
    if (shouldRenderVideoSubtitles &&
        request.renderMode == VideoComposeRenderMode.approximate &&
        request.subtitlePreset == null) {
      final fonts = SubtitleFontService.instance;
      usedFonts.addAll(
        fonts.familiesForTracks(
          request.subtitleStyle.textStyle,
          primary: effectivePrimary.map((s) => s.text),
          secondary: effectiveSecondary.map((s) => s.text),
          primaryLanguage: request.primaryFontLanguage,
          secondaryLanguage: request.secondaryFontLanguage,
          splitByLine: request.splitSubtitleByLine,
        ),
      );
      await fonts.verifyFiles(usedFonts);
      await fonts.prepareFamilies(usedFonts);
    }
    onStatus(
      stage: VideoComposeStage.preparing,
      progress: 0.15,
      message: shouldRenderVideoSubtitles
          ? '生成字幕样式'
          : (shouldTranscodeVideo ? '准备转码' : '快速封装'),
    );

    final Directory tempDir = await getTemporaryDirectory();
    String? assPath;
    String? preciseSubtitleConcatPath;
    if (shouldRenderVideoSubtitles &&
        request.renderMode == VideoComposeRenderMode.approximate &&
        request.subtitlePreset == null) {
      assPath = p.join(
        tempDir.path,
        'compose_${DateTime.now().millisecondsSinceEpoch}.ass',
      );
      onArtifact(assPath);
      await File(assPath).writeAsString(
        _assRenderer.buildAssContent(
          width: target!.width,
          height: target.height,
          primary: effectivePrimary,
          secondary: effectiveSecondary,
          style: request.styleForCanvas(
            width: target.width,
            height: target.height,
          ),
          primaryLanguage: request.primaryFontLanguage,
          secondaryLanguage: request.secondaryFontLanguage,
          alignment: request.subtitleAlignment,
        ),
        flush: true,
      );
    }
    if (shouldRenderVideoSubtitles &&
        (request.renderMode == VideoComposeRenderMode.precise ||
            request.subtitlePreset != null)) {
      _throwIfCancelled();
      final Directory preciseDir = Directory(
        p.join(
          tempDir.path,
          'compose_precise_${DateTime.now().millisecondsSinceEpoch}',
        ),
      );
      final PreciseSubtitleAssets assets = await _preciseRenderer.render(
        outputDirectory: preciseDir,
        width: target!.width,
        height: target.height,
        duration: probe?.duration ?? Duration.zero,
        primary: effectivePrimary,
        secondary: effectiveSecondary,
        style: request.styleForCanvas(
          width: target.width,
          height: target.height,
        ),
        primaryLanguage: request.primaryFontLanguage,
        secondaryLanguage: request.secondaryFontLanguage,
        subtitlePreset: request.subtitlePreset,
        alignment:
            request.subtitlePlacement?.alignment ?? request.subtitleAlignment,
        placement: request.subtitlePlacement,
        splitSubtitleByLine: request.splitSubtitleByLine,
        itemGap: request.subtitleItemGap,
        onProgress: (progress) => onStatus(
          stage: VideoComposeStage.preparing,
          progress: 0.15 + progress * 0.12,
          message: '生成精确字幕 ${(progress * 100).toStringAsFixed(0)}%',
        ),
        onArtifact: onArtifact,
      );
      preciseSubtitleConcatPath = assets.concatPath;
    }

    final List<ComposeSubtitleInput> softSubtitleInputs =
        <ComposeSubtitleInput>[];
    for (int i = 0; i < softSubtitles.length; i++) {
      final ComposeSubtitleSource source = softSubtitles[i];
      final String softPath = p.join(
        tempDir.path,
        'compose_soft_${DateTime.now().millisecondsSinceEpoch}_$i.srt',
      );
      onArtifact(softPath);
      await File(softPath).writeAsString(
        _subtitleService.buildSrtContent(source.items),
        flush: true,
      );
      softSubtitleInputs.add(
        ComposeSubtitleInput(
          path: softPath,
          title: source.title,
          language: source.language,
        ),
      );
    }

    await _outputPathService.ensureParentDirectory(request.outputPath);

    String? fontsDir;
    if (shouldRenderVideoSubtitles &&
        request.renderMode == VideoComposeRenderMode.approximate &&
        request.subtitlePreset == null) {
      fontsDir = await _fontService.prepareAssFonts(
        request.subtitleStyle,
        usedFamilies: usedFonts,
      );
      onArtifact(fontsDir);
    }
    if ((Platform.isAndroid || Platform.isIOS) &&
        shouldRenderVideoSubtitles &&
        request.renderMode == VideoComposeRenderMode.approximate &&
        request.subtitlePreset == null &&
        _fontService.requiresBundledFonts(request.subtitleStyle) &&
        (fontsDir == null || fontsDir.isEmpty)) {
      throw StateError('移动端内置字体资源加载失败');
    }
    if ((Platform.isAndroid || Platform.isIOS) &&
        shouldRenderVideoSubtitles &&
        request.renderMode == VideoComposeRenderMode.approximate &&
        request.subtitlePreset == null) {
      await _fontService.configureForRender(fontsDir: fontsDir);
    }

    final String filter = _executor.buildVideoFilter(
      sourceWidth: probe?.displayWidth ?? 0,
      sourceHeight: probe?.displayHeight ?? 0,
      targetWidth: shouldTranscodeVideo ? (target?.width ?? 0) : 0,
      targetHeight: shouldTranscodeVideo ? (target?.height ?? 0) : 0,
      assPath: assPath,
      fontsDir: fontsDir,
    );

    onStatus(
      stage: VideoComposeStage.rendering,
      progress: 0.28,
      message: shouldRenderVideoSubtitles
          ? '渲染字幕'
          : (shouldTranscodeVideo ? '转码并封装' : '快速封装中'),
    );

    _throwIfCancelled();
    var encoderLabel = '';
    await _executor.execute(
      request: request,
      filter: filter,
      preciseSubtitleConcatPath: preciseSubtitleConcatPath,
      softSubtitleInputs: softSubtitleInputs,
      duration: probe?.duration ?? Duration.zero,
      transcodeVideo: shouldTranscodeVideo,
      outputWidth: target?.width ?? 1920,
      outputHeight: target?.height ?? 1080,
      frameRate: probe?.frameRate ?? 30,
      onEncoderChanged: (label) {
        encoderLabel = label;
        onStatus(stage: VideoComposeStage.rendering, message: '渲染中 · $label');
      },
      onArtifact: onArtifact,
      onProgress: (double ratio) {
        onStatus(
          stage: VideoComposeStage.rendering,
          progress: 0.28 + ratio * 0.64,
          message: '渲染中 ${(ratio * 100).toStringAsFixed(0)}% · $encoderLabel',
        );
      },
    );

    onStatus(
      stage: VideoComposeStage.finalizing,
      progress: 0.96,
      message: '封装输出',
    );

    final File outputFile = File(request.outputPath);
    if (!await outputFile.exists()) {
      throw StateError('输出文件不存在');
    }
    final int outputSize = await outputFile.length();
    if (outputSize <= 1024) {
      throw StateError('输出文件异常');
    }
  }
}
