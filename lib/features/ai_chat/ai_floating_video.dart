import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import '../../models/subtitle_display_state.dart';
import '../../models/subtitle_model.dart';
import '../../models/subtitle_position.dart';
import '../../models/video_item.dart';
import '../../services/app_haptics.dart';
import '../../services/media_playback_service.dart';
import '../../services/settings_service.dart';
import '../../services/subtitle_debug_session.dart';
import '../../services/subtitle_position_actions.dart';
import '../../services/subtitle_timeline_resolver.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/stable_video_surface.dart';
import '../../widgets/subtitle_display_layer.dart';
import '../../widgets/subtitle_overlay.dart';

/// Remembers whether the floating player was left on, and where it sat.
///
/// Kept out of [SettingsService] on purpose: this is a per-device surface
/// preference like the chat reading scale, not something a settings export
/// should carry to another screen size.
class AiFloatingVideoState extends ChangeNotifier {
  AiFloatingVideoState({Future<SharedPreferences> Function()? preferences})
    : _preferences = preferences ?? SharedPreferences.getInstance;

  static final instance = AiFloatingVideoState();

  static const String enabledKey = 'ai_chat_floating_video_enabled_v1';
  static const String anchorKey = 'ai_chat_floating_video_anchor_v1';
  static const String widthKey = 'ai_chat_floating_video_width_v1';

  final Future<SharedPreferences> Function() _preferences;
  Future<void>? _loading;
  int _revision = 0;

  bool _enabled = true;
  bool get enabled => _enabled;

  /// Top-left of the window as a fraction of the free area. `1, 1` is the
  /// bottom-right corner, which is the first-run placement.
  double anchorX = 1;
  double anchorY = 1;

  /// Logical width chosen by the last resize. Null keeps the responsive
  /// default, so a phone never inherits a desktop-sized window.
  double? width;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final revision = _revision;
    try {
      final preferences = await _preferences();
      if (revision != _revision) return;
      final enabled = preferences.getBool(enabledKey);
      final anchor = preferences.getString(anchorKey);
      final width = preferences.getDouble(widthKey);
      var changed = false;
      if (enabled is bool && enabled != _enabled) {
        _enabled = enabled;
        changed = true;
      }
      final parsed = _parseAnchor(anchor);
      if (parsed != null) {
        anchorX = parsed.dx;
        anchorY = parsed.dy;
        changed = true;
      }
      if (width is double && width.isFinite && width > 0) {
        this.width = width;
        changed = true;
      }
      if (changed) notifyListeners();
    } catch (_) {
      // A missing preference store must not stop the chat from opening.
    }
  }

  static Offset? _parseAnchor(Object? raw) {
    if (raw is! String) return null;
    final parts = raw.split(',');
    if (parts.length != 2) return null;
    final x = double.tryParse(parts[0]);
    final y = double.tryParse(parts[1]);
    if (x == null || y == null || !x.isFinite || !y.isFinite) return null;
    return Offset(x.clamp(0.0, 1.0), y.clamp(0.0, 1.0));
  }

  Future<void> setEnabled(bool value) async {
    if (value == _enabled) return;
    _enabled = value;
    ++_revision;
    notifyListeners();
    await _write((preferences) => preferences.setBool(enabledKey, value));
  }

  /// Persists only after a gesture settles; dragging must not hit disk.
  ///
  /// [width] stays null for a pure move: a drag must not pin the responsive
  /// default, otherwise a phone-sized card would follow the user to a desktop.
  Future<void> rememberLayout({
    required Offset anchor,
    double? width,
  }) {
    anchorX = anchor.dx.clamp(0.0, 1.0);
    anchorY = anchor.dy.clamp(0.0, 1.0);
    if (width != null) this.width = width;
    ++_revision;
    return _write((preferences) async {
      final anchorSaved = await preferences.setString(
        anchorKey,
        '${anchorX.toStringAsFixed(4)},${anchorY.toStringAsFixed(4)}',
      );
      if (width == null) return anchorSaved;
      final widthSaved = await preferences.setDouble(widthKey, width);
      return anchorSaved && widthSaved;
    });
  }

  Future<void> _write(Future<bool> Function(SharedPreferences) action) async {
    try {
      await action(await _preferences());
    } catch (_) {
      // Losing a layout preference is harmless; keep the session usable.
    }
  }
}

/// Response dimensions for the floating player.
///
/// `PlayerControlMetrics` floors its scale at 0.72 for a full player window,
/// which still overflows a 176 px card. Everything here derives from the card
/// width so the chrome stays proportional at every size.
@immutable
class MiniVideoMetrics {
  const MiniVideoMetrics({
    required this.scale,
    required this.iconSize,
    required this.primaryIconSize,
    required this.buttonExtent,
    required this.timeFontSize,
    required this.progressTrackHeight,
    required this.progressHitHeight,
    required this.progressRowHeight,
    required this.stripHeight,
    required this.resizeExtent,
    required this.cornerRadius,
    required this.gap,
  });

  factory MiniVideoMetrics.fromWidth(double width) {
    final safe = width.isFinite && width > 0 ? width : 260.0;
    final scale = (safe / 320).clamp(0.55, 1.15).toDouble();
    double scaled(double value, double minimum, double maximum) =>
        (value * scale).clamp(minimum, maximum).toDouble();
    return MiniVideoMetrics(
      scale: scale,
      iconSize: scaled(17, 12, 20),
      primaryIconSize: scaled(20, 15, 24),
      buttonExtent: scaled(28, 20, 34),
      timeFontSize: scaled(10.5, 8.5, 12.5),
      progressTrackHeight: scaled(3, 2, 4),
      progressHitHeight: scaled(16, 12, 20),
      progressRowHeight: scaled(15, 12, 19),
      stripHeight: scaled(38, 30, 52),
      resizeExtent: scaled(26, 20, 32),
      cornerRadius: scaled(10, 7, 14),
      gap: scaled(4, 2, 7),
    );
  }

