# Application patches to flutter_markdown_plus 1.0.12

Upstream: https://github.com/foresightmobile/flutter_markdown_plus

The original BSD license is retained in LICENSE. Only lib/src/builder.dart is
modified. Compare it with the upstream 1.0.12 source when upgrading:

- Use strut as a minimum line height, allowing tall inline fractions and scripts
  to increase actual line height instead of overlapping neighboring text.
- Preserve nested TextSpan children and merge parent style before child style,
  retaining emphasis and link recognizers inside custom inline builders.
- Merge only leaf TextSpans. Converting nested spans to plain text discards
  embedded WidgetSpans and their formula/selection content.

Application integration uses Text.rich + WidgetSpan for inline formulas. Blocks,
tables, code, and Markdown parsing retain the upstream implementation.

Regressions: test/ai_markdown_matrix_regression_test.dart,
test/ai_markdown_mixed_content_test.dart, and test/ai_math_selection_test.dart.
