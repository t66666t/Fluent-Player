import 'bilibili_url_parser.dart';

enum ClipboardLinkKind { web, bilibili, douyin, podcast, feed }

bool _isDouyinHost(String host) => const [
  'douyin.com',
  'iesdouyin.com',
].any((domain) => host == domain || host.endsWith('.$domain'));

/// A destination hint, never a claim about a page's contents or availability.
class ClipboardLink {
  const ClipboardLink(this.url, this.kind, this.label, {this.bilibili});

  final String url;
  final ClipboardLinkKind kind;
  final String label;
  final BilibiliLinkTarget? bilibili;

  /// The app has a dedicated Douyin workflow; generic download is not an
  /// alternative for it. Check the source host as well, so callers supplying
  /// a generic link cannot expose that unusable entry for a Douyin source.
  bool get offersGenericDownload {
    if (kind == ClipboardLinkKind.douyin) return false;
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    return !_isDouyinHost(host);
  }

  // Do not remove unknown parameters, signatures, fragments or playback options.
  String get identity => url.replaceFirstMapped(
    RegExp(r'^(https?://)([^/?#]+)', caseSensitive: false),
    (match) => '${match[1]!.toLowerCase()}${match[2]!.toLowerCase()}',
  );
}

/// Offline extraction for unsolicited clipboard prompts. Manual input pages
/// intentionally accept more formats (IDs, search terms, local addresses).
class ClipboardLinkDetector {
  static const maxTextLength = 256 * 1024;
  static const maxLinks = 32;
  static const maxUrlLength = 8192;
  static final _start = RegExp(
    r'https?\\?://|(?:www\.|m\.|v\.)?(?:bilibili\.com|b23\.tv|bili2233\.cn|douyin\.com|iesdouyin\.com|youtu\.be|youtube\.com|xiaoyuzhoufm\.com|podcasts\.apple\.com)/',
    caseSensitive: false,
  );
  static final _markdown = RegExp(r'\[[^\n]{0,4096}?\]\(');
  static final _tokenStart = RegExp(
    '${_markdown.pattern}|${_start.pattern}',
    caseSensitive: false,
  );
  static final _bareId = RegExp(
    r'^(?:BV[0-9A-Za-z]{10}|av\d{1,19}|(?:ep|ss)\d{1,19})$',
    caseSensitive: false,
  );
  static final _domain = RegExp(
    r'^(?:[\p{L}\p{N}](?:[\p{L}\p{N}-]{0,61}[\p{L}\p{N}])?\.)+[\p{L}]{2,63}$',
    caseSensitive: false,
    unicode: true,
  );
  static final _percent = RegExp(r'%(?![0-9a-fA-F]{2})');
  static final _escapedPunctuation = RegExp(
    r'''\\([!"#$%&'()*+,\-./:;<=>?@\[\]\\^_`{|}~])''',
  );
  static const _delimiters = ' \t\r\n\u00a0\u3000<>"`，。！？、；：“”‘’【】《》';
  static const _bareHosts = [
    'bilibili.com/',
    'b23.tv/',
    'bili2233.cn/',
    'douyin.com/',
    'iesdouyin.com/',
    'youtu.be/',
    'youtube.com/',
    'xiaoyuzhoufm.com/',
    'podcasts.apple.com/',
  ];

  static List<ClipboardLink> detect(String raw) {
    if (raw.isEmpty || raw.length > maxTextLength) return const [];
    final result = <String, ClipboardLink>{};
    void add(String value) {
      final link = _classify(value);
      if (link != null) result.putIfAbsent(link.identity, () => link);
    }

    if (!_scan(raw, add)) return const [];
    if (result.length > maxLinks) return const [];

    if (result.isEmpty && _bareId.hasMatch(raw.trim())) {
      final target = parseBilibiliLink(raw);
      if (target != null) {
        final path = target.courseId != null
            ? 'cheese/play/${target.courseId}'
            : target.bangumiId != null
            ? 'bangumi/play/${target.bangumiId}'
            : 'video/${target.parseInput}';
        return [
          ClipboardLink(
            'https://www.bilibili.com/$path',
            ClipboardLinkKind.bilibili,
            '哔哩哔哩链接',
            bilibili: target,
          ),
        ];
      }
    }
    return result.values.toList(growable: false);
  }

