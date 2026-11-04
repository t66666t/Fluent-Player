import 'dart:convert';

import 'package:characters/characters.dart';

/// Bounds an already sanitized title for native download filenames. Reserve
/// space for task/video IDs, media extensions, partial files and sidecars.
String limitDownloadFileNameStem(String value, {int maxCodeUnits = 80}) {
  final limited = StringBuffer();
  var bytes = 0;
  for (final character in value.characters) {
    final size = utf8.encode(character).length;
    if (bytes + size > 180 ||
        limited.length + character.length > maxCodeUnits) {
      break;
    }
    limited.write(character);
    bytes += size;
  }
  return limited.toString().trim().replaceAll(RegExp(r'[. ]+$'), '');
}
