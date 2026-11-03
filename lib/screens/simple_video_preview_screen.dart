import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../platform/app_video_player_controller.dart';
import '../platform/windows_video_player_media_kit.dart';
import '../services/media_playback_service.dart';
import '../theme/app_page_transitions.dart';
import '../widgets/media_library_shell.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Opens a one-off preview without touching the library playback session.
Future<void> openLocalMediaPreview(
  BuildContext context, {
  required String videoPath,
  String? title,
  bool isAudio = false,
  Future<void> Function()? beforeOpen,
}) async {
  final exists = await File(videoPath).exists();
  if (!context.mounted) return;
  if (!exists) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('媒体文件不存在，可能已被移动或删除')));
    return;
  }
  await beforeOpen?.call();
  if (!context.mounted) return;
  unawaited(
    pushAboveMediaLibrary<void>(
      context,
      AppMaterialPageRoute<void>(
        settings: const RouteSettings(name: '/media/preview'),
        allowSnapshotting: false,
        delayPushOneFrame: false,
        builder: (_) => SimpleVideoPreviewScreen(
          videoPath: videoPath,
          title: title,
          isAudio: isAudio,
        ),
      ),
    ),
  );
}

class SimpleVideoPreviewScreen extends StatefulWidget {
  const SimpleVideoPreviewScreen({
    super.key,
    required this.videoPath,
    this.title,
    this.isAudio = false,
  });

  final String videoPath;
  final String? title;
  final bool isAudio;

  @override
  State<SimpleVideoPreviewScreen> createState() =>
      _SimpleVideoPreviewScreenState();
}

class _SimpleVideoPreviewScreenState extends State<SimpleVideoPreviewScreen>
    with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  Future<void>? _cleanup;
  bool _closing = false;
  bool _foreground = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_closing) unawaited(_initialize());
    });
  }

  @override
  void dispose() {
    _closing = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_stopPreview());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) unawaited(_pausePreview());
  }

  Future<void> _pausePreview() async {
    try {
      await _controller?.pause();
    } catch (_) {
      // The native controller may already be shutting down.
    }
  }

  Future<void> _stopPreview() => _cleanup ??= _releaseController();

  Future<void> _releaseController() async {
    final controller = _controller;
    _controller = null;
    if (controller == null) return;
    try {
      await controller.pause();
    } catch (_) {}
    try {
      await controller.dispose();
    } catch (_) {}
  }

  Future<void> _exitPreview({bool didPop = false}) async {
    if (_closing) return;
    setState(() => _closing = true);
    await _pausePreview();
    // Native creation may still be pending; it must not hold the back action.
    unawaited(_stopPreview());
    if (mounted && !didPop) Navigator.of(context).pop();
  }

  Future<void> _initialize() async {
    try {
      final file = File(widget.videoPath);
      if (!await file.exists()) {
        if (mounted && !_closing) {
          setState(() => _errorMessage = '媒体文件不存在，可能已被移动或删除');
        }
        return;
      }
      if (!mounted || _closing) return;
      final playback =
          context.read<MediaPlaybackService?>() ?? MediaPlaybackService();
      if (playback.isPlaying || playback.desiredPlaying) await playback.pause();
      if (!mounted || _closing) return;

      final controller = AppVideoPlayerController.file(
        file,
        httpHeaders: {
          if (widget.isAudio)
            NativeVideoPlayerMediaKit.audioPrimaryStreamHeader: '1',
        },
        videoPlayerOptions: VideoPlayerOptions(
          mixWithOthers: true,
          allowBackgroundPlayback: false,
        ),
      );
      _controller = controller;
      await controller.initialize();
      if (!mounted || _closing) return;
      await controller.setLooping(false);
      if (!mounted || _closing) return;
      setState(() {});
      if (_foreground) await controller.play();
    } catch (_) {
      if (!mounted || _closing) return;
      await _stopPreview();
      if (mounted && !_closing) {
        setState(() => _errorMessage = '播放失败：无法加载该媒体');
      }
    }
  }

  Future<void> _togglePlayback() async {
    final controller = _controller;
    if (controller == null || _closing || !_foreground) return;
    try {
      if (controller.value.isPlaying) {
        await controller.pause();
      } else {
        await controller.play();
      }
    } catch (_) {
      if (mounted && !_closing) {
        setState(() => _errorMessage = '播放失败：无法加载该媒体');
      }
    }
  }

  Widget _buildBody() {
    final controller = _controller;
    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _errorMessage!,
            style: const TextStyle(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_closing || controller == null || !controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) => Column(
        children: [
          Expanded(
            child: Center(
              child: widget.isAudio
                  ? const Icon(
                      Icons.graphic_eq,
                      color: Colors.white70,
                      size: 72,
                    )
                  : AspectRatio(
                      aspectRatio: value.aspectRatio > 0
                          ? value.aspectRatio
                          : 16 / 9,
                      child: VideoPlayer(controller),
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: VideoProgressIndicator(
              controller,
              allowScrubbing: true,
              colors: const VideoProgressColors(
                playedColor: Colors.redAccent,
                backgroundColor: Colors.white24,
              ),
            ),
          ),
          DesktopButtonClickRegion(child: IconButton(
            tooltip: value.isPlaying ? '暂停' : '播放',
            icon: Icon(
              value.isPlaying ? Icons.pause : Icons.play_arrow,
              color: Colors.white,
              size: 48,
            ),
            onPressed: _togglePlayback,
          )),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      unawaited(_exitPreview(didPop: didPop));
    },
    child: CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            unawaited(_exitPreview()),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            leading: DesktopButtonClickRegion(child: BackButton(onPressed: _exitPreview)),
            title: Text(widget.title ?? '视频预览'),
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
          ),
          body: SafeArea(child: _buildBody()),
        ),
      ),
    ),
  );
}
