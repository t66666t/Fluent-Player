import 'package:flutter/widgets.dart';
import 'package:flutter_math_fork/ast.dart';
import 'package:flutter_math_fork/flutter_math.dart' show Math, ParseException;
// The upstream AST API hides its build-result type. Keep this small adapter
// isolated and covered by glyph/style tests when upgrading flutter_math_fork.
// ignore: implementation_imports
import 'package:flutter_math_fork/src/ast/syntax_tree.dart' show BuildResult;

final _cjk = RegExp(r'[\u2e80-\u9fff\uac00-\ud7af\uf900-\ufaff\uff00-\uffef]');

/// The upstream "green" nodes also cache built widgets and GlobalKeys. Share
/// parsed templates, but give every formula occurrence its own render state.
Math isolateAiMathTree(Math parsed) {
  if (parsed.ast == null) return parsed;
  GreenNode clone(GreenNode node) {
    if (node is _CjkSymbol) return _CjkSymbol(node);
    if (node is SymbolNode) {
      return SymbolNode(
        symbol: node.symbol,
        mode: node.mode,
        variantForm: node.variantForm,
        overrideAtomType: node.overrideAtomType,
        overrideFont: node.overrideFont,
      );
    }
    if (node is SpaceNode) {
      return SpaceNode(
        height: node.height,
        width: node.width,
        depth: node.depth,
        shift: node.shift,
        breakPenalty: node.breakPenalty,
        fill: node.fill,
        mode: node.mode,
        alignerOrSpacer: node.alignerOrSpacer,
      );
    }
    if (node is PhantomNode) {
      return PhantomNode(
        phantomChild: clone(node.phantomChild) as EquationRowNode,
        zeroHeight: node.zeroHeight,
        zeroWidth: node.zeroWidth,
        zeroDepth: node.zeroDepth,
      );
    }
    if (node is StretchyOpNode) {
      // Its nullable above/below slots are incompatible with the upstream
      // updateChildren(List<EquationRowNode>) signature in version 0.7.4.
      return StretchyOpNode(
        above: node.above == null
            ? null
            : clone(node.above!) as EquationRowNode,
        below: node.below == null
            ? null
            : clone(node.below!) as EquationRowNode,
        symbol: node.symbol,
      );
    }
    if (node is MatrixNode) {
      // MatrixNode.updateChildren in 0.7.4 has an invalid flattened-body
      // slicing implementation and also rejects nullable empty cells.
      return node.copyWith(
        body: node.body
            .map(
              (row) => row
                  .map(
                    (cell) =>
                        cell == null ? null : clone(cell) as EquationRowNode,
                  )
                  .toList(),
            )
            .toList(),
      );
    }
    final original = node.children;
    final children = original
        .map((child) => child == null ? null : clone(child))
        .toList();
    if (original is List<EquationRowNode>) {
      return node.updateChildren(children.cast<EquationRowNode>());
    }
    if (original is List<EquationRowNode?>) {
      return node.updateChildren(children.cast<EquationRowNode?>());
    }
    return node.updateChildren(
      original is List<GreenNode> ? children.cast<GreenNode>() : children,
    );
  }

  try {
    return Math(
      ast: SyntaxTree(greenRoot: clone(parsed.ast!.greenRoot) as EquationRowNode),
    );
  } catch (_) {
    // Keep an upstream AST adaptation failure inside the formula boundary;
    // Math's existing error fallback preserves the complete copyable source.
    return Math(parseError: ParseException('Formula layout unavailable'));
  }
}

/// KaTeX fonts contain no CJK glyphs. Use the app's bundled MiSans face for
/// these leaves only, preserving all mathematical layout and TeX script sizes.
Math withAiMathFonts(Math parsed, String source) {
  if (!_cjk.hasMatch(source)) return parsed;
  final ast = parsed.ast;
  if (ast == null) return parsed;
  try {
    final root = _replace(ast.greenRoot);
    if (identical(root, ast.greenRoot)) return parsed;
    return Math(ast: SyntaxTree(greenRoot: root as EquationRowNode));
  } catch (_) {
    return Math(parseError: ParseException('CJK formula layout unavailable'));
  }
}

GreenNode _replace(GreenNode node) {
  if (node is SymbolNode && _cjk.hasMatch(node.symbol)) return _CjkSymbol(node);
  if (node is StretchyOpNode) {
    return StretchyOpNode(
      above: node.above == null
          ? null
          : _replace(node.above!) as EquationRowNode,
      below: node.below == null
          ? null
          : _replace(node.below!) as EquationRowNode,
      symbol: node.symbol,
    );
  }
  if (node is MatrixNode) {
    return node.copyWith(
      body: node.body
          .map(
            (row) => row
                .map(
                  (cell) =>
                      cell == null ? null : _replace(cell) as EquationRowNode,
                )
                .toList(),
          )
          .toList(),
    );
  }
  final original = node.children;
  if (original.isEmpty) return node;
  final children = original
      .map((child) => child == null ? null : _replace(child))
      .toList();
  if (List.generate(
    original.length,
    (i) => identical(children[i], original[i]),
  ).every((same) => same)) {
    return node;
  }
  if (original is List<EquationRowNode>) {
    return node.updateChildren(children.cast<EquationRowNode>());
  }
  if (original is List<EquationRowNode?>) {
    return node.updateChildren(children.cast<EquationRowNode?>());
  }
  return node.updateChildren(
    original is List<GreenNode> ? children.cast<GreenNode>() : children,
  );
}

class _CjkSymbol extends SymbolNode {
  _CjkSymbol(SymbolNode original)
    : super(
        symbol: original.symbol,
        mode: original.mode,
        variantForm: original.variantForm,
        overrideAtomType: original.overrideAtomType,
        overrideFont: original.overrideFont,
      );

  @override
  BuildResult buildWidget(
    MathOptions options,
    List<BuildResult?> childBuildResults,
  ) => BuildResult(
    options: options,
    widget: RichText(
      text: TextSpan(
        text: symbol,
        style: TextStyle(
          fontFamily: 'MiSans',
          fontFamilyFallback: const ['Noto Sans SC'],
          fontSize: options.fontSize * options.sizeMultiplier,
          color: options.color,
          fontWeight: options.textFontOptions?.fontWeight ?? FontWeight.normal,
        ),
      ),
      softWrap: false,
    ),
  );
}
