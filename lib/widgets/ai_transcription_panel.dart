import 'package:flutter/material.dart';
import 'sidebar_activity.dart';
import 'package:flutter/services.dart';
import 'landscape_sidebar_layout.dart';
import 'stable_width_label.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import '../models/transcription_status.dart';
import '../models/video_item.dart';
import '../models/transcription_progress.dart';
import '../models/local_asr_progress.dart';
import 'local_asr_progress_view.dart';
import 'transcription_audio_progress_label.dart';
import 'ai_transcription_configuration.dart';
import 'transcript_translate_settings_sheet.dart';
import 'transcription_restart_dialog.dart';
import '../services/subtitle_translation_languages.dart';
import '../utils/transcription_failure_summary.dart';
import 'operation_status.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// 转录按钮所有可能的文案，按钮按最宽的一条定宽，状态切换时图标和文字不跳。
const List<String> kAiTranscriptionActionLabels = [
  '开始语音转录',
  '加入队列',
  '已加入队列',
  '转录中...',
  '转录中 · 点击暂停',
  '正在暂停...',
  '正在取消...',
  '继续转录',
  '继续上次任务',
  '重试转录',
  '重新转录',
];

const List<String> kAiTranscribeTranslateActionLabels = [
  '转录并翻译',
  '加入队列',
  '已加入队列',
  '转录中...',
  '翻译中...',
  '转录中 · 点击暂停',
  '翻译中 · 点击暂停',
  '正在暂停...',
  '正在取消...',
  '继续转录',
  '继续上次任务',
  '继续转录并翻译',
  '重试转录并翻译',
  '重新转录并翻译',
];

/// Result handed to the player after a transcript, and a translation when
/// that step was requested and succeeded.
class AiTranscriptionCompletion {
  const AiTranscriptionCompletion({
    required this.primaryPath,
    this.translationPath,
    this.message = '',
  });

  final String primaryPath;
  final String? translationPath;
  final String message;

  bool get translated => translationPath != null && translationPath!.isNotEmpty;
}

class AiTranscriptionPanel extends StatefulWidget {
  final String videoPath;
  final VideoItem? sourceItem;
  final void Function(AiTranscriptionCompletion completion) onCompleted;

  final String? videoId;
  final VoidCallback? onBack;
  final bool musicAppearance;

  const AiTranscriptionPanel({
    super.key,
    required this.videoPath,
    this.sourceItem,
    required this.onCompleted,
    this.videoId,
    this.onBack,
    this.musicAppearance = false,
  });

  @override
  State<AiTranscriptionPanel> createState() => _AiTranscriptionPanelState();
}

class _AiTranscriptionPanelState extends State<AiTranscriptionPanel> {
  late final TranscriptionManager _manager;
  bool _hasRequestedForCurrentVideo = false;
  TranscriptionStatus? _terminalStatusForCurrentVideo;
  String _terminalMessageForCurrentVideo = "";
  bool _starting = false;
  String? _startupErrorDetails;

  bool get _cancelling =>
      _manager.isVideoCancelling(widget.videoPath, videoId: widget.videoId);

  bool get _actionsBusy => _starting || _cancelling;

