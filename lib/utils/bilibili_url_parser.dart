/// Bilibili link recognition shared by the search box, description links,
/// the clipboard check and the download page.
///
/// [parseBilibiliLink] turns user text into a [BilibiliLinkTarget] (video id,
/// 1-based part, start time). b23.tv short links are resolved by
/// [resolveBilibiliShortLink] through an injected cookie-free request.
/// [BilibiliUrlParser] is the download page's multi-line input normalizer and
/// shares the id patterns below.
library;

import 'dart:async';

// ------------------------------------------------------------------ hosts

const List<String> _videoHosts = <String>['bilibili.com'];
const List<String> _shortHosts = <String>['b23.tv', 'bili2233.cn'];

bool _hostIn(String host, List<String> domains) {
  final lower = host.toLowerCase();
  return domains.any((d) => lower == d || lower.endsWith('.$d'));
}

/// `bilibili.com` or one of its subdomains.
bool isBilibiliVideoHost(String host) => _hostIn(host, _videoHosts);

/// `b23.tv` / `bili2233.cn` short-link hosts.
bool isBilibiliShortHost(String host) => _hostIn(host, _shortHosts);

// -------------------------------------------------------------- id helpers

final RegExp _bvExact = RegExp(r'^BV[0-9A-Za-z]{10}$', caseSensitive: false);
final RegExp _avExact = RegExp(r'^av(\d{1,19})$', caseSensitive: false);
final RegExp _bangumiExact = RegExp(
  r'^(ep|ss)(\d{1,19})$',
  caseSensitive: false,
);
final RegExp _bvInPath = RegExp(r'BV[0-9A-Za-z]{10}', caseSensitive: false);
final RegExp _avInPath = RegExp(r'/av(\d{1,19})(?:/|$)', caseSensitive: false);
final RegExp _bangumiInPath = RegExp(
  r'/bangumi/play/(ep|ss)(\d{1,19})(?:/|$)',
  caseSensitive: false,
);
final RegExp _bangumiShortPath = RegExp(
  r'^/(ep|ss)(\d{1,19})/?$',
  caseSensitive: false,
);
final RegExp _courseInPath = RegExp(
  r'^/cheese/play/(ep|ss)(\d{1,19})/?$',
  caseSensitive: false,
);
final RegExp _bvInText = RegExp(
  r'(?<![0-9A-Za-z])BV[0-9A-Za-z]{10}(?![0-9A-Za-z])',
  caseSensitive: false,
);
final RegExp _avInText = RegExp(
  r'(?<![0-9A-Za-z])av(\d{1,19})(?![0-9A-Za-z])',
  caseSensitive: false,
);
final RegExp _bangumiInText = RegExp(
  r'(?<![0-9A-Za-z])(ep|ss)(\d{1,19})(?![0-9A-Za-z])',
  caseSensitive: false,
);
final RegExp _urlInText = RegExp(r'https?://[^\s，。！？、；：“”‘’（）【】<>"]+');
final RegExp _urlTrailingPunctuation = RegExp(r'[.,!?;:)\]]+$');

/// Normalizes the "bv" prefix casing: `bv1xx` -> `BV1xx`.
String normalizeBvidCase(String value) =>
    value.length < 2 ? value : 'BV${value.substring(2)}';

const String _bvAlphabet =
    'FcwAPNKTMug3GV5Lj7EJnHpWsx4tb8haYeviqBz6rkCy12mUSDQX9RdoZf';
const int _bvXor = 23442827791579;
const int _bvAidLimit = 1 << 51;
const int _bvBase = 58;

/// Converts an av number to its BV id, or null when out of range.
String? bvidFromAid(int aid) {
  if (aid <= 0 || aid >= _bvAidLimit) return null;
  final chars = 'BV1000000000'.split('');
  var value = (_bvAidLimit | aid) ^ _bvXor;
  for (var i = chars.length - 1; value > 0 && i >= 3; i--) {
    chars[i] = _bvAlphabet[value % _bvBase];
    value ~/= _bvBase;
  }
  _swapBvDigits(chars);
  return chars.join();
}

/// Converts a BV id back to its av number, or null when it is not a BV id.
int? aidFromBvid(String bvid) {
  if (!_bvExact.hasMatch(bvid)) return null;
  final chars = normalizeBvidCase(bvid).split('');
  _swapBvDigits(chars);
  var value = 0;
  for (final char in chars.skip(3)) {
    final digit = _bvAlphabet.indexOf(char);
    if (digit < 0) return null;
    value = value * _bvBase + digit;
  }
  final aid = (value & (_bvAidLimit - 1)) ^ _bvXor;
  return aid > 0 ? aid : null;
}