  final double scale;
  final double iconSize;
  final double primaryIconSize;
  final double buttonExtent;
  final double timeFontSize;
  final double progressTrackHeight;
  final double progressHitHeight;
  final double progressRowHeight;
  final double stripHeight;
  final double resizeExtent;
  final double cornerRadius;
  final double gap;
}

/// Smallest window worth showing. Below the availability floor the card is
/// hidden instead of shrinking into an unusable strip of pixels.
const double kFloatingVideoMinWidth = 176;
const double kFloatingVideoMaxWidth = 400;
const double kFloatingVideoMargin = 12;
const double kFloatingVideoMinAvailableWidth = 190;
const double kFloatingVideoMinAvailableHeight = 140;

/// First-run width: a third of a phone, half a desktop, never a black slab.
double defaultFloatingVideoWidth(Size available) {
  if (!available.width.isFinite || !available.height.isFinite) {
    return kFloatingVideoMinWidth;
  }
  final byWidth = available.width * 0.46;
  final byHeight = available.height * 0.42 * (16 / 9);
  return math.min(kFloatingVideoMaxWidth, math.min(byWidth, byHeight));
}

double maxFloatingVideoWidth(Size available) {
  final byHeight = available.height * 0.72 * (16 / 9);
  return math.max(
    kFloatingVideoMinWidth,
    math.min(available.width - kFloatingVideoMargin * 2, byHeight),
  );
}

/// Resolves the card rect inside [available], keeping it fully on screen.
///
/// [anchor] is the top-left expressed as a fraction of the free area, so a
/// rotation re-derives a sane corner instead of restoring off-screen pixels.
Rect floatingVideoRect({
  required Size available,
  required double width,
  required double aspect,
  required double stripHeight,
  required Offset anchor,
}) {
  final minWidth = math.min(kFloatingVideoMinWidth, available.width);
  final maxWidth = math.max(minWidth, maxFloatingVideoWidth(available));
  final resolvedWidth = width.clamp(minWidth, maxWidth).toDouble();
  final safeAspect = aspect.isFinite && aspect > 0.1 ? aspect : 16 / 9;
  final videoHeight = resolvedWidth / safeAspect;
  final height = math.min(videoHeight + stripHeight, available.height);
  final freeWidth = math.max(0.0, available.width - resolvedWidth);
  final freeHeight = math.max(0.0, available.height - height);
  return Rect.fromLTWH(
    (anchor.dx.clamp(0.0, 1.0) * freeWidth).clamp(0.0, freeWidth),
    (anchor.dy.clamp(0.0, 1.0) * freeHeight).clamp(0.0, freeHeight),
    resolvedWidth,
    height,
  );
}

/// Clock text for the mini strip: `m:ss`, or `h:mm:ss` past an hour.
String formatMiniDuration(Duration value) {
  final total = value.inSeconds < 0 ? 0 : value.inSeconds;
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  final two = seconds.toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:$two';
  }
  return '$minutes:$two';
}

/// The one command in the chat toolbar that keeps a filled surface.
///
/// Every other header control is a quiet transparent icon; this one carries an
/// accent plate when the floating player is on, so it reads as a mode rather
/// than another action, and doubles as the on/off indicator.
class AiFloatingVideoButton extends StatelessWidget {
  const AiFloatingVideoButton({
    super.key,
    required this.enabled,
    required this.onPressed,
  });

  final bool enabled;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: '悬浮播放',
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: enabled ? 1 : 0),
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        builder: (context, t, child) => SizedBox.square(
          dimension: 32,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Color.lerp(
                AppTokens.accent.withValues(alpha: 0),
                AppTokens.accentSoft,
                t,
              ),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: Color.lerp(
                  colors.outlineVariant,
                  AppTokens.accent,
                  t,
                )!,
              ),
            ),
            child: child,
          ),
        ),
        child: IconButton(
          onPressed: onPressed,
          tooltip: null,
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          iconSize: 17,
          style: IconButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            minimumSize: const Size.square(32),
            maximumSize: const Size.square(32),
            fixedSize: const Size.square(32),
            padding: EdgeInsets.zero,
            foregroundColor: enabled ? AppTokens.accent : AppTokens.text2,
          ),
          icon: const Icon(Icons.picture_in_picture_alt_rounded),
        ),
      ),
    );
  }
}

/// Whether the floating player has something worth showing.
///
/// Audio-only items report a mountable controller too, but floating a black
/// card with a music icon over the conversation is worse than hiding both the
/// card and its header toggle.
bool canFloatPlayback(MediaPlaybackService service) {
  final item = service.currentItem;
  if (item == null || item.type == MediaType.audio) return false;
  if (!service.hasMountableController) return false;
  final controller = service.controller;
  if (controller == null) return false;
  try {
    return controller.value.isInitialized && !controller.value.hasError;
  } catch (_) {
    return false;
  }
}

/// Hosts the floating player above the message list, never over the composer.
class AiFloatingVideoLayer extends StatefulWidget {
  const AiFloatingVideoLayer({super.key, required this.state});

  final AiFloatingVideoState state;

  @override
  State<AiFloatingVideoLayer> createState() => AiFloatingVideoLayerState();
}

