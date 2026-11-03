import 'package:path/path.dart' as p;

/// Normalize a local filesystem path from pickers, drag-drop, or share intents.
///
/// Strips `file://` URIs (common on Linux desktop_drop), trims whitespace, and
/// returns null for empty input. Network / app-scheme URIs are left untouched
/// except for trim + normalize of non-URI paths.
String? normalizeLocalFilesystemPath(String? path) {
  final String? trimmed = path?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  if (trimmed.startsWith('http://') ||
      trimmed.startsWith('https://') ||
      trimmed.startsWith('bilibili://') ||
      trimmed.startsWith('content://')) {
    return trimmed;
  }
  if (trimmed.startsWith('file://')) {
    try {
      return p.normalize(Uri.parse(trimmed).toFilePath());
    } catch (_) {
      // file:///foo -> /foo ; file://foo -> /foo (best-effort)
      final stripped = trimmed.replaceFirst(RegExp(r'^file://'), '');
      if (stripped.startsWith('/')) {
        return p.normalize(stripped);
      }
      return p.normalize('/$stripped');
    }
  }
  return p.normalize(trimmed);
}
