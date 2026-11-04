import 'package:flutter/material.dart';
import 'podcast_feed_parser.dart';
import 'podcast_typography.dart';

/// Reading layout for a show-notes article on the dark player surface.
///
/// Paragraphs stay paragraphs. A publisher timestamp outline becomes a
/// scannable column instead of running into the prose around it.
class PodcastArticleView extends StatelessWidget {
  const PodcastArticleView({super.key, required this.source, this.onSeek});

  final String source;

  /// Clock label from the tapped outline row, such as `00:01:56`.
  final ValueChanged<String>? onSeek;

  static const seekColor = Color(0xFFA9D5FF);

  static const _prose = TextStyle(
    fontFamily: PodcastType.reading,
    fontFamilyFallback: <String>[PodcastType.ui],
    fontWeight: FontWeight.w400,
    color: Color(0xC7FFFFFF),
    fontSize: 15,
    height: 1.7,
  );
  static const _heading = TextStyle(
    fontFamily: PodcastType.reading,
    fontFamilyFallback: <String>[PodcastType.ui],
    fontWeight: FontWeight.w700,
    color: Color(0xF2FFFFFF),
    fontSize: 15,
    height: 1.4,
  );
  static const _cue = TextStyle(
    fontFamily: PodcastType.reading,
    fontFamilyFallback: <String>[PodcastType.ui],
    fontWeight: FontWeight.w500,
    color: Color(0xE6FFFFFF),
    fontSize: 15,
    height: 1.35,
  );
  static const _time = TextStyle(
    fontFamily: PodcastType.figures,
    fontFamilyFallback: PodcastType.figureFallback,
    fontWeight: FontWeight.w500,
    color: Color(0x8FFFFFFF),
    fontSize: 13,
    height: 1.35,
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
  );

  @override
  Widget build(BuildContext context) {
    final lines = podcastArticleLines(source);
    if (lines.isEmpty) {
      return const SelectableText('这一集暂无简介。', style: _prose);
    }
    final firstCue = lines.indexWhere(
      (line) => line.kind == PodcastArticleKind.cue,
    );
    var timeWidth = 84.0;
    for (final line in lines.where(
      (line) => line.kind == PodcastArticleKind.cue,
    )) {
      final text = TextPainter(
        text: TextSpan(text: line.time, style: _time),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      if (text.width + 4 > timeWidth) timeWidth = text.width + 4;
      text.dispose();
    }
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < lines.length; i++)
            _line(
              lines,
              i,
              timeWidth: timeWidth,
              showHint: onSeek != null && i == firstCue,
            ),
        ],
      ),
    );
  }

  Widget _line(
    List<PodcastArticleLine> lines,
    int index, {
    required double timeWidth,
    required bool showHint,
  }) {
    final line = lines[index];
    final previous = index == 0 ? null : lines[index - 1];
    final top = _gap(line, previous);
    if (line.kind == PodcastArticleKind.cue) {
      final interactive = onSeek != null;
      final row = ConstrainedBox(
        constraints: BoxConstraints(minHeight: interactive ? 48 : 0),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final clock = Text(
              line.time!,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: interactive
                  ? _time.copyWith(
                      color: seekColor,
                      decoration: TextDecoration.underline,
                      decorationColor: seekColor,
                    )
                  : _time,
            );
            const play = Icon(
              Icons.play_circle_outline_rounded,
              size: 18,
              color: seekColor,
            );
            if (constraints.maxWidth <
                timeWidth + (interactive ? 26 : 0) + 128) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(child: clock),
                        if (interactive) ...[const SizedBox(width: 8), play],
                      ],
                    ),
                    if (line.text.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(line.text, style: _cue),
                    ],
                  ],
                ),
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                SizedBox(width: timeWidth, child: clock),
                const SizedBox(width: 12),
                Expanded(child: Text(line.text, style: _cue)),
                if (interactive) ...[const SizedBox(width: 8), play],
              ],
            );
          },
        ),
      );
      final content = !interactive
          ? row
          : Semantics(
              button: true,
              label: '跳到 ${line.time} ${line.text}',
              child: Tooltip(
                message: '跳到 ${line.time}',
                // Paint feedback above the player's opaque background. Use a local
                // ripple so a quick tap remains visible after pointer release.
                child: Material(
                  type: MaterialType.transparency,
                  borderRadius: BorderRadius.circular(8),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => onSeek!(line.time!),
                    borderRadius: BorderRadius.circular(8),
                    splashFactory: InkRipple.splashFactory,
                    splashColor: const Color(0x38A9D5FF),
                    highlightColor: const Color(0x24A9D5FF),
                    hoverColor: const Color(0x14A9D5FF),
                    focusColor: const Color(0x24A9D5FF),
                    child: ExcludeSemantics(child: row),
                  ),
                ),
              ),
            );
      return Padding(
        padding: EdgeInsets.only(top: top),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showHint)
              Padding(
                key: const ValueKey('podcast-timestamp-hint'),
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    const Icon(
                      Icons.touch_app_outlined,
                      size: 16,
                      color: seekColor,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '点击时间或条目跳转播放',
                        style: PodcastType.meta.copyWith(
                          fontSize: 12,
                          height: 1.45,
                          color: seekColor,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            content,
          ],
        ),
      );
    }
    final style = line.kind == PodcastArticleKind.heading ? _heading : _prose;
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: Text(line.text, style: style),
    );
  }

  double _gap(PodcastArticleLine line, PodcastArticleLine? previous) {
    if (previous == null) return 0;
    final bullet =
        line.kind == PodcastArticleKind.prose &&
        previous.kind == PodcastArticleKind.prose &&
        line.text.startsWith('• ') &&
        previous.text.startsWith('• ');
    if (bullet) return line.blankBefore ? 12 : 2;
    // <p> around each timestamp inserts a blank line; the outline is still one list.
    if (line.kind == PodcastArticleKind.cue &&
        previous.kind == PodcastArticleKind.cue) {
      return 0;
    }
    if (line.blankBefore || line.kind == PodcastArticleKind.heading) return 18;
    if (previous.kind == PodcastArticleKind.heading) return 8;
    return 12;
  }
}
