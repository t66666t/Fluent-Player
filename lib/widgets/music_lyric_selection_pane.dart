import 'dart:async';
import 'dart:ui' show BoxWidthStyle;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../controllers/music_lyric_selection_controller.dart';
import '../models/music_lyric_display_mode.dart';
import '../models/music_lyric_selection_document.dart';
import '../models/music_lyric_workspace_layout.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Read-only continuous lyric text. One controller, one selection and one
/// scroll view, so a drag can cross lines, roles and the parts not yet built
/// as separate rows.
class MusicLyricDocumentController extends TextEditingController {
  MusicLyricSelectionDocument document = MusicLyricSelectionDocument.empty;
  TextStyle primaryStyle = const TextStyle();
  TextStyle secondaryStyle = const TextStyle();
  TextStyle backgroundStyle = const TextStyle();
  TextStyle romanizationStyle = const TextStyle();
  String? highlightedGroupId;

  void adopt(MusicLyricSelectionDocument next, TextSelection selection) {
    document = next;
    value = TextEditingValue(
      text: next.fullText,
      selection: next.snap(selection),
    );
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    return document.buildTextSpan(
      primaryStyle: primaryStyle,
      secondaryStyle: secondaryStyle,
      backgroundStyle: backgroundStyle,
      romanizationStyle: romanizationStyle,
      highlightedGroupId: highlightedGroupId,
    );
  }
}

class MusicLyricSelectionPane extends StatefulWidget {
  final MusicLyricSelectionController controller;
  final MusicLyricEffectiveDisplay display;
  final ValueChanged<MusicLyricTrackDisplayMode> onModeChanged;
  final bool sourceMissing;
  final String? trackTitle;
  final bool mergeTitle;
  final VoidCallback? onReload;
  final Widget? footer;

  const MusicLyricSelectionPane({
    super.key,
    required this.controller,
    required this.display,
    required this.onModeChanged,
    this.sourceMissing = false,
    this.trackTitle,
    this.mergeTitle = false,
    this.onReload,
    this.footer,
  });

  @override
  State<MusicLyricSelectionPane> createState() =>
      MusicLyricSelectionPaneState();
}

