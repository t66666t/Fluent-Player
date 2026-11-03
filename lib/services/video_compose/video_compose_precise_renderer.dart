import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path/path.dart' as p;

import '../../features/model_center/inference_resource_governor.dart';
import '../../models/subtitle_debug_preset.dart';
import '../../models/subtitle_model.dart';
import '../../models/subtitle_position.dart';
import '../../models/subtitle_style.dart';
import '../../utils/subtitle_layout.dart';
import '../../widgets/subtitle_overlay.dart';
import '../subtitle_font_service.dart';
import 'video_compose_timeline.dart';

typedef PreciseRenderProgress = void Function(double progress);
typedef PreciseRenderArtifact = void Function(String path);

class PreciseSubtitleAssets {
  final String concatPath;
  final int frameCount;
  const PreciseSubtitleAssets({
    required this.concatPath,
    required this.frameCount,
  });
}

class VideoComposePreciseRenderer {
  bool _cancelled = false;
  void resetCancellation() => _cancelled = false;
  void cancel() => _cancelled = true;

  Future<PreciseSubtitleAssets> render({
    required Directory outputDirectory,
    required int width,
    required int height,
    required Duration duration,
    required List<SubtitleItem> primary,
    required List<SubtitleItem> secondary,
    required SubtitleStyle style,
    String? primaryLanguage,
    String? secondaryLanguage,
    SubtitleDebugPreset? subtitlePreset,
    required Alignment alignment,
    SubtitlePlacementSnapshot? placement,
    required bool splitSubtitleByLine,
    required double itemGap,
    required PreciseRenderProgress onProgress,
    required PreciseRenderArtifact onArtifact,
  }) async {
    resetCancellation();
    if (width <= 0 || height <= 0) throw StateError('无效的字幕画布尺寸');
    await outputDirectory.create(recursive: true);
    onArtifact(outputDirectory.path);
    final segments = buildComposeTimeline(
      duration: duration,
      primary: primary,
      secondary: secondary,
      splitSubtitleByLine: splitSubtitleByLine,
    );
    if (segments.isEmpty) throw StateError('无法生成精确字幕时间线');
    if (subtitlePreset == null) {
      final fonts = SubtitleFontService.instance;
      final used = fonts.familiesForTracks(
        style.textStyle,
        primary: primary.map((s) => s.text),
        secondary: secondary.map((s) => s.text),
        primaryLanguage: primaryLanguage,
        secondaryLanguage: secondaryLanguage,
        splitByLine: splitSubtitleByLine,
      );
      await fonts.verifyFiles(used);
      await fonts.prepareFamilies(used);
    }
    _throwIfCancelled();
    final surface = _PreciseWidgetSurface(width, height);
    final renderedFrames = <String, String>{};
    final concat = StringBuffer('ffconcat version 1.0\n');
    String? lastPath;
    try {
      await InferenceResourceSession.current?.checkAllocation(
        (width * height * surface.supersample * surface.supersample * 16)
                .ceil() +
            width * height * 8,
        modelLabel: '精确字幕图像',
      );
      for (var i = 0; i < segments.length; i++) {
        _throwIfCancelled();
        final segment = segments[i];
        var framePath = renderedFrames[segment.signature];
        if (framePath == null) {
          // Repeated scenes skip image loading, layout, and PNG encoding.
          final entries = await _loadEntries(
            segment.entries,
            primaryLanguage,
            secondaryLanguage,
          );
          _throwIfCancelled();
          framePath = p.join(
            outputDirectory.absolute.path,
            'frame_${renderedFrames.length.toString().padLeft(6, '0')}.png',
          );
          try {
            final png = await surface.render(
              entries: entries,
              style: style,
              subtitlePreset: subtitlePreset,
              alignment: placement?.alignment ?? alignment,
              itemGap: itemGap,
              presetPositionOverride: placement?.isCustom ?? false,
            );
            _throwIfCancelled();
            // Disposable assets need closed handles, not fsync per caption.
            await File(framePath).writeAsBytes(png);
          } catch (error) {
            if (_cancelled) rethrow;
            throw StateError('精确字幕场景 ${i + 1}/${segments.length} 渲染失败：$error');
          }
          onArtifact(framePath);
          renderedFrames[segment.signature] = framePath;
        }
        concat.writeln("file '${_escapeConcatPath(framePath)}'");
        // image2 defaults to 1/25. Set EVERY file to a millisecond time base.
        concat.writeln('option framerate 1000');
        concat.writeln(
          'duration ${(segment.endMs - segment.startMs) / 1000.0}',
        );
        lastPath = framePath;
        onProgress((i + 1) / segments.length);
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      surface.dispose();
    }
    _throwIfCancelled();
    concat.writeln("file '${_escapeConcatPath(lastPath!)}'");
    concat.writeln('option framerate 1000');
    final concatPath = p.join(
      outputDirectory.absolute.path,
      'subtitles.ffconcat',
    );
    await File(concatPath).writeAsString(concat.toString(), flush: true);
    onArtifact(concatPath);
    return PreciseSubtitleAssets(
      concatPath: concatPath,
      frameCount: renderedFrames.length,
    );
  }

  Future<List<SubtitleOverlayEntry>> _loadEntries(
    List<ComposeSceneEntry> entries,
    String? primaryLanguage,
    String? secondaryLanguage,
  ) async {
    final loaded = <SubtitleOverlayEntry>[];
    for (final entry in entries) {
      _throwIfCancelled();
      final image = await entry.imageLoader?.call();
      if (entry.imageLoader != null && (image == null || image.isEmpty)) {
        throw StateError('图像字幕 ${entry.index ?? ''} 加载失败');
      }
      loaded.add(
        SubtitleOverlayEntry(
          language: primaryLanguage,
          secondaryLanguage: secondaryLanguage,
          index: entry.index,
          text: entry.text,
          secondaryText: entry.secondaryText,
          image: image,
        ),
      );
    }
    return loaded;
  }

  String _escapeConcatPath(String path) =>
      path.replaceAll('\\', '/').replaceAll("'", r"'\''");
  void _throwIfCancelled() {
    if (_cancelled) throw StateError('视频合成已取消');
  }
}

/// Reuse one offscreen tree while capturing the exact playback overlay widget.
class _PreciseWidgetSurface {
  final int width, height;
  late final double supersample;
  late final Size size;
  final PipelineOwner pipelineOwner = PipelineOwner();
  final BuildOwner buildOwner = BuildOwner(focusManager: FocusManager());
  final RenderRepaintBoundary boundary = RenderRepaintBoundary();
  late final RenderView renderView;
  RenderObjectToWidgetElement<RenderBox>? rootElement;

