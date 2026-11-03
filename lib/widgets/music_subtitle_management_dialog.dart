import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/video_item.dart';
import '../services/library_service.dart';
import '../services/media_playback_service.dart';
import '../services/settings_service.dart';
import '../utils/app_toast.dart';
import '../widgets/ai_transcription_panel.dart';
import '../widgets/bilibili_subtitle_tracks_section.dart';
import '../widgets/music_lyric_search_dialog.dart';
import '../widgets/subtitle_management_sheet.dart';
import 'dialog_keyboard_viewport.dart';

const Color _musicSubtitleAccent = Color(0xFFFA586A);

/// Built once. Creating [ThemeData.dark] on every open competed with the first
/// frame of the dialog route.
final ThemeData _musicSubtitleDialogTheme = ThemeData.dark(useMaterial3: true)
    .copyWith(
      textTheme: ThemeData.dark().textTheme.apply(
        fontFamily: 'Inter',
        fontFamilyFallback: const ['Noto Sans SC'],
      ),
      platform: TargetPlatform.iOS,
      colorScheme: ColorScheme.fromSeed(
        seedColor: _musicSubtitleAccent,
        brightness: Brightness.dark,
      ),
      splashFactory: NoSplash.splashFactory,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.06),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );

final CupertinoThemeData _musicSubtitleCupertinoTheme = CupertinoThemeData(
  brightness: Brightness.dark,
  primaryColor: _musicSubtitleAccent,
  textTheme: CupertinoTextThemeData(
    textStyle: TextStyle(
      fontFamily: 'Inter',
      fontFamilyFallback: const ['Noto Sans SC'],
      color: Colors.white,
      fontSize: 17,
    ),
    actionTextStyle: TextStyle(
      fontFamily: 'Inter',
      fontFamilyFallback: const ['Noto Sans SC'],
      color: _musicSubtitleAccent,
      fontSize: 17,
    ),
  ),
);

/// Music's presentation of the shared subtitle manager. Discovery, selection,
/// import, extraction, translation and deletion remain owned by the same sheet.
class MusicSubtitleManagementDialog extends StatefulWidget {
  const MusicSubtitleManagementDialog({
    super.key,
    this.initialShowAi = false,
    this.artist = '',
  });

  final bool initialShowAi;

  /// 传给歌词搜索的歌手名。歌曲、播客和其它音频都保留搜索入口。
  final String artist;

  @override
  State<MusicSubtitleManagementDialog> createState() =>
      _MusicSubtitleManagementDialogState();
}

