import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'article_document.dart';
import 'article_layout_model.dart';

class ContinuousArticleView extends StatefulWidget {
  const ContinuousArticleView({
    super.key,
    required this.document,
    required this.layout,
    required this.style,
    required this.highlightStyle,
    required this.activeIndices,
    required this.itemScrollController,
    required this.itemPositionsListener,
    required this.onSubtitleTap,
    required this.padding,
    this.initialSentenceIndex = 0,
    this.initialAlignment = 0,
    this.physics,
    this.scrollOffsetController,
    this.keepSelectionAlive = false,
    this.onScrollableChanged,
    this.footer,
    this.footerExtent = 0,
    this.viewportKey,
  });

  final ArticleDocument document;
  final ArticleLayout layout;
  final TextStyle style;
  final TextStyle highlightStyle;
  final ValueListenable<List<int>> activeIndices;
  final ItemScrollController itemScrollController;
  final ItemPositionsListener itemPositionsListener;
  final ValueChanged<int>? onSubtitleTap;
  final EdgeInsets padding;
  final int initialSentenceIndex;
  final double initialAlignment;
  final ScrollPhysics? physics;
  final ScrollOffsetController? scrollOffsetController;
  final bool keepSelectionAlive;
  final ValueChanged<ScrollableState>? onScrollableChanged;
  final Widget? footer;

  /// The footer's laid-out height, included when deciding whether text fits.
  final double footerExtent;
  final Key? viewportKey;

  @override
  State<ContinuousArticleView> createState() => ContinuousArticleViewState();
}

class ContinuousArticleViewState extends State<ContinuousArticleView> {
  final Map<int, _ContinuousArticleLineState> _mountedLines =
      <int, _ContinuousArticleLineState>{};
  bool? _fitsViewport;

  int? subtitleIndexAtGlobalPosition(Offset position, int lineIndex) {
    return _mountedLines[lineIndex]?.subtitleIndexAtGlobalPosition(position);
  }

