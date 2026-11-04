import 'clipboard_link.dart';

/// Browser URL metadata is authoritative; its visible label may name another
/// site. Plain text uses exactly the same bounded extraction as the clipboard.
List<ClipboardLink> detectDesktopDroppedLinks({
  String? text,
  List<String> urls = const [],
}) {
  if (urls.isEmpty) return ClipboardLinkDetector.detect(text ?? '');
  if (urls.length > ClipboardLinkDetector.maxLinks) return const [];
  var length = 0;
  final result = <ClipboardLink>[];
  final seen = <String>{};
  var hasTarget = false;
  for (final raw in urls) {
    length += raw.length;
    if (length > ClipboardLinkDetector.maxTextLength ||
        raw.length > ClipboardLinkDetector.maxUrlLength) {
      return const [];
    }
    final url = raw.trim();
    if (url.isEmpty) continue;
    hasTarget = true;
    final links = ClipboardLinkDetector.detect(url);
    // Do not extract an inner URL from javascript:, a file URL, or malformed
    // native metadata, and do not silently repair the browser's target.
    if (links.length != 1 || links.single.url != url) continue;
    final link = links.single;
    if (seen.add(link.identity)) result.add(link);
  }
  return hasTarget ? result : ClipboardLinkDetector.detect(text ?? '');
}
