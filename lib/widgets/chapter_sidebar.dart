import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/media_chapter.dart';
import '../models/video_item.dart';
import '../services/chapter_thumbnail_service.dart';
import 'sidebar_activity.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

class ChapterSidebar extends StatefulWidget {
  final VideoItem videoItem;
  final VideoPlayerController controller;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onClose;
  final FocusNode? playerFocusNode;

  const ChapterSidebar({
    super.key,
    required this.videoItem,
    required this.controller,
    required this.onSeek,
    required this.onClose,
    this.playerFocusNode,
  });

  @override
  State<ChapterSidebar> createState() => _ChapterSidebarState();
}

class _ChapterSidebarState extends State<ChapterSidebar> {
  int _activeIndex = 0;
  bool _loopChapter = false;
  bool _loopSeekPending = false;
  bool _visuallyActive = true;

  List<MediaChapter> get _chapters => widget.videoItem.chapters;

  @override
  void initState() {
    super.initState();
    _activeIndex = _findActiveIndex(widget.controller.value.position);
    widget.controller.addListener(_onPlaybackChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visuallyActive = SidebarActivity.of(context);
    if (_visuallyActive) {
      _activeIndex = _findActiveIndex(widget.controller.value.position);
    }
  }

  @override
  void didUpdateWidget(covariant ChapterSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onPlaybackChanged);
      widget.controller.addListener(_onPlaybackChanged);
    }
    if (oldWidget.videoItem.id != widget.videoItem.id ||
        oldWidget.videoItem.chapters != widget.videoItem.chapters) {
      _activeIndex = _findActiveIndex(widget.controller.value.position);
      _loopSeekPending = false;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onPlaybackChanged);
    super.dispose();
  }

  void _onPlaybackChanged() {
    if (!mounted || _chapters.isEmpty) return;
    final position = widget.controller.value.position;
    if (_loopChapter &&
        !_loopSeekPending &&
        _activeIndex >= 0 &&
        _activeIndex < _chapters.length) {
      final active = _chapters[_activeIndex];
      final distanceToEnd = active.endMs - position.inMilliseconds;
      if (distanceToEnd <= 90 && distanceToEnd >= -350) {
        _loopSeekPending = true;
        widget.onSeek(active.start);
        Future<void>.delayed(const Duration(milliseconds: 180), () {
          _loopSeekPending = false;
        });
        return;
      }
    }

    final nextIndex = _findActiveIndex(position);
    if (nextIndex != _activeIndex) {
      if (_visuallyActive) {
        setState(() => _activeIndex = nextIndex);
      } else {
        _activeIndex = nextIndex;
      }
    }
  }

  int _findActiveIndex(Duration position) {
    final chapter = MediaChapter.atPosition(_chapters, position);
    if (chapter == null) return _chapters.isEmpty ? -1 : 0;
    return _chapters.indexOf(chapter);
  }

  void _seekToChapter(int index) {
    if (index < 0 || index >= _chapters.length) return;
    setState(() => _activeIndex = index);
    widget.onSeek(_chapters[index].start);
    widget.playerFocusNode?.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surface,
      child: SafeArea(
        left: false,
        child: Column(
          children: <Widget>[
            _buildHeader(theme),
            Divider(
              height: 1,
              color: theme.dividerColor.withValues(alpha: 0.5),
            ),
            Expanded(
              child: _chapters.isEmpty
                  ? Center(
                      child: Text(
                        '该媒体没有章节',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final viewportHeight = MediaQuery.sizeOf(
                          context,
                        ).height;
                        final widthBasedHeight = (constraints.maxWidth * 0.27)
                            .clamp(58.0, 96.0)
                            .toDouble();
                        final rowHeight = math.min(
                          widthBasedHeight,
                          math.max(52.0, viewportHeight * 0.18),
                        );
                        return ListView.builder(
                          key: const PageStorageKey('chapter-list'),
                          padding: EdgeInsets.symmetric(
                            vertical: rowHeight * 0.08,
                          ),
                          itemExtent: rowHeight,
                          itemCount: _chapters.length,
                          itemBuilder: (context, index) => _buildChapterRow(
                            theme,
                            index,
                            rowHeight,
                            constraints.maxWidth,
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '章节',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Tooltip(
            message: _loopChapter ? '关闭当前章节循环' : '循环当前章节',
            child: DesktopButtonClickRegion(
              child: IconButton(
                visualDensity: VisualDensity.compact,
                isSelected: _loopChapter,
                selectedIcon: Icon(
                  Icons.repeat_one_rounded,
                  color: theme.colorScheme.primary,
                ),
                icon: const Icon(Icons.repeat_rounded),
                onPressed: () => setState(() => _loopChapter = !_loopChapter),
              ),
            ),
          ),
          DesktopButtonClickRegion(
            child: IconButton(
              tooltip: '关闭',
              visualDensity: VisualDensity.compact,
              onPressed: widget.onClose,
              icon: const Icon(Icons.close_rounded),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChapterRow(
    ThemeData theme,
    int index,
    double rowHeight,
    double availableWidth,
  ) {
    final chapter = _chapters[index];
    final selected = index == _activeIndex;
    final horizontalPadding = availableWidth * 0.035;
    final thumbnailHeight = rowHeight * 0.72;
    final thumbnailWidth = thumbnailHeight * 16 / 9;
    return Material(
      color: selected
          ? theme.colorScheme.primary.withValues(alpha: 0.13)
          : Colors.transparent,
      child: InkWell(
        onTap: () => _seekToChapter(index),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: rowHeight * 0.08,
          ),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: thumbnailWidth,
                height: thumbnailHeight,
                child: _buildThumbnail(theme, chapter, index),
              ),
              SizedBox(width: availableWidth * 0.035),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Text(
                      chapter.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w600,
                        color: selected
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                    SizedBox(height: rowHeight * 0.045),
                    Text(
                      _formatDuration(chapter.start),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: selected
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
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

  Widget _buildThumbnail(ThemeData theme, MediaChapter chapter, int index) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(7),
      child: FutureBuilder<String?>(
        future: ChapterThumbnailService.instance.getOrCreate(
          videoId: widget.videoItem.id,
          videoPath: widget.videoItem.path,
          chapterIndex: index,
          chapter: chapter,
        ),
        builder: (context, snapshot) {
          final path = snapshot.data;
          if (path != null && path.isNotEmpty) {
            return Image.file(
              File(path),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => _thumbnailPlaceholder(theme),
            );
          }
          return _thumbnailPlaceholder(
            theme,
            loading: snapshot.connectionState == ConnectionState.waiting,
          );
        },
      ),
    );
  }

  Widget _thumbnailPlaceholder(ThemeData theme, {bool loading = false}) {
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: loading
            ? SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: theme.colorScheme.primary,
                ),
              )
            : Icon(
                Icons.movie_outlined,
                color: theme.colorScheme.onSurfaceVariant,
              ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
