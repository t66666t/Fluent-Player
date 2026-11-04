import '../models/video_item.dart';
import 'library_service.dart';

/// Legacy journals can recover by exact source identity, never by title.
/// Import time stays stable when a card is renamed, moved or played.
String? findLatestImportedCardId(
  LibraryService library,
  bool Function(VideoItem item) matches,
) {
  String? result;
  var newest = -1;
  var count = 0;
  var missingImportTime = false;
  var tied = false;
  for (final item in library.storageVideos) {
    if (item.isTransient || !matches(item)) continue;
    count++;
    final recordedTime = library.mediaActivity(item.id)?.addedAtMs;
    missingImportTime |= recordedTime == null;
    final added = recordedTime ?? 0;
    if (added > newest) {
      newest = added;
      result = item.id;
      tied = false;
    } else if (added == newest) {
      tied = true;
    }
  }
  // An old journal without an id cannot prove which of ambiguous cards was
  // imported last. Keep the user's queue untouched instead of guessing.
  if (count > 1 && (missingImportTime || tied)) return null;
  return result;
}