class MusicLyricSelectionPaneState extends State<MusicLyricSelectionPane>
    implements TextSelectionGestureDetectorBuilderDelegate {
  final MusicLyricDocumentController _text = MusicLyricDocumentController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _focus = FocusNode();
  final GlobalKey<EditableTextState> _textKey = GlobalKey<EditableTextState>();
  late final TextSelectionGestureDetectorBuilder _selectionGestures;
  int _appliedGeneration = -1;
  bool _wasAwaitingPointer = false;
  bool _revealed = false;
  String _appliedKey = '';
  Size _lastSize = Size.zero;
  bool _menuOpen = false;
  bool _selectBySentence = false;
  MusicLyricTextGroup? _sentenceAnchor;

  @override
  GlobalKey<EditableTextState> get editableTextKey => _textKey;

  @override
  bool get forcePressEnabled =>
      Theme.of(context).platform == TargetPlatform.iOS;

  @override
  bool get selectionEnabled => true;

  @override
  void initState() {
    super.initState();
    _selectionGestures = TextSelectionGestureDetectorBuilder(delegate: this);
    widget.controller.addListener(_onController);
    _text.addListener(_onTextSelection);
    _wasAwaitingPointer = widget.controller.awaitingPointerRelease;
    _adopt(jump: true);
  }

  @override
  void didUpdateWidget(covariant MusicLyricSelectionPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onController);
      widget.controller.addListener(_onController);
    }
    _adopt(jump: false);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onController);
    _text.removeListener(_onTextSelection);
    _text.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void closeTextMenu() {
    ContextMenuController.removeAny();
    if (_menuOpen) {
      _menuOpen = false;
      widget.controller.setTextMenuOpen(false);
    }
  }

  void _onController() {
    if (!mounted) return;
    final released =
        _wasAwaitingPointer && !widget.controller.awaitingPointerRelease;
    _wasAwaitingPointer = widget.controller.awaitingPointerRelease;
    _adopt(jump: false);
    if (released) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_revealSelection());
      });
    }
    setState(() {});
  }

  void _onTextSelection() {
    final controller = widget.controller;
    if (!controller.isActive) return;
    final next = _text.selection;
    if (next == controller.selection) return;
    controller.updateSelection(next);
  }

  void _selectEntireDocument() {
    closeTextMenu();
    _sentenceAnchor = null;
    widget.controller.selectAll();
  }

  void _toggleSentenceSelection() {
    closeTextMenu();
    setState(() {
      _selectBySentence = !_selectBySentence;
      _sentenceAnchor = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  void _selectSentence(TapUpDetails details) {
    final editable = _textKey.currentState;
    if (editable == null) return;
    final render = editable.renderEditable;
    final offset = render.getPositionForPoint(details.globalPosition).offset;
    final groups = widget.controller.document.groups;
    MusicLyricTextGroup? tapped;
    for (final group in groups) {
      if (offset >= group.documentStart && offset <= group.documentEnd) {
        tapped = group;
        break;
      }
    }
    if (tapped == null) return;
    // Ignore empty space below the document, which maps to its final offset.
    final boxes = render.getBoxesForSelection(
      TextSelection(
        baseOffset: tapped.documentStart,
        extentOffset: tapped.documentEnd,
      ),
    );
    final local = render.globalToLocal(details.globalPosition);
    if (!boxes.any((box) => local.dy >= box.top && local.dy <= box.bottom)) {
      return;
    }
    closeTextMenu();
    _focus.requestFocus();
    final anchor = _sentenceAnchor ?? tapped;
    final start = anchor.documentStart < tapped.documentStart
        ? anchor.documentStart
        : tapped.documentStart;
    final end = anchor.documentEnd > tapped.documentEnd
        ? anchor.documentEnd
        : tapped.documentEnd;
    widget.controller.updateSelection(
      TextSelection(baseOffset: start, extentOffset: end),
    );
    // Two taps complete one range; the next tap starts a new range.
    _sentenceAnchor = _sentenceAnchor == null ? tapped : null;
  }

  void _adopt({required bool jump}) {
    final controller = widget.controller;
    final key = '${controller.generation}|${controller.document.documentKey}';
    final changed = key != _appliedKey;
    if (changed) {
      _sentenceAnchor = null;
      _revealed = false;
      _appliedGeneration = controller.generation;
      _appliedKey = key;
      _text.adopt(controller.document, controller.selection);
      if (jump || controller.phase == MusicLyricSelectionPhase.selecting) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || controller.generation != _appliedGeneration) return;
          if (!controller.awaitingPointerRelease) {
            _revealSelection();
          }
        });
      }
    } else if (_text.selection != controller.selection) {
      _text.selection = controller.selection;
    }
  }

  Future<void> _revealSelection() async {
    if (_revealed) return;
    _revealed = true;
    final controller = widget.controller;
    if (!mounted || controller.document.isEmpty) return;
    _focus.requestFocus();
    await _scrollAnchor(controller.anchor);
    if (!mounted || controller.generation != _appliedGeneration) return;
    final selection = controller.selection;
    if (selection.isCollapsed) return;
    final editable = _textKey.currentState;
    if (editable == null) return;
    // A selection that already exists when the field is created does not build
    // the handle overlay. Pushing it through the same user-selection path as
    // the subtitle article does.
    editable.userUpdateTextEditingValue(
      _text.value.copyWith(selection: const TextSelection.collapsed(offset: 0)),
      SelectionChangedCause.tap,
    );
    editable.userUpdateTextEditingValue(
      _text.value.copyWith(selection: selection),
      SelectionChangedCause.longPress,
    );
  }

  Future<void> _scrollAnchor(MusicLyricReadingAnchor anchor) async {
    if (!_scroll.hasClients) return;
    final metrics = MusicLyricSelectionMetrics.forConstraints(_lastSize);
    final width =
        _textKey.currentState?.renderEditable.size.width ??
        (_lastSize.width -
                metrics.margin * 4 -
                metrics.textHorizontalPadding * 2)
            .clamp(1.0, double.infinity);
    final painter = TextPainter(
      text: _text.buildTextSpan(
        context: context,
        style: _text.primaryStyle,
        withComposing: false,
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: width);
    final caret = painter.getOffsetForCaret(
      TextPosition(offset: anchor.documentOffset.clamp(0, _text.text.length)),
      Rect.zero,
    );
    painter.dispose();
    final viewport = _scroll.position.viewportDimension;
    final target = (caret.dy - viewport * anchor.viewportFraction).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    if ((_scroll.offset - target).abs() < 1) return;
    _scroll.jumpTo(target);
  }

  TextStyle _style({
    required double size,
    required FontWeight weight,
    required double height,
    required double alpha,
    required String sample,
  }) {
    final chinese = _containsCjk(sample);
    return TextStyle(
      fontFamily: chinese ? 'Noto Sans SC' : 'Inter',
      fontSize: size,
      fontWeight: weight,
      height: height,
      color: Colors.white.withValues(alpha: alpha),
    );
  }

  bool _containsCjk(String text) {
    for (final rune in text.runes) {
      if (rune >= 0x4E00 && rune <= 0x9FFF) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final highContrast = MediaQuery.highContrastOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        if (_lastSize != size) {
          final previous = _lastSize;
          _lastSize = size;
          if (previous != Size.zero && previous != size) {
            closeTextMenu();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) unawaited(_scrollAnchor(controller.anchor));
            });
          }
        }
        final metrics = MusicLyricSelectionMetrics.forConstraints(size);
        final sample = controller.document.fullText;
        _text.primaryStyle = _style(
          size: metrics.primarySize,
          weight: FontWeight.w400,
          height: 1.65,
          alpha: 0.95,
          sample: sample,
        );
        _text.secondaryStyle = _style(
          size: metrics.secondarySize,
          weight: FontWeight.w400,
          height: 1.65,
          alpha: 0.76,
          sample: sample,
        );
        _text.backgroundStyle = _style(
          size: metrics.secondarySize,
          weight: FontWeight.w400,
          height: 1.65,
          alpha: 0.84,
          sample: sample,
        );
        _text.romanizationStyle = _style(
          size: metrics.secondarySize,
          weight: FontWeight.w400,
          height: 1.65,
          alpha: 0.7,
          sample: sample,
        );
        final tier = musicLyricSelectionChromeTier(
          innerWidth: constraints.maxWidth - metrics.margin * 2,
          textScale: MediaQuery.textScalerOf(context).scale(1),
        );
        final panelColor = highContrast
            ? const Color(0xFF101218)
            : const Color(0xFF17191F).withValues(alpha: 0.94);
        final theme = Theme.of(context);
        final body = Theme(
          data: theme.copyWith(
            brightness: Brightness.dark,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF0A84FF),
              brightness: Brightness.dark,
            ),
            textTheme: theme.textTheme.apply(
              fontFamily: 'Noto Sans SC',
              bodyColor: Colors.white,
              displayColor: Colors.white,
            ),
          ),
          child: _panel(
            metrics: metrics,
            tier: tier,
            panelColor: panelColor,
            controller: controller,
          ),
        );
        if (reduceMotion) return body;
        return AnimatedOpacity(
          opacity: 1,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          child: body,
        );
      },
    );
  }

  Widget _panel({
    required MusicLyricSelectionMetrics metrics,
    required MusicLyricSelectionChromeTier tier,
    required Color panelColor,
    required MusicLyricSelectionController controller,
  }) {
    final tight = _lastSize.height < 280;
    return Padding(
      padding: EdgeInsets.all(metrics.margin),
      child: DecoratedBox(
        key: const ValueKey('music-lyric-selection-panel'),
        decoration: BoxDecoration(
          color: panelColor,
          borderRadius: BorderRadius.circular(metrics.radius),
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: metrics.margin),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _toolbar(metrics, tier, tight),
              if (widget.sourceMissing) _missingBanner(),
              Expanded(
                child: AbsorbPointer(
                  absorbing: controller.awaitingPointerRelease,
                  child: _field(metrics),
                ),
              ),
              ?widget.footer,
              _actions(metrics),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toolbar(
    MusicLyricSelectionMetrics metrics,
    MusicLyricSelectionChromeTier tier,
    bool tight,
  ) {
    final textScaler = MediaQuery.textScalerOf(context);
    final toolbarHeight =
        (textScaler.scale(metrics.titleSize) * 1.5 +
                (widget.mergeTitle ? textScaler.scale(12) * 1.5 : 0) +
                8)
            .clamp(metrics.toolbarHeight, double.infinity);
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '歌词选取',
          style: TextStyle(
            fontFamily: 'Noto Sans SC',
            fontSize: metrics.titleSize,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        if (widget.mergeTitle && (widget.trackTitle?.isNotEmpty ?? false))
          Text(
            widget.trackTitle!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'Noto Sans SC',
              fontSize: 12,
              color: Colors.white.withValues(alpha: 0.7),
            ),
          ),
      ],
    );
    final done = _textButton(
      '完成',
      widget.controller.finish,
      const ValueKey('music-lyric-selection-done'),
    );
    // Updates belong in the fixed-height toolbar. Inserting a banner above
    // the document while a selection gesture is active moves its viewport.
    final reload = DesktopButtonClickRegion(
      child: IconButton(
        tooltip: '歌词已更新，重新载入',
        onPressed: widget.onReload,
        icon: const Icon(Icons.refresh, size: 20),
      ),
    );
    final modeControl = tight
        ? _modeMenu(compactLabel: true)
        : switch (tier) {
            MusicLyricSelectionChromeTier.wide => _segmented(),
            MusicLyricSelectionChromeTier.stacked => _segmented(),
            MusicLyricSelectionChromeTier.menu => _modeMenu(compactLabel: true),
          };
    if (tier == MusicLyricSelectionChromeTier.wide && !tight) {
      return SizedBox(
        height: toolbarHeight,
        child: Row(
          children: [
            title,
            const Spacer(),
            modeControl,
            const SizedBox(width: 8),
            if (widget.controller.contentStale) reload,
            done,
          ],
        ),
      );
    }
    return Column(
      children: [
        SizedBox(
          height: toolbarHeight,
          child: Row(
            children: [
              Expanded(child: title),
              if (tight) modeControl,
              if (widget.controller.contentStale) reload,
              done,
            ],
          ),
        ),
        if (!tight) Align(alignment: Alignment.centerLeft, child: modeControl),
      ],
    );
  }

  Widget _segmented() {
    return SegmentedButton<MusicLyricTrackDisplayMode>(
      showSelectedIcon: false,
      segments: [
        for (final mode in MusicLyricTrackDisplayMode.values)
          ButtonSegment(
            value: mode,
            label: Text(mode.label),
            enabled: widget.display.allows(mode),
            tooltip: widget.display.allows(mode)
                ? mode.label
                : mode == MusicLyricTrackDisplayMode.secondary
                ? '当前无副字幕'
                : '当前无主字幕',
          ),
      ],
      selected: {widget.display.effective},
      onSelectionChanged: (selection) {
        final mode = selection.first;
        if (!widget.display.allows(mode)) return;
        widget.onModeChanged(mode);
      },
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        textStyle: WidgetStateProperty.all(
          const TextStyle(
            fontFamily: 'Noto Sans SC',
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        minimumSize: WidgetStateProperty.all(const Size(44, 36)),
      ),
    );
  }

  Widget _modeMenu({required bool compactLabel}) {
    final current = widget.display.effective;
    return CapsulePopupMenuButton<MusicLyricTrackDisplayMode>(
      tooltip: '显示方式',
      onSelected: (mode) {
        if (!widget.display.allows(mode)) return;
        widget.onModeChanged(mode);
      },
      itemBuilder: (context) => [
        for (final mode in MusicLyricTrackDisplayMode.values)
          PopupMenuItem(
            value: mode,
            enabled: widget.display.allows(mode),
            child: Text(
              widget.display.allows(mode)
                  ? mode.label
                  : '${mode.label}（${mode == MusicLyricTrackDisplayMode.secondary ? '当前无副字幕' : '当前无主字幕'}）',
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Text(
          compactLabel ? '显示：${current.label} ▾' : '${current.label} ▾',
          style: const TextStyle(
            fontFamily: 'Noto Sans SC',
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _field(MusicLyricSelectionMetrics metrics) {
    final controller = widget.controller;
    if (controller.document.isEmpty) {
      return const Center(
        child: Text('当前字幕没有可选取文字', style: TextStyle(color: Color(0xBFFFFFFF))),
      );
    }
    return Theme(
      data: Theme.of(context).copyWith(
        textSelectionTheme: const TextSelectionThemeData(
          selectionColor: Color(0x4D0A84FF),
          selectionHandleColor: Color(0xFF0A84FF),
          cursorColor: Color(0xFF0A84FF),
        ),
      ),
      child: Padding(
        key: const ValueKey('music-lyric-selection-field'),
        padding: EdgeInsets.only(
          left: metrics.textHorizontalPadding,
          right: metrics.textHorizontalPadding,
          top: metrics.textVerticalPadding,
        ),
        child: CustomPaint(
          painter: _LyricPlaybackWashPainter(
            textKey: _textKey,
            document: controller.document,
            highlightedGroupId: controller.playbackHighlightGroupId,
          ),
          child: _textGestures(
            EditableText(
              key: _textKey,
              controller: _text,
              focusNode: _focus,
              style: _text.primaryStyle,
              textScaler: MediaQuery.textScalerOf(context),
              selectionWidthStyle: BoxWidthStyle.tight,
              readOnly: true,
              rendererIgnoresPointer: true,
              magnifierConfiguration:
                  TextMagnifier.adaptiveMagnifierConfiguration,
              showCursor: false,
              // Keep native handles for precise selection; sentence selection
              // uses taps and leaves scrolling available between endpoints.
              showSelectionHandles:
                  !_selectBySentence && !controller.selection.isCollapsed,
              selectionControls: _articleSelectionControls(context),
              selectionColor: const Color(0x4D0A84FF),
              cursorColor: const Color(0xFF0A84FF),
              backgroundCursorColor: const Color(0xFF0A84FF),
              cursorWidth: 0,
              maxLines: null,
              minLines: null,
              expands: true,
              forceLine: false,
              keyboardType: TextInputType.none,
              scrollController: _scroll,
              scrollPadding: EdgeInsets.zero,
              contextMenuBuilder: _buildContextMenu,
            ),
          ),
        ),
      ),
    );
  }

  // EditableText replaces its handle overlay when this callback changes.
  // Keep a stable tear-off so selection and playback rebuilds cannot interrupt
  // an in-progress handle drag.
  Widget _buildContextMenu(BuildContext context, EditableTextState editable) {
    if (!_menuOpen) {
      _menuOpen = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.controller.setTextMenuOpen(true);
      });
    }
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: editable.contextMenuAnchors,
      buttonItems: [
        ContextMenuButtonItem(
          label: '复制',
          onPressed: () {
            editable.hideToolbar();
            closeTextMenu();
            unawaited(widget.controller.copySelection());
          },
        ),
        ContextMenuButtonItem(
          label: '全选',
          onPressed: () {
            editable.hideToolbar();
            closeTextMenu();
            _selectEntireDocument();
          },
        ),
      ],
    );
  }

  Widget _textGestures(Widget child) {
    if (_selectBySentence) {
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapUp: _selectSentence,
        child: child,
      );
    }
    return _selectionGestures.buildGestureDetector(
      behavior: HitTestBehavior.translucent,
      child: child,
    );
  }

  /// Same handle controls [SelectionArea] installs for the subtitle article.
  TextSelectionControls _articleSelectionControls(BuildContext context) {
    return switch (Theme.of(context).platform) {
      TargetPlatform.android ||
      TargetPlatform.fuchsia => materialTextSelectionHandleControls,
      TargetPlatform.iOS => cupertinoTextSelectionHandleControls,
      TargetPlatform.macOS => cupertinoDesktopTextSelectionHandleControls,
      TargetPlatform.linux ||
      TargetPlatform.windows => desktopTextSelectionHandleControls,
    };
  }

  Widget _actions(MusicLyricSelectionMetrics metrics) {
    final enabled = widget.controller.canCopy;
    return Column(
      key: const ValueKey('music-lyric-selection-actions'),
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: MediaQuery.textScalerOf(context).scale(12) * 1.5 + 4,
          child: Center(
            child: Semantics(
              liveRegion: widget.controller.statusMessage != null,
              child: Text(
                widget.controller.statusMessage ??
                    (_selectBySentence ? '点首句和末句，选取整段' : '长按选择文字，或按句选取'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'Noto Sans SC',
                  color: Colors.white70,
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ),
        SizedBox(
          height: metrics.toolbarHeight,
          child: Row(
            children: [
              Expanded(
                child: _textButton(
                  '全选',
                  widget.controller.document.isEmpty
                      ? null
                      : _selectEntireDocument,
                  const ValueKey('music-lyric-selection-all'),
                ),
              ),
              Expanded(
                child: DesktopButtonClickRegion(
                  child: TextButton(
                    key: const ValueKey('music-lyric-selection-sentence'),
                    onPressed: widget.controller.document.isEmpty
                        ? null
                        : _toggleSentenceSelection,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(44, 44),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      backgroundColor: _selectBySentence
                          ? const Color(0x330A84FF)
                          : null,
                    ),
                    child: Semantics(
                      toggled: _selectBySentence,
                      child: const Text(
                        '按句选取',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: _textButton(
                  '复制',
                  enabled
                      ? () => unawaited(widget.controller.copySelection())
                      : null,
                  const ValueKey('music-lyric-selection-copy'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _textButton(String label, VoidCallback? onPressed, Key key) {
    return DesktopButtonClickRegion(
      child: TextButton(
        key: key,
        onPressed: onPressed,
        style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }

  Widget _missingBanner() {
    return _banner('暂时找不到源文件，已保留当前歌词文本');
  }

  Widget _banner(String message, {Widget? action}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.8),
                fontSize: 12,
              ),
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

/// Paints the playing lyric behind the glyphs. Kept out of the [TextSpan] so
/// a clock update does not rebuild the selectable paragraph and drop handles.
class _LyricPlaybackWashPainter extends CustomPainter {
  _LyricPlaybackWashPainter({
    required this.textKey,
    required this.document,
    required this.highlightedGroupId,
  });

  final GlobalKey textKey;
  final MusicLyricSelectionDocument document;
  final String? highlightedGroupId;

  @override
  void paint(Canvas canvas, Size size) {
    final group = document.groupById(highlightedGroupId);
    final render = textKey.currentContext?.findRenderObject();
    if (group == null || render is! RenderEditable || !render.hasSize) return;
    final boxes = render.getBoxesForSelection(
      TextSelection(
        baseOffset: group.documentStart,
        extentOffset: group.documentEnd,
      ),
    );
    if (boxes.isEmpty) return;
    final paint = Paint()
      ..color = MusicLyricSelectionDocument.playingBackground;
    for (final box in boxes) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(box.toRect(), const Radius.circular(4)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LyricPlaybackWashPainter oldDelegate) {
    return oldDelegate.highlightedGroupId != highlightedGroupId ||
        oldDelegate.document.documentKey != document.documentKey;
  }
}