  void _registerLine(int index, _ContinuousArticleLineState? state) {
    if (state == null) {
      _mountedLines.remove(index);
    } else {
      _mountedLines[index] = state;
    }
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.layout.lines;
    final initialLine = widget.layout
        .lineForSentence(widget.initialSentenceIndex)
        .clamp(0, lines.isEmpty ? 0 : lines.length - 1);

    return LayoutBuilder(
      builder: (context, constraints) {
        // Use the existing line measurements, stopping after one viewport.
        // A reading anchor on a full-height indexed list otherwise reserves
        // blank space above even when the entire article fits on screen.
        var contentHeight = widget.padding.vertical + widget.footerExtent;
        if (constraints.hasBoundedHeight) {
          for (final line in lines) {
            contentHeight += line.height;
            if (contentHeight > constraints.maxHeight) break;
          }
        }
        final fits =
            constraints.hasBoundedHeight &&
            contentHeight <= constraints.maxHeight;
        var alignment = widget.initialAlignment.clamp(0.0, 1.0);
        if (!fits &&
            lines.isNotEmpty &&
            constraints.hasBoundedHeight &&
            constraints.maxHeight > 0) {
          // Clamp a cold anchor before its first layout. Otherwise the indexed
          // viewport can start outside its bounds and immediately spring;
          // Scrollable then steals a first-frame long press on Android.
          final height = constraints.maxHeight;
          var before = initialLine == 0 ? 0.0 : widget.padding.top;
          for (
            var i = initialLine - 1;
            i >= 0 && before < alignment * height;
            i--
          ) {
            before += lines[i].height;
          }
          var after = widget.padding.bottom + widget.footerExtent;
          for (
            var i = initialLine;
            i < lines.length && after < (1 - alignment) * height;
            i++
          ) {
            after += lines[i].height;
          }
          final maximum = (before / height).clamp(0.0, 1.0);
          final minimum = (1 - after / height).clamp(0.0, 1.0);
          alignment = minimum > maximum
              ? maximum
              : alignment.clamp(minimum, maximum);
        }
        if (fits &&
            _fitsViewport == false &&
            widget.itemScrollController.isAttached) {
          // Reset the retained long-article anchor before laying out its
          // descendants, so a larger viewport paints the short article at top.
          widget.itemScrollController.jumpTo(index: 0);
        }
        _fitsViewport = fits;
        return Align(
          alignment: Alignment.topCenter,
          // Keep one viewport type as streamed lines cross the fit threshold;
          // swapping in a shrink-wrapping viewport would dispose selectable
          // lines and lose their selection state.
          child: SizedBox(
            height: fits ? contentHeight : null,
            child: Semantics(
              key: const PageStorageKey('subtitle-continuous-positioned-scroll'),
              label: '连续字幕文章',
              child: KeyedSubtree(
                key: widget.viewportKey,
                child: ScrollablePositionedList.builder(
                  key: const ValueKey('subtitle-continuous-article-view'),
                  itemScrollController: widget.itemScrollController,
                  itemPositionsListener: widget.itemPositionsListener,
                  initialScrollIndex: fits ? 0 : initialLine,
                  initialAlignment: fits ? 0 : alignment,
                  physics: fits
                      ? const NeverScrollableScrollPhysics()
                      : widget.physics,
                  scrollOffsetController: widget.scrollOffsetController,
                  padding: widget.padding,
                  itemCount: lines.length + (widget.footer == null ? 0 : 1),
                  itemBuilder: (context, lineIndex) {
                    if (lineIndex == lines.length) return widget.footer!;
                    return _ContinuousSelectionKeepAlive(
                      keepAlive: widget.keepSelectionAlive,
                      child: _ContinuousScrollableObserver(
                        onScrollableChanged: widget.onScrollableChanged,
                        child: _ContinuousArticleLine(
                          key: ValueKey('subtitle-continuous-line-$lineIndex'),
                          lineIndex: lineIndex,
                          document: widget.document,
                          record: lines[lineIndex],
                          style: widget.style,
                          highlightStyle: widget.highlightStyle,
                          activeIndices: widget.activeIndices,
                          onSubtitleTap: widget.onSubtitleTap,
                          onRegistrationChanged: _registerLine,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ContinuousSelectionKeepAlive extends StatefulWidget {
  const _ContinuousSelectionKeepAlive({
    required this.keepAlive,
    required this.child,
  });

  final bool keepAlive;
  final Widget child;

  @override
  State<_ContinuousSelectionKeepAlive> createState() =>
      _ContinuousSelectionKeepAliveState();
}

class _ContinuousSelectionKeepAliveState
    extends State<_ContinuousSelectionKeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => widget.keepAlive;

  @override
  void didUpdateWidget(covariant _ContinuousSelectionKeepAlive oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keepAlive != widget.keepAlive) updateKeepAlive();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class _ContinuousScrollableObserver extends StatefulWidget {
  const _ContinuousScrollableObserver({
    required this.onScrollableChanged,
    required this.child,
  });

  final ValueChanged<ScrollableState>? onScrollableChanged;
  final Widget child;

  @override
  State<_ContinuousScrollableObserver> createState() =>
      _ContinuousScrollableObserverState();
}

class _ContinuousScrollableObserverState
    extends State<_ContinuousScrollableObserver> {
  ScrollableState? _scrollable;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = Scrollable.maybeOf(context);
    if (next == null || identical(next, _scrollable)) return;
    _scrollable = next;
    widget.onScrollableChanged?.call(next);
  }

  @override
  void didUpdateWidget(covariant _ContinuousScrollableObserver oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.onScrollableChanged != widget.onScrollableChanged &&
        _scrollable != null) {
      widget.onScrollableChanged?.call(_scrollable!);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _ContinuousArticleLine extends StatefulWidget {
  const _ContinuousArticleLine({
    super.key,
    required this.lineIndex,
    required this.document,
    required this.record,
    required this.style,
    required this.highlightStyle,
    required this.activeIndices,
    required this.onSubtitleTap,
    required this.onRegistrationChanged,
  });

  final int lineIndex;
  final ArticleDocument document;
  final ArticleLineRecord record;
  final TextStyle style;
  final TextStyle highlightStyle;
  final ValueListenable<List<int>> activeIndices;
  final ValueChanged<int>? onSubtitleTap;
  final void Function(int, _ContinuousArticleLineState?) onRegistrationChanged;

  @override
  State<_ContinuousArticleLine> createState() => _ContinuousArticleLineState();
}

class _ContinuousArticleLineState extends State<_ContinuousArticleLine> {
  final GlobalKey _paintKey = GlobalKey();
  TextPainter? _normalPainter;
  double _layoutWidth = -1;
  Set<int> _active = const <int>{};
  Widget? _content;

  @override
  void initState() {
    super.initState();
    PaintingBinding.instance.systemFonts.addListener(_handleFontsChanged);
    _active = _lineActiveIndices();
    widget.activeIndices.addListener(_handleActiveIndicesChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onRegistrationChanged(widget.lineIndex, this);
    });
  }

  @override
  void didUpdateWidget(covariant _ContinuousArticleLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeIndices != widget.activeIndices) {
      oldWidget.activeIndices.removeListener(_handleActiveIndicesChanged);
      widget.activeIndices.addListener(_handleActiveIndicesChanged);
    }
    if (oldWidget.lineIndex != widget.lineIndex) {
      oldWidget.onRegistrationChanged(oldWidget.lineIndex, null);
      widget.onRegistrationChanged(widget.lineIndex, this);
    }
    if (oldWidget.record != widget.record ||
        oldWidget.style != widget.style ||
        oldWidget.highlightStyle != widget.highlightStyle ||
        oldWidget.onSubtitleTap != widget.onSubtitleTap ||
        oldWidget.document.textBetween(
              oldWidget.record.paintStart,
              oldWidget.record.end,
            ) !=
            widget.document.textBetween(
              widget.record.paintStart,
              widget.record.end,
            )) {
      _disposePainters();
      _content = null;
    }
    final next = _lineActiveIndices();
    if (!_sameSet(next, _active)) _content = null;
    _active = next;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _disposePainters();
    _content = null;
  }

  Set<int> _lineActiveIndices() => {
    for (final index in widget.record.sentenceIndices)
      if (widget.activeIndices.value.contains(index)) index,
  };

  void _handleActiveIndicesChanged() {
    final next = _lineActiveIndices();
    if (_sameSet(next, _active)) return;
    setState(() {
      _active = next;
      _content = null;
    });
  }

  void _handleFontsChanged() {
    _disposePainters();
    if (mounted) setState(() => _content = null);
  }

  bool _sameSet(Set<int> a, Set<int> b) {
    return a.length == b.length && a.containsAll(b);
  }

  void _ensurePainters(
    double width,
    TextDirection direction,
    TextScaler scaler,
  ) {
    if (_normalPainter != null &&
        (_layoutWidth - width).abs() < 0.01 &&
        _normalPainter!.textDirection == direction &&
        _normalPainter!.textScaler == scaler) {
      return;
    }
    _disposePainters();
    final text = widget.document.textBetween(
      widget.record.paintStart,
      widget.record.end,
    );
    _normalPainter = TextPainter(
      text: TextSpan(text: text, style: widget.style),
      textDirection: direction,
      textScaler: scaler,
      maxLines: 1,
    )..layout(maxWidth: width);
    _layoutWidth = width;
  }

  int? subtitleIndexAtGlobalPosition(Offset globalPosition) {
    final object = _paintKey.currentContext?.findRenderObject();
    final painter = _normalPainter;
    if (object is! RenderBox || !object.hasSize || painter == null) return null;
    final local = object.globalToLocal(globalPosition);
    if (!(Offset.zero & object.size).contains(local)) return null;
    final position = painter.getPositionForOffset(local);
    final documentOffset = widget.record.paintStart + position.offset;
    final sentenceIndex = widget.document.displayIndexAtOffset(documentOffset);
    if (sentenceIndex == null) return null;
    final sentence = widget.document.sentenceForDisplayIndex(sentenceIndex);
    if (sentence == null || !sentence.hasText) return null;
    final selection = TextSelection(
      baseOffset: (sentence.start - widget.record.paintStart).clamp(
        0,
        painter.text!.toPlainText().length,
      ),
      extentOffset: (sentence.end - widget.record.paintStart).clamp(
        0,
        painter.text!.toPlainText().length,
      ),
    );
    final hit = painter
        .getBoxesForSelection(selection)
        .any((box) => box.toRect().inflate(1).contains(local));
    return hit ? sentenceIndex : null;
  }

  void _handleTapUp(TapUpDetails details) {
    final object = _paintKey.currentContext?.findRenderObject();
    if (object is! RenderBox) return;
    final index = subtitleIndexAtGlobalPosition(
      object.localToGlobal(details.localPosition),
    );
    if (index != null) widget.onSubtitleTap?.call(index);
  }

  @override
  Widget build(BuildContext context) {
    return _content ??= LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        _ensurePainters(
          width,
          Directionality.of(context),
          MediaQuery.textScalerOf(context),
        );
        final painter = _normalPainter!;
        return Semantics(
          label: painter.text!.toPlainText(),
          button: widget.onSubtitleTap != null,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: widget.onSubtitleTap == null ? null : _handleTapUp,
            child: SizedBox(
              key: _paintKey,
              width: width,
              height: painter.height,
              child: Text.rich(
                key: ValueKey(
                  'subtitle-continuous-line-text-${widget.lineIndex}',
                ),
                _buildSelectableLineSpan(),
                maxLines: 1,
                softWrap: false,
                // A glyph's painted ink can extend slightly beyond its layout
                // advance (notably for italic and some CJK fonts). Let that ink
                // use the sidebar's existing horizontal padding instead of
                // clipping the final character at the logical line boundary.
                overflow: TextOverflow.visible,
                textScaler: MediaQuery.textScalerOf(context),
              ),
            ),
          ),
        );
      },
    );
  }

  List<TextSelection> _activeSelections() {
    final length = widget.record.end - widget.record.paintStart;
    final result = <TextSelection>[];
    for (final index in widget.record.sentenceIndices) {
      if (!_active.contains(index)) continue;
      final sentence = widget.document.sentenceForDisplayIndex(index);
      if (sentence == null || !sentence.hasText) continue;
      result.add(
        TextSelection(
          baseOffset: (sentence.start - widget.record.paintStart).clamp(
            0,
            length,
          ),
          extentOffset: (sentence.end - widget.record.paintStart).clamp(
            0,
            length,
          ),
        ),
      );
    }
    return result;
  }

  InlineSpan _buildSelectableLineSpan() {
    final String text = widget.document.textBetween(
      widget.record.paintStart,
      widget.record.end,
    );
    final List<TextSelection> selections = _activeSelections()
      ..sort((a, b) => a.start.compareTo(b.start));
    if (selections.isEmpty) {
      return TextSpan(text: text, style: widget.style);
    }

    final List<TextSpan> spans = <TextSpan>[];
    int cursor = 0;
    for (final TextSelection selection in selections) {
      final int start = selection.start.clamp(cursor, text.length);
      final int end = selection.end.clamp(start, text.length);
      if (start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, start)));
      }
      if (end > start) {
        spans.add(
          TextSpan(
            text: text.substring(start, end),
            style: widget.highlightStyle,
          ),
        );
      }
      cursor = end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }
    return TextSpan(style: widget.style, children: spans);
  }

  void _disposePainters() {
    _normalPainter?.dispose();
    _normalPainter = null;
    _layoutWidth = -1;
  }

  @override
  void dispose() {
    PaintingBinding.instance.systemFonts.removeListener(_handleFontsChanged);
    widget.onRegistrationChanged(widget.lineIndex, null);
    widget.activeIndices.removeListener(_handleActiveIndicesChanged);
    _disposePainters();
    super.dispose();
  }
}
