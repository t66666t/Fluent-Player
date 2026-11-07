import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'media_library_tooltip.dart';
import 'package:provider/provider.dart';
import '../features/media_cache/media_cache_actions.dart';
import '../features/media_cache/media_cache_selection.dart';
import '../features/media_cache/media_cache_service.dart';
import '../services/library_service.dart';
import '../services/playback_queue_add_service.dart';

import '../theme/app_tokens.dart';
import '../utils/desktop_media_management_shortcuts.dart';
import '../utils/media_library_virtual_selection_actions.dart';
import 'media_library_compact_app_bar.dart';
import 'media_library_shell.dart';
import 'add_to_playlist_button.dart';
import 'playback_queue_add_actions.dart';
import 'transcription_queue_actions.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Source-specific actions use the folder toolbar's layout and button styling.
class MediaLibrarySelectionBarAction {
  const MediaLibrarySelectionBarAction({
    required this.label,
    required this.icon,
    required this.color,
    required this.onPressed,
    this.tooltip,
    this.compactLabel,
  });
  final String label;
  final String? tooltip, compactLabel;
  final IconData icon;
  final Color color;
  final VoidCallback? onPressed;
}

/// Selection-mode actions under the media library on phone and desktop.
///
/// A single bounded row; action density follows available width and count.
/// Shortcut hints stay in tooltips to keep the labels quiet.
class MediaLibrarySelectionBottomBar extends StatelessWidget {
  const MediaLibrarySelectionBottomBar({
    super.key,
    required this.actions,
    required this.onAction,
    this.cacheSelectedIds = const {},
    this.queueSelectedIds,
    this.onQueueProcessed,
    this.showAddToQueue = true,
    this.onTranscribe,
  }) : customActions = const [],
       _custom = false,
       onAddToQueue = null;

  const MediaLibrarySelectionBottomBar.custom({
    super.key,
    required List<MediaLibrarySelectionBarAction> actions,
    required this.onAddToQueue,
    this.showAddToQueue = true,
    this.onTranscribe,
  }) : customActions = actions,
       _custom = true,
       actions = const [],
       onAction = _ignoreAction,
       cacheSelectedIds = const {},
       queueSelectedIds = null,
       onQueueProcessed = null;

  static void _ignoreAction(MediaLibraryVirtualSelectionActionKind _) {}

  /// Folder / collection selection: recycle, export, optional rename.
  factory MediaLibrarySelectionBottomBar.folders({
    Key? key,
    required VoidCallback onMoveToRecycleBin,
    required VoidCallback onExportFluentPack,
    VoidCallback? onRename,
    Set<String> cacheSelectedIds = const {},
    List<String>? queueSelectedIds,
    ValueChanged<Set<String>>? onQueueProcessed,
  }) {
    final actions = MediaLibraryVirtualSelectionActions.forFolders(
      selectedIds: onRename == null
          ? const <String>{'a', 'b'}
          : const <String>{'only'},
    );
    return MediaLibrarySelectionBottomBar(
      key: key,
      actions: actions,
      cacheSelectedIds: cacheSelectedIds,
      queueSelectedIds: queueSelectedIds,
      onQueueProcessed: onQueueProcessed,
      onAction: (kind) {
        switch (kind) {
          case MediaLibraryVirtualSelectionActionKind.recycle:
            onMoveToRecycleBin();
          case MediaLibraryVirtualSelectionActionKind.export:
            onExportFluentPack();
          case MediaLibraryVirtualSelectionActionKind.rename:
            onRename?.call();
          case MediaLibraryVirtualSelectionActionKind.pin:
          case MediaLibraryVirtualSelectionActionKind.unpin:
          case MediaLibraryVirtualSelectionActionKind.hideContinue:
          case MediaLibraryVirtualSelectionActionKind.dismissRecent:
            break;
        }
      },
    );
  }

  final List<MediaLibraryVirtualSelectionAction> actions;
  final ValueChanged<MediaLibraryVirtualSelectionActionKind> onAction;
  final Set<String> cacheSelectedIds;
  final List<String>? queueSelectedIds;
  final ValueChanged<Set<String>>? onQueueProcessed;
  final List<MediaLibrarySelectionBarAction> customActions;
  final bool _custom;
  final bool showAddToQueue;
  final Future<QueueAddResult> Function(QueueAddProgress)? onAddToQueue;
  final VoidCallback? onTranscribe;