  static int? _markdownEnd(String raw, int start) {
    var depth = 1;
    for (var i = start; i < raw.length && i - start <= maxUrlLength; i++) {
      if (raw[i] == '\\') {
        i++;
        continue;
      }
      if (raw[i] == '(') depth++;
      if (raw[i] == ')') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return null;
  }

  static bool _scan(String text, void Function(String) add) {
    var consumed = 0;
    var count = 0;
    final lower = text.toLowerCase();
    final markdownPossible = text.contains('](');
    var search = 0;
    while (search < text.length) {
      final start = _nextStart(lower, search, markdownPossible);
      if (start < 0) break;
      search = start + 1;
      final match = _tokenStart.matchAsPrefix(text, start);
      if (match == null) continue;
      if (match.start < consumed) continue;
      // Process in source order. Markdown-looking text inside an already
      // consumed URL query is data, not an independently trusted destination.
      if (text[match.start] == '[') {
        final end = _markdownEnd(text, match.end);
        if (end == null) continue;
        consumed = end + 1;
        search = consumed;
        if (++count > maxLinks) return false;
        var destination = text.substring(match.end, end).trim();
        if (destination.startsWith('<') && destination.contains('>')) {
          destination = destination.substring(1, destination.indexOf('>'));
        } else {
          destination = destination.split(RegExp(r'\s')).first;
        }
        add(destination.replaceAllMapped(_escapedPunctuation, (m) => m[1]!));
        continue;
      }
      var end = match.end;
      while (end < text.length && !_delimiters.contains(text[end])) {
        end++;
      }
      consumed = end;
      search = consumed;
      if (++count > maxLinks) return false;
      // Consume the whole token even when invalid, so an embedded URL in its
      // query/path/userinfo cannot turn into a separate trusted-site match.
      if (match.start > 0 &&
          RegExp(r'[A-Za-z0-9_@./%\\-]').hasMatch(text[match.start - 1])) {
        continue;
      }
      final prefix = text
          .substring((match.start - 12).clamp(0, text.length), match.start)
          .toLowerCase();
      if (prefix.endsWith('javascript:') ||
          prefix.endsWith('data:') ||
          prefix.endsWith('file:')) {
        continue;
      }
      if (end - match.start > maxUrlLength) continue;
      var value = text.substring(match.start, end);
      value = value.replaceFirstMapped(
        RegExp(r'^http(s?)\\:', caseSensitive: false),
        (m) => 'http${m[1]}:',
      );
      value = _trimWrappers(
        value,
        match.start > 0 ? text[match.start - 1] : null,
      );
      if (match.start > 0 &&
          text[match.start - 1] == "'" &&
          value.endsWith("'")) {
        value = value.substring(0, value.length - 1);
      }
      add(value);
    }
    return true;
  }

  // Native string searches skip long prose cheaply. Running the full
  // case-insensitive URL/Markdown expression at every Chinese character was
  // measurably slower, especially on text that cannot contain a link.
  static int _nextStart(String lower, int from, bool markdownPossible) {
    var first = lower.indexOf('http', from);
    void consider(int index) {
      if (index >= 0 && (first < 0 || index < first)) first = index;
    }

    if (markdownPossible) {
      var close = lower.indexOf('](', from);
      while (close >= 0) {
        final open = lower.indexOf(
          '[',
          (close - 4097).clamp(from, lower.length),
        );
        if (open >= 0 && open < close) {
          consider(open);
          break;
        }
        close = lower.indexOf('](', close + 2);
      }
    }
    for (final host in _bareHosts) {
      var index = lower.indexOf(host, from);
      if (index < 0) continue;
      for (final prefix in const ['www.', 'm.', 'v.']) {
        if (index - prefix.length >= from &&
            lower.substring(index - prefix.length, index) == prefix) {
          index -= prefix.length;
          break;
        }
      }
      consider(index);
    }
    return first;
  }

  static String _trimWrappers(String value, String? opening) {
    // Balanced parentheses may be part of a URL. Only unmatched closing
    // wrappers are removable. Query/fragment punctuation is not blanket-trimmed.
    for (final pair in const [('(', ')'), ('[', ']'), ('{', '}'), ('（', '）')]) {
      if (opening != pair.$1) continue;
      var balance = 0;
      for (final char in value.split('')) {
        if (char == pair.$1) balance++;
        if (char == pair.$2) balance--;
      }
      while (balance < 0 && value.endsWith(pair.$2)) {
        value = value.substring(0, value.length - 1);
        balance++;
      }
    }
    return value;
  }

  static ClipboardLink? _classify(String input) {
    if (input.isEmpty || input.length > maxUrlLength) return null;
    var value = input;
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(value)) {
      if (!_start.hasMatch(value) ||
          _start.firstMatch(value)!.start != 0 ||
          value.contains('://')) {
        return null;
      }
      value = 'https://$value';
    }
    if (_percent.hasMatch(value) ||
        value.contains('\\') ||
        value.contains(RegExp(r'[\x00-\x20\x7f]'))) {
      return null;
    }
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme.toLowerCase()) ||
        uri.userInfo.isNotEmpty ||
        !_validHost(uri.host)) {
      return null;
    }
    try {
      if (uri.hasPort && (uri.port < 1 || uri.port > 65535)) return null;
    } on FormatException {
      return null;
    }
    final host = uri.host.toLowerCase();
    // Keep the executable URL byte-for-byte. Uri.toString()/replace can
    // normalize percent escapes, which can invalidate a signed address.
    // Special routes compare real hosts with domain boundaries, never URL text.
    if ((!uri.hasPort || uri.port == 80 || uri.port == 443) &&
        const {
          'bilibili.com',
          'www.bilibili.com',
          'm.bilibili.com',
          'b23.tv',
          'bili2233.cn',
        }.contains(host)) {
      final validPath =
          (const {'b23.tv', 'bili2233.cn'}.contains(host) &&
              RegExp(r'^/[A-Za-z0-9_-]+/?$').hasMatch(uri.path)) ||
          RegExp(
            r'^/(?:video/(?:BV[0-9A-Za-z]{10}|av\d{1,19})|(?:bangumi|cheese)/play/(?:ep|ss)\d{1,19})/?$',
            caseSensitive: false,
          ).hasMatch(uri.path);
      BilibiliLinkTarget? target;
      if (validPath) {
        try {
          target = parseBilibiliLink(value);
        } on FormatException {
          // Percent-encoded bytes can be syntactically valid URL data while
          // not being valid UTF-8 query parameters for the legacy parser.
        }
      }
      return ClipboardLink(
        value,
        ClipboardLinkKind.bilibili,
        '哔哩哔哩链接',
        bilibili: target,
      );
    }
    // Only identify the source. Paths, IDs and ports do not prove whether the
    // page is downloadable and must not suppress its dedicated shortcut.
    if (_isDouyinHost(host)) {
      return ClipboardLink(value, ClipboardLinkKind.douyin, '抖音链接');
    }
    if ((host == 'podcasts.apple.com' || host == 'itunes.apple.com') &&
            RegExp(
              r'^/(?:[a-z]{2}/)?podcast/(?:[^/]+/)?id\d+/?$',
            ).hasMatch(uri.path) ||
        const {'xiaoyuzhoufm.com', 'www.xiaoyuzhoufm.com'}.contains(host) &&
            RegExp(
              r'^/(?:podcast|episode)/[0-9a-f]{24}/?$',
            ).hasMatch(uri.path) ||
        const {'www.ximalaya.com', 'ximalaya.com'}.contains(host) &&
            RegExp(r'^/(?:album|sound)/\d+/?$').hasMatch(uri.path)) {
      return ClipboardLink(value, ClipboardLinkKind.podcast, '播客链接');
    }
    if (RegExp(
      r'(?:^|/)(?:feed|rss|podcast)(?:\.xml|\.rss)?/?$|\.rss$',
      caseSensitive: false,
    ).hasMatch(uri.path)) {
      return ClipboardLink(value, ClipboardLinkKind.feed, '订阅源链接');
    }
    final label =
        const {
          'youtube.com',
          'www.youtube.com',
          'm.youtube.com',
          'youtu.be',
        }.contains(host)
        ? 'YouTube 链接'
        : const {
            'x.com',
            'www.x.com',
            'twitter.com',
            'www.twitter.com',
            'mobile.twitter.com',
          }.contains(host)
        ? 'X 链接'
        : '网页链接';
    return ClipboardLink(value, ClipboardLinkKind.web, label);
  }

  static bool _validHost(String host) {
    try {
      final decoded = Uri.decodeComponent(host);
      return _domain.hasMatch(decoded) &&
          !decoded.toLowerCase().endsWith('.local');
    } on FormatException {
      return false;
    }
  }
}

/// BV id the clipboard dialog's "播放" plays: the matched video of a
/// collection link, else the link's own BV (or av converted). Bangumi links
/// have no plain video to play here.
String? clipboardWatchBvid(BilibiliLinkTarget link, {String? targetBvid}) {
  if (link.isBangumi || link.isCourse) return null;
  final matched = targetBvid?.trim();
  if (matched != null && matched.isNotEmpty) return matched;
  return link.bvid ?? (link.aid != null ? bvidFromAid(link.aid!) : null);
}
