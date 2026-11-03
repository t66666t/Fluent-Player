import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_math_fork/ast.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'ai_math_fonts.dart';
import 'ai_math_line_breaks.dart';
import 'ai_math_selection.dart';
import 'ai_inline_math_viewport.dart';

/// Shares parsed templates across stream frames, messages and themes.
/// Limits are both count- and source-size-based; invalid input is cached too.
class AiMathCache {
  static const maxEntries = 128;
  static const maxCharacters = 65536;
  static final _entries = <String, Math>{};
  static int _characters = 0;
  static int _parses = 0;

  static Math parse(String source, {required bool display}) {
    final key = '${display ? 'd' : 'i'}:$source';
    final cached = _entries.remove(key);
    if (cached != null) {
      _entries[key] = cached;
      return cached;
    }
    _parses++;
    final result = Math.tex(
      _normalize(source),
      settings: TexParserSettings(
        displayMode: display,
        maxExpand: 100,
        strict: Strict.ignore,
      ),
    );
    final cachedResult = withAiMathFonts(result, source);
    _entries[key] = cachedResult;
    _characters += key.length;
    while (_entries.length > maxEntries || _characters > maxCharacters) {
      final first = _entries.keys.first;
      _characters -= first.length;
      _entries.remove(first);
    }
    return cachedResult;
  }

  static String _normalize(String source) {
    var value = source.trim();
    for (final delimiters in [(r'$$', r'$$'), (r'\[', r'\]'), (r'\(', r'\)')]) {
      if (value.startsWith(delimiters.$1) &&
          value.endsWith(delimiters.$2) &&
          value.length >= delimiters.$1.length + delimiters.$2.length) {
        value = value
            .substring(
              delimiters.$1.length,
              value.length - delimiters.$2.length,
            )
            .trim();
        break;
      }
    }
    // AMS outer wrappers differ from the KaTeX-compatible inner environments.
    for (final entry in {
      'equation': '',
      'equation*': '',
      'align': 'aligned',
      'align*': 'aligned',
      'gather': 'array',
      'gather*': 'array',
      'gathered': 'array',
    }.entries) {
      final begin = '\\begin{${entry.key}}', end = '\\end{${entry.key}}';
      if (value.startsWith(begin) && value.endsWith(end)) {
        final content = value.substring(
          begin.length,
          value.length - end.length,
        );
        if (entry.value == 'array') {
          return '\\begin{array}{c}$content\\end{array}';
        }
        return entry.value.isEmpty
            ? content
            : '\\begin{${entry.value}}$content\\end{${entry.value}}';
      }
    }
    return value;
  }

  static bool withinLimits(String source) {
    if (source.length > 4096) return false;
    var depth = 0, tokens = 0, rows = 0;
    for (var i = 0; i < source.length; i++) {
      final char = source.codeUnitAt(i);
      if (char > 32 && ++tokens > 1024) return false;
      if (char == 92) {
        if (i + 1 < source.length &&
            source.codeUnitAt(i + 1) == 92 &&
            ++rows > 32) {
          return false;
        }
        i++;
        continue;
      }
      if (char == 123 && ++depth > 32) return false;
      if (char == 125) depth--;
    }
    return true;
  }

  @visibleForTesting
  static int get parseCount => _parses;
  @visibleForTesting
  static int get entryCount => _entries.length;
  @visibleForTesting
  static int get characterCount => _characters;
  @visibleForTesting
  static void reset() {
    _entries.clear();
    _characters = 0;
    _parses = 0;
  }
}

/// Carries the current message width to inline formulas even when Markdown
/// reuses its parsed widgets during sidebar resizing.
class AiMathViewport extends InheritedWidget {
  const AiMathViewport({
    super.key,
    required this.maxWidth,
    required super.child,
  });

  final double maxWidth;

  static double? widthOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AiMathViewport>()?.maxWidth;

  @override
  bool updateShouldNotify(AiMathViewport oldWidget) =>
      maxWidth != oldWidget.maxWidth;
}

class AiMathFormula extends StatefulWidget {
  const AiMathFormula({
    super.key,
    required this.source,
    required this.maxWidth,
    this.copySource,
    this.block = false,
    this.display = false,
    this.complete = true,
    this.streaming = false,
    this.textStyle,
  });

