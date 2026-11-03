import 'dart:convert';
import 'package:characters/characters.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import 'package:xml/xml.dart';
import 'podcast_models.dart';

/// Single-line label. Titles, authors and transcript cues must not keep the
/// paragraph breaks that [podcastArticleText] preserves for show notes.
String podcastPlainText(String text) => (html.parseFragment(text).text ?? '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

const _articleParagraphTags = {
  'address',
  'article',
  'blockquote',
  'dd',
  'div',
  'dt',
  'figcaption',
  'footer',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'header',
  'p',
  'pre',
  'section',
  'tr',
};

/// Publishers encode show notes as HTML blocks or plain lines: a paragraph,
/// then a timestamp outline, then a sign-off. Collapsing that to one line is
/// what made the notes unreadable.
String podcastArticleText(String source) {
  final buffer = StringBuffer();
  void breakLine({bool paragraph = false}) {
    final current = buffer.toString();
    if (current.isEmpty) return;
    if (!current.endsWith('\n')) buffer.write('\n');
    if (paragraph && !buffer.toString().endsWith('\n\n')) buffer.write('\n');
  }

  void walk(Node node) {
    if (node is Text) {
      buffer.write(node.data);
      return;
    }
    if (node is! Element) {
      for (final child in node.nodes) {
        walk(child);
      }
      return;
    }
    final tag = node.localName?.toLowerCase() ?? '';
    if (tag == 'script' || tag == 'style') return;
    if (tag == 'br' || tag == 'hr') {
      buffer.write('\n');
      return;
    }
    if (tag == 'li') {
      breakLine();
      buffer.write('• ');
    }
    for (final child in node.nodes) {
      walk(child);
    }
    if (tag == 'li') {
      breakLine();
    } else if (_articleParagraphTags.contains(tag) ||
        tag == 'ul' ||
        tag == 'ol') {
      breakLine(paragraph: true);
    }
  }

  final fragment = html.parseFragment(source);
  for (final node in fragment.nodes) {
    walk(node);
  }
  return _tidyPodcastArticle(buffer.toString());
}

String _tidyPodcastArticle(String raw) {
  final lines = raw
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll('\u2028', '\n')
      .replaceAll('\u2029', '\n')
      .split('\n')
      .map(
        (line) => line.replaceAll(RegExp(r'[ \t\u00a0\u3000]+'), ' ').trim(),
      );
  final out = <String>[];
  var blank = false;
  for (final line in lines) {
    if (line.isEmpty) {
      if (out.isNotEmpty && !blank) {
        out.add('');
        blank = true;
      }
      continue;
    }
    blank = false;
    out.add(line);
  }
  while (out.isNotEmpty && out.last.isEmpty) {
    out.removeLast();
  }
  return out.join('\n');
}

enum PodcastArticleKind { prose, heading, cue }

/// One source line, classified only when the publisher already isolated it.
class PodcastArticleLine {
  const PodcastArticleLine(
    this.kind,
    this.text, {
    this.time,
    this.blankBefore = false,
  });
  final PodcastArticleKind kind;
  final String text;

  /// Clock text exactly as published, such as `00:01:56`.
  final String? time;

  /// A blank line in the source, usually an HTML paragraph boundary.
  final bool blankBefore;
}

final _articleClockPattern = RegExp(r'\d{1,3}[:：]\d{2}(?:[:：]\d{2})?');
const _articleClockBrackets = {
  '[': ']',
  '［': '］',
  '(': ')',
  '（': '）',
  '【': '】',
};
final _articleCuePrefix = RegExp(r'^(?:[•·*\-]\s+|\d+[.)]\s+)');
final _articleCueSeparator = RegExp(r'^\s*(?:[-–—|｜:：]\s*)?');

({String time, String text})? _articleCue(String body) {
  final close = _articleClockBrackets[body.isEmpty ? '' : body[0]];
  final match = _articleClockPattern.matchAsPrefix(body, close == null ? 0 : 1);
  if (match == null) return null;
  final time = match.group(0)!;
  final parts = time.replaceAll('：', ':').split(':').map(int.parse).toList();
  if (parts.last >= 60 || (parts.length == 3 && parts[1] >= 60)) return null;
  var end = match.end;
  if (close != null) {
    if (!body.startsWith(close, end)) return null;
    end += close.length;
  } else if (end < body.length &&
      RegExp(r'[\d:：.\]］)）】]').hasMatch(body[end])) {
    // Do not make an invalid/partial clock, decimal or mismatched bracket
    // into a link by accepting only its first few digits.
    return null;
  }
  return (
    time: time,
    text: body.substring(end).replaceFirst(_articleCueSeparator, '').trim(),
  );
}

final _headingBrackets = RegExp(r'^【[^【】]{1,20}】$');

PodcastArticleLine _classifyArticleLine(
  String line, {
  required bool blankBefore,
}) {
  final body = line.replaceFirst(_articleCuePrefix, '');
  final cue = _articleCue(body);
  if (cue != null) {
    return PodcastArticleLine(
      PodcastArticleKind.cue,
      cue.text,
      time: cue.time,
      blankBefore: blankBefore,
    );
  }
  // Graphemes, so a ZWJ emoji plus a short label still counts as a heading.
  final heading =
      _headingBrackets.hasMatch(body) ||
      (body.characters.length <= 16 &&
          (body.endsWith('：') || body.endsWith(':')) &&
          !RegExp(r'[。！？，,.!?]').hasMatch(body));
  return PodcastArticleLine(
    heading ? PodcastArticleKind.heading : PodcastArticleKind.prose,
    line,
    blankBefore: blankBefore,
  );
}

List<PodcastArticleLine> podcastArticleLines(String source) {
  final text = podcastArticleText(source);
  if (text.isEmpty) return const [];
  final lines = <PodcastArticleLine>[];
  var blankBefore = false;
  for (final line in text.split('\n')) {
    if (line.isEmpty) {
      blankBefore = lines.isNotEmpty;
      continue;
    }
    lines.add(_classifyArticleLine(line, blankBefore: blankBefore));
    blankBefore = false;
  }
  return lines;
}

int podcastDuration(String value) {
  final pieces = value.trim().replaceAll('：', ':').split(':');
  double seconds = 0;
  for (final piece in pieces) {
    final part = double.tryParse(piece);
    if (part == null || !part.isFinite || part < 0) return 0;
    seconds = seconds * 60 + part;
  }
  return (seconds * 1000).round();
}

/// Podcasting 2.0 JSON transcript segments use seconds and a textual body.
String podcastJsonTranscriptToSrt(String source) {
  final json = jsonDecode(source);
  final rows = json is List
      ? json
      : json is Map
      ? json['segments'] ?? json['transcript']
      : null;
  if (rows is! List) throw const FormatException('文字稿没有可识别的时间轴');
  int milliseconds(Object? value) => value is num
      ? (value * 1000).round()
      : podcastDuration(value?.toString() ?? '');
  String timestamp(int value) {
    final seconds = value ~/ 1000;
    return '${(seconds ~/ 3600).toString().padLeft(2, '0')}:${(seconds ~/ 60 % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')},${(value % 1000).toString().padLeft(3, '0')}';
  }

  final output = StringBuffer();
  var index = 0;
  for (final row in rows.whereType<Map>()) {
    final startValue = row['startTime'] ?? row['start'];
    final endValue = row['endTime'] ?? row['end'];
    if (startValue == null || endValue == null) continue;
    final start = milliseconds(startValue), end = milliseconds(endValue);
    final text = podcastPlainText(
      (row['body'] ?? row['text'] ?? '').toString(),
    );
    if (start < 0 || end <= start || text.isEmpty) continue;
    output.writeln(
      '${++index}\n${timestamp(start)} --> ${timestamp(end)}\n$text\n',
    );
  }
  if (index == 0) throw const FormatException('文字稿没有有效的字幕段落');
  return output.toString();
}