  @override
  Widget build(BuildContext context) {
    final compact = useCompactMediaLibraryTopBar(context);
    final library =
        cacheSelectedIds.isNotEmpty && MediaCacheService.instance != null
        ? context.watch<LibraryService>()
        : null;
    final showCache =
        library != null &&
        librarySelectionHasCacheableMedia(library, cacheSelectedIds);
    final showTranscribe = !_custom || onTranscribe != null;
    final transcriptionIds = queueSelectedIds ?? cacheSelectedIds.toList();
    // The mini player is painted above the library page. Report this bar's
    // height so the player moves up and these actions stay reachable.
    return MediaLibraryBottomBarObstruction(
      child: Material(
        color: AppTokens.bgRaised,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: AppTokens.lineSubtle)),
          ),
          child: SafeArea(
            top: false,
            minimum: EdgeInsets.only(
              bottom: MediaQuery.systemGestureInsetsOf(context).bottom,
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 8 : 24,
                vertical: 4,
              ),
              child: Center(
                heightFactor: 1,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 960),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final units =
                          actions.length +
                          customActions.length +
                          (showCache ? 1 : 0) +
                          (showTranscribe ? 1 : 0) +
                          (showAddToQueue ? 1 : 0);
                      final slotWidth =
                          constraints.maxWidth / (units == 0 ? 1 : units);
                      // Cache and settings share one action slot. Only reserve
                      // extra room when the compact split control cannot fit.
                      final cacheWidth = math.min(
                        constraints.maxWidth,
                        math.max(slotWidth, 64.0),
                      );
                      final actionWidth = showCache && units > 1
                          ? (constraints.maxWidth - cacheWidth) / (units - 1)
                          : slotWidth;
                      final dense = actionWidth < 130;
                      final actionInset = actionWidth < 40 ? 0.0 : 2.0;
                      return SizedBox(
                        height: 48,
                        child: Row(
                          children: [
                            if (showAddToQueue)
                              Expanded(
                                child: Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: actionInset,
                                  ),
                                  child: AddToPlaylistButton(
                                    onAdd: (progress) async {
                                      if (onAddToQueue case final add?) {
                                        return add(progress);
                                      }
                                      final ids = List<String>.of(
                                        queueSelectedIds ??
                                            cacheSelectedIds.toList(),
                                      );
                                      final result =
                                          await addLibrarySelectionToQueue(
                                            context,
                                            ids,
                                            progress: progress,
                                          );
                                      if (!result.cancelled &&
                                          !result.queueChanged) {
                                        onQueueProcessed?.call(
                                          ids
                                              .where(
                                                (id) =>
                                                    !result.failed.contains(id),
                                              )
                                              .toSet(),
                                        );
                                      }
                                      return result;
                                    },
                                    key: const ValueKey(
                                      'selection-add-to-playlist',
                                    ),
                                    height: 48,
                                    iconSize: dense ? 18 : 20,
                                    fontSize: dense ? 12 : 14,
                                    filled: true,
                                    stacked: true,
                                    fitLabel: true,
                                    label: _custom
                                        ? AddToPlaylistButton.defaultLabel
                                        : '插播',
                                    tooltip: AddToPlaylistButton.defaultLabel,
                                  ),
                                ),
                              ),
                            if (showTranscribe)
                              Expanded(
                                child: Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: actionInset,
                                  ),
                                  child: TranscriptionQueueButton(
                                    key: const ValueKey('selection-transcribe'),
                                    compact: dense,
                                    onPressed:
                                        onTranscribe ??
                                        (transcriptionIds.isEmpty
                                            ? null
                                            : () {
                                                openTranscriptionQueue(
                                                  context,
                                                  TranscriptionMediaSelection(
                                                    libraryIds:
                                                        transcriptionIds,
                                                  ),
                                                );
                                              }),
                                  ),
                                ),
                              ),
                            if (showCache)
                              SizedBox(
                                width: cacheWidth,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 2,
                                  ),
                                  child: MediaCacheSelectionControl(
                                    library: library,
                                    ids: cacheSelectedIds,
                                    compact: dense,
                                  ),
                                ),
                              ),
                            for (final action in actions)
                              Expanded(
                                child: Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: actionInset,
                                  ),
                                  child: _action(
                                    context: context,
                                    compact: dense,
                                    icon: action.icon,
                                    color: action.color,
                                    label: dense
                                        ? _compactLabel(action)
                                        : action.label,
                                    tooltip:
                                        _tooltipFor(context, action) ??
                                        _labelFor(context, action),
                                    onPressed: () => onAction(action.kind),
                                  ),
                                ),
                              ),
                            for (final action in customActions)
                              Expanded(
                                child: Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: actionInset,
                                  ),
                                  child: _action(
                                    context: context,
                                    compact: dense,
                                    icon: action.icon,
                                    color: action.color,
                                    label: dense
                                        ? action.compactLabel ?? action.label
                                        : action.label,
                                    tooltip: action.tooltip ?? action.label,
                                    onPressed: action.onPressed,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _compactLabel(MediaLibraryVirtualSelectionAction action) {
    switch (action.kind) {
      case MediaLibraryVirtualSelectionActionKind.recycle:
        return '回收站';
      case MediaLibraryVirtualSelectionActionKind.hideContinue:
        return '隐藏';
      case MediaLibraryVirtualSelectionActionKind.dismissRecent:
        return '忽略';
      default:
        return action.label;
    }
  }

  String _labelFor(
    BuildContext context,
    MediaLibraryVirtualSelectionAction action,
  ) {
    switch (action.kind) {
      case MediaLibraryVirtualSelectionActionKind.recycle:
        return DesktopMediaManagementShortcuts.buildTooltip(
          action.label,
          DesktopMediaManagementShortcutAction.openRecycleBin,
          context: context,
        );
      case MediaLibraryVirtualSelectionActionKind.export:
        return DesktopMediaManagementShortcuts.buildTooltip(
          action.label,
          DesktopMediaManagementShortcutAction.exportFluentPack,
          context: context,
        );
      case MediaLibraryVirtualSelectionActionKind.rename:
        return DesktopMediaManagementShortcuts.buildTooltip(
          action.label,
          DesktopMediaManagementShortcutAction.createCollection,
          context: context,
        );
      case MediaLibraryVirtualSelectionActionKind.pin:
      case MediaLibraryVirtualSelectionActionKind.unpin:
      case MediaLibraryVirtualSelectionActionKind.hideContinue:
      case MediaLibraryVirtualSelectionActionKind.dismissRecent:
        return action.label;
    }
  }

  String? _tooltipFor(
    BuildContext context,
    MediaLibraryVirtualSelectionAction action,
  ) {
    if (action.kind == MediaLibraryVirtualSelectionActionKind.export) {
      return DesktopMediaManagementShortcuts.buildTooltip(
        '导出为 Fluent Pack 或 Zip',
        DesktopMediaManagementShortcutAction.exportFluentPack,
        context: context,
      );
    }
    return action.tooltip;
  }

  Widget _action({
    required BuildContext context,
    required bool compact,
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback? onPressed,
    String? tooltip,
  }) {
    final text = FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(label, maxLines: 1, softWrap: false),
    );
    final button = DesktopButtonClickRegion(
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: color,
          backgroundColor: color.withValues(alpha: 0.045),
          textStyle: Theme.of(context).textTheme.labelLarge!.copyWith(
            fontSize: compact ? 12 : 14,
            fontWeight: FontWeight.w600,
            height: 1.3,
          ),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 2 : 8,
            vertical: 0,
          ),
          visualDensity: VisualDensity.standard,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: compact
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 18),
                  const SizedBox(height: 2),
                  SizedBox(height: 16, width: double.infinity, child: text),
                ],
              )
            : FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 20),
                    const SizedBox(width: 6),
                    text,
                  ],
                ),
              ),
      ),
    );
    final labeled = tooltip == null
        ? button
        : MediaLibraryTooltip(message: tooltip, child: button);
    return labeled;
  }
}