void _swapBvDigits(List<String> chars) {
  for (final (a, b) in const [(3, 9), (4, 7)]) {
    final tmp = chars[a];
    chars[a] = chars[b];
    chars[b] = tmp;
  }
}

// ------------------------------------------------------------ link target

/// What a piece of user text points to on Bilibili.
class BilibiliLinkTarget {
  /// BV id; filled for av input too when it converts.
  final String? bvid;

  /// av number when the input used one.
  final int? aid;

  /// `ep123` / `ss456` for bangumi links.
  final String? bangumiId;

  /// Classroom ids have a separate namespace from bangumi ep/ss ids.
  final String? courseId;

  /// Short link that still needs [resolveBilibiliShortLink].
  final Uri? shortLink;

  /// 1-based part number, or null when the link does not name one.
  final int? page;

  /// Start time from `t` (seconds) or `start_progress` (milliseconds).
  final Duration? startAt;

  const BilibiliLinkTarget({
    this.bvid,
    this.aid,
    this.bangumiId,
    this.courseId,
    this.shortLink,
    this.page,
    this.startAt,
  });

  bool get needsResolve =>
      bvid == null &&
      aid == null &&
      bangumiId == null &&
      courseId == null &&
      shortLink != null;

  bool get isBangumi => bangumiId != null;
  bool get isCourse => courseId != null;

  /// A single video (or a short link that may lead to one).
  bool get isVideo => !isBangumi && !isCourse;

  int get pageOrFirst => page ?? 1;

  /// Input handed to the download parser: a video/bangumi id or a classroom
  /// URL, whose path preserves its separate ep/ss namespace.
  String? get parseInput =>
      bvid ??
      (aid != null ? 'av$aid' : null) ??
      bangumiId ??
      (courseId != null
          ? 'https://www.bilibili.com/cheese/play/$courseId'
          : null);

  /// Fills [page] / [startAt] from [fallback] when this target has none, e.g.
  /// parameters on the short link itself.
  BilibiliLinkTarget withDefaultsFrom(BilibiliLinkTarget fallback) =>
      BilibiliLinkTarget(
        bvid: bvid,
        aid: aid,
        bangumiId: bangumiId,
        courseId: courseId,
        shortLink: shortLink,
        page: page ?? fallback.page,
        startAt: startAt ?? fallback.startAt,
      );

  @override
  String toString() =>
      'BilibiliLinkTarget(${parseInput ?? shortLink}, p=$page, t=$startAt)';
}

/// Recognizes a bare BV / av id (or `ep` / `ss`) or a Bilibili video, bangumi
/// or short link inside [raw]. Returns null for anything else.
///
/// With [findIdInText] a BV / av / ep / ss id is also picked out of
/// surrounding text (clipboard); otherwise such text is treated as a keyword.
BilibiliLinkTarget? parseBilibiliLink(String raw, {bool findIdInText = false}) {
  final text = raw.trim();
  if (text.isEmpty) return null;

  final exact = _parseBareId(text);
  if (exact != null) return exact;

  final urlMatch = _urlInText.firstMatch(text);
  if (urlMatch != null) {
    final cleaned = urlMatch.group(0)!.replaceAll(_urlTrailingPunctuation, '');
    final uri = Uri.tryParse(cleaned);
    final fromUrl = uri == null ? null : _parseUrl(uri);
    if (fromUrl != null || !findIdInText) return fromUrl;
  }
  if (!findIdInText) return null;

  // Ids inside a link to some other site do not count.
  final plain = text.replaceAll(_urlInText, ' ');
  final bv = _bvInText.firstMatch(plain);
  if (bv != null) {
    return BilibiliLinkTarget(bvid: normalizeBvidCase(bv.group(0)!));
  }
  final av = _avInText.firstMatch(plain);
  if (av != null) {
    final target = _avTarget(av.group(1)!);
    if (target != null) return target;
  }
  final bangumi = _bangumiInText.firstMatch(plain);
  if (bangumi != null) {
    return BilibiliLinkTarget(
      bangumiId: '${bangumi.group(1)!.toLowerCase()}${bangumi.group(2)}',
    );
  }
  return null;
}

/// Finds a target inside a resolved redirect URL; only bilibili.com counts.
BilibiliLinkTarget? parseResolvedBilibiliUrl(Uri uri) {
  if (!uri.hasAuthority || !isBilibiliVideoHost(uri.host)) return null;
  return _parseUrl(uri);
}

