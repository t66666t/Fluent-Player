import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'sidebar_activity.dart';
import 'landscape_sidebar_layout.dart';
import 'package:provider/provider.dart';

import '../models/ocr_subtitle_models.dart';
import '../models/video_item.dart';
import '../models/media_source_ref.dart';
import '../features/media_cache/media_cache_models.dart';
import '../services/library_service.dart';
import '../services/media_materialization_service.dart';
import '../services/ocr_subtitle_manager.dart';
import 'operation_status.dart';
import 'ocr_region_editor.dart';
import 'ocr_models_pane.dart';
import '../services/ocr_model_manager.dart';
import 'ocr_region_preview.dart';
import 'ocr_time_range_dialog.dart';
import 'ocr_compute_settings.dart';
import 'ocr_keep_awake_action.dart';
import 'ocr_video_quality_field.dart';
import 'media_materialization_progress_card.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

class OcrSubtitlePanel extends StatefulWidget {
  final VideoItem videoItem;
  final Duration duration;
  final Duration Function() currentPosition;
  final Future<bool> Function() pauseForRegionSelection;
  final Future<void> Function(bool wasPlaying) restorePlayback;
  final VoidCallback onBack;
  final Future<void> Function(List<String> paths) onCompleted;

  const OcrSubtitlePanel({
    super.key,
    required this.videoItem,
    required this.duration,
    required this.currentPosition,
    required this.pauseForRegionSelection,
    required this.restorePlayback,
    required this.onBack,
    required this.onCompleted,
  });

  @override
  State<OcrSubtitlePanel> createState() => _OcrSubtitlePanelState();
}

class _OcrSubtitlePanelState extends State<OcrSubtitlePanel> {
  late List<OcrSubtitleTrack> _tracks;
  bool _customRange = false;
  late double _startMs;
  late double _endMs;
  double? _rangePointerX;
  bool _modelInstalled = false;
  bool _modelsTab = false;
  String? _focusedModelId;
  int? _modelDetailsTrackIndex;
  List<OcrModelPreset> _presets = const [];
  Duration? _estimate;
  bool _hasDurationMeasurements = false;
  int _estimateRevision = 0;
  final Map<String, Future<bool>> _modelChecks = {};
  String? _previewPath;
  String? _deliveredPath;
  bool _tracksEditedInThisPanel = false;
  bool _preparingOnlineFrame = false;
  MediaMaterializationProgress? _preparationProgress;
  String? _preparationError;
  Completer<void>? _preparationCancellation;
  List<CacheQuality> _videoQualities = const [];
  String? _videoQualityId;
  bool _qualityEdited = false;
  String? _qualityError;
  bool _loadingQualities = false;
  bool _confirmingOnlineDownload = false;
  bool _startingOcr = false;
  bool _validateModelSelection = false;
  bool _diagnosticsExpanded = false;
  final _modelFieldKeys = <int, GlobalKey>{};
  final _modelFocusNodes = <int, FocusNode>{};
  final _diagnosticScrollController = ScrollController(keepScrollOffset: false);
  ({String title, String message, String? details})? _panelFailure;

  void _showProblem(String title, String message, {Object? error}) {
    if (!mounted) return;
    setState(() {
      _diagnosticsExpanded = false;
      _panelFailure = (
        title: title,
        message: error == null
            ? message
            : operationErrorSummary(error, fallback: message),
        details: error == null ? null : safeOperationDiagnostic(error),
      );
    });
  }

  int _qualityRevision = 0;
  Future<void>? _qualityLoad;
  late final OcrSubtitleManager _manager;
  final _progressScrollController = ScrollController();
  (String?, OcrSubtitleJobStatus?, String)? _lastManagerLayoutState;

