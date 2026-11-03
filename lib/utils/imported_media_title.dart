import 'package:path/path.dart' as p;

/// Resolves the title shown by the media library after an import.
///
/// [originalTitle] is metadata, not a file path. In particular, `/` and `\\`
/// are valid title characters and must never be interpreted as separators.
String resolveImportedMediaTitle({
  required String sourcePath,
  String? originalTitle,
}) {
  if (originalTitle != null && originalTitle.trim().isNotEmpty) {
    return originalTitle;
  }

  final fileName = p.basename(sourcePath).trim();
  var title = fileName;
  title = title.replaceFirst(RegExp(r'^incoming_media_\d+_'), '');
  title = title.replaceFirst(RegExp(r'^shared_media_\d+_'), '');
  title = title.replaceFirst(
    RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}_',
    ),
    '',
  );
  return title.isEmpty ? fileName : title;
}
