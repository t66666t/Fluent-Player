import 'dart:async';
import '../../services/app_haptics.dart';
import '../../services/settings_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import '../../services/app_web_navigation.dart';
import 'ai_math.dart';
import 'ai_math_syntax.dart';
import 'ai_math_table_syntax.dart';
import 'ai_markdown_emphasis.dart';
import 'ai_chat_typography.dart';
import '../../theme/app_typography.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// GFM is parsed by the maintained Flutter Markdown implementation. The app
/// never interprets generated HTML, embeds remote images, or executes code.
class AiMarkdown extends StatefulWidget {
  const AiMarkdown({
    super.key,
    required this.data,
    this.onSeek,
    this.isStreaming = false,
  });

  final String data;
  final ValueChanged<Duration>? onSeek;
  final bool isStreaming;

  static bool containsMath(String text) =>
      text.contains(r'\(') ||
      text.contains(r'\[') ||
      text.contains(r'\begin{') ||
      text.contains(r'$$') ||
      RegExp(r'\$[^\s$][^$\n]*\$(?!\d)').hasMatch(text) ||
      RegExp(r'```(?:math|latex|tex)\b', caseSensitive: false).hasMatch(text);

  static Duration? timestamp(String value) {
    final match = RegExp(
      r'^(?:(\d{1,3}):)?(\d{1,2}):(\d{2})$',
    ).firstMatch(value.trim());
    if (match == null) return null;
    final hours = int.tryParse(match.group(1) ?? '0') ?? 0;
    final minutes = int.parse(match.group(2)!);
    final seconds = int.parse(match.group(3)!);
    if (seconds > 59 || (match.group(1) != null && minutes > 59)) return null;
    return Duration(hours: hours, minutes: minutes, seconds: seconds);
  }

  @override
  State<AiMarkdown> createState() => _AiMarkdownState();
}

class _AiMarkdownState extends State<AiMarkdown> {
  final _links = <String?, TapGestureRecognizer>{};
  // ExpansionTile stores a bool under the enclosing message's PageStorage
  // identity. Markdown tables/code use double scroll offsets; keep those in a
  // separate bucket so a resize cannot restore an expansion flag as an offset.
  final _scrollStorage = PageStorageBucket();
  Set<String?>? _latestLinkPass;

  @override
  void dispose() {
    for (final recognizer in _links.values) {
      recognizer.dispose();
    }
    super.dispose();
  }

