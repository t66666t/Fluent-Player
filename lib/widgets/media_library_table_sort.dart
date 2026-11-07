import '../models/media_library_view_mode.dart';
import '../models/video_collection.dart';
import '../models/video_item.dart';
import '../services/library_service.dart';

/// View-only ordering for the details table.
///
/// [MediaTableSortKey.manual] returns [contents] unchanged (same instance is
/// fine). Folders ([VideoCollection]) always sort before media items. The sort
/// is stable: equal keys keep their original relative order. This never writes
/// back to the library's stored folder order.
List<dynamic> sortMediaLibraryContents(
  List<dynamic> contents,
  MediaTableSortKey key,
  bool descending, {
  LibraryService? library,
}) {
  if (key == MediaTableSortKey.manual) {
    return contents;
  }

  final indexed = contents.asMap().entries.toList(growable: false);
  indexed.sort((leftEntry, rightEntry) {
    final left = leftEntry.value;
    final right = rightEntry.value;
    final folderOrder = _folderOrder(left, right);
    if (folderOrder != 0) return folderOrder;

    final comparison = _compareItems(left, right, key);
    if (comparison != 0) {
      return descending ? -comparison : comparison;
    }
    return leftEntry.key.compareTo(rightEntry.key);
  });
  return [for (final entry in indexed) entry.value];
}

int _folderOrder(dynamic left, dynamic right) {
  final leftFolder = left is VideoCollection;
  final rightFolder = right is VideoCollection;
  if (leftFolder == rightFolder) return 0;
  return leftFolder ? -1 : 1;
}

int _compareItems(dynamic left, dynamic right, MediaTableSortKey key) {
  return switch (key) {
    MediaTableSortKey.manual => 0,
    MediaTableSortKey.title => _compareTitle(left, right),
    MediaTableSortKey.type => _compareType(left, right),
    MediaTableSortKey.duration => _compareDuration(left, right),
    MediaTableSortKey.progress => _compareProgress(left, right),
    MediaTableSortKey.updated => _compareUpdated(left, right),
  };
}

String _displayTitle(dynamic item) =>
    item is VideoCollection ? item.name : (item as VideoItem).title;

int _compareTitle(dynamic left, dynamic right) =>
    LibraryService.compareStructuredImportNames(
      _displayTitle(left),
      _displayTitle(right),
    );

String _typeLabel(dynamic item) {
  if (item is VideoCollection) return '文件夹';
  return (item as VideoItem).type == MediaType.audio ? '音频' : '视频';
}

int _compareType(dynamic left, dynamic right) =>
    _typeLabel(left).compareTo(_typeLabel(right));

int _durationSortMs(dynamic item) {
  if (item is VideoCollection) return item.childrenIds.length;
  return (item as VideoItem).durationMs;
}

int _compareDuration(dynamic left, dynamic right) =>
    _durationSortMs(left).compareTo(_durationSortMs(right));

double _progressFraction(dynamic item) {
  if (item is VideoCollection) return 0;
  final video = item as VideoItem;
  if (video.durationMs <= 0) return 0;
  return video.lastPositionMs / video.durationMs;
}

int _compareProgress(dynamic left, dynamic right) {
  final leftValue = _progressFraction(left);
  final rightValue = _progressFraction(right);
  return leftValue.compareTo(rightValue);
}

int _updatedSortMs(dynamic item) =>
    item is VideoCollection
        ? item.createTime
        : (item as VideoItem).lastUpdated;

int _compareUpdated(dynamic left, dynamic right) =>
    _updatedSortMs(left).compareTo(_updatedSortMs(right));