int podcastDate(String value) {
  final iso = DateTime.tryParse(value.trim());
  if (iso != null) return iso.millisecondsSinceEpoch;
  final match = RegExp(
    r'(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{2}):(\d{2})(?::(\d{2}))?\s*([+-]\d{4}|GMT|UTC|UT|Z)?',
    caseSensitive: false,
  ).firstMatch(value);
  if (match == null) return 0;
  const months = [
    'jan',
    'feb',
    'mar',
    'apr',
    'may',
    'jun',
    'jul',
    'aug',
    'sep',
    'oct',
    'nov',
    'dec',
  ];
  final month = months.indexOf(match[2]!.toLowerCase()) + 1;
  if (month == 0) return 0;
  var time = DateTime.utc(
    int.parse(match[3]!),
    month,
    int.parse(match[1]!),
    int.parse(match[4]!),
    int.parse(match[5]!),
    int.tryParse(match[6] ?? '') ?? 0,
  );
  final zone = match[7] ?? '';
  if (zone.startsWith('+') || zone.startsWith('-')) {
    final minutes =
        int.parse(zone.substring(1, 3)) * 60 + int.parse(zone.substring(3));
    time = time.subtract(
      Duration(minutes: zone.startsWith('-') ? -minutes : minutes),
    );
  }
  return time.millisecondsSinceEpoch;
}

