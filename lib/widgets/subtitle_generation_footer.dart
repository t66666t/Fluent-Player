import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/subtitle_model.dart';
import '../models/subtitle_stream.dart';
import '../models/transcription_progress.dart';
import '../services/media_playback_service.dart';
import '../services/ocr_subtitle_manager.dart';
import '../services/transcription_manager.dart';
import 'stable_width_label.dart';
import 'sidebar_activity.dart';

typedef _GenerationHint = ({
  String generation,
  String title,
  Duration completed,
  Duration total,
});

/// A quiet, non-selectable tail slot. Consumers may reserve its extent when
/// hidden to keep the last caption and reading anchor in place.
class SubtitleGenerationFooter extends StatefulWidget {
  const SubtitleGenerationFooter({
    super.key,
    required this.primary,
    this.secondary = const [],
    this.showPrimary = true,
    this.showSecondary = true,
    this.reserveSpaceWhenHidden = true,
    this.onExtentChanged,
  });

  static const double extent = 48;
  static bool availableIn(BuildContext context) =>
      context.read<MediaPlaybackService?>() != null &&
      (context.read<TranscriptionManager?>() != null ||
          context.read<OcrSubtitleManager?>() != null);
  final List<SubtitleItem> primary, secondary;
  final bool showPrimary, showSecondary;

  /// Keep an empty tail slot while the hint is hidden; otherwise reclaim it.
  final bool reserveSpaceWhenHidden;

  /// Report layout changes after the frame so an indexed transcript can update
  /// its fit calculation without subscribing to every generation progress tick.
  final ValueChanged<double>? onExtentChanged;

  @override
  State<SubtitleGenerationFooter> createState() =>
      _SubtitleGenerationFooterState();
}

