import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/ai_chat/ai_chat_panel.dart';
import '../models/subtitle_model.dart';
import '../models/video_item.dart';
import '../services/media_playback_service.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

typedef _ChatSource = ({
  VideoItem? item,
  List<SubtitleItem> primary,
  List<SubtitleItem> secondary,
  String? primaryPath,
  String? secondaryPath,
});

/// Keep the music player mounted below the fullscreen conversation. The AI
/// panel borrows the very same per-media session used by the video player.
Future<void> showMusicAiChatPage(
  BuildContext context, {
  required MediaPlaybackService playback,
  required ValueChanged<Duration> onSeek,
}) => showDialog<void>(
  context: context,
  useSafeArea: false,
  builder: (context) => ChangeNotifierProvider<MediaPlaybackService>.value(
    value: playback,
    child: AiChatFullscreenSurface(
      child: Selector<MediaPlaybackService, _ChatSource>(
        // Playback time has its own listenable. Only a source or transcript
        // change rebuilds the panel, including transcription finishing here.
        selector: (context, service) => (
          item: service.currentItem,
          primary: service.subtitles,
          secondary: service.secondarySubtitles,
          primaryPath: service.subtitlePaths.isNotEmpty
              ? service.subtitlePaths.first
              : service.currentItem?.subtitlePath,
          secondaryPath: service.subtitlePaths.length > 1
              ? service.subtitlePaths[1]
              : service.currentItem?.secondarySubtitlePath,
        ),
        builder: (context, source, _) {
          final item = source.item;
          void close() => Navigator.of(context).pop();
          if (item == null) {
            return Column(
              children: [
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: DesktopButtonClickRegion(
                    child: IconButton(
                      tooltip: '返回播放页',
                      onPressed: close,
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                  ),
                ),
                const Expanded(child: Center(child: Text('当前没有播放内容'))),
              ],
            );
          }
          return AiChatPanel(
            key: ValueKey('music-ai-chat-${item.id}'),
            videoItem: item,
            primarySubtitles: source.primary,
            secondarySubtitles: source.secondary,
            primaryPath: source.primaryPath,
            secondaryPath: source.secondaryPath,
            positionListenable: playback.positionNotifier,
            onSeek: onSeek,
            isFullscreen: true,
            fullscreenReturnLabel: '返回播放页',
            onExitFullscreen: close,
            onClose: close,
          );
        },
      ),
    ),
  ),
);