  TapGestureRecognizer _link(String? href, Set<String?> used) {
    if (used.isEmpty) {
      _latestLinkPass = used;
      // Only prune after an actual Markdown parse, not after a resize that
      // reused its cached children. Retained links survive in-flight taps.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !identical(_latestLinkPass, used)) return;
        for (final key
            in _links.keys.where((key) => !used.contains(key)).toList()) {
          _links.remove(key)!.dispose();
        }
      });
    }
    used.add(href);
    return _links.putIfAbsent(
      href,
      () => TapGestureRecognizer()..onTap = () => _openLink(context, href),
    );
  }

  Future<void> _openLink(BuildContext context, String? href) async {
    if (href == null) return;
    final uri = Uri.tryParse(href);
    if (uri == null) return;
    if (uri.scheme == 'video' && uri.host == 'seek') {
      final ms = int.tryParse(uri.queryParameters['ms'] ?? '');
      if (ms != null && ms >= 0) {
        widget.onSeek?.call(Duration(milliseconds: ms));
      }
      return;
    }
    final time = AiMarkdown.timestamp(href.replaceFirst('#', ''));
    if (time != null) {
      widget.onSeek?.call(time);
      return;
    }
    if ((uri.scheme != 'https' && uri.scheme != 'http') || uri.host.isEmpty) {
      return;
    }
    try {
      await AppWebNavigation.open(context, uri);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('无法打开链接')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = DefaultSelectionStyle.merge(
      selectionColor:
          (theme.textSelectionTheme.selectionColor ?? theme.colorScheme.primary)
              .withValues(alpha: .3),
      child: LayoutBuilder(
        builder: (context, constraints) => AiMathViewport(
          maxWidth: constraints.maxWidth,
          child: _body(context, double.infinity),
        ),
      ),
    );
    final selectable = SelectionContainer.maybeOf(context) == null
        ? SelectionArea(child: body)
        : body;
    return PageStorage(bucket: _scrollStorage, child: selectable);
  }

  Widget _body(BuildContext context, double width) {
    final colors = Theme.of(context).colorScheme;
    final typography = AiChatTypography.of(context);
    return MarkdownBody(
      key: ValueKey((widget.isStreaming, widget.onSeek != null)),
      data: widget.data,
      // One native selection region spans prose, code and custom formulas.
      selectable: false,
      softLineBreak: true,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      blockSyntaxes: const [AiMathBlockSyntax(), AiMathTableSyntax()],
      inlineSyntaxes: <md.InlineSyntax>[
        AiMathInlineSyntax(),
        AiMarkdownEmphasisSyntax(),
        if (widget.onSeek != null) _TimestampSyntax(),
        if (widget.onSeek != null) _TimestampAwareLinkSyntax(),
      ],
      builders: <String, MarkdownElementBuilder>{
        'a': _StableLinkBuilder(_link, widget.isStreaming),
        'pre': _CodeBlockBuilder(width, widget.isStreaming, typography),
        aiInlineMathTag: _MathBuilder(width, widget.isStreaming, block: false),
        aiDisplayMathTag: _MathBuilder(width, widget.isStreaming, block: true),
      },
      imageBuilder: (uri, title, alt) => Text(
        alt == null || alt.isEmpty ? '[图片]' : '[图片：$alt]',
        style: TextStyle(color: colors.onSurfaceVariant),
      ),
      onTapLink: (text, href, title) => _openLink(context, href),
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        p: typography.bodyStyle.copyWith(color: colors.onSurface),
        // SemiBold emphasis avoids the heavy ink of a full CJK w700 bold,
        // which reads as visual noise inside long answers (mainstream chat
        // UIs cap prose emphasis at 500–600).
        strong: const TextStyle(fontWeight: AppFontWeight.heading),
        h1: TextStyle(
          color: colors.onSurface,
          fontSize: typography.heading1,
          fontWeight: FontWeight.w600,
          height: 1.3,
        ),
        h2: TextStyle(
          color: colors.onSurface,
          fontSize: typography.heading2,
          fontWeight: FontWeight.w600,
          height: 1.3,
        ),
        h3: TextStyle(
          color: colors.onSurface,
          fontSize: typography.heading3,
          fontWeight: FontWeight.w600,
          height: 1.3,
        ),
        a: TextStyle(color: colors.primary, decoration: TextDecoration.none),
        h4: typography.bodyStyle.copyWith(fontWeight: FontWeight.w600),
        h5: typography.bodyStyle.copyWith(fontWeight: FontWeight.w600),
        h6: typography.bodyStyle.copyWith(fontWeight: FontWeight.w600),
        listBullet: typography.bodyStyle.copyWith(color: colors.onSurface),
        tableBody: typography.bodyStyle.copyWith(color: colors.onSurface),
        tableHead: typography.bodyStyle.copyWith(
          color: colors.onSurface,
          fontWeight: FontWeight.w600,
        ),
        blockSpacing: typography.blockSpacing,
        listIndent: typography.dense ? 18 : 24,
        code: TextStyle(
          fontFamily: 'monospace',
          fontWeight: FontWeight.w400,
          fontSize: typography.codeSize,
          color: colors.primary,
        ),
        // Custom code blocks own their decoration; math fences stay unframed.
        codeblockDecoration: const BoxDecoration(),
        blockquoteDecoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
          border: Border(left: BorderSide(color: colors.primary, width: 3)),
        ),
        blockquotePadding: EdgeInsets.all(typography.dense ? 8 : 12),
        tableBorder: TableBorder.all(color: colors.outlineVariant),
        tableCellsPadding: EdgeInsets.all(typography.dense ? 6 : 8),
        // Readable columns scroll together on narrow sidebars. Fixed sizing
        // also avoids querying unsupported upstream math dry baselines during
        // intrinsic measurement. Long formulas retain their cell scroll.
        tableColumnWidth: _ReadableTableColumnWidth(
          (MediaQuery.textScalerOf(context).scale(typography.fontSize) * 16)
              .clamp(180.0, 320.0),
        ),
        tablePadding: const EdgeInsets.only(bottom: 12),
        tableScrollbarThumbVisibility: true,
      ),
    );
  }
}