  @override
  void initState() {
    super.initState();
    _manager = context.read<OcrSubtitleManager>();
    _tracks = List<OcrSubtitleTrack>.from(
      _manager.tracksForVideo(widget.videoItem.id),
    );
    _startMs = 0;
    _endMs = widget.duration.inMilliseconds.toDouble().clamp(
      1,
      double.infinity,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _manager.addListener(_onManagerChanged);
      _manager.modelManager.center.addListener(_onModelsChanged);
      unawaited(_loadPresets());
      _refreshModelAndEstimate();
      _onManagerChanged();
      if (_needsOnlineMaterialization) unawaited(_loadVideoQualities());
    });
  }

  bool _visuallyActive = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visuallyActive = SidebarActivity.of(context);
  }

  @override
  void didUpdateWidget(covariant OcrSubtitlePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoItem.id != widget.videoItem.id) {
      final cancellation = _preparationCancellation;
      if (cancellation != null && !cancellation.isCompleted) {
        cancellation.complete();
      }
      _startMs = 0;
      _endMs = widget.duration.inMilliseconds.toDouble();
      _customRange = false;
      _estimate = null;
      _deliveredPath = null;
      _tracks = List<OcrSubtitleTrack>.from(
        _manager.tracksForVideo(widget.videoItem.id),
      );
      _tracksEditedInThisPanel = false;
      _panelFailure = null;
      _validateModelSelection = false;
      _diagnosticsExpanded = false;
      _focusedModelId = null;
      _modelDetailsTrackIndex = null;
      _preparingOnlineFrame = false;
      _preparationProgress = null;
      _preparationError = null;
      _preparationCancellation = null;
      _qualityRevision++;
      _qualityLoad = null;
      _videoQualities = const [];
      _videoQualityId = null;
      _qualityEdited = false;
      _qualityError = null;
      _loadingQualities = false;
      if (_needsOnlineMaterialization) unawaited(_loadVideoQualities());
      final previousPath = _previewPath;
      _previewPath = null;
      unawaited(_manager.deletePreview(previousPath));
      unawaited(_refreshModelAndEstimate());
    } else if (oldWidget.duration != widget.duration) {
      _startMs = _startMs.clamp(0, widget.duration.inMilliseconds.toDouble());
      _endMs = _customRange
          ? _endMs.clamp(_startMs, widget.duration.inMilliseconds.toDouble())
          : widget.duration.inMilliseconds.toDouble();
      unawaited(_refreshModelAndEstimate());
    }
  }

  @override
  void dispose() {
    // 面板关闭不再取消素材下载：下载已登记在全局任务注册表中，
    // 会继续在后台完成并沉淀为可复用缓存；重新进入面板或打开合成页时，
    // 通过任务快照恢复进度显示。切换视频（didUpdateWidget）仍会取消，
    // 因为继续下载的是旧卡片的素材。
    _manager.removeListener(_onManagerChanged);
    _manager.modelManager.center.removeListener(_onModelsChanged);
    _progressScrollController.dispose();
    _diagnosticScrollController.dispose();
    for (final node in _modelFocusNodes.values) {
      node.dispose();
    }
    unawaited(_manager.deletePreview(_previewPath));
    super.dispose();
  }

  void _onManagerChanged() {
    if (!mounted) return;
    final job = _manager.job;
    if (job?.videoId == widget.videoItem.id &&
        job?.status == OcrSubtitleJobStatus.downloading) {
      // A previously missing model becomes ready during the job. Re-check
      // only after installation, never on range-slider updates.
      for (final track in job!.tracks) {
        _modelChecks.remove('${track.language.name}:${track.modelId}');
      }
    }
    if (job?.videoId == widget.videoItem.id &&
        job?.status == OcrSubtitleJobStatus.completed &&
        job?.outputPaths.isNotEmpty == true) {
      final completedPaths = _manager.consumeCompletedPaths(
        widget.videoItem.id,
      );
      if (completedPaths != null && completedPaths.isNotEmpty) {
        unawaited(_refreshModelAndEstimate());
        final deliveryKey = completedPaths.join('|');
        if (_deliveredPath != deliveryKey) {
          _deliveredPath = deliveryKey;
          if (!_manager.streamingPlaybackAttached) {
            widget.onCompleted(completedPaths);
          }
        }
      }
    }
    final latestTracks = _manager.tracksForVideo(widget.videoItem.id);
    final layoutState = (
      job?.videoId,
      job?.status,
      _manager.computePreferences.signature,
    );
    // Recognition ticks update the pinned footer directly. Rebuilding region
    // previews, selectors and sliders for each tick can itself trigger the
    // frame-pressure limiter on a phone.
    if (job?.isRunning == true &&
        layoutState == _lastManagerLayoutState &&
        (_tracksEditedInThisPanel ||
            _sameTrackSettings(_tracks, latestTracks))) {
      return;
    }
    _lastManagerLayoutState = layoutState;
    if (!_tracksEditedInThisPanel) {
      _tracks = List<OcrSubtitleTrack>.from(latestTracks);
    }
    if (_visuallyActive) setState(() {});
  }

  bool _sameTrackSettings(
    List<OcrSubtitleTrack> left,
    List<OcrSubtitleTrack> right,
  ) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      final a = left[index];
      final b = right[index];
      // Defaults may return fresh objects with identical settings. Compare
      // their values so progress and header controls stay isolated from them.
      if (a.number != b.number ||
          a.language != b.language ||
          a.modelId != b.modelId ||
          a.modelIdentity != b.modelIdentity ||
          a.region.rect != b.region.rect) {
        return false;
      }
    }
    return true;
  }

  Future<void> _refreshModelAndEstimate() async {
    final revision = ++_estimateRevision;
    final videoId = widget.videoItem.id;
    await _manager.initialize();
    if (!mounted || revision != _estimateRevision) return;
    if (!_tracksEditedInThisPanel) {
      _tracks = List<OcrSubtitleTrack>.from(_manager.tracksForVideo(videoId));
    }
    final tracks = List<OcrSubtitleTrack>.from(_tracks);
    final modelChecks = Future.wait(
      tracks.map(
        (track) => _modelChecks.putIfAbsent(
          '${track.language.name}:${track.modelId}',
          () => _manager.isTrackModelInstalled(track),
        ),
      ),
    );
    final estimate = await _manager.estimateDuration(
      mediaDuration: widget.duration,
      start: _customRange
          ? Duration(milliseconds: _startMs.round())
          : Duration.zero,
      end: _customRange
          ? Duration(milliseconds: _endMs.round())
          : widget.duration,
      trackCount: tracks.length,
      tracks: tracks,
      videoId: videoId,
    );
    if (mounted && revision == _estimateRevision) {
      setState(() {
        _estimate = estimate;
        _hasDurationMeasurements = _manager.hasDurationMeasurements(
          videoId,
          tracks,
        );
      });
    }
    final installedStates = await modelChecks;
    if (mounted && revision == _estimateRevision) {
      setState(() {
        _modelInstalled = installedStates.every((installed) => installed);
      });
    }
  }

  Future<void> _loadPresets() async {
    try {
      final models = await _manager.modelManager.presets();
      if (mounted) setState(() => _presets = models);
    } catch (e) {
      debugPrint('OCR catalog: $e');
    }
  }

  void _onModelsChanged() {
    _modelChecks.clear();
    if (mounted) unawaited(_refreshModelAndEstimate());
  }

  void _changeRange(RangeValues values) {
    final maximum = widget.duration.inMilliseconds.toDouble().clamp(
      1,
      double.infinity,
    );
    var start = values.start.roundToDouble().clamp(0, maximum - 1).toDouble();
    var end = values.end.roundToDouble().clamp(1, maximum).toDouble();
    // Keep a positive range even when the handles overlap on screen.
    if (start >= end) {
      if (values.start != _startMs) {
        start = end - 1;
      } else {
        end = start + 1;
      }
    }
    setState(() {
      _startMs = start;
      _endMs = end;
    });
  }

  Future<void> _editRange() async {
    if (_manager.isRunning || widget.duration <= Duration.zero) return;
    final videoId = widget.videoItem.id;
    final duration = widget.duration;
    final values = await showDialog<RangeValues>(
      context: context,
      builder: (_) => OcrTimeRangeDialog(
        duration: duration,
        values: RangeValues(_startMs, _endMs),
      ),
    );
    if (!mounted ||
        values == null ||
        !_customRange ||
        _manager.isRunning ||
        widget.videoItem.id != videoId ||
        widget.duration != duration) {
      return;
    }
    _changeRange(values);
    unawaited(_refreshModelAndEstimate());
  }

  Thumb? _selectRangeThumb(
    TextDirection direction,
    RangeValues values,
    double tapValue,
    Size thumbSize,
    Size trackSize,
    double dx,
  ) {
    // Flutter starts a fast drag after the pointer has already moved. Use the
    // original press to keep a nearby handle from being selected by mistake.
    final pointerX = _rangePointerX;
    final trackWidth = trackSize.width - thumbSize.width;
    if (pointerX != null && trackWidth > 0) {
      final visualValue = ((pointerX - thumbSize.width / 2) / trackWidth).clamp(
        0.0,
        1.0,
      );
      tapValue = direction == TextDirection.ltr ? visualValue : 1 - visualValue;
    }
    // Select the closest handle even when their touch targets overlap.
    // Only coincident handles need the drag direction to disambiguate them.
    if (values.start == values.end) {
      if (dx == 0) return null;
      return (dx > 0) == (direction == TextDirection.ltr)
          ? Thumb.end
          : Thumb.start;
    }
    return (tapValue - values.start).abs() < (tapValue - values.end).abs()
        ? Thumb.start
        : Thumb.end;
  }

  void _choosePreset(OcrModelPreset model) {
    if (_manager.isRunning || _startingOcr) return;
    final selectedLanguages = {
      for (final (index, track) in _tracks.indexed)
        if ((_modelDetailsTrackIndex == null ||
                index == _modelDetailsTrackIndex) &&
            model.supports(track.language))
          track.language,
    };
    setState(() {
      _tracks = [
        for (final (index, track) in _tracks.indexed)
          (_modelDetailsTrackIndex == null ||
                      index == _modelDetailsTrackIndex) &&
                  model.supports(track.language)
              ? track.copyWith(
                  modelId: model.id,
                  modelIdentity: _manager.modelManager.center.loaded
                      ? _manager.modelManager.identity(model)
                      : '',
                )
              : track,
      ];
      _tracksEditedInThisPanel = true;
      _modelsTab = false;
      _focusedModelId = null;
      _modelDetailsTrackIndex = null;
    });
    for (final language in selectedLanguages) {
      unawaited(_manager.rememberModelSelection(language, model.id));
    }
    _manager.rememberTracks(widget.videoItem.id, _tracks);
    _onModelsChanged();
  }

  void _showModelDetails(OcrModelPreset model, int index) {
    setState(() {
      _focusedModelId = model.id;
      _modelDetailsTrackIndex = index;
      _modelsTab = true;
    });
  }

  Widget _modelChoiceLabel(
    OcrModelPreset model,
    int index, {
    bool dismissMenu = false,
  }) => Row(
    children: [
      Expanded(
        child: Text(
          '${model.name}${_manager.modelManager.ready(model) ? '' : ' · 待下载'}',
          overflow: TextOverflow.ellipsis,
        ),
      ),
      DesktopButtonClickRegion(
        child: IconButton(
          key: ValueKey(
            'ocr-model-info-$index-${model.id}${dismissMenu ? '-menu' : ''}',
          ),
          tooltip: '查看 ${model.name} 详情',
          constraints: const BoxConstraints.tightFor(width: 32, height: 32),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.info_outline_rounded, size: 17),
          onPressed: () {
            if (dismissMenu) Navigator.of(context).pop();
            _showModelDetails(model, index);
          },
        ),
      ),
    ],
  );

  Widget _modelSelector(int index, {required bool running}) {
    final track = _tracks[index];
    final models = _presets
        .where(
          (model) =>
              model.supports(track.language) &&
              (!model.legacy || _manager.modelManager.ready(model)),
        )
        .toList();
    final missing =
        _validateModelSelection && !_modelInstalled && track.modelId.isEmpty;
    final errorColor = Theme.of(context).colorScheme.error;
    return KeyedSubtree(
      key: _modelFieldKeys.putIfAbsent(index, GlobalKey.new),
      child: DropdownButtonFormField<String>(
        key: ValueKey('ocr-model-choice-${index}_${track.modelId}'),
        focusNode: _modelFocusNodes.putIfAbsent(index, FocusNode.new),
        initialValue: models.any((model) => model.id == track.modelId)
            ? track.modelId
            : '',
        dropdownColor: const Color(0xFF252930),
        isExpanded: true,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          labelText: missing ? '识别模型（必选）' : '识别模型',
          labelStyle: missing ? TextStyle(color: errorColor) : null,
          isDense: true,
          border: const OutlineInputBorder(),
          enabledBorder: missing
              ? OutlineInputBorder(borderSide: BorderSide(color: errorColor))
              : null,
          focusedBorder: missing
              ? OutlineInputBorder(
                  borderSide: BorderSide(color: errorColor, width: 2),
                )
              : null,
        ),
        selectedItemBuilder: (_) => [
          const Text('请选择模型（旧版已安装可复用）', overflow: TextOverflow.ellipsis),
          for (final model in models) _modelChoiceLabel(model, index),
        ],
        items: [
          const DropdownMenuItem(
            value: '',
            child: Text('请选择模型（旧版已安装可复用）', overflow: TextOverflow.ellipsis),
          ),
          for (final model in models)
            DropdownMenuItem(
              value: model.id,
              child: _modelChoiceLabel(model, index, dismissMenu: true),
            ),
        ],
        onChanged: running
            ? null
            : (value) {
                if (value == null) return;
                setState(() {
                  _tracks[index] = track.copyWith(
                    modelId: value,
                    modelIdentity:
                        value.isNotEmpty && _manager.modelManager.center.loaded
                        ? _manager.modelManager.identity(
                            models.firstWhere((m) => m.id == value),
                          )
                        : '',
                  );
                  _tracksEditedInThisPanel = true;
                });
                unawaited(
                  _manager.rememberModelSelection(track.language, value),
                );
                _manager.rememberTracks(widget.videoItem.id, _tracks);
                _onModelsChanged();
              },
      ),
    );
  }

  void _deleteTrack(int index) {
    if (_manager.isRunning || _tracks.length <= 1) return;
    final remaining = List<OcrSubtitleTrack>.from(_tracks)..removeAt(index);
    setState(() {
      _tracks = [
        for (final (index, track) in remaining.indexed)
          track.copyWith(number: index + 1),
      ];
      _tracksEditedInThisPanel = true;
    });
    _manager.rememberTracks(widget.videoItem.id, _tracks);
    unawaited(_refreshModelAndEstimate());
  }

  bool get _needsOnlineMaterialization => itemNeedsOnlineMaterialization(
    source: widget.videoItem.sourceRef,
    path: widget.videoItem.path,
  );

  Future<void> _loadVideoQualities() => _qualityLoad ??= _fetchVideoQualities();

  Future<void> _fetchVideoQualities() async {
    final revision = ++_qualityRevision;
    final item = widget.videoItem;
    setState(() {
      _loadingQualities = true;
      _qualityError = null;
    });
    try {
      await _manager.initialize();
      final seen = <String>{};
      final qualities =
          (await _manager.library.onlineVideoMaterializationQualities(
            item.id,
          )).where((q) => q.available && seen.add(q.id)).toList();
      if (!mounted || revision != _qualityRevision) return;
      if (qualities.isEmpty) throw StateError('当前账号没有可下载的完整视频画质');
      final selected = defaultOcrVideoQuality(
        qualities,
        preferredId:
            _manager.videoQualityFor(item.id) ??
            item.sourceRef?.cloudDrive?.preferredQuality,
        preferOriginal: item.sourceRef?.cloudDrive != null,
      );
      setState(() {
        _videoQualities = qualities;
        _videoQualityId = selected.id;
        _qualityEdited = _manager.videoQualityFor(item.id) != null;
      });
    } catch (error) {
      if (mounted && revision == _qualityRevision) {
        setState(() {
          _videoQualities = const [];
          _videoQualityId = null;
          _qualityError = operationErrorSummary(
            error,
            fallback: '无法获取视频画质，请检查网络后重试。',
          );
        });
      }
    } finally {
      if (mounted && revision == _qualityRevision) {
        setState(() => _loadingQualities = false);
        _qualityLoad = null;
      }
    }
  }

  void _changeVideoQuality(String id) {
    if (_manager.isRunning ||
        _preparingOnlineFrame ||
        _confirmingOnlineDownload ||
        _startingOcr) {
      return;
    }
    final previousPath = _previewPath;
    setState(() {
      _videoQualityId = id;
      _qualityEdited = true;
      _previewPath = null;
      _preparationProgress = null;
      _preparationError = null;
    });
    _manager.rememberVideoQuality(widget.videoItem.id, id);
    unawaited(_manager.deletePreview(previousPath));
  }

  Future<void> _selectRegion() async {
    if (_preparingOnlineFrame || _manager.isRunning || _startingOcr) return;
    if (!await _confirmOnlineVideoDownload()) return;
    if (!mounted) return;
    final item = widget.videoItem;
    final restorePlayback = widget.restorePlayback;
    final videoQualityId = _videoQualityId;
    final online = itemNeedsOnlineMaterialization(
      source: widget.videoItem.sourceRef,
      path: widget.videoItem.path,
    );
    final cancellation = Completer<void>();
    if (online && mounted) {
      setState(() {
        _preparingOnlineFrame = true;
        _preparationError = null;
        _preparationProgress = MediaMaterializationProgress(
          stage: MediaMaterializationStage.resolving,
          progress: 0,
          message:
              isCloudDriveMedia(
                source: widget.videoItem.sourceRef,
                path: widget.videoItem.path,
              )
              ? '正在准备网盘视频素材'
              : (widget.videoItem.sourceRef?.podcast != null
                    ? '正在准备播客视频素材'
                    : '正在准备 Bilibili 视频素材'),
        );
        _preparationCancellation = cancellation;
      });
    }
    var wasPlaying = false;
    var paused = false;
    String? capturedPath;
    try {
      wasPlaying = await widget.pauseForRegionSelection();
      paused = true;
      if (!mounted || widget.videoItem.id != item.id) return;
      final initialPosition = widget.currentPosition();
      final path = await _manager.captureFrame(
        videoId: item.id,
        videoPath: item.path,
        videoQualityId: videoQualityId,
        position: initialPosition,
        mirrorHorizontal: item.isVideoMirroredH,
        mirrorVertical: item.isVideoMirroredV,
        cancelSignal: online ? cancellation.future : null,
        onProgress: online
            ? (value) {
                if (!mounted || widget.videoItem.id != item.id) return;
                setState(() => _preparationProgress = value);
              }
            : null,
      );
      capturedPath = path;
      if (!mounted || widget.videoItem.id != item.id) return;
      final result = await showOcrRegionEditor(
        context,
        framePath: path,
        initialRegions: _tracks.map((track) => track.region).toList(),
        duration: widget.duration,
        initialPosition: initialPosition,
        loadFrameAt: (position) => _manager.captureFrame(
          videoId: item.id,
          videoPath: item.path,
          videoQualityId: videoQualityId,
          position: position,
          mirrorHorizontal: item.isVideoMirroredH,
          mirrorVertical: item.isVideoMirroredV,
          maxWidth: 960,
        ),
        loadFastFrameAt: (position) => _manager.captureFrame(
          videoId: item.id,
          videoPath: item.path,
          videoQualityId: videoQualityId,
          position: position,
          mirrorHorizontal: item.isVideoMirroredH,
          mirrorVertical: item.isVideoMirroredV,
          maxWidth: 480,
          fastPreview: true,
        ),
        releaseFrame: _manager.deletePreview,
      );
      if (result != null && mounted && widget.videoItem.id == item.id) {
        final previousPath = _previewPath;
        final updatedTracks = _manualTracksForRegions(result);
        setState(() {
          _tracks = updatedTracks;
          _tracksEditedInThisPanel = true;
          _previewPath = path;
        });
        _manager.rememberTracks(widget.videoItem.id, updatedTracks);
        unawaited(_refreshModelAndEstimate());
        capturedPath = null;
        unawaited(_manager.deletePreview(previousPath));
      }
    } catch (error) {
      if (mounted && online && widget.videoItem.id == item.id) {
        setState(
          () => _preparationError = operationErrorSummary(
            error,
            fallback: '无法准备字幕预览画面，请检查媒体来源后重试。',
          ),
        );
      }
      if (mounted && widget.videoItem.id == item.id) {
        _showProblem('无法打开字幕区域', '无法读取预览画面，请检查媒体文件和识别时间后重试。', error: error);
      }
    } finally {
      if (mounted && online && widget.videoItem.id == item.id) {
        setState(() {
          _preparingOnlineFrame = false;
          _preparationCancellation = null;
          if (_preparationError == null) _preparationProgress = null;
        });
      }
      await _manager.deletePreview(capturedPath);
      if (paused && widget.videoItem.id == item.id) {
        await restorePlayback(wasPlaying);
      }
    }
  }

  List<OcrSubtitleTrack> _manualTracksForRegions(
    List<NormalizedOcrRegion> regions,
  ) {
    final available = <int>{
      for (var index = 0; index < _tracks.length; index++) index,
    };
    final fallbackLanguage = _tracks.isEmpty
        ? OcrSubtitleLanguage.chinese
        : _tracks.first.language;
    return <OcrSubtitleTrack>[
      for (var regionIndex = 0; regionIndex < regions.length; regionIndex++)
        () {
          var bestIndex = -1;
          var bestOverlap = 0.0;
          for (final trackIndex in available) {
            final overlap = regions[regionIndex].intersectionOverUnion(
              _tracks[trackIndex].region,
            );
            if (overlap > bestOverlap) {
              bestOverlap = overlap;
              bestIndex = trackIndex;
            }
          }
          if (bestIndex >= 0) available.remove(bestIndex);
          return OcrSubtitleTrack(
            number: regionIndex + 1,
            region: regions[regionIndex],
            modelId: bestIndex >= 0 && bestOverlap >= 0.12
                ? _tracks[bestIndex].modelId
                : _manager.rememberedModelIdFor(fallbackLanguage),
            language: bestIndex >= 0 && bestOverlap >= 0.12
                ? _tracks[bestIndex].language
                : fallbackLanguage,
          );
        }(),
    ];
  }

  Future<void> _start() async {
    if (_startingOcr || _preparingOnlineFrame) return;
    final missingIndex = _tracks.indexWhere((track) => track.modelId.isEmpty);
    if (!_modelInstalled && missingIndex >= 0) {
      final videoId = widget.videoItem.id;
      setState(() {
        _validateModelSelection = true;
        _panelFailure = null;
        _diagnosticsExpanded = false;
        _modelsTab = false;
      });
      // A form submission takes the user directly to the field that needs input.
      // Changing the field's border and label reserves its existing layout space.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || widget.videoItem.id != videoId) return;
      final fieldContext = _modelFieldKeys[missingIndex]?.currentContext;
      if (fieldContext != null && fieldContext.mounted) {
        await Scrollable.ensureVisible(
          fieldContext,
          alignment: .5,
          duration: const Duration(milliseconds: 180),
        );
        if (!mounted || widget.videoItem.id != videoId) return;
        _modelFocusNodes[missingIndex]?.requestFocus();
      }
      return;
    }
    setState(() {
      _startingOcr = true;
      _panelFailure = null;
      _diagnosticsExpanded = false;
    });
    try {
      await _startRequest();
    } finally {
      if (mounted) setState(() => _startingOcr = false);
    }
  }

  Future<void> _startRequest() async {
    if (_preparingOnlineFrame) return;
    if (_manager.isRunning) {
      _showProblem('已有画面字幕任务正在运行', '请等待当前任务完成，或先在任务状态中取消。');
      return;
    }
    if (!await _confirmOnlineVideoDownload()) return;
    if (!mounted) return;
    final start = _customRange
        ? Duration(milliseconds: _startMs.round())
        : Duration.zero;
    final end = _customRange
        ? Duration(milliseconds: _endMs.round())
        : widget.duration;
    if (end <= start) {
      _showProblem('识别时间范围无效', '请将结束时间设在开始时间之后。');
      return;
    }
    final request = OcrSubtitleJob(
      videoId: widget.videoItem.id,
      videoPath: widget.videoItem.path,
      videoQualityId: _requestVideoQualityId,
      tracks: List.unmodifiable(_tracks),
      start: start,
      end: end,
      mirrorHorizontal: widget.videoItem.isVideoMirroredH,
      mirrorVertical: widget.videoItem.isVideoMirroredV,
    );
    try {
      await _manager.start(request);
    } catch (error) {
      _showProblem('无法开始画面字幕识别', '请检查识别区域、模型和媒体文件后重试。', error: error);
    }
  }

  bool _canResumeAtQuality(String? qualityId) =>
      _manager.canResumeConfiguration(
        videoId: widget.videoItem.id,
        videoQualityId: qualityId,
        tracks: _tracks,
        start: _customRange
            ? Duration(milliseconds: _startMs.round())
            : Duration.zero,
        end: _customRange
            ? Duration(milliseconds: _endMs.round())
            : widget.duration,
        mirrorHorizontal: widget.videoItem.isVideoMirroredH,
        mirrorVertical: widget.videoItem.isVideoMirroredV,
      );

  // Opening a legacy interrupted job must not add a new fingerprint field
  // until the user actually changes its material quality.
  String? get _requestVideoQualityId =>
      !_qualityEdited && _canResumeAtQuality(null) ? null : _videoQualityId;

  Future<bool> _confirmOnlineVideoDownload() async {
    if (!itemNeedsOnlineMaterialization(
      source: widget.videoItem.sourceRef,
      path: widget.videoItem.path,
    )) {
      return true;
    }
    if (_confirmingOnlineDownload) return false;
    final videoId = widget.videoItem.id;
    setState(() => _confirmingOnlineDownload = true);
    try {
      if (_videoQualityId == null) await _loadVideoQualities();
      if (!mounted || widget.videoItem.id != videoId) return false;
      final qualityId = _videoQualityId;
      if (qualityId == null) throw StateError(_qualityError ?? '请先选择可下载的视频画质');
      final estimate = await _manager.library
          .estimateOnlineMediaMaterialization(
            videoId,
            MediaMaterializationRequirement.videoFrames,
            qualityId: qualityId,
          );
      if (!mounted || widget.videoItem.id != videoId) return false;
      if (!estimate.requiresVideoDownload) return true;
      final size = estimate.estimatedBytes == null
          ? '大小暂时无法确定'
          : '预计 ${LibraryService.formatSize(estimate.estimatedBytes!)}';
      final accepted =
          await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: const Text('需要下载 OCR 视频素材'),
              content: Text(
                'OCR 需要先下载 ${estimate.qualityLabel} 视频轨（$size）。\n\n'
                '该素材会归属于当前卡片，后续 OCR 和视频合成可复用。',
              ),
              actions: [
                DesktopButtonClickRegion(
                  child: TextButton(
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: const Text('取消'),
                  ),
                ),
                DesktopButtonClickRegion(
                  child: FilledButton(
                    onPressed: () => Navigator.pop(dialogContext, true),
                    child: const Text('下载并继续'),
                  ),
                ),
              ],
            ),
          ) ??
          false;
      return accepted && mounted && widget.videoItem.id == videoId;
    } catch (error) {
      if (mounted) {
        _showProblem('无法获取视频素材信息', '请检查网络和媒体来源后重试。', error: error);
      }
      return false;
    } finally {
      if (mounted) setState(() => _confirmingOnlineDownload = false);
    }
  }

  /// 全局素材任务的进度卡片：任何页面（合成、OCR、播放页后台补齐）发起的
  /// 下载在退出页面后仍在继续，重进面板时据此恢复进度显示。
  Widget _buildActiveTaskCard() {
    final materialization = context.read<MediaMaterializationService>();
    return ListenableBuilder(
      listenable: materialization,
      builder: (context, _) {
        final job = _manager.job;
        final jobDownloadingMaterial =
            job?.videoId == widget.videoItem.id &&
            job?.status == OcrSubtitleJobStatus.materializing;
        if (jobDownloadingMaterial) {
          // OCR 任务自身的素材下载已通过任务进度展示，避免重复卡片。
          return const SizedBox.shrink();
        }
        final task = materialization.activeTaskFor(widget.videoItem.id);
        if (task == null || task.stage == MediaMaterializationStage.completed) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: MediaMaterializationProgressCard(
            progress: task.toProgress(),
            onCancel: () =>
                unawaited(materialization.cancelActiveTask(task.itemId)),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final sidebarSize =
        MediaQuery.orientationOf(context) == Orientation.landscape
        ? Size(
            LandscapeSidebarLayout.functionalWidthFor(screenSize),
            screenSize.height,
          )
        : screenSize;
    final layout = LandscapeSidebarLayout.fromSize(sidebarSize);
    final managerJob = _manager.job;
    final running = (managerJob?.isRunning ?? false) || _startingOcr;
    return Container(
      color: const Color(0xFF17191D),
      child: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: layout.headerHeight,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: layout.horizontalPadding,
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final textScale =
                        MediaQuery.textScalerOf(context).scale(12) / 12;
                    return Row(
                      children: [
                        SizedBox.square(
                          dimension: layout.controlHeight,
                          child: DesktopButtonClickRegion(
                            child: IconButton(
                              padding: EdgeInsets.zero,
                              onPressed: widget.onBack,
                              icon: Icon(
                                Icons.arrow_back,
                                color: Colors.white,
                                size: layout.iconSize,
                              ),
                            ),
                          ),
                        ),
                        SizedBox(width: layout.isNarrow ? 2 : 6),
                        Expanded(
                          child: Text(
                            'OCR 字幕',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: layout.titleSize,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ListenableBuilder(
                          listenable: _manager.processingKeepAwake,
                          builder: (context, _) => OcrKeepAwakeAction(
                            key: const ValueKey('ocr-processing-keep-awake'),
                            checked: _manager.keepScreenAwakeDuringProcessing,
                            active: _manager.processingKeepAwake.isActive,
                            compact: constraints.maxWidth < 300 * textScale,
                            showLabel: constraints.maxWidth >= 200 * textScale,
                            height: layout.controlHeight,
                            onChanged: (value) => unawaited(
                              _manager.setKeepScreenAwakeDuringProcessing(
                                value,
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
            const Divider(color: Colors.white10, height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  for (final entry in [(false, '识别'), (true, 'OCR 模型')])
                    Expanded(
                      child: DesktopButtonClickRegion(
                        child: TextButton(
                          key: ValueKey(
                            entry.$1 ? 'ocr-tab-models' : 'ocr-tab-recognition',
                          ),
                          onPressed: () => setState(() {
                            _modelsTab = entry.$1;
                            _focusedModelId = null;
                            _modelDetailsTrackIndex = null;
                          }),
                          style: TextButton.styleFrom(
                            foregroundColor: _modelsTab == entry.$1
                                ? const Color(0xFF8FB8FF)
                                : Colors.white54,
                          ),
                          child: Text(
                            entry.$2,
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: _modelsTab
                  ? OcrModelsPane(
                      manager: _manager.modelManager,
                      language: _tracks[_modelDetailsTrackIndex ?? 0].language,
                      canChoose: !running,
                      onChoose: _choosePreset,
                      focusModelId: _focusedModelId,
                    )
                  : ListView(
                      key: const PageStorageKey('ocr-options'),
                      padding: EdgeInsets.fromLTRB(
                        layout.horizontalPadding,
                        layout.sectionGap,
                        layout.horizontalPadding,
                        layout.sectionGap,
                      ),
                      children: [
                        // Keep form fields mounted so submit validation can focus
                        // a missing model even when its field is off screen.
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_preparationProgress != null) ...[
                              MediaMaterializationProgressCard(
                                progress: _preparationProgress!,
                                error: _preparationError,
                                onCancel: _preparingOnlineFrame
                                    ? () {
                                        final cancellation =
                                            _preparationCancellation;
                                        if (cancellation != null &&
                                            !cancellation.isCompleted) {
                                          cancellation.complete();
                                        }
                                      }
                                    : null,
                              ),
                              const SizedBox(height: 12),
                            ] else
                              _buildActiveTaskCard(),
                            if (_needsOnlineMaterialization) ...[
                              _card(
                                title: '视频素材',
                                child: OcrVideoQualityField(
                                  qualities: _videoQualities,
                                  value: _videoQualityId,
                                  loading: _loadingQualities,
                                  enabled:
                                      !running &&
                                      !_preparingOnlineFrame &&
                                      !_confirmingOnlineDownload &&
                                      !_startingOcr,
                                  podcast:
                                      widget.videoItem.sourceRef?.podcast !=
                                      null,
                                  error: _qualityError,
                                  onChanged: _changeVideoQuality,
                                  onRetry: () =>
                                      unawaited(_loadVideoQualities()),
                                ),
                              ),
                              const SizedBox(height: 12),
                            ],
                            _card(
                              title: '字幕区域',
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (_previewPath != null &&
                                      File(_previewPath!).existsSync())
                                    SizedBox(
                                      height: 118,
                                      child: ListView.separated(
                                        key: const PageStorageKey('ocr-tracks'),
                                        scrollDirection: Axis.horizontal,
                                        itemCount: _tracks.length,
                                        separatorBuilder: (_, _) =>
                                            const SizedBox(width: 8),
                                        itemBuilder: (context, index) =>
                                            SizedBox(
                                              width: 190,
                                              child: Stack(
                                                children: [
                                                  Positioned.fill(
                                                    child: ClipRRect(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            8,
                                                          ),
                                                      child: OcrRegionPreview(
                                                        imagePath:
                                                            _previewPath!,
                                                        region: _tracks[index]
                                                            .region,
                                                      ),
                                                    ),
                                                  ),
                                                  Positioned(
                                                    left: 6,
                                                    top: 6,
                                                    child: _numberBadge(
                                                      index + 1,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                      ),
                                    ),
                                  const SizedBox(height: 9),
                                  for (final track in _tracks)
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 3),
                                      child: Text(
                                        '区域 ${track.number} · ${_regionSummary(track.region)}',
                                        style: const TextStyle(
                                          color: Colors.white54,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ),
                                  const SizedBox(height: 5),
                                  Text(
                                    running
                                        ? '任务准备和运行时会锁定本次配置；结束后可以调整。'
                                        : '区域、语言和模型会自动保存；开始识别时使用当前显示的设置。',
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 13,
                                      height: 1.5,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      DesktopButtonClickRegion(
                                        child: OutlinedButton.icon(
                                          onPressed:
                                              running ||
                                                  _preparingOnlineFrame ||
                                                  _confirmingOnlineDownload ||
                                                  _startingOcr
                                              ? null
                                              : _selectRegion,
                                          icon: const Icon(Icons.crop_free),
                                          label: const Text('精确框选字幕区域'),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                            _card(
                              title: '识别设置',
                              child: Column(
                                children: [
                                  for (
                                    var index = 0;
                                    index < _tracks.length;
                                    index++
                                  ) ...[
                                    Row(
                                      children: [
                                        _numberBadge(index + 1),
                                        const SizedBox(width: 9),
                                        Expanded(
                                          child: CapsuleDropdownButtonFormField<OcrSubtitleLanguage>(
                                            isExpanded: true,
                                            key: ValueKey(
                                              'ocr_language_${index}_${_tracks[index].language.name}',
                                            ),
                                            initialValue:
                                                _tracks[index].language,
                                            dropdownColor: const Color(
                                              0xFF252930,
                                            ),
                                            style: const TextStyle(
                                              color: Colors.white,
                                            ),
                                            decoration: InputDecoration(
                                              labelText:
                                                  '区域 ${index + 1} 的字幕语言',
                                              border:
                                                  const OutlineInputBorder(),
                                              isDense: true,
                                            ),
                                            items: [
                                              for (final language
                                                  in OcrSubtitleLanguage.values)
                                                DropdownMenuItem(
                                                  value: language,
                                                  child: Text(
                                                    language.label,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ),
                                            ],
                                            onChanged: running
                                                ? null
                                                : (value) {
                                                    if (value == null) return;
                                                    setState(() {
                                                      _tracks[index] =
                                                          _tracks[index].copyWith(
                                                            language: value,
                                                            modelId: _manager
                                                                .rememberedModelIdFor(
                                                                  value,
                                                                ),
                                                            modelIdentity: '',
                                                          );
                                                      _tracksEditedInThisPanel =
                                                          true;
                                                    });
                                                    _manager.rememberTracks(
                                                      widget.videoItem.id,
                                                      _tracks,
                                                    );
                                                    _refreshModelAndEstimate();
                                                  },
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        DesktopButtonClickRegion(
                                          child: IconButton(
                                            key: ValueKey(
                                              'ocr-delete-region-$index',
                                            ),
                                            tooltip: _tracks.length <= 1
                                                ? '至少保留一个字幕区域'
                                                : '删除区域 ${index + 1}',
                                            style: IconButton.styleFrom(
                                              fixedSize: const Size.square(48),
                                              minimumSize: const Size.square(
                                                48,
                                              ),
                                              maximumSize: const Size.square(
                                                48,
                                              ),
                                              padding: EdgeInsets.zero,
                                              visualDensity:
                                                  VisualDensity.standard,
                                              tapTargetSize:
                                                  MaterialTapTargetSize
                                                      .shrinkWrap,
                                              foregroundColor: Colors.white70,
                                              disabledForegroundColor:
                                                  Colors.white24,
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                              ),
                                            ),
                                            iconSize: 20,
                                            onPressed:
                                                running || _tracks.length <= 1
                                                ? null
                                                : () => _deleteTrack(index),
                                            icon: const Icon(
                                              Icons.delete_outline,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    _modelSelector(index, running: running),
                                    if (index != _tracks.length - 1)
                                      const SizedBox(height: 12),
                                  ],
                                  const SizedBox(height: 4),
                                  SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text(
                                      '自选时间范围',
                                      style: TextStyle(color: Colors.white),
                                    ),
                                    subtitle: _customRange
                                        ? Align(
                                            alignment: Alignment.centerLeft,
                                            child: DesktopButtonClickRegion(
                                              child: TextButton.icon(
                                                key: const ValueKey(
                                                  'ocr-edit-time-range',
                                                ),
                                                onPressed:
                                                    running ||
                                                        widget.duration <=
                                                            Duration.zero
                                                    ? null
                                                    : _editRange,
                                                style: TextButton.styleFrom(
                                                  foregroundColor:
                                                      Colors.white70,
                                                  disabledForegroundColor:
                                                      Colors.white38,
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        vertical: 4,
                                                      ),
                                                  minimumSize: Size.zero,
                                                  tapTargetSize:
                                                      MaterialTapTargetSize
                                                          .shrinkWrap,
                                                ),
                                                iconAlignment:
                                                    IconAlignment.end,
                                                icon: const Icon(
                                                  Icons.edit_outlined,
                                                  size: 14,
                                                ),
                                                label: Text(
                                                  '${_formatMs(_startMs)} — ${_formatMs(_endMs)}',
                                                ),
                                              ),
                                            ),
                                          )
                                        : const Text(
                                            '整个视频',
                                            style: TextStyle(
                                              color: Colors.white54,
                                            ),
                                          ),
                                    value: _customRange,
                                    onChanged: running
                                        ? null
                                        : (value) {
                                            setState(
                                              () => _customRange = value,
                                            );
                                            unawaited(
                                              _refreshModelAndEstimate(),
                                            );
                                          },
                                  ),
                                  if (_customRange) ...[
                                    Listener(
                                      onPointerDown: (event) => _rangePointerX =
                                          event.localPosition.dx,
                                      onPointerUp: (_) => _rangePointerX = null,
                                      onPointerCancel: (_) =>
                                          _rangePointerX = null,
                                      child: SliderTheme(
                                        data: SliderTheme.of(context).copyWith(
                                          minThumbSeparation: 0,
                                          thumbSelector: _selectRangeThumb,
                                          showValueIndicator:
                                              ShowValueIndicator.never,
                                        ),
                                        child: RangeSlider(
                                          // A known track inset also lets handle
                                          // selection use the original pointer down.
                                          padding: EdgeInsets.zero,
                                          values: RangeValues(_startMs, _endMs),
                                          min: 0,
                                          max: widget.duration.inMilliseconds
                                              .toDouble()
                                              .clamp(1, double.infinity),
                                          onChanged:
                                              running ||
                                                  widget.duration <=
                                                      Duration.zero
                                              ? null
                                              : _changeRange,
                                          onChangeEnd: (_) =>
                                              _refreshModelAndEstimate(),
                                        ),
                                      ),
                                    ),
                                  ],
                                  Row(
                                    children: [
                                      Icon(
                                        _modelInstalled
                                            ? Icons.offline_pin
                                            : Icons.inventory_2_outlined,
                                        size: 17,
                                        color: _modelInstalled
                                            ? Colors.greenAccent
                                            : const Color(0xFF65A2FF),
                                      ),
                                      const SizedBox(width: 7),
                                      Expanded(
                                        child: Text(
                                          _modelInstalled
                                              ? '所选语言模型均已就绪，可完全离线识别'
                                              : _tracks.any(
                                                  (track) =>
                                                      track.modelId.isEmpty,
                                                )
                                              ? '请为每个字幕区域选择识别模型'
                                              : '开始识别时会自动下载所选模型，完成后继续 OCR',
                                          style: const TextStyle(
                                            color: Colors.white60,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                            _card(
                              title: '识别设备',
                              child: OcrComputeSettings(manager: _manager),
                            ),
                            const SizedBox(height: 12),
                            _card(
                              title: '处理流程',
                              child: Text(
                                '当前有 ${_tracks.length} 个独立字幕区域。\n'
                                '模型就绪后，任务会按设备余量自动分配算力。'
                                '各区域共享视频抽帧，逐段识别并分别保存 SRT 字幕。'
                                '取消或完成后会清理临时帧。',
                                style: const TextStyle(
                                  color: Colors.white60,
                                  fontSize: 12,
                                  height: 1.55,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
            ),
            SidebarValueBuilder<Object>(
              listenable: _manager,
              select: () => (_manager.job, _manager.materializationProgress),
              builder: (context, _, _) {
                final current = _manager.job;
                final own = current?.videoId == widget.videoItem.id;
                final active = current?.isRunning ?? false;
                return RepaintBoundary(
                  key: const ValueKey('ocr-pinned-footer-boundary'),
                  child: _buildPinnedTaskAction(
                    layout: layout,
                    job: own || active ? current : null,
                    running: active,
                    runningOtherVideo: active && !own,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPinnedTaskAction({
    required LandscapeSidebarLayout layout,
    required OcrSubtitleJob? job,
    required bool running,
    required bool runningOtherVideo,
  }) {
    final preparing = job?.status == OcrSubtitleJobStatus.preparing;
    final displayedProgress = switch (job?.status) {
      OcrSubtitleJobStatus.materializing =>
        _manager.materializationProgress?.progress ??
            job?.preparationProgress ??
            0,
      OcrSubtitleJobStatus.downloading => job?.preparationProgress ?? 0,
      _ => job?.progress ?? 0,
    };
    final remainingText = job?.remaining == null
        ? '时间估算中'
        : '剩余约 ${_formatDuration(job!.remaining)}';
    final missingTrack = _validateModelSelection && !_modelInstalled
        ? _tracks.where((track) => track.modelId.isEmpty).firstOrNull
        : null;
    final failure = _panelFailure;
    final jobError = !running && !runningOtherVideo ? job?.error : null;
    final hasProblem =
        missingTrack != null || failure != null || jobError != null;
    final diagnostic = missingTrack != null
        ? null
        : failure != null
        ? failure.details
        : jobError == null
        ? null
        : safeOperationDiagnostic(jobError);
    final status = missingTrack != null
        ? '区域 ${missingTrack.number} 未选模型'
        : failure?.title ??
              (jobError != null
                  ? operationErrorSummary(jobError, fallback: '识别未完成，请重试')
                  : runningOtherVideo
                  ? '正在处理其他视频的 OCR 字幕'
                  : _taskStatusText(job));
    final percent = OcrTaskProgressTracker.percentFor(displayedProgress);
    final showRecognition =
        running &&
        (job?.status == OcrSubtitleJobStatus.recognizing ||
            job?.status == OcrSubtitleJobStatus.extracting ||
            job?.status == OcrSubtitleJobStatus.writing);

    return Container(
      key: const ValueKey('ocr-pinned-task-action'),
      padding: EdgeInsets.fromLTRB(
        layout.horizontalPadding,
        layout.verticalPadding,
        layout.horizontalPadding,
        layout.verticalPadding,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF20242A),
        border: Border(top: BorderSide(color: Colors.white12)),
        boxShadow: [
          BoxShadow(
            color: Colors.black38,
            blurRadius: 10,
            offset: Offset(0, -3),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: MediaQuery.textScalerOf(context).scale(13) * 1.5,
            child: Row(
              children: [
                Icon(
                  hasProblem
                      ? Icons.error_outline_rounded
                      : running
                      ? Icons.sync_rounded
                      : Icons.info_outline_rounded,
                  size: layout.iconSize - 2,
                  color: hasProblem
                      ? Theme.of(context).colorScheme.error
                      : running
                      ? const Color(0xFF65A2FF)
                      : Colors.white54,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Semantics(
                    liveRegion: hasProblem,
                    child: Tooltip(
                      message: failure == null
                          ? status
                          : '${failure.title}：${failure.message}',
                      child: Text(
                        status,
                        key: const ValueKey('ocr-task-status'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: hasProblem
                              ? Theme.of(context).colorScheme.error
                              : Colors.white70,
                          fontSize: hasProblem ? 13 : layout.captionSize,
                        ),
                      ),
                    ),
                  ),
                ),
                if (diagnostic != null)
                  DesktopButtonClickRegion(
                    child: TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        minimumSize: const Size(0, 0),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                      onPressed: () => setState(
                        () => _diagnosticsExpanded = !_diagnosticsExpanded,
                      ),
                      child: const Text('诊断详情'),
                    ),
                  )
                else if (!hasProblem) ...[
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 40 * MediaQuery.textScalerOf(context).scale(1),
                    child: Text(
                      '$percent%',
                      key: const ValueKey('ocr-pinned-percent'),
                      textAlign: TextAlign.end,
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(
                        color: Colors.white60,
                        fontSize: layout.captionSize,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (_diagnosticsExpanded && diagnostic != null)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .2,
              ),
              child: SingleChildScrollView(
                controller: _diagnosticScrollController,
                primary: false,
                child: SelectableText(
                  diagnostic,
                  key: const ValueKey('ocr-task-diagnostic'),
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ),
            ),
          if (showRecognition && job!.tracks.isNotEmpty) ...[
            const SizedBox(height: 4),
            SizedBox(
              height:
                  MediaQuery.textScalerOf(context).scale(layout.captionSize) *
                  1.5 *
                  job.tracks.length.clamp(1, 2),
              child: Scrollbar(
                controller: _progressScrollController,
                thumbVisibility: job.tracks.length > 2,
                child: ListView(
                  key: const ValueKey('ocr-region-progress-list'),
                  controller: _progressScrollController,
                  padding: EdgeInsets.only(
                    right: job.tracks.length > 2 ? 8 : 0,
                  ),
                  children: [
                    for (final track in job.tracks)
                      _buildRegionProgress(layout, job, track),
                  ],
                ),
              ),
            ),
          ],
          if (running) ...[
            const SizedBox(height: 3),
            Text(
              remainingText,
              key: const ValueKey('ocr-remaining-time'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white54,
                fontSize: layout.captionSize,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
          const SizedBox(height: 6),
          LinearProgressIndicator(
            key: const ValueKey('ocr-pinned-progress'),
            value: preparing ? null : displayedProgress.clamp(0, 1),
            minHeight: 4,
            borderRadius: BorderRadius.circular(999),
          ),
          const SizedBox(height: 7),
          SizedBox(
            height: layout.controlHeight,
            child: running
                ? DesktopButtonClickRegion(
                    child: OutlinedButton.icon(
                      key: const ValueKey('ocr-pinned-cancel'),
                      onPressed: _manager.cancel,
                      icon: const Icon(Icons.stop_circle_outlined, size: 17),
                      label: const Text('取消任务'),
                    ),
                  )
                : DesktopButtonClickRegion(
                    child: FilledButton.icon(
                      key: const ValueKey('ocr-pinned-start'),
                      onPressed:
                          _preparingOnlineFrame ||
                              _confirmingOnlineDownload ||
                              _startingOcr
                          ? null
                          : _start,
                      icon: const Icon(
                        Icons.document_scanner_outlined,
                        size: 17,
                      ),
                      label: Text(
                        _canResumeAtQuality(_requestVideoQualityId)
                            ? '继续 OCR 识别'
                            : job?.status == OcrSubtitleJobStatus.failed
                            ? '重试 OCR 识别'
                            : '开始 OCR 识别',
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildRegionProgress(
    LandscapeSidebarLayout layout,
    OcrSubtitleJob job,
    OcrSubtitleTrack track,
  ) {
    final total = job.recognitionProgress?.total ?? job.end - job.start;
    final completed =
        job.recognitionProgress?.completedByTrack[track.number] ??
        Duration.zero;
    final language = track.language.label.replaceAll('（简繁兼容）', '');
    final label = '区域 ${track.number} · $language';
    final compactLabel =
        layout.isNarrow &&
        MediaQuery.textScalerOf(context).scale(layout.captionSize) > 14;
    final time =
        '${_formatDuration(completed, forceHours: total.inHours > 0)}'
        ' / ${_formatDuration(total)}';
    final style = TextStyle(
      color: Colors.white70,
      fontSize: layout.captionSize,
      height: 1.5,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Tooltip(
      message: '$label · 已处理 $time',
      child: Semantics(
        label: '$label · 已处理 $time',
        excludeSemantics: true,
        child: Row(
          key: ValueKey('ocr-region-${track.number}-progress'),
          children: [
            Expanded(
              flex: 3,
              child: Text(
                compactLabel ? '${track.number} · $language' : label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
            const SizedBox(width: 5),
            Flexible(
              flex: 4,
              child: Align(
                alignment: Alignment.centerRight,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(time, style: style),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card({required String title, required Widget child}) => Material(
    color: const Color(0xFF20242A),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: const BorderSide(color: Colors.white10),
    ),
    clipBehavior: Clip.antiAlias,
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    ),
  );

  Widget _numberBadge(int number) => Container(
    width: 26,
    height: 26,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: const Color(0xFF65A2FF),
      borderRadius: BorderRadius.circular(7),
    ),
    child: Text(
      '$number',
      style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w800),
    ),
  );

  String _regionSummary(NormalizedOcrRegion region) =>
      'X ${(100 * region.left).toStringAsFixed(1)}% · '
      'Y ${(100 * region.top).toStringAsFixed(1)}% · '
      '宽 ${(100 * region.width).toStringAsFixed(1)}% · '
      '高 ${(100 * region.height).toStringAsFixed(1)}%';

  String _formatMs(double value) =>
      _formatDuration(Duration(milliseconds: value.round()));

  String _taskStatusText(OcrSubtitleJob? job) {
    if (job == null || !job.isRunning) {
      final label =
          itemNeedsOnlineMaterialization(
            source: widget.videoItem.sourceRef,
            path: widget.videoItem.path,
          )
          ? '预计 OCR 耗时'
          : '预计耗时';
      final duration = _estimate != null && !_hasDurationMeasurements
          ? '待首次识别校准'
          : _formatDuration(_estimate);
      return '$label $duration'
          '${job == null ? '' : ' · ${job.statusMessage}'}';
    }
    return switch (job.status) {
      OcrSubtitleJobStatus.preparing => '正在准备 OCR 引擎',
      OcrSubtitleJobStatus.downloading => job.statusMessage,
      OcrSubtitleJobStatus.extracting => '正在提取字幕帧',
      OcrSubtitleJobStatus.recognizing => '正在处理 OCR 字幕',
      OcrSubtitleJobStatus.writing => '正在保存字幕',
      _ => job.statusMessage,
    };
  }

  String _formatDuration(Duration? value, {bool forceHours = false}) {
    if (value == null) return '计算中';
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60);
    final seconds = value.inSeconds.remainder(60);
    return hours > 0 || forceHours
        ? '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}'
        : '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
}