/// Keeps the outgoing actions mounted while the bar fades and slides away.
///
/// Leave this host in the scaffold and pass null to close it. The obstruction
/// reporter uses the same animation so the mini player follows the visible bar
/// on each frame, including when an exit is reversed by another selection.
class MediaLibrarySelectionBarTransition extends StatefulWidget {
  const MediaLibrarySelectionBarTransition({super.key, this.child});

  static const duration = Duration(milliseconds: 220);

  final Widget? child;

  @override
  State<MediaLibrarySelectionBarTransition> createState() =>
      _MediaLibrarySelectionBarTransitionState();
}

class _MediaLibrarySelectionBarTransitionState
    extends State<MediaLibrarySelectionBarTransition>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: MediaLibrarySelectionBarTransition.duration,
    value: widget.child == null ? 0 : 1,
  )..addStatusListener(_onStatus);
  late final _visibility = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeInOutCubic,
  );
  Widget? _retainedChild;
  bool _disableAnimations = false;

  @override
  void initState() {
    super.initState();
    _retainedChild = widget.child;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (_disableAnimations) _updateVisibility();
  }

  @override
  void didUpdateWidget(MediaLibrarySelectionBarTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.child != null) _retainedChild = widget.child;
    if ((oldWidget.child == null) != (widget.child == null)) {
      _updateVisibility();
    }
  }

  void _updateVisibility() {
    if (_disableAnimations) {
      _controller.value = widget.child == null ? 0 : 1;
    } else if (widget.child != null) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && widget.child == null) {
      setState(() => _retainedChild = null);
    }
  }

  @override
  void dispose() {
    _visibility.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final closing = widget.child == null;
    return IgnorePointer(
      ignoring: closing,
      child: ExcludeFocus(
        excluding: closing,
        child: ExcludeSemantics(
          excluding: closing,
          child: SizeTransition(
            sizeFactor: _visibility,
            alignment: Alignment.topCenter,
            child: FadeTransition(
              opacity: _visibility,
              child: _MediaLibraryBottomBarAnimation(
                animation: _visibility,
                child: _retainedChild ?? const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MediaLibraryBottomBarAnimation extends InheritedWidget {
  const _MediaLibraryBottomBarAnimation({
    required this.animation,
    required super.child,
  });

  final Animation<double> animation;

  @override
  bool updateShouldNotify(_MediaLibraryBottomBarAnimation oldWidget) =>
      animation != oldWidget.animation;
}

/// Tells the library frame the bar's visible height, then clears it on dispose.
///
/// Measurement waits until after layout: the bar's height includes the system
/// inset kept inside a [SafeArea], which a constant cannot.
class MediaLibraryBottomBarObstruction extends StatefulWidget {
  const MediaLibraryBottomBarObstruction({super.key, required this.child});

  final Widget child;

  @override
  State<MediaLibraryBottomBarObstruction> createState() =>
      MediaLibraryBottomBarObstructionState();
}

class MediaLibraryBottomBarObstructionState
    extends State<MediaLibraryBottomBarObstruction> {
  Route<dynamic>? _route;
  MediaLibraryShellController? _shell;
  Animation<double>? _visibility;
  double _height = 0;
  double? _reported;
  bool _reportScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    _shell = MediaLibraryShell.maybeOf(context);
    final visibility = context
        .dependOnInheritedWidgetOfExactType<_MediaLibraryBottomBarAnimation>()
        ?.animation;
    if (_visibility != visibility) {
      _visibility?.removeListener(_publishVisibleHeight);
      _visibility = visibility;
      _visibility?.addListener(_publishVisibleHeight);
    }
    _scheduleReport();
  }

  @override
  void dispose() {
    _visibility?.removeListener(_publishVisibleHeight);
    _publish(0);
    super.dispose();
  }

  void _scheduleReport() {
    if (_reportScheduled) return;
    _reportScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reportScheduled = false;
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      _height = box.size.height;
      _publishVisibleHeight();
    });
  }

  void _publishVisibleHeight() {
    _publish(_height * (_visibility?.value ?? 1));
  }

  void _publish(double height) {
    final route = _route;
    final shell = _shell;
    if (route == null || shell == null) return;
    if (_reported != null && (height - _reported!).abs() < 1) return;
    _reported = height;
    shell.setSelectionBarObstruction(route, height);
  }

  @override
  Widget build(BuildContext context) {
    _scheduleReport();
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        _scheduleReport();
        return true;
      },
      child: SizeChangedLayoutNotifier(child: widget.child),
    );
  }
}