  final String source;
  final String? copySource;
  final double maxWidth;
  final bool block, display, complete, streaming;
  final TextStyle? textStyle;

  @override
  State<AiMathFormula> createState() => _AiMathFormulaState();
}

class _AiMathFormulaState extends State<AiMathFormula> {
  final _scroll = ScrollController();
  Math? _parsed;
  String? _parsedSource;
  bool? _parsedDisplay;
  (TextStyle, TextScaler, bool)? _parsedVisual;

  Math _parse(bool display, TextStyle style) {
    final effectiveStyle = style.inherit
        ? DefaultTextStyle.of(context).style.merge(style)
        : style;
    final visual = (
      effectiveStyle,
      MediaQuery.textScalerOf(context),
      MediaQuery.boldTextOf(context),
    );
    if (_parsed == null ||
        _parsedSource != widget.source ||
        _parsedDisplay != display ||
        _parsedVisual != visual) {
      // Upstream AST nodes cache glyph widgets without checking all absolute
      // font-size changes. Re-isolate their render state when visual inputs
      // change, while continuing to reuse the cached parse template.
      _parsed = isolateAiMathTree(
        AiMathCache.parse(widget.source, display: display),
      );
      _parsedSource = widget.source;
      _parsedDisplay = display;
      _parsedVisual = visual;
    }
    return _parsed!;
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Widget _fallback(String message) {
    final colors = Theme.of(context).colorScheme;
    if (!widget.block) {
      return Tooltip(
        message: message,
        child: Text(widget.source, style: widget.textStyle),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          message,
          style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
        ),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 160),
          child: SingleChildScrollView(
            child: Text(
              widget.source,
              style: TextStyle(
                fontSize: (widget.textStyle?.fontSize ?? 14) - 1,
                height: 1.5,
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.complete && widget.source.trim().isEmpty) {
      return const SizedBox.shrink();
    }
    // Inline widgets may be measured intrinsically by Markdown tables, where
    // LayoutBuilder is unsupported. Their limit comes from the Markdown body.
    final viewportWidth = AiMathViewport.widthOf(context) ?? double.infinity;
    final width = widget.maxWidth < viewportWidth
        ? widget.maxWidth
        : viewportWidth;
    return widget.block
        ? LayoutBuilder(
            builder: (context, constraints) =>
                _buildEquation(context, constraints.constrainWidth(width)),
          )
        : _buildEquation(context, width);
  }

  Widget _buildEquation(BuildContext context, double maxWidth) {
    final width = maxWidth.clamp(1.0, double.infinity);
    final colors = Theme.of(context).colorScheme;
    final display = widget.block || widget.display;
    final style = (widget.textStyle ?? const TextStyle(fontSize: 14)).copyWith(
      fontSize:
          (widget.textStyle?.fontSize ?? 14) * (widget.block ? 18 / 14 : 1),
      color: widget.textStyle?.color ?? colors.onSurface,
    );
    Widget content;
    if (!widget.complete) {
      content = _fallback(widget.streaming ? '公式接收中…' : '公式未闭合，已保留原文');
    } else if (!AiMathCache.withinLimits(widget.source)) {
      content = _fallback('公式较复杂，已保留原文，可复制查看');
    } else {
      final parsed = _parse(display, style);
      final math = Math(
        ast: parsed.ast,
        parseError: parsed.parseError,
        mathStyle: display ? MathStyle.display : MathStyle.text,
        textStyle: style,
        onErrorFallback: (_) => _fallback('公式暂无法排版，已保留原文'),
      );
      final parts = widget.block && parsed.parseError == null
          ? _breakBlockMath(math)
          : (widgets: <Math>[math], penalties: <int>[0]);
      // Break only at TeX's outer relation/binary operators. Fractions,
      // matrices, delimiters and explicit no-break groups stay intact.
      content = parts.widgets.length > 1 && width.isFinite
          ? _MathLines(
              maxWidth: width,
              indent: MediaQuery.textScalerOf(context).scale(style.fontSize!),
              penalties: parts.penalties,
              children: parts.widgets,
            )
          : math;
    }
    final equation = Semantics(
      label: '数学公式：${widget.source}',
      child: RepaintBoundary(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width),
          child: AiSelectableMath(
            source: widget.copySource ?? widget.source,
            child: SelectionContainer.disabled(
              child: !widget.block
                  ? AiInlineMathViewport(controller: _scroll, child: content)
                  : ScrollConfiguration(
                      behavior: ScrollConfiguration.of(
                        context,
                      ).copyWith(scrollbars: false),
                      child: SingleChildScrollView(
                        controller: _scroll,
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.only(top: 3, bottom: 12),
                        child: content,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
    final interactive = MouseRegion(
      cursor: SystemMouseCursors.text,
      child: widget.block
          ? Scrollbar(
              controller: _scroll,
              thickness: 4,
              radius: const Radius.circular(2),
              child: Align(alignment: Alignment.centerLeft, child: equation),
            )
          : equation,
    );
    return widget.block
        ? Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: interactive,
          )
        : interactive;
  }
}

({List<Math> widgets, List<int> penalties}) _breakBlockMath(Math math) {
  final root = math.ast!.greenRoot;
  final nodes = root.flattenedChildList;
  final starts = <int>[0];
  final penalties = <int>[0];
  GreenNode? previous;
  var depth = 0;
  AtomType? delimiter(GreenNode node) {
    // A script attached to ')' hides its closing atom type upstream. Inspect
    // only the script's single-character base, never its grouped contents.
    if (node is MultiscriptsNode && node.base.flattenedChildList.length == 1) {
      return delimiter(node.base.flattenedChildList.single);
    }
    return node is SymbolNode ? node.atomType : null;
  }

  for (var index = 0; index < nodes.length; index++) {
    final node = nodes[index];
    if (node is SpaceNode) {
      if (depth == 0 &&
          node.breakPenalty != null &&
          node.breakPenalty! < 10000 &&
          index + 1 < nodes.length &&
          previous != null &&
          previous.rightType != AtomType.bin &&
          previous.rightType != AtomType.rel) {
        starts.add(index + 1);
        penalties.add(0);
      }
      continue;
    }
    // Ordinary parentheses are separate symbols in the AST, unlike \left…
    // \right. Do not split inside them, or a function argument may look like
    // a new top-level term on the next line.
    final delimiterType = delimiter(node);
    if (delimiterType == AtomType.close && depth > 0) depth--;
    final next = nodes
        .skip(index + 1)
        .where((next) => next.leftType != AtomType.spacing)
        .firstOrNull;
    final binary =
        node.leftType == AtomType.bin &&
        previous != null &&
        next != null &&
        !{
          AtomType.bin,
          AtomType.open,
          AtomType.rel,
          AtomType.op,
          AtomType.punct,
        }.contains(previous.rightType) &&
        !{AtomType.rel, AtomType.close, AtomType.punct}.contains(next.leftType);
    final relation = node.leftType == AtomType.rel && next != null;
    var noBreak = false;
    for (final direction in [-1, 1]) {
      for (
        var i = index + direction;
        i >= 0 && i < nodes.length && nodes[i] is SpaceNode;
        i += direction
      ) {
        if (((nodes[i] as SpaceNode).breakPenalty ?? 0) >= 10000) {
          noBreak = true;
        }
      }
    }
    final clause = previous?.rightType == AtomType.punct;
    // An implicit product can wrap before a named function, while the
    // function name and its argument remain one term (e.g. det(A) det(B)).
    final product =
        node is FunctionNode &&
        previous != null &&
        !{
          AtomType.bin,
          AtomType.rel,
          AtomType.open,
          AtomType.op,
        }.contains(previous.rightType);
    if (depth == 0 &&
        index > starts.last &&
        !noBreak &&
        (binary || relation || clause || product)) {
      starts.add(index);
      final additive =
          node is SymbolNode && {'+', '−', '-', '±', '∓'}.contains(node.symbol);
      penalties.add(
        clause
            ? -100
            : relation
            ? 0
            : additive
            ? 80
            : 300,
      );
    }
    if (delimiterType == AtomType.open) depth++;
    previous = node;
  }
  if (starts.length == 1) return (widgets: [math], penalties: [0]);
  List<GreenNode> styledLeaves(GreenNode node) {
    if (node is! TransparentNode) return [node];
    return node.children
        .expand(styledLeaves)
        .map((child) => node.updateChildren(<GreenNode>[child]))
        .toList();
  }

  // Keep each transparent style wrapper on its original leaf. The upstream
  // clipping helper duplicates ranges lying inside a single style wrapper.
  final styled = root.children.expand(styledLeaves).toList();
  final widgets = List.generate(starts.length, (index) {
    final start = starts[index];
    final end = index + 1 < starts.length ? starts[index + 1] : nodes.length;
    final before = nodes
        .take(start)
        .where((node) => node.rightType != AtomType.spacing)
        .lastOrNull;
    return Math(
      ast: SyntaxTree(
        greenRoot: EquationRowNode(
          children: [
            // Preserve the preceding atom's type. Without this phantom,
            // a leading binary '+' is treated as unary and loses TeX glue.
            if (before != null)
              PhantomNode(
                phantomChild: EquationRowNode(
                  children: [],
                  overrideType: before.rightType,
                ),
                zeroWidth: true,
                zeroHeight: true,
                zeroDepth: true,
              ),
            ...styled.sublist(start, end),
          ],
        ),
      ),
      mathStyle: math.mathStyle,
      textStyle: math.textStyle,
      onErrorFallback: math.onErrorFallback,
    );
  });
  return (widgets: widgets, penalties: penalties);
}

/// Measures intact TeX parts at their natural size and packs baseline-aligned
/// lines. An indivisible part wider than the line keeps its natural width, so
/// the formula's existing horizontal viewport can still reveal all of it.
class _MathLines extends MultiChildRenderObjectWidget {
  const _MathLines({
    required this.maxWidth,
    required this.indent,
    required this.penalties,
    required super.children,
  });

  final double maxWidth;
  final double indent;
  final List<int> penalties;

  @override
  _RenderMathLines createRenderObject(BuildContext context) =>
      _RenderMathLines(maxWidth, indent, penalties);

  @override
  void updateRenderObject(BuildContext context, _RenderMathLines renderObject) {
    renderObject.update(maxWidth, indent, penalties);
  }
}

class _MathLineParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderMathLines extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _MathLineParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _MathLineParentData> {
  _RenderMathLines(this._maxWidth, this._indent, this._penalties);

  double _maxWidth;
  double _indent;
  List<int> _penalties;
  double? _firstBaseline;

  void update(double maxWidth, double indent, List<int> penalties) {
    _maxWidth = maxWidth;
    _indent = indent;
    _penalties = penalties;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _MathLineParentData) {
      child.parentData = _MathLineParentData();
    }
  }

  @override
  void performLayout() {
    var y = 0.0, widest = 0.0;
    final children = <(RenderBox, double)>[];
    _firstBaseline = null;

    var child = firstChild;
    while (child != null) {
      child.layout(const BoxConstraints(), parentUsesSize: true);
      final baseline =
          child.getDistanceToBaseline(TextBaseline.alphabetic) ??
          child.size.height;
      children.add((child, baseline));
      child = childAfter(child);
    }
    final indent = _indent.clamp(0.0, _maxWidth * .15);
    final starts = planAiMathLines(
      widths: children.map((part) => part.$1.size.width).toList(),
      penalties: _penalties,
      maxWidth: _maxWidth,
      indent: indent,
    );
    for (var row = 0; row < starts.length; row++) {
      final start = starts[row];
      final end = row + 1 < starts.length ? starts[row + 1] : children.length;
      final line = children.sublist(start, end);
      var ascent = 0.0, descent = 0.0;
      for (final (child, baseline) in line) {
        if (baseline > ascent) ascent = baseline;
        final below = child.size.height - baseline;
        if (below > descent) descent = below;
      }
      _firstBaseline ??= ascent;
      var x =
          row > 0 &&
              _penalties[start] >= 0 &&
              line.first.$1.size.width + indent <= _maxWidth
          ? indent
          : 0.0;
      for (final (child, baseline) in line) {
        (child.parentData! as _MathLineParentData).offset = Offset(
          x,
          y + ascent - baseline,
        );
        x += child.size.width;
      }
      if (x > widest) widest = x;
      y += ascent + descent;
      if (row + 1 < starts.length) y += _indent * .45;
    }
    size = constraints.constrain(Size(widest, y));
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      _firstBaseline;

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
