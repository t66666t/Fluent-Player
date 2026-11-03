import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class PickedSubtitleFile {
  final String path;
  final String displayName;

  /// A path produced from a provider stream points into temporary storage and
  /// must be copied into the library even when automatic subtitle caching is
  /// disabled.
  final bool requiresPersistence;

  const PickedSubtitleFile({
    required this.path,
    required this.displayName,
    required this.requiresPersistence,
  });
}

Future<PickedSubtitleFile?> pickSubtitleFile({
  required List<String> allowedExtensions,
}) async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: allowedExtensions,
    allowMultiple: false,
    // Native playback consumes a path, so eagerly loading the entire subtitle
    // into memory only duplicates the later parser read. Web keeps its bytes
    // because it has no native file path, although path-based Web playback is
    // handled separately from this native fallback.
    withData: kIsWeb,
    withReadStream: !kIsWeb,
  );
  if (result == null || result.files.isEmpty) return null;

  final file = result.files.single;
  final directPath = file.path;
  if (directPath != null && directPath.trim().isNotEmpty) {
    return PickedSubtitleFile(
      path: directPath,
      displayName: file.name,
      requiresPersistence: false,
    );
  }

  if (kIsWeb) {
    throw const FileSystemException('当前 Web 字幕解析器需要可访问的文件路径');
  }

  final stream = file.readStream;
  if (stream == null) {
    throw const FileSystemException('文件选择器未返回可读取的字幕内容');
  }

  final tempRoot = await getTemporaryDirectory();
  final tempDir = Directory(p.join(tempRoot.path, 'picked_subtitles'));
  await tempDir.create(recursive: true);

  final safeName = p
      .basename(file.name)
      .replaceAll(RegExp(r'[<>:"/\\|?*\u0000-\u001F]+'), '_');
  final fallbackName = safeName.isEmpty ? 'subtitle.srt' : safeName;
  final target = File(
    p.join(
      tempDir.path,
      '${DateTime.now().microsecondsSinceEpoch}_$fallbackName',
    ),
  );
  final sink = target.openWrite();
  try {
    await sink.addStream(stream);
  } finally {
    await sink.close();
  }

  return PickedSubtitleFile(
    path: target.path,
    displayName: file.name,
    requiresPersistence: true,
  );
}
