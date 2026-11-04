import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/platform/app_video_player_controller.dart';

import '../services/media_playback_service.dart';
import '../services/app_haptics.dart';
import '../services/settings_service.dart';
import '../platform/windows_video_player_media_kit.dart';
import '../widgets/video_controls_overlay.dart';
import '../models/subtitle_style.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

class SimpleVideoPlayerScreen extends StatefulWidget {
  final String videoPath;
  final String title;

  const SimpleVideoPlayerScreen({
    super.key,
    required this.videoPath,
    required this.title,
  });

  @override
  State<SimpleVideoPlayerScreen> createState() =>
      _SimpleVideoPlayerScreenState();
}

class _SimpleVideoPlayerScreenState extends State<SimpleVideoPlayerScreen> {
  VideoPlayerController? _controller;
  String? _errorMessage;
  bool _isReady = false;
  bool _isLocked = false;
  bool _isExiting = false;
  bool _isLongPressing = false;
  String _longPressFeedbackText = '';
  double _preLongPressSpeed = 1.0;
  double _confirmedPlaybackSpeed = 1.0;
  double _lastDispatchedPlaybackSpeed = 1.0;
  int _playbackSpeedRequestId = 0;
  Future<void> _playbackSpeedCommandTail = Future<void>.value();
  final FocusNode _videoFocusNode = FocusNode();
  Future<PlaybackPreviewSuspension>? _suspension;
  TransitionRoute<dynamic>? _previewRoute;
  VideoPlayerController? _retiredController;
  Future<void>? _previewPause;
  Future<void>? _cleanupFuture;

  @override
  void initState() {
    super.initState();
    // Follow the playback page's orientation and system bars. In particular,
    // a queue DialogRoute prevents that page's RouteAware return callback.
    // Forcing and then resetting global SystemChrome state here loses it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initPlayer();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _previewRoute ??= ModalRoute.of(context);
  }

  @override
  void dispose() {
    _isExiting = true;
    _playbackSpeedRequestId++;
    _retireController();
    unawaited(_cleanupAfterRouteExit());
    _videoFocusNode.dispose();
    super.dispose();
  }

  Future<void> _exitPreview() async {
    if (_isExiting) return;
    final navigator = Navigator.of(context);
    if (!navigator.canPop()) return;
    setState(() {
      _isExiting = true;
      _retireController();
    });
    // Back must work even while the platform is still creating the player.
    // Finish this keyboard dispatch before exposing the source route. Its
    // global/early keyboard handlers must not see this same Escape as a new
    // request to exit the source player as well.
    await Future<void>.value();
    if (!mounted) return;
    navigator.pop();
  }

  void _retireController() {
    final controller = _controller;
    _controller = null;
    if (controller == null) return;
    _retiredController = controller;
    controller.removeListener(_onPlayerStateChanged);
    if (controller.value.isInitialized) {
      _previewPause = controller.pause().catchError((Object _) {});
    }
  }

  Future<void> _cleanupAfterRouteExit() =>
      _cleanupFuture ??= _performPreviewCleanup();

  Future<void> _performPreviewCleanup() async {
    // Do not release a native view still mounted during the exit animation,
    // or resume the source under an opaque preview route.
    await _previewRoute?.completed;
    final previewController = _retiredController;
    _playbackSpeedRequestId++;
    if (previewController != null) {
      final wasInitialized = previewController.value.isInitialized;
      try {
        await _previewPause;
      } catch (_) {}
      try {
        final disposal = previewController.dispose();
        if (wasInitialized) {
          await disposal;
        } else {
          // video_player.dispose joins a pending native create. It may take
          // arbitrarily long; _initPlayer's identity checks prohibit late play.
          unawaited(disposal.catchError((Object _) {}));
        }
      } catch (_) {}
    }
    try {
      final suspension = await _suspension;
      await suspension?.restore();
    } catch (error) {
      debugPrint('恢复预览前的播放失败：$error');
    }
  }

  Future<void> _initPlayer() async {
    final file = File(widget.videoPath);
    if (!await file.exists()) {
      if (!mounted || _isExiting) return;
      setState(() {
        _errorMessage = "媒体文件不存在，可能已被移动或删除";
      });
      return;
    }

    try {
      if (!mounted || _isExiting) return;
      final playbackService = Provider.of<MediaPlaybackService>(
        context,
        listen: false,
      );
      await (_suspension = playbackService.suspendForPreview());
      if (!mounted || _isExiting) return;
      final settings = Provider.of<SettingsService>(context, listen: false);
      final previewController = AppVideoPlayerController.file(
        file,
        videoPlayerOptions: MediaPlaybackService.buildVideoPlayerOptions(
          settings: settings,
        ),
      );
      _controller = previewController;
      await previewController.initialize();
      if (!_canUseController(previewController)) return;
      await previewController.setVolume(
        playbackService.isMuted ? 0 : playbackService.volume,
      );
      if (!_canUseController(previewController)) return;
      final targetSpeed = settings.effectiveGlobalPlaybackSpeed;
      if (!settings.isSamePlaybackSpeed(
        previewController.value.playbackSpeed,
        targetSpeed,
      )) {
        await previewController.setPlaybackSpeed(targetSpeed);
      }
      if (!_canUseController(previewController)) return;
      _confirmedPlaybackSpeed = targetSpeed;
      _lastDispatchedPlaybackSpeed = targetSpeed;
      previewController.addListener(_onPlayerStateChanged);

      setState(() {
        _isReady = true;
      });
      await previewController.play();
    } catch (e) {
      if (!mounted || _isExiting) return;
      setState(() {
        _errorMessage = "播放失败：无法加载该媒体 ($e)";
      });
    }
  }