/// Value equality keeps cached Markdown children and their selections intact
/// when a sidebar resize rebuilds an otherwise identical stylesheet.
class _ReadableTableColumnWidth extends FixedColumnWidth {
  const _ReadableTableColumnWidth(super.value);

  @override
  bool operator ==(Object other) =>
      other is _ReadableTableColumnWidth && other.value == value;

  @override
  int get hashCode => Object.hash(_ReadableTableColumnWidth, value);
}

class _TimestampSyntax extends md.InlineSyntax {
  _TimestampSyntax()
    : super(
        r'(?<![\w/:\\])(?:\[[ \t]*((?:\d{1,3}:)?\d{1,2}:\d{2})[ \t]*\](?![ \t]*[\[(])|((?:\d{1,3}:)?\d{1,2}:\d{2}))(?![\w:])',
      );

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    // Subtitle citations often arrive as [00:12]. Consume their brackets in
    // the Markdown parser, while leaving code and actual Markdown links alone.
    final text = match.group(1) ?? match.group(2)!;
    final time = AiMarkdown.timestamp(text);
    if (time == null) {
      parser.addNode(md.Text(match.group(0)!));
    } else {
      final node = md.Element.text('a', text);
      node.attributes['data-ai-timestamp'] = 'true';
      node.attributes['pad-left'] =
          '${match.start > 0 && parser.source.substring(match.start - 1, match.start).trim().isNotEmpty}';
      node.attributes['pad-right'] =
          '${match.end < parser.source.length && parser.source.substring(match.end, match.end + 1).trim().isNotEmpty}';
      node.attributes['href'] = 'video://seek?ms=${time.inMilliseconds}';
      parser.addNode(node);
    }
    return true;
  }
}

class _StableLinkBuilder extends MarkdownElementBuilder {
  _StableLinkBuilder(this.recognizerFor, this.streaming);
  final TapGestureRecognizer Function(String?, Set<String?>) recognizerFor;
  final bool streaming;
  final _used = <String?>{};

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final recognizer = recognizerFor(element.attributes['href'], _used);
    final linkStyle = (parentStyle ?? const TextStyle()).merge(preferredStyle);
    Iterable<InlineSpan> spans(md.Node node, TextStyle inheritedStyle) sync* {
      if (node is md.Text) {
        yield TextSpan(
          text: node.text,
          style: inheritedStyle,
          recognizer: recognizer,
        );
        return;
      }
      final child = node as md.Element;
      final style = switch (child.tag) {
        'strong' => const TextStyle(fontWeight: AppFontWeight.heading),
        'em' => const TextStyle(fontStyle: FontStyle.italic),
        'del' => const TextStyle(decoration: TextDecoration.lineThrough),
        'code' => TextStyle(
          fontFamily: 'monospace',
          fontWeight: FontWeight.w400,
          fontSize: AiChatTypography.of(context).codeSize,
        ),
        _ => null,
      };
      final childStyle = inheritedStyle.merge(style);
      if (child.tag == aiInlineMathTag) {
        yield _inlineMathSpan(
          child,
          childStyle,
          streaming,
          onTap: recognizer.onTap,
        );
        return;
      }
      if (child.tag == 'br') {
        yield TextSpan(text: '\n', style: childStyle);
        return;
      }
      if (child.tag == 'img') {
        yield TextSpan(
          text: '[图片：${child.attributes['alt'] ?? ''}]',
          style: childStyle,
          recognizer: recognizer,
        );
        return;
      }
      for (final node in child.children ?? <md.Node>[]) {
        yield* spans(node, childStyle);
      }
    }

    return Text.rich(
      TextSpan(
        style: linkStyle,
        children: [
          if (element.attributes['pad-left'] == 'true')
            TextSpan(text: ' ', style: parentStyle),
          ...?element.children?.expand((node) => spans(node, linkStyle)),
          if (element.attributes['pad-right'] == 'true')
            TextSpan(text: ' ', style: parentStyle),
        ],
      ),
    );
  }
}