class _SubtitleGenerationFooterState extends State<SubtitleGenerationFooter> {
  MediaPlaybackService? _playback;
  TranscriptionManager? _manager;
  OcrSubtitleManager? _ocr;
  _GenerationHint? _hint;
  double? _reportedExtent;
  bool _extentNotificationScheduled = false;
  bool _active = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind();
  }

  @override
  void didUpdateWidget(covariant SubtitleGenerationFooter oldWidget) {
    super.didUpdateWidget(oldWidget);
    _bind();
  }

  void _bind() {
    final playback = context.read<MediaPlaybackService?>();
    final manager = context.read<TranscriptionManager?>();
    final ocr = context.read<OcrSubtitleManager?>();
    final active = SidebarActivity.of(context);
    if (!identical(playback, _playback) ||
        !identical(manager, _manager) ||
        !identical(ocr, _ocr) ||
        active != _active) {
      _detach();
      _playback = playback;
      _manager = manager;
      _ocr = ocr;
      _active = active;
      if (_active) {
        _playback?.addListener(_refresh);
        _manager?.addListener(_refresh);
        _manager?.subtitleFilesRevision.addListener(_refresh);
        _ocr?.addListener(_refresh);
        _ocr?.subtitleFilesRevision.addListener(_refresh);
      }
    }
    if (_active) _hint = _resolve();
  }

  void _detach() {
    _playback?.removeListener(_refresh);
    _manager?.removeListener(_refresh);
    _manager?.subtitleFilesRevision.removeListener(_refresh);
    _ocr?.removeListener(_refresh);
    _ocr?.subtitleFilesRevision.removeListener(_refresh);
  }

  bool _shows(List<SubtitleItem> visible, List<SubtitleItem> generated) =>
      visible.isNotEmpty &&
      visible.length <= generated.length &&
      identical(visible.first, generated.first) &&
      identical(visible.last, generated[visible.length - 1]);

  bool _selected(SubtitleStreamUpdate stream) {
    final paths = _playback!.subtitlePaths;
    bool selected(int role, List<SubtitleItem> cues) {
      if (role >= paths.length) return false;
      final path = paths[role];
      return path == stream.primaryPath && _shows(cues, stream.primary) ||
          path == stream.secondaryPath && _shows(cues, stream.secondary);
    }

    return widget.showPrimary && selected(0, widget.primary) ||
        widget.showSecondary && selected(1, widget.secondary);
  }

  _GenerationHint? _resolve() => _transcriptionHint() ?? _ocrHint();

  _GenerationHint? _transcriptionHint() {
    final playback = _playback, manager = _manager;
    final item = playback?.currentItem;
    if (playback == null || manager == null || item == null) return null;
    final stream =
        manager.streamForVideo(item.path, videoId: item.id) ??
        manager.streamForVideo(item.path);
    if (stream == null ||
        stream.phase != SubtitleStreamPhase.generating ||
        !manager.isVideoRunning(stream.videoPath, videoId: stream.videoId) ||
        manager.isVideoStopping(stream.videoPath, videoId: stream.videoId)) {
      return null;
    }
    if (!_selected(stream)) return null;
    final audio = manager.localAudioProgress;
    final total =
        audio?.total ??
        (playback.duration > Duration.zero
            ? playback.duration
            : Duration(milliseconds: item.durationMs));
    return (
      generation: stream.generationId,
      title: stream.primaryComplete
          ? '正在翻译'
          : stream.secondaryPath != null
          ? '正在转录并翻译'
          : '正在转录',
      completed: Duration(
        seconds: (audio?.completed ?? stream.processedThrough).inSeconds,
      ),
      total: Duration(seconds: total.inSeconds),
    );
  }

  _GenerationHint? _ocrHint() {
    final playback = _playback, manager = _ocr;
    final item = playback?.currentItem, job = manager?.job;
    if (playback == null ||
        manager == null ||
        item == null ||
        job == null ||
        !job.isRunning ||
        (job.videoId != item.id && job.videoPath != item.path)) {
      return null;
    }
    for (final stream in manager.subtitleStreams) {
      if (stream.phase != SubtitleStreamPhase.generating ||
          (stream.videoId != item.id && stream.videoPath != item.path) ||
          !_selected(stream)) {
        continue;
      }
      final total = job.end - job.start;
      if (total <= Duration.zero) return null;
      final progress = job.recognitionProgress;
      // Regional positions are relative to the selected range. A bilingual
      // task has only covered a time span once its slower region has too.
      final completed = progress != null && progress.completedByTrack.isNotEmpty
          ? progress.completedByTrack.values.reduce((a, b) => a < b ? a : b)
          : stream.processedThrough - job.start;
      return (
        generation: stream.generationId,
        title: '正在识别字幕',
        completed: Duration(
          seconds: completed.inSeconds.clamp(0, total.inSeconds),
        ),
        total: Duration(seconds: total.inSeconds),
      );
    }
    return null;
  }

  void _refresh() {
    if (!mounted || !_active) return;
    final next = _resolve();
    if (_hint == next) return;
    setState(() => _hint = next);
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hint = _hint;
    _reportExtentAfterLayout();
    if (hint == null) {
      if (!widget.reserveSpaceWhenHidden) return const SizedBox.shrink();
      return const SizedBox(
        width: double.infinity,
        height: SubtitleGenerationFooter.extent,
      );
    }
    final audio = TranscriptionAudioProgress(
      completed: hint.completed,
      total: hint.total,
    );
    final title = hint.title;
    final text = '$title · ${audio.timeLabel}';
    final color = Colors.white.withValues(
      alpha: MediaQuery.highContrastOf(context) ? .92 : .72,
    );
    return SizedBox(
      width: double.infinity,
      height: SubtitleGenerationFooter.extent,
      child: RepaintBoundary(
        child: SelectionContainer.disabled(
          child: IgnorePointer(
            child: Semantics(
              label: text,
              child: ExcludeSemantics(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: StableWidthLabel(
                        text,
                        variants: [
                          for (final width in audio.widthVariants)
                            width.replaceFirst('已完成 ', '$title · '),
                        ],
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.4,
                          fontWeight: FontWeight.w400,
                          color: color,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _reportExtentAfterLayout() {
    if (widget.onExtentChanged == null || _extentNotificationScheduled) return;
    final extent = _hint == null && !widget.reserveSpaceWhenHidden
        ? 0.0
        : SubtitleGenerationFooter.extent;
    if (extent == _reportedExtent) return;
    _extentNotificationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _extentNotificationScheduled = false;
      if (!mounted) return;
      final currentExtent = _hint == null && !widget.reserveSpaceWhenHidden
          ? 0.0
          : SubtitleGenerationFooter.extent;
      if (currentExtent == _reportedExtent) return;
      _reportedExtent = currentExtent;
      widget.onExtentChanged?.call(currentExtent);
    });
  }
}
