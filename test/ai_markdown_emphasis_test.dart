import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:video_player_app/features/ai_chat/ai_markdown_emphasis.dart';
import 'package:video_player_app/features/ai_chat/ai_math_syntax.dart';

String _html(String source, {bool cjk = true, bool math = false}) =>
    md.markdownToHtml(
      source,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      inlineSyntaxes: [
        if (math) AiMathInlineSyntax(),
        if (cjk) AiMarkdownEmphasisSyntax(),
      ],
    );

void main() {
  test('renders the exact quoted emphasis from the user report', () {
    expect(
      _html('这节课以**“矩阵计算不仅要会算，更要理解运算律”**为主线。'),
      '<p>这节课以<strong>“矩阵计算不仅要会算，更要理解运算律”</strong>为主线。</p>\n',
    );
  });

  test('closes emphasis before the following Chinese sentence', () {
    expect(
      _html('**把公式联系起来。**视频用比喻来概括。'),
      '<p><strong>把公式联系起来。</strong>视频用比喻来概括。</p>\n',
    );
    expect(
      _html('**学习时需注意：**字幕中有几处错误。'),
      '<p><strong>学习时需注意：</strong>字幕中有几处错误。</p>\n',
    );
  });

  test('handles mixed punctuation and CJK on either boundary', () {
    expect(
      _html('中**(English)**文；中*“强调”*文。'),
      '<p>中<strong>(English)</strong>文；中<em>“强调”</em>文。</p>\n',
    );
    expect(
      _html('中**“English”**文；English**中文**文字。'),
      '<p>中<strong>“English”</strong>文；English<strong>中文</strong>文字。</p>\n',
    );
  });

  test('retains the native delimiter stack for nesting and triples', () {
    expect(
      _html('这段***“重点”***内容'),
      '<p>这段<em><strong>“重点”</strong></em>内容</p>\n',
    );
    expect(
      _html('以**“重点 *内容*”**为主线'),
      '<p>以<strong>“重点 <em>内容</em>”</strong>为主线</p>\n',
    );
  });

  test(
    'does not rewrite escaped, inline code, fenced code or link targets',
    () {
      final source =
          r'\*\*“原文”\*\*与`**“代码”**`'
          '\n\n'
          r'[以**“重点”**为主线](https://example.com/a_**b**)'
          '\n\n```text\n**“代码”**\n```';
      final result = _html(source);
      expect(result, contains('**“原文”**与<code>**“代码”**</code>'));
      expect(result, contains('<a href="https://example.com/a_**b**">'));
      expect(result, contains('以<strong>“重点”</strong>为主线</a>'));
      expect(result, contains('<code class="language-text">**“代码”**\n</code>'));
    },
  );

  test('preserves formula underscores inside nested emphasis', () {
    final result = _html(r'由**“分量 \(a_{i,j}\) 与 $b_i$”**得到。', math: true);
    expect(result, contains('<p>由<strong>“分量 <ai-math-inline '));
    expect(result, contains('>a_{i,j}</ai-math-inline> 与 '));
    expect(result, contains('>b_i</ai-math-inline>”</strong>得到。</p>'));
  });

  test('keeps unclosed streaming emphasis as source text', () {
    for (final source in ['以**“重点', '以***“重点', '**学习时需注意：', '中*“']) {
      expect(_html(source), '<p>$source</p>\n');
    }
  });

  test('does not change non-CJK CommonMark and rule-of-three behavior', () {
    for (final source in [
      'plain **bold** and *italic*',
      'foo_bar_baz',
      'foo__bar__baz',
      '**foo *bar* baz**',
      '***foo***',
      '**foo*bar**',
      '*foo**bar*',
      'a**"quoted"**b',
      'a*"quoted"*b',
      '_foo_bar_',
      'a***b**c*',
      '**foo **bar baz**',
      '***foo** bar*',
      r'\**escaped** and `a_b*c`',
      '[**link**](https://example.com/a_b)',
      '** emoji 🙂 **',
      'a**🙂**b',
      'a**“🙂”**b',
      'a__🙂__b',
    ]) {
      expect(_html(source), _html(source, cjk: false), reason: source);
    }
  });

  test('keeps underscore intra-word restrictions in CJK text', () {
    for (final source in ['这__“重点”__好', '中_文_字', '中__文__字']) {
      expect(_html(source), _html(source, cjk: false), reason: source);
    }
  });

  test(
    'recognizes supplementary Han, Hangul and width variation selectors',
    () {
      expect(_html('𠀀**“重点”**𠀀'), '<p>𠀀<strong>“重点”</strong>𠀀</p>\n');
      expect(_html('한**“강조”**글'), '<p>한<strong>“강조”</strong>글</p>\n');
      expect(
        _html('中\ufe00**“重点”**文'),
        '<p>中\ufe00<strong>“重点”</strong>文</p>\n',
      );
      expect(
        _html('“\ufe01**“重点”**文'),
        '<p>“\ufe01<strong>“重点”</strong>文</p>\n',
      );
    },
  );

  test('handles long unmatched runs without truncation or source mutation', () {
    final stars = List.filled(16000, '*').join();
    final source = '中$stars“尾部';
    final watch = Stopwatch()..start();
    final result = _html(source);
    watch.stop();
    expect(result, '<p>$source</p>\n');
    // A single run must be scanned once; this generous limit detects an
    // accidental recursive/rescanning implementation without timing flakiness.
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
  });
}