/// An explicit Markdown link owns its destination. Automatic timestamps in
/// its label must not create nested anchors that override that destination.
class _TimestampAwareLinkSyntax extends md.LinkSyntax {
  @override
  md.Node createNode(
    String destination,
    String? title, {
    required List<md.Node> Function() getChildren,
  }) => super.createNode(
    destination,
    title,
    getChildren: () => _restoreLabel(getChildren()),
  );

  List<md.Node> _restoreLabel(List<md.Node> nodes) {
    for (var i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      if (node is! md.Element) continue;
      if (node.attributes['data-ai-timestamp'] == 'true') {
        nodes[i] = md.Text(node.textContent);
      } else if (node.children != null) {
        _restoreLabel(node.children!);
      }
    }
    return nodes;
  }
}

class _CodeBlockBuilder extends MarkdownElementBuilder {
  _CodeBlockBuilder(this.width, this.streaming, this.typography);
  final double width;
  final bool streaming;
  final AiChatTextMetrics typography;
  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final child = element.children?.whereType<md.Element>().firstOrNull;
    final language = (child?.attributes['class'] ?? '').replaceFirst(
      'language-',
      '',
    );
    if (const {'math', 'latex', 'tex'}.contains(language.toLowerCase())) {
      return AiMathFormula(
        source: element.textContent,
        maxWidth: width,
        block: true,
        complete: !streaming,
        streaming: streaming,
        textStyle: typography.bodyStyle,
      );
    }
    return _CodeBlock(code: element.textContent, language: language);
  }
}

class _MathBuilder extends MarkdownElementBuilder {
  _MathBuilder(this.width, this.streaming, {required this.block});
  final double width;
  final bool streaming, block;

  @override
  bool isBlockElement() => block;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    if (!block) {
      // The Markdown builder merges Text/RichText into a single paragraph.
      // Returning the formula widget itself instead makes it a Wrap child,
      // splitting prose into independently wrapped text blocks.
      return Text.rich(
        TextSpan(
          children: [
            _inlineMathSpan(
              element,
              preferredStyle ??
                  parentStyle ??
                  AiChatTypography.of(context).bodyStyle,
              streaming,
            ),
          ],
        ),
      );
    }
    final formula = AiMathFormula(
      source: element.textContent,
      copySource: element.attributes['copy-source'],
      maxWidth: width,
      block: block,
      display: element.attributes['display'] == 'true',
      complete: element.attributes['complete'] != 'false',
      streaming: streaming,
      textStyle:
          preferredStyle ??
          parentStyle ??
          AiChatTypography.of(context).bodyStyle,
    );
    final suffix = element.attributes['suffix'];
    return suffix == null
        ? formula
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              formula,
              AiMarkdown(data: suffix, isStreaming: streaming),
            ],
          );
  }
}

WidgetSpan _inlineMathSpan(
  md.Element element,
  TextStyle? style,
  bool streaming, {
  GestureTapCallback? onTap,
}) {
  Widget formula = AiMathFormula(
    source: element.textContent,
    copySource: element.attributes['copy-source'],
    maxWidth: double.infinity,
    display: element.attributes['display'] == 'true',
    complete: element.attributes['complete'] != 'false',
    streaming: streaming,
    textStyle: style,
  );
  if (onTap != null) formula = GestureDetector(onTap: onTap, child: formula);
  return WidgetSpan(
    alignment: PlaceholderAlignment.baseline,
    baseline: TextBaseline.alphabetic,
    // WidgetSpan already scales its child with the paragraph's TextScaler.
    // Let it scale once, including fallback text and selection geometry.
    child: MediaQuery.withNoTextScaling(child: formula),
  );
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.code, required this.language});
  final String code;
  final String language;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final typography = AiChatTypography.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectionContainer.disabled(
            child: Padding(
              padding: const EdgeInsets.only(left: 12, right: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      language.isEmpty ? '代码' : language,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  DesktopButtonClickRegion(
                    child: IconButton(
                      iconSize: 16,
                      tooltip: '复制代码',
                      icon: const Icon(Icons.copy_outlined),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: code));
                        if (context.mounted) {
                          unawaited(AppHaptics.lightTap(SettingsService()));
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Text(
              code.trimRight(),
              style: TextStyle(
                fontFamily: 'monospace',
                fontWeight: FontWeight.w400,
                fontSize: typography.codeSize,
                height: 1.5,
                color: colors.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