BilibiliLinkTarget? _parseBareId(String text) {
  if (_bvExact.hasMatch(text)) {
    return BilibiliLinkTarget(bvid: normalizeBvidCase(text));
  }
  final av = _avExact.firstMatch(text);
  if (av != null) return _avTarget(av.group(1)!);
  final bangumi = _bangumiExact.firstMatch(text);
  if (bangumi != null) {
    return BilibiliLinkTarget(
      bangumiId: '${bangumi.group(1)!.toLowerCase()}${bangumi.group(2)}',
    );
  }
  return null;
}

BilibiliLinkTarget? _avTarget(String digits, {int? page, Duration? startAt}) {
  final aid = int.tryParse(digits);
  if (aid == null || aid <= 0) return null;
  return BilibiliLinkTarget(
    bvid: bvidFromAid(aid),
    aid: aid,
    page: page,
    startAt: startAt,
  );
}

BilibiliLinkTarget? _parseUrl(Uri uri) {
  if (!uri.hasAuthority) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'https' && scheme != 'http') return null;
  final query = uri.queryParameters;
  final page = _pageFrom(query);
  final startAt = _startFrom(query);

  if (isBilibiliShortHost(uri.host)) {
    // APP shares also use explicit bangumi addresses, e.g. b23.tv/ep273401.
    // Their path already identifies the episode/season; no redirect is needed.
    if (_hostIn(uri.host, const ['b23.tv'])) {
      final bangumi = _bangumiShortPath.firstMatch(uri.path);
      if (bangumi != null) {
        return BilibiliLinkTarget(
          bangumiId: '${bangumi.group(1)!.toLowerCase()}${bangumi.group(2)}',
          startAt: startAt,
        );
      }
    }
    if (uri.path.replaceAll('/', '').isEmpty) return null;
    return BilibiliLinkTarget(shortLink: uri, page: page, startAt: startAt);
  }
  if (!isBilibiliVideoHost(uri.host)) return null;

  final course = _courseInPath.firstMatch(uri.path);
  if (course != null) {
    return BilibiliLinkTarget(
      courseId: '${course.group(1)!.toLowerCase()}${course.group(2)}',
      startAt: startAt,
    );
  }
  final bangumi = _bangumiInPath.firstMatch(uri.path);
  if (bangumi != null) {
    return BilibiliLinkTarget(
      bangumiId: '${bangumi.group(1)!.toLowerCase()}${bangumi.group(2)}',
      startAt: startAt,
    );
  }
  final bv = _bvInPath.firstMatch(uri.path);
  if (bv != null) {
    return BilibiliLinkTarget(
      bvid: normalizeBvidCase(bv.group(0)!),
      page: page,
      startAt: startAt,
    );
  }
  final avPath = _avInPath.firstMatch(uri.path);
  if (avPath != null) {
    return _avTarget(avPath.group(1)!, page: page, startAt: startAt);
  }
  final bvQuery = query['bvid'] ?? '';
  if (_bvExact.hasMatch(bvQuery)) {
    return BilibiliLinkTarget(
      bvid: normalizeBvidCase(bvQuery),
      page: page,
      startAt: startAt,
    );
  }
  final aidQuery = query['aid'] ?? query['avid'] ?? '';
  if (RegExp(r'^\d{1,19}$').hasMatch(aidQuery)) {
    return _avTarget(aidQuery, page: page, startAt: startAt);
  }
  return null;
}

/// `p` is 1-based, `page` is 0-based; neither means "not specified".
int? _pageFrom(Map<String, String> query) {
  final p = int.tryParse(query['p']?.trim() ?? '');
  if (p != null) return p >= 1 ? p : null;
  final zeroBased = int.tryParse(query['page']?.trim() ?? '');
  if (zeroBased != null && zeroBased >= 0) return zeroBased + 1;
  return null;
}

/// `t` is seconds (decimals allowed), `start_progress` is milliseconds.
/// Zero or negative values mean "from the beginning" and give null.
Duration? _startFrom(Map<String, String> query) {
  final seconds = double.tryParse(query['t']?.trim() ?? '');
  if (seconds != null && seconds.isFinite) {
    return seconds > 0
        ? Duration(milliseconds: (seconds * 1000).round())
        : null;
  }
  final millis = int.tryParse(query['start_progress']?.trim() ?? '');
  if (millis != null) return millis > 0 ? Duration(milliseconds: millis) : null;
  return null;
}

// -------------------------------------------------------------- short link

const int kBilibiliShortLinkMaxRedirects = 5;
const Duration kBilibiliShortLinkTimeout = Duration(seconds: 5);

/// Why a short link could not be resolved.
enum BilibiliShortLinkFailure {
  insecureScheme('短链接只支持 https'),
  foreignHost('短链接跳转到了 B 站以外的网站'),
  tooManyRedirects('短链接跳转次数过多'),
  timeout('短链接解析超时，请检查网络'),
  network('短链接解析失败，请检查网络'),
  noVideo('链接里没有找到视频');