class AiFloatingVideoLayerState extends State<AiFloatingVideoLayer> {
  static const List<double> _speedLadder = <double>[
    0.5,
    0.75,
    1,
    1.25,
    1.5,
    1.75,
    2,
  ];

  final GlobalKey _speedAnchorKey = GlobalKey();

  MediaPlaybackService? _playback;
  bool _claimHeld = false;
  bool _mountVideo = false;
  bool _disposed = false;

  /// Set while the route is closing. Releasing notifies the service, which
  /// would otherwise make [_syncSurface] claim the output straight back.
  bool _exitRequested = false;

  /// Live top-left in the layer's own coordinates. Once a gesture or a
  /// clamp has produced one, it wins over the persisted anchor so that
  /// keyboard resizes and rotation keep the card where the user put it.
  Offset? _position;

  /// The rect used for the current frame; gesture math reads it instead of
  /// recomputing, so a drag and its paint can never disagree.
  Rect? _cardRect;
  Size _available = Size.zero;

  double? _resizeWidth;

  /// Set only once the user drags the corner, so the responsive default keeps
  /// adapting until then.
  double? _manualWidth;
  bool _dragging = false;
  bool _resizing = false;

  Offset? _doubleTapPosition;

  /// Caption state mirrors the full player: the same display state, the same
  /// style and the same alignment, laid out inside the card's own video box so
  /// the glyphs keep the fullscreen proportions instead of a fixed size.
  final ValueNotifier<SubtitleDisplayState> _subtitleDisplay =
      ValueNotifier<SubtitleDisplayState>(SubtitleDisplayState.empty);
  int? _currentSubtitleIndex;
  String? _currentSecondaryText;
  List<SubtitleItem> _secondaryCues = const <SubtitleItem>[];
  SubtitleTimelineResolver? _secondaryResolver;
  double? _scrubFraction;
  bool _boosting = false;