  @override
  void didUpdateWidget(covariant AiTranscriptionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoPath != widget.videoPath ||
        oldWidget.videoId != widget.videoId) {
      _hasRequestedForCurrentVideo = false;
      _terminalStatusForCurrentVideo = null;
      _terminalMessageForCurrentVideo = '';
      _startupErrorDetails = null;
    }
  }

  @override
  void initState() {
    super.initState();
    _manager = Provider.of<TranscriptionManager>(context, listen: false);
    _manager.addListener(_onManagerUpdate);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _checkCompletion(_manager);
    });
  }

  @override
  void dispose() {
    _manager.removeListener(_onManagerUpdate);
    super.dispose();
  }

  void _onManagerUpdate() {
    if (!mounted) return;
    _checkCompletion(_manager);
  }

  void _checkCompletion(TranscriptionManager manager) {
    final stream = manager.streamForVideo(
      widget.videoPath,
      videoId: widget.videoId,
    );
    if (stream != null && !stream.complete) return;
    final srtPath = manager.getGeneratedSrtPathForVideo(
      widget.videoPath,
      videoId: widget.videoId,
    );
    if (srtPath != null &&
        manager.consumeResultNotificationForVideo(
          widget.videoPath,
          videoId: widget.videoId,
        )) {
      _terminalStatusForCurrentVideo = TranscriptionStatus.completed;
      _terminalMessageForCurrentVideo = manager
          .completionMessageForVideo(widget.videoPath, videoId: widget.videoId)
          .trim();
      if (_terminalMessageForCurrentVideo.isEmpty) {
        _terminalMessageForCurrentVideo = '转录完成';
      }
      if (manager.hasSubtitleStreamForVideo(
        widget.videoPath,
        videoId: widget.videoId,
      )) {
        // The playback service already owns this stream and its user's track
        // choice. A completion callback would reload it and discard that choice.
        return;
      }
      final translation = manager.getGeneratedTranslationPathForVideo(
        widget.videoPath,
        videoId: widget.videoId,
      );
      widget.onCompleted(
        AiTranscriptionCompletion(
          primaryPath: srtPath,
          translationPath: translation,
          message: _terminalMessageForCurrentVideo,
        ),
      );
    }
  }

  Future<void> _startTranscription({
    required bool withTranslation,
    bool restart = false,
  }) async {
    if (_actionsBusy) return;
    final videoPath = widget.videoPath;
    final videoId = widget.videoId;
    final manager = Provider.of<TranscriptionManager>(context, listen: false);
    final sourceItem = widget.sourceItem;
    if (sourceItem != null) {
      manager.updateSourceForVideo(
        videoPath,
        videoId: videoId,
        sourceItem: sourceItem,
      );
    }
    final translateSettings = lookupSubtitleTranslateSettings(
      context,
      listen: false,
    );

    try {
      setState(() => _starting = true);
      if (restart &&
          !await confirmTranscriptionRestart(
            context,
            withTranslation: withTranslation,
            modelCenter: manager.modelCenter,
          )) {
        return;
      }
      if (!mounted ||
          widget.videoPath != videoPath ||
          widget.videoId != videoId) {
        return;
      }
      if (!restart &&
          !manager.isVideoAwaitingFirstStart(videoPath, videoId: videoId) &&
          (manager.isVideoPaused(videoPath, videoId: videoId) ||
              manager.isVideoFailed(videoPath, videoId: videoId))) {
        if (manager.translateEnabledForVideo(videoPath, videoId: videoId) !=
            withTranslation) {
          return;
        }
        setState(() {
          _hasRequestedForCurrentVideo = true;
          _terminalStatusForCurrentVideo = null;
          _terminalMessageForCurrentVideo = '';
          _startupErrorDetails = null;
        });
        if (manager.isVideoPaused(videoPath, videoId: videoId)) {
          manager.resumeVideo(videoPath, videoId: videoId);
        } else {
          manager.retryVideo(videoPath, videoId: videoId);
        }
        return;
      }
      final choice = withTranslation
          ? (translateSettings == null
                ? const TranscriptTranslateChoice.automatic()
                : await TranscriptTranslateChoice.capture(
                    translateSettings,
                    enabled: true,
                  ))
          : const TranscriptTranslateChoice.off();
      if (!mounted ||
          widget.videoPath != videoPath ||
          widget.videoId != videoId) {
        return;
      }
      setState(() {
        _hasRequestedForCurrentVideo = true;
        _terminalStatusForCurrentVideo = null;
        _terminalMessageForCurrentVideo = '';
        _startupErrorDetails = null;
      });
      if (restart) {
        final restarted = manager.restartVideo(
          videoPath,
          videoId: videoId,
          translateChoice: choice,
        );
        if (!restarted) {
          setState(() {
            _terminalStatusForCurrentVideo = TranscriptionStatus.error;
            _terminalMessageForCurrentVideo = '任务状态已变化，请先暂停任务再从头开始';
          });
        }
        return;
      }
      if (manager.isVideoAwaitingFirstStart(videoPath, videoId: videoId)) {
        manager.resumeVideo(
          videoPath,
          videoId: videoId,
          translateChoice: choice,
        );
        return;
      }
      final settings = Provider.of<SettingsService>(context, listen: false);
      final library = Provider.of<LibraryService>(context, listen: false);
      await manager.startTranscription(
        videoPath,
        videoId: videoId,
        libraryService: library,
        sourceItem: sourceItem,
        autoCache: settings.autoCacheSubtitles,
        autoStart: true,
        translateChoice: choice,
      );
    } catch (e) {
      if (mounted &&
          widget.videoPath == videoPath &&
          widget.videoId == videoId) {
        setState(() {
          _terminalStatusForCurrentVideo = TranscriptionStatus.error;
          _terminalMessageForCurrentVideo = operationErrorSummary(
            e,
            fallback: '无法开始语音转录，请检查媒体文件和转录设置后重试。',
          );
          _startupErrorDetails = safeOperationDiagnostic(e);
        });
      }
      // Error is handled in manager state
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _cancelTranscription() async {
    if (_actionsBusy) return;
    final path = widget.videoPath;
    final id = widget.videoId;
    final cancelled = await _manager.cancelVideo(path, videoId: id);
    if (!cancelled ||
        !mounted ||
        widget.videoPath != path ||
        widget.videoId != id) {
      return;
    }
    setState(() {
      _hasRequestedForCurrentVideo = false;
      _terminalStatusForCurrentVideo = null;
      _terminalMessageForCurrentVideo = '';
      _startupErrorDetails = null;
    });
  }

  Widget _withCancellationAction({
    required LandscapeSidebarLayout layout,
    required bool showCancel,
    required Widget child,
  }) {
    if (!showCancel) return child;
    const red = Color(0xFFFF767D);
    return Row(
      children: [
        Expanded(child: child),
        const SizedBox(width: 8),
        SizedBox(
          width: 40,
          height: layout.controlHeight,
          child: DesktopButtonClickRegion(
            child: IconButton(
              key: const ValueKey('ai-transcription-cancel'),
              tooltip: _cancelling ? '正在取消任务' : '取消任务',
              onPressed: _actionsBusy ? null : _cancelTranscription,
              style: IconButton.styleFrom(
                foregroundColor: red,
                disabledForegroundColor: red.withValues(alpha: 0.6),
                backgroundColor: red.withValues(alpha: 0.1),
                disabledBackgroundColor: red.withValues(alpha: 0.06),
                padding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(layout.controlHeight / 2),
                  side: BorderSide(color: red.withValues(alpha: 0.3)),
                ),
              ),
              icon: _cancelling
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: red,
                      ),
                    )
                  : const Icon(Icons.close_rounded, size: 20),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final manager = context.read<TranscriptionManager>();
    return SidebarValueBuilder<Object>(
      listenable: manager,
      select: () => (
        manager.currentVideoPath,
        manager.currentVideoId,
        manager.status,
        manager.isProcessing,
        manager.pendingCount,
        manager.processingCount,
        manager.queuedCount,
        manager.isVideoRunning(widget.videoPath, videoId: widget.videoId),
        manager.isVideoQueued(widget.videoPath, videoId: widget.videoId),
        manager.isVideoPaused(widget.videoPath, videoId: widget.videoId),
        manager.isVideoAwaitingFirstStart(
          widget.videoPath,
          videoId: widget.videoId,
        ),
        manager.isVideoFailed(widget.videoPath, videoId: widget.videoId),
        manager.isVideoStopping(widget.videoPath, videoId: widget.videoId),
        manager.isVideoCancelling(widget.videoPath, videoId: widget.videoId),
        manager.isVideoTranslating(widget.videoPath, videoId: widget.videoId),
        manager.translateEnabledForVideo(
          widget.videoPath,
          videoId: widget.videoId,
        ),
        manager.queuePositionForVideo(
          widget.videoPath,
          videoId: widget.videoId,
        ),
        manager.getGeneratedSrtPathForVideo(
          widget.videoPath,
          videoId: widget.videoId,
        ),
      ),
      builder: (context, _, child) {
        final bool samePath = manager.currentVideoPath == widget.videoPath;
        final String? trimmedVideoId = widget.videoId?.trim();
        final bool sameVideoId =
            trimmedVideoId == null ||
            trimmedVideoId.isEmpty ||
            manager.currentVideoId == trimmedVideoId;
        final bool isJobForThisVideo = samePath && sameVideoId;
        final bool isProcessing = manager.isVideoRunning(
          widget.videoPath,
          videoId: widget.videoId,
        );
        final bool isQueued = manager.isVideoQueued(
          widget.videoPath,
          videoId: widget.videoId,
        );
        final bool isBusyWithOther = manager.isProcessing && !isJobForThisVideo;
        final bool hasGeneratedSrt =
            manager.getGeneratedSrtPathForVideo(
              widget.videoPath,
              videoId: widget.videoId,
            ) !=
            null;
        final int pendingCount = manager.pendingCount;
        final int processingCount = manager.processingCount;
        final int queueCount = manager.queuedCount;
        final int queuePosition = manager.queuePositionForVideo(
          widget.videoPath,
          videoId: widget.videoId,
        );
        final cancelling = _cancelling;
        final stopping =
            cancelling ||
            manager.isVideoStopping(widget.videoPath, videoId: widget.videoId);
        final awaitingFirstStart = manager.isVideoAwaitingFirstStart(
          widget.videoPath,
          videoId: widget.videoId,
        );
        final paused =
            !awaitingFirstStart &&
            manager.isVideoPaused(widget.videoPath, videoId: widget.videoId);
        final bool canQueueCurrentVideo =
            !isProcessing && (!isQueued || paused || awaitingFirstStart);
        final failed = manager.isVideoFailed(
          widget.videoPath,
          videoId: widget.videoId,
        );
        final taskWithTranslation = manager.translateEnabledForVideo(
          widget.videoPath,
          videoId: widget.videoId,
        );
        final hasTask =
            !awaitingFirstStart &&
            (isProcessing || isQueued || paused || failed || stopping);
        final transcriptionBlocked = hasTask && taskWithTranslation;
        final String actionLabel = transcriptionBlocked
            ? '开始语音转录'
            : cancelling
            ? '正在取消...'
            : stopping
            ? '正在暂停...'
            : isProcessing
            ? '转录中 · 点击暂停'
            : paused
            ? '继续转录'
            : failed
            ? '重试转录'
            : isQueued && !awaitingFirstStart
            ? "已加入队列"
            : (hasGeneratedSrt
                  ? "重新转录"
                  : (isBusyWithOther ? "加入队列" : "开始语音转录"));

        return Focus(
          autofocus: true,
          onKeyEvent: (node, event) {
            if (event is KeyRepeatEvent) return KeyEventResult.handled;
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.escape) {
              widget.onBack?.call();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: LayoutBuilder(
            builder: (context, constraints) {
              final layout = LandscapeSidebarLayout.fromSize(
                Size(constraints.maxWidth, constraints.maxHeight),
              );
              return Container(
                padding: EdgeInsets.symmetric(
                  horizontal: layout.horizontalPadding,
                  vertical: layout.verticalPadding,
                ),
                decoration: BoxDecoration(
                  color: widget.musicAppearance
                      ? Colors.transparent
                      : const Color(0xFF1E1E1E),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(16),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!widget.musicAppearance)
                      SizedBox(
                        height: layout.headerHeight,
                        child: Row(
                          children: [
                            SizedBox.square(
                              dimension: layout.controlHeight,
                              child: DesktopButtonClickRegion(
                                child: IconButton(
                                  padding: EdgeInsets.zero,
                                  icon: Icon(
                                    Icons.arrow_back,
                                    color: Colors.white,
                                    size: layout.iconSize,
                                  ),
                                  tooltip: "返回",
                                  onPressed: widget.onBack,
                                ),
                              ),
                            ),
                            SizedBox(width: layout.isNarrow ? 2 : 6),
                            Expanded(
                              child: Text(
                                "语音转录",
                                style: TextStyle(
                                  fontSize: layout.titleSize,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (isProcessing)
                              const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.blueAccent,
                                ),
                              ),
                          ],
                        ),
                      ),
                    SizedBox(height: layout.sectionGap / 2),
                    Expanded(
                      child: ListView(
                        key: const PageStorageKey('transcription-options'),
                        padding: EdgeInsets.only(bottom: layout.sectionGap),
                        children: [
                          if (hasTask) ...[
                            Text(
                              isProcessing
                                  ? '以下设置用于新任务；当前任务保持开始时的语言与配置。'
                                  : '以下设置用于新任务；继续任务沿用上次配置。',
                              style: TextStyle(
                                color: Colors.white60,
                                fontSize: layout.captionSize + 1,
                              ),
                            ),
                            SizedBox(height: layout.sectionGap / 2),
                          ],
                          AiTranscriptionConfiguration(
                            center: manager.modelCenter,
                            hotwords: manager.hotwordStore,
                            mediaKey: manager.mediaKeyForVideo(
                              widget.videoPath,
                              videoId: widget.videoId,
                            ),
                            mediaTitle:
                                widget.sourceItem?.title ??
                                widget.videoPath.split(RegExp(r'[/\\]')).last,
                            translation: lookupSubtitleTranslateSettings(
                              context,
                            ),
                          ),
                          SizedBox(height: layout.sectionGap),
                          if ((paused || failed) && !taskWithTranslation)
                            _buildResumeActions(
                              manager: manager,
                              layout: layout,
                              withTranslation: false,
                              failed: failed,
                            )
                          else
                            _withCancellationAction(
                              layout: layout,
                              showCancel: hasTask && !taskWithTranslation,
                              child: DesktopButtonClickRegion(
                                child: ElevatedButton.icon(
                                  key: const ValueKey(
                                    'ai-transcription-action',
                                  ),
                                  onPressed:
                                      transcriptionBlocked ||
                                          stopping ||
                                          _actionsBusy
                                      ? null
                                      : isProcessing
                                      ? () => manager.pauseVideo(
                                          widget.videoPath,
                                          videoId: widget.videoId,
                                        )
                                      : canQueueCurrentVideo
                                      ? () => _startTranscription(
                                          withTranslation: false,
                                        )
                                      : null,
                                  icon: Icon(
                                    isProcessing && !transcriptionBlocked
                                        ? Icons.pause_circle_outline
                                        : Icons.auto_awesome,
                                  ),
                                  label: StableWidthLabel(
                                    actionLabel,
                                    variants: kAiTranscriptionActionLabels,
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.blue,
                                    foregroundColor: Colors.white,
                                    minimumSize: Size.fromHeight(
                                      layout.controlHeight,
                                    ),
                                    padding: EdgeInsets.symmetric(
                                      vertical: layout.verticalPadding / 2,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          SizedBox(height: layout.sectionGap),
                          const SizedBox(height: 4),
                          _buildTranslateAction(
                            layout: layout,
                            manager: manager,
                            isProcessing: isProcessing,
                            isQueued: isQueued,
                            isBusyWithOther: isBusyWithOther,
                            canQueueCurrentVideo: canQueueCurrentVideo,
                            blocked: hasTask && !taskWithTranslation,
                          ),
                          SizedBox(height: layout.sectionGap),
                          Container(
                            padding: EdgeInsets.all(layout.horizontalPadding),
                            decoration: BoxDecoration(
                              color: Colors.blueGrey.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: Colors.blueGrey.withValues(alpha: 0.45),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  "语音转录队列",
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                    fontSize: layout.bodySize,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  "处理中 $processingCount / 排队 $queueCount / 总计 $pendingCount",
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: layout.captionSize,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(height: layout.sectionGap),
                          SidebarValueBuilder<Object>(
                            listenable: manager,
                            select: () => (
                              manager.progress,
                              manager.statusMessage,
                              manager.translationProgress,
                              manager.localAsrProgress,
                              manager.localAudioProgress,
                              manager.status,
                            ),
                            builder: (context, _, _) =>
                                _buildInlineProgressSection(
                                  manager: manager,
                                  isJobForThisVideo: isJobForThisVideo,
                                  isProcessing: isProcessing,
                                  isQueued: isQueued,
                                  hasGeneratedSrt: hasGeneratedSrt,
                                  queuePosition: queuePosition,
                                  canQueueCurrentVideo: canQueueCurrentVideo,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildTranslateAction({
    required LandscapeSidebarLayout layout,
    required TranscriptionManager manager,
    required bool isProcessing,
    required bool isQueued,
    required bool isBusyWithOther,
    required bool canQueueCurrentVideo,
    required bool blocked,
  }) {
    final translating = manager.isVideoTranslating(
      widget.videoPath,
      videoId: widget.videoId,
    );
    final cancelling = _cancelling;
    final stopping =
        cancelling ||
        manager.isVideoStopping(widget.videoPath, videoId: widget.videoId);
    final paused =
        manager.isVideoPaused(widget.videoPath, videoId: widget.videoId) &&
        !manager.isVideoAwaitingFirstStart(
          widget.videoPath,
          videoId: widget.videoId,
        );
    final failed = manager.isVideoFailed(
      widget.videoPath,
      videoId: widget.videoId,
    );
    if ((paused || failed) && !blocked) {
      return _buildResumeActions(
        manager: manager,
        layout: layout,
        withTranslation: true,
        failed: failed,
      );
    }
    final actionLabel = blocked
        ? '转录并翻译'
        : cancelling
        ? '正在取消...'
        : stopping
        ? '正在暂停...'
        : isProcessing
        ? (translating ? '翻译中 · 点击暂停' : '转录中 · 点击暂停')
        : paused
        ? '继续转录并翻译'
        : failed
        ? '重试转录并翻译'
        : isQueued &&
              !manager.isVideoAwaitingFirstStart(
                widget.videoPath,
                videoId: widget.videoId,
              )
        ? '已加入队列'
        : (manager.getGeneratedSrtPathForVideo(
                    widget.videoPath,
                    videoId: widget.videoId,
                  ) !=
                  null
              ? '重新转录并翻译'
              : (isBusyWithOther ? '加入队列' : '转录并翻译'));
    assert(
      kAiTranscribeTranslateActionLabels.contains(actionLabel),
      actionLabel,
    );
    final enabled =
        !blocked &&
        !stopping &&
        !_actionsBusy &&
        (isProcessing || canQueueCurrentVideo);
    final radius = BorderRadius.circular(layout.controlHeight / 2);
    return _withCancellationAction(
      layout: layout,
      showCancel: !blocked && (isProcessing || isQueued || stopping),
      child: SizedBox(
        height: layout.controlHeight,
        child: Material(
          color: enabled ? Colors.blue : Colors.white10,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  key: const ValueKey('ai-transcription-translate-action'),
                  onTap: blocked || stopping || _actionsBusy
                      ? null
                      : isProcessing
                      ? () => manager.pauseVideo(
                          widget.videoPath,
                          videoId: widget.videoId,
                        )
                      : canQueueCurrentVideo
                      ? () => _startTranscription(withTranslation: true)
                      : null,
                  child: Opacity(
                    opacity: enabled ? 1 : 0.38,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.translate,
                            color: Colors.white,
                            size: 18,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              actionLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const ColoredBox(
                color: Colors.white24,
                child: SizedBox(width: 1, height: double.infinity),
              ),
              SizedBox(
                width: 40,
                child: Tooltip(
                  message: '翻译设置',
                  child: InkWell(
                    onTap: () => showTranscriptTranslateSettings(context),
                    child: const Icon(
                      Icons.settings_outlined,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResumeActions({
    required TranscriptionManager manager,
    required LandscapeSidebarLayout layout,
    required bool withTranslation,
    required bool failed,
  }) {
    return ListenableBuilder(
      listenable: manager.configurationChanges,
      builder: (context, _) {
        final settings = lookupSubtitleTranslateSettings(context);
        final changed = manager.configurationChangedForVideo(
          widget.videoPath,
          videoId: widget.videoId,
          translationSettings: settings,
        );
        final stream = manager.streamForVideo(
          widget.videoPath,
          videoId: widget.videoId,
        );
        final processed = stream?.processedThrough;
        final time = processed == null
            ? null
            : TranscriptionAudioProgress(
                completed: processed,
                total: processed,
              ).timeLabel.split(' / ').first;
        final mode = withTranslation ? '转录并翻译' : '转录';
        final message =
            _terminalStatusForCurrentVideo == TranscriptionStatus.error
            ? _terminalMessageForCurrentVideo
            : manager.completionMessageForVideo(
                widget.videoPath,
                videoId: widget.videoId,
              );
        final caption = TextStyle(
          color: Colors.white60,
          fontSize: layout.captionSize + 1,
          height: 1.4,
        );
        Widget action({required bool restart}) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (restart)
              DesktopButtonClickRegion(
                child: OutlinedButton.icon(
                  key: const ValueKey('ai-transcription-restart'),
                  onPressed: _actionsBusy
                      ? null
                      : () => _startTranscription(
                          withTranslation: withTranslation,
                          restart: true,
                        ),
                  icon: const Icon(Icons.restart_alt, size: 18),
                  label: const Text('重新开始'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                  ),
                ),
              )
            else
              _withCancellationAction(
                layout: layout,
                showCancel: true,
                child: DesktopButtonClickRegion(
                  child: ElevatedButton.icon(
                    key: ValueKey(
                      withTranslation
                          ? 'ai-transcription-translate-action'
                          : 'ai-transcription-action',
                    ),
                    onPressed: _actionsBusy
                        ? null
                        : () => _startTranscription(
                            withTranslation: withTranslation,
                          ),
                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: Text(_cancelling ? '正在取消...' : '继续上次任务'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 3),
            Text(
              restart ? '使用当前配置' : '沿用上次配置',
              textAlign: TextAlign.center,
              style: caption,
            ),
          ],
        );
        return Container(
          key: const ValueKey('ai-transcription-resume-card'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.035),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '$mode · ${failed ? '处理失败' : '已停止'}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(time == null ? '可继续上次任务' : '已处理至 $time', style: caption),
              if (failed && message.isNotEmpty) ...[
                const SizedBox(height: 6),
                OperationStatus(
                  title: transcriptionFailureSummary(message),
                  kind: OperationStatusKind.error,
                  details: safeOperationDiagnostic(message),
                ),
              ],
              if (changed) ...[
                const SizedBox(height: 8),
                Text(
                  '当前设置与上次任务不同，继续任务仍使用上次配置。',
                  key: const ValueKey('ai-transcription-settings-changed'),
                  style: caption.copyWith(color: Colors.amberAccent),
                ),
              ],
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
                  // Leave room for the cancel control beside Continue.
                  if (constraints.maxWidth < 358 * scale) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        action(restart: false),
                        const SizedBox(height: 10),
                        action(restart: true),
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: action(restart: false)),
                      const SizedBox(width: 10),
                      Expanded(child: action(restart: true)),
                    ],
                  );
                },
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: DesktopButtonClickRegion(
                  child: TextButton(
                    key: const ValueKey('ai-transcription-saved-configuration'),
                    onPressed: () => _showSavedConfiguration(manager),
                    child: const Text('查看任务配置'),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showSavedConfiguration(TranscriptionManager manager) async {
    final saved = manager.configurationForVideo(
      widget.videoPath,
      videoId: widget.videoId,
    );
    final model = saved?.transcription;
    final translation = saved?.translation;
    final rows = <(String, String)>[
      ('任务', translation?.enabled == true ? '转录并翻译' : '转录'),
      ('转录模型', model?.profile.name ?? '尚未开始处理'),
      if (model != null)
        ('识别语言', subtitleLanguageLabel(model.profile.language)),
      if (model?.asrEnhancements?.hotwords.isNotEmpty == true)
        ('任务热词', model!.asrEnhancements!.hotwords),
      if (model?.profile.local == true)
        (
          '识别线程',
          model!.requestedAsrThreads == 0
              ? '自动'
              : '${model.requestedAsrThreads}',
        ),
      if (saved?.punctuation != null) ('标点处理', saved!.punctuation!.label),
      if (translation?.enabled == true) ...[
        ('翻译方式', subtitleTranslateProviderLabels[translation!.provider]!),
        if (translation.localSpecification != null)
          ('翻译模型', translation.localSpecification!.profile.name),
        if (translation.apiEndpoint != null)
          ('翻译模型', translation.apiEndpoint!.model),
        (
          '翻译语言',
          translation.smartPolicy?.summary ??
              '${subtitleLanguageLabel(translation.sourceLanguage ?? 'auto')} → ${subtitleLanguageLabel(translation.targetLanguage ?? 'zh-CN')}',
        ),
        if (translation.apiEndpoint != null) ...[
          (
            '翻译批量',
            '每批 ${translation.aiOptions.batchSize} 条 · 并发 ${translation.aiOptions.threadNum}',
          ),
          ('翻译反思', translation.aiOptions.reflect ? '开启' : '关闭'),
          if (translation.aiOptions.customPrompt.isNotEmpty)
            ('翻译提示词', translation.aiOptions.customPrompt),
        ],
      ],
    ];
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('上次任务配置'),
        scrollable: true,
        content: SizedBox(
          width: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('继续任务将沿用这些设置。调整当前设置后，可通过“重新开始”应用。'),
              const SizedBox(height: 14),
              for (final (label, value) in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '$label：',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        TextSpan(text: value),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          DesktopButtonClickRegion(
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInlineProgressSection({
    required TranscriptionManager manager,
    required bool isJobForThisVideo,
    required bool isProcessing,
    required bool isQueued,
    required bool hasGeneratedSrt,
    required int queuePosition,
    required bool canQueueCurrentVideo,
  }) {
    if (manager.isVideoPaused(widget.videoPath, videoId: widget.videoId) ||
        manager.isVideoFailed(widget.videoPath, videoId: widget.videoId)) {
      return const SizedBox.shrink();
    }
    if (isQueued) {
      final String queueText = queuePosition > 0
          ? "已加入队列，当前顺位：$queuePosition"
          : "已加入队列，等待处理中";
      return _buildStatusCard(
        icon: Icons.queue,
        borderColor: Colors.orange.withValues(alpha: 0.5),
        bgColor: Colors.orange.withValues(alpha: 0.12),
        title: "排队中",
        message: queueText,
      );
    }

    if (isProcessing && isJobForThisVideo) {
      final double progress = manager.progress.clamp(0.0, 1.0);
      final String message = manager.statusMessage.trim().isEmpty
          ? "正在处理，请稍候..."
          : manager.statusMessage;
      return _buildProgressCard(
        progress: progress,
        statusMessage: message,
        status: manager.status,
        translationProgress: manager.translationProgress,
        localAsrProgress: manager.localAsrProgress,
        audioProgress: manager.localAudioProgress,
      );
    }

    if (manager.status == TranscriptionStatus.error && isJobForThisVideo) {
      _terminalStatusForCurrentVideo = TranscriptionStatus.error;
      _terminalMessageForCurrentVideo = manager.statusMessage.trim().isEmpty
          ? "转录失败"
          : manager.statusMessage;
    }

    if (hasGeneratedSrt) {
      _terminalStatusForCurrentVideo = TranscriptionStatus.completed;
      if (_terminalMessageForCurrentVideo.trim().isEmpty) {
        _terminalMessageForCurrentVideo = "转录完成，可直接使用生成字幕";
      }
    }

    if (_terminalStatusForCurrentVideo == TranscriptionStatus.completed) {
      return const SizedBox.shrink();
    }

    if (_terminalStatusForCurrentVideo == TranscriptionStatus.error) {
      return OperationStatus(
        title: '语音转录未能完成',
        message: _startupErrorDetails != null
            ? _terminalMessageForCurrentVideo
            : transcriptionFailureSummary(_terminalMessageForCurrentVideo),
        kind: OperationStatusKind.error,
        details:
            _startupErrorDetails ??
            safeOperationDiagnostic(_terminalMessageForCurrentVideo),
      );
    }

    if (_hasRequestedForCurrentVideo && !canQueueCurrentVideo) {
      return _buildStatusCard(
        icon: Icons.info_outline,
        borderColor: Colors.blueGrey.withValues(alpha: 0.5),
        bgColor: Colors.blueGrey.withValues(alpha: 0.15),
        title: "任务状态",
        message: "任务状态同步中，请稍候...",
      );
    }

    return _buildStatusCard(
      icon: Icons.tips_and_updates_outlined,
      borderColor: Colors.blueGrey.withValues(alpha: 0.35),
      bgColor: Colors.blueGrey.withValues(alpha: 0.1),
      title: "提示",
      message: "点击“开始语音转录”后，将在此处持续显示处理进度与状态。",
    );
  }

  Widget _buildProgressCard({
    required double progress,
    required String statusMessage,
    required TranscriptionStatus status,
    double? translationProgress,
    LocalAsrProgress? localAsrProgress,
    TranscriptionAudioProgress? audioProgress,
  }) {
    final waiting = TranscriptionProgress.isWaiting(status, statusMessage);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.sync, size: 16, color: Colors.blueAccent),
              const SizedBox(width: 6),
              Expanded(
                child: audioProgress != null
                    ? TranscriptionAudioProgressLabel(
                        progress: audioProgress,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      )
                    : Text(
                        TranscriptionProgress.stage(status, statusMessage),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
              if (audioProgress == null)
                Text(
                  waiting ? '等待结果' : '总进度 ${(progress * 100).floor()}%',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
            ],
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: audioProgress?.fraction ?? progress,
            minHeight: 6,
            backgroundColor: Colors.white10,
            valueColor: const AlwaysStoppedAnimation<Color>(Colors.blueAccent),
            borderRadius: BorderRadius.circular(999),
          ),
          const SizedBox(height: 10),
          if (localAsrProgress != null) ...[
            LocalAsrProgressView(
              progress: localAsrProgress,
              foregroundColor: Colors.white70,
            ),
            const SizedBox(height: 10),
          ],
          if (translationProgress != null) ...[
            Text(
              '翻译 ${(translationProgress * 100).floor()}%',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: translationProgress.clamp(0.0, 1.0),
              minHeight: 3,
              backgroundColor: Colors.white10,
              borderRadius: BorderRadius.circular(999),
            ),
            const SizedBox(height: 10),
          ],
          Text(
            statusMessage,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          if (waiting) ...[
            const SizedBox(height: 8),
            const LinearProgressIndicator(minHeight: 2),
            const SizedBox(height: 6),
            const Text(
              '音频已提交，正在等待获取识别结果',
              style: TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatusCard({
    required IconData icon,
    required Color borderColor,
    required Color bgColor,
    required String title,
    required String message,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Colors.white70, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