  const BilibiliShortLinkFailure(this.message);

  /// Chinese text for a toast.
  final String message;

  /// Network trouble may go away; the other failures are final for a link.
  bool get isRetryable => this == timeout || this == network;
}

/// Outcome of [resolveBilibiliShortLink]: a target or a failure, never both.
class BilibiliShortLinkResult {
  final BilibiliLinkTarget? target;
  final BilibiliShortLinkFailure? failure;

  const BilibiliShortLinkResult.success(BilibiliLinkTarget this.target)
    : failure = null;

  const BilibiliShortLinkResult.failed(BilibiliShortLinkFailure this.failure)
    : target = null;

  bool get isSuccess => target != null;

  String? get message => failure?.message;
}

/// `http://b23.tv/...` (or another short-link host) as https; any other
/// link is returned unchanged. Only the address the user supplied is
/// upgraded, never a redirect target.
Uri upgradeBilibiliShortLink(Uri link) {
  if (link.scheme.toLowerCase() == 'http' && isBilibiliShortHost(link.host)) {
    return link.replace(scheme: 'https');
  }
  return link;
}

/// One request of the redirect chain: the `Location` it points to, or null
/// when the response is not a redirect. Throws on network errors.
typedef BilibiliRedirectFetcher = Future<Uri?> Function(Uri url);

/// Follows [link] with [fetchRedirect] until it reaches a Bilibili video.
///
/// A starting `http://` short link (b23.tv / bili2233.cn) is upgraded to
/// https first. After that every hop must be https and stay on b23.tv /
/// bili2233.cn / bilibili.com; at most [maxRedirects] redirects are followed
/// and the whole chain must finish within [timeout]. Never throws; failures
/// come back as a result.
Future<BilibiliShortLinkResult> resolveBilibiliShortLink(
  Uri link, {
  required BilibiliRedirectFetcher fetchRedirect,
  int maxRedirects = kBilibiliShortLinkMaxRedirects,
  Duration timeout = kBilibiliShortLinkTimeout,
}) async {
  final fromLink = _parseUrl(link) ?? const BilibiliLinkTarget();
  final start = upgradeBilibiliShortLink(link);
  Future<BilibiliShortLinkResult> follow() async {
    var current = start;
    var redirects = 0;
    while (true) {
      if (current.scheme.toLowerCase() != 'https') {
        return const BilibiliShortLinkResult.failed(
          BilibiliShortLinkFailure.insecureScheme,
        );
      }
      if (!isBilibiliShortHost(current.host) &&
          !isBilibiliVideoHost(current.host)) {
        return const BilibiliShortLinkResult.failed(
          BilibiliShortLinkFailure.foreignHost,
        );
      }
      final resolved = _parseUrl(current);
      if (resolved != null && !resolved.needsResolve) {
        return BilibiliShortLinkResult.success(
          resolved.withDefaultsFrom(fromLink),
        );
      }
      if (isBilibiliVideoHost(current.host)) {
        // Landed on the main site: either a video page or nothing to open.
        return const BilibiliShortLinkResult.failed(
          BilibiliShortLinkFailure.noVideo,
        );
      }
      if (redirects >= maxRedirects) {
        return const BilibiliShortLinkResult.failed(
          BilibiliShortLinkFailure.tooManyRedirects,
        );
      }
      final Uri? next;
      try {
        next = await fetchRedirect(current);
      } catch (_) {
        return const BilibiliShortLinkResult.failed(
          BilibiliShortLinkFailure.network,
        );
      }
      if (next == null) {
        return const BilibiliShortLinkResult.failed(
          BilibiliShortLinkFailure.noVideo,
        );
      }
      redirects++;
      current = current.resolveUri(next);
    }
  }

  try {
    return await follow().timeout(timeout);
  } on TimeoutException {
    return const BilibiliShortLinkResult.failed(
      BilibiliShortLinkFailure.timeout,
    );
  }
}

// ------------------------------------------------- download page normalizer

class BilibiliNormalizedInput {
  final String cleanedInput;
  final BilibiliUrlType type;
  final String? id;

  const BilibiliNormalizedInput({
    required this.cleanedInput,
    required this.type,
    required this.id,
  });
}

/// Normalizes one line of the download page input (BV / av / ep / ss / link)
/// while keeping the cleaned text, which the download task records as its
/// source. Video recognition with part and start time is
/// [parseBilibiliLink].
class BilibiliUrlParser {
  static const String _bvPattern = r'(BV[a-zA-Z0-9]{10})';
  static const String _avPattern = r'(av\d+)';
  static const String _epPattern = r'(ep\d+)';
  static const String _ssPattern = r'(ss\d+)';