  @override
  void initState() {
    super.initState();
    unawaited(widget.state.load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final resolved = _resolvePlaybackService(context);
    if (!identical(resolved, _playback)) {
      _playback?.removeListener(_onPlaybackChanged);
      _playback?.positionNotifier.removeListener(_onPositionChanged);
      _playback = resolved..addListener(_onPlaybackChanged);
      _playback!.positionNotifier.addListener(_onPositionChanged);
    }
    _syncSurface();
    _refreshSubtitle();
  }

  @override
  void dispose() {
    _disposed = true;
    _playback?.removeListener(_onPlaybackChanged);
    _playback?.positionNotifier.removeListener(_onPositionChanged);
    _subtitleDisplay.dispose();
    if (_boosting) {
      _boosting = false;
      unawaited(_playback?.endTemporaryPlaybackSpeed());
    }
    _detachSurface();
    super.dispose();
  }

  MediaPlaybackService _resolvePlaybackService(BuildContext context) {
    try {
      return Provider.of<MediaPlaybackService>(context, listen: false);
    } catch (_) {
      return MediaPlaybackService();
    }
  }

  SettingsService _resolveSettings(BuildContext context) {
    try {
      return Provider.of<SettingsService>(context, listen: false);
    } catch (_) {
      return SettingsService();
    }
  }

  /// Lets the playback page below take the texture back before the closing
  /// route finishes animating, so the player is never briefly black.
  ///
  /// Drops this view first, then releases, mirroring the music cover handoff:
  /// the page only remounts once ownership is back.
  void releaseForExit() {
    _exitRequested = true;
    if (_mountVideo) {
      _mountVideo = false;
      if (mounted) setState(() {});
    }
    _detachSurface(immediate: true);
  }

  void _onPlaybackChanged() {
    if (_disposed) return;
    _syncSurface();
    _refreshSubtitle();
  }

  /// Follows the media clock and publishes the active cue, the same way the
  /// playback page does: the caption changes only when the cue does.
  void _onPositionChanged() {
    if (_disposed) return;
    _refreshSubtitle();
  }

  void _refreshSubtitle() {
    final service = _playback;
    if (service == null) {
      if (_currentSubtitleIndex != null) {
        _currentSubtitleIndex = null;
        _currentSecondaryText = null;
        _subtitleDisplay.value = SubtitleDisplayState.empty;
      }
      return;
    }
    final position = service.positionNotifier.value;
    final cue = service.subtitleAtPosition(position);
    final secondary = _secondaryTextAt(service, position);
    if (cue?.index == _currentSubtitleIndex &&
        secondary == _currentSecondaryText) {
      return;
    }
    _currentSubtitleIndex = cue?.index;
    _currentSecondaryText = secondary;
    _subtitleDisplay.value = SubtitleDisplayState(
      entries: cue == null
          ? const <SubtitleOverlayEntry>[]
          : <SubtitleOverlayEntry>[
              SubtitleOverlayEntry(
                index: cue.index,
                text: cue.text,
                secondaryText: secondary,
              ),
            ],
    );
  }

  String? _secondaryTextAt(MediaPlaybackService service, Duration position) {
    final cues = service.secondarySubtitles;
    if (cues.isEmpty) return null;
    if (!identical(_secondaryCues, cues)) {
      _secondaryCues = cues;
      _secondaryResolver = SubtitleTimelineResolver(cues);
    }
    final text = _secondaryResolver?.subtitleAt(position)?.text.trim();
    return (text == null || text.isEmpty) ? null : text;
  }

  bool _hasPicture(MediaPlaybackService? service) =>
      service != null && canFloatPlayback(service);

  /// Claims the shared output only while a real picture exists. Claiming and
  /// mounting are split across frames so the page below detaches first.
  void _syncSurface() {
    if (_exitRequested) return;
    final service = _playback;
    final wanted = _hasPicture(service);
    if (wanted) {
      if (_claimHeld) return;
      _claimHeld = true;
      _runOutsideBuild(() {
        if (_disposed || !_claimHeld) return;
        service?.claimVideoSurface(this);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_disposed || !_claimHeld || !mounted) return;
          if (!identical(service, _playback) || !_hasPicture(service)) {
            // The session changed between claim and mount; give it back
            // instead of holding ownership without a view.
            _detachSurface();
            return;
          }
          setState(() => _mountVideo = true);
        });
      });
      return;
    }
    if (_mountVideo) {
      _mountVideo = false;
      _runOutsideBuild(() {
        if (mounted) setState(() {});
      });
    }
    _detachSurface();
  }

  void _detachSurface({bool immediate = false}) {
    if (!_claimHeld) return;
    _claimHeld = false;
    final service = _playback;
    // A stale owner is ignored inside the service, so a stolen claim is safe.
    if (immediate) {
      service?.releaseVideoSurface(this);
      return;
    }
    _runOutsideBuild(() => service?.releaseVideoSurface(this));
  }

  /// Service notifications arrive during build; mutating state there throws.
  void _runOutsideBuild(void Function() action) {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => action());
      return;
    }
    action();
  }

  void _togglePlay() {
    final service = _playback;
    if (service == null) return;
    unawaited(AppHaptics.lightTap(_resolveSettings(context)));
    if (service.desiredPlaying) {
      unawaited(service.pause());
    } else {
      unawaited(service.resume());
    }
  }

  void _seekBy(Duration delta) {
    final service = _playback;
    if (service == null) return;
    unawaited(AppHaptics.lightTap(_resolveSettings(context)));
    final duration = service.duration;
    var target = service.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;
    unawaited(service.seekTo(target, source: 'floating-video'));
  }

  void _startBoost() {
    final service = _playback;
    if (service == null || _boosting) return;
    _boosting = true;
    unawaited(
      service.beginTemporaryPlaybackSpeed(_resolveSettings(context).longPressSpeed),
    );
    setState(() {});
  }

  void _endBoost() {
    if (!_boosting) return;
    _boosting = false;
    unawaited(_playback?.endTemporaryPlaybackSpeed());
    if (mounted) setState(() {});
  }

  Future<void> _pickSpeed() async {
    final service = _playback;
    if (service == null) return;
    final box = _speedAnchorKey.currentContext?.findRenderObject();
    final overlayBox = Overlay.maybeOf(
      context,
    )?.context.findRenderObject();
    if (box is! RenderBox || overlayBox is! RenderBox) return;
    final origin = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    final selected = await showMenu<double>(
      context: context,
      position: RelativeRect.fromLTRB(
        origin.dx,
        origin.dy,
        overlayBox.size.width - origin.dx - box.size.width,
        overlayBox.size.height - origin.dy - box.size.height,
      ),
      items: <PopupMenuEntry<double>>[
        for (final speed in _speedLadder)
          PopupMenuItem<double>(
            value: speed,
            height: 36,
            child: Text(
              '${_compactSpeed(speed)}×',
              style: const TextStyle(fontSize: 13),
            ),
          ),
      ],
    );
    if (selected == null || !mounted) return;
    unawaited(AppHaptics.lightTap(_resolveSettings(context)));
    unawaited(service.setPlaybackSpeed(selected));
  }

  void _toggleSubtitles() {
    final settings = _resolveSettings(context);
    unawaited(AppHaptics.lightTap(settings));
    unawaited(settings.saveShowSubtitles(!settings.showSubtitles));
    setState(() {});
  }

  static String _compactSpeed(double speed) {
    final rounded = speed.roundToDouble();
    return speed == rounded ? speed.toStringAsFixed(1) : speed.toString();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _available = constraints.biggest;
        final service = _playback;
        // The host only mounts this while a picture exists; a session that
        // loses it mid-flight falls back to the poster instead of a dead card.
        if (service == null ||
            _available.width < kFloatingVideoMinAvailableWidth ||
            _available.height < kFloatingVideoMinAvailableHeight) {
          return const SizedBox.shrink();
        }
        final rect = _resolveRect(_available);
        return Stack(
          children: <Widget>[
            Positioned.fromRect(
              rect: rect,
              child: _buildWindow(context, service, rect),
            ),
          ],
        );
      },
    );
  }

  Rect _resolveRect(Size available) {
    final controller = _playback?.controller;
    var aspect = 16 / 9;
    try {
      final size = controller?.value.size;
      if (size != null && size.width > 0 && size.height > 0) {
        aspect = size.width / size.height;
      }
    } catch (_) {}
    final width =
        _resizeWidth ??
        widget.state.width ??
        defaultFloatingVideoWidth(available);
    final metrics = MiniVideoMetrics.fromWidth(width);
    final base = floatingVideoRect(
      available: available,
      width: width,
      aspect: aspect,
      stripHeight: metrics.stripHeight,
      anchor: Offset(widget.state.anchorX, widget.state.anchorY),
    );
    final live = _position;
    if (live == null) return base;
    // A keyboard, a rotation or a resize changes the free area under a card
    // the user placed by hand. Keep that position and pull it back on screen
    // rather than snapping back to the anchor.
    final freeWidth = math.max(0.0, available.width - base.width);
    final freeHeight = math.max(0.0, available.height - base.height);
    final left = live.dx.clamp(0.0, freeWidth);
    final top = live.dy.clamp(0.0, freeHeight);
    if (left != live.dx || top != live.dy) {
      _position = Offset(left, top);
    }
    return Rect.fromLTWH(left, top, base.width, base.height);
  }

  Widget _buildWindow(
    BuildContext context,
    MediaPlaybackService service,
    Rect rect,
  ) {
    final metrics = MiniVideoMetrics.fromWidth(rect.width);
    final videoHeight = math.max(0.0, rect.height - metrics.stripHeight);
    final controller = _mountVideo && _hasPicture(service)
        ? service.controller
        : null;
    final activeAspect = videoHeight > 0 && rect.width > 0
        ? rect.width / videoHeight
        : 16 / 9;

    _cardRect = rect;

    // Lifting the shadow while dragging is the cheapest way to say "this is
    // in your hand"; it costs no layout and reads on both touch and mouse.
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: _dragging || _resizing ? 24 : 14),
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      builder: (context, elevation, child) => Material(
        key: const ValueKey<String>('ai-floating-video'),
        elevation: elevation,
        color: AppTokens.bgRaised,
        shadowColor: Colors.black.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(metrics.cornerRadius),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
      child: Column(
        children: <Widget>[
          SizedBox(
            height: videoHeight,
            width: rect.width,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                ColoredBox(
                  color: Colors.black,
                  child: controller == null
                      ? const Center(
                          child: Icon(
                            Icons.movie_outlined,
                            color: AppTokens.text4,
                            size: 20,
                          ),
                        )
                      : StableVideoSurface(
                          referenceSize: Size(640, 640 / activeAspect),
                          child: VideoPlayer(
                            controller,
                            key: ValueKey<Object>(controller),
                          ),
                        ),
                ),
                if (_resolveSettings(context).showSubtitles)
                  _buildSubtitles(service, rect.width, videoHeight),
                Positioned.fill(child: _buildVideoGestures(rect.width)),
              ],
            ),
          ),
          _buildStrip(service, metrics, rect),
        ],
      ),
    );
  }

  /// Same zone model as the full player: the outer 20% on either side jumps,
  /// the middle toggles. A long press borrows the temporary rate.
  ///
  /// Wrapped in a raw [Listener] so two fingers can pinch the card bigger:
  /// a corner handle alone is a small target on a phone, and pinch is what
  /// every system PiP uses on touch.
  ///
  /// A single finger drag moves the card instead of seeking. A pan only wins
  /// the arena once the finger travels past the slop, while a long press wins
  /// by holding still, so holding to boost never turns into a drag.
  Widget _buildVideoGestures(double width) => MouseRegion(
    cursor: _dragging ? SystemMouseCursors.grabbing : SystemMouseCursors.grab,
    child: Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: (event) => _onPointerUp(event.pointer),
      onPointerCancel: (event) => _onPointerUp(event.pointer),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTapDown: (details) =>
            _doubleTapPosition = details.localPosition,
        onDoubleTap: () {
          if (_pinching) return;
          _handleDoubleTap(width);
        },
        onLongPressStart: (_) {
          if (_pinching) return;
          _startBoost();
        },
        onLongPressEnd: (_) => _endBoost(),
        onLongPressCancel: _endBoost,
        onPanStart: (_) {
          if (_pinching) return;
          _beginDrag();
        },
        onPanUpdate: (details) {
          if (_pinching) return;
          _updateDrag(details);
        },
        onPanEnd: _endDrag,
        onPanCancel: () => _endDrag(DragEndDetails()),
      ),
    ),
  );

  void _handleDoubleTap(double width) {
    final service = _playback;
    if (service == null || width <= 0) return;
    final position = _doubleTapPosition;
    final dx = position?.dx ?? width / 2;
    if (dx < width * 0.2) {
      _seekBy(Duration(seconds: -_seekStepSeconds()));
      return;
    }
    if (dx > width * 0.8) {
      _seekBy(Duration(seconds: _seekStepSeconds()));
      return;
    }
    _togglePlay();
  }

  int _seekStepSeconds() {
    final step = _resolveSettings(context).doubleTapSeekSeconds;
    return step > 0 ? step : 5;
  }

  /// The caption layer of the full player, reused verbatim.
  ///
  /// It is laid out inside the card's own video box, so the reference height
  /// is the card's video height and the glyphs keep the same ratio to the
  /// picture as they do on the playback page. The alignment comes from the
  /// user's saved subtitle position, so a caption dragged to the top of the
  /// full player also lands at the top here.
  Widget _buildSubtitles(
    MediaPlaybackService service,
    double width,
    double videoHeight,
  ) {
    if (videoHeight <= 0) return const SizedBox.shrink();
    final settings = _resolveSettings(context);
    final isAudio = service.currentItem?.type == MediaType.audio;
    final target = SubtitlePositionTarget.resolve(
      ghost: false,
      audio: isAudio,
      presetId: SubtitleDebugSession.instance.preset?.id,
    );
    final style = isAudio
        ? settings.audioSubtitleStyleLandscape
        : settings.subtitleStyleLandscape;
    final videoSize = Size(width, videoHeight);
    return Positioned.fill(
      child: IgnorePointer(
        child: SubtitleDisplayLayer(
          notifier: _subtitleDisplay,
          alignment: displayedSubtitleAlignment(
            settings: settings,
            target: target,
          ),
          style: style,
          // The card is the page here: a screen-calibrated reading size must
          // shrink with the card, not stay sized for the whole window.
          fullPageSize: videoSize,
          presetPositionOverride: targetHasPresetOverride(settings, target),
        ),
      ),
    );
  }

  // ----- drag -------------------------------------------------------------

  /// Free area for the card's top-left corner at its current size.
  Offset _freeExtent(Rect rect) => Offset(
    math.max(0.0, _available.width - rect.width),
    math.max(0.0, _available.height - rect.height),
  );

  void _beginDrag() {
    final rect = _cardRect;
    if (rect == null) return;
    setState(() {
      _dragging = true;
      _position = rect.topLeft;
    });
  }

  void _updateDrag(DragUpdateDetails details) {
    final rect = _cardRect;
    final current = _position;
    if (rect == null || current == null) return;
    final free = _freeExtent(rect);
    setState(() {
      _position = Offset(
        (current.dx + details.delta.dx).clamp(0.0, free.dx),
        (current.dy + details.delta.dy).clamp(0.0, free.dy),
      );
    });
  }

  /// The card stops where the finger stopped. No momentum, no magnetism: the
  /// window goes exactly where it was put.
  void _endDrag(DragEndDetails details) {
    setState(() => _dragging = false);
    final rect = _cardRect;
    final current = _position;
    if (rect == null || current == null) return;
    _rememberPosition(current, _freeExtent(rect), rect);
  }

  void _rememberPosition(Offset position, Offset free, Rect rect) {
    final anchor = Offset(
      free.dx <= 0 ? 1 : (position.dx / free.dx).clamp(0.0, 1.0),
      free.dy <= 0 ? 1 : (position.dy / free.dy).clamp(0.0, 1.0),
    );
    // A drag must not freeze the responsive default width; only an explicit
    // resize pins it.
    unawaited(
      widget.state.rememberLayout(anchor: anchor, width: _manualWidth),
    );
  }

  // ----- resize -----------------------------------------------------------

  void _beginResize(double width) {
    setState(() {
      _resizing = true;
      _manualWidth ??= width;
      _resizeWidth = _manualWidth;
    });
  }

  void _updateResize(DragUpdateDetails details) {
    final current = _resizeWidth;
    if (current == null) return;
    _applyWidth(current + details.delta.dx);
  }

  void _applyWidth(double target) {
    final maxWidth = maxFloatingVideoWidth(_available);
    setState(() {
      _resizeWidth = target
          .clamp(math.min(kFloatingVideoMinWidth, _available.width), maxWidth)
          .toDouble();
      _manualWidth = _resizeWidth;
    });
  }

  // ----- pinch -------------------------------------------------------------

  final Map<int, Offset> _pointers = <int, Offset>{};
  bool _pinching = false;
  bool _resizeHover = false;
  double _pinchStartDistance = 0;
  double _pinchStartWidth = 0;

  void _onPointerDown(PointerDownEvent event) {
    if (_exitRequested) return;
    _pointers[event.pointer] = event.position;
    if (_pointers.length == 2) _beginPinch();
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.position;
    if (!_pinching || _pointers.length < 2 || _pinchStartDistance <= 0) return;
    final points = _pointers.values.toList(growable: false);
    final distance = (points[0] - points[1]).distance;
    _applyWidth(_pinchStartWidth * distance / _pinchStartDistance);
  }

  void _onPointerUp(int pointer) {
    _pointers.remove(pointer);
    if (_pinching && _pointers.length < 2) _endPinch();
  }

  void _beginPinch() {
    final points = _pointers.values.toList(growable: false);
    final width = _cardRect?.width ?? 0;
    _pinchStartDistance = (points[0] - points[1]).distance;
    _pinchStartWidth = width;
    if (_pinchStartDistance < 24 || width <= 0) return;
    setState(() {
      _pinching = true;
      _resizing = true;
      _manualWidth = width;
      _resizeWidth = width;
    });
  }

  void _endPinch() {
    setState(() {
      _pinching = false;
      _resizing = false;
    });
    _endResize();
  }

  void _endResize() {
    final width = _manualWidth;
    if (width == null) return;
    final rect = _cardRect;
    final position = _position ?? rect?.topLeft;
    if (position != null && rect != null) {
      _rememberPosition(position, _freeExtent(rect), rect);
    } else {
      unawaited(
        widget.state.rememberLayout(
          anchor: Offset(widget.state.anchorX, widget.state.anchorY),
          width: width,
        ),
      );
    }
    setState(() => _resizing = false);
  }

  // ----- control strip ----------------------------------------------------

  Widget _buildStrip(
    MediaPlaybackService service,
    MiniVideoMetrics metrics,
    Rect rect,
  ) {
    return Container(
      height: metrics.stripHeight,
      decoration: const BoxDecoration(
        color: AppTokens.bgRaised,
        border: Border(top: BorderSide(color: AppTokens.lineSubtle)),
      ),
      child: Column(
        children: <Widget>[
          _buildProgressRow(service, metrics),
          Expanded(child: _buildButtonRow(service, metrics, rect)),
        ],
      ),
    );
  }

  Widget _buildProgressRow(
    MediaPlaybackService service,
    MiniVideoMetrics metrics,
  ) {
    final labelWidth = math.max(26.0, metrics.timeFontSize * 3.4);
    return SizedBox(
      height: metrics.progressRowHeight,
      child: Row(
        children: <Widget>[
          SizedBox(
            width: labelWidth,
            child: ValueListenableBuilder<Duration>(
              valueListenable: service.coarsePositionNotifier,
              builder: (context, position, _) => _timeLabel(
                formatMiniDuration(_previewPosition(service, position)),
                metrics,
                Alignment.centerRight,
              ),
            ),
          ),
          Expanded(child: _buildProgressBar(service, metrics)),
          SizedBox(
            width: labelWidth,
            child: _timeLabel(
              formatMiniDuration(service.duration),
              metrics,
              Alignment.centerLeft,
            ),
          ),
        ],
      ),
    );
  }

  Duration _previewPosition(MediaPlaybackService service, Duration fallback) {
    final fraction = _scrubFraction;
    if (fraction != null && service.duration > Duration.zero) {
      return service.duration * fraction;
    }
    return fallback;
  }

  Widget _timeLabel(
    String text,
    MiniVideoMetrics metrics,
    Alignment alignment,
  ) => Align(
    alignment: alignment,
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: metrics.gap),
      child: Text(
        text,
        maxLines: 1,
        style: TextStyle(
          color: AppTokens.text2,
          fontSize: metrics.timeFontSize,
          height: 1,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        ),
      ),
    ),
  );

  Widget _buildProgressBar(
    MediaPlaybackService service,
    MiniVideoMetrics metrics,
  ) {
    final duration = service.duration;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        double fractionOf(Duration value) {
          if (duration <= Duration.zero) return 0;
          return (value.inMilliseconds / duration.inMilliseconds).clamp(
            0.0,
            1.0,
          );
        }

        void seekToLocal(Offset local) {
          if (width <= 0 || duration <= Duration.zero) return;
          setState(() => _scrubFraction = (local.dx / width).clamp(0.0, 1.0));
        }

        void commit() {
          final fraction = _scrubFraction;
          setState(() => _scrubFraction = null);
          if (fraction != null && duration > Duration.zero) {
            unawaited(
              service.seekTo(
                duration * fraction,
                source: 'floating-video-scrub',
              ),
            );
          }
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) => seekToLocal(details.localPosition),
          onTapUp: (_) => commit(),
          onTapCancel: commit,
          onHorizontalDragStart: (details) =>
              seekToLocal(details.localPosition),
          onHorizontalDragUpdate: (details) =>
              seekToLocal(details.localPosition),
          onHorizontalDragEnd: (_) => commit(),
          onHorizontalDragCancel: commit,
          child: ValueListenableBuilder<Duration>(
            valueListenable: service.positionNotifier,
            builder: (context, position, _) {
              final played = _scrubFraction ?? fractionOf(position);
              final buffered = math.max(
                fractionOf(service.bufferedPosition),
                played,
              );
              return CustomPaint(
                size: Size(width, metrics.progressHitHeight),
                painter: _MiniProgressPainter(
                  played: played,
                  buffered: buffered,
                  track: metrics.progressTrackHeight,
                  activeColor: AppTokens.accent,
                  bufferedColor: AppTokens.text4,
                  trackColor: Colors.white.withValues(alpha: .16),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildButtonRow(
    MediaPlaybackService service,
    MiniVideoMetrics metrics,
    Rect rect,
  ) {
    final settings = _resolveSettings(context);
    final subtitlesOn = settings.showSubtitles;
    final extent = metrics.buttonExtent;
    final primaryExtent = extent + metrics.gap;
    final speedWidth = math.max(extent, metrics.timeFontSize * 3);
    final handleWidth = math.max(metrics.resizeExtent, 28.0);
    final preferredGap = (extent * .38).clamp(5.0, 12.0).toDouble();
    final inset = math.min(10.0, extent * .3);

    return LayoutBuilder(
      builder: (context, constraints) {
        // Space between the groups is not the design; the space *inside* each
        // group is. Compute the pitch from what is left so a narrow card
        // closes the gaps instead of overflowing.
        final available = math.max(
          0.0,
          constraints.maxWidth - handleWidth - inset,
        );
        final fixed = extent * 4 + primaryExtent + speedWidth;
        final gap = fixed >= available
            ? 0.0
            : math.min(preferredGap, (available - fixed) / 4);
        final transportWidth = extent * 2 + primaryExtent + gap * 2;
        final togglesWidth = speedWidth + extent * 2 + gap * 2;
        // Centre the transport on the card, and only slide it left when the
        // toggles would otherwise sit on top of it. Never right of centre.
        final centred = (available - transportWidth) / 2;
        final furthestLeft = math.max(
          0.0,
          available - togglesWidth - gap - transportWidth,
        );
        final transportLeft = centred.clamp(0.0, furthestLeft);

        Widget transport() => Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _iconButton(
              icon: Icons.replay_10_rounded,
              tooltip: '快退 10 秒',
              metrics: metrics,
              onPressed: () => _seekBy(const Duration(seconds: -10)),
            ),
            SizedBox(width: gap),
            _iconButton(
              icon: service.desiredPlaying
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
              tooltip: service.desiredPlaying ? '暂停' : '播放',
              metrics: metrics,
              primary: true,
              onPressed: _togglePlay,
            ),
            SizedBox(width: gap),
            _iconButton(
              icon: Icons.forward_10_rounded,
              tooltip: '快进 10 秒',
              metrics: metrics,
              onPressed: () => _seekBy(const Duration(seconds: 10)),
            ),
          ],
        );

        Widget toggles() => Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            KeyedSubtree(
              key: _speedAnchorKey,
              child: _speedButton(service, metrics, speedWidth),
            ),
            SizedBox(width: gap),
            _iconButton(
              icon: subtitlesOn
                  ? Icons.subtitles
                  : Icons.subtitles_off,
              tooltip: subtitlesOn ? '关闭字幕' : '打开字幕',
              metrics: metrics,
              active: subtitlesOn,
              onPressed: _toggleSubtitles,
            ),
            SizedBox(width: gap),
            _iconButton(
              icon: service.isMuted
                  ? Icons.volume_off_rounded
                  : Icons.volume_up_rounded,
              tooltip: service.isMuted ? '取消静音' : '静音',
              metrics: metrics,
              onPressed: () {
                unawaited(AppHaptics.lightTap(settings));
                unawaited(service.toggleMute());
              },
            ),
          ],
        );

        // Transport left, toggles flush right, in the same order the full
        // player's bottom row uses: speed, subtitles, mute.
        return Stack(
          children: <Widget>[
            Positioned(
              left: inset + transportLeft,
              top: 0,
              bottom: 0,
              child: transport(),
            ),
            Positioned(
              right: handleWidth,
              top: 0,
              bottom: 0,
              child: toggles(),
            ),
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: _buildResizeHandle(metrics, rect),
            ),
          ],
        );
      },
    );
  }

  Widget _iconButton({
    required IconData icon,
    required String tooltip,
    required MiniVideoMetrics metrics,
    required VoidCallback onPressed,
    bool primary = false,
    bool active = false,
  }) {
    final size = primary
        ? metrics.buttonExtent + metrics.gap
        : metrics.buttonExtent;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: BoxConstraints.tightFor(width: size, height: size),
      iconSize: primary ? metrics.primaryIconSize : metrics.iconSize,
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        minimumSize: Size(size, size),
        maximumSize: Size(size, size),
        fixedSize: Size(size, size),
        foregroundColor: active ? AppTokens.accent : Colors.white,
      ),
      icon: Icon(icon),
    );
  }

  Widget _speedButton(
    MediaPlaybackService service,
    MiniVideoMetrics metrics,
    double width,
  ) {
    final speed = service.playbackSpeed;
    return Tooltip(
      message: '播放速度',
      child: InkWell(
        onTap: _pickSpeed,
        borderRadius: BorderRadius.circular(metrics.cornerRadius),
        child: SizedBox(
          width: width,
          height: metrics.buttonExtent,
          child: Center(
            child: Text(
              '${_compactSpeed(speed)}×',
              maxLines: 1,
              style: TextStyle(
                color: speed == 1 ? Colors.white : AppTokens.accent,
                fontSize: metrics.timeFontSize,
                fontWeight: FontWeight.w600,
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildResizeHandle(MiniVideoMetrics metrics, Rect rect) {
    // Invisible-ish by default and brighter on hover or while dragging, the
    // way desktop window corners behave. Pan rather than horizontal drag: a
    // diagonal push from a corner is what people actually do.
    return MouseRegion(
      cursor: SystemMouseCursors.resizeUpLeftDownRight,
      onEnter: (_) {
        if (!_resizeHover) setState(() => _resizeHover = true);
      },
      onExit: (_) {
        if (_resizeHover && !_resizing) setState(() => _resizeHover = false);
      },
      child: GestureDetector(
        key: const ValueKey<String>('ai-floating-resize'),
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => _beginResize(rect.width),
        onPanUpdate: _updateResize,
        onPanEnd: (_) => _endResize(),
        onPanCancel: _endResize,
        child: SizedBox(
          width: math.max(metrics.resizeExtent, 32.0),
          height: double.infinity,
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(
              end: (_resizeHover || _resizing) ? 1 : 0,
            ),
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            builder: (context, t, _) => CustomPaint(
              painter: _MiniResizeGrip(
                strength: t,
                stroke: 1.4 + .5 * t,
                radius: math.max(metrics.resizeExtent, 32),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniProgressPainter extends CustomPainter {
  _MiniProgressPainter({
    required this.played,
    required this.buffered,
    required this.track,
    required this.activeColor,
    required this.bufferedColor,
    required this.trackColor,
  });

  final double played;
  final double buffered;
  final double track;
  final Color activeColor;
  final Color bufferedColor;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final paint = Paint()..isAntiAlias = true;
    void line(double from, double to, Color color) {
      if (to <= from) return;
      paint.color = color;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(from, y - track / 2, to, y + track / 2),
          Radius.circular(track),
        ),
        paint,
      );
    }

    line(0, size.width, trackColor);
    line(0, size.width * buffered.clamp(0.0, 1.0), bufferedColor);
    line(0, size.width * played.clamp(0.0, 1.0), activeColor);
  }

  @override
  bool shouldRepaint(_MiniProgressPainter old) =>
      old.played != played ||
      old.buffered != buffered ||
      old.track != track ||
      old.activeColor != activeColor;
}

/// A corner bracket in the style of a crop mark.
///
/// Two concentric arcs were tried first and read as a signal-strength icon,
/// which is the opposite of what this corner means. A pair of straight
/// strokes meeting at the corner is the shape people already know as
/// "resize me".
class _MiniResizeGrip extends CustomPainter {
  _MiniResizeGrip({
    required this.strength,
    required this.stroke,
    required this.radius,
  });

  final double strength;
  final double stroke;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    // Inset from the card corner so the rounded corner never clips it.
    final corner = Offset(size.width - 1 - 4, size.height - 1 - 4);
    final arm = math.min(radius * .42, math.min(size.width, size.height) * .5);
    if (arm <= 2) return;

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke
      ..color = Colors.white.withValues(
        alpha: (.78 + .22 * strength).clamp(0.0, 1.0),
      );

    // Horizontal arm running in from the corner…
    canvas.drawLine(
      Offset(corner.dx - arm, corner.dy),
      corner,
      paint,
    );
    // …and the vertical arm running up out of it.
    canvas.drawLine(
      corner,
      Offset(corner.dx, corner.dy - arm),
      paint,
    );
  }

  @override
  bool shouldRepaint(_MiniResizeGrip old) =>
      old.strength != strength ||
      old.stroke != stroke ||
      old.radius != radius;
}
