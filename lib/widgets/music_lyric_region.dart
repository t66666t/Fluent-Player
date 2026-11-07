import '../models/subtitle_stream.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../controllers/music_lyric_selection_controller.dart';
import '../models/music_lyric_display_mode.dart';
import '../models/music_lyric_font.dart';
import '../models/music_lyric_typography.dart';
import '../models/subtitle_style.dart';
import '../models/subtitle_model.dart';
import '../services/music_lyric_content_resolver.dart';
import 'music_lyric_selection_pane.dart';
import 'music_lyric_view.dart';
import 'subtitle_generation_footer.dart';

/// Lyric column shared by the portrait and landscape players. The pointer
/// listener stays mounted across the mode switch so the finger that opened
/// selection cannot land on Copy or Done.
class MusicLyricRegion extends StatefulWidget {
  final String mediaId;
  final List<SubtitleItem> subtitles;
  final List<SubtitleItem> secondarySubtitles;
  final bool splitSubtitleByLine;
  final MusicLyricTrackDisplayMode preference;
  final ValueChanged<MusicLyricTrackDisplayMode> onPreferenceChanged;
  final bool sourceMissing;
  final String? trackTitle;
  final bool mergeTitle;
  final ValueChanged<MusicLyricSelectionPhase>? onPhaseChanged;
  final ValueChanged<Duration>? onSeek;
  final ValueListenable<Duration>? positionListenable;
  final MusicLyricPositionController? positionController;
  final void Function(double? direction)? onScrollDirectionChanged;
  final ValueChanged<bool>? onManualScrollActivityChanged;
  final VoidCallback? onDirectLyricTap;
  final ValueChanged<bool>? onPointerHoldChanged;
  final bool stabilizeAlacDirectSeek;
  final bool isPlaying;
  final double lyricFontSizeScale;
  final double lyricSpacingScale;
  final double lyricSecondaryRatio;
  final SubtitleTextStyle lyricTextStyle;
  final bool wordByWordEnabled;
  final bool lyricBlurEnabled;
  final double anchorFraction;
  final bool showAnchorGuide;
  final ValueChanged<Offset>? onAnchorGuidePositionChanged;
  final EdgeInsets? focusInsets;
  final double horizontalPaddingFraction;
  final bool applyEdgeFade;

  const MusicLyricRegion({
    super.key,
    required this.mediaId,
    required this.subtitles,
    required this.secondarySubtitles,
    required this.splitSubtitleByLine,
    required this.preference,
    required this.onPreferenceChanged,
    this.sourceMissing = false,
    this.trackTitle,
    this.mergeTitle = false,
    this.onPhaseChanged,
    this.onSeek,
    this.positionListenable,
    this.positionController,
    this.onScrollDirectionChanged,
    this.onManualScrollActivityChanged,
    this.onDirectLyricTap,
    this.onPointerHoldChanged,
    this.stabilizeAlacDirectSeek = false,
    this.isPlaying = true,
    this.lyricFontSizeScale = 1.0,
    this.lyricSpacingScale = MusicLyricTypography.defaultSpacingScale,
    this.lyricSecondaryRatio = MusicLyricTypography.defaultSecondaryRatio,
    this.lyricTextStyle = MusicLyricFont.defaultStyle,
    this.wordByWordEnabled = true,
    this.lyricBlurEnabled = true,
    this.anchorFraction = 0.30,
    this.showAnchorGuide = false,
    this.onAnchorGuidePositionChanged,
    this.focusInsets,
    this.horizontalPaddingFraction = 0.05,
    this.applyEdgeFade = true,
  });

  @override
  State<MusicLyricRegion> createState() => MusicLyricRegionState();
}

class MusicLyricRegionState extends State<MusicLyricRegion> {
  final MusicLyricSelectionController _controller =
      MusicLyricSelectionController();
  final GlobalKey<MusicLyricSelectionPaneState> _paneKey = GlobalKey();
  MusicLyricSelectionPhase _lastPhase = MusicLyricSelectionPhase.normal;
  int? _heldPointer;
  String? _noticeShownFor;
  bool _listeningToPlayback = false;
  final _projections = <MusicLyricTrackDisplayMode, MusicLyricProjection>{};