  static BilibiliNormalizedInput? normalizeInput(String rawInput) {
    final trimmed = rawInput.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    String cleanedInput = trimmed;
    final linkMatch = RegExp(r'(https?://[^\s]+)').firstMatch(trimmed);
    if (linkMatch != null) {
      cleanedInput = linkMatch.group(0)!;
      cleanedInput = cleanedInput.replaceAll(RegExp(r'[.,!?;:")]*$'), '');
    } else {
      final bvMatch = RegExp(
        _bvPattern,
        caseSensitive: false,
      ).firstMatch(trimmed);
      if (bvMatch != null) {
        cleanedInput = normalizeBvidCase(bvMatch.group(0)!);
      } else {
        final ssMatch = RegExp(
          _ssPattern,
          caseSensitive: false,
        ).firstMatch(trimmed);
        if (ssMatch != null) {
          cleanedInput = ssMatch.group(0)!.toLowerCase();
        } else {
          final epMatch = RegExp(
            _epPattern,
            caseSensitive: false,
          ).firstMatch(trimmed);
          if (epMatch != null) {
            cleanedInput = epMatch.group(0)!.toLowerCase();
          } else {
            final avMatch = RegExp(
              _avPattern,
              caseSensitive: false,
            ).firstMatch(trimmed);
            if (avMatch != null) {
              cleanedInput = avMatch.group(0)!.toLowerCase();
            }
          }
        }
      }
    }

    final type = determineType(cleanedInput);
    final id = extractId(cleanedInput, type);
    // A short link does not contain a BV/AV/EP/SS id until its redirect is
    // resolved. Keep it as a valid normalized input so the download service
    // gets a chance to resolve it.
    if (type == BilibiliUrlType.unknown ||
        (type != BilibiliUrlType.shortLink && id == null)) {
      return null;
    }
    return BilibiliNormalizedInput(
      cleanedInput: cleanedInput,
      type: type,
      id: id,
    );
  }

  static BilibiliUrlType determineType(String input) {
    final courseId = parseBilibiliLink(input)?.courseId;
    if (courseId != null) {
      return courseId.startsWith('ep')
          ? BilibiliUrlType.courseEp
          : BilibiliUrlType.courseSs;
    }
    if (input.contains("b23.tv") || input.contains("bili2233.cn")) {
      final bangumiId = parseBilibiliLink(input)?.bangumiId;
      if (bangumiId != null) {
        return bangumiId.startsWith('ep')
            ? BilibiliUrlType.bangumiEp
            : BilibiliUrlType.bangumiSs;
      }
      return BilibiliUrlType.shortLink;
    }
    if (RegExp(_bvPattern).hasMatch(input)) return BilibiliUrlType.videoBv;
    if (RegExp(_avPattern, caseSensitive: false).hasMatch(input)) {
      return BilibiliUrlType.videoAv;
    }
    if (RegExp(_epPattern, caseSensitive: false).hasMatch(input)) {
      return BilibiliUrlType.bangumiEp;
    }
    if (RegExp(_ssPattern, caseSensitive: false).hasMatch(input)) {
      return BilibiliUrlType.bangumiSs;
    }

    return BilibiliUrlType.unknown;
  }

  static String? extractId(String input, BilibiliUrlType type) {
    switch (type) {
      case BilibiliUrlType.videoBv:
        final match = RegExp(
          _bvPattern,
          caseSensitive: false,
        ).firstMatch(input)?.group(1);
        return match == null ? null : normalizeBvidCase(match);
      case BilibiliUrlType.videoAv:
        return RegExp(
          _avPattern,
          caseSensitive: false,
        ).firstMatch(input)?.group(1)?.toLowerCase();
      case BilibiliUrlType.bangumiEp:
      case BilibiliUrlType.courseEp:
        return RegExp(
          _epPattern,
          caseSensitive: false,
        ).firstMatch(input)?.group(1)?.toLowerCase();
      case BilibiliUrlType.bangumiSs:
      case BilibiliUrlType.courseSs:
        return RegExp(
          _ssPattern,
          caseSensitive: false,
        ).firstMatch(input)?.group(1)?.toLowerCase();
      default:
        return null;
    }
  }

  static String normalizeBvValue(String value) => normalizeBvidCase(value);
}

enum BilibiliUrlType {
  videoBv,
  videoAv,
  bangumiEp,
  bangumiSs,
  courseEp,
  courseSs,
  shortLink,
  unknown,
}
