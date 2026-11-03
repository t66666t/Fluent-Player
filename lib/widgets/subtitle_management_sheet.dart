import 'package:video_player_app/widgets/dialog_keyboard_viewport.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'keyboard_inset_padding.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../services/embedded_subtitle_service.dart';
import '../models/subtitle_source_type.dart';
import '../models/subtitle_classification.dart';
import '../services/library_service.dart';
import '../services/media_playback_service.dart';
import '../services/streaming_subtitle_store.dart';
import '../services/subtitle_stream_source.dart';
import 'subtitle_stream_provider.dart';
import '../models/subtitle_stream.dart';
import '../services/task_subtitle_storage_service.dart';
import '../models/managed_subtitle_asset.dart';
import '../services/ai_subtitle_api_settings.dart';
import '../services/ai_subtitle_translator.dart';
import '../services/subtitle_translate_settings.dart';
import '../services/subtitle_manual_translation_settings.dart';
import 'translation_language_controls.dart';
import 'ai_subtitle_api_dialog.dart';
import '../services/subtitle_translation_service.dart';
import '../services/subtitle_discovery_service.dart';
import 'operation_status.dart';
import '../utils/reveal_in_file_manager.dart';
import '../utils/subtitle_parser.dart';
import '../utils/timed_subtitle_parser.dart';
import '../models/subtitle_model.dart';
import '../services/subtitle_word_timing_store.dart';
import '../utils/subtitle_file_matcher.dart';
import '../services/bilibili/bilibili_shared_subtitles.dart';
import '../services/bilibili/bilibili_subtitle_tracks.dart';
import '../features/cloud_drive/services/cloud_drive_subtitle_tracks.dart';
import 'bilibili_subtitle_tracks_section.dart';
import 'cloud_drive_subtitle_tracks_section.dart';
import 'landscape_sidebar_layout.dart';
import 'music_lyric_search_dialog.dart';
import 'model_center_button.dart';
import '../features/model_center/model_center_screen.dart';
import 'subtitle_row_action_menu.dart';
import 'subtitle_management_tile.dart';
import 'subtitle_search_dialog.dart';
import '../features/subtitle_search/subtitle_search_models.dart';
import '../features/subtitle_search/subtitle_search_importer.dart';
import '../features/subtitle_search/subtitle_batch_matcher.dart';
import '../models/video_item.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

@visibleForTesting
Future<bool> showSubtitleDeletionConfirmationDialog(
  BuildContext context, {
  required String fileName,
  required bool isSidecar,
  required bool isExternal,
  bool useCupertinoStyle = false,
}) async {
  final message = isSidecar
      ? '这是视频同目录下的伴随字幕。删除磁盘文件后，所有使用该视频的任务都将无法再看到它。\n\n确定删除 $fileName 吗？'
      : isExternal
      ? '这是任务目录之外的外部字幕。删除会直接移除原始磁盘文件，其他引用该文件的地方也会受影响。\n\n确定删除 $fileName 吗？'
      : '确定要删除 $fileName 吗？';
  return await showDialog<bool>(
        context: context,
        builder: (dialogContext) => useCupertinoStyle
            ? CupertinoAlertDialog(
                title: Text(isExternal ? '删除外部字幕文件' : '删除字幕'),
                content: Text(message),
                actions: [
                  CupertinoDialogAction(
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: const Text('取消'),
                  ),
                  CupertinoDialogAction(
                    isDestructiveAction: true,
                    onPressed: () => Navigator.pop(dialogContext, true),
                    child: const Text('删除'),
                  ),
                ],
              )
            : AlertDialog(
                backgroundColor: const Color(0xFF2C2C2C),
                title: Text(
                  isExternal ? '删除外部字幕文件' : '删除字幕',
                  style: const TextStyle(color: Colors.white),
                ),
                content: Text(
                  message,
                  style: const TextStyle(color: Colors.white70),
                ),
                actions: [
                  DesktopButtonClickRegion(
                    child: TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('取消'),
                    ),
                  ),
                  DesktopButtonClickRegion(
                    child: TextButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                      ),
                      child: const Text('删除'),
                    ),
                  ),
                ],
              ),
      ) ??
      false;
}

enum SubtitleManagementAppearance { standard, musicIOS }

class SubtitleManagementSheet extends StatefulWidget {
  final String videoPath;
  final String? videoId;
  final VoidCallback onSubtitleChanged;
  final VoidCallback onOpenAi;

  /// Supplied for video media on platforms that support OCR subtitles.
  final VoidCallback? onOpenOcrSubtitle;
  final Function(List<String> paths)? onSubtitleSelected;
  final Function(String path)? onSubtitlePreview; // New callback
  final VoidCallback? onClose;

  /// 歌词搜索。音乐页会带上歌手名；不传时字幕管理按当前正在播放的媒体自己打开。
  final Future<void> Function()? onSearchLyrics;
  final Map<String, String>? associatedSubtitles;
  final Map<String, String>? localSubtitles;
  final List<String> initialSelectedPaths;
  final bool showEmbeddedSubtitles;
  final SubtitleManagementAppearance appearance;
  final bool showHeader;

  @visibleForTesting
  final Future<bool> Function(String path)? revealSavedSubtitle;

  @visibleForTesting
  final SubtitleDiscoveryService? discoveryService;

  /// The Bilibili subtitle tracks of the video, listed as「B 站字幕」in place
  /// of the bound download subtitles. Null for other videos.
  final BilibiliSubtitleTracks? bilibiliTracks;

  /// Official cloud subtitles for this card. Null for other videos.
  final CloudDriveSubtitleTracks? cloudDriveTracks;
  final String? embeddedProbePath;
  final String? embeddedError;
  final VoidCallback? onRetryEmbedded;

  const SubtitleManagementSheet({
    super.key,
    required this.videoPath,
    this.videoId,
    required this.onSubtitleChanged,
    required this.onOpenAi,
    this.onOpenOcrSubtitle,
    this.onSubtitleSelected,
    this.onSubtitlePreview,
    this.onClose,
    this.onSearchLyrics,
    this.associatedSubtitles,
    this.localSubtitles,
    this.initialSelectedPaths = const [],
    this.showEmbeddedSubtitles = true,
    this.appearance = SubtitleManagementAppearance.standard,
    this.showHeader = true,
    this.revealSavedSubtitle,
    this.discoveryService,
    this.bilibiliTracks,
    this.cloudDriveTracks,
    this.embeddedProbePath,
    this.embeddedError,
    this.onRetryEmbedded,
  });

  @override
  State<SubtitleManagementSheet> createState() =>
      _SubtitleManagementSheetState();
}

class _SubtitleManagementSheetState extends State<SubtitleManagementSheet> {
  bool get _isMusicIOS =>
      widget.appearance == SubtitleManagementAppearance.musicIOS;