String _decode(List<int> bytes) {
  if (bytes.length > 1 &&
      ((bytes[0] == 255 && bytes[1] == 254) ||
          (bytes[0] == 254 && bytes[1] == 255))) {
    final little = bytes[0] == 255;
    return String.fromCharCodes([
      for (var i = 2; i + 1 < bytes.length; i += 2)
        little ? bytes[i] | bytes[i + 1] << 8 : bytes[i] << 8 | bytes[i + 1],
    ]);
  }
  final header = ascii.decode(
    bytes.take(160).map((b) => b < 128 ? b : 32).toList(),
  );
  if (RegExp(
    r'encoding\s*=\s*["\x27](gbk|gb2312|gb18030)',
    caseSensitive: false,
  ).hasMatch(header)) {
    return gbk.decode(bytes);
  }
  return utf8.decode(bytes, allowMalformed: true).replaceFirst('\uFEFF', '');
}

class PodcastFeedParser {
  const PodcastFeedParser();
  PodcastFeed parse(
    List<int> bytes,
    String feedUrl, {
    String? channelId,
    int? nowMs,
  }) {
    final document = XmlDocument.parse(_decode(bytes));
    final root = document.rootElement;
    final isAtom = root.name.local == 'feed';
    final channel = isAtom ? root : root.getElement('channel');
    if (channel == null || (!isAtom && root.name.local != 'rss')) {
      throw const FormatException('这个链接没有返回可识别的播客订阅源');
    }
    final base = Uri.parse(feedUrl);
    String resolve(String? value) {
      if (value == null || value.trim().isEmpty) return '';
      final uri = base.resolve(value.trim());
      return ['http', 'https'].contains(uri.scheme) ? uri.toString() : '';
    }

    Iterable<XmlElement> children(XmlElement e, String name) =>
        e.childElements.where((c) => c.name.local == name);
    String text(XmlElement e, List<String> names) {
      for (final name in names) {
        final matching = children(e, name).toList()
          ..sort(
            (a, b) => (a.name.prefix == null ? 0 : 1).compareTo(
              b.name.prefix == null ? 0 : 1,
            ),
          );
        for (final c in matching) {
          if (c.innerText.trim().isNotEmpty) return c.innerText.trim();
        }
      }
      return '';
    }

    String image(XmlElement e) {
      for (final c in children(e, 'image')) {
        final value =
            c.getAttribute('href') ?? c.getAttribute('url') ?? text(c, ['url']);
        if (resolve(value).isNotEmpty) return resolve(value);
      }
      return resolve(text(e, ['logo', 'icon']));
    }

    String link(XmlElement e, String rel) {
      for (final c in children(e, 'link')) {
        if ((c.getAttribute('rel') ?? 'alternate') == rel) {
          return resolve(c.getAttribute('href') ?? c.innerText);
        }
      }
      return '';
    }

    final id =
        channelId ??
        'podcast_${podcastHash(podcastCanonicalUrl(feedUrl)).substring(0, 32)}';
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final parsed = PodcastChannel(
      id: id,
      feedUrl: feedUrl,
      title: podcastPlainText(text(channel, ['title'])),
      author: podcastPlainText(
        text(channel, ['author', 'creator', 'managingEditor']),
      ),
      description: text(channel, ['description', 'subtitle', 'summary']),
      imageUrl: image(channel),
      link: link(channel, 'alternate'),
      language: text(channel, ['language']),
      guid: text(channel, ['guid']),
      nextPage: link(channel, 'next').isEmpty ? null : link(channel, 'next'),
    );
    if (parsed.title.isEmpty) parsed.title = base.host;
    final entries = children(channel, isAtom ? 'entry' : 'item');
    final episodes = <String, PodcastEpisode>{};
    for (final entry in entries) {
      final media = <String, PodcastMedia>{};
      void add(
        String? value,
        String? type,
        String? length, [
        String label = '',
      ]) {
        final url = resolve(value);
        if (url.isEmpty) return;
        media.putIfAbsent(
          url,
          () => PodcastMedia(
            url: url,
            mimeType: type ?? '',
            length: int.tryParse(length ?? ''),
            label: label,
          ),
        );
      }

      for (final child in entry.childElements) {
        switch (child.name.local) {
          case 'enclosure':
            add(
              child.getAttribute('url'),
              child.getAttribute('type'),
              child.getAttribute('length'),
            );
          case 'link':
            if (child.getAttribute('rel') == 'enclosure') {
              add(
                child.getAttribute('href'),
                child.getAttribute('type'),
                child.getAttribute('length'),
              );
            }
          case 'content':
            final type = child.getAttribute('type') ?? '';
            if (type.startsWith('audio/') || type.startsWith('video/')) {
              add(
                child.getAttribute('url'),
                type,
                child.getAttribute('fileSize'),
              );
            }
          case 'alternateEnclosure':
            for (final source in child.childElements.where(
              (c) => c.name.local == 'source',
            )) {
              add(
                source.getAttribute('uri'),
                child.getAttribute('type'),
                child.getAttribute('length'),
                child.getAttribute('title') ?? '',
              );
            }
        }
      }
      if (media.isEmpty) continue;
      final title = podcastPlainText(text(entry, ['title']));
      final guid = text(entry, ['guid', 'id']);
      final pub = podcastDate(
        text(entry, ['pubDate', 'published', 'date', 'updated']),
      );
      final stable = guid.isNotEmpty
          ? 'guid:$guid'
          : 'media:${podcastCanonicalUrl(media.values.first.url)}';
      final episodeId = 'pe_${podcastHash('$id|$stable').substring(0, 40)}';
      final transcripts = children(entry, 'transcript')
          .map(
            (e) => PodcastTranscript(
              url: resolve(e.getAttribute('url')),
              type: e.getAttribute('type') ?? '',
              language: e.getAttribute('language') ?? '',
            ),
          )
          .where((t) => t.url.isNotEmpty)
          .toList();
      final chapterElements = children(entry, 'chapters');
      episodes.putIfAbsent(
        episodeId,
        () => PodcastEpisode(
          id: episodeId,
          channelId: id,
          title: title.isEmpty ? '未命名节目' : title,
          guid: guid,
          description: text(entry, [
            'encoded',
            'description',
            'content',
            'summary',
          ]),
          imageUrl: image(entry),
          link: link(entry, 'alternate'),
          media: media.values.toList(),
          publishedMs: pub,
          durationMs: podcastDuration(text(entry, ['duration'])),
          season: int.tryParse(text(entry, ['season'])),
          number: int.tryParse(text(entry, ['episode'])),
          chaptersUrl: chapterElements.isEmpty
              ? null
              : resolve(chapterElements.first.getAttribute('url')),
          transcripts: transcripts,
          discoveredMs: now,
        ),
      );
    }
    return PodcastFeed(parsed, episodes.values.toList());
  }