  bool _canUseController(VideoPlayerController controller) =>
      mounted && !_isExiting && identical(_controller, controller);

  void _onPlayerStateChanged() {
    if (!mounted || _isExiting) return;
    setState(() {});
  }

  void _togglePlayPause() {
    if (_controller == null) return;
    unawaited(AppHaptics.lightTap(SettingsService()));
    if (_controller!.value.isPlaying) {
      _controller!.pause();
    } else {
      _controller!.play();
    }
  }

  bool _startLongPressSpeed() {
    final controller = _controller;
    if (controller == null) return false;
    final settings = Provider.of<SettingsService>(context, listen: false);
    _preLongPressSpeed = _confirmedPlaybackSpeed;
    _isLongPressing = true;
    _longPressFeedbackText = "${settings.longPressSpeed}x";
    unawaited(_requestPlaybackSpeed(controller, settings.longPressSpeed));
    return true;
  }

  void _endLongPressSpeed() {
    if (!_isLongPressing) return;
    final controller = _controller;
    _isLongPressing = false;
    if (controller == null) return;
    unawaited(_requestPlaybackSpeed(controller, _preLongPressSpeed));
  }

  Future<void> _requestPlaybackSpeed(
    VideoPlayerController controller,
    double speed,
  ) async {
    if (!speed.isFinite || speed <= 0) return;
    final requestId = ++_playbackSpeedRequestId;
    // ignore: invalid_use_of_visible_for_testing_member
    NativeVideoPlayerMediaKit.cancelPendingRateChange(controller.playerId);
    final previousCommand = _playbackSpeedCommandTail;
    final command = () async {
      try {
        await previousCommand;
      } catch (_) {}
      if (requestId != _playbackSpeedRequestId || controller != _controller) {
        return;
      }
      try {
        if ((_lastDispatchedPlaybackSpeed - speed).abs() >= 0.001) {
          _lastDispatchedPlaybackSpeed = speed;
          await controller.setPlaybackSpeed(speed);
        }
        if (requestId != _playbackSpeedRequestId || controller != _controller) {
          return;
        }
        _confirmedPlaybackSpeed = speed;
      } catch (_) {
        _lastDispatchedPlaybackSpeed = _confirmedPlaybackSpeed;
        rethrow;
      }
    }();
    _playbackSpeedCommandTail = command.catchError((Object _) {});
    await command;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_exitPreview());
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _exitPreview,
        },
        child: Focus(autofocus: true, child: _buildContent(context)),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    if (_errorMessage != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                color: Colors.redAccent,
                size: 64,
              ),
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                style: const TextStyle(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              DesktopButtonClickRegion(
                child: ElevatedButton(
                  onPressed: _exitPreview,
                  child: const Text("返回"),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (!_isReady || _controller == null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            const Center(child: CircularProgressIndicator()),
            SafeArea(
              child: DesktopButtonClickRegion(
                child: IconButton(
                  tooltip: '返回',
                  onPressed: _exitPreview,
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final settings = Provider.of<SettingsService>(context);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Center(
            child: ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: _controller!,
              builder: (context, value, child) =>
                  AspectRatio(aspectRatio: value.aspectRatio, child: child),
              child: VideoPlayer(_controller!),
            ),
          ),
          VideoControlsOverlay(
            controller: _controller!,
            isLocked: _isLocked,
            mediaTitle: widget.title,
            isPreviewMode: true,
            focusNode: _videoFocusNode,
            onTogglePlay: _togglePlayPause,
            onBackPressed: _exitPreview,
            onExitPressed: _exitPreview,
            onToggleLock: () {
              setState(() {
                _isLocked = !_isLocked;
              });
            },
            onToggleSidebar: null,
            isSubtitleSidebarVisible: false,
            onOpenSettings: null,
            onOpenSubtitleManager: null,
            onOpenSubtitleEditor: null,
            onToggleFloatingSubtitleSettings: null,
            onOpenVideoCompose: null,
            onToggleEpisodePicker: null,
            onToggleFullScreen: null,
            onSpeedUpdate: (speed) =>
                _requestPlaybackSpeed(_controller!, speed),
            doubleTapSeekSeconds: settings.doubleTapSeekSeconds,
            enableDoubleTapSubtitleSeek: false,
            showSubtitles: false,
            onToggleSubtitles: () {},
            onMoveSubtitles: () {},
            subtitles: const [],
            subtitleEntries: const [],
            subtitleStyle: const SubtitleStyle(),
            subtitleAlignment: Alignment.bottomCenter,
            onEnterSubtitleDragMode: () {},
            isLongPressing: _isLongPressing,
            longPressFeedbackText: _longPressFeedbackText,
            onLongPressStart: _startLongPressSpeed,
            onLongPressEnd: _endLongPressSpeed,
            showPlayControls: true,
            showBottomBar: true,
          ),
        ],
      ),
    );
  }
}
