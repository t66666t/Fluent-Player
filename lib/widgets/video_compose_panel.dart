import 'dart:async';
import '../services/subtitle_font_service.dart';
import '../models/subtitle_font.dart';
import '../services/video_compose/video_compose_subtitle_service.dart';
import 'subtitle_font_license_dialog.dart';
import '../services/subtitle_debug_session.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import '../models/subtitle_position.dart';
import '../models/subtitle_style.dart';
import '../services/subtitle_position_actions.dart';
import '../models/video_compose_models.dart';
import '../models/video_item.dart';
import '../models/media_source_ref.dart';
import '../services/library_service.dart';
import '../services/media_materialization_service.dart';
import '../services/settings_service.dart';
import '../services/video_compose_manager.dart';
import '../services/video_compose/video_compose_preview_controller.dart';
import '../services/video_compose/android_compose_storage_access.dart';
import '../utils/app_toast.dart';
import '../utils/open_with_other_apps.dart';
import 'media_materialization_progress_card.dart';
import 'video_compose_queue_dialog.dart';
import 'sidebar_activity.dart';
import 'visibility_input_gate.dart';
import '../screens/simple_video_player_screen.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

class VideoComposePanel extends StatefulWidget {
  final VideoItem videoItem;
  final List<String> currentSelectedPaths;
  final Map<String, String> availableSubtitleMap;
  final VoidCallback? onBack;
  final VoidCallback? onOpenSubtitleStyle;
  final VoidCallback? onOpenSubtitleManager;
  final ValueChanged<VideoComposePreviewConfig>? onPreviewChanged;
  final Future<void> Function()? beforeEnqueue;
  final Future<Map<String, String>> Function()? prepareSubtitleOptions;

  const VideoComposePanel({
    super.key,
    required this.videoItem,
    required this.currentSelectedPaths,
    required this.availableSubtitleMap,
    this.onBack,
    this.onOpenSubtitleStyle,
    this.onOpenSubtitleManager,
    this.onPreviewChanged,
    this.beforeEnqueue,
    this.prepareSubtitleOptions,
  });

  @override
  State<VideoComposePanel> createState() => _VideoComposePanelState();
}

class _ComposeSelectItem<T> {
  final T value;
  final String label;

  const _ComposeSelectItem({required this.value, required this.label});
}

class _ComposeSelect<T> extends StatefulWidget {
  final T? value;
  final String label;
  final String emptyLabel;
  final List<_ComposeSelectItem<T>> items;
  final ValueChanged<T>? onChanged;
  final double fontSize;

  const _ComposeSelect({
    super.key,
    required this.value,
    required this.label,
    required this.items,
    required this.onChanged,
    required this.fontSize,
    this.emptyLabel = '请选择',
  });

  @override
  State<_ComposeSelect<T>> createState() => _ComposeSelectState<T>();
}