  List<String> parseOpml(String source) {
    final document = XmlDocument.parse(source);
    if (document.rootElement.name.local.toLowerCase() != 'opml') {
      throw const FormatException('这不是 OPML 订阅列表');
    }
    return document.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'outline')
        .map((e) => e.getAttribute('xmlUrl') ?? e.getAttribute('xmlurl') ?? '')
        .where(
          (v) =>
              Uri.tryParse(v)?.hasAbsolutePath == true &&
              ['http', 'https'].contains(Uri.tryParse(v)?.scheme),
        )
        .toSet()
        .toList();
  }

  String exportOpml(Iterable<PodcastChannel> channels) {
    final builder = XmlBuilder()
      ..processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element(
      'opml',
      attributes: {'version': '2.0'},
      nest: () {
        builder.element(
          'head',
          nest: () => builder.element('title', nest: 'Fluent Player 播客订阅'),
        );
        builder.element(
          'body',
          nest: () {
            for (final c in channels) {
              builder.element(
                'outline',
                attributes: {
                  'type': 'rss',
                  'text': c.title,
                  'title': c.title,
                  'xmlUrl': c.feedUrl,
                  if (c.link.isNotEmpty) 'htmlUrl': c.link,
                },
              );
            }
          },
        );
      },
    );
    return builder.buildDocument().toXmlString(pretty: true);
  }
}