  BoxDecoration _subtitleRowDecoration(Color accent, {String? path}) {
    if (_isMusicIOS) {
      return BoxDecoration(
        color: Colors.white.withValues(alpha: 0.055),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.035)),
      );
    }
    return BoxDecoration(
      color: accent.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: accent.withValues(alpha: 0.2)),
    );
  }

  EdgeInsets get _rowMargin => EdgeInsets.only(bottom: _isMusicIOS ? 10 : 4);
  String _formatFileSize(int bytes) =>
      '${(bytes / 1024).toStringAsFixed(1)} KB';

  Future<void> _showMusicActions(
    String title,
    List<(String, VoidCallback, bool)> actions,
  ) async {
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text(title),
        actions: actions
            .map(
              (action) => CupertinoActionSheetAction(
                isDestructiveAction: action.$3,
                onPressed: () {
                  Navigator.of(ctx).pop();
                  action.$2();
                },
                child: Text(action.$1),
              ),
            )
            .toList(),
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('取消'),
        ),
      ),
    );
  }

  Widget _buildMusicRow({
    required String label,
    required String description,
    String? path,
    VoidCallback? onTap,
    List<Widget> badges = const [],
    required List<(String, VoidCallback, bool)> actions,
    Widget expanded = const SizedBox.shrink(),
    bool busy = false,
  }) {
    final selected = path == null ? -1 : _selectedIndexOf(path);
    return Container(
      margin: _rowMargin,
      decoration: _subtitleRowDecoration(Colors.white, path: path),
      child: Column(
        children: [
          CupertinoListTile(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            leading: busy
                ? const CupertinoActivityIndicator()
                : Icon(
                    selected >= 0
                        ? CupertinoIcons.checkmark_circle_fill
                        : CupertinoIcons.doc_text,
                    color: selected >= 0
                        ? const Color(0xFFFA586A)
                        : Colors.white60,
                    size: 22,
                  ),
            title: Row(
              children: [
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                for (final badge in badges)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: badge,
                  ),
              ],
            ),
            subtitle: Text(
              selected == 0
                  ? '主字幕 · $description'
                  : selected == 1
                  ? '副字幕 · $description'
                  : description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white38,
                fontSize: 12,
                height: 1.5,
              ),
            ),
            trailing: actions.isEmpty
                ? null
                : SubtitleRowActionMenuButton(
                    key: ValueKey('music-subtitle-actions-${path ?? label}'),
                    actions: [
                      for (final action in actions)
                        SubtitleRowAction(
                          label: action.$1,
                          onSelected: action.$2,
                          destructive: action.$3,
                        ),
                    ],
                  ),
            onTap: onTap,
          ),
          expanded,
        ],
      ),
    );
  }

  Widget _buildPrimaryAction({
    required String label,
    required IconData icon,
    required VoidCallback onPressed,
    required LandscapeSidebarLayout layout,
    bool emphasized = false,
    bool stacked = false,
  }) {
    if (_isMusicIOS) {
      return CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        color: emphasized
            ? const Color(0xFFFA586A)
            : Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        onPressed: onPressed,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: Colors.white),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );
    }
    final style = ElevatedButton.styleFrom(
      backgroundColor: emphasized ? Colors.blueAccent : Colors.white10,
      foregroundColor: Colors.white,
      minimumSize: Size.fromHeight(layout.controlHeight),
      padding: EdgeInsets.symmetric(vertical: layout.verticalPadding / 2),
    );
    final text = Text(label, style: TextStyle(fontSize: layout.bodySize));
    if (stacked) {
      return DesktopButtonClickRegion(
        child: ElevatedButton(
          onPressed: onPressed,
          style: style,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18),
              const SizedBox(height: 4),
              FittedBox(fit: BoxFit.scaleDown, child: text),
            ],
          ),
        ),
      );
    }
    return DesktopButtonClickRegion(
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: text,
        style: style,
      ),
    );
  }

  static final RegExp _extractedTrackPattern = RegExp(
    r'\.stream_(\d+)(?:\.[^.]+)?$',
    caseSensitive: false,
  );
  List<File> _subtitleFiles = [];
  List<EmbeddedSubtitleTrack> _embeddedTracks = [];
  bool _isScanningFiles = true;
  bool _isScanningSidecars = false;
  bool _isScanningEmbedded = false;
  int _scanGeneration = 0;
  final Map<String, int> _subtitleFileSizes = <String, int>{};
  final Set<String> _sidecarSubtitlePaths = <String>{};
  final Set<String> _taskSubtitlePaths = <String>{};

  /// Files of this online Bilibili part that live outside the open card's
  /// own task folder: the shared part folder, and sibling cards' task folders.
  final Set<String> _partSubtitlePaths = <String>{};

  /// 同目录伴随字幕的匹配等级（供"建议匹配/名称不匹配"标注展示）。
  final Map<String, SubtitleMatchGrade> _sidecarGrade =
      <String, SubtitleMatchGrade>{};
  int? _extractingTrackIndex;
  bool _exportingSubtitle = false;
  String? _feedbackTitle;
  String? _feedbackMessage;
  String? _feedbackDiagnostic;
  String? _feedbackPath;
  Future<void> Function()? _feedbackRetry;
  bool _retryingFeedback = false;
  List<String> _selectedPaths = []; // Track selected items
  String? _customDownloadPath;
  String _defaultDownloadPath = "用户/下载";

  final Map<int, String> _extractedTrackPaths =
      {}; // Map track index to extracted path

  final SubtitleTranslationService _subtitleTranslationService =
      SubtitleTranslationService.instance;
  String? _expandedTranslatePath;
  // 翻译状态由服务（单例）持有，UI 通过监听器刷新，跨页面重建可恢复进度。
  // _translateSourceLanguage / _translateTargetLanguage / _translateProvider
  // 展示当前服务的语言偏好；实际翻译在启动时捕获独立快照。
  String _translateSourceLanguage = 'auto';
  String _translateTargetLanguage = 'zh-CN';
  SubtitleTranslateProvider _translateProvider = SubtitleTranslateProvider.bing;

  /// 当前是否有针对 [path] 的翻译任务在进行。
  bool _isPathTranslating(String? path) {
    return path != null &&
        _subtitleTranslationService.isTranslatingPathForVideo(
          videoPath: widget.videoPath,
          inputPath: path,
        );
  }

  bool _isActiveTranslationForCurrentVideo() {
    return _subtitleTranslationService.isTranslatingForVideo(widget.videoPath);
  }

  bool _isTranslationPanelExpandedFor(String path) {
    final expandedPath = _expandedTranslatePath;
    return expandedPath != null &&
        _normalizePath(expandedPath) == _normalizePath(path);
  }

  void _restoreActiveTranslationUi() {
    if (!_isActiveTranslationForCurrentVideo()) return;
    final activeInputPath = _subtitleTranslationService.activeInputPath;
    if (activeInputPath == null || activeInputPath.isEmpty) return;

    // Restore the panel as well as the service state so progress is visible as
    // soon as the fresh subtitle scan renders the active source file.
    _expandedTranslatePath = p.normalize(activeInputPath);
    final sourceLanguage = _subtitleTranslationService.activeSourceLanguage;
    final targetLanguage = _subtitleTranslationService.activeTargetLanguage;
    final provider = _subtitleTranslationService.activeProvider;
    if (sourceLanguage != null && _containsSourceLanguage(sourceLanguage)) {
      _translateSourceLanguage = sourceLanguage;
    }
    if (targetLanguage != null && _containsTargetLanguage(targetLanguage)) {
      _translateTargetLanguage = targetLanguage;
    }
    if (provider != null) {
      _translateProvider = provider;
    }
  }

  bool _manualTranslateMode = false;
  bool _manualPromptSubtitleFirst = true;
  bool _isLoadingManualSource = false;
  String? _manualLoadedSourcePath;

  static const String _manualPromptEditableDefault =
      SubtitleManualTranslationSettings.defaultPrompt;

  final TextEditingController _manualSourceController = TextEditingController();
  final TextEditingController _manualPromptController = TextEditingController(
    text: _manualPromptEditableDefault,
  );
  final TextEditingController _aiPromptController = TextEditingController();
  final FocusNode _aiPromptFocus = FocusNode();
  AiSubtitleTranslationSettings _aiOptions =
      AiSubtitleTranslationSettings.defaults;
  AiSubtitleBinding? _aiBinding;
  SubtitleTranslateSettings? _sharedTranslateSettings;
  SubtitleTranslateSettings? _ownedTranslateSettings;

  Timer? _translatePrefsSaveDebounce;
  bool _isApplyingTranslatePrefs = false;

  static const String _prefKeyTranslateMode =
      SubtitleManualTranslationSettings.enabledKey;
  static const String _prefKeyManualPromptOrder =
      SubtitleManualTranslationSettings.subtitleFirstKey;
  static const String _prefKeyManualPromptEditable =
      SubtitleManualTranslationSettings.promptKey;

  /// `ai.srt` and `ai.2.srt` are the files the transcriber writes.
  bool _isGeneratedAiFileName(String name) {
    return RegExp(r'^ai(\.\d+)?\.srt$', caseSensitive: false).hasMatch(name);
  }

  String _normalizePath(String path) {
    final normalized = p.normalize(path);
    if (Platform.isWindows) {
      return normalized.toLowerCase();
    }
    return normalized;
  }

  int _selectedIndexOf(String path) {
    final key = _normalizePath(path);
    for (int i = 0; i < _selectedPaths.length; i++) {
      if (_normalizePath(_selectedPaths[i]) == key) {
        return i;
      }
    }
    return -1;
  }

  bool _selectedContains(String path) => _selectedIndexOf(path) != -1;

  List<String> _normalizeSelectedPaths(List<String> input) {
    final keys = <String>{};
    final output = <String>[];
    for (final item in input) {
      if (item.isEmpty) continue;
      final normalized = p.normalize(item);
      final key = _normalizePath(normalized);
      if (keys.add(key)) {
        output.add(normalized);
      }
    }
    return output;
  }

  int? _streamIndexFromExtractedPath(String path) {
    final match = _extractedTrackPattern.firstMatch(p.basename(path));
    if (match == null) return null;
    return int.tryParse(match.group(1) ?? '');
  }

  bool _matchesCurrentVideoExtractedFile(String path, Set<String> prefixes) {
    final fileName = p.basename(path);
    if (!fileName.contains('.stream_')) {
      return false;
    }
    for (final prefix in prefixes) {
      if (prefix.isNotEmpty && fileName.startsWith('$prefix.stream_')) {
        return true;
      }
    }
    return false;
  }

  void _registerExtractedTrackPath(
    String path, {
    required Set<String> extractedPrefixes,
  }) {
    final normalized = p.normalize(path);
    if (!_matchesCurrentVideoExtractedFile(normalized, extractedPrefixes)) {
      return;
    }
    final index = _streamIndexFromExtractedPath(normalized);
    if (index == null) return;
    _extractedTrackPaths[index] = normalized;
  }

  bool _isImageSubtitleCodec(String codecName) {
    final codec = codecName.toLowerCase();
    return codec == 'hdmv_pgs_subtitle' ||
        codec == 'dvd_subtitle' ||
        codec == 'pgs' ||
        codec == 'pgs_subtitle' ||
        codec == 'vobsub' ||
        codec == 'xsub';
  }

  CloudDriveSubtitleTracks? _watchedCloudTracks;
  SubtitleStreamSource? _streamManager;
  Timer? _streamFilesTimer;

  void _onStreamingFiles() {
    if (!mounted) return;
    final urgent = _streamManager!.subtitleStreams.any(
      (stream) =>
          (stream.videoId == widget.videoId ||
              stream.videoPath == widget.videoPath) &&
          stream.phase != SubtitleStreamPhase.generating,
    );
    if (urgent) {
      _streamFilesTimer?.cancel();
      _streamFilesTimer = null;
      _applyStreamingFiles();
    } else {
      _streamFilesTimer ??= Timer(const Duration(seconds: 1), () {
        _streamFilesTimer = null;
        _applyStreamingFiles();
      });
    }
  }

  void _applyStreamingFiles() {
    if (!mounted || _streamManager == null) return;
    setState(_mergeStreamingFiles);
  }

  void _mergeStreamingFiles() {
    for (final stream
        in _streamManager?.subtitleStreams ?? const <SubtitleStreamUpdate>[]) {
      if (stream.videoId != widget.videoId &&
          stream.videoPath != widget.videoPath) {
        continue;
      }
      for (final path in stream.paths) {
        final key = _normalizePath(path);
        _subtitleFileSizes[key] = path == stream.primaryPath
            ? stream.primaryBytes
            : stream.secondaryBytes;
        if (!_subtitleFiles.any((file) => _normalizePath(file.path) == key)) {
          _subtitleFiles.add(File(path));
        }
        _taskSubtitlePaths.add(key);
      }
    }
  }

  String _streamDescription(String path) {
    final stream = _streamManager?.streamForPath(path);
    if (stream == null) return '';
    final phase = switch (stream.phase) {
      SubtitleStreamPhase.generating => '生成中',
      SubtitleStreamPhase.stopping => '正在停止',
      SubtitleStreamPhase.paused => '已暂停',
      SubtitleStreamPhase.failed => '出错可续传',
      SubtitleStreamPhase.complete => '已完成',
    };
    final seconds = stream.processedThrough.inSeconds;
    final position =
        '${seconds ~/ 60}:'
        '${(seconds % 60).toString().padLeft(2, '0')}';
    return ' · $phase · ${stream.cueCount} 条 · 已处理 $position';
  }

  Widget _streamAction(String path) {
    final stream = _streamManager?.streamForPath(path);
    if (stream == null || stream.complete) return const SizedBox.shrink();
    final running =
        stream.phase == SubtitleStreamPhase.generating ||
        stream.phase == SubtitleStreamPhase.stopping;
    return DesktopButtonClickRegion(
      child: IconButton(
        tooltip: running ? '停止并保留进度' : '继续生成',
        icon: Icon(
          running ? Icons.stop_circle_outlined : Icons.play_circle_outline,
          size: 20,
        ),
        onPressed: stream.phase == SubtitleStreamPhase.stopping
            ? null
            : () {
                if (running) {
                  unawaited(_streamManager!.stopStreamForPath(path));
                } else {
                  _streamManager!.resumeStreamForPath(path);
                }
              },
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
      ),
    );
  }

  void _bindCloudTracks(CloudDriveSubtitleTracks? tracks) {
    _watchedCloudTracks = tracks;
    tracks?.addListener(_onCloudTracksChanged);
  }

  void _onCloudTracksChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _bindCloudTracks(widget.cloudDriveTracks);
    try {
      _streamManager = lookupSubtitleStreams(context);
      _streamManager?.subtitleFilesRevision.addListener(_onStreamingFiles);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _applyStreamingFiles(),
      );
    } on ProviderNotFoundException {
      /* Standalone subtitle tools have no ASR. */
    }
    _selectedPaths = _normalizeSelectedPaths(widget.initialSelectedPaths);
    _manualPromptController.addListener(_onManualPromptChanged);
    _aiPromptController.addListener(_onAiPromptChanged);
    _subtitleTranslationService.addListener(_onTranslationChanged);
    _subtitleTranslationService.addCompletionCallback(_onTranslationComplete);
    _restoreActiveTranslationUi();
    _loadSubtitles();
    _initDefaultPath();
    _loadCustomDownloadPath();
    _loadTranslatePanelPreferences();
    _refreshAiBinding();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final shared =
        lookupSubtitleTranslateSettings(context, listen: false) ??
        (_ownedTranslateSettings ??= SubtitleTranslateSettings());
    if (identical(shared, _sharedTranslateSettings)) return;
    _sharedTranslateSettings?.removeListener(_onSharedTranslateSettings);
    _sharedTranslateSettings = shared;
    _sharedTranslateSettings?.addListener(_onSharedTranslateSettings);
    unawaited(
      shared.ensureLoaded().then((_) {
        if (mounted) _onSharedTranslateSettings();
      }),
    );
  }

  @override
  void dispose() {
    _streamFilesTimer?.cancel();
    _streamManager?.subtitleFilesRevision.removeListener(_onStreamingFiles);
    _watchedCloudTracks?.removeListener(_onCloudTracksChanged);
    _translatePrefsSaveDebounce?.cancel();
    _sharedTranslateSettings?.removeListener(_onSharedTranslateSettings);
    _saveTranslatePanelPreferences();
    _subtitleTranslationService.removeListener(_onTranslationChanged);
    _subtitleTranslationService.removeCompletionCallback(
      _onTranslationComplete,
    );
    _manualPromptController.removeListener(_onManualPromptChanged);
    _aiPromptController.removeListener(_onAiPromptChanged);
    _manualSourceController.dispose();
    _manualPromptController.dispose();
    _aiPromptController.dispose();
    _aiPromptFocus.dispose();
    _ownedTranslateSettings?.dispose();
    super.dispose();
  }

  void _onTranslationChanged() {
    if (!mounted) return;
    setState(() {});
  }

  /// 翻译完成回调。即便发起翻译的 UI 已销毁，只要重开后重新注册即可接收。
  void _onTranslationComplete(SubtitleTranslationCompletion completion) {
    if (!mounted) return;
    if (!_sameVideoPath(completion.videoPath)) return;
    // Completion updates only this media's files and inline state.
    if (completion.isSuccess && completion.result != null) {
      _clearSubtitleFeedback();
      _loadSubtitles();
      _notifySubtitleFilesChanged();
      setState(() {
        _expandedTranslatePath = null;
      });
    } else if (completion.error != null) {
      final failedPath =
          _subtitleTranslationService.activeInputPath ?? _expandedTranslatePath;
      unawaited(
        _showSubtitleFailure(
          '字幕翻译失败',
          '请检查翻译服务、语言设置和网络后重试。',
          error: completion.error,
          retry: failedPath == null
              ? null
              : () => _translateSubtitle(failedPath),
        ),
      );
    }
  }

  Future<void> _showSubtitleFailure(
    String title,
    String message, {
    Object? error,
    Future<void> Function()? retry,
    String? path,
  }) async {
    if (!mounted) return;
    setState(() {
      _feedbackTitle = title;
      _feedbackMessage = error == null
          ? message
          : operationErrorSummary(error, fallback: message);
      _feedbackDiagnostic = error == null
          ? null
          : safeOperationDiagnostic(error);
      _feedbackRetry = retry;
      _feedbackPath = path;
    });
  }

  void _clearSubtitleFeedback() {
    if (!mounted || _feedbackTitle == null) return;
    setState(() {
      _feedbackTitle = null;
      _feedbackMessage = null;
      _feedbackDiagnostic = null;
      _feedbackRetry = null;
      _feedbackPath = null;
    });
  }

  Future<void> _retrySubtitleFeedback() async {
    final retry = _feedbackRetry;
    if (retry == null || _retryingFeedback) return;
    setState(() => _retryingFeedback = true);
    try {
      await retry();
    } finally {
      if (mounted) setState(() => _retryingFeedback = false);
    }
  }

  Widget _buildSubtitleFeedback() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _feedbackTitle!,
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        if (_feedbackMessage?.isNotEmpty == true)
          Text(
            _feedbackMessage!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
        Wrap(
          spacing: 8,
          children: [
            if (_feedbackRetry != null)
              TextButton(
                onPressed: _retryingFeedback ? null : _retrySubtitleFeedback,
                child: Text(_feedbackPath == null ? '重试' : '重试打开位置'),
              ),
            if (_feedbackPath != null)
              TextButton(
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: _feedbackPath!)),
                child: const Text('复制路径'),
              ),
            if (_feedbackDiagnostic != null)
              TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (context) => AlertDialog(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    title: const Text('诊断详情', style: TextStyle(fontSize: 16)),
                    scrollable: true,
                    content: SelectableText(
                      _feedbackDiagnostic!,
                      style: const TextStyle(fontSize: 13),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('关闭'),
                      ),
                    ],
                  ),
                ),
                child: const Text('诊断详情'),
              ),
          ],
        ),
      ],
    ),
  );

  bool _sameVideoPath(String path) =>
      _normalizePath(path) == _normalizePath(widget.videoPath);

  void _notifySubtitleFilesChanged() {
    try {
      Provider.of<LibraryService>(
        context,
        listen: false,
      ).notifySubtitleFilesChanged(videoId: widget.videoId);
    } catch (_) {
      // Isolated previews/tests may host the sheet without LibraryService.
    }
    widget.onSubtitleChanged();
  }

  String _requireVideoId() {
    final videoId = widget.videoId?.trim() ?? '';
    if (videoId.isEmpty) {
      throw StateError('当前媒体没有任务 ID，无法创建任务字幕');
    }
    return videoId;
  }

  /// 歌词搜索盖在字幕管理上面。关掉之后再刷新列表，刚导入的歌词才会出现。
  ///
  /// 音乐页传入带歌手名的搜索。横屏和竖屏播放页共用这张表，没有单独回调时
  /// 按当前正在播放的媒体打开同一套搜索。
  Future<void> _openLyricSearch() async {
    _clearSubtitleFeedback();
    try {
      final search = widget.onSearchLyrics;
      if (search != null) {
        await search();
      } else {
        LibraryService? library;
        MediaPlaybackService? playback;
        try {
          library = context.read<LibraryService>();
        } catch (_) {
          library = null;
        }
        try {
          playback = context.read<MediaPlaybackService>();
        } catch (_) {
          playback = null;
        }
        final videoId = widget.videoId?.trim() ?? '';
        final item =
            (videoId.isEmpty ? null : library?.getVideo(videoId)) ??
            playback?.currentItem;
        if (item == null) {
          await _showSubtitleFailure('无法搜索歌词', '请先打开一个媒体文件。');
          return;
        }
        await showMusicLyricSearchDialog(context, item: item);
      }
    } catch (error) {
      if (mounted) {
        await _showSubtitleFailure(
          '无法搜索歌词',
          '请检查网络后重试。',
          error: error,
          retry: () => _openLyricSearch(),
        );
      }
    }
    if (!mounted) return;
    try {
      final playback = context.read<MediaPlaybackService>();
      if (playback.currentItem?.id == widget.videoId &&
          playback.subtitlePaths.isNotEmpty) {
        setState(() {
          _selectedPaths = _normalizeSelectedPaths(
            List<String>.of(playback.subtitlePaths),
          );
        });
      }
    } catch (_) {
      // 没有播放服务的预览只刷新文件列表。
    }
    await _loadSubtitles();
  }

  /// 宽区域并排，窄区域上下叠放，避免「搜索在线字幕」被挤成省略号。
  Widget _buildSearchEntries({required bool paired}) {
    final lyric = _searchEntry(
      key: const ValueKey('subtitle-lyric-search-entry'),
      label: '搜索歌词',
      detail: '网易云 · QQ 音乐',
      icon: Icons.manage_search_rounded,
      color: const Color(0xFFFA586A),
      paired: paired,
      onTap: () => unawaited(_openLyricSearch()),
    );
    final online = _searchEntry(
      key: const ValueKey('subtitle-online-search-entry'),
      label: '搜索在线字幕',
      detail: '电影 · 美剧 · 日语动漫',
      icon: Icons.travel_explore_rounded,
      color: const Color(0xFF7DE2CB),
      paired: paired,
      onTap: _searchOnlineSubtitles,
    );
    if (!paired) {
      return Column(children: [lyric, const SizedBox(height: 8), online]);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: lyric),
        const SizedBox(width: 8),
        Expanded(child: online),
      ],
    );
  }

  Widget _searchEntry({
    required Key key,
    required String label,
    required String detail,
    required IconData icon,
    required Color color,
    required bool paired,
    required VoidCallback onTap,
  }) {
    return Material(
      color: color.withValues(alpha: .09),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        key: key,
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: paired ? 10 : 12,
            vertical: paired ? 10 : 12,
          ),
          child: Row(
            children: [
              Icon(icon, color: color, size: paired ? 20 : 22),
              SizedBox(width: paired ? 8 : 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: color,
                        fontSize: paired ? 12 : 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _searchOnlineSubtitles() async {
    final videoId = widget.videoId?.trim() ?? '';
    if (videoId.isEmpty) {
      await _showSubtitleFailure('无法搜索在线字幕', '请先将当前媒体加入媒体库。');
      return;
    }
    final library = context.read<LibraryService>();
    final title =
        library.getVideo(videoId)?.title ??
        p.basenameWithoutExtension(widget.videoPath);
    final current = library.getVideo(videoId);
    final folderId = current?.parentId;
    final batchVideos = current == null
        ? <VideoItem>[]
        : library
              .getVideosInFolder(folderId)
              .where(
                (v) =>
                    v.type == MediaType.video &&
                    (folderId != null ||
                        p.dirname(v.path) == p.dirname(current.path)),
              )
              .toList();
    await showSubtitleSearchDialog(
      context,
      mediaKey: videoId,
      title: title,
      filename: p.basename(widget.videoPath),
      batchTargets: [
        for (final v in batchVideos)
          SubtitleBatchTarget(
            id: v.id,
            title: v.title,
            path: v.path,
            hasSubtitle: v.subtitlePath?.isNotEmpty ?? false,
          ),
      ],
      onBatchImport: (targetId, request, existingPath) async {
        final target = library.getVideo(targetId);
        if (target == null ||
            target.isRecycled ||
            target.parentId != folderId ||
            !batchVideos.any((v) => v.id == targetId)) {
          throw StateError('这个视频已移出原文件夹或被删除，已跳过');
        }
        final path = await const SubtitleSearchImporter().save(
          library: library,
          videoId: targetId,
          request: request,
          existingPath: existingPath,
        );
        if (request.role == SubtitleSearchImportRole.primary) {
          await library.updateVideoSubtitles(
            targetId,
            path,
            false,
            secondarySubtitlePath: target.secondarySubtitlePath == path
                ? null
                : target.secondarySubtitlePath,
            isSecondaryCached: target.isSecondarySubtitleCached,
          );
          if (mounted && widget.videoId == targetId) {
            final paths = SubtitleSearchImporter.selectedPaths(
              _selectedPaths,
              path,
              request.role,
            );
            setState(() => _selectedPaths = paths);
            await widget.onSubtitleSelected?.call(paths);
          }
        }
        if (mounted) {
          unawaited(_loadSubtitles());
          _notifySubtitleFilesChanged();
        }
        return path;
      },
      onImport: (request, existingPath) async {
        if (!mounted ||
            widget.videoId != videoId ||
            library.getVideo(videoId) == null) {
          throw StateError('当前媒体已变化，请返回原视频后再导入字幕');
        }
        if (request.role == SubtitleSearchImportRole.secondary &&
            _selectedPaths.isEmpty) {
          throw StateError('请先选择一条主字幕，再添加副字幕');
        }
        final path = await const SubtitleSearchImporter().save(
          library: library,
          videoId: videoId,
          request: request,
          existingPath: existingPath,
        );
        if (!mounted || widget.videoId != videoId) {
          throw StateError('字幕已保存；请在原视频的字幕管理中选择');
        }
        if (request.role != SubtitleSearchImportRole.saveOnly) {
          final selected = SubtitleSearchImporter.selectedPaths(
            _selectedPaths,
            path,
            request.role,
          );
          setState(() => _selectedPaths = selected);
          await widget.onSubtitleSelected?.call(
            List<String>.from(_selectedPaths),
          );
        }
        if (mounted && widget.videoId == videoId) {
          unawaited(_loadSubtitles());
          _notifySubtitleFilesChanged();
        }
        return path;
      },
    );
  }

  Future<void> _registerManagedSubtitle(
    String path,
    ManagedSubtitleAssetKind kind,
    String displayName, {
    String? sourcePath,
    String? language,
  }) async {
    final videoId = _requireVideoId();
    final library = Provider.of<LibraryService>(context, listen: false);
    final sourceAssetId = sourcePath == null
        ? null
        : library.managedSubtitleAssetForPath(videoId, sourcePath)?.assetId;
    await library.registerManagedSubtitleAsset(
      videoId,
      path: path,
      kind: kind,
      displayName: displayName,
      sourceAssetId: sourceAssetId,
      language: language,
    );
  }

  void _initDefaultPath() {
    if (Platform.isWindows) {
      try {
        final exeDir = p.dirname(Platform.resolvedExecutable);
        _defaultDownloadPath = p.join(exeDir, 'Downloads');
      } catch (e) {
        // Fallback
      }
      return;
    }
    if (Platform.isLinux || Platform.isMacOS) {
      // Resolved asynchronously when opening; placeholder for the path bar.
      _defaultDownloadPath = 'Downloads';
    }
  }

  Future<void> _loadCustomDownloadPath() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final path = prefs.getString('subtitle_download_path');
      if (mounted) {
        setState(() {
          _customDownloadPath = path;
        });
      }
    } catch (e) {
      debugPrint("Error loading custom download path: $e");
    }
  }

  Future<void> _setCustomDownloadPath() async {
    _clearSubtitleFeedback();
    try {
      final String? selectedDirectory = await FilePicker.platform
          .getDirectoryPath();
      if (selectedDirectory != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('subtitle_download_path', selectedDirectory);
        if (mounted) {
          setState(() {
            _customDownloadPath = selectedDirectory;
          });
        }
      }
    } catch (e) {
      await _showSubtitleFailure(
        '导出位置未能保存',
        '请检查所选文件夹权限后重试。',
        error: e,
        retry: _setCustomDownloadPath,
      );
    }
  }

  bool _containsSourceLanguage(String code) {
    for (final lang in _sourceLanguageOptions) {
      if (lang.code == code) return true;
    }
    return false;
  }

  bool _containsTargetLanguage(String code) {
    for (final lang in _targetLanguageOptions) {
      if (lang.code == code) return true;
    }
    return false;
  }

  Future<void> _restoreTranslateLanguageSettings() async {
    final settings = _sharedTranslateSettings;
    if (settings == null) return;
    await settings.ensureLoaded();
    await settings.refreshBinding();
    if (mounted) _onSharedTranslateSettings();
  }

  void _onSharedTranslateSettings() {
    final shared = _sharedTranslateSettings;
    if (!mounted || shared == null || _isApplyingTranslatePrefs) return;
    final prompt = shared.aiOptions.customPrompt;
    final keepPrompt =
        _aiPromptFocus.hasFocus && _aiPromptController.text != prompt;
    setState(() {
      _translateProvider = shared.providerEnZh;
      if (!_isActiveTranslationForCurrentVideo()) {
        _translateSourceLanguage = shared.sourceLanguage;
        _translateTargetLanguage = shared.targetLanguage;
      }
      _aiOptions = keepPrompt
          ? shared.aiOptions.copyWith(customPrompt: _aiPromptController.text)
          : shared.aiOptions;
    });
    if (!keepPrompt && _aiPromptController.text != prompt) {
      _isApplyingTranslatePrefs = true;
      _aiPromptController.text = prompt;
      _isApplyingTranslatePrefs = false;
    }
    unawaited(_refreshAiBinding());
  }

  void _onManualPromptChanged() {
    if (_isApplyingTranslatePrefs) return;
    _scheduleTranslatePrefsSave();
  }

  void _onAiPromptChanged() {
    if (_isApplyingTranslatePrefs) return;
    _aiOptions = _aiOptions.copyWith(customPrompt: _aiPromptController.text);
    _scheduleTranslatePrefsSave();
  }

  void _scheduleTranslatePrefsSave() {
    _translatePrefsSaveDebounce?.cancel();
    _translatePrefsSaveDebounce = Timer(const Duration(milliseconds: 260), () {
      _saveTranslatePanelPreferences();
    });
  }

  Future<void> _openModelSettings() async {
    // Commit pending edits before the shared settings can change on the route.
    _translatePrefsSaveDebounce?.cancel();
    await _saveTranslatePanelPreferences();
    if (!mounted) return;
    await openModelCenter(context, tab: 0);
    if (mounted) _onSharedTranslateSettings();
  }

  Future<void> _saveTranslatePanelPreferences() async {
    // Capture before the first await. dispose() starts this save and then
    // releases the controllers, so a later read would touch a disposed one.
    final aiPrompt = _aiPromptController.text;
    final manualPrompt = _manualPromptController.text;
    final manualMode = _manualTranslateMode;
    final subtitleFirst = _manualPromptSubtitleFirst;
    final aiOptions = _aiOptions.copyWith(customPrompt: aiPrompt);
    final shared = _sharedTranslateSettings;
    try {
      if (shared != null) {
        await shared.setAiOptions(aiOptions);
      }
      final prefs = await SharedPreferences.getInstance();
      if (shared == null) await aiOptions.save();
      await prefs.setBool(_prefKeyTranslateMode, manualMode);
      await prefs.setBool(_prefKeyManualPromptOrder, subtitleFirst);
      await prefs.setString(_prefKeyManualPromptEditable, manualPrompt);
    } catch (e) {
      debugPrint('Error saving translate panel preferences: $e');
    }
  }

  Future<void> _loadTranslatePanelPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final savedManualMode =
          prefs.getBool(_prefKeyTranslateMode) ?? _manualTranslateMode;
      final savedPromptOrder =
          prefs.getBool(_prefKeyManualPromptOrder) ??
          _manualPromptSubtitleFirst;
      final savedEditablePrompt =
          prefs.getString(_prefKeyManualPromptEditable) ??
          _manualPromptEditableDefault;
      final shared = _sharedTranslateSettings;
      if (shared != null) {
        await shared.ensureLoaded();
      }
      final aiOptions =
          shared?.aiOptions ?? await AiSubtitleTranslationSettings.load();
      if (!mounted) return;
      setState(() {
        _aiOptions = aiOptions;
        _translateProvider =
            shared?.providerEnZh ?? SubtitleTranslateProvider.bing;
        _translateSourceLanguage = shared?.sourceLanguage ?? 'auto';
        _translateTargetLanguage = shared?.targetLanguage ?? 'zh-CN';
        _manualTranslateMode = savedManualMode;
        _manualPromptSubtitleFirst = savedPromptOrder;
      });

      _isApplyingTranslatePrefs = true;
      _manualPromptController.text = savedEditablePrompt;
      _aiPromptController.text = aiOptions.customPrompt;
      _isApplyingTranslatePrefs = false;
    } catch (e) {
      debugPrint('Error loading translate panel preferences: $e');
    }
  }

  Future<void> _refreshAiBinding() async {
    try {
      final binding = await AiSubtitleBinding.load();
      if (!mounted) return;
      setState(() => _aiBinding = binding);
    } catch (error) {
      debugPrint('[ai-subtitle] 读取已绑定的 AI 失败: $error');
    }
  }

  /// Opens the translation endpoint only. Chat keeps a separate interface.
  Future<void> _openAiApiSettings() async {
    _clearSubtitleFeedback();
    try {
      final store = AiSubtitleApiSettingsStore();
      final current = await store.load();
      if (!mounted) return;
      final result = await showDialog<AiSubtitleApiSettings>(
        context: context,
        builder: (context) => AiSubtitleApiDialog(settings: current),
      );
      if (result != null) {
        await store.save(result);
      }
      await _refreshAiBinding();
    } catch (error) {
      if (mounted) {
        await _showSubtitleFailure(
          '翻译接口未能保存',
          '请检查接口设置和存储空间后重试。',
          error: error,
          retry: () => _openAiApiSettings(),
        );
      }
    }
  }

  Future<void> _openDownloadDirectory() async {
    _clearSubtitleFeedback();
    String? path;
    try {
      final dir = await _resolveDownloadTargetDir();
      path = dir.path;
      if (!await dir.exists()) {
        throw FileSystemException(
          '导出文件夹不存在',
          path,
          const OSError('not found', 2),
        );
      }
      if (await revealInFileManager(path)) return;
      await _showSubtitleFailure(
        '无法打开导出文件夹',
        '',
        path: path,
        retry: _openDownloadDirectory,
      );
    } catch (error) {
      await _showSubtitleFailure(
        '无法打开导出文件夹',
        '请检查文件夹是否仍存在并允许访问。',
        error: error,
        path: path,
        retry: _openDownloadDirectory,
      );
    }
  }

  @override
  void didUpdateWidget(SubtitleManagementSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.cloudDriveTracks, widget.cloudDriveTracks)) {
      _watchedCloudTracks?.removeListener(_onCloudTracksChanged);
      _bindCloudTracks(widget.cloudDriveTracks);
    }
    if (widget.videoPath != oldWidget.videoPath ||
        widget.videoId != oldWidget.videoId) {
      _clearSubtitleFeedback();
      setState(() {
        _isScanningFiles = true;
        _isScanningSidecars = false;
        _isScanningEmbedded = widget.showEmbeddedSubtitles;
        _subtitleFiles = [];
        _subtitleFileSizes.clear();
        _sidecarSubtitlePaths.clear();
        _embeddedTracks = [];
        _extractingTrackIndex = null;
        _selectedPaths = _normalizeSelectedPaths(widget.initialSelectedPaths);
        _extractedTrackPaths.clear();
      });
      _loadSubtitles();
      return;
    }
    if (widget.initialSelectedPaths != oldWidget.initialSelectedPaths) {
      // Only update if the lengths or contents differ
      bool changed =
          widget.initialSelectedPaths.length !=
          oldWidget.initialSelectedPaths.length;
      if (!changed) {
        for (int i = 0; i < widget.initialSelectedPaths.length; i++) {
          if (widget.initialSelectedPaths[i] !=
              oldWidget.initialSelectedPaths[i]) {
            changed = true;
            break;
          }
        }
      }

      if (changed) {
        setState(() {
          _selectedPaths = _normalizeSelectedPaths(widget.initialSelectedPaths);
        });
      }
    }
  }

  Future<void> _loadSubtitles() async {
    final generation = ++_scanGeneration;
    final embeddedService = Provider.of<EmbeddedSubtitleService>(
      context,
      listen: false,
    );
    if (mounted) {
      setState(() {
        _isScanningFiles = true;
        _isScanningSidecars = false;
        _isScanningEmbedded = widget.showEmbeddedSubtitles;
      });
    }
    unawaited(_loadEmbeddedTracks(generation, embeddedService));

    final filesByPath = <String, File>{};
    final modifiedByPath = <String, DateTime>{};
    List<File> sortedFiles() {
      return filesByPath.values.toList()..sort((first, second) {
        final firstTime = modifiedByPath[_normalizePath(first.path)];
        final secondTime = modifiedByPath[_normalizePath(second.path)];
        if (firstTime == null || secondTime == null) return 0;
        return secondTime.compareTo(firstTime);
      });
    }

    try {
      _extractedTrackPaths.clear();
      _taskSubtitlePaths.clear();
      _partSubtitlePaths.clear();
      final videoName = p.basenameWithoutExtension(
        SubtitleDiscoveryService.localVideoPath(widget.videoPath) ??
            widget.videoPath,
      );
      final extractedPrefixes = <String>{
        videoName,
        if (widget.videoId != null && widget.videoId!.trim().isNotEmpty)
          widget.videoId!.trim(),
      };

      final videoId = widget.videoId?.trim() ?? '';
      LibraryService? library;
      try {
        library = Provider.of<LibraryService>(context, listen: false);
      } catch (_) {}
      if (videoId.isNotEmpty) {
        final taskFiles = await _taskSubtitleStorage(
          library,
        ).listTaskSubtitles(videoId);
        if (!mounted || generation != _scanGeneration) return;
        _taskSubtitlePaths.addAll(
          taskFiles.map((file) => _normalizePath(file.path)),
        );
        // Persistence can wait behind other library writes. Listing files must
        // not keep showing a discovery spinner while that queue drains.
        unawaited(
          _reconcileTaskSubtitleAssets(library, videoId, taskFiles, generation),
        );
        for (final file in taskFiles) {
          _registerExtractedTrackPath(
            file.path,
            extractedPrefixes: extractedPrefixes,
          );
          await _addFileWithMetadata(file, filesByPath, modifiedByPath);
        }
      }

      for (final path in _selectedPaths) {
        final file = File(path);
        if (await file.exists()) {
          _registerExtractedTrackPath(
            path,
            extractedPrefixes: extractedPrefixes,
          );
          if (_streamIndexFromExtractedPath(path) != null) continue;
          await _addFileWithMetadata(file, filesByPath, modifiedByPath);
        }
      }

      // Locally created/managed groups are explicit local subtitles. They may
      // live outside both the video folder and the standard subtitles folder.
      for (final path in widget.localSubtitles?.values ?? const <String>[]) {
        final file = File(path);
        if (!await file.exists()) continue;
        _registerExtractedTrackPath(path, extractedPrefixes: extractedPrefixes);
        if (_streamIndexFromExtractedPath(path) != null) continue;
        await _addFileWithMetadata(file, filesByPath, modifiedByPath);
      }

      if (!mounted || generation != _scanGeneration) return;
      await _addBilibiliPartSubtitles(
        videoId: videoId,
        library: library,
        filesByPath: filesByPath,
        modifiedByPath: modifiedByPath,
        generation: generation,
      );
    } catch (error) {
      debugPrint('Error listing saved subtitles: $error');
    }
    if (!mounted || generation != _scanGeneration) return;
    // Saved subtitles are usable before a potentially slow directory walk.
    // A cloud/content/online identity has no local sibling directory.
    final scanSidecars =
        SubtitleDiscoveryService.localVideoPath(widget.videoPath) != null;
    setState(() {
      _subtitleFiles = sortedFiles();
      _mergeStreamingFiles();
      _sidecarSubtitlePaths.clear();
      _sidecarGrade.clear();
      _isScanningFiles = false;
      _isScanningSidecars = scanSidecars;
    });
    if (!scanSidecars) return;

    try {
      final discovery =
          widget.discoveryService ?? const SubtitleDiscoveryService();
      final discovered = await discovery.scanVideoDirectory(
        videoPath: widget.videoPath,
      );
      if (!mounted || generation != _scanGeneration) return;

      // Only name matches belong in this card's subtitle list.
      final sidecarEntries = discovered.where(
        (entry) =>
            entry.sourceType == SubtitleSourceType.sidecar && entry.isAuto,
      );
      for (final entry in sidecarEntries) {
        final key = _normalizePath(entry.path);
        if (filesByPath.containsKey(key)) continue;
        filesByPath[key] = File(entry.path);
        modifiedByPath[key] = entry.modifiedAt;
        _subtitleFileSizes[key] = entry.length;
      }
      setState(() {
        _sidecarSubtitlePaths.addAll(
          sidecarEntries.map((entry) => _normalizePath(entry.path)),
        );
        _sidecarGrade.addAll({
          for (final entry in sidecarEntries)
            _normalizePath(entry.path): entry.grade,
        });
        _subtitleFiles = sortedFiles();
        _mergeStreamingFiles();
        _isScanningSidecars = false;
      });
    } catch (e) {
      debugPrint('Sidecar subtitle scan skipped: $e');
      if (mounted && generation == _scanGeneration) {
        setState(() {
          _mergeStreamingFiles();
          _isScanningFiles = false;
          _isScanningSidecars = false;
        });
      }
    }
  }

  Future<void> _reconcileTaskSubtitleAssets(
    LibraryService? library,
    String videoId,
    List<File> files,
    int generation,
  ) async {
    if (library == null || files.isEmpty) return;
    try {
      await library.reconcileManagedSubtitleAssets(
        videoId,
        files.map((file) => file.path),
      );
      if (mounted && generation == _scanGeneration) setState(() {});
    } catch (error) {
      debugPrint('Managed subtitle reconcile skipped: ${error.runtimeType}');
    }
  }

  /// Online Bilibili parts share one subtitle list. Local files do not.
  TaskSubtitleStorageService _taskSubtitleStorage(LibraryService? library) {
    final root = library?.dataRootDirOrNull;
    if (root == null) return const TaskSubtitleStorageService();
    return TaskSubtitleStorageService(dataRootOverride: root);
  }

  Future<void> _addBilibiliPartSubtitles({
    required String videoId,
    required LibraryService? library,
    required Map<String, File> filesByPath,
    required Map<String, DateTime> modifiedByPath,
    required int generation,
  }) async {
    if (videoId.isEmpty) return;
    final item =
        library?.getVideo(videoId) ??
        widget.bilibiliTracks?.store.itemOf(videoId);
    if (item == null || BilibiliSharedSubtitles.folderNameOf(item) == null) {
      return;
    }
    final shared = BilibiliSharedSubtitles(
      dataRootOverride: library?.dataRootDirOrNull,
    );
    for (final file in await shared.list(item)) {
      if (!mounted || generation != _scanGeneration) return;
      _partSubtitlePaths.add(_normalizePath(file.path));
      await _addFileWithMetadata(file, filesByPath, modifiedByPath);
    }
    if (library == null) return;
    final storage = _taskSubtitleStorage(library);
    for (final card in library.cardsOfSameBilibiliPart(videoId)) {
      if (card.id == videoId) continue;
      final siblingFiles = await storage.listTaskSubtitles(card.id);
      for (final file in siblingFiles) {
        if (!mounted || generation != _scanGeneration) return;
        _partSubtitlePaths.add(_normalizePath(file.path));
        await _addFileWithMetadata(file, filesByPath, modifiedByPath);
      }
    }
  }

  Future<String> _allocateSubtitleFile(String videoId, String fileName) async {
    try {
      return await Provider.of<LibraryService>(
        context,
        listen: false,
      ).allocateSubtitleFile(videoId, fileName);
    } catch (_) {
      return const TaskSubtitleStorageService().allocatePath(videoId, fileName);
    }
  }

  Future<Directory> _subtitleOutputDirectory(String videoId) async {
    try {
      final library = Provider.of<LibraryService>(context, listen: false);
      final item = library.getVideo(videoId);
      if (item != null && BilibiliSharedSubtitles.folderNameOf(item) != null) {
        return BilibiliSharedSubtitles(
          dataRootOverride: library.dataRootDirOrNull,
        ).directoryFor(item, create: true);
      }
    } catch (_) {}
    return const TaskSubtitleStorageService().taskDirectory(
      videoId,
      create: true,
    );
  }

  Future<void> _addFileWithMetadata(
    File file,
    Map<String, File> filesByPath,
    Map<String, DateTime> modifiedByPath,
  ) async {
    if (SubtitleWordTimingStore.isCompanion(file.path)) return;
    final key = _normalizePath(file.path);
    if (filesByPath.containsKey(key)) return;
    try {
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) return;
      filesByPath[key] = file;
      modifiedByPath[key] = stat.modified;
      _subtitleFileSizes[key] = stat.size;
      final companion = File(SubtitleWordTimingStore.pathFor(file.path));
      if (await companion.exists()) {
        _subtitleFileSizes[key] = stat.size + await companion.length();
      }
    } on FileSystemException {
      // A file can disappear while its directory is being scanned.
    }
  }

  Future<void> _loadEmbeddedTracks(
    int generation,
    EmbeddedSubtitleService service,
  ) async {
    final probePath = SubtitleDiscoveryService.localVideoPath(
      widget.embeddedProbePath ?? widget.videoPath,
    );
    if (!widget.showEmbeddedSubtitles || probePath == null) {
      if (mounted && generation == _scanGeneration) {
        setState(() {
          _embeddedTracks = [];
          _isScanningEmbedded = false;
        });
      }
      return;
    }
    try {
      final tracks = await service.getEmbeddedSubtitles(probePath);
      if (!mounted || generation != _scanGeneration) return;
      setState(() {
        _embeddedTracks = tracks;
        _isScanningEmbedded = false;
      });
    } catch (e) {
      debugPrint('Error probing embedded subtitles: $e');
      if (mounted && generation == _scanGeneration) {
        setState(() => _isScanningEmbedded = false);
      }
    }
  }

  Future<void> _handleEmbeddedTrackSelection(
    EmbeddedSubtitleTrack track,
  ) async {
    _clearSubtitleFeedback();
    // Reuse the path recorded when this track was extracted in this session.
    if (_extractedTrackPaths.containsKey(track.index)) {
      final path = _extractedTrackPaths[track.index]!;
      _handleSelection(path);
      return;
    }

    if (_extractingTrackIndex != null) return;

    setState(() => _extractingTrackIndex = track.index);

    try {
      final videoId = _requireVideoId();
      final subDir = await const TaskSubtitleStorageService().taskDirectory(
        videoId,
        create: true,
      );

      if (mounted) {
        final service = Provider.of<EmbeddedSubtitleService>(
          context,
          listen: false,
        );
        // Pass codecName to avoid re-probing issues
        final path = await service.extractSubtitle(
          widget.videoPath,
          track.index,
          subDir.path,
          codecName: track.codecName,
          videoId: widget.videoId,
        );

        if (path != null) {
          await _registerManagedSubtitle(
            path,
            ManagedSubtitleAssetKind.embedded,
            _displayEmbeddedTitle(track),
          );
          if (mounted) {
            // Store mapping
            _extractedTrackPaths[track.index] = path;

            _handleSelection(path);
          }
        } else {
          if (mounted) {
            await _showSubtitleFailure(
              '无法提取内嵌字幕',
              '媒体中没有可提取的字幕，或该字幕格式暂不受支持。',
              retry: () => _handleEmbeddedTrackSelection(track),
            );
          }
        }
      }
    } catch (e) {
      debugPrint("Error extracting: $e");
      if (mounted) {
        await _showSubtitleFailure(
          '内嵌字幕提取失败',
          '请检查媒体文件是否完整，并确认字幕格式受支持。',
          error: e,
          retry: () => _handleEmbeddedTrackSelection(track),
        );
      }
    } finally {
      if (mounted) setState(() => _extractingTrackIndex = null);
    }
  }

  Future<void> _deleteSubtitle(File file) async {
    _clearSubtitleFeedback();
    LibraryService? library;
    try {
      library = Provider.of<LibraryService>(context, listen: false);
    } catch (_) {}

    final normalizedPath = _normalizePath(file.path);
    final isSidecar = _sidecarSubtitlePaths.contains(normalizedPath);
    final isTaskOwned = _taskSubtitlePaths.contains(normalizedPath);
    final isPartOwned = _partSubtitlePaths.contains(normalizedPath);
    final isOwned = isTaskOwned || isPartOwned;
    final isExternal = !isOwned;
    final videoId = widget.videoId?.trim() ?? '';
    final deletionPaths = isOwned && library != null && videoId.isNotEmpty
        ? library.managedSubtitleDeletionPaths(videoId, file.path).toList()
        : <String>[file.path];
    final companionPath = SubtitleWordTimingStore.pathFor(file.path);
    if (await File(companionPath).exists() &&
        !deletionPaths.contains(companionPath)) {
      deletionPaths.add(companionPath);
    }
    if (!mounted) return;

    final confirm = await showSubtitleDeletionConfirmationDialog(
      context,
      fileName: p.basename(file.path),
      isSidecar: isSidecar,
      isExternal: isExternal,
      useCupertinoStyle: _isMusicIOS,
    );

    if (confirm) {
      try {
        await _streamManager?.stopStreamForPath(file.path);
        final deletedPathKeys = <String>{};
        final successfullyDeletedPaths = <String>[];
        final failedPaths = <String>[];
        final storage = const TaskSubtitleStorageService();
        final orderedDeletionPaths = [
          ...deletionPaths.where(SubtitleWordTimingStore.isCompanion),
          ...deletionPaths.where(
            (path) => !SubtitleWordTimingStore.isCompanion(path),
          ),
        ];
        for (final path in orderedDeletionPaths) {
          final boundWordPath = library
              ?.managedSubtitleAssetForPath(videoId, path)
              ?.wordTimingPath;
          if (failedPaths.contains(
            boundWordPath ?? SubtitleWordTimingStore.pathFor(path),
          )) {
            failedPaths.add(path);
            continue;
          }
          try {
            final partOwned = _partSubtitlePaths.contains(_normalizePath(path));
            final taskOwned =
                videoId.isNotEmpty &&
                await storage.isTaskOwnedPath(path, videoId);
            final parentPartOwned =
                SubtitleWordTimingStore.isCompanion(path) &&
                _partSubtitlePaths.contains(
                  _normalizePath(
                    path.substring(
                      0,
                      path.length - SubtitleWordTimingStore.suffix.length,
                    ),
                  ),
                );
            if (isOwned && !taskOwned && !partOwned && !parentPartOwned) {
              failedPaths.add(path);
              continue;
            }
            final target = File(path);
            if (await target.exists()) await target.delete();
            _streamManager?.forgetStreamForPath(path);
            deletedPathKeys.add(_normalizePath(path));
            successfullyDeletedPaths.add(path);
          } on FileSystemException {
            failedPaths.add(path);
          }
        }
        if (isOwned && library != null && videoId.isNotEmpty) {
          await library.forgetSubtitleFiles(videoId, successfullyDeletedPaths);
        }
        final hadDeletedSelection = _selectedPaths.any(
          (path) => deletedPathKeys.contains(_normalizePath(path)),
        );
        if (hadDeletedSelection) {
          setState(() {
            _selectedPaths.removeWhere(
              (path) => deletedPathKeys.contains(_normalizePath(path)),
            );
          });
          if (widget.onSubtitleSelected != null) {
            widget.onSubtitleSelected!(_selectedPaths);
          }
        }
        _loadSubtitles(); // Reload list
        _notifySubtitleFilesChanged();
        if (failedPaths.isNotEmpty && mounted) {
          await _showSubtitleFailure(
            '部分字幕未能删除',
            '有 ${failedPaths.length} 个字幕文件未能删除，请检查文件权限后重试。',
            error: failedPaths.join('\n'),
            retry: () => _deleteSubtitle(file),
          );
        }
      } catch (e) {
        if (mounted) {
          await _showSubtitleFailure(
            '字幕删除失败',
            '部分字幕可能尚未删除，请查看当前列表并检查文件权限后重试。',
            error: e,
            retry: () => _deleteSubtitle(file),
          );
        }
      }
    }
  }

  Future<Directory> _resolveDownloadTargetDir() async {
    // 1. 优先使用用户自定义路径
    if (_customDownloadPath != null) {
      final customDir = Directory(_customDownloadPath!);
      if (await customDir.exists()) {
        return customDir;
      }
    }

    if (Platform.isAndroid) {
      // 优先使用公共下载目录，方便用户通过 MT 管理器等访问
      final downloadDir = Directory('/storage/emulated/0/Download');
      if (await downloadDir.exists()) {
        return downloadDir;
      }
      final dir = await getExternalStorageDirectory();
      if (dir != null) return dir;
    }
    if (Platform.isWindows) {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final downloadDir = Directory(p.join(exeDir, 'Downloads'));
      if (!await downloadDir.exists()) {
        await downloadDir.create(recursive: true);
      }
      return downloadDir;
    }
    if (Platform.isLinux || Platform.isMacOS) {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) return downloads;
    }
    return getApplicationDocumentsDirectory();
  }

  Future<void> _downloadSubtitleFile(String path) async {
    if (_exportingSubtitle) return;
    _clearSubtitleFeedback();
    _exportingSubtitle = true;
    try {
      final sourceFile = File(path);
      if (!await sourceFile.exists()) {
        if (mounted) {
          await _showSubtitleFailure(
            '字幕文件不存在',
            '原字幕可能已移动或删除，请重新选择字幕后导出。',
            retry: () => _downloadSubtitleFile(path),
          );
        }
        return;
      }

      Directory targetDir = await _resolveDownloadTargetDir();
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }

      final sourceDir = p.normalize(p.dirname(path));
      final targetDirPath = p.normalize(targetDir.path);
      String targetPath = path;

      final streaming = _streamManager?.streamForPath(path);
      if (sourceDir != targetDirPath ||
          streaming != null && !streaming.complete) {
        final fileName = p.basename(path);
        String destPath = p.join(targetDir.path, fileName);
        if (await File(destPath).exists()) {
          final base = p.basenameWithoutExtension(fileName);
          final ext = p.extension(fileName);
          destPath = p.join(
            targetDir.path,
            "$base.downloaded.${DateTime.now().millisecondsSinceEpoch}$ext",
          );
        }
        if (streaming != null && !streaming.complete) {
          await File(destPath).writeAsString(
            encodeStreamingSrt(
              path == streaming.primaryPath
                  ? streaming.primary
                  : streaming.secondary,
            ),
          );
        } else {
          await sourceFile.copy(destPath);
        }
        targetPath = destPath;
      }

      bool revealed = false;
      Object? openerError;
      try {
        revealed = await (widget.revealSavedSubtitle ?? revealInFileManager)(
          targetPath,
        );
      } catch (error) {
        openerError = error;
      }
      if (mounted) {
        await _showSubtitleExportResult(
          targetPath,
          revealed: revealed,
          openerError: openerError,
        );
      }
    } catch (error) {
      if (mounted) {
        await _showSubtitleFailure(
          '导出字幕失败',
          '请检查导出文件夹的权限和可用空间。原字幕保留。',
          error: error,
          retry: () => _downloadSubtitleFile(path),
        );
      }
    } finally {
      _exportingSubtitle = false;
    }
  }

  Future<void> _showSubtitleExportResult(
    String path, {
    required bool revealed,
    Object? openerError,
  }) async {
    if (revealed) {
      _clearSubtitleFeedback();
      return;
    }
    await _showSubtitleFailure(
      '字幕已保存，无法打开位置',
      '',
      error: null,
      path: path,
      retry: () => _retrySavedSubtitleLocation(path),
    );
    if (mounted && openerError != null) {
      setState(
        () => _feedbackDiagnostic = safeOperationDiagnostic(openerError),
      );
    }
  }

  Future<void> _retrySavedSubtitleLocation(String path) async {
    Object? error;
    var opened = false;
    try {
      opened = await (widget.revealSavedSubtitle ?? revealInFileManager)(path);
    } catch (failure) {
      error = failure;
    }
    await _showSubtitleExportResult(path, revealed: opened, openerError: error);
  }

  Future<void> _downloadEmbeddedTrack(EmbeddedSubtitleTrack track) async {
    _clearSubtitleFeedback();
    if (_extractingTrackIndex != null) return;
    if (_extractedTrackPaths.containsKey(track.index)) {
      await _downloadSubtitleFile(_extractedTrackPaths[track.index]!);
      return;
    }

    setState(() => _extractingTrackIndex = track.index);

    try {
      final videoId = _requireVideoId();
      final subDir = await const TaskSubtitleStorageService().taskDirectory(
        videoId,
        create: true,
      );

      if (!mounted) return;
      final service = Provider.of<EmbeddedSubtitleService>(
        context,
        listen: false,
      );
      final path = await service.extractSubtitle(
        widget.videoPath,
        track.index,
        subDir.path,
        codecName: track.codecName,
        videoId: widget.videoId,
      );

      if (path != null) {
        await _registerManagedSubtitle(
          path,
          ManagedSubtitleAssetKind.embedded,
          _displayEmbeddedTitle(track),
        );
        _extractedTrackPaths[track.index] = path;
        await _downloadSubtitleFile(path);
      } else {
        if (mounted) {
          await _showSubtitleFailure(
            '无法提取内嵌字幕',
            '媒体中没有可提取的字幕，或该字幕格式暂不受支持。',
            retry: () => _downloadEmbeddedTrack(track),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        await _showSubtitleFailure(
          '内嵌字幕提取失败',
          '请检查媒体文件是否完整，并确认字幕格式受支持。',
          error: e,
          retry: () => _downloadEmbeddedTrack(track),
        );
      }
    } finally {
      if (mounted) setState(() => _extractingTrackIndex = null);
    }
  }

  Future<void> _importSubtitle() async {
    if (_isMusicIOS) {
      await _showMusicActions('导入字幕', [
        ('从文件导入', _importSubtitleFromFile, false),
        ('从词级文件导入', () => _importSubtitleFromFile(wordLevel: true), false),
        ('手动输入文本', _showManualSubtitleInputDialog, false),
      ]);
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2C),
        title: const Text(
          '导入字幕',
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: const Text(
          '请选择导入方式：',
          style: TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          DesktopButtonClickRegion(
            child: TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消', style: TextStyle(color: Colors.white54)),
            ),
          ),
          DesktopButtonClickRegion(
            child: TextButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                _importSubtitleFromFile();
              },
              icon: const Icon(
                Icons.folder_open,
                size: 18,
                color: Colors.white70,
              ),
              label: const Text('从文件导入', style: TextStyle(color: Colors.white)),
            ),
          ),
          DesktopButtonClickRegion(
            child: TextButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                _showManualSubtitleInputDialog();
              },
              icon: const Icon(
                Icons.edit_note,
                size: 18,
                color: Colors.blueAccent,
              ),
              label: const Text(
                '手动输入文本',
                style: TextStyle(color: Colors.blueAccent),
              ),
            ),
          ),
          DesktopButtonClickRegion(
            child: TextButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                _importSubtitleFromFile(wordLevel: true);
              },
              icon: const Icon(Icons.lyrics_outlined, size: 18),
              label: const Text('从词级文件导入'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _importSubtitleFromFile({bool wordLevel = false}) async {
    _clearSubtitleFeedback();
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: TimedSubtitleParser.inputExtensions,
      );

      if (result != null && result.files.single.path != null) {
        final srcFile = File(result.files.single.path!);
        if (SubtitleWordTimingStore.isCompanion(srcFile.path)) {
          await _showSubtitleFailure(
            '请选择主字幕文件',
            '词级附属数据会随主字幕一起加载，请选择对应的 SRT 等主字幕文件。',
            retry: () => _importSubtitleFromFile(wordLevel: wordLevel),
          );
          return;
        }
        final videoId = _requireVideoId();
        final ext = p.extension(srcFile.path).toLowerCase();
        final originalStem = p.basenameWithoutExtension(srcFile.path).trim();
        List<SubtitleItem>? importedCues;
        String? importedContent;
        final requiresValidation =
            wordLevel ||
            ![
              '.srt',
              '.vtt',
              '.lrc',
              '.ass',
              '.ssa',
              '.sup',
              '.sub',
              '.idx',
              '.scc',
            ].contains(ext);
        if (requiresValidation ||
            await File(
              SubtitleWordTimingStore.pathFor(srcFile.path),
            ).exists()) {
          try {
            importedContent = SubtitleParser.decodeBytes(
              await srcFile.readAsBytes(),
              sourcePath: srcFile.path,
            );
            importedCues = wordLevel && ext == '.srt'
                ? TimedSubtitleParser.parseWordSrt(importedContent)
                : SubtitleParser.parse(
                    importedContent,
                    sourcePath: srcFile.path,
                  );
            if (importedCues.isEmpty) throw const FormatException('没有可用的字幕时间');
            importedCues = await SubtitleWordTimingStore.attach(
              srcFile.path,
              importedContent,
              importedCues,
            );
          } catch (error) {
            if (requiresValidation) {
              await _showSubtitleFailure(
                '无法读取字幕内容',
                '请确认文件包含可识别的字幕文本和时间轴，或选择其他字幕文件。',
                error: error,
                retry: () => _importSubtitleFromFile(wordLevel: wordLevel),
              );
              return;
            }
            importedCues = null;
          }
        }
        final destPath = await _allocateSubtitleFile(
          videoId,
          TaskSubtitleStorageService.readableSubtitleFileName(
            label: originalStem.isEmpty ? '字幕' : originalStem,
            extension: ext.isEmpty ? '.srt' : ext,
          ),
        );
        await srcFile.copy(destPath);
        if (wordLevel && ext == '.srt') {
          await File(
            destPath,
          ).writeAsString(_wordImportSrt(importedCues!), flush: true);
        }
        if (importedCues != null &&
            (wordLevel && ext == '.srt' ||
                await File(
                  SubtitleWordTimingStore.pathFor(srcFile.path),
                ).exists())) {
          await SubtitleWordTimingStore.write(destPath, importedCues);
        }
        await _registerManagedSubtitle(
          destPath,
          ManagedSubtitleAssetKind.imported,
          originalStem.isEmpty ? '字幕' : originalStem,
        );
        _loadSubtitles();
        _notifySubtitleFilesChanged();
      }
    } catch (error) {
      await _showSubtitleFailure(
        '字幕导入失败',
        '请检查所选文件是否可读取、字幕格式是否受支持，以及存储空间是否充足。',
        error: error,
        retry: () => _importSubtitleFromFile(wordLevel: wordLevel),
      );
    }
  }

  String _wordImportSrt(List<SubtitleItem> cues) {
    String stamp(Duration value) {
      final ms = value.inMilliseconds;
      String pad(int n, int width) => n.toString().padLeft(width, '0');
      return '${pad(ms ~/ 3600000, 2)}:${pad(ms ~/ 60000 % 60, 2)}:${pad(ms ~/ 1000 % 60, 2)},${pad(ms % 1000, 3)}';
    }

    return cues
        .asMap()
        .entries
        .map(
          (entry) =>
              '${entry.key + 1}\n${stamp(entry.value.startTime)} --> ${stamp(entry.value.endTime)}\n${entry.value.text}\n',
        )
        .join('\n');
  }

  /// 生成默认手动字幕名称 (S1, S2, S3...)
  String _generateDefaultManualSubtitleName() {
    final videoName = p.basenameWithoutExtension(widget.videoPath);
    final videoId = (widget.videoId ?? '').trim();
    final prefixes = <String>{
      '$videoName.manual.',
      if (videoId.isNotEmpty) '$videoId.manual.',
    };
    int maxNum = 0;
    final reg = RegExp(r'\.manual\.S(\d+)\.');
    for (final file in _subtitleFiles) {
      final name = p.basename(file.path);
      if (!prefixes.any(name.startsWith)) continue;
      final match = reg.firstMatch(name);
      if (match != null) {
        final n = int.tryParse(match.group(1)!) ?? 0;
        if (n > maxNum) maxNum = n;
      }
    }
    return 'S${maxNum + 1}';
  }

  /// 手动输入字幕文本对话框
  Future<void> _showManualSubtitleInputDialog() async {
    final nameController = TextEditingController(
      text: _generateDefaultManualSubtitleName(),
    );
    final textController = TextEditingController();
    SubtitleFormat? detectedFormat;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final screenWidth = MediaQuery.sizeOf(ctx).width;
            final screenHeight = MediaQuery.sizeOf(ctx).height;
            final dialogWidth = (screenWidth * 0.85).clamp(320.0, 600.0);
            final dialogHeight = (screenHeight * 0.75).clamp(360.0, 640.0);

            return DialogKeyboardViewport(
              child: AlertDialog(
                backgroundColor: const Color(0xFF2C2C2C),
                contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                content: SizedBox(
                  width: dialogWidth,
                  height: dialogHeight,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 标题
                      const Text(
                        '手动输入字幕',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),

                      // 名称输入框
                      Row(
                        children: [
                          const Text(
                            '名称：',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: SizedBox(
                              height: 36,
                              child: TextField(
                                controller: nameController,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                ),
                                decoration: InputDecoration(
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8,
                                  ),
                                  filled: true,
                                  fillColor: Colors.white10,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(6),
                                    borderSide: BorderSide.none,
                                  ),
                                  hintText: '输入字幕名称',
                                  hintStyle: const TextStyle(
                                    color: Colors.white38,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),

                      // 格式检测提示行 + 粘贴/清除按钮
                      Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            size: 14,
                            color: detectedFormat != null
                                ? Colors.greenAccent
                                : Colors.white38,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            textController.text.isEmpty
                                ? '输入文本后自动识别格式'
                                : '识别格式: ${detectedFormat?.displayName ?? 'SRT'}',
                            style: TextStyle(
                              color: textController.text.isEmpty
                                  ? Colors.white38
                                  : (detectedFormat != null
                                        ? Colors.greenAccent
                                        : Colors.orangeAccent),
                              fontSize: 11,
                            ),
                          ),
                          const Spacer(),
                          InkWell(
                            onTap: () async {
                              await _pasteIntoController(textController);
                              final fmt = SubtitleParser.detectFormat(
                                textController.text,
                              );
                              setDialogState(() {
                                detectedFormat = fmt;
                              });
                            },
                            child: const Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.content_paste,
                                    size: 14,
                                    color: Colors.blueAccent,
                                  ),
                                  SizedBox(width: 2),
                                  Text(
                                    '粘贴',
                                    style: TextStyle(
                                      color: Colors.blueAccent,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          InkWell(
                            onTap: () {
                              textController.clear();
                              setDialogState(() {
                                detectedFormat = null;
                              });
                            },
                            child: const Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.clear_all,
                                    size: 14,
                                    color: Colors.orangeAccent,
                                  ),
                                  SizedBox(width: 2),
                                  Text(
                                    '清除',
                                    style: TextStyle(
                                      color: Colors.orangeAccent,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),

                      // 文本输入区
                      Expanded(
                        child: TextField(
                          controller: textController,
                          maxLines: null,
                          expands: true,
                          textAlignVertical: TextAlignVertical.top,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                          decoration: InputDecoration(
                            filled: true,
                            fillColor: Colors.black26,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(6),
                              borderSide: BorderSide.none,
                            ),
                            contentPadding: const EdgeInsets.all(10),
                            hintText:
                                '在此粘贴或输入字幕文本...\n\n'
                                '支持 SRT / VTT / ASS / LRC 格式，将自动识别',
                            hintStyle: const TextStyle(
                              color: Colors.white24,
                              fontSize: 12,
                            ),
                          ),
                          onChanged: (value) {
                            final fmt = SubtitleParser.detectFormat(value);
                            setDialogState(() {
                              detectedFormat = fmt;
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  DesktopButtonClickRegion(
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text(
                        '取消',
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
                  ),
                  DesktopButtonClickRegion(
                    child: ElevatedButton(
                      onPressed: textController.text.trim().isEmpty
                          ? null
                          : () async {
                              final name = nameController.text.trim();
                              final content = textController.text;
                              Navigator.pop(ctx);
                              await _importManualSubtitleText(
                                name.isEmpty ? 'S1' : name,
                                content,
                              );
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueAccent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 6,
                        ),
                      ),
                      child: const Text('导入', style: TextStyle(fontSize: 13)),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// 将手动输入的字幕文本保存为本地文件并刷新列表
  Future<void> _importManualSubtitleText(String name, String content) async {
    _clearSubtitleFeedback();
    try {
      final format = SubtitleParser.detectFormat(content);
      final videoId = _requireVideoId();

      // 文件名安全处理
      final safeName = name.replaceAll(RegExp(r'[^\w\u4e00-\u9fff\-]'), '_');
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = 'manual.$safeName.$timestamp${format.extension}';
      final outputPath = await _allocateSubtitleFile(videoId, fileName);

      await File(outputPath).writeAsString(content, flush: true);
      await _registerManagedSubtitle(
        outputPath,
        ManagedSubtitleAssetKind.manual,
        name,
      );
      await _loadSubtitles();
      _notifySubtitleFilesChanged();
    } catch (e) {
      if (mounted) {
        await _showSubtitleFailure(
          '字幕导入失败',
          '请检查字幕格式、文件权限和存储空间后重试。',
          error: e,
          retry: () => _importManualSubtitleText(name, content),
        );
      }
    }
  }

  /// A Bilibili track that was just fetched becomes selected (never
  /// unselected, should it already be).
  void _selectFetchedSubtitle(String path) {
    if (!_selectedContains(path)) _handleSelection(path);
  }

  void _handleSelection(String path) {
    final normalizedPath = p.normalize(path);
    setState(() {
      final existingIndex = _selectedIndexOf(normalizedPath);
      if (existingIndex != -1) {
        _selectedPaths.removeAt(existingIndex);
      } else {
        if (_selectedPaths.length >= 2) {
          _selectedPaths.removeLast();
        }
        _selectedPaths.add(normalizedPath);
      }
    });

    if (widget.onSubtitleSelected != null) {
      widget.onSubtitleSelected!(_selectedPaths);
    }
  }

  /// A subtitle file bound to the card (download or Bilibili track), with
  /// its export and translate actions. [isAi] adds the「AI」mark.
  Widget _buildAssociatedRow({
    required String label,
    required String path,
    bool isAi = false,
  }) {
    final exists = File(path).existsSync();
    if (_isMusicIOS) {
      return _buildMusicRow(
        label: label,
        description: exists ? '已就绪' : '文件丢失',
        path: path,
        onTap: exists ? () => _handleSelection(path) : null,
        badges: [if (isAi) const BilibiliAiBadge()],
        actions: [
          if (exists) ('导出字幕', () => _downloadSubtitleFile(path), false),
          if (exists) ('翻译字幕', () => _toggleTranslatePanel(path), false),
        ],
        expanded: _buildTranslationPanel(path: path, enabled: exists),
      );
    }
    return Container(
      margin: _rowMargin,
      clipBehavior: Clip.antiAlias,
      decoration: _subtitleRowDecoration(Colors.purpleAccent, path: path),
      child: Column(
        children: [
          // Its own surface, so the selected colour and the tap ripple
          // show above the row colour.
          Material(
            type: MaterialType.transparency,
            child: SubtitleManagementTile(
              leading: const Icon(
                Icons.subtitles,
                color: Colors.purpleAccent,
                size: 20,
              ),
              title: Text(
                label,
                style: TextStyle(
                  color: _selectedIndexOf(path) == 0
                      ? Colors.blueAccent
                      : (_selectedIndexOf(path) == 1
                            ? Colors.orangeAccent
                            : Colors.white),
                  fontSize: 13,
                  fontWeight: _selectedContains(path)
                      ? FontWeight.bold
                      : FontWeight.normal,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              selectionBadge: _selectedContains(path)
                  ? _buildSelectionBadge(path)
                  : null,
              badges: [if (isAi) const BilibiliAiBadge()],
              subtitle: Text(
                exists ? "已就绪" : "文件丢失",
                style: TextStyle(
                  color: exists ? Colors.white30 : Colors.redAccent,
                  fontSize: 11,
                ),
              ),
              selected: _selectedContains(path),
              actions: [
                DesktopButtonClickRegion(
                  child: IconButton(
                    tooltip: '导出字幕',
                    icon: const Icon(
                      Icons.download_outlined,
                      color: Colors.white70,
                      size: 18,
                    ),
                    onPressed: exists
                        ? () => _downloadSubtitleFile(path)
                        : null,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ),
                _buildTranslateAction(path: path, enabled: exists),
              ],
              onTap: exists ? () => _handleSelection(path) : null,
            ),
          ),
          _buildTranslationPanel(path: path, enabled: exists),
        ],
      ),
    );
  }

  Widget _buildSelectionBadge(String path) {
    final index = _selectedIndexOf(path);
    if (index == -1) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: index == 0 ? Colors.blueAccent : Colors.orangeAccent,
        borderRadius: BorderRadius.circular(_isMusicIOS ? 7 : 4),
      ),
      child: Text(
        index == 0 ? "主" : "副",
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  String _displayNameForPath(String path, {required String fallback}) {
    final videoId = widget.videoId?.trim() ?? '';
    if (videoId.isEmpty) return fallback;
    try {
      final stored = Provider.of<LibraryService>(
        context,
        listen: false,
      ).managedSubtitleAssetForPath(videoId, path)?.displayName.trim();
      if (stored != null && stored.isNotEmpty) return stored;
    } catch (_) {}
    return fallback;
  }

  String _displayEmbeddedTitle(EmbeddedSubtitleTrack track) {
    final title = track.title.trim();
    if (title.isNotEmpty && title != "未知标题") return title;
    final language = track.language.trim();
    if (language.isNotEmpty && language != "未知语言") return language;
    return "内嵌字幕 ${track.index}";
  }

  String _displayEmbeddedTitleByIndex(int index) {
    for (final track in _embeddedTracks) {
      if (track.index == index) {
        return _displayEmbeddedTitle(track);
      }
    }
    return "内嵌字幕 $index";
  }

  bool _isTranslatedSubtitlePath(String path) {
    final name = p.basename(path).toLowerCase();
    return name.contains('.translated.');
  }

  String? _extractTranslatedLanguageCode(String path) {
    final name = p.basename(path);
    final match = RegExp(
      r'\.translated\.([^.]+)(?:\.\d+)?\.[^.]+$',
      caseSensitive: false,
    ).firstMatch(name);
    if (match == null) return null;
    return match.group(1);
  }

  String _translatedLanguageBadgeText(String path) {
    final code = (_extractTranslatedLanguageCode(path) ?? '').toLowerCase();
    if (code.startsWith('zh')) return '中';
    if (code.startsWith('en')) return '英';
    if (code.startsWith('ja')) return '日';
    if (code.startsWith('ko')) return '韩';
    if (code.startsWith('fr')) return '法';
    if (code.startsWith('de')) return '德';
    if (code.startsWith('es')) return '西';
    if (code.startsWith('ru')) return '俄';
    if (code.startsWith('it')) return '意';
    if (code.startsWith('pt')) return '葡';
    if (code.startsWith('ar')) return '阿';
    return '译';
  }

  Widget _buildTranslatedLanguageBadge(String path) {
    if (!_isTranslatedSubtitlePath(path)) {
      return const SizedBox.shrink();
    }
    final badge = _translatedLanguageBadgeText(path);
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.lightBlueAccent.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: Colors.lightBlueAccent.withValues(alpha: 0.5),
        ),
      ),
      child: Text(
        badge,
        style: const TextStyle(
          color: Colors.lightBlueAccent,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    );
  }

  Widget _buildSubtitleSourceBadge(String path) {
    if (!_sidecarSubtitlePaths.contains(_normalizePath(path))) {
      return const SizedBox.shrink();
    }
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.greenAccent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.42)),
      ),
      child: Text(
        SubtitleSourceType.sidecar.displayName,
        style: const TextStyle(
          color: Colors.greenAccent,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    );
  }

  /// 对名称未完全匹配的同目录字幕给出提示标注，方便用户判断是否手动选用。
  Widget _buildSidecarMatchIndicator(String path) {
    final grade = _sidecarGrade[_normalizePath(path)];
    if (grade == null || grade == SubtitleMatchGrade.autoMatch) {
      return const SizedBox.shrink();
    }
    final (label, color, bg, borderColor) = switch (grade) {
      SubtitleMatchGrade.manualOnly => (
        '名称相似',
        Colors.orangeAccent,
        Colors.orangeAccent.withValues(alpha: 0.12),
        Colors.orangeAccent.withValues(alpha: 0.42),
      ),
      _ => (
        '名称不匹配',
        Colors.grey,
        Colors.grey.withValues(alpha: 0.12),
        Colors.grey.withValues(alpha: 0.4),
      ),
    };
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: borderColor),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    );
  }

  Widget _buildOcrBadge(ManagedSubtitleAsset? asset) {
    if (asset?.kind != ManagedSubtitleAssetKind.ocr) {
      return const SizedBox.shrink();
    }
    final language = switch (asset?.language) {
      'zh-Hans' => '中',
      'en' => '英',
      'ja' => '日',
      'ko' => '韩',
      'latin' => '拉丁',
      _ => null,
    };
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.lightBlueAccent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: Colors.lightBlueAccent.withValues(alpha: 0.45),
        ),
      ),
      child: Text(
        language == null ? 'OCR' : 'OCR · $language',
        style: const TextStyle(
          color: Colors.lightBlueAccent,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    );
  }

  List<SubtitleTranslationLanguage> get _sourceLanguageOptions => [
    SubtitleTranslationLanguage(code: 'auto', label: '自动检测'),
    ...(_sharedTranslateSettings?.availableLanguages ??
        SubtitleTranslationService.supportedLanguages),
  ];

  List<SubtitleTranslationLanguage> get _targetLanguageOptions =>
      _sharedTranslateSettings?.availableLanguages ??
      SubtitleTranslationService.supportedLanguages;

  String _languageLabelByCode(String code) {
    for (final lang in _sourceLanguageOptions) {
      if (lang.code == code) return lang.label;
    }
    for (final lang in _targetLanguageOptions) {
      if (lang.code == code) return lang.label;
    }
    return code;
  }

  String _manualPromptLockedPrefix() {
    if (_sharedTranslateSettings?.mode == SubtitleTranslationMode.smart) {
      final policy = _sharedTranslateSettings!.smartPolicy;
      final rules = policy.summary;
      final uncertain = policy.keepUncertain ? '保留原文' : '按其他语言规则处理';
      return '任务：自动识别字幕片段的语言，按以下规则逐段翻译：$rules。\n'
          '方向无法确定时$uncertain。\n'
          '保留人名、品牌、网址、时间轴与格式标签；不要重复翻译同一片段。\n'
          '输出必须是纯净字幕文本（仅字幕文件内容），禁止输出任何解释或额外回复。\n\n';
    }
    final source = _languageLabelByCode(_translateSourceLanguage);
    final target = _languageLabelByCode(_translateTargetLanguage);
    return '任务：将字幕从【$source】翻译为【$target】。\n'
        '输出必须是纯净字幕文本（仅字幕文件内容），禁止输出任何解释或额外回复。\n\n';
  }

  String get _translateActionLabel =>
      _sharedTranslateSettings?.mode == SubtitleTranslationMode.smart
      ? '开始智能互译'
      : '翻译为 ${_languageLabelByCode(_translateTargetLanguage)}';

  String _manualFullPromptText() {
    final editable = _manualPromptController.text.trim();
    final locked = _manualPromptLockedPrefix();
    if (editable.isEmpty) return locked.trimRight();
    return '$locked$editable';
  }

  String _singleLinePreview(String value) {
    final compact = value.replaceAll('\r\n', '\n').replaceAll('\n', ' ').trim();
    if (compact.isEmpty) return '（空）';
    if (compact.length <= 80) return compact;
    return '${compact.substring(0, 80)}...';
  }

  /// Copies without a success toast. Confirmation bars after copy are omitted.
  Future<void> _copyText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }

  bool get _isDesktopPlatform =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  Future<void> _pasteIntoController(TextEditingController controller) async {
    final data = await Clipboard.getData('text/plain');
    final pastedText = data?.text ?? '';
    if (pastedText.isEmpty) {
      return;
    }

    final currentText = controller.text;
    var start = controller.selection.start;
    var end = controller.selection.end;

    if (start < 0 || end < 0) {
      start = currentText.length;
      end = currentText.length;
    }
    if (start > end) {
      final temp = start;
      start = end;
      end = temp;
    }

    final nextText = currentText.replaceRange(start, end, pastedText);
    final caret = start + pastedText.length;

    controller.value = controller.value.copyWith(
      text: nextText,
      selection: TextSelection.collapsed(offset: caret),
      composing: TextRange.empty,
    );
  }

  Future<void> _prepareManualSource(String path) async {
    _clearSubtitleFeedback();
    final normalized = p.normalize(path);
    if (_manualLoadedSourcePath == normalized &&
        _manualSourceController.text.isNotEmpty) {
      return;
    }
    if (mounted) {
      setState(() {
        _isLoadingManualSource = true;
      });
    }
    try {
      final content = await File(path).readAsString();
      if (!mounted) return;
      setState(() {
        _manualSourceController.text = content;
        _manualLoadedSourcePath = normalized;
      });
    } catch (e) {
      if (mounted) {
        await _showSubtitleFailure(
          '无法读取字幕',
          '请检查字幕文件是否仍存在并允许读取。',
          error: e,
          retry: () => _prepareManualSource(path),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingManualSource = false;
        });
      }
    }
  }

  Future<void> _showManualSourceEditor() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      enableDrag: true,
      backgroundColor: const Color(0xFF1E1E1E),
      builder: (context) {
        return KeyboardInsetPadding(
          child: DraggableScrollableSheet(
            initialChildSize: 0.55,
            minChildSize: 0.35,
            maxChildSize: 0.85,
            expand: false,
            builder: (context, scrollController) {
              return Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      '字幕全文（可复制）',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: TextField(
                        controller: _manualSourceController,
                        readOnly: true,
                        maxLines: null,
                        expands: true,
                        scrollController: scrollController,
                        style: const TextStyle(
                          color: Colors.white,
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          hintText: '字幕内容为空',
                          hintStyle: TextStyle(color: Colors.white38),
                        ),
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

  Future<void> _showManualPromptEditor() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      enableDrag: true,
      backgroundColor: const Color(0xFF1E1E1E),
      builder: (context) {
        return KeyboardInsetPadding(
          child: DraggableScrollableSheet(
            initialChildSize: 0.65,
            minChildSize: 0.4,
            maxChildSize: 0.9,
            expand: false,
            builder: (context, scrollController) {
              final source = _languageLabelByCode(_translateSourceLanguage);
              final target = _languageLabelByCode(_translateTargetLanguage);
              return Padding(
                padding: const EdgeInsets.all(12),
                child: LayoutBuilder(
                  builder: (context, constraints) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        '提示词（前缀锁定）',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: constraints.maxHeight * .35,
                        ),
                        child: SingleChildScrollView(
                          key: const PageStorageKey('subtitle-manager-prompt'),
                          child: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.04),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.white12),
                            ),
                            child: RichText(
                              text: TextSpan(
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                  height: 1.45,
                                ),
                                children: [
                                  if (_sharedTranslateSettings?.mode ==
                                      SubtitleTranslationMode.smart)
                                    TextSpan(text: _manualPromptLockedPrefix())
                                  else ...[
                                    const TextSpan(text: '任务：将字幕从【'),
                                    TextSpan(
                                      text: source,
                                      style: const TextStyle(
                                        color: Colors.lightBlueAccent,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const TextSpan(text: '】翻译为【'),
                                    TextSpan(
                                      text: target,
                                      style: const TextStyle(
                                        color: Colors.amberAccent,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const TextSpan(
                                      text:
                                          '】。\n输出必须是纯净字幕文本（仅字幕文件内容），禁止输出任何解释或额外回复。\n\n',
                                    ),
                                  ],
                                  const TextSpan(
                                    text: '（以上为锁定前缀，随语言自动更新，不可编辑）',
                                    style: TextStyle(
                                      color: Colors.white38,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: TextField(
                          controller: _manualPromptController,
                          maxLines: null,
                          expands: true,
                          scrollController: scrollController,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: '可编辑提示词',
                            alignLabelWithHint: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _showManualHelpDialog() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2C),
        title: const Text('手动翻译帮助', style: TextStyle(color: Colors.white)),
        content: const Text(
          '建议先复制“字幕全文 + 提示词”，粘贴到你的 AI 助手中。\n\n'
          '你可以在提示词中手动补充：\n'
          '1) 希望 AI 扮演的角色（如影视本地化译审）。\n'
          '2) 特殊术语、专有名词、人名地名的固定译法。\n'
          '3) 语气风格要求（口语化/正式/简洁等）。\n\n'
          '请始终要求 AI 仅返回纯字幕文本，避免任何解释性内容。',
          style: TextStyle(color: Colors.white70, height: 1.45),
        ),
        actions: [
          DesktopButtonClickRegion(
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('知道了'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showManualResultInputDialog(String sourcePath) async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final screenWidth = MediaQuery.sizeOf(ctx).width;
            final screenHeight = MediaQuery.sizeOf(ctx).height;
            final dialogWidth = (screenWidth * 0.85).clamp(320.0, 600.0);
            final dialogHeight = (screenHeight * 0.75).clamp(360.0, 640.0);

            return DialogKeyboardViewport(
              child: AlertDialog(
                backgroundColor: const Color(0xFF2C2C2C),
                contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                content: SizedBox(
                  width: dialogWidth,
                  height: dialogHeight,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 标题
                      const Text(
                        '输入翻译结果',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),

                      // 提示行 + 粘贴/清除按钮
                      Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            size: 14,
                            color: controller.text.isEmpty
                                ? Colors.white38
                                : Colors.greenAccent,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            controller.text.isEmpty
                                ? '在此粘贴 AI 返回的完整字幕文本'
                                : '已输入 ${controller.text.length} 字符',
                            style: TextStyle(
                              color: controller.text.isEmpty
                                  ? Colors.white38
                                  : Colors.greenAccent,
                              fontSize: 11,
                            ),
                          ),
                          const Spacer(),
                          InkWell(
                            onTap: () async {
                              await _pasteIntoController(controller);
                              setDialogState(() {});
                            },
                            child: const Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.content_paste,
                                    size: 14,
                                    color: Colors.blueAccent,
                                  ),
                                  SizedBox(width: 2),
                                  Text(
                                    '粘贴',
                                    style: TextStyle(
                                      color: Colors.blueAccent,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          InkWell(
                            onTap: () {
                              controller.clear();
                              setDialogState(() {});
                            },
                            child: const Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.clear_all,
                                    size: 14,
                                    color: Colors.orangeAccent,
                                  ),
                                  SizedBox(width: 2),
                                  Text(
                                    '清除',
                                    style: TextStyle(
                                      color: Colors.orangeAccent,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),

                      // 文本输入区
                      Expanded(
                        child: GestureDetector(
                          onSecondaryTapDown: _isDesktopPlatform
                              ? (_) {
                                  _pasteIntoController(controller);
                                  setDialogState(() {});
                                }
                              : null,
                          child: TextField(
                            controller: controller,
                            maxLines: null,
                            expands: true,
                            textAlignVertical: TextAlignVertical.top,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontFamily: 'monospace',
                            ),
                            decoration: InputDecoration(
                              filled: true,
                              fillColor: Colors.black26,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(6),
                                borderSide: BorderSide.none,
                              ),
                              contentPadding: const EdgeInsets.all(10),
                              hintText: '在此粘贴 AI 返回的完整字幕文本...',
                              hintStyle: const TextStyle(
                                color: Colors.white24,
                                fontSize: 12,
                              ),
                            ),
                            onChanged: (_) => setDialogState(() {}),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  DesktopButtonClickRegion(
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text(
                        '取消',
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
                  ),
                  DesktopButtonClickRegion(
                    child: ElevatedButton(
                      onPressed: controller.text.trim().isEmpty
                          ? null
                          : () => Navigator.pop(ctx, true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueAccent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 6,
                        ),
                      ),
                      child: const Text('确认导入', style: TextStyle(fontSize: 13)),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    final text = controller.text;
    controller.dispose();

    if (confirmed != true) return;
    if (text.trim().isEmpty) {
      if (mounted) {
        await _showSubtitleFailure(
          '尚未导入翻译结果',
          '请输入或粘贴翻译后的字幕内容。',
          retry: () => _showManualResultInputDialog(sourcePath),
        );
      }
      return;
    }

    await _importManualTranslatedSubtitle(sourcePath, text);
  }

  Future<void> _importManualTranslatedSubtitle(
    String sourcePath,
    String content,
  ) async {
    _clearSubtitleFeedback();
    try {
      final videoId = _requireVideoId();
      final sourceName = p.basenameWithoutExtension(sourcePath);
      final sourceExt = p.extension(sourcePath).toLowerCase();
      final ext = sourceExt.isEmpty ? '.srt' : sourceExt;
      final outputLanguage =
          _sharedTranslateSettings?.mode == SubtitleTranslationMode.smart
          ? 'mul'
          : _translateTargetLanguage;
      final safeTarget = outputLanguage.replaceAll(
        RegExp(r'[^a-zA-Z0-9_-]'),
        '-',
      );
      final outputName =
          '$sourceName.manual.translated.$safeTarget.${DateTime.now().millisecondsSinceEpoch}$ext';
      final outputPath = await _allocateSubtitleFile(videoId, outputName);

      await File(outputPath).writeAsString(content, flush: true);
      await _registerManagedSubtitle(
        outputPath,
        ManagedSubtitleAssetKind.translated,
        '$sourceName（手动翻译）',
        sourcePath: sourcePath,
        language: outputLanguage,
      );
      await _loadSubtitles();
      _notifySubtitleFilesChanged();

      if (mounted) {
        setState(() {
          _expandedTranslatePath = null;
        });
      }

      bool revealed = false;
      Object? openerError;
      try {
        revealed = await revealInFileManager(outputPath);
      } catch (error) {
        openerError = error;
      }
      if (!revealed && mounted) {
        await _showSubtitleExportResult(
          outputPath,
          revealed: false,
          openerError: openerError,
        );
        return;
      }
    } catch (e) {
      if (mounted) {
        await _showSubtitleFailure(
          '字幕导入失败',
          '请检查字幕格式、文件权限和存储空间后重试。',
          error: e,
          retry: () => _importManualTranslatedSubtitle(sourcePath, content),
        );
      }
    }
  }

  Widget _buildManualInputRow({
    required String title,
    required String preview,
    required VoidCallback onTap,
    required VoidCallback onCopy,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
          DesktopButtonClickRegion(
            child: IconButton(
              icon: const Icon(
                Icons.copy_all_rounded,
                color: Colors.white70,
                size: 17,
              ),
              tooltip: '复制',
              onPressed: onCopy,
            ),
          ),
        ],
      ),
    );
  }

  void _toggleTranslatePanel(String path) {
    if (_isActiveTranslationForCurrentVideo()) {
      return;
    }
    final nextPath = _isTranslationPanelExpandedFor(path) ? null : path;
    setState(() {
      _expandedTranslatePath = nextPath;
    });
    if (nextPath != null) {
      _prepareManualSource(nextPath);
      _restoreTranslateLanguageSettings();
    }
  }

  Future<void> _translateSubtitle(String path) async {
    _clearSubtitleFeedback();
    // 防止对同一视频重复发起翻译。
    if (_isPathTranslating(path)) return;
    final aiOptions = _aiOptions.copyWith(
      customPrompt: _aiPromptController.text,
    );
    var translationStarted = false;

    // 翻译状态由服务（单例）持有并在内部管理；
    // 完成后的列表刷新由 _onTranslationComplete 回调统一处理，
    // 因此即便本页面中途销毁，重开后仍能恢复进度并在完成时收到事件。
    try {
      final videoId = _requireVideoId();
      final library = Provider.of<LibraryService>(context, listen: false);
      final sourceAssetId = library
          .managedSubtitleAssetForPath(videoId, path)
          ?.assetId;
      final taskDirectory = await _subtitleOutputDirectory(videoId);
      final settings = _sharedTranslateSettings!;
      final choice = await TranscriptTranslateChoice.capture(
        settings,
        enabled: true,
      );
      final endpoint = choice.apiEndpoint == null
          ? null
          : await AiSubtitleApiSettingsStore().loadForSnapshot(
              choice.apiEndpoint!,
            );
      translationStarted = true;
      final result = await _subtitleTranslationService.translateSubtitleFile(
        inputPath: path,
        sourceLanguage: choice.sourceLanguage!,
        targetLanguage: choice.targetLanguage!,
        provider: choice.provider,
        smartPolicy: choice.smartPolicy,
        aiEndpoint: endpoint,
        localSpecification: choice.localSpecification,
        videoPath: widget.videoPath,
        outputDirectory: taskDirectory.path,
        outputFilePrefix: p.basenameWithoutExtension(path),
        aiOptions: aiOptions,
        onProgress: (_) {
          // 进度由服务统一通过 ChangeNotifier 通知，这里无需额外处理。
        },
      );
      await library.registerManagedSubtitleAsset(
        videoId,
        path: result.outputPath,
        kind: ManagedSubtitleAssetKind.translated,
        displayName: '${p.basenameWithoutExtension(path)}（翻译）',
        sourceAssetId: sourceAssetId,
        language: choice.targetLanguage,
      );
      if (mounted) {
        await _loadSubtitles();
      }
      // 完成事件由 _onTranslationComplete 处理，无需在此重复。
    } catch (error) {
      // The service reports failures after it starts. Snapshot/configuration
      // errors happen earlier and need their own visible message.
      if (!translationStarted && mounted) {
        await _showSubtitleFailure(
          '无法开始字幕翻译',
          '请检查字幕文件、翻译服务和语言设置后重试。',
          error: error,
          retry: () => _translateSubtitle(path),
        );
      }
    }
  }

  Widget _buildTranslateAction({required String path, required bool enabled}) {
    return DesktopButtonClickRegion(
      child: IconButton(
        icon: const Icon(
          Icons.translate,
          color: Colors.lightBlueAccent,
          size: 18,
        ),
        tooltip: "翻译字幕",
        onPressed: enabled ? () => _toggleTranslatePanel(path) : null,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
      ),
    );
  }

  // 构建内嵌字幕的翻译按钮
  Widget _buildEmbeddedTranslateButton(EmbeddedSubtitleTrack track) {
    final isExtracted = _extractedTrackPaths.containsKey(track.index);
    final isExtracting = _extractingTrackIndex == track.index;

    return DesktopButtonClickRegion(
      child: IconButton(
        icon: const Icon(
          Icons.translate,
          color: Colors.lightBlueAccent,
          size: 18,
        ),
        tooltip: isExtracted ? "翻译字幕" : "提取并翻译字幕",
        onPressed: isExtracting ? null : () => _handleEmbeddedTranslate(track),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
      ),
    );
  }

  // 处理内嵌字幕的翻译：已提取则直接翻译，未提取则先提取再翻译
  Future<void> _handleEmbeddedTranslate(EmbeddedSubtitleTrack track) async {
    // 如果已经提取过，直接打开翻译面板
    if (_extractedTrackPaths.containsKey(track.index)) {
      _toggleTranslatePanel(_extractedTrackPaths[track.index]!);
      return;
    }

    // 否则先提取，再打开翻译面板
    await _extractAndTranslate(track);
  }

  // 提取字幕并打开翻译面板
  Future<void> _extractAndTranslate(EmbeddedSubtitleTrack track) async {
    _clearSubtitleFeedback();
    if (_extractingTrackIndex != null) return;

    setState(() => _extractingTrackIndex = track.index);

    try {
      final videoId = _requireVideoId();
      final subDir = await const TaskSubtitleStorageService().taskDirectory(
        videoId,
        create: true,
      );

      if (!mounted) return;
      final service = Provider.of<EmbeddedSubtitleService>(
        context,
        listen: false,
      );
      final path = await service.extractSubtitle(
        widget.videoPath,
        track.index,
        subDir.path,
        codecName: track.codecName,
        videoId: widget.videoId,
      );

      if (path != null && mounted) {
        await _registerManagedSubtitle(
          path,
          ManagedSubtitleAssetKind.embedded,
          _displayEmbeddedTitle(track),
        );
        // 保存提取路径
        setState(() {
          _extractedTrackPaths[track.index] = path;
        });

        // 打开翻译面板
        _toggleTranslatePanel(path);
      } else {
        if (mounted) {
          await _showSubtitleFailure(
            '无法提取内嵌字幕',
            '媒体中没有可提取的字幕，或该字幕格式暂不受支持。',
            retry: () => _extractAndTranslate(track),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        await _showSubtitleFailure(
          '内嵌字幕提取失败',
          '请检查媒体文件是否完整，并确认字幕格式受支持。',
          error: e,
          retry: () => _extractAndTranslate(track),
        );
      }
    } finally {
      if (mounted) setState(() => _extractingTrackIndex = null);
    }
  }

  Widget _buildAiTranslationOptions({
    required bool busy,
    bool showApiEntry = false,
  }) {
    final binding = _aiBinding;
    final notReady = binding != null && !binding.ready;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showApiEntry)
          Align(
            alignment: Alignment.centerRight,
            child: _SubtitleApiGlassButton(onPressed: _openAiApiSettings),
          ),
        if (showApiEntry) const SizedBox(height: 6),
        Text(
          binding?.summary ?? '正在读取翻译接口…',
          style: TextStyle(
            color: notReady ? Colors.orange : Colors.white60,
            fontSize: 11,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 8),
        CapsuleDropdownButtonFormField<int>(
          key: ValueKey('ai-batch-${_aiOptions.batchSize}'),
          initialValue: _aiOptions.batchSize,
          decoration: const InputDecoration(
            labelText: '每批条数',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          dropdownColor: const Color(0xFF2A2A2A),
          style: const TextStyle(color: Colors.white, fontSize: 12),
          items: [
            for (final size in AiSubtitleTranslationSettings.batchChoices)
              DropdownMenuItem(
                value: size,
                child: Text('$size 条', style: const TextStyle(fontSize: 12)),
              ),
          ],
          onChanged: busy
              ? null
              : (value) {
                  if (value == null) return;
                  setState(() {
                    _aiOptions = _aiOptions.copyWith(batchSize: value);
                  });
                  _scheduleTranslatePrefsSave();
                },
        ),
        const SizedBox(height: 8),
        CapsuleDropdownButtonFormField<int>(
          key: ValueKey('ai-threads-${_aiOptions.threadNum}'),
          initialValue: _aiOptions.threadNum,
          decoration: const InputDecoration(
            labelText: '并发数',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          dropdownColor: const Color(0xFF2A2A2A),
          style: const TextStyle(color: Colors.white, fontSize: 12),
          items: [
            for (final count in AiSubtitleTranslationSettings.threadChoices)
              DropdownMenuItem(
                value: count,
                child: Text('$count', style: const TextStyle(fontSize: 12)),
              ),
          ],
          onChanged: busy
              ? null
              : (value) {
                  if (value == null) return;
                  setState(() {
                    _aiOptions = _aiOptions.copyWith(threadNum: value);
                  });
                  _scheduleTranslatePrefsSave();
                },
        ),
        if (binding?.usesCli == true)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              'Codex / OpenCode 按顺序翻译，上面的并发只对 API 生效。',
              style: TextStyle(color: Colors.white38, fontSize: 10),
            ),
          ),
        const SizedBox(height: 4),
        Row(
          children: [
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '反思翻译',
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                  Text(
                    '先直译，再改成更自然的说法。更慢，也更费额度。',
                    style: TextStyle(color: Colors.white38, fontSize: 10),
                  ),
                ],
              ),
            ),
            Switch(
              value: _aiOptions.reflect,
              onChanged: busy
                  ? null
                  : (value) {
                      setState(() {
                        _aiOptions = _aiOptions.copyWith(reflect: value);
                      });
                      _scheduleTranslatePrefsSave();
                    },
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ],
        ),
        TextField(
          controller: _aiPromptController,
          focusNode: _aiPromptFocus,
          enabled: !busy,
          minLines: 2,
          maxLines: 4,
          style: const TextStyle(color: Colors.white, fontSize: 12),
          decoration: const InputDecoration(
            labelText: '术语与要求',
            hintText: '例如：角色名保持原文；语气口语化',
            hintStyle: TextStyle(color: Colors.white38, fontSize: 12),
            isDense: true,
            border: OutlineInputBorder(),
          ),
        ),
      ],
    );
  }

  Widget _musicTranslationPicker(
    String label,
    String value,
    List<(String, VoidCallback, bool)> choices,
    bool busy,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: CapsuleDropdownButtonFormField<String>(
        initialValue: choices.any((choice) => choice.$1 == value)
            ? value
            : null,
        decoration: InputDecoration(labelText: label),
        items: [
          for (final choice in choices)
            DropdownMenuItem(value: choice.$1, child: Text(choice.$1)),
        ],
        onChanged: busy
            ? null
            : (next) {
                if (next != null) {
                  choices.firstWhere((choice) => choice.$1 == next).$2();
                }
              },
      ),
    );
  }

  Widget _buildMusicTranslationPanel(String path, bool enabled) {
    final busy = _isPathTranslating(path);
    if (!_isTranslationPanelExpandedFor(path)) {
      if (!busy) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const CupertinoActivityIndicator(),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _subtitleTranslationService.activity ?? '翻译中…',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
          ],
        ),
      );
    }
    const providers = {
      SubtitleTranslateProvider.bing: '必应翻译',
      SubtitleTranslateProvider.ai: 'AI 翻译',
      SubtitleTranslateProvider.local: '本地模型翻译',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Divider(height: 16, color: Colors.white.withValues(alpha: 0.06)),
          Align(
            alignment: Alignment.centerRight,
            child: ModelCenterButton(
              foregroundColor: const Color(0xFFFA8896),
              onPressed: _openModelSettings,
            ),
          ),
          CupertinoSlidingSegmentedControl<bool>(
            groupValue: _manualTranslateMode,
            backgroundColor: Colors.white.withValues(alpha: 0.05),
            thumbColor: const Color(0xFF48484A),
            children: const {false: Text('自动翻译'), true: Text('手动翻译')},
            onValueChanged: (value) {
              if (busy || value == null) return;
              setState(() => _manualTranslateMode = value);
              _scheduleTranslatePrefsSave();
            },
          ),
          const SizedBox(height: 8),
          if (_sharedTranslateSettings case final settings?)
            TranslationLanguageControls(
              settings: settings,
              enabled: !busy,
              foregroundColor: Colors.white,
            ),
          if (!_manualTranslateMode) ...[
            _musicTranslationPicker(
              '翻译服务',
              providers[_translateProvider] ?? '',
              providers.entries
                  .map(
                    (entry) => (
                      entry.value,
                      () {
                        unawaited(
                          _sharedTranslateSettings!.setProviderEnZh(entry.key),
                        );
                        if (entry.key == SubtitleTranslateProvider.ai) {
                          _refreshAiBinding();
                        }
                      },
                      false,
                    ),
                  )
                  .toList(),
              busy,
            ),
            if (_translateProvider == SubtitleTranslateProvider.ai)
              _buildAiTranslationOptions(busy: busy, showApiEntry: true),
            if (busy)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    const CupertinoActivityIndicator(),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _subtitleTranslationService.activity ?? '翻译中…',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            CupertinoButton(
              padding: const EdgeInsets.symmetric(vertical: 10),
              color: const Color(0xFFFA586A),
              borderRadius: BorderRadius.circular(12),
              onPressed: !enabled || busy
                  ? null
                  : () => _translateSubtitle(path),
              child: Text(
                _translateActionLabel,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
          ] else ...[
            CupertinoButton(
              padding: const EdgeInsets.symmetric(vertical: 8),
              onPressed: _showManualSourceEditor,
              child: const Text('查看字幕全文', style: TextStyle(fontSize: 14)),
            ),
            CupertinoButton(
              padding: const EdgeInsets.symmetric(vertical: 8),
              onPressed: _showManualPromptEditor,
              child: const Text('编辑翻译提示词', style: TextStyle(fontSize: 14)),
            ),
            CupertinoButton(
              padding: const EdgeInsets.symmetric(vertical: 8),
              onPressed: () => _copyText(
                _manualPromptSubtitleFirst
                    ? '${_manualFullPromptText()}\n\n${_manualSourceController.text}'
                    : '${_manualSourceController.text}\n\n${_manualFullPromptText()}',
              ),
              child: const Text('复制提示词与字幕', style: TextStyle(fontSize: 14)),
            ),
            CupertinoButton(
              padding: const EdgeInsets.symmetric(vertical: 8),
              onPressed: () => _showMusicActions('手动翻译', [
                (
                  '复制字幕全文',
                  () => _copyText(_manualSourceController.text),
                  false,
                ),
                ('复制提示词', () => _copyText(_manualFullPromptText()), false),
                (
                  '交换复制顺序',
                  () {
                    setState(
                      () => _manualPromptSubtitleFirst =
                          !_manualPromptSubtitleFirst,
                    );
                    _scheduleTranslatePrefsSave();
                  },
                  false,
                ),
                ('手动翻译帮助', _showManualHelpDialog, false),
                ('管理 AI 接口', _openAiApiSettings, false),
              ]),
              child: const Text('更多选项', style: TextStyle(fontSize: 14)),
            ),
            CupertinoButton(
              padding: const EdgeInsets.symmetric(vertical: 10),
              color: const Color(0xFFFA586A),
              borderRadius: BorderRadius.circular(12),
              onPressed: enabled
                  ? () => _showManualResultInputDialog(path)
                  : null,
              child: const Text(
                '输入翻译结果',
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTranslationPanel({required String path, required bool enabled}) {
    if (_isMusicIOS) return _buildMusicTranslationPanel(path, enabled);
    // 即使面板未展开，若该字幕正在翻译（含重开页面后恢复的进度），也显示精简进度条。
    if (!_isTranslationPanelExpandedFor(path)) {
      if (_isPathTranslating(path)) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          child: Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: LinearProgressIndicator(
                  value: _subtitleTranslationService.progress,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _subtitleTranslationService.activity ??
                    '${(100 * _subtitleTranslationService.progress).toStringAsFixed(0)}%',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white60, fontSize: 11),
              ),
            ],
          ),
        );
      }
      return const SizedBox.shrink();
    }

    final busy = _isPathTranslating(path);

    final sourcePreview = _isLoadingManualSource
        ? '正在读取字幕全文...'
        : _singleLinePreview(_manualSourceController.text);
    final promptPreview = _singleLinePreview(_manualFullPromptText());

    final orderedRows = _manualPromptSubtitleFirst
        ? [
            _buildManualInputRow(
              title: '提示词（点击展开）',
              preview: promptPreview,
              onTap: _showManualPromptEditor,
              onCopy: () => _copyText(_manualFullPromptText()),
            ),
            _buildManualInputRow(
              title: '字幕全文（点击展开）',
              preview: sourcePreview,
              onTap: _showManualSourceEditor,
              onCopy: () => _copyText(_manualSourceController.text),
            ),
          ]
        : [
            _buildManualInputRow(
              title: '字幕全文（点击展开）',
              preview: sourcePreview,
              onTap: _showManualSourceEditor,
              onCopy: () => _copyText(_manualSourceController.text),
            ),
            _buildManualInputRow(
              title: '提示词（点击展开）',
              preview: promptPreview,
              onTap: _showManualPromptEditor,
              onCopy: () => _copyText(_manualFullPromptText()),
            ),
          ];

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: 4,
            children: [
              const Text(
                '字幕翻译',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ModelCenterButton(
                    compact: true,
                    foregroundColor: Colors.lightBlueAccent,
                    onPressed: _openModelSettings,
                  ),
                  _SubtitleApiGlassButton(onPressed: _openAiApiSettings),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '自动',
                    style: TextStyle(color: Colors.white60, fontSize: 11),
                  ),
                  Switch(
                    value: _manualTranslateMode,
                    onChanged: busy
                        ? null
                        : (v) {
                            setState(() {
                              _manualTranslateMode = v;
                            });
                            _scheduleTranslatePrefsSave();
                          },
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  const Text(
                    '手动',
                    style: TextStyle(color: Colors.white60, fontSize: 11),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (_sharedTranslateSettings case final settings?)
            TranslationLanguageControls(
              settings: settings,
              enabled: !busy,
              foregroundColor: Colors.white,
            ),
          const SizedBox(height: 8),
          if (!_manualTranslateMode) ...[
            CapsuleDropdownButtonFormField<SubtitleTranslateProvider>(
              isExpanded: true,
              initialValue: _translateProvider,
              decoration: const InputDecoration(
                labelText: '翻译服务',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              dropdownColor: const Color(0xFF2A2A2A),
              style: const TextStyle(color: Colors.white, fontSize: 12),
              items: const [
                DropdownMenuItem(
                  value: SubtitleTranslateProvider.bing,
                  child: Text(
                    '必应翻译',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                DropdownMenuItem(
                  value: SubtitleTranslateProvider.ai,
                  child: Text(
                    'AI 翻译',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                DropdownMenuItem(
                  value: SubtitleTranslateProvider.local,
                  child: Text(
                    '本地模型翻译',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
              onChanged: busy
                  ? null
                  : (value) {
                      if (value == null) return;
                      unawaited(
                        _sharedTranslateSettings!.setProviderEnZh(value),
                      );
                      if (value == SubtitleTranslateProvider.ai) {
                        _refreshAiBinding();
                      }
                    },
            ),
            if (_translateProvider == SubtitleTranslateProvider.ai) ...[
              const SizedBox(height: 8),
              _buildAiTranslationOptions(busy: busy),
            ],
            const SizedBox(height: 10),
            if (busy) ...[
              LinearProgressIndicator(
                value: _subtitleTranslationService.progress,
              ),
              const SizedBox(height: 6),
              Text(
                _subtitleTranslationService.activity ??
                    '翻译中 ${(100 * _subtitleTranslationService.progress).toStringAsFixed(0)}%',
                style: const TextStyle(color: Colors.white60, fontSize: 11),
              ),
              const SizedBox(height: 8),
            ],
            DesktopButtonClickRegion(
              child: ElevatedButton.icon(
                onPressed: (!enabled || busy)
                    ? null
                    : () => _translateSubtitle(path),
                icon: const Icon(Icons.translate, size: 16),
                label: Text(
                  _translateActionLabel,
                  style: const TextStyle(fontSize: 12),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.lightBlueAccent,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ),
          ] else ...[
            ...orderedRows,
            Row(
              children: [
                DesktopButtonClickRegion(
                  child: TextButton.icon(
                    onPressed: () {
                      setState(() {
                        _manualPromptSubtitleFirst =
                            !_manualPromptSubtitleFirst;
                      });
                      _scheduleTranslatePrefsSave();
                    },
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white70,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                    ),
                    icon: const Icon(Icons.swap_vert, size: 16),
                    label: const Text('切换顺序', style: TextStyle(fontSize: 11)),
                  ),
                ),
                const Spacer(),
                DesktopButtonClickRegion(
                  child: TextButton.icon(
                    onPressed: _showManualHelpDialog,
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.lightBlueAccent,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                    ),
                    icon: const Icon(Icons.help_outline, size: 16),
                    label: const Text('帮助', style: TextStyle(fontSize: 11)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                DesktopButtonClickRegion(
                  child: ElevatedButton.icon(
                    onPressed: () {
                      final first = _manualPromptSubtitleFirst
                          ? _manualFullPromptText()
                          : _manualSourceController.text;
                      final second = _manualPromptSubtitleFirst
                          ? _manualSourceController.text
                          : _manualFullPromptText();
                      _copyText('$first\n\n$second');
                    },
                    icon: const Icon(Icons.copy_all, size: 15),
                    label: const Text('复制全部', style: TextStyle(fontSize: 11)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white10,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                    ),
                  ),
                ),
                DesktopButtonClickRegion(
                  child: ElevatedButton.icon(
                    onPressed: enabled
                        ? () => _showManualResultInputDialog(path)
                        : null,
                    icon: const Icon(Icons.edit_note, size: 15),
                    label: const Text('输入翻译结果', style: TextStyle(fontSize: 11)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.lightBlueAccent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return _buildContent(context, constraints.biggest);
      },
    );
  }

  Widget _buildContent(BuildContext context, Size availableSize) {
    final size = MediaQuery.sizeOf(context);
    final textScaler = MediaQuery.textScalerOf(context);
    final sidebarSize = _isMusicIOS
        ? availableSize
        : size.width > size.height
        ? Size(LandscapeSidebarLayout.functionalWidthFor(size), size.height)
        : size;
    final layout = LandscapeSidebarLayout.fromSize(sidebarSize);
    final searchContentWidth = availableSize.width.isFinite
        ? availableSize.width - layout.horizontalPadding * 2
        : 640.0;
    final stackedPrimaryActions =
        widget.onOpenOcrSubtitle != null &&
        searchContentWidth < 330 * textScaler.scale(1);
    // 大字号时并排更容易把标题挤掉，阈值跟着文字缩放一起变宽。
    final pairSearchEntries = searchContentWidth >= 240 * textScaler.scale(1);
    final shownPaths = <String>{};
    final associatedSubtitles = <String, String>{
      ...?widget.associatedSubtitles,
    };
    final bilibiliTracks = widget.bilibiliTracks;
    final bilibiliItemId = widget.videoId;
    final showBilibiliTracks = bilibiliTracks != null && bilibiliItemId != null;
    final cloudTracks = widget.cloudDriveTracks;
    final cloudItemId = widget.videoId;
    final showCloudTracks = cloudTracks != null && cloudItemId != null;
    if (cloudTracks != null && cloudItemId != null) {
      for (final track in cloudTracks.listFor(cloudItemId).tracks) {
        final path = track.savedPath;
        if (path != null) shownPaths.add(_normalizePath(path));
      }
    }
    if (showBilibiliTracks) {
      // The group lists every file bound to the card (also ones saved after
      // the page last rebuilt), so no other group shows them again.
      final item = bilibiliTracks.store.itemOf(bilibiliItemId);
      associatedSubtitles.addAll(
        item?.downloadAssociatedSubtitles ?? const <String, String>{},
      );
      shownPaths.addAll(associatedSubtitles.values.map(_normalizePath));
    }
    final classification = SubtitleClassificationIndex(
      downloadAssociatedPaths: associatedSubtitles.values,
      extractedEmbeddedPaths: _extractedTrackPaths.values,
    );
    final localSubtitleFiles = _subtitleFiles.where((file) {
      if (classification.categoryForPath(file.path) != SubtitleCategory.local) {
        return false;
      }
      return !_extractedTrackPaths.values.any(
        (path) => _normalizePath(path) == _normalizePath(file.path),
      );
    }).toList();
    final hasEmbeddedContent =
        widget.showEmbeddedSubtitles &&
        (_embeddedTracks.isNotEmpty ||
            _extractedTrackPaths.isNotEmpty ||
            widget.embeddedError != null);
    return Container(
      padding: EdgeInsets.fromLTRB(
        layout.horizontalPadding,
        layout.verticalPadding,
        layout.horizontalPadding,
        layout.verticalPadding,
      ),
      decoration: BoxDecoration(
        color: _isMusicIOS ? Colors.transparent : const Color(0xFF1E1E1E),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.showHeader)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  "字幕管理",
                  style: TextStyle(
                    fontSize: layout.titleSize,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const Spacer(),
                DesktopButtonClickRegion(
                  child: IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: () {
                      if (widget.onClose != null) {
                        widget.onClose!();
                      } else {
                        Navigator.pop(context);
                      }
                    },
                    constraints: const BoxConstraints(),
                    padding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),

          // 歌曲、播客和视频播放页都提供歌词搜索与在线字幕搜索。
          Padding(
            padding: EdgeInsets.only(top: layout.sectionGap, bottom: 4),
            child: _buildSearchEntries(paired: pairSearchEntries),
          ),

          if (_isMusicIOS &&
              (Platform.isWindows || Platform.isLinux || Platform.isMacOS))
            Align(
              alignment: Alignment.centerRight,
              child: CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                minimumSize: const Size(0, 32),
                onPressed: () => _showMusicActions('字幕导出位置', [
                  ('选择导出位置', _setCustomDownloadPath, false),
                  ('打开导出目录', _openDownloadDirectory, false),
                ]),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '导出位置',
                      style: TextStyle(fontSize: 12, color: Colors.white54),
                    ),
                    SizedBox(width: 4),
                    Icon(
                      CupertinoIcons.chevron_down,
                      size: 10,
                      color: Colors.white54,
                    ),
                  ],
                ),
              ),
            ),
          if (!_isMusicIOS &&
              (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) ...[
            SizedBox(height: layout.sectionGap),
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: layout.horizontalPadding,
                vertical: layout.verticalPadding,
              ),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white10),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.download_rounded,
                    color: Colors.white54,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SingleChildScrollView(
                      key: const PageStorageKey(
                        'subtitle-manager-download-path',
                      ),
                      scrollDirection: Axis.horizontal,
                      child: Text(
                        _customDownloadPath ?? "默认: $_defaultDownloadPath",
                        style: TextStyle(
                          color: _customDownloadPath != null
                              ? Colors.white
                              : Colors.white38,
                          fontSize: 12,
                          fontFamily: _isMusicIOS ? 'Inter' : 'monospace',
                        ),
                        maxLines: 1,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  DesktopButtonClickRegion(
                    child: TextButton(
                      onPressed: _setCustomDownloadPath,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        backgroundColor: Colors.white10,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      child: const Text("浏览", style: TextStyle(fontSize: 12)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: "打开导出目录",
                    child: InkWell(
                      onTap: _openDownloadDirectory,
                      borderRadius: BorderRadius.circular(4),
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.white10,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Icon(
                          Icons.folder,
                          color: Colors.amber,
                          size: 16,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          if (_feedbackTitle != null) _buildSubtitleFeedback(),
          SizedBox(height: layout.sectionGap / 2),

          Expanded(
            child:
                (_subtitleFiles.isEmpty &&
                    !hasEmbeddedContent &&
                    associatedSubtitles.isEmpty &&
                    !showBilibiliTracks &&
                    !showCloudTracks &&
                    !_isScanningFiles &&
                    !_isScanningSidecars &&
                    !_isScanningEmbedded)
                ? const Center(
                    child: Text(
                      "暂无关联字幕文件",
                      style: TextStyle(color: Colors.white54),
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView(
                    key: const PageStorageKey('subtitle-manager-files'),
                    children: [
                      if (cloudTracks != null && cloudItemId != null) ...[
                        CloudDriveSubtitleTracksSection(
                          itemId: cloudItemId,
                          tracks: cloudTracks,
                          onPick: _selectFetchedSubtitle,
                          savedRow: (track) => _buildAssociatedRow(
                            label: track.label,
                            path: track.savedPath!,
                            isAi: track.isAi,
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 4),
                          child: Divider(color: Colors.white10, height: 1),
                        ),
                      ],
                      // 1. Subtitles created and bound by a download task;
                      // for a Bilibili video, all of its tracks.
                      if (showBilibiliTracks) ...[
                        BilibiliSubtitleTracksSection(
                          itemId: bilibiliItemId,
                          tracks: bilibiliTracks,
                          onPick: _selectFetchedSubtitle,
                          savedRow: (track) => _buildAssociatedRow(
                            label: track.label,
                            path: track.path!,
                            isAi: track.isAi,
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 4),
                          child: Divider(color: Colors.white10, height: 1),
                        ),
                      ] else if (associatedSubtitles.isNotEmpty) ...[
                        const Padding(
                          padding: EdgeInsets.only(bottom: 4, top: 4),
                          child: Text(
                            "媒体库关联字幕",
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        ...associatedSubtitles.entries
                            .where(
                              (entry) =>
                                  shownPaths.add(_normalizePath(entry.value)),
                            )
                            .map(
                              (entry) => _buildAssociatedRow(
                                label: _displayNameForPath(
                                  entry.value,
                                  fallback: entry.key,
                                ),
                                path: entry.value,
                              ),
                            ),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 4),
                          child: Divider(color: Colors.white10, height: 1),
                        ),
                      ],

                      // 2. Embedded Tracks Section
                      if (hasEmbeddedContent) ...[
                        const Padding(
                          padding: EdgeInsets.only(bottom: 4, top: 4),
                          child: Text(
                            "内嵌字幕 (点击提取)",
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        if (widget.embeddedError != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.embeddedError!,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 13,
                                  ),
                                ),
                                if (widget.onRetryEmbedded != null)
                                  TextButton(
                                    onPressed: widget.onRetryEmbedded,
                                    child: const Text('重试'),
                                  ),
                              ],
                            ),
                          ),
                        if (_embeddedTracks.isEmpty) ...[
                          ..._extractedTrackPaths.entries
                              .where(
                                (e) => shownPaths.add(_normalizePath(e.value)),
                              )
                              .where(
                                (e) =>
                                    classification.categoryForPath(e.value) ==
                                    SubtitleCategory.embedded,
                              )
                              .map((entry) {
                                final trackIndex = entry.key;
                                final path = entry.value;
                                final exists = File(path).existsSync();
                                if (_isMusicIOS) {
                                  return _buildMusicRow(
                                    label: _displayEmbeddedTitleByIndex(
                                      trackIndex,
                                    ),
                                    description: exists
                                        ? p.basename(path)
                                        : '文件丢失',
                                    path: path,
                                    onTap: exists
                                        ? () => _handleSelection(path)
                                        : null,
                                    actions: [
                                      if (exists)
                                        (
                                          '导出字幕',
                                          () => _downloadSubtitleFile(path),
                                          false,
                                        ),
                                      if (exists)
                                        (
                                          '翻译字幕',
                                          () => _toggleTranslatePanel(path),
                                          false,
                                        ),
                                    ],
                                    expanded: _buildTranslationPanel(
                                      path: path,
                                      enabled: exists,
                                    ),
                                  );
                                }
                                return Container(
                                  margin: _rowMargin,
                                  clipBehavior: Clip.antiAlias,
                                  decoration: _subtitleRowDecoration(
                                    Colors.blueAccent,
                                    path: path,
                                  ),
                                  child: Column(
                                    children: [
                                      SubtitleManagementTile(
                                        selected: _selectedContains(path),
                                        leading: const Icon(
                                          Icons.closed_caption,
                                          color: Colors.blueAccent,
                                          size: 20,
                                        ),
                                        title: Text(
                                          _displayEmbeddedTitleByIndex(
                                            trackIndex,
                                          ),
                                          style: TextStyle(
                                            color: _selectedContains(path)
                                                ? Colors.blueAccent
                                                : Colors.white,
                                            fontSize: 13,
                                            fontWeight: _selectedContains(path)
                                                ? FontWeight.bold
                                                : FontWeight.normal,
                                          ),
                                        ),
                                        subtitle: Text(
                                          exists ? p.basename(path) : "文件丢失",
                                          style: TextStyle(
                                            color: exists
                                                ? Colors.white30
                                                : Colors.redAccent,
                                            fontSize: 11,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        selectionBadge: _selectedContains(path)
                                            ? _buildSelectionBadge(path)
                                            : null,
                                        actions: [
                                          DesktopButtonClickRegion(
                                            child: IconButton(
                                              tooltip: '导出字幕',
                                              icon: const Icon(
                                                Icons.download_outlined,
                                                color: Colors.white70,
                                                size: 18,
                                              ),
                                              onPressed: exists
                                                  ? () => _downloadSubtitleFile(
                                                      path,
                                                    )
                                                  : null,
                                              padding: EdgeInsets.zero,
                                              constraints:
                                                  const BoxConstraints(),
                                            ),
                                          ),
                                          _buildTranslateAction(
                                            path: path,
                                            enabled: exists,
                                          ),
                                        ],
                                        onTap: exists
                                            ? () => _handleSelection(path)
                                            : null,
                                      ),
                                      _buildTranslationPanel(
                                        path: path,
                                        enabled: exists,
                                      ),
                                    ],
                                  ),
                                );
                              }),
                        ],
                        ..._embeddedTracks.map((track) {
                          final isImage = _isImageSubtitleCodec(
                            track.codecName,
                          );
                          // 获取提取后的路径（如果已提取）
                          final extractedPath =
                              _extractedTrackPaths[track.index];
                          final exists =
                              extractedPath != null &&
                              File(extractedPath).existsSync();
                          if (_isMusicIOS) {
                            return _buildMusicRow(
                              label: _displayEmbeddedTitle(track),
                              description:
                                  '${track.language} · ${track.codecName}${isImage ? ' · 图像字幕' : ''}',
                              path: extractedPath,
                              busy: _extractingTrackIndex == track.index,
                              onTap: _extractingTrackIndex == track.index
                                  ? null
                                  : () => _handleEmbeddedTrackSelection(track),
                              actions: _extractingTrackIndex == track.index
                                  ? []
                                  : [
                                      (
                                        '导出字幕',
                                        () => _downloadEmbeddedTrack(track),
                                        false,
                                      ),
                                      (
                                        '翻译字幕',
                                        () => _handleEmbeddedTranslate(track),
                                        false,
                                      ),
                                    ],
                              expanded: extractedPath == null
                                  ? const SizedBox.shrink()
                                  : _buildTranslationPanel(
                                      path: extractedPath,
                                      enabled: exists,
                                    ),
                            );
                          }

                          return Container(
                            margin: _rowMargin,
                            clipBehavior: Clip.antiAlias,
                            decoration: _subtitleRowDecoration(
                              Colors.blueAccent,
                              path: extractedPath,
                            ),
                            child: Column(
                              children: [
                                SubtitleManagementTile(
                                  selected:
                                      extractedPath != null &&
                                      _selectedContains(extractedPath),
                                  leading:
                                      (_extractingTrackIndex == track.index)
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(
                                          Icons.closed_caption,
                                          color: Colors.blueAccent,
                                          size: 20,
                                        ),
                                  title: Text(
                                    _displayEmbeddedTitle(track),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                    ),
                                  ),
                                  subtitle: Text(
                                    "${track.language} • ${track.codecName}${isImage ? " • 图像字幕" : ""}",
                                    style: const TextStyle(
                                      color: Colors.white30,
                                      fontSize: 11,
                                    ),
                                  ),
                                  selectionBadge:
                                      extractedPath != null &&
                                          _selectedContains(extractedPath)
                                      ? _buildSelectionBadge(extractedPath)
                                      : null,
                                  actions: [
                                    DesktopButtonClickRegion(
                                      child: IconButton(
                                        tooltip: '导出字幕',
                                        icon: const Icon(
                                          Icons.download_outlined,
                                          color: Colors.white70,
                                          size: 18,
                                        ),
                                        onPressed:
                                            _extractingTrackIndex == track.index
                                            ? null
                                            : () =>
                                                  _downloadEmbeddedTrack(track),
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(),
                                      ),
                                    ),
                                    // 翻译按钮：已提取则直接翻译，未提取则先提取再翻译
                                    _buildEmbeddedTranslateButton(track),
                                  ],
                                  onTap: () =>
                                      _handleEmbeddedTrackSelection(track),
                                ),
                                // 添加翻译面板（如果已展开）
                                if (extractedPath != null)
                                  _buildTranslationPanel(
                                    path: extractedPath,
                                    enabled: exists,
                                  ),
                              ],
                            ),
                          );
                        }),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 4),
                          child: Divider(color: Colors.white10, height: 1),
                        ),
                      ],

                      // 3. All non-download, non-embedded subtitle files.
                      if (localSubtitleFiles.isNotEmpty) ...[
                        const Padding(
                          padding: EdgeInsets.only(bottom: 4, top: 4),
                          child: Text(
                            "本地字幕",
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        ...localSubtitleFiles
                            .where(
                              (file) =>
                                  shownPaths.add(_normalizePath(file.path)),
                            )
                            .map((file) {
                              final name = p.basename(file.path);
                              final isManual = name.contains(".manual.");
                              ManagedSubtitleAsset? managedAsset;
                              final videoId = widget.videoId;
                              if (videoId != null && videoId.isNotEmpty) {
                                try {
                                  managedAsset =
                                      Provider.of<LibraryService>(
                                        context,
                                        listen: false,
                                      ).managedSubtitleAssetForPath(
                                        videoId,
                                        file.path,
                                      );
                                } catch (_) {}
                              }
                              final isOcr =
                                  managedAsset?.kind ==
                                  ManagedSubtitleAssetKind.ocr;
                              final isAi =
                                  name.contains('.ai.') ||
                                  _isGeneratedAiFileName(name) ||
                                  managedAsset?.kind ==
                                      ManagedSubtitleAssetKind.ai;
                              final storedName =
                                  managedAsset?.displayName.trim() ?? '';
                              // A stored name is the accurate label and may be
                              // shared by several files. Filename markers are
                              // only a fallback for older files that have none.
                              // `ai.srt` has no readable label of its own.
                              String displayName = storedName.isNotEmpty
                                  ? storedName
                                  : name;
                              if (isAi &&
                                  (storedName.isEmpty || storedName == name)) {
                                displayName = 'AI 字幕';
                              }
                              if (storedName.isEmpty && isManual) {
                                final parts = name.split('.manual.');
                                if (parts.length > 1) {
                                  final afterManual = parts
                                      .sublist(1)
                                      .join('.manual.');
                                  // 去掉末尾的 timestamp.ext 部分
                                  final dotIdx = afterManual.lastIndexOf('.');
                                  if (dotIdx > 0) {
                                    final withoutExt = afterManual.substring(
                                      0,
                                      dotIdx,
                                    );
                                    final lastDot = withoutExt.lastIndexOf('.');
                                    if (lastDot > 0) {
                                      displayName = withoutExt.substring(
                                        0,
                                        lastDot,
                                      );
                                    } else {
                                      displayName = withoutExt;
                                    }
                                  }
                                }
                              }

                              if (_isMusicIOS) {
                                return _buildMusicRow(
                                  label: displayName,
                                  path: file.path,
                                  description:
                                      '${isOcr
                                          ? 'OCR · '
                                          : isAi
                                          ? 'AI · '
                                          : isManual
                                          ? '手动 · '
                                          : ''}${_formatFileSize(_subtitleFileSizes[_normalizePath(file.path)] ?? 0)}${_streamDescription(file.path)}',
                                  onTap: () => _handleSelection(file.path),
                                  actions: [
                                    if (_streamManager?.streamForPath(file.path)
                                        case final stream?
                                        when !stream.complete)
                                      (
                                        stream.phase ==
                                                SubtitleStreamPhase.generating
                                            ? '停止并保留进度'
                                            : stream.phase ==
                                                  SubtitleStreamPhase.stopping
                                            ? '正在停止'
                                            : '继续生成',
                                        () {
                                          if (stream.phase ==
                                              SubtitleStreamPhase.generating) {
                                            unawaited(
                                              _streamManager!.stopStreamForPath(
                                                file.path,
                                              ),
                                            );
                                          } else if (stream.phase !=
                                              SubtitleStreamPhase.stopping) {
                                            _streamManager!.resumeStreamForPath(
                                              file.path,
                                            );
                                          }
                                        },
                                        false,
                                      ),
                                    (
                                      '导出字幕',
                                      () => _downloadSubtitleFile(file.path),
                                      false,
                                    ),
                                    (
                                      '翻译字幕',
                                      () => _toggleTranslatePanel(file.path),
                                      false,
                                    ),
                                    ('删除字幕', () => _deleteSubtitle(file), true),
                                  ],
                                  expanded: _buildTranslationPanel(
                                    path: file.path,
                                    enabled: true,
                                  ),
                                );
                              }
                              return Container(
                                margin: _rowMargin,
                                clipBehavior: Clip.antiAlias,
                                decoration: _isMusicIOS
                                    ? _subtitleRowDecoration(
                                        Colors.white,
                                        path: file.path,
                                      )
                                    : BoxDecoration(
                                        color: Colors.white.withValues(
                                          alpha: 0.05,
                                        ),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                child: Material(
                                  type: MaterialType.transparency,
                                  child: Column(
                                    children: [
                                      SubtitleManagementTile(
                                        leading: Icon(
                                          isOcr
                                              ? Icons.document_scanner_outlined
                                              : isAi
                                              ? Icons.auto_awesome
                                              : (isManual
                                                    ? Icons.edit_note
                                                    : Icons.subtitles),
                                          color: isOcr
                                              ? Colors.lightBlueAccent
                                              : isAi
                                              ? Colors.blueAccent
                                              : (isManual
                                                    ? Colors.tealAccent
                                                    : Colors.white70),
                                          size: 20,
                                        ),
                                        title: Text(
                                          displayName,
                                          style: TextStyle(
                                            color:
                                                _selectedIndexOf(file.path) == 0
                                                ? Colors.blueAccent
                                                : (_selectedIndexOf(
                                                            file.path,
                                                          ) ==
                                                          1
                                                      ? Colors.orangeAccent
                                                      : Colors.white),
                                            fontSize: 13,
                                            fontWeight:
                                                _selectedContains(file.path)
                                                ? FontWeight.bold
                                                : FontWeight.normal,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        selectionBadge:
                                            _selectedContains(file.path)
                                            ? _buildSelectionBadge(file.path)
                                            : null,
                                        badges: [
                                          _buildSubtitleSourceBadge(file.path),
                                          _buildSidecarMatchIndicator(
                                            file.path,
                                          ),
                                          _buildOcrBadge(managedAsset),
                                          _buildTranslatedLanguageBadge(
                                            file.path,
                                          ),
                                        ],
                                        subtitle: Text(
                                          _subtitleFileSizes[_normalizePath(
                                                    file.path,
                                                  )] !=
                                                  null
                                              ? "${(_subtitleFileSizes[_normalizePath(file.path)]! / 1024).toStringAsFixed(1)} KB${_streamDescription(file.path)}"
                                              : '字幕文件',
                                          style: const TextStyle(
                                            color: Colors.white30,
                                            fontSize: 11,
                                          ),
                                        ),
                                        selected: _selectedContains(file.path),
                                        actions: [
                                          _streamAction(file.path),
                                          DesktopButtonClickRegion(
                                            child: IconButton(
                                              tooltip: '导出字幕',
                                              icon: const Icon(
                                                Icons.download_outlined,
                                                color: Colors.white70,
                                                size: 18,
                                              ),
                                              onPressed: () =>
                                                  _downloadSubtitleFile(
                                                    file.path,
                                                  ),
                                              padding: EdgeInsets.zero,
                                              constraints:
                                                  const BoxConstraints(),
                                            ),
                                          ),
                                          _buildTranslateAction(
                                            path: file.path,
                                            enabled: true,
                                          ),
                                          DesktopButtonClickRegion(
                                            child: IconButton(
                                              tooltip: '删除字幕',
                                              icon: const Icon(
                                                Icons.delete_outline,
                                                color: Colors.redAccent,
                                                size: 18,
                                              ),
                                              onPressed: () =>
                                                  _deleteSubtitle(file),
                                              padding: EdgeInsets.zero,
                                              constraints:
                                                  const BoxConstraints(),
                                            ),
                                          ),
                                        ],
                                        onTap: () =>
                                            _handleSelection(file.path),
                                      ),
                                      _buildTranslationPanel(
                                        path: file.path,
                                        enabled: true,
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }),
                      ],
                      if (_isScanningFiles ||
                          _isScanningSidecars ||
                          _isScanningEmbedded)
                        Padding(
                          key: const ValueKey('subtitle-discovery-status'),
                          padding: const EdgeInsets.only(top: 8, bottom: 8),
                          child: Row(
                            children: [
                              const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.8,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  [
                                    if (_isScanningFiles) '正在读取已保存字幕…',
                                    if (_isScanningSidecars) '正在查找本地同文件夹字幕…',
                                    if (_isScanningEmbedded) '正在检测内嵌字幕…',
                                  ].join('\n'),
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),

          SizedBox(height: layout.sectionGap),

          Row(
            children: [
              Expanded(
                child: _buildPrimaryAction(
                  layout: layout,
                  stacked: stackedPrimaryActions,
                  onPressed: _importSubtitle,
                  icon: _isMusicIOS
                      ? CupertinoIcons.folder_badge_plus
                      : Icons.folder_open,
                  label: '导入字幕',
                ),
              ),
              SizedBox(width: layout.sectionGap),
              if (widget.onOpenOcrSubtitle != null) ...[
                Expanded(
                  child: _buildPrimaryAction(
                    layout: layout,
                    stacked: stackedPrimaryActions,
                    onPressed: widget.onOpenOcrSubtitle!,
                    icon: Icons.document_scanner_outlined,
                    label: 'OCR字幕',
                  ),
                ),
                SizedBox(width: layout.sectionGap),
              ],
              Expanded(
                child: _buildPrimaryAction(
                  layout: layout,
                  stacked: stackedPrimaryActions,
                  emphasized: true,
                  onPressed: () {
                    if (widget.onClose == null) {
                      Navigator.pop(context); // Close sheet if dialog
                    }
                    widget.onOpenAi(); // Open AI panel
                  },
                  icon: _isMusicIOS
                      ? CupertinoIcons.sparkles
                      : Icons.auto_awesome,
                  label: '语音转录',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Soft glass chip so the translation endpoint stays visible in the subtitle bar.
class _SubtitleApiGlassButton extends StatelessWidget {
  const _SubtitleApiGlassButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(14);
    return Tooltip(
      message: '翻译接口',
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: Colors.white.withValues(alpha: 0.14),
              blurRadius: 12,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: radius,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(alpha: 0.18),
                    Colors.white.withValues(alpha: 0.05),
                  ],
                ),
                border: Border.all(color: Colors.white.withValues(alpha: 0.30)),
              ),
              child: DesktopButtonClickRegion(
                child: TextButton(
                  onPressed: onPressed,
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white.withValues(alpha: 0.94),
                    backgroundColor: Colors.transparent,
                    overlayColor: Colors.white.withValues(alpha: 0.08),
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    minimumSize: const Size(56, 28),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    shape: RoundedRectangleBorder(borderRadius: radius),
                  ),
                  child: const Text(
                    '接口',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
