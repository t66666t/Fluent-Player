import 'dart:io';

import 'package:path/path.dart' as p;

class BilibiliVideoShotFrame {
  final String spritePath;
  final int spriteIndex;
  final int column;
  final int row;

  const BilibiliVideoShotFrame({
    required this.spritePath,
    required this.spriteIndex,
    required this.column,
    required this.row,
  });
}

/// Card-owned Bilibili seek-preview sprite metadata.
///
/// Bilibili prepends a zero sentinel to the API `index` array. The persisted
/// [timestampsSeconds] list deliberately excludes that sentinel, so element N
/// maps directly to sprite cell N (left-to-right, then top-to-bottom).
class BilibiliVideoShot {
  final List<String> spritePaths;
  final List<int> timestampsSeconds;
  final int columns;
  final int rows;
  final int cellWidth;
  final int cellHeight;

  const BilibiliVideoShot({
    required this.spritePaths,
    required this.timestampsSeconds,
    required this.columns,
    required this.rows,
    required this.cellWidth,
    required this.cellHeight,
  });

  bool get isUsable =>
      spritePaths.isNotEmpty &&
      timestampsSeconds.isNotEmpty &&
      columns > 0 &&
      rows > 0 &&
      cellWidth > 0 &&
      cellHeight > 0;

  bool get hasLocalSprites =>
      isUsable && spritePaths.every((path) => File(path).existsSync());

  int get cellsPerSprite => columns * rows;

  BilibiliVideoShotFrame? frameAt(int positionMs) {
    if (!isUsable) return null;
    final maxFrames = spritePaths.length * cellsPerSprite;
    final availableFrames = timestampsSeconds.length.clamp(0, maxFrames);
    if (availableFrames <= 0) return null;

    final seconds = positionMs <= 0 ? 0 : positionMs / 1000;
    var low = 0;
    var high = availableFrames - 1;
    var selected = 0;
    while (low <= high) {
      final middle = low + ((high - low) >> 1);
      if (timestampsSeconds[middle] <= seconds) {
        selected = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }

    final spriteIndex = selected ~/ cellsPerSprite;
    final cellIndex = selected % cellsPerSprite;
    return BilibiliVideoShotFrame(
      spritePath: spritePaths[spriteIndex],
      spriteIndex: spriteIndex,
      column: cellIndex % columns,
      row: cellIndex ~/ columns,
    );
  }

  BilibiliVideoShot replaceRoot(String oldRoot, String newRoot) {
    return BilibiliVideoShot(
      spritePaths: spritePaths
          .map((path) => _replaceRootPath(path, oldRoot, newRoot))
          .toList(growable: false),
      timestampsSeconds: timestampsSeconds,
      columns: columns,
      rows: rows,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'spritePaths': spritePaths,
    'timestampsSeconds': timestampsSeconds,
    'columns': columns,
    'rows': rows,
    'cellWidth': cellWidth,
    'cellHeight': cellHeight,
  };

  factory BilibiliVideoShot.fromJson(Map<String, dynamic> json) {
    return BilibiliVideoShot(
      spritePaths: (json['spritePaths'] as List? ?? const <dynamic>[])
          .map((value) => _normalizeLocalFilePath(value.toString()))
          .where((value) => value.isNotEmpty)
          .toList(growable: false),
      timestampsSeconds:
          (json['timestampsSeconds'] as List? ?? const <dynamic>[])
              .map(
                (value) => value is num
                    ? value.toInt()
                    : int.tryParse(value.toString()),
              )
              .whereType<int>()
              .where((value) => value >= 0)
              .toList(growable: false),
      columns: (json['columns'] as num?)?.toInt() ?? 0,
      rows: (json['rows'] as num?)?.toInt() ?? 0,
      cellWidth: (json['cellWidth'] as num?)?.toInt() ?? 0,
      cellHeight: (json['cellHeight'] as num?)?.toInt() ?? 0,
    );
  }

  static BilibiliVideoShot? fromJsonOrNull(Object? value) {
    if (value is! Map) return null;
    final parsed = BilibiliVideoShot.fromJson(Map<String, dynamic>.from(value));
    return parsed.isUsable ? parsed : null;
  }
}

String _normalizeLocalFilePath(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return '';
  if (trimmed.startsWith('file://')) {
    try {
      return Uri.parse(trimmed).toFilePath();
    } catch (_) {}
  }
  return p.normalize(trimmed);
}

String _replaceRootPath(String value, String oldRoot, String newRoot) {
  final normalizedValue = p.normalize(value);
  final normalizedOldRoot = p.normalize(oldRoot);
  if (!p.equals(normalizedValue, normalizedOldRoot) &&
      !p.isWithin(normalizedOldRoot, normalizedValue)) {
    return value;
  }
  final relative = p.relative(normalizedValue, from: normalizedOldRoot);
  return p.normalize(p.join(newRoot, relative));
}