class _ComposeSelectState<T> extends State<_ComposeSelect<T>>
    with SingleTickerProviderStateMixin {
  final LayerLink _layerLink = LayerLink();
  final FocusNode _focusNode = FocusNode();
  OverlayEntry? _overlayEntry;
  late final AnimationController _animationController;
  late final CurvedAnimation _fadeAnimation;
  late final Animation<double> _scaleAnimation;
  late final Animation<Offset> _slideAnimation;
  bool _isOpen = false;
  bool _isHovered = false;
  bool _isFocused = false;
  bool _overlayBuildScheduled = false;
  double _anchorWidth = 240;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
      reverseDuration: const Duration(milliseconds: 100),
    );
    final curved = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _fadeAnimation = curved;
    _scaleAnimation = Tween<double>(begin: 0.96, end: 1).animate(curved);
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, -0.035),
      end: Offset.zero,
    ).animate(curved);
    _focusNode.addListener(_handleFocusChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // This menu lives in the root overlay, outside the retained panel's
    // Offstage/TickerMode. Release it synchronously when its owner is hidden;
    // waiting for a muted exit animation would leave an invisible page barrier.
    if (!SidebarActivity.of(context) ||
        !(ModalRoute.isCurrentOf(context) ?? true)) {
      _removeMenu();
    }
  }

  @override
  void didUpdateWidget(covariant _ComposeSelect<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isEnabled) {
      _removeMenu();
    } else {
      // The root overlay is not a descendant of this field. Invalidating it
      // during the field's build violates the framework's build ordering.
      _scheduleOverlayBuild();
    }
  }

  void _scheduleOverlayBuild() {
    if (_overlayEntry == null || _overlayBuildScheduled) return;
    _overlayBuildScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _overlayBuildScheduled = false;
      if (mounted) _overlayEntry?.markNeedsBuild();
    });
  }

  void _removeMenu() {
    final entry = _overlayEntry;
    _overlayEntry = null;
    _isOpen = false;
    _animationController.stop();
    entry?.remove();
    entry?.dispose();
  }

  @override
  void deactivate() {
    _removeMenu();
    super.deactivate();
  }

  @override
  void dispose() {
    _removeMenu();
    _focusNode
      ..removeListener(_handleFocusChanged)
      ..dispose();
    _fadeAnimation.dispose();
    _animationController.dispose();
    super.dispose();
  }

  bool get _isEnabled => widget.items.isNotEmpty && widget.onChanged != null;

  String get _selectedLabel {
    for (final item in widget.items) {
      if (item.value == widget.value) return item.label;
    }
    return widget.items.isEmpty ? '暂无可用选项' : widget.emptyLabel;
  }

  IconData get _fieldIcon {
    if (widget.label.contains('字幕')) return Icons.subtitles_rounded;
    if (widget.label.contains('分辨率')) return Icons.aspect_ratio_rounded;
    if (widget.label.contains('烧录') || widget.label.contains('渲染')) {
      return Icons.auto_awesome_rounded;
    }
    return Icons.tune_rounded;
  }

  void _handleFocusChanged() {
    if (!mounted || _isFocused == _focusNode.hasFocus) return;
    setState(() => _isFocused = _focusNode.hasFocus);
  }

  void _toggleMenu() {
    if (!_isEnabled) return;
    if (_isOpen) {
      _closeMenu();
    } else {
      _openMenu();
    }
  }

  void _openMenu() {
    if (!_isEnabled || _isOpen) return;
    _focusNode.requestFocus();
    _isOpen = true;
    if (mounted) setState(() {});
    _overlayEntry ??= OverlayEntry(builder: _buildOverlay);
    if (!_overlayEntry!.mounted) {
      Overlay.of(context, rootOverlay: true).insert(_overlayEntry!);
    } else {
      _overlayEntry!.markNeedsBuild();
    }
    _animationController.forward();
  }

  Future<void> _closeMenu() async {
    if (!_isOpen && _overlayEntry == null) return;
    final entry = _overlayEntry;
    _isOpen = false;
    if (mounted) setState(() {});
    entry?.markNeedsBuild();
    try {
      await _animationController.reverse().orCancel;
    } on TickerCanceled {
      return;
    }
    if (mounted && !_isOpen && identical(entry, _overlayEntry)) _removeMenu();
  }

  void _selectItem(T value) {
    widget.onChanged?.call(value);
    _overlayEntry?.markNeedsBuild();
    _closeMenu();
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    if (_overlayEntry == null) return const SizedBox.shrink();
    final double popupWidth = _anchorWidth.clamp(220.0, 520.0);
    final renderBox = context.findRenderObject() as RenderBox?;
    final anchorTop = renderBox?.localToGlobal(Offset.zero).dy ?? 0;
    final anchorHeight = renderBox?.size.height ?? 52;
    final viewportHeight = MediaQuery.sizeOf(context).height;
    final estimatedHeight = (widget.items.length * 47.0 + 48).clamp(
      96.0,
      420.0,
    );
    final spaceBelow = viewportHeight - anchorTop - anchorHeight;
    final bool showAbove =
        spaceBelow < estimatedHeight + 12 && anchorTop > spaceBelow;
    return FadeInputGate(
      opacity: _fadeAnimation,
      enabled: _isOpen,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _closeMenu,
            ),
          ),
          CompositedTransformFollower(
            link: _layerLink,
            showWhenUnlinked: false,
            targetAnchor: showAbove ? Alignment.topLeft : Alignment.bottomLeft,
            followerAnchor: showAbove
                ? Alignment.bottomLeft
                : Alignment.topLeft,
            offset: Offset(0, showAbove ? -8 : 8),
            child: FadeTransition(
              opacity: _fadeAnimation,
              child: SlideTransition(
                position: _slideAnimation,
                child: ScaleTransition(
                  scale: _scaleAnimation,
                  alignment: Alignment.topCenter,
                  child: Material(
                    color: Colors.transparent,
                    child: Container(
                      width: popupWidth,
                      constraints: const BoxConstraints(maxHeight: 420),
                      padding: const EdgeInsets.fromLTRB(7, 8, 7, 7),
                      decoration: BoxDecoration(
                        color: const Color(0xFF20242B),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFF3A414D)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.48),
                            blurRadius: 28,
                            offset: const Offset(0, 12),
                          ),
                          BoxShadow(
                            color: const Color(
                              0xFF4D91FF,
                            ).withValues(alpha: 0.08),
                            blurRadius: 18,
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
                            child: Row(
                              children: [
                                Container(
                                  width: 5,
                                  height: 14,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF65A2FF),
                                    borderRadius: BorderRadius.circular(99),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    widget.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: (widget.fontSize - 1).clamp(
                                        10.0,
                                        13.0,
                                      ),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Flexible(
                            child: SingleChildScrollView(
                              key: PageStorageKey(
                                'compose-select-${widget.label}',
                              ),
                              padding: EdgeInsets.zero,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: widget.items
                                    .map(_buildPopupItem)
                                    .toList(growable: false),
                              ),
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
        ],
      ),
    );
  }

  Widget _buildPopupItem(_ComposeSelectItem<T> item) {
    final bool selected = item.value == widget.value;
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: _ComposeSelectOption(
        label: item.label,
        selected: selected,
        fontSize: widget.fontSize,
        onTap: () => _selectItem(item.value),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool highlighted = _isOpen || _isFocused;
    final Color borderColor = highlighted
        ? const Color(0xFF639FFF)
        : (_isHovered ? const Color(0xFF4A5361) : const Color(0xFF383E48));
    final Color fillColor = highlighted
        ? const Color(0xFF27364B)
        : (_isHovered ? const Color(0xFF292F38) : const Color(0xFF242930));
    final double controlHeight = (widget.fontSize * 3.9).clamp(48.0, 56.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth.isFinite) _anchorWidth = constraints.maxWidth;
        return CompositedTransformTarget(
          link: _layerLink,
          child: Semantics(
            button: true,
            enabled: _isEnabled,
            expanded: _isOpen,
            label: widget.label,
            value: _selectedLabel,
            child: FocusableActionDetector(
              focusNode: _focusNode,
              enabled: _isEnabled,
              mouseCursor: _isEnabled
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              onShowHoverHighlight: (value) {
                if (mounted && _isHovered != value) {
                  setState(() => _isHovered = value);
                }
              },
              onShowFocusHighlight: (value) {
                if (mounted && _isFocused != value) {
                  setState(() => _isFocused = value);
                }
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _isEnabled ? _toggleMenu : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  curve: Curves.easeOutCubic,
                  height: controlHeight,
                  padding: const EdgeInsets.fromLTRB(9, 7, 10, 7),
                  decoration: BoxDecoration(
                    color: fillColor,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: borderColor,
                      width: highlighted ? 1.35 : 1,
                    ),
                    boxShadow: highlighted
                        ? [
                            BoxShadow(
                              color: const Color(
                                0xFF2979FF,
                              ).withValues(alpha: 0.12),
                              blurRadius: 12,
                              spreadRadius: 1,
                            ),
                          ]
                        : const <BoxShadow>[],
                  ),
                  child: Row(
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        curve: Curves.easeOutCubic,
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: highlighted
                              ? const Color(0xFF4D91FF)
                              : const Color(0xFF343B46),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          _fieldIcon,
                          size: widget.fontSize + 3,
                          color: highlighted ? Colors.white : Colors.white60,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: highlighted
                                    ? const Color(0xFF8DB8FF)
                                    : Colors.white54,
                                fontSize: (widget.fontSize - 2).clamp(
                                  9.0,
                                  11.0,
                                ),
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.15,
                              ),
                            ),
                            const SizedBox(height: 2),
                            ClipRect(
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 160),
                                reverseDuration: const Duration(
                                  milliseconds: 120,
                                ),
                                switchInCurve: Curves.easeOutCubic,
                                switchOutCurve: Curves.easeInCubic,
                                transitionBuilder: (child, animation) {
                                  return FadeTransition(
                                    opacity: animation,
                                    child: SlideTransition(
                                      position: Tween<Offset>(
                                        begin: const Offset(0, 0.16),
                                        end: Offset.zero,
                                      ).animate(animation),
                                      child: child,
                                    ),
                                  );
                                },
                                child: Text(
                                  _selectedLabel,
                                  key: ValueKey<Object?>(widget.value),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: _isEnabled
                                        ? Colors.white
                                        : Colors.white38,
                                    fontSize: widget.fontSize,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 7),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        curve: Curves.easeOutCubic,
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: highlighted
                              ? Colors.white.withValues(alpha: 0.1)
                              : Colors.transparent,
                          shape: BoxShape.circle,
                        ),
                        child: AnimatedRotation(
                          turns: _isOpen ? 0.5 : 0,
                          duration: const Duration(milliseconds: 120),
                          curve: Curves.easeOutCubic,
                          child: Icon(
                            Icons.keyboard_arrow_down_rounded,
                            size: widget.fontSize + 7,
                            color: highlighted
                                ? const Color(0xFFA9CAFF)
                                : Colors.white54,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ComposeSelectOption extends StatefulWidget {
  final String label;
  final bool selected;
  final double fontSize;
  final VoidCallback onTap;

  const _ComposeSelectOption({
    required this.label,
    required this.selected,
    required this.fontSize,
    required this.onTap,
  });

  @override
  State<_ComposeSelectOption> createState() => _ComposeSelectOptionState();
}

class _ComposeSelectOptionState extends State<_ComposeSelectOption> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.selected || _hovered;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOutCubic,
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
          decoration: BoxDecoration(
            color: widget.selected
                ? const Color(0xFF2C4770)
                : (_hovered ? const Color(0xFF2B323D) : Colors.transparent),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: widget.selected
                  ? const Color(0xFF477EC4)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 100),
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: widget.selected
                      ? const Color(0xFF67A3FF)
                      : const Color(0xFF303741),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: active ? const Color(0xFF78ACFF) : Colors.white24,
                  ),
                ),
                child: AnimatedScale(
                  scale: widget.selected ? 1 : 0,
                  duration: const Duration(milliseconds: 100),
                  curve: Curves.easeOutBack,
                  child: const Icon(
                    Icons.check_rounded,
                    size: 15,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: widget.selected ? Colors.white : Colors.white70,
                    fontSize: widget.fontSize,
                    height: 1.25,
                    fontWeight: widget.selected
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VideoComposePanelState extends State<VideoComposePanel> {
  late Map<String, String> _subtitleOptions;
  bool _preparingSubtitleOptions = false;
  bool _primarySelectionEdited = false, _secondarySelectionEdited = false;
  Object? _subtitlePreparationError;
  int _subtitlePreparationRevision = 0;
  String? _primaryPath;
  String? _secondaryPath;
  String? _customOutputPath;
  String? _sourceResolutionLabel;
  VideoComposeResolution _resolution = VideoComposeResolution.p1080;
  VideoComposeRenderMode _renderMode = VideoComposeRenderMode.precise;
  bool _continuousSubtitle = false;
  bool _embedSoftSubtitles = false;
  bool _softSubtitleOnly = false;
  bool _softSubtitleUseSourceQuality = true;
  bool _animateVisibility = false;
  bool get _showCustomOutputDirectory => !Platform.isIOS;

  String get _openOutputLabel {
    if (Platform.isWindows) return '用文件资源管理器打开';
    if (Platform.isMacOS) return '在“访达”中显示';
    if (Platform.isLinux) return '在文件管理器中显示';
    return '用其他应用打开';
  }

  String get _savedOutputHint {
    if (Platform.isWindows) return '已保存，可在文件资源管理器中定位该文件';
    if (Platform.isMacOS) return '已保存，可在“访达”中定位该文件';
    if (Platform.isLinux) return '已保存，可在文件管理器中定位该文件';
    return '已保存，可使用其他应用打开该视频';
  }

  String get _defaultOutputDirectoryLabel {
    if (Platform.isAndroid) {
      return '/storage/emulated/0/Download/ComposedVideos';
    }
    if (Platform.isWindows || Platform.isMacOS) {
      return '默认目录（程序所在目录/ComposedVideos）';
    }
    return '默认目录（应用文档/ComposedVideos）';
  }

  @override
  void initState() {
    super.initState();
    _subtitleOptions = Map.of(widget.availableSubtitleMap);
    _preparingSubtitleOptions = widget.prepareSubtitleOptions != null;
    _loadInitialFromSettings(applyState: false);
    _loadSourceResolution();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.prepareSubtitleOptions != null) {
        unawaited(_prepareSubtitleOptions());
      }
      _notifyPreviewChanged();
      setState(() {
        _animateVisibility = true;
      });
    });
  }

  @override
  void didUpdateWidget(covariant VideoComposePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoItem.id != widget.videoItem.id ||
        oldWidget.videoItem.path != widget.videoItem.path) {
      _subtitlePreparationRevision++;
      _subtitleOptions = Map.of(widget.availableSubtitleMap);
      _primarySelectionEdited = _secondarySelectionEdited = false;
      _loadInitialFromSettings(applyState: false);
      if (widget.prepareSubtitleOptions != null) {
        unawaited(_prepareSubtitleOptions());
      }
    } else {
      _subtitleOptions = {..._subtitleOptions, ...widget.availableSubtitleMap};
    }
  }

  Future<void> _prepareSubtitleOptions() async {
    final prepare = widget.prepareSubtitleOptions;
    if (prepare == null) return;
    final revision = ++_subtitlePreparationRevision;
    final itemId = widget.videoItem.id;
    setState(() {
      _preparingSubtitleOptions = true;
      _subtitlePreparationError = null;
    });
    try {
      final options = await prepare();
      if (!mounted ||
          revision != _subtitlePreparationRevision ||
          itemId != widget.videoItem.id) {
        return;
      }
      final primary = _primaryPath, secondary = _secondaryPath;
      setState(() {
        _subtitleOptions = {...widget.availableSubtitleMap, ...options};
        if (!_primarySelectionEdited &&
            _primaryPath == null &&
            _subtitleOptions.isNotEmpty) {
          _primaryPath =
              _subtitleOptions.containsKey(widget.videoItem.subtitlePath)
              ? widget.videoItem.subtitlePath
              : _subtitleOptions.keys.first;
        }
        if (!_secondarySelectionEdited &&
            _secondaryPath == null &&
            widget.videoItem.secondarySubtitlePath != _primaryPath &&
            _subtitleOptions.containsKey(
              widget.videoItem.secondarySubtitlePath,
            )) {
          _secondaryPath = widget.videoItem.secondarySubtitlePath;
        }
      });
      if (primary != _primaryPath || secondary != _secondaryPath) {
        _notifyPreviewChanged();
      }
    } catch (error) {
      if (mounted && revision == _subtitlePreparationRevision) {
        setState(() => _subtitlePreparationError = error);
      }
    } finally {
      if (mounted && revision == _subtitlePreparationRevision) {
        setState(() => _preparingSubtitleOptions = false);
      }
    }
  }

  void _notifyPreviewChanged() {
    widget.onPreviewChanged?.call(
      VideoComposePreviewConfig(
        primarySubtitlePath: _primaryPath,
        secondarySubtitlePath: _secondaryPath,
        renderSecondarySubtitle:
            _secondaryPath != null && _secondaryPath!.isNotEmpty,
        continuousSubtitle: _continuousSubtitle,
        splitSubtitleByLine: Provider.of<SettingsService>(
          context,
          listen: false,
        ).splitSubtitleByLine,
        burnSubtitles: !_softSubtitleOnly,
      ),
    );
  }

  Future<void> _loadSourceResolution() async {
    String? source;
    if (itemNeedsOnlineMaterialization(
      source: widget.videoItem.sourceRef,
      path: widget.videoItem.path,
    )) {
      try {
        final estimate = await context
            .read<LibraryService>()
            .estimateOnlineMediaMaterialization(
              widget.videoItem.id,
              MediaMaterializationRequirement.videoFrames,
            );
        if (estimate.width != null && estimate.height != null) {
          source = '${estimate.width}×${estimate.height}';
        }
      } catch (_) {}
    } else {
      final manager = Provider.of<VideoComposeManager>(context, listen: false);
      source = await manager.getSourceResolutionLabel(widget.videoItem.path);
    }
    if (!mounted) return;
    setState(() {
      _sourceResolutionLabel = source;
    });
  }

  void _loadInitialFromSettings({bool applyState = true}) {
    final settings = Provider.of<SettingsService>(context, listen: false);
    final List<String> candidates = _subtitleOptions.keys.toList();
    String? selectedPrimary;
    String? selectedSecondary;

    final String? currentPrimary = widget.currentSelectedPaths.isNotEmpty
        ? widget.currentSelectedPaths.first
        : null;
    final String? currentSecondary = widget.currentSelectedPaths.length > 1
        ? widget.currentSelectedPaths[1]
        : null;

    // 跟随当前视频卡片/当前播放选择：优先当前播放器选中的主字幕，
    // 其次视频条目持久化的主字幕，最后回退到候选列表第一项。
    if (currentPrimary != null && candidates.contains(currentPrimary)) {
      selectedPrimary = currentPrimary;
    } else if (widget.videoItem.subtitlePath != null &&
        candidates.contains(widget.videoItem.subtitlePath)) {
      selectedPrimary = widget.videoItem.subtitlePath;
    } else if (candidates.isNotEmpty) {
      selectedPrimary = candidates.first;
    }

    // 副字幕跟随当前播放器选择，其次视频条目持久化的副字幕，
    // 都没有则保持"无"。
    if (currentSecondary != null && candidates.contains(currentSecondary)) {
      selectedSecondary = currentSecondary;
    } else if (widget.videoItem.secondarySubtitlePath != null &&
        candidates.contains(widget.videoItem.secondarySubtitlePath)) {
      selectedSecondary = widget.videoItem.secondarySubtitlePath;
    }

    void assignState() {
      _primaryPath = selectedPrimary;
      _secondaryPath = selectedSecondary;
      _customOutputPath = _showCustomOutputDirectory
          ? settings.videoComposeCustomOutputPath
          : null;
      if (Platform.isAndroid &&
          (_customOutputPath == null || _customOutputPath!.isEmpty)) {
        _customOutputPath = '/storage/emulated/0/Download/ComposedVideos';
      }
      _resolution = _resolutionFromHeight(
        settings.videoComposeResolutionHeight,
      );
      _renderMode = VideoComposeRenderMode.fromStorage(
        settings.videoComposeRenderMode,
        fallback: VideoComposeRenderMode.precise,
      );
      _continuousSubtitle = settings.videoComposeContinuousSubtitle;
      _embedSoftSubtitles = settings.videoComposeEmbedSoftSubtitles;
      _softSubtitleOnly =
          settings.videoComposeSoftSubtitleOnly && _embedSoftSubtitles;
      _softSubtitleUseSourceQuality =
          settings.videoComposeSoftSubtitleUseSourceQuality;
    }

    if (applyState) {
      if (!mounted) return;
      setState(assignState);
      return;
    }
    assignState();
  }

  VideoComposeResolution _resolutionFromHeight(int value) {
    return switch (value) {
      360 => VideoComposeResolution.p360,
      480 => VideoComposeResolution.p480,
      720 => VideoComposeResolution.p720,
      1080 => VideoComposeResolution.p1080,
      1440 => VideoComposeResolution.p1440,
      2160 => VideoComposeResolution.p2160,
      _ => VideoComposeResolution.source,
    };
  }

  int _heightFromResolution(VideoComposeResolution value) {
    return switch (value) {
      VideoComposeResolution.source => 0,
      VideoComposeResolution.p360 => 360,
      VideoComposeResolution.p480 => 480,
      VideoComposeResolution.p720 => 720,
      VideoComposeResolution.p1080 => 1080,
      VideoComposeResolution.p1440 => 1440,
      VideoComposeResolution.p2160 => 2160,
    };
  }

  bool _enqueuePending = false;
  Future<void> _enqueueCompose() async {
    if (_enqueuePending) return;
    setState(() => _enqueuePending = true);
    try {
      await _enqueueComposeChecked();
    } catch (e) {
      if (mounted) AppToast.show('无法创建合成任务：$e', type: AppToastType.error);
    } finally {
      if (mounted) setState(() => _enqueuePending = false);
    }
  }

  Future<void> _enqueueComposeChecked() async {
    final manager = Provider.of<VideoComposeManager>(context, listen: false);
    final settings = Provider.of<SettingsService>(context, listen: false);
    final bool softOnly = _softSubtitleOnly;
    final bool embedSoftSubtitles = _embedSoftSubtitles || softOnly;
    final List<VideoComposeSoftSubtitleTrack> softTracks = embedSoftSubtitles
        ? _subtitleOptions.entries
              .where((e) => e.key.trim().isNotEmpty)
              .map(
                (e) => VideoComposeSoftSubtitleTrack(
                  path: e.key,
                  title: e.value.trim().isEmpty ? '字幕' : e.value.trim(),
                ),
              )
              .toList()
        : const <VideoComposeSoftSubtitleTrack>[];
    String? primary = _primaryPath;
    String? secondary = (_secondaryPath != null && _secondaryPath!.isNotEmpty)
        ? _secondaryPath
        : null;
    if (!softOnly) {
      if ((primary == null || primary.isEmpty) &&
          (secondary == null || secondary.isEmpty)) {
        if (mounted) {
          AppToast.show('请先选择至少一个字幕', type: AppToastType.error);
        }
        return;
      }
      if ((primary == null || primary.isEmpty) &&
          secondary != null &&
          secondary.isNotEmpty) {
        primary = secondary;
        secondary = null;
      }
    }
    String? effectiveOutputPath = _showCustomOutputDirectory
        ? _customOutputPath?.trim()
        : null;
    if (effectiveOutputPath != null && effectiveOutputPath.isEmpty) {
      effectiveOutputPath = null;
    }
    if (Platform.isAndroid && effectiveOutputPath == null) {
      effectiveOutputPath = '/storage/emulated/0/Download/ComposedVideos';
      _customOutputPath = effectiveOutputPath;
      settings.updateSetting(
        'videoComposeCustomOutputPath',
        effectiveOutputPath,
      );
    }
    if (Platform.isAndroid &&
        effectiveOutputPath != null &&
        await _androidOutputNeedsStoragePermission(effectiveOutputPath)) {
      final granted = await _ensureAndroidExternalStoragePermission(
        requestFromUser: true,
      );
      if (!granted) return;
    }
    if (effectiveOutputPath != null) {
      try {
        final dir = Directory(effectiveOutputPath);
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
      } catch (_) {
        if (mounted) {
          AppToast.show('输出目录不可用，请重新选择', type: AppToastType.error);
        }
        return;
      }
    }
    if (!await _confirmOnlineMaterializationIfNeeded()) return;
    await widget.beforeEnqueue?.call();
    final bool audioItem = widget.videoItem.type == MediaType.audio;
    final SubtitlePositionTarget positionTarget =
        SubtitlePositionTarget.resolve(
          ghost: false,
          audio: audioItem,
          presetId: SubtitleDebugSession.instance.preset?.id,
        );
    final Alignment composeAlignment = displayedSubtitleAlignment(
      settings: settings,
      target: positionTarget,
    );
    final SubtitlePlacementSnapshot? composePlacement =
        SubtitleDebugSession.instance.preset == null
        ? null
        : targetHasPresetOverride(settings, positionTarget)
        ? SubtitlePlacementSnapshot.custom(composeAlignment)
        : const SubtitlePlacementSnapshot.presetDefault();
    final SubtitleStyle landscapeStyle =
        widget.videoItem.type == MediaType.audio
        ? settings.audioSubtitleStyleLandscape
        : settings.subtitleStyleLandscape;
    final SubtitleStyle portraitStyle = widget.videoItem.type == MediaType.audio
        ? settings.audioSubtitleStylePortrait
        : settings.subtitleStylePortrait;
    final fonts = SubtitleFontService.instance;
    String? primaryLanguage;
    String? secondaryLanguage;
    if (!softOnly) {
      await fonts.ready;
      const subtitles = VideoComposeSubtitleService();
      final mainItems = await subtitles.loadSubtitle(primary);
      final secondaryItems = await subtitles.loadSubtitle(secondary);
      primaryLanguage = fonts.languageForSource(
        primary,
        label: _subtitleOptions[primary],
        texts: mainItems.take(100).map((s) => s.text),
      );
      secondaryLanguage = fonts.languageForSource(
        fonts.secondarySource(primary, secondary),
        label: _subtitleOptions[secondary],
        texts: secondaryItems.take(100).map((s) => s.text),
      );
      final preset = SubtitleDebugSession.instance.preset;
      final used = preset != null
          ? {
              preset.primaryFont,
              if (secondaryItems.isNotEmpty || settings.splitSubtitleByLine)
                preset.secondaryFont,
            }
          : fonts.familiesForTracks(
              landscapeStyle.textStyle,
              primary: mainItems.map((s) => s.text),
              secondary: secondaryItems.map((s) => s.text),
              primaryLanguage: primaryLanguage,
              secondaryLanguage: secondaryLanguage,
              splitByLine: settings.splitSubtitleByLine,
            );
      await fonts.verifyFiles(used);
      if (!mounted) return;
      final assets = used
          .map((id) => fonts.find(id) ?? SubtitleFontAsset(id: id, name: id))
          .toList();
      if (!await confirmSubtitleFontLicenses(context, assets)) return;
    }
    if (!mounted) return;
    await manager.enqueue(
      primaryFontLanguage: primaryLanguage,
      secondaryFontLanguage: secondaryLanguage,
      videoId: widget.videoItem.id,
      videoPath: widget.videoItem.path,
      title: widget.videoItem.title,
      primarySubtitlePath: primary,
      secondarySubtitlePath: secondary,
      renderSecondarySubtitle: secondary != null,
      continuousSubtitle: _continuousSubtitle,
      embedSoftSubtitles: embedSoftSubtitles,
      softSubtitleOnly: softOnly,
      softSubtitleUseSourceQuality: _softSubtitleUseSourceQuality,
      softSubtitleTracks: softTracks,
      resolution: _resolution,
      renderMode: SubtitleDebugSession.instance.usesPresets
          ? VideoComposeRenderMode.precise
          : _renderMode,
      subtitlePreset: SubtitleDebugSession.instance.preset,
      subtitleStyle: landscapeStyle,
      subtitleStylePortrait: portraitStyle,
      subtitleAlignment: composeAlignment,
      subtitlePlacement: composePlacement,
      splitSubtitleByLine: settings.splitSubtitleByLine,
      customOutputPath: effectiveOutputPath,
    );
  }

  Future<bool> _confirmOnlineMaterializationIfNeeded() async {
    if (!itemNeedsOnlineMaterialization(
      source: widget.videoItem.sourceRef,
      path: widget.videoItem.path,
    )) {
      return true;
    }
    final library = context.read<LibraryService>();
    try {
      final height = _heightFromResolution(_resolution);
      final estimate = await library.estimateOnlineMediaMaterialization(
        widget.videoItem.id,
        MediaMaterializationRequirement.completeMedia,
        targetHeight: height <= 0 ? null : height,
      );
      if (!estimate.requiresVideoDownload || !mounted) return true;
      final size = estimate.estimatedBytes == null
          ? '大小暂时无法确定'
          : '预计 ${LibraryService.formatSize(estimate.estimatedBytes!)}';
      return await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: const Text('需要准备本地视频素材'),
              content: Text(
                '视频合成需要先下载 ${estimate.qualityLabel} 音视频素材（$size）。\n\n'
                '素材会归属于当前卡片，后续合成和 OCR 可复用，并计入回收站可释放空间。',
              ),
              actions: [
                DesktopButtonClickRegion(
                  child: TextButton(
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: const Text('取消'),
                  ),
                ),
                DesktopButtonClickRegion(
                  child: FilledButton(
                    onPressed: () => Navigator.pop(dialogContext, true),
                    child: const Text('下载并继续'),
                  ),
                ),
              ],
            ),
          ) ??
          false;
    } catch (error) {
      if (mounted) {
        AppToast.show('无法获取在线视频素材信息：$error', type: AppToastType.error);
      }
      return false;
    }
  }

  Future<bool> _ensureAndroidExternalStoragePermission({
    required bool requestFromUser,
  }) async {
    if (!Platform.isAndroid) return true;
    final allFilesStatus = await Permission.manageExternalStorage.status;
    final permission = composeSharedStoragePermission(allFilesStatus);
    if (await permission.isGranted) return true;
    if (!requestFromUser) return false;
    if ((await permission.request()).isGranted) return true;
    if (!mounted) return false;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2C2C2C),
          title: const Text('需要存储权限', style: TextStyle(color: Colors.white)),
          content: Text(
            permission == Permission.storage
                ? '要保存到所选公共目录，请在系统设置中授予存储读写权限。'
                : '要保存到所选公共目录，请在系统设置中授予“管理所有文件”权限。',
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            DesktopButtonClickRegion(
              child: TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
            ),
            DesktopButtonClickRegion(
              child: TextButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  await openAppSettings();
                },
                child: const Text('去设置'),
              ),
            ),
          ],
        );
      },
    );
    return await permission.isGranted;
  }

  Future<bool> _androidOutputNeedsStoragePermission(String outputPath) async {
    final owned = <String>[];
    try {
      final directories = await getExternalStorageDirectories();
      owned.addAll(directories?.map((directory) => directory.path) ?? const []);
    } catch (_) {}
    try {
      final directories = await getExternalCacheDirectories();
      owned.addAll(directories?.map((directory) => directory.path) ?? const []);
    } catch (_) {}
    return composeOutputRequiresAllFilesPermission(
      outputPath,
      appOwnedDirectories: owned,
    );
  }

  void _showSoftSubtitleHelp() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2C2C2C),
          title: const Text('软字幕内嵌说明', style: TextStyle(color: Colors.white)),
          content: const Text(
            '开启“软字幕内嵌”后，合成完成的视频会额外内置当前选择的主字幕和副字幕轨道，播放器可切换或关闭字幕。\n\n开启“仅合成软字幕”后，将不再把字幕烧录到画面中，只保留可切换的内嵌字幕轨道。',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            DesktopButtonClickRegion(
              child: TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('我知道了'),
              ),
            ),
          ],
        );
      },
    );
  }

  Duration get _fastTransitionDuration =>
      _animateVisibility && !MediaQuery.disableAnimationsOf(context)
      ? const Duration(milliseconds: 120)
      : Duration.zero;

  void _openSubtitleManager() {
    final callback = widget.onOpenSubtitleManager;
    if (callback == null) {
      AppToast.show('字幕管理区暂不可用', type: AppToastType.info);
      return;
    }
    callback();
  }

  void _openQueueDialog() {
    showDialog<void>(
      context: context,
      builder: (_) => VideoComposeQueueDialog(
        onPreview: (task) =>
            _openOutputPreview(task.request.outputPath, task.request.title),
        onOpenOutput: _openOutput,
        openOutputLabel: _openOutputLabel,
        requestDeleteOutputPermission: (tasks) async {
          if (!Platform.isAndroid) return true;
          for (final task in tasks) {
            if (await _androidOutputNeedsStoragePermission(
              task.request.outputPath,
            )) {
              return _ensureAndroidExternalStoragePermission(
                requestFromUser: true,
              );
            }
          }
          return true;
        },
      ),
    );
  }

  bool _outputPreviewOpen = false;

  Future<void> _openOutputPreview(String path, String title) async {
    if (!mounted || _outputPreviewOpen) return;
    _outputPreviewOpen = true;
    try {
      final route = AppMaterialPageRoute<void>(
        settings: const RouteSettings(name: '/compose/preview'),
        allowSnapshotting: false,
        builder: (_) => SimpleVideoPlayerScreen(videoPath: path, title: title),
      );
      await Navigator.of(context).push(route);
      await route.completed;
    } finally {
      _outputPreviewOpen = false;
    }
  }

  Widget _buildTopActionButton({
    required VoidCallback? onPressed,
    required IconData icon,
    required String label,
    required double buttonHeight,
    required double textSize,
  }) {
    return DesktopButtonClickRegion(
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          minimumSize: Size.fromHeight(buttonHeight),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          foregroundColor: Colors.white,
          side: const BorderSide(color: Colors.white30),
          textStyle: TextStyle(fontSize: textSize),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: textSize + 2),
            const SizedBox(width: 4),
            Flexible(
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompactSwitchCard({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    required double textSize,
    required double smallSize,
    required double switchScale,
    Widget? child,
    bool showChild = false,
    bool embedChildInLeading = false,
  }) {
    final Widget? effectiveChild = child == null
        ? null
        : AnimatedSize(
            duration: _fastTransitionDuration,
            curve: Curves.easeOutCubic,
            child: showChild
                ? Padding(padding: const EdgeInsets.only(top: 6), child: child)
                : const SizedBox.shrink(),
          );
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white24),
        borderRadius: BorderRadius.circular(8),
        color: Colors.white.withValues(alpha: 0.03),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      title,
                      style: TextStyle(color: Colors.white, fontSize: textSize),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: smallSize,
                      ),
                    ),
                    if (embedChildInLeading && effectiveChild != null)
                      effectiveChild,
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Transform.scale(
                scale: switchScale,
                alignment: Alignment.centerRight,
                child: Switch.adaptive(
                  value: value,
                  onChanged: onChanged,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          if (!embedChildInLeading && effectiveChild != null) effectiveChild,
        ],
      ),
    );
  }

  String _resolutionLabel(VideoComposeResolution value) {
    return switch (value) {
      VideoComposeResolution.source =>
        _sourceResolutionLabel == null
            ? '原始分辨率'
            : '原始分辨率 (${_sourceResolutionLabel!})',
      VideoComposeResolution.p360 => '360P',
      VideoComposeResolution.p480 => '480P',
      VideoComposeResolution.p720 => '720P',
      VideoComposeResolution.p1080 => '1080P',
      VideoComposeResolution.p1440 => '1440P',
      VideoComposeResolution.p2160 => '2160P',
    };
  }

  String _stageText(VideoComposeStage stage, String message, String? error) {
    if (stage == VideoComposeStage.failed &&
        error != null &&
        error.trim().isNotEmpty) {
      return '$message: ${error.trim()}';
    }
    return message;
  }

  Future<void> _openOutput(String path) async {
    final file = File(path);
    if (!file.existsSync()) {
      if (!mounted) return;
      AppToast.show('文件不存在，无法打开', type: AppToastType.error);
      return;
    }
    // The output file is already where the user saved it. Opening that path
    // directly avoids both the folder-wide chooser and a full-file copy.
    final bool opened = await openWithOtherApps(path);
    if (!mounted) return;
    if (!opened) {
      AppToast.show('无法打开输出文件', type: AppToastType.error);
    }
  }

  Widget _buildComposeProgressCard({
    required VideoComposeTaskState task,
    required bool isRunningCurrent,
    required double spacing,
    required double textSize,
    required double smallSize,
  }) {
    final double progress = task.stage == VideoComposeStage.completed
        ? 1
        : task.progress.clamp(0, 1).toDouble();
    final Color progressColor = task.stage == VideoComposeStage.failed
        ? Colors.redAccent
        : (task.stage == VideoComposeStage.completed
              ? const Color(0xFF58D68D)
              : (isRunningCurrent
                    ? const Color(0xFF5B9CFF)
                    : const Color(0xFFFFB55B)));
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: (spacing * 1.6).clamp(10.0, 14.0),
        vertical: (spacing * 1.15).clamp(8.0, 12.0),
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF252930),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: progressColor.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                task.stage == VideoComposeStage.completed
                    ? Icons.check_circle_outline_rounded
                    : (task.stage == VideoComposeStage.failed
                          ? Icons.error_outline_rounded
                          : Icons.movie_filter_outlined),
                size: textSize + 4,
                color: progressColor,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  _stageText(task.stage, task.message, task.error),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: smallSize,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${(progress * 100).round()}%',
                style: TextStyle(
                  color: progressColor,
                  fontSize: smallSize,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: (spacing * 0.85).clamp(5.0, 8.0)),
          TweenAnimationBuilder<double>(
            tween: Tween<double>(end: progress),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            builder: (context, value, child) {
              return ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                  value: value,
                  minHeight: 6,
                  backgroundColor: Colors.black26,
                  valueColor: AlwaysStoppedAnimation<Color>(progressColor),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.sizeOf(context).height;
    final manager = context.read<VideoComposeManager>();
    final settings = context.read<SettingsService>();
    return LayoutBuilder(
      builder: (context, constraints) {
        final h = constraints.maxHeight.isInfinite
            ? screenH
            : constraints.maxHeight;
        final w = constraints.maxWidth;

        final pad = (h * 0.012).clamp(6.0, 10.0);
        final titleSize = (h * 0.018).clamp(12.0, 15.0);
        final textSize = (h * 0.0158).clamp(10.0, 13.0);
        final smallSize = (h * 0.0135).clamp(9.0, 11.0);
        final buttonHeight = (h * 0.045).clamp(30.0, 38.0);
        final spacing = (h * 0.0075).clamp(3.0, 8.0);
        final topBarHeight = (h * 0.043).clamp(30.0, 36.0);
        final topIconSize = (h * 0.023).clamp(16.0, 21.0);
        final actionGap = (h * 0.007).clamp(4.0, 8.0);
        final formPairGap = (spacing * 1.5).clamp(8.0, 12.0);
        final useTwoColumnForm = w >= 360;
        final switchScale = (textSize / 13.0).clamp(0.68, 0.86);

        return Container(
          color: const Color(0xFF1E1E1E),
          padding: EdgeInsets.all(pad),
          child: SidebarValueBuilder<Object>(
            listenable: manager,
            select: () {
              final task = manager.latestTaskForVideo(widget.videoItem.id);
              return (
                task?.taskId,
                task?.stage,
                task?.error,
                task?.completedAt,
                task?.request.outputPath,
                manager.runningTask?.request.videoId == widget.videoItem.id,
              );
            },
            builder: (context, _, child) {
              final latest = manager.latestTaskForVideo(widget.videoItem.id);
              return SingleChildScrollView(
                key: const PageStorageKey('compose-options'),
                padding: EdgeInsets.only(
                  bottom: MediaQuery.viewPaddingOf(context).bottom + spacing,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: topBarHeight,
                      child: Row(
                        children: [
                          SizedBox(
                            width: topBarHeight,
                            height: topBarHeight,
                            child: DesktopButtonClickRegion(
                              child: IconButton(
                                padding: EdgeInsets.zero,
                                onPressed: widget.onBack,
                                iconSize: topIconSize,
                                icon: const Icon(
                                  Icons.arrow_back,
                                  color: Colors.white,
                                ),
                                tooltip: '返回',
                              ),
                            ),
                          ),
                          SizedBox(width: spacing),
                          Expanded(
                            child: Text(
                              '视频合成',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: titleSize,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          SizedBox(
                            height: topBarHeight - 2,
                            child: DesktopButtonClickRegion(
                              child: OutlinedButton.icon(
                                onPressed: _openQueueDialog,
                                icon: Icon(
                                  Icons.queue_play_next,
                                  size: topIconSize - 1,
                                ),
                                label: Text(
                                  '队列',
                                  style: TextStyle(fontSize: smallSize),
                                ),
                                style: OutlinedButton.styleFrom(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: (pad * 0.85).clamp(6.0, 10.0),
                                  ),
                                  foregroundColor: Colors.white70,
                                  side: const BorderSide(color: Colors.white30),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: spacing),
                    Text(
                      widget.videoItem.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: textSize,
                      ),
                    ),
                    if (!_softSubtitleOnly) ...[
                      SizedBox(height: spacing),
                      ListenableBuilder(
                        listenable: SubtitleDebugSession.instance,
                        builder: (context, _) =>
                            SubtitleDebugSession.instance.usesPresets
                            ? Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                child: Text(
                                  '字幕预设：${SubtitleDebugSession.instance.preset!.name} · 精确渲染',
                                  style: TextStyle(
                                    color: Colors.tealAccent,
                                    fontSize: textSize,
                                  ),
                                ),
                              )
                            : _ComposeSelect<VideoComposeRenderMode>(
                                key: const ValueKey(
                                  'compose_render_mode_dropdown',
                                ),
                                value: _renderMode,
                                label: '字幕烧录方式',
                                fontSize: textSize,
                                items: VideoComposeRenderMode.values
                                    .map(
                                      (mode) => _ComposeSelectItem(
                                        value: mode,
                                        label:
                                            mode ==
                                                VideoComposeRenderMode.precise
                                            ? '精确渲染（推荐）'
                                            : '粗略渲染',
                                      ),
                                    )
                                    .toList(),
                                onChanged: (mode) {
                                  setState(() => _renderMode = mode);
                                  settings.updateSetting(
                                    'videoComposeRenderMode',
                                    mode.storageValue,
                                  );
                                },
                              ),
                      ),
                      SizedBox(height: spacing * 0.5),
                      if (useTwoColumnForm)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: AnimatedSwitcher(
                                duration: _fastTransitionDuration,
                                switchInCurve: Curves.easeOutCubic,
                                switchOutCurve: Curves.easeInCubic,
                                child:
                                    !(_softSubtitleOnly &&
                                        _softSubtitleUseSourceQuality)
                                    ? _ComposeSelect<VideoComposeResolution>(
                                        key: const ValueKey(
                                          'resolution_dropdown',
                                        ),
                                        value: _resolution,
                                        label: _sourceResolutionLabel == null
                                            ? '视频分辨率'
                                            : '视频分辨率（原始: $_sourceResolutionLabel）',
                                        fontSize: textSize,
                                        items: VideoComposeResolution.values
                                            .map(
                                              (e) => _ComposeSelectItem(
                                                value: e,
                                                label: _resolutionLabel(e),
                                              ),
                                            )
                                            .toList(),
                                        onChanged: (v) {
                                          setState(() => _resolution = v);
                                          settings.updateSetting(
                                            'videoComposeResolutionHeight',
                                            _heightFromResolution(v),
                                          );
                                        },
                                      )
                                    : const SizedBox.shrink(),
                              ),
                            ),
                            SizedBox(width: formPairGap),
                            Expanded(
                              child: _buildCompactSwitchCard(
                                title: '字幕连续显示',
                                subtitle: '按播放逻辑延长至下一条',
                                value: _continuousSubtitle,
                                onChanged: (v) {
                                  setState(() => _continuousSubtitle = v);
                                  settings.updateSetting(
                                    'videoComposeContinuousSubtitle',
                                    v,
                                  );
                                  _notifyPreviewChanged();
                                },
                                textSize: textSize,
                                smallSize: smallSize,
                                switchScale: switchScale,
                              ),
                            ),
                          ],
                        )
                      else ...[
                        AnimatedSwitcher(
                          duration: _fastTransitionDuration,
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          child:
                              !(_softSubtitleOnly &&
                                  _softSubtitleUseSourceQuality)
                              ? _ComposeSelect<VideoComposeResolution>(
                                  key: const ValueKey('resolution_dropdown'),
                                  value: _resolution,
                                  label: _sourceResolutionLabel == null
                                      ? '视频分辨率'
                                      : '视频分辨率（原始: $_sourceResolutionLabel）',
                                  fontSize: textSize,
                                  items: VideoComposeResolution.values
                                      .map(
                                        (e) => _ComposeSelectItem(
                                          value: e,
                                          label: _resolutionLabel(e),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: (v) {
                                    setState(() => _resolution = v);
                                    settings.updateSetting(
                                      'videoComposeResolutionHeight',
                                      _heightFromResolution(v),
                                    );
                                  },
                                )
                              : const SizedBox.shrink(),
                        ),
                        SizedBox(height: spacing * 0.5),
                        _buildCompactSwitchCard(
                          title: '字幕连续显示',
                          subtitle: '按播放逻辑延长至下一条',
                          value: _continuousSubtitle,
                          onChanged: (v) {
                            setState(() => _continuousSubtitle = v);
                            settings.updateSetting(
                              'videoComposeContinuousSubtitle',
                              v,
                            );
                            _notifyPreviewChanged();
                          },
                          textSize: textSize,
                          smallSize: smallSize,
                          switchScale: switchScale,
                        ),
                      ],
                      SizedBox(height: spacing * 0.5),
                      if (useTwoColumnForm)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: _ComposeSelect<String>(
                                key: const ValueKey('primary_dropdown'),
                                value: _primaryPath,
                                label: '主字幕渲染',
                                fontSize: textSize,
                                items: _subtitleOptions.entries
                                    .map(
                                      (e) => _ComposeSelectItem(
                                        value: e.key,
                                        label: e.value,
                                      ),
                                    )
                                    .toList(),
                                onChanged: (v) {
                                  setState(() {
                                    _primarySelectionEdited = true;
                                    _primaryPath = v;
                                  });
                                  settings.updateSetting(
                                    'videoComposePrimarySubtitlePath',
                                    v,
                                  );
                                  _notifyPreviewChanged();
                                },
                              ),
                            ),
                            SizedBox(width: formPairGap),
                            Expanded(
                              child: _ComposeSelect<String>(
                                key: const ValueKey('secondary_dropdown'),
                                value: _secondaryPath ?? '',
                                label: '副字幕渲染',
                                fontSize: textSize,
                                items: <_ComposeSelectItem<String>>[
                                  const _ComposeSelectItem<String>(
                                    value: '',
                                    label: '无',
                                  ),
                                  ..._subtitleOptions.entries.map(
                                    (e) => _ComposeSelectItem(
                                      value: e.key,
                                      label: e.value,
                                    ),
                                  ),
                                ],
                                onChanged: (v) {
                                  setState(() {
                                    _secondarySelectionEdited = true;
                                    _secondaryPath = v.isEmpty ? null : v;
                                  });
                                  settings.updateSetting(
                                    'videoComposeSecondarySubtitlePath',
                                    v,
                                  );
                                  _notifyPreviewChanged();
                                },
                              ),
                            ),
                          ],
                        )
                      else ...[
                        _ComposeSelect<String>(
                          key: const ValueKey('primary_dropdown'),
                          value: _primaryPath,
                          label: '主字幕渲染',
                          fontSize: textSize,
                          items: _subtitleOptions.entries
                              .map(
                                (e) => _ComposeSelectItem(
                                  value: e.key,
                                  label: e.value,
                                ),
                              )
                              .toList(),
                          onChanged: (v) {
                            setState(() {
                              _primarySelectionEdited = true;
                              _primaryPath = v;
                            });
                            settings.updateSetting(
                              'videoComposePrimarySubtitlePath',
                              v,
                            );
                            _notifyPreviewChanged();
                          },
                        ),
                        SizedBox(height: spacing * 0.5),
                        _ComposeSelect<String>(
                          key: const ValueKey('secondary_dropdown'),
                          value: _secondaryPath ?? '',
                          label: '副字幕渲染',
                          fontSize: textSize,
                          items: <_ComposeSelectItem<String>>[
                            const _ComposeSelectItem<String>(
                              value: '',
                              label: '无',
                            ),
                            ..._subtitleOptions.entries.map(
                              (e) => _ComposeSelectItem(
                                value: e.key,
                                label: e.value,
                              ),
                            ),
                          ],
                          onChanged: (v) {
                            setState(() {
                              _secondarySelectionEdited = true;
                              _secondaryPath = v.isEmpty ? null : v;
                            });
                            settings.updateSetting(
                              'videoComposeSecondarySubtitlePath',
                              v,
                            );
                            _notifyPreviewChanged();
                          },
                        ),
                      ],
                    ],
                    if (_softSubtitleOnly) ...[
                      SizedBox(height: spacing),
                      AnimatedSwitcher(
                        duration: _fastTransitionDuration,
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        child:
                            !(_softSubtitleOnly &&
                                _softSubtitleUseSourceQuality)
                            ? _ComposeSelect<VideoComposeResolution>(
                                key: const ValueKey('resolution_dropdown'),
                                value: _resolution,
                                label: _sourceResolutionLabel == null
                                    ? '视频分辨率'
                                    : '视频分辨率（原始: $_sourceResolutionLabel）',
                                fontSize: textSize,
                                items: VideoComposeResolution.values
                                    .map(
                                      (e) => _ComposeSelectItem(
                                        value: e,
                                        label: _resolutionLabel(e),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (v) {
                                  setState(() => _resolution = v);
                                  settings.updateSetting(
                                    'videoComposeResolutionHeight',
                                    _heightFromResolution(v),
                                  );
                                },
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                    SizedBox(height: spacing * 0.5),
                    Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.white24),
                        borderRadius: BorderRadius.circular(8),
                        color: Colors.white.withValues(alpha: 0.03),
                      ),
                      padding: EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: spacing * 0.2,
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Padding(
                                  padding: EdgeInsets.only(
                                    right: actionGap * 0.5,
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              '软字幕内嵌',
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: textSize,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              '合成后额外内嵌主/副字幕轨道',
                                              style: TextStyle(
                                                color: Colors.white54,
                                                fontSize: smallSize,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Transform.scale(
                                        scale: switchScale,
                                        alignment: Alignment.centerRight,
                                        child: Switch.adaptive(
                                          value: _embedSoftSubtitles,
                                          onChanged: (v) {
                                            setState(() {
                                              _embedSoftSubtitles = v;
                                              if (!v) {
                                                _softSubtitleOnly = false;
                                              }
                                            });
                                            settings.updateSetting(
                                              'videoComposeEmbedSoftSubtitles',
                                              v,
                                            );
                                            if (!v) {
                                              settings.updateSetting(
                                                'videoComposeSoftSubtitleOnly',
                                                false,
                                              );
                                            }
                                            _notifyPreviewChanged();
                                          },
                                          materialTapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              Text(
                                '字幕 ${widget.availableSubtitleMap.length}',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: smallSize,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              SizedBox(width: actionGap),
                              DesktopButtonClickRegion(
                                child: OutlinedButton.icon(
                                  onPressed: _openSubtitleManager,
                                  style: OutlinedButton.styleFrom(
                                    minimumSize: Size(
                                      0,
                                      (buttonHeight * 0.82).clamp(28.0, 34.0),
                                    ),
                                    padding: EdgeInsets.symmetric(
                                      horizontal: (pad * 0.6).clamp(5.0, 8.0),
                                    ),
                                    foregroundColor: Colors.white70,
                                    side: const BorderSide(
                                      color: Colors.white24,
                                    ),
                                    textStyle: TextStyle(fontSize: smallSize),
                                  ),
                                  icon: Icon(
                                    Icons.subtitles_outlined,
                                    size: smallSize + 4,
                                  ),
                                  label: const Text('管理'),
                                ),
                              ),
                            ],
                          ),
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            visualDensity: const VisualDensity(
                              horizontal: 0,
                              vertical: -4,
                            ),
                            dense: true,
                            value: _softSubtitleOnly,
                            title: Text(
                              '仅合成软字幕',
                              style: TextStyle(
                                color: _embedSoftSubtitles
                                    ? Colors.white
                                    : Colors.white54,
                                fontSize: textSize,
                              ),
                            ),
                            subtitle: Text(
                              '不烧录到画面，仅保留内嵌字幕轨道',
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: smallSize,
                              ),
                            ),
                            onChanged: _embedSoftSubtitles
                                ? (v) {
                                    final value = v ?? false;
                                    setState(() => _softSubtitleOnly = value);
                                    settings.updateSetting(
                                      'videoComposeSoftSubtitleOnly',
                                      value,
                                    );
                                    _notifyPreviewChanged();
                                  }
                                : null,
                          ),
                          AnimatedSwitcher(
                            duration: _fastTransitionDuration,
                            switchInCurve: Curves.easeOutCubic,
                            switchOutCurve: Curves.easeInCubic,
                            child: _softSubtitleOnly
                                ? CheckboxListTile(
                                    key: const ValueKey(
                                      'source_quality_checkbox',
                                    ),
                                    contentPadding: EdgeInsets.zero,
                                    visualDensity: const VisualDensity(
                                      horizontal: 0,
                                      vertical: -4,
                                    ),
                                    dense: true,
                                    value: _softSubtitleUseSourceQuality,
                                    title: Text(
                                      '采用视频原画质',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: textSize,
                                      ),
                                    ),
                                    subtitle: Text(
                                      '仅封装字幕轨道，不重编码视频',
                                      style: TextStyle(
                                        color: Colors.white54,
                                        fontSize: smallSize,
                                      ),
                                    ),
                                    onChanged: (v) {
                                      final value = v ?? true;
                                      setState(
                                        () => _softSubtitleUseSourceQuality =
                                            value,
                                      );
                                      settings.updateSetting(
                                        'videoComposeSoftSubtitleUseSourceQuality',
                                        value,
                                      );
                                    },
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: spacing),
                    if (_showCustomOutputDirectory) ...[
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '自定义输出目录',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: textSize,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  _customOutputPath ??
                                      _defaultOutputDirectoryLabel,
                                  style: TextStyle(
                                    color: Colors.white54,
                                    fontSize: smallSize,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          DesktopButtonClickRegion(
                            child: IconButton(
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              icon: const Icon(
                                Icons.folder_open,
                                color: Colors.blueAccent,
                              ),
                              onPressed: () async {
                                String? selectedDirectory = await FilePicker
                                    .platform
                                    .getDirectoryPath(dialogTitle: '选择保存目录');
                                if (selectedDirectory != null && mounted) {
                                  setState(() {
                                    _customOutputPath = selectedDirectory;
                                  });
                                  settings.updateSetting(
                                    'videoComposeCustomOutputPath',
                                    selectedDirectory,
                                  );
                                }
                              },
                            ),
                          ),
                          if (Platform.isAndroid)
                            DesktopButtonClickRegion(
                              child: IconButton(
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                icon: const Icon(
                                  Icons.security_outlined,
                                  color: Colors.orangeAccent,
                                ),
                                onPressed: () async {
                                  await _ensureAndroidExternalStoragePermission(
                                    requestFromUser: true,
                                  );
                                },
                              ),
                            ),
                        ],
                      ),
                      if (Platform.isAndroid) ...[
                        SizedBox(height: spacing * 0.4),
                        Text(
                          '默认输出目录: /storage/emulated/0/Download/ComposedVideos',
                          style: TextStyle(
                            color: Colors.greenAccent,
                            fontSize: smallSize,
                          ),
                        ),
                      ],
                      SizedBox(height: spacing * 1.5),
                    ] else
                      SizedBox(height: spacing * 0.5),
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: Colors.white.withValues(alpha: 0.035),
                        border: Border.all(color: Colors.white24),
                      ),
                      padding: EdgeInsets.all((pad * 0.45).clamp(4.0, 8.0)),
                      child: Row(
                        children: [
                          Expanded(
                            child: _buildTopActionButton(
                              onPressed: _openSubtitleManager,
                              icon: Icons.subtitles,
                              label: '字幕管理',
                              buttonHeight: buttonHeight,
                              textSize: textSize,
                            ),
                          ),
                          SizedBox(width: actionGap * 0.8),
                          Expanded(
                            child: _buildTopActionButton(
                              onPressed: _showSoftSubtitleHelp,
                              icon: Icons.info_outline,
                              label: '软字幕说明',
                              buttonHeight: buttonHeight,
                              textSize: textSize,
                            ),
                          ),
                          SizedBox(width: actionGap * 0.8),
                          Expanded(
                            child: _buildTopActionButton(
                              onPressed: _softSubtitleOnly
                                  ? null
                                  : widget.onOpenSubtitleStyle,
                              icon: Icons.style,
                              label: '字幕样式',
                              buttonHeight: buttonHeight,
                              textSize: textSize,
                            ),
                          ),
                          SizedBox(width: actionGap * 0.8),
                          Expanded(
                            child: _buildTopActionButton(
                              onPressed: _openQueueDialog,
                              icon: Icons.queue_play_next,
                              label: '查看队列',
                              buttonHeight: buttonHeight,
                              textSize: textSize,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: spacing),
                    if (latest != null)
                      SidebarValueBuilder<Object>(
                        listenable: manager,
                        select: () => (
                          manager.latestTaskForVideo(widget.videoItem.id),
                          manager.materializationProgressForTask(latest.taskId),
                          manager.runningTask?.request.videoId ==
                              widget.videoItem.id,
                        ),
                        builder: (context, _, _) {
                          final task = manager.latestTaskForVideo(
                            widget.videoItem.id,
                          );
                          if (task == null) return const SizedBox.shrink();
                          final progress = manager
                              .materializationProgressForTask(task.taskId);
                          return Padding(
                            padding: EdgeInsets.only(bottom: spacing),
                            child: RepaintBoundary(
                              child: progress != null
                                  ? MediaMaterializationProgressCard(
                                      progress: progress,
                                      padding: EdgeInsets.symmetric(
                                        horizontal: (spacing * 1.6).clamp(
                                          10.0,
                                          14.0,
                                        ),
                                        vertical: (spacing * 1.15).clamp(
                                          8.0,
                                          12.0,
                                        ),
                                      ),
                                    )
                                  : _buildComposeProgressCard(
                                      task: task,
                                      isRunningCurrent:
                                          manager
                                              .runningTask
                                              ?.request
                                              .videoId ==
                                          widget.videoItem.id,
                                      spacing: spacing,
                                      textSize: textSize,
                                      smallSize: smallSize,
                                    ),
                            ),
                          );
                        },
                      ),
                    if (_preparingSubtitleOptions)
                      const Padding(
                        key: ValueKey('compose-subtitle-preparation'),
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            SizedBox.square(
                              dimension: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 8),
                            Flexible(child: Text('正在准备内嵌字幕…')),
                          ],
                        ),
                      ),
                    if (_subtitlePreparationError != null)
                      DesktopButtonClickRegion(
                        child: TextButton.icon(
                          key: const ValueKey('compose-subtitle-retry'),
                          onPressed: _prepareSubtitleOptions,
                          icon: const Icon(Icons.refresh),
                          label: const Text('内嵌字幕准备失败，点击重试'),
                        ),
                      ),
                    DesktopButtonClickRegion(
                      child: ElevatedButton.icon(
                        key: const ValueKey('compose-enqueue'),
                        onPressed: _enqueuePending || _preparingSubtitleOptions
                            ? null
                            : _enqueueCompose,
                        style: ElevatedButton.styleFrom(
                          minimumSize: Size.fromHeight(buttonHeight),
                          padding: EdgeInsets.zero,
                          backgroundColor: Colors.blueAccent,
                          foregroundColor: Colors.white,
                          textStyle: TextStyle(
                            fontSize: textSize,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        icon: Icon(
                          Icons.movie_creation_outlined,
                          size: textSize + 4,
                        ),
                        label: const Text('加入合成队列'),
                      ),
                    ),
                    SizedBox(height: spacing),
                    if (latest != null) ...[
                      if (latest.stage == VideoComposeStage.completed ||
                          latest.stage == VideoComposeStage.failed)
                        SelectableText(
                          latest.stage == VideoComposeStage.completed
                              ? '输出位置：${latest.request.outputPath}'
                              : '失败任务的输出位置：${latest.request.outputPath}',
                          style: TextStyle(
                            color: Colors.white54,
                            fontSize: smallSize,
                          ),
                        ),
                      if (latest.stage == VideoComposeStage.completed &&
                          File(latest.request.outputPath).existsSync()) ...[
                        SizedBox(height: spacing * 0.6),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                _savedOutputHint,
                                style: TextStyle(
                                  color: Colors.greenAccent,
                                  fontSize: smallSize,
                                ),
                              ),
                            ),
                            DesktopButtonClickRegion(
                              child: IconButton(
                                icon: const Icon(
                                  Icons.play_circle_outline,
                                  color: Colors.white,
                                ),
                                tooltip: '预览',
                                iconSize: 28,
                                onPressed: () => _openOutputPreview(
                                  latest.request.outputPath,
                                  latest.request.title,
                                ),
                              ),
                            ),
                            DesktopButtonClickRegion(
                              child: IconButton(
                                icon: const Icon(
                                  Icons.open_in_new_outlined,
                                  color: Colors.white,
                                ),
                                tooltip: _openOutputLabel,
                                iconSize: 28,
                                onPressed: () async {
                                  await _openOutput(latest.request.outputPath);
                                },
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}
