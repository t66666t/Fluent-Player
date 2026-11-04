import 'dart:io';

import 'package:path/path.dart' as p;

/// The three mutually exclusive sections shown by subtitle management.
enum SubtitleCategory { downloadAssociated, embedded, local }

/// Classifies subtitle files by immutable origin, never by playback role.
///
/// Download association has highest priority because it is explicit metadata
/// written by Bilibili/yt-dlp import. Extracted embedded files are identified by
/// the embedded-track registry. Every other filesystem subtitle is local.
class SubtitleClassificationIndex {
  final Set<String> _downloadAssociatedPaths;
  final Set<String> _extractedEmbeddedPaths;

  SubtitleClassificationIndex({
    Iterable<String> downloadAssociatedPaths = const <String>[],
    Iterable<String> extractedEmbeddedPaths = const <String>[],
  }) : _downloadAssociatedPaths = downloadAssociatedPaths
           .where((path) => path.isNotEmpty)
           .map(_pathKey)
           .toSet(),
       _extractedEmbeddedPaths = extractedEmbeddedPaths
           .where((path) => path.isNotEmpty)
           .map(_pathKey)
           .toSet();

  SubtitleCategory categoryForPath(String path) {
    final key = _pathKey(path);
    if (_downloadAssociatedPaths.contains(key)) {
      return SubtitleCategory.downloadAssociated;
    }
    if (_extractedEmbeddedPaths.contains(key)) {
      return SubtitleCategory.embedded;
    }
    return SubtitleCategory.local;
  }

  static String _pathKey(String path) {
    final normalized = p.normalize(path);
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }
}