class _MusicSubtitleManagementDialogState
    extends State<MusicSubtitleManagementDialog> {
  bool _showAi = false;
  @override
  void initState() {
    super.initState();
    _showAi = widget.initialShowAi;
  }

  Future<void> _selectionWork = Future<void>.value();
  int _selectionRequest = 0;

  Future<void> _selectSubtitles(VideoItem item, List<String> paths) {
    final playback = context.read<MediaPlaybackService>();
    final library = context.read<LibraryService>();
    final autoCache = context.read<SettingsService>().autoCacheSubtitles;
    // The sheet mutates its selection list in place; capture each request now.
    final selected = List<String>.of(paths.take(2));
    final request = ++_selectionRequest;
    _selectionWork = _selectionWork
        .then((_) async {
          if (request != _selectionRequest ||
              playback.currentItem?.id != item.id) {
            return;
          }
          final loaded = await playback.loadSubtitlePathsForCurrentItem(
            itemId: item.id,
            paths: selected,
          );
          if (!loaded ||
              request != _selectionRequest ||
              playback.currentItem?.id != item.id) {
            return;
          }
          await library.updateVideoSubtitles(
            item.id,
            selected.isEmpty ? null : selected.first,
            autoCache,
            secondarySubtitlePath: selected.length > 1 ? selected[1] : null,
            isSecondaryCached: autoCache,
          );
        })
        .catchError((Object error) {
          if (mounted) AppToast.show('加载字幕失败：$error', type: AppToastType.error);
        });
    return _selectionWork;
  }

  @override
  Widget build(BuildContext context) {
    final playback = context.read<MediaPlaybackService>();
    final item = context.select<MediaPlaybackService, VideoItem?>(
      (s) => s.currentItem,
    );
    const accent = _musicSubtitleAccent;
    return Theme(
      data: _musicSubtitleDialogTheme,
      child: CupertinoTheme(
        data: _musicSubtitleCupertinoTheme,
        child: DialogKeyboardViewport(
          child: Dialog(
            key: const ValueKey('music-subtitle-dialog'),
            backgroundColor: Colors.transparent,
            insetAnimationDuration: Duration.zero,
            insetPadding: const EdgeInsets.all(16),
            child: SizedBox(
              width: 620,
              height: 640,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(28),
                // The panel is already nearly opaque. A live backdrop blur forced
                // an offscreen layer before the first frame could appear.
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xF2222226),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.12),
                    ),
                  ),
                  child: Material(
                    type: MaterialType.transparency,
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 14, 12, 12),
                          child: Row(
                            children: [
                              if (_showAi)
                                CupertinoButton(
                                  key: const ValueKey(
                                    'music-subtitle-dialog-ai-back',
                                  ),
                                  padding: const EdgeInsets.only(right: 12),
                                  minimumSize: const Size(32, 32),
                                  onPressed: () =>
                                      setState(() => _showAi = false),
                                  child: const Icon(
                                    CupertinoIcons.chevron_back,
                                    color: accent,
                                    size: 20,
                                  ),
                                ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _showAi ? '语音转录' : '字幕管理',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 22,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: -0.6,
                                      ),
                                    ),
                                    if (item != null)
                                      Text(
                                        item.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white54,
                                          fontSize: 12,
                                          height: 1.6,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              CupertinoButton(
                                key: const ValueKey(
                                  'music-subtitle-dialog-close',
                                ),
                                padding: EdgeInsets.zero,
                                minimumSize: const Size(36, 36),
                                onPressed: () => Navigator.of(context).pop(),
                                child: Container(
                                  width: 28,
                                  height: 28,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.white.withValues(alpha: 0.10),
                                  ),
                                  child: const Icon(
                                    CupertinoIcons.xmark,
                                    color: Colors.white70,
                                    size: 14,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Divider(
                          height: 1,
                          color: Colors.white.withValues(alpha: 0.07),
                        ),
                        Expanded(
                          child: item == null
                              ? const Center(child: Text('请先打开一个媒体文件'))
                              : Stack(
                                  children: [
                                    Offstage(
                                      offstage: _showAi,
                                      child: SubtitleManagementSheet(
                                        key: ValueKey(
                                          'music-subtitle-manager-${item.id}',
                                        ),
                                        videoPath: item.path,
                                        videoId: item.id,
                                        appearance: SubtitleManagementAppearance
                                            .musicIOS,
                                        showHeader: false,
                                        associatedSubtitles:
                                            item.downloadAssociatedSubtitles,
                                        localSubtitles:
                                            item.localSubtitleGroups,
                                        initialSelectedPaths:
                                            playback.subtitlePaths.isNotEmpty
                                            ? List<String>.of(
                                                playback.subtitlePaths,
                                              )
                                            : [
                                                if (item.subtitlePath
                                                    case final path?
                                                    when path.isNotEmpty)
                                                  path,
                                                if (item.secondarySubtitlePath
                                                    case final path?
                                                    when path.isNotEmpty)
                                                  path,
                                              ],
                                        bilibiliTracks:
                                            bilibiliSubtitleTracksFor(
                                              context,
                                              item,
                                            ),
                                        onSubtitleChanged: () {},
                                        onSubtitleSelected: (paths) =>
                                            _selectSubtitles(item, paths),
                                        onSubtitlePreview: (path) =>
                                            _selectSubtitles(item, [
                                              path,
                                              if (playback
                                                      .subtitlePaths
                                                      .length >
                                                  1)
                                                playback.subtitlePaths[1],
                                            ]),
                                        onClose: () =>
                                            Navigator.of(context).pop(),
                                        onOpenAi: () =>
                                            setState(() => _showAi = true),
                                        onSearchLyrics: () =>
                                            showMusicLyricSearchDialog(
                                              context,
                                              artist: widget.artist,
                                            ),
                                      ),
                                    ),
                                    if (_showAi)
                                      AiTranscriptionPanel(
                                        key: ValueKey(
                                          'music-subtitle-ai-${item.id}',
                                        ),
                                        videoPath: item.path,
                                        videoId: item.id,
                                        musicAppearance: true,
                                        sourceItem: item,
                                        onBack: () =>
                                            setState(() => _showAi = false),
                                        onCompleted: (completion) => unawaited(
                                          _selectSubtitles(item, [
                                            completion.primaryPath,
                                            if (completion.translated)
                                              completion.translationPath!
                                            else if (playback
                                                    .subtitlePaths
                                                    .length >
                                                1)
                                              playback.subtitlePaths[1],
                                          ]),
                                        ),
                                      ),
                                  ],
                                ),
                        ),
                      ],
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
}

Future<void> showMusicSubtitleManagementDialog(
  BuildContext context, {
  bool initialShowAi = false,
  String artist = '',
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭字幕管理',
    barrierColor: Colors.black.withValues(alpha: 0.38),
    // Short enough that the first painted frame is already visible, instead of
    // spending the open inside a fully transparent fade.
    transitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (context, animation, secondaryAnimation) =>
        MusicSubtitleManagementDialog(
          initialShowAi: initialShowAi,
          artist: artist,
        ),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final eased = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: eased,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1).animate(eased),
          child: child,
        ),
      );
    },
  );
}