  _PreciseWidgetSurface(this.width, this.height) {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final dpr = math.max(1.0, view.devicePixelRatio);
    // Bound supersampling memory on high-DPI 4K devices without reducing the
    // requested output resolution. Normal-size canvases keep the view's DPR.
    final maxScale = math.min(
      8192.0 / math.max(width, height),
      math.sqrt(16 * 1024 * 1024 / (width * height)),
    );
    supersample = math.max(1.0, math.min(dpr, maxScale));
    size = Size(width.toDouble(), height.toDouble());
    renderView = RenderView(
      view: view,
      configuration: ViewConfiguration(
        logicalConstraints: BoxConstraints.tight(size),
        physicalConstraints: BoxConstraints.tight(size * supersample),
        devicePixelRatio: supersample,
      ),
      child: boundary,
    );
    renderView.attach(pipelineOwner);
    renderView.prepareInitialFrame();
  }

  Future<Uint8List> render({
    required List<SubtitleOverlayEntry> entries,
    required SubtitleStyle style,
    required SubtitleDebugPreset? subtitlePreset,
    required Alignment alignment,
    required double itemGap,
    required bool presetPositionOverride,
  }) async {
    final rootWidget = Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: MediaQueryData(size: size, devicePixelRatio: supersample),
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: SubtitleOverlayGroup(
            enableDebugPreview: false,
            presetOverride: subtitlePreset,
            entries: entries,
            style: SubtitleLayout.forVideoExport(style),
            referenceHeight: size.height,
            alignment: alignment,
            itemGap: itemGap,
            isVisualOnly: true,
            presetPositionOverride: presetPositionOverride,
          ),
        ),
      ),
    );
    final root = rootElement = RenderObjectToWidgetAdapter<RenderBox>(
      container: boundary,
      child: rootWidget,
    ).attachToRenderTree(buildOwner, rootElement);
    buildOwner.buildScope(root);
    for (final entry in entries) {
      if (entry.image != null) {
        Object? imageError;
        await precacheImage(
          MemoryImage(entry.image!),
          root,
          onError: (error, _) => imageError = error,
        );
        if (imageError != null) throw StateError('图像字幕解码失败：$imageError');
      }
    }
    buildOwner.buildScope(root);
    pipelineOwner.flushLayout();
    pipelineOwner.flushCompositingBits();
    pipelineOwner.flushPaint();
    buildOwner.finalizeTree();
    ui.Image? image;
    ui.Image? outputImage;
    try {
      image = await boundary.toImage(pixelRatio: supersample);
      if (supersample > 1.0001) {
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder).drawImageRect(
          image,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          Offset.zero & size,
          ui.Paint()..filterQuality = ui.FilterQuality.high,
        );
        final picture = recorder.endRecording();
        try {
          outputImage = await picture.toImage(width, height);
        } finally {
          picture.dispose();
        }
      } else {
        outputImage = image;
      }
      final data = await outputImage.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('精确字幕图像编码失败');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      if (outputImage != null && !identical(outputImage, image)) {
        outputImage.dispose();
      }
      image?.dispose();
    }
  }

  void dispose() {
    if (rootElement != null) {
      rootElement = RenderObjectToWidgetAdapter<RenderBox>(
        container: boundary,
      ).attachToRenderTree(buildOwner, rootElement);
      buildOwner.buildScope(rootElement!);
      buildOwner.finalizeTree();
    }
    renderView.detach();
    buildOwner.focusManager.dispose();
    pipelineOwner.dispose();
  }
}