  bool get isSelectionActive => _controller.isActive;
  bool get textMenuOpen => _controller.textMenuOpen;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onController);
  }

  @override
  void didUpdateWidget(covariant MusicLyricRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Playback publishes immutable cue lists. Controls, hover and reading
    // selection can rebuild this region frequently without changing content.
    if (oldWidget.mediaId != widget.mediaId ||
        oldWidget.subtitles != widget.subtitles ||
        oldWidget.secondarySubtitles != widget.secondarySubtitles ||
        oldWidget.splitSubtitleByLine != widget.splitSubtitleByLine) {
      final append =
          oldWidget.mediaId == widget.mediaId &&
          oldWidget.splitSubtitleByLine == widget.splitSubtitleByLine &&
          isSubtitleAppend(oldWidget.subtitles, widget.subtitles) &&
          (identical(oldWidget.secondarySubtitles, widget.secondarySubtitles) ||
              isSubtitleAppend(
                oldWidget.secondarySubtitles,
                widget.secondarySubtitles,
              ));
      if (append) {
        for (final mode in _projections.keys.toList()) {
          _projections[mode] = resolveMusicLyricProjection(
            mediaId: widget.mediaId,
            primary: widget.subtitles,
            secondary: widget.secondarySubtitles,
            splitSubtitleByLine: widget.splitSubtitleByLine,
            mode: mode,
            previous: _projections[mode],
          );
        }
      } else {
        _projections.clear();
      }
    }
    if (oldWidget.positionListenable != widget.positionListenable) {
      if (_listeningToPlayback) {
        oldWidget.positionListenable?.removeListener(_onPlaybackClock);
        widget.positionListenable?.addListener(_onPlaybackClock);
      }
    }
    _controller.noteSource(
      mediaId: widget.mediaId,
      primary: widget.subtitles,
      secondary: widget.secondarySubtitles,
      splitSubtitleByLine: widget.splitSubtitleByLine,
    );
    if (oldWidget.preference != widget.preference && _controller.isActive) {
      _controller.switchMode(_effective().effective);
    }
  }

  @override
  void dispose() {
    widget.positionListenable?.removeListener(_onPlaybackClock);
    _controller.removeListener(_onController);
    _controller.dispose();
    super.dispose();
  }

  void _onPlaybackClock() {
    final clock = widget.positionListenable;
    if (clock == null || !_controller.isActive) return;
    _controller.syncPlaybackHighlight(clock.value);
  }

  void _onController() {
    if (_listeningToPlayback != _controller.isActive) {
      _listeningToPlayback = _controller.isActive;
      if (_listeningToPlayback) {
        widget.positionListenable?.addListener(_onPlaybackClock);
      } else {
        widget.positionListenable?.removeListener(_onPlaybackClock);
      }
    }
    if (_controller.phase != _lastPhase) {
      _lastPhase = _controller.phase;
      widget.onPhaseChanged?.call(_controller.phase);
    }
    if (mounted) setState(() {});
  }

  MusicLyricProjection _projectionFor(MusicLyricTrackDisplayMode mode) {
    return _projections.putIfAbsent(
      mode,
      () => resolveMusicLyricProjection(
        mediaId: widget.mediaId,
        primary: widget.subtitles,
        secondary: widget.secondarySubtitles,
        splitSubtitleByLine: widget.splitSubtitleByLine,
        mode: mode,
      ),
    );
  }

  MusicLyricEffectiveDisplay _effective() {
    final availability = _projectionFor(
      MusicLyricTrackDisplayMode.both,
    ).availability;
    return resolveMusicLyricEffectiveDisplay(
      preference: widget.preference,
      availability: availability,
    );
  }

  bool handleBack() => _controller.handleBack();

  void handleEscape() {
    if (_controller.textMenuOpen) {
      _paneKey.currentState?.closeTextMenu();
      _controller.setTextMenuOpen(false);
      return;
    }
    _controller.finish();
  }

  void _openSelection(
    MusicLyricSelectionRequest request, {
    required bool awaitingPointer,
  }) {
    final effective = _effective();
    if (!effective.primaryEnabled &&
        !effective.secondaryEnabled &&
        _projectionFor(effective.effective).rows.isEmpty) {
      return;
    }
    _controller.begin(
      mediaId: widget.mediaId,
      primary: widget.subtitles,
      secondary: widget.secondarySubtitles,
      splitSubtitleByLine: widget.splitSubtitleByLine,
      mode: effective.effective,
      groupId: request.groupId,
      time: request.time,
      awaitingPointer: awaitingPointer,
    );
  }

  void _changeMode(MusicLyricTrackDisplayMode mode) {
    final effective = _effective();
    if (!effective.allows(mode)) return;
    widget.onPreferenceChanged(mode);
    if (_controller.isActive) _controller.switchMode(mode);
  }

  @override
  Widget build(BuildContext context) {
    final effective = _effective();
    _maybeNotice(effective);
    final selecting = _controller.isActive;
    final footer = SubtitleGenerationFooter.availableIn(context)
        ? SubtitleGenerationFooter(
            key: const ValueKey('music-lyric-generation-footer'),
            reserveSpaceWhenHidden: !selecting,
            primary: widget.subtitles,
            secondary: widget.secondarySubtitles,
            showPrimary:
                effective.effective != MusicLyricTrackDisplayMode.secondary,
            showSecondary:
                effective.effective != MusicLyricTrackDisplayMode.primary,
          )
        : null;
    final body = selecting
        ? MusicLyricSelectionPane(
            key: _paneKey,
            controller: _controller,
            display: effective,
            onModeChanged: _changeMode,
            sourceMissing: widget.sourceMissing,
            trackTitle: widget.trackTitle,
            mergeTitle: widget.mergeTitle,
            footer: footer,
            onReload: () {
              final latest = _effective();
              _controller.reload(
                primary: widget.subtitles,
                secondary: widget.secondarySubtitles,
                splitSubtitleByLine: widget.splitSubtitleByLine,
                mode: latest.effective,
              );
            },
          )
        : MusicLyricView(
            key: ValueKey(
              'music-lyric-view-${widget.mediaId}-${effective.effective.storageValue}',
            ),
            subtitles: widget.subtitles,
            secondarySubtitles: widget.secondarySubtitles,
            projection: _projectionFor(effective.effective),
            footer: footer,
            displayMode: effective.effective,
            onSeek: widget.onSeek,
            positionListenable: selecting ? null : widget.positionListenable,
            positionController: widget.positionController,
            onScrollDirectionChanged: widget.onScrollDirectionChanged,
            onManualScrollActivityChanged: widget.onManualScrollActivityChanged,
            onDirectLyricTap: widget.onDirectLyricTap,
            onPointerHoldChanged: widget.onPointerHoldChanged,
            onRequestTextSelection: (request) {
              _openSelection(request, awaitingPointer: request.awaitingPointer);
            },
            stabilizeAlacDirectSeek: widget.stabilizeAlacDirectSeek,
            isPlaying: widget.isPlaying,
            lyricFontSizeScale: widget.lyricFontSizeScale,
            lyricSpacingScale: widget.lyricSpacingScale,
            lyricSecondaryRatio: widget.lyricSecondaryRatio,
            lyricTextStyle: widget.lyricTextStyle,
            wordByWordEnabled: widget.wordByWordEnabled,
            lyricBlurEnabled: widget.lyricBlurEnabled,
            splitSubtitleByLine: widget.splitSubtitleByLine,
            anchorFraction: widget.anchorFraction,
            showAnchorGuide: widget.showAnchorGuide,
            onAnchorGuidePositionChanged: widget.onAnchorGuidePositionChanged,
            focusInsets: widget.focusInsets,
            horizontalPaddingFraction: widget.horizontalPaddingFraction,
            applyEdgeFade: widget.applyEdgeFade && !selecting,
          );
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        _heldPointer = event.pointer;
      },
      onPointerUp: (event) {
        if (event.pointer == _heldPointer) {
          _heldPointer = null;
          if (_controller.phase == MusicLyricSelectionPhase.enteringSelection) {
            _controller.pointerReleased();
          }
        }
      },
      onPointerCancel: (event) {
        if (event.pointer == _heldPointer) {
          _heldPointer = null;
          if (_controller.phase == MusicLyricSelectionPhase.enteringSelection) {
            _controller.pointerReleased();
          }
        }
      },
      child: SizedBox.expand(child: body),
    );
  }

  void _maybeNotice(MusicLyricEffectiveDisplay effective) {
    final notice = effective.notice;
    if (notice == null) return;
    final token =
        '${widget.mediaId}|${effective.preference.storageValue}|$notice';
    if (_noticeShownFor == token) return;
    _noticeShownFor = token;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(notice), duration: const Duration(seconds: 2)),
      );
    });
  }
}
