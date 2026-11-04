/// Image URL handling for Bilibili covers and avatars.
///
/// Only HTTPS images on Bilibili's own image CDNs are loaded. Anything else
/// (other hosts, credentials in the URL, literal IPs, odd schemes) is dropped
/// so the UI shows a placeholder instead.
library;

const List<String> _allowedImageDomains = <String>['hdslb.com', 'biliimg.com'];

/// Small cover variant used by lists (and as the detail header placeholder).
/// 16:10, so it must not be the player poster: covering a 16:9 frame with it
/// zooms the picture, then the sharper 16:9 file snaps back.
const String bilibiliCoverThumbnailSuffix = '@320w_200h_1c.webp';

/// 16:9 stand-in for the player poster. Same crop as [bilibiliCoverSharpTiers],
/// so swapping up to a sharper file does not change the framing.
const String bilibiliCoverFrameSuffix = '@320w_180h_1c.webp';

/// Sharper 16:9 cover sizes for the detail header, smallest first. Wider
/// than the last one loads the original image without a suffix.
const List<(int, String)> bilibiliCoverSharpTiers = <(int, String)>[
  (672, '@672w_378h_1c.webp'),
  (960, '@960w_540h_1c.webp'),
  (1280, '@1280w_720h_1c.webp'),
];

final RegExp _hostPattern = RegExp(r'^[a-z0-9-]+(?:\.[a-z0-9-]+)+$');

/// Returns a normalized https URL for an allowed Bilibili image host, or null.
///
/// `//host/path` and `http://` are upgraded to https. Any existing `@...`
/// processing suffix is kept as-is.
String? normalizeBilibiliImageUrl(String? raw) {
  var value = raw?.trim() ?? '';
  if (value.isEmpty) return null;
  if (value.startsWith('//')) value = 'https:$value';
  var uri = Uri.tryParse(value);
  if (uri == null) return null;
  if (uri.scheme == 'http') {
    uri = uri.replace(scheme: 'https', port: uri.port == 80 ? 443 : uri.port);
  }
  if (uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      !uri.hasAuthority ||
      uri.path.isEmpty ||
      (uri.hasPort && uri.port != 443)) {
    return null;
  }
  final host = uri.host.toLowerCase();
  if (!_hostPattern.hasMatch(host)) return null;
  final allowed = _allowedImageDomains.any(
    (domain) => host == domain || host.endsWith('.$domain'),
  );
  if (!allowed) return null;
  return Uri(
    scheme: 'https',
    host: host,
    path: uri.path,
    query: uri.hasQuery ? uri.query : null,
  ).toString();
}

/// Cover thumbnail: normalized URL with the size suffix replacing any
/// existing processing suffix. Null means "show the placeholder".
String? bilibiliCoverThumbnailUrl(String? raw) {
  return _coverUrl(raw, bilibiliCoverThumbnailSuffix);
}

String? _coverUrl(String? raw, String suffix) {
  final normalized = normalizeBilibiliImageUrl(raw);
  if (normalized == null) return null;
  final uri = Uri.parse(normalized);
  final path = _stripProcessingSuffix(uri.path);
  return Uri(scheme: 'https', host: uri.host, path: '$path$suffix').toString();
}

/// 16:9 player-poster stand-in. Same host rules as [normalizeBilibiliImageUrl].
String? bilibiliCoverFrameUrl(String? raw) {
  return _coverUrl(raw, bilibiliCoverFrameSuffix);
}

/// Width-only resize preserves portrait/square covers. Height+crop suffixes
/// cannot be used to infer the original cover's geometry.
String? bilibiliCoverNaturalUrl(String? raw, double pixelWidth) {
  final width = bilibiliCoverSharpTiers
      .firstWhere(
        (tier) => !pixelWidth.isFinite || pixelWidth <= tier.$1,
        orElse: () => bilibiliCoverSharpTiers.last,
      )
      .$1;
  return _coverUrl(raw, '@${width}w.webp');
}

/// Player poster sized for [pixelWidth] physical pixels. Always a 16:9 crop,
/// including past the last tier: the uncropped original is not 16:9 and would
/// zoom inside the video frame. Null means "keep the stand-in".
String? bilibiliCoverVideoFrameUrl(String? raw, double pixelWidth) {
  final normalized = normalizeBilibiliImageUrl(raw);
  if (normalized == null) return null;
  var suffix = bilibiliCoverSharpTiers.last.$2;
  for (final (width, tierSuffix) in bilibiliCoverSharpTiers) {
    if (!pixelWidth.isFinite || pixelWidth <= width) {
      suffix = tierSuffix;
      break;
    }
  }
  return _coverUrl(raw, suffix);
}

/// Detail header cover sized for [pixelWidth] physical pixels (display
/// width × devicePixelRatio): the smallest tier that covers it, never below
/// 672w, or the original image when even 1280w is too small. Same host rules
/// as [normalizeBilibiliImageUrl]; null means "keep the placeholder".
String? bilibiliCoverSharpUrl(String? raw, double pixelWidth) {
  final normalized = normalizeBilibiliImageUrl(raw);
  if (normalized == null) return null;
  final uri = Uri.parse(normalized);
  final path = _stripProcessingSuffix(uri.path);
  var suffix = '';
  for (final (width, tierSuffix) in bilibiliCoverSharpTiers) {
    if (!pixelWidth.isFinite || pixelWidth <= width) {
      suffix = tierSuffix;
      break;
    }
  }
  return Uri(scheme: 'https', host: uri.host, path: '$path$suffix').toString();
}

/// Avatar: normalized only. No crop suffix, so the original framing is kept.
String? bilibiliAvatarUrl(String? raw) => normalizeBilibiliImageUrl(raw);

String _stripProcessingSuffix(String path) {
  final slash = path.lastIndexOf('/');
  final at = path.indexOf('@', slash < 0 ? 0 : slash);
  return at < 0 ? path : path.substring(0, at);
}
